//! miniaudio device wrapper. f32 stereo interleaved at 48 kHz, 256-frame
//! target block. The data callback dispatches to a Zig render function
//! with a user context pointer. No allocation on the audio thread.

const std = @import("std");
const c = @import("c.zig");

pub const SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: u32 = 2;
pub const BLOCK_FRAMES: u32 = 256;

/// Audio-thread render callback. `out` is interleaved stereo L R L R…,
/// length = frames * 2. Called from the miniaudio thread.
pub const RenderFn = *const fn (ctx: *anyopaque, out: [*]f32, frames: u32) void;

/// Audio-thread capture callback. `in` is `frames` mono f32 input samples
/// (null when the device has no capture half). Called before render, so the
/// transport still reads the block-start position. Must not allocate.
pub const CaptureFn = *const fn (ctx: *anyopaque, in: ?[*]const f32, frames: u32) void;

/// One enumerated capture device — opaque id (passed back to select it) plus
/// a display name, copied out of context-owned memory immediately.
pub const MA_NAME_CAP = 255;
pub const MAX_INPUT_DEVICES = 32;
pub const InputDevice = struct {
    id: c.ma.ma_device_id,
    name: [MA_NAME_CAP:0]u8 = [_:0]u8{0} ** MA_NAME_CAP,
};

const AudioObjectPropertyAddress = extern struct { selector: u32, scope: u32, element: u32 };
extern "c" fn AudioObjectGetPropertyData(id: u32, addr: *const AudioObjectPropertyAddress, qual_size: u32, qual: ?*const anyopaque, size: *u32, data: *anyopaque) i32;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// The length of one callback block, for real-time scheduling.
pub fn blockPeriodNs() u64 {
    return @as(u64, requestedBlockFrames()) * std.time.ns_per_s / SAMPLE_RATE;
}

pub const Audio = struct {
    device: c.ma.ma_device,
    context: c.ma.ma_context = undefined,
    has_context: bool = false,
    initialized: bool = false,
    /// True when the device opened in duplex mode (capture is available).
    capture_available: bool = false,
    /// Whether the mic is wanted (a track is armed or a take is recording).
    /// The device is playback-only otherwise: opening the mic switches
    /// Bluetooth headsets (AirPods) into their call profile, whose narrow
    /// band and noise suppression wreck the output.
    want_capture: bool = false,
    /// Explicit capture device chosen by the user (else system default).
    capture_id: c.ma.ma_device_id = undefined,
    has_capture_id: bool = false,
    /// Bumped each time a device starts: its I/O workgroup is new.
    device_gen: u32 = 0,
    render_ctx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    render_fn: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    capture_ctx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    capture_fn: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    probe_counter: u32 = 0,
    probe_overruns: u32 = 0,
    /// DSP load: render time over the callback's budget, smoothed, in
    /// permille (the UI's CPU readout); `load_peak` holds the worst since
    /// the UI last took it.
    load: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    load_peak: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    load_avg: f32 = 0,

    fn noteLoad(self: *Audio, ticks: u64, frames: u32) void {
        noteLoadImpl(self, ticks, frames);
    }

    /// UI thread: the smoothed load and the peak since the last call, 0..1+.
    pub fn takeLoad(self: *Audio) struct { avg: f32, peak: f32 } {
        return .{
            .avg = @as(f32, @floatFromInt(self.load.load(.monotonic))) / 1000,
            .peak = @as(f32, @floatFromInt(self.load_peak.swap(0, .monotonic))) / 1000,
        };
    }

    pub fn init(self: *Audio) !void {
        self.render_ctx = std.atomic.Value(usize).init(0);
        self.render_fn = std.atomic.Value(usize).init(0);
        self.capture_ctx = std.atomic.Value(usize).init(0);
        self.capture_fn = std.atomic.Value(usize).init(0);
        self.probe_counter = 0;
        self.probe_overruns = 0;
        self.initialized = false;
        self.capture_available = false;
        self.want_capture = false;
        self.has_capture_id = false;
        self.device_gen = 0;

        // A persistent context backs both device init and enumeration.
        if (c.ma.ma_context_init(null, 0, null, &self.context) != c.ma.MA_SUCCESS)
            return error.AudioInitFailed;
        self.has_context = true;
        try self.openDevice();
    }

    /// Open (or re-open) the device: duplex (playback + mono capture from the
    /// `capture_id` selection) when capture is wanted, else playback-only.
    /// Assumes no device is initialized. A duplex device that won't open
    /// falls back to playback-only so the app runs.
    fn openDevice(self: *Audio) !void {
        self.capture_available = false;
        if (!self.want_capture) return self.openPlayback();

        var duplex = c.ma.ma_device_config_init(c.ma.ma_device_type_duplex);
        duplex.playback.format = c.ma.ma_format_f32;
        duplex.playback.channels = CHANNELS;
        duplex.capture.format = c.ma.ma_format_f32;
        duplex.capture.channels = 1;
        if (self.has_capture_id) duplex.capture.pDeviceID = &self.capture_id;
        duplex.sampleRate = SAMPLE_RATE;
        duplex.periodSizeInFrames = requestedBlockFrames();
        duplex.coreaudio.allowNominalSampleRateChange = c.ma.MA_TRUE;
        duplex.dataCallback = audioCallback;
        duplex.pUserData = self;

        if (c.ma.ma_device_init(&self.context, &duplex, &self.device) != c.ma.MA_SUCCESS) {
            // A chosen device that won't open shouldn't strand the app —
            // drop the selection and fall back to playback-only.
            self.has_capture_id = false;
            std.log.warn("audio: capture unavailable; recording disabled (playback-only device)", .{});
            return self.openPlayback();
        }
        self.capture_available = true;
        try self.startDevice();
        self.warnIfResampling();
    }

    /// The engine renders at 48 kHz in fixed 256-frame callbacks. A device
    /// left at another rate (MacBook speakers default to 44.1 kHz) makes
    /// miniaudio resample, and to keep the callbacks fixed-size it sometimes
    /// asks for two blocks inside one hardware period: a render past half the
    /// budget then misses the deadline, and since the transport only moves
    /// with rendered audio, playback drags. Devices are asked to switch to
    /// 48 kHz at open (allowNominalSampleRateChange); this says when one won't.
    fn warnIfResampling(self: *Audio) void {
        const rate = self.device.playback.internalSampleRate;
        if (rate != SAMPLE_RATE)
            std.log.warn("audio: output device runs at {} Hz, resampling from {} Hz; heavy projects may drag", .{ rate, SAMPLE_RATE });
    }

    fn openPlayback(self: *Audio) !void {
        var play = c.ma.ma_device_config_init(c.ma.ma_device_type_playback);
        play.playback.format = c.ma.ma_format_f32;
        play.playback.channels = CHANNELS;
        play.sampleRate = SAMPLE_RATE;
        play.periodSizeInFrames = requestedBlockFrames();
        play.coreaudio.allowNominalSampleRateChange = c.ma.MA_TRUE;
        play.dataCallback = audioCallback;
        play.pUserData = self;
        if (c.ma.ma_device_init(&self.context, &play, &self.device) != c.ma.MA_SUCCESS)
            return error.AudioInitFailed;
        try self.startDevice();
        self.warnIfResampling();
    }

    fn startDevice(self: *Audio) !void {
        if (c.ma.ma_device_start(&self.device) != c.ma.MA_SUCCESS) {
            c.ma.ma_device_uninit(&self.device);
            return error.AudioStartFailed;
        }
        self.initialized = true;
        self.device_gen +%= 1;
    }

    /// The running device's I/O workgroup (os_workgroup_t, retained: the
    /// caller releases it), for render workers to join (docs/07 §Parallel
    /// rendering); null if there is none.
    pub fn workgroup(self: *Audio) ?*anyopaque {
        if (!self.initialized) return null;
        const addr: AudioObjectPropertyAddress = .{
            .selector = fourcc("oswg"),
            .scope = fourcc("glob"),
            .element = 0,
        };
        var wg: ?*anyopaque = null;
        var size: u32 = @sizeOf(?*anyopaque);
        const id = self.device.unnamed_0.coreaudio.deviceObjectIDPlayback;
        if (AudioObjectGetPropertyData(id, &addr, 0, null, &size, @ptrCast(&wg)) != 0) return null;
        return wg;
    }

    fn reopen(self: *Audio) !void {
        if (self.initialized) {
            _ = c.ma.ma_device_stop(&self.device);
            c.ma.ma_device_uninit(&self.device);
            self.initialized = false;
        }
        try self.openDevice();
    }

    /// Open the mic (duplex) or release it (playback-only). Re-opens the
    /// device only on a change; the render/capture hooks persist.
    pub fn setWantCapture(self: *Audio, want: bool) !void {
        if (want == self.want_capture) return;
        self.want_capture = want;
        try self.reopen();
    }

    /// Enumerate capture (input) devices into `out`; returns the count
    /// written. Names/ids are copied so they outlive the context call.
    pub fn listInputDevices(self: *Audio, out: []InputDevice) usize {
        if (!self.has_context) return 0;
        var infos: [*c]c.ma.ma_device_info = undefined;
        var count: c.ma.ma_uint32 = 0;
        if (c.ma.ma_context_get_devices(&self.context, null, null, &infos, &count) != c.ma.MA_SUCCESS)
            return 0;
        const n = @min(out.len, @as(usize, count));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i].id = infos[i].id;
            const src = std.mem.sliceTo(&infos[i].name, 0);
            const m = @min(src.len, MA_NAME_CAP);
            @memcpy(out[i].name[0..m], src[0..m]);
            out[i].name[m] = 0;
        }
        return n;
    }

    /// Switch the capture device (null = system default). Stops, re-opens, and
    /// restarts; the render/capture hooks persist across the swap.
    pub fn useInputDevice(self: *Audio, id: ?*const c.ma.ma_device_id) !void {
        if (id) |p| {
            self.capture_id = p.*;
            self.has_capture_id = true;
        } else {
            self.has_capture_id = false;
        }
        // Takes effect now if the mic is open, else when it next opens.
        if (self.want_capture) try self.reopen();
    }

    /// Name of the active capture device (empty when capture is unavailable).
    pub fn currentInputName(self: *const Audio) []const u8 {
        if (!self.capture_available) return "";
        return std.mem.sliceTo(&self.device.capture.name, 0);
    }

    /// Best-effort round-trip latency (input + output) in frames, used to
    /// nudge a recorded clip back onto the grid. Valid after init.
    pub fn roundTripLatencyFrames(self: *const Audio) u32 {
        if (!self.initialized) return 0;
        const cap = self.device.capture.internalPeriodSizeInFrames;
        const play = self.device.playback.internalPeriodSizeInFrames;
        return cap + play;
    }

    /// Install the input-capture hook (audio thread reads it each block).
    pub fn setCapture(self: *Audio, ctx: ?*anyopaque, func: ?CaptureFn) void {
        const ctx_v: usize = if (ctx) |p| @intFromPtr(p) else 0;
        const fn_v: usize = if (func) |p| @intFromPtr(p) else 0;
        self.capture_ctx.store(ctx_v, .monotonic);
        self.capture_fn.store(fn_v, .release);
    }

    pub fn deinit(self: *Audio) void {
        if (self.initialized) {
            c.ma.ma_device_uninit(&self.device);
            self.initialized = false;
        }
        if (self.has_context) {
            _ = c.ma.ma_context_uninit(&self.context);
            self.has_context = false;
        }
    }

    pub fn stop(self: *Audio) void {
        if (!self.initialized) return;
        _ = c.ma.ma_device_stop(&self.device);
    }

    pub fn start(self: *Audio) !void {
        if (!self.initialized) return;
        if (c.ma.ma_device_start(&self.device) != c.ma.MA_SUCCESS)
            return error.AudioStartFailed;
    }

    pub fn setRender(self: *Audio, ctx: ?*anyopaque, func: ?RenderFn) void {
        const ctx_v: usize = if (ctx) |p| @intFromPtr(p) else 0;
        const fn_v: usize = if (func) |p| @intFromPtr(p) else 0;
        // ctx written first (monotonic), fn last (release) — audio thread's
        // acquire load on fn pairs with this to guarantee a consistent ctx.
        self.render_ctx.store(ctx_v, .monotonic);
        self.render_fn.store(fn_v, .release);
    }
};

fn audioCallback(
    dev: ?*c.ma.ma_device,
    out_raw: ?*anyopaque,
    in_raw: ?*const anyopaque,
    frames: c.ma.ma_uint32,
) callconv(.c) void {
    const self: *Audio = @ptrCast(@alignCast(dev.?.pUserData));
    const out_ptr = out_raw orelse return;
    const out_f32: [*]f32 = @ptrCast(@alignCast(out_ptr));

    // Capture runs first: the recorder stamps the block-start position from
    // the transport, which render() is about to advance.
    const cap_raw = self.capture_fn.load(.acquire);
    if (cap_raw != 0) {
        const cap_ctx: *anyopaque = @ptrFromInt(self.capture_ctx.load(.monotonic));
        const capture: CaptureFn = @ptrFromInt(cap_raw);
        const in_f32: ?[*]const f32 = if (in_raw) |p| @ptrCast(@alignCast(p)) else null;
        capture(cap_ctx, in_f32, @intCast(frames));
    }

    const fn_raw = self.render_fn.load(.acquire);
    if (fn_raw == 0) {
        @memset(out_f32[0 .. @as(usize, frames) * CHANNELS], 0);
        return;
    }
    const ctx: *anyopaque = @ptrFromInt(self.render_ctx.load(.monotonic));
    const render: RenderFn = @ptrFromInt(fn_raw);
    const probe = audioProbeEnabled();
    const t0 = if (probe) probeNowNs() else 0;
    const tick0 = std.c.mach_absolute_time();
    render(ctx, out_f32, @intCast(frames));
    self.noteLoad(std.c.mach_absolute_time() - tick0, frames);
    if (probe) {
        const elapsed_ns: i128 = probeNowNs() - t0;
        const budget_ns: i128 = @divTrunc(@as(i128, @intCast(frames)) * std.time.ns_per_s, SAMPLE_RATE);
        self.probe_counter +%= 1;
        const over = elapsed_ns > budget_ns;
        if (over) self.probe_overruns +%= 1;
        if ((over and self.probe_overruns <= 8) or self.probe_counter % 256 == 0 or audioProbeVerbose()) {
            std.debug.print(
                "audio-callback frames={} render_ms={d:.3} budget_ms={d:.3} over={} overruns={}\n",
                .{
                    frames,
                    @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
                    @as(f64, @floatFromInt(budget_ns)) / 1_000_000.0,
                    over,
                    self.probe_overruns,
                },
            );
        }
    }
}

fn audioProbeEnabled() bool {
    return std.c.getenv("SLAB_AUDIO_PROBE") != null;
}

fn audioProbeVerbose() bool {
    return std.c.getenv("SLAB_AUDIO_PROBE_VERBOSE") != null;
}

fn requestedBlockFrames() u32 {
    const raw = std.c.getenv("SLAB_AUDIO_BLOCK_FRAMES") orelse return BLOCK_FRAMES;
    const s = std.mem.span(raw);
    const parsed = std.fmt.parseInt(u32, s, 10) catch return BLOCK_FRAMES;
    return switch (parsed) {
        64, 128, 256, 512, 1024 => parsed,
        else => BLOCK_FRAMES,
    };
}

var timebase: std.c.mach_timebase_info_data = .{ .numer = 0, .denom = 0 };

fn noteLoadImpl(self: *Audio, ticks: u64, frames: u32) void {
    if (timebase.denom == 0) _ = std.c.mach_timebase_info(&timebase);
    const ns = @as(f64, @floatFromInt(ticks)) * @as(f64, @floatFromInt(timebase.numer)) / @as(f64, @floatFromInt(@max(timebase.denom, 1)));
    const budget_ns = @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(self.device.sampleRate));
    if (budget_ns <= 0) return;
    const x: f32 = @floatCast(ns / budget_ns);
    // A time constant of about half a second at 256-frame callbacks.
    self.load_avg += (x - self.load_avg) * 0.01;
    self.load.store(@intFromFloat(@min(self.load_avg, 4) * 1000), .monotonic);
    const p: u32 = @intFromFloat(@min(x, 4) * 1000);
    if (p > self.load_peak.load(.monotonic)) self.load_peak.store(p, .monotonic);
}

fn probeNowNs() i128 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @divTrunc(@as(i128, @intCast(std.c.mach_absolute_time())) * @as(i128, @intCast(info.numer)), @as(i128, @intCast(info.denom)));
}
