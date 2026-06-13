//! Waveform peak cache + draw — the host-side keystone for every waveform
//! view (the sampler oscillogram now; audio clips in the arrangement later).
//!
//! Drawing raw f64 audio per frame is too expensive and aliases when zoomed
//! out, so we precompute a pyramid of min/max peak pairs: level 0 buckets
//! BASE samples, each higher level halves the resolution. A draw at any zoom
//! picks the finest level whose bucket is ≤ one pixel, then walks its peaks.
//! Build is UI-thread only; the audio thread never touches the cache.

const std = @import("std");
const c = @import("c.zig");
const theme = @import("ui/theme.zig");

pub const Peak = struct { min: f32 = 0, max: f32 = 0 };

// Level 0 bucket size. Small enough that a fully zoomed-in oscillogram still
// has detail, big enough that the pyramid is a few % of the audio size.
const BASE: usize = 64;

pub const PeakCache = struct {
    // Concatenated pyramid: levels[level] is a slice into `peaks`.
    peaks: []Peak = &.{},
    level_off: [24]usize = [_]usize{0} ** 24,
    level_len: [24]usize = [_]usize{0} ** 24,
    level_count: usize = 0,
    sample_count: usize = 0,

    pub fn deinit(self: *PeakCache, alloc: std.mem.Allocator) void {
        if (self.peaks.len > 0) alloc.free(self.peaks);
        self.* = .{};
    }

    /// Build a fresh pyramid from `samples`. Replaces any existing contents.
    pub fn build(self: *PeakCache, alloc: std.mem.Allocator, samples: []const f64) !void {
        self.deinit(alloc);
        if (samples.len == 0) return;

        // Level sizes: level 0 has ceil(N/BASE) buckets; each next halves.
        var sizes: [24]usize = undefined;
        var levels: usize = 0;
        var n = (samples.len + BASE - 1) / BASE;
        while (true) {
            sizes[levels] = n;
            levels += 1;
            if (n <= 1 or levels >= sizes.len) break;
            n = (n + 1) / 2;
        }
        var total: usize = 0;
        for (sizes[0..levels]) |s| total += s;

        const peaks = try alloc.alloc(Peak, total);
        errdefer alloc.free(peaks);

        var off: usize = 0;
        for (sizes[0..levels], 0..) |s, lvl| {
            self.level_off[lvl] = off;
            self.level_len[lvl] = s;
            off += s;
        }
        self.level_count = levels;
        self.sample_count = samples.len;
        self.peaks = peaks;

        // Level 0 directly from samples.
        const l0 = peaks[self.level_off[0]..][0..self.level_len[0]];
        for (l0, 0..) |*p, i| {
            const start = i * BASE;
            const end = @min(start + BASE, samples.len);
            var mn: f32 = @floatCast(samples[start]);
            var mx = mn;
            for (samples[start..end]) |s| {
                const v: f32 = @floatCast(s);
                mn = @min(mn, v);
                mx = @max(mx, v);
            }
            p.* = .{ .min = mn, .max = mx };
        }
        // Higher levels by pairwise reduction of the level below.
        var lvl: usize = 1;
        while (lvl < levels) : (lvl += 1) {
            const dst = peaks[self.level_off[lvl]..][0..self.level_len[lvl]];
            const src = peaks[self.level_off[lvl - 1]..][0..self.level_len[lvl - 1]];
            for (dst, 0..) |*p, i| {
                const a = src[i * 2];
                const b = if (i * 2 + 1 < src.len) src[i * 2 + 1] else a;
                p.* = .{ .min = @min(a.min, b.min), .max = @max(a.max, b.max) };
            }
        }
    }

    /// Min/max over [start_sample, end_sample) by reading the level whose
    /// bucket spans roughly `samples_per_px`. Cheap enough to call per pixel.
    fn rangePeak(self: *const PeakCache, start_sample: f64, end_sample: f64, samples_per_px: f64) Peak {
        if (self.level_count == 0) return .{};
        // Choose the level whose bucket (BASE * 2^lvl) is ≤ samples_per_px.
        var lvl: usize = 0;
        var bucket: f64 = BASE;
        while (lvl + 1 < self.level_count and bucket * 2.0 <= samples_per_px) : (lvl += 1) bucket *= 2.0;

        const off = self.level_off[lvl];
        const len = self.level_len[lvl];
        const lo = @max(0, @as(isize, @intFromFloat(@floor(start_sample / bucket))));
        const hi = @min(@as(isize, @intCast(len)), @as(isize, @intFromFloat(@ceil(end_sample / bucket))));
        if (hi <= lo) {
            const idx: usize = @min(len - 1, @as(usize, @intCast(@max(0, lo))));
            return self.peaks[off + idx];
        }
        var mn: f32 = 1e30;
        var mx: f32 = -1e30;
        var i: usize = @intCast(lo);
        while (i < @as(usize, @intCast(hi))) : (i += 1) {
            const p = self.peaks[off + i];
            mn = @min(mn, p.min);
            mx = @max(mx, p.max);
        }
        return .{ .min = mn, .max = mx };
    }
};

/// Draw the waveform for sample window [win_start, win_end) into `r`, one
/// vertical min/max bar per pixel column. Brutalist: 1px, no AA, no fill
/// gradient — a solid block between min and max plus a centre zero line.
pub fn draw(r: c.rl.Rectangle, cache: *const PeakCache, win_start: f64, win_end: f64, col: c.rl.Color) void {
    if (r.width < 1 or r.height < 1 or cache.sample_count == 0) return;
    const span = @max(win_end - win_start, 1.0);
    const cols: usize = @intFromFloat(r.width);
    const spp = span / @as(f64, @floatFromInt(cols));
    const mid = r.y + r.height * 0.5;
    const half = r.height * 0.5;

    // zero line
    c.rl.DrawLineEx(.{ .x = r.x, .y = mid }, .{ .x = r.x + r.width, .y = mid }, 1.0, theme.slab_lo);

    var px: usize = 0;
    while (px < cols) : (px += 1) {
        const s0 = win_start + @as(f64, @floatFromInt(px)) * spp;
        const s1 = s0 + spp;
        const p = cache.rangePeak(s0, s1, spp);
        // map [-1,1] -> pixels (clamped), y grows downward
        const ymax = mid - std.math.clamp(@as(f32, @floatCast(p.max)), -1.0, 1.0) * @as(f32, @floatCast(half));
        const ymin = mid - std.math.clamp(@as(f32, @floatCast(p.min)), -1.0, 1.0) * @as(f32, @floatCast(half));
        const x = r.x + @as(f32, @floatFromInt(px));
        const top = @min(ymax, ymin);
        const bot = @max(ymax, ymin);
        c.rl.DrawLineEx(.{ .x = x, .y = top }, .{ .x = x, .y = bot + 1 }, 1.0, col);
    }
}

const testing = std.testing;

test "peak cache captures extremes and reduces" {
    var cache = PeakCache{};
    defer cache.deinit(testing.allocator);

    // 1000 samples: a +0.8 spike at 100, a -0.6 dip at 500, else small.
    var buf: [1000]f64 = undefined;
    for (&buf, 0..) |*s, i| s.* = 0.01 * @sin(@as(f64, @floatFromInt(i)));
    buf[100] = 0.8;
    buf[500] = -0.6;

    try cache.build(testing.allocator, &buf);
    try testing.expect(cache.level_count >= 1);
    try testing.expectEqual(@as(usize, 1000), cache.sample_count);

    // The top level's single (or few) buckets must still see both extremes.
    const top = cache.level_count - 1;
    var mn: f32 = 1e30;
    var mx: f32 = -1e30;
    for (cache.peaks[cache.level_off[top]..][0..cache.level_len[top]]) |p| {
        mn = @min(mn, p.min);
        mx = @max(mx, p.max);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.8), mx, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.6), mn, 1e-4);

    // A coarse range query over the whole thing recovers both extremes.
    const whole = cache.rangePeak(0, 1000, 1000);
    try testing.expectApproxEqAbs(@as(f32, 0.8), whole.max, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.6), whole.min, 1e-4);
}

test "empty build is safe" {
    var cache = PeakCache{};
    defer cache.deinit(testing.allocator);
    try cache.build(testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), cache.sample_count);
    const p = cache.rangePeak(0, 10, 1);
    try testing.expectEqual(@as(f32, 0), p.max);
}
