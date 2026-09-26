//! Measured behaviour of kernels/00-primitives/oversample.fy: passband
//! gain and stopband rejection of the 4x decimator, image rejection of the
//! 4x interpolator.

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const PROBES =
    \\dsp: t-dec4 | out s x0 x1 x2 x3 | s x0 x1 x2 x3 dec4 out f!64 ;
    \\dsp: t-up4 | out s x | s x up4 | a b c d |
    \\  a out f!64  b out 8 ptr+ f!64  c out 16 ptr+ f!64  d out 24 ptr+ f!64 ;
;

const SR: f64 = 48_000.0;

/// Amplitude of the component at `hz` in `x` (sampled at `sr`), one-bin DFT.
fn amp(x: []const f64, hz: f64, sr: f64) f64 {
    var re: f64 = 0;
    var im: f64 = 0;
    for (x, 0..) |v, i| {
        const w = 2.0 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / sr;
        re += v * @cos(w);
        im += v * @sin(w);
    }
    return 2.0 * @sqrt(re * re + im * im) / @as(f64, @floatFromInt(x.len));
}

fn db(x: f64) f64 {
    return 20.0 * std.math.log10(@max(x, 1e-20));
}

/// Decimate a 4x-rate sine at `hz`; return the output amplitude at `probe`.
fn decimated(host: *FyHost, hz: f64, probe: f64) !f64 {
    var state = [_]f64{0} ** 26;
    var out: f64 = 0;
    var ys: [4800]f64 = undefined;
    var n: usize = 0;
    var t: usize = 0;
    while (n < 4800 + 480) : (n += 1) {
        var xs: [4]f64 = undefined;
        for (&xs) |*x| {
            x.* = @sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(t)) / (4.0 * SR));
            t += 1;
        }
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out) }, .{ .ptr = @intFromPtr(&state) },
            .{ .f64 = xs[0] },             .{ .f64 = xs[1] },
            .{ .f64 = xs[2] },             .{ .f64 = xs[3] },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("t-dec4", 1, &args);
        if (n >= 480) ys[n - 480] = out;
    }
    return amp(&ys, probe, SR);
}

test "4x decimator: flat passband, aliases rejected" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile("kernels/00-primitives/oversample.fy");
    try host.compile(PROBES);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    for ([_]f64{ 100.0, 1000.0, 10000.0, 20000.0 }) |hz| {
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), db(try decimated(&host, hz, hz)), 0.02);
    }
    // 30 kHz folds to 18 kHz, 70 kHz to 22 kHz; 74 kHz is the first
    // stage's job (it would fold to 22 kHz at 2x).
    try std.testing.expect(db(try decimated(&host, 30000.0, 18000.0)) < -100.0);
    try std.testing.expect(db(try decimated(&host, 70000.0, 22000.0)) < -100.0);
    try std.testing.expect(db(try decimated(&host, 74000.0, 22000.0)) < -100.0);
}

test "4x interpolator: images rejected" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compileFile("kernels/00-primitives/oversample.fy");
    try host.compile(PROBES);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);

    var state = [_]f64{0} ** 26;
    var quad = [_]f64{0} ** 4;
    var ys: [4 * 4800]f64 = undefined;
    const hz = 5000.0;
    for (0..4800 + 480) |n| {
        const x = @sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(n)) / SR);
        const args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&quad) }, .{ .ptr = @intFromPtr(&state) }, .{ .f64 = x } };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("t-up4", 1, &args);
        if (n >= 480) @memcpy(ys[(n - 480) * 4 ..][0..4], &quad);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), db(amp(&ys, hz, 4 * SR)), 0.02);
    for ([_]f64{ SR - hz, SR + hz, 2 * SR - hz, 2 * SR + hz }) |image| {
        try std.testing.expect(db(amp(&ys, image, 4 * SR)) < -100.0);
    }
}
