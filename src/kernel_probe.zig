const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;
const machine = @import("machine.zig");
const wav = @import("wav.zig");

extern fn close(fd: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn tanh(x: f64) f64;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;
const OSC_SAMPLE_RATE: u32 = 48_000;
const OSC_LISTEN_SECONDS: usize = 2;
const OSC_SWEEP_START_HZ: f64 = 50.0;
const OSC_SWEEP_END_HZ: f64 = 2000.0;
const FILTER_SAMPLE_RATE: u32 = 48_000;
const FILTER_RENDER_SECONDS: f64 = 2.0;
const FILTER_GAP_SECONDS: f64 = 0.12;
const FILTER_CUTOFF_START_HZ: f64 = 80.0;
const FILTER_CUTOFF_END_HZ: f64 = 8000.0;
const FILTER_INPUT_HZ: f64 = 110.0;
const FILTER_SAW_GAIN: f64 = 0.0;
const FILTER_NOISE_GAIN: f64 = 0.34;
const FILTER_DRIVE: f64 = 1.2;
const FILTER_RESONANCES = [_]f64{ 0.0, 0.45, 0.80, 1.08, 1.25 };
const VOICE_SAMPLE_RATE: u32 = 48_000;
const VOICE_SECONDS: f64 = 3.0;

const Cli = struct {
    kernel: []const u8 = "kernels/00-primitives/v2.fy",
    word: []const u8 = "k-v2-add",
    case_name: []const u8 = "v2-add",
    iterations: u64 = 1_000_000,
    out_prefix: []const u8 = "scratch/kernel_v2_add",
};

const CaseData = struct {
    a: [2]f64,
    b: [2]f64,
    acc: [2]f64 = .{ 0, 0 },
    expected: [2]f64,
    args_len: usize,
};

const Metrics = struct {
    max_abs_error: f64 = 0,
    nonfinite_count: usize = 0,
    ns_per_iter: f64 = 0,
    libc_tanh_ns_per_iter: f64 = 0,
    zig_table_ns_per_iter: f64 = 0,
    zig_rational_ns_per_iter: f64 = 0,
    zig_reference_ns_per_iter: f64 = 0,
    table_vs_libc_tanh_max_abs_error: f64 = 0,
    rms: f64 = 0,
    peak: f64 = 0,
    mean: f64 = 0,
    final_phase: f64 = 0,
    fundamental_hz: f64 = 0,
    alias_residual_db: f64 = 0,
    naive_alias_residual_db: f64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const cli = try parseCli(init);
    try ensureScratch();

    var host = FyHost.init(alloc);
    defer host.deinit();
    try host.compileFile(cli.kernel);

    if (std.mem.eql(u8, cli.case_name, "tanh-table-sweep") or
        std.mem.eql(u8, cli.case_name, "tanh-rational-sweep"))
    {
        try runTanhTableCase(alloc, cli, &host);
        return;
    }
    if (isEnvelopeCase(cli.case_name)) {
        try runEnvelopeCase(alloc, cli, &host);
        return;
    }
    if (isFilterCase(cli.case_name)) {
        try runFilterCase(alloc, cli, &host);
        return;
    }
    if (isOscillatorCase(cli.case_name)) {
        try runSawPolyblepCase(alloc, cli, &host);
        return;
    }
    if (isControlCase(cli.case_name)) {
        try runControlCase(alloc, cli, &host);
        return;
    }
    if (isDrumCase(cli.case_name)) {
        try runDrumCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "delay-render")) {
        try runDelayCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "reverb-render")) {
        try runReverbCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "log2-sweep") or
        std.mem.eql(u8, cli.case_name, "exp2-sweep"))
    {
        try runPow2Case(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "comp-render")) {
        try runCompCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "eq-render")) {
        try runEqCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "sat-render")) {
        try runSatCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "gate-render")) {
        try runGateCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "chorus-render")) {
        try runChorusCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "juno-voice-render")) {
        try runJunoCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "funk-render")) {
        try runFunkCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "sampler-render")) {
        try runSamplerCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "ms20-voice-render")) {
        try runMs20VoiceCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "ms20-svf-sweep")) {
        try runMs20SvfSweepCase(alloc, cli, &host);
        return;
    }
    if (std.mem.eql(u8, cli.case_name, "ladder-sweep")) {
        try runLadderSweepCase(alloc, cli, &host);
        return;
    }

    const data = try caseData(cli.case_name);
    var a align(16) = data.a;
    var b align(16) = data.b;
    var acc align(16) = data.acc;
    var out align(16) = [_]f64{ 0, 0 };

    const args3 = [_]Fy.Value{
        Fy.makeInt(@intCast(@intFromPtr(&out))),
        Fy.makeInt(@intCast(@intFromPtr(&a))),
        Fy.makeInt(@intCast(@intFromPtr(&b))),
    };
    const args4 = [_]Fy.Value{
        Fy.makeInt(@intCast(@intFromPtr(&out))),
        Fy.makeInt(@intCast(@intFromPtr(&acc))),
        Fy.makeInt(@intCast(@intFromPtr(&a))),
        Fy.makeInt(@intCast(@intFromPtr(&b))),
    };
    const args = if (data.args_len == 4) args4[0..] else args3[0..];

    const warmup = @min(cli.iterations, 10_000);
    _ = try host.fy.callWordRepeatedWithArgsNoResult(cli.word, warmup, args);

    out = .{ 0, 0 };
    const start = nowNs();
    _ = try host.fy.callWordRepeatedWithArgsNoResult(cli.word, cli.iterations, args);
    const run_ns = nowNs() - start;

    const metrics = computeMetrics(out, data.expected, run_ns, cli.iterations);
    if (metrics.nonfinite_count != 0 or metrics.max_abs_error > 0.000000000001) {
        try writeArtifacts(alloc, cli, &host, data, out, metrics);
        return error.KernelRatchetFailed;
    }

    try writeArtifacts(alloc, cli, &host, data, out, metrics);
    std.debug.print(
        "kernel {s}:{s} case={s} ns_per_iter={d:.3} max_abs_error={d:.12}\n",
        .{ cli.kernel, cli.word, cli.case_name, metrics.ns_per_iter, metrics.max_abs_error },
    );
}

fn parseCli(init: std.process.Init) !Cli {
    var cli = Cli{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.startsWith(u8, arg, "--kernel=")) {
            cli.kernel = arg["--kernel=".len..];
        } else if (std.mem.startsWith(u8, arg, "--word=")) {
            cli.word = arg["--word=".len..];
        } else if (std.mem.startsWith(u8, arg, "--case=")) {
            cli.case_name = arg["--case=".len..];
        } else if (std.mem.startsWith(u8, arg, "--iters=")) {
            cli.iterations = try std.fmt.parseInt(u64, arg["--iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            cli.out_prefix = arg["--out=".len..];
        } else {
            usage();
            return error.InvalidArgument;
        }
    }
    return cli;
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  zig build kernel-probe -- --kernel=kernels/00-primitives/v2.fy --word=k-v2-add --case=v2-add --iters=1000000 --out=scratch/kernel_v2_add
        \\
        \\cases:
        \\  v2-add | v2-mul | v2-fmadd | tanh-table-sweep | tanh-rational-sweep
        \\  adsr-linear-render | adsr-cap-render
        \\  ms20-lpf-grid | ms20-lpf4-render
        \\  hz-step-render | slew-onepole-render | vca-render | osc-mix2-render | dc-block-render
        \\  ms20-voice-render
        \\  saw-polyblep-render | saw-falling-polyblep-render | saw-cap-polyblep-render
        \\  saw-topcut-polyblep-render | square-polyblep-render | pulse-polyblep-render
        \\
    , .{});
}

fn isFilterCase(name: []const u8) bool {
    return std.mem.eql(u8, name, "ms20-lpf-grid") or
        std.mem.eql(u8, name, "ms20-lpf4-render") or
        std.mem.eql(u8, name, "ms20-lpf4-cubic-render");
}

fn isEnvelopeCase(name: []const u8) bool {
    return std.mem.eql(u8, name, "adsr-linear-render") or
        std.mem.eql(u8, name, "adsr-cap-render");
}

fn isOscillatorCase(name: []const u8) bool {
    return std.mem.eql(u8, name, "saw-polyblep-render") or
        std.mem.eql(u8, name, "saw-falling-polyblep-render") or
        std.mem.eql(u8, name, "saw-cap-polyblep-render") or
        std.mem.eql(u8, name, "saw-topcut-polyblep-render") or
        std.mem.eql(u8, name, "square-polyblep-render") or
        std.mem.eql(u8, name, "pulse-polyblep-render");
}

fn isControlCase(name: []const u8) bool {
    return std.mem.eql(u8, name, "hz-step-render") or
        std.mem.eql(u8, name, "slew-onepole-render") or
        std.mem.eql(u8, name, "vca-render") or
        std.mem.eql(u8, name, "osc-mix2-render") or
        std.mem.eql(u8, name, "dc-block-render");
}

fn caseData(name: []const u8) !CaseData {
    if (std.mem.eql(u8, name, "v2-add")) return .{
        .a = .{ 1.25, -2.0 },
        .b = .{ 0.75, 5.5 },
        .expected = .{ 2.0, 3.5 },
        .args_len = 3,
    };
    if (std.mem.eql(u8, name, "v2-mul")) return .{
        .a = .{ 1.5, -2.0 },
        .b = .{ 4.0, -0.25 },
        .expected = .{ 6.0, 0.5 },
        .args_len = 3,
    };
    if (std.mem.eql(u8, name, "v2-fmadd")) return .{
        .a = .{ 1.5, -2.0 },
        .b = .{ 4.0, -0.25 },
        .acc = .{ 0.25, 10.0 },
        .expected = .{ 6.25, 10.5 },
        .args_len = 4,
    };
    return error.InvalidCase;
}

fn computeMetrics(out: [2]f64, expected: [2]f64, run_ns: u64, iterations: u64) Metrics {
    var m = Metrics{};
    for (out, expected) |actual, exp| {
        if (!std.math.isFinite(actual)) {
            m.nonfinite_count += 1;
            continue;
        }
        m.max_abs_error = @max(m.max_abs_error, @abs(actual - exp));
    }
    if (iterations > 0) {
        m.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(iterations));
    }
    return m;
}

fn runTanhTableCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_count: usize = 97;
    const table_len: usize = 1026;
    const drive: f64 = 2.5;
    const use_rational_reference = std.mem.eql(u8, cli.case_name, "tanh-rational-sweep");

    const input = try alloc.alloc(f64, sample_count);
    defer alloc.free(input);
    const expected = try alloc.alloc(f64, sample_count);
    defer alloc.free(expected);
    const out = try alloc.alloc(f64, sample_count);
    defer alloc.free(out);
    const table = try alloc.alloc(f64, table_len);
    defer alloc.free(table);

    const span = table_len - 2;
    for (table, 0..) |*v, i| {
        const grid_i = @min(i, span);
        const t = -4.0 + 8.0 * (@as(f64, @floatFromInt(grid_i)) / @as(f64, @floatFromInt(span)));
        v.* = std.math.tanh(t);
    }

    for (input, expected, out, 0..) |*inp, *exp, *dst, i| {
        const phase = (@as(f64, @floatFromInt(i)) + 0.37) / @as(f64, @floatFromInt(sample_count));
        inp.* = -1.5 + 3.0 * phase;
        exp.* = if (use_rational_reference)
            tanh(inp.* * drive)
        else
            tableLinearLookup(table, inp.* * drive);
        dst.* = 0;
    }

    const perf_args = [_]Fy.Value{
        Fy.makeInt(@intCast(@intFromPtr(&out[0]))),
        Fy.makeInt(@intCast(@intFromPtr(&input[0]))),
        Fy.makeInt(@intCast(@intFromPtr(table.ptr))),
        Fy.makeInt(@intCast(span)),
        makeFyFloat(drive),
    };
    const perf_raw_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&input[0]) },
        .{ .ptr = @intFromPtr(table.ptr) },
        .{ .int = @intCast(span) },
        .{ .f64 = drive },
    };
    const use_raw_dsp2 = host.fy.isDsp2Word(cli.word);

    const warmup = @min(cli.iterations, 1_000);
    if (use_raw_dsp2) {
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, warmup, &perf_raw_args);
    } else {
        _ = try host.fy.callWordRepeatedWithArgsNoResult(cli.word, warmup, &perf_args);
    }

    const start = nowNs();
    if (use_raw_dsp2) {
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, cli.iterations, &perf_raw_args);
    } else {
        _ = try host.fy.callWordRepeatedWithArgsNoResult(cli.word, cli.iterations, &perf_args);
    }
    const run_ns = nowNs() - start;
    const libc_tanh_ns_per_iter = benchmarkLibcTanh(input, drive, cli.iterations);
    const zig_table_ns_per_iter = benchmarkZigTable(table, input, drive, cli.iterations);
    const zig_rational_ns_per_iter = benchmarkZigRational(input, drive, cli.iterations);

    @memset(out, 0);
    for (input, out) |*inp, *dst| {
        const sample_args = [_]Fy.Value{
            Fy.makeInt(@intCast(@intFromPtr(dst))),
            Fy.makeInt(@intCast(@intFromPtr(inp))),
            Fy.makeInt(@intCast(@intFromPtr(table.ptr))),
            Fy.makeInt(@intCast(span)),
            makeFyFloat(drive),
        };
        const sample_raw_args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(dst) },
            .{ .ptr = @intFromPtr(inp) },
            .{ .ptr = @intFromPtr(table.ptr) },
            .{ .int = @intCast(span) },
            .{ .f64 = drive },
        };
        if (use_raw_dsp2) {
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &sample_raw_args);
        } else {
            _ = try host.fy.callWordRepeatedWithArgsNoResult(cli.word, 1, &sample_args);
        }
    }

    var metrics = computeSliceMetrics(out, expected, run_ns, cli.iterations);
    metrics.libc_tanh_ns_per_iter = libc_tanh_ns_per_iter;
    metrics.zig_table_ns_per_iter = zig_table_ns_per_iter;
    metrics.zig_rational_ns_per_iter = zig_rational_ns_per_iter;
    metrics.table_vs_libc_tanh_max_abs_error = computeTrueTanhError(input, out, drive);
    try writeTanhArtifacts(alloc, cli, host, input, expected, out, metrics, table_len, drive);
    const max_allowed_error: f64 = if (use_rational_reference) 0.03 else 0.000000000001;
    if (metrics.nonfinite_count != 0 or metrics.max_abs_error > max_allowed_error) {
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} samples={} table_len={} ns_per_iter={d:.3} max_abs_error={d:.12}\n",
        .{ cli.kernel, cli.word, cli.case_name, sample_count, table_len, metrics.ns_per_iter, metrics.max_abs_error },
    );
}

fn tableLinearLookup(table: []const f64, x_unclamped: f64) f64 {
    const x = std.math.clamp(x_unclamped, -4.0, 4.0);
    const span = table.len - 2;
    const pos = ((x + 4.0) * 0.125) * @as(f64, @floatFromInt(span));
    const idx = @min(@as(usize, @intFromFloat(pos)), span);
    const frac = pos - @as(f64, @floatFromInt(idx));
    const y0 = table[idx];
    const y1 = table[idx + 1];
    return y0 + (y1 - y0) * frac;
}

fn benchmarkLibcTanh(input: []const f64, drive: f64, iterations: u64) f64 {
    if (iterations == 0) return 0;
    var sink: f64 = 0;
    const input_ptr: [*]const volatile f64 = @ptrCast(input.ptr);
    const sink_ptr: *volatile f64 = @ptrCast(&sink);

    var i: u64 = 0;
    var idx: usize = 0;
    const start = nowNs();
    while (i < iterations) : (i += 1) {
        sink_ptr.* = tanh(input_ptr[idx] * drive);
        idx += 1;
        if (idx == input.len) idx = 0;
    }
    const run_ns = nowNs() - start;
    return @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(iterations));
}

fn benchmarkZigTable(table: []const f64, input: []const f64, drive: f64, iterations: u64) f64 {
    if (iterations == 0) return 0;
    var sink: f64 = 0;
    const input_ptr: [*]const volatile f64 = @ptrCast(input.ptr);
    const sink_ptr: *volatile f64 = @ptrCast(&sink);

    var i: u64 = 0;
    var idx: usize = 0;
    const start = nowNs();
    while (i < iterations) : (i += 1) {
        sink_ptr.* = tableLinearLookup(table, input_ptr[idx] * drive);
        idx += 1;
        if (idx == input.len) idx = 0;
    }
    const run_ns = nowNs() - start;
    return @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(iterations));
}

fn tanhRationalApprox(x_unclamped: f64) f64 {
    const x = std.math.clamp(x_unclamped, -4.0, 4.0);
    const x2 = x * x;
    const y = x * (27.0 + x2) / (27.0 + 9.0 * x2);
    return std.math.clamp(y, -1.0, 1.0);
}

fn benchmarkZigRational(input: []const f64, drive: f64, iterations: u64) f64 {
    if (iterations == 0) return 0;
    var sink: f64 = 0;
    const input_ptr: [*]const volatile f64 = @ptrCast(input.ptr);
    const sink_ptr: *volatile f64 = @ptrCast(&sink);

    var i: u64 = 0;
    var idx: usize = 0;
    const start = nowNs();
    while (i < iterations) : (i += 1) {
        sink_ptr.* = tanhRationalApprox(input_ptr[idx] * drive);
        idx += 1;
        if (idx == input.len) idx = 0;
    }
    const run_ns = nowNs() - start;
    return @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(iterations));
}

const Ms20LpfState = struct {
    ic1: f64 = 0,
    ic2: f64 = 0,
};

fn runFilterCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    if (std.mem.eql(u8, cli.case_name, "ms20-lpf4-render") or
        std.mem.eql(u8, cli.case_name, "ms20-lpf4-cubic-render"))
    {
        try runMs20FyFilterCase(alloc, cli, host);
        return;
    }

    const sample_rate = FILTER_SAMPLE_RATE;
    const frames_per_render: usize = @intFromFloat(FILTER_RENDER_SECONDS * @as(f64, @floatFromInt(sample_rate)));
    const gap_frames: usize = @intFromFloat(FILTER_GAP_SECONDS * @as(f64, @floatFromInt(sample_rate)));
    const render_count = FILTER_RESONANCES.len;
    const total_frames = render_count * frames_per_render + (render_count - 1) * gap_frames;

    const output = try alloc.alloc(f64, total_frames);
    defer alloc.free(output);
    @memset(output, 0);

    const start = nowNs();
    var peak: f64 = 0;
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var nonfinite_count: usize = 0;
    var offset: usize = 0;
    for (FILTER_RESONANCES) |resonance| {
        var state = Ms20LpfState{};
        var osc_phase: f64 = 0;
        var noise_state: u32 = 0x1234abcd;
        var i: usize = 0;
        while (i < frames_per_render) : (i += 1) {
            const pos = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(frames_per_render - 1));
            const cutoff = FILTER_CUTOFF_START_HZ * @exp(@log(FILTER_CUTOFF_END_HZ / FILTER_CUTOFF_START_HZ) * pos);
            const dt = FILTER_INPUT_HZ / @as(f64, @floatFromInt(sample_rate));
            const input = zigSawPolyblep(osc_phase, dt) * FILTER_SAW_GAIN + whiteNoise(&noise_state) * FILTER_NOISE_GAIN;
            osc_phase = wrap01(osc_phase + dt);
            const coeffs = ms20Coeffs(cutoff, resonance, sample_rate);
            const y = ms20ishLpfStepWithCoeffs(&state, input, coeffs.g, coeffs.damping, FILTER_DRIVE);
            output[offset + i] = y;
            if (!std.math.isFinite(y)) {
                nonfinite_count += 1;
            } else {
                peak = @max(peak, @abs(y));
                sum += y;
                sum_sq += y * y;
            }
        }
        offset += frames_per_render;
        if (offset < output.len) offset += gap_frames;
    }
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(render_count * frames_per_render));
    metrics.nonfinite_count = nonfinite_count;
    metrics.peak = peak;
    const finite_count = @as(f64, @floatFromInt(output.len - nonfinite_count));
    if (finite_count > 0) {
        metrics.mean = sum / finite_count;
        metrics.rms = @sqrt(sum_sq / finite_count);
    }

    try writeFilterArtifacts(alloc, cli, output, metrics, sample_rate, frames_per_render, gap_frames);
    if (metrics.nonfinite_count != 0 or metrics.peak > 8.0) return error.KernelRatchetFailed;

    std.debug.print(
        "kernel {s}:{s} case={s} renders={} frames={} ns_per_sample={d:.3} peak={d:.3} rms={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, render_count, frames_per_render, metrics.ns_per_iter, metrics.peak, metrics.rms },
    );
}

// Layout mirrors the SvfState / SvfParams ustructs in ms20_svf.fy.
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

// Render the g-wet filter sweep ENTIRELY through the fy chain:
//   k-svf-coeffs-* (coefficients computed in fy) + k-ms20-svf (filter in fy).
// No Zig/libm DSP on the signal path - this is exactly what the DAW machine
// will run. Writes a WAV for listening / plotting against the Python oracle
// (tools/audio_probe/render_ms20_sweeps.py, profile g-wet).
fn runMs20SvfSweepCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_rate = FILTER_SAMPLE_RATE;
    const os_rate = @as(f64, @floatFromInt(sample_rate)) * 4.0;
    // Shorter than the grid case: each sample makes two ad-hoc fy calls.
    const render_secs: f64 = 0.6;
    const frames_per_render: usize = @intFromFloat(render_secs * @as(f64, @floatFromInt(sample_rate)));
    const gap_frames: usize = @intFromFloat(FILTER_GAP_SECONDS * @as(f64, @floatFromInt(sample_rate)));
    const render_count = FILTER_RESONANCES.len;
    const total_frames = render_count * frames_per_render + (render_count - 1) * gap_frames;

    const output = try alloc.alloc(f64, total_frames);
    defer alloc.free(output);
    @memset(output, 0);

    const saw_gain: f64 = 0.55;
    const noise_gain: f64 = 0.03;

    const start = nowNs();
    var peak: f64 = 0;
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var nonfinite_count: usize = 0;
    var offset: usize = 0;
    for (FILTER_RESONANCES) |resonance| {
        var params = SvfParams{};
        var state = SvfState{};
        // DC-block + profile coefficients are constant over the render.
        const dc_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = os_rate } };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-svf-coeffs-dc", 1, &dc_args);
        const prof_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = resonance } };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-svf-coeffs-profile", 1, &prof_args);

        var osc_phase: f64 = 0;
        var noise_state: u32 = 0x1234abcd;
        var out_sample: f64 = 0;
        var i: usize = 0;
        while (i < frames_per_render) : (i += 1) {
            const pos = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(frames_per_render - 1));
            const cutoff = FILTER_CUTOFF_START_HZ * @exp(@log(FILTER_CUTOFF_END_HZ / FILTER_CUTOFF_START_HZ) * pos);
            const dt = FILTER_INPUT_HZ / @as(f64, @floatFromInt(sample_rate));
            const input = zigSawPolyblep(osc_phase, dt) * saw_gain + whiteNoise(&noise_state) * noise_gain;
            osc_phase = wrap01(osc_phase + dt);

            // tone coefficients (g, damping) track the swept cutoff, in fy.
            const tone_args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&params) },
                .{ .f64 = cutoff },
                .{ .f64 = resonance },
                .{ .f64 = os_rate },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-svf-coeffs-tone", 1, &tone_args);

            const filt_args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&out_sample) },
                .{ .ptr = @intFromPtr(&state) },
                .{ .ptr = @intFromPtr(&params) },
                .{ .f64 = input },
                .{ .f64 = params.g },
                .{ .f64 = params.damping },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-ms20-svf", 1, &filt_args);

            output[offset + i] = out_sample;
            if (!std.math.isFinite(out_sample)) {
                nonfinite_count += 1;
            } else {
                peak = @max(peak, @abs(out_sample));
                sum += out_sample;
                sum_sq += out_sample * out_sample;
            }
        }
        offset += frames_per_render;
        if (offset < output.len) offset += gap_frames;
    }
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(render_count * frames_per_render));
    metrics.nonfinite_count = nonfinite_count;
    metrics.peak = peak;
    const finite_count = @as(f64, @floatFromInt(output.len - nonfinite_count));
    if (finite_count > 0) {
        metrics.mean = sum / finite_count;
        metrics.rms = @sqrt(sum_sq / finite_count);
    }

    try writeFilterArtifacts(alloc, cli, output, metrics, sample_rate, frames_per_render, gap_frames);
    if (metrics.nonfinite_count != 0 or metrics.peak > 8.0) return error.KernelRatchetFailed;

    std.debug.print(
        "kernel {s}:{s} case={s} renders={} frames={} ns_per_sample={d:.3} peak={d:.3} rms={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, render_count, frames_per_render, metrics.ns_per_iter, metrics.peak, metrics.rms },
    );
}

// Exercise the clean linear ZDF 4-pole ladder (kernels/04-filters/ladder.fy)
// across a cutoff sweep at several resonance settings, entirely through the fy
// chain. g = tan(pi*fc/sr) is computed here and passed in; k is the feedback,
// capped below the linear ladder's oscillation threshold of 4. Writes a WAV for
// listening / spectrogram plotting.
fn runLadderSweepCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_rate = FILTER_SAMPLE_RATE;
    const sr_f: f64 = @floatFromInt(sample_rate);
    const render_secs: f64 = 0.6;
    const frames_per_render: usize = @intFromFloat(render_secs * sr_f);
    const gap_frames: usize = @intFromFloat(FILTER_GAP_SECONDS * sr_f);
    const render_count = FILTER_RESONANCES.len;
    const total_frames = render_count * frames_per_render + (render_count - 1) * gap_frames;

    const output = try alloc.alloc(f64, total_frames);
    defer alloc.free(output);
    @memset(output, 0);

    const saw_gain: f64 = 0.5;
    const noise_gain: f64 = 0.03;

    const start = nowNs();
    var peak: f64 = 0;
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var nonfinite_count: usize = 0;
    var offset: usize = 0;
    for (FILTER_RESONANCES) |resonance| {
        // k = feedback; clamp below 4 so the linear ladder never blows up.
        const k = @min(resonance, 1.0) * 3.9;
        var lstate = [_]f64{ 0, 0, 0, 0 };
        var out_sample: f64 = 0;
        var osc_phase: f64 = 0;
        var noise_state: u32 = 0x1234abcd;
        var i: usize = 0;
        while (i < frames_per_render) : (i += 1) {
            const pos = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(frames_per_render - 1));
            const cutoff = FILTER_CUTOFF_START_HZ * @exp(@log(FILTER_CUTOFF_END_HZ / FILTER_CUTOFF_START_HZ) * pos);
            const g = std.math.tan(std.math.pi * cutoff / sr_f);
            const dt = FILTER_INPUT_HZ / sr_f;
            const input = zigSawPolyblep(osc_phase, dt) * saw_gain + whiteNoise(&noise_state) * noise_gain;
            osc_phase = wrap01(osc_phase + dt);

            const args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&out_sample) },
                .{ .ptr = @intFromPtr(&lstate[0]) },
                .{ .f64 = input },
                .{ .f64 = g },
                .{ .f64 = k },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-ladder4", 1, &args);

            output[offset + i] = out_sample;
            if (!std.math.isFinite(out_sample)) {
                nonfinite_count += 1;
            } else {
                peak = @max(peak, @abs(out_sample));
                sum += out_sample;
                sum_sq += out_sample * out_sample;
            }
        }
        offset += frames_per_render;
        if (offset < output.len) offset += gap_frames;
    }
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(render_count * frames_per_render));
    metrics.nonfinite_count = nonfinite_count;
    metrics.peak = peak;
    const finite_count = @as(f64, @floatFromInt(output.len - nonfinite_count));
    if (finite_count > 0) {
        metrics.mean = sum / finite_count;
        metrics.rms = @sqrt(sum_sq / finite_count);
    }

    try writeFilterArtifacts(alloc, cli, output, metrics, sample_rate, frames_per_render, gap_frames);
    if (metrics.nonfinite_count != 0 or metrics.peak > 8.0) return error.KernelRatchetFailed;

    std.debug.print(
        "kernel {s}:{s} case={s} renders={} frames={} ns_per_sample={d:.3} peak={d:.3} rms={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, render_count, frames_per_render, metrics.ns_per_iter, metrics.peak, metrics.rms },
    );
}

fn ms20ishLpfStep(state: *Ms20LpfState, input: f64, cutoff_hz: f64, resonance: f64, drive: f64, sample_rate: u32) f64 {
    const coeffs = ms20Coeffs(cutoff_hz, resonance, sample_rate);
    return ms20ishLpfStepWithCoeffs(state, input, coeffs.g, coeffs.damping, drive);
}

const Ms20Coeffs = struct {
    g: f64,
    damping: f64,
};

fn ms20Coeffs(cutoff_hz: f64, resonance: f64, sample_rate: u32) Ms20Coeffs {
    const oversample: usize = 4;
    const os_rate = @as(f64, @floatFromInt(sample_rate * oversample));
    const fc = std.math.clamp(cutoff_hz, 20.0, @as(f64, @floatFromInt(sample_rate)) * 0.42);
    const g = @tan(std.math.pi * fc / os_rate);
    const damping = @max(0.015, 1.2 / (1.0 + resonance * 8.0));
    return .{ .g = g, .damping = damping };
}

fn ms20ishLpfStepWithCoeffs(state: *Ms20LpfState, input: f64, g: f64, damping: f64, drive: f64) f64 {
    return ms20ishLpfStepWithCoeffsClip(state, input, g, damping, drive, .rational);
}

const Ms20Clip = enum {
    rational,
    cubic,
};

fn ms20ishLpfStepWithCoeffsClip(state: *Ms20LpfState, input: f64, g: f64, damping: f64, drive: f64, clip: Ms20Clip) f64 {
    const oversample: usize = 4;
    const driven = clipSample(input * drive, 1.0, clip);
    const h = 1.0 / (1.0 + 2.0 * damping * g + g * g);
    const coeff = 2.0 * damping + g;
    var out: f64 = state.ic2;
    var i: usize = 0;
    while (i < oversample) : (i += 1) {
        const hp = (driven - coeff * state.ic1 - state.ic2) * h;
        const bp = g * hp + state.ic1;
        state.ic1 = clipSample(g * hp + bp, 1.05, clip);
        const lp = g * bp + state.ic2;
        state.ic2 = clipSample(g * bp + lp, 1.05, clip);
        out = lp;
    }
    return clipSample(out, 1.8, clip);
}

fn runMs20FyFilterCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_count: usize = 8192;
    const sample_rate = FILTER_SAMPLE_RATE;
    const resonance: f64 = 1.08;
    const drive: f64 = 1.2;
    const clip: Ms20Clip = if (std.mem.eql(u8, cli.case_name, "ms20-lpf4-cubic-render")) .cubic else .rational;
    const out = try alloc.alloc(f64, sample_count);
    defer alloc.free(out);
    const expected = try alloc.alloc(f64, sample_count);
    defer alloc.free(expected);
    const input = try alloc.alloc(f64, sample_count);
    defer alloc.free(input);
    const g = try alloc.alloc(f64, sample_count);
    defer alloc.free(g);
    const damping = try alloc.alloc(f64, sample_count);
    defer alloc.free(damping);
    @memset(out, 0);
    @memset(expected, 0);

    var perf_out: f64 = 0;
    var perf_ic1: f64 = 0;
    var perf_ic2: f64 = 0;
    const perf_coeffs = ms20Coeffs(920.0, resonance, sample_rate);
    const perf_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .ptr = @intFromPtr(&perf_ic1) },
        .{ .ptr = @intFromPtr(&perf_ic2) },
        .{ .f64 = 0.25 },
        .{ .f64 = perf_coeffs.g },
        .{ .f64 = perf_coeffs.damping },
        .{ .f64 = drive },
    };
    const warmup = @min(cli.iterations, 1_000);
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, warmup, &perf_args);

    perf_out = 0;
    perf_ic1 = 0;
    perf_ic2 = 0;
    const start = nowNs();
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, cli.iterations, &perf_args);
    const run_ns = nowNs() - start;
    const zig_reference_ns_per_iter = benchmarkZigMs20Filter(perf_coeffs.g, perf_coeffs.damping, drive, clip, cli.iterations);

    var osc_phase: f64 = 0.19;
    var noise_state: u32 = 0x91f00d3d;
    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const pos = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_count - 1));
        const cutoff = 90.0 * @exp(@log(7200.0 / 90.0) * pos);
        const coeffs = ms20Coeffs(cutoff, resonance, sample_rate);
        const dt = 110.0 / @as(f64, @floatFromInt(sample_rate));
        input[i] = zigSawFallingPolyblep(osc_phase, dt) * 0.72 + whiteNoise(&noise_state) * 0.04;
        g[i] = coeffs.g;
        damping[i] = coeffs.damping;
        osc_phase = wrap01(osc_phase + dt);
    }

    var zig_state = Ms20LpfState{};
    for (expected, input, g, damping) |*exp, x, gg, damp| {
        exp.* = ms20ishLpfStepWithCoeffsClip(&zig_state, x, gg, damp, drive, clip);
    }

    var fy_ic1: f64 = 0;
    var fy_ic2: f64 = 0;
    i = 0;
    while (i < sample_count) : (i += 1) {
        const sample_args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out[i]) },
            .{ .ptr = @intFromPtr(&fy_ic1) },
            .{ .ptr = @intFromPtr(&fy_ic2) },
            .{ .f64 = input[i] },
            .{ .f64 = g[i] },
            .{ .f64 = damping[i] },
            .{ .f64 = drive },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &sample_args);
    }

    var metrics = computeSliceMetrics(out, expected, run_ns, cli.iterations);
    metrics.zig_reference_ns_per_iter = zig_reference_ns_per_iter;
    fillSignalMetrics(out, &metrics);
    try writeControlArtifacts(alloc, cli, host, out, expected, metrics);
    if (metrics.nonfinite_count != 0 or metrics.max_abs_error > 0.000000000001) {
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} samples={} ns_per_iter={d:.3} max_abs_error={d:.12} peak={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, sample_count, metrics.ns_per_iter, metrics.max_abs_error, metrics.peak },
    );
}

fn diodeClip(x: f64, amount: f64) f64 {
    return tanhRationalApprox(x * amount);
}

fn cubicClip(x: f64, amount: f64) f64 {
    const z = std.math.clamp(x * amount, -1.0, 1.0);
    return 1.5 * (z - (z * z * z) / 3.0);
}

fn clipSample(x: f64, amount: f64, clip: Ms20Clip) f64 {
    return switch (clip) {
        .rational => diodeClip(x, amount),
        .cubic => cubicClip(x, amount),
    };
}

fn whiteNoise(state: *u32) f64 {
    state.* = state.* *% 1664525 +% 1013904223;
    const v = (state.* >> 8) & 0x00ff_ffff;
    return @as(f64, @floatFromInt(v)) / 8_388_607.5 - 1.0;
}

fn runControlCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_count: usize = 1024;
    const out = try alloc.alloc(f64, sample_count);
    defer alloc.free(out);
    const expected = try alloc.alloc(f64, sample_count);
    defer alloc.free(expected);
    @memset(out, 0);
    @memset(expected, 0);

    var perf_out: f64 = 0;
    var perf_a: f64 = 0.25;
    var perf_b: f64 = -0.5;
    const perf_hz_step = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .f64 = 440.0 },
        .{ .f64 = 1.0 / 48_000.0 },
    };
    const perf_slew = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .ptr = @intFromPtr(&perf_a) },
        .{ .f64 = 0.8 },
        .{ .f64 = 0.035 },
    };
    const perf_vca = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .ptr = @intFromPtr(&perf_a) },
        .{ .f64 = 0.62 },
        .{ .f64 = 0.74 },
    };
    const perf_mix = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .ptr = @intFromPtr(&perf_a) },
        .{ .ptr = @intFromPtr(&perf_b) },
        .{ .f64 = 0.64 },
        .{ .f64 = 0.36 },
    };
    const perf_dc = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .ptr = @intFromPtr(&perf_a) },
        .{ .ptr = @intFromPtr(&perf_b) },
        .{ .f64 = 0.42 },
        .{ .f64 = 0.995 },
    };
    const perf_args = if (std.mem.eql(u8, cli.case_name, "hz-step-render"))
        perf_hz_step[0..]
    else if (std.mem.eql(u8, cli.case_name, "slew-onepole-render"))
        perf_slew[0..]
    else if (std.mem.eql(u8, cli.case_name, "vca-render"))
        perf_vca[0..]
    else if (std.mem.eql(u8, cli.case_name, "osc-mix2-render"))
        perf_mix[0..]
    else
        perf_dc[0..];
    const warmup = @min(cli.iterations, 1_000);
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, warmup, perf_args);

    perf_out = 0;
    perf_a = 0.25;
    perf_b = -0.5;
    const start = nowNs();
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, cli.iterations, perf_args);
    const run_ns = nowNs() - start;

    if (std.mem.eql(u8, cli.case_name, "hz-step-render")) {
        const inv_sample_rate = 1.0 / 48_000.0;
        var i: usize = 0;
        while (i < sample_count) : (i += 1) {
            const hz = 40.0 + @as(f64, @floatFromInt(i)) * 3.25;
            expected[i] = hz * inv_sample_rate;
            const sample_args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&out[i]) },
                .{ .f64 = hz },
                .{ .f64 = inv_sample_rate },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &sample_args);
        }
    } else if (std.mem.eql(u8, cli.case_name, "slew-onepole-render")) {
        const target = 0.8;
        const coeff = 0.035;
        var state: f64 = -0.65;
        var exp_state: f64 = state;
        for (out, expected) |*dst, *exp| {
            exp_state = exp_state + (target - exp_state) * coeff;
            exp.* = exp_state;
            const sample_args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(dst) },
                .{ .ptr = @intFromPtr(&state) },
                .{ .f64 = target },
                .{ .f64 = coeff },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &sample_args);
        }
    } else if (std.mem.eql(u8, cli.case_name, "vca-render")) {
        const amp = 0.62;
        const level = 0.74;
        var input: f64 = 0;
        for (out, expected, 0..) |*dst, *exp, i| {
            const phase = @as(f64, @floatFromInt(i)) / 64.0;
            input = @sin(phase * 2.0 * std.math.pi);
            exp.* = input * amp * level;
            const sample_args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(dst) },
                .{ .ptr = @intFromPtr(&input) },
                .{ .f64 = amp },
                .{ .f64 = level },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &sample_args);
        }
    } else if (std.mem.eql(u8, cli.case_name, "osc-mix2-render")) {
        const gain_a = 0.64;
        const gain_b = 0.36;
        var osc_a: f64 = 0;
        var osc_b: f64 = 0;
        var phase_a: f64 = 0;
        var phase_b: f64 = 0.17;
        const dt_a = 13.0 / @as(f64, @floatFromInt(sample_count));
        const dt_b = 19.0 / @as(f64, @floatFromInt(sample_count));
        for (out, expected) |*dst, *exp| {
            osc_a = zigSawPolyblep(phase_a, dt_a);
            osc_b = zigPulsePolyblep(phase_b, dt_b, 0.42);
            phase_a = wrap01(phase_a + dt_a);
            phase_b = wrap01(phase_b + dt_b);
            exp.* = osc_a * gain_a + osc_b * gain_b;
            const sample_args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(dst) },
                .{ .ptr = @intFromPtr(&osc_a) },
                .{ .ptr = @intFromPtr(&osc_b) },
                .{ .f64 = gain_a },
                .{ .f64 = gain_b },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &sample_args);
        }
    } else if (std.mem.eql(u8, cli.case_name, "dc-block-render")) {
        const coeff = 0.995;
        var prev_x: f64 = 0;
        var prev_y: f64 = 0;
        var exp_prev_x: f64 = 0;
        var exp_prev_y: f64 = 0;
        var input: f64 = 0;
        for (out, expected, 0..) |*dst, *exp, i| {
            const step: f64 = if (i >= 128) 0.42 else 0.0;
            input = step + 0.08 * @sin(@as(f64, @floatFromInt(i)) * 0.17);
            const y = input - exp_prev_x + coeff * exp_prev_y;
            exp_prev_x = input;
            exp_prev_y = y;
            exp.* = y;
            const sample_args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(dst) },
                .{ .ptr = @intFromPtr(&prev_x) },
                .{ .ptr = @intFromPtr(&prev_y) },
                .{ .f64 = input },
                .{ .f64 = coeff },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &sample_args);
        }
    } else {
        return error.InvalidCase;
    }

    var metrics = computeSliceMetrics(out, expected, run_ns, cli.iterations);
    fillSignalMetrics(out, &metrics);
    try writeControlArtifacts(alloc, cli, host, out, expected, metrics);
    if (metrics.nonfinite_count != 0 or metrics.max_abs_error > 0.000000000001) {
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} samples={} ns_per_iter={d:.3} max_abs_error={d:.12} peak={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, sample_count, metrics.ns_per_iter, metrics.max_abs_error, metrics.peak },
    );
}

const Ms20VoiceState = extern struct {
    phase1: f64 = 0,
    phase2: f64 = 0.37,
    ic1: f64 = 0,
    ic2: f64 = 0,
    dc_prev_x: f64 = 0,
    dc_prev_y: f64 = 0,
    amp: f64 = 0,
    age: f64 = 0,
};

const Ms20VoiceParams = extern struct {
    note_hz: f64 = 110,
    target_amp: f64 = 0,
    inv_sample_rate: f64 = 1.0 / 48_000.0,
    detune: f64 = 1.0058,
    g: f64 = 0,
    damping: f64 = 0,
    drive: f64 = 1.25,
    level: f64 = 0.72,
    amp_coeff: f64 = 0.0035,
    gate_time: f64 = 1.0e9,
    amp_attack: f64 = 0.0055,
    amp_decay: f64 = 0.12,
    amp_sustain: f64 = 0.46,
    amp_release: f64 = 0.13,
    g_env: f64 = 0,
    filter_attack: f64 = 0.014,
    filter_decay: f64 = 0.14,
    filter_sustain: f64 = 0.18,
    filter_release: f64 = 0.11,
};

const TimedNoteEvent = struct {
    absolute_sample: u64,
    event: machine.NoteEvent,
};

fn makeNoteEvent(sample_offset: u32, kind: machine.NoteKind, note_id: i32, pitch: f32, velocity: f32) machine.NoteEvent {
    return .{
        .sample_offset = sample_offset,
        .kind = kind,
        .channel = 0,
        .note_id = note_id,
        .pitch = pitch,
        .velocity = velocity,
    };
}

fn makeTimedNoteEvent(absolute_sample: u64, kind: machine.NoteKind, note_id: i32, pitch: f32, velocity: f32) TimedNoteEvent {
    return .{
        .absolute_sample = absolute_sample,
        .event = makeNoteEvent(0, kind, note_id, pitch, velocity),
    };
}

fn midiToHz(pitch: f64) f64 {
    return 440.0 * @exp(@log(2.0) * ((pitch - 69.0) / 12.0));
}

fn runMs20VoiceCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_rate = VOICE_SAMPLE_RATE;
    const frames: usize = @intFromFloat(VOICE_SECONDS * @as(f64, @floatFromInt(sample_rate)));
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    const env = try alloc.alloc(f64, frames);
    defer alloc.free(env);
    const cutoff = try alloc.alloc(f64, frames);
    defer alloc.free(cutoff);
    const note_track = try alloc.alloc(f64, frames);
    defer alloc.free(note_track);
    const gate_track = try alloc.alloc(f64, frames);
    defer alloc.free(gate_track);

    var state = Ms20VoiceState{};
    const inv_sr = 1.0 / @as(f64, @floatFromInt(sample_rate));
    const resonance = 1.25;
    const base_coeffs = ms20Coeffs(180.0, resonance, sample_rate);
    const peak_coeffs = ms20Coeffs(5000.0, resonance, sample_rate);
    var params = Ms20VoiceParams{
        .inv_sample_rate = inv_sr,
        .g = base_coeffs.g,
        .damping = base_coeffs.damping,
        .g_env = peak_coeffs.g - base_coeffs.g,
    };
    const events = [_]TimedNoteEvent{
        makeTimedNoteEvent(0, .note_on, 1, 45.0, 0.95),
        makeTimedNoteEvent(@intFromFloat(0.62 * @as(f64, @floatFromInt(sample_rate))), .note_off, 1, 45.0, 0.0),
        makeTimedNoteEvent(@intFromFloat(0.76 * @as(f64, @floatFromInt(sample_rate))), .note_on, 2, 48.0, 0.88),
        makeTimedNoteEvent(@intFromFloat(1.36 * @as(f64, @floatFromInt(sample_rate))), .note_off, 2, 48.0, 0.0),
        makeTimedNoteEvent(@intFromFloat(1.52 * @as(f64, @floatFromInt(sample_rate))), .note_on, 3, 43.0, 1.0),
        makeTimedNoteEvent(@intFromFloat(2.55 * @as(f64, @floatFromInt(sample_rate))), .note_off, 3, 43.0, 0.0),
    };

    const start = nowNs();
    @memset(out, 0);
    @memset(env, 0);
    @memset(cutoff, 1650.0);
    @memset(note_track, 0);
    @memset(gate_track, 0);

    var cursor: usize = 0;
    var event_index: usize = 0;
    while (cursor < frames) {
        const next_event_sample = if (event_index < events.len)
            @min(@as(usize, @intCast(events[event_index].absolute_sample)), frames)
        else
            frames;
        if (next_event_sample > cursor) {
            const count = next_event_sample - cursor;
            const segment_start_age = state.age;
            const args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&out[cursor]) },
                .{ .ptr = @intFromPtr(&state) },
                .{ .ptr = @intFromPtr(&params) },
            };
            _ = try host.fy.callDsp2RawRepeatedWithAutoOutNoResult(cli.word, @intCast(count), &args);
            var i = cursor;
            while (i < next_event_sample) : (i += 1) {
                const age = segment_start_age + @as(f64, @floatFromInt(i - cursor + 1)) * inv_sr;
                env[i] = envelopeExpected("adsr-cap-render", age, params.amp_attack, params.amp_decay, params.amp_sustain, params.gate_time, params.amp_release) * params.target_amp;
                const fenv = envelopeExpected("adsr-cap-render", age, params.filter_attack, params.filter_decay, params.filter_sustain, params.gate_time, params.filter_release);
                const g_now = params.g + params.g_env * fenv;
                cutoff[i] = @as(f64, @floatFromInt(sample_rate * 4)) * std.math.atan(g_now) / std.math.pi;
                note_track[i] = if (params.target_amp > 0.0001) params.note_hz else 0;
                gate_track[i] = if (age < params.gate_time) 1 else 0;
            }
            cursor = next_event_sample;
        }
        while (event_index < events.len and events[event_index].absolute_sample == cursor) : (event_index += 1) {
            const ev = events[event_index].event;
            if (ev.isOn()) {
                params.note_hz = midiToHz(@floatCast(ev.pitch));
                params.target_amp = @floatCast(ev.velocity);
                params.gate_time = 1.0e9;
                state.phase1 = 0;
                state.phase2 = 0.37;
                state.age = 0;
            } else if (ev.kind == .note_off) {
                params.gate_time = state.age;
            }
        }
    }
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    metrics.fundamental_hz = midiToHz(45.0);
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    try writeVoiceArtifacts(alloc, cli, host, out, env, cutoff, note_track, gate_track, events.len, metrics, sample_rate);
    if (metrics.nonfinite_count != 0 or metrics.peak > 4.0) return error.KernelRatchetFailed;

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} peak={d:.3} rms={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, metrics.peak, metrics.rms },
    );
}

fn benchmarkZigMs20Filter(g: f64, damping: f64, drive: f64, clip: Ms20Clip, iterations: u64) f64 {
    if (iterations == 0) return 0;
    var state = Ms20LpfState{};
    var sink: f64 = 0;
    const sink_ptr: *volatile f64 = @ptrCast(&sink);
    var i: u64 = 0;
    const start = nowNs();
    while (i < iterations) : (i += 1) {
        sink_ptr.* = ms20ishLpfStepWithCoeffsClip(&state, 0.25, g, damping, drive, clip);
    }
    const run_ns = nowNs() - start;
    return @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(iterations));
}

fn runEnvelopeCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_count: usize = 1201;
    const control_rate: f64 = 1000.0;
    const attack: f64 = 0.08;
    const decay: f64 = 0.18;
    const sustain: f64 = 0.42;
    const gate: f64 = 0.72;
    const release: f64 = 0.35;

    const time = try alloc.alloc(f64, sample_count);
    defer alloc.free(time);
    const out = try alloc.alloc(f64, sample_count);
    defer alloc.free(out);
    const expected = try alloc.alloc(f64, sample_count);
    defer alloc.free(expected);

    for (time, expected, out, 0..) |*t, *exp, *dst, i| {
        t.* = @as(f64, @floatFromInt(i)) / control_rate;
        exp.* = envelopeExpected(cli.case_name, t.*, attack, decay, sustain, gate, release);
        dst.* = 0;
    }

    var perf_out: f64 = 0;
    var perf_time: f64 = 0.375;
    const perf_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .ptr = @intFromPtr(&perf_time) },
        .{ .f64 = attack },
        .{ .f64 = decay },
        .{ .f64 = sustain },
        .{ .f64 = gate },
        .{ .f64 = release },
    };
    const warmup = @min(cli.iterations, 1_000);
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, warmup, &perf_args);

    const start = nowNs();
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, cli.iterations, &perf_args);
    const run_ns = nowNs() - start;

    for (time, out) |*t, *dst| {
        const sample_args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(dst) },
            .{ .ptr = @intFromPtr(t) },
            .{ .f64 = attack },
            .{ .f64 = decay },
            .{ .f64 = sustain },
            .{ .f64 = gate },
            .{ .f64 = release },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &sample_args);
    }

    var metrics = computeSliceMetrics(out, expected, run_ns, cli.iterations);
    fillSignalMetrics(out, &metrics);
    try writeEnvelopeArtifacts(alloc, cli, host, time, out, expected, metrics, control_rate, attack, decay, sustain, gate, release);
    if (metrics.nonfinite_count != 0 or metrics.max_abs_error > 0.000000000001) {
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} samples={} ns_per_iter={d:.3} max_abs_error={d:.12} peak={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, sample_count, metrics.ns_per_iter, metrics.max_abs_error, metrics.peak },
    );
}

fn zigAdsrLinear(time: f64, attack: f64, decay: f64, sustain: f64, gate: f64, release: f64) f64 {
    if (time < attack) return std.math.clamp(time / attack, 0.0, 1.0);
    const decay_end = attack + decay;
    if (time < decay_end) {
        const u = (time - attack) / decay;
        return 1.0 - (1.0 - sustain) * u;
    }
    if (time < gate) return sustain;
    const release_end = gate + release;
    if (time < release_end) {
        const u = (time - gate) / release;
        return sustain * (1.0 - u);
    }
    return 0.0;
}

fn zigCapCurve(u_unclamped: f64) f64 {
    const u = std.math.clamp(u_unclamped, 0.0, 1.0);
    const inv = 1.0 - u;
    const inv2 = inv * inv;
    return inv2 * inv2;
}

fn zigAdsrCap(time: f64, attack: f64, decay: f64, sustain: f64, gate: f64, release: f64) f64 {
    if (time < attack) return 1.0 - zigCapCurve(time / attack);
    const decay_end = attack + decay;
    if (time < decay_end) {
        const u = (time - attack) / decay;
        return sustain + (1.0 - sustain) * zigCapCurve(u);
    }
    if (time < gate) return sustain;
    const release_end = gate + release;
    if (time < release_end) {
        const u = (time - gate) / release;
        return sustain * zigCapCurve(u);
    }
    return 0.0;
}

fn envelopeExpected(case_name: []const u8, time: f64, attack: f64, decay: f64, sustain: f64, gate: f64, release: f64) f64 {
    if (std.mem.eql(u8, case_name, "adsr-cap-render")) return zigAdsrCap(time, attack, decay, sustain, gate, release);
    return zigAdsrLinear(time, attack, decay, sustain, gate, release);
}

fn runSawPolyblepCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_count: usize = 4096;
    const sample_rate: f64 = @floatFromInt(OSC_SAMPLE_RATE);
    const fundamental_bin: usize = 171;
    const freq = sample_rate * @as(f64, @floatFromInt(fundamental_bin)) / @as(f64, @floatFromInt(sample_count));
    const inv_sample_rate = 1.0 / sample_rate;
    const initial_phase: f64 = 0.137;
    const pulse_width: f64 = 0.37;
    const use_pulse_width = std.mem.eql(u8, cli.case_name, "pulse-polyblep-render");

    const out = try alloc.alloc(f64, sample_count);
    defer alloc.free(out);
    const expected = try alloc.alloc(f64, sample_count);
    defer alloc.free(expected);
    const naive = try alloc.alloc(f64, sample_count);
    defer alloc.free(naive);

    var expected_phase = initial_phase;
    const dt = freq * inv_sample_rate;
    for (expected, naive) |*exp, *dry| {
        exp.* = oscillatorExpected(cli.case_name, expected_phase, dt, pulse_width);
        dry.* = oscillatorNaive(cli.case_name, expected_phase, pulse_width);
        expected_phase = wrap01(expected_phase + dt);
    }

    var perf_out: f64 = 0;
    var perf_phase = initial_phase;
    const perf_args4 = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .ptr = @intFromPtr(&perf_phase) },
        .{ .f64 = freq },
        .{ .f64 = inv_sample_rate },
    };
    const perf_args5 = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .ptr = @intFromPtr(&perf_phase) },
        .{ .f64 = freq },
        .{ .f64 = inv_sample_rate },
        .{ .f64 = pulse_width },
    };
    const perf_args = if (use_pulse_width) perf_args5[0..] else perf_args4[0..];
    const warmup = @min(cli.iterations, 1_000);
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, warmup, perf_args);

    perf_phase = initial_phase;
    const start = nowNs();
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, cli.iterations, perf_args);
    const run_ns = nowNs() - start;

    const final_analysis_phase = try renderOscillatorBuffer(host, cli.word, out, initial_phase, freq, inv_sample_rate, pulse_width, use_pulse_width);

    var metrics = computeSliceMetrics(out, expected, run_ns, cli.iterations);
    fillSignalMetrics(out, &metrics);
    metrics.final_phase = final_analysis_phase;
    metrics.fundamental_hz = freq;
    metrics.alias_residual_db = harmonicResidualDb(out, fundamental_bin);
    metrics.naive_alias_residual_db = harmonicResidualDb(naive, fundamental_bin);

    try writeSawArtifacts(alloc, cli, host, out, expected, naive, metrics, OSC_SAMPLE_RATE, pulse_width);
    if (metrics.nonfinite_count != 0 or metrics.max_abs_error > 0.000000000001) {
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} samples={} freq={d:.3} ns_per_iter={d:.3} max_abs_error={d:.12} alias_residual_db={d:.2}\n",
        .{ cli.kernel, cli.word, cli.case_name, sample_count, freq, metrics.ns_per_iter, metrics.max_abs_error, metrics.alias_residual_db },
    );
}

fn renderOscillatorBuffer(
    host: *FyHost,
    word: []const u8,
    out: []f64,
    initial_phase: f64,
    freq: f64,
    inv_sample_rate: f64,
    pulse_width: f64,
    use_pulse_width: bool,
) !f64 {
    var phase = initial_phase;
    for (out) |*dst| {
        const sample_args4 = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(dst) },
            .{ .ptr = @intFromPtr(&phase) },
            .{ .f64 = freq },
            .{ .f64 = inv_sample_rate },
        };
        const sample_args5 = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(dst) },
            .{ .ptr = @intFromPtr(&phase) },
            .{ .f64 = freq },
            .{ .f64 = inv_sample_rate },
            .{ .f64 = pulse_width },
        };
        const sample_args = if (use_pulse_width) sample_args5[0..] else sample_args4[0..];
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(word, 1, sample_args);
    }
    return phase;
}

fn zigSawRaw(phase: f64) f64 {
    return phase + phase - 1.0;
}

fn zigPolyblep(phase: f64, dt: f64) f64 {
    if (phase < dt) {
        const u = phase / dt;
        return u + u - u * u - 1.0;
    }
    if (phase > 1.0 - dt) {
        const u = (phase - 1.0) / dt;
        return u * u + u + u + 1.0;
    }
    return 0.0;
}

fn zigSawPolyblep(phase: f64, dt: f64) f64 {
    return zigSawRaw(phase) - zigPolyblep(phase, dt);
}

fn zigSawFallingRaw(phase: f64) f64 {
    return 1.0 - phase - phase;
}

fn zigSawFallingPolyblep(phase: f64, dt: f64) f64 {
    return zigSawFallingRaw(phase) + zigPolyblep(phase, dt);
}

fn zigCapRampRaw(phase: f64) f64 {
    return 4.0 * phase - 2.0 * phase * phase - 1.0;
}

fn zigCapSawPolyblep(phase: f64, dt: f64) f64 {
    return zigCapRampRaw(phase) - zigPolyblep(phase, dt);
}

fn zigPulseRaw(phase: f64, width: f64) f64 {
    return if (phase < width) 1.0 else -1.0;
}

fn zigPulsePolyblep(phase: f64, dt: f64, width: f64) f64 {
    const edge = wrap01(phase - width);
    return zigPulseRaw(phase, width) + zigPolyblep(phase, dt) - zigPolyblep(edge, dt);
}

fn oscillatorExpected(case_name: []const u8, phase: f64, dt: f64, width: f64) f64 {
    if (std.mem.eql(u8, case_name, "saw-falling-polyblep-render")) return zigSawFallingPolyblep(phase, dt);
    if (std.mem.eql(u8, case_name, "saw-cap-polyblep-render")) return zigCapSawPolyblep(phase, dt);
    if (std.mem.eql(u8, case_name, "saw-topcut-polyblep-render")) return std.math.clamp(zigSawPolyblep(phase, dt), -1.0, 0.65);
    if (std.mem.eql(u8, case_name, "square-polyblep-render")) return zigPulsePolyblep(phase, dt, 0.5);
    if (std.mem.eql(u8, case_name, "pulse-polyblep-render")) return zigPulsePolyblep(phase, dt, width);
    return zigSawPolyblep(phase, dt);
}

fn oscillatorNaive(case_name: []const u8, phase: f64, width: f64) f64 {
    if (std.mem.eql(u8, case_name, "saw-falling-polyblep-render")) return zigSawFallingRaw(phase);
    if (std.mem.eql(u8, case_name, "saw-cap-polyblep-render")) return zigCapRampRaw(phase);
    if (std.mem.eql(u8, case_name, "saw-topcut-polyblep-render")) return std.math.clamp(zigSawRaw(phase), -1.0, 0.65);
    if (std.mem.eql(u8, case_name, "square-polyblep-render")) return zigPulseRaw(phase, 0.5);
    if (std.mem.eql(u8, case_name, "pulse-polyblep-render")) return zigPulseRaw(phase, width);
    return zigSawRaw(phase);
}

fn wrap01(x: f64) f64 {
    if (x > 1.0) return x - 1.0;
    if (x < 0.0) return x + 1.0;
    return x;
}

fn fillSignalMetrics(signal: []const f64, metrics: *Metrics) void {
    if (signal.len == 0) return;
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var peak: f64 = 0;
    for (signal) |x| {
        sum += x;
        sum_sq += x * x;
        peak = @max(peak, @abs(x));
    }
    metrics.mean = sum / @as(f64, @floatFromInt(signal.len));
    metrics.rms = @sqrt(sum_sq / @as(f64, @floatFromInt(signal.len)));
    metrics.peak = peak;
}

fn harmonicResidualDb(signal: []const f64, fundamental_bin: usize) f64 {
    const n = signal.len;
    if (n == 0 or fundamental_bin == 0) return 0;

    var total_power: f64 = 0;
    var harmonic_power: f64 = 0;
    var k: usize = 1;
    while (k < n / 2) : (k += 1) {
        var re: f64 = 0;
        var im: f64 = 0;
        for (signal, 0..) |x, i| {
            const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(k * i)) / @as(f64, @floatFromInt(n));
            re += x * @cos(angle);
            im -= x * @sin(angle);
        }
        const power = re * re + im * im;
        total_power += power;
        if (k % fundamental_bin == 0) harmonic_power += power;
    }

    if (total_power <= 0) return -300;
    const residual = @max(total_power - harmonic_power, 1.0e-300);
    return 10.0 * @log10(residual / total_power);
}

fn computeTrueTanhError(input: []const f64, out: []const f64, drive: f64) f64 {
    var max_abs_error: f64 = 0;
    for (input, out) |inp, actual| {
        const true_value = tanh(inp * drive);
        max_abs_error = @max(max_abs_error, @abs(actual - true_value));
    }
    return max_abs_error;
}

fn makeFyFloat(value: f64) Fy.Value {
    const bits: u64 = @bitCast(value);
    const tagged = (bits & ~@as(u64, 3)) | 2;
    return @bitCast(tagged);
}

fn computeSliceMetrics(out: []const f64, expected: []const f64, run_ns: u64, iterations: u64) Metrics {
    var m = Metrics{};
    for (out, expected) |actual, exp| {
        if (!std.math.isFinite(actual)) {
            m.nonfinite_count += 1;
            continue;
        }
        m.max_abs_error = @max(m.max_abs_error, @abs(actual - exp));
    }
    if (iterations > 0) {
        m.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(iterations));
    }
    return m;
}

fn writeArtifacts(alloc: std.mem.Allocator, cli: Cli, host: *FyHost, data: CaseData, out: [2]f64, metrics: Metrics) !void {
    const metrics_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(metrics_path);
    const disasm_path = try std.fmt.allocPrint(alloc, "{s}_disasm.txt", .{cli.out_prefix});
    defer alloc.free(disasm_path);
    const lanes_path = try std.fmt.allocPrint(alloc, "{s}_lanes.csv", .{cli.out_prefix});
    defer alloc.free(lanes_path);

    const report = if (host.fy.isDsp2Word(cli.word))
        try host.fy.reportDsp2RawWord(cli.word)
    else
        host.fy.reportWord(cli.word) orelse return error.MissingReport;
    const metrics_json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "kernel": "{s}",
        \\  "word": "{s}",
        \\  "case": "{s}",
        \\  "iterations": {d},
        \\  "ns_per_iter": {d:.6},
        \\  "max_abs_error": {d:.12},
        \\  "nonfinite_count": {d},
        \\  "instruction_count": {d},
        \\  "push_count": {d},
        \\  "pop_count": {d},
        \\  "float_alu_count": {d},
        \\  "neon_float_alu_count": {d},
        \\  "neon_load_count": {d},
        \\  "neon_store_count": {d}
        \\}}
        \\
    , .{
        cli.kernel,
        cli.word,
        cli.case_name,
        cli.iterations,
        metrics.ns_per_iter,
        metrics.max_abs_error,
        metrics.nonfinite_count,
        report.instruction_count,
        report.push_count,
        report.pop_count,
        report.float_alu_count,
        report.neon_float_alu_count,
        report.neon_load_count,
        report.neon_store_count,
    });
    defer alloc.free(metrics_json);
    try writeFile(alloc, metrics_path, metrics_json);

    const disasm = if (host.fy.isDsp2Word(cli.word))
        try host.fy.disassembleDsp2RawWordAlloc(alloc, cli.word)
    else
        try host.fy.disassembleWordAlloc(alloc, cli.word);
    defer alloc.free(disasm);
    try writeFile(alloc, disasm_path, disasm);

    const lanes = try std.fmt.allocPrint(alloc,
        \\lane,a,b,acc,out,expected,error
        \\0,{d:.12},{d:.12},{d:.12},{d:.12},{d:.12},{d:.12}
        \\1,{d:.12},{d:.12},{d:.12},{d:.12},{d:.12},{d:.12}
        \\
    , .{
        data.a[0], data.b[0], data.acc[0], out[0], data.expected[0], out[0] - data.expected[0],
        data.a[1], data.b[1], data.acc[1], out[1], data.expected[1], out[1] - data.expected[1],
    });
    defer alloc.free(lanes);
    try writeFile(alloc, lanes_path, lanes);
}

fn writeTanhArtifacts(
    alloc: std.mem.Allocator,
    cli: Cli,
    host: *FyHost,
    input: []const f64,
    expected: []const f64,
    out: []const f64,
    metrics: Metrics,
    table_len: usize,
    drive: f64,
) !void {
    const metrics_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(metrics_path);
    const disasm_path = try std.fmt.allocPrint(alloc, "{s}_disasm.txt", .{cli.out_prefix});
    defer alloc.free(disasm_path);
    const lanes_path = try std.fmt.allocPrint(alloc, "{s}_lanes.csv", .{cli.out_prefix});
    defer alloc.free(lanes_path);

    const report = if (host.fy.isDsp2Word(cli.word))
        try host.fy.reportDsp2RawWord(cli.word)
    else
        host.fy.reportWord(cli.word) orelse return error.MissingReport;
    const metrics_json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "kernel": "{s}",
        \\  "word": "{s}",
        \\  "case": "{s}",
        \\  "samples": {d},
        \\  "table_len": {d},
        \\  "drive": {d:.6},
        \\  "iterations": {d},
        \\  "ns_per_iter": {d:.6},
        \\  "libc_tanh_ns_per_iter": {d:.6},
        \\  "zig_table_ns_per_iter": {d:.6},
        \\  "zig_rational_ns_per_iter": {d:.6},
        \\  "table_vs_libc_tanh_speedup": {d:.6},
        \\  "zig_table_vs_libc_tanh_speedup": {d:.6},
        \\  "zig_rational_vs_libc_tanh_speedup": {d:.6},
        \\  "table_vs_libc_tanh_max_abs_error": {d:.12},
        \\  "max_abs_error": {d:.12},
        \\  "nonfinite_count": {d},
        \\  "instruction_count": {d},
        \\  "push_count": {d},
        \\  "pop_count": {d},
        \\  "float_alu_count": {d},
        \\  "neon_float_alu_count": {d},
        \\  "neon_load_count": {d},
        \\  "neon_store_count": {d}
        \\}}
        \\
    , .{
        cli.kernel,
        cli.word,
        cli.case_name,
        input.len,
        table_len,
        drive,
        cli.iterations,
        metrics.ns_per_iter,
        metrics.libc_tanh_ns_per_iter,
        metrics.zig_table_ns_per_iter,
        metrics.zig_rational_ns_per_iter,
        if (metrics.ns_per_iter > 0) metrics.libc_tanh_ns_per_iter / metrics.ns_per_iter else 0,
        if (metrics.zig_table_ns_per_iter > 0) metrics.libc_tanh_ns_per_iter / metrics.zig_table_ns_per_iter else 0,
        if (metrics.zig_rational_ns_per_iter > 0) metrics.libc_tanh_ns_per_iter / metrics.zig_rational_ns_per_iter else 0,
        metrics.table_vs_libc_tanh_max_abs_error,
        metrics.max_abs_error,
        metrics.nonfinite_count,
        report.instruction_count,
        report.push_count,
        report.pop_count,
        report.float_alu_count,
        report.neon_float_alu_count,
        report.neon_load_count,
        report.neon_store_count,
    });
    defer alloc.free(metrics_json);
    try writeFile(alloc, metrics_path, metrics_json);

    const disasm = if (host.fy.isDsp2Word(cli.word))
        try host.fy.disassembleDsp2RawWordAlloc(alloc, cli.word)
    else
        try host.fy.disassembleWordAlloc(alloc, cli.word);
    defer alloc.free(disasm);
    try writeFile(alloc, disasm_path, disasm);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,input,out,expected,error\n");
    for (input, out, expected, 0..) |inp, actual, exp, i| {
        try appendFmt(alloc, &csv, "{d},{d:.12},{d:.12},{d:.12},{d:.12}\n", .{
            i,
            inp,
            actual,
            exp,
            actual - exp,
        });
    }
    try writeFile(alloc, lanes_path, csv.items);
}

fn writeEnvelopeArtifacts(
    alloc: std.mem.Allocator,
    cli: Cli,
    host: *FyHost,
    time: []const f64,
    out: []const f64,
    expected: []const f64,
    metrics: Metrics,
    control_rate: f64,
    attack: f64,
    decay: f64,
    sustain: f64,
    gate: f64,
    release: f64,
) !void {
    const metrics_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(metrics_path);
    const disasm_path = try std.fmt.allocPrint(alloc, "{s}_disasm.txt", .{cli.out_prefix});
    defer alloc.free(disasm_path);
    const lanes_path = try std.fmt.allocPrint(alloc, "{s}_lanes.csv", .{cli.out_prefix});
    defer alloc.free(lanes_path);

    const report = if (host.fy.isDsp2Word(cli.word))
        try host.fy.reportDsp2RawWord(cli.word)
    else
        host.fy.reportWord(cli.word) orelse return error.MissingReport;
    const seconds = if (time.len > 0) time[time.len - 1] else 0.0;
    const metrics_json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "kernel": "{s}",
        \\  "word": "{s}",
        \\  "case": "{s}",
        \\  "samples": {d},
        \\  "control_rate": {d:.6},
        \\  "seconds": {d:.6},
        \\  "attack": {d:.6},
        \\  "decay": {d:.6},
        \\  "sustain": {d:.6},
        \\  "gate": {d:.6},
        \\  "release": {d:.6},
        \\  "release_end": {d:.6},
        \\  "iterations": {d},
        \\  "ns_per_iter": {d:.6},
        \\  "max_abs_error": {d:.12},
        \\  "nonfinite_count": {d},
        \\  "rms": {d:.12},
        \\  "peak": {d:.12},
        \\  "mean": {d:.12},
        \\  "instruction_count": {d},
        \\  "push_count": {d},
        \\  "pop_count": {d},
        \\  "float_alu_count": {d},
        \\  "neon_float_alu_count": {d},
        \\  "neon_load_count": {d},
        \\  "neon_store_count": {d}
        \\}}
        \\
    , .{
        cli.kernel,
        cli.word,
        cli.case_name,
        time.len,
        control_rate,
        seconds,
        attack,
        decay,
        sustain,
        gate,
        release,
        gate + release,
        cli.iterations,
        metrics.ns_per_iter,
        metrics.max_abs_error,
        metrics.nonfinite_count,
        metrics.rms,
        metrics.peak,
        metrics.mean,
        report.instruction_count,
        report.push_count,
        report.pop_count,
        report.float_alu_count,
        report.neon_float_alu_count,
        report.neon_load_count,
        report.neon_store_count,
    });
    defer alloc.free(metrics_json);
    try writeFile(alloc, metrics_path, metrics_json);

    const disasm = if (host.fy.isDsp2Word(cli.word))
        try host.fy.disassembleDsp2RawWordAlloc(alloc, cli.word)
    else
        try host.fy.disassembleWordAlloc(alloc, cli.word);
    defer alloc.free(disasm);
    try writeFile(alloc, disasm_path, disasm);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,out,expected,error,gate\n");
    for (time, out, expected, 0..) |t, actual, exp, i| {
        try appendFmt(alloc, &csv, "{d},{d:.12},{d:.12},{d:.12},{d:.12},{d:.12}\n", .{
            i,
            t,
            actual,
            exp,
            actual - exp,
            if (t < gate) @as(f64, 1.0) else 0.0,
        });
    }
    try writeFile(alloc, lanes_path, csv.items);
}

fn writeFilterArtifacts(
    alloc: std.mem.Allocator,
    cli: Cli,
    output: []const f64,
    metrics: Metrics,
    sample_rate: u32,
    frames_per_render: usize,
    gap_frames: usize,
) !void {
    const metrics_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(metrics_path);
    const lanes_path = try std.fmt.allocPrint(alloc, "{s}_lanes.csv", .{cli.out_prefix});
    defer alloc.free(lanes_path);
    const wav_path = try std.fmt.allocPrint(alloc, "{s}.wav", .{cli.out_prefix});
    defer alloc.free(wav_path);

    var metrics_json: std.ArrayList(u8) = .empty;
    defer metrics_json.deinit(alloc);
    try appendFmt(alloc, &metrics_json,
        \\{{
        \\  "kernel": "{s}",
        \\  "word": "{s}",
        \\  "case": "{s}",
        \\  "sample_rate": {d},
        \\  "renders": {d},
        \\  "render_frames": {d},
        \\  "gap_frames": {d},
        \\  "seconds_per_render": {d:.6},
        \\  "cutoff_start_hz": {d:.6},
        \\  "cutoff_end_hz": {d:.6},
        \\  "input_hz": {d:.6},
        \\  "saw_gain": {d:.6},
        \\  "noise_gain": {d:.6},
        \\  "drive": {d:.6},
        \\  "oversample": 4,
        \\  "wav_path": "{s}",
        \\  "wav_samples": {d},
        \\  "wav_seconds": {d:.6},
        \\  "iterations": {d},
        \\  "ns_per_iter": {d:.6},
        \\  "nonfinite_count": {d},
        \\  "rms": {d:.12},
        \\  "peak": {d:.12},
        \\  "mean": {d:.12},
        \\  "instruction_count": 0,
        \\  "push_count": 0,
        \\  "pop_count": 0,
        \\  "float_alu_count": 0,
        \\  "neon_float_alu_count": 0,
        \\  "neon_load_count": 0,
        \\  "neon_store_count": 0,
        \\  "resonances": [
        \\
    , .{
        cli.kernel,
        cli.word,
        cli.case_name,
        sample_rate,
        FILTER_RESONANCES.len,
        frames_per_render,
        gap_frames,
        @as(f64, @floatFromInt(frames_per_render)) / @as(f64, @floatFromInt(sample_rate)),
        FILTER_CUTOFF_START_HZ,
        FILTER_CUTOFF_END_HZ,
        FILTER_INPUT_HZ,
        FILTER_SAW_GAIN,
        FILTER_NOISE_GAIN,
        FILTER_DRIVE,
        wav_path,
        output.len,
        @as(f64, @floatFromInt(output.len)) / @as(f64, @floatFromInt(sample_rate)),
        cli.iterations,
        metrics.ns_per_iter,
        metrics.nonfinite_count,
        metrics.rms,
        metrics.peak,
        metrics.mean,
    });
    for (FILTER_RESONANCES, 0..) |resonance, i| {
        try appendFmt(alloc, &metrics_json, "    {d:.6}{s}\n", .{
            resonance,
            if (i + 1 == FILTER_RESONANCES.len) "" else ",",
        });
    }
    try metrics_json.appendSlice(alloc,
        \\  ]
        \\}
        \\
    );
    try writeFile(alloc, metrics_path, metrics_json.items);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "render,sample,time,input_hz,cutoff_hz,resonance,out\n");
    const decimate: usize = 64;
    var offset: usize = 0;
    for (FILTER_RESONANCES, 0..) |resonance, render| {
        var i: usize = 0;
        while (i < frames_per_render) : (i += decimate) {
            const pos = if (frames_per_render > 1)
                @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(frames_per_render - 1))
            else
                0.0;
            const cutoff = FILTER_CUTOFF_START_HZ * @exp(@log(FILTER_CUTOFF_END_HZ / FILTER_CUTOFF_START_HZ) * pos);
            try appendFmt(alloc, &csv, "{d},{d},{d:.12},{d:.6},{d:.6},{d:.6},{d:.12}\n", .{
                render,
                i,
                @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_rate)),
                FILTER_INPUT_HZ,
                cutoff,
                resonance,
                output[offset + i],
            });
        }
        offset += frames_per_render;
        if (offset < output.len) offset += gap_frames;
    }
    try writeFile(alloc, lanes_path, csv.items);
    try writeWav16StereoBuffer(alloc, wav_path, output, sample_rate);
}

fn writeControlArtifacts(
    alloc: std.mem.Allocator,
    cli: Cli,
    host: *FyHost,
    out: []const f64,
    expected: []const f64,
    metrics: Metrics,
) !void {
    const metrics_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(metrics_path);
    const disasm_path = try std.fmt.allocPrint(alloc, "{s}_disasm.txt", .{cli.out_prefix});
    defer alloc.free(disasm_path);
    const lanes_path = try std.fmt.allocPrint(alloc, "{s}_lanes.csv", .{cli.out_prefix});
    defer alloc.free(lanes_path);

    const report = if (host.fy.isDsp2Word(cli.word))
        try host.fy.reportDsp2RawWord(cli.word)
    else
        host.fy.reportWord(cli.word) orelse return error.MissingReport;
    const metrics_json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "kernel": "{s}",
        \\  "word": "{s}",
        \\  "case": "{s}",
        \\  "samples": {d},
        \\  "iterations": {d},
        \\  "ns_per_iter": {d:.6},
        \\  "zig_reference_ns_per_iter": {d:.6},
        \\  "max_abs_error": {d:.12},
        \\  "nonfinite_count": {d},
        \\  "rms": {d:.12},
        \\  "peak": {d:.12},
        \\  "mean": {d:.12},
        \\  "instruction_count": {d},
        \\  "push_count": {d},
        \\  "pop_count": {d},
        \\  "float_alu_count": {d},
        \\  "neon_float_alu_count": {d},
        \\  "neon_load_count": {d},
        \\  "neon_store_count": {d}
        \\}}
        \\
    , .{
        cli.kernel,
        cli.word,
        cli.case_name,
        out.len,
        cli.iterations,
        metrics.ns_per_iter,
        metrics.zig_reference_ns_per_iter,
        metrics.max_abs_error,
        metrics.nonfinite_count,
        metrics.rms,
        metrics.peak,
        metrics.mean,
        report.instruction_count,
        report.push_count,
        report.pop_count,
        report.float_alu_count,
        report.neon_float_alu_count,
        report.neon_load_count,
        report.neon_store_count,
    });
    defer alloc.free(metrics_json);
    try writeFile(alloc, metrics_path, metrics_json);

    const disasm = if (host.fy.isDsp2Word(cli.word))
        try host.fy.disassembleDsp2RawWordAlloc(alloc, cli.word)
    else
        try host.fy.disassembleWordAlloc(alloc, cli.word);
    defer alloc.free(disasm);
    try writeFile(alloc, disasm_path, disasm);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,out,expected,error\n");
    for (out, expected, 0..) |actual, exp, i| {
        try appendFmt(alloc, &csv, "{d},{d:.12},{d:.12},{d:.12}\n", .{
            i,
            actual,
            exp,
            actual - exp,
        });
    }
    try writeFile(alloc, lanes_path, csv.items);
}

fn writeVoiceArtifacts(
    alloc: std.mem.Allocator,
    cli: Cli,
    host: *FyHost,
    out: []const f64,
    env: []const f64,
    cutoff: []const f64,
    note_track: []const f64,
    gate_track: []const f64,
    event_count: usize,
    metrics: Metrics,
    sample_rate: u32,
) !void {
    const metrics_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(metrics_path);
    const disasm_path = try std.fmt.allocPrint(alloc, "{s}_disasm.txt", .{cli.out_prefix});
    defer alloc.free(disasm_path);
    const lanes_path = try std.fmt.allocPrint(alloc, "{s}_lanes.csv", .{cli.out_prefix});
    defer alloc.free(lanes_path);
    const wav_path = try std.fmt.allocPrint(alloc, "{s}.wav", .{cli.out_prefix});
    defer alloc.free(wav_path);

    // Composition words have no single raw body to report/disassemble.
    const report = if (host.fy.isCompositionWord(cli.word))
        Fy.CompileReport{}
    else
        try host.fy.reportDsp2RawWord(cli.word);
    const metrics_json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "kernel": "{s}",
        \\  "word": "{s}",
        \\  "case": "{s}",
        \\  "sample_rate": {d},
        \\  "samples": {d},
        \\  "seconds": {d:.6},
        \\  "wav_path": "{s}",
        \\  "fundamental_hz": {d:.6},
        \\  "ns_per_sample": {d:.6},
        \\  "nonfinite_count": {d},
        \\  "rms": {d:.12},
        \\  "peak": {d:.12},
        \\  "mean": {d:.12},
        \\  "note_event_count": {d},
        \\  "oscillators": 2,
        \\  "filter": "zig-ms20ish-same-math-as-fy-k-ms20-lpf4",
        \\  "vca": "amp-envelope-times-level",
        \\  "dc_block_coeff": 0.995000,
        \\  "instruction_count": {d},
        \\  "push_count": {d},
        \\  "pop_count": {d},
        \\  "float_alu_count": {d},
        \\  "neon_float_alu_count": {d},
        \\  "neon_load_count": {d},
        \\  "neon_store_count": {d}
        \\}}
        \\
    , .{
        cli.kernel,
        cli.word,
        cli.case_name,
        sample_rate,
        out.len,
        @as(f64, @floatFromInt(out.len)) / @as(f64, @floatFromInt(sample_rate)),
        wav_path,
        metrics.fundamental_hz,
        metrics.ns_per_iter,
        metrics.nonfinite_count,
        metrics.rms,
        metrics.peak,
        metrics.mean,
        event_count,
        report.instruction_count,
        report.push_count,
        report.pop_count,
        report.float_alu_count,
        report.neon_float_alu_count,
        report.neon_load_count,
        report.neon_store_count,
    });
    defer alloc.free(metrics_json);
    try writeFile(alloc, metrics_path, metrics_json);
    try writeWav16StereoBuffer(alloc, wav_path, out, sample_rate);
    if (!host.fy.isCompositionWord(cli.word)) {
        const disasm = try host.fy.disassembleDsp2RawWordAlloc(alloc, cli.word);
        defer alloc.free(disasm);
        try writeFile(alloc, disasm_path, disasm);
    }

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,out,amp_env,cutoff_hz,note_hz,gate\n");
    const decimate: usize = 32;
    var i: usize = 0;
    while (i < out.len) : (i += decimate) {
        try appendFmt(alloc, &csv, "{d},{d:.12},{d:.12},{d:.12},{d:.6},{d:.6},{d:.1}\n", .{
            i,
            @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_rate)),
            out[i],
            env[i],
            cutoff[i],
            note_track[i],
            gate_track[i],
        });
    }
    try writeFile(alloc, lanes_path, csv.items);
}

fn writeSawArtifacts(
    alloc: std.mem.Allocator,
    cli: Cli,
    host: *FyHost,
    out: []const f64,
    expected: []const f64,
    naive: []const f64,
    metrics: Metrics,
    sample_rate: u32,
    pulse_width: f64,
) !void {
    const wav_samples = @as(usize, sample_rate) * OSC_LISTEN_SECONDS;
    const metrics_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(metrics_path);
    const disasm_path = try std.fmt.allocPrint(alloc, "{s}_disasm.txt", .{cli.out_prefix});
    defer alloc.free(disasm_path);
    const lanes_path = try std.fmt.allocPrint(alloc, "{s}_lanes.csv", .{cli.out_prefix});
    defer alloc.free(lanes_path);
    const wav_path = try std.fmt.allocPrint(alloc, "{s}.wav", .{cli.out_prefix});
    defer alloc.free(wav_path);

    const report = if (host.fy.isDsp2Word(cli.word))
        try host.fy.reportDsp2RawWord(cli.word)
    else
        host.fy.reportWord(cli.word) orelse return error.MissingReport;
    const metrics_json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "kernel": "{s}",
        \\  "word": "{s}",
        \\  "case": "{s}",
        \\  "samples": {d},
        \\  "sample_rate": {d},
        \\  "wav_path": "{s}",
        \\  "wav_samples": {d},
        \\  "wav_seconds": {d:.6},
        \\  "wav_sweep_start_hz": {d:.6},
        \\  "wav_sweep_end_hz": {d:.6},
        \\  "fundamental_hz": {d:.6},
        \\  "iterations": {d},
        \\  "ns_per_iter": {d:.6},
        \\  "max_abs_error": {d:.12},
        \\  "nonfinite_count": {d},
        \\  "rms": {d:.12},
        \\  "peak": {d:.12},
        \\  "mean": {d:.12},
        \\  "final_phase": {d:.12},
        \\  "alias_residual_db": {d:.6},
        \\  "naive_alias_residual_db": {d:.6},
        \\  "instruction_count": {d},
        \\  "push_count": {d},
        \\  "pop_count": {d},
        \\  "float_alu_count": {d},
        \\  "neon_float_alu_count": {d},
        \\  "neon_load_count": {d},
        \\  "neon_store_count": {d}
        \\}}
        \\
    , .{
        cli.kernel,
        cli.word,
        cli.case_name,
        out.len,
        sample_rate,
        wav_path,
        wav_samples,
        @as(f64, @floatFromInt(wav_samples)) / @as(f64, @floatFromInt(sample_rate)),
        OSC_SWEEP_START_HZ,
        OSC_SWEEP_END_HZ,
        metrics.fundamental_hz,
        cli.iterations,
        metrics.ns_per_iter,
        metrics.max_abs_error,
        metrics.nonfinite_count,
        metrics.rms,
        metrics.peak,
        metrics.mean,
        metrics.final_phase,
        metrics.alias_residual_db,
        metrics.naive_alias_residual_db,
        report.instruction_count,
        report.push_count,
        report.pop_count,
        report.float_alu_count,
        report.neon_float_alu_count,
        report.neon_load_count,
        report.neon_store_count,
    });
    defer alloc.free(metrics_json);
    try writeFile(alloc, metrics_path, metrics_json);
    try writeWav16OscSweep(alloc, wav_path, cli.case_name, wav_samples, sample_rate, pulse_width);

    const disasm = if (host.fy.isDsp2Word(cli.word))
        try host.fy.disassembleDsp2RawWordAlloc(alloc, cli.word)
    else
        try host.fy.disassembleWordAlloc(alloc, cli.word);
    defer alloc.free(disasm);
    try writeFile(alloc, disasm_path, disasm);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,out,expected,naive,error\n");
    for (out, expected, naive, 0..) |actual, exp, dry, i| {
        try appendFmt(alloc, &csv, "{d},{d:.12},{d:.12},{d:.12},{d:.12}\n", .{
            i,
            actual,
            exp,
            dry,
            actual - exp,
        });
    }
    try writeFile(alloc, lanes_path, csv.items);
}

fn appendFmt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

fn ensureScratch() !void {
    const rc = mkdir("scratch", 0o755);
    if (rc != 0 and std.c._errno().* != 17) return error.MkdirFailed;
}

fn writeWav16OscSweep(
    alloc: std.mem.Allocator,
    path: []const u8,
    case_name: []const u8,
    frames: usize,
    sample_rate: u32,
    pulse_width: f64,
) !void {
    const data_bytes: u32 = @intCast(frames * 2 * 2);
    const total_bytes: usize = 44 + data_bytes;
    const buf = try alloc.alloc(u8, total_bytes);
    defer alloc.free(buf);
    @memset(buf, 0);

    @memcpy(buf[0..4], "RIFF");
    putU32(buf[4..8], 36 + data_bytes);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    putU32(buf[16..20], 16);
    putU16(buf[20..22], 1);
    putU16(buf[22..24], 2);
    putU32(buf[24..28], sample_rate);
    putU32(buf[28..32], sample_rate * 2 * 2);
    putU16(buf[32..34], 4);
    putU16(buf[34..36], 16);
    @memcpy(buf[36..40], "data");
    putU32(buf[40..44], data_bytes);

    var off: usize = 44;
    var phase: f64 = 0.0;
    const sr_f: f64 = @floatFromInt(sample_rate);
    const sweep_ratio = OSC_SWEEP_END_HZ / OSC_SWEEP_START_HZ;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const pos = if (frames > 1)
            @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(frames - 1))
        else
            0.0;
        const freq = OSC_SWEEP_START_HZ * @exp(@log(sweep_ratio) * pos);
        const dt = freq / sr_f;
        const sample = oscillatorExpected(case_name, phase, dt, pulse_width);
        const pcm = sampleToI16(sample);
        putI16(buf[off..][0..2], pcm);
        putI16(buf[off + 2 ..][0..2], pcm);
        off += 4;
        phase = wrap01(phase + dt);
    }
    try writeFile(alloc, path, buf);
}

fn writeWav16StereoBuffer(
    alloc: std.mem.Allocator,
    path: []const u8,
    samples: []const f64,
    sample_rate: u32,
) !void {
    const data_bytes: u32 = @intCast(samples.len * 2 * 2);
    const total_bytes: usize = 44 + data_bytes;
    const buf = try alloc.alloc(u8, total_bytes);
    defer alloc.free(buf);
    @memset(buf, 0);

    @memcpy(buf[0..4], "RIFF");
    putU32(buf[4..8], 36 + data_bytes);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    putU32(buf[16..20], 16);
    putU16(buf[20..22], 1);
    putU16(buf[22..24], 2);
    putU32(buf[24..28], sample_rate);
    putU32(buf[28..32], sample_rate * 2 * 2);
    putU16(buf[32..34], 4);
    putU16(buf[34..36], 16);
    @memcpy(buf[36..40], "data");
    putU32(buf[40..44], data_bytes);

    var off: usize = 44;
    for (samples) |sample| {
        const pcm = sampleToI16(sample);
        putI16(buf[off..][0..2], pcm);
        putI16(buf[off + 2 ..][0..2], pcm);
        off += 4;
    }
    try writeFile(alloc, path, buf);
}

fn sampleToI16(v: f64) i16 {
    const clipped = std.math.clamp(v, -1.0, 1.0);
    return @intFromFloat(clipped * 32767.0);
}

fn putU16(dst: []u8, v: u16) void {
    dst[0] = @intCast(v & 0xff);
    dst[1] = @intCast((v >> 8) & 0xff);
}

fn putI16(dst: []u8, v: i16) void {
    putU16(dst, @bitCast(v));
}

fn putU32(dst: []u8, v: u32) void {
    dst[0] = @intCast(v & 0xff);
    dst[1] = @intCast((v >> 8) & 0xff);
    dst[2] = @intCast((v >> 16) & 0xff);
    dst[3] = @intCast((v >> 24) & 0xff);
}

fn writeFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const fd = open(z, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = close(fd);
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data[done..].ptr, data.len - done);
        if (n <= 0) return error.WriteFailed;
        done += @intCast(n);
    }
}

fn nowNs() u64 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @intCast(@divTrunc(
        @as(u128, @intCast(std.c.mach_absolute_time())) * @as(u128, @intCast(info.numer)),
        @as(u128, @intCast(info.denom)),
    ));
}

// ── Drum kernel cases (kernels/05-drums, docs/16) ─────────────────────

const DRUM_SAMPLE_RATE: u32 = 48_000;
const LN_1000: f64 = 6.907755278982137;

fn isDrumCase(name: []const u8) bool {
    return std.mem.eql(u8, name, "sine-shape-render") or
        std.mem.eql(u8, name, "decay-exp-render") or
        drumVoiceCase(name) != null;
}

fn runDrumCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    if (std.mem.eql(u8, cli.case_name, "sine-shape-render")) return runSineShapeCase(alloc, cli, host);
    if (std.mem.eql(u8, cli.case_name, "decay-exp-render")) return runDecayExpCase(alloc, cli, host);
    return runDrumVoiceCase(alloc, cli, host, drumVoiceCase(cli.case_name).?);
}

// Phase grid over [0,2) (exercises the frac wrap) against libm sine.
fn runSineShapeCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sample_count: usize = 4096;
    const xs = try alloc.alloc(f64, sample_count);
    defer alloc.free(xs);
    const out = try alloc.alloc(f64, sample_count);
    defer alloc.free(out);
    const expected = try alloc.alloc(f64, sample_count);
    defer alloc.free(expected);

    for (xs, expected, out, 0..) |*x, *exp, *dst, i| {
        x.* = 2.0 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_count));
        exp.* = @sin(2.0 * std.math.pi * x.*);
        dst.* = 0;
    }

    var perf_out: f64 = 0;
    const perf_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&perf_out) },
        .{ .f64 = 0.337 },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, @min(cli.iterations, 1_000), &perf_args);
    const start = nowNs();
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, cli.iterations, &perf_args);
    const run_ns = nowNs() - start;

    for (xs, out) |x, *dst| {
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(dst) },
            .{ .f64 = x },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &args);
    }

    var metrics = computeSliceMetrics(out, expected, run_ns, cli.iterations);
    fillSignalMetrics(out, &metrics);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,phase,out,expected,error\n");
    for (xs, out, expected, 0..) |x, actual, exp, i| {
        try appendFmt(alloc, &csv, "{d},{d:.12},{d:.12},{d:.12},{d:.12}\n", .{ i, x, actual, exp, actual - exp });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, null);
    if (metrics.nonfinite_count != 0 or metrics.max_abs_error > 0.00001) return error.KernelRatchetFailed;

    std.debug.print(
        "kernel {s}:{s} case={s} samples={} ns_per_iter={d:.3} max_abs_error={d:.12}\n",
        .{ cli.kernel, cli.word, cli.case_name, sample_count, metrics.ns_per_iter, metrics.max_abs_error },
    );
}

// Two ratchets: the series coefficient against libm exp over a log sweep of
// decay times, and a 0.5 s decay trace against pow(coeff, n).
fn runDecayExpCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);

    const grid: usize = 257;
    var coeff_out: f64 = 0;
    var max_coeff_err: f64 = 0;
    var gi: usize = 0;
    while (gi < grid) : (gi += 1) {
        const u = @as(f64, @floatFromInt(gi)) / @as(f64, @floatFromInt(grid - 1));
        const t = 0.0005 * std.math.pow(f64, 10_000.0, u); // 0.5 ms .. 5 s
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&coeff_out) },
            .{ .f64 = t },
            .{ .f64 = sr },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("k-decay-exp-coeff", 1, &args);
        const expected_c = @exp(-LN_1000 / (std.math.clamp(t, 0.0005, 10.0) * sr));
        if (!std.math.isFinite(coeff_out)) return error.KernelRatchetFailed;
        max_coeff_err = @max(max_coeff_err, @abs(coeff_out - expected_c));
    }

    const frames: usize = DRUM_SAMPLE_RATE / 2;
    const tau: f64 = 0.3;
    const coeff = @exp(-LN_1000 / (tau * sr));
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    const expected = try alloc.alloc(f64, frames);
    defer alloc.free(expected);
    var env: f64 = 1.0;

    const start = nowNs();
    for (out, expected, 0..) |*dst, *exp, i| {
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(dst) },
            .{ .ptr = @intFromPtr(&env) },
            .{ .f64 = coeff },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &args);
        exp.* = std.math.pow(f64, coeff, @as(f64, @floatFromInt(i + 1)));
    }
    const run_ns = nowNs() - start;

    var metrics = computeSliceMetrics(out, expected, run_ns, frames);
    fillSignalMetrics(out, &metrics);
    const trace_err = metrics.max_abs_error;
    metrics.max_abs_error = @max(max_coeff_err, trace_err);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,out,expected,error\n");
    for (out, expected, 0..) |actual, exp, i| {
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.12},{d:.12},{d:.12}\n", .{
            i,
            @as(f64, @floatFromInt(i)) / sr,
            actual,
            exp,
            actual - exp,
        });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, null);
    if (metrics.nonfinite_count != 0 or max_coeff_err > 0.000002 or trace_err > 0.000000001) {
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} coeff_err={d:.12} trace_err={d:.12}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, max_coeff_err, trace_err },
    );
}

// One config per drum voice: state/params cell counts mirror the voice's
// ustructs (user-facing params first, derived zeros after — the prepare
// word fills those), plus a default param set that matches the manifest.
const DrumVoiceConfig = struct {
    prepare_word: []const u8,
    trigger_word: []const u8,
    state_f64s: usize,
    param_defaults: []const f64,
    params_f64s: usize,
};

fn drumVoiceCase(name: []const u8) ?DrumVoiceConfig {
    if (std.mem.eql(u8, name, "drum-kick-render")) return .{
        .prepare_word = "kick-prepare",
        .trigger_word = "kick-trigger",
        .state_f64s = 7,
        // tune sweep bend decay click drive level
        .param_defaults = &.{ 50.0, 7.0, 0.055, 0.42, 0.35, 1.8, 0.9 },
        .params_f64s = 11,
    };
    if (std.mem.eql(u8, name, "drum-snare-render")) return .{
        .prepare_word = "snare-prepare",
        .trigger_word = "snare-trigger",
        .state_f64s = 10,
        // tune body-decay snap-level snap-decay snap-hz level
        .param_defaults = &.{ 185.0, 0.18, 0.8, 0.10, 1800.0, 0.9 },
        .params_f64s = 11,
    };
    if (std.mem.eql(u8, name, "drum-clap-render")) return .{
        .prepare_word = "clap-prepare",
        .trigger_word = "clap-trigger",
        .state_f64s = 7,
        // tone-hz spread-s decay-s level
        .param_defaults = &.{ 1100.0, 0.011, 0.28, 0.9 },
        .params_f64s = 9,
    };
    if (std.mem.eql(u8, name, "drum-hat-render")) return .{
        .prepare_word = "hat-prepare",
        .trigger_word = "hat-ch-trigger",
        .state_f64s = 15,
        // tune tone ch-decay oh-decay level
        .param_defaults = &.{ 1.0, 1.0, 0.07, 0.6, 0.85 },
        .params_f64s = 15,
    };
    if (std.mem.eql(u8, name, "drum-openhat-render")) return .{
        .prepare_word = "hat-prepare",
        .trigger_word = "hat-oh-trigger",
        .state_f64s = 15,
        .param_defaults = &.{ 1.0, 1.0, 0.07, 0.6, 0.85 },
        .params_f64s = 15,
    };
    return null;
}

const MAX_DRUM_CELLS = 32;

// Three hits at different velocities; audition WAV + lane CSV + stat ratchet.
fn runDrumVoiceCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost, cfg: DrumVoiceConfig) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const frames: usize = 2 * DRUM_SAMPLE_RATE;
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);

    var state align(8) = [_]f64{0} ** MAX_DRUM_CELLS;
    var params align(8) = [_]f64{0} ** MAX_DRUM_CELLS;
    if (cfg.state_f64s > MAX_DRUM_CELLS or cfg.params_f64s > MAX_DRUM_CELLS) return error.InvalidCase;
    @memcpy(params[0..cfg.param_defaults.len], cfg.param_defaults);

    const prep_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .f64 = sr },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cfg.prepare_word, 1, &prep_args);

    const Hit = struct { frame: usize, velocity: f64 };
    const hits = [_]Hit{
        .{ .frame = 0, .velocity = 1.0 },
        .{ .frame = @intFromFloat(0.7 * sr), .velocity = 0.6 },
        .{ .frame = @intFromFloat(1.4 * sr), .velocity = 1.0 },
    };

    // Staged voices are `call:` compositions and need the composition caller.
    var comp_slots = Fy.Dsp2RawRepeatedSlots{};
    var comp_caller: ?Fy.Dsp2RawRepeatedCaller = null;
    if (host.fy.isCompositionWord(cli.word)) {
        comp_caller = try host.fy.compileDsp2CompositionCaller(cli.word, &comp_slots, true, false);
    }

    const start = nowNs();
    var cursor: usize = 0;
    var hit_index: usize = 0;
    while (cursor < frames) {
        while (hit_index < hits.len and hits[hit_index].frame == cursor) : (hit_index += 1) {
            const trig_args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&state) },
                .{ .ptr = @intFromPtr(&params) },
                .{ .f64 = 1.0 },
                .{ .f64 = hits[hit_index].velocity },
            };
            _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cfg.trigger_word, 1, &trig_args);
        }
        const next = if (hit_index < hits.len) @min(hits[hit_index].frame, frames) else frames;
        const count = next - cursor;
        if (count > 0) {
            const args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&out[cursor]) },
                .{ .ptr = @intFromPtr(&state) },
                .{ .ptr = @intFromPtr(&params) },
            };
            if (comp_caller) |*cc| {
                _ = try cc.call(@intCast(count), &args);
            } else {
                _ = try host.fy.callDsp2RawRepeatedWithAutoOutNoResult(cli.word, @intCast(count), &args);
            }
            cursor = next;
        }
    }
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,out\n");
    for (out, 0..) |x, i| {
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.12}\n", .{ i, @as(f64, @floatFromInt(i)) / sr, x });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    if (metrics.nonfinite_count != 0 or metrics.peak < 0.2 or metrics.peak > 1.0 or @abs(metrics.mean) > 0.02) {
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} peak={d:.3} rms={d:.3} mean={d:.6}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, metrics.peak, metrics.rms, metrics.mean },
    );
}

// ── Effect kernel cases (kernels/07-effects) ──────────────────────────

// k-delay-tick against a sample-exact Zig mirror of the same algorithm:
// host-style ring injection (pointer + element count in state cells 0/1),
// impulse-train input, then echo-placement and decay ratchets.
fn runDelayCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const frames: usize = 2 * DRUM_SAMPLE_RATE;
    const ring_len: usize = 65536;

    const ring = try alloc.alloc(f64, ring_len);
    defer alloc.free(ring);
    @memset(ring, 0);
    const ref_ring = try alloc.alloc(f64, ring_len);
    defer alloc.free(ref_ring);
    @memset(ref_ring, 0);

    const input = try alloc.alloc(f64, frames);
    defer alloc.free(input);
    @memset(input, 0);
    input[0] = 0.9;
    input[DRUM_SAMPLE_RATE] = 0.9;
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);

    // State mirrors DelayState; the ring is injected the way the host does
    // it — pointer bits in cell 0, element count (f64) in cell 1.
    var state align(8) = [_]f64{0} ** 8;
    @as(*usize, @ptrCast(&state[0])).* = @intFromPtr(ring.ptr);
    state[1] = @floatFromInt(ring_len);

    // DelayParams: time-s feedback mix damp-hz, derived filled by prepare.
    var params align(8) = [_]f64{ 0.25, 0.5, 0.5, 4000.0, 0, 0 };
    const prep_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&params) },
        .{ .f64 = sr },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("delay-block-prepare", 1, &prep_args);

    // Same caller shape the machine adapter uses: out and in auto-advance.
    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2RawRepeatedCaller(
        cli.word,
        &slots,
        &.{ .ptr, .ptr, .ptr, .ptr },
        true,
        true,
    );
    const render_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&input[0]) },
    };
    const start = nowNs();
    _ = try caller.call(@intCast(frames), &render_args);
    const run_ns = nowNs() - start;

    // Zig mirror, op-for-op.
    const expected = try alloc.alloc(f64, frames);
    defer alloc.free(expected);
    {
        const len: f64 = @floatFromInt(ring_len);
        const dt_target = std.math.clamp(params[4], 2.0, len - 4.0);
        const damp_a = params[5];
        var tz: f64 = 0;
        var w: f64 = 0;
        var dz: f64 = 0;
        for (input, expected) |x, *exp| {
            tz += (dt_target - tz) * 0.0008;
            const rp0 = w - tz;
            const rp = if (rp0 < 0) rp0 + len else rp0;
            const idx0: usize = @intFromFloat(rp);
            const rp1 = rp + 1.0;
            const rpw = if (rp1 < len) rp1 else rp1 - len;
            const idx1: usize = @intFromFloat(rpw);
            const s0 = ref_ring[idx0];
            const rd = s0 + (ref_ring[idx1] - s0) * (rp - @floor(rp));
            dz += (rd - dz) * damp_a;
            ref_ring[@intFromFloat(w)] = x + dz * params[1];
            const w1 = w + 1.0;
            w = if (w1 < len) w1 else w1 - len;
            exp.* = x * (1.0 - params[2]) + rd * params[2];
        }
    }

    var metrics = computeSliceMetrics(out, expected, run_ns, frames);
    fillSignalMetrics(out, &metrics);

    // Echo placement: first echo of the t=0 impulse lands a wet tap near
    // 0.25 s (the slewed delay converges from 0, so allow a window) and a
    // quieter feedback repeat follows.
    var first_echo: f64 = 0;
    for (out[1000 .. DRUM_SAMPLE_RATE / 2]) |x| first_echo = @max(first_echo, @abs(x));
    var second_echo: f64 = 0;
    for (out[DRUM_SAMPLE_RATE / 2 .. DRUM_SAMPLE_RATE - 100]) |x| second_echo = @max(second_echo, @abs(x));

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,in,out,expected,error\n");
    for (input, out, expected, 0..) |x, actual, exp, i| {
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.6},{d:.12},{d:.12},{d:.12}\n", .{
            i, @as(f64, @floatFromInt(i)) / sr, x, actual, exp, actual - exp,
        });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    if (metrics.nonfinite_count != 0 or metrics.max_abs_error > 0.000000001 or
        first_echo < 0.2 or second_echo < 0.05 or second_echo > first_echo)
    {
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} max_abs_error={d:.12} echo1={d:.3} echo2={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, metrics.max_abs_error, first_echo, second_echo },
    );
}

// log2-approx / exp2-approx against libm over their full stated domains.
fn runPow2Case(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const is_log = std.mem.eql(u8, cli.case_name, "log2-sweep");
    const sample_count: usize = 8192;
    const xs = try alloc.alloc(f64, sample_count);
    defer alloc.free(xs);
    const out = try alloc.alloc(f64, sample_count);
    defer alloc.free(out);
    const expected = try alloc.alloc(f64, sample_count);
    defer alloc.free(expected);

    for (xs, expected, out, 0..) |*x, *exp, *dst, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_count - 1));
        if (is_log) {
            // log sweep of x across [2^-24, 2^24]
            x.* = std.math.pow(f64, 2.0, -24.0 + 48.0 * t);
            exp.* = std.math.log2(x.*);
        } else {
            x.* = -32.0 + 64.0 * t;
            exp.* = std.math.pow(f64, 2.0, x.*);
        }
        dst.* = 0;
    }

    const start = nowNs();
    for (xs, out) |x, *dst| {
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(dst) },
            .{ .f64 = x },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cli.word, 1, &args);
    }
    const run_ns = nowNs() - start;

    // exp2 spans ~19 orders of magnitude — ratchet relative error there,
    // absolute error for log2.
    var max_err: f64 = 0;
    var nonfinite: usize = 0;
    for (out, expected) |actual, exp| {
        if (!std.math.isFinite(actual)) nonfinite += 1;
        const err = if (is_log) @abs(actual - exp) else @abs(actual - exp) / @max(@abs(exp), 1e-30);
        max_err = @max(max_err, err);
    }

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(sample_count));
    metrics.max_abs_error = max_err;
    metrics.nonfinite_count = @intCast(nonfinite);
    fillSignalMetrics(out, &metrics);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,x,out,expected,error\n");
    for (xs, out, expected, 0..) |x, actual, exp, i| {
        try appendFmt(alloc, &csv, "{d},{d:.12},{d:.12},{d:.12},{d:.12}\n", .{ i, x, actual, exp, actual - exp });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, null);
    if (nonfinite != 0 or max_err > 0.00001) return error.KernelRatchetFailed;

    std.debug.print(
        "kernel {s}:{s} case={s} samples={} ns_per_iter={d:.3} max_err={d:.12}\n",
        .{ cli.kernel, cli.word, cli.case_name, sample_count, metrics.ns_per_iter, max_err },
    );
}

// k-sampler-voice: load the bundled 220 Hz pluck via the asset arena and
// play it at root (220) and an octave up (440); ratchet that the rendered
// fundamental matches the played note (resampling pitch is correct), that
// looping sustains where a one-shot would have ended, and finiteness.
fn runSamplerCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);

    // Load the asset the same way the host does (the rig has no FyRawMachine).
    var sample = wav.load(alloc, "machines/sampler/assets/default.wav") catch {
        std.debug.print("sampler: could not load bundled asset\n", .{});
        return error.KernelRatchetFailed;
    };
    defer sample.deinit(alloc);

    const frames: usize = DRUM_SAMPLE_RATE; // 1 s
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);

    // SamplerParams field order mirrors the ustruct (3 asset + user + derived).
    const P = struct {
        const smp_ptr = 0;
        const smp_len = 1;
        const smp_sr = 2;
        const tune = 3;
        const root_hz = 4;
        const start = 5;
        const loop_on = 6;
        const loop_start = 7;
        const loop_end = 8;
        const atk = 9;
        const dec = 10;
        const sus = 11;
        const rel = 12;
        const level = 13;
    };

    const detect = struct {
        // Strongest 12-TET note in 110..900 Hz via Goertzel, returned in Hz.
        fn pitch(seg: []const f64, srate: f64) f64 {
            var best_mag: f64 = 0;
            var best_f: f64 = 0;
            var midi: f64 = 45; // A2
            while (midi <= 81) : (midi += 1) {
                const f = 440.0 * std.math.pow(f64, 2.0, (midi - 69.0) / 12.0);
                const m = goertzelMag(seg, f, srate);
                if (m > best_mag) {
                    best_mag = m;
                    best_f = f;
                }
            }
            return best_f;
        }
    };

    const renderNote = struct {
        fn go(h: *FyHost, smp: wav.Sample, note_hz: f64, loop: f64, dec: f64, rel: f64, o: []f64, srate: f64) !void {
            @memset(o, 0);
            var state align(8) = [_]f64{0} ** 8;
            var params align(8) = [_]f64{0} ** 24;
            params[P.smp_ptr] = @bitCast(@intFromPtr(smp.data.ptr));
            params[P.smp_len] = @floatFromInt(smp.data.len);
            params[P.smp_sr] = smp.sample_rate;
            params[P.root_hz] = 220.0;
            params[P.loop_on] = loop;
            params[P.loop_end] = 1.0;
            params[P.atk] = 0.002;
            params[P.dec] = dec;
            params[P.sus] = 1.0;
            params[P.rel] = rel;
            params[P.level] = 0.9;
            const bp = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = srate } };
            _ = try h.fy.callDsp2RawRepeatedWithArgsNoResult("sampler-block-prepare", 1, &bp);
            const on = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&state) }, .{ .ptr = @intFromPtr(&params) },
                .{ .f64 = note_hz }, .{ .f64 = 0.9 },
            };
            _ = try h.fy.callDsp2RawRepeatedWithArgsNoResult("sampler-note-on", 1, &on);
            var slots = Fy.Dsp2RawRepeatedSlots{};
            var caller = try h.fy.compileDsp2CompositionCaller("k-sampler-voice", &slots, true, false);
            const args = [_]Fy.Dsp2RawArg{
                .{ .ptr = @intFromPtr(&o[0]) }, .{ .ptr = @intFromPtr(&state) }, .{ .ptr = @intFromPtr(&params) },
            };
            _ = try caller.call(@intCast(o.len), &args);
        }
    };

    // Root note (220): rendered pitch must be 220.
    const start = nowNs();
    try renderNote.go(host, sample, 220.0, 0.0, 0.6, 0.3, out, sr);
    const run_ns = nowNs() - start;
    const pitch_root = detect.pitch(out[2000..18386], sr);

    // Octave up (440): resampled faster, rendered pitch must be 440.
    try renderNote.go(host, sample, 440.0, 0.0, 0.6, 0.3, out, sr);
    const pitch_oct = detect.pitch(out[2000..18386], sr);

    // One-shot vs loop: the bundled pluck decays to near silence by ~0.9 s;
    // looping the first 60 ms keeps it ringing at the tail.
    try renderNote.go(host, sample, 220.0, 0.0, 5.0, 5.0, out, sr); // long env, one-shot
    var oneshot_tail: f64 = 0;
    for (out[frames - 4000 ..]) |x| oneshot_tail += x * x;
    var params_loop align(8) = [_]f64{0} ** 24;
    _ = &params_loop;
    var loop_state align(8) = [_]f64{0} ** 8;
    {
        // loop the first 60 ms with a long sustain
        @memset(out, 0);
        params_loop[P.smp_ptr] = @bitCast(@intFromPtr(sample.data.ptr));
        params_loop[P.smp_len] = @floatFromInt(sample.data.len);
        params_loop[P.smp_sr] = sample.sample_rate;
        params_loop[P.root_hz] = 220.0;
        params_loop[P.loop_on] = 1.0;
        params_loop[P.loop_start] = 0.0;
        params_loop[P.loop_end] = 60.0 * sample.sample_rate / 1000.0 / @as(f64, @floatFromInt(sample.data.len));
        params_loop[P.atk] = 0.002;
        params_loop[P.dec] = 5.0;
        params_loop[P.sus] = 1.0;
        params_loop[P.rel] = 5.0;
        params_loop[P.level] = 0.9;
        const bp = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params_loop) }, .{ .f64 = sr } };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("sampler-block-prepare", 1, &bp);
        const on = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&loop_state) }, .{ .ptr = @intFromPtr(&params_loop) },
            .{ .f64 = 220.0 }, .{ .f64 = 0.9 },
        };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("sampler-note-on", 1, &on);
        var slots = Fy.Dsp2RawRepeatedSlots{};
        var caller = try host.fy.compileDsp2CompositionCaller("k-sampler-voice", &slots, true, false);
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out[0]) }, .{ .ptr = @intFromPtr(&loop_state) }, .{ .ptr = @intFromPtr(&params_loop) },
        };
        _ = try caller.call(@intCast(out.len), &args);
    }
    var loop_tail: f64 = 0;
    for (out[frames - 4000 ..]) |x| loop_tail += x * x;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,loop_out\n");
    var j: usize = 0;
    while (j < frames) : (j += 16) {
        try appendFmt(alloc, &csv, "{d},{d:.6},{d:.9}\n", .{ j, @as(f64, @floatFromInt(j)) / sr, out[j] });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    const root_err = @abs(pitch_root - 220.0) / 220.0;
    const oct_err = @abs(pitch_oct - 440.0) / 440.0;
    if (metrics.nonfinite_count != 0 or root_err > 0.02 or oct_err > 0.02 or
        loop_tail < oneshot_tail * 4.0)
    {
        std.debug.print("sampler ratchet detail: pitch_root={d:.1} pitch_oct={d:.1} oneshot_tail={d:.6} loop_tail={d:.6}\n", .{ pitch_root, pitch_oct, oneshot_tail, loop_tail });
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} pitch_root={d:.1}Hz pitch_oct={d:.1}Hz loop/oneshot_tail={d:.1}x\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, pitch_root, pitch_oct, loop_tail / @max(oneshot_tail, 1e-12) },
    );
}

// k-funk-tick: a pluck train (sharp attacks, decaying tails) through the
// FUNK OVERLOAD macro at two settings. At funk=0.5 the filter must open
// on each attack (brightness, via zero-crossing rate, rises right after
// onset). At funk=0.92 the gate must chop the gaps far deeper than at
// 0.5 (gap RMS relative to peak RMS collapses). One render helper, two
// passes off fresh state.
const FunkPass = struct {
    bright_early: f64, // 7th-harmonic / fundamental just after attack
    bright_late: f64, // ditto in the decayed tail
    gate_depth: f64, // gap RMS / peak RMS
    peak: f64,
    nonfinite: usize,
};

fn funkRenderPass(
    host: *FyHost,
    funk: f64,
    input: []const f64,
    out: []f64,
    sr: f64,
    spacing: usize,
) !FunkPass {
    var state align(8) = [_]f64{0} ** 8;
    var params align(8) = [_]f64{ funk, 420.0, 0.08, 1.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const bp = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = sr } };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("funk-block-prepare", 1, &bp);

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2CompositionCaller("k-funk-tick", &slots, true, true);
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&input[0]) },
    };
    _ = try caller.call(@intCast(out.len), &args);

    var p = FunkPass{ .bright_early = 0, .bright_late = 0, .gate_depth = 0, .peak = 0, .nonfinite = 0 };
    for (out) |x| {
        if (!std.math.isFinite(x)) p.nonfinite += 1;
        p.peak = @max(p.peak, @abs(x));
    }

    // Per-pluck windows: early (just after attack, filter open) and late
    // (decayed tail, filter closed). Brightness = 7th-harmonic / fundamental
    // (normalizes out the pluck's amplitude decay); level = RMS for the gate.
    const f0 = 220.0;
    const f7 = 220.0 * 7.0; // 1540 Hz — only passes when the filter is open
    var be: f64 = 0;
    var bl: f64 = 0;
    var peak_sq: f64 = 0;
    var gap_sq: f64 = 0;
    var nwin: f64 = 0;
    var a: usize = spacing; // skip the first onset transient
    while (a + spacing <= out.len) : (a += spacing) {
        const early = out[a + 50 .. a + 2050];
        const late = out[a + 8000 .. a + 10000];
        be += goertzelMag(early, f7, sr) / @max(goertzelMag(early, f0, sr), 1e-9);
        bl += goertzelMag(late, f7, sr) / @max(goertzelMag(late, f0, sr), 1e-9);
        for (out[a + 50 .. a + 1500]) |x| peak_sq += x * x;
        for (out[a + 8000 .. a + 11500]) |x| gap_sq += x * x;
        nwin += 1;
    }
    p.bright_early = be / nwin;
    p.bright_late = bl / nwin;
    const peak_rms = @sqrt(peak_sq / (nwin * 1450));
    const gap_rms = @sqrt(gap_sq / (nwin * 3500));
    p.gate_depth = gap_rms / @max(peak_rms, 1e-12);
    return p;
}

fn runFunkCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const frames: usize = 4 * DRUM_SAMPLE_RATE;
    const spacing: usize = DRUM_SAMPLE_RATE / 4; // 4 plucks/sec

    const input = try alloc.alloc(f64, frames);
    defer alloc.free(input);
    @memset(input, 0);
    var a: usize = 0;
    while (a < frames) : (a += spacing) {
        var i: usize = 0;
        while (i < spacing and a + i < frames) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / sr;
            const env = @exp(-t / 0.12); // plucked decay
            // Harmonic-rich pluck (band-limited saw, 12 partials) so the
            // filter sweep actually changes the spectrum / crossing rate.
            var s: f64 = 0;
            var h: usize = 1;
            while (h <= 12) : (h += 1) {
                s += @sin(2.0 * std.math.pi * 220.0 * @as(f64, @floatFromInt(h)) * t) / @as(f64, @floatFromInt(h));
            }
            input[a + i] = 0.45 * env * s;
        }
    }

    const out_lo = try alloc.alloc(f64, frames);
    defer alloc.free(out_lo);
    const out_hi = try alloc.alloc(f64, frames);
    defer alloc.free(out_hi);
    @memset(out_lo, 0);
    @memset(out_hi, 0);

    const start = nowNs();
    const lo = try funkRenderPass(host, 0.5, input, out_lo, sr, spacing);
    const hi = try funkRenderPass(host, 0.92, input, out_hi, sr, spacing);
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(2 * frames));
    fillSignalMetrics(out_hi, &metrics);
    metrics.nonfinite_count = @intCast(lo.nonfinite + hi.nonfinite);

    const wah_ratio = lo.bright_early / @max(lo.bright_late, 1e-9);
    const gate_tighten = hi.gate_depth / @max(lo.gate_depth, 1e-9);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,in,funk50,funk92\n");
    var j: usize = 0;
    while (j < frames) : (j += 16) {
        try appendFmt(alloc, &csv, "{d},{d:.6},{d:.6},{d:.6},{d:.6}\n", .{
            j, @as(f64, @floatFromInt(j)) / sr, input[j], out_lo[j], out_hi[j],
        });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out_hi);

    if (metrics.nonfinite_count != 0 or hi.peak > 1.0 or lo.peak > 1.0 or
        wah_ratio < 1.15 or gate_tighten > 0.6)
    {
        std.debug.print("funk ratchet detail: wah_ratio={d:.3} gate_tighten={d:.3} depth50={d:.4} depth92={d:.4} peak50={d:.3} peak92={d:.3}\n", .{ wah_ratio, gate_tighten, lo.gate_depth, hi.gate_depth, lo.peak, hi.peak });
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} wah_ratio={d:.2} gate_tighten={d:.2} depth50={d:.3} depth92={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, wah_ratio, gate_tighten, lo.gate_depth, hi.gate_depth },
    );
}

// k-juno-voice: one voice, A3 note for 1.5 s then release; ratchets
// finite output, sensible peak, audible sustain, and a decayed tail.
fn runJunoCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const frames: usize = 3 * DRUM_SAMPLE_RATE;
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);

    var state align(8) = [_]f64{0} ** 24;
    // JunoParams user defaults: lfo-rate vibrato range saw pulse pwm
    // pwm-mode sub noise detune hpf cutoff res env-amt lfo-vcf kybd
    // a d s r vca-mode level (+ derived). Pure saw (sub/noise off) so the
    // pitch-correlation ratchet has an unambiguous 220 Hz period.
    var params align(8) = [_]f64{
        1.5, 0.0,   1.0, 1.0, 0.0,  0.0, 0.0, 0.0, 0.0,  0.0,
        20.0, 1800.0, 0.15, 0.4, 0.0, 0.3, 0.01, 0.3, 0.6, 0.4,
        0.0, 0.8,
        0, 0, 0, 0, 0, 0,
    };

    const bp_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = sr } };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("juno-block-prepare", 1, &bp_args);
    const on_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .f64 = 220.0 },
        .{ .f64 = 0.9 },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("juno-note-on", 1, &on_args);

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2CompositionCaller(cli.word, &slots, true, false);
    const held: usize = 3 * DRUM_SAMPLE_RATE / 2;
    const args_a = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
    };
    const start = nowNs();
    _ = try caller.call(@intCast(held), &args_a);
    const off_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("juno-note-off", 1, &off_args);
    const args_b = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[held]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
    };
    _ = try caller.call(@intCast(frames - held), &args_b);
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    var sustain_rms: f64 = 0;
    for (out[DRUM_SAMPLE_RATE .. DRUM_SAMPLE_RATE + DRUM_SAMPLE_RATE / 4]) |x| sustain_rms += x * x;
    sustain_rms = @sqrt(sustain_rms / @as(f64, @floatFromInt(DRUM_SAMPLE_RATE / 4)));
    var tail_rms: f64 = 0;
    for (out[frames - DRUM_SAMPLE_RATE / 4 ..]) |x| tail_rms += x * x;
    tail_rms = @sqrt(tail_rms / @as(f64, @floatFromInt(DRUM_SAMPLE_RATE / 4)));

    // Pitch sanity: the sustain must be PERIODIC at the played note, not
    // noise — normalized autocorrelation at the 220 Hz lag. (Numeric
    // peak/RMS ratchets alone cannot tell a saw from noise.)
    var pitch_corr: f64 = -1;
    {
        const seg = out[DRUM_SAMPLE_RATE..][0..8192];
        var best: f64 = -1;
        var lag: usize = 210;
        while (lag <= 228) : (lag += 1) {
            var num: f64 = 0;
            var e0: f64 = 0;
            var e1: f64 = 0;
            for (seg[0 .. seg.len - lag], seg[lag..]) |a, b| {
                num += a * b;
                e0 += a * a;
                e1 += b * b;
            }
            const r = num / @max(@sqrt(e0 * e1), 1e-30);
            best = @max(best, r);
        }
        pitch_corr = best;
    }

    // Filter-ring sanity: with the default patch the effective cutoff sits
    // near 3.7 kHz; an under-damped 4-pole whistles there — and the whistle
    // can be harmonically locked, invisible to the pitch ratchet. The
    // strongest 3.2–4.4 kHz component must stay well under the fundamental.
    var ring_ratio: f64 = 0;
    {
        const seg = out[DRUM_SAMPLE_RATE..][0..4096];
        var fund: f64 = 0;
        var ring: f64 = 0;
        var f: f64 = 200.0;
        while (f <= 240.0) : (f += 5.0) fund = @max(fund, goertzelMag(seg, f, sr));
        f = 3200.0;
        while (f <= 4400.0) : (f += 40.0) ring = @max(ring, goertzelMag(seg, f, sr));
        ring_ratio = ring / @max(fund, 1e-12);
    }

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,out\n");
    var j: usize = 0;
    while (j < frames) : (j += 16) {
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.9}\n", .{ j, @as(f64, @floatFromInt(j)) / sr, out[j] });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    if (metrics.nonfinite_count != 0 or metrics.peak < 0.05 or metrics.peak > 1.0 or
        sustain_rms < 0.02 or tail_rms > sustain_rms * 0.02 or pitch_corr < 0.6 or
        ring_ratio > 0.25)
    {
        std.debug.print("juno ratchet detail: peak={d:.3} sustain_rms={d:.4} tail_rms={d:.6} pitch_corr={d:.3} ring_ratio={d:.3}\n", .{ metrics.peak, sustain_rms, tail_rms, pitch_corr, ring_ratio });
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} peak={d:.3} sustain_rms={d:.4} tail_rms={d:.6} pitch_corr={d:.3} ring_ratio={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, metrics.peak, sustain_rms, tail_rms, pitch_corr, ring_ratio },
    );
}

fn goertzelMag(seg: []const f64, freq: f64, sr: f64) f64 {
    var re: f64 = 0;
    var im: f64 = 0;
    const w = 2.0 * std.math.pi * freq / sr;
    for (seg, 0..) |s, i| {
        const a = w * @as(f64, @floatFromInt(i));
        re += s * @cos(a);
        im += s * @sin(a);
    }
    return 2.0 * @sqrt(re * re + im * im) / @as(f64, @floatFromInt(seg.len));
}

// k-chorus-tick in mode I, full wet, tone wide open: an impulse train
// recovers the modulated tap's delay per impulse; ratchet the trace
// against the Juno voicing (center 3.35 ms, depth ±1.8 ms, 0.513 Hz).
fn runChorusCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const frames: usize = 5 * DRUM_SAMPLE_RATE;
    const ring_len: usize = 1152;
    const spacing: usize = 1024;

    const ring = try alloc.alloc(f64, ring_len);
    defer alloc.free(ring);
    @memset(ring, 0);
    const input = try alloc.alloc(f64, frames);
    defer alloc.free(input);
    @memset(input, 0);
    var k: usize = 0;
    while (k < frames) : (k += spacing) input[k] = 1.0;
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);

    var state align(8) = [_]f64{0} ** 8;
    @as(*usize, @ptrCast(&state[0])).* = @intFromPtr(ring.ptr);
    state[1] = @floatFromInt(ring_len);
    state[2] = 0.0; // left channel

    // mode rate-mul depth-mul tone-hz spread mix + derived
    var params align(8) = [_]f64{ 0.0, 1.0, 1.0, 18000.0, 1.0, 1.0, 0, 0, 0, 0 };
    const bp_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = sr } };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("chorus-block-prepare", 1, &bp_args);

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2RawRepeatedCaller(
        cli.word,
        &slots,
        &.{ .ptr, .ptr, .ptr, .ptr },
        true,
        true,
    );
    const render_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&input[0]) },
    };
    const start = nowNs();
    _ = try caller.call(@intCast(frames), &render_args);
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    // Recover the delay per impulse: centroid of |out| within the window
    // after each impulse (the wet response is 1-2 interpolated taps).
    var delays = std.ArrayList(f64).empty;
    defer delays.deinit(alloc);
    k = 0;
    while (k + spacing <= frames) : (k += spacing) {
        var num: f64 = 0;
        var den: f64 = 0;
        for (out[k .. k + spacing], 0..) |y, off| {
            const a = @abs(y);
            num += a * @as(f64, @floatFromInt(off));
            den += a;
        }
        if (den > 0.01) try delays.append(alloc, num / den);
    }
    var d_min: f64 = 1e9;
    var d_max: f64 = -1e9;
    for (delays.items) |d| {
        d_min = @min(d_min, d);
        d_max = @max(d_max, d);
    }
    // LFO period from mean crossings of the delay trace.
    var crossings: usize = 0;
    const d_mid = (d_min + d_max) / 2.0;
    for (delays.items[1..], delays.items[0 .. delays.items.len - 1]) |b, a| {
        if ((a < d_mid) != (b < d_mid)) crossings += 1;
    }
    const trace_dur = @as(f64, @floatFromInt(delays.items.len * spacing)) / sr;
    const rate_hz = @as(f64, @floatFromInt(crossings)) / 2.0 / trace_dur;

    const center = 0.00335 * sr;
    const depth = 0.0018 * sr;

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "impulse,time,delay_samples\n");
    for (delays.items, 0..) |d, i| {
        try appendFmt(alloc, &csv, "{d},{d:.6},{d:.3}\n", .{ i, @as(f64, @floatFromInt(i * spacing)) / sr, d });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    if (metrics.nonfinite_count != 0 or
        @abs(d_min - (center - depth)) > 12.0 or
        @abs(d_max - (center + depth)) > 12.0 or
        @abs(rate_hz - 0.513) > 0.12)
    {
        std.debug.print("chorus ratchet detail: dmin={d:.1} dmax={d:.1} (want {d:.1}..{d:.1}) rate={d:.3}Hz\n", .{ d_min, d_max, center - depth, center + depth, rate_hz });
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} delay={d:.1}..{d:.1}spl rate={d:.3}Hz\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, d_min, d_max, rate_hz },
    );
}

// The Zig-side gain computer the kernel must match: soft-knee overshoot
// in log2 units times slope, all from the same constants.
fn compExpectedGainDb(level_db: f64, thresh_db: f64, ratio: f64, knee_db: f64) f64 {
    const l = (level_db - thresh_db) / 6.0205999132796239;
    const w = @max(knee_db / 6.0205999132796239, 1e-6);
    const half = w / 2.0;
    const over = if (l <= -half) 0.0 else if (l >= half) l else (l + half) * (l + half) / (2.0 * w);
    return over * (1.0 / ratio - 1.0) * 6.0205999132796239;
}

// k-comp-tick: 1 kHz bursts at stepped levels through the full staged
// compressor with a host-style detector trace. Ratchets the static curve
// against the reference gain computer and the attack/release timing.
fn runCompCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const burst_len: usize = DRUM_SAMPLE_RATE / 2;
    const levels_db = [_]f64{ -30.0, -18.0, -12.0, -6.0, 0.0 };
    const frames: usize = burst_len * levels_db.len;

    const thresh_db = -18.0;
    const ratio = 4.0;
    const knee_db = 6.0;
    const atk_s = 0.005;
    const rel_s = 0.120;

    const input = try alloc.alloc(f64, frames);
    defer alloc.free(input);
    const det = try alloc.alloc(f64, frames);
    defer alloc.free(det);
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);
    for (input, det, 0..) |*x, *d, i| {
        const level = std.math.pow(f64, 10.0, levels_db[i / burst_len] / 20.0);
        x.* = level * @sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / sr);
        d.* = @abs(x.*);
    }

    // CompState: detector pointer in cell 0, rest zero.
    var state align(8) = [_]f64{0} ** 16;
    @as(*usize, @ptrCast(&state[0])).* = @intFromPtr(det.ptr);
    // CompParams: thresh ratio knee atk rel makeup mix + derived.
    var params align(8) = [_]f64{0} ** 16;
    params[0] = thresh_db;
    params[1] = ratio;
    params[2] = knee_db;
    params[3] = atk_s;
    params[4] = rel_s;
    params[5] = 0.0; // makeup
    params[6] = 1.0; // full wet

    const bp_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = sr } };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("comp-block-prepare", 1, &bp_args);

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2CompositionCaller(cli.word, &slots, true, true);
    const render_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&input[0]) },
    };
    const start = nowNs();
    _ = try caller.call(@intCast(frames), &render_args);
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    // Static curve: steady-state gain over the last 100 ms of each burst.
    var max_curve_err_db: f64 = 0;
    for (levels_db, 0..) |ldb, bi| {
        const tail_start = (bi + 1) * burst_len - DRUM_SAMPLE_RATE / 10;
        const tail_end = (bi + 1) * burst_len;
        var in_e: f64 = 0;
        var out_e: f64 = 0;
        for (input[tail_start..tail_end], out[tail_start..tail_end]) |x, y| {
            in_e += x * x;
            out_e += y * y;
        }
        const meas_db = 10.0 * std.math.log10(@max(out_e, 1e-30) / @max(in_e, 1e-30));
        const exp_db = compExpectedGainDb(ldb, thresh_db, ratio, knee_db);
        max_curve_err_db = @max(max_curve_err_db, @abs(meas_db - exp_db));
    }

    // Timing: at the -30 -> -18 -> ... -6 dB step (burst 3 onset), gain
    // reduction should settle within a few attack times. Find when |out|
    // envelope first comes within 1 dB of its steady tail level.
    const onset = 3 * burst_len;
    var settle: usize = 0;
    {
        var tail_peak: f64 = 0;
        for (out[onset + burst_len - DRUM_SAMPLE_RATE / 10 .. onset + burst_len]) |y| tail_peak = @max(tail_peak, @abs(y));
        const hi = tail_peak * 1.122; // +1 dB
        var run: usize = 0;
        var k: usize = onset;
        var block_peak: f64 = 0;
        while (k < onset + burst_len) : (k += 1) {
            block_peak = @max(block_peak, @abs(out[k]));
            if ((k - onset) % 48 == 47) { // 1 ms windows
                if (block_peak <= hi) {
                    run += 1;
                    if (run >= 3) {
                        settle = k - onset;
                        break;
                    }
                } else run = 0;
                block_peak = 0;
            }
        }
    }
    const settle_s = @as(f64, @floatFromInt(settle)) / sr;

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,in,out\n");
    var j: usize = 0;
    while (j < frames) : (j += 16) {
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.9},{d:.9}\n", .{
            j, @as(f64, @floatFromInt(j)) / sr, input[j], out[j],
        });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    if (metrics.nonfinite_count != 0 or max_curve_err_db > 1.0 or
        settle == 0 or settle_s > 10.0 * atk_s)
    {
        std.debug.print("comp ratchet detail: curve_err={d:.3}dB settle={d:.4}s\n", .{ max_curve_err_db, settle_s });
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} curve_err={d:.3}dB settle={d:.4}s\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, max_curve_err_db, settle_s },
    );
}

// k-eq-tick: sine bursts at several frequencies through a known curve.
// Ratchets: finite output, and the measured per-frequency gain matches the
// analytic composite biquad magnitude (same RBJ formulas) within tolerance —
// i.e. the fy coefficient fill and the per-sample biquads are correct.
const EqBiquad = struct { b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64 };

fn eqRbjPeak(fc: f64, db: f64, q: f64, sr: f64) EqBiquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const a = std.math.pow(f64, 10.0, db / 40.0);
    const alpha = sw / (2.0 * q);
    return .{ .b0 = 1 + alpha * a, .b1 = -2 * cw, .b2 = 1 - alpha * a, .a0 = 1 + alpha / a, .a1 = -2 * cw, .a2 = 1 - alpha / a };
}

fn eqRbjShelf(fc: f64, db: f64, sr: f64, high: bool) EqBiquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const a = std.math.pow(f64, 10.0, db / 40.0);
    const beta = 2.0 * @sqrt(a) * (sw / 2.0) * std.math.sqrt2;
    const ap1 = a + 1.0;
    const am1 = a - 1.0;
    if (high) return .{
        .b0 = a * (ap1 + am1 * cw + beta),
        .b1 = -2 * a * (am1 + ap1 * cw),
        .b2 = a * (ap1 + am1 * cw - beta),
        .a0 = ap1 - am1 * cw + beta,
        .a1 = 2 * (am1 - ap1 * cw),
        .a2 = ap1 - am1 * cw - beta,
    };
    return .{
        .b0 = a * (ap1 - am1 * cw + beta),
        .b1 = 2 * a * (am1 - ap1 * cw),
        .b2 = a * (ap1 - am1 * cw - beta),
        .a0 = ap1 + am1 * cw + beta,
        .a1 = -2 * (am1 + ap1 * cw),
        .a2 = ap1 + am1 * cw - beta,
    };
}

fn eqBiquadMagDb(bq: EqBiquad, f: f64, sr: f64) f64 {
    const w = 2.0 * std.math.pi * f / sr;
    const cw = @cos(w);
    const c2w = @cos(2.0 * w);
    const num = bq.b0 * bq.b0 + bq.b1 * bq.b1 + bq.b2 * bq.b2 + 2.0 * (bq.b0 * bq.b1 + bq.b1 * bq.b2) * cw + 2.0 * bq.b0 * bq.b2 * c2w;
    const den = bq.a0 * bq.a0 + bq.a1 * bq.a1 + bq.a2 * bq.a2 + 2.0 * (bq.a0 * bq.a1 + bq.a1 * bq.a2) * cw + 2.0 * bq.a0 * bq.a2 * c2w;
    return 10.0 * std.math.log10(@max(num / @max(den, 1e-30), 1e-30));
}

fn runEqCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const test_freqs = [_]f64{ 80.0, 300.0, 1000.0, 3000.0, 8000.0, 14000.0 };
    const burst_len: usize = DRUM_SAMPLE_RATE / 4; // 0.25 s per burst
    const frames: usize = burst_len * test_freqs.len;

    // A known shaping curve: +6 dB low shelf @100, flat low-mid, -8 dB peak
    // @3k (Q1.2), +4 dB high shelf @8k, HPF off.
    const ls_hz = 100.0;
    const ls_db = 6.0;
    const p1_hz = 1000.0;
    const p1_db = 0.0;
    const p1_q = 0.9;
    const p2_hz = 3000.0;
    const p2_db = -8.0;
    const p2_q = 1.2;
    const hs_hz = 8000.0;
    const hs_db = 4.0;

    const input = try alloc.alloc(f64, frames);
    defer alloc.free(input);
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);
    for (input, 0..) |*x, i| {
        const f = test_freqs[i / burst_len];
        x.* = 0.5 * @sin(2.0 * std.math.pi * f * @as(f64, @floatFromInt(i)) / sr);
    }

    // EqParams flat layout (see EqParams ustruct): 12 user cells, sr, 25 coeffs.
    var params align(8) = [_]f64{0} ** 40;
    params[0] = 20.0; // hpf-hz
    params[1] = 0.0; // hpf-on (off)
    params[2] = ls_hz;
    params[3] = ls_db;
    params[4] = p1_hz;
    params[5] = p1_db;
    params[6] = p1_q;
    params[7] = p2_hz;
    params[8] = p2_db;
    params[9] = p2_q;
    params[10] = hs_hz;
    params[11] = hs_db;
    // EqState: sig + 5*(z1,z2) = 11 cells.
    var state align(8) = [_]f64{0} ** 16;

    // Stash sr (block-prepare) then fill coefficients (the five derive stages).
    const bp_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = sr } };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("eq-block-prepare", 1, &bp_args);
    const coef_args = [_]Fy.Dsp2RawArg{.{ .ptr = @intFromPtr(&params) }};
    inline for (.{ "eq-coef-hpf", "eq-coef-ls", "eq-coef-p1", "eq-coef-p2", "eq-coef-hs" }) |cw| {
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult(cw, 1, &coef_args);
    }

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2CompositionCaller(cli.word, &slots, true, true);
    const render_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&input[0]) },
    };
    const start = nowNs();
    _ = try caller.call(@intCast(frames), &render_args);
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    // Per-burst measured gain vs analytic composite magnitude.
    const ls = eqRbjShelf(ls_hz, ls_db, sr, false);
    const p1 = eqRbjPeak(p1_hz, p1_db, p1_q, sr);
    const p2 = eqRbjPeak(p2_hz, p2_db, p2_q, sr);
    const hs = eqRbjShelf(hs_hz, hs_db, sr, true);
    var max_err_db: f64 = 0;
    for (test_freqs, 0..) |f, bi| {
        const tail_start = (bi + 1) * burst_len - DRUM_SAMPLE_RATE / 20; // last 50 ms
        const tail_end = (bi + 1) * burst_len;
        var in_e: f64 = 0;
        var out_e: f64 = 0;
        for (input[tail_start..tail_end], out[tail_start..tail_end]) |x, y| {
            in_e += x * x;
            out_e += y * y;
        }
        const meas_db = 10.0 * std.math.log10(@max(out_e, 1e-30) / @max(in_e, 1e-30));
        const exp_db = eqBiquadMagDb(ls, f, sr) + eqBiquadMagDb(p1, f, sr) + eqBiquadMagDb(p2, f, sr) + eqBiquadMagDb(hs, f, sr);
        max_err_db = @max(max_err_db, @abs(meas_db - exp_db));
    }

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,in,out\n");
    var j: usize = 0;
    while (j < frames) : (j += 16) {
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.9},{d:.9}\n", .{
            j, @as(f64, @floatFromInt(j)) / sr, input[j], out[j],
        });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    if (metrics.nonfinite_count != 0 or max_err_db > 1.5) {
        std.debug.print("eq ratchet detail: max_gain_err={d:.3}dB\n", .{max_err_db});
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} max_gain_err={d:.3}dB peak={d:.3} rms={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, max_err_db, metrics.peak, metrics.rms },
    );
}

// k-sat-tick: a 220 Hz sine driven at low then high gain (Tube). Ratchets:
// finite, output bounded by the shaper ceiling, and the crest factor drops
// under heavy drive (the waveform flattens) — i.e. it actually saturates.
fn runSatCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const burst: usize = DRUM_SAMPLE_RATE / 2;
    const frames: usize = burst * 2;
    const drives_db = [_]f64{ 0.0, 24.0 };

    const input = try alloc.alloc(f64, frames);
    defer alloc.free(input);
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);
    for (input, 0..) |*x, i| {
        x.* = 0.5 * @sin(2.0 * std.math.pi * 220.0 * @as(f64, @floatFromInt(i)) / sr);
    }

    // SatParams: drive-db mode tone-hz mix out-db + 7 derived.
    var params align(8) = [_]f64{0} ** 16;
    params[1] = 0.0; // mode = Tube (asymmetric)
    params[2] = 18000.0; // tone open
    params[3] = 1.0; // full wet
    params[4] = 0.0; // out 0 dB
    // SatState: dc-x1 dc-y1 lp.
    var state align(8) = [_]f64{0} ** 8;

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2RawRepeatedCaller(cli.word, &slots, &.{ .ptr, .ptr, .ptr, .ptr }, true, true);

    const start = nowNs();
    for (drives_db, 0..) |ddb, seg| {
        params[0] = ddb;
        const bp_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = sr } };
        _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("sat-block-prepare", 1, &bp_args);
        const off = seg * burst;
        const render_args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out[off]) },
            .{ .ptr = @intFromPtr(&state) },
            .{ .ptr = @intFromPtr(&params) },
            .{ .ptr = @intFromPtr(&input[off]) },
        };
        _ = try caller.call(@intCast(burst), &render_args);
    }
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    // Crest factor (peak/rms) over each burst's tail; a pure sine is ~1.414,
    // a flattened (saturated) wave is lower.
    var crest = [_]f64{ 0, 0 };
    for (0..2) |seg| {
        const tail_start = (seg + 1) * burst - DRUM_SAMPLE_RATE / 10;
        const tail_end = (seg + 1) * burst;
        var pk: f64 = 0;
        var e: f64 = 0;
        var n: usize = 0;
        for (out[tail_start..tail_end]) |y| {
            pk = @max(pk, @abs(y));
            e += y * y;
            n += 1;
        }
        const rms = @sqrt(e / @as(f64, @floatFromInt(n)));
        crest[seg] = pk / @max(rms, 1e-12);
    }

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,in,out\n");
    var j: usize = 0;
    while (j < frames) : (j += 16) {
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.9},{d:.9}\n", .{
            j, @as(f64, @floatFromInt(j)) / sr, input[j], out[j],
        });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    if (metrics.nonfinite_count != 0 or metrics.peak > 1.2 or crest[1] >= crest[0] * 0.9) {
        std.debug.print("sat ratchet detail: crest_lo={d:.3} crest_hi={d:.3} peak={d:.3}\n", .{ crest[0], crest[1], metrics.peak });
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} crest_lo={d:.3} crest_hi={d:.3} peak={d:.3}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, crest[0], crest[1], metrics.peak },
    );
}

// k-gate-tick: a 220 Hz sine, loud (above threshold) then quiet (below).
// Ratchets: finite, the loud segment passes near unity, and the quiet
// segment is attenuated toward the RANGE floor — i.e. the gate opens and
// closes. The detector trace is abs(input) (mono), as the host fills it.
fn runGateCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const half: usize = DRUM_SAMPLE_RATE / 2;
    const frames: usize = half * 2;

    const input = try alloc.alloc(f64, frames);
    defer alloc.free(input);
    const det = try alloc.alloc(f64, frames);
    defer alloc.free(det);
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);
    for (input, det, 0..) |*x, *d, i| {
        const amp: f64 = if (i < half) 0.5 else 0.003; // loud above thresh, quiet below
        x.* = amp * @sin(2.0 * std.math.pi * 220.0 * @as(f64, @floatFromInt(i)) / sr);
        d.* = @abs(x.*);
    }

    // GateState: det ptr in cell 0, rest zero. (idx 0 -> walks the whole run.)
    var state align(8) = [_]f64{0} ** 8;
    @as(*usize, @ptrCast(&state[0])).* = @intFromPtr(det.ptr);
    // GateParams: thresh range atk hold rel + derived.
    var params align(8) = [_]f64{0} ** 16;
    params[0] = -40.0; // thresh-db
    params[1] = -60.0; // range-db (floor)
    params[2] = 0.001; // atk-s
    params[3] = 0.05; // hold-s
    params[4] = 0.05; // rel-s

    const bp_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = sr } };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("gate-block-prepare", 1, &bp_args);

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2CompositionCaller(cli.word, &slots, true, true);
    const render_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&input[0]) },
    };
    const start = nowNs();
    _ = try caller.call(@intCast(frames), &render_args);
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    // Open ratio over the loud tail; attenuation over the quiet tail.
    const win = DRUM_SAMPLE_RATE / 10; // 100 ms
    var in_a: f64 = 0;
    var out_a: f64 = 0;
    for (input[half - win .. half], out[half - win .. half]) |x, y| {
        in_a += x * x;
        out_a += y * y;
    }
    var in_b: f64 = 0;
    var out_b: f64 = 0;
    for (input[frames - win .. frames], out[frames - win .. frames]) |x, y| {
        in_b += x * x;
        out_b += y * y;
    }
    const open_ratio_db = 10.0 * std.math.log10(@max(out_a, 1e-30) / @max(in_a, 1e-30));
    const closed_db = 10.0 * std.math.log10(@max(out_b, 1e-30) / @max(in_b, 1e-30));

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,in,out\n");
    var j: usize = 0;
    while (j < frames) : (j += 16) {
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.9},{d:.9}\n", .{
            j, @as(f64, @floatFromInt(j)) / sr, input[j], out[j],
        });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    // Open: within ~1 dB of unity. Closed: attenuated by at least 30 dB.
    if (metrics.nonfinite_count != 0 or @abs(open_ratio_db) > 1.0 or closed_db > -30.0) {
        std.debug.print("gate ratchet detail: open={d:.3}dB closed={d:.3}dB\n", .{ open_ratio_db, closed_db });
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} open={d:.3}dB closed={d:.3}dB\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, open_ratio_db, closed_db },
    );
}

// k-verb-tick: impulse through the plate, full wet. Ratchets: finite,
// RT60 (Schroeder backward integration) in a plausible plate range for
// the default decay, and a tail that is actually decaying.
fn runReverbCase(alloc: std.mem.Allocator, cli: Cli, host: *FyHost) !void {
    const sr: f64 = @floatFromInt(DRUM_SAMPLE_RATE);
    const frames: usize = 5 * DRUM_SAMPLE_RATE;
    const ring_len: usize = 86400; // 0.9 s at 96k, matches the manifest request

    const ring = try alloc.alloc(f64, ring_len);
    defer alloc.free(ring);
    @memset(ring, 0);

    const input = try alloc.alloc(f64, frames);
    defer alloc.free(input);
    @memset(input, 0);
    input[0] = 1.0;
    const out = try alloc.alloc(f64, frames);
    defer alloc.free(out);
    @memset(out, 0);

    // VerbState mirror: ring pointer, element count, channel id up front.
    var state align(8) = [_]f64{0} ** 64;
    @as(*usize, @ptrCast(&state[0])).* = @intFromPtr(ring.ptr);
    state[1] = @floatFromInt(ring_len);
    state[2] = 0.0; // left channel

    // VerbParams: predelay decay damp-hz bw-hz mix mod-depth mod-rate + derived.
    var params align(8) = [_]f64{0} ** 32;
    params[0] = 0.01;
    params[1] = 0.75;
    params[2] = 5000.0;
    params[3] = 9000.0;
    params[4] = 1.0; // full wet so the ratchets see only the tank
    params[5] = 10.0;
    params[6] = 1.2;

    const bp_args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&params) }, .{ .f64 = sr } };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("verb-block-prepare", 1, &bp_args);
    const prep_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .f64 = sr },
    };
    _ = try host.fy.callDsp2RawRepeatedWithArgsNoResult("verb-prepare", 1, &prep_args);

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try host.fy.compileDsp2CompositionCaller(cli.word, &slots, true, true);
    const render_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&input[0]) },
    };
    const start = nowNs();
    _ = try caller.call(@intCast(frames), &render_args);
    const run_ns = nowNs() - start;

    var metrics = Metrics{};
    metrics.ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(frames));
    fillSignalMetrics(out, &metrics);
    for (out) |x| {
        if (!std.math.isFinite(x)) metrics.nonfinite_count += 1;
    }

    // Schroeder backward integration -> RT60 from the -5..-25 dB slope.
    const edc = try alloc.alloc(f64, frames);
    defer alloc.free(edc);
    var acc: f64 = 0;
    var i: usize = frames;
    while (i > 0) {
        i -= 1;
        acc += out[i] * out[i];
        edc[i] = acc;
    }
    const e0 = @max(edc[0], 1e-30);
    var t5: f64 = -1;
    var t25: f64 = -1;
    for (edc, 0..) |e, j| {
        const db = 10.0 * std.math.log10(@max(e, 1e-30) / e0);
        if (t5 < 0 and db <= -5.0) t5 = @as(f64, @floatFromInt(j)) / sr;
        if (t25 < 0 and db <= -25.0) {
            t25 = @as(f64, @floatFromInt(j)) / sr;
            break;
        }
    }
    const rt60: f64 = if (t5 >= 0 and t25 > t5) (t25 - t5) * 3.0 else -1;

    // Tail actually decays: late RMS well under early RMS.
    var early: f64 = 0;
    var late: f64 = 0;
    for (out[0..DRUM_SAMPLE_RATE]) |x| early += x * x;
    for (out[frames - DRUM_SAMPLE_RATE ..]) |x| late += x * x;

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(alloc);
    try csv.appendSlice(alloc, "sample,time,out,edc_db\n");
    var j: usize = 0;
    while (j < frames) : (j += 64) {
        const db = 10.0 * std.math.log10(@max(edc[j], 1e-30) / e0);
        try appendFmt(alloc, &csv, "{d},{d:.9},{d:.12},{d:.3}\n", .{
            j, @as(f64, @floatFromInt(j)) / sr, out[j], db,
        });
    }
    try writeDrumArtifacts(alloc, cli, host, csv.items, metrics, out);

    if (metrics.nonfinite_count != 0 or metrics.peak > 4.0 or
        rt60 < 0.8 or rt60 > 12.0 or late >= early * 0.25)
    {
        std.debug.print("reverb ratchet detail: rt60={d:.3} early={d:.6} late={d:.6} peak={d:.3}\n", .{ rt60, early, late, metrics.peak });
        return error.KernelRatchetFailed;
    }

    std.debug.print(
        "kernel {s}:{s} case={s} frames={} ns_per_sample={d:.3} rt60={d:.2}s peak={d:.3} rms={d:.4}\n",
        .{ cli.kernel, cli.word, cli.case_name, frames, metrics.ns_per_iter, rt60, metrics.peak, metrics.rms },
    );
}

fn writeDrumArtifacts(
    alloc: std.mem.Allocator,
    cli: Cli,
    host: *FyHost,
    csv_text: []const u8,
    metrics: Metrics,
    wav_samples: ?[]const f64,
) !void {
    const metrics_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(metrics_path);
    const disasm_path = try std.fmt.allocPrint(alloc, "{s}_disasm.txt", .{cli.out_prefix});
    defer alloc.free(disasm_path);
    const lanes_path = try std.fmt.allocPrint(alloc, "{s}_lanes.csv", .{cli.out_prefix});
    defer alloc.free(lanes_path);

    // Composition words have no single raw body to report/disassemble.
    const report = if (host.fy.isCompositionWord(cli.word))
        Fy.CompileReport{}
    else
        try host.fy.reportDsp2RawWord(cli.word);
    const metrics_json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "kernel": "{s}",
        \\  "word": "{s}",
        \\  "case": "{s}",
        \\  "sample_rate": {d},
        \\  "iterations": {d},
        \\  "ns_per_iter": {d:.6},
        \\  "max_abs_error": {d:.12},
        \\  "nonfinite_count": {d},
        \\  "rms": {d:.12},
        \\  "peak": {d:.12},
        \\  "mean": {d:.12},
        \\  "instruction_count": {d},
        \\  "push_count": {d},
        \\  "pop_count": {d},
        \\  "float_alu_count": {d}
        \\}}
        \\
    , .{
        cli.kernel,
        cli.word,
        cli.case_name,
        DRUM_SAMPLE_RATE,
        cli.iterations,
        metrics.ns_per_iter,
        metrics.max_abs_error,
        metrics.nonfinite_count,
        metrics.rms,
        metrics.peak,
        metrics.mean,
        report.instruction_count,
        report.push_count,
        report.pop_count,
        report.float_alu_count,
    });
    defer alloc.free(metrics_json);
    try writeFile(alloc, metrics_path, metrics_json);

    if (!host.fy.isCompositionWord(cli.word)) {
        const disasm = try host.fy.disassembleDsp2RawWordAlloc(alloc, cli.word);
        defer alloc.free(disasm);
        try writeFile(alloc, disasm_path, disasm);
    }

    try writeFile(alloc, lanes_path, csv_text);

    if (wav_samples) |samples| {
        const wav_path = try std.fmt.allocPrint(alloc, "{s}.wav", .{cli.out_prefix});
        defer alloc.free(wav_path);
        try writeWav16StereoBuffer(alloc, wav_path, samples, DRUM_SAMPLE_RATE);
    }
}
