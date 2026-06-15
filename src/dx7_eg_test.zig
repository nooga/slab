//! Rig validation for the DX7 envelope kernel
//! (kernels/03-envelopes/dx7_eg.fy).
//!
//! Equivalence pins the branchless stage/ramp codegen against a plain-Zig
//! reference (the dB-domain `value` is exact arithmetic → ~1e-12; the gain
//! goes through exp2-approx so it's checked at the looser exp2 tolerance).
//! Behavioral tests prove the DX7-specific structure: reaches each level,
//! segment timing, exponential shape, note-off, retrigger-from-current, and
//! key rate scaling.

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const EG_PATH = "kernels/03-envelopes/dx7_eg.fy";

// Mirror ustruct Dx7EgState / Dx7EgParams — do not reorder.
const EgState = extern struct {
    value: f64 = 0,
    stage: f64 = 4, // idle = released at L4
    prev_gate: f64 = 0,
};
const EgParams = extern struct {
    step1: f64,
    step2: f64,
    step3: f64,
    step4: f64,
    l1: f64,
    l2: f64,
    l3: f64,
    l4: f64,
    rate_scale: f64,
};

fn defaultParams() EgParams {
    return .{ .step1 = 0.01, .step2 = 0.004, .step3 = 0.003, .step4 = 0.002, .l1 = 1.0, .l2 = 0.7, .l3 = 0.5, .l4 = 0.0, .rate_scale = 1.0 };
}

fn selLt(a: f64, b: f64, t: f64, f: f64) f64 {
    return if (a < b) t else f;
}

// Zig reference: returns the new dB-domain value, updates state. Mirrors
// dx7-eg-step exactly (same fsel-lt branchless logic).
fn egStep(st: *EgState, p: *const EgParams, gate: f64) f64 {
    const value = st.value;
    const stage = st.stage;
    const pgate = st.prev_gate;
    const onedge = selLt(0.5, gate, 1.0, 0.0) * selLt(pgate, 0.5, 1.0, 0.0);
    const offedge = selLt(gate, 0.5, 1.0, 0.0) * selLt(0.5, pgate, 1.0, 0.0);
    const stageb = selLt(0.5, offedge, 4.0, selLt(0.5, onedge, 1.0, stage));
    const target = selLt(stageb, 1.5, p.l1, selLt(stageb, 2.5, p.l2, selLt(stageb, 3.5, p.l3, p.l4)));
    const step = selLt(stageb, 1.5, p.step1, selLt(stageb, 2.5, p.step2, selLt(stageb, 3.5, p.step3, p.step4))) * p.rate_scale;
    const diff = target - value;
    const adiff = selLt(0.0, diff, diff, 0.0 - diff);
    const sstep = selLt(0.0, diff, step, 0.0 - step);
    const reached = selLt(step, adiff, 0.0, 1.0);
    const newval = std.math.clamp(selLt(0.5, reached, target, value + sstep), 0.0, 1.0);
    const advance = reached * selLt(stageb, 2.5, 1.0, 0.0);
    const newstage = selLt(0.5, advance, stageb + 1.0, stageb);
    st.stage = newstage;
    st.value = newval;
    st.prev_gate = gate;
    return newval;
}

fn gainOf(value: f64) f64 {
    return std.math.exp2((value - 1.0) * 16.0);
}

fn egFy(host: *FyHost, out: *f64, st: *EgState, p: *const EgParams, gate: f64) !void {
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(out) },
        .{ .ptr = @intFromPtr(st) },
        .{ .ptr = @intFromPtr(p) },
        .{ .f64 = gate },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-dx7-eg", 1, &args);
}

test "k-dx7-eg matches the Zig reference (value exact, gain within exp2 tol)" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(EG_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const p = defaultParams();
    var fy_state = EgState{};
    var ref_state = EgState{};
    var fy_out: f64 = 0;
    var max_value_err: f64 = 0;
    var max_gain_err: f64 = 0;

    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const gate: f64 = if (i >= 50 and i < 2500) 1.0 else 0.0; // on then off
        const ref_value = egStep(&ref_state, &p, gate);
        try egFy(&host, &fy_out, &fy_state, &p, gate);
        try std.testing.expect(std.math.isFinite(fy_out));
        max_value_err = @max(max_value_err, @abs(fy_state.value - ref_value));
        max_gain_err = @max(max_gain_err, @abs(fy_out - gainOf(ref_value)));
    }
    try std.testing.expect(max_value_err < 1e-12);
    try std.testing.expect(max_gain_err < 1e-4);
}

test "dx7 eg reaches each segment level and holds at sustain" {
    var st = EgState{};
    const p = defaultParams();
    // Long gate-on: attack to L1, decay to L2, decay to L3, then hold.
    var i: usize = 0;
    var v: f64 = 0;
    while (i < 3000) : (i += 1) v = egStep(&st, &p, 1.0);
    try std.testing.expectApproxEqAbs(p.l3, v, 1e-9); // settled at sustain L3
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), st.stage, 1e-9); // holding in segment 3
}

test "dx7 eg segment timing follows the step rate" {
    var st = EgState{};
    const p = defaultParams();
    // From 0, segment 1 ramps to L1=1.0 at step1=0.01 → ~100 samples.
    var reached_at: usize = 0;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        _ = egStep(&st, &p, 1.0);
        if (st.stage > 1.5 and reached_at == 0) reached_at = i; // advanced past seg 1
    }
    const expected: f64 = p.l1 / p.step1; // 100
    try std.testing.expectApproxEqAbs(expected, @as(f64, @floatFromInt(reached_at)), 2.0);
}

test "dx7 eg ramp is exponential in amplitude (linear in dB)" {
    var st = EgState{};
    const p = defaultParams();
    // Walk into segment 2 (L1->L2 descent) and sample the gain ratio, which
    // must be constant for an exponential (dB-linear) ramp.
    var i: usize = 0;
    while (i < 130) : (i += 1) _ = egStep(&st, &p, 1.0); // ~100 attack + into decay
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), st.stage, 1e-9);

    var prev = gainOf(st.value);
    var first_ratio: f64 = 0;
    var max_dev: f64 = 0;
    var k: usize = 0;
    while (k < 40) : (k += 1) {
        const g = gainOf(egStep(&st, &p, 1.0));
        const ratio = g / prev;
        if (k == 0) first_ratio = ratio else max_dev = @max(max_dev, @abs(ratio - first_ratio));
        prev = g;
    }
    try std.testing.expect(max_dev < 1e-6); // constant ratio ⇒ exponential
}

test "dx7 eg note-off releases from the current level" {
    var st = EgState{};
    const p = defaultParams();
    var i: usize = 0;
    while (i < 1500) : (i += 1) _ = egStep(&st, &p, 1.0); // reach sustain L3
    const at_release = st.value;
    try std.testing.expectApproxEqAbs(p.l3, at_release, 1e-6);
    // Note-off → segment 4 toward L4=0, descending from the current value.
    _ = egStep(&st, &p, 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), st.stage, 1e-9);
    var j: usize = 0;
    while (j < 50) : (j += 1) _ = egStep(&st, &p, 0.0);
    try std.testing.expect(st.value < at_release); // released, moving toward 0
}

test "dx7 eg retrigger continues from the current value (no reset)" {
    var st = EgState{};
    const p = defaultParams();
    // Partial attack, release a bit, then retrigger.
    var i: usize = 0;
    while (i < 40) : (i += 1) _ = egStep(&st, &p, 1.0); // ~0.4 up
    var j: usize = 0;
    while (j < 10) : (j += 1) _ = egStep(&st, &p, 0.0); // release a little
    const before = st.value;
    _ = egStep(&st, &p, 1.0); // retrigger edge: stage→1, value kept
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), st.stage, 1e-9);
    // One attack step up from `before` — no jump to zero.
    try std.testing.expect(st.value > before - 1e-9);
    try std.testing.expect(@abs(st.value - before) < p.step1 + 1e-9);
}

test "dx7 eg key rate scaling speeds the envelope proportionally" {
    const base = defaultParams();
    var fast = base;
    fast.rate_scale = 2.0;

    var st1 = EgState{};
    var st2 = EgState{};
    var t1: usize = 0;
    var t2: usize = 0;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        _ = egStep(&st1, &base, 1.0);
        _ = egStep(&st2, &fast, 1.0);
        if (st1.stage > 1.5 and t1 == 0) t1 = i;
        if (st2.stage > 1.5 and t2 == 0) t2 = i;
    }
    // 2x rate ⇒ ~half the samples to clear segment 1.
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(t1)), 2.0 * @as(f64, @floatFromInt(t2)), 3.0);
}
