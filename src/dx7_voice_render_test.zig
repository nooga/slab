//! Rig validation for the complete DX7 voice (6 ops + 6 envelopes + matrix),
//! kernels/06-voices/dx7_voice_render.fy.
//!
//! The per-op envelope gain runs through exp2-approx, so render equivalence is
//! at audio tolerance — the tight codegen pins live in the component tests
//! (operator <1e-9, eg value <1e-12, voice <1e-9). Here we confirm the wiring:
//! envelopes scale operator levels and the matrix sums correctly, and a
//! behavioral test shows the envelope actually shapes the voice amplitude.

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const PATH = "kernels/06-voices/dx7_voice_render.fy";

const Params = extern struct {
    inc0: f64 = 0,
    inc1: f64 = 0,
    inc2: f64 = 0,
    inc3: f64 = 0,
    inc4: f64 = 0,
    inc5: f64 = 0,
    lvl0: f64 = 0,
    lvl1: f64 = 0,
    lvl2: f64 = 0,
    lvl3: f64 = 0,
    lvl4: f64 = 0,
    lvl5: f64 = 0,
    fb0: f64 = 0,
    fb1: f64 = 0,
    fb2: f64 = 0,
    fb3: f64 = 0,
    fb4: f64 = 0,
    fb5: f64 = 0,
    w01: f64 = 0,
    w02: f64 = 0,
    w03: f64 = 0,
    w04: f64 = 0,
    w05: f64 = 0,
    w12: f64 = 0,
    w13: f64 = 0,
    w14: f64 = 0,
    w15: f64 = 0,
    w23: f64 = 0,
    w24: f64 = 0,
    w25: f64 = 0,
    w34: f64 = 0,
    w35: f64 = 0,
    w45: f64 = 0,
    c0: f64 = 0,
    c1: f64 = 0,
    c2: f64 = 0,
    c3: f64 = 0,
    c4: f64 = 0,
    c5: f64 = 0,
};

fn selLt(a: f64, b: f64, t: f64, f: f64) f64 {
    return if (a < b) t else f;
}
// dsp-std sin2pi, mirrored op for op (src/dsp_std_ref.zig).
const polySin = @import("dsp_std_ref.zig").sin2pi;
fn op(st: *[18]f64, i: usize, inc: f64, mod: f64, level: f64, fb: f64) f64 {
    const b = i * 3;
    const fbmod = fb * 0.5 * (st[b + 1] + st[b + 2]);
    const out = level * polySin(st[b] + mod + fbmod);
    st[b + 2] = st[b + 1];
    st[b + 1] = out;
    const adv = st[b] + inc;
    st[b] = adv - @floor(adv);
    return out;
}
fn voiceStep(st: *[18]f64, p: *const Params) f64 {
    const o5 = op(st, 5, p.inc5, 0.0, p.lvl5, p.fb5);
    const o4 = op(st, 4, p.inc4, p.w45 * o5, p.lvl4, p.fb4);
    const o3 = op(st, 3, p.inc3, p.w34 * o4 + p.w35 * o5, p.lvl3, p.fb3);
    const o2 = op(st, 2, p.inc2, p.w23 * o3 + p.w24 * o4 + p.w25 * o5, p.lvl2, p.fb2);
    const o1 = op(st, 1, p.inc1, p.w12 * o2 + p.w13 * o3 + p.w14 * o4 + p.w15 * o5, p.lvl1, p.fb1);
    const o0 = op(st, 0, p.inc0, p.w01 * o1 + p.w02 * o2 + p.w03 * o3 + p.w04 * o4 + p.w05 * o5, p.lvl0, p.fb0);
    return p.c0 * o0 + p.c1 * o1 + p.c2 * o2 + p.c3 * o3 + p.c4 * o4 + p.c5 * o5;
}

// One EG step on op `i`'s 3-slot state, params block at ep[base..], returns gain.
fn egGain(st: []f64, ep: []const f64, base: usize, gate: f64) f64 {
    const value = st[0];
    const stage = st[1];
    const pgate = st[2];
    const step1 = ep[base];
    const step2 = ep[base + 1];
    const step3 = ep[base + 2];
    const step4 = ep[base + 3];
    const l1 = ep[base + 4];
    const l2 = ep[base + 5];
    const l3 = ep[base + 6];
    const l4 = ep[base + 7];
    const rs = ep[base + 8];
    const onedge = selLt(0.5, gate, 1.0, 0.0) * selLt(pgate, 0.5, 1.0, 0.0);
    const offedge = selLt(gate, 0.5, 1.0, 0.0) * selLt(0.5, pgate, 1.0, 0.0);
    const stageb = selLt(0.5, offedge, 4.0, selLt(0.5, onedge, 1.0, stage));
    const target = selLt(stageb, 1.5, l1, selLt(stageb, 2.5, l2, selLt(stageb, 3.5, l3, l4)));
    const step = selLt(stageb, 1.5, step1, selLt(stageb, 2.5, step2, selLt(stageb, 3.5, step3, step4))) * rs;
    const diff = target - value;
    const adiff = selLt(0.0, diff, diff, 0.0 - diff);
    const sstep = selLt(0.0, diff, step, 0.0 - step);
    const reached = selLt(step, adiff, 0.0, 1.0);
    const newval = std.math.clamp(selLt(0.5, reached, target, value + sstep), 0.0, 1.0);
    const advance = reached * selLt(stageb, 2.5, 1.0, 0.0);
    st[0] = newval;
    st[1] = selLt(0.5, advance, stageb + 1.0, stageb);
    st[2] = gate;
    return std.math.exp2((newval - 1.0) * 16.0);
}

fn renderRef(vstate: *[18]f64, egstate: *[18]f64, vp: *Params, ep: *[60]f64, gate: f64) f64 {
    vp.lvl0 = ep[9] * egGain(egstate[0..3], ep, 0, gate);
    vp.lvl1 = ep[19] * egGain(egstate[3..6], ep, 10, gate);
    vp.lvl2 = ep[29] * egGain(egstate[6..9], ep, 20, gate);
    vp.lvl3 = ep[39] * egGain(egstate[9..12], ep, 30, gate);
    vp.lvl4 = ep[49] * egGain(egstate[12..15], ep, 40, gate);
    vp.lvl5 = ep[59] * egGain(egstate[15..18], ep, 50, gate);
    return voiceStep(vstate, vp);
}

// The complete voice: one k-dx7-eg call per operator (each writes its gain;
// level = gain * output-level), then one k-dx7-voice call for the matrix.
// This is the audio-thread shape — composed from individually-validated
// kernels rather than one fy word (which hits a deep-composition limit).
fn setLvl(vp: *Params, i: usize, v: f64) void {
    switch (i) {
        0 => vp.lvl0 = v,
        1 => vp.lvl1 = v,
        2 => vp.lvl2 = v,
        3 => vp.lvl3 = v,
        4 => vp.lvl4 = v,
        else => vp.lvl5 = v,
    }
}

fn renderFy(host: *FyHost, out: *f64, vstate: *[18]f64, egstate: *[18]f64, ep: *[60]f64, vp: *Params, gate: f64) !void {
    const g = gate;
    for (0..6) |i| {
        var gain: f64 = 0;
        const ega = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&gain) },
            .{ .ptr = @intFromPtr(&egstate[i * 3]) },
            .{ .ptr = @intFromPtr(&ep[i * 10]) },
            .{ .f64 = g },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-dx7-eg", 1, &ega);
        setLvl(vp, i, gain * ep[i * 10 + 9]); // gain * output level
    }
    const voice = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(out) },
        .{ .ptr = @intFromPtr(vstate) },
        .{ .ptr = @intFromPtr(vp) },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-dx7-voice", 1, &voice);
}

// Initialize a 6-EG bank state to idle (stage = 4, value 0) so envelopes hold
// silent until the first note-on edge.
fn initEgBank(es: *[18]f64) void {
    for (0..6) |i| es[i * 3 + 1] = 4.0;
}

// op i's EG block: step1..step4, l1..l4, rate-scale, ol.
fn setEg(ep: *[60]f64, i: usize, s1: f64, s2: f64, s3: f64, s4: f64, l1: f64, l2: f64, l3: f64, l4: f64, rs: f64, ol: f64) void {
    const b = i * 10;
    ep[b] = s1;
    ep[b + 1] = s2;
    ep[b + 2] = s3;
    ep[b + 3] = s4;
    ep[b + 4] = l1;
    ep[b + 5] = l2;
    ep[b + 6] = l3;
    ep[b + 7] = l4;
    ep[b + 8] = rs;
    ep[b + 9] = ol;
}

test "complete voice (eg-bank + voice) matches the Zig reference" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    var vp = Params{};
    vp.inc0 = 220.0 / 48000.0;
    vp.inc1 = 220.0 / 48000.0;
    vp.w01 = 1.0;
    vp.c0 = 1.0;

    var ep = [_]f64{0} ** 60;
    // op0 carrier env, op1 modulator env. Others silent (ol=0).
    setEg(&ep, 0, 0.01, 0.004, 0.003, 0.005, 1.0, 0.8, 0.7, 0.0, 1.0, 1.0);
    setEg(&ep, 1, 0.008, 0.004, 0.003, 0.006, 1.0, 0.6, 0.5, 0.0, 1.0, 0.16);

    var fy_vp = vp;
    var ref_vp = vp;
    var fy_vs = [_]f64{0} ** 18;
    var fy_es = [_]f64{0} ** 18;
    var ref_vs = [_]f64{0} ** 18;
    var ref_es = [_]f64{0} ** 18;
    initEgBank(&fy_es);
    initEgBank(&ref_es);
    var fy_out: f64 = 0;
    var max_err: f64 = 0;

    // Each composed render is 7 fresh JIT links (6 EG + voice), so keep the
    // sample count just large enough to cross every envelope stage (attack →
    // sustain → release): equivalence holds sample-for-sample regardless.
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        const gate: f64 = if (i >= 20 and i < 400) 1.0 else 0.0;
        const ref = renderRef(&ref_vs, &ref_es, &ref_vp, &ep, gate);
        try renderFy(&host, &fy_out, &fy_vs, &fy_es, &ep, &fy_vp, gate);
        try std.testing.expect(std.math.isFinite(fy_out));
        max_err = @max(max_err, @abs(fy_out - ref));
    }
    try std.testing.expect(max_err < 5e-4);
}

test "dx7 voice envelope shapes amplitude (silent -> swell -> release)" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    var vp = Params{};
    vp.inc0 = 0.02;
    vp.inc1 = 0.02;
    vp.w01 = 1.0;
    vp.c0 = 1.0;
    var ep = [_]f64{0} ** 60;
    // Attack carrier with a loud sustain (L3 near 0 dB) and a quick release;
    // modulator with its own env. (L=0.95 -> ~-0.8 dB; lower L maps deep into
    // dB.) Rates are brisk so the swell/release fit a short sample window —
    // each render is 7 fresh JIT links, so we keep the count small.
    setEg(&ep, 0, 0.01, 0.01, 0.005, 0.01, 1.0, 0.97, 0.95, 0.0, 1.0, 1.0);
    setEg(&ep, 1, 0.01, 0.01, 0.005, 0.01, 1.0, 0.8, 0.7, 0.0, 1.0, 0.16);

    var vs = [_]f64{0} ** 18;
    var es = [_]f64{0} ** 18;
    initEgBank(&es);
    var out: f64 = 0;
    const n = 900;
    var buf: [n]f64 = undefined;
    for (&buf, 0..) |*s, i| {
        const gate: f64 = if (i < 550) 1.0 else 0.0; // note off at 550
        try renderFy(&host, &out, &vs, &es, &ep, &vp, gate);
        s.* = out;
    }

    const rmsWin = struct {
        fn f(x: []const f64, a: usize, b: usize) f64 {
            var s: f64 = 0;
            for (x[a..b]) |v| s += v * v;
            return @sqrt(s / @as(f64, @floatFromInt(b - a)));
        }
    }.f;

    const early = rmsWin(&buf, 0, 40); // envelope near zero
    const mid = rmsWin(&buf, 400, 500); // attacked / sustaining
    const late = rmsWin(&buf, 820, 900); // after release

    try std.testing.expect(early < 0.01); // starts silent
    try std.testing.expect(mid > 0.1); // swells
    try std.testing.expect(late < 0.02); // releases back toward silence
}
