//! Host-owned pool of loaded audio sources — the backing store for audio
//! clips in the arrangement (and, later, for the sampler's runtime assets).
//!
//! A `Source` owns the decoded f64 audio (via wav.Sample) plus a min/max
//! peak pyramid (waveform.PeakCache) for zoomable waveform drawing. Clips
//! reference sources by index; indices are stable for the document's
//! lifetime because the pool only ever appends (never removes/compacts).
//!
//! Ownership lives above the document: the pool survives undo/redo, so a
//! reloaded project resolves each clip's file path back to the already-
//! loaded source (dedup by path) without re-reading the file.
//!
//! UI-thread-owned. The audio thread never touches the pool — it reads the
//! raw `data` pointer captured into a TrackSnapshot, which stays valid
//! because sources are never freed mid-session.

const std = @import("std");
const storage = @import("storage.zig");
const wav = @import("wav.zig");
const waveform = @import("waveform.zig");
const transients = @import("transients.zig");

/// A source's transients (docs/29 §Transients), found on a worker thread.
/// `onsets` is written once, before `ready` is set, and never again, so
/// any thread that sees `ready` may read it.
pub const Analysis = struct {
    ready: std.atomic.Value(bool) = .init(false),
    onsets: transients.Onsets = .{},
    thread: ?std.Thread = null,

    fn run(self: *Analysis, alloc: std.mem.Allocator, l: []const f64, r: ?[]const f64, rate: f64) void {
        self.onsets = transients.detect(alloc, l, r, rate) catch .{};
        self.ready.store(true, .release);
    }
};

pub const MAX_PATH = storage.MAX_PATH;

pub const Source = struct {
    sample: wav.Sample,
    /// The mid (mono: the signal), and for a stereo source each side.
    cache: waveform.PeakCache = .{},
    cache_l: waveform.PeakCache = .{},
    cache_r: waveform.PeakCache = .{},
    path_buf: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: u16 = 0,
    name_off: u16 = 0, // basename start within path_buf
    /// Heap-owned so it stays put when the pool's list grows.
    analysis: ?*Analysis = null,

    /// The transients, once found (null while the worker runs).
    pub fn onsets(self: *const Source) ?[]const f64 {
        const a = self.analysis orelse return null;
        if (!a.ready.load(.acquire)) return null;
        return a.onsets.sec;
    }

    /// What a waveform draws: the side caches when stereo.
    pub fn waves(self: *const Source) waveform.Waves {
        if (self.cache_r.sample_count > 0) return .{ .mid = &self.cache, .l = &self.cache_l, .r = &self.cache_r };
        return .{ .mid = &self.cache };
    }

    pub fn path(self: *const Source) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn name(self: *const Source) []const u8 {
        return self.path_buf[self.name_off..self.path_len];
    }

    /// Length of the source in seconds at its native rate.
    pub fn seconds(self: *const Source) f64 {
        if (self.sample.sample_rate <= 0) return 0;
        return @as(f64, @floatFromInt(self.sample.data.len)) / self.sample.sample_rate;
    }
};

pub const AudioPool = struct {
    sources: std.ArrayList(Source) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) AudioPool {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *AudioPool) void {
        self.waitAnalyses();
        for (self.sources.items) |*s| {
            if (s.analysis) |a| {
                a.onsets.deinit(self.alloc);
                self.alloc.destroy(a);
            }
            s.sample.deinit(self.alloc);
            s.cache.deinit(self.alloc);
            s.cache_l.deinit(self.alloc);
            s.cache_r.deinit(self.alloc);
        }
        self.sources.deinit(self.alloc);
    }

    /// Wait for every source's transients: before a render that must not
    /// depend on how fast they were found (docs/29 §On the audio thread).
    pub fn waitAnalyses(self: *AudioPool) void {
        for (self.sources.items) |*s| if (s.analysis) |a| if (a.thread) |t| {
            t.join();
            a.thread = null;
        };
    }

    pub fn count(self: *const AudioPool) usize {
        return self.sources.items.len;
    }

    pub fn get(self: *const AudioPool, idx: u32) ?*const Source {
        if (idx >= self.sources.items.len) return null;
        return &self.sources.items[idx];
    }

    fn indexOfPath(self: *const AudioPool, p: []const u8) ?u32 {
        for (self.sources.items, 0..) |*s, i| {
            if (std.mem.eql(u8, s.path(), p)) return @intCast(i);
        }
        return null;
    }

    /// Load `path` into the pool (or return the existing index if it is
    /// already loaded). Decodes the file and builds the peak pyramid.
    pub fn loadFile(self: *AudioPool, given: []const u8) !u32 {
        // One file, one source, however it was named.
        var ab: [storage.MAX_PATH]u8 = undefined;
        const path = storage.absolute(&ab, given);
        if (path.len == 0 or path.len > MAX_PATH) return error.PathTooLong;
        if (self.indexOfPath(path)) |existing| return existing;

        var sample = try wav.loadStereo(self.alloc, path);
        errdefer sample.deinit(self.alloc);

        var src = Source{ .sample = sample };
        if (sample.isStereo()) {
            // The waveform draws the mid.
            const mid = try self.alloc.alloc(f64, sample.data.len);
            defer self.alloc.free(mid);
            for (mid, sample.data, sample.right) |*m, l, r| m.* = (l + r) * 0.5;
            try src.cache.build(self.alloc, mid);
            errdefer src.cache.deinit(self.alloc);
            try src.cache_l.build(self.alloc, sample.data);
            errdefer src.cache_l.deinit(self.alloc);
            try src.cache_r.build(self.alloc, sample.right);
        } else try src.cache.build(self.alloc, sample.data);
        errdefer {
            src.cache.deinit(self.alloc);
            src.cache_l.deinit(self.alloc);
            src.cache_r.deinit(self.alloc);
        }

        @memcpy(src.path_buf[0..path.len], path);
        src.path_len = @intCast(path.len);
        src.name_off = @intCast(basenameStart(path));

        try self.sources.append(self.alloc, src);
        const s = &self.sources.items[self.sources.items.len - 1];
        // Find its transients on the side; a failed spawn finds them here.
        if (self.alloc.create(Analysis)) |a| {
            a.* = .{};
            s.analysis = a;
            const r: ?[]const f64 = if (sample.isStereo()) sample.right else null;
            a.thread = std.Thread.spawn(.{}, Analysis.run, .{ a, self.alloc, sample.data, r, sample.sample_rate }) catch blk: {
                a.run(self.alloc, sample.data, r, sample.sample_rate);
                break :blk null;
            };
        } else |_| {}
        return @intCast(self.sources.items.len - 1);
    }
};

fn basenameStart(path: []const u8) usize {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return i + 1;
    }
    return 0;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "loadFile dedups by path and exposes basename" {
    var pool = AudioPool.init(testing.allocator);
    defer pool.deinit();

    const idx0 = try pool.loadFile("machines/sampler/assets/default.wav");
    const idx1 = try pool.loadFile("machines/sampler/assets/default.wav");
    try testing.expectEqual(idx0, idx1);
    try testing.expectEqual(@as(usize, 1), pool.count());

    const src = pool.get(idx0).?;
    try testing.expectEqualStrings("default.wav", src.name());
    try testing.expect(src.sample.data.len > 0);
    try testing.expect(src.cache.sample_count == src.sample.data.len);
    try testing.expect(src.seconds() > 0);
}

test "get out of range is null" {
    var pool = AudioPool.init(testing.allocator);
    defer pool.deinit();
    try testing.expect(pool.get(0) == null);
}
