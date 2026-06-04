const std = @import("std");
const fy_mod = @import("fy");

const Fy = fy_mod.Fy;

const Case = struct {
    name: []const u8,
    source: []const u8,
    word: []const u8,
};

const cases = [_]Case{
    .{
        .name = "noalloc-int-add",
        .source = "noalloc: bench-noalloc-int-add 1 2 + ;",
        .word = "bench-noalloc-int-add",
    },
    .{
        .name = "dsp-int-add",
        .source = "dsp: bench-dsp-int-add 1 2 + ;",
        .word = "bench-dsp-int-add",
    },
    .{
        .name = "dsp-stack-shuffle",
        .source = "dsp: bench-dsp-stack 1 2 3 4 over2 + + + + + ;",
        .word = "bench-dsp-stack",
    },
    .{
        .name = "word-call",
        .source = "noalloc: bench-inc 1 + ; noalloc: bench-call 41 bench-inc ;",
        .word = "bench-call",
    },
    .{
        .name = "inline-word-call",
        .source = "inline-noalloc: bench-inline-inc 1 + ; inline-noalloc: bench-inline-call 41 bench-inline-inc ;",
        .word = "bench-inline-call",
    },
    .{
        .name = "dsp-word-call",
        .source = "dsp: bench-dsp-inc 1 + ; dsp: bench-dsp-call 41 bench-dsp-inc ;",
        .word = "bench-dsp-call",
    },
    .{
        .name = "dsp-branch-ifte",
        .source = "dsp: bench-dsp-branch 5 dup 3 > [ 1 + ] [ 1 - ] ifte ;",
        .word = "bench-dsp-branch",
    },
    .{
        .name = "noalloc-float-muladd",
        .source = "noalloc: bench-noalloc-float 0.5 0.25 f* 0.125 f+ ;",
        .word = "bench-noalloc-float",
    },
    .{
        .name = "dsp-float-muladd",
        .source = "dsp: bench-dsp-float 0.5 0.25 f* 0.125 f+ ;",
        .word = "bench-dsp-float",
    },
    .{
        .name = "dsp-float-shape",
        .source = "dsp: bench-dsp-shape -0.25 fwrap01 0.5 f* fclamp01 ;",
        .word = "bench-dsp-shape",
    },
    .{
        .name = "dsp-f32-load-store",
        .source = ":: bench-dsp-mem 4 alloc ; dsp: bench-dsp-f32 bench-dsp-mem dup 0.5 swap f!32 f@32 0.25 f+ ;",
        .word = "bench-dsp-f32",
    },
};

const Options = struct {
    iterations: u64 = 10_000_000,
    filter: ?[]const u8 = null,
    disasm: bool = false,
};

fn usage() void {
    std.debug.print(
        \\usage: fy-bench [--iters N] [--filter NAME] [--disasm]
        \\
        \\Runs fixed fy microbenchmarks and prints TSV:
        \\case compile_ns run_ns iterations ns_per_iter result instructions pushes pops roundtrips branches bl blr falu fcmp fsel tag_clear tag_retag f32_load f32_store
        \\
    , .{});
}

fn parseOptions(args: []const [:0]const u8) !Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--iters")) {
            i += 1;
            if (i == args.len) return error.MissingArgument;
            const value = args[i];
            opts.iterations = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i == args.len) return error.MissingArgument;
            opts.filter = args[i];
        } else if (std.mem.eql(u8, arg, "--disasm")) {
            opts.disasm = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            std.process.exit(0);
        } else {
            return error.UnknownArgument;
        }
    }
    return opts;
}

fn shouldRun(case: Case, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    return std.mem.indexOf(u8, case.name, f) != null or std.mem.indexOf(u8, case.word, f) != null;
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, case: Case, opts: Options) !void {
    var fy = Fy.init(allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    const compile_start = nowNs(io);
    _ = try fy.run(case.source);
    const compile_ns = nowNs(io) - compile_start;

    const warmup_iters = @min(opts.iterations, 100_000);
    _ = try fy.callWordRepeated(case.word, warmup_iters);

    const run_start = nowNs(io);
    const result = try fy.callWordRepeated(case.word, opts.iterations);
    const run_ns = nowNs(io) - run_start;
    const ns_per_iter = @as(f64, @floatFromInt(run_ns)) / @as(f64, @floatFromInt(opts.iterations));

    const report = fy.reportWord(case.word) orelse return error.MissingReport;
    std.debug.print(
        "{s}\t{d}\t{d}\t{d}\t{d:.3}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            case.name,
            compile_ns,
            run_ns,
            opts.iterations,
            ns_per_iter,
            result,
            report.instruction_count,
            report.push_count,
            report.pop_count,
            report.stack_round_trip_pairs,
            report.local_branch_count,
            report.bl_count,
            report.blr_count,
            report.float_alu_count,
            report.float_compare_count,
            report.float_select_count,
            report.float_tag_clear_count,
            report.float_retag_count,
            report.f32_load_count,
            report.f32_store_count,
        },
    );

    if (opts.disasm) {
        const disasm = try fy.disassembleWordAlloc(allocator, case.word);
        defer allocator.free(disasm);
        std.debug.print("\n[{s} disasm]\n{s}\n", .{ case.name, disasm });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const opts = parseOptions(args) catch |err| {
        usage();
        return err;
    };
    const allocator = std.heap.page_allocator;
    std.debug.print("case\tcompile_ns\trun_ns\titerations\tns_per_iter\tresult\tinstructions\tpushes\tpops\troundtrips\tbranches\tbl\tblr\tfalu\tfcmp\tfsel\ttag_clear\ttag_retag\tf32_load\tf32_store\n", .{});
    for (cases) |case| {
        if (shouldRun(case, opts.filter)) {
            try runCase(allocator, io, case, opts);
        }
    }
}
