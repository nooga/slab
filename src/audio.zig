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

pub const Audio = struct {
    device: c.ma.ma_device,
    initialized: bool = false,
    render_ctx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    render_fn: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    probe_counter: u32 = 0,
    probe_overruns: u32 = 0,

    pub fn init(self: *Audio) !void {
        self.render_ctx = std.atomic.Value(usize).init(0);
        self.render_fn = std.atomic.Value(usize).init(0);
        self.probe_counter = 0;
        self.probe_overruns = 0;
        self.initialized = false;

        var cfg = c.ma.ma_device_config_init(c.ma.ma_device_type_playback);
        cfg.playback.format = c.ma.ma_format_f32;
        cfg.playback.channels = CHANNELS;
        cfg.sampleRate = SAMPLE_RATE;
        cfg.periodSizeInFrames = requestedBlockFrames();
        cfg.dataCallback = audioCallback;
        cfg.pUserData = self;

        if (c.ma.ma_device_init(null, &cfg, &self.device) != c.ma.MA_SUCCESS)
            return error.AudioInitFailed;
        if (c.ma.ma_device_start(&self.device) != c.ma.MA_SUCCESS) {
            c.ma.ma_device_uninit(&self.device);
            return error.AudioStartFailed;
        }
        self.initialized = true;
    }

    pub fn deinit(self: *Audio) void {
        if (self.initialized) {
            c.ma.ma_device_uninit(&self.device);
            self.initialized = false;
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
    _: ?*const anyopaque,
    frames: c.ma.ma_uint32,
) callconv(.c) void {
    const self: *Audio = @ptrCast(@alignCast(dev.?.pUserData));
    const out_ptr = out_raw orelse return;
    const out_f32: [*]f32 = @ptrCast(@alignCast(out_ptr));

    const fn_raw = self.render_fn.load(.acquire);
    if (fn_raw == 0) {
        @memset(out_f32[0 .. @as(usize, frames) * CHANNELS], 0);
        return;
    }
    const ctx: *anyopaque = @ptrFromInt(self.render_ctx.load(.monotonic));
    const render: RenderFn = @ptrFromInt(fn_raw);
    const probe = audioProbeEnabled();
    const t0 = if (probe) probeNowNs() else 0;
    render(ctx, out_f32, @intCast(frames));
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

fn probeNowNs() i128 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @divTrunc(@as(i128, @intCast(std.c.mach_absolute_time())) * @as(i128, @intCast(info.numer)), @as(i128, @intCast(info.denom)));
}
