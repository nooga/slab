//! Measured behaviour of the nonlinear Moog ladder
//! (kernels/04-filters/moog_ladder.fy) at 4x through dec4: small-signal
//! response, and self-oscillation that tracks the cutoff.

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

const PROBES =
    \\dsp: t-moog | out m d x cutoff res osr |
    \\  cutoff osr res moog-coeffs | g k |
    \\  d  m x g k moog-step  m x g k moog-step  m x g k moog-step  m x g k moog-step  dec4
    \\  out f!64 ;
;

const SR: f64 = 48_000.0;

const Rig = struct {
    host: FyHost,
    m: [10]f64 = [_]f64{0} ** 10,
    d: [26]f64 = [_]f64{0} ** 26,

    fn step(self: *Rig, x: f64, cutoff: f64, res: f64) !f64 {
        var out: f64 = 0;
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out) }, .{ .ptr = @intFromPtr(&self.m) },
            .{ .ptr = @intFromPtr(&self.d) }, .{ .f64 = x },
            .{ .f64 = cutoff },            .{ .f64 = res },
            .{ .f64 = 4.0 * SR },
        };
        _ = try self.host.fy.callDsp2RawRepeatedWithArgsNoResult("t-moog", 1, &args);
        return out;
    }
};

fn amp(x: []const f64, hz: f64) f64 {
    var re: f64 = 0;
    var im: f64 = 0;
    for (x, 0..) |v, i| {
        const w = 2.0 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / SR;
        re += v * @cos(w);
        im += v * @sin(w);
    }
    return 2.0 * @sqrt(re * re + im * im) / @as(f64, @floatFromInt(x.len));
}

fn db(x: f64) f64 {
    return 20.0 * std.math.log10(@max(x, 1e-20));
}

fn gainAt(rig: *Rig, hz: f64, cutoff: f64) !f64 {
    rig.m = [_]f64{0} ** 10;
    rig.d = [_]f64{0} ** 26;
    var ys: [4800]f64 = undefined;
    for (0..4800 + 2400) |n| {
        const x = 0.01 * @sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(n)) / SR);
        const y = try rig.step(x, cutoff, 0.0);
        if (n >= 2400) ys[n - 2400] = y;
    }
    return db(amp(&ys, hz) / 0.01);
}

/// Frequency of the self-oscillation: zero crossings over one second.
fn oscHz(rig: *Rig, cutoff: f64) !f64 {
    rig.m = [_]f64{0} ** 10;
    rig.d = [_]f64{0} ** 26;
    var prev: f64 = 0;
    var first: ?usize = null;
    var last: usize = 0;
    var crossings: usize = 0;
    for (0..48000 * 2) |n| {
        const kick: f64 = if (n < 4) 0.5 else 0.0;
        const y = try rig.step(kick, cutoff, 1.05);
        if (n > 48000 and prev <= 0 and y > 0) {
            if (first == null) first = n else {
                crossings += 1;
                last = n;
            }
        }
        prev = y;
    }
    if (crossings == 0) return 0;
    return SR * @as(f64, @floatFromInt(crossings)) / @as(f64, @floatFromInt(last - first.?));
}

test "moog ladder: -24 dB/oct response, self-oscillation tracks the cutoff" {
    var rig = Rig{ .host = FyHost.init(std.testing.allocator) };
    defer rig.host.deinit();
    try rig.host.compileFile("kernels/04-filters/moog_ladder.fy");
    try rig.host.compileFile("kernels/00-primitives/oversample.fy");
    try rig.host.compile(PROBES);
    Fy.Builtins.fyPtr = @intFromPtr(&rig.host.fy);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), try gainAt(&rig, 100.0, 2000.0), 0.3);
    try std.testing.expectApproxEqAbs(@as(f64, -12.0), try gainAt(&rig, 2000.0, 2000.0), 1.5);
    // two octaves up: about -24 dB/oct past the knee
    try std.testing.expect(try gainAt(&rig, 8000.0, 2000.0) < -36.0);

    for ([_]f64{ 110.0, 440.0, 1760.0, 7040.0 }) |fc| {
        const hz = try oscHz(&rig, fc);
        const cents = 1200.0 * std.math.log2(hz / fc);
        try std.testing.expect(@abs(cents) < 6.0);
    }
}
