//! Equivalence test: the fy `fms20-svf` fused primitive (called via
//! `k-ms20-svf` in kernels/04-filters/ms20_svf.fy) must reproduce the exact
//! "g-wet" MS-20 topology from the Python listening oracle
//! (tools/audio_probe/render_ms20_sweeps.py, profile g-wet).
//!
//! The reference `gWetStep` below transcribes that filter_step operation for
//! operation. Both sides receive identical per-sample coefficients, so this
//! pins the JIT codegen (offsets, ops, register threading) to the model.

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const SVF_PATH = "kernels/04-filters/ms20_svf.fy";

// extern layout mirrors the SvfState / SvfParams ustructs in ms20_svf.fy and
// the offsets baked into the fms20-svf primitive.
const SvfState = extern struct {
    ic1: f64 = 0,
    ic2: f64 = 0,
    fb_dc: f64 = 0,
    out_dc: f64 = 0,
};

const SvfParams = extern struct {
    g: f64 = 0,
    damping: f64 = 0,
    drive: f64 = 0,
    resonance: f64 = 0,
    fb_gain: f64 = 0,
    fb_clip: f64 = 0,
    out_clip: f64 = 0,
    leak: f64 = 0,
    fb_dc_coeff: f64 = 0,
    out_dc_coeff: f64 = 0,
};

// g-wet profile (render_ms20_sweeps.py PROFILES["g-wet"]).
const GWET = struct {
    const drive: f64 = 1.90;
    const fb_gain: f64 = 5.4;
    const fb_clip: f64 = 2.70;
    const out_clip: f64 = 2.10;
    const damping_base: f64 = 0.58;
    const damping_res: f64 = 6.2;
    const leak: f64 = 0.99988;
};

const SAMPLE_RATE: f64 = 48_000.0;
const OVERSAMPLE: f64 = 4.0;

// rational-tanh clip, matching fy's emitTanhRationalInto (no +-5 preclamp;
// the outer [-1,1] clamp makes it a no-op for our signal range).
fn tanhRational(x: f64) f64 {
    const x2 = x * x;
    const num = x * (27.0 + x2);
    const den = 27.0 + 9.0 * x2;
    var y = num / den;
    y = @max(y, -1.0);
    y = @min(y, 1.0);
    return y;
}

fn clipA(x: f64, amount: f64) f64 {
    return tanhRational(x * amount);
}

// Fill SvfParams entirely in fy via the three coeff words.
fn fyFillCoeffs(host: *FyHost, p: *SvfParams, cutoff: f64, resonance: f64, os_rate: f64) !void {
    const tone = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(p) },
        .{ .f64 = cutoff },
        .{ .f64 = resonance },
        .{ .f64 = os_rate },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-svf-coeffs-tone", 1, &tone);
    const dc = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(p) },
        .{ .f64 = os_rate },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-svf-coeffs-dc", 1, &dc);
    const profile = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(p) },
        .{ .f64 = resonance },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-svf-coeffs-profile", 1, &profile);
}

// Reference g-wet sample step, operation-for-operation identical to the fy
// fms20-svf codegen (same float associations).
fn gWetStep(st: *SvfState, p: SvfParams, x: f64) f64 {
    const two_damping = p.damping + p.damping;
    const a2dg = two_damping + p.g;
    var h = 1.0 + two_damping * p.g;
    h = h + p.g * p.g;
    h = 1.0 / h;
    const xd = x * p.drive;
    const rfg = p.resonance * p.fb_gain;

    var out: f64 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var d = st.ic2 - st.fb_dc;
        st.fb_dc = st.fb_dc + p.fb_dc_coeff * d;
        d = st.ic2 - st.fb_dc;
        const feedback = clipA(d * rfg, p.fb_clip);
        const driven = clipA(xd - feedback, 1.0);

        var hp = driven - a2dg * st.ic1;
        hp = hp - st.ic2;
        hp = hp * h;
        const ghp = p.g * hp;
        const bp = ghp + st.ic1;
        const next_ic1 = ghp + bp;
        st.ic1 = p.leak * next_ic1;
        const gbp = p.g * bp;
        const lp = gbp + st.ic2;
        const next_ic2 = gbp + lp;
        st.ic2 = p.leak * next_ic2;

        const colored = clipA(lp + 0.20 * bp, p.out_clip);
        st.out_dc = st.out_dc + p.out_dc_coeff * (colored - st.out_dc);
        out = colored - st.out_dc;
    }
    return out;
}

// Per-sample coefficient prep (computed in the test; later moves into an fy
// coeff word). Matches the Python filter_step coefficient math.
fn fillCoeffs(p: *SvfParams, cutoff_hz: f64, resonance: f64) void {
    const os_rate = SAMPLE_RATE * OVERSAMPLE;
    const fc = std.math.clamp(cutoff_hz, 20.0, SAMPLE_RATE * 0.42);
    p.g = @tan(std.math.pi * fc / os_rate);
    p.damping = @max(0.035, GWET.damping_base / (1.0 + resonance * GWET.damping_res));
    p.drive = GWET.drive;
    p.resonance = resonance;
    p.fb_gain = GWET.fb_gain;
    p.fb_clip = GWET.fb_clip;
    p.out_clip = GWET.out_clip;
    p.leak = GWET.leak;
    p.fb_dc_coeff = 1.0 - @exp(-2.0 * std.math.pi * 18.0 / os_rate);
    p.out_dc_coeff = 1.0 - @exp(-2.0 * std.math.pi * 10.0 / os_rate);
}

test "fms20-svf matches the g-wet oracle topology over a cutoff sweep" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(SVF_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const n: usize = 8192;
    const resonance: f64 = 1.08;

    var fy_state = SvfState{};
    var ref_state = SvfState{};
    var params = SvfParams{};
    var fy_out: f64 = 0;

    // deterministic naive saw input (exercises the nonlinearity; both sides
    // get the identical sample so the waveform shape is irrelevant).
    var phase: f64 = 0.19;
    const dt: f64 = 110.0 / SAMPLE_RATE;

    var max_abs_err: f64 = 0;
    var peak: f64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const pos = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        const cutoff = 90.0 * @exp(@log(7200.0 / 90.0) * pos);
        fillCoeffs(&params, cutoff, resonance);

        const x = (phase + phase - 1.0) * 0.6;
        phase += dt;
        if (phase >= 1.0) phase -= 1.0;

        const ref = gWetStep(&ref_state, params, x);

        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&fy_out) },
            .{ .ptr = @intFromPtr(&fy_state) },
            .{ .ptr = @intFromPtr(&params) },
            .{ .f64 = x },
            .{ .f64 = params.g },
            .{ .f64 = params.damping },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-ms20-svf", 1, &args);

        try std.testing.expect(std.math.isFinite(fy_out));
        max_abs_err = @max(max_abs_err, @abs(fy_out - ref));
        peak = @max(peak, @abs(ref));
    }

    // The filter must actually move/resonate (not a flat lowpass).
    try std.testing.expect(peak > 0.05);
    // fy JIT output must track the reference to tight tolerance.
    try std.testing.expect(max_abs_err < 1e-9);
}

test "k-ms20-svf-coeffs computes g-wet coefficients in fy (no host/libm)" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(SVF_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const os_rate = SAMPLE_RATE * OVERSAMPLE;
    const cutoffs = [_]f64{ 90.0, 480.0, 1800.0, 7200.0, 19000.0 };
    const resonances = [_]f64{ 0.2, 1.08, 1.38 };

    for (resonances) |res| {
        for (cutoffs) |cutoff| {
            var fy_p = SvfParams{};
            try fyFillCoeffs(&host, &fy_p, cutoff, res, os_rate);

            var ref = SvfParams{};
            fillCoeffs(&ref, cutoff, res); // libm tan/exp reference (== Python)

            // tan via tiny-angle series: should track libm to ~1e-5.
            try std.testing.expectApproxEqAbs(ref.g, fy_p.g, 1e-4);
            // pure arithmetic — should be tight.
            try std.testing.expectApproxEqAbs(ref.damping, fy_p.damping, 1e-9);
            // 1-exp(-a) tiny-arg series — very accurate.
            try std.testing.expectApproxEqAbs(ref.fb_dc_coeff, fy_p.fb_dc_coeff, 1e-7);
            try std.testing.expectApproxEqAbs(ref.out_dc_coeff, fy_p.out_dc_coeff, 1e-7);
            // profile constants — exact.
            try std.testing.expectApproxEqAbs(ref.drive, fy_p.drive, 1e-12);
            try std.testing.expectApproxEqAbs(ref.resonance, fy_p.resonance, 1e-12);
            try std.testing.expectApproxEqAbs(ref.fb_gain, fy_p.fb_gain, 1e-12);
            try std.testing.expectApproxEqAbs(ref.fb_clip, fy_p.fb_clip, 1e-12);
            try std.testing.expectApproxEqAbs(ref.out_clip, fy_p.out_clip, 1e-12);
            try std.testing.expectApproxEqAbs(ref.leak, fy_p.leak, 1e-12);
        }
    }
}

// End-to-end: coeffs computed in fy + filter in fy must still match the
// g-wet oracle topology fed with libm coeffs, within an audio tolerance
// (the only difference is the tiny-angle tan/exp approximation).
test "fy coeffs + fms20-svf track the oracle end to end" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(SVF_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const os_rate = SAMPLE_RATE * OVERSAMPLE;
    const n: usize = 8192;
    const resonance: f64 = 1.08;

    var fy_state = SvfState{};
    var ref_state = SvfState{};
    var fy_params = SvfParams{};
    var ref_params = SvfParams{};
    var fy_out: f64 = 0;

    var phase: f64 = 0.19;
    const dt: f64 = 110.0 / SAMPLE_RATE;
    var max_abs_err: f64 = 0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const pos = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        const cutoff = 90.0 * @exp(@log(7200.0 / 90.0) * pos);

        // fy computes its own coeffs; reference uses libm.
        try fyFillCoeffs(&host, &fy_params, cutoff, resonance, os_rate);
        fillCoeffs(&ref_params, cutoff, resonance);

        const x = (phase + phase - 1.0) * 0.6;
        phase += dt;
        if (phase >= 1.0) phase -= 1.0;

        const ref = gWetStep(&ref_state, ref_params, x);
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&fy_out) },
            .{ .ptr = @intFromPtr(&fy_state) },
            .{ .ptr = @intFromPtr(&fy_params) },
            .{ .f64 = x },
            .{ .f64 = fy_params.g },
            .{ .f64 = fy_params.damping },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-ms20-svf", 1, &args);

        try std.testing.expect(std.math.isFinite(fy_out));
        max_abs_err = @max(max_abs_err, @abs(fy_out - ref));
    }

    // Whole-signal: fy (poly coeffs) vs oracle (libm coeffs) — audio tolerance.
    try std.testing.expect(max_abs_err < 5e-3);
}
