//! Rig validation for the FM-86 voice stages (kernels/06-voices/fm86_voice.fy).
//!
//! The machine runs ONE word per sample (k-fm86-voice-sample), which composes
//! the stages with `call:`. The raw-register probe path can't build a `call:`
//! word, so here we drive the same stages directly — six fm86-eg-opN (each one
//! validated dx7-eg-step writing gain*output-level into its lvl slot) then the
//! matrix — and pin the result sample-exact against the plain-Zig reference.
//! The composed call: word itself is exercised end-to-end via the machine
//! adapter (src/machines/fy_raw_machine.zig).

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const PATH = "kernels/06-voices/fm86_voice.fy";

// Mirrors ustruct Fm86State: 6 op phase blocks, 6 EG blocks, gate, note-hz.
const State = extern struct {
    op: [18]f64 = [_]f64{0} ** 18,
    eg: [18]f64 = [_]f64{0} ** 18, // per op: value, stage, prev-gate
    gate: f64 = 0,
    note_hz: f64 = 0,
    vout: f64 = 0,
};

// Mirrors ustruct Fm86Params (110 f64). The first 39 are a Dx7VoiceParams.
const Params = extern struct {
    inc: [6]f64 = [_]f64{0} ** 6,
    lvl: [6]f64 = [_]f64{0} ** 6, // written by the kernel each sample
    fb: [6]f64 = [_]f64{0} ** 6,
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
    c: [6]f64 = [_]f64{0} ** 6,
    eg: [54]f64 = [_]f64{0} ** 54, // 6 blocks of step1-4, l1-4, rate-scale
    ol: [6]f64 = [_]f64{0} ** 6,
    ratio: [6]f64 = [_]f64{0} ** 6,
    algo: f64 = 0,
    feedback: f64 = 0,
    master: f64 = 0,
    inv_sr: f64 = 0,
};

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
    const o5 = op(st, 5, p.inc[5], 0.0, p.lvl[5], p.fb[5]);
    const o4 = op(st, 4, p.inc[4], p.w45 * o5, p.lvl[4], p.fb[4]);
    const o3 = op(st, 3, p.inc[3], p.w34 * o4 + p.w35 * o5, p.lvl[3], p.fb[3]);
    const o2 = op(st, 2, p.inc[2], p.w23 * o3 + p.w24 * o4 + p.w25 * o5, p.lvl[2], p.fb[2]);
    const o1 = op(st, 1, p.inc[1], p.w12 * o2 + p.w13 * o3 + p.w14 * o4 + p.w15 * o5, p.lvl[1], p.fb[1]);
    const o0 = op(st, 0, p.inc[0], p.w01 * o1 + p.w02 * o2 + p.w03 * o3 + p.w04 * o4 + p.w05 * o5, p.lvl[0], p.fb[0]);
    return p.c[0] * o0 + p.c[1] * o1 + p.c[2] * o2 + p.c[3] * o3 + p.c[4] * o4 + p.c[5] * o5;
}

fn selLt(a: f64, b: f64, t: f64, f: f64) f64 {
    return if (a < b) t else f;
}

// One EG step on op `i`'s 3-slot state; params block at p.eg[i*9..], returns gain.
fn egGain(st: []f64, ep: []const f64, gate: f64) f64 {
    const value = st[0];
    const stage = st[1];
    const pgate = st[2];
    const step1 = ep[0];
    const step2 = ep[1];
    const step3 = ep[2];
    const step4 = ep[3];
    const l1 = ep[4];
    const l2 = ep[5];
    const l3 = ep[6];
    const l4 = ep[7];
    const rs = ep[8];
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

fn renderRef(st: *State, p: *Params, gate: f64) f64 {
    inline for (0..6) |i| {
        p.lvl[i] = p.ol[i] * egGain(st.eg[i * 3 .. i * 3 + 3], p.eg[i * 9 .. i * 9 + 9], gate);
    }
    return voiceStep(&st.op, p);
}

// Drive the voice the way k-fm86-voice-sample's `call:` stages do, but as
// separate raw-probe calls: the raw-register probe path cannot build a word
// containing `call:` (only the machine's caller path can), so we exercise each
// stage word — none of which contain `call:` — directly. This pins the staged
// DSP sample-exact; the composed call: word itself is covered by the machine
// end-to-end test (src/machines/fy_raw_machine.zig).
const EG_WORDS = [_][:0]const u8{ "fm86-eg-op0", "fm86-eg-op1", "fm86-eg-op2", "fm86-eg-op3", "fm86-eg-op4", "fm86-eg-op5" };

fn renderFy(host: *FyHost, out: *f64, st: *State, p: *Params, gate: f64) !void {
    st.gate = gate;
    const eg_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(st) }, .{ .ptr = @intFromPtr(p) } };
    for (EG_WORDS) |w| {
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(w, 1, &eg_args);
    }
    const voice_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(out) },
        .{ .ptr = @intFromPtr(st) },
        .{ .ptr = @intFromPtr(p) },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-dx7-voice", 1, &voice_args);
}

fn initIdle(st: *State) void {
    inline for (0..6) |i| st.eg[i * 3 + 1] = 4.0; // stage = 4 (idle), value 0
}

fn setEg(p: *Params, i: usize, s1: f64, s2: f64, s3: f64, s4: f64, l1: f64, l2: f64, l3: f64, l4: f64, rs: f64) void {
    const b = i * 9;
    p.eg[b] = s1;
    p.eg[b + 1] = s2;
    p.eg[b + 2] = s3;
    p.eg[b + 3] = s4;
    p.eg[b + 4] = l1;
    p.eg[b + 5] = l2;
    p.eg[b + 6] = l3;
    p.eg[b + 7] = l4;
    p.eg[b + 8] = rs;
}

test "fm86 voice stages match the Zig reference" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    // 2-op: op1 modulates op0 (the only carrier), each with its own envelope.
    var p = Params{};
    p.inc[0] = 220.0 / 48000.0;
    p.inc[1] = 220.0 / 48000.0;
    p.w01 = 1.0;
    p.c[0] = 1.0;
    p.ol[0] = 1.0;
    p.ol[1] = 0.16;
    setEg(&p, 0, 0.01, 0.008, 0.004, 0.01, 1.0, 0.9, 0.8, 0.0, 1.0);
    setEg(&p, 1, 0.012, 0.006, 0.004, 0.01, 1.0, 0.7, 0.5, 0.0, 1.0);

    var fy_p = p;
    var ref_p = p;
    var fy_st = State{};
    var ref_st = State{};
    initIdle(&fy_st);
    initIdle(&ref_st);

    var fy_out: f64 = 0;
    var max_err: f64 = 0;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        const gate: f64 = if (i >= 20 and i < 400) 1.0 else 0.0;
        const ref = renderRef(&ref_st, &ref_p, gate);
        try renderFy(&host, &fy_out, &fy_st, &fy_p, gate);
        try std.testing.expect(std.math.isFinite(fy_out));
        max_err = @max(max_err, @abs(fy_out - ref));
    }
    try std.testing.expect(max_err < 5e-4);
}

test "fm86 voice envelope shapes amplitude (silent -> swell -> release)" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    var p = Params{};
    p.inc[0] = 0.02;
    p.inc[1] = 0.02;
    p.w01 = 1.0;
    p.c[0] = 1.0;
    p.ol[0] = 1.0;
    p.ol[1] = 0.16;
    setEg(&p, 0, 0.01, 0.01, 0.005, 0.01, 1.0, 0.97, 0.95, 0.0, 1.0);
    setEg(&p, 1, 0.01, 0.01, 0.005, 0.01, 1.0, 0.8, 0.7, 0.0, 1.0);

    var st = State{};
    initIdle(&st);
    var out: f64 = 0;
    const n = 900;
    var buf: [n]f64 = undefined;
    for (&buf, 0..) |*s, i| {
        const gate: f64 = if (i < 550) 1.0 else 0.0;
        try renderFy(&host, &out, &st, &p, gate);
        s.* = out;
    }

    const rms = struct {
        fn f(x: []const f64, a: usize, b: usize) f64 {
            var s: f64 = 0;
            for (x[a..b]) |v| s += v * v;
            return @sqrt(s / @as(f64, @floatFromInt(b - a)));
        }
    }.f;

    try std.testing.expect(rms(&buf, 0, 40) < 0.01); // starts silent
    try std.testing.expect(rms(&buf, 400, 500) > 0.1); // swells
    try std.testing.expect(rms(&buf, 820, 900) < 0.02); // releases
}
