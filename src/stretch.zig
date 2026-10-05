//! MIX (docs/29 §MIX): a phase vocoder that stretches in real time on the
//! audio thread. Output frames sit on a grid anchored at the clip's start,
//! one hop apart; each analyzes the source around where the maps put it,
//! plus a twin frame one hop back for each bin's frequency, so nothing
//! about the stretch ratio has to be remembered: it may change every
//! frame, and a jump costs one frame and a phase reset. Phases are locked
//! to the spectrum's peaks (identity locking), reset at transients, and
//! both channels turn with the mid so the image stays put.
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

pub const Stretcher = struct {
    /// The clip it plays (0: free) and the last call it played in.
    uid: u32 = 0,
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

    pub fn claim(self: *Stretcher, uid: u32, t0: i64) void {
        self.uid = uid;
        self.t0 = t0;
        self.live = false;
    }

    fn frameT(self: *const Stretcher, m: i64) i64 {
        return self.t0 + m * H;
    }

    fn restart(self: *Stretcher, a: i64) void {
        @memset(&self.ring_l, 0);
        @memset(&self.ring_r, 0);
        // The first frame whose window still reaches `a`.
        self.m = @divFloor(a - N / 2 - self.t0, H) + 1;
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
            while (self.frameT(self.m) - N / 2 <= a) : (self.m += 1) self.synth(src, ctx, self.frameT(self.m), a);
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
};

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

/// A track's stretchers: one per clip sounding at once.
pub const Bank = struct {
    pub const SIZE = 4;
    st: [SIZE]Stretcher = [_]Stretcher{.{}} ** SIZE,
    tick: u64 = 0,

    /// The stretcher playing clip `uid`, or a free one claimed for it (null
    /// when all are busy). Call `beginBlock` first, once per block.
    pub fn get(self: *Bank, uid: u32, t0: i64) ?*Stretcher {
        for (&self.st) |*s| if (s.uid == uid and s.used + 1 >= self.tick) {
            if (s.t0 != t0) s.claim(uid, t0);
            s.used = self.tick;
            return s;
        };
        for (&self.st) |*s| if (s.uid == 0 or s.used + 1 < self.tick) {
            s.claim(uid, t0);
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
    st.claim(1, 0);
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
    st.claim(1, 0);
    st.render(.{ .l = x.ptr, .r = null, .len = x.len, .reversed = false }, Lin{ .rate = 0.5, .p0 = 20_000 }, 0, &l, &r, &g);
    try std.testing.expectApproxEqAbs(@as(f64, 440), hz(l[4096..20_000]), 1);
    // Level holds, too.
    var peak: f32 = 0;
    for (l[4096..20_000]) |v| peak = @max(peak, @abs(v));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.03);

    @memset(&l, 0);
    st.* = .{};
    st.claim(1, 0);
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
    st.claim(1, 0);
    var l = [_]f32{0} ** 24_000;
    var r = [_]f32{0} ** 24_000;
    const g = [_]f32{1} ** 24_000;
    st.render(.{ .l = xl.ptr, .r = xr.ptr, .len = xl.len, .reversed = false }, Lin{ .rate = 0.7, .p0 = 20_000 }, 0, &l, &r, &g);
    try std.testing.expectApproxEqAbs(@as(f64, 300), hz(l[4096..20_000]), 1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1200), hz(r[4096..20_000]), 3);
}
