//! Audio input recorder. The capture half of the duplex device hands the
//! audio thread a block of the device's input channels each callback;
//! `captureFn` takes the take's channel (or pair) into a lock-free SPSC
//! ring. A writer thread drains the ring and streams it to a float32 WAV
//! on disk, mono or stereo. Frames the ring had no room for come back as
//! silence, so the rest of the take keeps its time. On stop the file is finalized and the UI
//! thread turns it into an AudioPool source + clip (via the existing loader).
//!
//! Audio-thread discipline: `captureFn` only pushes into a preallocated ring —
//! no allocation, no syscalls, no locks. Everything else runs on the UI thread
//! (start/finish) or the dedicated writer thread (disk IO).

const std = @import("std");
const storage = @import("storage.zig");
const Transport = @import("transport.zig").Transport;

pub const SAMPLE_RATE: u32 = 48_000;
pub const MAX_PATH = 1024;

/// Live-waveform summary granularity. One peak per bucket; the writer thread
/// fills these as it drains the ring so the UI can draw the take growing in
/// real time. 1024 samples ≈ 21 ms/bucket; 16384 buckets ≈ 5.8 min.
pub const SAMPLES_PER_BUCKET: u32 = 1024;
const LIVE_BUCKETS: usize = 1 << 14;

// libc IO — same direct-extern convention as wav.zig / presets.zig (the
// std.fs surface moved in zig 0.16 and the codebase avoids it for files).
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern fn access(path: [*:0]const u8, mode: c_int) c_int;

const timespec = extern struct { sec: i64, nsec: i64 };
extern fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

// macOS fcntl.h values.
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;
const SEEK_SET: c_int = 0;

/// Single-producer / single-consumer lock-free ring of f32. The audio thread
/// is the sole producer; the writer thread the sole consumer. Capacity is a
/// power of two; indices are free-running `usize` masked into the buffer.
pub const Ring = struct {
    buf: []f32,
    mask: usize,
    write: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    read: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(alloc: std.mem.Allocator, capacity_pow2: usize) !Ring {
        std.debug.assert(std.math.isPowerOfTwo(capacity_pow2));
        const buf = try alloc.alloc(f32, capacity_pow2);
        @memset(buf, 0); // touch ring pages before the first capture callback
        return .{ .buf = buf, .mask = capacity_pow2 - 1 };
    }

    pub fn deinit(self: *Ring, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    pub fn reset(self: *Ring) void {
        self.write.store(0, .monotonic);
        self.read.store(0, .monotonic);
    }

    /// Producer (audio thread). Returns the number of frames accepted; a
    /// short return means the consumer fell behind (an overrun).
    pub fn push(self: *Ring, src: []const f32) usize {
        const w = self.write.load(.monotonic);
        const r = self.read.load(.acquire);
        const free = self.buf.len - (w -% r);
        const n = @min(src.len, free);
        var i: usize = 0;
        while (i < n) : (i += 1) self.buf[(w +% i) & self.mask] = src[i];
        self.write.store(w +% n, .release);
        return n;
    }

    /// Producer: like push, but only whole frames of `ch` samples.
    pub fn pushFrames(self: *Ring, src: []const f32, ch: usize) usize {
        const w = self.write.load(.monotonic);
        const r = self.read.load(.acquire);
        const free = self.buf.len - (w -% r);
        const n = @min(src.len, free - free % ch);
        var i: usize = 0;
        while (i < n) : (i += 1) self.buf[(w +% i) & self.mask] = src[i];
        self.write.store(w +% n, .release);
        return n;
    }

    /// Consumer (writer thread). Returns the number of frames copied out.
    pub fn pop(self: *Ring, dst: []f32) usize {
        const r = self.read.load(.monotonic);
        const w = self.write.load(.acquire);
        const avail = w -% r;
        const n = @min(dst.len, avail);
        var i: usize = 0;
        while (i < n) : (i += 1) dst[i] = self.buf[(r +% i) & self.mask];
        self.read.store(r +% n, .release);
        return n;
    }
};

const State = enum(u32) { idle = 0, recording = 1 };

pub const Result = struct {
    /// Repo-relative path of the finished WAV (valid until the next start()).
    path: []const u8,
    /// Total frames in the take, dropped ones (written as silence) included.
    frames: u64,
    /// Transport sample position at the first captured block.
    start_sample: u64,
    /// Frames the first block had waited in the device's duplex ring: it
    /// is late by this on top of the hardware's round trip.
    backlog: u32,
};

/// Which input a take records: one channel, or a pair from `first`.
pub const Input = struct {
    first: u8 = 0, // 0-based
    stereo: bool = false,

    pub fn channels(self: Input) u32 {
        return if (self.stereo) 2 else 1;
    }

    /// "1", "1-2": 1-based, as the UI and the project file show it.
    pub fn label(self: Input, buf: []u8) []const u8 {
        return if (self.stereo)
            std.fmt.bufPrint(buf, "{d}-{d}", .{ self.first + 1, self.first + 2 }) catch "?"
        else
            std.fmt.bufPrint(buf, "{d}", .{self.first + 1}) catch "?";
    }

    pub fn parse(text: []const u8) ?Input {
        if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
            const a = std.fmt.parseInt(u8, text[0..dash], 10) catch return null;
            const b = std.fmt.parseInt(u8, text[dash + 1 ..], 10) catch return null;
            if (a < 1 or b != a + 1) return null;
            return .{ .first = a - 1, .stereo = true };
        }
        const a = std.fmt.parseInt(u8, text, 10) catch return null;
        if (a < 1) return null;
        return .{ .first = a - 1 };
    }
};

/// Where a take belongs on the timeline: its first block was stamped at
/// `start_sample`, but the sound in it reached the mic a round trip
/// earlier than the output it was played against (hardware both ways,
/// plus `backlog` frames waiting between the callbacks, plus the
/// project's own `pdc` latency on the output).
pub fn takeStart(start_sample: u64, round_trip: u32, backlog: u32, pdc: u32) u64 {
    const late = @as(u64, round_trip) + backlog + pdc;
    return start_sample -| late;
}

const ZEROS: [512]f32 = @splat(0);
const CHUNK = 256;

pub const Recorder = struct {
    alloc: std.mem.Allocator,
    transport: *const Transport,
    ring: Ring,

    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(State.idle)),
    // Entry/exit handshake: setting idle does not cancel an in-flight push.
    // The writer waits for quiescence before its final drain; audio never waits.
    capture_inflight: std.atomic.Value(bool) = .init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    writer: ?std.Thread = null,

    // Audio-thread → UI shared.
    start_sample: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    start_stamped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    frames_captured: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overruns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    start_backlog: std.atomic.Value(u32) = .init(0),
    /// The transport moved other than forward by the frames captured (a
    /// seek or a loop wrap): the take no longer matches its timeline.
    jumped: std.atomic.Value(bool) = .init(false),
    /// Dropped frames not yet made up with silence; the writer pads what's
    /// left at the end. Audio thread writes, writer reads after quiescence.
    gap: std.atomic.Value(u64) = .init(0),

    // Set on the UI thread before start() publishes the take.
    input: Input = .{},
    // Audio-thread-owned.
    next_pos: u64 = 0,

    // Live waveform — written by the writer thread, read by the UI. Each
    // slot is the peak |sample| of one bucket; `peak_count` publishes how
    // many are valid.
    live_peaks: []f32,
    peak_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bucket_acc: f32 = 0, // writer-owned bucket accumulation
    bucket_fill: u32 = 0,

    // Writer-thread-owned.
    fd: c_int = -1,
    data_bytes: u64 = 0,

    take_counter: u32 = 0,
    path_buf: [MAX_PATH]u8 = @splat(0),
    path_len: usize = 0,
    // A folder set with setDir; empty: storage.recordingsDir at each take.
    dir_buf: [MAX_PATH]u8 = undefined,
    dir_len: usize = 0,
    take_dir_buf: [MAX_PATH]u8 = undefined,
    take_dir_len: usize = 0,

    pub fn init(alloc: std.mem.Allocator, transport: *const Transport) !Recorder {
        // 2^18 mono frames ≈ 5.4 s of slack at 48 kHz — far more than the
        // writer thread should ever need against local disk.
        var ring = try Ring.init(alloc, 1 << 18);
        errdefer ring.deinit(alloc);
        const peaks = try alloc.alloc(f32, LIVE_BUCKETS);
        return .{ .alloc = alloc, .transport = transport, .ring = ring, .live_peaks = peaks };
    }

    pub fn deinit(self: *Recorder) void {
        if (self.writer) |t| {
            self.requestStop();
            t.join();
            self.writer = null;
        }
        self.ring.deinit(self.alloc);
        self.alloc.free(self.live_peaks);
    }

    /// UI thread: the published live-waveform peaks (one per bucket of
    /// SAMPLES_PER_BUCKET captured frames). Grows while recording.
    pub fn livePeaks(self: *const Recorder) []const f32 {
        const n = self.peak_count.load(.acquire);
        return self.live_peaks[0..@min(n, self.live_peaks.len)];
    }

    /// UI thread: transport sample position where the current take began.
    pub fn startSampleValue(self: *const Recorder) u64 {
        return self.start_sample.load(.monotonic);
    }

    pub fn isRecording(self: *const Recorder) bool {
        return self.state.load(.acquire) == @intFromEnum(State.recording);
    }

    pub fn capturedFrames(self: *const Recorder) u64 {
        return self.frames_captured.load(.monotonic);
    }

    /// Audio-thread entry. `in` is `frames` frames of `channels`
    /// interleaved input (the capture half of the duplex callback), or null
    /// if the device has no input; `backlog` is how long they waited.
    pub fn captureFn(ctx: *anyopaque, in: ?[*]const f32, frames: u32, channels: u32, backlog: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (!self.beginCapture()) return;
        defer self.endCapture();
        const ptr = in orelse return;
        const pos = self.transport.samples();
        if (!self.start_stamped.load(.acquire)) {
            self.start_sample.store(pos, .monotonic);
            self.start_backlog.store(backlog, .monotonic);
            self.start_stamped.store(true, .release);
        } else if (pos != self.next_pos) self.jumped.store(true, .release);
        self.next_pos = pos + frames;
        self.take(ptr, frames, @max(channels, 1));
    }

    /// The take's channel(s) out of `frames` interleaved frames of `ch`,
    /// into the ring. Audio thread.
    fn take(self: *Recorder, in: [*]const f32, frames: u32, ch: u32) void {
        const oc = self.input.channels();
        const a = @min(self.input.first, ch - 1);
        const b = @min(a + 1, ch - 1);
        var buf: [CHUNK * 2]f32 = undefined;
        var done: u32 = 0;
        while (done < frames) {
            const n = @min(frames - done, CHUNK);
            for (0..n) |i| {
                const f = in + (done + i) * ch;
                if (oc == 2) {
                    buf[2 * i] = f[a];
                    buf[2 * i + 1] = f[b];
                } else buf[i] = f[a];
            }
            self.pushPadded(buf[0 .. n * oc], oc);
            done += n;
        }
        _ = self.frames_captured.fetchAdd(frames, .monotonic);
    }

    /// Frames dropped earlier go in first, as silence; whatever doesn't
    /// fit now is owed. Audio thread.
    fn pushPadded(self: *Recorder, samples: []const f32, oc: u32) void {
        var gap = self.gap.load(.monotonic);
        while (gap > 0) {
            const z = @min(gap * oc, ZEROS.len - ZEROS.len % oc);
            const got = self.ring.pushFrames(ZEROS[0..z], oc);
            gap -= got / oc;
            if (got < z) break;
        }
        const n = samples.len / oc;
        if (gap > 0) {
            gap += n;
            _ = self.overruns.fetchAdd(@intCast(n), .monotonic);
        } else {
            const got = self.ring.pushFrames(samples, oc);
            if (got < samples.len) {
                const lost = (samples.len - got) / oc;
                gap += lost;
                _ = self.overruns.fetchAdd(@intCast(lost), .monotonic);
            }
        }
        self.gap.store(gap, .monotonic);
    }

    fn beginCapture(self: *Recorder) bool {
        self.capture_inflight.store(true, .seq_cst);
        if (self.state.load(.seq_cst) == @intFromEnum(State.recording)) return true;
        self.endCapture();
        return false;
    }

    fn endCapture(self: *Recorder) void {
        self.capture_inflight.store(false, .seq_cst);
    }

    /// UI thread. Opens a fresh take file, primes the ring, and spawns the
    /// writer thread. After this returns the audio thread may capture.
    pub fn start(self: *Recorder) !void {
        if (self.isRecording() or self.writer != null) return error.AlreadyRecording;

        // Takes go to the open package's audio/ folder, or the home
        // folder's Cache for an unsaved project (docs/25).
        const d = if (self.dir_len > 0) self.dir_buf[0..self.dir_len] else storage.recordingsDir(&self.take_dir_buf);
        if (d.ptr != &self.take_dir_buf) @memcpy(self.take_dir_buf[0..d.len], d);
        self.take_dir_len = d.len;
        storage.makeParents(self.dir()); // failures: open() reports

        self.buildTakePath();
        var zpath: [MAX_PATH:0]u8 = undefined;
        @memcpy(zpath[0..self.path_len], self.path_buf[0..self.path_len]);
        zpath[self.path_len] = 0;

        const fd = open(&zpath, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
        if (fd < 0) return error.OpenFailed;
        self.fd = fd;
        self.data_bytes = 0;
        if (!self.writeHeaderPlaceholder(@intCast(self.input.channels()))) {
            _ = close(fd);
            self.fd = -1;
            return error.WriteFailed;
        }

        self.ring.reset();
        self.gap.store(0, .monotonic);
        self.jumped.store(false, .monotonic);
        self.start_backlog.store(0, .monotonic);
        self.peak_count.store(0, .release);
        self.bucket_acc = 0;
        self.bucket_fill = 0;
        self.start_stamped.store(false, .release);
        self.frames_captured.store(0, .monotonic);
        self.overruns.store(0, .monotonic);
        self.done.store(false, .release);
        self.stop_requested.store(false, .release);

        self.writer = std.Thread.spawn(.{}, writerMain, .{self}) catch |err| {
            self.state.store(@intFromEnum(State.idle), .release);
            _ = close(self.fd);
            self.fd = -1;
            return err;
        };
        // Publish recording only once the writer exists. Spawn failure must
        // not admit a callback that could overlap the next ring reset.
        self.state.store(@intFromEnum(State.recording), .seq_cst);
    }

    /// UI thread. Signals the audio thread to stop capturing and the writer
    /// to drain and finalize. Non-blocking — poll `isFinished()`.
    pub fn requestStop(self: *Recorder) void {
        // Close entry first. A callback already inside can still push; the
        // writer must observe its exit before finalizing or allowing restart.
        self.state.store(@intFromEnum(State.idle), .seq_cst);
        self.stop_requested.store(true, .release);
    }

    pub fn isFinishing(self: *const Recorder) bool {
        return self.writer != null;
    }

    pub fn isFinished(self: *const Recorder) bool {
        return self.writer != null and self.done.load(.acquire);
    }

    /// UI thread. Joins the writer (must be called once `isFinished()`), and
    /// returns the finished take. The path stays valid until the next start().
    pub fn finish(self: *Recorder) Result {
        if (self.writer) |t| {
            t.join();
            self.writer = null;
        }
        return .{
            .path = self.path_buf[0..self.path_len],
            .frames = self.frames_captured.load(.monotonic),
            .start_sample = self.start_sample.load(.monotonic),
            .backlog = self.start_backlog.load(.monotonic),
        };
    }

    // ── writer thread ────────────────────────────────────────────────

    fn writerMain(self: *Recorder) void {
        var scratch: [4096]f32 = undefined;
        while (true) {
            const n = self.ring.pop(&scratch);
            if (n > 0) {
                self.writeSamples(scratch[0..n]);
                continue;
            }
            if (self.stop_requested.load(.acquire) and !self.capture_inflight.load(.seq_cst)) {
                // Entry is closed and any producer that saw recording has
                // exited. Its final block is now visible to this drain.
                const m = self.ring.pop(&scratch);
                if (m > 0) {
                    self.writeSamples(scratch[0..m]);
                    continue;
                }
                break;
            }
            const ts = timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = nanosleep(&ts, null);
        }
        // Frames still owed when the take stopped: silence, to the end.
        var owed = self.gap.load(.acquire) * self.input.channels();
        while (owed > 0) {
            const z = @min(owed, ZEROS.len);
            self.writeSamples(ZEROS[0..z]);
            owed -= z;
        }
        self.finalizeFile();
        self.done.store(true, .release);
    }

    fn writeSamples(self: *Recorder, samples: []const f32) void {
        self.accumulatePeaks(samples);
        if (self.fd < 0) return;
        const bytes = std.mem.sliceAsBytes(samples);
        var off: usize = 0;
        while (off < bytes.len) {
            const w = write(self.fd, bytes.ptr + off, bytes.len - off);
            if (w <= 0) return; // disk error — stop appending, header stays sane
            off += @intCast(w);
            self.data_bytes += @intCast(w);
        }
    }

    /// Fold drained samples into the live peak buckets (writer thread).
    fn accumulatePeaks(self: *Recorder, samples: []const f32) void {
        for (samples) |s| {
            const a = @abs(s);
            if (a > self.bucket_acc) self.bucket_acc = a;
            self.bucket_fill += 1;
            if (self.bucket_fill >= SAMPLES_PER_BUCKET * self.input.channels()) {
                const idx = self.peak_count.load(.monotonic);
                if (idx < self.live_peaks.len) {
                    self.live_peaks[idx] = self.bucket_acc;
                    self.peak_count.store(idx + 1, .release);
                }
                self.bucket_acc = 0;
                self.bucket_fill = 0;
            }
        }
    }

    fn finalizeFile(self: *Recorder) void {
        if (self.fd < 0) return;
        // Patch the two size fields now that the data length is known.
        const data_len: u32 = @intCast(@min(self.data_bytes, std.math.maxInt(u32)));
        const riff_len: u32 = 36 + data_len;
        var b4: [4]u8 = undefined;
        if (lseek(self.fd, 4, SEEK_SET) >= 0) {
            std.mem.writeInt(u32, &b4, riff_len, .little);
            _ = write(self.fd, &b4, 4);
        }
        if (lseek(self.fd, 40, SEEK_SET) >= 0) {
            std.mem.writeInt(u32, &b4, data_len, .little);
            _ = write(self.fd, &b4, 4);
        }
        _ = close(self.fd);
        self.fd = -1;
    }

    /// 44-byte canonical WAV header, float32, sizes left at zero (patched
    /// in finalizeFile). Returns false on a short write.
    fn writeHeaderPlaceholder(self: *Recorder, ch: u16) bool {
        var h: [44]u8 = undefined;
        const bits: u16 = 32;
        const byte_rate: u32 = SAMPLE_RATE * ch * (bits / 8);
        const block_align: u16 = ch * (bits / 8);
        @memcpy(h[0..4], "RIFF");
        std.mem.writeInt(u32, h[4..8], 0, .little); // chunk size (patched)
        @memcpy(h[8..12], "WAVE");
        @memcpy(h[12..16], "fmt ");
        std.mem.writeInt(u32, h[16..20], 16, .little); // fmt chunk size
        std.mem.writeInt(u16, h[20..22], 3, .little); // IEEE float
        std.mem.writeInt(u16, h[22..24], ch, .little);
        std.mem.writeInt(u32, h[24..28], SAMPLE_RATE, .little);
        std.mem.writeInt(u32, h[28..32], byte_rate, .little);
        std.mem.writeInt(u16, h[32..34], block_align, .little);
        std.mem.writeInt(u16, h[34..36], bits, .little);
        @memcpy(h[36..40], "data");
        std.mem.writeInt(u32, h[40..44], 0, .little); // data size (patched)
        return write(self.fd, &h, h.len) == @as(isize, h.len);
    }

    /// Send takes to `path` instead (tests). UI thread, between takes.
    pub fn setDir(self: *Recorder, path: []const u8) void {
        const n = @min(path.len, self.dir_buf.len);
        @memcpy(self.dir_buf[0..n], path[0..n]);
        self.dir_len = n;
    }

    fn dir(self: *const Recorder) []const u8 {
        return self.take_dir_buf[0..self.take_dir_len];
    }

    /// The next take-NNN.wav not already there: the counter starts over
    /// each session, the folder doesn't.
    fn buildTakePath(self: *Recorder) void {
        while (self.take_counter < 9999) {
            self.take_counter += 1;
            const s = std.mem.printSentinel(&self.path_buf, "{s}/take-{d:0>3}.wav", .{ self.dir(), self.take_counter }, 0) catch break;
            self.path_len = s.len;
            if (access(s.ptr, 0) != 0) return;
        }
        const s = std.fmt.bufPrint(&self.path_buf, "{s}/take.wav", .{self.dir()}) catch "recordings/take.wav";
        if (s.ptr != &self.path_buf) @memcpy(self.path_buf[0..s.len], s);
        self.path_len = s.len;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "ring push/pop round-trips and reports overrun on overflow" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    const a = [_]f32{ 1, 2, 3, 4, 5 };
    try testing.expectEqual(@as(usize, 5), ring.push(&a));

    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 5), ring.pop(out[0..8]));
    try testing.expectEqualSlices(f32, &a, out[0..5]);

    // Capacity 8 → at most 8 frames live at once; a 10-frame push truncates.
    const big: [10]f32 = @splat(0);
    try testing.expectEqual(@as(usize, 8), ring.push(&big));
}

test "ring wraps around the buffer boundary" {
    var ring = try Ring.init(testing.allocator, 4);
    defer ring.deinit(testing.allocator);

    var scratch: [4]f32 = undefined;
    // Drive write/read indices past the capacity so the masked slot wraps.
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        const in = [_]f32{ @floatFromInt(round * 3), @floatFromInt(round * 3 + 1), @floatFromInt(round * 3 + 2) };
        try testing.expectEqual(@as(usize, 3), ring.push(&in));
        try testing.expectEqual(@as(usize, 3), ring.pop(scratch[0..3]));
        try testing.expectEqualSlices(f32, &in, scratch[0..3]);
    }
}

test "realtime: recording stop drains a callback already inside capture" {
    const a = testing.allocator;
    var transport = Transport{};
    var rec = try Recorder.init(a, &transport);
    defer rec.deinit();
    rec.setDir("/tmp/slab-recording-audit");
    try rec.start();
    const path = try a.dupeSentinel(u8, rec.path_buf[0..rec.path_len], 0);
    defer a.free(path);
    defer _ = struct {
        extern "c" fn unlink(p: [*:0]const u8) c_int;
    }.unlink(path);
    // Hold the actual capture-entry gate open across the UI stop, then
    // deliver the final producer block. An idle flag alone loses this block.
    try testing.expect(rec.beginCapture());
    errdefer rec.endCapture();
    rec.requestStop();
    const pause = timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    _ = nanosleep(&pause, null);
    try testing.expect(!rec.isFinished());
    const samples: [64]f32 = @splat(0.25);
    try testing.expectEqual(samples.len, rec.ring.push(&samples));
    _ = rec.frames_captured.fetchAdd(samples.len, .monotonic);
    rec.endCapture();
    var tries: usize = 0;
    while (!rec.isFinished() and tries < 100) : (tries += 1) _ = nanosleep(&pause, null);
    try testing.expect(rec.isFinished());
    const result = rec.finish();
    try testing.expectEqual(@as(u64, 64), result.frames);
    var loaded = try @import("wav.zig").load(a, result.path);
    defer loaded.deinit(a);
    try testing.expectEqual(@as(usize, 64), loaded.data.len);
    for (loaded.data) |v| try testing.expectEqual(@as(f64, 0.25), v);
    try testing.expect(!rec.beginCapture());
}

test "take placement: hardware round trip, ring backlog and PDC all come off" {
    try testing.expectEqual(@as(u64, 48_000 - 700 - 512 - 97), takeStart(48_000, 700, 512, 97));
    try testing.expectEqual(@as(u64, 0), takeStart(100, 700, 512, 0));
}

test "input labels round-trip; a pair must be adjacent" {
    var b: [8]u8 = undefined;
    try testing.expectEqualStrings("1", (Input{}).label(&b));
    try testing.expectEqualStrings("3-4", (Input{ .first = 2, .stereo = true }).label(&b));
    try testing.expectEqual(Input{ .first = 2, .stereo = true }, Input.parse("3-4").?);
    try testing.expectEqual(Input{ .first = 4 }, Input.parse("5").?);
    try testing.expect(Input.parse("3-5") == null);
    try testing.expect(Input.parse("0") == null);
    try testing.expect(Input.parse("x") == null);
}

fn testRecorder(transport: *const Transport, ring_frames: usize) !Recorder {
    var rec = try Recorder.init(testing.allocator, transport);
    rec.ring.deinit(testing.allocator);
    rec.ring = try Ring.init(testing.allocator, ring_frames);
    rec.state.store(@intFromEnum(State.recording), .seq_cst);
    return rec;
}

test "capture takes the track's channel or pair out of the device's channels" {
    var transport = Transport{};
    var rec = try testRecorder(&transport, 64);
    defer rec.deinit();
    defer rec.state.store(@intFromEnum(State.idle), .seq_cst);
    // 4 channels, frame i: 10i + channel
    var in: [8 * 4]f32 = undefined;
    for (0..8) |i| for (0..4) |ch| {
        in[i * 4 + ch] = @floatFromInt(10 * i + ch);
    };
    rec.input = .{ .first = 2, .stereo = true };
    Recorder.captureFn(&rec, &in, 8, 4, 0);
    var out: [16]f32 = undefined;
    try testing.expectEqual(@as(usize, 16), rec.ring.pop(&out));
    for (0..8) |i| {
        try testing.expectEqual(@as(f32, @floatFromInt(10 * i + 2)), out[2 * i]);
        try testing.expectEqual(@as(f32, @floatFromInt(10 * i + 3)), out[2 * i + 1]);
    }
    // a channel past the device's: its last one, not a neighbour's memory
    rec.input = .{ .first = 7 };
    Recorder.captureFn(&rec, &in, 8, 4, 0);
    try testing.expectEqual(@as(usize, 8), rec.ring.pop(&out));
    for (0..8) |i| try testing.expectEqual(@as(f32, @floatFromInt(10 * i + 3)), out[i]);
}

test "an overrun comes back as silence, so the rest of the take keeps its time" {
    var transport = Transport{};
    var rec = try testRecorder(&transport, 16);
    defer rec.deinit();
    defer rec.state.store(@intFromEnum(State.idle), .seq_cst);
    var a: [12]f32 = undefined;
    for (&a, 0..) |*v, i| v.* = @floatFromInt(i + 1);
    // 24 frames into 16: 8 dropped
    Recorder.captureFn(&rec, &a, 12, 1, 0);
    transport.sample_pos.store(12, .monotonic);
    Recorder.captureFn(&rec, &a, 12, 1, 0);
    try testing.expectEqual(@as(u32, 8), rec.overruns.load(.monotonic));
    var out: [32]f32 = undefined;
    try testing.expectEqual(@as(usize, 16), rec.ring.pop(&out));
    // drained: the 8 owed frames go in as zeros before the next block
    transport.sample_pos.store(24, .monotonic);
    var b: [4]f32 = @splat(0.5);
    Recorder.captureFn(&rec, &b, 4, 1, 0);
    const n = rec.ring.pop(&out);
    try testing.expectEqual(@as(usize, 12), n);
    for (out[0..8]) |v| try testing.expectEqual(@as(f32, 0), v);
    for (out[8..12]) |v| try testing.expectEqual(@as(f32, 0.5), v);
    try testing.expectEqual(@as(u64, 28), rec.frames_captured.load(.monotonic));
    try testing.expect(!rec.jumped.load(.monotonic));
}

test "a take notices the transport jumping, and stamps its first block's backlog" {
    var transport = Transport{};
    var rec = try testRecorder(&transport, 1024);
    defer rec.deinit();
    defer rec.state.store(@intFromEnum(State.idle), .seq_cst);
    var a: [64]f32 = @splat(0);
    transport.sample_pos.store(1000, .monotonic);
    Recorder.captureFn(&rec, &a, 64, 1, 512);
    transport.sample_pos.store(1064, .monotonic);
    Recorder.captureFn(&rec, &a, 64, 1, 300);
    try testing.expect(!rec.jumped.load(.monotonic));
    try testing.expectEqual(@as(u64, 1000), rec.start_sample.load(.monotonic));
    try testing.expectEqual(@as(u32, 512), rec.start_backlog.load(.monotonic));
    transport.sample_pos.store(0, .monotonic); // a loop wrap
    Recorder.captureFn(&rec, &a, 64, 1, 300);
    try testing.expect(rec.jumped.load(.monotonic));
}
