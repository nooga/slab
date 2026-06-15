//! Rig validation for the FM operator kernel
//! (kernels/01-oscillators/fm_operator.fy).
//!
//! Two prongs, the same pattern as ms20_svf_test.zig:
//!   1. Equivalence — the fy `k-fm-op` JIT output must match a plain-Zig
//!      reference (the same degree-9 sine poly) sample-for-sample, pinning
//!      the codegen to the model.
//!   2. Spectral — unmodulated the operator is a clean sine at the carrier;
//!      modulated, energy lands only at f_c ± n·f_m (FM sidebands).

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const FM_OP_PATH = "kernels/01-oscillators/fm_operator.fy";
const SAMPLE_RATE: f64 = 48_000.0;

// Mirrors `ustruct: FmOpState` in fm_operator.fy — do not reorder.
const FmOpState = extern struct {
    phase: f64 = 0,
    fb1: f64 = 0,
    fb2: f64 = 0,
};

// The exact degree-9 sine polynomial from kernels/05-drums/sine.fy:
// sin(2*pi*phase) via u = 1 - 2*frac(phase). Using the identical constants
// pins the fy codegen equivalence to ~machine epsilon.
fn polySin(phase: f64) f64 {
    const u = 1.0 - 2.0 * (phase - @floor(phase));
    const uu = u * u;
    var p: f64 = 0.064026102748925784;
    p = p * uu - 0.58185926636534557;
    p = p * uu + 2.5427128809580819;
    p = p * uu - 5.1664017645052089;
    p = p * uu + 3.1415278977538725;
    return p * u;
}

fn fmOpStep(st: *FmOpState, inc: f64, mod: f64, level: f64, fb: f64) f64 {
    const fbmod = fb * 0.5 * (st.fb1 + st.fb2);
    const out = level * polySin(st.phase + mod + fbmod);
    st.fb2 = st.fb1;
    st.fb1 = out;
    const adv = st.phase + inc;
    st.phase = adv - @floor(adv);
    return out;
}

// One Goertzel bin magnitude (amplitude) at integer bin k over n samples.
fn binAmp(x: []const f64, k: usize) f64 {
    const n = x.len;
    const w = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
    const cw = @cos(w);
    const sw = @sin(w);
    const coeff = 2.0 * cw;
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (x) |xv| {
        const s0 = xv + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    const re = s1 - s2 * cw;
    const im = s2 * sw;
    return @sqrt(re * re + im * im) * 2.0 / @as(f64, @floatFromInt(n));
}

fn fyStep(host: *FyHost, out: *f64, st: *FmOpState, inc: f64, mod: f64, level: f64, fb: f64) !void {
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(out) },
        .{ .ptr = @intFromPtr(st) },
        .{ .f64 = inc },
        .{ .f64 = mod },
        .{ .f64 = level },
        .{ .f64 = fb },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-fm-op", 1, &args);
}

test "k-fm-op matches the Zig reference sample-for-sample (codegen pin)" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(FM_OP_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    var fy_state = FmOpState{};
    var ref_state = FmOpState{};
    var fy_out: f64 = 0;

    const inc_c = 220.0 / SAMPLE_RATE;
    const inc_m = 137.0 / SAMPLE_RATE;
    const level = 0.8;
    const fb = 0.6; // exercise the feedback path
    var mphase: f64 = 0;
    var max_err: f64 = 0;

    var i: usize = 0;
    while (i < 8192) : (i += 1) {
        // A modulator that goes negative, to exercise phase wrapping both ways.
        const mod = 0.7 * polySin(mphase);
        mphase = mphase + inc_m - @floor(mphase + inc_m);

        const ref = fmOpStep(&ref_state, inc_c, mod, level, fb);
        try fyStep(&host, &fy_out, &fy_state, inc_c, mod, level, fb);

        try std.testing.expect(std.math.isFinite(fy_out));
        max_err = @max(max_err, @abs(fy_out - ref));
    }
    try std.testing.expect(max_err < 1e-9);
}

test "fm operator is a clean sine when unmodulated" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(FM_OP_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const n = 4096;
    const k_c = 200; // carrier bin -> f_c = 200*48000/4096
    var buf: [n]f64 = undefined;
    var st = FmOpState{};
    var out: f64 = 0;
    const inc = @as(f64, @floatFromInt(k_c)) / @as(f64, n);
    const level = 0.8;

    var peak: f64 = 0;
    var sumsq: f64 = 0;
    for (&buf) |*s| {
        try fyStep(&host, &out, &st, inc, 0.0, level, 0.0);
        s.* = out;
        peak = @max(peak, @abs(out));
        sumsq += out * out;
    }
    const rms = @sqrt(sumsq / @as(f64, n));

    try std.testing.expectApproxEqAbs(level, peak, 0.01);
    try std.testing.expectApproxEqAbs(level * std.math.sqrt1_2, rms, 0.01);
    // Energy sits at the carrier bin; an off bin is negligible.
    try std.testing.expectApproxEqAbs(level, binAmp(&buf, k_c), 0.01);
    try std.testing.expect(binAmp(&buf, k_c + 17) < 0.005);
}

test "fm modulation produces sidebands at f_c +/- n*f_m" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(FM_OP_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const n = 4096;
    const k_c = 600; // carrier bin
    const k_m = 50; // modulator bin
    var buf: [n]f64 = undefined;
    var st = FmOpState{};
    var out: f64 = 0;
    const inc_c = @as(f64, @floatFromInt(k_c)) / @as(f64, n);
    const inc_m = @as(f64, @floatFromInt(k_m)) / @as(f64, n);
    // mod is in phase units, so radian index = 2*pi*beta. Use index ~1 rad so
    // J0/J1/J2 dominate cleanly (J1(1)~0.44, J2(1)~0.115).
    const beta = 1.0 / (2.0 * std.math.pi);
    var mphase: f64 = 0;

    for (&buf) |*s| {
        const mod = beta * polySin(mphase);
        mphase = mphase + inc_m - @floor(mphase + inc_m);
        try fyStep(&host, &out, &st, inc_c, mod, 1.0, 0.0);
        s.* = out;
    }

    const carrier = binAmp(&buf, k_c);
    const upper1 = binAmp(&buf, k_c + k_m);
    const lower1 = binAmp(&buf, k_c - k_m);
    const upper2 = binAmp(&buf, k_c + 2 * k_m);
    const off = binAmp(&buf, k_c + k_m / 2); // not on the f_m grid

    // First-order sidebands are strong and symmetric; the second order shows
    // up; nothing leaks between the grid lines.
    try std.testing.expect(upper1 > 0.2);
    try std.testing.expect(lower1 > 0.2);
    try std.testing.expectApproxEqAbs(upper1, lower1, 0.02);
    try std.testing.expect(upper2 > 0.02);
    try std.testing.expect(off < 0.01);
    try std.testing.expect(std.math.isFinite(carrier));
}
