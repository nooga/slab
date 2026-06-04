//! FyMachine — thin shim that bridges fy's audio and UI callbacks into
//! Slab's Machine vtable.  Both fn pointers are atomic for hot-patch.

const std = @import("std");
const c = @import("../c.zig");
const Fy = @import("fy").Fy;
const machine = @import("../machine.zig");
const fy_host_mod = @import("../fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const MAX_PARAMS = 256;

pub const FyMachine = struct {
    host: *FyHost,
    render_fn: std.atomic.Value(?*const fn () callconv(.c) void),
    ui_fn: std.atomic.Value(?*const fn () callconv(.c) void),
    reset_fn: std.atomic.Value(?*const fn () callconv(.c) void),
    name_buf: [64]u8,
    name_len: usize,
    params: [MAX_PARAMS]u8 = [_]u8{0} ** MAX_PARAMS,
    params_size: usize = 0,
    preset_index: u8 = 0,
    panel_w: f32 = 108,
    probe_counter: u32 = 0,

    pub fn init(
        host: *FyHost,
        name: []const u8,
        audio_cb: *const fn () callconv(.c) void,
        ui_cb: ?*const fn () callconv(.c) void,
        reset_cb: ?*const fn () callconv(.c) void,
        params_size: usize,
    ) FyMachine {
        var m = FyMachine{
            .host = host,
            .render_fn = std.atomic.Value(?*const fn () callconv(.c) void).init(audio_cb),
            .ui_fn = std.atomic.Value(?*const fn () callconv(.c) void).init(ui_cb),
            .reset_fn = std.atomic.Value(?*const fn () callconv(.c) void).init(reset_cb),
            .name_buf = undefined,
            .name_len = 0,
            .params_size = @min(params_size, MAX_PARAMS),
        };
        const n = @min(name.len, 63);
        @memcpy(m.name_buf[0..n], name[0..n]);
        m.name_len = n;
        initDefaultParams(&m);
        return m;
    }

    pub fn swapAudioCallback(self: *FyMachine, cb: *const fn () callconv(.c) void) void {
        self.render_fn.store(cb, .release);
    }

    pub fn swapUiCallback(self: *FyMachine, cb: ?*const fn () callconv(.c) void) void {
        self.ui_fn.store(cb, .release);
    }

    pub fn machineInterface(self: *FyMachine) machine.Machine {
        return .{
            .name = self.name_buf[0..self.name_len],
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .deinit = deinitImpl,
            .sync_params = syncParamsImpl,
            .preset_count = presetCountImpl,
            .preset_name = presetNameImpl,
            .apply_preset = applyPresetImpl,
            .panel_w = self.panel_w,
        };
    }
};

fn renderImpl(
    state: *anyopaque,
    ctx: *const machine.MachineCtx,
    l: []f32,
    r: []f32,
) void {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    const cb = self.render_fn.load(.acquire) orelse return;
    const probe = fyProbeEnabled();
    const wait_start = if (probe) probeNowNs() else 0;
    fy_host_mod.lockCallbacks();
    defer fy_host_mod.unlockCallbacks();
    const wait_ns = if (probe) probeNowNs() - wait_start else 0;

    Fy.Builtins.fyPtr = @intFromPtr(&self.host.fy);
    var local_ctx = ctx.*;
    local_ctx.params_current = if (self.params_size > 0) @ptrCast(&self.params[0]) else null;
    FyHost.setCtx(&local_ctx);
    FyHost.setParams(local_ctx.params_current);
    FyHost.setAudioBuffers(l.ptr, r.ptr);
    defer FyHost.clearAudioBuffers();
    defer FyHost.setParams(null);
    defer FyHost.clearCtx();

    var debug_name: [65:0]u8 = [_:0]u8{0} ** 65;
    const n = @min(self.name_len, 64);
    @memcpy(debug_name[0..n], self.name_buf[0..n]);
    debug_name[n] = 0;
    FyHost.setDebugMachineName(@ptrCast(&debug_name[0]));
    const render_start = if (probe) probeNowNs() else 0;
    cb();
    if (probe) {
        const render_ns = probeNowNs() - render_start;
        const budget_ns: i128 = @divTrunc(@as(i128, @intCast(ctx.block_size)) * std.time.ns_per_s, @as(i128, @intFromFloat(ctx.sample_rate)));
        self.probe_counter +%= 1;
        if (fyProbeVerbose() or render_ns > @divTrunc(budget_ns, 2) or self.probe_counter % 512 == 0) {
            std.debug.print(
                "fy-probe \"{s}\" block={} frames={} events={} wait_us={d:.1} render_us={d:.1} budget_us={d:.1}\n",
                .{
                    self.name_buf[0..self.name_len],
                    ctx.block_start,
                    ctx.block_size,
                    ctx.note_in_count,
                    @as(f64, @floatFromInt(wait_ns)) / 1_000.0,
                    @as(f64, @floatFromInt(render_ns)) / 1_000.0,
                    @as(f64, @floatFromInt(budget_ns)) / 1_000.0,
                },
            );
        }
    }
}

fn fyProbeEnabled() bool {
    return std.c.getenv("SLAB_FY_PROBE") != null;
}

fn fyProbeVerbose() bool {
    return std.c.getenv("SLAB_FY_PROBE_VERBOSE") != null;
}

fn probeNowNs() i128 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @divTrunc(@as(i128, @intCast(std.c.mach_absolute_time())) * @as(i128, @intCast(info.numer)), @as(i128, @intCast(info.denom)));
}

fn drawPanelImpl(state: *anyopaque, r: c.rl.Rectangle, m: widgets.Mouse) void {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    fy_host_mod.lockCallbacks();
    defer fy_host_mod.unlockCallbacks();

    Fy.Builtins.fyPtr = @intFromPtr(&self.host.fy);
    FyHost.setUiContext(r, m);
    FyHost.setParams(if (self.params_size > 0) @ptrCast(&self.params[0]) else null);
    defer FyHost.setParams(null);
    defer FyHost.clearUiContext();

    const cb = self.ui_fn.load(.acquire) orelse {
        // Fallback: plain label.
        c.rl.DrawRectangleRec(r, theme.pane_alt);
        widgets.drawLabelF("FY SINE", r.x + 4, r.y + 4, theme.fsTiny(), theme.text_mute);
        return;
    };
    cb();
}

fn resetImpl(state: *anyopaque) void {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    const cb = self.reset_fn.load(.acquire) orelse return;
    fy_host_mod.lockCallbacks();
    defer fy_host_mod.unlockCallbacks();

    Fy.Builtins.fyPtr = @intFromPtr(&self.host.fy);
    FyHost.setParams(if (self.params_size > 0) @ptrCast(&self.params[0]) else null);
    defer FyHost.setParams(null);
    cb();
}

fn syncParamsImpl(dst_state: *anyopaque, src_state: *anyopaque) void {
    const dst: *FyMachine = @ptrCast(@alignCast(dst_state));
    const src: *FyMachine = @ptrCast(@alignCast(src_state));
    if (!std.mem.eql(u8, dst.name_buf[0..dst.name_len], src.name_buf[0..src.name_len])) return;
    const n = @min(dst.params_size, src.params_size);
    if (n == 0) return;
    @memcpy(dst.params[0..n], src.params[0..n]);
}

pub const Mono1Params = extern struct {
    gain: f32,
    range: f32,
    saw: f32,
    pulse: f32,
    pw: f32,
    sub: f32,
    noise: f32,
    attack: f32,
    decay: f32,
    sustain: f32,
    release: f32,
    cutoff: f32,
    resonance: f32,
    drive: f32,
    hpf: f32,
    fenv: f32,
    keytrack: f32,
    lfo_rate: f32,
    lfo_delay: f32,
    lfo_pitch: f32,
    lfo_pw: f32,
    lfo_amp: f32,
    lfo_cutoff: f32,
};

fn initDefaultParams(self: *FyMachine) void {
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "mono1") and self.params_size >= @sizeOf(Mono1Params)) {
        applyMono1Preset(self, 0);
    } else if (std.mem.eql(u8, self.name_buf[0..self.name_len], "chorus") and self.params_size >= @sizeOf(Chorus1Params)) {
        const p: *align(1) Chorus1Params = @ptrCast(&self.params[0]);
        p.* = .{ .mode = 0.0, .mix = 0.42, .noise = 0.02, .level = 1.0 };
    } else if (std.mem.eql(u8, self.name_buf[0..self.name_len], "comp1") and self.params_size >= @sizeOf(Comp1Params)) {
        const p: *align(1) Comp1Params = @ptrCast(&self.params[0]);
        p.* = .{ .threshold = 0.42, .ratio = 0.42, .attack = 0.12, .release = 0.36, .makeup = 0.42, .mix = 0.72, .drive = 0.10 };
    } else if (std.mem.eql(u8, self.name_buf[0..self.name_len], "fm1") and self.params_size >= @sizeOf(Fm1Params)) {
        applyFm1Preset(self, 0);
    } else if (std.mem.eql(u8, self.name_buf[0..self.name_len], "delay1") and self.params_size >= @sizeOf(Delay1Params)) {
        const p: *align(1) Delay1Params = @ptrCast(&self.params[0]);
        p.* = .{ .time = 0.36, .feedback = 0.42, .mix = 0.32, .tone = 0.52, .ping = 0.45, .mod = 0.08, .level = 0.78 };
    } else if (std.mem.eql(u8, self.name_buf[0..self.name_len], "verb1") and self.params_size >= @sizeOf(Verb1Params)) {
        const p: *align(1) Verb1Params = @ptrCast(&self.params[0]);
        p.* = .{ .size = 0.68, .damp = 0.42, .mix = 0.42, .width = 0.86, .level = 0.90 };
    }
}

pub const Chorus1Params = extern struct {
    mode: f32,
    mix: f32,
    noise: f32,
    level: f32,
};

pub const Comp1Params = extern struct {
    threshold: f32,
    ratio: f32,
    attack: f32,
    release: f32,
    makeup: f32,
    mix: f32,
    drive: f32,
};

pub const Fm1Params = extern struct {
    level: f32,
    algorithm: f32,
    feedback: f32,
    op2_level: f32,
    op3_level: f32,
    op4_level: f32,
    op2_ratio: f32,
    op3_ratio: f32,
    op4_ratio: f32,
    attack: f32,
    decay: f32,
    sustain: f32,
    release: f32,
    wave: f32,
};

pub const Delay1Params = extern struct {
    time: f32,
    feedback: f32,
    mix: f32,
    tone: f32,
    ping: f32,
    mod: f32,
    level: f32,
};

pub const Verb1Params = extern struct {
    size: f32,
    damp: f32,
    mix: f32,
    width: f32,
    level: f32,
};

const Mono1Preset = struct {
    name: [*:0]const u8,
    params: Mono1Params,
};

const mono1_presets = [_]Mono1Preset{
    .{ .name = "JUNO SAW", .params = .{ .gain = 0.48, .range = 1.0, .saw = 0.78, .pulse = 0.0, .pw = 0.5, .sub = 0.22, .noise = 0.0, .attack = 0.012, .decay = 0.18, .sustain = 0.72, .release = 0.16, .cutoff = 0.74, .resonance = 0.08, .drive = 0.12, .hpf = 0.0, .fenv = 0.58, .keytrack = 0.10, .lfo_rate = 0.26, .lfo_delay = 0.0, .lfo_pitch = 0.0, .lfo_pw = 0.0, .lfo_amp = 0.0, .lfo_cutoff = 0.0 } },
    .{ .name = "JUNO BOTH", .params = .{ .gain = 0.42, .range = 1.0, .saw = 0.62, .pulse = 0.38, .pw = 0.5, .sub = 0.18, .noise = 0.0, .attack = 0.01, .decay = 0.16, .sustain = 0.68, .release = 0.14, .cutoff = 0.70, .resonance = 0.12, .drive = 0.14, .hpf = 0.0, .fenv = 0.60, .keytrack = 0.10, .lfo_rate = 0.26, .lfo_delay = 0.0, .lfo_pitch = 0.0, .lfo_pw = 0.0, .lfo_amp = 0.0, .lfo_cutoff = 0.0 } },
    .{ .name = "JUNO SUB", .params = .{ .gain = 0.5, .range = 0.0, .saw = 0.62, .pulse = 0.0, .pw = 0.5, .sub = 0.38, .noise = 0.0, .attack = 0.008, .decay = 0.22, .sustain = 0.78, .release = 0.18, .cutoff = 0.68, .resonance = 0.10, .drive = 0.16, .hpf = 0.0, .fenv = 0.55, .keytrack = 0.08, .lfo_rate = 0.26, .lfo_delay = 0.0, .lfo_pitch = 0.0, .lfo_pw = 0.0, .lfo_amp = 0.0, .lfo_cutoff = 0.0 } },
    .{ .name = "JP PUNCH BASS", .params = .{ .gain = 0.62, .range = 0.0, .saw = 0.58, .pulse = 0.22, .pw = 0.44, .sub = 0.48, .noise = 0.0, .attack = 0.004, .decay = 0.12, .sustain = 0.44, .release = 0.07, .cutoff = 0.52, .resonance = 0.10, .drive = 0.34, .hpf = 0.0, .fenv = 0.86, .keytrack = 0.06, .lfo_rate = 0.18, .lfo_delay = 0.0, .lfo_pitch = 0.0, .lfo_pw = 0.0, .lfo_amp = 0.0, .lfo_cutoff = 0.0 } },
    .{ .name = "JP LUSH CHORD", .params = .{ .gain = 0.36, .range = 1.0, .saw = 0.70, .pulse = 0.34, .pw = 0.55, .sub = 0.12, .noise = 0.0, .attack = 0.045, .decay = 0.42, .sustain = 0.78, .release = 0.44, .cutoff = 0.62, .resonance = 0.08, .drive = 0.10, .hpf = 0.04, .fenv = 0.36, .keytrack = 0.18, .lfo_rate = 0.22, .lfo_delay = 0.18, .lfo_pitch = 0.006, .lfo_pw = 0.18, .lfo_amp = 0.0, .lfo_cutoff = 0.10 } },
    .{ .name = "JP SOFT STRINGS", .params = .{ .gain = 0.34, .range = 1.0, .saw = 0.82, .pulse = 0.0, .pw = 0.50, .sub = 0.10, .noise = 0.0, .attack = 0.12, .decay = 0.55, .sustain = 0.88, .release = 0.58, .cutoff = 0.58, .resonance = 0.04, .drive = 0.06, .hpf = 0.08, .fenv = 0.24, .keytrack = 0.22, .lfo_rate = 0.20, .lfo_delay = 0.22, .lfo_pitch = 0.004, .lfo_pw = 0.0, .lfo_amp = 0.0, .lfo_cutoff = 0.12 } },
    .{ .name = "JP GLASS PLUCK", .params = .{ .gain = 0.46, .range = 2.0, .saw = 0.38, .pulse = 0.52, .pw = 0.42, .sub = 0.0, .noise = 0.02, .attack = 0.002, .decay = 0.16, .sustain = 0.12, .release = 0.13, .cutoff = 0.70, .resonance = 0.18, .drive = 0.08, .hpf = 0.18, .fenv = 0.72, .keytrack = 0.26, .lfo_rate = 0.30, .lfo_delay = 0.0, .lfo_pitch = 0.0, .lfo_pw = 0.0, .lfo_amp = 0.0, .lfo_cutoff = 0.0 } },
    .{ .name = "JP BRASS LEAD", .params = .{ .gain = 0.48, .range = 1.0, .saw = 0.74, .pulse = 0.32, .pw = 0.46, .sub = 0.08, .noise = 0.0, .attack = 0.018, .decay = 0.28, .sustain = 0.62, .release = 0.20, .cutoff = 0.66, .resonance = 0.12, .drive = 0.18, .hpf = 0.02, .fenv = 0.62, .keytrack = 0.16, .lfo_rate = 0.34, .lfo_delay = 0.16, .lfo_pitch = 0.010, .lfo_pw = 0.04, .lfo_amp = 0.0, .lfo_cutoff = 0.0 } },
    .{ .name = "JP ARP PULSE", .params = .{ .gain = 0.44, .range = 1.0, .saw = 0.12, .pulse = 0.86, .pw = 0.36, .sub = 0.08, .noise = 0.0, .attack = 0.004, .decay = 0.13, .sustain = 0.36, .release = 0.09, .cutoff = 0.60, .resonance = 0.16, .drive = 0.16, .hpf = 0.08, .fenv = 0.66, .keytrack = 0.20, .lfo_rate = 0.40, .lfo_delay = 0.0, .lfo_pitch = 0.0, .lfo_pw = 0.12, .lfo_amp = 0.0, .lfo_cutoff = 0.0 } },
};

const Chorus1Preset = struct {
    name: [*:0]const u8,
    params: Chorus1Params,
};

const chorus1_presets = [_]Chorus1Preset{
    .{ .name = "JUNO I", .params = .{ .mode = 0.0, .mix = 0.36, .noise = 0.01, .level = 1.0 } },
    .{ .name = "JUNO II", .params = .{ .mode = 1.0, .mix = 0.46, .noise = 0.015, .level = 1.0 } },
    .{ .name = "JUNO I+II", .params = .{ .mode = 2.0, .mix = 0.52, .noise = 0.02, .level = 0.96 } },
    .{ .name = "CLEAN WIDE", .params = .{ .mode = 1.0, .mix = 0.38, .noise = 0.0, .level = 1.0 } },
};

const Fm1Preset = struct {
    name: [*:0]const u8,
    params: Fm1Params,
};

const fm1_presets = [_]Fm1Preset{
    .{ .name = "DX EPIANO", .params = .{ .level = 0.44, .algorithm = 0.34, .feedback = 0.08, .op2_level = 0.42, .op3_level = 0.24, .op4_level = 0.10, .op2_ratio = 0.26, .op3_ratio = 0.51, .op4_ratio = 0.64, .attack = 0.005, .decay = 0.30, .sustain = 0.42, .release = 0.24, .wave = 0.0 } },
    .{ .name = "FM BASS", .params = .{ .level = 0.58, .algorithm = 0.02, .feedback = 0.34, .op2_level = 0.62, .op3_level = 0.12, .op4_level = 0.05, .op2_ratio = 0.24, .op3_ratio = 0.14, .op4_ratio = 0.40, .attack = 0.002, .decay = 0.18, .sustain = 0.56, .release = 0.08, .wave = 0.0 } },
    .{ .name = "OPL BELL", .params = .{ .level = 0.42, .algorithm = 0.34, .feedback = 0.18, .op2_level = 0.38, .op3_level = 0.70, .op4_level = 0.28, .op2_ratio = 0.51, .op3_ratio = 0.76, .op4_ratio = 0.89, .attack = 0.002, .decay = 0.46, .sustain = 0.08, .release = 0.42, .wave = 0.42 } },
    .{ .name = "GLASS STACK", .params = .{ .level = 0.40, .algorithm = 0.72, .feedback = 0.12, .op2_level = 0.50, .op3_level = 0.44, .op4_level = 0.36, .op2_ratio = 0.39, .op3_ratio = 0.64, .op4_ratio = 0.76, .attack = 0.015, .decay = 0.38, .sustain = 0.30, .release = 0.35, .wave = 0.0 } },
};

fn presetCountImpl(state: *anyopaque) u8 {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "mono1")) return mono1_presets.len;
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "chorus")) return chorus1_presets.len;
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "fm1")) return fm1_presets.len;
    return 0;
}

fn presetNameImpl(state: *anyopaque, index: u8) [*:0]const u8 {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "mono1")) {
        return mono1_presets[@min(index, mono1_presets.len - 1)].name;
    }
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "chorus")) {
        return chorus1_presets[@min(index, chorus1_presets.len - 1)].name;
    }
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "fm1")) {
        return fm1_presets[@min(index, fm1_presets.len - 1)].name;
    }
    return "";
}

fn applyPresetImpl(state: *anyopaque, index: u8) void {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "mono1")) applyMono1Preset(self, index);
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "chorus")) applyChorus1Preset(self, index);
    if (std.mem.eql(u8, self.name_buf[0..self.name_len], "fm1")) applyFm1Preset(self, index);
}

fn applyMono1Preset(self: *FyMachine, index: u8) void {
    if (self.params_size < @sizeOf(Mono1Params)) return;
    const i = @min(index, mono1_presets.len - 1);
    const p: *align(1) Mono1Params = @ptrCast(&self.params[0]);
    p.* = mono1_presets[i].params;
    self.preset_index = @intCast(i);
}

fn applyChorus1Preset(self: *FyMachine, index: u8) void {
    if (self.params_size < @sizeOf(Chorus1Params)) return;
    const i = @min(index, chorus1_presets.len - 1);
    const p: *align(1) Chorus1Params = @ptrCast(&self.params[0]);
    p.* = chorus1_presets[i].params;
    self.preset_index = @intCast(i);
}

fn applyFm1Preset(self: *FyMachine, index: u8) void {
    if (self.params_size < @sizeOf(Fm1Params)) return;
    const i = @min(index, fm1_presets.len - 1);
    const p: *align(1) Fm1Params = @ptrCast(&self.params[0]);
    p.* = fm1_presets[i].params;
    self.preset_index = @intCast(i);
}

fn deinitImpl(state: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    self.host.deinit();
    alloc.destroy(self.host);
    alloc.destroy(self);
}
