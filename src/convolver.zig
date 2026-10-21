//! Partitioned convolution for the audio thread (proposal, docs/43): a
//! machine declares an impulse response with `convolver`, and the host
//! convolves the machine's stereo input with it, handing the kernel the
//! result per sample as io.cv-l / io.cv-r.
//!
//! Uniform overlap-save: the IR is cut into N-sample partitions, each
//! transformed once (zero-padded to 2N) when it loads. Every N input
//! samples, one forward FFT of the last 2N inputs, a multiply-accumulate
//! of every partition against the matching past input spectrum, and one
//! inverse FFT give the next N outputs, so the output runs exactly N
//! samples late (the machine reports it with `latency!`). Left and right
//! share each transform: both are real, so the pair travels as one
//! complex signal, l + i·r, and splits by the spectrum's symmetry. Only
//! bins 0..N are multiplied; the rest mirror them.
//!
//! Built off the audio thread; process() allocates nothing.

const std = @import("std");
const fft = @import("fft.zig");
const C = fft.C;

pub const N = 256;
const M = 2 * N;
const BINS = N + 1;
const F = fft.Fft(M);

pub const Convolver = struct {
    parts: usize,
    /// Partition spectra, parts x BINS each; h_r aliases h_l for a mono IR.
    h_l: []C,
    h_r: []C,
    /// Past input spectra, the same shape, as a ring indexed by `head`.
    x_l: []C,
    x_r: []C,
    head: usize = 0,
    in_l: [M]f32 = @splat(0),
    in_r: [M]f32 = @splat(0),
    out_l: [N]f32 = @splat(0),
    out_r: [N]f32 = @splat(0),
    pos: usize = 0,
    stereo_ir: bool,

    /// An IR of `l` (and `r`, for a stereo one: L feeds L, R feeds R) at
    /// `ir_sr`, resampled to `sr` and scaled so white noise comes out at
    /// the level it went in.
    pub fn init(alloc: std.mem.Allocator, l: []const f64, r: ?[]const f64, ir_sr: f64, sr: f64) !*Convolver {
        const ratio = if (ir_sr > 0) sr / ir_sr else 1;
        const n = @max(1, @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(l.len)) * ratio))));
        const parts = (n + N - 1) / N;
        const self = try alloc.create(Convolver);
        errdefer alloc.destroy(self);
        const stereo_ir = r != null;
        const h_l = try alloc.alloc(C, parts * BINS);
        errdefer alloc.free(h_l);
        const h_r = if (stereo_ir) try alloc.alloc(C, parts * BINS) else h_l;
        errdefer if (stereo_ir) alloc.free(h_r);
        const x_l = try alloc.alloc(C, parts * BINS);
        errdefer alloc.free(x_l);
        const x_r = try alloc.alloc(C, parts * BINS);
        errdefer alloc.free(x_r);
        @memset(x_l, .{ .re = 0, .im = 0 });
        @memset(x_r, .{ .re = 0, .im = 0 });
        self.* = .{ .parts = parts, .h_l = h_l, .h_r = h_r, .x_l = x_l, .x_r = x_r, .stereo_ir = stereo_ir };

        var energy = channelEnergy(l);
        if (r) |rr| energy = (energy + channelEnergy(rr)) / 2;
        const gain: f64 = if (energy > 0) 1 / @sqrt(energy * ratio) else 0;
        partition(h_l, l, ratio, gain, parts);
        if (r) |rr| partition(h_r, rr, ratio, gain, parts);
        return self;
    }

    pub fn deinit(self: *Convolver, alloc: std.mem.Allocator) void {
        alloc.free(self.h_l);
        if (self.stereo_ir) alloc.free(self.h_r);
        alloc.free(self.x_l);
        alloc.free(self.x_r);
        alloc.destroy(self);
    }

    /// The IR's length in samples at the rate it was built for.
    pub fn len(self: *const Convolver) usize {
        return self.parts * N;
    }

    pub fn reset(self: *Convolver) void {
        @memset(self.x_l, .{ .re = 0, .im = 0 });
        @memset(self.x_r, .{ .re = 0, .im = 0 });
        self.in_l = @splat(0);
        self.in_r = @splat(0);
        self.out_l = @splat(0);
        self.out_r = @splat(0);
        self.pos = 0;
        self.head = 0;
    }

    /// One stereo sample in, the convolved sample from N samples ago out.
    pub inline fn process(self: *Convolver, l: f64, r: f64) [2]f64 {
        self.in_l[N + self.pos] = @floatCast(l);
        self.in_r[N + self.pos] = @floatCast(r);
        const y = [2]f64{ self.out_l[self.pos], self.out_r[self.pos] };
        self.pos += 1;
        if (self.pos == N) {
            self.block();
            self.pos = 0;
        }
        return y;
    }

    fn block(self: *Convolver) void {
        var z: [M]C = undefined;
        for (&z, self.in_l, self.in_r) |*v, a, b| v.* = .{ .re = a, .im = b };
        F.forward(&z);
        const xl = self.x_l[self.head * BINS ..][0..BINS];
        const xr = self.x_r[self.head * BINS ..][0..BINS];
        for (0..BINS) |k| {
            const zk = z[k];
            const zc = z[(M - k) % M].conj();
            const s = zk.add(zc);
            const d = zk.sub(zc);
            xl[k] = s.scale(0.5);
            xr[k] = .{ .re = 0.5 * d.im, .im = -0.5 * d.re }; // d / 2i
        }

        var yl: [BINS]C = @splat(.{ .re = 0, .im = 0 });
        var yr: [BINS]C = @splat(.{ .re = 0, .im = 0 });
        for (0..self.parts) |p| {
            const slot = (self.head + self.parts - p) % self.parts;
            mac(&yl, self.x_l[slot * BINS ..][0..BINS], self.h_l[p * BINS ..][0..BINS]);
            mac(&yr, self.x_r[slot * BINS ..][0..BINS], self.h_r[p * BINS ..][0..BINS]);
        }

        // Back to one complex signal, yl + i·yr, over the whole spectrum.
        for (0..BINS) |k| z[k] = .{ .re = yl[k].re - yr[k].im, .im = yl[k].im + yr[k].re };
        for (1..N) |k| {
            const a = yl[k].conj();
            const b = yr[k].conj();
            z[M - k] = .{ .re = a.re - b.im, .im = a.im + b.re };
        }
        F.inverse(&z);
        for (0..N) |i| {
            self.out_l[i] = z[N + i].re;
            self.out_r[i] = z[N + i].im;
        }
        @memcpy(self.in_l[0..N], self.in_l[N..M]);
        @memcpy(self.in_r[0..N], self.in_r[N..M]);
        self.head = (self.head + 1) % self.parts;
    }
};

inline fn mac(acc: *[BINS]C, x: *const [BINS]C, h: *const [BINS]C) void {
    for (acc, x, h) |*a, xv, hv| a.* = a.add(xv.mul(hv));
}

fn channelEnergy(x: []const f64) f64 {
    var e: f64 = 0;
    for (x) |v| e += v * v;
    return e;
}

/// Resample `ir` by `ratio` (linear), scale it, and store each N-sample
/// partition's spectrum (zero-padded to M) in `out`.
fn partition(out: []C, ir: []const f64, ratio: f64, gain: f64, parts: usize) void {
    for (0..parts) |p| {
        var z: [M]C = @splat(.{ .re = 0, .im = 0 });
        for (0..N) |i| {
            const t = @as(f64, @floatFromInt(p * N + i)) / ratio;
            const j: usize = @intFromFloat(@floor(t));
            if (j >= ir.len) break;
            const a = ir[j];
            const b = if (j + 1 < ir.len) ir[j + 1] else 0;
            z[i] = .{ .re = @floatCast((a + (b - a) * (t - @floor(t))) * gain), .im = 0 };
        }
        F.forward(&z);
        @memcpy(out[p * BINS ..][0..BINS], z[0..BINS]);
    }
}

fn direct(ir: []const f64, x: []const f64, n: usize, gain: f64) f64 {
    var s: f64 = 0;
    for (ir, 0..) |h, k| {
        if (k > n) break;
        s += h * gain * x[n - k];
    }
    return s;
}

test "convolver: matches direct convolution, N samples late, stereo IR" {
    const alloc = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(7);
    var irl: [700]f64 = undefined;
    var irr: [700]f64 = undefined;
    for (&irl, &irr, 0..) |*a, *b, i| {
        const decay = @exp(-@as(f64, @floatFromInt(i)) / 150.0);
        a.* = (rng.random().float(f64) - 0.5) * decay;
        b.* = (rng.random().float(f64) - 0.5) * decay;
    }
    const cv = try Convolver.init(alloc, &irl, &irr, 48000, 48000);
    defer cv.deinit(alloc);
    const gain = 1 / @sqrt((channelEnergy(&irl) + channelEnergy(&irr)) / 2);
    var xl: [2000]f64 = undefined;
    var xr: [2000]f64 = undefined;
    for (&xl, &xr) |*a, *b| {
        a.* = rng.random().float(f64) - 0.5;
        b.* = rng.random().float(f64) - 0.5;
    }
    for (0..2000) |n| {
        const y = cv.process(xl[n], xr[n]);
        if (n < N) {
            try std.testing.expectEqual(@as(f64, 0), y[0]);
            continue;
        }
        try std.testing.expectApproxEqAbs(direct(&irl, &xl, n - N, gain), y[0], 2e-4);
        try std.testing.expectApproxEqAbs(direct(&irr, &xr, n - N, gain), y[1], 2e-4);
    }
}

test "convolver: a mono IR feeds both channels, and reset clears the tail" {
    const alloc = std.testing.allocator;
    const ir = [_]f64{ 1, 0.5, 0.25 };
    const cv = try Convolver.init(alloc, &ir, null, 48000, 48000);
    defer cv.deinit(alloc);
    const g = 1 / @sqrt(channelEnergy(&ir));
    var out: [N + 4][2]f64 = undefined;
    for (&out, 0..) |*o, n| o.* = cv.process(if (n == 0) 1 else 0, if (n == 1) 1 else 0);
    try std.testing.expectApproxEqAbs(g, out[N][0], 1e-5);
    try std.testing.expectApproxEqAbs(0.5 * g, out[N + 1][0], 1e-5);
    try std.testing.expectApproxEqAbs(g, out[N + 1][1], 1e-5);
    cv.reset();
    for (0..2 * N) |_| {
        const y = cv.process(0, 0);
        try std.testing.expectEqual(@as(f64, 0), y[0]);
    }
}
