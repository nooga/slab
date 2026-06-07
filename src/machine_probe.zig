const std = @import("std");
const Fy = @import("fy").Fy;
const registry_mod = @import("machine_registry.zig");
const machine_mod = @import("machine.zig");
const fy_host_mod = @import("fy_host.zig");
const FyMachine = @import("machines/fy_machine.zig").FyMachine;
const fy_machine_mod = @import("machines/fy_machine.zig");
const fy_raw_machine_mod = @import("machines/fy_raw_machine.zig");

const SAMPLE_RATE: u32 = 48_000;
const BLOCK_FRAMES: usize = 256;
const MAX_CHAIN = 8;

extern fn close(fd: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;

const Cli = struct {
    chain: []const u8 = "verb1",
    input: InputSpec = .impulse,
    seconds: f32 = 2.0,
    out_prefix: []const u8 = "scratch/probe",
    params: []const u8 = "",
};

const InputKind = enum { impulse, step, sine, note };

const InputSpec = struct {
    kind: InputKind,
    freq: f32 = 440.0,
    pitch: f32 = 60.0,
    velocity: f32 = 0.9,

    const impulse = InputSpec{ .kind = .impulse };
};

const ChainItem = struct {
    reg_idx: usize,
    mach: machine_mod.Machine,
};

const Metrics = struct {
    peak_l: f32 = 0,
    peak_r: f32 = 0,
    rms_l: f64 = 0,
    rms_r: f64 = 0,
    dc_l: f64 = 0,
    dc_r: f64 = 0,
    nonfinite_count: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const cli = try parseCli(init);
    try ensureScratch();

    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    try loadRegistry(&reg);

    var chain: [MAX_CHAIN]ChainItem = undefined;
    const chain_len = try instantiateChain(alloc, &reg, cli.chain, &chain);
    defer {
        for (chain[0..chain_len]) |*item| {
            if (item.mach.deinit) |deinit_fn| deinit_fn(item.mach.state, alloc);
        }
    }
    try applyParamOverrides(chain[0..chain_len], cli.params);
    for (chain[0..chain_len]) |*item| item.mach.reset(item.mach.state);

    const total_frames: usize = @intFromFloat(@max(0.05, cli.seconds) * @as(f32, @floatFromInt(SAMPLE_RATE)));
    const l = try alloc.alloc(f32, total_frames);
    defer alloc.free(l);
    const r = try alloc.alloc(f32, total_frames);
    defer alloc.free(r);
    @memset(l, 0);
    @memset(r, 0);

    try renderOffline(cli.input, chain[0..chain_len], l, r);
    const metrics = computeMetrics(l, r);

    const wav_path = try std.fmt.allocPrint(alloc, "{s}.wav", .{cli.out_prefix});
    defer alloc.free(wav_path);
    const json_path = try std.fmt.allocPrint(alloc, "{s}_metrics.json", .{cli.out_prefix});
    defer alloc.free(json_path);
    try writeWav16(alloc, wav_path, l, r);
    try writeMetrics(alloc, json_path, cli, metrics, total_frames);

    std.debug.print("wrote {s}\nwrote {s}\n", .{ wav_path, json_path });
}

fn parseCli(init: std.process.Init) !Cli {
    var cli = Cli{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.startsWith(u8, arg, "--chain=")) {
            cli.chain = arg["--chain=".len..];
        } else if (std.mem.startsWith(u8, arg, "--input=")) {
            cli.input = try parseInput(arg["--input=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--seconds=")) {
            cli.seconds = try std.fmt.parseFloat(f32, arg["--seconds=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            cli.out_prefix = arg["--out=".len..];
        } else if (std.mem.startsWith(u8, arg, "--params=")) {
            cli.params = arg["--params=".len..];
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
        \\  zig build machine-probe -- --chain=verb1 --input=impulse --seconds=2 --out=scratch/verb1 --params=verb1.mix=1
        \\
        \\inputs:
        \\  impulse | step | sine:440 | note:60
        \\
    , .{});
}

fn parseInput(s: []const u8) !InputSpec {
    if (std.mem.eql(u8, s, "impulse")) return .{ .kind = .impulse };
    if (std.mem.eql(u8, s, "step")) return .{ .kind = .step };
    if (std.mem.startsWith(u8, s, "sine:")) {
        return .{ .kind = .sine, .freq = try std.fmt.parseFloat(f32, s["sine:".len..]) };
    }
    if (std.mem.startsWith(u8, s, "note:")) {
        return .{ .kind = .note, .pitch = try std.fmt.parseFloat(f32, s["note:".len..]) };
    }
    return error.InvalidInput;
}

fn ensureScratch() !void {
    const rc = mkdir("scratch", 0o755);
    if (rc != 0 and std.c._errno().* != 17) return error.MkdirFailed;
}

fn loadRegistry(reg: *registry_mod.Registry) !void {
    try reg.load("sine", "machines/sine_v1/sine.fy", "sine-audio", "sine-ui", 108);
    try reg.load("square", "machines/square_v1/square.fy", "square-audio", "square-ui", 108);
    try reg.load("mono1", "machines/mono1/mono1.fy", "mono1-audio", "mono1-ui", 580);
    try reg.load("drum1", "machines/drum1/drum1.fy", "drum1-audio", "drum1-ui", 428);
    try reg.load("chorus", "machines/chorus1/chorus1.fy", "chorus1-audio", "chorus1-ui", 320);
    try reg.load("comp1", "machines/comp1/comp1.fy", "comp1-audio", "comp1-ui", 375);
    try reg.load("fm1", "machines/fm1/fm1.fy", "fm1-audio", "fm1-ui", 428);
    try reg.load("delay1", "machines/delay1/delay1.fy", "delay1-audio", "delay1-ui", 375);
    try reg.load("verb1", "machines/verb1/verb1.fy", "verb1-audio", "verb1-ui", 270);
    try reg.loadRawManifest("machines/raw_ms20/raw-ms20.manifest");
}

fn instantiateChain(alloc: std.mem.Allocator, reg: *registry_mod.Registry, chain_text: []const u8, out: *[MAX_CHAIN]ChainItem) !usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, chain_text, ',');
    while (it.next()) |raw_name| {
        const name = std.mem.trim(u8, raw_name, " \t\r\n");
        if (name.len == 0) continue;
        if (count >= MAX_CHAIN) return error.ChainTooLong;
        if (fy_raw_machine_mod.fixtureSpec(name)) |spec| {
            const raw = try fy_raw_machine_mod.FyRawMachine.create(alloc, spec);
            out[count] = .{
                .reg_idx = std.math.maxInt(usize),
                .mach = raw.machineInterface(),
            };
            count += 1;
            continue;
        }
        const idx = findMachine(reg, name) orelse return error.UnknownMachine;
        out[count] = .{
            .reg_idx = idx,
            .mach = try reg.instantiate(idx),
        };
        count += 1;
    }
    if (count == 0) return error.EmptyChain;
    return count;
}

fn findMachine(reg: *registry_mod.Registry, name: []const u8) ?usize {
    for (reg.entries[0..reg.count], 0..) |*entry, i| {
        if (std.mem.eql(u8, entry.nameSlice(), name)) return i;
    }
    return null;
}

fn renderOffline(input: InputSpec, chain: []ChainItem, l: []f32, r: []f32) !void {
    var a_l: [BLOCK_FRAMES]f32 = undefined;
    var a_r: [BLOCK_FRAMES]f32 = undefined;
    var b_l: [BLOCK_FRAMES]f32 = undefined;
    var b_r: [BLOCK_FRAMES]f32 = undefined;
    var events: [2]machine_mod.NoteEvent = undefined;
    const note_off_frame: usize = @min(l.len, SAMPLE_RATE / 2);

    var frame: usize = 0;
    while (frame < l.len) : (frame += BLOCK_FRAMES) {
        const n = @min(BLOCK_FRAMES, l.len - frame);
        const cur_l = a_l[0..n];
        const cur_r = a_r[0..n];
        @memset(cur_l, 0);
        @memset(cur_r, 0);
        fillAudioInput(input, frame, cur_l, cur_r);

        var event_count: usize = 0;
        if (input.kind == .note) {
            if (frame == 0) {
                events[event_count] = .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = input.pitch, .velocity = input.velocity };
                event_count += 1;
            }
            if (note_off_frame >= frame and note_off_frame < frame + n) {
                events[event_count] = .{ .sample_offset = @intCast(note_off_frame - frame), .kind = .note_off, .channel = 0, .note_id = 1, .pitch = input.pitch, .velocity = 0 };
                event_count += 1;
            }
        }

        var src_l = cur_l;
        var src_r = cur_r;
        var dst_l = b_l[0..n];
        var dst_r = b_r[0..n];
        for (chain) |*item| {
            @memset(dst_l, 0);
            @memset(dst_r, 0);
            var ctx = machine_mod.MachineCtx{
                .sample_rate = @floatFromInt(SAMPLE_RATE),
                .block_size = @intCast(n),
                .block_start = @intCast(frame),
                .tempo_bpm = 120,
                .ppq_position = 0,
                .transport_state = .playing,
                .note_in = if (event_count > 0) @ptrCast(&events[0]) else null,
                .note_in_count = @intCast(event_count),
            };
            if (isAudioEffect(item)) {
                const in_ports = [_][*]const f32{ src_l.ptr, src_r.ptr };
                ctx.audio_in = @ptrCast(&in_ports[0]);
                ctx.audio_in_count = 2;
                ctx.note_in = null;
                ctx.note_in_count = 0;
            }
            item.mach.render(item.mach.state, &ctx, dst_l, dst_r);

            const old_l = src_l;
            const old_r = src_r;
            src_l = dst_l;
            src_r = dst_r;
            dst_l = old_l;
            dst_r = old_r;
            event_count = 0;
        }

        @memcpy(l[frame..][0..n], src_l);
        @memcpy(r[frame..][0..n], src_r);
    }
}

fn fillAudioInput(input: InputSpec, frame: usize, l: []f32, r: []f32) void {
    switch (input.kind) {
        .impulse => if (frame == 0 and l.len > 0) {
            l[0] = 1.0;
            r[0] = 1.0;
        },
        .step => {
            @memset(l, 0.5);
            @memset(r, 0.5);
        },
        .sine => {
            for (l, r, 0..) |*sl, *sr, i| {
                const sample_index: f32 = @floatFromInt(frame + i);
                const v: f32 = @floatCast(@sin(@as(f64, sample_index) * std.math.tau * @as(f64, input.freq) / SAMPLE_RATE) * 0.5);
                sl.* = v;
                sr.* = v;
            }
        },
        .note => {},
    }
}

fn isAudioEffect(item: *const ChainItem) bool {
    const name = item.mach.name;
    return std.mem.eql(u8, name, "raw-sat") or
        std.mem.eql(u8, name, "chorus") or
        std.mem.eql(u8, name, "comp1") or
        std.mem.eql(u8, name, "delay1") or
        std.mem.eql(u8, name, "verb1");
}

fn applyParamOverrides(chain: []ChainItem, params_text: []const u8) !void {
    if (params_text.len == 0) return;
    var it = std.mem.splitScalar(u8, params_text, ',');
    while (it.next()) |raw| {
        const spec = std.mem.trim(u8, raw, " \t\r\n");
        if (spec.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidParamSpec;
        const lhs = spec[0..eq];
        const value = try std.fmt.parseFloat(f32, spec[eq + 1 ..]);
        const dot = std.mem.indexOfScalar(u8, lhs, '.') orelse return error.InvalidParamSpec;
        const machine_name = lhs[0..dot];
        const param_name = lhs[dot + 1 ..];
        var applied = false;
        for (chain) |*item| {
            if (!std.mem.eql(u8, item.mach.name, machine_name)) continue;
            try setParam(item.mach, param_name, value);
            applied = true;
        }
        if (!applied) return error.ParamMachineNotInChain;
    }
}

fn setParam(mach: machine_mod.Machine, field: []const u8, value: f32) !void {
    const fy: *FyMachine = @ptrCast(@alignCast(mach.state));
    if (std.mem.eql(u8, mach.name, "delay1")) {
        const p: *align(1) fy_machine_mod.Delay1Params = @ptrCast(&fy.params[0]);
        if (setField(fy_machine_mod.Delay1Params, p, field, value)) return;
    } else if (std.mem.eql(u8, mach.name, "verb1")) {
        const p: *align(1) fy_machine_mod.Verb1Params = @ptrCast(&fy.params[0]);
        if (setField(fy_machine_mod.Verb1Params, p, field, value)) return;
    } else if (std.mem.eql(u8, mach.name, "fm1")) {
        const p: *align(1) fy_machine_mod.Fm1Params = @ptrCast(&fy.params[0]);
        if (setField(fy_machine_mod.Fm1Params, p, field, value)) return;
    } else if (std.mem.eql(u8, mach.name, "chorus")) {
        const p: *align(1) fy_machine_mod.Chorus1Params = @ptrCast(&fy.params[0]);
        if (setField(fy_machine_mod.Chorus1Params, p, field, value)) return;
    } else if (std.mem.eql(u8, mach.name, "comp1")) {
        const p: *align(1) fy_machine_mod.Comp1Params = @ptrCast(&fy.params[0]);
        if (setField(fy_machine_mod.Comp1Params, p, field, value)) return;
    } else if (std.mem.eql(u8, mach.name, "mono1")) {
        const p: *align(1) fy_machine_mod.Mono1Params = @ptrCast(&fy.params[0]);
        if (setField(fy_machine_mod.Mono1Params, p, field, value)) return;
    }
    return error.UnknownParam;
}

fn setField(comptime T: type, p: *align(1) T, field: []const u8, value: f32) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, field)) {
            @field(p, f.name) = value;
            return true;
        }
    }
    return false;
}

fn computeMetrics(l: []const f32, r: []const f32) Metrics {
    var m = Metrics{};
    var sum_l: f64 = 0;
    var sum_r: f64 = 0;
    var sum_sq_l: f64 = 0;
    var sum_sq_r: f64 = 0;
    for (l, r) |sl, sr| {
        if (!std.math.isFinite(sl) or !std.math.isFinite(sr)) {
            m.nonfinite_count += 1;
            continue;
        }
        m.peak_l = @max(m.peak_l, @abs(sl));
        m.peak_r = @max(m.peak_r, @abs(sr));
        sum_l += sl;
        sum_r += sr;
        sum_sq_l += @as(f64, sl) * @as(f64, sl);
        sum_sq_r += @as(f64, sr) * @as(f64, sr);
    }
    const n: f64 = @floatFromInt(@max(l.len, 1));
    m.dc_l = sum_l / n;
    m.dc_r = sum_r / n;
    m.rms_l = @sqrt(sum_sq_l / n);
    m.rms_r = @sqrt(sum_sq_r / n);
    return m;
}

fn writeMetrics(alloc: std.mem.Allocator, path: []const u8, cli: Cli, m: Metrics, frames: usize) !void {
    const json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "sample_rate": {d},
        \\  "frames": {d},
        \\  "seconds": {d:.6},
        \\  "chain": "{s}",
        \\  "peak_l": {d:.8},
        \\  "peak_r": {d:.8},
        \\  "rms_l": {d:.8},
        \\  "rms_r": {d:.8},
        \\  "dc_l": {d:.8},
        \\  "dc_r": {d:.8},
        \\  "nonfinite_count": {d}
        \\}}
        \\
    , .{ SAMPLE_RATE, frames, @as(f64, @floatFromInt(frames)) / SAMPLE_RATE, cli.chain, m.peak_l, m.peak_r, m.rms_l, m.rms_r, m.dc_l, m.dc_r, m.nonfinite_count });
    defer alloc.free(json);
    try writeFile(alloc, path, json);
}

fn writeWav16(alloc: std.mem.Allocator, path: []const u8, l: []const f32, r: []const f32) !void {
    const frames = l.len;
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
    putU32(buf[24..28], SAMPLE_RATE);
    putU32(buf[28..32], SAMPLE_RATE * 2 * 2);
    putU16(buf[32..34], 4);
    putU16(buf[34..36], 16);
    @memcpy(buf[36..40], "data");
    putU32(buf[40..44], data_bytes);

    var off: usize = 44;
    for (l, r) |sl, sr| {
        putI16(buf[off..][0..2], sampleToI16(sl));
        putI16(buf[off + 2 ..][0..2], sampleToI16(sr));
        off += 4;
    }
    try writeFile(alloc, path, buf);
}

fn sampleToI16(v: f32) i16 {
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
