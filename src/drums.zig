//! Drums to a kit (docs/30 §Drums to pattern and kit): a source's hits
//! (docs/29 §Transients) sorted into the drums that made them. Each hit
//! is described by its first moments — how much is under 150 Hz, where
//! its spectrum's center is, how noisy it is, how long it rings — the
//! hits are clustered on that, each group named for what it sounds like
//! and given its General MIDI key, and the cleanest hit of each becomes
//! its pad. UI thread or worker, never the audio thread.

const std = @import("std");
const fft = @import("fft.zig");
const transients = @import("transients.zig");
const C = fft.C;

pub const Class = enum(u8) {
    kick,
    snare,
    closed_hat,
    open_hat,
    tom,
    perc,

    pub fn label(c: Class) []const u8 {
        return switch (c) {
            .kick => "KICK",
            .snare => "SNARE",
            .closed_hat => "HAT",
            .open_hat => "OPEN HAT",
            .tom => "TOM",
            .perc => "PERC",
        };
    }

    /// GM keys for the first, second, … group of the class.
    fn keys(c: Class) []const u8 {
        return switch (c) {
            .kick => &.{ 36, 35 },
            .snare => &.{ 38, 40, 39 },
            .closed_hat => &.{ 42, 44 },
            .open_hat => &.{ 46, 49 },
            .tom => &.{ 45, 47, 48, 50, 43, 41 },
            .perc => &.{ 37, 39, 51, 53, 54, 56, 70, 75 },
        };
    }
};

pub const Feature = struct {
    /// Share under 150 Hz in its first 60 ms (from the transients).
    low: f32,
    /// Spectral centroid in Hz, and flatness 0 (a tone) .. 1 (noise), of
    /// its first 43 ms.
    centroid: f32,
    flat: f32,
    /// Seconds until it is 20 dB under its peak (cut at the next hit).
    decay: f32,
};

const WIN = 2048;
const F = fft.Fft(WIN);

fn mid(l: []const f64, r: ?[]const f64, i: usize) f64 {
    if (i >= l.len) return 0;
    return if (r) |rr| (l[i] + rr[i]) * 0.5 else l[i];
}

pub fn feature(l: []const f64, r: ?[]const f64, rate: f64, sec: f64, next: f64, low: f32) Feature {
    const s0: usize = @intFromFloat(@max(0, sec * rate));
    // The spectrum of its first WIN samples (a half Hann: the hit is at
    // the start).
    var buf: [WIN]C = undefined;
    for (&buf, 0..) |*b, i| {
        const w: f32 = @floatCast(0.5 + 0.5 * @cos(std.math.pi * @as(f64, @floatFromInt(i)) / WIN));
        b.* = .{ .re = @as(f32, @floatCast(mid(l, r, s0 + i))) * w, .im = 0 };
    }
    F.forward(&buf);
    var num: f64 = 0;
    var den: f64 = 0;
    var logsum: f64 = 0;
    var cnt: f64 = 0;
    const bin_hz = rate / WIN;
    const lo: usize = @intFromFloat(@ceil(40 / bin_hz));
    const hi: usize = @min(WIN / 2, @as(usize, @intFromFloat(16_000 / bin_hz)));
    for (lo..hi) |k| {
        const p = @as(f64, buf[k].re) * buf[k].re + @as(f64, buf[k].im) * buf[k].im + 1e-12;
        num += p * @as(f64, @floatFromInt(k)) * bin_hz;
        den += p;
        logsum += @log(p);
        cnt += 1;
    }
    const centroid: f32 = if (den > 0) @floatCast(num / den) else 0;
    const flat: f32 = if (den > 0) @floatCast(@exp(logsum / cnt) / (den / cnt)) else 0;

    // The envelope in 5 ms steps: its peak, then 20 dB down.
    const step: usize = @intFromFloat(@max(1, 0.005 * rate));
    const end: usize = @min(l.len, @as(usize, @intFromFloat(@max(sec + 0.01, @min(next, sec + 1.0)) * rate)));
    var peak: f64 = 0;
    var decay: f32 = @floatCast(@max(0, @as(f64, @floatFromInt(end -| s0)) / rate));
    var i = s0;
    while (i + step <= end) : (i += step) {
        var e: f64 = 0;
        for (i..i + step) |j| e += mid(l, r, j) * mid(l, r, j);
        if (e > peak) peak = e;
        if (peak > 0 and e < peak * 0.01) {
            decay = @floatCast(@as(f64, @floatFromInt(i - s0)) / rate);
            break;
        }
    }
    return .{ .low = low, .centroid = centroid, .flat = flat, .decay = decay };
}

/// The point a hit sits at for clustering: each feature brought to about
/// 0..1.
fn point(f: Feature) [4]f32 {
    return .{
        f.low,
        // Where the spectrum sits tells drums apart most: twice the say.
        std.math.clamp(std.math.log2(@max(50, f.centroid) / 50) / 4.5, 0, 2),
        std.math.clamp(f.flat * 2, 0, 1),
        std.math.clamp(f.decay / 0.4, 0, 1),
    };
}

/// What a group sounds like, from its middle.
pub fn classOf(f: Feature) Class {
    if (f.low >= 0.45) return .kick;
    if (f.centroid >= 4500) return if (f.decay >= 0.12) .open_hat else .closed_hat;
    if (f.flat >= 0.12 and f.centroid >= 900) return .snare;
    if (f.centroid < 900 and f.flat < 0.12) return .tom;
    return .perc;
}

pub const MAX_GROUPS = 8;

pub const Kit = struct {
    /// Per hit (as the source's onsets): its group.
    group: []u8 = &.{},
    n: usize = 0,
    class: [MAX_GROUPS]Class = undefined,
    key: [MAX_GROUPS]u8 = undefined,
    /// Per group: the hit that is its pad.
    pad: [MAX_GROUPS]usize = undefined,

    pub fn deinit(self: *Kit, alloc: std.mem.Allocator) void {
        alloc.free(self.group);
        self.* = .{};
    }
};

fn dist(a: [4]f32, b: [4]f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += (x - y) * (x - y);
    return s;
}

/// k-means from the farthest-first seeds, a few rounds.
fn kmeans(pts: []const [4]f32, k: usize, assign: []u8, cent: *[MAX_GROUPS][4]f32) f32 {
    cent[0] = pts[0];
    for (1..k) |c| {
        var far: usize = 0;
        var far_d: f32 = -1;
        for (pts, 0..) |p, i| {
            var d: f32 = std.math.inf(f32);
            for (cent[0..c]) |q| d = @min(d, dist(p, q));
            if (d > far_d) {
                far_d = d;
                far = i;
            }
        }
        cent[c] = pts[far];
    }
    var sse: f32 = 0;
    for (0..20) |_| {
        sse = 0;
        for (pts, assign) |p, *a| {
            var best: usize = 0;
            for (cent[0..k], 0..) |q, c| if (dist(p, q) < dist(p, cent[best])) {
                best = c;
            };
            a.* = @intCast(best);
            sse += dist(p, cent[best]);
        }
        var sum: [MAX_GROUPS][4]f32 = undefined;
        var cnt = [_]f32{0} ** MAX_GROUPS;
        for (sum[0..k]) |*s| s.* = .{ 0, 0, 0, 0 };
        for (pts, assign) |p, a| {
            for (0..4) |j| sum[a][j] += p[j];
            cnt[a] += 1;
        }
        for (0..k) |c| if (cnt[c] > 0) {
            for (0..4) |j| cent[c][j] = sum[c][j] / cnt[c];
        };
    }
    return sse;
}

/// The kit in a source's hits: as few groups as describe them (another
/// group must cut what's left unexplained by a third), each named and
/// keyed, its pad the strongest hit with room after it.
pub fn kit(alloc: std.mem.Allocator, l: []const f64, r: ?[]const f64, rate: f64, hits: *const transients.Onsets) !Kit {
    const n = hits.sec.len;
    var out = Kit{ .group = try alloc.alloc(u8, n) };
    errdefer out.deinit(alloc);
    if (n == 0) return out;
    const feats = try alloc.alloc(Feature, n);
    defer alloc.free(feats);
    const pts = try alloc.alloc([4]f32, n);
    defer alloc.free(pts);
    const len_sec = @as(f64, @floatFromInt(l.len)) / rate;
    for (hits.sec, 0..) |s, i| {
        const next = if (i + 1 < n) hits.sec[i + 1] else len_sec;
        feats[i] = feature(l, r, rate, s, next, hits.low[i]);
        pts[i] = point(feats[i]);
    }
    const tmp = try alloc.alloc(u8, n);
    defer alloc.free(tmp);
    var cent: [MAX_GROUPS][4]f32 = undefined;
    var tcent: [MAX_GROUPS][4]f32 = undefined;
    var k: usize = 1;
    var sse = kmeans(pts, 1, out.group, &cent);
    const total = sse;
    while (k < @min(MAX_GROUPS, n) and total > 1e-6) {
        const s2 = kmeans(pts, k + 1, tmp, &tcent);
        // Worth a group: it explains a third of what's left, and enough.
        if (s2 > sse * 0.67 or sse < total * 0.04) break;
        k += 1;
        sse = s2;
        @memcpy(out.group, tmp);
        cent = tcent;
    }
    out.n = k;

    // Name each group by its median hit, key it, pick its pad.
    var used = [_]u8{0} ** std.enums.values(Class).len;
    for (0..k) |g| {
        var med: Feature = .{ .low = 0, .centroid = 0, .flat = 0, .decay = 0 };
        var lows: [4096]f32 = undefined;
        var cs: [4096]f32 = undefined;
        var fs: [4096]f32 = undefined;
        var ds: [4096]f32 = undefined;
        var m: usize = 0;
        for (out.group, 0..) |gi, i| if (gi == g and m < lows.len) {
            lows[m] = feats[i].low;
            cs[m] = feats[i].centroid;
            fs[m] = feats[i].flat;
            ds[m] = feats[i].decay;
            m += 1;
        };
        if (m > 0) {
            inline for (.{ &lows, &cs, &fs, &ds }) |arr| std.mem.sort(f32, arr[0..m], {}, std.sort.asc(f32));
            med = .{ .low = lows[m / 2], .centroid = cs[m / 2], .flat = fs[m / 2], .decay = ds[m / 2] };
        }
        const cl = classOf(med);
        out.class[g] = cl;
        const ks = cl.keys();
        out.key[g] = ks[@min(used[@intFromEnum(cl)], ks.len - 1)];
        used[@intFromEnum(cl)] += 1;
        var best: usize = 0;
        var best_s: f32 = -1;
        for (out.group, 0..) |gi, i| if (gi == g) {
            const gap = (if (i + 1 < n) hits.sec[i + 1] else len_sec) - hits.sec[i];
            const sc = hits.strength[i] * @as(f32, @floatCast(@min(1, gap / 0.15)));
            if (sc > best_s) {
                best_s = sc;
                best = i;
            }
        };
        out.pad[g] = best;
    }
    // A key two groups landed on (a class past its list): the next free.
    for (0..k) |g| for (0..g) |h| if (out.key[h] == out.key[g]) {
        var cand: u8 = 60;
        while (true) : (cand += 1) {
            var taken = false;
            for (out.key[0..k]) |kk| taken = taken or kk == cand;
            if (!taken) break;
        }
        out.key[g] = cand;
    };
    return out;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

/// A test signal: two bars of a beat at 48 kHz, kick on 1 and the "and"
/// of 2, snare on 2 and 4, closed hats on the eighths between, an open
/// hat at the end.
pub fn beat(x: []f64, bpm: f64) void {
    const rate = 48_000.0;
    var rng = std.Random.DefaultPrng.init(7);
    var hp: f64 = 0;
    var prev: f64 = 0;
    for (0..16) |k| {
        const s: usize = @intFromFloat(@as(f64, @floatFromInt(k)) * 30 / bpm * rate);
        const pos = k % 8;
        const long = k == 15;
        for (0..@min(@as(usize, if (long) 20000 else 12000), x.len - s)) |i| {
            const t = @as(f64, @floatFromInt(i)) / rate;
            const noise = rng.random().float(f64) * 2 - 1;
            // A crude highpass for the hats.
            hp = 0.6 * (hp + noise - prev);
            prev = noise;
            const v = if (pos == 0 or pos == 3)
                0.9 * @exp(-t * 18) * @sin(2 * std.math.pi * (50 + 120 * @exp(-t * 40)) * t)
            else if (pos == 2 or pos == 6)
                0.5 * @exp(-t * 22) * (noise * 0.8 + 0.5 * @sin(2 * std.math.pi * 190 * t))
            else
                0.25 * @exp(-t * (if (long) @as(f64, 9) else 70)) * hp;
            x[s + i] += v;
        }
    }
}

test "kit: a beat sorts into kick, snare and hats, each on its GM key" {
    const alloc = testing.allocator;
    const rate = 48_000.0;
    const bpm = 100.0;
    const x = try alloc.alloc(f64, @intFromFloat(8.0 * 60.0 / bpm * rate + rate));
    defer alloc.free(x);
    @memset(x, 0);
    beat(x, bpm);
    var on = try transients.detect(alloc, x, null, rate);
    defer on.deinit(alloc);
    try testing.expectEqual(@as(usize, 16), on.sec.len);
    var k = try kit(alloc, x, null, rate, &on);
    defer k.deinit(alloc);
    for (on.sec, 0..) |_, i| {
        const pos = i % 8;
        const want: Class = if (pos == 0 or pos == 3) .kick else if (pos == 2 or pos == 6) .snare else if (i == 15) .open_hat else .closed_hat;
        const got = k.class[k.group[i]];
        if (got != want) {
            std.debug.print("hit {d}: want {s}, got {s}\n", .{ i, want.label(), got.label() });
            return error.TestUnexpectedResult;
        }
    }
    for (0..k.n) |g| try testing.expectEqual(@as(u8, switch (k.class[g]) {
        .kick => 36,
        .snare => 38,
        .closed_hat => 42,
        .open_hat => 46,
        else => 0,
    }), k.key[g]);
    // The pads have room after them.
    for (0..k.n) |g| try testing.expect(k.class[k.group[k.pad[g]]] == k.class[g]);
}
