//! Rig validation for the 6-op DX7 voice / algorithm matrix
//! (kernels/06-voices/dx7_voice.fy).
//!
//! Equivalence pins the unrolled 6-operator routing codegen against a
//! plain-Zig reference. Two known algorithm configs confirm the matrix
//! actually routes: a 2-op stack makes FM sidebands; six carriers make six
//! independent partials.

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const VOICE_PATH = "kernels/06-voices/dx7_voice.fy";

// Layout mirrors Dx7VoiceParams — do not reorder.
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

// dsp-std sin2pi, mirrored op for op (src/dsp_std_ref.zig).
const polySin = @import("dsp_std_ref.zig").sin2pi;

// One operator step on op `i` of an 18-f64 state (phase,fb1,fb2 per op).
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

fn voiceFy(host: *FyHost, out: *f64, st: *[18]f64, p: *const Params) !void {
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(out) },
        .{ .ptr = @intFromPtr(st) },
        .{ .ptr = @intFromPtr(p) },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-dx7-voice", 1, &args);
}

test "k-dx7-voice matches the Zig reference (codegen pin)" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(VOICE_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    // A mixed config: a feedback op, a couple of modulation paths, three carriers.
    var p = Params{};
    p.inc0 = 0.010;
    p.inc1 = 0.013;
    p.inc2 = 0.017;
    p.inc3 = 0.019;
    p.inc4 = 0.023;
    p.inc5 = 0.029;
    p.lvl0 = 0.5;
    p.lvl1 = 0.5;
    p.lvl2 = 0.5;
    p.lvl3 = 0.5;
    p.lvl4 = 0.5;
    p.lvl5 = 0.5;
    p.fb5 = 0.4;
    p.w45 = 0.3;
    p.w04 = 0.2;
    p.w12 = 0.15;
    p.c0 = 1.0;
    p.c1 = 1.0;
    p.c2 = 0.5;

    var fy_state = [_]f64{0} ** 18;
    var ref_state = [_]f64{0} ** 18;
    var fy_out: f64 = 0;
    var max_err: f64 = 0;

    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const ref = voiceStep(&ref_state, &p);
        try voiceFy(&host, &fy_out, &fy_state, &p);
        try std.testing.expect(std.math.isFinite(fy_out));
        max_err = @max(max_err, @abs(fy_out - ref));
    }
    try std.testing.expect(max_err < 1e-9);
}

test "dx7 voice 2-op stack makes FM sidebands" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(VOICE_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const n = 4096;
    const k_c = 400;
    const k_m = 60;
    // op1 (index 1) modulates op0 (index 0, the only carrier).
    var p = Params{};
    p.inc0 = @as(f64, @floatFromInt(k_c)) / @as(f64, n);
    p.inc1 = @as(f64, @floatFromInt(k_m)) / @as(f64, n);
    p.lvl0 = 1.0;
    p.lvl1 = 1.0 / (2.0 * std.math.pi); // radian index ~1
    p.w01 = 1.0;
    p.c0 = 1.0;

    var st = [_]f64{0} ** 18;
    var out: f64 = 0;
    var buf: [n]f64 = undefined;
    for (&buf) |*s| {
        try voiceFy(&host, &out, &st, &p);
        s.* = out;
    }
    try std.testing.expect(binAmp(&buf, k_c + k_m) > 0.2);
    try std.testing.expect(binAmp(&buf, k_c - k_m) > 0.2);
    try std.testing.expectApproxEqAbs(binAmp(&buf, k_c + k_m), binAmp(&buf, k_c - k_m), 0.02);
    try std.testing.expect(binAmp(&buf, k_c + k_m / 2) < 0.01); // off-grid quiet
}

test "dx7 voice six carriers make six independent partials" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile(VOICE_PATH);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const n = 4096;
    const bins = [_]usize{ 100, 150, 200, 260, 330, 400 };
    const lvl = 0.3;
    var p = Params{};
    // All six operators are carriers at distinct frequencies, no routing.
    inline for (.{ "inc0", "inc1", "inc2", "inc3", "inc4", "inc5" }, 0..) |f, i| {
        @field(p, f) = @as(f64, @floatFromInt(bins[i])) / @as(f64, n);
    }
    inline for (.{ "lvl0", "lvl1", "lvl2", "lvl3", "lvl4", "lvl5" }) |f| @field(p, f) = lvl;
    inline for (.{ "c0", "c1", "c2", "c3", "c4", "c5" }) |f| @field(p, f) = 1.0;

    var st = [_]f64{0} ** 18;
    var out: f64 = 0;
    var buf: [n]f64 = undefined;
    for (&buf) |*s| {
        try voiceFy(&host, &out, &st, &p);
        s.* = out;
    }
    for (bins) |b| try std.testing.expectApproxEqAbs(lvl, binAmp(&buf, b), 0.02);
    try std.testing.expect(binAmp(&buf, 175) < 0.01); // nothing between partials
}
