//! MIX (docs/29 §MIX): a phase vocoder that stretches in real time on the
//! audio thread. Output frames sit on a grid anchored at the clip's start,
//! one hop apart; each analyzes the source around where the maps put it,
//! plus a twin frame one hop back for each bin's frequency, so nothing
//! about the stretch ratio has to be remembered: it may change every
//! frame, and a jump costs one frame and a phase reset. Phases are locked
//! to the spectrum's peaks (identity locking), reset at transients, and
//! both channels turn with the mid so the image stays put. The same
//! stretcher runs VOICE's grains (docs/29 §VOICE) and Tune's
//! pitch-synchronous ones (docs/30 §Tune).
//!
//! A `Stretcher` is plain memory: the UI thread allocates a `Bank` of
//! them for a track (`Track.publishSnapshot`) and frees it with the track;
//! the audio thread only reuses them.

const std = @import("std");
const fft = @import("fft.zig");
const warp = @import("warp.zig");

const C = fft.C;
pub const N = 4096;
pub const H = N / 4;
const BINS = N / 2 + 1;
const F = fft.Fft(N);
const TAU: f32 = 2 * std.math.pi;

const WINDOW: [N]f32 = blk: {
    @setEvalBranchQuota(10_000_000);
    var w: [N]f32 = undefined;
    for (&w, 0..) |*v, i| v.* = @floatCast(0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / N));
    break :blk w;
};
/// A Hann window analyzing and again synthesizing, four frames deep, sums
/// to 1.5.
const OLA_GAIN: f32 = 1.0 / 1.5;

/// What a stretcher reads: a source, mono or stereo, read mirrored when
/// reversed. Positions are in source samples in the clip's direction.
pub const Source = struct {
    l: [*]const f64,
    r: ?[*]const f64,
    len: usize,
    reversed: bool,
    /// Its sample rate.
    rate: f64 = 48_000,

    fn exact(self: Source, x: i64) [2]f32 {
        const i = if (self.reversed) @as(i64, @intCast(self.len)) - 1 - x else x;
        if (i < 0 or i >= @as(i64, @intCast(self.len))) return .{ 0, 0 };
        const u: usize = @intCast(i);
        const l: f32 = @floatCast(self.l[u]);
        return .{ l, if (self.r) |r| @floatCast(r[u]) else l };
    }

    fn at(self: Source, x: f64, step: f64) [2]f32 {
        const p = if (self.reversed) @as(f64, @floatFromInt(self.len)) - 1 - x else x;
        return warp.read(self.l, self.r, self.len, p, step);
    }
};

/// What a stretcher runs: MIX's vocoder frames, VOICE's grains, or
/// Tune's pitch-synchronous ones (docs/30 §Tune).
pub const Kind = enum(u8) { mix, voice, tune };

/// Tune: how far ahead of the playhead its grains are made, which bounds
/// a grain's half (a period of 47 Hz at 48 kHz).
pub const TUNE_REACH = 1024;

/// Where Tune's next grain comes from (`ctx.tuneAt`): its center in the
/// source (a pitch mark when sung), a period there in source samples, and
/// the pitch it plays at against the source's (1: as sung).
pub const TuneGrain = struct { center: f64, period: f64, beta: f64 };

/// VOICE's grains, in output samples (10–80 ms at 48 kHz, even, within
/// the ring).
pub const MIN_GRAIN = 480;
pub const MAX_GRAIN = 3840;

pub const Stretcher = struct {
    /// The clip it plays (0: free) and the last call it played in.
    uid: u32 = 0,
    kind: Kind = .mix,
    /// Frame length and hop in output samples: N and H for MIX, a grain and
    /// half of it for VOICE.
    span: i64 = N,
    hop: i64 = H,
    /// VOICE: where the last grain was read, centered (source samples).
    q_prev: f64 = 0,
    /// Tune: the output sample its next grain is centered on.
    next_t: f64 = 0,
    used: u64 = 0,
    live: bool = false,
    /// The output sample it expects next, the frame grid's origin, and
    /// the next frame to make.
    next_a: i64 = 0,
    t0: i64 = 0,
    m: i64 = 0,
    reset_phase: bool = true,
    prev_pos: f64 = 0,
    /// Output phases (the mid's), per bin.
    psi: [BINS]f32 = [_]f32{0} ** BINS,
    ring_l: [N]f32 = [_]f32{0} ** N,
    ring_r: [N]f32 = [_]f32{0} ** N,
    bl: [N]C = undefined,
    br: [N]C = undefined,
    mag: [BINS]f32 = undefined,
    ph: [BINS]f32 = undefined,
    peaks: [N / 4]u16 = undefined,
    peak_psi: [N / 4]f32 = undefined,

    pub fn claim(self: *Stretcher, uid: u32, t0: i64, kind: Kind, grain: i64) void {
        self.uid = uid;
        self.t0 = t0;
        self.kind = kind;
        self.span = switch (kind) {
            .mix => N,
            .voice => std.math.clamp(grain & ~@as(i64, 1), MIN_GRAIN, MAX_GRAIN),
            .tune => 2 * TUNE_REACH,
        };
        self.hop = if (kind == .mix) H else @divExact(self.span, 2);
        self.live = false;
    }

    fn fits(self: *const Stretcher, t0: i64, kind: Kind, grain: i64) bool {
        if (self.t0 != t0 or self.kind != kind) return false;
        return kind != .voice or self.span == std.math.clamp(grain & ~@as(i64, 1), MIN_GRAIN, MAX_GRAIN);
    }

    fn frameT(self: *const Stretcher, m: i64) i64 {
        return self.t0 + m * self.hop;
    }

    fn restart(self: *Stretcher, a: i64) void {
        @memset(&self.ring_l, 0);
        @memset(&self.ring_r, 0);
        // The first frame whose window still reaches `a`.
        self.m = @divFloor(a - @divExact(self.span, 2) - self.t0, self.hop) + 1;
        self.next_t = @floatFromInt(a - TUNE_REACH);
        self.reset_phase = true;
        self.live = true;
    }

    /// Output samples `a .. a + out.len` of the clip into `out_l`/`out_r`
    /// (added, times `gain[i]`). `ctx` maps an output sample to a source
    /// position (`pos(t) f64`), gives the read step (`step: f64`: source
    /// samples per frame sample, the pitch in it) and says whether a
    /// transient lies between two positions (`hit(p0, p1) bool`).
    pub fn render(self: *Stretcher, src: Source, ctx: anytype, a0: i64, out_l: []f32, out_r: []f32, gain: []const f32) void {
        if (!self.live or a0 != self.next_a) self.restart(a0);
        for (out_l, out_r, gain, 0..) |*ol, *or_, g, k| {
            const a = a0 + @as(i64, @intCast(k));
            if (self.kind == .tune) {
                // Only a context that tunes can play Tune's grains.
                if (comptime @hasDecl(@TypeOf(ctx), "tuneAt")) {
                    while (self.next_t - TUNE_REACH <= @as(f64, @floatFromInt(a))) self.tuneGrain(src, ctx, a);
                }
            } else while (self.frameT(self.m) - @divExact(self.span, 2) <= a) : (self.m += 1) switch (self.kind) {
                .mix => self.synth(src, ctx, self.frameT(self.m), a),
                .voice => self.voiceGrain(src, ctx, self.frameT(self.m), a),
                .tune => unreachable,
            };
            const slot: usize = @intCast(@mod(a, N));
            ol.* += self.ring_l[slot] * g;
            or_.* += self.ring_r[slot] * g;
            self.ring_l[slot] = 0;
            self.ring_r[slot] = 0;
        }
        self.next_a = a0 + @as(i64, @intCast(out_l.len));
    }

    /// Frame centered on output sample `t`, overlap-added from `a` (the
    /// next sample to play) on: what's before it is played or skipped, and
    /// its ring slots already hold what comes a ring later.
    fn synth(self: *Stretcher, src: Source, ctx: anytype, t: i64, a: i64) void {
        const pos = ctx.pos(@floatFromInt(t));
        const step: f64 = ctx.step;
        const reset = self.reset_phase or ctx.hit(self.prev_pos, pos);
        self.reset_phase = false;
        self.prev_pos = pos;
        const stereo = src.r != null;

        // ── Analysis: this frame (re) and its twin a hop back (im) ──
        const back = @as(f64, H) * step;
        if (@abs(step - 1) < 1e-9) {
            const base: i64 = @intFromFloat(@round(pos));
            for (0..N) |i| {
                const off = @as(i64, @intCast(i)) - N / 2;
                const va = src.exact(base + off);
                const vb = src.exact(base - H + off);
                const w = WINDOW[i];
                self.bl[i] = .{ .re = va[0] * w, .im = vb[0] * w };
                self.br[i] = .{ .re = va[1] * w, .im = vb[1] * w };
            }
        } else {
            for (0..N) |i| {
                const off = (@as(f64, @floatFromInt(i)) - N / 2) * step;
                const va = src.at(pos + off, step);
                const vb = src.at(pos - back + off, step);
                const w = WINDOW[i];
                self.bl[i] = .{ .re = va[0] * w, .im = vb[0] * w };
                self.br[i] = .{ .re = va[1] * w, .im = vb[1] * w };
            }
        }
        F.forward(&self.bl);
        if (stereo) F.forward(&self.br);

        // ── The mid's magnitudes and phases; the twin's at the peaks ──
        var max: f32 = 0;
        for (0..BINS) |k| {
            const am = splitA(&self.bl, k).add(if (stereo) splitA(&self.br, k) else C{ .re = 0, .im = 0 });
            self.mag[k] = am.mag();
            self.ph[k] = am.arg();
            max = @max(max, self.mag[k]);
        }

        // ── Output phases ──
        var np: usize = 0;
        if (!reset and max > 0) {
            const floor = max * 1e-4;
            var k: usize = 2;
            while (k + 2 < BINS) : (k += 1) {
                const v = self.mag[k];
                if (v > floor and v > self.mag[k - 1] and v >= self.mag[k + 1] and v > self.mag[k - 2] and v >= self.mag[k + 2] and np < self.peaks.len) {
                    self.peaks[np] = @intCast(k);
                    np += 1;
                }
            }
        }
        if (np == 0) {
            @memcpy(&self.psi, &self.ph);
        } else {
            // Each peak advances by its own frequency over the hop.
            for (self.peaks[0..np], 0..) |p, i| {
                const bm = splitB(&self.bl, p).add(if (stereo) splitB(&self.br, p) else C{ .re = 0, .im = 0 });
                const expect = TAU * @as(f32, @floatFromInt(@as(u32, p) * H)) / N;
                const dev = princarg(self.ph[p] - bm.arg() - expect);
                self.peak_psi[i] = princarg(self.psi[p] + expect + dev);
            }
            // Every bin keeps its offset from the peak whose region it's in
            // (regions split halfway between peaks).
            var pi: usize = 0;
            for (0..BINS) |k| {
                while (pi + 1 < np and k * 2 > @as(usize, self.peaks[pi]) + self.peaks[pi + 1]) pi += 1;
                const p = self.peaks[pi];
                self.psi[k] = princarg(self.peak_psi[pi] + self.ph[k] - self.ph[p]);
            }
        }

        // ── Synthesis: each channel turned by the mid's correction ──
        // Bin k overwrites bl[k] and br[N−k] only after reading them; no
        // later bin reads either.
        for (0..BINS) |k| {
            const rot = C.polar(1, self.psi[k] - self.ph[k]);
            const yl = splitA(&self.bl, k).mul(rot);
            const yr = if (stereo) splitA(&self.br, k).mul(rot) else yl;
            // Pack both real outputs into one inverse: z = yl + i·yr.
            self.bl[k] = .{ .re = yl.re - yr.im, .im = yl.im + yr.re };
            if (k > 0 and k < N / 2) {
                const cl = yl.conj();
                const cr = yr.conj();
                self.br[N - k] = .{ .re = cl.re - cr.im, .im = cl.im + cr.re };
            }
        }
        for (N / 2 + 1..N) |k| self.bl[k] = self.br[k];
        F.inverse(&self.bl);

        const s0 = t - N / 2;
        for (@intCast(@max(0, a - s0))..N) |i| {
            const slot: usize = @intCast(@mod(s0 + @as(i64, @intCast(i)), N));
            const w = WINDOW[i] * OLA_GAIN;
            self.ring_l[slot] += self.bl[i].re * w;
            self.ring_r[slot] += (if (stereo) self.bl[i].im else self.bl[i].re) * w;
        }
    }

    /// VOICE (docs/29 §VOICE): one grain centered on output sample `t`,
    /// read near where the maps put it, at the offset within ±10 ms whose
    /// waveform best continues the last grain's (WSOLA), so periods line up.
    fn voiceGrain(self: *Stretcher, src: Source, ctx: anytype, t: i64, a: i64) void {
        const w = self.span;
        const half = @divExact(w, 2);
        const step: f64 = ctx.step;
        const p = ctx.pos(@floatFromInt(t));
        var q = p;
        if (!self.reset_phase) {
            // The template: what would naturally follow the last grain.
            const c = self.q_prev + @as(f64, @floatFromInt(self.hop)) * step;
            const reach: i64 = @intFromFloat(@round(0.01 * src.rate));
            const L: usize = @intCast(@divExact(half, 4));
            var tmpl: [MAX_GRAIN / 8]f32 = undefined;
            for (tmpl[0..L], 0..) |*v, j| v.* = mono(src, c + (@as(f64, @floatFromInt(j * 4)) - @as(f64, @floatFromInt(half)) / 2) * step);
            const Score = struct {
                fn at(sr: Source, tm: []const f32, center: f64, st: f64, h: i64) f32 {
                    var sum: f32 = 0;
                    for (tm, 0..) |v, j| sum += v * mono(sr, center + (@as(f64, @floatFromInt(j * 4)) - @as(f64, @floatFromInt(h)) / 2) * st);
                    return sum;
                }
            };
            var best: i64 = 0;
            var best_s = -std.math.inf(f32);
            var d: i64 = -reach;
            while (d <= reach) : (d += 4) {
                const sc = Score.at(src, tmpl[0..L], p + @as(f64, @floatFromInt(d)), step, half);
                if (sc > best_s) {
                    best_s = sc;
                    best = d;
                }
            }
            const coarse = best;
            d = coarse - 3;
            while (d <= coarse + 3) : (d += 1) {
                if (d == coarse) continue;
                const sc = Score.at(src, tmpl[0..L], p + @as(f64, @floatFromInt(d)), step, half);
                if (sc > best_s) {
                    best_s = sc;
                    best = d;
                }
            }
            q = p + @as(f64, @floatFromInt(best));
        }
        self.reset_phase = false;
        self.q_prev = q;
        // A Hann grain; at half overlap they sum to one.
        const exact = @abs(step - 1) < 1e-9;
        const qi: i64 = @intFromFloat(@round(q));
        const s0 = t - half;
        const from: usize = @intCast(@max(0, a - s0));
        const fw: f32 = @floatFromInt(w);
        for (from..@intCast(w)) |i| {
            const off = @as(i64, @intCast(i)) - half;
            const v = if (exact) src.exact(qi + off) else src.at(q + @as(f64, @floatFromInt(off)) * step, step);
            const win = 0.5 - 0.5 * @cos(TAU * @as(f32, @floatFromInt(i)) / fw);
            const slot: usize = @intCast(@mod(s0 + @as(i64, @intCast(i)), N));
            self.ring_l[slot] += v[0] * win;
            self.ring_r[slot] += v[1] * win;
        }
    }

    /// Tune (docs/30 §Tune): TD-PSOLA. A grain two source periods long,
    /// centered on the pitch mark nearest where the maps put output sample
    /// `next_t`, read at the source's own speed (so its formants stay),
    /// laid down at `next_t`; the next grain a period at the pitch it
    /// should be later. Unsung, grains are 10 ms, 5 ms apart, as they are.
    fn tuneGrain(self: *Stretcher, src: Source, ctx: anytype, a: i64) void {
        const t = self.next_t;
        const g: TuneGrain = ctx.tuneAt(ctx.pos(t));
        const base: f64 = ctx.base;
        // Output samples: half a grain (a source period) and the hop.
        const half = @min(@as(f64, TUNE_REACH), g.period / base);
        const hop = @max(16, g.period / base / std.math.clamp(g.beta, 0.5, 2));
        self.next_t = t + hop;
        // Hann grains of length 2·half a hop apart sum to half/hop.
        const norm: f32 = @floatCast(hop / half);
        const h: i64 = @intFromFloat(@floor(half));
        const tc: i64 = @intFromFloat(@round(t));
        const frac = t - @as(f64, @floatFromInt(tc));
        const exact = @abs(base - 1) < 1e-9 and @abs(frac) < 1e-9 and @abs(g.center - @round(g.center)) < 1e-9;
        var i: i64 = -h;
        while (i <= h) : (i += 1) {
            const at = tc + i;
            if (at < a) continue;
            const off = @as(f64, @floatFromInt(i)) - frac;
            const w: f32 = @floatCast(0.5 + 0.5 * @cos(std.math.pi * off / half));
            if (w <= 0) continue;
            const v = if (exact) src.exact(@as(i64, @intFromFloat(g.center)) + i) else src.at(g.center + off * base, base);
            const slot: usize = @intCast(@mod(at, N));
            self.ring_l[slot] += v[0] * w * norm;
            self.ring_r[slot] += v[1] * w * norm;
        }
    }
};

/// The source's mid at the nearest sample, for matching.
fn mono(src: Source, x: f64) f32 {
    const v = src.exact(@intFromFloat(@round(x)));
    return v[0] + v[1];
}

/// The spectrum of the real part (A) and of the imaginary part (B) of a
/// packed transform, at bin k.
inline fn splitA(z: *const [N]C, k: usize) C {
    const a = z[k];
    const b = z[(N - k) % N].conj();
    return a.add(b).scale(0.5);
}

inline fn splitB(z: *const [N]C, k: usize) C {
    const a = z[k];
    const b = z[(N - k) % N].conj();
    const d = a.sub(b);
    return (C{ .re = d.im, .im = -d.re }).scale(0.5);
}

fn princarg(x: f32) f32 {
    return x - TAU * @round(x / TAU);
}

// ── SMEAR (docs/29 §SMEAR) ───────────────────────────────────────────

/// SMEAR's window sizes, in output samples (0.34, 0.68, 1.37, 2.73 s at
/// 48 kHz).
pub const SMEAR_SIZES = [_]usize{ 16384, 32768, 65536, 131072 };
const SMEAR_MAX = SMEAR_SIZES[SMEAR_SIZES.len - 1];
/// Hann, analyzing and synthesizing, four deep, over frames whose phases
/// are unrelated: their powers add, to 9/16 of the source's.
const SMEAR_GAIN: f32 = 4.0 / 3.0;

/// Paulstretch: long windows, each frame's phases drawn at random, seeded
/// by the clip and the frame, so any start renders the same. A few
/// megabytes; a track gets two when it first plays SMEAR.
pub const Smearer = struct {
    uid: u32 = 0,
    used: u64 = 0,
    live: bool = false,
    next_a: i64 = 0,
    t0: i64 = 0,
    m: i64 = 0,
    n: usize = SMEAR_SIZES[1],
    tw: [SMEAR_MAX / 2]C = undefined,
    buf: [SMEAR_MAX]C = undefined,
    ring_l: [SMEAR_MAX]f32 = undefined,
    ring_r: [SMEAR_MAX]f32 = undefined,

    /// After allocating (UI thread): the twiddles.
    pub fn init(self: *Smearer) void {
        self.* = .{};
        fft.twiddles(&self.tw);
    }

    pub fn claim(self: *Smearer, uid: u32, t0: i64, n: usize) void {
        self.uid = uid;
        self.t0 = t0;
        self.n = n;
        self.live = false;
    }

    fn hop(self: *const Smearer) i64 {
        return @intCast(self.n / 4);
    }

    fn frameT(self: *const Smearer, m: i64) i64 {
        return self.t0 + m * self.hop();
    }

    pub fn render(self: *Smearer, src: Source, ctx: anytype, a0: i64, out_l: []f32, out_r: []f32, gain: []const f32) void {
        const half: i64 = @intCast(self.n / 2);
        if (!self.live or a0 != self.next_a) {
            @memset(self.ring_l[0..self.n], 0);
            @memset(self.ring_r[0..self.n], 0);
            self.m = @divFloor(a0 - half - self.t0, self.hop()) + 1;
            self.live = true;
        }
        for (out_l, out_r, gain, 0..) |*ol, *or_, g, k| {
            const a = a0 + @as(i64, @intCast(k));
            while (self.frameT(self.m) - half <= a) : (self.m += 1) self.frame(src, ctx, self.frameT(self.m), a);
            const slot: usize = @intCast(@mod(a, @as(i64, @intCast(self.n))));
            ol.* += self.ring_l[slot] * g;
            or_.* += self.ring_r[slot] * g;
            self.ring_l[slot] = 0;
            self.ring_r[slot] = 0;
        }
        self.next_a = a0 + @as(i64, @intCast(out_l.len));
    }

    fn frame(self: *Smearer, src: Source, ctx: anytype, t: i64, a: i64) void {
        const n = self.n;
        const nf: f32 = @floatFromInt(n);
        const half: i64 = @intCast(n / 2);
        const step: f64 = ctx.step;
        const pos = ctx.pos(@floatFromInt(t));
        const buf = self.buf[0..n];
        const exact = @abs(step - 1) < 1e-9;
        const base: i64 = @intFromFloat(@round(pos));
        // Both channels in one transform: l + i·r.
        for (buf, 0..) |*b, i| {
            const off = @as(i64, @intCast(i)) - half;
            const v = if (exact) src.exact(base + off) else src.at(pos + @as(f64, @floatFromInt(off)) * step, step);
            const w = 0.5 - 0.5 * @cos(TAU * @as(f32, @floatFromInt(i)) / nf);
            b.* = .{ .re = v[0] * w, .im = v[1] * w };
        }
        fft.transform(buf, &self.tw, false);
        const seed = (@as(u64, self.uid) << 32) ^ @as(u64, @bitCast(self.m));
        for (0..n / 2 + 1) |k| {
            const z = buf[k];
            const zc = buf[(n - k) % n].conj();
            const al = z.add(zc).scale(0.5);
            const d = z.sub(zc);
            const ar = (C{ .re = d.im, .im = -d.re }).scale(0.5);
            // DC and Nyquist stay real; every other bin gets a fresh phase,
            // both channels turned alike so the image holds.
            const rot = if (k == 0 or k == n / 2) C{ .re = 1, .im = 0 } else blk: {
                const rnd: f32 = @floatCast(@as(f64, @floatFromInt(splitmix(seed ^ (@as(u64, k) *% 0x9E37_79B9_7F4A_7C15)) >> 11)) / @as(f64, 1 << 53));
                break :blk C.polar(1, rnd * TAU - al.add(ar).arg());
            };
            const yl = al.mul(rot);
            const yr = ar.mul(rot);
            buf[k] = .{ .re = yl.re - yr.im, .im = yl.im + yr.re };
            if (k > 0 and k < n / 2) {
                const cl = yl.conj();
                const cr = yr.conj();
                buf[n - k] = .{ .re = cl.re - cr.im, .im = cl.im + cr.re };
            }
        }
        fft.transform(buf, &self.tw, true);
        const s0 = t - half;
        const from: usize = @intCast(@max(0, a - s0));
        const stereo = src.r != null;
        for (from..n) |i| {
            const w = (0.5 - 0.5 * @cos(TAU * @as(f32, @floatFromInt(i)) / nf)) * SMEAR_GAIN;
            const slot: usize = @intCast(@mod(s0 + @as(i64, @intCast(i)), @as(i64, @intCast(n))));
            self.ring_l[slot] += buf[i].re * w;
            self.ring_r[slot] += (if (stereo) buf[i].im else buf[i].re) * w;
        }
    }
};

fn splitmix(x0: u64) u64 {
    var x = x0 +% 0x9E37_79B9_7F4A_7C15;
    x = (x ^ (x >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    x = (x ^ (x >> 27)) *% 0x94D0_49BB_1331_11EB;
    return x ^ (x >> 31);
}

/// A track's stretchers: one per clip sounding at once.
pub const Bank = struct {
    pub const SIZE = 4;
    st: [SIZE]Stretcher = [_]Stretcher{.{}} ** SIZE,
    /// SMEAR's, made on the UI thread when a clip first needs them.
    smear: [2]?*Smearer = .{ null, null },
    tick: u64 = 0,

    /// The smearer playing clip `uid`, or a free one claimed for it.
    pub fn getSmear(self: *Bank, uid: u32, t0: i64, n: usize) ?*Smearer {
        for (self.smear) |o| if (o) |s| if (s.uid == uid and s.used + 1 >= self.tick) {
            if (s.t0 != t0 or s.n != n) s.claim(uid, t0, n);
            s.used = self.tick;
            return s;
        };
        for (self.smear) |o| if (o) |s| if (s.uid == 0 or s.used + 1 < self.tick) {
            s.claim(uid, t0, n);
            s.used = self.tick;
            return s;
        };
        return null;
    }

    /// UI thread: make the smearers if they aren't.
    pub fn needSmear(self: *Bank) void {
        for (&self.smear) |*o| if (o.* == null) {
            const s = std.heap.page_allocator.create(Smearer) catch return;
            s.init();
            o.* = s;
        };
    }

    /// UI thread, with the audio thread off the track: free the smearers.
    pub fn deinit(self: *Bank) void {
        for (&self.smear) |*o| if (o.*) |s| {
            std.heap.page_allocator.destroy(s);
            o.* = null;
        };
    }

    /// The stretcher playing clip `uid`, or a free one claimed for it (null
    /// when all are busy). Call `beginBlock` first, once per block.
    pub fn get(self: *Bank, uid: u32, t0: i64, kind: Kind, grain: i64) ?*Stretcher {
        for (&self.st) |*s| if (s.uid == uid and s.used + 1 >= self.tick) {
            if (!s.fits(t0, kind, grain)) s.claim(uid, t0, kind, grain);
            s.used = self.tick;
            return s;
        };
        for (&self.st) |*s| if (s.uid == 0 or s.used + 1 < self.tick) {
            s.claim(uid, t0, kind, grain);
            s.used = self.tick;
            return s;
        };
        return null;
    }

    /// Once per call that mixes the track's clips: a stretcher not used
    /// in the previous call is free again.
    pub fn beginBlock(self: *Bank) void {
        self.tick += 1;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const Lin = struct {
    /// pos(t) = (t − t0)·rate + p0
    rate: f64,
    p0: f64 = 0,
    step: f64 = 1,
    fn pos(self: Lin, t: f64) f64 {
        return t * self.rate + self.p0;
    }
    fn hit(_: Lin, _: f64, _: f64) bool {
        return false;
    }
};

fn sine(alloc: std.mem.Allocator, n: usize, freq: f64) ![]f64 {
    const x = try alloc.alloc(f64, n);
    for (x, 0..) |*v, i| v.* = 0.5 * @sin(2 * std.math.pi * freq * @as(f64, @floatFromInt(i)) / 48_000.0);
    return x;
}

/// The frequency of a steady signal, by zero crossings.
fn hz(x: []const f32) f64 {
    var n: usize = 0;
    var first: ?usize = null;
    var last: usize = 0;
    for (x[1..], x[0 .. x.len - 1], 1..) |b, a, i| if (a < 0 and b >= 0) {
        if (first == null) first = i;
        last = i;
        n += 1;
    };
    if (n < 2) return 0;
    return @as(f64, @floatFromInt(n - 1)) * 48_000.0 / @as(f64, @floatFromInt(last - first.?));
}

test "stretch: at ratio 1 it gives the source back" {
    const alloc = std.testing.allocator;
    const x = try alloc.alloc(f64, 48_000);
    defer alloc.free(x);
    var rng = std.Random.DefaultPrng.init(1);
    for (x, 0..) |*v, i| v.* = 0.3 * @sin(@as(f64, @floatFromInt(i)) * 0.03) + 0.2 * (rng.random().float(f64) - 0.5);
    const st = try alloc.create(Stretcher);
    defer alloc.destroy(st);
    st.* = .{};
    st.claim(1, 0, .mix, 0);
    var l = [_]f32{0} ** 20_000;
    var r = [_]f32{0} ** 20_000;
    const g = [_]f32{1} ** 512;
    var a: usize = 0;
    while (a < l.len) : (a += 512) {
        const n = @min(512, l.len - a);
        st.render(.{ .l = x.ptr, .r = null, .len = x.len, .reversed = false }, Lin{ .rate = 1, .p0 = 10_000 }, @intCast(a), l[a..][0..n], r[a..][0..n], g[0..n]);
    }
    for (l, r, 0..) |lv, rv, i| {
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(x[10_000 + i])), lv, 2e-3);
        try std.testing.expectEqual(lv, rv);
    }
}

test "stretch: twice as long, same pitch; an octave up, same length" {
    const alloc = std.testing.allocator;
    const x = try sine(alloc, 96_000, 440);
    defer alloc.free(x);
    const st = try alloc.create(Stretcher);
    defer alloc.destroy(st);
    var l = [_]f32{0} ** 24_000;
    var r = [_]f32{0} ** 24_000;
    const g = [_]f32{1} ** 24_000;
    st.* = .{};
    st.claim(1, 0, .mix, 0);
    st.render(.{ .l = x.ptr, .r = null, .len = x.len, .reversed = false }, Lin{ .rate = 0.5, .p0 = 20_000 }, 0, &l, &r, &g);
    try std.testing.expectApproxEqAbs(@as(f64, 440), hz(l[4096..20_000]), 1);
    // Level holds, too.
    var peak: f32 = 0;
    for (l[4096..20_000]) |v| peak = @max(peak, @abs(v));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.03);

    @memset(&l, 0);
    st.* = .{};
    st.claim(1, 0, .mix, 0);
    st.render(.{ .l = x.ptr, .r = null, .len = x.len, .reversed = false }, Lin{ .rate = 1, .p0 = 20_000, .step = 2 }, 0, &l, &r, &g);
    try std.testing.expectApproxEqAbs(@as(f64, 880), hz(l[4096..20_000]), 2);
}

test "stretch: a stereo image keeps its channels apart" {
    const alloc = std.testing.allocator;
    const xl = try sine(alloc, 96_000, 300);
    defer alloc.free(xl);
    const xr = try sine(alloc, 96_000, 1200);
    defer alloc.free(xr);
    const st = try alloc.create(Stretcher);
    defer alloc.destroy(st);
    st.* = .{};
    st.claim(1, 0, .mix, 0);
    var l = [_]f32{0} ** 24_000;
    var r = [_]f32{0} ** 24_000;
    const g = [_]f32{1} ** 24_000;
    st.render(.{ .l = xl.ptr, .r = xr.ptr, .len = xl.len, .reversed = false }, Lin{ .rate = 0.7, .p0 = 20_000 }, 0, &l, &r, &g);
    try std.testing.expectApproxEqAbs(@as(f64, 300), hz(l[4096..20_000]), 1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1200), hz(r[4096..20_000]), 3);
}

test "voice: grains keep the pitch and the level, stretched and squeezed" {
    const alloc = std.testing.allocator;
    const x = try sine(alloc, 96_000, 220);
    defer alloc.free(x);
    const st = try alloc.create(Stretcher);
    defer alloc.destroy(st);
    var l = [_]f32{0} ** 24_000;
    var r = [_]f32{0} ** 24_000;
    const g = [_]f32{1} ** 24_000;
    for ([_]f64{ 0.6, 1.5 }) |rate| {
        st.* = .{};
        st.claim(1, 0, .voice, 1920);
        @memset(&l, 0);
        st.render(.{ .l = x.ptr, .r = null, .len = x.len, .reversed = false }, Lin{ .rate = rate, .p0 = 30_000 }, 0, &l, &r, &g);
        try std.testing.expectApproxEqAbs(@as(f64, 220), hz(l[4096..20_000]), 0.5);
        var lo: f32 = 1;
        var hi: f32 = 0;
        // The envelope stays put: every 10 ms holds a peak near 0.5.
        var k: usize = 4096;
        while (k + 480 < 20_000) : (k += 480) {
            var pk: f32 = 0;
            for (l[k..][0..480]) |v| pk = @max(pk, @abs(v));
            lo = @min(lo, pk);
            hi = @max(hi, pk);
        }
        try std.testing.expect(lo > 0.45 and hi < 0.55);
    }
}

test "smear: keeps the spectrum and the level, renders the same from anywhere" {
    const alloc = std.testing.allocator;
    const x = try sine(alloc, 200_000, 330);
    defer alloc.free(x);
    const sm = try std.heap.page_allocator.create(Smearer);
    defer std.heap.page_allocator.destroy(sm);
    sm.init();
    const n = 40_000;
    const l = try alloc.alloc(f32, n);
    defer alloc.free(l);
    const r = try alloc.alloc(f32, n);
    defer alloc.free(r);
    const g = try alloc.alloc(f32, n);
    defer alloc.free(g);
    @memset(g, 1);
    @memset(l, 0);
    sm.claim(7, 0, SMEAR_SIZES[0]);
    const src = Source{ .l = x.ptr, .r = null, .len = x.len, .reversed = false };
    sm.render(src, Lin{ .rate = 0.25, .p0 = 60_000 }, 0, l, r, g);
    try std.testing.expectApproxEqAbs(@as(f64, 330), hz(l[16_384..n]), 2);
    var e: f64 = 0;
    for (l[16_384..n]) |v| e += v * v;
    const rms = @sqrt(e / @as(f64, @floatFromInt(n - 16_384)));
    try std.testing.expectApproxEqAbs(0.5 / @sqrt(2.0), rms, 0.06);
    // From the middle: the same samples.
    const mid = l[30_000];
    @memset(l, 0);
    sm.claim(7, 0, SMEAR_SIZES[0]);
    sm.render(src, Lin{ .rate = 0.25, .p0 = 60_000 }, 25_000, l[0..10_000], r[0..10_000], g[0..10_000]);
    try std.testing.expectApproxEqAbs(mid, l[5_000], 1e-4);
}

/// Tune's context in tests: a straight map, marks every `period` samples
/// from `mark0`, and a fixed pitch ratio.
const Psola = struct {
    rate: f64,
    p0: f64 = 0,
    base: f64 = 1,
    step: f64 = 1,
    period: f64,
    mark0: f64,
    beta: f64,
    fn pos(self: Psola, t: f64) f64 {
        return t * self.rate + self.p0;
    }
    fn hit(_: Psola, _: f64, _: f64) bool {
        return false;
    }
    fn tuneAt(self: Psola, s: f64) TuneGrain {
        const k = @round((s - self.mark0) / self.period);
        return .{ .center = self.mark0 + k * self.period, .period = self.period, .beta = self.beta };
    }
};

test "tune: grains move the pitch, keep the level, and stretch time" {
    const alloc = std.testing.allocator;
    const pitch = @import("pitch.zig");
    // A voice-ish 200 Hz: harmonics falling, a formant near 800 Hz.
    const x = try alloc.alloc(f64, 96_000);
    defer alloc.free(x);
    for (x, 0..) |*v, i| {
        const ph = 2 * std.math.pi * 200 * @as(f64, @floatFromInt(i)) / 48_000.0;
        var s: f64 = 0;
        for (1..12) |h| {
            const f: f64 = @floatFromInt(h * 200);
            s += (1 + 2 * @exp(-std.math.pow(f64, (f - 800) / 250, 2))) / @as(f64, @floatFromInt(h)) * @sin(@as(f64, @floatFromInt(h)) * ph);
        }
        v.* = 0.15 * s;
    }
    var mark0: usize = 0;
    for (0..240) |i| if (x[i] > x[mark0]) {
        mark0 = i;
    };
    const st = try alloc.create(Stretcher);
    defer alloc.destroy(st);
    const n = 47 * 512;
    var l = [_]f32{0} ** n;
    var r = [_]f32{0} ** n;
    const g = [_]f32{1} ** n;
    const Case = struct { rate: f64, beta: f64 };
    for ([_]Case{ .{ .rate = 1, .beta = 1 }, .{ .rate = 1, .beta = std.math.pow(f64, 2, 2.0 / 12.0) }, .{ .rate = 0.5, .beta = std.math.pow(f64, 2, -1.0 / 12.0) } }) |cs| {
        st.* = .{};
        st.claim(1, 0, .tune, 0);
        @memset(&l, 0);
        const src = Source{ .l = x.ptr, .r = null, .len = x.len, .reversed = false };
        var a: usize = 0;
        while (a < n) : (a += 512) st.render(src, Psola{ .rate = cs.rate, .p0 = 20_000, .period = 240, .mark0 = @floatFromInt(mark0), .beta = cs.beta }, @intCast(a), l[a..][0..512], r[a..][0..512], g[0..512]);
        const y = try alloc.alloc(f64, n - 2048);
        defer alloc.free(y);
        for (y, l[2048..]) |*o, v| o.* = v;
        var tr = try pitch.track(alloc, y, null, 48_000, .voice);
        defer tr.deinit(alloc);
        const f = tr.f0[tr.len() / 2];
        try std.testing.expectApproxEqRel(@as(f32, @floatCast(200 * cs.beta)), f, 0.006);
        // The level of the source, within 1 dB.
        var e0: f64 = 0;
        for (x[20_000..40_000]) |v| e0 += v * v;
        var e1: f64 = 0;
        for (y[0..20_000]) |v| e1 += v * v;
        try std.testing.expect(@abs(10 * std.math.log10(e1 / e0)) < 1);
    }
}
