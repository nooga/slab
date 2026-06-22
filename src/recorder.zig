//! Audio input recorder. The capture half of the duplex device hands the
//! audio thread a block of mono f32 input each callback; `captureFn` copies
//! it into a lock-free SPSC ring. A writer thread drains the ring and streams
//! it to a float32-mono WAV on disk. On stop the file is finalized and the UI
//! thread turns it into an AudioPool source + clip (via the existing loader).
//!
//! Audio-thread discipline: `captureFn` only pushes into a preallocated ring —
//! no allocation, no syscalls, no locks. Everything else runs on the UI thread
//! (start/finish) or the dedicated writer thread (disk IO).

const std = @import("std");
const Transport = @import("transport.zig").Transport;

pub const SAMPLE_RATE: u32 = 48_000;
pub const MAX_PATH = 512;

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
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

const timespec = extern struct { sec: i64, nsec: i64 };
extern fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

// macOS fcntl.h values.
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;
const SEEK_SET: c_int = 0;

const RECORDINGS_DIR = "recordings";

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
    /// Total mono frames captured.
    frames: u64,
    /// Transport sample position at the first captured block.
    start_sample: u64,
};

pub const Recorder = struct {
    alloc: std.mem.Allocator,
    transport: *const Transport,
    ring: Ring,

    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(State.idle)),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    writer: ?std.Thread = null,

    // Audio-thread → UI shared.
    start_sample: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    start_stamped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    frames_captured: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overruns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

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
    path_buf: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: usize = 0,

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
            self.stop_requested.store(true, .release);
            self.state.store(@intFromEnum(State.idle), .release);
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

    /// Audio-thread entry. `in` is `frames` mono f32 samples (the capture
    /// half of the duplex callback), or null if the device has no input.
    pub fn captureFn(ctx: *anyopaque, in: ?[*]const f32, frames: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.state.load(.acquire) != @intFromEnum(State.recording)) return;
        const ptr = in orelse return;
        if (!self.start_stamped.load(.acquire)) {
            self.start_sample.store(self.transport.samples(), .monotonic);
            self.start_stamped.store(true, .release);
        }
        const block = ptr[0..frames];
        const accepted = self.ring.push(block);
        if (accepted < frames) {
            _ = self.overruns.fetchAdd(@intCast(frames - accepted), .monotonic);
        }
        _ = self.frames_captured.fetchAdd(accepted, .monotonic);
    }

    /// UI thread. Opens a fresh take file, primes the ring, and spawns the
    /// writer thread. After this returns the audio thread may capture.
    pub fn start(self: *Recorder) !void {
        if (self.isRecording() or self.writer != null) return error.AlreadyRecording;

        _ = mkdir(RECORDINGS_DIR, 0o755); // ignore EEXIST / failures; open() reports

        self.buildTakePath();
        var zpath: [MAX_PATH:0]u8 = undefined;
        @memcpy(zpath[0..self.path_len], self.path_buf[0..self.path_len]);
        zpath[self.path_len] = 0;

        const fd = open(&zpath, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
        if (fd < 0) return error.OpenFailed;
        self.fd = fd;
        self.data_bytes = 0;
        if (!self.writeHeaderPlaceholder()) {
            _ = close(fd);
            self.fd = -1;
            return error.WriteFailed;
        }

        self.ring.reset();
        self.peak_count.store(0, .release);
        self.bucket_acc = 0;
        self.bucket_fill = 0;
        self.start_stamped.store(false, .release);
        self.frames_captured.store(0, .monotonic);
        self.overruns.store(0, .monotonic);
        self.done.store(false, .release);
        self.stop_requested.store(false, .release);

        self.state.store(@intFromEnum(State.recording), .release);
        self.writer = std.Thread.spawn(.{}, writerMain, .{self}) catch |err| {
            self.state.store(@intFromEnum(State.idle), .release);
            _ = close(self.fd);
            self.fd = -1;
            return err;
        };
    }

    /// UI thread. Signals the audio thread to stop capturing and the writer
    /// to drain and finalize. Non-blocking — poll `isFinished()`.
    pub fn requestStop(self: *Recorder) void {
        // Order matters: stop captures first so the writer's final drain sees
        // no concurrent producer, then ask it to finalize.
        self.state.store(@intFromEnum(State.idle), .release);
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
            if (self.stop_requested.load(.acquire)) {
                // One final drain in case the producer pushed during the gap.
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
            if (self.bucket_fill >= SAMPLES_PER_BUCKET) {
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

    /// 44-byte canonical WAV header, float32 mono, sizes left at zero (patched
    /// in finalizeFile). Returns false on a short write.
    fn writeHeaderPlaceholder(self: *Recorder) bool {
        var h: [44]u8 = undefined;
        const ch: u16 = 1;
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

    fn buildTakePath(self: *Recorder) void {
        self.take_counter += 1;
        const s = std.fmt.bufPrint(&self.path_buf, "{s}/take-{d:0>3}.wav", .{ RECORDINGS_DIR, self.take_counter }) catch {
            const fallback = RECORDINGS_DIR ++ "/take.wav";
            @memcpy(self.path_buf[0..fallback.len], fallback);
            self.path_len = fallback.len;
            return;
        };
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
    const big = [_]f32{0} ** 10;
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
