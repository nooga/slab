//! A fixed-size complex FFT for the audio thread (docs/29 §MIX): radix-2,
//! in place, f32, twiddles and the bit-reversal permutation computed at
//! compile time, so a transform allocates nothing and costs no trig.

const std = @import("std");

pub const C = struct {
    re: f32,
    im: f32,

    pub inline fn add(a: C, b: C) C {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    pub inline fn sub(a: C, b: C) C {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }
    pub inline fn mul(a: C, b: C) C {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
    pub inline fn conj(a: C) C {
        return .{ .re = a.re, .im = -a.im };
    }
    pub inline fn scale(a: C, s: f32) C {
        return .{ .re = a.re * s, .im = a.im * s };
    }
    pub inline fn mag(a: C) f32 {
        return @sqrt(a.re * a.re + a.im * a.im);
    }
    pub inline fn arg(a: C) f32 {
        return std.math.atan2(a.im, a.re);
    }
    pub inline fn polar(r: f32, th: f32) C {
        return .{ .re = r * @cos(th), .im = r * @sin(th) };
    }
};

pub fn Fft(comptime n: usize) type {
    std.debug.assert(std.math.isPowerOfTwo(n));
    const bits = std.math.log2_int(usize, n);
    return struct {
        pub const N = n;

        const tw: [n / 2]C = blk: {
            @setEvalBranchQuota(100_000_000);
            var t: [n / 2]C = undefined;
            for (&t, 0..) |*v, k| {
                const a = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
                v.* = .{ .re = @floatCast(@cos(a)), .im = @floatCast(@sin(a)) };
            }
            break :blk t;
        };

        const rev: [n]u32 = blk: {
            @setEvalBranchQuota(100_000_000);
            var t: [n]u32 = undefined;
            for (&t, 0..) |*v, i| v.* = @bitReverse(@as(std.meta.Int(.unsigned, bits), @intCast(i)));
            break :blk t;
        };

        /// Forward transform in place (e^{−i}, unscaled).
        pub fn forward(x: *[n]C) void {
            run(x, false);
        }

        /// Inverse transform in place (e^{+i}), scaled by 1/n.
        pub fn inverse(x: *[n]C) void {
            run(x, true);
            const s: f32 = 1.0 / @as(f32, @floatFromInt(n));
            for (x) |*v| v.* = v.scale(s);
        }

        fn run(x: *[n]C, inv: bool) void {
            for (0..n) |i| {
                const j = rev[i];
                if (i < j) std.mem.swap(C, &x[i], &x[j]);
            }
            var len: usize = 2;
            while (len <= n) : (len <<= 1) {
                const half = len / 2;
                const stride = n / len;
                var i: usize = 0;
                while (i < n) : (i += len) {
                    for (0..half) |k| {
                        var w = tw[k * stride];
                        if (inv) w.im = -w.im;
                        const u = x[i + k];
                        const v = x[i + k + half].mul(w);
                        x[i + k] = u.add(v);
                        x[i + k + half] = u.sub(v);
                    }
                }
            }
        }
    };
}

test "fft: matches a direct DFT and inverts" {
    const F = Fft(64);
    var x: [64]C = undefined;
    var rng = std.Random.DefaultPrng.init(3);
    for (&x) |*v| v.* = .{ .re = rng.random().float(f32) - 0.5, .im = rng.random().float(f32) - 0.5 };
    const orig = x;
    F.forward(&x);
    for (0..64) |k| {
        var s = C{ .re = 0, .im = 0 };
        for (orig, 0..) |v, j| {
            const a = -2.0 * std.math.pi * @as(f32, @floatFromInt(k * j)) / 64.0;
            s = s.add(v.mul(.{ .re = @cos(a), .im = @sin(a) }));
        }
        try std.testing.expectApproxEqAbs(s.re, x[k].re, 1e-4);
        try std.testing.expectApproxEqAbs(s.im, x[k].im, 1e-4);
    }
    F.inverse(&x);
    for (orig, x) |a, b| {
        try std.testing.expectApproxEqAbs(a.re, b.re, 1e-5);
        try std.testing.expectApproxEqAbs(a.im, b.im, 1e-5);
    }
}
