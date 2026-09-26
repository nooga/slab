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
const dx7_algorithms = @import("../dx7_algorithms.zig");
const presets_mod = @import("../presets.zig");
const wav = @import("../wav.zig");
const waveform = @import("../waveform.zig");
const native_dialog = @import("../native_dialog.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const MAX_STATE = 1024;
const MAX_PARAMS = 1024;
// State regions: polyphonic voice machines get one per voice, effect
// machines use two (L/R). Region index is injected at channel_cell.
const MAX_REGIONS = 8;
// Host-allocated buffers are sized in seconds at the highest sample rate we
// run at; kernels read the element count back from state and clamp, so a
// lower device rate just means extra headroom.
const BUFFER_SR = 96_000.0;
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
    // Per-region state: effect machines run L through region 0 and R through
    // region 1 so per-channel state never cross-talks; polyphonic voice
    // machines get one region per voice.
    state_buf: [MAX_REGIONS * MAX_STATE]u8 align(8) = [_]u8{0} ** (MAX_REGIONS * MAX_STATE),
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
    // Active panel tab for paged machines (index into desc.pages). Per
    // instance, UI-thread only.
    ui_tab: usize = 0,
    // Generic derived-params hook (params derive-data --): a machine-declared
    // dsp2 word run each block to compute params from controls + opaque data.
    derive_slots: RawSlots = .{},
    derive_caller: ?RawCaller = null,
    preset_dir: [512]u8 = [_]u8{0} ** 512,
    preset_dir_len: usize = 0,
    presets: presets_mod.List = .{},
    current_preset_idx: i32 = -1,
    // Host-allocated audio buffers (manifest `buffer` requests), one per
    // channel. Base pointer + element count are injected into each channel's
    // state at the request's introspected offsets.
    buffer_mem: [machine_desc.MAX_BUFFERS][2][]f64 = undefined,
    // Read-only audio assets loaded from disk at create (manifest `asset`),
    // shared across voices via params.
    asset_mem: [machine_desc.MAX_ASSETS]wav.Sample = [_]wav.Sample{.{ .data = &.{}, .sample_rate = 0 }} ** machine_desc.MAX_ASSETS,
    // A valid silent target for assets that failed to load, so a kernel's
    // clamped read hits real zeroed memory instead of an empty slice's ptr.
    asset_silence: [2]f64 align(8) = .{ 0, 0 },
    // Peak pyramid per asset for oscillogram drawing (UI thread only).
    asset_cache: [machine_desc.MAX_ASSETS]waveform.PeakCache = [_]waveform.PeakCache{.{}} ** machine_desc.MAX_ASSETS,
    // Display name (basename) of each asset's currently loaded file.
    asset_label: [machine_desc.MAX_ASSETS][96]u8 = undefined,
    asset_label_len: [machine_desc.MAX_ASSETS]usize = [_]usize{0} ** machine_desc.MAX_ASSETS,
    // Stored so runtime sample loads can (re)allocate without a passed alloc.
    alloc: std.mem.Allocator = undefined,
    // Stereo-linked detector trace (manifest `detector-cell`): filled per
    // block with max(|L|,|R|), read by both channels for linked dynamics.
    det_buf: [MAX_BLOCK]f64 align(8) = [_]f64{0} ** MAX_BLOCK,
    // Voice allocator (voice machines with desc.voices > 1). Voices are
    // never freed — like the Juno-106, every voice always renders; note-on
    // takes the oldest un-gated voice, else steals the oldest gated one.
    // note_id is -1 throughout the sequencer, so matching is by pitch.
    voice_pitch: [MAX_REGIONS]f32 = [_]f32{-1} ** MAX_REGIONS,
    voice_gate: [MAX_REGIONS]bool = [_]bool{false} ** MAX_REGIONS,
    voice_age: [MAX_REGIONS]u64 = [_]u64{0} ** MAX_REGIONS,
    age_counter: u64 = 0,
    // Per-frame meter ballistics (meter display kind). One per machine; a
    // limiter has a single meter. Updated on the UI thread from live state.
    meter_ui: MeterUi = .{},

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
        if (desc.voices > MAX_REGIONS) return error.RawMachineTooManyVoices;
        // Host buffers are allocated per channel (2); polyphonic machines
        // would need per-voice rings — not wired yet.
        if (desc.voices > 1 and desc.buffer_count > 0) return error.RawMachineVoicesWithBuffers;

        try validateWord(host, desc.renderWord());
        if (desc.prepareWord()) |word| try validateWord(host, word);
        if (desc.noteOnWord()) |word| try validateWord(host, word);
        if (desc.noteOffWord()) |word| try validateWord(host, word);
        if (desc.blockPrepareWord()) |word| try validateWord(host, word);

        self.* = .{
            .host = host,
            .desc = desc,
            .panel_w = desc.panel_w,
            .alloc = alloc,
        };
        if (presets_mod.dirFromMachinePath(self.preset_dir[0..], path)) |dir| {
            self.preset_dir_len = dir.len;
            self.presets = presets_mod.scan(dir);
        }
        try self.allocBuffers(alloc);
        errdefer self.freeBuffersUpTo(alloc, self.desc.buffer_count);
        try self.loadAssets(alloc, path);
        errdefer self.freeAssets(alloc);
        try self.compileCallers();
        self.initRawControls(); // runs block-prepare, which reads asset SR
        return self;
    }

    // Load each declared asset (path relative to the machine's directory)
    // into f64 mono and inject ptr/len/native-sr into params. Missing files
    // are non-fatal: the asset stays empty (len 0) and the voice is silent
    // until something is loaded at runtime (Phase B).
    fn loadAssets(self: *FyRawMachine, alloc: std.mem.Allocator, machine_path: []const u8) !void {
        const dir = std.fs.path.dirname(machine_path) orelse ".";
        for (self.desc.assets[0..self.desc.asset_count], 0..) |*req, ai| {
            var pbuf: [768]u8 = undefined;
            const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, req.fileSlice() }) catch continue;
            self.asset_mem[ai] = wav.load(alloc, full) catch wav.Sample{ .data = &.{}, .sample_rate = 0 };
            self.asset_cache[ai].build(alloc, self.asset_mem[ai].data) catch {};
            self.setAssetLabel(ai, req.fileSlice());
        }
        self.injectAssets();
    }

    fn setAssetLabel(self: *FyRawMachine, ai: usize, path: []const u8) void {
        const base = std.fs.path.basename(path);
        const n = @min(base.len, self.asset_label[ai].len);
        @memcpy(self.asset_label[ai][0..n], base[0..n]);
        self.asset_label_len[ai] = n;
    }

    fn freeAssets(self: *FyRawMachine, alloc: std.mem.Allocator) void {
        for (self.asset_mem[0..self.desc.asset_count], 0..) |*s, ai| {
            if (s.data.len > 0) alloc.free(s.data);
            s.* = .{ .data = &.{}, .sample_rate = 0 };
            self.asset_cache[ai].deinit(alloc);
        }
    }

    // Swap an asset's audio at runtime (UI thread). lockCallbacks fences the
    // render path so the audio thread can't be mid-read of the old buffer
    // while we free it and repoint params. The peak cache is UI-only and
    // needs no fence. On failure the old sample is kept.
    fn loadAssetRuntime(self: *FyRawMachine, ai: usize, path: []const u8) bool {
        if (ai >= self.desc.asset_count) return false;
        var loaded = wav.load(self.alloc, path) catch return false;
        var new_cache = waveform.PeakCache{};
        new_cache.build(self.alloc, loaded.data) catch {
            loaded.deinit(self.alloc);
            return false;
        };

        fy_host_mod.lockCallbacks();
        const old = self.asset_mem[ai];
        self.asset_mem[ai] = loaded;
        self.injectAssets();
        fy_host_mod.unlockCallbacks();

        if (old.data.len > 0) self.alloc.free(old.data);
        self.asset_cache[ai].deinit(self.alloc);
        self.asset_cache[ai] = new_cache;
        self.setAssetLabel(ai, path);
        return true;
    }

    fn assetIndexByName(self: *const FyRawMachine, name: []const u8) ?usize {
        for (self.desc.assets[0..self.desc.asset_count], 0..) |*a, i| {
            if (std.mem.eql(u8, a.nameSlice(), name)) return i;
        }
        return null;
    }

    // Asset pointer/length/native-SR live in params (shared, read-only).
    // syncRawParams never touches these offsets, so they persist across
    // blocks; only reset (which memsets params) needs a re-inject.
    fn injectAssets(self: *FyRawMachine) void {
        for (self.desc.assets[0..self.desc.asset_count], 0..) |*req, ai| {
            const s = self.asset_mem[ai];
            const ptr: usize = if (s.data.len > 0) @intFromPtr(s.data.ptr) else @intFromPtr(&self.asset_silence[0]);
            self.writeParamUsize(req.ptr_offset, ptr);
            self.writeParamF64(req.len_offset, @floatFromInt(s.data.len));
            self.writeParamF64(req.sr_offset, if (s.sample_rate > 0) s.sample_rate else 48_000);
        }
    }

    fn writeParamUsize(self: *FyRawMachine, offset: usize, value: usize) void {
        if (offset + @sizeOf(usize) > self.desc.params_size) return;
        const ptr: *align(8) usize = @ptrCast(@alignCast(&self.params_buf[offset]));
        ptr.* = value;
    }

    fn allocBuffers(self: *FyRawMachine, alloc: std.mem.Allocator) !void {
        var done: usize = 0;
        errdefer self.freeBuffersUpTo(alloc, done);
        for (self.desc.buffers[0..self.desc.buffer_count], 0..) |*req, bi| {
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(req.seconds * BUFFER_SR))));
            const mem_l = try alloc.alloc(f64, n);
            errdefer alloc.free(mem_l);
            const mem_r = try alloc.alloc(f64, n);
            @memset(mem_l, 0);
            @memset(mem_r, 0);
            self.buffer_mem[bi] = .{ mem_l, mem_r };
            done = bi + 1;
        }
        self.injectBuffers();
    }

    fn freeBuffersUpTo(self: *FyRawMachine, alloc: std.mem.Allocator, count: usize) void {
        for (self.buffer_mem[0..count]) |pair| {
            for (pair) |mem| alloc.free(mem);
        }
    }

    // Write each buffer's base pointer + element count into both channel
    // states, plus the channel index if requested. Must rerun after any
    // state memset (reset).
    fn injectBuffers(self: *FyRawMachine) void {
        for (self.desc.buffers[0..self.desc.buffer_count], 0..) |*req, bi| {
            for (0..2) |ch| {
                const mem = self.buffer_mem[bi][ch];
                self.writeStateUsize(ch, req.ptr_offset, @intFromPtr(mem.ptr));
                self.writeStateF64(ch, req.len_offset, @floatFromInt(mem.len));
            }
        }
        if (self.desc.channel_cell) |off| {
            // Region index: channel for effects, voice index for synths
            // (per-voice detune spread reads this).
            for (0..self.regionCount()) |reg| self.writeStateF64(reg, off, @floatFromInt(reg));
        }
        if (self.desc.detector_cell) |off| {
            for (0..2) |ch| self.writeStateUsize(ch, off, @intFromPtr(&self.det_buf[0]));
        }
    }

    fn writeStateUsize(self: *FyRawMachine, ch: usize, offset: usize, value: usize) void {
        if (offset + @sizeOf(usize) > self.desc.state_size) return;
        const ptr: *align(8) usize = @ptrCast(@alignCast(&self.state_buf[ch * MAX_STATE + offset]));
        ptr.* = value;
    }

    fn writeStateF64(self: *FyRawMachine, ch: usize, offset: usize, value: f64) void {
        if (offset + @sizeOf(f64) > self.desc.state_size) return;
        const ptr: *align(8) f64 = @ptrCast(@alignCast(&self.state_buf[ch * MAX_STATE + offset]));
        ptr.* = value;
    }

    fn readStateF64(self: *const FyRawMachine, ch: usize, offset: usize) f64 {
        if (offset + @sizeOf(f64) > self.desc.state_size) return 0;
        const ptr: *align(8) const f64 = @ptrCast(@alignCast(&self.state_buf[ch * MAX_STATE + offset]));
        return ptr.*;
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
            .save_preset_named = savePresetNamedImpl,
            .rename_preset = renamePresetImpl,
            .current_preset = currentPresetImpl,
            .write_params_json = writeParamsJsonImpl,
            .set_param = setParamImpl,
        };
    }

    fn presetDir(self: *const FyRawMachine) []const u8 {
        return self.preset_dir[0..self.preset_dir_len];
    }

    /// Stable machine id = the machine's directory name, derived from the
    /// preset dir (`machines/ms20/presets` → `ms20`). Embedded in preset
    /// JSON for hub forward-compat; the loader ignores it.
    fn machineId(self: *const FyRawMachine) []const u8 {
        const dir = std.fs.path.dirname(self.presetDir()) orelse return "";
        return std.fs.path.basename(dir);
    }

    fn statePtr(self: *FyRawMachine) usize {
        return @intFromPtr(&self.state_buf[0]);
    }

    fn statePtrCh(self: *FyRawMachine, ch: usize) usize {
        return @intFromPtr(&self.state_buf[ch * MAX_STATE]);
    }

    fn regionCount(self: *const FyRawMachine) usize {
        return if (self.desc.mode == .voice_sample) @max(self.desc.voices, 1) else 2;
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
                0,
                false,);
        }
        if (self.desc.noteOnWord()) |word| {
            self.note_on_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.note_on_slots,
                &.{ .ptr, .ptr, .f64, .f64 },
                0,
                false,);
        }
        if (self.desc.noteOffWord()) |word| {
            self.note_off_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.note_off_slots,
                &.{ .ptr, .ptr },
                0,
                false,);
        }
        if (self.desc.blockPrepareWord()) |word| {
            self.block_prepare_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                word,
                &self.block_prepare_slots,
                &.{ .ptr, .f64 },
                0,
                false,);
        }
        if (self.desc.deriveWord()) |word| {
            // A staged derive (`call:` composition, e.g. the EQ's per-band
            // coefficient fill) goes through the composition caller; both
            // args are pointers and nothing auto-advances.
            if (self.host.fy.isCompositionWord(word)) {
                self.derive_caller = try self.host.fy.compileDsp2CompositionCaller(
                    word,
                    &self.derive_slots,
                    0,
                    false,);
            } else {
                self.derive_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                    word,
                    &self.derive_slots,
                    &.{ .ptr, .ptr },
                    0,
                    false,);
            }
        }
        switch (self.desc.mode) {
            .voice_sample => {
                // A `call:` composition voice is invoked through the dedicated
                // composition caller (same out/state/params + auto-advance ABI).
                if (self.host.fy.isCompositionWord(self.desc.renderWord())) {
                    self.render_caller = try self.host.fy.compileDsp2CompositionCaller(
                        self.desc.renderWord(),
                        &self.render_slots,
                        8,
                        false,);
                } else {
                    self.render_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                        self.desc.renderWord(),
                        &self.render_slots,
                        &.{ .ptr, .ptr, .ptr },
                        8,
                        false,);
                }
            },
            .effect_sample => {},
            .effect_block => {
                // Staged effects (`call:` compositions, e.g. the reverb tank)
                // go through the composition caller; both advance out + in.
                if (self.host.fy.isCompositionWord(self.desc.renderWord())) {
                    self.effect_caller = try self.host.fy.compileDsp2CompositionCaller(
                        self.desc.renderWord(),
                        &self.effect_slots,
                        8,
                        true,);
                } else {
                    self.effect_caller = try self.host.fy.compileDsp2RawRepeatedCaller(
                        self.desc.renderWord(),
                        &self.effect_slots,
                        &.{ .ptr, .ptr, .ptr, .ptr },
                        8,
                        true,);
                }
            },
        }
    }

    fn initRawControls(self: *FyRawMachine) void {
        var i: usize = 0;
        while (i < MAX_CONTROLS) : (i += 1) {
            const value: f32 = if (i < self.desc.control_count) blk: {
                const ctl = self.desc.controls[i];
                // switches store the selected index and int-steps the raw
                // integer directly (not a 0..1 norm).
                break :blk switch (ctl.kind) {
                    .switch_sel, .int_range => @floatCast(ctl.default),
                    .direct_f64 => valueToNorm(ctl, ctl.default),
                };
            } else 0;
            self.raw_control_bits[i] = std.atomic.Value(u32).init(@bitCast(value));
        }
        self.syncRawParams(48_000.0, 120.0); // no transport yet at init; sane default
    }

    fn controlNorm(self: *const FyRawMachine, idx: usize) f32 {
        return @bitCast(self.raw_control_bits[idx].load(.monotonic));
    }

    pub fn setControlNorm(self: *FyRawMachine, idx: usize, value: f32) void {
        self.raw_control_bits[idx].store(@bitCast(std.math.clamp(value, 0.0, 1.0)), .monotonic);
    }

    // Unclamped store — switches keep the selected index here, not a 0..1 norm.
    fn setControlRaw(self: *FyRawMachine, idx: usize, value: f32) void {
        self.raw_control_bits[idx].store(@bitCast(value), .monotonic);
    }

    fn syncRawParams(self: *FyRawMachine, sample_rate: f64, tempo_bpm: f64) void {
        const controls = self.desc.controls[0..self.desc.control_count];
        for (controls, 0..) |control, i| {
            switch (control.kind) {
                .direct_f64 => self.writeParamF64(control.offset, normToValue(control, self.controlNorm(i))),
                .switch_sel => self.writeParamF64(control.offset, control.option_values[switchIndex(control, self.controlNorm(i))]),
                .int_range => self.writeParamF64(control.offset, intRangeValue(control, self.controlNorm(i))),
            }
        }

        for (self.desc.consts[0..self.desc.const_count]) |cnst| {
            self.writeParamF64(cnst.offset, cnst.value);
        }

        // Machine-declared derive hook (params derive-data --): compute derived
        // params from the fresh control values, e.g. FM-86 expands ALGO into the
        // voice routing from its own fy table. Generic — the frame has no
        // machine-specific knowledge. Runs before block-prepare; both only touch
        // params, no ordering dependency.
        if (self.derive_caller) |*dv| {
            const args = [_]Fy.Dsp2RawArg{ .{ .ptr = self.paramsPtr() }, .{ .ptr = self.desc.derive_data } };
            _ = dv.call(1, &args) catch {};
        }

        // Host-written tempo cell: deposit ctx.tempo_bpm into params so a
        // tempo-syncing block-prepare can read it (e.g. delay2 SYNC mode).
        if (self.desc.tempo_cell) |off| self.writeParamF64(off, tempo_bpm);

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
fn currentPresetImpl(state: *anyopaque) i32 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    return self.current_preset_idx;
}

// Store one real-valued control by its stable id. Shared by preset apply,
// the host param-set path (project load), and anything that restores a
// machine's settings from an id→value map. Switches clamp to the option
// index; direct controls go through valueToNorm.
fn applyControlValue(self: *FyRawMachine, id: []const u8, value: f64) void {
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (!std.mem.eql(u8, ctl.idSlice(), id)) continue;
        switch (ctl.kind) {
            .switch_sel => {
                const hi: f64 = @floatFromInt(@max(ctl.option_count, 1) - 1);
                self.setControlRaw(i, @floatCast(std.math.clamp(value, 0, hi)));
            },
            .int_range => self.setControlRaw(i, @floatCast(intRangeValue(ctl.*, @floatCast(value)))),
            .direct_f64 => self.setControlNorm(i, valueToNorm(ctl.*, value)),
        }
        return;
    }
}

fn applyPresetImpl(state: *anyopaque, index: u8) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (index >= self.presets.count) return;
    self.current_preset_idx = index;
    var fbuf: [presets_mod.MAX_FILE]u8 = undefined;
    const data = presets_mod.readFileBuf(&fbuf, self.presetDir(), self.presets.names[index].slice()) orelse return;

    var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const params = parsed.value.object.get("params") orelse return;
    if (params != .object) return;
    var it = params.object.iterator();
    while (it.next()) |kv| applyControlValue(self, kv.key_ptr.*, jsonF64(kv.value_ptr.*));
}

fn jsonF64(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

// Host param-set (project load): apply one id→value pair. Same real-value
// convention as presets.
fn setParamImpl(state: *anyopaque, id: []const u8, value: f64) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    applyControlValue(self, id, value);
}

// Dump current control values as a JSON object {"id": realValue, ...} into
// `out`. Real values match the preset convention (Hz/sec/option index), so
// presets and embedded project settings share one representation.
fn writeParamsJsonImpl(state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    try out.append(alloc, '{');
    // Control ids are [a-z0-9-] (no JSON-escaping needed); values are finite.
    var buf: [96]u8 = undefined;
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        const value: f64 = switch (ctl.kind) {
            .switch_sel => @floatFromInt(switchIndex(ctl.*, self.controlNorm(i))),
            .int_range => intRangeValue(ctl.*, self.controlNorm(i)),
            .direct_f64 => normToValue(ctl.*, self.controlNorm(i)),
        };
        const sep: []const u8 = if (i > 0) "," else "";
        const frag = std.fmt.bufPrint(&buf, "{s}\"{s}\":{d}", .{ sep, ctl.idSlice(), value }) catch continue;
        try out.appendSlice(alloc, frag);
    }
    try out.append(alloc, '}');
}

// Serialize the current control values to a JSON preset body:
// {"schema":1,"machine":"<id>","params":{"id":value,...}}.
// Control ids are [a-z0-9-] so no JSON escaping is needed.
fn buildPresetContent(self: *FyRawMachine, content: []u8) ?usize {
    var used: usize = 0;
    {
        const head = std.fmt.bufPrint(content[used..], "{{\"schema\":1,\"machine\":\"{s}\",\"params\":{{", .{self.machineId()}) catch return null;
        used += head.len;
    }
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        const value: f64 = switch (ctl.kind) {
            .switch_sel => @floatFromInt(switchIndex(ctl.*, self.controlNorm(i))),
            .int_range => intRangeValue(ctl.*, self.controlNorm(i)),
            .direct_f64 => normToValue(ctl.*, self.controlNorm(i)),
        };
        const sep: []const u8 = if (i > 0) "," else "";
        const frag = std.fmt.bufPrint(content[used..], "{s}\"{s}\":{d}", .{ sep, ctl.idSlice(), value }) catch return null;
        used += frag.len;
    }
    const tail = std.fmt.bufPrint(content[used..], "}}}}\n", .{}) catch return null;
    used += tail.len;
    return used;
}

// Rescan the preset directory and re-find `name` as the current preset.
// Returns its sorted index, or null if it didn't reappear.
fn rescanAndSelect(self: *FyRawMachine, name: []const u8) ?u8 {
    self.presets = presets_mod.scan(self.presetDir());
    for (self.presets.names[0..self.presets.count], 0..) |*pn, i| {
        if (std.mem.eql(u8, pn.slice(), name)) {
            self.current_preset_idx = @intCast(i);
            return @intCast(i);
        }
    }
    return null;
}

// Write the current control values to `<name>.preset`, rescan, and select
// it. Returns the new sorted index. Shared by auto- and named-save paths.
fn writePreset(self: *FyRawMachine, name: []const u8) ?u8 {
    if (self.preset_dir_len == 0) return null;
    var content: [presets_mod.MAX_FILE]u8 = undefined;
    const used = buildPresetContent(self, &content) orelse return null;
    if (!presets_mod.writeFile(self.presetDir(), name, content[0..used])) return null;
    return rescanAndSelect(self, name);
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
    return writePreset(self, name);
}

// Save under a caller-supplied name. Sanitizes to the preset name limits;
// an empty/oversized name fails. Overwrites an existing preset of the same
// name (the rescan picks up the single file either way).
fn savePresetNamedImpl(state: *anyopaque, name_z: [*:0]const u8) ?u8 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const name = presetSanitize(std.mem.span(name_z)) orelse return null;
    return writePreset(self, name);
}

// Rename preset `index` to `new_name`: rename the file on disk, rescan, and
// keep it selected. Returns the new sorted index.
fn renamePresetImpl(state: *anyopaque, index: u8, new_name_z: [*:0]const u8) ?u8 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (self.preset_dir_len == 0 or index >= self.presets.count) return null;
    const new_name = presetSanitize(std.mem.span(new_name_z)) orelse return null;
    var old_buf: [presets_mod.MAX_NAME]u8 = undefined;
    const old = self.presets.names[index].slice();
    if (old.len > old_buf.len) return null;
    @memcpy(old_buf[0..old.len], old);
    if (!presets_mod.renameFile(self.presetDir(), old_buf[0..old.len], new_name)) return null;
    return rescanAndSelect(self, new_name);
}

// Trim surrounding space and reject empty / oversized / path-bearing names
// (the `/` subdir separator is reserved for factory grouping dirs).
fn presetSanitize(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > presets_mod.MAX_NAME) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '/') != null) return null;
    return trimmed;
}

fn validateWord(host: *FyHost, word: []const u8) !void {
    // Composition (`call:`) words have no value-graph raw body to report —
    // they are validated by compileDsp2CompositionCaller instead.
    if (host.fy.isCompositionWord(word)) return;
    _ = try host.fy.reportDsp2RawWord(word);
}

pub fn normToValue(control: Control, norm: f32) f64 {
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

// Number of selectable steps in an int_range control (max - min + 1).
fn intRangeCount(control: Control) usize {
    return @intFromFloat(@round(control.max - control.min) + 1);
}

// The int_range param value: the stored raw rounded and clamped to [min, max].
fn intRangeValue(control: Control, raw: f32) f64 {
    return std.math.clamp(@round(@as(f64, raw)), control.min, control.max);
}

fn renderImpl(state: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const frames = @min(@as(usize, @intCast(ctx.block_size)), @min(l.len, @min(r.len, MAX_BLOCK)));
    if (frames == 0) return;

    fy_host_mod.lockCallbacks();
    defer fy_host_mod.unlockCallbacks();
    Fy.Builtins.fyPtr = @intFromPtr(&self.host.fy);

    self.syncRawParams(ctx.sample_rate, ctx.tempo_bpm);
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
    // Prepare runs once per state region: per channel for effects, per
    // voice for polyphonic machines.
    for (0..self.regionCount()) |reg| {
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = self.statePtrCh(reg) },
            .{ .ptr = self.paramsPtr() },
            .{ .f64 = sample_rate },
        };
        _ = try caller.call(1, &args);
    }
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
    // Polyphonic machines render every voice every block (Juno-style — no
    // freeing, silent voices are cheap and predictable); kernels of
    // multi-voice machines ACCUMULATE into the host-zeroed out buffer.
    for (0..self.regionCount()) |voice| {
        const args = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&self.mono_buf[start]) },
            .{ .ptr = self.statePtrCh(voice) },
            .{ .ptr = self.paramsPtr() },
        };
        _ = try caller.call(@intCast(end - start), &args);
    }
}

fn applyNoteEvent(self: *FyRawMachine, ev: machine.NoteEvent) !void {
    switch (ev.kind) {
        .note_on => {
            if (ev.velocity <= 0) {
                try noteOffEvent(self, ev.pitch);
            } else {
                try noteOnEvent(self, ev);
            }
        },
        .note_off => try noteOffEvent(self, ev.pitch),
        .reset => {
            for (0..self.regionCount()) |voice| {
                self.voice_gate[voice] = false;
                try callNoteOff(self, voice);
            }
        },
        else => {},
    }
}

// Pick a voice: oldest un-gated first, else steal the oldest gated.
fn allocVoice(self: *FyRawMachine) usize {
    const n = self.regionCount();
    var best: usize = 0;
    var best_age: u64 = std.math.maxInt(u64);
    var found_free = false;
    for (0..n) |v| {
        if (self.voice_gate[v]) continue;
        if (self.voice_age[v] < best_age) {
            best = v;
            best_age = self.voice_age[v];
            found_free = true;
        }
    }
    if (found_free) return best;
    best_age = std.math.maxInt(u64);
    for (0..n) |v| {
        if (self.voice_age[v] < best_age) {
            best = v;
            best_age = self.voice_age[v];
        }
    }
    return best;
}

fn noteOnEvent(self: *FyRawMachine, ev: machine.NoteEvent) !void {
    const voice = allocVoice(self);
    self.age_counter += 1;
    self.voice_age[voice] = self.age_counter;
    self.voice_pitch[voice] = ev.pitch;
    self.voice_gate[voice] = true;
    // note-pitch machines (drums) address slots by raw MIDI pitch.
    const note_arg = if (self.desc.note_pitch) @as(f64, ev.pitch) else midiToHz(ev.pitch);
    try callNoteOn(self, voice, note_arg, ev.velocity);
}

// note_id is -1 throughout the sequencer, so note-off matches the newest
// gated voice holding this pitch. Mono machines just release voice 0.
fn noteOffEvent(self: *FyRawMachine, pitch: f32) !void {
    const n = self.regionCount();
    if (n == 1) {
        self.voice_gate[0] = false;
        try callNoteOff(self, 0);
        return;
    }
    var found: ?usize = null;
    var newest: u64 = 0;
    for (0..n) |v| {
        if (!self.voice_gate[v]) continue;
        if (self.voice_pitch[v] != pitch) continue;
        if (self.voice_age[v] >= newest) {
            newest = self.voice_age[v];
            found = v;
        }
    }
    if (found) |v| {
        self.voice_gate[v] = false;
        try callNoteOff(self, v);
    }
}

fn callNoteOn(self: *FyRawMachine, voice: usize, hz: f64, velocity: f64) !void {
    const caller = if (self.note_on_caller) |*c_| c_ else return;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = self.statePtrCh(voice) },
        .{ .ptr = self.paramsPtr() },
        .{ .f64 = hz },
        .{ .f64 = velocity },
    };
    _ = try caller.call(1, &args);
}

fn callNoteOff(self: *FyRawMachine, voice: usize) !void {
    const caller = if (self.note_off_caller) |*c_| c_ else return;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = self.statePtrCh(voice) },
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
            .{ .ptr = self.statePtrCh(0) },
            .{ .ptr = self.paramsPtr() },
            .{ .f64 = xl },
        };
        _ = try self.host.fy.callDsp2RawRepeatedWithArgsNoResult(self.desc.renderWord(), 1, &args_l);
        l[i] = @floatCast(std.math.clamp(out_sample, -1.0, 1.0));

        const xr: f64 = if (in_r) |p| p[i] else xl;
        const args_r = [_]Fy.Dsp2RawArg{
            .{ .ptr = @intFromPtr(&out_sample) },
            .{ .ptr = self.statePtrCh(1) },
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
    if (self.desc.detector_cell != null) {
        for (self.det_buf[0..l.len], self.in_l_buf[0..l.len], self.in_r_buf[0..l.len]) |*d, xl, xr| {
            d.* = @max(@abs(xl), @abs(xr));
        }
    }

    const args_l = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&self.out_l_buf[0]) },
        .{ .ptr = self.statePtrCh(0) },
        .{ .ptr = self.paramsPtr() },
        .{ .ptr = @intFromPtr(&self.in_l_buf[0]) },
    };
    _ = try caller.call(l.len, &args_l);

    const args_r = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&self.out_r_buf[0]) },
        .{ .ptr = self.statePtrCh(1) },
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
    for (0..self.regionCount()) |reg| {
        @memset(self.state_buf[reg * MAX_STATE ..][0..self.desc.state_size], 0);
    }
    @memset(self.voice_gate[0..], false);
    @memset(self.voice_pitch[0..], -1);
    @memset(self.params_buf[0..self.desc.params_size], 0);
    for (self.buffer_mem[0..self.desc.buffer_count]) |pair| {
        for (pair) |mem| @memset(mem, 0);
    }
    self.injectBuffers();
    self.injectAssets(); // params were memset; restore the asset pointers
    self.failed = false;
}

fn deinitImpl(state: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    self.freeBuffersUpTo(alloc, self.desc.buffer_count);
    self.freeAssets(alloc);
    // derive-data is libc-malloc'd by fy's `alloc`; fy doesn't track it.
    if (self.desc.derive_data != 0) std.c.free(@ptrFromInt(self.desc.derive_data));
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

fn drawDisplay(self: *FyRawMachine, rect: c.rl.Rectangle, disp: *const Display, mouse: widgets.Mouse) void {
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
        .waveform => drawWaveformDisplay(self, field, disp.sourceSlice(), mouse),
        .meter => drawMeterDisplay(self, field, disp),
        .response => drawResponseDisplay(self, field),
    }
}

// ── Frequency-response curve (parametric EQ) ──────────────────────────
//
// Recomputes the composite biquad magnitude from the machine's own band
// controls (read on the UI thread from the same norms the audio thread
// turns into params) and draws it as a 1 px polyline over a log-frequency
// axis. The audio truth stays in fy (kernels/07-effects/eq.fy); this curve
// is a cosmetic mirror, so a fixed 48 kHz display rate is fine.

const EQ_DB_RANGE: f64 = 18.0; // half-range; the field spans ±18 dB

const Biquad = struct { b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64 };

fn rbjPeak(fc: f64, db: f64, q: f64, sr: f64) Biquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const a = std.math.pow(f64, 10.0, db / 40.0);
    const alpha = sw / (2.0 * q);
    return .{ .b0 = 1 + alpha * a, .b1 = -2 * cw, .b2 = 1 - alpha * a, .a0 = 1 + alpha / a, .a1 = -2 * cw, .a2 = 1 - alpha / a };
}

fn rbjLowShelf(fc: f64, db: f64, sr: f64) Biquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const a = std.math.pow(f64, 10.0, db / 40.0);
    const beta = 2.0 * @sqrt(a) * (sw / 2.0) * std.math.sqrt2;
    const ap1 = a + 1.0;
    const am1 = a - 1.0;
    return .{
        .b0 = a * (ap1 - am1 * cw + beta),
        .b1 = 2 * a * (am1 - ap1 * cw),
        .b2 = a * (ap1 - am1 * cw - beta),
        .a0 = ap1 + am1 * cw + beta,
        .a1 = -2 * (am1 + ap1 * cw),
        .a2 = ap1 + am1 * cw - beta,
    };
}

fn rbjHighShelf(fc: f64, db: f64, sr: f64) Biquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const a = std.math.pow(f64, 10.0, db / 40.0);
    const beta = 2.0 * @sqrt(a) * (sw / 2.0) * std.math.sqrt2;
    const ap1 = a + 1.0;
    const am1 = a - 1.0;
    return .{
        .b0 = a * (ap1 + am1 * cw + beta),
        .b1 = -2 * a * (am1 + ap1 * cw),
        .b2 = a * (ap1 + am1 * cw - beta),
        .a0 = ap1 - am1 * cw + beta,
        .a1 = 2 * (am1 - ap1 * cw),
        .a2 = ap1 - am1 * cw - beta,
    };
}

fn rbjHpf(fc: f64, q: f64, sr: f64) Biquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const alpha = sw / (2.0 * q);
    const omc = 1.0 + cw;
    return .{ .b0 = omc / 2.0, .b1 = -omc, .b2 = omc / 2.0, .a0 = 1 + alpha, .a1 = -2 * cw, .a2 = 1 - alpha };
}

fn biquadMagDb(bq: Biquad, f: f64, sr: f64) f64 {
    const w = 2.0 * std.math.pi * f / sr;
    const cw = @cos(w);
    const c2w = @cos(2.0 * w);
    const num = bq.b0 * bq.b0 + bq.b1 * bq.b1 + bq.b2 * bq.b2 + 2.0 * (bq.b0 * bq.b1 + bq.b1 * bq.b2) * cw + 2.0 * bq.b0 * bq.b2 * c2w;
    const den = bq.a0 * bq.a0 + bq.a1 * bq.a1 + bq.a2 * bq.a2 + 2.0 * (bq.a0 * bq.a1 + bq.a1 * bq.a2) * cw + 2.0 * bq.a0 * bq.a2 * c2w;
    return 10.0 * std.math.log10(@max(num / @max(den, 1e-12), 1e-12));
}

fn controlValueById(self: *const FyRawMachine, id: []const u8) ?f64 {
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (std.mem.eql(u8, ctl.idSlice(), id)) {
            return switch (ctl.kind) {
                .direct_f64 => normToValue(ctl.*, self.controlNorm(i)),
                .switch_sel => ctl.option_values[switchIndex(ctl.*, self.controlNorm(i))],
                .int_range => intRangeValue(ctl.*, self.controlNorm(i)),
            };
        }
    }
    return null;
}

fn drawResponseDisplay(self: *FyRawMachine, field: c.rl.Rectangle) void {
    const sr: f64 = 48000.0;

    const hpf_on = (controlValueById(self,"eq-hpf-on") orelse 0.0) >= 0.5;
    const hpf = rbjHpf(controlValueById(self,"eq-hpf-hz") orelse 20.0, std.math.sqrt1_2, sr);
    const ls = rbjLowShelf(controlValueById(self,"eq-ls-hz") orelse 100.0, controlValueById(self,"eq-ls-db") orelse 0.0, sr);
    const p1 = rbjPeak(controlValueById(self,"eq-p1-hz") orelse 500.0, controlValueById(self,"eq-p1-db") orelse 0.0, controlValueById(self,"eq-p1-q") orelse 0.9, sr);
    const p2 = rbjPeak(controlValueById(self,"eq-p2-hz") orelse 3000.0, controlValueById(self,"eq-p2-db") orelse 0.0, controlValueById(self,"eq-p2-q") orelse 0.9, sr);
    const hs = rbjHighShelf(controlValueById(self,"eq-hs-hz") orelse 8000.0, controlValueById(self,"eq-hs-db") orelse 0.0, sr);

    // Horizontal grid: 0 dB centre + ±9 dB lines.
    const mid_y = field.y + field.height * 0.5;
    c.rl.DrawLineEx(.{ .x = field.x, .y = mid_y }, .{ .x = field.x + field.width, .y = mid_y }, 1.0, theme.grid_beat);
    inline for (.{ -9.0, 9.0 }) |g| {
        const gy = field.y + @as(f32, @floatCast(0.5 - (@as(f64, g)) / (2.0 * EQ_DB_RANGE))) * field.height;
        c.rl.DrawLineEx(.{ .x = field.x, .y = gy }, .{ .x = field.x + field.width, .y = gy }, 1.0, theme.grid_sub);
    }
    // Vertical decade lines at 100 / 1k / 10k Hz (log axis 20..20000).
    inline for (.{ 100.0, 1000.0, 10000.0 }) |fline| {
        const tx = std.math.log10(@as(f64, fline) / 20.0) / 3.0; // 20..20000 spans 3 decades
        const vx = field.x + @as(f32, @floatCast(tx)) * field.width;
        c.rl.DrawLineEx(.{ .x = vx, .y = field.y }, .{ .x = vx, .y = field.y + field.height }, 1.0, theme.grid_sub);
    }

    const N: usize = 160;
    var prev = c.rl.Vector2{ .x = 0, .y = 0 };
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(N - 1));
        const f = 20.0 * std.math.pow(f64, 1000.0, t); // 20 → 20000 Hz, log-spaced
        var db: f64 = 0;
        if (hpf_on) db += biquadMagDb(hpf, f, sr);
        db += biquadMagDb(ls, f, sr);
        db += biquadMagDb(p1, f, sr);
        db += biquadMagDb(p2, f, sr);
        db += biquadMagDb(hs, f, sr);
        const yn = std.math.clamp(0.5 - db / (2.0 * EQ_DB_RANGE), 0.0, 1.0);
        const px = field.x + @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N - 1)) * field.width;
        const py = field.y + @as(f32, @floatCast(yn)) * field.height;
        const p = c.rl.Vector2{ .x = px, .y = py };
        if (i > 0) c.rl.DrawLineEx(prev, p, 1.5, theme.accent_hi);
        prev = p;
    }
}

// ── L2-style level / loudness meter ───────────────────────────────────
//
// Vertical full-scale meter (0 dB at top, -60 dB floor): per-channel input
// and output level bars, a gain-reduction band descending from the top, dB
// scale ticks, peak-hold lines, and LUFS (momentary/short-term/integrated)
// + output-peak numeric readouts. All log conversions happen here; the
// kernel stores only linear cells.

const METER_DB_FLOOR: f32 = -60.0;
const METER_GR_RANGE: f32 = 24.0; // dB of GR shown across the band height

const MeterUi = struct {
    // Smoothed display values (dB), fast attack / slow release.
    in_db: [2]f32 = .{ METER_DB_FLOOR, METER_DB_FLOOR },
    out_db: [2]f32 = .{ METER_DB_FLOOR, METER_DB_FLOOR },
    gr_db: f32 = 0,
    // Peak-hold (dB) with hold time then decay.
    in_hold: [2]f32 = .{ METER_DB_FLOOR, METER_DB_FLOOR },
    out_hold: [2]f32 = .{ METER_DB_FLOOR, METER_DB_FLOOR },
    gr_hold: f32 = 0,
    hold_age: f32 = 0,
    out_peak_db: f32 = METER_DB_FLOOR, // max output peak since last clear (clip readout)
    last_t: f64 = 0,
};

fn lin2db(x: f64) f32 {
    return @floatCast(20.0 * std.math.log10(@max(x, 1e-7)));
}

fn ms2lufs(ms: f64) f32 {
    return @floatCast(-0.691 + 10.0 * std.math.log10(@max(ms, 1e-12)));
}

// dB → y within [top, bottom], 0 dB at top, floor at bottom.
fn dbToY(db: f32, top: f32, bottom: f32) f32 {
    const frac = std.math.clamp((db - METER_DB_FLOOR) / (0.0 - METER_DB_FLOOR), 0.0, 1.0);
    return bottom - frac * (bottom - top);
}

fn drawMeterDisplay(self: *FyRawMachine, field: c.rl.Rectangle, disp: *const Display) void {
    const D = machine_desc.MeterOffset;
    const regions = self.regionCount();
    const r1: usize = if (regions > 1) 1 else 0;

    // Pull live linear cells (region 0 = L, region 1 = R).
    const gminL = self.readStateF64(0, disp.meterOffset(.gmin));
    const gminR = self.readStateF64(r1, disp.meterOffset(.gmin));
    const gmin = @min(gminL, gminR);
    const gr_now: f32 = -lin2db(@max(gmin, 1e-7)); // gmin<=1 → reduction in dB ≥0
    const in_now = [2]f32{ lin2db(self.readStateF64(0, disp.meterOffset(.ipk))), lin2db(self.readStateF64(r1, disp.meterOffset(.ipk))) };
    const out_now = [2]f32{ lin2db(self.readStateF64(0, disp.meterOffset(.opk))), lin2db(self.readStateF64(r1, disp.meterOffset(.opk))) };

    const msmL = self.readStateF64(0, disp.meterOffset(.msm));
    const msmR = self.readStateF64(r1, disp.meterOffset(.msm));
    const mssL = self.readStateF64(0, disp.meterOffset(.mss));
    const mssR = self.readStateF64(r1, disp.meterOffset(.mss));
    const msumL = self.readStateF64(0, disp.meterOffset(.msum));
    const msumR = self.readStateF64(r1, disp.meterOffset(.msum));
    const mn = @max(self.readStateF64(0, disp.meterOffset(.mn)), 1.0);
    const lufs_m = ms2lufs(msmL + msmR);
    const lufs_s = ms2lufs(mssL + mssR);
    const lufs_i = ms2lufs((msumL + msumR) / mn);

    _ = D;

    // Ballistics.
    var ui = &self.meter_ui;
    const t = c.rl.GetTime();
    var dt: f32 = if (ui.last_t > 0) @floatCast(t - ui.last_t) else 0.016;
    ui.last_t = t;
    dt = std.math.clamp(dt, 0.0, 0.1);
    const rel_db_s: f32 = 36.0; // bar release rate dB/s
    const hold_s: f32 = 1.5;
    const hold_decay: f32 = 18.0;

    var ch: usize = 0;
    while (ch < 2) : (ch += 1) {
        ui.in_db[ch] = ballistic(ui.in_db[ch], in_now[ch], rel_db_s, dt);
        ui.out_db[ch] = ballistic(ui.out_db[ch], out_now[ch], rel_db_s, dt);
    }
    ui.gr_db = ballisticGr(ui.gr_db, gr_now, 60.0, dt);

    // Peak-hold: refresh on new max, else age & decay.
    var any_new = false;
    ch = 0;
    while (ch < 2) : (ch += 1) {
        if (in_now[ch] > ui.in_hold[ch]) {
            ui.in_hold[ch] = in_now[ch];
            any_new = true;
        }
        if (out_now[ch] > ui.out_hold[ch]) {
            ui.out_hold[ch] = out_now[ch];
            any_new = true;
        }
    }
    if (gr_now > ui.gr_hold) {
        ui.gr_hold = gr_now;
        any_new = true;
    }
    if (out_now[0] > ui.out_peak_db) ui.out_peak_db = out_now[0];
    if (out_now[1] > ui.out_peak_db) ui.out_peak_db = out_now[1];
    if (any_new) ui.hold_age = 0 else ui.hold_age += dt;
    if (ui.hold_age > hold_s) {
        ch = 0;
        while (ch < 2) : (ch += 1) {
            ui.in_hold[ch] -= hold_decay * dt;
            ui.out_hold[ch] -= hold_decay * dt;
        }
        ui.gr_hold -= hold_decay * dt;
    }

    // Layout: a graph area on top, a readout strip at the bottom.
    const read_h = theme.size(46);
    const graph = widgets.rect(field.x, field.y, field.width, @max(1, field.height - read_h));
    c.rl.DrawRectangleRec(graph, theme.slab_edge);
    const top = graph.y + theme.size(4);
    const bot = graph.y + graph.height - theme.size(4);

    // dB scale ticks down the left.
    const scale_x = graph.x + theme.size(2);
    const ticks = [_]f32{ 0, -6, -12, -24, -36, -48, -60 };
    for (ticks) |dbv| {
        const y = dbToY(dbv, top, bot);
        c.rl.DrawRectangle(@intFromFloat(graph.x), @intFromFloat(y), @intFromFloat(graph.width), 1, theme.grid_sub);
        var lb: [8:0]u8 = undefined;
        const s = std.fmt.bufPrintZ(&lb, "{d:.0}", .{dbv}) catch "";
        widgets.drawLabelF(s, scale_x, y + 1, theme.fsTiny() - 1, theme.text_mute);
    }

    // Column geometry: [scale ~22px] IN-L IN-R | GR | OUT-L OUT-R
    const col_x = graph.x + theme.size(22);
    const col_w = graph.x + graph.width - theme.size(4) - col_x;
    const bar_w = @max(2, (col_w - theme.size(8)) / 5.0);
    var x = col_x;

    drawLevelBar(widgets.rect(x, top, bar_w, bot - top), ui.in_db[0], ui.in_hold[0], theme.text_dim, top, bot);
    x += bar_w + 1;
    drawLevelBar(widgets.rect(x, top, bar_w, bot - top), ui.in_db[1], ui.in_hold[1], theme.text_dim, top, bot);
    x += bar_w + theme.size(3);

    // GR band: descends from the top, height ∝ reduction.
    const gr_col = widgets.rect(x, top, bar_w, bot - top);
    c.rl.DrawRectangleRec(gr_col, theme.pane_alt);
    const gr_h = std.math.clamp(ui.gr_db / METER_GR_RANGE, 0.0, 1.0) * (bot - top);
    if (gr_h > 0)
        c.rl.DrawRectangleRec(widgets.rect(gr_col.x, top, bar_w, gr_h), theme.accent_rec);
    if (ui.gr_hold > 0.05) {
        const hy = top + std.math.clamp(ui.gr_hold / METER_GR_RANGE, 0.0, 1.0) * (bot - top);
        c.rl.DrawRectangle(@intFromFloat(gr_col.x), @intFromFloat(hy), @intFromFloat(bar_w), 1, theme.text_fg);
    }
    x += bar_w + theme.size(3);

    drawLevelBar(widgets.rect(x, top, bar_w, bot - top), ui.out_db[0], ui.out_hold[0], theme.accent_play, top, bot);
    x += bar_w + 1;
    drawLevelBar(widgets.rect(x, top, bar_w, bot - top), ui.out_db[1], ui.out_hold[1], theme.accent_play, top, bot);

    // Readout strip.
    var ry = graph.y + graph.height + theme.size(2);
    const fs = theme.fsTiny();
    const clip = ui.out_peak_db > -0.05;
    var b: [40:0]u8 = undefined;
    const grs = std.fmt.bufPrintZ(&b, "GR {d:.1} dB", .{ui.gr_db}) catch "";
    widgets.drawLabelF(grs, field.x + theme.size(2), ry, fs, theme.accent_rec);
    var b2: [40:0]u8 = undefined;
    const ops = std.fmt.bufPrintZ(&b2, "OUT {d:.1} dB", .{ui.out_peak_db}) catch "";
    widgets.drawLabelF(ops, field.x + field.width / 2, ry, fs, if (clip) theme.accent_rec else theme.text_dim);
    ry += fs + theme.size(3);
    var b3: [56:0]u8 = undefined;
    const ls = std.fmt.bufPrintZ(&b3, "M {d:.1}  S {d:.1}  I {d:.1} LUFS", .{ lufs_m, lufs_s, lufs_i }) catch "";
    widgets.drawLabelF(ls, field.x + theme.size(2), ry, fs, theme.text_fg);
}

fn ballistic(cur: f32, target: f32, rel_db_s: f32, dt: f32) f32 {
    if (target >= cur) return target; // instant attack
    return @max(target, cur - rel_db_s * dt);
}

fn ballisticGr(cur: f32, target: f32, rel_db_s: f32, dt: f32) f32 {
    if (target >= cur) return target;
    return @max(target, cur - rel_db_s * dt);
}

fn drawLevelBar(r: c.rl.Rectangle, db: f32, hold_db: f32, col: c.rl.Color, top: f32, bot: f32) void {
    c.rl.DrawRectangleRec(r, theme.pane_alt);
    const y = dbToY(db, top, bot);
    if (bot - y > 0)
        c.rl.DrawRectangleRec(widgets.rect(r.x, y, r.width, bot - y), col);
    if (hold_db > METER_DB_FLOOR + 0.5) {
        const hy = dbToY(hold_db, top, bot);
        c.rl.DrawRectangle(@intFromFloat(r.x), @intFromFloat(hy), @intFromFloat(r.width), 1, theme.text_fg);
    }
}

// Oscillogram of a loaded asset: a top bar with the filename + a LOAD button
// (opens the native audio picker and hot-swaps the sample), then the peak
// waveform with read-only start/loop markers from the matching controls.
fn drawWaveformDisplay(self: *FyRawMachine, field: c.rl.Rectangle, asset_name: []const u8, mouse: widgets.Mouse) void {
    const ai = self.assetIndexByName(asset_name) orelse return;

    const bar_h = theme.size(16);
    const bar = widgets.rect(field.x, field.y, field.width, bar_h);
    const wave = widgets.rect(field.x, field.y + bar_h, field.width, @max(1, field.height - bar_h));

    // filename (or a hint) on the left.
    var nbuf: [110:0]u8 = [_:0]u8{0} ** 110;
    const label = self.asset_label[ai][0..self.asset_label_len[ai]];
    const ln = @min(label.len, 109);
    if (ln > 0) @memcpy(nbuf[0..ln], label[0..ln]) else @memcpy(nbuf[0..9], "no sample");
    widgets.drawLabelF(@ptrCast(&nbuf[0]), bar.x + theme.size(4), bar.y + (bar_h - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_dim);

    const btn_w = theme.size(44);
    const btn = widgets.rect(bar.x + bar.width - btn_w - 2, bar.y + 1, btn_w, bar_h - 2);
    if (widgets.button(btn, "LOAD", mouse)) {
        if (native_dialog.openAudioFile(self.alloc) catch null) |path| {
            defer self.alloc.free(path);
            _ = self.loadAssetRuntime(ai, path);
        }
    }

    c.rl.DrawRectangleRec(wave, theme.slab_edge);
    const inner = widgets.rect(wave.x + 1, wave.y + 1, wave.width - 2, wave.height - 2);
    const cache = &self.asset_cache[ai];
    waveform.draw(inner, cache, 0, @floatFromInt(@max(cache.sample_count, 1)), theme.accent_hi);

    // Draggable markers: START / LOOP BEG / LOOP END. Dragging writes the
    // matching control's normalized value live (the audio thread reads it
    // atomically) and the source knob follows.
    drawMarker(self, inner, "smp-start", theme.accent_play, mouse);
    drawMarker(self, inner, "smp-loop-start", theme.accent_hi, mouse);
    drawMarker(self, inner, "smp-loop-end", theme.accent_hi, mouse);
}

const MARKER_SALT: u64 = 0x5A3B_0FF5_7A6C_0001;

fn drawMarker(self: *FyRawMachine, area: c.rl.Rectangle, id: []const u8, col: c.rl.Color, mouse: widgets.Mouse) void {
    var idx: usize = 0;
    var found = false;
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (std.mem.eql(u8, ctl.idSlice(), id)) {
            idx = i;
            found = true;
            break;
        }
    }
    if (!found) return;

    const frac = std.math.clamp(@as(f32, self.controlNorm(idx)), 0, 1);
    const x = area.x + frac * area.width;
    const key = widgets.keyFromIds(MARKER_SALT, @intFromPtr(self), idx);
    const dragging = widgets.isDraggingKey(key);
    const hot = widgets.contains(area, mouse.x, mouse.y) and @abs(mouse.x - x) <= theme.fine(4);

    if (dragging) {
        if (mouse.left_down) {
            const nf = std.math.clamp((mouse.x - area.x) / area.width, 0, 1);
            self.setControlNorm(idx, nf);
        } else {
            widgets.cancelDrag();
        }
    } else if (hot and mouse.left_pressed and !widgets.hasActiveDrag()) {
        _ = widgets.tryStartDrag(key);
    }
    if (hot or dragging) widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);

    const lw: f32 = if (hot or dragging) 2.0 else 1.0;
    c.rl.DrawLineEx(.{ .x = x, .y = area.y }, .{ .x = x, .y = area.y + area.height }, lw, col);
    // A small grab tab at the top so the handle reads as draggable.
    const tab = theme.fine(3);
    c.rl.DrawRectangleRec(widgets.rect(x - tab, area.y, tab * 2 + 1, tab + 1), col);
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
    drawRows(self, self.desc.rows[0..self.desc.row_count], body, mouse);
}

// Height of the panel's tab bar (paged machines).
const TAB_BAR_H: f32 = 16;

// Tab bar across the top of the body; clicking a tab swaps the active page.
// Brutalist: 1px-separated beveled cells, the active one raised/lit.
fn drawTabBar(self: *FyRawMachine, bar: c.rl.Rectangle, mouse: widgets.Mouse) void {
    const n = self.desc.page_count;
    if (n == 0) return;
    c.rl.DrawRectangleRec(bar, theme.pane_alt);
    const cw = bar.width / @as(f32, @floatFromInt(n));
    var x = bar.x;
    for (self.desc.pages[0..n], 0..) |*pg, i| {
        const w = if (i + 1 == n) (bar.x + bar.width - x) else cw;
        const cell = widgets.rect(x, bar.y, w, bar.height);
        const active = i == self.ui_tab;
        const hover = widgets.contains(cell, mouse.x, mouse.y) and !widgets.hasActiveDrag();
        if (hover and mouse.left_released) self.ui_tab = i;
        const fill = if (active) theme.slab_hi else if (hover) theme.slab_fill else theme.pane_alt;
        c.rl.DrawRectangleRec(widgets.rect(cell.x + 1, cell.y + 1, cell.width - 2, cell.height - 2), fill);
        if (i > 0) c.rl.DrawRectangle(@intFromFloat(cell.x), @intFromFloat(cell.y + 1), 1, @intFromFloat(cell.height - 2), theme.slab_edge);
        const size = theme.fsTiny();
        const tw = widgets.measureTextF(pg.nameZ(), size);
        widgets.drawLabelF(pg.nameZ(), cell.x + (cell.width - tw) / 2, cell.y + (cell.height - size) / 2 - 1, size, if (active) theme.text_fg else theme.text_dim);
        x += w;
    }
}

fn drawRows(self: *FyRawMachine, rows: []const machine_desc.LayoutRow, body: c.rl.Rectangle, mouse: widgets.Mouse) void {
    const row_count = rows.len;
    var total_rw: f32 = 0;
    for (rows) |*r| total_rw += r.weight;
    if (total_rw <= 0) return;
    var y = body.y;
    for (rows, 0..) |*r, ri| {
        const rh = if (ri + 1 == row_count) (body.y + body.height - y) else body.height * r.weight / total_rw;
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
                            drawDisplay(self, item_rect, &self.desc.displays[it.index], mouse);
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
    if (self.desc.page_count > 0) {
        if (self.ui_tab >= self.desc.page_count) self.ui_tab = 0;
        const bar = widgets.rect(body.x, body.y, body.width, TAB_BAR_H);
        drawTabBar(self, bar, mouse);
        const page_body = widgets.rect(body.x, body.y + TAB_BAR_H, body.width, body.height - TAB_BAR_H);
        const pg = &self.desc.pages[self.ui_tab];
        drawRows(self, pg.rows[0..pg.row_count], page_body, mouse);
        return;
    }
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
            .int_range => {
                // Detented rotary over [min, max] with generated number labels.
                const INT_LABEL_CAP = 64;
                const n_steps = @min(intRangeCount(ctl.*), INT_LABEL_CAP);
                const lo: i64 = @intFromFloat(@round(ctl.min));
                var numbuf: [INT_LABEL_CAP][8]u8 = undefined;
                var labels: [INT_LABEL_CAP][*:0]const u8 = undefined;
                for (0..n_steps) |s| {
                    _ = std.fmt.bufPrintZ(numbuf[s][0..], "{d}", .{lo + @as(i64, @intCast(s))}) catch {};
                    labels[s] = @ptrCast(&numbuf[s][0]);
                }
                const cur: i64 = @intFromFloat(intRangeValue(ctl.*, self.controlNorm(gi)));
                var idx: u8 = @intCast(std.math.clamp(cur - lo, 0, @as(i64, @intCast(n_steps - 1))));
                if (widgets.knobStepped(kr, ctl.labelZ(), labels[0..n_steps], &idx, mouse)) {
                    self.setControlRaw(gi, @floatFromInt(lo + @as(i64, idx)));
                }
            },
            .direct_f64 => {
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

test "FM-86 plays a note end to end (routing hook + staged voice)" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 57, .velocity = 0.9 },
        .{ .sample_offset = 700, .kind = .note_off, .channel = 0, .note_id = 1, .pitch = 57, .velocity = 0 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 1024;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 1024;
    var r = [_]f32{0} ** 1024;
    testRender(mach, &ctx, &l, &r);

    // Finite, mono-duplicated, and within the clamp.
    for (l, r) |sl, sr| {
        try testing.expect(std.math.isFinite(sl));
        try testing.expectEqual(sl, sr);
        try testing.expect(@abs(sl) <= 1.0);
    }

    // The default patch (algorithm 1) must make sound once the carrier
    // envelopes have opened, then fall after note-off — proving the algorithm
    // routing hook filled carriers/weights and the staged voice ran.
    var sustain_energy: f64 = 0;
    for (l[300..700]) |s| sustain_energy += @abs(s);
    var release_tail: f64 = 0;
    for (l[1000..1024]) |s| release_tail += @abs(s);
    try testing.expect(sustain_energy > 1.0);
    try testing.expect(release_tail * 16 < sustain_energy);
}

test "FM-86 fy derive routing matches the dx7_algorithms oracle (all 32)" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // master 1.0 so carrier weights compare 1:1 with the oracle (which doesn't
    // fold master); a non-zero feedback to check the fb fields land.
    const feedback: f64 = 0.6;
    mach.set_param.?(mach.state, "master", 1.0);
    mach.set_param.?(mach.state, "feedback", feedback);

    const vp: *const dx7_algorithms.VoiceParams = @ptrCast(@alignCast(&inst.params_buf[0]));
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 16;
    var l = [_]f32{0} ** 16;
    var r = [_]f32{0} ** 16;

    // The ALGO int-step selects each algorithm; the fy derive word fills the
    // routing from its own table. Pin all 27 routing fields against the
    // validated Zig oracle for every algorithm.
    for (1..33) |n| {
        mach.set_param.?(mach.state, "algo", @floatFromInt(n));
        testRender(mach, &ctx, &l, &r); // syncRawParams -> fy derive fills routing

        var want = dx7_algorithms.VoiceParams{};
        dx7_algorithms.applyRouting(&want, dx7_algorithms.dx7_algorithms[n - 1], feedback);

        // Tolerance, not exact: feedback/master flow through the f32 control
        // atomics, so a value like 0.6 comes back as 0.6 + ~1e-7.
        inline for (.{ "w01", "w02", "w03", "w04", "w05", "w12", "w13", "w14", "w15", "w23", "w24", "w25", "w34", "w35", "w45", "c0", "c1", "c2", "c3", "c4", "c5", "fb0", "fb1", "fb2", "fb3", "fb4", "fb5" }) |f| {
            testing.expectApproxEqAbs(@field(want, f), @field(vp.*, f), 1e-5) catch |e| {
                std.debug.print("algorithm {d} field {s}: want {d} got {d}\n", .{ n, f, @field(want, f), @field(vp.*, f) });
                return e;
            };
        }
    }
}

test "FM-86 plays an imported DX7 preset (E.PIANO 1)" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Find the imported E.PIANO preset and apply it through the real loader.
    const count = mach.preset_count.?(mach.state);
    var idx: i32 = -1;
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(mach.preset_name.?(mach.state, i)), "e-piano-1")) idx = i;
    }
    // The factory bank is generated locally (machines/fm86/tools/dx7_import.py)
    // and may not be committed (Yamaha-derived); validate when present.
    if (idx < 0) return error.SkipZigTest;
    mach.apply_preset.?(mach.state, @intCast(idx));

    // Hold the note across ~0.5 s (render caps a call at MAX_BLOCK), note-on
    // only in the first block, then keep rendering with the gate held.
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 4096;
    var on = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 60, .velocity = 0.9 },
    };

    var attack_rms: f64 = 0;
    var late_rms: f64 = 0;
    var peak: f64 = 0;
    const blocks = 6; // 6 * 4096 ~= 0.5 s
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        if (b == 0) {
            ctx.note_in = @ptrCast(on[0..].ptr);
            ctx.note_in_count = on.len;
        } else {
            ctx.note_in = null;
            ctx.note_in_count = 0;
        }
        var l = [_]f32{0} ** 4096;
        var r = [_]f32{0} ** 4096;
        testRender(mach, &ctx, &l, &r);
        var sum: f64 = 0;
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expectEqual(sl, sr);
            try testing.expect(@abs(sl) <= 1.0);
            sum += @as(f64, sl) * sl;
            peak = @max(peak, @abs(sl));
        }
        const rms = @sqrt(sum / 4096.0);
        if (b == 0) attack_rms = rms;
        if (b == blocks - 1) late_rms = rms;
    }

    try testing.expect(peak > 0.05); // makes sound
    // Still ringing ~0.5 s in — the bug where decay/release was ~10x too fast
    // left this near-silent (notes played only their attack transient).
    try testing.expect(late_rms > 0.01);
    try testing.expect(late_rms > attack_rms * 0.05);
}

test "FM-86 is polyphonic — a chord sounds all three notes" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Three held notes, distinct note ids so the voice pool keeps them all.
    const pitches = [_]f32{ 60, 64, 67 }; // C4, E4, G4
    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = pitches[0], .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 2, .pitch = pitches[1], .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 3, .pitch = pitches[2], .velocity = 0.9 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 4096;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;
    var l = [_]f32{0} ** 4096;
    var r = [_]f32{0} ** 4096;
    testRender(mach, &ctx, &l, &r);

    // Goertzel magnitude at each note's fundamental; all three must be present.
    for (pitches) |p| {
        const hz = midiToHz(p);
        const w = 2.0 * std.math.pi * hz / 48_000.0;
        const cw = @cos(w);
        var s1: f64 = 0;
        var s2: f64 = 0;
        for (l) |x| {
            const s0 = @as(f64, x) + 2.0 * cw * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        const mag = @sqrt(s1 * s1 + s2 * s2 - 2.0 * cw * s1 * s2) * 2.0 / 4096.0;
        try testing.expect(mag > 0.02); // this pitch is sounding
    }
}

test "FM-86 survives many small live-style blocks with note churn" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 44_100;
    ctx.block_size = 256;
    var l = [_]f32{0} ** 256;
    var r = [_]f32{0} ** 256;

    var blk: usize = 0;
    while (blk < 300) : (blk += 1) {
        // Periodically toss in note-ons (chords + voice stealing) and offs.
        var evs: [4]machine.NoteEvent = undefined;
        var n: usize = 0;
        if (blk % 5 == 0) {
            const base: i32 = @intCast(48 + (blk % 24));
            for (0..3) |k| {
                evs[n] = .{ .sample_offset = @intCast(k * 30), .kind = .note_on, .channel = 0, .note_id = @intCast(blk * 4 + k), .pitch = @floatFromInt(base + @as(i32, @intCast(k * 4))), .velocity = 0.8 };
                n += 1;
            }
        }
        if (blk % 7 == 3) {
            // After any note-ons above — the render loop requires events sorted
            // by sample_offset (the real host guarantees this).
            evs[n] = .{ .sample_offset = 120, .kind = .note_off, .channel = 0, .note_id = @intCast((blk - 1) * 4), .pitch = 0, .velocity = 0 };
            n += 1;
        }
        ctx.note_in = if (n > 0) @ptrCast(evs[0..].ptr) else null;
        ctx.note_in_count = @intCast(n);
        testRender(mach, &ctx, &l, &r);
        for (l) |s| try testing.expect(std.math.isFinite(s));
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

    inst.syncRawParams(48_000, 120.0);

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

test "raw DSP2 delay machine: host buffer injection and echo" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/delay2/delay2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // One buffer request, allocated per channel and injected into both
    // channel states (pointer in cell 0, element count in cell 1).
    try testing.expectEqual(@as(usize, 1), inst.desc.buffer_count);
    const len_f: f64 = @floatFromInt(inst.buffer_mem[0][0].len);
    for (0..2) |ch| {
        const base = ch * MAX_STATE;
        const ptr_bits: *align(8) const usize = @ptrCast(@alignCast(&inst.state_buf[base]));
        try testing.expectEqual(@intFromPtr(inst.buffer_mem[0][ch].ptr), ptr_bits.*);
        const len_cell: *align(8) const f64 = @ptrCast(@alignCast(&inst.state_buf[base + 8]));
        try testing.expectEqual(len_f, len_cell.*);
    }

    // Impulse in the first block, silence after: the wet tap must come back
    // roughly one delay time later, and only on the channel that got fed.
    const block = 512;
    var in_l = [_]f32{0} ** block;
    var in_r = [_]f32{0} ** block;
    in_l[0] = 0.9;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    var echo_l: f64 = 0;
    var echo_r: f64 = 0;
    var blk: usize = 0;
    while (blk < 48) : (blk += 1) {
        testRender(mach, &ctx, &l, &r);
        if (blk == 0) {
            in_l[0] = 0; // impulse only once
            try testing.expect(l[0] > 0.4); // dry portion passes immediately
        } else {
            for (l) |x| echo_l = @max(echo_l, @abs(x));
            for (r) |x| echo_r = @max(echo_r, @abs(x));
        }
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expect(std.math.isFinite(sr));
        }
    }
    try testing.expect(echo_l > 0.05); // wet repeat arrived
    try testing.expect(echo_r < 0.0001); // R state/ring independent of L
}

test "raw DSP2 reverb machine: channel cell, wide decorrelated tail" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/verb2/verb2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Channel index injected at the manifest's channel-cell offset (16:
    // after buf ptr + len) — 0.0 left, 1.0 right.
    const cell = inst.desc.channel_cell.?;
    const l_chan: *align(8) const f64 = @ptrCast(@alignCast(&inst.state_buf[cell]));
    const r_chan: *align(8) const f64 = @ptrCast(@alignCast(&inst.state_buf[MAX_STATE + cell]));
    try testing.expectEqual(@as(f64, 0.0), l_chan.*);
    try testing.expectEqual(@as(f64, 1.0), r_chan.*);

    // Centered impulse in: the tail must ring on both channels but differ
    // between them (decorrelated tap sets), and stay finite.
    const block = 512;
    var in_l = [_]f32{0} ** block;
    var in_r = [_]f32{0} ** block;
    in_l[0] = 0.9;
    in_r[0] = 0.9;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    var tail_l: f64 = 0;
    var tail_r: f64 = 0;
    var lr_diff: f64 = 0;
    var blk: usize = 0;
    while (blk < 60) : (blk += 1) {
        testRender(mach, &ctx, &l, &r);
        if (blk == 0) {
            in_l[0] = 0;
            in_r[0] = 0;
        }
        if (blk >= 20) {
            for (l, r) |sl, sr| {
                tail_l += @abs(sl);
                tail_r += @abs(sr);
                lr_diff += @abs(sl - sr);
            }
        }
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expect(std.math.isFinite(sr));
        }
    }
    try testing.expect(tail_l > 0.5); // the tank rings well past the impulse
    try testing.expect(tail_r > 0.5);
    try testing.expect(lr_diff > 0.1 * tail_l); // channels are decorrelated
}

test "raw DSP2 compressor machine: stereo-linked gain" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/comp2/comp2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Loud tone on L only, quiet tone on R: linked detection means the
    // loud left channel must pull the quiet right channel down by the
    // same gain. With per-channel (unlinked) detection R would stay ~1:1.
    const block = 512;
    var in_l: [block]f32 = undefined;
    var in_r: [block]f32 = undefined;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l: [block]f32 = undefined;
    var r: [block]f32 = undefined;
    var phase: f64 = 0;
    var blk: usize = 0;
    var r_gain_db: f64 = 0;
    while (blk < 40) : (blk += 1) {
        for (&in_l, &in_r) |*a, *b| {
            const s = @sin(phase);
            phase += 2.0 * std.math.pi * 1000.0 / 48_000.0;
            a.* = @floatCast(0.9 * s); // ~ -1 dBFS: far over the -18 dB threshold
            b.* = @floatCast(0.02 * s); // ~ -34 dBFS: far under it
        }
        testRender(mach, &ctx, &l, &r);
        if (blk == 39) {
            var in_e: f64 = 0;
            var out_e: f64 = 0;
            for (in_r, r) |x, y| {
                in_e += @as(f64, x) * x;
                out_e += @as(f64, y) * y;
            }
            r_gain_db = 10.0 * std.math.log10(out_e / in_e);
        }
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expect(std.math.isFinite(sr));
        }
    }
    // Default: thresh -18, ratio 4 -> the ~-1 dBFS left drives ~12 dB of
    // reduction, which must land on the quiet right channel too.
    try testing.expect(r_gain_db < -8.0);
    try testing.expect(r_gain_db > -20.0);
}

test "raw DSP2 chorus machine: inverted-LFO stereo spread" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/chorus2/chorus2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Mono tone in: with SPREAD = 1 the two channels' modulated taps run
    // mirrored LFOs, so the wet outputs must differ; the difference is
    // the whole point of the Juno stereo.
    const block = 512;
    var in_l: [block]f32 = undefined;
    var in_r: [block]f32 = undefined;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l: [block]f32 = undefined;
    var r: [block]f32 = undefined;
    var phase: f64 = 0;
    var energy: f64 = 0;
    var lr_diff: f64 = 0;
    var blk: usize = 0;
    while (blk < 30) : (blk += 1) {
        for (&in_l, &in_r) |*a, *b| {
            const s: f32 = @floatCast(0.5 * @sin(phase));
            phase += 2.0 * std.math.pi * 440.0 / 48_000.0;
            a.* = s;
            b.* = s;
        }
        testRender(mach, &ctx, &l, &r);
        if (blk >= 10) {
            for (l, r) |sl, sr| {
                energy += @abs(sl);
                lr_diff += @abs(sl - sr);
            }
        }
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expect(std.math.isFinite(sr));
        }
    }
    try testing.expect(energy > 1.0);
    try testing.expect(lr_diff > 0.02 * energy);
}

test "raw DSP2 juno machine: polyphonic chord through the voice pool" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/juno2/juno2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    try testing.expectEqual(@as(usize, 8), inst.desc.voices);

    // C major triad on, then release only the E: C and G keep sounding.
    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 64, .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 67, .velocity = 0.9 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 512;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 512;
    var r = [_]f32{0} ** 512;
    testRender(mach, &ctx, &l, &r);

    // Three voices gated on distinct pitches.
    var gated: usize = 0;
    for (inst.voice_gate[0..8]) |g| {
        if (g) gated += 1;
    }
    try testing.expectEqual(@as(usize, 3), gated);

    // Release the E by pitch.
    var off = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = 64, .velocity = 0 },
    };
    ctx.note_in = @ptrCast(off[0..].ptr);
    ctx.note_in_count = 1;
    var blk: usize = 0;
    var energy: f64 = 0;
    while (blk < 20) : (blk += 1) {
        testRender(mach, &ctx, &l, &r);
        ctx.note_in_count = 0; // only the first block carries the off
        for (l) |x| {
            try testing.expect(std.math.isFinite(x));
            energy += @abs(x);
        }
    }
    gated = 0;
    for (inst.voice_gate[0..8]) |g| {
        if (g) gated += 1;
    }
    try testing.expectEqual(@as(usize, 2), gated);
    try testing.expect(energy > 5.0); // held C+G still sounding
}

test "raw DSP2 funk machine: macro drives the gate stutter" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/funk/funk.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // The funk macro is control 0; render a pluck (loud attack, decaying
    // tail) at min vs max and compare the tail energy. At max the gate
    // slams the tail shut, so its tail/peak ratio must collapse.
    const block = 512;
    var in_l: [block]f32 = undefined;
    var in_r: [block]f32 = undefined;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;
    var l: [block]f32 = undefined;
    var r: [block]f32 = undefined;

    const run = struct {
        fn pass(mc: machine.Machine, cx: *machine.MachineCtx, il: *[block]f32, ir: *[block]f32, ol: *[block]f32, or_: *[block]f32) struct { peak: f64, tail: f64 } {
            // 64 blocks: a sharp pluck at block 0, decaying, silent tail.
            var peak_sq: f64 = 0;
            var tail_sq: f64 = 0;
            var blk: usize = 0;
            while (blk < 64) : (blk += 1) {
                for (il, ir, 0..) |*aa, *bb, i| {
                    const n: f64 = @floatFromInt(blk * block + i);
                    const env = @exp(-n / 9000.0);
                    var s: f64 = 0;
                    var h: usize = 1;
                    while (h <= 8) : (h += 1) {
                        s += @sin(2.0 * std.math.pi * 220.0 * @as(f64, @floatFromInt(h)) * n / 48000.0) / @as(f64, @floatFromInt(h));
                    }
                    const v: f32 = @floatCast(0.4 * env * s);
                    aa.* = v;
                    bb.* = v;
                }
                mc.render(mc.state, cx, ol, or_);
                for (ol) |x| {
                    if (blk < 3) peak_sq += @as(f64, x) * x;
                    if (blk >= 40) tail_sq += @as(f64, x) * x;
                }
            }
            return .{ .peak = @sqrt(peak_sq), .tail = @sqrt(tail_sq) };
        }
    };

    inst.setControlNorm(0, 0.0); // clean
    const clean = run.pass(mach, &ctx, &in_l, &in_r, &l, &r);
    mach.reset(mach.state);
    inst.setControlRaw(0, 1.0); // funk macro is a knob (norm), 1.0 = full
    inst.setControlNorm(0, 1.0); // OVERLOAD
    const loud = run.pass(mach, &ctx, &in_l, &in_r, &l, &r);

    try testing.expect(std.math.isFinite(clean.peak) and std.math.isFinite(loud.peak));
    try testing.expect(clean.peak > 0.01); // the effect passes audio
    // Tail-to-peak ratio collapses under the gate.
    const clean_ratio = clean.tail / @max(clean.peak, 1e-9);
    const loud_ratio = loud.tail / @max(loud.peak, 1e-9);
    try testing.expect(loud_ratio < clean_ratio * 0.5);
}

test "raw DSP2 sampler machine: asset loads and polyphonic notes sound" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // The bundled asset loaded into the arena and got injected into params.
    try testing.expectEqual(@as(usize, 1), inst.desc.asset_count);
    try testing.expect(inst.asset_mem[0].data.len > 1000);
    const off = inst.desc.assets[0].ptr_offset;
    const ptr_bits: *align(8) const usize = @ptrCast(@alignCast(&inst.params_buf[off]));
    try testing.expectEqual(@intFromPtr(inst.asset_mem[0].data.ptr), ptr_bits.*);
    try testing.expectEqual(@as(usize, 8), inst.desc.voices);

    // Two-note chord through the voice pool produces sound; reset silences.
    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 57, .velocity = 0.9 }, // A3 = root
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 64, .velocity = 0.9 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 512;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 512;
    var r = [_]f32{0} ** 512;
    var energy: f64 = 0;
    var blk: usize = 0;
    while (blk < 8) : (blk += 1) {
        testRender(mach, &ctx, &l, &r);
        ctx.note_in_count = 0;
        for (l) |x| {
            try testing.expect(std.math.isFinite(x));
            energy += @abs(x);
        }
    }
    try testing.expect(energy > 1.0); // the sample is playing

    // Runtime hot-swap (the path the LOAD button drives, minus the dialog):
    // the params pointer must follow the new buffer, the peak cache rebuild,
    // and the old buffer free without leaking (testing allocator enforces).
    const old_ptr = @intFromPtr(inst.asset_mem[0].data.ptr);
    try testing.expect(inst.loadAssetRuntime(0, "machines/sampler/assets/default.wav"));
    const new_ptr = @intFromPtr(inst.asset_mem[0].data.ptr);
    try testing.expect(new_ptr != old_ptr); // a fresh allocation
    const pbits: *align(8) const usize = @ptrCast(@alignCast(&inst.params_buf[off]));
    try testing.expectEqual(new_ptr, pbits.*);
    try testing.expect(inst.asset_cache[0].sample_count > 1000);
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

test "raw machine presets: named save + rename round-trip" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/drum2/drum2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Named save lands a file at the chosen stem and selects it.
    inst.setControlNorm(0, 0.3);
    const before = normToValue(inst.desc.controls[0], inst.controlNorm(0));
    const idx = savePresetNamedImpl(inst, "zz-test-named") orelse return error.PresetSaveFailed;
    try testing.expectEqualStrings("zz-test-named", inst.presets.names[idx].slice());

    // Invalid names are refused.
    try testing.expectEqual(@as(?u8, null), savePresetNamedImpl(inst, "   "));
    try testing.expectEqual(@as(?u8, null), savePresetNamedImpl(inst, "has/slash"));

    // Rename moves the file; the value survives an apply afterwards.
    const ridx = renamePresetImpl(inst, idx, "zz-test-renamed") orelse return error.PresetRenameFailed;
    try testing.expectEqualStrings("zz-test-renamed", inst.presets.names[ridx].slice());
    try testing.expect(!inst.presets.contains("zz-test-named"));
    inst.setControlNorm(0, 0.95);
    applyPresetImpl(inst, ridx);
    try testing.expectApproxEqAbs(before, normToValue(inst.desc.controls[0], inst.controlNorm(0)), 0.001);

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/zz-test-renamed.preset", .{inst.presetDir()});
    fy_host_mod.deleteFilePosix(path);
}
