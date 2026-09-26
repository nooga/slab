//! Accuracy of dsp-std (kernels/00-primitives/math.fy) against std.math,
//! over dense grids. The bounds are the documented ones in math.fy with a
//! little headroom.

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const PROBES =
    \\dsp: t-exp2 | out x | x exp2 out f!64 ;
    \\dsp: t-log2 | out x | x log2 out f!64 ;
    \\dsp: t-sin | out x | x sin out f!64 ;
    \\dsp: t-cos | out x | x cos out f!64 ;
    \\dsp: t-tan | out x | x tan out f!64 ;
    \\dsp: t-tanh | out x | x tanh out f!64 ;
    \\dsp: t-tanw | out x | x tan-warp out f!64 ;
    \\dsp: t-db | out x | x db>lin out f!64 ;
    \\dsp: t-pow | out x | x 1.5 pow out f!64 ;
;

fn call(host: *FyHost, word: []const u8, x: f64) !f64 {
    var out: f64 = 0;
    const args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&out) }, .{ .f64 = x } };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(word, 1, &args);
    return out;
}

const Kind = enum { abs, rel };

fn sweep(host: *FyHost, word: []const u8, lo: f64, hi: f64, kind: Kind, ref: *const fn (f64) f64) !f64 {
    const n: usize = 20000;
    var worst: f64 = 0;
    for (0..n) |i| {
        const x = lo + (hi - lo) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        const got = try call(host, word, x);
        const want = ref(x);
        try std.testing.expect(std.math.isFinite(got));
        const err = switch (kind) {
            .abs => @abs(got - want),
            .rel => @abs(got - want) / @max(@abs(want), 1e-300),
        };
        worst = @max(worst, err);
    }
    return worst;
}

fn exp2Ref(x: f64) f64 {
    return std.math.exp2(x);
}
fn log2Ref(x: f64) f64 {
    return std.math.log2(std.math.exp2(x));
}
fn sinRef(x: f64) f64 {
    return @sin(x);
}
fn cosRef(x: f64) f64 {
    return @cos(x);
}
fn tanRef(x: f64) f64 {
    return @tan(x);
}
fn tanhRef(x: f64) f64 {
    return std.math.tanh(x);
}
fn dbRef(x: f64) f64 {
    return std.math.pow(f64, 10.0, x / 20.0);
}

test "dsp-std elementary functions match libm" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile("kernels/00-primitives/math.fy");
    try host.compile(PROBES);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    try std.testing.expect(try sweep(&host, "t-exp2", -60.0, 60.0, .rel, exp2Ref) < 1e-10);
    // log2 is swept in the exponent domain: x = 2^t
    var worst_log: f64 = 0;
    for (0..20000) |i| {
        const t = -80.0 + 160.0 * @as(f64, @floatFromInt(i)) / 19999.0;
        const x = std.math.exp2(t);
        worst_log = @max(worst_log, @abs(try call(&host, "t-log2", x) - std.math.log2(x)));
    }
    try std.testing.expect(worst_log < 1e-11);
    try std.testing.expect(try sweep(&host, "t-sin", -20.0, 20.0, .abs, sinRef) < 1e-10);
    try std.testing.expect(try sweep(&host, "t-cos", -20.0, 20.0, .abs, cosRef) < 1e-10);
    try std.testing.expect(try sweep(&host, "t-tan", -1.5, 1.5, .rel, tanRef) < 1e-9);
    try std.testing.expect(try sweep(&host, "t-tanw", 0.0, 1.45, .rel, tanRef) < 1e-8);
    try std.testing.expect(try sweep(&host, "t-tanh", -30.0, 30.0, .abs, tanhRef) < 1e-10);
    try std.testing.expect(try sweep(&host, "t-db", -120.0, 24.0, .rel, dbRef) < 1e-10);

    // Pinned points: exact where it matters for gain staging.
    try std.testing.expectEqual(@as(f64, 1.0), try call(&host, "t-db", 0.0));
    try std.testing.expectEqual(@as(f64, 8.0), try call(&host, "t-exp2", 3.0));
    try std.testing.expectEqual(@as(f64, 0.0), try call(&host, "t-tanh", 0.0));
    try std.testing.expectEqual(@as(f64, 0.0), try call(&host, "t-log2", 1.0));
    try std.testing.expectEqual(@as(f64, 1.0), try call(&host, "t-cos", 0.0));
    try std.testing.expectApproxEqRel(@as(f64, 8.0), try call(&host, "t-pow", 4.0), 1e-10);
}

test "table: data reads back through tbl-lerp" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile("kernels/00-primitives/table.fy");
    try host.compile(
        \\table: t-sq 16 dup f* ;
        \\dsp: t-sq-at | out x | t-sq x tbl-lerp out f!64 ;
        \\dsp: t-sq-n | out | t-sq-len out f!64 ;
    );
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    try std.testing.expectEqual(@as(f64, 16.0), try call0(&host, "t-sq-n"));
    try std.testing.expectEqual(@as(f64, 9.0), try call(&host, "t-sq-at", 3.0));
    try std.testing.expectEqual(@as(f64, 12.5), try call(&host, "t-sq-at", 3.5));
    // the extra cell: index 15.5 interpolates toward 16^2
    try std.testing.expectEqual(@as(f64, 240.5), try call(&host, "t-sq-at", 15.5));
}

fn call0(host: *FyHost, word: []const u8) !f64 {
    var out: f64 = 0;
    const args = [_]Fy.Dsp2RawArg{.{ .ptr = @intFromPtr(&out) }};
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(word, 1, &args);
    return out;
}
