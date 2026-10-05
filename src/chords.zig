//! Chords and key (docs/30 §Chords and key): what harmony an audio source
//! plays. A chroma — how much of each pitch class sounds — per frame,
//! from the spectrum's peaks against the take's own tuning; averaged per
//! beat by the caller; matched to chord templates that carry their tones'
//! overtones, with the bass voting for the root; smoothed over the beats
//! by Viterbi, so chords change on beats and rarely. UI thread or worker,
//! never the audio thread.

const std = @import("std");
const fft = @import("fft.zig");
const warp = @import("warp.zig");
const tune = @import("tune.zig");
const C = fft.C;

pub const RATE: f64 = 11_025;
const N = 4096;
const HOP = 1024;
pub const HOP_SEC: f64 = HOP / RATE;
const F = fft.Fft(N);
/// The spectrum it reads: A1 up, the bass below about E3 (a chord voiced
/// low starts around there).
const LO_HZ: f64 = 55;
const HI_HZ: f64 = 5000;
const BASS_HI_HZ: f64 = 160;

pub const Quality = enum(u8) {
    maj,
    min,
    dom7,
    maj7,
    min7,
    sus2,
    sus4,
    dim,
    aug,

    pub fn intervals(q: Quality) []const u4 {
        return switch (q) {
            .maj => &.{ 0, 4, 7 },
            .min => &.{ 0, 3, 7 },
            .dom7 => &.{ 0, 4, 7, 10 },
            .maj7 => &.{ 0, 4, 7, 11 },
            .min7 => &.{ 0, 3, 7, 10 },
            .sus2 => &.{ 0, 2, 7 },
            .sus4 => &.{ 0, 5, 7 },
            .dim => &.{ 0, 3, 6 },
            .aug => &.{ 0, 4, 8 },
        };
    }

    pub fn suffix(q: Quality) []const u8 {
        return switch (q) {
            .maj => "",
            .min => "m",
            .dom7 => "7",
            .maj7 => "maj7",
            .min7 => "m7",
            .sus2 => "sus2",
            .sus4 => "sus4",
            .dim => "dim",
            .aug => "aug",
        };
    }

    /// How much a chord of this kind has to beat a triad to be heard:
    /// the plain ones first.
    fn prior(q: Quality) f32 {
        return switch (q) {
            .maj, .min => 1,
            .dom7, .maj7, .min7 => 0.97,
            else => 0.94,
        };
    }
};

pub const Chord = struct {
    root: u8,
    quality: Quality,

    pub fn eql(a: Chord, b: Chord) bool {
        return a.root == b.root and a.quality == b.quality;
    }

    pub fn name(self: Chord, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ tune.KEYS[self.root % 12], self.quality.suffix() }) catch "";
    }
};

pub const Chroma = struct {
    /// Per frame (HOP_SEC apart, from the source's start): above A2, and
    /// the bass below E3.
    treble: [][12]f32 = &.{},
    bass: [][12]f32 = &.{},
    /// The take's A against A440, in semitones.
    tuning: f32 = 0,

    pub fn deinit(self: *Chroma, alloc: std.mem.Allocator) void {
        alloc.free(self.treble);
        alloc.free(self.bass);
        self.* = .{};
    }
};

fn downsample(alloc: std.mem.Allocator, l: []const f64, r: ?[]const f64, rate: f64) ![]f32 {
    const ratio = rate / RATE;
    const n: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(l.len)) / ratio));
    const x = try alloc.alloc(f32, n);
    const rp: ?[*]const f64 = if (r) |rr| rr.ptr else null;
    for (x, 0..) |*v, i| {
        const s = warp.read(l.ptr, rp, l.len, @as(f64, @floatFromInt(i)) * ratio, ratio);
        v.* = (s[0] + s[1]) * 0.5;
    }
    return x;
}

const WINDOW: [N]f32 = blk: {
    @setEvalBranchQuota(1_000_000);
    var w: [N]f32 = undefined;
    for (&w, 0..) |*v, i| v.* = @floatCast(0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / N));
    break :blk w;
};

/// A frame's peaks: bin, its interpolated pitch (MIDI) and magnitude.
const Peak = struct { p: f32, m: f32 };

fn peaks(x: []const f32, k: usize, buf: *[N]C, out: *[512]Peak) usize {
    const c0: isize = @as(isize, @intCast(k * HOP)) - N / 2;
    for (buf, 0..) |*b, i| {
        const j = c0 + @as(isize, @intCast(i));
        const v: f32 = if (j >= 0 and j < @as(isize, @intCast(x.len))) x[@intCast(j)] else 0;
        b.* = .{ .re = v * WINDOW[i], .im = 0 };
    }
    F.forward(buf);
    const lo: usize = @intFromFloat(LO_HZ * N / RATE);
    const hi: usize = @intFromFloat(HI_HZ * N / RATE);
    var mag: [N / 2]f32 = undefined;
    for (mag[0 .. hi + 2], 0..) |*m, i| m.* = buf[i].mag();
    var n: usize = 0;
    var i = lo;
    while (i <= hi and n < out.len) : (i += 1) {
        if (!(mag[i] > mag[i - 1] and mag[i] >= mag[i + 1])) continue;
        const a = mag[i - 1];
        const b = mag[i];
        const c = mag[i + 1];
        const den = a - 2 * b + c;
        const d: f32 = if (den < 0) std.math.clamp(0.5 * (a - c) / den, -0.5, 0.5) else 0;
        const hz = (@as(f32, @floatFromInt(i)) + d) * @as(f32, @floatCast(RATE)) / N;
        out[n] = .{ .p = 69 + 12 * std.math.log2(hz / 440), .m = b };
        n += 1;
    }
    return n;
}

/// The chroma of `l` (and `r`, its right channel) at `rate`: a pass for
/// the tuning (the peaks' circular mean from their nearest semitones),
/// a pass folding each peak into its pitch class.
pub fn chroma(alloc: std.mem.Allocator, l: []const f64, r: ?[]const f64, rate: f64) !Chroma {
    const x = try downsample(alloc, l, r, rate);
    defer alloc.free(x);
    const frames = x.len / HOP + 1;
    var out = Chroma{
        .treble = try alloc.alloc([12]f32, frames),
        .bass = try alloc.alloc([12]f32, frames),
    };
    errdefer out.deinit(alloc);
    var buf: [N]C = undefined;
    var pk: [512]Peak = undefined;
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (0..frames) |k| {
        const n = peaks(x, k, &buf, &pk);
        for (pk[0..n]) |q| {
            const a = 2 * std.math.pi * @as(f64, q.p);
            sx += q.m * @cos(a);
            sy += q.m * @sin(a);
        }
    }
    out.tuning = if (sx != 0 or sy != 0) @floatCast(std.math.atan2(sy, sx) / (2 * std.math.pi)) else 0;
    const bass_top: f32 = @floatCast(69 + 12 * std.math.log2(BASS_HI_HZ / 440));
    const treble_lo: f32 = 69 - 12 * 2; // A2
    for (0..frames) |k| {
        @memset(&out.treble[k], 0);
        @memset(&out.bass[k], 0);
        const n = peaks(x, k, &buf, &pk);
        for (pk[0..n]) |q| {
            const p = q.p - out.tuning;
            const s = @round(p);
            // Full at the semitone, nothing a quarter tone off.
            const w = @max(0, 1 - 4 * @abs(p - s));
            if (w == 0) continue;
            const pc: usize = @intCast(@mod(@as(i32, @intFromFloat(s)), 12));
            const v = q.m * w;
            if (p >= treble_lo) out.treble[k][pc] += v;
            if (p < bass_top) out.bass[k][pc] += v;
        }
    }
    return out;
}

/// The chroma averaged between each pair of `edges` (source seconds,
/// increasing): one per beat.
pub fn perSpan(alloc: std.mem.Allocator, ch: *const Chroma, edges: []const f64) !struct { treble: [][12]f32, bass: [][12]f32 } {
    const n = edges.len -| 1;
    const t = try alloc.alloc([12]f32, n);
    errdefer alloc.free(t);
    const b = try alloc.alloc([12]f32, n);
    for (0..n) |i| {
        @memset(&t[i], 0);
        @memset(&b[i], 0);
        const k0: usize = @intFromFloat(@max(0, @round(edges[i] / HOP_SEC)));
        const k1: usize = @intFromFloat(@max(0, @round(edges[i + 1] / HOP_SEC)));
        var k = k0;
        while (k < @max(k1, k0 + 1) and k < ch.treble.len) : (k += 1) {
            for (0..12) |pc| {
                t[i][pc] += ch.treble[k][pc];
                b[i][pc] += ch.bass[k][pc];
            }
        }
    }
    return .{ .treble = t, .bass = b };
}

const QUALITIES = std.enums.values(Quality);
const STATES = 12 * QUALITIES.len + 1;
const NONE = STATES - 1;

/// Each chord's template: its tones with the first four harmonics of
/// each (an octave, a twelfth, two octaves), normalized.
const TEMPLATES: [STATES - 1][12]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [STATES - 1][12]f32 = undefined;
    const harm = [_]struct { st: u8, w: f32 }{ .{ .st = 0, .w = 1 }, .{ .st = 12, .w = 0.6 }, .{ .st = 19, .w = 0.4 }, .{ .st = 24, .w = 0.3 } };
    for (QUALITIES, 0..) |q, qi| for (0..12) |root| {
        var v = [_]f32{0} ** 12;
        for (q.intervals()) |iv| for (harm) |h| {
            v[(root + iv + h.st) % 12] += h.w;
        };
        var norm: f32 = 0;
        for (v) |x| norm += x * x;
        norm = @sqrt(norm);
        for (&v) |*x| x.* /= norm;
        t[qi * 12 + root] = v;
    };
    break :blk t;
};

fn chordOf(state: usize) ?Chord {
    if (state == NONE) return null;
    return .{ .root = @intCast(state % 12), .quality = QUALITIES[state / 12] };
}

/// One chord (or none) per span: each span's fit to every template, the
/// bass's say on the root, and a Viterbi path that stays put unless a
/// change pays.
pub fn decode(alloc: std.mem.Allocator, treble: []const [12]f32, bass: []const [12]f32) ![]?Chord {
    const n = treble.len;
    const out = try alloc.alloc(?Chord, n);
    errdefer alloc.free(out);
    if (n == 0) return out;
    var loudest: f32 = 0;
    for (treble) |v| {
        var e: f32 = 0;
        for (v) |x| e += x;
        loudest = @max(loudest, e);
    }
    const back = try alloc.alloc([STATES]u16, n);
    defer alloc.free(back);
    var delta: [STATES]f32 = [_]f32{0} ** STATES;
    var next: [STATES]f32 = undefined;
    // How sharply a fit counts, and what a change costs: a chord that
    // fits clearly better (by 0.1) takes over within two beats; one that
    // only edges ahead on a beat full of drums doesn't.
    const kappa: f32 = 20;
    const change: f32 = 4;
    for (0..n) |i| {
        var e: f32 = 0;
        var norm: f32 = 0;
        for (treble[i]) |x| {
            e += x;
            norm += x * x;
        }
        norm = @sqrt(norm);
        var bmax: f32 = 0;
        for (bass[i]) |x| bmax = @max(bmax, x);
        var emit: [STATES]f32 = undefined;
        const quiet = loudest <= 0 or e < 0.02 * loudest or norm == 0;
        var fit: f32 = 0;
        var mean: f32 = 0;
        for (0..STATES - 1) |s| {
            if (quiet) {
                emit[s] = 0;
                continue;
            }
            var cos: f32 = 0;
            for (0..12) |pc| cos += treble[i][pc] / norm * TEMPLATES[s][pc];
            const root_bass = if (bmax > 0) bass[i][s % 12] / bmax else 0;
            emit[s] = cos * QUALITIES[s / 12].prior() + 0.2 * root_bass;
            fit = @max(fit, emit[s]);
            mean += emit[s];
        }
        mean /= STATES - 1;
        // A beat where one chord stands out says so; one where every
        // chord fits about as well (drums, a release) hardly speaks.
        const clarity = std.math.clamp((fit - mean) / 0.25, 0.1, 1);
        for (emit[0 .. STATES - 1]) |*v| v.* *= kappa * clarity;
        emit[NONE] = if (quiet) kappa else kappa * clarity * 0.55;
        // The best way into each state: from itself, or from the best of
        // all (every change costs the same).
        var best: usize = 0;
        for (delta, 0..) |v, s| if (v > delta[best]) {
            best = s;
        };
        for (0..STATES) |s| {
            const from_self = delta[s];
            const from_best = delta[best] - change;
            if (i == 0 or from_self >= from_best) {
                next[s] = (if (i == 0) 0 else from_self) + emit[s];
                back[i][s] = @intCast(s);
            } else {
                next[s] = from_best + emit[s];
                back[i][s] = @intCast(best);
            }
        }
        var top: f32 = -std.math.inf(f32);
        for (next) |v| top = @max(top, v);
        for (&next) |*v| v.* -= top;
        delta = next;
    }
    var s: usize = 0;
    for (delta, 0..) |v, j| if (v > delta[s]) {
        s = j;
    };
    var i = n;
    while (i > 0) {
        i -= 1;
        out[i] = chordOf(s);
        s = back[i][s];
    }
    return out;
}

/// The key of everything heard (docs/30 §Chords and key).
pub fn key(ch: *const Chroma) struct { key: u8, scale: tune.Scale } {
    var hist = [_]f32{0} ** 12;
    for (ch.treble) |v| for (v, 0..) |x, pc| {
        hist[pc] += x;
    };
    const k = tune.keyOf(hist);
    return .{ .key = k.key, .scale = k.scale };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const SR: f64 = 48_000;

/// A test signal: chords as a band would hold them, two beats each, the
/// root an octave under, the rest close in octave 3–4, each tone with
/// falling harmonics.
pub fn play(alloc: std.mem.Allocator, prog: []const Chord, beat_sec: f64, cents: f64) ![]f64 {
    const per = beat_sec * 2;
    const n: usize = @intFromFloat(per * @as(f64, @floatFromInt(prog.len)) * SR);
    const x = try alloc.alloc(f64, n);
    @memset(x, 0);
    for (prog, 0..) |ch, ci| {
        var tones: [6]f64 = undefined;
        var nt: usize = 0;
        tones[nt] = 36 + @as(f64, @floatFromInt(ch.root));
        nt += 1;
        for (ch.quality.intervals()) |iv| {
            tones[nt] = 48 + @as(f64, @floatFromInt(ch.root + iv));
            nt += 1;
        }
        const a: usize = @intFromFloat(per * @as(f64, @floatFromInt(ci)) * SR);
        const b: usize = @intFromFloat(per * @as(f64, @floatFromInt(ci + 1)) * SR);
        for (tones[0..nt]) |p| {
            const f = 440 * std.math.pow(f64, 2, (p + cents / 100 - 69) / 12);
            for (a..b) |i| {
                const t = @as(f64, @floatFromInt(i - a)) / SR;
                var v: f64 = 0;
                var h: f64 = 1;
                while (h <= 6) : (h += 1) v += @sin(2 * std.math.pi * f * h * t) / (h * h);
                x[i] += 0.08 * v * @min(1, t / 0.01) * @exp(-t * 0.5);
            }
        }
    }
    return x;
}

fn progression(alloc: std.mem.Allocator, prog: []const Chord, cents: f64) !void {
    const beat = 0.5;
    const x = try play(alloc, prog, beat, cents);
    defer alloc.free(x);
    var ch = try chroma(alloc, x, null, SR);
    defer ch.deinit(alloc);
    try testing.expect(@abs(ch.tuning * 100 - @as(f32, @floatCast(cents))) < 6);
    var edges: [65]f64 = undefined;
    const beats = prog.len * 2;
    for (edges[0 .. beats + 1], 0..) |*e, i| e.* = @as(f64, @floatFromInt(i)) * beat;
    const ps = try perSpan(alloc, &ch, edges[0 .. beats + 1]);
    defer alloc.free(ps.treble);
    defer alloc.free(ps.bass);
    const got = try decode(alloc, ps.treble, ps.bass);
    defer alloc.free(got);
    for (got, 0..) |g, i| {
        const want = prog[i / 2];
        var b1: [8]u8 = undefined;
        var b2: [8]u8 = undefined;
        if (g == null or !g.?.eql(want)) {
            std.debug.print("beat {d}: want {s}, got {s}\n", .{ i, want.name(&b1), if (g) |c| c.name(&b2) else "N" });
            return error.TestUnexpectedResult;
        }
    }
}

test "chords: a I–vi–IV–V, each chord on its beats" {
    try progression(testing.allocator, &.{
        .{ .root = 0, .quality = .maj },
        .{ .root = 9, .quality = .min },
        .{ .root = 5, .quality = .maj },
        .{ .root = 7, .quality = .maj },
        .{ .root = 0, .quality = .maj },
    }, 0);
}

test "chords: sevenths and a band tuned 30 cents sharp" {
    try progression(testing.allocator, &.{
        .{ .root = 2, .quality = .min7 },
        .{ .root = 7, .quality = .dom7 },
        .{ .root = 0, .quality = .maj7 },
        .{ .root = 9, .quality = .min },
    }, 30);
}

test "key: a progression in A minor" {
    const alloc = testing.allocator;
    const x = try play(alloc, &.{
        .{ .root = 9, .quality = .min },
        .{ .root = 2, .quality = .min },
        .{ .root = 4, .quality = .maj },
        .{ .root = 9, .quality = .min },
    }, 0.5, 0);
    defer alloc.free(x);
    var ch = try chroma(alloc, x, null, SR);
    defer ch.deinit(alloc);
    const k = key(&ch);
    try testing.expectEqual(@as(u8, 9), k.key);
    try testing.expectEqual(tune.Scale.minor, k.scale);
}
