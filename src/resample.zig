//! Offline sample-rate conversion for exports (docs/27 §Format): a
//! polyphase windowed-sinc resampler at an exact rational ratio. The
//! engine renders at 48 kHz; 44.1, 88.2 and 96 kHz exports come through
//! here. Kaiser window (β 12.3, about 120 dB of stopband); the passband
//! runs to 20 kHz going down, to 21.6 kHz going up, the transition ending
//! at the lower rate's Nyquist. The kernel is centred, so the output keeps
//! the input's timing.

const std = @import("std");

/// out = in × L / M.
const Ratio = struct { l: usize, m: usize };

fn ratio(from: u32, to: u32) Ratio {
    const g = std.math.gcd(from, to);
    return .{ .l = to / g, .m = from / g };
}

/// Interleaved stereo `x` at `from` Hz, at `to` Hz. Caller owns it.
pub fn stereo(alloc: std.mem.Allocator, x: []const f32, from: u32, to: u32) ![]f32 {
    return convert(alloc, x, from, to, false);
}

/// As `stereo`, for a loop: past either end it reads round from the
/// other, so the seam stays seamless.
pub fn loop(alloc: std.mem.Allocator, x: []const f32, from: u32, to: u32) ![]f32 {
    return convert(alloc, x, from, to, true);
}

fn convert(alloc: std.mem.Allocator, x: []const f32, from: u32, to: u32, circular: bool) ![]f32 {
    if (from == to) return alloc.dupe(f32, x);
    const r = ratio(from, to);
    const k = try Kernel.init(alloc, from, to, r);
    defer k.deinit(alloc);
    const n = x.len / 2;
    const out_n = (n * r.l + r.m - 1) / r.m;
    const out = try alloc.alloc(f32, out_n * 2);
    errdefer alloc.free(out);
    const half: isize = @intCast(k.half);
    for (0..out_n) |i| {
        const pos = i * r.m;
        const base: isize = @intCast(pos / r.l);
        const taps = k.phase(pos % r.l);
        var acc_l: f64 = 0;
        var acc_r: f64 = 0;
        // Input samples base - half + 1 .. base + half.
        const lo = base - half + 1;
        for (taps, 0..) |h, j| {
            var s = lo + @as(isize, @intCast(j));
            if (circular) {
                s = @mod(s, @as(isize, @intCast(n)));
            } else if (s < 0 or s >= n) continue;
            const u: usize = @intCast(s);
            acc_l += h * x[u * 2];
            acc_r += h * x[u * 2 + 1];
        }
        out[i * 2] = @floatCast(acc_l);
        out[i * 2 + 1] = @floatCast(acc_r);
    }
    return out;
}

/// L phases of 2·half taps each: phase p is the kernel at input offsets
/// (j - half + 1) - p/L, j = 0 .. 2·half.
const Kernel = struct {
    taps: []f64,
    half: usize,

    const BETA = 12.3;

    fn init(alloc: std.mem.Allocator, from: u32, to: u32, r: Ratio) !Kernel {
        const lower: f64 = @floatFromInt(@min(from, to));
        const fin: f64 = @floatFromInt(from);
        // Cutoff halfway through the transition band, in input-Nyquist units.
        const pass: f64 = if (to < from) 20_000 else 0.9 * lower / 2;
        const stop = lower / 2;
        const fc = (pass + stop) / 2 / (fin / 2);
        const tw = (stop - pass) / fin; // transition, cycles per input sample
        // Kaiser's estimate for ~120 dB, in input samples, each side.
        const len = (120.0 - 7.95) / (14.36 * tw);
        const half: usize = @intFromFloat(@ceil(len / 2) + 1);
        const width = 2 * half;
        const taps = try alloc.alloc(f64, r.l * width);
        const bessel_beta = besselI0(BETA);
        for (0..r.l) |p| {
            var sum: f64 = 0;
            for (0..width) |j| {
                const t = @as(f64, @floatFromInt(j)) - @as(f64, @floatFromInt(half)) + 1 - @as(f64, @floatFromInt(p)) / @as(f64, @floatFromInt(r.l));
                const u = t / @as(f64, @floatFromInt(half));
                const win = if (@abs(u) >= 1) 0 else besselI0(BETA * @sqrt(1 - u * u)) / bessel_beta;
                const v = fc * sinc(fc * t) * win;
                taps[p * width + j] = v;
                sum += v;
            }
            // Unity gain at DC for every phase.
            for (taps[p * width ..][0..width]) |*v| v.* /= sum;
        }
        return .{ .taps = taps, .half = half };
    }

    fn deinit(self: Kernel, alloc: std.mem.Allocator) void {
        alloc.free(self.taps);
    }

    fn phase(self: Kernel, p: usize) []const f64 {
        const width = 2 * self.half;
        return self.taps[p * width ..][0..width];
    }
};

fn sinc(x: f64) f64 {
    if (@abs(x) < 1e-12) return 1;
    const a = std.math.pi * x;
    return @sin(a) / a;
}

fn besselI0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (k < 50) : (k += 1) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn sine(alloc: std.mem.Allocator, hz: f64, rate: u32, secs: f64) ![]f32 {
    const n: usize = @intFromFloat(secs * @as(f64, @floatFromInt(rate)));
    const x = try alloc.alloc(f32, n * 2);
    for (0..n) |i| {
        const v: f32 = @floatCast(0.5 * @sin(2 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate))));
        x[i * 2] = v;
        x[i * 2 + 1] = -v;
    }
    return x;
}

/// Largest deviation from `amp`·sin at `rate` over the middle half.
fn sineError(y: []const f32, hz: f64, rate: u32, amp: f64) f64 {
    const n = y.len / 2;
    var worst: f64 = 0;
    for (n / 4..3 * n / 4) |i| {
        const want = amp * @sin(2 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate)));
        worst = @max(worst, @abs(y[i * 2] - want));
        worst = @max(worst, @abs(y[i * 2 + 1] + want));
    }
    return worst;
}

fn peakMid(y: []const f32) f64 {
    const n = y.len / 2;
    var p: f64 = 0;
    for (y[n / 2 .. 3 * n / 2]) |v| p = @max(p, @abs(v));
    return p;
}

test "48 kHz to 44.1, 88.2 and 96 kHz keeps a tone's level and timing" {
    const alloc = testing.allocator;
    for ([_]u32{ 44_100, 88_200, 96_000 }) |to| {
        for ([_]f64{ 1000, 15_000 }) |hz| {
            const x = try sine(alloc, hz, 48_000, 0.5);
            defer alloc.free(x);
            const y = try stereo(alloc, x, 48_000, to);
            defer alloc.free(y);
            try testing.expectEqual((x.len / 2 * to + 47_999) / 48_000, y.len / 2);
            // Within 0.001 of the ideal sine (−66 dB re its 0.5).
            try testing.expect(sineError(y, hz, to, 0.5) < 1e-3);
        }
    }
}

test "a loop resamples round its seam" {
    // 1 kHz fits 48 kHz in 48 samples and 44.1 kHz in 44.1: a loop of
    // 480 samples is ten periods at both, so the circular output is the
    // sine everywhere, ends included.
    const alloc = testing.allocator;
    const x = try sine(alloc, 1000, 48_000, 0.01);
    defer alloc.free(x);
    const y = try loop(alloc, x, 48_000, 44_100);
    defer alloc.free(y);
    try testing.expectEqual(@as(usize, 441), y.len / 2);
    for (0..441) |i| {
        const want = 0.5 * @sin(2 * std.math.pi * 1000 * @as(f64, @floatFromInt(i)) / 44_100.0);
        try testing.expectApproxEqAbs(want, y[i * 2], 1e-3);
    }
}

test "going down to 44.1 kHz, what's past its Nyquist is gone" {
    const alloc = testing.allocator;
    const x = try sine(alloc, 23_000, 48_000, 0.5);
    defer alloc.free(x);
    const y = try stereo(alloc, x, 48_000, 44_100);
    defer alloc.free(y);
    // 0.5 in, under −110 dB out.
    try testing.expect(peakMid(y) < 0.5 * std.math.pow(f64, 10, -110.0 / 20.0));
}
