//! kernels/08-analog/analog.fy: drift amplitude is rate-independent, and
//! spread gives distinct, stable per-voice offsets.

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const PROBES =
    \\dsp: t-drift | out s c | s c drift-step out f!64 ;
    \\dsp: t-spread | out v salt | v salt spread out f!64 ;
;

fn driftRms(host: *FyHost, rate: f64) !f64 {
    var s = [_]f64{ 0.25, 0, 0 };
    var out: f64 = 0;
    const c = 2.0 * std.math.pi * rate / 48000.0;
    var acc: f64 = 0;
    const n: usize = 48000 * 120;
    for (0..n) |_| {
        const args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&out) }, .{ .ptr = @intFromPtr(&s) }, .{ .f64 = c } };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("t-drift", 1, &args);
        acc += out * out;
    }
    return @sqrt(acc / @as(f64, @floatFromInt(n)));
}

test "analog: drift RMS about 1 at any rate; spread distinct per voice" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile("kernels/08-analog/analog.fy");
    try host.compile(PROBES);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    const slow = try driftRms(&host, 0.5);
    const fast = try driftRms(&host, 8.0);
    try std.testing.expect(slow > 0.4 and slow < 2.6); // 60 periods: a noisy estimate
    try std.testing.expect(fast > 0.7 and fast < 1.4);

    var seen: [16]f64 = undefined;
    for (0..16) |v| {
        var out: f64 = 0;
        const args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&out) }, .{ .f64 = @floatFromInt(v) }, .{ .f64 = 1.0 } };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("t-spread", 1, &args);
        try std.testing.expect(out >= -1.0 and out <= 1.0);
        for (seen[0..v]) |o| try std.testing.expect(@abs(o - out) > 0.02);
        seen[v] = out;
    }
}
