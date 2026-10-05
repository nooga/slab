//! Pitch (docs/30 §The pitch tracker): one voice's fundamental over time,
//! by pYIN — YIN's dips weighed under a prior over thresholds, then a
//! Viterbi path through pitch and voicing — and the notes it sings
//! (docs/30 §Notes from the pitch). Runs on a worker thread, never on the
//! audio thread.

const std = @import("std");
const fft = @import("fft.zig");
const warp = @import("warp.zig");
const C = fft.C;

/// The tracker's own rate: a voice's or a bass's fundamental is under
/// 2 kHz, and a frame here costs a ninth of one at 48.
pub const RATE: f64 = 16_000;
/// A frame (64 ms: two periods of the lowest pitch) and the hop (10 ms).
pub const W = 1024;
pub const HOP = 160;
pub const HOP_SEC: f64 = HOP / RATE;
const NFFT = 2048;
const F = fft.Fft(NFFT);
/// The longest lag: the period of C1, rounded up.
const TAU_MAX = 490;
/// The level's window (20 ms).
const LEVEL = 320;

/// Bins are 20 cents from C1 up to C7.
pub const F_MIN: f64 = 32.703195662574829;
const PER_SEMI = 5;
const NBINS = 6 * 12 * PER_SEMI;
/// How far a voiced path moves per frame (5 semitones), and what it costs
/// to start or stop being voiced.
const MAX_STEP = 25;
const SWITCH: f64 = 0.01;
const THRESHOLDS = 100;
/// What a frame with no dip under a threshold gives its deepest one.
const NO_TROUGH: f64 = 0.01;
/// Candidates kept per frame.
const CANDS = 8;
/// Frames decoded per Viterbi pass (its backpointers' memory).
const CHUNK = 4096;

pub const Range = enum(u8) {
    any,
    bass,
    voice,

    pub fn hz(r: Range) [2]f64 {
        return switch (r) {
            .any => .{ F_MIN, 2093 },
            .bass => .{ F_MIN, 400 },
            .voice => .{ 65, 1600 },
        };
    }
};

/// Per 10 ms frame, from the source's start.
pub const Track = struct {
    /// Hz, 0 where unvoiced.
    f0: []f32 = &.{},
    /// How sure the frame is voiced: the weight its dips got, 0..1.
    voicing: []f32 = &.{},
    /// The level over the frame's middle 20 ms.
    rms: []f32 = &.{},

    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        alloc.free(self.f0);
        alloc.free(self.voicing);
        alloc.free(self.rms);
        self.* = .{};
    }

    pub fn len(self: *const Track) usize {
        return self.f0.len;
    }
};

const Cand = struct { bin: i16 = -1, hz: f32 = 0, p: f32 = 0 };

/// The prior over thresholds, Beta(2, 18) (mean 0.1), on 0.01..1.00.
const PRIOR: [THRESHOLDS]f64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [THRESHOLDS]f64 = undefined;
    var sum: f64 = 0;
    for (&t, 0..) |*v, i| {
        const s = @as(f64, @floatFromInt(i + 1)) / THRESHOLDS;
        var q: f64 = 1;
        for (0..17) |_| q *= 1 - s;
        v.* = s * q;
        sum += v.*;
    }
    for (&t) |*v| v.* /= sum;
    break :blk t;
};

fn binOf(hz: f64) i32 {
    return @intFromFloat(@round(12.0 * PER_SEMI * std.math.log2(hz / F_MIN)));
}

fn hzOf(bin: i32) f64 {
    return F_MIN * std.math.pow(f64, 2, @as(f64, @floatFromInt(bin)) / (12.0 * PER_SEMI));
}

/// Down to the tracker's rate through the band-limited reader, as mid.
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

/// One frame's candidates (the most likely CANDS dips), its voicing and
/// RMS. `x` is the whole signal; the frame is centered on `center`.
fn frame(x: []const f32, center: isize, lo: f64, hi: f64, buf: *[NFFT]C, prod: *[NFFT]C, out: *[CANDS]Cand) struct { voicing: f32, rms: f32 } {
    const start = center - W / 2;
    const seg = W + TAU_MAX;
    var e: [seg + 1]f64 = undefined;
    e[0] = 0;
    for (0..NFFT) |j| {
        const i = start + @as(isize, @intCast(j));
        const v: f32 = if (j < seg and i >= 0 and i < @as(isize, @intCast(x.len))) x[@intCast(i)] else 0;
        buf[j] = .{ .re = if (j < W) v else 0, .im = v };
        if (j < seg) e[j + 1] = e[j] + @as(f64, v) * v;
    }
    const e0 = e[W];
    // The level over the frame's middle 20 ms, quick enough to see a
    // syllable sung again.
    const rms: f32 = @floatCast(@sqrt((e[W / 2 + LEVEL / 2] - e[W / 2 - LEVEL / 2]) / LEVEL));
    for (out) |*cd| cd.* = .{};
    if (e0 < 1e-10) return .{ .voicing = 0, .rms = rms };

    // Both spectra from one transform, then their cross-correlation.
    F.forward(buf);
    for (0..NFFT) |k| {
        const z = buf[k];
        const zc = buf[(NFFT - k) % NFFT].conj();
        const a = z.add(zc).scale(0.5);
        const d = z.sub(zc);
        const b = C{ .re = d.im * 0.5, .im = -d.re * 0.5 };
        prod[k] = a.conj().mul(b);
    }
    F.inverse(prod);

    // YIN's cumulative mean normalized difference.
    var dn: [TAU_MAX + 1]f64 = undefined;
    dn[0] = 1;
    var sum: f64 = 0;
    for (1..TAU_MAX + 1) |tau| {
        const d = @max(0, e0 + (e[tau + W] - e[tau]) - 2 * @as(f64, prod[tau].re));
        sum += d;
        dn[tau] = if (sum > 0) d * @as(f64, @floatFromInt(tau)) / sum else 1;
    }

    // The dips in range.
    const t_lo: usize = @max(2, @as(usize, @intFromFloat(@floor(RATE / hi))));
    const t_hi: usize = @min(TAU_MAX - 1, @as(usize, @intFromFloat(@ceil(RATE / lo))));
    var tr: [64]usize = undefined;
    var nt: usize = 0;
    var tau = t_lo;
    while (tau <= t_hi and nt < tr.len) : (tau += 1) {
        if (dn[tau] < dn[tau - 1] and dn[tau] <= dn[tau + 1]) {
            tr[nt] = tau;
            nt += 1;
        }
    }
    if (nt == 0) return .{ .voicing = 0, .rms = rms };
    var gmin: usize = 0;
    for (tr[0..nt], 0..) |t, i| if (dn[t] < dn[tr[gmin]]) {
        gmin = i;
    };
    var p: [64]f64 = [_]f64{0} ** 64;
    for (PRIOR, 0..) |w, i| {
        const s = @as(f64, @floatFromInt(i + 1)) / THRESHOLDS;
        var hit: ?usize = null;
        for (tr[0..nt], 0..) |t, k| if (dn[t] < s) {
            hit = k;
            break;
        };
        if (hit) |k| p[k] += w else p[gmin] += w * NO_TROUGH;
    }

    // To bins, each dip refined by a parabola through it.
    var voicing: f64 = 0;
    for (tr[0..nt], 0..) |t, k| {
        if (p[k] <= 0) continue;
        voicing += p[k];
        const a = dn[t - 1];
        const b = dn[t];
        const c = dn[t + 1];
        const den = a - 2 * b + c;
        const tf = @as(f64, @floatFromInt(t)) + (if (den > 1e-12) std.math.clamp(0.5 * (a - c) / den, -0.5, 0.5) else 0);
        const hz = RATE / tf;
        const bin = binOf(hz);
        if (bin < 0 or bin >= NBINS) continue;
        // Into the top CANDS, merging a bin met twice.
        var slot: ?usize = null;
        for (out, 0..) |*cd, i| if (cd.bin == bin) {
            slot = i;
            break;
        };
        if (slot) |i| {
            out[i].p += @floatCast(p[k]);
            continue;
        }
        var low: usize = 0;
        for (out, 0..) |cd, i| if (cd.p < out[low].p) {
            low = i;
        };
        if (p[k] > out[low].p) out[low] = .{ .bin = @intCast(bin), .hz = @floatCast(hz), .p = @floatCast(p[k]) };
    }
    return .{ .voicing = @floatCast(@min(1, voicing)), .rms = rms };
}

/// The pitch of `l` (and `r`, its right channel, when stereo) at `rate`.
pub fn track(alloc: std.mem.Allocator, l: []const f64, r: ?[]const f64, rate: f64, range: Range) !Track {
    const x = try downsample(alloc, l, r, rate);
    defer alloc.free(x);
    const frames = x.len / HOP + 1;
    var out = Track{
        .f0 = try alloc.alloc(f32, frames),
        .voicing = try alloc.alloc(f32, frames),
        .rms = try alloc.alloc(f32, frames),
    };
    errdefer out.deinit(alloc);

    const hz = range.hz();
    const b_lo: usize = @intCast(@max(0, binOf(hz[0])));
    const b_hi: usize = @intCast(@min(NBINS - 1, binOf(hz[1])));
    const nb = b_hi - b_lo + 1;
    const ns = nb * 2;

    const cands = try alloc.alloc([CANDS]Cand, @min(frames, CHUNK));
    defer alloc.free(cands);
    const back = try alloc.alloc(u16, @min(frames, CHUNK) * ns);
    defer alloc.free(back);
    var delta = try alloc.alloc(f64, ns);
    defer alloc.free(delta);
    var next = try alloc.alloc(f64, ns);
    defer alloc.free(next);
    const obs_v = try alloc.alloc(f64, nb);
    defer alloc.free(obs_v);

    // Pitch moves cheaper the less it moves; voicing mostly stays.
    var lt: [MAX_STEP + 1]f64 = undefined;
    {
        var s: f64 = 0;
        for (0..MAX_STEP + 1) |d| s += @as(f64, @floatFromInt(if (d == 0) MAX_STEP + 1 else 2 * (MAX_STEP + 1 - d)));
        for (&lt, 0..) |*v, d| v.* = @log(@as(f64, @floatFromInt(MAX_STEP + 1 - d)) / s);
    }
    const stay = @log(1 - SWITCH);
    const sw = @log(SWITCH);
    const floor_p = 1e-12;

    @memset(delta, -@log(@as(f64, @floatFromInt(ns))));
    var buf: [NFFT]C = undefined;
    var prod: [NFFT]C = undefined;
    var c0: usize = 0;
    while (c0 < frames) : (c0 += CHUNK) {
        const n = @min(CHUNK, frames - c0);
        for (0..n) |ci| {
            const k = c0 + ci;
            const fr = frame(x, @intCast(k * HOP), hz[0], hz[1], &buf, &prod, &cands[ci]);
            out.voicing[k] = fr.voicing;
            out.rms[k] = fr.rms;
            @memset(obs_v, floor_p);
            for (cands[ci]) |cd| if (cd.p > 0 and cd.bin >= b_lo and cd.bin <= b_hi) {
                obs_v[@as(usize, @intCast(cd.bin)) - b_lo] += cd.p;
            };
            const obs_u = @log(@max(floor_p, (1 - @as(f64, fr.voicing)) / @as(f64, @floatFromInt(nb))));
            const bk = back[ci * ns ..][0..ns];
            var best_any: f64 = -std.math.inf(f64);
            for (0..nb) |b| {
                const lo_b = b -| MAX_STEP;
                const hi_b = @min(nb - 1, b + MAX_STEP);
                var m0: f64 = -std.math.inf(f64);
                var a0: usize = 0;
                var m1: f64 = -std.math.inf(f64);
                var a1: usize = 0;
                for (lo_b..hi_b + 1) |j| {
                    const t = lt[if (j > b) j - b else b - j];
                    const u = delta[j * 2] + t;
                    if (u > m0) {
                        m0 = u;
                        a0 = j * 2;
                    }
                    const v = delta[j * 2 + 1] + t;
                    if (v > m1) {
                        m1 = v;
                        a1 = j * 2 + 1;
                    }
                }
                // State b·2: unvoiced, b·2 + 1: voiced.
                if (m0 + stay >= m1 + sw) {
                    next[b * 2] = m0 + stay + obs_u;
                    bk[b * 2] = @intCast(a0);
                } else {
                    next[b * 2] = m1 + sw + obs_u;
                    bk[b * 2] = @intCast(a1);
                }
                const ov = @log(obs_v[b]);
                if (m1 + stay >= m0 + sw) {
                    next[b * 2 + 1] = m1 + stay + ov;
                    bk[b * 2 + 1] = @intCast(a1);
                } else {
                    next[b * 2 + 1] = m0 + sw + ov;
                    bk[b * 2 + 1] = @intCast(a0);
                }
                best_any = @max(best_any, @max(next[b * 2], next[b * 2 + 1]));
            }
            // Kept near zero so a long take doesn't run out of range.
            for (next) |*v| v.* -= best_any;
            std.mem.swap([]f64, &delta, &next);
        }

        // Back through this chunk from its likeliest end.
        var s: usize = 0;
        for (delta, 0..) |v, i| if (v > delta[s]) {
            s = i;
        };
        var ci = n;
        while (ci > 0) {
            ci -= 1;
            const k = c0 + ci;
            if (s % 2 == 1) {
                const bin: i32 = @intCast(s / 2 + b_lo);
                // The nearest dip's own frequency, else the bin's.
                var f: f64 = hzOf(bin);
                var dist: i32 = 3;
                for (cands[ci]) |cd| if (cd.p > 0) {
                    const dd: i32 = @intCast(@abs(@as(i32, cd.bin) - bin));
                    if (dd < dist) {
                        dist = dd;
                        f = cd.hz;
                    }
                };
                out.f0[k] = @floatCast(f);
            } else out.f0[k] = 0;
            s = back[ci * ns + s];
        }
    }
    return out;
}

// ── Notes ────────────────────────────────────────────────────────────

pub const Note = struct {
    /// Seconds into the source.
    sec: f64,
    end: f64,
    pitch: u8,
    velocity: u8,
};

pub const Notes = struct {
    notes: []Note = &.{},
    /// The take's own A against A440, in cents (0 with `a440`).
    cents: f32 = 0,

    pub fn deinit(self: *Notes, alloc: std.mem.Allocator) void {
        alloc.free(self.notes);
        self.* = .{};
    }
};

/// Frames under this are left out (−50 dBFS).
const GATE: f32 = 0.00316;
/// A note's shortest, a gap bridged inside one, and how long another
/// pitch has to hold to start a new note: in frames.
const MIN_FRAMES = 6;
const GAP_FRAMES = 3;
const HOLD_FRAMES = 6;
/// How far the held pitch has to move from a note's to count as another.
const MOVE: f64 = 0.65;
/// The longest a scoop into a note can be.
const SCOOP_FRAMES = 15;

fn midiOf(hz: f32) f64 {
    return 69 + 12 * std.math.log2(@as(f64, hz) / 440);
}

fn medianOf(v: []f64) f64 {
    std.mem.sort(f64, v, {}, std.sort.asc(f64));
    return if (v.len % 2 == 1) v[v.len / 2] else (v[v.len / 2 - 1] + v[v.len / 2]) * 0.5;
}

/// Whether frames `k0..k1` only pass through `p`, their note's pitch:
/// shorter than SCOOP_FRAMES, under half of them within 0.3 of it.
fn gliding(m: []const f64, voiced: []const bool, k0: usize, k1: usize, p: f64) bool {
    if (k1 - k0 >= SCOOP_FRAMES) return false;
    var held: usize = 0;
    var all: usize = 0;
    for (k0..k1) |j| if (voiced[j]) {
        all += 1;
        if (@abs(m[j] - p) < 0.3) held += 1;
    };
    return held * 2 < all;
}

/// The notes a pitch track sings. `onsets` (seconds, with their
/// strengths) start a new note inside one; `a440` keeps the reference
/// at A440 instead of the take's own tuning.
pub fn notes(alloc: std.mem.Allocator, tr: *const Track, onsets: ?[]const f64, strength: ?[]const f32, a440: bool) !Notes {
    const n = tr.len();
    const m = try alloc.alloc(f64, n);
    defer alloc.free(m);
    const voiced = try alloc.alloc(bool, n);
    defer alloc.free(voiced);
    for (0..n) |k| {
        voiced[k] = tr.f0[k] > 0 and tr.rms[k] >= GATE;
        m[k] = if (voiced[k]) midiOf(tr.f0[k]) else 0;
    }

    // The take's reference: the circular mean of every voiced frame's
    // distance from its nearest semitone.
    var ref: f64 = 0;
    if (!a440) {
        var sx: f64 = 0;
        var sy: f64 = 0;
        for (0..n) |k| if (voiced[k]) {
            const w: f64 = tr.rms[k];
            const a = 2 * std.math.pi * m[k];
            sx += w * @cos(a);
            sy += w * @sin(a);
        };
        if (sx != 0 or sy != 0) ref = std.math.atan2(sy, sx) / (2 * std.math.pi);
    }
    for (0..n) |k| if (voiced[k]) {
        m[k] -= ref;
    };

    // The held pitch: a median over five frames, voiced ones only.
    const med = try alloc.alloc(f64, n);
    defer alloc.free(med);
    for (0..n) |k| {
        var w: [5]f64 = undefined;
        var c: usize = 0;
        const a = k -| 2;
        for (a..@min(n, k + 3)) |j| if (voiced[j]) {
            w[c] = m[j];
            c += 1;
        };
        med[k] = if (c >= 3) medianOf(w[0..c]) else m[k];
    }

    // Onsets, as frames that start a note inside one.
    const cut = try alloc.alloc(bool, n);
    defer alloc.free(cut);
    @memset(cut, false);
    if (onsets) |os| for (os, 0..) |s, i| {
        if (strength) |st| if (st[i] < 0.3) continue;
        const k: usize = @intFromFloat(@max(0, @round(s / HOP_SEC)));
        if (k < n) cut[k] = true;
    };

    var list: std.ArrayList(Note) = .empty;
    errdefer list.deinit(alloc);
    var scratch: std.ArrayList(f64) = .empty;
    defer scratch.deinit(alloc);

    const Open = struct { k0: usize, last: usize, p: f64, cand: ?f64 = null, kc: usize = 0 };
    var open: ?Open = null;
    const close = struct {
        fn f(a: std.mem.Allocator, l: *std.ArrayList(Note), sc: *std.ArrayList(f64), mm: []const f64, vv: []const bool, rms: []const f32, k0: usize, k1: usize) !void {
            if (k1 - k0 < MIN_FRAMES) return;
            sc.clearRetainingCapacity();
            var peak: f32 = 0;
            for (k0..k1) |j| if (vv[j]) {
                try sc.append(a, mm[j]);
                peak = @max(peak, rms[j]);
            };
            if (sc.items.len == 0) return;
            const p = @round(medianOf(sc.items));
            if (p < 0 or p > 127) return;
            const db = 20 * std.math.log10(@max(1e-6, @as(f64, peak)));
            try l.append(a, .{
                .sec = @as(f64, @floatFromInt(k0)) * HOP_SEC,
                .end = @as(f64, @floatFromInt(k1)) * HOP_SEC,
                .pitch = @intFromFloat(p),
                .velocity = @intFromFloat(std.math.clamp(30 + (db + 40) / 34 * 90, 1, 127)),
            });
        }
    }.f;

    for (0..n) |k| {
        if (!voiced[k]) {
            if (open) |o| if (k - o.last > GAP_FRAMES) {
                try close(alloc, &list, &scratch, m, voiced, tr.rms, o.k0, o.last + 1);
                open = null;
            };
            continue;
        }
        if (open == null) {
            open = .{ .k0 = k, .last = k, .p = @round(med[k]) };
            continue;
        }
        var o = &open.?;
        const age = k - o.k0;
        // A re-sung syllable: an onset, or 6 dB up within 40 ms.
        var rise = false;
        if (age >= MIN_FRAMES) {
            var lo: f32 = std.math.inf(f32);
            for ((k -| 4)..k) |j| lo = @min(lo, tr.rms[j]);
            rise = cut[k] or tr.rms[k] >= 2 * lo;
        }
        if (rise or k - o.last > 1) {
            if (rise) {
                try close(alloc, &list, &scratch, m, voiced, tr.rms, o.k0, k);
                open = .{ .k0 = k, .last = k, .p = @round(med[k]) };
                continue;
            }
        }
        o.last = k;
        if (@abs(med[k] - o.p) > MOVE) {
            const q = @round(med[k]);
            if (o.cand != null and o.cand.? == q) {
                if (k - o.kc >= HOLD_FRAMES) {
                    const kc = o.kc;
                    // A scoop into the note is part of it, not one before it.
                    if (gliding(m, voiced, o.k0, kc, o.p)) {
                        open = .{ .k0 = o.k0, .last = k, .p = q };
                    } else {
                        try close(alloc, &list, &scratch, m, voiced, tr.rms, o.k0, kc);
                        open = .{ .k0 = kc, .last = k, .p = q };
                    }
                }
            } else {
                o.cand = q;
                o.kc = k;
            }
        } else o.cand = null;
    }
    if (open) |o| try close(alloc, &list, &scratch, m, voiced, tr.rms, o.k0, o.last + 1);

    return .{ .notes = try list.toOwnedSlice(alloc), .cents = @floatCast(ref * 100) };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const SR: f64 = 48_000;

/// A voice-ish tone: harmonics falling 6 dB an octave, through a formant
/// bump, at `hz(t)`.
fn sing(x: []f64, from: usize, to: usize, hz: *const fn (f64) f64, amp: f64, phase: *f64) void {
    for (from..to) |i| {
        const t = @as(f64, @floatFromInt(i)) / SR;
        const f = hz(t);
        phase.* += f / SR;
        var v: f64 = 0;
        var h: f64 = 1;
        while (h * f < 6000) : (h += 1) {
            const formant = 1 + 2 * @exp(-std.math.pow(f64, (h * f - 700) / 300, 2));
            v += formant / h * @sin(2 * std.math.pi * h * phase.*);
        }
        // Soft edges, so a note starts like a sung one.
        const edge = @min(1, @min(@as(f64, @floatFromInt(i - from)), @as(f64, @floatFromInt(to - i))) / (0.01 * SR));
        x[i] += amp * 0.3 * v * edge;
    }
}

fn midiHz(p: f64) f64 {
    return 440 * std.math.pow(f64, 2, (p - 69) / 12);
}

test "track: a steady tone's pitch within 5 cents, unvoiced around it" {
    const alloc = testing.allocator;
    const x = try alloc.alloc(f64, @intFromFloat(SR * 1.5));
    defer alloc.free(x);
    @memset(x, 0);
    var ph: f64 = 0;
    sing(x, @intFromFloat(SR * 0.25), @intFromFloat(SR * 1.25), &struct {
        fn f(_: f64) f64 {
            return 196;
        }
    }.f, 0.5, &ph);
    var tr = try track(alloc, x, null, SR, .any);
    defer tr.deinit(alloc);
    var voiced: usize = 0;
    for (tr.f0, 0..) |f, k| {
        const t = @as(f64, @floatFromInt(k)) * HOP_SEC;
        if (t > 0.35 and t < 1.15) {
            try testing.expect(f > 0);
            try testing.expect(@abs(1200 * std.math.log2(f / 196.0)) < 5);
            voiced += 1;
        }
        if (t < 0.15 or t > 1.4) try testing.expectEqual(@as(f32, 0), f);
    }
    try testing.expect(voiced > 70);
}

test "track: a bass line an octave apart, not an octave off" {
    const alloc = testing.allocator;
    const x = try alloc.alloc(f64, @intFromFloat(SR * 1.2));
    defer alloc.free(x);
    @memset(x, 0);
    var ph: f64 = 0;
    sing(x, 0, @intFromFloat(SR * 0.6), &struct {
        fn f(_: f64) f64 {
            return 55;
        }
    }.f, 0.5, &ph);
    sing(x, @intFromFloat(SR * 0.6), @intFromFloat(SR * 1.2), &struct {
        fn f(_: f64) f64 {
            return 110;
        }
    }.f, 0.5, &ph);
    var tr = try track(alloc, x, null, SR, .bass);
    defer tr.deinit(alloc);
    const a = tr.f0[@intFromFloat(0.3 / HOP_SEC)];
    const b = tr.f0[@intFromFloat(0.9 / HOP_SEC)];
    try testing.expectApproxEqRel(@as(f32, 55), a, 0.01);
    try testing.expectApproxEqRel(@as(f32, 110), b, 0.01);
}

test "notes: a hummed line, 30 cents flat, comes out on its keys" {
    const alloc = testing.allocator;
    const line = [_]u8{ 60, 62, 64, 65, 67, 67, 64 };
    const dur = 0.35;
    const x = try alloc.alloc(f64, @intFromFloat(SR * (dur * @as(f64, @floatFromInt(line.len)) + 0.3)));
    defer alloc.free(x);
    @memset(x, 0);
    var ph: f64 = 0;
    for (line, 0..) |p, i| {
        const Ctx = struct {
            var hz: f64 = 0;
            fn f(_: f64) f64 {
                return hz;
            }
        };
        Ctx.hz = midiHz(@as(f64, @floatFromInt(p)) - 0.3);
        const a: usize = @intFromFloat(SR * (0.1 + dur * @as(f64, @floatFromInt(i))));
        // A breath between the two Gs, so they're two notes.
        const b: usize = a + @as(usize, @intFromFloat(SR * (dur - 0.06)));
        sing(x, a, b, &Ctx.f, 0.4, &ph);
    }
    var tr = try track(alloc, x, null, SR, .voice);
    defer tr.deinit(alloc);
    var ns = try notes(alloc, &tr, null, null, false);
    defer ns.deinit(alloc);
    try testing.expectEqual(line.len, ns.notes.len);
    for (ns.notes, line, 0..) |nt, p, i| {
        try testing.expectEqual(p, nt.pitch);
        const t0 = 0.1 + dur * @as(f64, @floatFromInt(i));
        try testing.expect(@abs(nt.sec - t0) < 0.04);
        try testing.expect(@abs(nt.end - (t0 + dur - 0.06)) < 0.05);
    }
    try testing.expect(@abs(ns.cents + 30) < 5);
}

test "notes: vibrato and a scoop stay one note" {
    const alloc = testing.allocator;
    const x = try alloc.alloc(f64, @intFromFloat(SR * 1.4));
    defer alloc.free(x);
    @memset(x, 0);
    var ph: f64 = 0;
    sing(x, @intFromFloat(SR * 0.1), @intFromFloat(SR * 1.3), &struct {
        fn f(t: f64) f64 {
            // An 80 ms scoop up from a semitone under, then ±40 ct at
            // 5.5 Hz, coming in as the note settles.
            const scoop = if (t < 0.18) -1 + (t - 0.1) / 0.08 else 0;
            const vib = 0.4 * @min(1, @max(0, (t - 0.25) / 0.15)) * @sin(2 * std.math.pi * 5.5 * (t - 0.25));
            return midiHz(69 + scoop + vib);
        }
    }.f, 0.4, &ph);
    var tr = try track(alloc, x, null, SR, .voice);
    defer tr.deinit(alloc);
    var ns = try notes(alloc, &tr, null, null, true);
    defer ns.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), ns.notes.len);
    try testing.expectEqual(@as(u8, 69), ns.notes[0].pitch);
}

test "notes: noise and silence sing nothing" {
    const alloc = testing.allocator;
    const x = try alloc.alloc(f64, @intFromFloat(SR * 1.0));
    defer alloc.free(x);
    var rng = std.Random.DefaultPrng.init(5);
    for (x, 0..) |*v, i| v.* = if (i < x.len / 2) 0 else (rng.random().float(f64) - 0.5) * 0.3;
    var tr = try track(alloc, x, null, SR, .any);
    defer tr.deinit(alloc);
    var ns = try notes(alloc, &tr, null, null, false);
    defer ns.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), ns.notes.len);
}

test "notes: a short grace note is its own, a re-sung syllable splits" {
    const alloc = testing.allocator;
    const x = try alloc.alloc(f64, @intFromFloat(SR * 1.3));
    defer alloc.free(x);
    @memset(x, 0);
    var ph: f64 = 0;
    sing(x, @intFromFloat(SR * 0.1), @intFromFloat(SR * 1.2), &struct {
        fn f(t: f64) f64 {
            return midiHz(if (t < 0.22) 67 else 69);
        }
    }.f, 0.4, &ph);
    // A dip to −20 dB for 40 ms at 0.7 s, legato: the same A sung again.
    for (@as(usize, @intFromFloat(SR * 0.68))..@as(usize, @intFromFloat(SR * 0.72))) |i| x[i] *= 0.1;
    var tr = try track(alloc, x, null, SR, .voice);
    defer tr.deinit(alloc);
    var ns = try notes(alloc, &tr, null, null, true);
    defer ns.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), ns.notes.len);
    try testing.expectEqual(@as(u8, 67), ns.notes[0].pitch);
    try testing.expectEqual(@as(u8, 69), ns.notes[1].pitch);
    try testing.expectEqual(@as(u8, 69), ns.notes[2].pitch);
    try testing.expect(@abs(ns.notes[2].sec - 0.71) < 0.04);
}
