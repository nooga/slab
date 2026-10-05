//! Tempo detection (docs/29 §Transients): a source's tempo and first
//! downbeat from its transients. The hits make an envelope; its
//! autocorrelation, read at each candidate tempo's beat and its multiples,
//! scores the tempo, weighted toward 120 and, for a loop, toward a whole
//! number of bars; a comb over the envelope then finds the beat's phase,
//! and the strongest of the bar's four beats the downbeat. UI thread.

const std = @import("std");

pub const Guess = struct {
    bpm: f64,
    /// A downbeat, in source seconds: the earliest.
    first: f64,
    /// The best score over the mean: 1 is none at all, 2 and up is sure.
    confidence: f32,

    pub fn sure(g: Guess) bool {
        return g.confidence >= 1.6;
    }
};

const RATE = 200.0; // envelope bins a second
const MIN_BPM = 60.0;
const MAX_BPM = 200.0;
/// A loop is this long or shorter: its length is a whole number of bars.
pub const LOOP_MAX_SEC = 30.0;

/// `low`: each onset's low share (transients.Onsets.low), or empty.
pub fn detect(alloc: std.mem.Allocator, onsets: []const f64, strength: []const f32, low: []const f32, len: f64) !?Guess {
    if (onsets.len < 4 or len <= 1) return null;
    const n: usize = @intFromFloat(@ceil(len * RATE) + 4);
    const e = try alloc.alloc(f32, n);
    defer alloc.free(e);
    @memset(e, 0);
    for (onsets, strength) |t, s| {
        const i: usize = @intFromFloat(@round(t * RATE));
        if (i + 1 >= n) continue;
        const w = 0.3 + s;
        e[i] += w;
        if (i > 0) e[i - 1] += w * 0.5;
        e[i + 1] += w * 0.5;
    }

    // Autocorrelation over the lags of 50..400 BPM (multiples included).
    const max_lag: usize = @min(n - 1, @as(usize, @intFromFloat(@ceil(RATE * 60 / MIN_BPM * 4))) + 2);
    const ac = try alloc.alloc(f32, max_lag + 1);
    defer alloc.free(ac);
    for (ac, 0..) |*v, lag| {
        var sum: f32 = 0;
        for (e[0 .. n - lag], e[lag..]) |a, b| sum += a * b;
        v.* = sum;
    }
    const At = struct {
        fn lerp(a: []const f32, x: f64) f32 {
            if (x < 0 or x >= @as(f64, @floatFromInt(a.len - 1))) return 0;
            const i: usize = @intFromFloat(@floor(x));
            const f: f32 = @floatCast(x - @floor(x));
            return a[i] + (a[i + 1] - a[i]) * f;
        }
    };

    var best_bpm: f64 = 0;
    var best: f32 = 0;
    var total: f32 = 0;
    var count: f32 = 0;
    var bpm: f64 = MIN_BPM;
    while (bpm <= MAX_BPM) : (bpm += 0.05) {
        const lag = RATE * 60 / bpm;
        var sc = At.lerp(ac, lag) + 0.5 * At.lerp(ac, 2 * lag) + 0.5 * At.lerp(ac, 4 * lag);
        // Tempos near 120 are likelier; a loop's length is whole bars.
        const oct = std.math.log2(bpm / 120);
        sc *= @floatCast(@exp(-0.5 * (oct / 0.7) * (oct / 0.7)));
        if (len <= LOOP_MAX_SEC) {
            const beats = len * bpm / 60;
            const bars4 = @round(beats / 4) * 4;
            if (bars4 >= 4 and @abs(beats - bars4) < 0.03 * bars4) sc *= 1.3;
        }
        total += sc;
        count += 1;
        if (sc > best) {
            best = sc;
            best_bpm = bpm;
        }
    }
    if (best <= 0) return null;
    // A loop's tempo is exactly its bars.
    if (len <= LOOP_MAX_SEC) {
        const beats = len * best_bpm / 60;
        const bars4 = @round(beats / 4) * 4;
        if (bars4 >= 4 and @abs(beats - bars4) < 0.03 * bars4) best_bpm = bars4 * 60 / len;
    }

    // The beat's phase: the comb over the envelope that collects the most.
    const period = RATE * 60 / best_bpm;
    var phase: f64 = 0;
    var phase_best: f32 = -1;
    var ph: f64 = 0;
    while (ph < period) : (ph += 1) {
        var sum: f32 = 0;
        var k: f64 = ph;
        while (k < @as(f64, @floatFromInt(n - 1))) : (k += period) sum += At.lerp(e, k);
        if (sum > phase_best) {
            phase_best = sum;
            phase = ph;
        }
    }
    // The downbeat: the beat of the four whose hits are most like kicks
    // (low), a loop's first beat liked best.
    const beat_s = 60 / best_bpm;
    const phase_s = phase / RATE;
    var down: f64 = phase_s;
    var down_best: f32 = -1;
    for (0..4) |j| {
        const at = phase_s + @as(f64, @floatFromInt(j)) * beat_s;
        var sum: f32 = 0;
        for (onsets, 0..) |t, i| {
            const d = @mod(t - at + 2 * beat_s, 4 * beat_s) - 2 * beat_s;
            if (@abs(d) > 0.03) continue;
            sum += 0.2 * strength[i] + (if (i < low.len) low[i] else 0);
        }
        if (len <= LOOP_MAX_SEC and @abs(@mod(at + 2 * beat_s, 4 * beat_s) - 2 * beat_s) < 0.03) sum *= 1.5;
        if (sum > down_best) {
            down_best = sum;
            down = at;
        }
    }
    var first = @mod(down, 4 * beat_s);
    // On the hit itself, when there's one within 40 ms (the envelope's
    // bins are 5 ms).
    var near: f64 = 0.04;
    for (onsets) |t| if (@abs(t - first) < near) {
        near = @abs(t - first);
        first = t;
    };
    return .{ .bpm = best_bpm, .first = first, .confidence = best / (total / count) };
}

/// Follow the beat through a take whose tempo drifts (docs/29 §Audio on
/// the time axis): from the guess's downbeat, each next beat is the hit
/// near where the last period says (within 15 % of it, the stronger and
/// nearer the likelier), else where it says; the period follows each beat
/// found, slowly. Beats in source seconds, from the first downbeat to
/// the end; the caller owns them.
pub fn trackBeats(alloc: std.mem.Allocator, onsets: []const f64, strength: []const f32, len: f64, g: Guess) ![]f64 {
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(alloc);
    var period = 60 / g.bpm;
    var t = g.first;
    try out.append(alloc, t);
    var i: usize = 0;
    while (t + period < len) {
        const want = t + period;
        const reach = 0.15 * period;
        while (i < onsets.len and onsets[i] < want - reach) i += 1;
        var best: ?f64 = null;
        var best_s: f64 = 0;
        var j = i;
        while (j < onsets.len and onsets[j] <= want + reach) : (j += 1) {
            const d = (onsets[j] - want) / (0.07 * period);
            const sc = (0.3 + strength[j]) * @exp(-d * d);
            if (sc > best_s) {
                best_s = sc;
                best = onsets[j];
            }
        }
        const next = best orelse want;
        if (best != null) period = 0.85 * period + 0.15 * (next - t);
        t = next;
        try out.append(alloc, t);
    }
    return out.toOwnedSlice(alloc);
}

// ── Tests ────────────────────────────────────────────────────────────

fn pattern(alloc: std.mem.Allocator, bpm: f64, first: f64, len: f64, on: *std.ArrayList(f64), st: *std.ArrayList(f32)) !void {
    // Kick on 1 and 3, snare on 2 and 4, hats on the eighths.
    const eighth = 30 / bpm;
    var t = first - 8 * eighth;
    var k: i64 = -8;
    while (t < len) : ({
        t += eighth;
        k += 1;
    }) {
        if (t < 0) continue;
        const pos = @mod(k, 8);
        try on.append(alloc, t);
        try st.append(alloc, if (pos == 0) 1.0 else if (pos == 4) 0.7 else if (@mod(pos, 2) == 0) 0.5 else 0.15);
    }
}

test "detect: a loop's tempo, exactly its bars, and its downbeat" {
    const alloc = std.testing.allocator;
    var on: std.ArrayList(f64) = .empty;
    defer on.deinit(alloc);
    var st: std.ArrayList(f32) = .empty;
    defer st.deinit(alloc);
    // Two bars at 92 BPM, starting on the downbeat.
    const len = 8 * 60.0 / 92.0;
    try pattern(alloc, 92, 0, len, &on, &st);
    const g = (try detect(alloc, on.items, st.items, &.{}, len)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 92), g.bpm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), g.first, 0.01);
    try std.testing.expect(g.sure());
}

test "detect: a longer take with a pickup" {
    const alloc = std.testing.allocator;
    var on: std.ArrayList(f64) = .empty;
    defer on.deinit(alloc);
    var st: std.ArrayList(f32) = .empty;
    defer st.deinit(alloc);
    // 40 s at 128.4 BPM, its first downbeat 0.31 s in (a pickup before).
    try pattern(alloc, 128.4, 0.31, 40, &on, &st);
    const lows = try alloc.alloc(f32, on.items.len);
    defer alloc.free(lows);
    for (st.items, lows) |v, *lw| lw.* = if (v == 1.0) 1 else 0; // the kicks
    const g = (try detect(alloc, on.items, st.items, lows, 40)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 128.4), g.bpm, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.31), g.first, 0.01);
}

test "detect: too few hits is no guess" {
    try std.testing.expect((try detect(std.testing.allocator, &.{ 0.1, 0.5 }, &.{ 1, 1 }, &.{}, 3)) == null);
}

test "detect: from audio, through the transient finder" {
    const alloc = std.testing.allocator;
    const transients = @import("transients.zig");
    // Two bars of a 97 BPM beat at 48 kHz: kick, snare, hats.
    const rate = 48_000.0;
    const bpm: f64 = 97.0;
    const len: f64 = 8.0 * 60.0 / bpm;
    const n: usize = @intFromFloat(len * rate);
    const x = try alloc.alloc(f64, n);
    defer alloc.free(x);
    @memset(x, 0);
    var rng = std.Random.DefaultPrng.init(5);
    for (0..16) |k| {
        const s: usize = @intFromFloat(@as(f64, @floatFromInt(k)) * 30 / bpm * rate);
        const pos = k % 8;
        for (0..@min(9000, n - s)) |i| {
            const t = @as(f64, @floatFromInt(i)) / rate;
            const v = if (pos == 0 or pos == 3)
                0.9 * @exp(-t * 18) * @sin(2 * std.math.pi * (50 + 120 * @exp(-t * 40)) * t)
            else if (pos == 4)
                0.6 * @exp(-t * 25) * (rng.random().float(f64) * 2 - 1)
            else
                0.25 * @exp(-t * 90) * (rng.random().float(f64) * 2 - 1);
            x[s + i] += v;
        }
    }
    var on = try transients.detect(alloc, x, null, rate);
    defer on.deinit(alloc);
    const g = (try detect(alloc, on.sec, on.strength, on.low, len)).?;
    try std.testing.expectApproxEqAbs(bpm, g.bpm, 0.01);
    try std.testing.expect(g.first < 0.005);
    try std.testing.expect(g.sure());
}

test "trackBeats: follows a take that speeds up" {
    const alloc = std.testing.allocator;
    // 32 beats from 100 to 110 BPM, a hit on each and a ghost between.
    var on: std.ArrayList(f64) = .empty;
    defer on.deinit(alloc);
    var st: std.ArrayList(f32) = .empty;
    defer st.deinit(alloc);
    var beats: [33]f64 = undefined;
    var t: f64 = 0;
    for (0..33) |k| {
        beats[k] = t;
        const bpm = 100 + 10 * @as(f64, @floatFromInt(k)) / 32;
        try on.append(alloc, t);
        try st.append(alloc, 0.8);
        try on.append(alloc, t + 30 / bpm);
        try st.append(alloc, 0.1);
        t += 60 / bpm;
    }
    const got = try trackBeats(alloc, on.items, st.items, t - 0.01, .{ .bpm = 100, .first = 0, .confidence = 3 });
    defer alloc.free(got);
    try std.testing.expect(got.len >= 32);
    for (got[0..32], beats[0..32]) |a, b| try std.testing.expectApproxEqAbs(b, a, 1e-9);
}
