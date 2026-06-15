//! DX7 algorithm routing: turn an algorithm spec (which operator modulates
//! which, which are carriers, which has feedback) into the 6-op voice's
//! routing params (kernels/06-voices/dx7_voice.fy). The 32-entry DX7
//! algorithm table is just data to fill into `applyRouting` later; this is
//! the builder + the param layout it writes.
//!
//! Operator numbering is 1..6 (DX7). The voice evaluates op6→op1, so a
//! modulator must have a HIGHER number than the operator it modulates
//! (upper-triangular). `validate` checks this.

const std = @import("std");

/// Mirrors `ustruct: Dx7VoiceParams` in kernels/06-voices/dx7_voice.fy — the
/// per-sample voice routing the JIT reads. `lvl*` are per-sample operator
/// levels (envelope × output level), written each sample by the render path.
pub const VoiceParams = extern struct {
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

/// A DX7 algorithm topology. Operator numbers are 1..6.
pub const Algorithm = struct {
    /// (modulator, carrier) edges; modulator number must be > carrier number.
    edges: []const [2]u8,
    /// Operators whose output sums into the voice output.
    carriers: []const u8,
    /// Operator with self-feedback (1..6).
    feedback_op: u8,
};

/// Set the routing weight w[i][j] (0-based, i<j): operator (j+1) modulates
/// operator (i+1).
fn setW(vp: *VoiceParams, i: u8, j: u8, v: f64) void {
    switch (@as(u8, i) * 10 + j) {
        1 => vp.w01 = v,
        2 => vp.w02 = v,
        3 => vp.w03 = v,
        4 => vp.w04 = v,
        5 => vp.w05 = v,
        12 => vp.w12 = v,
        13 => vp.w13 = v,
        14 => vp.w14 = v,
        15 => vp.w15 = v,
        23 => vp.w23 = v,
        24 => vp.w24 = v,
        25 => vp.w25 = v,
        34 => vp.w34 = v,
        35 => vp.w35 = v,
        45 => vp.w45 = v,
        else => unreachable,
    }
}

fn setC(vp: *VoiceParams, i: u8, v: f64) void {
    switch (i) {
        0 => vp.c0 = v,
        1 => vp.c1 = v,
        2 => vp.c2 = v,
        3 => vp.c3 = v,
        4 => vp.c4 = v,
        else => vp.c5 = v,
    }
}

fn setFb(vp: *VoiceParams, i: u8, v: f64) void {
    switch (i) {
        0 => vp.fb0 = v,
        1 => vp.fb1 = v,
        2 => vp.fb2 = v,
        3 => vp.fb3 = v,
        4 => vp.fb4 = v,
        else => vp.fb5 = v,
    }
}

/// True if every edge routes a higher-numbered operator into a lower one
/// (the upper-triangular constraint the voice's fixed eval order requires).
pub fn validate(alg: Algorithm) bool {
    for (alg.edges) |e| {
        if (e[0] <= e[1] or e[0] < 1 or e[0] > 6 or e[1] < 1 or e[1] > 6) return false;
    }
    if (alg.feedback_op < 1 or alg.feedback_op > 6) return false;
    for (alg.carriers) |c| if (c < 1 or c > 6) return false;
    return true;
}

/// Write `alg`'s routing (edges → weights, carriers, feedback) into `vp`,
/// clearing the routing fields first. Leaves inc/lvl untouched (set per note /
/// per sample by the caller). `feedback` is the self-feedback amount.
pub fn applyRouting(vp: *VoiceParams, alg: Algorithm, feedback: f64) void {
    // Clear routing.
    inline for (.{ "w01", "w02", "w03", "w04", "w05", "w12", "w13", "w14", "w15", "w23", "w24", "w25", "w34", "w35", "w45", "c0", "c1", "c2", "c3", "c4", "c5", "fb0", "fb1", "fb2", "fb3", "fb4", "fb5" }) |f| {
        @field(vp, f) = 0;
    }
    for (alg.edges) |e| setW(vp, e[1] - 1, e[0] - 1, 1.0); // car<mod ⇒ w[car][mod]
    for (alg.carriers) |c| setC(vp, c - 1, 1.0);
    setFb(vp, alg.feedback_op - 1, feedback);
}

// ── The DX7 algorithm table will live here; seeded with the unambiguous ones.

/// Algorithm 32: all six operators are independent carriers (additive organ),
/// feedback on op6. (The clearest DX7 algorithm to pin the builder against.)
pub const alg32: Algorithm = .{
    .edges = &.{},
    .carriers = &.{ 1, 2, 3, 4, 5, 6 },
    .feedback_op = 6,
};

const testing = std.testing;

test "applyRouting: additive algorithm 32" {
    var vp = VoiceParams{};
    try testing.expect(validate(alg32));
    applyRouting(&vp, alg32, 0.3);
    // All carriers on, no modulation, feedback on op6.
    try testing.expectEqual(@as(f64, 1.0), vp.c0);
    try testing.expectEqual(@as(f64, 1.0), vp.c5);
    try testing.expectEqual(@as(f64, 0.0), vp.w01);
    try testing.expectEqual(@as(f64, 0.0), vp.w45);
    try testing.expectEqual(@as(f64, 0.3), vp.fb5);
    try testing.expectEqual(@as(f64, 0.0), vp.fb0);
}

test "applyRouting: a 4-op stack into one carrier" {
    // op6→op5→op4→op3 (carrier op3), feedback op6 — the shape of an FM stack.
    const stack: Algorithm = .{
        .edges = &.{ .{ 6, 5 }, .{ 5, 4 }, .{ 4, 3 } },
        .carriers = &.{3},
        .feedback_op = 6,
    };
    var vp = VoiceParams{};
    try testing.expect(validate(stack));
    applyRouting(&vp, stack, 0.5);
    try testing.expectEqual(@as(f64, 1.0), vp.w45); // op6→op5
    try testing.expectEqual(@as(f64, 1.0), vp.w34); // op5→op4
    try testing.expectEqual(@as(f64, 1.0), vp.w23); // op4→op3
    try testing.expectEqual(@as(f64, 1.0), vp.c2); // op3 carrier
    try testing.expectEqual(@as(f64, 0.0), vp.c0);
    try testing.expectEqual(@as(f64, 0.5), vp.fb5);
}

test "validate rejects a lower-numbered modulator" {
    const bad: Algorithm = .{ .edges = &.{.{ 1, 2 }}, .carriers = &.{2}, .feedback_op = 1 };
    try testing.expect(!validate(bad)); // op1 can't modulate op2 (eval order)
}

// End-to-end: a builder-produced algorithm drives the validated voice and
// makes the expected sound.
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

fn binAmp(x: []const f64, k: usize) f64 {
    const n = x.len;
    const w = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
    const cw = @cos(w);
    const sw = @sin(w);
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (x) |xv| {
        const s0 = xv + 2.0 * cw * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return @sqrt((s1 - s2 * cw) * (s1 - s2 * cw) + (s2 * sw) * (s2 * sw)) * 2.0 / @as(f64, @floatFromInt(n));
}

test "alg32 routing drives the voice to six partials" {
    var host = FyHost.init(testing.allocator);
    defer host.deinit();
    try host.compileFile("kernels/06-voices/dx7_voice.fy");
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    var vp = VoiceParams{};
    applyRouting(&vp, alg32, 0.0); // additive, feedback off for a clean test
    const n = 4096;
    const bins = [_]usize{ 100, 150, 200, 260, 330, 400 };
    inline for (.{ "inc0", "inc1", "inc2", "inc3", "inc4", "inc5" }, 0..) |f, i| {
        @field(vp, f) = @as(f64, @floatFromInt(bins[i])) / @as(f64, n);
    }
    inline for (.{ "lvl0", "lvl1", "lvl2", "lvl3", "lvl4", "lvl5" }) |f| @field(vp, f) = 0.3;

    var st = [_]f64{0} ** 18;
    var out: f64 = 0;
    var buf: [n]f64 = undefined;
    for (&buf) |*s| {
        const args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&out) }, .{ .ptr = @intFromPtr(&st) }, .{ .ptr = @intFromPtr(&vp) } };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-dx7-voice", 1, &args);
        s.* = out;
    }
    for (bins) |b| try testing.expectApproxEqAbs(@as(f64, 0.3), binAmp(&buf, b), 0.02);
    try testing.expect(binAmp(&buf, 175) < 0.01);
}
