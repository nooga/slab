const std = @import("std");
const Fy = @import("fy").Fy;
const fy_host_mod = @import("fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const machine = @import("machine.zig");
const Mono1Params = @import("machines/fy_machine.zig").Mono1Params;

const BLOCK_FRAMES = 256;
const SAMPLE_RATE = 48_000.0;
const DEFAULT_WARMUP_BLOCKS = 1024;
const DEFAULT_MEASURE_BLOCKS = 20_000;

const Case = struct {
    name: []const u8,
    word: []const u8,
    params: Mono1Params,
    pitch: f32,
    velocity: f32 = 0.8,
};

const Stats = struct {
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    total_ns: u128 = 0,
    blocks: u64 = 0,

    fn add(self: *Stats, ns: u64) void {
        self.min_ns = @min(self.min_ns, ns);
        self.max_ns = @max(self.max_ns, ns);
        self.total_ns += ns;
        self.blocks += 1;
    }

    fn avgNs(self: Stats) f64 {
        if (self.blocks == 0) return 0;
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.blocks));
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;

    var warmup_blocks: usize = DEFAULT_WARMUP_BLOCKS;
    var measure_blocks: usize = DEFAULT_MEASURE_BLOCKS;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.startsWith(u8, arg, "--warmup=")) {
            warmup_blocks = try std.fmt.parseInt(usize, arg["--warmup=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--blocks=")) {
            measure_blocks = try std.fmt.parseInt(usize, arg["--blocks=".len..], 10);
        } else {
            std.debug.print("usage: zig build bench-mono1 -- [--warmup=N] [--blocks=N]\n", .{});
            return error.InvalidArgument;
        }
    }

    const cases = [_]Case{
        .{
            .name = "live saw+sub",
            .word = "mono1-audio",
            .params = monoParams(.{
                .gain = 0.48,
                .range = 1.0,
                .saw = 0.78,
                .pulse = 0.0,
                .pw = 0.5,
                .sub = 0.22,
                .noise = 0.0,
                .cutoff = 0.74,
                .resonance = 0.08,
                .drive = 0.12,
                .fenv = 0.58,
                .keytrack = 0.10,
            }),
            .pitch = 60,
        },
        .{
            .name = "live lush chord voice",
            .word = "mono1-audio",
            .params = monoParams(.{
                .gain = 0.36,
                .range = 1.0,
                .saw = 0.70,
                .pulse = 0.34,
                .pw = 0.55,
                .sub = 0.12,
                .cutoff = 0.62,
                .resonance = 0.08,
                .drive = 0.10,
                .hpf = 0.04,
                .fenv = 0.36,
                .keytrack = 0.18,
                .lfo_rate = 0.22,
                .lfo_delay = 0.18,
                .lfo_pitch = 0.006,
                .lfo_pw = 0.18,
                .lfo_cutoff = 0.10,
            }),
            .pitch = 64,
        },
        .{
            .name = "live arp pulse",
            .word = "mono1-audio",
            .params = monoParams(.{
                .gain = 0.44,
                .range = 1.0,
                .saw = 0.12,
                .pulse = 0.86,
                .pw = 0.36,
                .sub = 0.08,
                .attack = 0.004,
                .decay = 0.13,
                .sustain = 0.36,
                .release = 0.09,
                .cutoff = 0.60,
                .resonance = 0.16,
                .drive = 0.16,
                .hpf = 0.08,
                .fenv = 0.66,
                .keytrack = 0.20,
                .lfo_rate = 0.40,
                .lfo_pw = 0.12,
            }),
            .pitch = 72,
        },
        .{
            .name = "hq blep lush chord voice",
            .word = "mono1-audio-hq",
            .params = monoParams(.{
                .gain = 0.36,
                .range = 1.0,
                .saw = 0.70,
                .pulse = 0.34,
                .pw = 0.55,
                .sub = 0.12,
                .cutoff = 0.62,
                .resonance = 0.08,
                .drive = 0.10,
                .hpf = 0.04,
                .fenv = 0.36,
                .keytrack = 0.18,
                .lfo_rate = 0.22,
                .lfo_delay = 0.18,
                .lfo_pitch = 0.006,
                .lfo_pw = 0.18,
                .lfo_cutoff = 0.10,
            }),
            .pitch = 64,
        },
        .{
            .name = "hq blep arp pulse",
            .word = "mono1-audio-hq",
            .params = monoParams(.{
                .gain = 0.44,
                .range = 1.0,
                .saw = 0.12,
                .pulse = 0.86,
                .pw = 0.36,
                .sub = 0.08,
                .attack = 0.004,
                .decay = 0.13,
                .sustain = 0.36,
                .release = 0.09,
                .cutoff = 0.60,
                .resonance = 0.16,
                .drive = 0.16,
                .hpf = 0.08,
                .fenv = 0.66,
                .keytrack = 0.20,
                .lfo_rate = 0.40,
                .lfo_pw = 0.12,
            }),
            .pitch = 72,
        },
    };

    std.debug.print(
        "mono1 bench block_frames={} sample_rate={d:.0} warmup_blocks={} measure_blocks={}\n",
        .{ BLOCK_FRAMES, SAMPLE_RATE, warmup_blocks, measure_blocks },
    );
    std.debug.print("case,word,blocks,avg_ms,min_ms,max_ms,ns_per_sample,mono_voices_at_48k_256\n", .{});

    for (cases) |case| {
        const result = try runCase(alloc, case, warmup_blocks, measure_blocks);
        const avg_ns = result.avgNs();
        const avg_ms = avg_ns / std.time.ns_per_ms;
        const min_ms = @as(f64, @floatFromInt(result.min_ns)) / std.time.ns_per_ms;
        const max_ms = @as(f64, @floatFromInt(result.max_ns)) / std.time.ns_per_ms;
        const ns_per_sample = avg_ns / @as(f64, @floatFromInt(BLOCK_FRAMES));
        const budget_ms = (@as(f64, @floatFromInt(BLOCK_FRAMES)) / SAMPLE_RATE) * 1000.0;
        const voices = if (avg_ms > 0) budget_ms / avg_ms else 0;
        std.debug.print(
            "\"{s}\",{s},{},{d:.4},{d:.4},{d:.4},{d:.1},{d:.2}\n",
            .{ case.name, case.word, result.blocks, avg_ms, min_ms, max_ms, ns_per_sample, voices },
        );
    }
}

fn runCase(alloc: std.mem.Allocator, case: Case, warmup_blocks: usize, measure_blocks: usize) !Stats {
    var host = FyHost.init(alloc);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile("machines/mono1/mono1.fy");

    const render = try host.createAudioCallback(case.word);
    const reset = try host.createAudioCallback("mono1-reset");
    var params = case.params;
    var l_buf = [_]f32{0} ** BLOCK_FRAMES;
    var r_buf = [_]f32{0} ** BLOCK_FRAMES;
    var events = [_]machine.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_on,
        .channel = 0,
        .note_id = 1,
        .pitch = case.pitch,
        .velocity = case.velocity,
    }};

    callReset(&host, reset, &params);
    callRender(&host, render, &params, events[0..], &l_buf, &r_buf, 0);

    var block_start: u64 = BLOCK_FRAMES;
    var i: usize = 0;
    while (i < warmup_blocks) : (i += 1) {
        callRender(&host, render, &params, &.{}, &l_buf, &r_buf, block_start);
        block_start += BLOCK_FRAMES;
    }

    var stats = Stats{};
    i = 0;
    while (i < measure_blocks) : (i += 1) {
        const start = nowNs();
        callRender(&host, render, &params, &.{}, &l_buf, &r_buf, block_start);
        const elapsed: u64 = nowNs() - start;
        stats.add(elapsed);
        block_start += BLOCK_FRAMES;
    }

    return stats;
}

fn nowNs() u64 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @intCast(@divTrunc(
        @as(u128, @intCast(std.c.mach_absolute_time())) * @as(u128, @intCast(info.numer)),
        @as(u128, @intCast(info.denom)),
    ));
}

fn callReset(host: *FyHost, reset: *const fn () callconv(.c) void, params: *Mono1Params) void {
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setParams(@ptrCast(params));
    reset();
    FyHost.setParams(null);
}

fn callRender(
    host: *FyHost,
    render: *const fn () callconv(.c) void,
    params: *Mono1Params,
    events: []const machine.NoteEvent,
    l_buf: *[BLOCK_FRAMES]f32,
    r_buf: *[BLOCK_FRAMES]f32,
    block_start: u64,
) void {
    @memset(l_buf[0..], 0);
    @memset(r_buf[0..], 0);
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = SAMPLE_RATE;
    ctx.block_size = BLOCK_FRAMES;
    ctx.block_start = block_start;
    ctx.tempo_bpm = 120.0;
    ctx.note_in = if (events.len > 0) @ptrCast(events.ptr) else null;
    ctx.note_in_count = @intCast(events.len);
    ctx.params_current = params;

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setParams(ctx.params_current);
    FyHost.setAudioBuffers(l_buf.ptr, r_buf.ptr);
    render();
    FyHost.clearAudioBuffers();
    FyHost.setParams(null);
    FyHost.clearCtx();
}

fn monoParams(patch: anytype) Mono1Params {
    var p = Mono1Params{
        .gain = 0.45,
        .range = 1.0,
        .saw = 0.7,
        .pulse = 0.0,
        .pw = 0.5,
        .sub = 0.0,
        .noise = 0.0,
        .attack = 0.012,
        .decay = 0.18,
        .sustain = 0.72,
        .release = 0.16,
        .cutoff = 0.70,
        .resonance = 0.08,
        .drive = 0.12,
        .hpf = 0.0,
        .fenv = 0.50,
        .keytrack = 0.10,
        .lfo_rate = 0.25,
        .lfo_delay = 0.0,
        .lfo_pitch = 0.0,
        .lfo_pw = 0.0,
        .lfo_amp = 0.0,
        .lfo_cutoff = 0.0,
    };

    inline for (std.meta.fields(@TypeOf(patch))) |field| {
        @field(p, field.name) = @field(patch, field.name);
    }
    return p;
}
