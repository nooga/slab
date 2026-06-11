//! Generic raw-DSP2 fy machine adapter.
//!
//! The host owns scheduling, state storage, params storage, note/event
//! routing, and buffers; fy owns the raw DSP2 entrypoints. The machine is
//! fully described by the `manifest` word in its .fy file (vocabulary in
//! machines/lib/manifest.fy, walker in src/machine_desc.zig) — entry words,
//! sizes, controls, panel layout, and the optional block-prepare word. The
//! adapter is generic: adding a machine never requires a Zig wrapper.

const std = @import("std");
const Fy = @import("fy").Fy;
const c = @import("../c.zig");
const machine = @import("../machine.zig");
const fy_host_mod = @import("../fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const machine_desc = @import("../machine_desc.zig");
const presets_mod = @import("../presets.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const MAX_STATE = 1024;
const MAX_PARAMS = 1024;
const MAX_BLOCK = 4096;
const MAX_OPTS = machine_desc.MAX_OPTS;
const MAX_CONTROLS = machine_desc.MAX_CONTROLS;
const MAX_STRIPS = machine_desc.MAX_STRIPS;
const RawCaller = Fy.Dsp2RawRepeatedCaller;
const RawSlots = Fy.Dsp2RawRepeatedSlots;

pub const Mode = machine_desc.Mode;
const Control = machine_desc.Control;
const Display = machine_desc.Display;

pub const FyRawMachine = struct {
    host: *FyHost,
    desc: machine_desc.Desc,
    state_buf: [MAX_STATE]u8 align(8) = [_]u8{0} ** MAX_STATE,
    params_buf: [MAX_PARAMS]u8 align(8) = [_]u8{0} ** MAX_PARAMS,
    mono_buf: [MAX_BLOCK]f64 align(8) = [_]f64{0} ** MAX_BLOCK,
    in_l_buf: [MAX_BLOCK]f64 align(8) = [_]f64{0} ** MAX_BLOCK,
    in_r_buf: [MAX_BLOCK]f64 align(8) = [_]f64{0} ** MAX_BLOCK,
    out_l_buf: [MAX_BLOCK]f64 align(8) = [_]f64{0} ** MAX_BLOCK,
    out_r_buf: [MAX_BLOCK]f64 align(8) = [_]f64{0} ** MAX_BLOCK,
    prepare_slots: RawSlots = .{},
    note_on_slots: RawSlots = .{},
    note_off_slots: RawSlots = .{},
    render_slots: RawSlots = .{},
    effect_slots: RawSlots = .{},
    block_prepare_slots: RawSlots = .{},
    prepare_caller: ?RawCaller = null,
    note_on_caller: ?RawCaller = null,
    note_off_caller: ?RawCaller = null,
    render_caller: ?RawCaller = null,
    effect_caller: ?RawCaller = null,
    // Optional per-block dsp2 word (params sample-rate --): coefficient fills
    // that must not run per sample, e.g. the MS-20 svf profile region.
    block_prepare_caller: ?RawCaller = null,
    raw_control_bits: [MAX_CONTROLS]std.atomic.Value(u32) = undefined,
    panel_w: f32 = 128,
    failed: bool = false,
    preset_dir: [512]u8 = [_]u8{0} ** 512,
    preset_dir_len: usize = 0,
    presets: presets_mod.List = .{},

    pub fn create(alloc: std.mem.Allocator, path: []const u8) !*FyRawMachine {
        const self = try alloc.create(FyRawMachine);
        errdefer alloc.destroy(self);
        const host = try alloc.create(FyHost);
        errdefer alloc.destroy(host);
        host.* = FyHost.init(alloc);
        errdefer host.deinit();

        try host.compileFile(path);
        const desc = try machine_desc.read(host);
        if (desc.state_size > MAX_STATE or desc.params_size > MAX_PARAMS) return error.RawMachineStorageTooLarge;

        try validateWord(host, desc.renderWord());
        if (desc.prepareWord()) |word| try validateWord(host, word);
        if (desc.noteOnWord()) |word| try validateWord(host, word);
        if (desc.noteOffWord()) |word| try validateWord(host, word);
        if (desc.blockPrepareWord()) |word| try validateWord(host, word);

        self.* = .{
            .host = host,
            .desc = desc,
            .panel_w = desc.panel_w,
        };
        if (presets_mod.dirFromMachinePath(self.preset_dir[0..], path)) |dir| {
            self.preset_dir_len = dir.len;
            self.presets = presets_mod.scan(dir);
        }
        try self.compileCallers();
        self.initRawControls();
        return self;
    }

    pub fn machineInterface(self: *FyRawMachine) machine.Machine {
        return .{
            .name = self.desc.nameSlice(),
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .deinit = deinitImpl,
            .panel_w = self.panel_w,
            .host_titlebar = true,
            .note_labels = self.desc.noteLabels(),
            .preset_count = presetCountImpl,
            .preset_name = presetNameImpl,
            .apply_preset = applyPresetImpl,
            .save_preset = savePresetImpl,
        };
    }

    fn presetDir(self: *const FyRawMachine) []const u8 {
        return self.preset_dir[0..self.preset_dir_len];
    }

    fn statePtr(self: *FyRawMachine) usize {
        return @intFromPtr(&self.state_buf[0]);
    }

    fn paramsPtr(self: *FyRawMachine) usize {
        return @intFromPtr(&self.params_buf[0]);
    }

    fn compileCallers(self: *FyRawMachine) !void {
        if (self.desc.prepareWord()) |word| {
            self.prepare_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.prepare_slots,
                &.{ .ptr, .ptr, .f64 },
                false,
                false,
            );
        }
        if (self.desc.noteOnWord()) |word| {
            self.note_on_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.note_on_slots,
                &.{ .ptr, .ptr, .f64, .f64 },
                false,
                false,
            );
        }
        if (self.desc.noteOffWord()) |word| {
            self.note_off_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.note_off_slots,
                &.{ .ptr, .ptr },
                false,
                false,
            );
        }
        if (self.desc.blockPrepareWord()) |word| {
            self.block_prepare_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.block_prepare_slots,
                &.{ .ptr, .f64 },
                false,
                false,
            );
        }
        switch (self.desc.mode) {
            .voice_sample => {
                // A `call:` composition voice is invoked through the dedicated
                // composition caller (same out/state/params + auto-advance ABI).
                if (self.host.fy.isCompositionWord(self.desc.renderWord())) {
                    self.render_caller = try self.host.fy.compileDsp2CompositionCaller(
                        self.desc.renderWord(),
                        &self.render_slots,
                        true,
                    );
                } else {
                    self.render_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                        self.desc.renderWord(),
                        &self.render_slots,
                        &.{ .ptr, .ptr, .ptr },
                        true,
                        false,
                    );
                }
            },
            .effect_sample => {},
            .effect_block => {
                self.effect_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                    self.desc.renderWord(),
                    &self.effect_slots,
                    &.{ .ptr, .ptr, .ptr, .ptr },
                    true,
                    true,
                );
            },
        }
    }

    fn initRawControls(self: *FyRawMachine) void {
        var i: usize = 0;
        while (i < MAX_CONTROLS) : (i += 1) {
            const value: f32 = if (i < self.desc.control_count) blk: {
                const ctl = self.desc.controls[i];
                // switches store the selected index directly (not a 0..1 norm).
                break :blk if (ctl.kind == .switch_sel) @floatCast(ctl.default) else valueToNorm(ctl, ctl.default);
            } else 0;
            self.raw_control_bits[i] = std.atomic.Value(u32).init(@bitCast(value));
        }
        self.syncRawParams(48_000.0);
    }

    fn controlNorm(self: *const FyRawMachine, idx: usize) f32 {
        return @bitCast(self.raw_control_bits[idx].load(.monotonic));
    }

    fn setControlNorm(self: *FyRawMachine, idx: usize, value: f32) void {
        self.raw_control_bits[idx].store(@bitCast(std.math.clamp(value, 0.0, 1.0)), .monotonic);
    }

    // Unclamped store — switches keep the selected index here, not a 0..1 norm.
    fn setControlRaw(self: *FyRawMachine, idx: usize, value: f32) void {
        self.raw_control_bits[idx].store(@bitCast(value), .monotonic);
    }

    fn syncRawParams(self: *FyRawMachine, sample_rate: f64) void {
        const controls = self.desc.controls[0..self.desc.control_count];
        for (controls, 0..) |control, i| {
            switch (control.kind) {
                .direct_f64 => self.writeParamF64(control.offset, normToValue(control, self.controlNorm(i))),
                .switch_sel => self.writeParamF64(control.offset, control.option_values[switchIndex(control, self.controlNorm(i))]),
            }
        }

        for (self.desc.consts[0..self.desc.const_count]) |cnst| {
            self.writeParamF64(cnst.offset, cnst.value);
        }

        // Per-block coefficient fill in fy (params sample-rate --). Runs after
        // controls/consts land so the word reads fresh raw values.
        if (self.block_prepare_caller) |*bp| {
            const args = [_]Fy.Dsp2RawArg{ .{ .ptr = self.paramsPtr() }, .{ .f64 = sample_rate } };
            _ = bp.call(1, &args) catch {};
        }
    }

    fn writeParamF64(self: *FyRawMachine, offset: usize, value: f64) void {
        if (offset + @sizeOf(f64) > self.desc.params_size) return;
        const ptr: *align(8) f64 = @ptrCast(@alignCast(&self.params_buf[offset]));
        ptr.* = value;
    }

    fn readParamF64(self: *const FyRawMachine, offset: usize) f64 {
        if (offset + @sizeOf(f64) > self.desc.params_size) return 0;
        const ptr: *align(8) const f64 = @ptrCast(@alignCast(&self.params_buf[offset]));
        return ptr.*;
    }
};

fn presetCountImpl(state: *anyopaque) u8 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    return @intCast(@min(self.presets.count, 255));
}

fn presetNameImpl(state: *anyopaque, index: u8) [*:0]const u8 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (index >= self.presets.count) return "";
    return self.presets.names[index].z();
}

// Apply = parse `id|value` lines and store each matching control's value
// (clamped via valueToNorm; switches store the option index raw). Runs on
// the UI thread; the audio thread sees the atomics next block.
fn applyPresetImpl(state: *anyopaque, index: u8) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (index >= self.presets.count) return;
    var fbuf: [presets_mod.MAX_FILE]u8 = undefined;
    const data = presets_mod.readFileBuf(&fbuf, self.presetDir(), self.presets.names[index].slice()) orelse return;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const pair = presets_mod.parseLine(line) orelse continue;
        for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
            if (!std.mem.eql(u8, ctl.idSlice(), pair.id)) continue;
            switch (ctl.kind) {
                .switch_sel => {
                    const hi: f64 = @floatFromInt(@max(ctl.option_count, 1) - 1);
                    self.setControlRaw(i, @floatCast(std.math.clamp(pair.value, 0, hi)));
                },
                else => self.setControlNorm(i, valueToNorm(ctl.*, pair.value)),
            }
            break;
        }
    }
}

// Save the current control values as `user-N.preset` (first free N) and
// rescan so the new preset shows up immediately.
fn savePresetImpl(state: *anyopaque) ?u8 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (self.preset_dir_len == 0) return null;

    var name_buf: [presets_mod.MAX_NAME]u8 = undefined;
    var n: usize = 1;
    const name = blk: while (n < 100) : (n += 1) {
        const candidate = std.fmt.bufPrint(&name_buf, "user-{d}", .{n}) catch return null;
        if (!self.presets.contains(candidate)) break :blk candidate;
    } else return null;

    var content: [presets_mod.MAX_FILE]u8 = undefined;
    var used: usize = 0;
    {
        const line = std.fmt.bufPrint(content[used..], "# {s} preset\n", .{self.desc.nameSlice()}) catch return null;
        used += line.len;
    }
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        const value: f64 = switch (ctl.kind) {
            .switch_sel => @floatFromInt(switchIndex(ctl.*, self.controlNorm(i))),
            else => normToValue(ctl.*, self.controlNorm(i)),
        };
        const line = std.fmt.bufPrint(content[used..], "{s}|{d:.9}\n", .{ ctl.idSlice(), value }) catch return null;
        used += line.len;
    }
    if (!presets_mod.writeFile(self.presetDir(), name, content[0..used])) return null;

    self.presets = presets_mod.scan(self.presetDir());
    for (self.presets.names[0..self.presets.count], 0..) |*pn, i| {
        if (std.mem.eql(u8, pn.slice(), name)) return @intCast(i);
    }
    return null;
}

fn validateWord(host: *FyHost, word: []const u8) !void {
    // Composition (`call:`) words have no value-graph raw body to report —
    // they are validated by compileDsp2CompositionCaller instead.
    if (host.fy.isCompositionWord(word)) return;
    _ = try host.fy.reportDsp2RawWord(word);
}

fn normToValue(control: Control, norm: f32) f64 {
    const t = std.math.clamp(@as(f64, norm), 0.0, 1.0);
    return switch (control.curve) {
        .linear => control.min + (control.max - control.min) * t,
        .exp => control.min * @exp(@log(control.max / control.min) * t),
        .pow => control.min + (control.max - control.min) * t * t,
    };
}

fn valueToNorm(control: Control, value: f64) f32 {
    const v = std.math.clamp(value, control.min, control.max);
    const t = switch (control.curve) {
        .linear => (v - control.min) / (control.max - control.min),
        .exp => @log(v / control.min) / @log(control.max / control.min),
        .pow => @sqrt((v - control.min) / (control.max - control.min)),
    };
    return @floatCast(std.math.clamp(t, 0.0, 1.0));
}

fn switchIndex(control: Control, raw: f32) usize {
    if (control.option_count == 0) return 0;
    const r = @round(@as(f64, raw));
    const hi: f64 = @floatFromInt(control.option_count - 1);
    return @intFromFloat(std.math.clamp(r, 0, hi));
}

fn renderImpl(state: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const frames = @min(@as(usize, @intCast(ctx.block_size)), @min(l.len, @min(r.len, MAX_BLOCK)));
    if (frames == 0) return;

    fy_host_mod.lockCallbacks();
    defer fy_host_mod.unlockCallbacks();
    Fy.Builtins.fyPtr = @intFromPtr(&self.host.fy);

    self.syncRawParams(ctx.sample_rate);
    callPrepare(self, ctx.sample_rate) catch {
        self.failed = true;
        @memset(l[0..frames], 0);
        @memset(r[0..frames], 0);
        return;
    };

    switch (self.desc.mode) {
        .voice_sample => renderVoiceSample(self, ctx, l[0..frames], r[0..frames]) catch {
            self.failed = true;
            @memset(l[0..frames], 0);
            @memset(r[0..frames], 0);
        },
        .effect_sample => renderEffectSample(self, ctx, l[0..frames], r[0..frames]) catch {
            self.failed = true;
            @memset(l[0..frames], 0);
            @memset(r[0..frames], 0);
        },
        .effect_block => renderEffectBlock(self, ctx, l[0..frames], r[0..frames]) catch {
            self.failed = true;
            @memset(l[0..frames], 0);
            @memset(r[0..frames], 0);
        },
    }
}

fn callPrepare(self: *FyRawMachine, sample_rate: f64) !void {
    const caller = if (self.prepare_caller) |*c_| c_ else return;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = self.statePtr() },
        .{ .ptr = self.paramsPtr() },
        .{ .f64 = sample_rate },
    };
    _ = try caller.call(1, &args);
}

fn renderVoiceSample(self: *FyRawMachine, ctx: *const machine.MachineCtx, l: []f32, r: []f32) !void {
    @memset(self.mono_buf[0..l.len], 0);

    const events = if (ctx.note_in) |p| p[0..ctx.note_in_count] else &[_]machine.NoteEvent{};
    var cursor: usize = 0;
    var event_index: usize = 0;
    while (cursor < l.len) {
        const next_event_sample = if (event_index < events.len)
            @min(@as(usize, @intCast(events[event_index].sample_offset)), l.len)
        else
            l.len;

        if (next_event_sample > cursor) {
            try renderVoiceSegment(self, cursor, next_event_sample);
            cursor = next_event_sample;
        }

        while (event_index < events.len and @min(@as(usize, @intCast(events[event_index].sample_offset)), l.len) == cursor) : (event_index += 1) {
            try applyNoteEvent(self, events[event_index]);
        }
    }

    for (l, r, self.mono_buf[0..l.len]) |*sl, *sr, x| {
        const y: f32 = @floatCast(std.math.clamp(x, -1.0, 1.0));
        sl.* = y;
        sr.* = y;
    }
}

fn renderVoiceSegment(self: *FyRawMachine, start: usize, end: usize) !void {
    if (end <= start) return;
    const caller = if (self.render_caller) |*c_| c_ else return error.UnknownWord;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&self.mono_buf[start]) },
        .{ .ptr = self.statePtr() },
        .{ .ptr = self.paramsPtr() },
    };
    _ = try caller.call(@intCast(end - start), &args);
}

fn applyNoteEvent(self: *FyRawMachine, ev: machine.NoteEvent) !void {
    switch (ev.kind) {
        .note_on => {
            if (ev.velocity <= 0) {
                try callNoteOff(self);
            } else {
                // note-pitch machines (drums) address slots by raw MIDI pitch.
                const note_arg = if (self.desc.note_pitch) @as(f64, ev.pitch) else midiToHz(ev.pitch);
                try callNoteOn(self, note_arg, ev.velocity);
            }
        },
        .note_off, .reset => try callNoteOff(self),
        else => {},
    }
}

fn callNoteOn(self: *FyRawMachine, hz: f64, velocity: f64) !void {
    const caller = if (self.note_on_caller) |*c_| c_ else return;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = self.statePtr() },
        .{ .ptr = self.paramsPtr() },
        .{ .f64 = hz },
        .{ .f64 = velocity },
    };
    _ = try caller.call(1, &args);
}

fn callNoteOff(self: *FyRawMachine) !void {
    const caller = if (self.note_off_caller) |*c_| c_ else return;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = self.statePtr() },
        .{ .ptr = self.paramsPtr() },
    };
    _ = try caller.call(1, &args);
}

fn renderEffectSample(self: *FyRawMachine, ctx: *const machine.MachineCtx, l: []f32, r: []f32) !void {
    const in_l, const in_r = inputChannels(ctx);
    var out_sample: f64 = 0;
    var i: usize = 0;
    while (i < l.len) : (i += 1) {
        const xl: f64 = if (in_l) |p| p[i] else 0;
        const args_l = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out_sample) },
            .{ .ptr = self.statePtr() },
            .{ .ptr = self.paramsPtr() },
            .{ .f64 = xl },
        };
        _ = try self.host.fy.callDsp2RawRepeatedWithArgsNoResult(self.desc.renderWord(), 1, &args_l);
        l[i] = @floatCast(std.math.clamp(out_sample, -1.0, 1.0));

        const xr: f64 = if (in_r) |p| p[i] else xl;
        const args_r = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out_sample) },
            .{ .ptr = self.statePtr() },
            .{ .ptr = self.paramsPtr() },
            .{ .f64 = xr },
        };
        _ = try self.host.fy.callDsp2RawRepeatedWithArgsNoResult(self.desc.renderWord(), 1, &args_r);
        r[i] = @floatCast(std.math.clamp(out_sample, -1.0, 1.0));
    }
}

fn renderEffectBlock(self: *FyRawMachine, ctx: *const machine.MachineCtx, l: []f32, r: []f32) !void {
    const caller = if (self.effect_caller) |*c_| c_ else return error.UnknownWord;
    const in_l, const in_r = inputChannels(ctx);
    for (self.in_l_buf[0..l.len], 0..) |*dst, i| dst.* = if (in_l) |p| p[i] else 0;
    for (self.in_r_buf[0..r.len], 0..) |*dst, i| dst.* = if (in_r) |p| p[i] else self.in_l_buf[i];

    const args_l = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&self.out_l_buf[0]) },
        .{ .ptr = self.statePtr() },
        .{ .ptr = self.paramsPtr() },
        .{ .ptr = @intFromPtr(&self.in_l_buf[0]) },
    };
    _ = try caller.call(l.len, &args_l);

    const args_r = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&self.out_r_buf[0]) },
        .{ .ptr = self.statePtr() },
        .{ .ptr = self.paramsPtr() },
        .{ .ptr = @intFromPtr(&self.in_r_buf[0]) },
    };
    _ = try caller.call(r.len, &args_r);

    for (l, self.out_l_buf[0..l.len]) |*dst, sample| {
        dst.* = @floatCast(std.math.clamp(sample, -1.0, 1.0));
    }
    for (r, self.out_r_buf[0..r.len]) |*dst, sample| {
        dst.* = @floatCast(std.math.clamp(sample, -1.0, 1.0));
    }
}

fn inputChannels(ctx: *const machine.MachineCtx) struct { ?[*]const f32, ?[*]const f32 } {
    if (ctx.audio_in_count >= 2) {
        if (ctx.audio_in) |ports| return .{ ports[0], ports[1] };
    }
    return .{ null, null };
}

fn resetImpl(state: *anyopaque) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    @memset(self.state_buf[0..self.desc.state_size], 0);
    @memset(self.params_buf[0..self.desc.params_size], 0);
    self.failed = false;
}

fn deinitImpl(state: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    self.host.deinit();
    alloc.destroy(self.host);
    alloc.destroy(self);
}

// Generic machine panel body: beveled module strips laid out from the
// descriptor controls. The bay draws the title bar (host_titlebar = true), so
// `rect` here is the body below it. Control-less fixtures show an info readout.
fn drawPanelImpl(state: *anyopaque, rect: c.rl.Rectangle, mouse: widgets.Mouse) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (rect.width <= 0 or rect.height <= 0) return;

    c.rl.DrawRectangleRec(rect, theme.pane_bg);

    if (self.desc.control_count == 0) {
        drawFixtureInfo(self, rect);
        return;
    }
    drawControlStrips(self, rect, mouse);
}

fn drawFixtureInfo(self: *FyRawMachine, body: c.rl.Rectangle) void {
    const mode_text: [*:0]const u8 = switch (self.desc.mode) {
        .voice_sample => "raw voice/sample",
        .effect_sample => "raw effect/sample",
        .effect_block => "raw effect/block",
    };
    widgets.drawLabelF(mode_text, body.x + 5, body.y + 6, theme.fsTiny(), theme.text_dim);

    const detail: [*:0]const u8 = if (std.mem.eql(u8, self.desc.nameSlice(), "raw-osc"))
        "saw osc  note in"
    else if (std.mem.eql(u8, self.desc.nameSlice(), "raw-sat"))
        "rational tanh  drive 1.35"
    else if (std.mem.eql(u8, self.desc.nameSlice(), "raw-silence"))
        "zero output"
    else
        "dsp2 fixture";
    widgets.drawLabelF(detail, body.x + 5, body.y + 22, theme.fsTiny(), theme.text_fg);

    const status: [*:0]const u8 = if (self.failed) "status: failed" else "status: live";
    widgets.drawLabelF(status, body.x + 5, body.y + 38, theme.fsTiny(), if (self.failed) theme.accent_rec else theme.accent_play);
}

const StripView = struct {
    title: [*:0]const u8,
    module: []const u8,
    width: f32,
    cols: usize,
};

// Strips come from descriptor `strip` declarations if present, else are
// derived as one column per distinct module in control order.
fn collectStrips(self: *FyRawMachine, out: *[MAX_STRIPS]StripView) usize {
    if (self.desc.strip_count > 0) {
        for (self.desc.strips[0..self.desc.strip_count], 0..) |*s, i| {
            out[i] = .{ .title = s.moduleZ(), .module = s.moduleSlice(), .width = 1, .cols = s.cols };
        }
        return self.desc.strip_count;
    }
    var n: usize = 0;
    for (self.desc.controls[0..self.desc.control_count]) |*ctl| {
        const m = ctl.moduleSlice();
        var found = false;
        for (out[0..n]) |ex| {
            if (std.mem.eql(u8, ex.module, m)) {
                found = true;
                break;
            }
        }
        if (!found and n < MAX_STRIPS) {
            out[n] = .{ .title = ctl.moduleZ(), .module = m, .width = 1, .cols = 1 };
            n += 1;
        }
    }
    return n;
}

fn stripViewAt(self: *const FyRawMachine, idx: usize) StripView {
    const s = &self.desc.strips[idx];
    return .{ .title = s.moduleZ(), .module = s.moduleSlice(), .width = 1, .cols = s.cols };
}

fn controlNormByLabel(self: *const FyRawMachine, module: []const u8, label: []const u8) ?f32 {
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (std.mem.eql(u8, ctl.moduleSlice(), module) and
            std.mem.eql(u8, ctl.label[0..ctl.label_len], label))
            return self.controlNorm(i);
    }
    return null;
}

// Capacitor charge/discharge easing toward a target: fast then slow, used for
// every ADSR segment (matches the cap-discharge envelope). shape(0)=0, shape(1)=1.
fn capShape(t: f32) f32 {
    const k: f32 = 4.0;
    return (1.0 - @exp(-k * t)) / (1.0 - @exp(-k));
}

fn drawDisplay(self: *FyRawMachine, rect: c.rl.Rectangle, disp: *const Display) void {
    // One shared sunken-black field; comma-separated sources are drawn as small
    // labeled graphs side-by-side inside it (compact, no per-graph header).
    const field = widgets.displayField(rect);
    switch (disp.kind) {
        .adsr => {
            // Overlay every source curve in the same field, one pen each.
            const pens = [_]c.rl.Color{ theme.accent_hi, theme.accent_play, theme.accent_rec };
            var it = std.mem.splitScalar(u8, disp.sourceSlice(), ',');
            var idx: usize = 0;
            while (it.next()) |raw| : (idx += 1) {
                const src = std.mem.trim(u8, raw, " ");
                drawAdsrCurve(self, field, src, pens[idx % pens.len], idx);
            }
        },
    }
}

// Draw the A/D/S/R envelope shape (segment widths from the knob norms, a fixed
// sustain hold), reacting live to the source module's ATK/DEC/SUS/REL knobs.
fn drawAdsrCurve(self: *FyRawMachine, area: c.rl.Rectangle, source: []const u8, col: c.rl.Color, label_idx: usize) void {
    const atk = controlNormByLabel(self, source, "ATK") orelse 0.3;
    const dec = controlNormByLabel(self, source, "DEC") orelse 0.3;
    const sus = controlNormByLabel(self, source, "SUS") orelse 0.5;
    const rel = controlNormByLabel(self, source, "REL") orelse 0.3;

    const pad = theme.fine(2);
    const x0 = area.x + pad;
    const w = area.width - 2 * pad;
    const top = area.y + pad;
    const h = area.height - 2 * pad;
    if (w <= 1 or h <= 1) return;
    const base = top + h;

    const hold: f32 = 0.5;
    const wsum = atk + dec + hold + rel + 0.0001;
    const aw = w * atk / wsum;
    const dw = w * dec / wsum;
    const hw = w * hold / wsum;
    const rw = w * rel / wsum;

    const xa1 = x0 + aw;
    const xd1 = xa1 + dw;
    const xh1 = xd1 + hw;
    const xr1 = xh1 + rw;

    if (label_idx == 0) c.rl.DrawLineEx(.{ .x = x0, .y = base }, .{ .x = x0 + w, .y = base }, 1.0, theme.slab_edge);

    drawCapSeg(x0, 0.0, xa1, 1.0, base, h, col);
    drawCapSeg(xa1, 1.0, xd1, sus, base, h, col);
    c.rl.DrawLineEx(.{ .x = xd1, .y = base - sus * h }, .{ .x = xh1, .y = base - sus * h }, 1.5, col);
    drawCapSeg(xh1, sus, xr1, 0.0, base, h, col);

    // inline label: first token of the source, in the curve's colour, offset so
    // overlaid sources' labels sit side by side.
    var buf: [12:0]u8 = [_:0]u8{0} ** 12;
    const tok_end = std.mem.indexOfScalar(u8, source, ' ') orelse source.len;
    const tlen = @min(tok_end, 11);
    @memcpy(buf[0..tlen], source[0..tlen]);
    buf[tlen] = 0;
    widgets.drawLabelF(@ptrCast(&buf[0]), area.x + 1 + @as(f32, @floatFromInt(label_idx)) * theme.size(22), top - 1, theme.fsTiny(), col);
}

fn drawCapSeg(xa: f32, la: f32, xb: f32, lb: f32, base: f32, h: f32, col: c.rl.Color) void {
    const N: usize = 14;
    var prev = c.rl.Vector2{ .x = xa, .y = base - la * h };
    var i: usize = 1;
    while (i <= N) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N));
        const l = la + (lb - la) * capShape(t);
        const p = c.rl.Vector2{ .x = xa + (xb - xa) * t, .y = base - l * h };
        c.rl.DrawLineEx(prev, p, 1.5, col);
        prev = p;
    }
}

// Weighted box layout (docs/15): split body height across rows, each row's
// width across cells, each cell's height across its stacked strips. Last
// element in each axis takes the remainder so the block fills exactly.
fn drawLayoutTree(self: *FyRawMachine, body: c.rl.Rectangle, mouse: widgets.Mouse) void {
    var total_rw: f32 = 0;
    for (self.desc.rows[0..self.desc.row_count]) |*r| total_rw += r.weight;
    if (total_rw <= 0) return;
    var y = body.y;
    for (self.desc.rows[0..self.desc.row_count], 0..) |*r, ri| {
        const rh = if (ri + 1 == self.desc.row_count) (body.y + body.height - y) else body.height * r.weight / total_rw;
        var total_cw: f32 = 0;
        for (r.cells[0..r.cell_count]) |*cc| total_cw += cc.weight;
        if (total_cw > 0) {
            var x = body.x;
            for (r.cells[0..r.cell_count], 0..) |*cc, ci| {
                const cw = if (ci + 1 == r.cell_count) (body.x + body.width - x) else body.width * cc.weight / total_cw;
                var total_sw: f32 = 0;
                for (cc.items[0..cc.item_count]) |it| total_sw += it.weight;
                if (total_sw > 0) {
                    var sy = y;
                    for (cc.items[0..cc.item_count], 0..) |it, ii| {
                        const sh = if (ii + 1 == cc.item_count) (y + rh - sy) else rh * it.weight / total_sw;
                        const item_rect = widgets.rect(x, sy, cw, sh);
                        if (it.is_display) {
                            drawDisplay(self, item_rect, &self.desc.displays[it.index]);
                        } else {
                            drawStrip(self, item_rect, stripViewAt(self, it.index), mouse);
                        }
                        sy += sh;
                    }
                }
                x += cw;
            }
        }
        y += rh;
    }
}

fn drawControlStrips(self: *FyRawMachine, body: c.rl.Rectangle, mouse: widgets.Mouse) void {
    if (self.desc.row_count > 0) {
        drawLayoutTree(self, body, mouse);
        return;
    }
    var strips: [MAX_STRIPS]StripView = undefined;
    const n = collectStrips(self, &strips);
    if (n == 0) return;

    var total: f32 = 0;
    for (strips[0..n]) |s| total += s.width;
    if (total <= 0) return;
    // Strips sit flush and fill the body exactly: each gets a fraction of the
    // width proportional to its declared width, and the last takes the
    // remainder. This avoids per-strip theme.size rounding so the strip block
    // lines up precisely with the host title bar (no overhang).
    var x = body.x;
    for (strips[0..n], 0..) |s, i| {
        const w = if (i + 1 == n) (body.x + body.width - x) else body.width * s.width / total;
        if (w <= 0) break;
        drawStrip(self, widgets.rect(x, body.y, w, body.height), s, mouse);
        x += w;
    }
}

fn drawStrip(self: *FyRawMachine, rect_: c.rl.Rectangle, view: StripView, mouse: widgets.Mouse) void {
    const inner = widgets.strip(rect_, view.title);

    var count: usize = 0;
    for (self.desc.controls[0..self.desc.control_count]) |*ctl| {
        if (std.mem.eql(u8, ctl.moduleSlice(), view.module)) count += 1;
    }
    if (count == 0) return;

    const cols = view.cols;
    const rows = (count + cols - 1) / cols;
    const cell_w = inner.width / @as(f32, @floatFromInt(cols));
    const cell_h = @max(theme.size(44), inner.height / @as(f32, @floatFromInt(rows)));
    var local_i: usize = 0;
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, gi| {
        if (!std.mem.eql(u8, ctl.moduleSlice(), view.module)) continue;
        const col = local_i % cols;
        const row = local_i / cols;
        const kr = widgets.rect(
            inner.x + @as(f32, @floatFromInt(col)) * cell_w,
            inner.y + @as(f32, @floatFromInt(row)) * cell_h,
            cell_w,
            @min(cell_h, inner.y + inner.height - (inner.y + @as(f32, @floatFromInt(row)) * cell_h)),
        );
        switch (ctl.kind) {
            .switch_sel => {
                var labels: [MAX_OPTS][*:0]const u8 = undefined;
                for (0..ctl.option_count) |oi| labels[oi] = ctl.optionLabelZ(oi);
                var idx: u8 = @intCast(switchIndex(ctl.*, self.controlNorm(gi)));
                if (widgets.knobStepped(kr, ctl.labelZ(), labels[0..ctl.option_count], &idx, mouse)) {
                    self.setControlRaw(gi, @floatFromInt(idx));
                }
            },
            else => {
                var value = self.controlNorm(gi);
                var vbuf: [16:0]u8 = undefined;
                const display = formatControlValue(&vbuf, normToValue(ctl.*, value));
                if (widgets.knobEx(kr, ctl.labelZ(), &value, mouse, display)) {
                    self.setControlNorm(gi, value);
                }
            },
        }
        local_i += 1;
    }
}

// Compact real-value readout for knobs: 3 significant-ish digits, k-suffix
// above 1000 (so 1.2k, 182, 50.3, 0.055 all fit the tiny font).
fn formatControlValue(buf: *[16:0]u8, v: f64) [*:0]const u8 {
    const av = @abs(v);
    const s = if (av >= 10_000.0)
        std.fmt.bufPrintZ(buf, "{d:.1}k", .{v / 1000.0})
    else if (av >= 1000.0)
        std.fmt.bufPrintZ(buf, "{d:.2}k", .{v / 1000.0})
    else if (av >= 100.0)
        std.fmt.bufPrintZ(buf, "{d:.0}", .{v})
    else if (av >= 10.0)
        std.fmt.bufPrintZ(buf, "{d:.1}", .{v})
    else if (av >= 1.0)
        std.fmt.bufPrintZ(buf, "{d:.2}", .{v})
    else
        std.fmt.bufPrintZ(buf, "{d:.3}", .{v});
    return (s catch return "?").ptr;
}

fn midiToHz(pitch: f32) f64 {
    return 440.0 * @exp(@log(2.0) * ((@as(f64, pitch) - 69.0) / 12.0));
}

const testing = std.testing;

fn testRender(mach: machine.Machine, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    mach.render(mach.state, ctx, l, r);
}

test "raw DSP2 silence fixture renders zeros through generic adapter" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/raw_fixtures/silence.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 32;
    var l = [_]f32{1} ** 32;
    var r = [_]f32{1} ** 32;
    testRender(mach, &ctx, &l, &r);

    for (l, r) |sl, sr| {
        try testing.expectEqual(@as(f32, 0), sl);
        try testing.expectEqual(@as(f32, 0), sr);
    }
}

test "raw DSP2 oscillator fixture responds to note events" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/raw_fixtures/oscillator.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 45, .velocity = 0.8 },
        .{ .sample_offset = 32, .kind = .note_off, .channel = 0, .note_id = 1, .pitch = 45, .velocity = 0 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 64;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 64;
    var r = [_]f32{0} ** 64;
    testRender(mach, &ctx, &l, &r);

    var pre_off_energy: f64 = 0;
    var post_off_energy: f64 = 0;
    for (l[0..32]) |sample| pre_off_energy += @abs(sample);
    for (l[32..64]) |sample| post_off_energy += @abs(sample);
    try testing.expect(pre_off_energy > 0.01);
    try testing.expect(post_off_energy < 0.000001);
    for (l, r) |sl, sr| {
        try testing.expect(std.math.isFinite(sl));
        try testing.expectEqual(sl, sr);
    }
}

test "raw DSP2 saturator fixture processes audio input through generic adapter" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/raw_fixtures/saturator.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var in_l = [_]f32{0.75} ** 32;
    var in_r = [_]f32{-0.75} ** 32;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 32;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l = [_]f32{0} ** 32;
    var r = [_]f32{0} ** 32;
    testRender(mach, &ctx, &l, &r);

    try testing.expect(l[0] > in_l[0]);
    try testing.expect(r[0] < in_r[0]);
    try testing.expect(@abs(l[0]) <= 1.0);
    try testing.expect(@abs(r[0]) <= 1.0);
    for (l, r) |sl, sr| {
        try testing.expect(std.math.isFinite(sl));
        try testing.expect(std.math.isFinite(sr));
    }
}

test "raw DSP2 MS-20 fixture renders a finite note through generic adapter" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/ms20/ms20.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 45, .velocity = 0.9 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 512;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 512;
    var r = [_]f32{0} ** 512;
    testRender(mach, &ctx, &l, &r);

    var peak: f32 = 0;
    for (l, r) |sl, sr| {
        try testing.expect(std.math.isFinite(sl));
        try testing.expect(std.math.isFinite(sr));
        try testing.expectEqual(sl, sr);
        peak = @max(peak, @abs(sl));
    }
    try testing.expect(peak > 0.001);
    try testing.expect(peak <= 1.0);
}

test "raw DSP2 MS-20 fills the svf profile region in fy (no Zig derive)" {
    const cutoff_off: usize = 32;
    const env_peak_off: usize = 112;
    const svf_drive: usize = 192;
    const svf_resonance: usize = 200;
    const svf_fb_gain: usize = 208;
    const svf_fb_dc: usize = 240;
    const svf_out_dc: usize = 248;

    const inst = try FyRawMachine.create(testing.allocator, "machines/ms20/ms20.fy");
    defer inst.machineInterface().deinit.?(inst, testing.allocator);

    inst.syncRawParams(48_000);

    // Controls land at their declared offsets as raw values (defaults).
    try testing.expect(inst.readParamF64(cutoff_off) > 60.0);
    try testing.expect(inst.readParamF64(env_peak_off) > 1000.0);

    // Profile region computed in fy by ms20-block-prepare (k-svf-coeffs-*).
    try testing.expectApproxEqAbs(@as(f64, 1.90), inst.readParamF64(svf_drive), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 5.4), inst.readParamF64(svf_fb_gain), 1e-6);
    try testing.expect(inst.readParamF64(svf_resonance) > 0.0);
    try testing.expect(inst.readParamF64(svf_fb_dc) > 0.0);
    try testing.expect(inst.readParamF64(svf_fb_dc) < 0.01);
    try testing.expect(inst.readParamF64(svf_out_dc) > 0.0);
    try testing.expect(inst.readParamF64(svf_out_dc) < inst.readParamF64(svf_fb_dc));
}

test "raw machine presets: scan factory, save round-trip, apply restores" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/drum2/drum2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Factory presets present and sorted.
    try testing.expect(inst.presets.count >= 2);
    try testing.expect(inst.presets.contains("808-boom"));
    try testing.expect(inst.presets.contains("909-punch"));

    // Move a knob, save, perturb, apply — value comes back.
    inst.setControlNorm(0, 0.25);
    const before = normToValue(inst.desc.controls[0], inst.controlNorm(0));
    const idx = savePresetImpl(inst) orelse return error.PresetSaveFailed;
    inst.setControlNorm(0, 0.9);
    applyPresetImpl(inst, idx);
    const after = normToValue(inst.desc.controls[0], inst.controlNorm(0));
    try testing.expectApproxEqAbs(before, after, 0.001);

    // Clean up the user-N file the save created.
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.preset", .{ inst.presetDir(), inst.presets.names[idx].slice() });
    fy_host_mod.deleteFilePosix(path);
}
