//! Loudness (docs/27 §Normalize and the loudness report): ITU-R BS.1770-4
//! integrated loudness, EBU Tech 3342 loudness range and true peak, for an
//! exported file. K-weighting is the standard's shelf and RLB highpass,
//! derived for any rate; integrated loudness gates 400 ms blocks (75 %
//! overlap) at −70 LUFS and then 10 LU under their mean; LRA takes 3 s
//! blocks at 10 Hz, gated at −70 LUFS and 20 LU under, from the 10th to
//! the 95th percentile; true peak is the largest sample of a 4×
//! oversampled copy. slabkit's analyze.py is the reference.

const std = @import("std");

pub const Stats = struct {
    /// LUFS; −70 when nothing passes the gate.
    integrated: f64 = -70,
    /// Loudness range, LU.
    lra: f64 = 0,
    /// The loudest 3 s, LUFS.
    short_term_max: f64 = -70,
    /// dBFS and dBTP.
    sample_peak: f64 = -180,
    true_peak: f64 = -180,
};

/// Measure interleaved stereo `x` at `sr`.
pub fn measure(alloc: std.mem.Allocator, x: []const f32, sr: u32) !Stats {
    const n = x.len / 2;
    var st = Stats{};
    if (n == 0) return st;

    // K-weighted power per frame, both channels summed (weights 1, 1).
    const pw = try alloc.alloc(f64, n);
    defer alloc.free(pw);
    var kl = KFilter.init(@floatFromInt(sr));
    var kr = kl;
    for (0..n) |i| {
        const l = kl.run(x[i * 2]);
        const r = kr.run(x[i * 2 + 1]);
        pw[i] = l * l + r * r;
    }
    // Prefix sums make any block's mean power O(1).
    const cs = try alloc.alloc(f64, n + 1);
    defer alloc.free(cs);
    cs[0] = 0;
    for (pw, 0..) |p, i| cs[i + 1] = cs[i] + p;

    const fsr: f64 = @floatFromInt(sr);
    const hop: usize = @intFromFloat(@round(0.1 * fsr));
    st.integrated = gated(alloc, cs, @intFromFloat(@round(0.4 * fsr)), hop, -10, null) catch -70;
    st.lra = blk: {
        var range: [2]f64 = undefined;
        _ = gated(alloc, cs, @intFromFloat(@round(3 * fsr)), hop, -20, &range) catch break :blk 0;
        break :blk range[1] - range[0];
    };
    st.short_term_max = shortTermMax(cs, @intFromFloat(@round(3 * fsr)), hop);

    var peak: f32 = 0;
    for (x) |v| peak = @max(peak, @abs(v));
    st.sample_peak = db(peak);
    st.true_peak = db(@max(peak, truePeak(x)));
    return st;
}

fn db(v: f64) f64 {
    return 20 * std.math.log10(@max(v, 1e-9));
}

fn lufs(p: f64) f64 {
    return -0.691 + 10 * std.math.log10(@max(p, 1e-12));
}

/// Mean powers of `win`-frame blocks every `hop`, gated at −70 LUFS and
/// then `rel` LU under the mean of what passed; that mean's loudness. With
/// `pct`, also the 10th and 95th percentiles of the gated blocks (LRA).
fn gated(alloc: std.mem.Allocator, cs: []const f64, win: usize, hop: usize, rel: f64, pct: ?*[2]f64) !f64 {
    const n = cs.len - 1;
    const count = if (n >= win) (n - win) / hop + 1 else 1;
    const p = try alloc.alloc(f64, count);
    defer alloc.free(p);
    for (p, 0..) |*b, k| {
        const s = k * hop;
        const e = @min(n, s + win);
        b.* = (cs[e] - cs[s]) / @as(f64, @floatFromInt(@max(1, e - s)));
    }
    var sum: f64 = 0;
    var m: usize = 0;
    for (p) |b| if (lufs(b) > -70) {
        sum += b;
        m += 1;
    };
    if (m == 0) return error.Silent;
    const gate = lufs(sum / @as(f64, @floatFromInt(m))) + rel;
    var kept: usize = 0;
    sum = 0;
    for (p) |b| if (lufs(b) > -70 and lufs(b) > gate) {
        sum += b;
        p[kept] = b;
        kept += 1;
    };
    if (kept == 0) return error.Silent;
    if (pct) |out| {
        const g = p[0..kept];
        std.sort.pdq(f64, g, {}, std.sort.asc(f64));
        out[0] = lufs(g[percentile(kept, 10)]);
        out[1] = lufs(g[percentile(kept, 95)]);
    }
    return lufs(sum / @as(f64, @floatFromInt(kept)));
}

fn percentile(n: usize, pc: usize) usize {
    return @min(n - 1, (n - 1) * pc / 100);
}

fn shortTermMax(cs: []const f64, win: usize, hop: usize) f64 {
    const n = cs.len - 1;
    if (n < win) return lufs(cs[n] / @as(f64, @floatFromInt(@max(1, n))));
    var best: f64 = 0;
    var s: usize = 0;
    while (s + win <= n) : (s += hop) best = @max(best, (cs[s + win] - cs[s]) / @as(f64, @floatFromInt(win)));
    return lufs(best);
}

/// The K-weighting filter: a high shelf, then the RLB highpass.
const KFilter = struct {
    shelf: Biquad,
    hp: Biquad,

    fn init(sr: f64) KFilter {
        var f = KFilter{ .shelf = undefined, .hp = undefined };
        {
            const f0 = 1681.974450955533;
            const g: f64 = 3.999843853973347;
            const q = 0.7071752369554196;
            const k = @tan(std.math.pi * f0 / sr);
            const vh = std.math.pow(f64, 10, g / 20);
            const vb = std.math.pow(f64, vh, 0.4996667741545416);
            const a0 = 1 + k / q + k * k;
            f.shelf = .{
                .b = .{ (vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0 },
                .a = .{ 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0 },
            };
        }
        {
            const f0 = 38.13547087602444;
            const q = 0.5003270373238773;
            const k = @tan(std.math.pi * f0 / sr);
            const a0 = 1 + k / q + k * k;
            f.hp = .{ .b = .{ 1, -2, 1 }, .a = .{ 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0 } };
        }
        return f;
    }

    fn run(self: *KFilter, x: f32) f64 {
        return self.hp.run(self.shelf.run(x));
    }
};

const Biquad = struct {
    b: [3]f64,
    a: [2]f64,
    z1: f64 = 0,
    z2: f64 = 0,

    /// Transposed direct form II.
    fn run(self: *Biquad, x: f64) f64 {
        const y = self.b[0] * x + self.z1;
        self.z1 = self.b[1] * x - self.a[0] * y + self.z2;
        self.z2 = self.b[2] * x - self.a[1] * y;
        return y;
    }
};

/// 4× oversampling taps: a 48-tap Blackman-windowed sinc, 12 per phase.
const TP_TAPS = 12;
const tp_phases: [4][TP_TAPS]f64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [4][TP_TAPS]f64 = undefined;
    const len = 4 * TP_TAPS;
    for (0..4) |ph| for (0..TP_TAPS) |k| {
        const i: f64 = @floatFromInt(k * 4 + ph);
        const c = i - @as(f64, len - 1) / 2.0;
        const x = c / 4.0;
        const sinc = if (@abs(x) < 1e-12) 1.0 else @sin(std.math.pi * x) / (std.math.pi * x);
        const w = 0.42 - 0.5 * @cos(2 * std.math.pi * i / @as(f64, len - 1)) + 0.08 * @cos(4 * std.math.pi * i / @as(f64, len - 1));
        t[ph][k] = sinc * w;
    };
    break :blk t;
};

/// The largest absolute value of the 4× oversampled signal.
fn truePeak(x: []const f32) f64 {
    const n = x.len / 2;
    var peak: f64 = 0;
    for (0..2) |c| {
        var i: usize = TP_TAPS;
        while (i < n) : (i += 1) {
            for (tp_phases) |taps| {
                var acc: f64 = 0;
                for (taps, 0..) |h, k| acc += h * x[(i - k) * 2 + c];
                peak = @max(peak, @abs(acc));
            }
        }
    }
    return peak;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn tone(alloc: std.mem.Allocator, hz: f64, amp: f64, secs: f64, sr: u32) ![]f32 {
    const n: usize = @intFromFloat(secs * @as(f64, @floatFromInt(sr)));
    const x = try alloc.alloc(f32, n * 2);
    for (0..n) |i| {
        const v: f32 = @floatCast(amp * @sin(2 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sr))));
        x[i * 2] = v;
        x[i * 2 + 1] = v;
    }
    return x;
}

test "a 1 kHz sine at -20 dBFS in both channels reads -20 LUFS (+0.69 stereo, -0.69 offset)" {
    // BS.1770: a 0 dB 1 kHz sine in one channel is -3.01 LKFS; in two,
    // -0.0 LKFS. At -20 dBFS: -20.0 (K-weighting is ~+0.7 dB at 1 kHz,
    // which the -0.691 offset takes back).
    const x = try tone(testing.allocator, 1000, 0.1, 10, 48_000);
    defer testing.allocator.free(x);
    const s = try measure(testing.allocator, x, 48_000);
    try testing.expectApproxEqAbs(@as(f64, -20.0), s.integrated, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0), s.lra, 0.1);
    try testing.expectApproxEqAbs(@as(f64, -20.0), s.sample_peak, 0.01);
}

test "the gate ignores silence; LRA spans a quiet and a loud half" {
    const alloc = testing.allocator;
    const loud = try tone(alloc, 1000, 0.1, 10, 48_000);
    defer alloc.free(loud);
    // 10 s at -32, 10 s at -20, 10 s of silence.
    const x = try alloc.alloc(f32, loud.len * 3);
    defer alloc.free(x);
    @memset(x, 0);
    for (loud, 0..) |v, i| x[i] = v * 0.25;
    @memcpy(x[loud.len..][0..loud.len], loud);
    var s = try measure(alloc, x, 48_000);
    // Both halves pass the relative gate (-32 is within 10 LU of their
    // mean): their mean power, -22.75.
    try testing.expectApproxEqAbs(@as(f64, -20 + 10 * std.math.log10(17.0 / 32.0)), s.integrated, 0.05);
    try testing.expectApproxEqAbs(@as(f64, -20), s.short_term_max, 0.05);
    // Without the silence the range is the two levels apart.
    s = try measure(alloc, x[0 .. loud.len * 2], 48_000);
    try testing.expectApproxEqAbs(@as(f64, 12), s.lra, 0.2);
}

test "true peak finds the inter-sample peak a sample peak misses" {
    // fs/4 sine at 45° phase: samples sit at ±0.707 of the true crest.
    const alloc = testing.allocator;
    const n = 4800;
    const x = try alloc.alloc(f32, n * 2);
    defer alloc.free(x);
    for (0..n) |i| {
        const v: f32 = @floatCast(0.9 * @sin(std.math.pi / 2.0 * @as(f64, @floatFromInt(i)) + std.math.pi / 4.0));
        x[i * 2] = v;
        x[i * 2 + 1] = v;
    }
    const s = try measure(alloc, x, 48_000);
    try testing.expectApproxEqAbs(@as(f64, 20 * std.math.log10(0.9 * 0.7071)), s.sample_peak, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 20 * std.math.log10(0.9)), s.true_peak, 0.2);
}
