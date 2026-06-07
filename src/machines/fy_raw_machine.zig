//! Generic raw-DSP2 fy machine adapter.
//!
//! This is the testbed for the next machine ABI: the host owns scheduling,
//! state storage, params storage, note/event routing, and buffers; fy owns
//! the raw DSP2 entrypoints. The adapter is intentionally generic so adding
//! a new machine does not require a Zig wrapper.

const std = @import("std");
const Fy = @import("fy").Fy;
const c = @import("../c.zig");
const machine = @import("../machine.zig");
const fy_host_mod = @import("../fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

extern fn close(fd: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn fstat(fd: c_int, sb: *std.c.Stat) c_int;
const O_RDONLY: c_int = 0;

const MAX_STATE = 1024;
const MAX_PARAMS = 1024;
const MAX_NAME = 64;
const MAX_BLOCK = 4096;
const MAX_RAW_CONTROLS = 24;
const MAX_RAW_DERIVES = 8;
const MAX_RAW_CONSTS = 16;
const MAX_CONTROL_TEXT = 24;
const RawCaller = Fy.Dsp2RawRepeatedCaller;
const RawSlots = Fy.Dsp2RawRepeatedSlots;

const RawParamCurve = enum {
    linear,
    exp,
};

const RawParamKind = enum {
    direct_f64,
    value,
};

const RawControl = struct {
    module: [MAX_CONTROL_TEXT:0]u8 = [_:0]u8{0} ** MAX_CONTROL_TEXT,
    module_len: usize = 0,
    label: [MAX_CONTROL_TEXT:0]u8 = [_:0]u8{0} ** MAX_CONTROL_TEXT,
    label_len: usize = 0,
    id: [MAX_CONTROL_TEXT:0]u8 = [_:0]u8{0} ** MAX_CONTROL_TEXT,
    id_len: usize = 0,
    kind: RawParamKind,
    offset: usize = 0,
    min: f64,
    max: f64,
    default: f64,
    curve: RawParamCurve = .linear,

    fn moduleZ(self: *const RawControl) [*:0]const u8 {
        return @ptrCast(&self.module[0]);
    }

    fn labelZ(self: *const RawControl) [*:0]const u8 {
        return @ptrCast(&self.label[0]);
    }

    fn idSlice(self: *const RawControl) []const u8 {
        return self.id[0..self.id_len];
    }
};

const RawDeriveKind = enum {
    ms20_lpf,
};

const RawDerive = struct {
    kind: RawDeriveKind,
    a: [MAX_CONTROL_TEXT:0]u8 = [_:0]u8{0} ** MAX_CONTROL_TEXT,
    a_len: usize = 0,
    b: [MAX_CONTROL_TEXT:0]u8 = [_:0]u8{0} ** MAX_CONTROL_TEXT,
    b_len: usize = 0,
    c: [MAX_CONTROL_TEXT:0]u8 = [_:0]u8{0} ** MAX_CONTROL_TEXT,
    c_len: usize = 0,
    out0_offset: usize = 0,
    out1_offset: usize = 0,
    out2_offset: usize = 0,

    fn aSlice(self: *const RawDerive) []const u8 {
        return self.a[0..self.a_len];
    }

    fn bSlice(self: *const RawDerive) []const u8 {
        return self.b[0..self.b_len];
    }

    fn cSlice(self: *const RawDerive) []const u8 {
        return self.c[0..self.c_len];
    }
};

const RawConstF64 = struct {
    offset: usize,
    value: f64,
};

pub const Mode = enum {
    voice_sample,
    effect_sample,
    effect_block,
};

pub const Spec = struct {
    name: []const u8,
    path: []const u8,
    mode: Mode,
    render_word: []const u8,
    prepare_word: ?[]const u8 = null,
    note_on_word: ?[]const u8 = null,
    note_off_word: ?[]const u8 = null,
    state_size: usize,
    params_size: usize,
    panel_w: f32 = 128,
    manifest_path: ?[]const u8 = null,
};

pub fn fixtureSpec(name: []const u8) ?Spec {
    if (std.mem.eql(u8, name, "raw-silence")) return .{
        .name = "raw-silence",
        .path = "machines/raw_fixtures/silence.fy",
        .mode = .voice_sample,
        .render_word = "raw-silence-render",
        .state_size = 8,
        .params_size = 8,
    };
    if (std.mem.eql(u8, name, "raw-osc")) return .{
        .name = "raw-osc",
        .path = "machines/raw_fixtures/oscillator.fy",
        .mode = .voice_sample,
        .render_word = "raw-osc-render",
        .prepare_word = "raw-osc-prepare",
        .note_on_word = "raw-osc-note-on",
        .note_off_word = "raw-osc-note-off",
        .state_size = 8,
        .params_size = 24,
    };
    if (std.mem.eql(u8, name, "raw-sat")) return .{
        .name = "raw-sat",
        .path = "machines/raw_fixtures/saturator.fy",
        .mode = .effect_block,
        .render_word = "raw-sat-render",
        .prepare_word = "raw-sat-prepare",
        .state_size = 8,
        .params_size = 8,
    };
    if (std.mem.eql(u8, name, "raw-ms20")) return .{
        .name = "raw-ms20",
        .path = "kernels/06-voices/ms20_voice_probe.fy",
        .mode = .voice_sample,
        .render_word = "k-ms20-voice-sample",
        .prepare_word = "ms20-voice-prepare",
        .note_on_word = "ms20-voice-note-on",
        .note_off_word = "ms20-voice-note-off",
        .state_size = 64,
        .params_size = 256,
        .panel_w = 680,
        .manifest_path = "machines/raw_ms20/raw-ms20.manifest",
    };
    return null;
}

pub const FyRawMachine = struct {
    host: *FyHost,
    spec: Spec,
    name_buf: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: usize = 0,
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
    prepare_caller: ?RawCaller = null,
    note_on_caller: ?RawCaller = null,
    note_off_caller: ?RawCaller = null,
    render_caller: ?RawCaller = null,
    effect_caller: ?RawCaller = null,
    // raw-ms20 g-wet svf: host fills the SvfParams profile region per block by
    // calling these fy coeff words (replaces the old Zig coefficient derive).
    svf_dc_slots: RawSlots = .{},
    svf_profile_slots: RawSlots = .{},
    svf_dc_caller: ?RawCaller = null,
    svf_profile_caller: ?RawCaller = null,
    svf_profile_offset: usize = 0,
    raw_control_bits: [MAX_RAW_CONTROLS]std.atomic.Value(u32) = undefined,
    raw_controls: [MAX_RAW_CONTROLS]RawControl = undefined,
    raw_control_count: usize = 0,
    raw_derives: [MAX_RAW_DERIVES]RawDerive = undefined,
    raw_derive_count: usize = 0,
    raw_consts: [MAX_RAW_CONSTS]RawConstF64 = undefined,
    raw_const_count: usize = 0,
    panel_w: f32 = 128,
    failed: bool = false,

    pub fn create(alloc: std.mem.Allocator, spec: Spec) !*FyRawMachine {
        if (spec.state_size > MAX_STATE or spec.params_size > MAX_PARAMS) return error.RawMachineStorageTooLarge;

        const self = try alloc.create(FyRawMachine);
        errdefer alloc.destroy(self);
        const host = try alloc.create(FyHost);
        errdefer alloc.destroy(host);
        host.* = FyHost.init(alloc);
        errdefer host.deinit();

        try host.compileFile(spec.path);
        try validateWord(host, spec.render_word);
        if (spec.prepare_word) |word| try validateWord(host, word);
        if (spec.note_on_word) |word| try validateWord(host, word);
        if (spec.note_off_word) |word| try validateWord(host, word);

        self.* = .{
            .host = host,
            .spec = spec,
            .name_buf = [_]u8{0} ** MAX_NAME,
            .name_len = @min(spec.name.len, MAX_NAME),
            .panel_w = spec.panel_w,
        };
        @memcpy(self.name_buf[0..self.name_len], spec.name[0..self.name_len]);
        try self.initRawControls(alloc);
        try self.compileCallers();
        return self;
    }

    pub fn machineInterface(self: *FyRawMachine) machine.Machine {
        return .{
            .name = self.name_buf[0..self.name_len],
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .deinit = deinitImpl,
            .panel_w = self.panel_w,
        };
    }

    fn statePtr(self: *FyRawMachine) usize {
        return @intFromPtr(&self.state_buf[0]);
    }

    fn paramsPtr(self: *FyRawMachine) usize {
        return @intFromPtr(&self.params_buf[0]);
    }

    fn compileCallers(self: *FyRawMachine) !void {
        if (self.spec.prepare_word) |word| {
            self.prepare_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.prepare_slots,
                &.{ .ptr, .ptr, .f64 },
                false,
                false,
            );
        }
        if (self.spec.note_on_word) |word| {
            self.note_on_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.note_on_slots,
                &.{ .ptr, .ptr, .f64, .f64 },
                false,
                false,
            );
        }
        if (self.spec.note_off_word) |word| {
            self.note_off_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.note_off_slots,
                &.{ .ptr, .ptr },
                false,
                false,
            );
        }
        switch (self.spec.mode) {
            .voice_sample => {
                self.render_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                    self.spec.render_word,
                    &self.render_slots,
                    &.{ .ptr, .ptr, .ptr },
                    true,
                    false,
                );
            },
            .effect_sample => {},
            .effect_block => {
                self.effect_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                    self.spec.render_word,
                    &self.effect_slots,
                    &.{ .ptr, .ptr, .ptr, .ptr },
                    true,
                    true,
                );
            },
        }

        // raw-ms20: fill the SvfParams profile region (offset 176) per block
        // via fy coeff words instead of a Zig derive.
        if (std.mem.eql(u8, self.spec.name, "raw-ms20")) {
            self.svf_profile_offset = 176;
            self.svf_dc_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                "k-svf-coeffs-dc",
                &self.svf_dc_slots,
                &.{ .ptr, .f64 },
                false,
                false,
            );
            self.svf_profile_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                "k-svf-coeffs-profile",
                &self.svf_profile_slots,
                &.{ .ptr, .f64 },
                false,
                false,
            );
        }
    }

    fn initRawControls(self: *FyRawMachine, alloc: std.mem.Allocator) !void {
        self.raw_control_count = 0;
        self.raw_derive_count = 0;
        self.raw_const_count = 0;
        if (self.spec.manifest_path) |path| try self.loadRawControlsFromManifest(alloc, path);
        var i: usize = 0;
        while (i < MAX_RAW_CONTROLS) : (i += 1) {
            const value: f32 = if (i < self.raw_control_count) valueToNorm(self.raw_controls[i], self.raw_controls[i].default) else 0;
            self.raw_control_bits[i] = std.atomic.Value(u32).init(@bitCast(value));
        }
        self.syncRawParams(48_000.0);
    }

    fn loadRawControlsFromManifest(self: *FyRawMachine, alloc: std.mem.Allocator, path: []const u8) !void {
        const data = try readFilePosix(alloc, path);
        defer alloc.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '|');
            const tag = fields.next() orelse continue;
            if (std.mem.eql(u8, tag, "control")) {
                if (self.raw_control_count >= MAX_RAW_CONTROLS) return error.RawControlLimitExceeded;
                const control = try parseControlFields(&fields);
                self.raw_controls[self.raw_control_count] = control;
                self.raw_control_count += 1;
            } else if (std.mem.eql(u8, tag, "derive")) {
                if (self.raw_derive_count >= MAX_RAW_DERIVES) return error.RawDeriveLimitExceeded;
                const derive = try parseDeriveFields(&fields);
                self.raw_derives[self.raw_derive_count] = derive;
                self.raw_derive_count += 1;
            } else if (std.mem.eql(u8, tag, "const-f64")) {
                if (self.raw_const_count >= MAX_RAW_CONSTS) return error.RawConstLimitExceeded;
                const cnst = try parseConstF64Fields(&fields);
                self.raw_consts[self.raw_const_count] = cnst;
                self.raw_const_count += 1;
            }
        }
    }

    fn controlNorm(self: *const FyRawMachine, idx: usize) f32 {
        return @bitCast(self.raw_control_bits[idx].load(.monotonic));
    }

    fn setControlNorm(self: *FyRawMachine, idx: usize, value: f32) void {
        self.raw_control_bits[idx].store(@bitCast(std.math.clamp(value, 0.0, 1.0)), .monotonic);
    }

    fn syncRawParams(self: *FyRawMachine, sample_rate: f64) void {
        const controls = self.raw_controls[0..self.raw_control_count];
        for (controls, 0..) |control, i| {
            const value = normToValue(control, self.controlNorm(i));
            switch (control.kind) {
                .direct_f64 => self.writeParamF64(control.offset, value),
                .value => {},
            }
        }

        for (self.raw_consts[0..self.raw_const_count]) |cnst| {
            self.writeParamF64(cnst.offset, cnst.value);
        }

        for (self.raw_derives[0..self.raw_derive_count]) |derive| {
            switch (derive.kind) {
                .ms20_lpf => {
                    const cutoff_hz = self.controlValueById(derive.aSlice()) orelse continue;
                    const resonance = self.controlValueById(derive.bSlice()) orelse continue;
                    const env_peak_hz = self.controlValueById(derive.cSlice()) orelse continue;
                    const base = ms20Coeffs(cutoff_hz, resonance, sample_rate);
                    const peak = ms20Coeffs(@max(env_peak_hz, cutoff_hz), resonance, sample_rate);
                    self.writeParamF64(derive.out0_offset, base.g);
                    self.writeParamF64(derive.out1_offset, base.damping);
                    self.writeParamF64(derive.out2_offset, @max(0.0, peak.g - base.g));
                },
            }
        }

        // raw-ms20: fill the SvfParams profile region in fy (drive/resonance/
        // fb_gain/clips/leak + the two DC-block coeffs). g and damping stay
        // per-sample in the voice; nothing here computes filter coefficients.
        if (self.svf_profile_caller) |*pc| {
            const profile_ptr = self.paramsPtr() + self.svf_profile_offset;
            const os_rate = sample_rate * 4.0;
            const resonance = self.controlValueById("resonance") orelse 1.0;
            if (self.svf_dc_caller) |*dc| {
                const dc_args = [_]Fy.Dsp2RawArg{ .{ .ptr = profile_ptr }, .{ .f64 = os_rate } };
                _ = dc.call(1, &dc_args) catch {};
            }
            const prof_args = [_]Fy.Dsp2RawArg{ .{ .ptr = profile_ptr }, .{ .f64 = resonance } };
            _ = pc.call(1, &prof_args) catch {};
        }
    }

    fn controlValueById(self: *const FyRawMachine, id: []const u8) ?f64 {
        for (self.raw_controls[0..self.raw_control_count], 0..) |control, i| {
            if (std.mem.eql(u8, control.idSlice(), id)) return normToValue(control, self.controlNorm(i));
        }
        return null;
    }

    fn writeParamF64(self: *FyRawMachine, offset: usize, value: f64) void {
        if (offset + @sizeOf(f64) > self.spec.params_size) return;
        const ptr: *align(8) f64 = @ptrCast(@alignCast(&self.params_buf[offset]));
        ptr.* = value;
    }

    fn readParamF64(self: *const FyRawMachine, offset: usize) f64 {
        if (offset + @sizeOf(f64) > self.spec.params_size) return 0;
        const ptr: *align(8) const f64 = @ptrCast(@alignCast(&self.params_buf[offset]));
        return ptr.*;
    }
};

fn validateWord(host: *FyHost, word: []const u8) !void {
    _ = try host.fy.reportDsp2RawWord(word);
}

fn normToValue(control: RawControl, norm: f32) f64 {
    const t = std.math.clamp(@as(f64, norm), 0.0, 1.0);
    return switch (control.curve) {
        .linear => control.min + (control.max - control.min) * t,
        .exp => control.min * @exp(@log(control.max / control.min) * t),
    };
}

fn valueToNorm(control: RawControl, value: f64) f32 {
    const v = std.math.clamp(value, control.min, control.max);
    const t = switch (control.curve) {
        .linear => (v - control.min) / (control.max - control.min),
        .exp => @log(v / control.min) / @log(control.max / control.min),
    };
    return @floatCast(std.math.clamp(t, 0.0, 1.0));
}

const Ms20Coeffs = struct {
    g: f64,
    damping: f64,
};

fn ms20Coeffs(cutoff_hz: f64, resonance: f64, sample_rate: f64) Ms20Coeffs {
    const os_rate = sample_rate * 4.0;
    const fc = std.math.clamp(cutoff_hz, 20.0, sample_rate * 0.42);
    const g = @tan(std.math.pi * fc / os_rate);
    const damping = @max(0.015, 1.2 / (1.0 + resonance * 8.0));
    return .{ .g = g, .damping = damping };
}

fn parseControlFields(fields: *std.mem.SplitIterator(u8, .scalar)) !RawControl {
    var control = RawControl{
        .kind = .direct_f64,
        .min = 0,
        .max = 1,
        .default = 0,
    };

    const module = fields.next() orelse return error.InvalidRawManifest;
    const label = fields.next() orelse return error.InvalidRawManifest;
    const id = fields.next() orelse return error.InvalidRawManifest;
    const kind = fields.next() orelse return error.InvalidRawManifest;
    const offset = fields.next() orelse return error.InvalidRawManifest;
    const min = fields.next() orelse return error.InvalidRawManifest;
    const max = fields.next() orelse return error.InvalidRawManifest;
    const default = fields.next() orelse return error.InvalidRawManifest;
    const curve = fields.next() orelse "linear";

    control.module_len = try copyZ(&control.module, module);
    control.label_len = try copyZ(&control.label, label);
    control.id_len = try copyZ(&control.id, id);
    control.kind = parseParamKind(kind) orelse return error.InvalidRawManifest;
    control.offset = if (std.mem.eql(u8, offset, "-")) 0 else try std.fmt.parseInt(usize, offset, 10);
    control.min = try std.fmt.parseFloat(f64, min);
    control.max = try std.fmt.parseFloat(f64, max);
    control.default = try std.fmt.parseFloat(f64, default);
    control.curve = parseParamCurve(curve) orelse return error.InvalidRawManifest;
    return control;
}

fn parseParamKind(raw: []const u8) ?RawParamKind {
    if (std.mem.eql(u8, raw, "direct-f64")) return .direct_f64;
    if (std.mem.eql(u8, raw, "value")) return .value;
    return null;
}

fn parseDeriveFields(fields: *std.mem.SplitIterator(u8, .scalar)) !RawDerive {
    var derive = RawDerive{
        .kind = .ms20_lpf,
    };

    const kind = fields.next() orelse return error.InvalidRawManifest;
    const a = fields.next() orelse return error.InvalidRawManifest;
    const b = fields.next() orelse return error.InvalidRawManifest;
    const c_ = fields.next() orelse return error.InvalidRawManifest;
    const out0 = fields.next() orelse return error.InvalidRawManifest;
    const out1 = fields.next() orelse return error.InvalidRawManifest;
    const out2 = fields.next() orelse return error.InvalidRawManifest;

    derive.kind = parseDeriveKind(kind) orelse return error.InvalidRawManifest;
    derive.a_len = try copyZ(&derive.a, a);
    derive.b_len = try copyZ(&derive.b, b);
    derive.c_len = try copyZ(&derive.c, c_);
    derive.out0_offset = try std.fmt.parseInt(usize, out0, 10);
    derive.out1_offset = try std.fmt.parseInt(usize, out1, 10);
    derive.out2_offset = try std.fmt.parseInt(usize, out2, 10);
    return derive;
}

fn parseDeriveKind(raw: []const u8) ?RawDeriveKind {
    if (std.mem.eql(u8, raw, "ms20-lpf")) return .ms20_lpf;
    return null;
}

fn parseConstF64Fields(fields: *std.mem.SplitIterator(u8, .scalar)) !RawConstF64 {
    const offset = fields.next() orelse return error.InvalidRawManifest;
    const value = fields.next() orelse return error.InvalidRawManifest;
    return .{
        .offset = try std.fmt.parseInt(usize, offset, 10),
        .value = try std.fmt.parseFloat(f64, value),
    };
}

fn parseParamCurve(raw: []const u8) ?RawParamCurve {
    if (std.mem.eql(u8, raw, "linear")) return .linear;
    if (std.mem.eql(u8, raw, "exp")) return .exp;
    return null;
}

fn copyZ(dest: *[MAX_CONTROL_TEXT:0]u8, src: []const u8) !usize {
    if (src.len >= MAX_CONTROL_TEXT) return error.RawManifestStringTooLong;
    @memset(dest, 0);
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return src.len;
}

fn readFilePosix(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const fd = open(z, O_RDONLY);
    if (fd < 0) return error.FileOpenFailed;
    defer _ = close(fd);
    var st: std.c.Stat = undefined;
    if (fstat(fd, &st) != 0) return error.StatFailed;
    const size: usize = @intCast(st.size);
    if (size > 64 * 1024) return error.FileTooLarge;
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    var done: usize = 0;
    while (done < size) {
        const n = try std.posix.read(@intCast(fd), buf[done..]);
        if (n == 0) break;
        done += n;
    }
    if (done != size) return error.ReadFailed;
    return buf;
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

    switch (self.spec.mode) {
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
    _ = self.spec.prepare_word orelse return;
    const caller = if (self.prepare_caller) |*c_| c_ else return error.UnknownWord;
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
                try callNoteOn(self, midiToHz(ev.pitch), ev.velocity);
            }
        },
        .note_off, .reset => try callNoteOff(self),
        else => {},
    }
}

fn callNoteOn(self: *FyRawMachine, hz: f64, velocity: f64) !void {
    _ = self.spec.note_on_word orelse return;
    const caller = if (self.note_on_caller) |*c_| c_ else return error.UnknownWord;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = self.statePtr() },
        .{ .ptr = self.paramsPtr() },
        .{ .f64 = hz },
        .{ .f64 = velocity },
    };
    _ = try caller.call(1, &args);
}

fn callNoteOff(self: *FyRawMachine) !void {
    _ = self.spec.note_off_word orelse return;
    const caller = if (self.note_off_caller) |*c_| c_ else return error.UnknownWord;
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
        _ = try self.host.fy.callDsp2RawRepeatedWithArgsNoResult(self.spec.render_word, 1, &args_l);
        l[i] = @floatCast(std.math.clamp(out_sample, -1.0, 1.0));

        const xr: f64 = if (in_r) |p| p[i] else xl;
        const args_r = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out_sample) },
            .{ .ptr = self.statePtr() },
            .{ .ptr = self.paramsPtr() },
            .{ .f64 = xr },
        };
        _ = try self.host.fy.callDsp2RawRepeatedWithArgsNoResult(self.spec.render_word, 1, &args_r);
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
    @memset(self.state_buf[0..self.spec.state_size], 0);
    @memset(self.params_buf[0..self.spec.params_size], 0);
    self.failed = false;
}

fn deinitImpl(state: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    self.host.deinit();
    alloc.destroy(self.host);
    alloc.destroy(self);
}

fn drawPanelImpl(state: *anyopaque, rect: c.rl.Rectangle, mouse: widgets.Mouse) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (rect.width <= 0 or rect.height <= 0) return;

    if (std.mem.eql(u8, self.spec.name, "raw-ms20")) {
        drawMs20Panel(self, rect, mouse);
        return;
    }

    var title: [MAX_NAME + 1:0]u8 = [_:0]u8{0} ** (MAX_NAME + 1);
    @memcpy(title[0..self.name_len], self.name_buf[0..self.name_len]);
    title[self.name_len] = 0;

    const header_h = @min(rect.height, theme.paneHeaderH());
    widgets.bevelRaised(widgets.rect(rect.x, rect.y, rect.width, header_h), theme.slab_fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF(@ptrCast(&title[0]), rect.x + 4, rect.y + 1, theme.fsTiny(), theme.text_fg);

    if (rect.height <= header_h) return;
    const body = widgets.rect(rect.x, rect.y + header_h, rect.width, rect.height - header_h);
    c.rl.DrawRectangleRec(body, theme.pane_alt);

    const mode_text: [*:0]const u8 = switch (self.spec.mode) {
        .voice_sample => "raw voice/sample",
        .effect_sample => "raw effect/sample",
        .effect_block => "raw effect/block",
    };
    widgets.drawLabelF(mode_text, body.x + 5, body.y + 6, theme.fsTiny(), theme.text_dim);

    const detail: [*:0]const u8 = if (std.mem.eql(u8, self.spec.name, "raw-osc"))
        "saw osc  note in"
    else if (std.mem.eql(u8, self.spec.name, "raw-sat"))
        "rational tanh  drive 1.35"
    else if (std.mem.eql(u8, self.spec.name, "raw-ms20"))
        "2 osc  ms20 lpf  adsr"
    else if (std.mem.eql(u8, self.spec.name, "raw-silence"))
        "zero output"
    else
        "dsp2 fixture";
    widgets.drawLabelF(detail, body.x + 5, body.y + 22, theme.fsTiny(), theme.text_fg);

    const status: [*:0]const u8 = if (self.failed) "status: failed" else "status: live";
    widgets.drawLabelF(status, body.x + 5, body.y + 38, theme.fsTiny(), if (self.failed) theme.accent_rec else theme.accent_play);
}

fn drawMs20Panel(self: *FyRawMachine, rect: c.rl.Rectangle, mouse: widgets.Mouse) void {
    const header_h = @min(rect.height, theme.paneHeaderH());
    widgets.bevelRaised(widgets.rect(rect.x, rect.y, rect.width, header_h), theme.slab_fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("RAW-MS20", rect.x + 4, rect.y + 1, theme.fsTiny(), theme.text_fg);
    if (rect.height <= header_h) return;

    const body = widgets.rect(rect.x, rect.y + header_h, rect.width, rect.height - header_h);
    c.rl.DrawRectangleRec(body, theme.pane_bg);

    const modules = [_][*:0]const u8{ "VCO", "LPF", "VCA", "AMP ENV", "FLT ENV" };
    const widths = [_]f32{ 58, 176, 58, 188, 188 };
    var total_base: f32 = 0;
    for (widths) |w| total_base += w;
    const scale = @min(1.0, body.width / theme.size(total_base));
    const gap: f32 = 1;
    var x = body.x;

    for (modules, widths) |module_name, base_w| {
        const module_w = @min(theme.size(base_w) * scale, body.x + body.width - x);
        if (module_w <= 0) break;
        const mr = widgets.rect(x, body.y, module_w, body.height);
        drawMs20Module(self, mr, module_name, mouse);
        x += module_w + gap;
        if (x >= body.x + body.width) break;
    }
}

fn drawMs20Module(self: *FyRawMachine, rect: c.rl.Rectangle, module_name: [*:0]const u8, mouse: widgets.Mouse) void {
    c.rl.DrawRectangleRec(rect, theme.pane_alt);
    c.rl.DrawRectangleLinesEx(rect, 1, theme.slab_edge);
    widgets.drawLabelF(module_name, rect.x + 4, rect.y + 3, theme.fsTiny(), theme.text_dim);

    const top = rect.y + theme.size(15);
    const controls = self.raw_controls[0..self.raw_control_count];
    const count = countModuleControls(controls, module_name);
    if (count == 0) return;

    const cols: usize = if (rect.width >= theme.size(92) and count > 1) 2 else 1;
    const rows = (count + cols - 1) / cols;
    const cell_w = rect.width / @as(f32, @floatFromInt(cols));
    const cell_h = @max(theme.size(48), (rect.y + rect.height - top) / @as(f32, @floatFromInt(rows)));
    var local_i: usize = 0;
    for (controls, 0..) |control, global_i| {
        if (!std.mem.eql(u8, control.module[0..control.module_len], std.mem.span(module_name))) continue;
        const col = local_i % cols;
        const row = local_i / cols;
        const kr = widgets.rect(
            rect.x + @as(f32, @floatFromInt(col)) * cell_w,
            top + @as(f32, @floatFromInt(row)) * cell_h,
            cell_w,
            @min(cell_h, rect.y + rect.height - (top + @as(f32, @floatFromInt(row)) * cell_h)),
        );
        var value = self.controlNorm(global_i);
        if (widgets.knob(kr, control.labelZ(), &value, mouse)) {
            self.setControlNorm(global_i, value);
        }
        local_i += 1;
    }
}

fn countModuleControls(controls: []const RawControl, module_name: [*:0]const u8) usize {
    var count: usize = 0;
    for (controls) |control| {
        if (std.mem.eql(u8, control.module[0..control.module_len], std.mem.span(module_name))) count += 1;
    }
    return count;
}

fn midiToHz(pitch: f32) f64 {
    return 440.0 * @exp(@log(2.0) * ((@as(f64, pitch) - 69.0) / 12.0));
}

const testing = std.testing;

fn testRender(mach: machine.Machine, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    mach.render(mach.state, ctx, l, r);
}

test "raw DSP2 silence fixture renders zeros through generic adapter" {
    const spec = fixtureSpec("raw-silence").?;
    const inst = try FyRawMachine.create(testing.allocator, spec);
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
    const spec = fixtureSpec("raw-osc").?;
    const inst = try FyRawMachine.create(testing.allocator, spec);
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
    const spec = fixtureSpec("raw-sat").?;
    const inst = try FyRawMachine.create(testing.allocator, spec);
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
    const spec = fixtureSpec("raw-ms20").?;
    const inst = try FyRawMachine.create(testing.allocator, spec);
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

    const spec = fixtureSpec("raw-ms20").?;
    const inst = try FyRawMachine.create(testing.allocator, spec);
    defer inst.machineInterface().deinit.?(inst, testing.allocator);

    inst.syncRawParams(48_000);

    // Controls land at their declared offsets as raw values (defaults).
    try testing.expect(inst.readParamF64(cutoff_off) > 60.0);
    try testing.expect(inst.readParamF64(env_peak_off) > 1000.0);

    // Profile region computed in fy by k-svf-coeffs-profile / -dc.
    try testing.expectApproxEqAbs(@as(f64, 1.90), inst.readParamF64(svf_drive), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 5.4), inst.readParamF64(svf_fb_gain), 1e-6);
    try testing.expect(inst.readParamF64(svf_resonance) > 0.0);
    try testing.expect(inst.readParamF64(svf_fb_dc) > 0.0);
    try testing.expect(inst.readParamF64(svf_fb_dc) < 0.01);
    try testing.expect(inst.readParamF64(svf_out_dc) > 0.0);
    try testing.expect(inst.readParamF64(svf_out_dc) < inst.readParamF64(svf_fb_dc));
}
