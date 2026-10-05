//! Tune (docs/30 §Tune): a voice put in key. What the audio thread needs
//! from a source's pitch track — each frame's pitch, its held pitch and
//! the pitch marks (one per period, on the waveform's peak) — made once on
//! the worker, and the correction at any frame, computed from them with
//! no state, so a seek or a loop costs nothing.

const std = @import("std");
const pitch = @import("pitch.zig");

pub const Scale = enum(u8) {
    chromatic,
    major,
    minor,
    harmonic,
    dorian,
    mixolydian,
    penta_major,
    penta_minor,
    blues,

    /// Its pitch classes from the key, as bits.
    pub fn mask(s: Scale) u12 {
        const steps: []const u4 = switch (s) {
            .chromatic => &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
            .major => &.{ 0, 2, 4, 5, 7, 9, 11 },
            .minor => &.{ 0, 2, 3, 5, 7, 8, 10 },
            .harmonic => &.{ 0, 2, 3, 5, 7, 8, 11 },
            .dorian => &.{ 0, 2, 3, 5, 7, 9, 10 },
            .mixolydian => &.{ 0, 2, 4, 5, 7, 9, 10 },
            .penta_major => &.{ 0, 2, 4, 7, 9 },
            .penta_minor => &.{ 0, 3, 5, 7, 10 },
            .blues => &.{ 0, 3, 5, 6, 7, 10 },
        };
        var m: u12 = 0;
        for (steps) |st| m |= @as(u12, 1) << st;
        return m;
    }

    pub fn label(s: Scale) []const u8 {
        return switch (s) {
            .chromatic => "CHROM",
            .major => "MAJOR",
            .minor => "MINOR",
            .harmonic => "HARM",
            .dorian => "DOR",
            .mixolydian => "MIXO",
            .penta_major => "PENT+",
            .penta_minor => "PENT-",
            .blues => "BLUES",
        };
    }
};

pub const KEYS = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

/// A clip's tune (saved with it).
pub const Settings = struct {
    on: bool = false,
    /// Pitch class of the key, C = 0.
    key: u8 = 0,
    scale: Scale = .chromatic,
    /// How long a correction takes (0: at once, the effect).
    speed_ms: u16 = 20,
    /// How much of the singer's own movement is kept (0..100).
    humanize: u8 = 0,
};

pub const MAX_SPEED_MS = 400;

/// A source's pitch as the audio thread reads it: per 10 ms frame its
/// MIDI pitch and held pitch (0: unvoiced), and the pitch marks in
/// source samples, increasing. Read-only once made.
pub const Tuning = struct {
    midi: []f32 = &.{},
    held: []f32 = &.{},
    marks: []f64 = &.{},

    pub fn deinit(self: *Tuning, alloc: std.mem.Allocator) void {
        alloc.free(self.midi);
        alloc.free(self.held);
        alloc.free(self.marks);
        self.* = .{};
    }
};

/// Frames under this level don't count as sung (−50 dBFS).
const GATE: f32 = 0.00316;

pub fn prepare(alloc: std.mem.Allocator, tr: *const pitch.Track, l: []const f64, r: ?[]const f64, rate: f64) !Tuning {
    const n = tr.len();
    var t = Tuning{
        .midi = try alloc.alloc(f32, n),
        .held = try alloc.alloc(f32, n),
    };
    errdefer t.deinit(alloc);
    for (t.midi, 0..) |*m, k| m.* = if (tr.f0[k] > 0 and tr.rms[k] >= GATE) @floatCast(69 + 12 * std.math.log2(@as(f64, tr.f0[k]) / 440)) else 0;
    // The held pitch: a median over five frames, voiced ones only.
    for (t.held, 0..) |*h, k| {
        if (t.midi[k] == 0) {
            h.* = 0;
            continue;
        }
        var w: [5]f32 = undefined;
        var c: usize = 0;
        for ((k -| 2)..@min(n, k + 3)) |j| if (t.midi[j] != 0) {
            w[c] = t.midi[j];
            c += 1;
        };
        std.mem.sort(f32, w[0..c], {}, std.sort.asc(f32));
        h.* = w[c / 2];
    }
    t.marks = try marks(alloc, tr, t.midi, l, r, rate);
    return t;
}

fn mid(l: []const f64, r: ?[]const f64, i: usize) f64 {
    return if (r) |rr| (l[i] + rr[i]) * 0.5 else l[i];
}

/// One mark per period through each voiced run: the first on the run's
/// highest peak in its first period, each next on the highest peak within
/// a quarter period of where the last one's period puts it.
fn marks(alloc: std.mem.Allocator, tr: *const pitch.Track, midi: []const f32, l: []const f64, r: ?[]const f64, rate: f64) ![]f64 {
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(alloc);
    const per_frame = pitch.HOP_SEC * rate;
    const len = l.len;
    const Peak = struct {
        fn at(ll: []const f64, rr: ?[]const f64, a: usize, b: usize) usize {
            var best = a;
            var v = -std.math.inf(f64);
            for (a..b) |i| {
                const x = mid(ll, rr, i);
                if (x > v) {
                    v = x;
                    best = i;
                }
            }
            return best;
        }
    };
    var k: usize = 0;
    while (k < midi.len) {
        if (midi[k] == 0) {
            k += 1;
            continue;
        }
        const start: usize = @intFromFloat(@as(f64, @floatFromInt(k)) * per_frame);
        if (start >= len) break;
        var period = rate / tr.f0[k];
        var p = Peak.at(l, r, start, @min(len, start + @as(usize, @intFromFloat(@ceil(period)))));
        while (true) {
            // On the peak between samples: a parabola through it.
            var at: f64 = @floatFromInt(p);
            if (p > 0 and p + 1 < len) {
                const a0 = mid(l, r, p - 1);
                const b0 = mid(l, r, p);
                const c0 = mid(l, r, p + 1);
                const den = a0 - 2 * b0 + c0;
                if (den < 0) at += std.math.clamp(0.5 * (a0 - c0) / den, -0.5, 0.5);
            }
            try out.append(alloc, at);
            const pred = @as(f64, @floatFromInt(p)) + period;
            const fk: usize = @intFromFloat(pred / per_frame);
            if (fk >= midi.len or midi[fk] == 0) {
                k = fk + 1;
                break;
            }
            period = rate / tr.f0[fk];
            const q = period / 4;
            const a: usize = @intFromFloat(@max(@as(f64, @floatFromInt(p + 1)), pred - q));
            // The file ends inside the next period: no mark there.
            if (pred + q + 1 >= @as(f64, @floatFromInt(len))) {
                k = midi.len;
                break;
            }
            const b: usize = @as(usize, @intFromFloat(pred + q)) + 1;
            if (a >= b) {
                k = fk + 1;
                break;
            }
            p = Peak.at(l, r, a, b);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The nearest pitch of the scale to `m` (MIDI, fractional).
pub fn snap(m: f32, key: u8, scale_mask: u12) f32 {
    var best: f32 = m;
    var dist: f32 = std.math.inf(f32);
    const base = @floor(m);
    var d: i32 = -6;
    while (d <= 6) : (d += 1) {
        const p = base + @as(f32, @floatFromInt(d));
        const pc: u4 = @intCast(@mod(@as(i32, @intFromFloat(p)) - @as(i32, key), 12));
        if (scale_mask & (@as(u12, 1) << pc) == 0) continue;
        const e = @abs(p - m);
        if (e < dist) {
            dist = e;
            best = p;
        }
    }
    return best;
}

/// What frame `k` is moved by, in semitones: each sung frame's distance
/// from the scale note its held pitch is nearest, smoothed over the last
/// SPEED (an exponential look back, sung frames only), and with HUMANIZE
/// mixed toward the same over 300 ms of this note only, which keeps
/// vibrato and slides and moves only where the note sits.
pub fn correction(t: *const Tuning, k: usize, set: Settings) f32 {
    if (k >= t.midi.len or t.midi[k] == 0) return 0;
    const mask = set.scale.mask();
    const fast = smooth(t, k, @as(f32, @floatFromInt(@min(set.speed_ms, MAX_SPEED_MS))) / 10, set.key, mask, false);
    if (set.humanize == 0) return fast;
    const h = @as(f32, @floatFromInt(@min(set.humanize, 100))) / 100;
    return (1 - h) * fast + h * smooth(t, k, 30, set.key, mask, true);
}

/// `one_note`: look back only while the frames go to the same note.
fn smooth(t: *const Tuning, k: usize, tau: f32, key: u8, mask: u12, one_note: bool) f32 {
    const off = struct {
        fn at(tt: *const Tuning, j: usize, ky: u8, mk: u12) f32 {
            return snap(tt.held[j], ky, mk) - tt.midi[j];
        }
    }.at;
    if (tau < 0.5) return off(t, k, key, mask);
    const target = snap(t.held[k], key, mask);
    const reach: usize = @intFromFloat(@ceil(tau * 3));
    var sum: f32 = 0;
    var wsum: f32 = 0;
    var j = k + 1;
    while (j > 0 and k + 1 - j <= reach) {
        j -= 1;
        if (t.midi[j] == 0) {
            // A breath ends the look back: a new phrase starts in tune.
            break;
        }
        if (one_note and snap(t.held[j], key, mask) != target) break;
        const w = @exp(-@as(f32, @floatFromInt(k - j)) / tau);
        sum += w * off(t, j, key, mask);
        wsum += w;
    }
    return if (wsum > 0) sum / wsum else 0;
}

/// The key a take is sung in, from how long each pitch class is held
/// against the Krumhansl–Kessler profiles: major or minor.
pub fn detectKey(t: *const Tuning) struct { key: u8, scale: Scale } {
    const major = [12]f32{ 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 };
    const minor = [12]f32{ 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 };
    var hist = [_]f32{0} ** 12;
    for (t.held) |h| if (h != 0) {
        hist[@intCast(@mod(@as(i32, @intFromFloat(@round(h))), 12))] += 1;
    };
    var best: struct { key: u8, scale: Scale } = .{ .key = 0, .scale = .chromatic };
    var best_r: f32 = -2;
    for (0..12) |key| for ([_]Scale{ .major, .minor }) |sc| {
        const prof = if (sc == .major) major else minor;
        var mx: f32 = 0;
        var my: f32 = 0;
        for (0..12) |i| {
            mx += hist[(i + key) % 12];
            my += prof[i];
        }
        mx /= 12;
        my /= 12;
        var sxy: f32 = 0;
        var sxx: f32 = 0;
        var syy: f32 = 0;
        for (0..12) |i| {
            const x = hist[(i + key) % 12] - mx;
            const y = prof[i] - my;
            sxy += x * y;
            sxx += x * x;
            syy += y * y;
        }
        if (sxx == 0) continue;
        const rr = sxy / @sqrt(sxx * syy);
        if (rr > best_r) {
            best_r = rr;
            best = .{ .key = @intCast(key), .scale = sc };
        }
    };
    return .{ .key = best.key, .scale = best.scale };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn fake(alloc: std.mem.Allocator, ms: []const f32) !Tuning {
    const midi = try alloc.dupe(f32, ms);
    return .{ .midi = midi, .held = try alloc.dupe(f32, ms), .marks = try alloc.alloc(f64, 0) };
}

test "snap: to the nearest note of the scale" {
    const maj = Scale.major.mask();
    try testing.expectEqual(@as(f32, 60), snap(60.3, 0, maj));
    try testing.expectEqual(@as(f32, 62), snap(61.6, 0, maj));
    // C#, between C and D in C major: whichever is nearer.
    try testing.expectEqual(@as(f32, 62), snap(61.2, 0, maj));
    // A minor's G#, in harmonic minor.
    try testing.expectEqual(@as(f32, 68), snap(67.8, 9, Scale.harmonic.mask()));
    try testing.expectEqual(@as(f32, 61), snap(61.4, 0, Scale.chromatic.mask()));
}

test "correction: hard at speed 0, gradual at a slower one, none in a breath" {
    const alloc = testing.allocator;
    var ms: [40]f32 = undefined;
    for (&ms, 0..) |*m, k| m.* = if (k < 5) 0 else 60.4;
    var t = try fake(alloc, &ms);
    defer t.deinit(alloc);
    try testing.expectEqual(@as(f32, 0), correction(&t, 2, .{ .speed_ms = 0 }));
    try testing.expectApproxEqAbs(@as(f32, -0.4), correction(&t, 10, .{ .speed_ms = 0 }), 1e-5);
    // A steady offset is corrected at any speed: the look back stops at
    // the breath before the note.
    try testing.expectApproxEqAbs(@as(f32, -0.4), correction(&t, 30, .{ .speed_ms = 200 }), 1e-5);
}

test "correction: humanize keeps vibrato, fixes where the note sits" {
    const alloc = testing.allocator;
    var ms: [200]f32 = undefined;
    var held: [200]f32 = undefined;
    for (&ms, &held, 0..) |*m, *h, k| {
        m.* = 60.3 + 0.4 * @sin(2 * std.math.pi * 5.5 * @as(f32, @floatFromInt(k)) * 0.01);
        h.* = 60.3;
    }
    var t = try fake(alloc, &ms);
    defer t.deinit(alloc);
    @memcpy(t.held, &held);
    var hard_dev: f32 = 0;
    var human_dev: f32 = 0;
    for (100..200) |k| {
        hard_dev = @max(hard_dev, @abs(ms[k] + correction(&t, k, .{ .speed_ms = 0 }) - 60));
        human_dev = @max(human_dev, @abs(ms[k] + correction(&t, k, .{ .speed_ms = 0, .humanize = 100 }) - 60));
    }
    try testing.expect(hard_dev < 1e-4);
    // The vibrato stays (±0.4 less what the 300 ms look back catches), centered on C.
    try testing.expect(human_dev > 0.3 and human_dev < 0.5);
}

test "detectKey: a line in A minor" {
    const alloc = testing.allocator;
    const line = [_]f32{ 69, 72, 76, 74, 72, 71, 69, 64, 69, 76, 77, 76, 74, 72, 71, 69 };
    var ms: [line.len * 10]f32 = undefined;
    for (&ms, 0..) |*m, k| m.* = line[k / 10];
    var t = try fake(alloc, &ms);
    defer t.deinit(alloc);
    const k = detectKey(&t);
    try testing.expectEqual(@as(u8, 9), k.key);
    try testing.expectEqual(Scale.minor, k.scale);
}

test "marks: one a period, on the peaks" {
    const alloc = testing.allocator;
    const sr: f64 = 48_000;
    const x = try alloc.alloc(f64, @intFromFloat(sr * 0.5));
    defer alloc.free(x);
    for (x, 0..) |*v, i| {
        const ph = @as(f64, @floatFromInt(i)) * 200 / sr;
        v.* = 0.3 * (@sin(2 * std.math.pi * ph) + 0.5 * @sin(4 * std.math.pi * ph + 1));
    }
    var tr = try pitch.track(alloc, x, null, sr, .voice);
    defer tr.deinit(alloc);
    var t = try prepare(alloc, &tr, x, null, sr);
    defer t.deinit(alloc);
    try testing.expect(t.marks.len > 80);
    for (t.marks[1..], t.marks[0 .. t.marks.len - 1]) |b, a| try testing.expectApproxEqAbs(@as(f64, 240), b - a, 2);
}
