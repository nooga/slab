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
const wav = @import("wav.zig");
const waveform = @import("waveform.zig");

pub const MAX_PATH = 512;

pub const Source = struct {
    sample: wav.Sample,
    cache: waveform.PeakCache = .{},
    path_buf: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: u16 = 0,
    name_off: u16 = 0, // basename start within path_buf

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
        for (self.sources.items) |*s| {
            s.sample.deinit(self.alloc);
            s.cache.deinit(self.alloc);
        }
        self.sources.deinit(self.alloc);
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
    pub fn loadFile(self: *AudioPool, path: []const u8) !u32 {
        if (path.len == 0 or path.len > MAX_PATH) return error.PathTooLong;
        if (self.indexOfPath(path)) |existing| return existing;

        var sample = try wav.load(self.alloc, path);
        errdefer sample.deinit(self.alloc);

        var src = Source{ .sample = sample };
        try src.cache.build(self.alloc, sample.data);
        errdefer src.cache.deinit(self.alloc);

        @memcpy(src.path_buf[0..path.len], path);
        src.path_len = @intCast(path.len);
        src.name_off = @intCast(basenameStart(path));

        try self.sources.append(self.alloc, src);
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
