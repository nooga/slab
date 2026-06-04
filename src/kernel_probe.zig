const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;

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
        try runFilterCase(alloc, cli);
        return;
    }
    if (isOscillatorCase(cli.case_name)) {
        try runSawPolyblepCase(alloc, cli, &host);
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
        \\  ms20-lpf-grid
        \\  saw-polyblep-render | saw-falling-polyblep-render | saw-cap-polyblep-render
        \\  saw-topcut-polyblep-render | square-polyblep-render | pulse-polyblep-render
        \\
    , .{});
}

fn isFilterCase(name: []const u8) bool {
    return std.mem.eql(u8, name, "ms20-lpf-grid");
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

fn runFilterCase(alloc: std.mem.Allocator, cli: Cli) !void {
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
            const y = ms20ishLpfStep(&state, input, cutoff, resonance, FILTER_DRIVE, sample_rate);
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

fn ms20ishLpfStep(state: *Ms20LpfState, input: f64, cutoff_hz: f64, resonance: f64, drive: f64, sample_rate: u32) f64 {
    const oversample: usize = 4;
    const os_rate = @as(f64, @floatFromInt(sample_rate * oversample));
    const fc = std.math.clamp(cutoff_hz, 20.0, @as(f64, @floatFromInt(sample_rate)) * 0.42);
    const g = @tan(std.math.pi * fc / os_rate);
    const damping = @max(0.015, 1.2 / (1.0 + resonance * 8.0));
    const x = input;
    var out: f64 = state.ic2;
    var i: usize = 0;
    while (i < oversample) : (i += 1) {
        const driven = diodeClip(x * drive, 1.0);
        const h = 1.0 / (1.0 + 2.0 * damping * g + g * g);
        const hp = (driven - (2.0 * damping + g) * state.ic1 - state.ic2) * h;
        const bp = g * hp + state.ic1;
        state.ic1 = diodeClip(g * hp + bp, 1.05);
        const lp = g * bp + state.ic2;
        state.ic2 = diodeClip(g * bp + lp, 1.05);
        out = diodeClip(lp, 1.8);
    }
    return out;
}

fn diodeClip(x: f64, amount: f64) f64 {
    return tanhRationalApprox(x * amount);
}

fn whiteNoise(state: *u32) f64 {
    state.* = state.* *% 1664525 +% 1013904223;
    const v = (state.* >> 8) & 0x00ff_ffff;
    return @as(f64, @floatFromInt(v)) / 8_388_607.5 - 1.0;
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
