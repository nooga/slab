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
    /// The energy the hit adds, by third octaves (its first ~40 ms
    /// against the ~40 ms before it): the share of that under 150 Hz,
    /// where it centers (Hz, geometric, energy-weighted), and how evenly
    /// it spreads over the top above 1 kHz, 0 (a tone) .. 1 (noise).
    low: f32,
    centroid: f32,
    flat: f32,
    /// The share of what it adds at 150–600 Hz: a snare's or a tom's body,
    /// which a hat hasn't.
    body: f32 = 0,
    /// How much louder the band under 150 Hz got (after over before): a
    /// new kick makes it louder, a kick still ringing (its pitch falling
    /// into other bins) only quieter.
    low_rise: f32 = 0,
    /// Where it centers above 150 Hz, for a hit that isn't a kick.
    upper: f32 = 0,
    /// All the energy it adds.
    gain: f32 = 0,
    /// Seconds until it is 20 dB under its peak (cut at the next hit).
    decay: f32,
};

const WIN = 2048;
const F = fft.Fft(WIN);
/// Where the windows before a hit start, further back: over 12 ms, half
/// the beat of two notes 40 Hz apart.
const BEFORE_OFFSETS = [_]isize{ 0, 192, 384, 576 };
/// Third-octave bands from 40 Hz, up to 16 kHz.
const BAND_LO: f64 = 40;
const BANDS = 26;

fn mid(l: []const f64, r: ?[]const f64, i: usize) f64 {
    if (i >= l.len) return 0;
    return if (r) |rr| (l[i] + rr[i]) * 0.5 else l[i];
}

pub fn feature(l: []const f64, r: ?[]const f64, rate: f64, sec: f64, next: f64) Feature {
    const s0: usize = @intFromFloat(@max(0, sec * rate));
    // What the hit adds: the energy in each third of an octave over the
    // WIN samples from just before it, less that over the WIN before
    // those. Full Hann windows, so a held bass or pad under it (a drum
    // stem's bleed, a mix) measures the same in both and cancels; whole
    // bands, so a partial's energy stays in its band.
    var after: [WIN]C = undefined;
    var buf: [WIN]C = undefined;
    const lead = WIN / 8;
    const a0 = @as(isize, @intCast(s0)) - lead;
    const hann = struct {
        fn w(i: usize) f32 {
            return @floatCast(0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / WIN));
        }
    }.w;
    for (&after, 0..) |*a, i| {
        const ia = a0 + @as(isize, @intCast(i));
        a.* = .{ .re = if (ia >= 0) @as(f32, @floatCast(mid(l, r, @intCast(ia)))) * hann(i) else 0, .im = 0 };
    }
    F.forward(&after);
    // Before, as the most each bin held over a few windows a little apart:
    // notes beating against each other, or a partial's phase, swing a
    // bin's energy, and its peak is what a hit has to beat.
    var before_e: [WIN / 2]f64 = [_]f64{0} ** (WIN / 2);
    for (BEFORE_OFFSETS) |off| {
        for (&buf, 0..) |*b, i| {
            const ib = a0 - WIN - off + @as(isize, @intCast(i));
            b.* = .{ .re = if (ib >= 0) @as(f32, @floatCast(mid(l, r, @intCast(ib)))) * hann(i) else 0, .im = 0 };
        }
        F.forward(&buf);
        for (&before_e, 0..) |*e, k| e.* = @max(e.*, @as(f64, buf[k].re) * buf[k].re + @as(f64, buf[k].im) * buf[k].im);
    }
    const bin_hz = rate / WIN;
    var gain: [BANDS]f64 = undefined;
    var total: f64 = 0;
    var low_a: f64 = 0;
    var low_b: f64 = 0;
    for (&gain, 0..) |*g, bi| {
        const f0 = BAND_LO * std.math.pow(f64, 2, @as(f64, @floatFromInt(bi)) / 3);
        const k0: usize = @intFromFloat(@round(f0 / bin_hz));
        const k1: usize = @min(WIN / 2, @max(k0 + 1, @as(usize, @intFromFloat(@round(f0 * std.math.pow(f64, 2, 1.0 / 3.0) / bin_hz)))));
        // Bin by bin, so two notes sharing a band (beating against each
        // other) each stay steady in their own bin and cancel; a steady
        // sound's windowed energy still wobbles with its phase, so a bin
        // counts only what it gains past a quarter of what it had.
        var gb: f64 = 0;
        for (k0..k1) |k| {
            const ea = @as(f64, after[k].re) * after[k].re + @as(f64, after[k].im) * after[k].im;
            gb += @max(0, ea - before_e[k] * 1.25);
            if (f0 < 150) {
                low_a += ea;
                low_b += before_e[k];
            }
        }
        g.* = gb;
        total += g.*;
    }
    var low_e: f64 = 0;
    var body_e: f64 = 0;
    var logf: f64 = 0;
    var up_e: f64 = 0;
    var up_logf: f64 = 0;
    var top_sum: f64 = 0;
    var top_log: f64 = 0;
    var top_n: f64 = 0;
    for (gain, 0..) |g, bi| {
        const fc = BAND_LO * std.math.pow(f64, 2, (@as(f64, @floatFromInt(bi)) + 0.5) / 3);
        if (fc < 150) low_e += g;
        if (fc >= 150 and fc < 600) body_e += g;
        logf += g * @log(fc);
        if (fc >= 150) {
            up_e += g;
            up_logf += g * @log(fc);
        }
        // Per hertz: noise is flat over the top, a tone isn't.
        if (fc >= 1000) {
            const d = g / fc + 1e-30;
            top_sum += d;
            top_log += @log(d);
            top_n += 1;
        }
    }
    const low: f32 = if (total > 0) @floatCast(low_e / total) else 0;
    const body: f32 = if (total > 0) @floatCast(body_e / total) else 0;
    const low_rise: f32 = @floatCast(@min(100, low_a / (low_b + 1e-12)));
    const centroid: f32 = if (total > 0) @floatCast(@exp(logf / total)) else 0;
    const flat: f32 = if (top_sum > 0) @floatCast(@exp(top_log / top_n) / (top_sum / top_n)) else 0;
    const upper: f32 = if (up_e > 0) @floatCast(@exp(up_logf / up_e)) else centroid;

    // How long it rings: 5 ms steps from the hit until what it added is
    // 20 dB under its peak, over the level before it. A bright hit is
    // followed in the first difference (a high-pass), where a bass or a
    // pad under it hardly shows.
    const diff = centroid >= 2000;
    const lv = struct {
        fn at(ll: []const f64, rr: ?[]const f64, j: usize, d: bool) f64 {
            const x = mid(ll, rr, j);
            const v = if (d and j > 0) x - mid(ll, rr, j - 1) else x;
            return v * v;
        }
    }.at;
    const step: usize = @intFromFloat(@max(1, 0.005 * rate));
    var pre: f64 = 0;
    {
        const p0 = s0 -| 4 * step;
        for (p0..s0) |j| pre += lv(l, r, j, diff);
        pre = pre / @as(f64, @floatFromInt(@max(1, s0 - p0))) * @as(f64, @floatFromInt(step));
    }
    const end: usize = @min(l.len, @as(usize, @intFromFloat(@max(sec + 0.01, @min(next, sec + 1.0)) * rate)));
    var peak: f64 = 0;
    var decay: f32 = @floatCast(@max(0, @as(f64, @floatFromInt(end -| s0)) / rate));
    var i = s0;
    while (i + step <= end) : (i += step) {
        var e: f64 = 0;
        for (i..i + step) |j| e += lv(l, r, j, diff);
        const own = @max(0, e - pre);
        if (own > peak) peak = own;
        if (peak > 0 and own < peak * 0.01) {
            decay = @floatCast(@as(f64, @floatFromInt(i - s0)) / rate);
            break;
        }
    }
    return .{ .low = low, .centroid = centroid, .flat = flat, .body = body, .low_rise = low_rise, .upper = upper, .gain = @floatCast(total), .decay = decay };
}

/// The point a hit sits at for clustering: each feature brought to about
/// 0..1.
fn point(f: Feature) [4]f32 {
    return .{
        f.low,
        // Where the spectrum sits tells drums apart most: twice the say.
        std.math.clamp(std.math.log2(@max(50, f.centroid) / 50) / 4.5, 0, 2),
        f.body,
        std.math.clamp(f.decay / 0.4, 0, 1),
    };
}

/// What a group sounds like, from its middle.
/// Measured on drum2 kits, clean and as Demucs' drum stems of rendered
/// songs (docs/30 §Drums): a kick's gain is mostly under 150 Hz; a hat's
/// sits high with no body and rings 10–15 ms closed, 90 ms and more open;
/// a snare has body or rings 30 ms and more around 1–5 kHz; a tom is
/// tonal and low. How noisy it is didn't tell (drum2's hats are metallic).
pub fn classOf(f: Feature) Class {
    if (f.low >= 0.4 and f.low_rise >= 1.5) return .kick;
    // Not a kick: what it adds above 150 Hz says what it is (a kick's
    // tail under it is no part of it).
    const c = if (f.low >= 0.4) f.upper else f.centroid;
    if (c >= 4500 and f.body < 0.1) return if (f.decay >= 0.09) .open_hat else .closed_hat;
    if (c < 700) return .tom;
    if (f.body >= 0.15 or (c >= 900 and f.decay >= 0.03)) return .snare;
    if (c >= 2000) return .closed_hat;
    return .perc;
}

pub const MAX_GROUPS = 8;
/// A flicker in a tail, not a drum (no group, no note): its onset
/// strength under this. Demucs' drum stems' flickers sit near 0.03; a
/// kick on a held bass, which hardly moves the flux, at 0.08.
pub const MIN_STRENGTH: f32 = 0.06;
/// `Kit.group` of a hit too weak to be a drum.
pub const NONE: u8 = 255;

pub const Kit = struct {
    /// Per hit (as the source's onsets): its group, or NONE.
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

/// The kit in a source's hits: each hit named for what it sounds like,
/// a name's hits split when they are two drums, each group keyed, its
/// pad the strongest hit with room after it.
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
        // It rings until the next hit at least half as strong: a flicker
        // in its own tail doesn't cut it short.
        var next = len_sec;
        for (i + 1..n) |j| if (hits.strength[j] >= hits.strength[i] * 0.5) {
            next = hits.sec[j];
            break;
        };
        feats[i] = feature(l, r, rate, s, next);
        pts[i] = point(feats[i]);
    }
    // Each hit named on its own; then each name's hits split in two when
    // they are clearly two drums (a second kick, a rim and a snare): the
    // split leaves a third of the spread or less, and both halves are
    // played at least three times.
    const class_of = try alloc.alloc(Class, n);
    defer alloc.free(class_of);
    for (feats, class_of) |f, *c| c.* = classOf(f);
    @memset(out.group, NONE);
    const sub = try alloc.alloc(u8, n);
    defer alloc.free(sub);
    const sel = try alloc.alloc([4]f32, n);
    defer alloc.free(sel);
    const idx = try alloc.alloc(usize, n);
    defer alloc.free(idx);
    var k: usize = 0;
    var used = [_]u8{0} ** std.enums.values(Class).len;
    for (std.enums.values(Class)) |cl| {
        var m: usize = 0;
        for (class_of, 0..) |c, i| if (c == cl and hits.strength[i] >= MIN_STRENGTH) {
            sel[m] = pts[i];
            idx[m] = i;
            m += 1;
        };
        if (m == 0 or k == MAX_GROUPS) continue;
        var cent: [MAX_GROUPS][4]f32 = undefined;
        const one = kmeans(sel[0..m], 1, sub[0..m], &cent);
        var parts: usize = 1;
        if (m >= 6 and k + 2 <= MAX_GROUPS and one > 1e-6) {
            const two = kmeans(sel[0..m], 2, sub[0..m], &cent);
            var c0: usize = 0;
            for (sub[0..m]) |g| c0 += @intFromBool(g == 0);
            if (two < one * 0.33 and c0 >= 3 and m - c0 >= 3) parts = 2;
        }
        if (parts == 1) @memset(sub[0..m], 0);
        for (0..parts) |p| {
            const g = k + p;
            out.class[g] = cl;
            const ks = cl.keys();
            out.key[g] = ks[@min(used[@intFromEnum(cl)], ks.len - 1)];
            used[@intFromEnum(cl)] += 1;
        }
        for (sub[0..m], idx[0..m]) |sg, i| out.group[i] = @intCast(k + sg);
        k += parts;
    }
    out.n = k;

    // Each group's pad: its strongest hit with room after it.
    for (0..k) |g| {
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

test "kit: a beat over a held bass and chords still sorts" {
    const alloc = testing.allocator;
    const rate = 48_000.0;
    const bpm = 100.0;
    const x = try alloc.alloc(f64, @intFromFloat(8.0 * 60.0 / bpm * rate + rate));
    defer alloc.free(x);
    // A sub bass and a chord held under it all, as a drum stem's bleed or
    // a full mix has them; louder than the hats.
    for (x, 0..) |*v, i| {
        const t = @as(f64, @floatFromInt(i)) / rate;
        v.* = 0.35 * @sin(2 * std.math.pi * 55 * t) + 0.1 * (@sin(2 * std.math.pi * 220 * t) + @sin(2 * std.math.pi * 277 * t) + @sin(2 * std.math.pi * 330 * t));
    }
    beat(x, bpm);
    var on = try transients.detect(alloc, x, null, rate);
    defer on.deinit(alloc);
    var k = try kit(alloc, x, null, rate, &on);
    defer k.deinit(alloc);
    // Each hit where it was played (the held chord adds an onset of its
    // own at the start).
    for (0..16) |i| {
        const t = @as(f64, @floatFromInt(i)) * 30 / bpm;
        // The strongest onset there (a flicker in a tail can sit beside it).
        var near: ?usize = null;
        for (on.sec, 0..) |s, j| if (@abs(s - t) < 0.02 and (near == null or on.strength[j] > on.strength[near.?])) {
            near = j;
        };
        const h = near orelse return error.TestUnexpectedResult;
        if (k.group[h] == NONE) return error.TestUnexpectedResult;
        const pos = i % 8;
        const want: Class = if (pos == 0 or pos == 3) .kick else if (pos == 2 or pos == 6) .snare else if (i == 15) .open_hat else .closed_hat;
        const got = k.class[k.group[h]];
        if (got != want) {
            std.debug.print("hit {d}: want {s}, got {s}\n", .{ i, want.label(), got.label() });
            return error.TestUnexpectedResult;
        }
    }
}
