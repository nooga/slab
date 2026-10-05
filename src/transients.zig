//! Transients (docs/29 §Transients): where the hits in an audio source
//! are. A spectral-flux onset envelope, peaks picked against a local
//! median, each refined in the sample domain to the start of its steepest
//! rise. Runs on a worker thread when a source enters the pool; the result
//! is read-only after that, by the UI and the audio thread alike.

const std = @import("std");
const wavetable = @import("wavetable.zig");
const Complex = wavetable.Complex;

pub const Onsets = struct {
    /// Seconds into the source, increasing.
    sec: []f64 = &.{},
    /// How strong each one is, 0..1 (the normalized flux above its
    /// threshold).
    strength: []f32 = &.{},

    pub fn deinit(self: *Onsets, alloc: std.mem.Allocator) void {
        alloc.free(self.sec);
        alloc.free(self.strength);
        self.* = .{};
    }
};

const N = 1024;
const HOP = 128;
const BINS = N / 2;
/// Frames each side for the local maximum, and for the median.
const PEAK_W = 3;
const MEDIAN_W = 8;
/// Above the local median, in normalized flux.
const DELTA = 0.07;
const MIN_GAP_SEC = 0.03;
/// The refinement's envelope window and search reach.
const ENV_SEC = 0.001;
const SEARCH_SEC = 0.025;

fn mid(l: []const f64, r: ?[]const f64, i: isize) f64 {
    if (i < 0 or i >= @as(isize, @intCast(l.len))) return 0;
    const u: usize = @intCast(i);
    return if (r) |rr| (l[u] + rr[u]) * 0.5 else l[u];
}

/// The onsets of `l` (and `r`, its right channel, when stereo) at `rate`.
pub fn detect(alloc: std.mem.Allocator, l: []const f64, r: ?[]const f64, rate: f64) !Onsets {
    const frames = l.len / HOP + 1;
    if (l.len < N / 4) return .{ .sec = try alloc.alloc(f64, 0), .strength = try alloc.alloc(f32, 0) };

    // ── The onset envelope ──
    const odf = try alloc.alloc(f32, frames);
    defer alloc.free(odf);
    var win: [N]f64 = undefined;
    for (&win, 0..) |*w, i| w.* = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / N);
    var prev = [_]f32{0} ** BINS;
    var buf: [N]Complex = undefined;
    for (0..frames) |k| {
        const c0: isize = @as(isize, @intCast(k * HOP)) - N / 2;
        for (&buf, 0..) |*b, i| b.* = Complex.init(mid(l, r, c0 + @as(isize, @intCast(i))) * win[i], 0);
        wavetable.fft(&buf, false);
        var flux: f32 = 0;
        for (0..BINS) |b| {
            const m: f32 = @floatCast(@log(1 + 100 * buf[b].magnitude() / (N / 4)));
            const d = m - prev[b];
            if (d > 0) flux += d;
            prev[b] = m;
        }
        odf[k] = flux;
    }
    odf[0] = 0; // the first frame rises from silence by construction

    // Normalize to the 99th percentile, so loud and quiet files pick alike.
    {
        const sorted = try alloc.dupe(f32, odf);
        defer alloc.free(sorted);
        std.mem.sort(f32, sorted, {}, std.sort.asc(f32));
        // A floor at a fraction of the strongest rise, so a file with few
        // or no hits doesn't blow its flutter up into onsets.
        const p = @max(sorted[@min(sorted.len - 1, sorted.len * 99 / 100)], 0.3 * sorted[sorted.len - 1], 1e-6);
        for (odf) |*v| v.* = @min(v.* / p, 2);
    }

    // ── Peaks ──
    var secs: std.ArrayList(f64) = .empty;
    defer secs.deinit(alloc);
    var strs: std.ArrayList(f32) = .empty;
    defer strs.deinit(alloc);
    const min_gap: f64 = MIN_GAP_SEC * rate;
    // The source's start is always a slice's start; a hit right there is
    // it, and a window running off the end sees the cut as a click.
    var last: f64 = 0;
    const end_frame = (l.len -| N / 2) / HOP;
    for (0..@min(frames, end_frame + 1)) |k| {
        const v = odf[k];
        if (v < DELTA) continue;
        const lo = k -| PEAK_W;
        const hi = @min(frames, k + PEAK_W + 1);
        var is_max = true;
        for (lo..hi) |j| if (odf[j] > v or (odf[j] == v and j < k)) {
            is_max = false;
            break;
        };
        if (!is_max) continue;
        var med: [2 * MEDIAN_W + 1]f32 = undefined;
        var n: usize = 0;
        for ((k -| MEDIAN_W)..@min(frames, k + MEDIAN_W + 1)) |j| {
            med[n] = odf[j];
            n += 1;
        }
        std.mem.sort(f32, med[0..n], {}, std.sort.asc(f32));
        const th = med[n / 2] + DELTA;
        if (v < th) continue;
        const at = refine(l, r, rate, @floatFromInt(k * HOP));
        if (at - last < min_gap) continue;
        try secs.append(alloc, at / rate);
        try strs.append(alloc, @min(1, v - th));
        last = at;
    }
    return .{ .sec = try secs.toOwnedSlice(alloc), .strength = try strs.toOwnedSlice(alloc) };
}

/// The start of the steepest 1 ms rise of the rectified signal near
/// sample `t`: where the hit begins.
fn refine(l: []const f64, r: ?[]const f64, rate: f64, t: f64) f64 {
    const e: isize = @max(1, @as(isize, @intFromFloat(ENV_SEC * rate)));
    const reach: isize = @intFromFloat(SEARCH_SEC * rate);
    const ti: isize = @intFromFloat(t);
    const a: isize = @max(0, ti - reach);
    const b = @min(@as(isize, @intCast(l.len)) - 2 * e, ti + reach);
    if (b <= a) return @floatFromInt(@max(0, ti));
    // Sliding sums of |x| over [i, i+e) and [i+e, i+2e).
    var s0: f64 = 0;
    var s1: f64 = 0;
    var j: isize = 0;
    while (j < e) : (j += 1) {
        s0 += @abs(mid(l, r, a + j));
        s1 += @abs(mid(l, r, a + e + j));
    }
    var best: isize = a;
    var best_rise = s1 - s0;
    var i: isize = a;
    while (i < b) : (i += 1) {
        const rise = s1 - s0;
        if (rise > best_rise) {
            best_rise = rise;
            best = i + e;
        }
        s0 += @abs(mid(l, r, i + e)) - @abs(mid(l, r, i));
        s1 += @abs(mid(l, r, i + 2 * e)) - @abs(mid(l, r, i + e));
    }
    // `best` is where the quiet window ends and the loud one begins.
    return @floatFromInt(best);
}

// ── Tests ────────────────────────────────────────────────────────────

fn hits(alloc: std.mem.Allocator, rate: f64, at: []const f64, len_sec: f64, noise: f64) ![]f64 {
    const n: usize = @intFromFloat(len_sec * rate);
    const x = try alloc.alloc(f64, n);
    var rng = std.Random.DefaultPrng.init(7);
    for (x) |*v| v.* = (rng.random().float(f64) * 2 - 1) * noise;
    for (at, 0..) |t, k| {
        const s: usize = @intFromFloat(t * rate);
        const amp: f64 = if (k % 2 == 0) 0.9 else 0.4;
        for (0..@min(4800, n - s)) |i| {
            const fi: f64 = @floatFromInt(i);
            x[s + i] += amp * @exp(-fi / 900) * @sin(2 * std.math.pi * (180 + 2000 * @exp(-fi / 300)) * fi / rate);
        }
    }
    return x;
}

test "detect: finds each hit within half a millisecond, and nothing else" {
    const alloc = std.testing.allocator;
    const rate = 48_000.0;
    const at = [_]f64{ 0.1, 0.35, 0.6, 0.725, 0.85, 1.2, 1.3333 };
    const x = try hits(alloc, rate, &at, 1.6, 0.002);
    defer alloc.free(x);
    var o = try detect(alloc, x, null, rate);
    defer o.deinit(alloc);
    try std.testing.expectEqual(at.len, o.sec.len);
    for (at, o.sec) |want, got| try std.testing.expectApproxEqAbs(want, got, 0.0005);
    for (o.strength) |s| try std.testing.expect(s > 0 and s <= 1);
}

test "detect: a sustained tone has none, not even at its edges" {
    const alloc = std.testing.allocator;
    const rate = 48_000.0;
    const x = try alloc.alloc(f64, 48_000);
    defer alloc.free(x);
    for (x, 0..) |*v, i| v.* = 0.5 * @sin(2 * std.math.pi * 440 * @as(f64, @floatFromInt(i)) / rate);
    var o = try detect(alloc, x, null, rate);
    defer o.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), o.sec.len);
}

