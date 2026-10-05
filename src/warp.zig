//! Warp (docs/29): an audio clip's map from its own beats to source
//! seconds, the edits on it, and the band-limited reader every audio clip
//! plays through. The map and the reader are plain functions over slices,
//! for the UI thread and the audio thread alike; nothing here allocates
//! except the clip edits, which run on the UI thread.

const std = @import("std");
const tempo_mod = @import("tempo.zig");
const clip_mod = @import("clip.zig");

/// A moment of the source pinned to a content beat.
pub const Marker = struct {
    sec: f64,
    beat: f64,
};

/// How a warped clip keeps time (docs/29 §The algorithms).
pub const Mode = enum(u8) {
    tape,
    beats,
    voice,
    mix,
    smear,

    pub fn label(m: Mode) []const u8 {
        return switch (m) {
            .tape => "TAPE",
            .beats => "BEATS",
            .voice => "VOICE",
            .mix => "MIX",
            .smear => "SMEAR",
        };
    }

    pub fn parse(s: []const u8) ?Mode {
        inline for (std.meta.fields(Mode)) |f| if (std.mem.eql(u8, s, f.name)) return @field(Mode, f.name);
        return null;
    }
};

/// Where BEATS cuts (docs/29 §BEATS): at the transients, or on a grid of
/// content beats.
pub const Preserve = enum(u8) {
    hits,
    d16,
    d8,
    d4,

    pub fn label(p: Preserve) []const u8 {
        return switch (p) {
            .hits => "HITS",
            .d16 => "1/16",
            .d8 => "1/8",
            .d4 => "1/4",
        };
    }

    /// The grid in beats, null for the transients.
    pub fn beats(p: Preserve) ?f64 {
        return switch (p) {
            .hits => null,
            .d16 => 0.25,
            .d8 => 0.5,
            .d4 => 1,
        };
    }
};

/// What fills a stretched slice after its own audio: silence, or its
/// tail looped back and forth.
pub const Gap = enum(u8) {
    cut,
    loop,

    pub fn label(g: Gap) []const u8 {
        return switch (g) {
            .cut => "CUT",
            .loop => "LOOP",
        };
    }
};

/// Whether a mode runs on a stretcher (state kept between blocks).
pub fn stretches(m: Mode) bool {
    return m == .mix or m == .voice or m == .smear;
}

pub fn parseEnum(comptime E: type, s: []const u8) ?E {
    inline for (std.meta.fields(E)) |f| if (std.mem.eql(u8, s, f.name)) return @field(E, f.name);
    return null;
}

// ── The map ──────────────────────────────────────────────────────────

/// Markers, strictly increasing in both `sec` and `beat`, at least two.
/// Between two the source plays linearly; past either end it continues
/// at the nearest segment's rate.
pub const Map = struct {
    m: []const Marker,

    /// The segment (its first marker's index) holding content beat `b`,
    /// the first or last one past the ends.
    pub fn segAtBeat(self: Map, b: f64) usize {
        var lo: usize = 0;
        var hi: usize = self.m.len - 1;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.m[mid].beat <= b) lo = mid else hi = mid;
        }
        return lo;
    }

    pub fn segAtSec(self: Map, s: f64) usize {
        var lo: usize = 0;
        var hi: usize = self.m.len - 1;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.m[mid].sec <= s) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Source seconds per content beat over segment `i`.
    pub fn slope(self: Map, i: usize) f64 {
        const a = self.m[i];
        const b = self.m[i + 1];
        return (b.sec - a.sec) / (b.beat - a.beat);
    }

    pub fn secAt(self: Map, b: f64) f64 {
        const i = self.segAtBeat(b);
        return self.m[i].sec + (b - self.m[i].beat) * self.slope(i);
    }

    pub fn beatAt(self: Map, s: f64) f64 {
        const i = self.segAtSec(s);
        return self.m[i].beat + (s - self.m[i].sec) / self.slope(i);
    }

    /// The tempo the source plays in over the segment under `b` (its SEG
    /// BPM).
    pub fn bpmAt(self: Map, b: f64) f64 {
        return 60.0 / self.slope(self.segAtBeat(b));
    }

    /// A stretch of the content `[b0, b1)` that plays `[s0, s1)` of the
    /// source linearly.
    pub const Span = struct { b0: f64, b1: f64, s0: f64, s1: f64 };

    /// The linear spans covering content beats `[lo, hi)`, clipped to the
    /// source's `[0, len)`: what the waveform draws, segment by segment.
    pub fn spans(self: Map, lo: f64, hi: f64, len: f64, out: []Span) []Span {
        var n: usize = 0;
        const blo = @max(lo, self.beatAt(0));
        const bhi = @min(hi, self.beatAt(len));
        if (bhi <= blo) return out[0..0];
        var i = self.segAtBeat(blo);
        var b = blo;
        while (b < bhi and n < out.len) {
            const end = if (i + 2 < self.m.len) @min(bhi, self.m[i + 1].beat) else bhi;
            if (end > b) {
                out[n] = .{ .b0 = b, .b1 = end, .s0 = self.secAt(b), .s1 = self.secAt(end) };
                n += 1;
            }
            b = end;
            if (i + 2 < self.m.len) i += 1;
        }
        return out[0..n];
    }
};

/// Whether `m` is a valid map: two or more, strictly increasing.
pub fn valid(m: []const Marker) bool {
    if (m.len < 2) return false;
    for (m[1..], m[0 .. m.len - 1]) |b, a| if (!(b.sec > a.sec and b.beat > a.beat)) return false;
    return true;
}

// ── Clip edits (UI thread) ───────────────────────────────────────────

/// The mode a clip warps in first (docs/29 §The algorithms): BEATS for a
/// loop dense with hits, MIX for the rest (and while the hits aren't
/// found yet).
pub fn defaultMode(onsets: ?[]const f64, len: f64) Mode {
    const on = onsets orelse return .mix;
    if (len <= 0 or len > 30) return .mix;
    return if (@as(f64, @floatFromInt(on.len)) / len >= 2) .beats else .mix;
}

/// Warp an unwarped clip on, keeping its sound where it sits: the source
/// laid on beats at the tempo under its start, its window as the offset
/// and length, in `defaultMode`. `len` is the source's length in seconds.
pub fn warpOn(alloc: std.mem.Allocator, clip: *clip_mod.Clip, tmap: *const tempo_mod.TempoMap, len: f64, onsets: ?[]const f64) !void {
    if (clip.audio.warp) return;
    clip.audio.mode = defaultMode(onsets, len);
    const bps = tmap.bpmAt(clip.start_beat) / 60.0;
    const total = @max(len, clip.audio.start_sec + clip.audio.dur_sec, 0.001);
    clip.warp_markers.clearRetainingCapacity();
    try clip.warp_markers.appendSlice(alloc, &.{
        .{ .sec = 0, .beat = 0 },
        .{ .sec = total, .beat = total * bps },
    });
    // Reversed, the content is the mirrored source; the window's head
    // there is what the source's end leaves.
    const head = if (clip.audio.reversed) total - (clip.audio.start_sec + clip.audio.dur_sec) else clip.audio.start_sec;
    clip.audio.offset_beats = head * bps;
    clip.length_beats = @max(MIN_BEATS, clip.audio.dur_sec * bps);
    clip.audio.warp = true;
}

/// Back to a window: the source seconds its first and last beat map to.
/// The caller reflows its length through the tempo map.
pub fn warpOff(clip: *clip_mod.Clip, len: f64) void {
    if (!clip.audio.warp) return;
    const map = Map{ .m = clip.warp_markers.items };
    if (valid(map.m)) {
        const s0 = std.math.clamp(map.secAt(clip.audio.offset_beats), 0, len);
        const s1 = std.math.clamp(map.secAt(clip.audio.offset_beats + clip.length_beats), s0, len);
        clip.audio.start_sec = if (clip.audio.reversed) len - s1 else s0;
        clip.audio.dur_sec = s1 - s0;
    }
    clip.audio.warp = false;
}

/// Scale a warped clip's content by `k` about its start: every marker's
/// beat and the offset times `k`, so the same audio fills `k` times the
/// beats.
pub fn stretch(clip: *clip_mod.Clip, k: f64) void {
    for (clip.warp_markers.items) |*mk| mk.beat *= k;
    clip.audio.offset_beats *= k;
    clip.length_beats *= k;
}

/// Reverse a warped clip in place: the same region, backwards, over the
/// same beats (docs/29 §The model). `len` is the source's seconds.
pub fn mirror(clip: *clip_mod.Clip, len: f64) void {
    const m = clip.warp_markers.items;
    const pivot = 2 * clip.audio.offset_beats + clip.length_beats;
    for (m) |*mk| mk.* = .{ .sec = len - mk.sec, .beat = pivot - mk.beat };
    std.mem.reverse(Marker, m);
    clip.audio.reversed = !clip.audio.reversed;
}

// ── The band-limited reader (docs/29 §The band-limited reader) ──────

/// Zero crossings each side, and table points per crossing.
const ZC = 8;
const RES = 512;
/// The widest the kernel gets when reading fast: past 4× it aliases
/// rather than cost more.
const MAX_SQUEEZE = 4.0;
const MIN_BEATS = 1.0 / 16.0;

fn bessel0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (k < 40) : (k += 1) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}

const KERNEL: [ZC * RES + 2]f32 = blk: {
    @setEvalBranchQuota(10_000_000);
    const beta = 9.0;
    var t: [ZC * RES + 2]f32 = undefined;
    const bessel_beta = bessel0(beta);
    for (&t, 0..) |*v, i| {
        if (i >= ZC * RES) {
            v.* = 0;
            continue;
        }
        const x = @as(f64, @floatFromInt(i)) / RES;
        // Exactly zero on the crossings, so an integer read is the sample.
        if (i % RES == 0) {
            v.* = if (i == 0) 1 else 0;
            continue;
        }
        const sinc = @sin(std.math.pi * x) / (std.math.pi * x);
        const r = x / ZC;
        v.* = @floatCast(sinc * bessel0(beta * @sqrt(1 - r * r)) / bessel_beta);
    }
    break :blk t;
};

fn kernel(x: f64) f32 {
    const p = @abs(x) * RES;
    if (p >= ZC * RES) return 0;
    const i: usize = @intFromFloat(p);
    const f: f32 = @floatCast(p - @as(f64, @floatFromInt(i)));
    return KERNEL[i] + (KERNEL[i + 1] - KERNEL[i]) * f;
}

/// One stereo frame of `l`/`r` (r null: mono) at fractional position
/// `pos`, reading `ratio` source samples per output sample: the cutoff
/// falls to 1/ratio when reading fast. Outside `[0, len)` is silence.
pub fn read(l: [*]const f64, r: ?[*]const f64, len: usize, pos: f64, ratio: f64) [2]f32 {
    const fc: f64 = if (ratio > 1) 1.0 / @min(ratio, MAX_SQUEEZE) else 1.0;
    const reach = @as(f64, ZC) / fc;
    const flen: f64 = @floatFromInt(len);
    if (pos <= -reach or pos >= flen + reach) return .{ 0, 0 };
    const j0f = @max(0, @floor(pos - reach) + 1);
    const j1f = @min(flen - 1, @floor(pos + reach));
    if (j1f < j0f) return .{ 0, 0 };
    var sl: f64 = 0;
    var sr: f64 = 0;
    var j: usize = @intFromFloat(j0f);
    const j1: usize = @intFromFloat(j1f);
    const rr = r orelse l;
    while (j <= j1) : (j += 1) {
        const w: f64 = kernel((pos - @as(f64, @floatFromInt(j))) * fc);
        sl += l[j] * w;
        sr += rr[j] * w;
    }
    return .{ @floatCast(sl * fc), @floatCast(sr * fc) };
}

// ── Tests ────────────────────────────────────────────────────────────

test "map: linear between markers, extrapolated past them" {
    const m = [_]Marker{ .{ .sec = 0, .beat = 0 }, .{ .sec = 2, .beat = 4 }, .{ .sec = 3, .beat = 8 } };
    const map = Map{ .m = &m };
    try std.testing.expectApproxEqAbs(@as(f64, 1), map.secAt(2), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), map.secAt(6), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.25), map.secAt(9), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), map.secAt(-1), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6), map.beatAt(2.5), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 120), map.bpmAt(1), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 240), map.bpmAt(5), 1e-9);
    var buf: [8]Map.Span = undefined;
    const sp = map.spans(-4, 20, 3.5, &buf);
    try std.testing.expectEqual(@as(usize, 2), sp.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0), sp[0].b0, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), sp[0].b1, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10), sp[1].b1, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), sp[1].s1, 1e-12);
}

test "reader: integer positions are the samples, between them it interpolates" {
    var x: [64]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = @sin(@as(f64, @floatFromInt(i)) * 0.3);
    for (0..64) |i| {
        const got = read(&x, null, x.len, @floatFromInt(i), 1);
        try std.testing.expectEqual(@as(f32, @floatCast(x[i])), got[0]);
    }
    // A slow sine between samples, away from the edges.
    const mid = read(&x, null, x.len, 30.5, 1)[0];
    try std.testing.expectApproxEqAbs(@sin(30.5 * 0.3), mid, 2e-3);
    try std.testing.expectEqual(@as(f32, 0), read(&x, null, x.len, -20, 1)[0]);
}

test "reader: reading fast lowers the cutoff" {
    // Nyquist-rate alternation read at 2×: filtered nearly away.
    var x: [256]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = if (i % 2 == 0) 1 else -1;
    try std.testing.expect(@abs(read(&x, null, x.len, 128.25, 2)[0]) < 0.05);
    try std.testing.expect(@abs(read(&x, null, x.len, 128, 1)[0] - 1) < 1e-6);
}
