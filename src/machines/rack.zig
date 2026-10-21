//! Rack: lanes of chains played as one device (docs/42).
//!
//! Up to MAX_LANES lanes, each a chain: an instrument and its inserts in
//! an instrument rack (`rack`), inserts alone in an effect rack (`fxrack`).
//! An instrument rack sends a note to every lane whose key and velocity
//! ranges hold it (split and layer are the same thing: ranges that don't
//! or do overlap), transposed, with a polyphony cap that releases the
//! oldest note first, as the Fairlight's registers do; everything else
//! (CCs, resets) goes to every lane. An effect rack gives every lane its
//! input. Lanes sum after their level, pan, mute and solo, aligned to the
//! slowest lane's latency, which the rack reports. A rack can sit in a
//! lane, MAX_DEPTH deep.
//!
//! Macros (docs/42 §Macros) are the rack's controls `rk-m1`…`rk-m8`, with
//! `rk-chain` beside them: they automate, take presets and nest like any
//! control. A mapping ties a macro to a control inside (or a lane's level
//! or pan) over a range in the target's knob space, through an optional
//! formula. The rack sets mapped controls with `set_mod` between
//! SMOOTH_CHUNK-sample sub-blocks while a macro moves, so a macro sweep is
//! the same as automating the control itself.
//!
//! A rack preset (machines/rack/presets/*.preset) and a project store the
//! lanes as {"rack":2,"kind":…,"lanes":[{…,"instrument":{"machine":id,
//! "params":{…}},"effects":[…]}]}, each machine's settings in its own form,
//! so any machine that persists works inside a rack. The first form,
//! {"parts":[{"machine":id,"lo":…,"params":{…}},…]}, reads as lanes with an
//! instrument and no effects; tools (tools/library/cmi.py for CMI
//! instruments) write it.
//!
//! UI owns the editable lanes; audio owns its adopted lanes and held notes.
//! The lane list publishes through a latest-value handoff, each lane's
//! chain through its own chain.State (the track's machinery). A removed
//! lane retires on UI only after audio acknowledges a list without it.

const std = @import("std");
const storage = @import("../storage.zig");
const machine = @import("../machine.zig");
const registry_mod = @import("../machine_registry.zig");
const presets_mod = @import("../presets.zig");
const handoff = @import("../handoff.zig");
const chain_mod = @import("../chain.zig");
const engine = @import("../engine.zig");
const ui_core = @import("../ui/core.zig");
const ctl = @import("../ui/controls.zig");
const ui_style = @import("../ui/style.zig");
const menu = @import("../ui/menu.zig");
const pane = @import("../ui/pane_input.zig");
const bay = @import("../ui/machine_bay.zig");
const text_field = @import("../ui/text_field.zig");
const formula = @import("../formula.zig");
const snapshot = @import("../snapshot.zig");
const automation = @import("../automation.zig");
const fy_raw = @import("fy_raw_machine.zig");

const Ui = ui_core.Ui;
const Rect = ui_core.Rect;
const Machine = machine.Machine;
const NoteEvent = machine.NoteEvent;
const Effect = chain_mod.Effect;

pub const MAX_LANES = 8;
/// Effects one lane holds (docs/42 §Capacities).
pub const MAX_LANE_EFFECTS = 16;
/// Racks nest this deep: a top rack is level 0.
pub const MAX_DEPTH = 3;
const MAX_BLOCK = engine.MAX_BLOCK;
const MAX_EVENTS = 512;
const MAX_HELD = 32;
const MAX_LABEL = 31;
const PRESET_FILE = 256 * 1024;
pub const SIDE_W: i32 = 200;
const PICK_MENU_KEY: u64 = 0x5241434b; // "RACK"
/// The longest latency lanes are aligned over: what a lane's line holds.
const MAX_ALIGN = chain_mod.DRY_LEN - MAX_BLOCK;

/// The registry paths: a directory with presets/ and no .fy.
pub const PATH = "machines/rack/rack";
pub const FX_PATH = "machines/fxrack/fxrack";

pub const Kind = enum { instrument, effect };

/// A lane's three zones (docs/42 §UI): the keys, velocities and CHAIN
/// values it plays at.
pub const Zone = enum { key, vel, chain };

pub const MAX_MACROS = 8;
pub const MAX_MAPS = 64;
/// Control index of CHAIN, after the macros.
pub const CHAIN = MAX_MACROS;
pub const CONTROLS = MAX_MACROS + 1;
const CONTROL_IDS = [CONTROLS][]const u8{ "rk-m1", "rk-m2", "rk-m3", "rk-m4", "rk-m5", "rk-m6", "rk-m7", "rk-m8", "rk-chain" };
const MACRO_LABELS = [MAX_MACROS][]const u8{ "MACRO 1", "MACRO 2", "MACRO 3", "MACRO 4", "MACRO 5", "MACRO 6", "MACRO 7", "MACRO 8" };

pub const Name = struct {
    buf: [MAX_LABEL + 1]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn set(self: *Name, s: []const u8) void {
        const n = @min(s.len, MAX_LABEL);
        @memcpy(self.buf[0..n], s[0..n]);
        self.buf[n] = 0;
        self.len = @intCast(n);
    }
};

/// What a mapping moves: a machine's control in the lane, or the lane's
/// own level (dB) or pan (-1..1).
pub const TargetKind = enum(u8) { control, level, pan };

/// One macro → one target (docs/42 §Mappings). `min` and `max` are in the
/// target's knob space (a continuous control's norm, a stepped one's raw
/// value; dB for level), so a target with a curve keeps it.
pub const Mapping = struct {
    macro: u8 = 0,
    lane: u8 = 0,
    target: TargetKind = .control,
    /// The insert's chain uid; null = the lane's instrument.
    slot: ?u16 = null,
    control: u16 = 0,
    stepped: bool = false,
    min: f32 = 0,
    max: f32 = 1,
    program: formula.Program = .{},
    text: [formula.MAX_TEXT + 1]u8 = @splat(0),
    text_len: u8 = 0,
    /// The text doesn't compile; `program` is the last one that did.
    bad: bool = false,

    pub fn textSlice(self: *const Mapping) []const u8 {
        return self.text[0..self.text_len];
    }

    /// The target's value for macro `x`, the macros being `m`.
    pub fn value(self: *const Mapping, x: f32, m: *const [MAX_MACROS]f32) f32 {
        const t = self.program.eval(x, m);
        const v = self.min + (self.max - self.min) * t;
        return if (self.stepped) @round(v) else v;
    }

    pub fn sameTarget(a: *const Mapping, b: *const Mapping) bool {
        return a.lane == b.lane and a.target == b.target and
            (a.target != .control or (a.slot == b.slot and a.control == b.control));
    }
};

/// Audio: a control the rack set last chunk.
const Applied = struct { state: *anyopaque, set: machine.SetModFn, control: u16, value: f32 };

const Held = struct { channel: u8, id: i32, pitch: f32 };

/// An effect rack's lanes have no instrument: this one, which plays nothing.
var silent_state: u8 = 0;
fn silentRender(_: *anyopaque, _: *const machine.MachineCtx, _: []f32, _: []f32) void {}
fn silentReset(_: *anyopaque) void {}
fn silentPanel(_: *anyopaque, _: *Ui, _: Rect) void {}
const silent = Machine{ .name = "none", .state = &silent_state, .render = silentRender, .reset = silentReset, .draw_panel = silentPanel };

pub const Lane = struct {
    /// The chain's publication; `instrument` and `effects` are its
    /// editable side (UI only).
    chain: *chain_mod.State,
    /// Which lane it is while others come and go: automation inside the
    /// rack addresses it by this (docs/42 §Automation inside a rack).
    uid: u8 = 0,
    instrument: Machine = silent,
    /// Registry index of the instrument; null in an effect rack.
    reg_idx: ?u8 = null,
    effects: std.ArrayList(Effect) = .empty,
    /// The line that holds this lane back to the slowest lane (audio).
    line: *chain_mod.DryLine,
    label: [MAX_LABEL + 1]u8 = @splat(0),
    label_len: u8 = 0,
    // Settings are copied from the UI configuration at block boundaries.
    lo: u8 = 0,
    hi: u8 = 127,
    vlo: u8 = 1,
    vhi: u8 = 127,
    /// The CHAIN values it plays at (docs/42 §UI zones).
    clo: u8 = 0,
    chi: u8 = 127,
    /// Semitones, whole: a lane's fine tuning is its instrument's.
    transpose: i8 = 0,
    level_db: f32 = 0,
    pan: f32 = 0,
    /// Notes at once, 0 = the instrument's own voices.
    poly: u8 = 0,
    mute: bool = false,
    solo: bool = false,
    // Audio thread: the notes this lane is holding, oldest first.
    held: [MAX_HELD]Held = undefined,
    held_n: u8 = 0,
    /// Audio thread: the delay its line holds now.
    delay: u32 = 0,

    pub fn labelSlice(self: *const Lane) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn setLabel(self: *Lane, s: []const u8) void {
        const n = @min(s.len, MAX_LABEL);
        @memcpy(self.label[0..n], s[0..n]);
        self.label[n] = 0;
        self.label_len = @intCast(n);
    }

    /// The lane's `z` zone, lo and hi.
    pub fn zone(self: *Lane, z: Zone) [2]*u8 {
        return switch (z) {
            .key => .{ &self.lo, &self.hi },
            .vel => .{ &self.vlo, &self.vhi },
            .chain => .{ &self.clo, &self.chi },
        };
    }

    fn takes(self: *const Lane, pitch: f32, vel: f32) bool {
        const k: i32 = @intFromFloat(@round(pitch));
        const v: i32 = @intFromFloat(@round(std.math.clamp(vel, 0, 1) * 127));
        return k >= self.lo and k <= self.hi and v >= self.vlo and v <= self.vhi;
    }

    /// Audio: samples its output is late, instrument and active inserts.
    fn latency(self: *Lane) u32 {
        var n = self.chain.audio_machine.latencySamples();
        for (self.chain.audioEffects()) |*fx| {
            if (!fx.bypass.load(.monotonic) or fx.dry_line >= 0) n += fx.mach.latencySamples();
        }
        return n;
    }

    /// Audio: how long it rings on after its input stops (docs/04 §Idle
    /// skipping), its instrument's tail and every insert's in turn.
    fn tail(self: *Lane, sample_rate: f64) u32 {
        var n = self.chain.audio_machine.idleHold(sample_rate, 0);
        if (n == machine.TAIL_FOREVER) return n;
        for (self.chain.audioEffects()) |*fx| {
            const h = fx.mach.idleHold(sample_rate, 0);
            if (h == machine.TAIL_FOREVER) return h;
            n +|= h;
        }
        return n;
    }
};

const LaneVersion = struct {
    lanes: [MAX_LANES]Lane = undefined,
    count: usize = 0,
    generation: u64 = 0,
    maps: [MAX_MAPS]Mapping = undefined,
    map_count: usize = 0,
};
const RetiredLane = struct { chain: *chain_mod.State, instrument: Machine, effects: std.ArrayList(Effect), line: *chain_mod.DryLine };

pub const Rack = struct {
    alloc: std.mem.Allocator,
    reg: *registry_mod.Registry,
    kind: Kind,
    /// How deep it sits in other racks: 0 on a track.
    level: u8 = 0,
    lanes: [MAX_LANES]Lane = undefined,
    count: usize = 0,
    versions: handoff.Latest(LaneVersion) = .init(.{}),
    retired: handoff.Retirement(RetiredLane, 128) = .{},
    generation: u64 = 0, // UI-owned
    next_lane_uid: u8 = 0,
    publication_depth: usize = 0,
    audio_lanes: [MAX_LANES]Lane = undefined,
    audio_count: usize = 0,

    // UI
    selected: usize = 0,
    /// Folded to its face: the macro knobs alone (docs/42 §Collapsed face).
    collapsed: bool = false,
    presets: presets_mod.List = .{},
    current_preset: i32 = -1,
    /// A lane or an insert came or went since the project last asked.
    edited: bool = false,
    macro_names: [MAX_MACROS]Name = @splat(.{}),
    maps: [MAX_MAPS]Mapping = undefined,
    map_count: usize = 0,
    /// The automated value each control shows (null: no lane), set by the
    /// host every frame.
    ui_auto: [CONTROLS]?f32 = @splat(null),
    touch: ?machine.Touch = null,
    // The macro block (UI): the picked macro and mapping, MAP armed, the
    // control a MAP click already took, and the name and formula fields.
    sel_macro: usize = 0,
    sel_map: ?usize = null,
    map_armed: bool = false,
    map_held: ?struct { state: *anyopaque, control: u16 } = null,
    name_tb: text_field.TextBuf = .{},
    name_for: ?usize = null,
    formula_tb: text_field.TextBuf = .{},
    formula_for: ?usize = null,
    /// Which zones the lane map shows and the range fields edit.
    zone_tab: Zone = .key,
    /// Where a drag on the lane map started (0..127).
    zone_from: ?u8 = null,
    /// An insert's name tile pressed (`armed`), dragging once it travels.
    fx_drag: struct { armed: bool = false, active: bool = false, src: usize = 0, press_x: f32 = 0 } = .{},

    // Macros, UI writes and audio reads: the hand-set value in knob space
    // (CHAIN's raw 0..127), and a count a jump (preset, project) bumps.
    hand: [CONTROLS]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0)),
    snaps: [CONTROLS]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0)),
    wake: std.atomic.Value(bool) = .init(false),
    /// Audio: what each macro plays now, the smoothed hand value unless a
    /// lane or an outer rack's macro drives it.
    cur: [CONTROLS]f32 = @splat(0),
    eff: [CONTROLS]f32 = @splat(0),
    seen_snaps: [CONTROLS]u32 = @splat(0),
    primed: bool = false,
    auto_on: [CONTROLS]bool = @splat(false),
    auto_val: [CONTROLS]f32 = @splat(0),
    mod_on: [CONTROLS]bool = @splat(false),
    mod_val: [CONTROLS]f32 = @splat(0),
    applied: [MAX_MAPS]Applied = undefined,
    applied_n: usize = 0,
    lane_level: [MAX_LANES]?f32 = @splat(null),
    lane_pan: [MAX_LANES]?f32 = @splat(null),

    // audio scratch
    sl: [MAX_BLOCK]f32 = undefined,
    sr: [MAX_BLOCK]f32 = undefined,
    fl: [MAX_BLOCK]f32 = undefined,
    fr: [MAX_BLOCK]f32 = undefined,
    events: [MAX_EVENTS]NoteEvent = undefined,
    chunk_events: [MAX_EVENTS]NoteEvent = undefined,

    pub fn create(alloc: std.mem.Allocator, reg: *registry_mod.Registry, kind: Kind) !*Rack {
        const self = try alloc.create(Rack);
        self.* = .{ .alloc = alloc, .reg = reg, .kind = kind };
        self.rescan();
        return self;
    }

    pub fn machineInterface(self: *Rack) Machine {
        return .{
            .name = if (self.kind == .effect) "FX Rack" else "Rack",
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .adopt_updates = adoptImpl,
            .deinit = deinitImpl,
            .preset_count = presetCountImpl,
            .preset_name = presetNameImpl,
            .apply_preset = applyPresetImpl,
            .save_preset_named = savePresetNamedImpl,
            .save_preset_library = savePresetLibraryImpl,
            .current_preset = currentPresetImpl,
            .mark_preset = markPresetImpl,
            .write_state_json = writeStateJsonImpl,
            .apply_state_json = applyStateJsonImpl,
            .take_edited = takeEditedImpl,
            .latency = latencyImpl,
            .tail = tailImpl,
            .take_wake = takeWakeImpl,
            .control_count = controlCountImpl,
            .control_info = controlInfoImpl,
            .control_value = controlValueImpl,
            .control_knob = controlKnobImpl,
            .control_base = controlBaseImpl,
            .format_control = formatControlImpl,
            .set_auto_ui = setAutoUiImpl,
            .take_touch = takeTouchImpl,
            .set_mod = setModImpl,
            .child = childImpl,
            .write_params_json = writeParamsJsonImpl,
            .set_param = setParamImpl,
            .panel_w_fn = panelWImpl,
            .host_titlebar = true,
            // Lanes get the notes, bends included; most of them play it.
            .takes_expression = self.kind == .instrument,
            .panel_w = MACRO_W + SIDE_W + 200,
        };
    }

    fn disposeMachine(self: *Rack, m: Machine) void {
        if (m.deinit) |d| d(m.state, self.alloc);
    }

    fn disposeLane(self: *Rack, l: RetiredLane) void {
        self.disposeMachine(l.instrument);
        var fx = l.effects;
        for (fx.items) |*e| {
            self.disposeMachine(e.mach);
            if (e.shared_io) |io| self.alloc.destroy(io);
        }
        fx.deinit(self.alloc);
        l.chain.destroy(self.alloc);
        self.alloc.destroy(l.line);
    }

    fn collect(self: *Rack) void {
        self.retired.collect(self, disposeLane);
        for (self.lanes[0..self.count]) |*l| l.chain.collect(self.alloc);
    }

    fn publishLanes(self: *Rack) void {
        if (self.publication_depth != 0) return;
        self.generation += 1;
        const v = self.versions.write();
        v.count = self.count;
        v.generation = self.generation;
        @memcpy(v.lanes[0..self.count], self.lanes[0..self.count]);
        v.map_count = self.map_count;
        @memcpy(v.maps[0..self.map_count], self.maps[0..self.map_count]);
        self.versions.publish();
    }

    /// Audio: the newest lane list, and each lane's newest chain.
    fn adoptLanes(self: *Rack) void {
        if (self.versions.adopt()) {
            machine.codeBarrier();
            const v = self.versions.current();
            const previous = self.audio_lanes;
            const n = self.audio_count;
            for (v.lanes[0..v.count], 0..) |p, i| {
                self.audio_lanes[i] = p;
                self.audio_lanes[i].held_n = 0;
                self.audio_lanes[i].delay = 0;
                for (previous[0..n]) |old| if (old.chain == p.chain) {
                    self.audio_lanes[i].held = old.held;
                    self.audio_lanes[i].held_n = old.held_n;
                    self.audio_lanes[i].delay = old.delay;
                    break;
                };
            }
            self.audio_count = v.count;
            self.retired.acknowledge(v.generation);
        }
        for (self.audio_lanes[0..self.audio_count]) |*l| {
            // A new instrument hears none of the notes already held.
            if (l.chain.adopt() and l.chain.apply()) l.held_n = 0;
        }
    }

    fn rescan(self: *Rack) void {
        self.presets = presets_mod.scanMachine(self.presetDir(), self.id());
    }

    pub fn id(self: *const Rack) []const u8 {
        return if (self.kind == .effect) "fxrack" else "rack";
    }

    fn presetDir(self: *const Rack) []const u8 {
        return if (self.kind == .effect) "machines/fxrack/presets" else "machines/rack/presets";
    }

    // ── lanes ────────────────────────────────────────────────────────

    /// UI thread: prepare a machine in a private compiler/image and reset
    /// it before publication. Audio keeps using its adopted configuration.
    /// A rack goes one level deeper than this one, MAX_DEPTH at most.
    fn instantiate(self: *Rack, reg_idx: usize) !Machine {
        const nested = self.reg.entries[reg_idx].native != .none;
        if (nested and self.level + 1 >= MAX_DEPTH) return error.RackTooDeep;
        const m = try self.reg.instantiatePrepared(reg_idx);
        if (nested) {
            const inner: *Rack = @ptrCast(@alignCast(m.state));
            inner.level = self.level + 1;
        }
        m.reset(m.state);
        return m;
    }

    /// The next uid no lane has.
    fn freeLaneUid(self: *Rack) u8 {
        while (true) {
            const u = self.next_lane_uid;
            self.next_lane_uid +%= 1;
            for (self.lanes[0..self.count]) |*l| {
                if (l.uid == u) break;
            } else return u;
        }
    }

    fn newLane(self: *Rack, inst: Machine, reg_idx: ?u8) !*Lane {
        if (self.count >= MAX_LANES) return error.RackFull;
        const ch = try chain_mod.State.create(self.alloc, inst);
        errdefer ch.destroy(self.alloc);
        const line = try self.alloc.create(chain_mod.DryLine);
        @memset(std.mem.asBytes(line), 0);
        self.lanes[self.count] = .{ .chain = ch, .uid = self.freeLaneUid(), .instrument = inst, .reg_idx = reg_idx, .line = line };
        self.count += 1;
        self.publishLanes();
        return &self.lanes[self.count - 1];
    }

    /// Append a lane: in an instrument rack, one playing registry machine
    /// `reg_idx` over all keys; in an effect rack, an empty one (a dry
    /// path) that `reg_idx`, when given, becomes the first insert of.
    pub fn addLane(self: *Rack, reg_idx: ?usize) !*Lane {
        if (self.count >= MAX_LANES) return error.RackFull;
        if (self.kind == .instrument) {
            const idx = reg_idx orelse return error.NoInstrument;
            const m = try self.instantiate(idx);
            errdefer self.disposeMachine(m);
            const l = try self.newLane(m, @intCast(idx));
            l.setLabel(self.reg.entries[idx].nameSlice());
            return l;
        }
        const l = try self.newLane(silent, null);
        if (reg_idx) |idx| {
            try self.addEffect(self.count - 1, idx);
            l.setLabel(self.reg.entries[idx].nameSlice());
        } else l.setLabel("DRY");
        return l;
    }

    /// Swap lane `i`'s instrument for registry machine `reg_idx`, keeping
    /// its ranges, mix and inserts.
    pub fn replaceInstrument(self: *Rack, i: usize, reg_idx: usize) !void {
        if (i >= self.count or self.kind != .instrument) return;
        self.collect();
        const m = try self.instantiate(reg_idx);
        const l = &self.lanes[i];
        l.chain.replaceInstrument(self.alloc, &l.instrument, l.effects.items, m) catch |e| {
            self.disposeMachine(m);
            return e;
        };
        l.reg_idx = @intCast(reg_idx);
        l.setLabel(self.reg.entries[reg_idx].nameSlice());
        self.dropMaps(i, .instrument);
    }

    /// Append registry machine `reg_idx` to lane `i`'s inserts.
    pub fn addEffect(self: *Rack, i: usize, reg_idx: usize) !void {
        if (i >= self.count) return error.InvalidLane;
        const l = &self.lanes[i];
        if (l.effects.items.len >= MAX_LANE_EFFECTS) return error.TooManyEffects;
        const m = try self.instantiate(reg_idx);
        l.chain.addEffect(self.alloc, l.instrument, &l.effects, m, @intCast(reg_idx)) catch |e| {
            self.disposeMachine(m);
            return e;
        };
    }

    pub fn removeEffect(self: *Rack, i: usize, j: usize) void {
        if (i >= self.count) return;
        const l = &self.lanes[i];
        if (j < l.effects.items.len) self.dropMaps(i, .{ .insert = l.effects.items[j].uid });
        l.chain.removeEffect(self.alloc, l.instrument, &l.effects, j) catch {};
    }

    pub fn replaceEffect(self: *Rack, i: usize, j: usize, reg_idx: usize) !void {
        if (i >= self.count) return error.InvalidLane;
        const l = &self.lanes[i];
        const m = try self.instantiate(reg_idx);
        if (j < l.effects.items.len) self.dropMaps(i, .{ .insert = l.effects.items[j].uid });
        l.chain.replaceEffect(self.alloc, l.instrument, l.effects.items, j, m, @intCast(reg_idx)) catch |e| {
            self.disposeMachine(m);
            return e;
        };
    }

    pub fn moveEffect(self: *Rack, i: usize, from: usize, to: usize) void {
        if (i >= self.count) return;
        const l = &self.lanes[i];
        l.chain.moveEffect(l.instrument, &l.effects, from, to);
    }

    pub fn setEffectBypass(self: *Rack, i: usize, j: usize, on: bool) void {
        if (i >= self.count) return;
        const l = &self.lanes[i];
        if (j >= l.effects.items.len) return;
        l.effects.items[j].bypass.store(on, .monotonic);
        l.chain.publish(l.instrument, l.effects.items);
    }

    // ── macros and mappings ──────────────────────────────────────────

    /// UI: set control `i` (a macro's 0..1, CHAIN's 0..127) by hand;
    /// `jump` skips the glide (presets, projects).
    pub fn setMacro(self: *Rack, i: usize, knob: f32, jump: bool) void {
        if (i >= CONTROLS) return;
        const v = if (i == CHAIN) std.math.clamp(@round(knob), 0, 127) else std.math.clamp(knob, 0, 1);
        self.hand[i].store(@bitCast(v), .monotonic);
        if (jump) _ = self.snaps[i].fetchAdd(1, .monotonic);
        self.wake.store(true, .release);
    }

    pub fn macroBase(self: *const Rack, i: usize) f32 {
        return @bitCast(self.hand[i].load(.monotonic));
    }

    pub fn macroLabel(self: *const Rack, i: usize) []const u8 {
        if (i == CHAIN) return "CHAIN";
        const n = self.macro_names[i].slice();
        return if (n.len > 0) n else MACRO_LABELS[i];
    }

    /// The machine a mapping's target sits on, UI side.
    pub fn targetMachine(self: *Rack, m: *const Mapping) ?Machine {
        if (m.target != .control or m.lane >= self.count) return null;
        const l = &self.lanes[m.lane];
        const uid = m.slot orelse return if (l.reg_idx != null) l.instrument else null;
        for (l.effects.items) |*fx| if (fx.uid == uid) return fx.mach;
        return null;
    }

    /// Add mapping `m`, replacing one on the same macro and target. Its
    /// steppedness comes from the target.
    pub fn addMapping(self: *Rack, m: Mapping) !*Mapping {
        var mm = m;
        if (mm.macro >= MAX_MACROS or mm.lane >= self.count) return error.InvalidTarget;
        if (mm.target == .control) {
            const t = self.targetMachine(&mm) orelse return error.InvalidTarget;
            if (mm.control >= t.controlCount()) return error.InvalidTarget;
            mm.stepped = t.control_info.?(t.state, mm.control).stepped;
        } else mm.stepped = false;
        for (self.maps[0..self.map_count]) |*x| if (x.macro == mm.macro and x.sameTarget(&mm)) {
            x.* = mm;
            return x;
        };
        if (self.map_count >= MAX_MAPS) return error.TooManyMappings;
        self.maps[self.map_count] = mm;
        self.map_count += 1;
        self.publishLanes();
        return &self.maps[self.map_count - 1];
    }

    pub fn removeMapping(self: *Rack, k: usize) void {
        if (k >= self.map_count) return;
        var j = k;
        while (j + 1 < self.map_count) : (j += 1) self.maps[j] = self.maps[j + 1];
        self.map_count -= 1;
        self.publishLanes();
    }

    /// Set a mapping's formula text. Text that doesn't compile is kept,
    /// marked bad, and the last good program keeps running.
    pub fn setFormula(m: *Mapping, text: []const u8) void {
        const n = @min(text.len, formula.MAX_TEXT);
        @memcpy(m.text[0..n], text[0..n]);
        m.text[n] = 0;
        m.text_len = @intCast(n);
        if (formula.compile(m.text[0..n])) |prog| {
            m.program = prog;
            m.bad = false;
        } else |_| m.bad = true;
    }

    /// The target's control name, or LEVEL / PAN.
    pub fn targetLabel(self: *Rack, m: *const Mapping) []const u8 {
        return switch (m.target) {
            .level => "LEVEL",
            .pan => "PAN",
            .control => if (self.targetMachine(m)) |t| t.control_info.?(t.state, m.control).label else "?",
        };
    }

    fn formatTarget(self: *Rack, m: *const Mapping, knob: f32, buf: []u8) []const u8 {
        switch (m.target) {
            .level => return std.fmt.bufPrint(buf, "{d:.0}", .{knob}) catch "?",
            .pan => return std.fmt.bufPrint(buf, "{d:.1}", .{knob}) catch "?",
            .control => {
                const t = self.targetMachine(m) orelse return "?";
                const f = t.format_control orelse return std.fmt.bufPrint(buf, "{d:.2}", .{knob}) catch "?";
                return f(t.state, m.control, knob, buf);
            },
        }
    }

    /// One MIN/MAX step (`d` steps, Shift ×10): a hundredth of a knob's
    /// travel, a stepped control's next value, a dB, a tenth of pan.
    fn stepTarget(self: *Rack, m: *const Mapping, knob: f32, d: i32) f32 {
        const df: f32 = @floatFromInt(d);
        return switch (m.target) {
            .level => std.math.clamp(knob + df, -60, 12),
            .pan => std.math.clamp(knob + 0.1 * df, -1, 1),
            .control => blk: {
                if (!m.stepped) break :blk std.math.clamp(knob + 0.01 * df, 0, 1);
                const t = self.targetMachine(m) orelse break :blk knob;
                const info = t.control_info.?(t.state, m.control);
                break :blk std.math.clamp(knob + std.math.sign(df), info.lo, info.hi);
            },
        };
    }

    /// MAP: put control `control` of `t` (lane `li`, insert `slot`) on the
    /// picked macro over its whole range, once per press.
    fn mapTouched(self: *Rack, li: usize, slot: ?u16, t: Machine, control: u16) void {
        if (!self.map_armed) return;
        if (self.map_held) |h| if (h.state == t.state and h.control == control) return;
        self.map_held = .{ .state = t.state, .control = control };
        const info = t.control_info orelse return;
        const ci = info(t.state, control);
        beforeEdit(self);
        const m = self.addMapping(.{
            .macro = @intCast(self.sel_macro),
            .lane = @intCast(li),
            .slot = slot,
            .control = control,
            .min = if (ci.stepped) ci.lo else 0,
            .max = if (ci.stepped) ci.hi else 1,
        }) catch return;
        self.sel_map = (@intFromPtr(m) - @intFromPtr(&self.maps[0])) / @sizeOf(Mapping);
        self.formula_for = null;
    }

    /// MAP: lane `li`'s level or pan on the picked macro, from off (or
    /// hard left) up to where it is now (or hard right).
    fn mapLane(self: *Rack, li: usize, what: TargetKind) void {
        const l = &self.lanes[li];
        beforeEdit(self);
        const m = self.addMapping(.{
            .macro = @intCast(self.sel_macro),
            .lane = @intCast(li),
            .target = what,
            .min = if (what == .level) -60 else -1,
            .max = if (what == .level) l.level_db else 1,
        }) catch return;
        self.sel_map = (@intFromPtr(m) - @intFromPtr(&self.maps[0])) / @sizeOf(Mapping);
        self.formula_for = null;
    }

    const Drop = union(enum) { lane, instrument, insert: u16 };

    /// Drop the mappings onto lane `i` (all of it, its instrument, or one
    /// insert by uid).
    fn dropMaps(self: *Rack, i: usize, what: Drop) void {
        var k: usize = 0;
        while (k < self.map_count) {
            const m = &self.maps[k];
            const hit = m.lane == i and switch (what) {
                .lane => true,
                .instrument => m.target == .control and m.slot == null,
                .insert => |uid| m.target == .control and m.slot != null and m.slot.? == uid,
            };
            if (hit) self.removeMapping(k) else k += 1;
        }
    }

    /// Move lane `from` to `to`, its mappings with it.
    pub fn moveLane(self: *Rack, from: usize, to: usize) void {
        if (from >= self.count or to >= self.count or from == to) return;
        const l = self.lanes[from];
        if (from < to) {
            var j = from;
            while (j < to) : (j += 1) self.lanes[j] = self.lanes[j + 1];
        } else {
            var j = from;
            while (j > to) : (j -= 1) self.lanes[j] = self.lanes[j - 1];
        }
        self.lanes[to] = l;
        for (self.maps[0..self.map_count]) |*m| {
            if (m.lane == from) {
                m.lane = @intCast(to);
            } else if (from < to and m.lane > from and m.lane <= to) {
                m.lane -= 1;
            } else if (to < from and m.lane >= to and m.lane < from) m.lane += 1;
        }
        self.publishLanes();
    }

    fn retireLane(self: *Rack, generation: u64, l: *Lane) void {
        self.retired.append(generation, .{ .chain = l.chain, .instrument = l.instrument, .effects = l.effects, .line = l.line });
    }

    pub fn removeLane(self: *Rack, i: usize) void {
        if (i >= self.count) return;
        self.collect();
        if (!self.retired.available()) return;
        const next_generation = self.generation + 1;
        var old = self.lanes[i];
        var j = i;
        while (j + 1 < self.count) : (j += 1) self.lanes[j] = self.lanes[j + 1];
        self.count -= 1;
        self.dropMaps(i, .lane);
        for (self.maps[0..self.map_count]) |*m| if (m.lane > i) {
            m.lane -= 1;
        };
        self.publishLanes();
        self.retireLane(next_generation, &old);
        if (self.selected >= self.count and self.selected > 0) self.selected -= 1;
    }

    pub fn clear(self: *Rack) !void {
        self.collect();
        if (self.retired.len + self.count > 128) return error.PublicationFull;
        const next_generation = self.generation + 1;
        const n = self.count;
        var old: [MAX_LANES]Lane = undefined;
        @memcpy(old[0..n], self.lanes[0..n]);
        self.count = 0;
        self.map_count = 0;
        self.publishLanes();
        for (old[0..n]) |*l| self.retireLane(next_generation, l);
        self.selected = 0;
    }

    /// Apply one machine's saved settings (params, then files, then zone
    /// edits, then its own state), as a project load does for a track's.
    /// With no params, a named preset is the settings (rigs written by
    /// hand: {"machine":"amp2","preset":"guitar-clean"}).
    fn applyMachineJson(m: Machine, po: std.json.ObjectMap) void {
        const preset: ?usize = if (po.get("preset")) |nv| (if (nv == .string) presetIndex(m, nv.string) else null) else null;
        if (po.get("params") == null) if (preset) |pi| if (m.apply_preset) |apply| apply(m.state, @intCast(pi));
        if (po.get("params")) |pv| if (pv == .object) if (m.set_param) |set| {
            var it = pv.object.iterator();
            while (it.next()) |kv| set(m.state, kv.key_ptr.*, jsonF64(kv.value_ptr.*));
        };
        if (po.get("assets")) |av| if (av == .object) if (m.load_asset) |load| {
            var it = av.object.iterator();
            while (it.next()) |kv| if (kv.value_ptr.* == .string) {
                _ = load(m.state, kv.key_ptr.*, kv.value_ptr.string);
            };
        };
        if (po.get("zones")) |zv| if (m.apply_zones_json) |f| f(m.state, zv);
        if (po.get("state")) |sv| if (m.apply_state_json) |f| f(m.state, sv);
        // The preset it was set from, for its title strip.
        if (preset) |pi| if (m.mark_preset) |mark| mark(m.state, @intCast(pi));
    }

    /// Give `to` the settings of `from`, the same machine (registry entry
    /// `reg_idx`), through the form a rack saves it in: params, files, zones,
    /// state and preset label. Grouping into a rack and out of one use it.
    pub fn copySettings(self: *Rack, from: Machine, to: Machine, reg_idx: u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        try self.writeMachineJson(&out, self.alloc, from, reg_idx);
        try out.append(self.alloc, '}');
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, out.items, .{});
        defer parsed.deinit();
        if (parsed.value == .object) applyMachineJson(to, parsed.value.object);
    }

    fn presetIndex(m: Machine, name: []const u8) ?usize {
        const count = m.preset_count orelse return null;
        const name_of = m.preset_name orelse return null;
        for (0..count(m.state)) |i| {
            if (std.mem.eql(u8, std.mem.span(name_of(m.state, @intCast(i))), name)) return i;
        }
        return null;
    }

    fn machineOf(self: *Rack, v: ?std.json.Value) ?usize {
        const o = v orelse return null;
        if (o != .object) return null;
        const mid = if (o.object.get("machine")) |x| (if (x == .string) x.string else return null) else return null;
        return self.reg.findById(mid);
    }

    /// A lane's ranges, transpose and mix from `po`.
    fn applyLaneSettings(l: *Lane, po: std.json.ObjectMap) void {
        if (po.get("name")) |x| if (x == .string) l.setLabel(x.string);
        if (po.get("lo")) |x| l.lo = jsonU7(x);
        if (po.get("hi")) |x| l.hi = jsonU7(x);
        if (po.get("vlo")) |x| l.vlo = jsonU7(x);
        if (po.get("vhi")) |x| l.vhi = jsonU7(x);
        if (po.get("clo")) |x| l.clo = jsonU7(x);
        if (po.get("chi")) |x| l.chi = jsonU7(x);
        if (po.get("transpose")) |x| l.transpose = @intFromFloat(std.math.clamp(@round(jsonF64(x)), -48, 48));
        if (po.get("level")) |x| l.level_db = @floatCast(std.math.clamp(jsonF64(x), -60, 12));
        if (po.get("pan")) |x| l.pan = @floatCast(std.math.clamp(jsonF64(x), -1, 1));
        if (po.get("poly")) |x| l.poly = @intFromFloat(std.math.clamp(@round(jsonF64(x)), 0, 64));
        if (po.get("mute")) |x| l.mute = x == .bool and x.bool;
        if (po.get("solo")) |x| l.solo = x == .bool and x.bool;
    }

    /// Replace every lane with those in `v`: {"rack":2,"lanes":[…]}, or the
    /// first form {"parts":[…]}. Machines the registry doesn't have are
    /// skipped, and so are racks past MAX_DEPTH.
    pub fn applyJson(self: *Rack, v: std.json.Value) void {
        if (v != .object) return;
        self.publication_depth += 1;
        defer {
            self.publication_depth -= 1;
            self.publishLanes();
        }
        if (v.object.get("lanes")) |lv| {
            if (lv != .array) return;
            self.clear() catch return;
            for (lv.array.items) |item| {
                if (item != .object) continue;
                const po = item.object;
                const l = if (self.kind == .instrument) blk: {
                    const idx = self.machineOf(po.get("instrument")) orelse continue;
                    const lane = self.addLane(idx) catch continue;
                    applyMachineJson(lane.instrument, po.get("instrument").?.object);
                    break :blk lane;
                } else self.addLane(null) catch continue;
                const li = self.count - 1;
                if (po.get("effects")) |ev| if (ev == .array) for (ev.array.items) |fv| {
                    const idx = self.machineOf(fv) orelse continue;
                    self.addEffect(li, idx) catch continue;
                    const fx = &l.effects.items[l.effects.items.len - 1];
                    applyMachineJson(fx.mach, fv.object);
                    if (fv.object.get("bypass")) |b| if (b == .bool and b.bool) fx.bypass.store(true, .monotonic);
                };
                applyLaneSettings(l, po);
                l.chain.publish(l.instrument, l.effects.items);
            }
            self.applyMacrosJson(v.object);
            if (v.object.get("collapsed")) |x| self.collapsed = x == .bool and x.bool;
        } else if (v.object.get("parts")) |pv| {
            // The first form: instrument lanes, no inserts.
            if (pv != .array or self.kind != .instrument) return;
            self.clear() catch return;
            for (pv.array.items) |item| {
                if (item != .object) continue;
                const idx = self.machineOf(item) orelse continue;
                const l = self.addLane(idx) catch continue;
                applyMachineJson(l.instrument, item.object);
                applyLaneSettings(l, item.object);
            }
        } else return;
        self.selected = 0;
    }

    /// Macro names and values, CHAIN, and the mappings, once the lanes
    /// they reach are in.
    fn applyMacrosJson(self: *Rack, o: std.json.ObjectMap) void {
        for (&self.macro_names, 0..) |*n, i| {
            n.* = .{};
            self.setMacro(i, 0, true);
        }
        self.setMacro(CHAIN, 0, true);
        if (o.get("macros")) |mv| if (mv == .array) for (mv.array.items[0..@min(mv.array.items.len, MAX_MACROS)], 0..) |item, i| {
            if (item != .object) continue;
            if (item.object.get("name")) |x| if (x == .string) self.macro_names[i].set(x.string);
            if (item.object.get("value")) |x| self.setMacro(i, @floatCast(jsonF64(x)), true);
        };
        if (o.get("chain")) |x| self.setMacro(CHAIN, @floatCast(jsonF64(x)), true);
        const mv = o.get("maps") orelse return;
        if (mv != .array) return;
        for (mv.array.items) |item| {
            if (item != .object) continue;
            const mo = item.object;
            var m = Mapping{};
            const macro = if (mo.get("macro")) |x| jsonF64(x) else continue;
            const lane = if (mo.get("lane")) |x| jsonF64(x) else continue;
            if (macro < 1 or macro > MAX_MACROS or lane < 1 or lane > @as(f64, @floatFromInt(self.count))) continue;
            m.macro = @intFromFloat(macro - 1);
            m.lane = @intFromFloat(lane - 1);
            const l = &self.lanes[m.lane];
            if (mo.get("target")) |x| if (x == .string) {
                m.target = std.meta.stringToEnum(TargetKind, x.string) orelse continue;
            };
            var tm: ?Machine = null;
            if (m.target == .control) {
                if (mo.get("insert")) |x| {
                    const n = jsonF64(x);
                    if (n < 1 or n > @as(f64, @floatFromInt(l.effects.items.len))) continue;
                    m.slot = l.effects.items[@intFromFloat(n - 1)].uid;
                }
                tm = self.targetMachine(&m) orelse continue;
                const cid = if (mo.get("control")) |x| (if (x == .string) x.string else continue) else continue;
                m.control = @intCast(tm.?.controlIndex(cid) orelse continue);
            }
            inline for (.{ "min", "max" }) |k| if (mo.get(k)) |x| {
                const real = jsonF64(x);
                @field(m, k) = if (tm) |t| (if (t.control_knob) |f| f(t.state, m.control, real) else @floatCast(real)) else @floatCast(real);
            };
            if (mo.get("formula")) |x| if (x == .string) setFormula(&m, x.string);
            _ = self.addMapping(m) catch continue;
        }
    }

    fn writeMacrosJson(self: *Rack, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        try out.appendSlice(alloc, ",\"macros\":[");
        for (0..MAX_MACROS) |i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"name\":");
            try jsonString(out, alloc, self.macro_names[i].slice());
            try out.print(alloc, ",\"value\":{d}}}", .{self.macroBase(i)});
        }
        try out.print(alloc, "],\"chain\":{d},\"maps\":[", .{self.macroBase(CHAIN)});
        for (self.maps[0..self.map_count], 0..) |*m, k| {
            if (k > 0) try out.append(alloc, ',');
            try out.print(alloc, "{{\"macro\":{d},\"lane\":{d}", .{ m.macro + 1, m.lane + 1 });
            var lo: f64 = m.min;
            var hi: f64 = m.max;
            if (m.target != .control) {
                try out.print(alloc, ",\"target\":\"{s}\"", .{@tagName(m.target)});
            } else if (self.targetMachine(m)) |t| {
                if (m.slot) |uid| for (self.lanes[m.lane].effects.items, 0..) |*fx, j| if (fx.uid == uid) {
                    try out.print(alloc, ",\"insert\":{d}", .{j + 1});
                };
                try out.appendSlice(alloc, ",\"control\":");
                try jsonString(out, alloc, t.control_info.?(t.state, m.control).id);
                if (t.control_value) |f| {
                    lo = f(t.state, m.control, m.min);
                    hi = f(t.state, m.control, m.max);
                }
            }
            try out.print(alloc, ",\"min\":{d},\"max\":{d}", .{ lo, hi });
            if (m.text_len > 0) {
                try out.appendSlice(alloc, ",\"formula\":");
                try jsonString(out, alloc, m.textSlice());
            }
            try out.append(alloc, '}');
        }
        try out.append(alloc, ']');
    }

    fn writeMachineJson(self: *Rack, out: *std.ArrayList(u8), alloc: std.mem.Allocator, m: Machine, reg_idx: u8) !void {
        try out.appendSlice(alloc, "{\"machine\":");
        try jsonString(out, alloc, self.reg.entries[reg_idx].idSlice());
        if (m.write_params_json) |f| {
            try out.appendSlice(alloc, ",\"params\":");
            try f(m.state, out, alloc);
        }
        inline for (.{ .{ "assets", "write_assets_json" }, .{ "zones", "write_zones_json" } }) |kv| {
            if (@field(m, kv[1])) |f| {
                const at = out.items.len;
                try out.appendSlice(alloc, ",\"" ++ kv[0] ++ "\":");
                const before = out.items.len;
                try f(m.state, out, alloc);
                if (out.items.len == before) out.shrinkRetainingCapacity(at);
            }
        }
        if (m.write_state_json) |f| {
            try out.appendSlice(alloc, ",\"state\":");
            try f(m.state, out, alloc);
        }
        if (m.current_preset) |cf| if (m.preset_name) |name_of| {
            const cur = cf(m.state);
            if (cur >= 0) {
                try out.appendSlice(alloc, ",\"preset\":");
                try jsonString(out, alloc, std.mem.span(name_of(m.state, @intCast(cur))));
            }
        };
    }

    pub fn writeJson(self: *Rack, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        try out.print(alloc, "{{\"rack\":2,\"kind\":\"{s}\",\"lanes\":[", .{@tagName(self.kind)});
        for (self.lanes[0..self.count], 0..) |*l, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"name\":");
            try jsonString(out, alloc, l.labelSlice());
            try out.print(alloc, ",\"lo\":{d},\"hi\":{d},\"vlo\":{d},\"vhi\":{d},\"clo\":{d},\"chi\":{d},\"transpose\":{d},\"level\":{d},\"pan\":{d},\"poly\":{d},\"mute\":{s},\"solo\":{s}", .{
                l.lo, l.hi, l.vlo, l.vhi, l.clo, l.chi, l.transpose, l.level_db, l.pan, l.poly, if (l.mute) "true" else "false", if (l.solo) "true" else "false",
            });
            if (l.reg_idx) |ri| {
                try out.appendSlice(alloc, ",\"instrument\":");
                try self.writeMachineJson(out, alloc, l.instrument, ri);
                try out.append(alloc, '}');
            }
            try out.appendSlice(alloc, ",\"effects\":[");
            for (l.effects.items, 0..) |*fx, j| {
                if (j > 0) try out.append(alloc, ',');
                try self.writeMachineJson(out, alloc, fx.mach, fx.idx orelse 0);
                try out.print(alloc, ",\"bypass\":{s}}}", .{if (fx.bypass.load(.monotonic)) "true" else "false"});
            }
            try out.appendSlice(alloc, "]}");
        }
        try out.append(alloc, ']');
        try self.writeMacrosJson(out, alloc);
        if (self.collapsed) try out.appendSlice(alloc, ",\"collapsed\":true");
        try out.append(alloc, '}');
    }

    // ── audio ────────────────────────────────────────────────────────

    /// Events for lane `p` out of the block's `in`: its notes transposed,
    /// the oldest released first when it is at its cap, and everything
    /// that isn't a note. Returns how many.
    fn route(p: *Lane, in: []const NoteEvent, out: []NoteEvent, open: bool) usize {
        var n: usize = 0;
        for (in) |ev| {
            if (n + 2 > out.len) break;
            switch (ev.kind) {
                .note_on => if (ev.velocity > 0) {
                    if (!open or !p.takes(ev.pitch, ev.velocity)) continue;
                    const cap: usize = if (p.poly > 0) @min(p.poly, MAX_HELD) else MAX_HELD;
                    if (p.held_n >= cap) {
                        var off = ev;
                        off.kind = .note_off;
                        off.channel = p.held[0].channel;
                        off.note_id = p.held[0].id;
                        off.pitch = p.held[0].pitch;
                        off.velocity = 0;
                        out[n] = off;
                        n += 1;
                        dropHeld(p, 0);
                    }
                    var on = ev;
                    on.pitch = ev.pitch + @as(f32, @floatFromInt(p.transpose));
                    p.held[p.held_n] = .{ .channel = ev.channel, .id = ev.note_id, .pitch = on.pitch };
                    p.held_n += 1;
                    out[n] = on;
                    n += 1;
                } else if (releaseHeld(p, ev)) |off| {
                    out[n] = off;
                    n += 1;
                },
                .note_off => if (releaseHeld(p, ev)) |off| {
                    out[n] = off;
                    n += 1;
                },
                // Expression carries a pitch: transpose it like the note.
                .expression => if (findHeld(p, ev) != null) {
                    var e = ev;
                    e.pitch = ev.pitch + @as(f32, @floatFromInt(p.transpose));
                    out[n] = e;
                    n += 1;
                },
                .pressure, .slide, .glide, .note_hold => if (findHeld(p, ev)) |h| {
                    var e = ev;
                    e.pitch = p.held[h].pitch;
                    out[n] = e;
                    n += 1;
                },
                .reset => {
                    p.held_n = 0;
                    out[n] = ev;
                    n += 1;
                },
                else => {
                    out[n] = ev;
                    n += 1;
                },
            }
        }
        return n;
    }

    fn findHeld(p: *const Lane, ev: NoteEvent) ?usize {
        for (p.held[0..p.held_n], 0..) |h, i| {
            if (h.channel == ev.channel and h.id == ev.note_id) return i;
        }
        return null;
    }

    fn dropHeld(p: *Lane, i: usize) void {
        var j = i;
        while (j + 1 < p.held_n) : (j += 1) p.held[j] = p.held[j + 1];
        p.held_n -= 1;
    }

    /// The note-off for a note this lane holds, at the pitch it played.
    fn releaseHeld(p: *Lane, ev: NoteEvent) ?NoteEvent {
        const i = findHeld(p, ev) orelse return null;
        var off = ev;
        off.kind = .note_off;
        off.pitch = p.held[i].pitch;
        dropHeld(p, i);
        return off;
    }

    /// Audio: the slowest lane's latency, which every lane is held to.
    fn latency(self: *Rack) u32 {
        var n: u32 = 0;
        for (self.audio_lanes[0..self.audio_count]) |*l| n = @max(n, l.latency());
        return @min(n, MAX_ALIGN);
    }
};

fn adoptImpl(state: *anyopaque) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.adoptLanes();
    for (self.audio_lanes[0..self.audio_count]) |*l| {
        const m = &l.chain.audio_machine;
        if (m.adopt_updates) |f| f(m.state);
        for (l.chain.audioEffects()) |*fx| if (fx.mach.adopt_updates) |f| f(fx.mach.state);
    }
}

fn renderImpl(state: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    const frames = @min(@as(usize, ctx.block_size), @min(l.len, @min(r.len, MAX_BLOCK)));
    // An effect rack's input, read before the output (they may alias).
    var in_l: [MAX_BLOCK]f32 = undefined;
    var in_r: [MAX_BLOCK]f32 = undefined;
    if (self.kind == .effect) {
        if (ctx.audio_in) |ports| if (ctx.audio_in_count >= 2) {
            @memcpy(in_l[0..frames], ports[0][0..frames]);
            @memcpy(in_r[0..frames], ports[1][0..frames]);
        } else {
            @memset(in_l[0..frames], 0);
            @memset(in_r[0..frames], 0);
        } else {
            @memset(in_l[0..frames], 0);
            @memset(in_r[0..frames], 0);
        }
    }
    @memset(l[0..frames], 0);
    @memset(r[0..frames], 0);
    self.adoptLanes();
    if (frames == 0) return;

    // Macros that move reach their targets every SMOOTH_CHUNK samples, as
    // automation reaches a machine's own knobs; steady ones once a block.
    const view: ?*const snapshot.AutoView = if (ctx.automation) |p| @ptrCast(@alignCast(p)) else null;
    const auto = if (view) |v| v.any() else false;
    if (!auto) @memset(self.auto_on[0..], false);
    const mapped = self.versions.current().map_count > 0;
    const chunk: usize = if (mapped and (auto or macrosGliding(self))) fy_raw.SMOOTH_CHUNK else frames;
    const beats_per_sample = ctx.tempo_bpm / (60.0 * ctx.sample_rate);
    var pos: usize = 0;
    while (pos < frames) : (pos += chunk) {
        const n = @min(chunk, frames - pos);
        const beat = ctx.ppq_position + @as(f64, @floatFromInt(pos)) * beats_per_sample;
        if (auto) evalAutomation(self, view.?, beat);
        advanceMacros(self, n, ctx.sample_rate);
        if (mapped or self.applied_n > 0) applyMaps(self);
        renderLanes(self, ctx, pos, n, beat, in_l[pos..], in_r[pos..], l[pos..][0..n], r[pos..][0..n]);
    }
}

/// Frames [pos, pos+n) of the block through every lane, summed into
/// `l`/`r`.
fn renderLanes(self: *Rack, ctx: *const machine.MachineCtx, pos: usize, n: usize, beat: f64, in_l: []const f32, in_r: []const f32, l: []f32, r: []f32) void {
    const whole = pos == 0 and n == ctx.block_size;
    const all: []const NoteEvent = if (ctx.note_in) |p| p[0..ctx.note_in_count] else &.{};
    // This window's events, re-based; late offsets land in the last one.
    var in: []const NoteEvent = all;
    if (!whole) {
        var c: usize = 0;
        const last = pos + n >= ctx.block_size;
        for (all) |e| {
            const at: usize = e.sample_offset;
            if ((at >= pos and at < pos + n) or (last and at >= pos + n)) {
                if (c == self.chunk_events.len) break;
                self.chunk_events[c] = e;
                self.chunk_events[c].sample_offset = @intCast(@min(at, pos + n - 1) - pos);
                c += 1;
            }
        }
        in = self.chunk_events[0..c];
    }
    const total = self.latency();
    const chain_at: u8 = @intFromFloat(std.math.clamp(self.eff[CHAIN], 0, 127));
    var solo = false;
    for (self.audio_lanes[0..self.audio_count]) |*p| solo = solo or p.solo;
    const view: ?*const snapshot.AutoView = if (ctx.automation) |v| @ptrCast(@alignCast(v)) else null;
    for (self.audio_lanes[0..self.audio_count], 0..) |*p, li| {
        // The track's lanes reach a lane's machines a step down the rack:
        // its instrument at slot 0, each insert at its uid (renderEffects
        // moves the step's slot along the chain).
        var lane_view: snapshot.AutoView = undefined;
        var sub = ctx.*;
        sub.block_size = @intCast(n);
        sub.ppq_position = beat;
        sub.automation = null;
        if (view) |v| {
            lane_view = v.into(.{ .lane = p.uid, .slot = 0 });
            sub.automation = &lane_view;
        }
        sub.note_out = null;
        sub.note_out_cap = 0;
        sub.note_out_count = null;
        sub.audio_in = null;
        sub.audio_in_count = 0;
        // MUTE, another lane's SOLO, or a CHAIN outside its zone closes the
        // lane's input: no new notes, no audio in. What it holds rings out
        // and is heard.
        const open = !p.mute and (!solo or p.solo) and chain_at >= p.clo and chain_at <= p.chi;
        if (self.kind == .instrument) {
            const k = Rack.route(p, in, &self.events, open);
            sub.note_in = if (k > 0) &self.events else null;
            sub.note_in_count = @intCast(k);
            @memset(self.sl[0..n], 0);
            @memset(self.sr[0..n], 0);
            const m = &p.chain.audio_machine;
            m.render(m.state, &sub, self.sl[0..n], self.sr[0..n]);
        } else {
            sub.note_in = null;
            sub.note_in_count = 0;
            if (open) {
                @memcpy(self.sl[0..n], in_l[0..n]);
                @memcpy(self.sr[0..n], in_r[0..n]);
            } else {
                @memset(self.sl[0..n], 0);
                @memset(self.sr[0..n], 0);
            }
        }
        var out = engine.RenderedPair{ .l = self.sl[0..n], .r = self.sr[0..n] };
        if (p.chain.audio_effect_count > 0) {
            out = engine.renderEffects(p.chain, sub, self.sl[0..n], self.sr[0..n], self.fl[0..n], self.fr[0..n], .{ .on = true, .wake = p.held_n > 0 });
        }
        // Held back to the slowest lane.
        const d = total -| p.latency();
        if (d > 0 or p.delay > 0) {
            const line = p.line;
            const mask = chain_mod.DRY_LEN - 1;
            if (d != p.delay) {
                // A new alignment: what the line held was for another delay.
                @memset(&line.l, 0);
                @memset(&line.r, 0);
                line.w = 0;
                p.delay = d;
            }
            for (0..n) |k| {
                const w = (line.w + k) & mask;
                line.l[w] = out.l[k];
                line.r[w] = out.r[k];
                const rd = (line.w + k + chain_mod.DRY_LEN - d) & mask;
                out.l[k] = line.l[rd];
                out.r[k] = line.r[rd];
            }
            line.w = (line.w + n) & mask;
        }
        const level = self.lane_level[li] orelse p.level_db;
        const pan = self.lane_pan[li] orelse p.pan;
        const g = std.math.pow(f32, 10, level / 20);
        const gl = g * @min(1, 1 - pan);
        const gr = g * @min(1, 1 + pan);
        for (l, r, out.l, out.r) |*ol, *or_, a, b| {
            ol.* += a * gl;
            or_.* += b * gr;
        }
    }
}

// ── macros, audio side ───────────────────────────────────────────────

fn handAudio(self: *const Rack, i: usize) f32 {
    return @bitCast(self.hand[i].load(.monotonic));
}

/// Audio: a hand-set macro still gliding to where the hand left it.
fn macrosGliding(self: *const Rack) bool {
    if (!self.primed) return false;
    for (0..MAX_MACROS) |i| {
        if (self.mod_on[i] or self.auto_on[i]) continue;
        if (self.snaps[i].load(.monotonic) != self.seen_snaps[i]) continue;
        if (self.cur[i] != handAudio(self, i)) return true;
    }
    return false;
}

/// Audio: evaluate the rack's own lanes (its macros and CHAIN) at `beat`.
fn evalAutomation(self: *Rack, view: *const snapshot.AutoView, machine_beat: f64) void {
    const beat = view.hold_beat orelse machine_beat;
    @memset(self.auto_on[0..], false);
    const snap = view.snap;
    for (snap.lanes[0..snap.lane_count], 0..) |lane, li| {
        if (!view.matches(lane) or lane.control >= CONTROLS) continue;
        const lb = lane.localBeat(beat) orelse continue;
        self.auto_on[lane.control] = true;
        self.auto_val[lane.control] = automation.evalCursor(view.points(lane), lb, &view.cursors[li]);
    }
}

/// Audio: what each control plays over the next `n` samples. An outer
/// rack's macro wins, then a lane; a hand-set value glides as a knob does.
fn advanceMacros(self: *Rack, n: usize, sample_rate: f64) void {
    const a: f32 = @floatCast(1.0 - @exp(-@as(f64, @floatFromInt(n)) / (fy_raw.SMOOTH_TAU_S * sample_rate)));
    for (0..CONTROLS) |i| {
        const target = handAudio(self, i);
        const sn = self.snaps[i].load(.monotonic);
        if (!self.primed or sn != self.seen_snaps[i] or i == CHAIN) {
            self.cur[i] = target;
            self.seen_snaps[i] = sn;
        } else if (self.cur[i] != target) {
            var c = self.cur[i] + (target - self.cur[i]) * a;
            if (@abs(target - c) < fy_raw.SMOOTH_EPS) c = target;
            self.cur[i] = c;
        }
        self.eff[i] = if (self.mod_on[i]) self.mod_val[i] else if (self.auto_on[i]) self.auto_val[i] else self.cur[i];
    }
    self.primed = true;
}

fn liveMachine(self: *Rack, st: *anyopaque) bool {
    for (self.audio_lanes[0..self.audio_count]) |*p| {
        if (p.chain.audio_machine.state == st) return true;
        for (p.chain.audioEffects()) |*fx| if (fx.mach.state == st) return true;
    }
    return false;
}

/// Audio: every mapping's target to its macro's value; controls no
/// mapping sets any more go back to their own.
fn applyMaps(self: *Rack) void {
    const v = self.versions.current();
    @memset(self.lane_level[0..], null);
    @memset(self.lane_pan[0..], null);
    var now: [MAX_MAPS]Applied = undefined;
    var nn: usize = 0;
    const macros: *const [MAX_MACROS]f32 = self.eff[0..MAX_MACROS];
    for (v.maps[0..v.map_count]) |*m| {
        if (m.lane >= self.audio_count) continue;
        const val = m.value(macros[m.macro], macros);
        const p = &self.audio_lanes[m.lane];
        switch (m.target) {
            .level => self.lane_level[m.lane] = val,
            .pan => self.lane_pan[m.lane] = val,
            .control => {
                var fx: ?*Effect = null;
                const mach: *Machine = if (m.slot) |uid| blk: {
                    for (p.chain.audioEffects()) |*e| if (e.uid == uid) {
                        fx = e;
                        break :blk &e.mach;
                    };
                    continue;
                } else &p.chain.audio_machine;
                const set = mach.set_mod orelse continue;
                const was: ?f32 = for (self.applied[0..self.applied_n]) |x| {
                    if (x.state == mach.state and x.control == m.control) break x.value;
                } else null;
                // A quiet insert wakes for a new value.
                if (fx) |e| if (was == null or was.? != val) {
                    e.quiet = 0;
                };
                set(mach.state, m.control, val);
                const dup = for (now[0..nn]) |*x| {
                    if (x.state == mach.state and x.control == m.control) break x;
                } else null;
                if (dup) |x| x.value = val else {
                    now[nn] = .{ .state = mach.state, .set = set, .control = m.control, .value = val };
                    nn += 1;
                }
            },
        }
    }
    for (self.applied[0..self.applied_n]) |x| {
        const kept = for (now[0..nn]) |y| {
            if (y.state == x.state and y.control == x.control) break true;
        } else false;
        if (!kept and liveMachine(self, x.state)) x.set(x.state, x.control, null);
    }
    @memcpy(self.applied[0..nn], now[0..nn]);
    self.applied_n = nn;
}

// ── controls (docs/22) ───────────────────────────────────────────────

fn controlCountImpl(_: *anyopaque) usize {
    return CONTROLS;
}

fn controlInfoImpl(state: *anyopaque, i: usize) machine.ControlInfo {
    const self: *Rack = @ptrCast(@alignCast(state));
    if (i == CHAIN) return .{ .id = CONTROL_IDS[i], .label = "CHAIN", .module = "MACROS", .stepped = true, .lo = 0, .hi = 127 };
    return .{ .id = CONTROL_IDS[@min(i, CHAIN)], .label = self.macroLabel(@min(i, CHAIN)), .module = "MACROS" };
}

/// Real units are knob space: a macro's 0..1, CHAIN's 0..127.
fn controlValueImpl(_: *anyopaque, _: usize, knob: f32) f64 {
    return knob;
}

fn controlKnobImpl(_: *anyopaque, i: usize, value: f64) f32 {
    const v: f32 = @floatCast(value);
    return if (i == CHAIN) std.math.clamp(@round(v), 0, 127) else std.math.clamp(v, 0, 1);
}

fn controlBaseImpl(state: *anyopaque, i: usize) f32 {
    const self: *Rack = @ptrCast(@alignCast(state));
    return if (i < CONTROLS) self.macroBase(i) else 0;
}

fn formatControlImpl(_: *anyopaque, i: usize, knob: f32, buf: []u8) []const u8 {
    if (i == CHAIN) return std.fmt.bufPrint(buf, "{d}", .{@as(i32, @intFromFloat(@round(knob)))}) catch "?";
    return std.fmt.bufPrint(buf, "{d}%", .{@as(i32, @intFromFloat(@round(knob * 100)))}) catch "?";
}

fn setAutoUiImpl(state: *anyopaque, i: usize, knob: ?f32) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    if (i < CONTROLS) self.ui_auto[i] = knob;
}

fn takeTouchImpl(state: *anyopaque) ?machine.Touch {
    const self: *Rack = @ptrCast(@alignCast(state));
    const t = self.touch;
    self.touch = null;
    return t;
}

/// UI: the lanes' machines in order, each lane's instrument (slot 0) then
/// its inserts (their uids).
fn childImpl(state: *anyopaque, i: usize) ?machine.Child {
    const self: *Rack = @ptrCast(@alignCast(state));
    var k = i;
    for (self.lanes[0..self.count], 0..) |*l, li| {
        const has_inst = l.reg_idx != null;
        const n = l.effects.items.len + @intFromBool(has_inst);
        if (k >= n) {
            k -= n;
            continue;
        }
        if (has_inst and k == 0) return .{ .step = .{ .lane = l.uid, .slot = 0 }, .lane = @intCast(li), .pos = 0, .mach = &l.instrument };
        const j = k - @intFromBool(has_inst);
        const fx = &l.effects.items[j];
        return .{ .step = .{ .lane = l.uid, .slot = fx.uid }, .lane = @intCast(li), .pos = @intCast(j + 1), .mach = &fx.mach };
    }
    return null;
}

/// A rack in a lane: the outer rack's macro drives this one's.
fn setModImpl(state: *anyopaque, i: usize, knob: ?f32) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    if (i >= CONTROLS) return;
    if (knob) |k| {
        self.mod_on[i] = true;
        self.mod_val[i] = if (i == CHAIN) std.math.clamp(@round(k), 0, 127) else std.math.clamp(k, 0, 1);
    } else self.mod_on[i] = false;
}

fn writeParamsJsonImpl(state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void {
    const self: *Rack = @ptrCast(@alignCast(state));
    try out.append(alloc, '{');
    for (CONTROL_IDS, 0..) |cid, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.print(alloc, "\"{s}\":{d}", .{ cid, self.macroBase(i) });
    }
    try out.append(alloc, '}');
}

fn setParamImpl(state: *anyopaque, pid: []const u8, value: f64) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    for (CONTROL_IDS, 0..) |cid, i| if (std.mem.eql(u8, cid, pid)) self.setMacro(i, controlKnobImpl(state, i, value), true);
}

fn latencyImpl(state: *anyopaque) u32 {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.adoptLanes();
    return self.latency();
}

fn tailImpl(state: *anyopaque, sample_rate: f64) u32 {
    const self: *Rack = @ptrCast(@alignCast(state));
    var n: u32 = 0;
    for (self.audio_lanes[0..self.audio_count]) |*l| {
        const t = l.tail(sample_rate);
        if (t == machine.TAIL_FOREVER) return t;
        n = @max(n, t);
    }
    return n;
}

/// A control edit on any machine inside wakes the rack, and the insert it
/// landed on renders again however long it has been quiet.
fn takeWakeImpl(state: *anyopaque) bool {
    const self: *Rack = @ptrCast(@alignCast(state));
    var any = self.wake.swap(false, .acquire);
    for (self.audio_lanes[0..self.audio_count]) |*l| {
        if (l.chain.audio_machine.takeWake()) any = true;
        for (l.chain.audioEffects()) |*fx| if (fx.mach.takeWake()) {
            fx.quiet = 0;
            any = true;
        };
    }
    return any;
}

fn takeEditedImpl(state: *anyopaque) bool {
    const self: *Rack = @ptrCast(@alignCast(state));
    var any = self.edited;
    self.edited = false;
    for (self.lanes[0..self.count]) |*l| {
        if (l.instrument.takeEdited()) any = true;
        for (l.effects.items) |*fx| if (fx.mach.takeEdited()) {
            any = true;
        };
    }
    return any;
}

fn resetImpl(state: *anyopaque) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.adoptLanes();
    for (self.audio_lanes[0..self.audio_count]) |*p| {
        p.held_n = 0;
        const m = &p.chain.audio_machine;
        m.reset(m.state);
        for (p.chain.audioEffects()) |*fx| {
            fx.mach.reset(fx.mach.state);
            fx.quiet = 0;
        }
        if (p.delay > 0) {
            @memset(&p.line.l, 0);
            @memset(&p.line.r, 0);
        }
    }
}

fn deinitImpl(state: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    // Device/consumer stopped before destruction.
    for (self.lanes[0..self.count]) |*l| self.disposeLane(.{ .chain = l.chain, .instrument = l.instrument, .effects = l.effects, .line = l.line });
    self.retired.drain(self, Rack.disposeLane);
    alloc.destroy(self);
}

// ── presets ──────────────────────────────────────────────────────────

fn presetCountImpl(state: *anyopaque) machine.PresetIndex {
    const self: *Rack = @ptrCast(@alignCast(state));
    return @intCast(self.presets.count);
}

fn presetNameImpl(state: *anyopaque, index: machine.PresetIndex) [*:0]const u8 {
    const self: *Rack = @ptrCast(@alignCast(state));
    if (index >= self.presets.count) return "";
    return self.presets.names[index].z();
}

fn currentPresetImpl(state: *anyopaque) i32 {
    const self: *Rack = @ptrCast(@alignCast(state));
    return self.current_preset;
}

fn markPresetImpl(state: *anyopaque, index: i32) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.current_preset = if (index >= 0 and index < self.presets.count) index else -1;
}

fn applyPresetImpl(state: *anyopaque, index: machine.PresetIndex) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    if (index >= self.presets.count) return;
    const buf = self.alloc.alloc(u8, PRESET_FILE) catch return;
    defer self.alloc.free(buf);
    const data = presets_mod.readPreset(buf, self.presetDir(), self.id(), self.presets.names[index].slice()) orelse return;
    var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
    defer parsed.deinit();
    self.applyJson(parsed.value);
    self.current_preset = index;
    // A rig opens as its face: the macros it was built to be played by.
    self.collapsed = true;
}

fn savePresetNamedImpl(state: *anyopaque, name_z: [*:0]const u8) ?machine.PresetIndex {
    const bank: presets_mod.Bank = if (std.mem.endsWith(u8, storage.projectDir(), ".slab")) .project else .user;
    return savePresetIn(state, name_z, bank);
}

fn savePresetLibraryImpl(state: *anyopaque, name_z: [*:0]const u8) ?machine.PresetIndex {
    return savePresetIn(state, name_z, .user);
}

/// Save the rack as preset `name` in `bank` (docs/25 §Save to Library).
/// A project's preset names the package's files relative to it.
fn savePresetIn(state: *anyopaque, name_z: [*:0]const u8, bank: presets_mod.Bank) ?machine.PresetIndex {
    const self: *Rack = @ptrCast(@alignCast(state));
    const bare = std.mem.trim(u8, std.mem.span(name_z), " \t\r\n");
    if (bare.len == 0 or bare.len > presets_mod.MAX_NAME or std.mem.indexOfScalar(u8, bare, '/') != null) return null;
    var nb: [presets_mod.MAX_NAME + 16]u8 = undefined;
    const name = presets_mod.inBank(&nb, bank, bare) orelse return null;
    if (name.len > presets_mod.MAX_NAME) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.alloc);
    out.print(self.alloc, "{{\"slab\":\"preset\",\"schema\":1,\"machine\":\"{s}\",", .{self.id()}) catch return null;
    const at = out.items.len;
    if (bank == .project) storage.beginProjectSave();
    const wrote = self.writeJson(&out, self.alloc);
    if (bank == .project) storage.endProjectSave();
    wrote catch return null;
    // splice the lanes object's body into the preset object
    std.mem.copyForwards(u8, out.items[at..], out.items[at + 1 ..]);
    out.shrinkRetainingCapacity(out.items.len - 1);
    out.append(self.alloc, '\n') catch return null;
    if (!presets_mod.writePreset(self.presetDir(), self.id(), name, out.items)) return null;
    self.rescan();
    for (self.presets.names[0..self.presets.count], 0..) |*pn, i| {
        if (std.mem.eql(u8, pn.slice(), name)) {
            self.current_preset = @intCast(i);
            return @intCast(i);
        }
    }
    return null;
}

// ── project ──────────────────────────────────────────────────────────

fn writeStateJsonImpl(state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void {
    const self: *Rack = @ptrCast(@alignCast(state));
    try self.writeJson(out, alloc);
}

fn applyStateJsonImpl(state: *anyopaque, v: std.json.Value) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.applyJson(v);
}

// ── panel ────────────────────────────────────────────────────────────
//
//   ┌ LANES    [+][−]┐┌[×][INSTRUMENT][preset▾][ON]┐┌[×][INSERT][preset▾][BYP]┐┌+┐
//   │ 1 BASS    [M][S]││ its panel                   ││ its panel            │IO││ │
//   │ 2 CLEAN   [M][S]││                             ││                      │  ││ │
//   │ ▬▬▬▬ key map    ││                             ││                      │  ││ │
//   │ LO  HI  VLO VHI ││                             ││                      │  ││ │
//   │ TRN PLY LVL PAN ││                             ││                      │  ││ │
//   └─────────────────┘└─────────────────────────────┘└──────────────────────┘└──┘
//
// The selected lane's chain draws as the bay draws a track's (nested
// device columns with their own title strips: preset, ON/BYP, replace,
// remove); the + tile adds an insert.

const ROW_H: i32 = 16;
const FIELD_H: i32 = 18;

fn chainW(self: *Rack) i32 {
    if (self.selected >= self.count) return bay.TITLE_H * 6;
    const l = &self.lanes[self.selected];
    var w: i32 = bay.TITLE_H;
    if (l.reg_idx != null) w += bay.panelW(&l.instrument);
    for (l.effects.items) |*fx| w += bay.effectW(fx);
    if (l.reg_idx == null and l.effects.items.len == 0) w += 160;
    return w;
}

fn panelWImpl(state: *anyopaque) f32 {
    const self: *Rack = @ptrCast(@alignCast(state));
    if (self.collapsed) return @floatFromInt(MACRO_W);
    return @floatFromInt(MACRO_W + SIDE_W + chainW(self));
}

fn noteName(buf: []u8, k: u8) []const u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const oct = @as(i32, k / 12) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[k % 12], oct }) catch "?";
}

/// A packed readout: a short legend, then the value in glass with ▴▾
/// steps; returns the step (+/-1, x `big` with Shift).
fn field(ui: *Ui, r: Rect, key: []const u8, label: []const u8, value: []const u8, big: i32) i32 {
    ui.pushId(key);
    defer ui.popId();
    var row = r;
    const lab = row.cutLeft(ui.fonts.legend.measure(label) + 3);
    ui.textIn(&ui.fonts.legend, lab, label, ui_style.text_dim, .left, true);
    ctl.display(ui, row, value, .{ .flush = true });
    const d = ctl.glassSteps(ui, row, "step");
    return if (ui.in.shift) d * big else d;
}

/// `n` equal cells across `r`, 2 px apart.
fn cells(r: Rect, comptime n: usize) [n]Rect {
    var out: [n]Rect = undefined;
    var row = r;
    const ni: i32 = @intCast(n);
    const w = @divFloor(r.w - 2 * (ni - 1), ni);
    for (&out, 0..) |*c, i| {
        c.* = if (i + 1 == n) row else row.cutLeft(w);
        if (i + 1 < n) _ = row.cutLeft(2);
    }
    return out;
}

fn step7(v: *u8, d: i32, lo: i32, hi: i32) void {
    v.* = @intCast(std.math.clamp(@as(i32, v.*) + d, lo, hi));
}

const LANE_COLORS = [_]ui_style.Color{
    ui_style.led_green,                   ui_style.vfd,                            ui_style.accent,                            ui_style.led_green.mix(ui_style.vfd, 0.5),
    ui_style.vfd.mix(ui_style.text, 0.4), ui_style.accent.mix(ui_style.text, 0.4), ui_style.led_green.mix(ui_style.text, 0.4), ui_style.text_dim,
};

/// The lane's label from a picked preset's name.
fn labelFromPreset(l: *Lane, m: Machine, pi: machine.PresetIndex) void {
    var buf: [64]u8 = undefined;
    if (m.preset_name) |pn| l.setLabel(std.fmt.bufPrint(&buf, "{s}", .{lastSegment(std.mem.span(pn(m.state, pi)))}) catch "");
}

/// Before the panel changes what the rack holds: an undo step, and the
/// project is edited.
fn beforeEdit(self: *Rack) void {
    bay.beforeNestedEdit();
    self.edited = true;
}

fn drawPanelImpl(state: *anyopaque, ui: *Ui, rect: Rect) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.collect();
    defer self.publishLanes();
    var body = rect;
    if (self.collapsed) {
        drawFace(self, ui, body);
        return;
    }
    drawMacros(self, ui, body.cutLeft(MACRO_W));
    const side = body.cutLeft(SIDE_W);
    drawLanes(self, ui, side);
    drawChain(self, ui, body);
    pollMapTouch(self);
}

// ── macro block ──────────────────────────────────────────────────────
//
//   ┌ MACROS       [MAP]┐   four knobs a row, two rows; the picked one is
//   │ (o) (o) (o) (o)   │   underlined. NAME names it. A row a mapping:
//   │ (o) (o) (o) (o)   │   × removes it, the label picks it, MIN and MAX
//   │ NAME [DRIVE     ] │   step its range in the target's units. f(x)
//   │ × 1·DRIVE  2  30  │   edits the picked mapping's formula; red until
//   │ × 1·LEVEL  0  -6  │   it parses (the old one keeps running).
//   │ f(x) [x^2       ] │
//   └───────────────────┘

const MACRO_W: i32 = 184;
const RANGE_W: i32 = 44;
const KNOB_LABELS = [MAX_MACROS][]const u8{ "M1", "M2", "M3", "M4", "M5", "M6", "M7", "M8" };

fn drawMacros(self: *Rack, ui: *Ui, r: Rect) void {
    var col = ui.plate(r, .{}).inset(3);
    var head = col.cutTop(ROW_H);
    _ = col.cutTop(2);
    const mapb = head.cutRight(34);
    _ = head.cutRight(2);
    foldButton(self, ui, head.cutRight(ROW_H));
    _ = ui.engraved(&ui.fonts.legend, head.x + 2, head.y + 3, "MACROS", ui_style.text_dim);
    if (ctl.button(ui, mapb, "map", &self.map_armed, .{ .kind = .latch, .label = "MAP", .flush = true, .lit = ui_style.accent })) self.map_held = null;
    menu.tip(ui, mapb, "Map: click a control in the lane, or LV or PN, to put it on the picked macro");

    const cell = ctl.knobCell(.m, true);
    for (0..2) |ri| {
        var row = col.cutTop(cell[1]);
        const cw = @divFloor(row.w, 4);
        for (0..4) |ci| {
            const i = ri * 4 + ci;
            const kr = if (ci == 3) row else row.cutLeft(cw);
            macroKnob(self, ui, kr, i);
            if (i == self.sel_macro) ui.rect(Rect.xywh(kr.x + 6, kr.bottom() - 1, kr.w - 12, 1), if (self.map_armed) ui_style.accent else ui_style.text_dim);
        }
    }
    _ = col.cutTop(3);
    const sel = self.sel_macro;

    // NAME
    var nrow = col.cutTop(ROW_H);
    _ = col.cutTop(2);
    const nl = nrow.cutLeft(ui.fonts.legend.measure("NAME") + 4);
    ui.textIn(&ui.fonts.legend, nl, "NAME", ui_style.text_dim, .left, true);
    if (self.name_for != sel) {
        self.name_tb.set(self.macro_names[sel].slice());
        self.name_for = sel;
    }
    switch (text_field.field(ui, nrow, "name", &self.name_tb, .{ .commit_on_blur = true })) {
        .commit => if (!std.mem.eql(u8, self.name_tb.text(), self.macro_names[sel].slice())) {
            beforeEdit(self);
            self.macro_names[sel].set(std.mem.trim(u8, self.name_tb.text(), " "));
            self.name_for = null;
        },
        .cancel => self.name_for = null,
        else => {},
    }

    // f(x), at the bottom
    var frow = col.cutBottom(ROW_H);
    _ = col.cutBottom(2);

    // a row a mapping of the picked macro
    var shown: usize = 0;
    var k: usize = 0;
    while (k < self.map_count) : (k += 1) {
        const m = &self.maps[k];
        if (m.macro != sel) continue;
        if (col.h < ROW_H) break;
        shown += 1;
        var row = col.cutTop(ROW_H);
        _ = col.cutTop(1);
        ui.pushId(.{ "map", k });
        defer ui.popId();
        const x = row.cutLeft(ROW_H);
        _ = row.cutLeft(2);
        if (ctl.button(ui, x, "rm", null, .{ .label = "\u{00d7}", .flush = true })) {
            beforeEdit(self);
            self.removeMapping(k);
            self.sel_map = null;
            self.formula_for = null;
            break;
        }
        const hi_r = row.cutRight(RANGE_W);
        _ = row.cutRight(2);
        const lo_r = row.cutRight(RANGE_W);
        _ = row.cutRight(2);
        var lb: [40]u8 = undefined;
        var on = self.sel_map == k;
        const text = std.fmt.bufPrint(&lb, "{d}\u{00b7}{s}", .{ m.lane + 1, self.targetLabel(m) }) catch "?";
        if (ctl.button(ui, row, "pick", &on, .{ .kind = .latch, .label = text, .flush = true, .lit = if (m.bad) ui_style.led_red else ui_style.text })) {
            self.sel_map = k;
            self.formula_for = null;
        }
        inline for (.{ .{ "min", lo_r }, .{ "max", hi_r } }) |pr| {
            var vb: [24]u8 = undefined;
            const cur = @field(m, pr[0]);
            const d = field(ui, pr[1], pr[0], "", self.formatTarget(m, cur, &vb), 10);
            if (d != 0) {
                beforeEdit(self);
                @field(m, pr[0]) = self.stepTarget(m, cur, d);
            }
        }
    }
    if (shown == 0) {
        const hint = if (self.map_armed) "CLICK A CONTROL TO MAP" else "NO MAPPINGS";
        ui.textIn(&ui.fonts.legend, col.cutTop(ROW_H), hint, ui_style.text_mute, .center, true);
    }

    // the picked mapping's formula
    const fm: ?*Mapping = if (self.sel_map) |i| (if (i < self.map_count and self.maps[i].macro == sel) &self.maps[i] else null) else null;
    const fl = frow.cutLeft(ui.fonts.legend.measure("f(x)") + 4);
    ui.textIn(&ui.fonts.legend, fl, "f(x)", if (fm != null and fm.?.bad) ui_style.led_red else ui_style.text_dim, .left, true);
    const m = fm orelse {
        ui.rect(frow, ui_style.well);
        return;
    };
    const mi = self.sel_map.?;
    if (self.formula_for != mi) {
        self.formula_tb.set(m.textSlice());
        self.formula_for = mi;
    }
    switch (text_field.field(ui, frow, .{ "formula", mi }, &self.formula_tb, .{ .commit_on_blur = true })) {
        .commit => if (!std.mem.eql(u8, self.formula_tb.text(), m.textSlice())) {
            beforeEdit(self);
            Rack.setFormula(m, std.mem.trim(u8, self.formula_tb.text(), " "));
            self.formula_for = null;
        },
        .cancel => self.formula_for = null,
        else => {},
    }
    menu.tip(ui, frow, "Shapes the macro x (0..1) before the range: x^2, 1 - x, x * (1 - m4), step(x, 3)");
}

/// Macro `i`'s knob, its name for a legend; taking it picks the macro.
fn macroKnob(self: *Rack, ui: *Ui, kr: Rect, i: usize) void {
    ui.pushId(i);
    defer ui.popId();
    var v = self.ui_auto[i] orelse self.macroBase(i);
    const before = v;
    var vb: [8]u8 = undefined;
    const readout = std.fmt.bufPrint(&vb, "{d}", .{@as(i32, @intFromFloat(@round(v * 100)))}) catch "?";
    _ = ctl.knob(ui, kr, "knob", &v, .{ .size = .m, .label = if (self.macro_names[i].len > 0) self.macro_names[i].slice() else KNOB_LABELS[i], .readout = readout });
    if (v != before) self.setMacro(i, v, false);
    if (ui.active == ui.id("knob")) {
        self.touch = .{ .control = @intCast(i), .knob = v };
        if (self.sel_macro != i) self.sel_map = null;
        self.sel_macro = i;
    }
}

fn foldButton(self: *Rack, ui: *Ui, r: Rect) void {
    if (ctl.button(ui, r, "fold", null, .{ .glyph = if (self.collapsed) .tri_right else .tri_left, .flush = true })) {
        self.collapsed = !self.collapsed;
        self.edited = true;
    }
    menu.tip(ui, r, if (self.collapsed) "Open the rack: its lanes and their chains" else "Fold the rack to its macro knobs");
}

/// The folded rack: the macros that do something (named or mapped; all
/// eight when none are), four a row, under a strip with the unfold button.
fn drawFace(self: *Rack, ui: *Ui, r: Rect) void {
    var col = ui.plate(r, .{}).inset(3);
    var head = col.cutTop(ROW_H);
    _ = col.cutTop(2);
    foldButton(self, ui, head.cutRight(ROW_H));
    _ = ui.engraved(&ui.fonts.legend, head.x + 2, head.y + 3, "MACROS", ui_style.text_dim);
    var shown: [MAX_MACROS]usize = undefined;
    var n: usize = 0;
    for (0..MAX_MACROS) |i| {
        const used = self.macro_names[i].len > 0 or for (self.maps[0..self.map_count]) |*m| {
            if (m.macro == i) break true;
        } else false;
        if (used) {
            shown[n] = i;
            n += 1;
        }
    }
    if (n == 0) {
        for (0..MAX_MACROS) |i| shown[i] = i;
        n = MAX_MACROS;
    }
    const cell = ctl.knobCell(.m, true);
    var k: usize = 0;
    while (k < n) {
        var row = col.cutTop(cell[1]);
        const cw = @divFloor(row.w, 4);
        for (0..4) |ci| {
            if (k >= n) break;
            macroKnob(self, ui, row.cutLeft(cw), shown[k]);
            _ = ci;
            k += 1;
        }
    }
}

/// A hand on a control in the open lane: with MAP armed, the first frame
/// puts it on the picked macro over its whole range; otherwise, a control
/// a macro owns moves that macro instead (docs/42 §Reaching the target).
fn pollMapTouch(self: *Rack) void {
    if (self.selected >= self.count) return;
    const li = self.selected;
    const l = &self.lanes[li];
    var held = false;
    if (l.reg_idx != null) if (l.instrument.take_touch) |tt| if (tt(l.instrument.state)) |t| {
        held = true;
        if (self.map_armed) self.mapTouched(li, null, l.instrument, t.control) else handOnMapped(self, li, null, t);
    };
    for (l.effects.items) |*fx| if (fx.mach.take_touch) |tt| if (tt(fx.mach.state)) |t| {
        held = true;
        if (self.map_armed) self.mapTouched(li, fx.uid, fx.mach, t.control) else handOnMapped(self, li, fx.uid, t);
    };
    if (!held) self.map_held = null;
}

/// UI: the macros as the formulas see them.
fn macroValues(self: *const Rack) [MAX_MACROS]f32 {
    var out: [MAX_MACROS]f32 = undefined;
    for (&out, 0..) |*v, i| v.* = self.ui_auto[i] orelse self.macroBase(i);
    return out;
}

/// The macro value that puts mapping `m`'s target nearest `knob`: the
/// formula has no inverse in general, so the best of 257 points, then a
/// finer look around it.
fn invertMapping(m: *const Mapping, knob: f32, macros: [MAX_MACROS]f32) f32 {
    var ms = macros;
    var best: f32 = 0;
    var best_d: f32 = std.math.inf(f32);
    var lo: f32 = 0;
    var span: f32 = 1;
    for (0..2) |_| {
        for (0..257) |k| {
            const x = std.math.clamp(lo + span * @as(f32, @floatFromInt(k)) / 256, 0, 1);
            ms[m.macro] = x;
            const d = @abs(m.value(x, &ms) - knob);
            // Ties go to the point nearest where the macro is.
            if (d < best_d - 1e-6 or (d <= best_d + 1e-6 and @abs(x - macros[m.macro]) < @abs(best - macros[m.macro]))) {
                best = x;
                best_d = d;
            }
        }
        lo = best - 1.0 / 256.0;
        span = 2.0 / 256.0;
    }
    return best;
}

fn handOnMapped(self: *Rack, li: usize, slot: ?u16, t: machine.Touch) void {
    const macros = macroValues(self);
    for (self.maps[0..self.map_count]) |*m| {
        if (m.target != .control or m.lane != li or m.slot != slot or m.control != t.control) continue;
        if (@abs(m.value(macros[m.macro], &macros) - t.knob) < 1e-4) return;
        self.setMacro(m.macro, invertMapping(m, t.knob, macros), false);
        self.touch = .{ .control = m.macro, .knob = self.macroBase(m.macro) };
        return;
    }
}

fn zoneText(buf: []u8, z: Zone, v: u8) []const u8 {
    return if (z == .key) noteName(buf, v) else std.fmt.bufPrint(buf, "{d}", .{v}) catch "?";
}

/// The lane map: a stripe a lane over 0..127 for the shown zone, the
/// selected lane bright; a press and drag sets the selected lane's range.
/// Octave ticks for keys, CHAIN's position for chain zones.
fn drawZoneMap(self: *Rack, ui: *Ui, map: Rect, chain_now: f32) void {
    ui.rect(map, ui_style.well);
    const inner_w = map.w - 4;
    for (self.lanes[0..self.count], 0..) |*p, pi| {
        const z = p.zone(self.zone_tab);
        const x0 = map.x + 2 + @divFloor(inner_w * @as(i32, z[0].*), 128);
        const x1 = map.x + 2 + @divFloor(inner_w * (@as(i32, z[1].*) + 1), 128);
        const col = if (p.mute) ui_style.text_mute else LANE_COLORS[pi];
        ui.rect(Rect.xywh(x0, map.y + 2 + @as(i32, @intCast(pi)) * 3, @max(1, x1 - x0), 2), if (pi == self.selected) col else col.alpha(140));
    }
    switch (self.zone_tab) {
        .key => {
            var k: i32 = 0;
            while (k < 128) : (k += 12) ui.rect(Rect.xywh(map.x + 2 + @divFloor(inner_w * k, 128), map.bottom() - 2, 1, 2), ui_style.text_mute);
        },
        .chain => {
            const cx = map.x + 2 + @divFloor(inner_w * (@as(i32, @intFromFloat(chain_now)) * 2 + 1), 256);
            ui.rect(Rect.xywh(cx, map.y, 1, map.h), ui_style.accent);
        },
        .vel => {},
    }
    if (self.selected >= self.count) return;
    const b = ui.behaviorEx(ui.id("zone-map"), map, .{ .focusable = false });
    const at: u8 = @intCast(std.math.clamp(@divFloor((ui.in.ix() - map.x - 2) * 128, @max(1, inner_w)), 0, 127));
    if (b.pressed) self.zone_from = at;
    if (b.held) if (self.zone_from) |from| {
        const z = self.lanes[self.selected].zone(self.zone_tab);
        const lo = @max(@min(from, at), @as(u8, if (self.zone_tab == .vel) 1 else 0));
        const hi = @max(from, at);
        if (z[0].* != lo or z[1].* != hi) {
            if (b.pressed) beforeEdit(self);
            z[0].* = lo;
            z[1].* = hi;
            self.edited = true;
            self.publishLanes();
        }
    };
    if (!b.held) self.zone_from = null;
    menu.tip(ui, map, "Drag to set the selected lane's zone");
}

fn drawLanes(self: *Rack, ui: *Ui, r: Rect) void {
    const inst = self.kind == .instrument;
    var side = ui.plate(r, .{}).inset(3);

    // header: LANES, + and −
    var head = side.cutTop(ROW_H);
    _ = side.cutTop(2);
    const rm = head.cutRight(ROW_H);
    _ = head.cutRight(2);
    const add = head.cutRight(ROW_H);
    _ = ui.engraved(&ui.fonts.legend, head.x + 2, head.y + 3, "LANES", ui_style.text_dim);
    const akey = pane.keyFromIds(PICK_MENU_KEY, @intFromPtr(self), 2);
    if (self.count < MAX_LANES) {
        if (ctl.button(ui, add, "add", null, .{ .label = "+", .flush = true })) {
            if (inst) {
                if (!menu.isOpen(akey)) {
                    bay.scanRegistryPresets(self.reg);
                    menu.openBelow(akey, add);
                }
            } else if (blk: {
                beforeEdit(self);
                break :blk self.addLane(null);
            }) |_| {
                self.selected = self.count - 1;
            } else |_| {}
        }
        menu.tip(ui, add, if (inst) "Add a lane: another instrument layered or split" else "Add a lane: a dry path to put inserts on");
    }
    if (inst) if (bay.machinePickerMenuFor(akey, self.reg, .instruments)) |pick| {
        beforeEdit(self);
        if (self.addLane(pick.reg_idx)) |np| {
            self.selected = self.count - 1;
            if (pick.preset) |pi| if (np.instrument.apply_preset) |ap| {
                ap(np.instrument.state, pi);
                labelFromPreset(np, np.instrument, pi);
            };
        } else |_| {}
    };
    if (self.count > 0) {
        if (ctl.button(ui, rm, "rm", null, .{ .label = "\u{2212}", .flush = true })) {
            beforeEdit(self);
            self.removeLane(self.selected);
            return;
        }
        menu.tip(ui, rm, "Remove the selected lane");
    }

    // one row a lane: select, MUTE, SOLO
    for (self.lanes[0..self.count], 0..) |*p, i| {
        var row = side.cutTop(ROW_H);
        ui.pushId(i);
        defer ui.popId();
        const so = row.cutRight(ROW_H);
        const mu = row.cutRight(ROW_H);
        _ = row.cutRight(2);
        var on = i == self.selected;
        var lb: [48]u8 = undefined;
        var a: [4]u8 = undefined;
        var b: [4]u8 = undefined;
        const text = if (inst)
            std.fmt.bufPrint(&lb, "{d} {s}  {s}-{s}", .{ i + 1, p.labelSlice(), noteName(&a, p.lo), noteName(&b, p.hi) }) catch "?"
        else
            std.fmt.bufPrint(&lb, "{d} {s}", .{ i + 1, p.labelSlice() }) catch "?";
        if (ctl.button(ui, row, "sel", &on, .{ .kind = .latch, .label = text, .flush = true, .lit = LANE_COLORS[i] })) self.selected = i;
        if (ctl.button(ui, mu, "mute", &p.mute, .{ .kind = .latch, .label = "M", .flush = true, .lit = ui_style.accent })) self.publishLanes();
        menu.tip(ui, mu, "Mute: the lane takes no new notes or input");
        if (ctl.button(ui, so, "solo", &p.solo, .{ .kind = .latch, .label = "S", .flush = true, .lit = ui_style.accent })) self.publishLanes();
        menu.tip(ui, so, "Solo: only soloed lanes take notes or input");
    }
    _ = side.cutTop(3);

    // Zones: KEY, VEL and CHN tabs (an effect rack has CHAIN only), a
    // stripe a lane over 0..127 that a drag sets for the selected lane, and
    // the selected lane's range of it.
    if (!inst) self.zone_tab = .chain;
    if (self.count > 0) {
        var tabs = side.cutTop(ROW_H);
        _ = side.cutTop(2);
        const chain_r = tabs.cutRight(64);
        _ = tabs.cutRight(4);
        if (inst) {
            const tc = cells(tabs, 3);
            inline for (.{ .{ Zone.key, "KEY", "Key zones: the notes each lane plays" }, .{ Zone.vel, "VEL", "Velocity zones: how hard a note must be for each lane" }, .{ Zone.chain, "CHN", "Chain zones: the CHAIN values each lane plays at" } }, 0..) |t, ti| {
                var on = self.zone_tab == t[0];
                if (ctl.button(ui, tc[ti], t[1], &on, .{ .kind = .latch, .label = t[1], .flush = true, .lit = ui_style.text })) self.zone_tab = t[0];
                menu.tip(ui, tc[ti], t[2]);
            }
        } else _ = ui.engraved(&ui.fonts.legend, tabs.x + 2, tabs.y + 3, "CHAIN ZONES", ui_style.text_dim);
        // CHAIN itself, which the chain zones answer to.
        var cb: [8]u8 = undefined;
        const chain_now = self.ui_auto[CHAIN] orelse self.macroBase(CHAIN);
        const dc = field(ui, chain_r, "chain", "CHAIN", std.fmt.bufPrint(&cb, "{d}", .{@as(i32, @intFromFloat(chain_now))}) catch "?", 8);
        if (dc != 0) {
            self.setMacro(CHAIN, chain_now + @as(f32, @floatFromInt(dc)), true);
            self.touch = .{ .control = CHAIN, .knob = self.macroBase(CHAIN) };
            self.edited = true;
        }
        menu.tip(ui, chain_r, "CHAIN: lanes play while it sits inside their chain zone");

        const map = side.cutTop(@intCast(3 * self.count + 6));
        _ = side.cutTop(3);
        drawZoneMap(self, ui, map, chain_now);
    }

    if (self.selected >= self.count) return;
    const p = &self.lanes[self.selected];
    var s = p.*; // edit a copy, publish at the block boundary
    var buf: [16]u8 = undefined;
    {
        const z = s.zone(self.zone_tab);
        const c1 = cells(side.cutTop(FIELD_H), 2);
        const big: i32 = if (self.zone_tab == .key) 12 else 16;
        const lo_lo: i32 = if (self.zone_tab == .vel) 1 else 0;
        var b2: [16]u8 = undefined;
        step7(z[0], field(ui, c1[0], "zlo", "LO", zoneText(&buf, self.zone_tab, z[0].*), big), lo_lo, z[1].*);
        step7(z[1], field(ui, c1[1], "zhi", "HI", zoneText(&b2, self.zone_tab, z[1].*), big), z[0].*, 127);
        _ = side.cutTop(2);
    }
    const c2 = cells(side.cutTop(FIELD_H), 4);
    var at: usize = 0;
    if (inst) {
        const dt = field(ui, c2[0], "trn", "TR", std.fmt.bufPrint(&buf, "{s}{d}", .{ if (s.transpose > 0) "+" else "", s.transpose }) catch "?", 12);
        s.transpose = @intCast(std.math.clamp(@as(i32, s.transpose) + dt, -48, 48));
        const dp = field(ui, c2[1], "poly", "PL", if (s.poly == 0) "ALL" else std.fmt.bufPrint(&buf, "{d}", .{s.poly}) catch "?", 4);
        s.poly = @intCast(std.math.clamp(@as(i32, s.poly) + dp, 0, 32));
        at = 2;
    }
    const dl = field(ui, c2[at], "lvl", "LV", std.fmt.bufPrint(&buf, "{d:.0}", .{s.level_db}) catch "?", 6);
    const dpan = field(ui, c2[at + 1], "pan", "PN", std.fmt.bufPrint(&buf, "{d:.1}", .{s.pan}) catch "?", 5);
    if (self.map_armed) {
        // MAP takes the click: the lane's level or pan goes on the macro.
        if (dl != 0) self.mapLane(self.selected, .level);
        if (dpan != 0) self.mapLane(self.selected, .pan);
    } else {
        s.level_db = std.math.clamp(s.level_db + @as(f32, @floatFromInt(dl)), -60, 12);
        s.pan = std.math.clamp(s.pan + 0.1 * @as(f32, @floatFromInt(dpan)), -1, 1);
    }
    if (@abs(s.pan) < 0.05) s.pan = 0;
    if (s.lo != p.lo or s.hi != p.hi or s.vlo != p.vlo or s.vhi != p.vhi or s.clo != p.clo or s.chi != p.chi or
        s.transpose != p.transpose or s.poly != p.poly or s.level_db != p.level_db or s.pan != p.pan)
    {
        if (s.lo != p.lo or s.hi != p.hi or s.vlo != p.vlo or s.vhi != p.vhi or s.clo != p.clo or s.chi != p.chi) self.edited = true;
        p.lo = s.lo;
        p.hi = s.hi;
        p.vlo = s.vlo;
        p.vhi = s.vhi;
        p.clo = s.clo;
        p.chi = s.chi;
        p.transpose = s.transpose;
        p.poly = s.poly;
        p.level_db = s.level_db;
        p.pan = s.pan;
        self.publishLanes();
    }
}

/// The selected lane's chain as nested bay devices, then the + tile.
fn drawChain(self: *Rack, ui: *Ui, r: Rect) void {
    if (self.selected >= self.count) {
        ui.rect(r, ui_style.well);
        ui.textIn(&ui.fonts.legend, r, "ADD A LANE", ui_style.text_mute, .center, true);
        return;
    }
    const li = self.selected;
    const l = &self.lanes[li];
    ui.pushId(@intFromPtr(l.chain));
    defer ui.popId();
    const map_was = ui.map_mode;
    ui.map_mode = self.map_armed;
    defer ui.map_mode = map_was;
    var res = bay.Result{};
    var x = r.x;
    // Dragging an insert's name tile: the drop slot is the first card whose
    // middle lies right of the pointer, as in the bay.
    var drop_idx: usize = l.effects.items.len;
    var drop_x: i32 = 0;
    {
        var ex = x + (if (l.reg_idx != null) bay.panelW(&l.instrument) else 0);
        for (l.effects.items, 0..) |*fx, j| {
            const fw = bay.effectW(fx);
            if (self.fx_drag.active and drop_idx == l.effects.items.len and ui.in.mx < @as(f32, @floatFromInt(ex + @divFloor(fw, 2)))) {
                drop_idx = j;
                drop_x = ex;
            }
            ex += fw;
        }
        if (drop_idx == l.effects.items.len) drop_x = ex;
    }
    var reorder: ?[2]usize = null;
    if (l.reg_idx != null) {
        const w = bay.panelW(&l.instrument);
        const out = bay.drawDevice(ui, Rect.xywh(x, r.y, w, r.h), &l.instrument, .instrument, null, !l.mute, null, self.reg, &res);
        if (out.toggle) {
            l.mute = !l.mute;
            self.publishLanes();
        }
        x += w;
    }
    for (l.effects.items, 0..) |*fx, j| {
        const w = bay.effectW(fx);
        const out = bay.drawDevice(ui, Rect.xywh(x, r.y, w, r.h), &fx.mach, .{ .effect = j }, fx, !fx.bypass.load(.monotonic), null, self.reg, &res);
        if (out.toggle) self.setEffectBypass(li, j, !fx.bypass.load(.monotonic));
        if (out.name_pressed and !self.fx_drag.armed) self.fx_drag = .{ .armed = true, .src = j, .press_x = ui.in.mx };
        if (out.name_released and self.fx_drag.armed and self.fx_drag.src == j) {
            if (self.fx_drag.active) {
                // Taking the source out shifts the cards after it left.
                const to = if (drop_idx > j) drop_idx - 1 else drop_idx;
                if (to != j) reorder = .{ j, to };
            } else {
                // A click, not a drag: the insert's replace menu, as the bay's.
                const key = pane.keyFromIds(bay.REPLACE_MENU_KEY, @intFromPtr(fx.mach.state), 0);
                if (!menu.isOpen(key)) {
                    bay.scanRegistryPresets(self.reg);
                    menu.openBelow(key, out.name_rect);
                }
            }
            self.fx_drag = .{};
        }
        if (self.fx_drag.active and self.fx_drag.src == j) ui.overlayRect(Rect.xywh(x, r.y, w, r.h), ui_style.accent.alpha(40));
        x += w;
    }
    if (self.fx_drag.armed and ui.in.down and @abs(ui.in.mx - self.fx_drag.press_x) > 6) self.fx_drag.active = true;
    if (self.fx_drag.armed and !ui.in.down and !ui.in.released) self.fx_drag = .{};
    if (self.fx_drag.active) ui.overlayRect(Rect.xywh(drop_x - 1, r.y, 2, r.h), ui_style.accent);
    if (reorder) |mv| {
        beforeEdit(self);
        self.moveEffect(li, mv[0], mv[1]);
    }
    if (l.reg_idx == null and l.effects.items.len == 0) {
        const hint = Rect.xywh(x, r.y, 160, r.h);
        ui.rect(hint, ui_style.well);
        ui.textIn(&ui.fonts.legend, hint, "DRY: + ADDS AN INSERT", ui_style.text_mute, .center, true);
        x += 160;
    }
    // + : an insert at the end of the lane
    const plus = Rect.xywh(x, r.y, bay.TITLE_H, bay.TITLE_H);
    const fkey = pane.keyFromIds(PICK_MENU_KEY, @intFromPtr(self), 3);
    var open = menu.isOpen(fkey);
    if (ctl.button(ui, plus, "addfx", &open, .{ .label = "+", .flush = true }) and !menu.isOpen(fkey)) {
        bay.scanRegistryPresets(self.reg);
        menu.openBelow(fkey, plus);
    }
    menu.tip(ui, plus, "Add an insert to this lane");
    if (x + bay.TITLE_H <= r.right()) _ = ui.plate(Rect.xywh(x, r.y + bay.TITLE_H, bay.TITLE_H, r.h - bay.TITLE_H), .{});
    if (bay.machinePickerMenuFor(fkey, self.reg, .effects)) |pick| {
        beforeEdit(self);
        if (self.addEffect(li, pick.reg_idx)) {
            const fx = &l.effects.items[l.effects.items.len - 1];
            if (pick.preset) |pi| if (fx.mach.apply_preset) |ap| ap(fx.mach.state, pi);
        } else |_| {}
    }

    // What the title strips asked for.
    if (res.remove_ref != null or res.replace_ref != null) beforeEdit(self);
    if (res.remove_ref) |ref| switch (ref) {
        // An instrument lane is its instrument: removing it removes the lane.
        .instrument => {
            self.removeLane(li);
            return;
        },
        .effect => |j| self.removeEffect(li, j),
    };
    if (res.replace_ref) |ref| if (res.replace_machine) |idx| {
        switch (ref) {
            .instrument => self.replaceInstrument(li, idx) catch {},
            .effect => |j| self.replaceEffect(li, j, idx) catch {},
        }
        const m: ?Machine = switch (ref) {
            .instrument => l.instrument,
            .effect => |j| if (j < l.effects.items.len) l.effects.items[j].mach else null,
        };
        if (res.replace_preset) |pi| if (m) |mm| if (mm.apply_preset) |ap| {
            ap(mm.state, pi);
            if (ref == .instrument) labelFromPreset(l, mm, pi);
        };
    };
    const target: ?bay.DeviceRef = res.preset_apply_ref orelse res.preset_save_ref orelse res.preset_rename_ref;
    if (target) |ref| {
        const m: ?Machine = switch (ref) {
            .instrument => l.instrument,
            .effect => |j| if (j < l.effects.items.len) l.effects.items[j].mach else null,
        };
        if (m) |mm| bay.nested_preset = .{
            .mach = mm,
            .apply = res.preset_apply,
            .save = res.preset_save_ref != null and !res.preset_save_library,
            .save_library = res.preset_save_ref != null and res.preset_save_library,
            .rename = if (res.preset_rename_ref != null) res.preset_rename_index else null,
            .anchor = res.preset_anchor,
        };
    }
}

fn lastSegment(s: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
}

// ── json helpers ─────────────────────────────────────────────────────

fn jsonF64(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        .bool => |b| if (b) 1 else 0,
        else => 0,
    };
}

fn jsonU7(v: std.json.Value) u8 {
    return @intFromFloat(std.math.clamp(@round(jsonF64(v)), 0, 127));
}

fn jsonString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        0...0x1f => try out.print(alloc, "\\u{x:0>4}", .{ch}),
        else => try out.append(alloc, ch),
    };
    try out.append(alloc, '"');
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn testCtx(evs: []const NoteEvent, frames: u32) machine.MachineCtx {
    return .{
        .sample_rate = 48000,
        .block_size = frames,
        .block_start = 0,
        .tempo_bpm = 120,
        .ppq_position = 0,
        .transport_state = .playing,
        .note_in = if (evs.len > 0) evs.ptr else null,
        .note_in_count = @intCast(evs.len),
    };
}

fn noteOn(pitch: f32, id: i32) NoteEvent {
    return .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = id, .pitch = pitch, .velocity = 1 };
}

fn noteOff(pitch: f32, id: i32) NoteEvent {
    return .{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = id, .pitch = pitch, .velocity = 0 };
}

/// Blocks of 512 through the rack's machine, first block with `evs`.
fn play(m: Machine, evs: []const NoteEvent, out: []f32) void {
    var r: [512]f32 = undefined;
    var at: usize = 0;
    var first = true;
    while (at + 512 <= out.len) : (at += 512) {
        const ctx = testCtx(if (first) evs else &.{}, 512);
        if (m.adopt_updates) |f| f(m.state);
        m.render(m.state, &ctx, out[at..][0..512], &r);
        first = false;
    }
}

/// Blocks of 256 of `in` (mono, both channels) through an effect `m`.
fn process(m: Machine, in: []const f32, out_l: []f32, out_r: []f32) void {
    var at: usize = 0;
    while (at + 256 <= in.len) : (at += 256) {
        var ctx = testCtx(&.{}, 256);
        const ports = [_][*]const f32{ in[at..].ptr, in[at..].ptr };
        ctx.audio_in = &ports;
        ctx.audio_in_count = 2;
        if (m.adopt_updates) |f| f(m.state);
        m.render(m.state, &ctx, out_l[at..][0..256], out_r[at..][0..256]);
    }
}

/// Pitch by autocorrelation: the lag (50..800 Hz) where the signal best
/// matches itself, refined by a parabola.
fn acHz(x: []const f32) f64 {
    const lo: usize = 48000 / 800;
    const hi: usize = 48000 / 50;
    const n = x.len - hi;
    var best: usize = lo;
    var best_v: f64 = -1e300;
    var vals: [hi + 2]f64 = undefined;
    var lag: usize = lo;
    while (lag <= hi) : (lag += 1) {
        var acc: f64 = 0;
        for (x[0..n], x[lag..][0..n]) |a, b| acc += a * b;
        vals[lag] = acc;
        if (acc > best_v) {
            best_v = acc;
            best = lag;
        }
    }
    // prefer the shortest lag almost as good (not an octave down)
    lag = lo;
    while (lag < best) : (lag += 1) {
        if (vals[lag] > 0.9 * best_v and vals[lag] >= vals[lag - 1] and vals[lag] >= vals[lag + 1]) {
            best = lag;
            break;
        }
    }
    const a = vals[best - 1];
    const b = vals[best];
    const c = vals[best + 1];
    const den = a - 2 * b + c;
    const t = @as(f64, @floatFromInt(best)) + (if (den != 0) 0.5 * (a - c) / den else 0);
    return 48000 / t;
}

fn rms(x: []const f32) f64 {
    var s: f64 = 0;
    for (x) |v| s += v * v;
    return @sqrt(s / @as(f64, @floatFromInt(x.len)));
}

test "rack: a split sends each key to its lane, transposed; POLY releases the oldest; lanes round-trip as JSON" {
    const a = testing.allocator;
    var reg = registry_mod.Registry.init(a);
    defer reg.deinit();
    try reg.loadFyMachine("machines/unfairlight/unfairlight.fy");
    try reg.loadNative();
    const rack = try Rack.create(a, &reg, .instrument);
    const m = rack.machineInterface();
    defer m.deinit.?(m.state, a);

    // lower half plays as keyed, upper half an octave down; both dark
    // enough that zero crossings count the fundamental
    const lo = try rack.addLane(0);
    lo.hi = 59;
    const hi = try rack.addLane(0);
    hi.lo = 60;
    hi.transpose = -12;
    for (rack.lanes[0..2]) |*p| {
        p.instrument.set_param.?(p.instrument.state, "cmi-filter", 60);
        p.instrument.set_param.?(p.instrument.state, "cmi-loop", 1);
    }

    var out: [(512 * 24)]f32 = @splat(0);
    rack.publishLanes();
    // A2 on the lower lane: the bundled pluck (A3) an octave down
    play(m, &.{noteOn(45, 1)}, &out);
    try testing.expectApproxEqRel(@as(f64, 110), acHz(out[512 * 4 ..]), 0.01);
    try testing.expectEqual(@as(u8, 1), rack.audio_lanes[0].held_n);
    try testing.expectEqual(@as(u8, 0), rack.audio_lanes[1].held_n);
    play(m, &.{noteOff(45, 1)}, &out);
    try testing.expectEqual(@as(u8, 0), rack.audio_lanes[0].held_n);
    // A4 on the upper lane, down an octave: A3
    m.reset(m.state);
    play(m, &.{noteOn(69, 2)}, &out);
    try testing.expectApproxEqRel(@as(f64, 220), acHz(out[512 * 4 ..]), 0.01);
    try testing.expectEqual(@as(u8, 1), rack.audio_lanes[1].held_n);
    try testing.expectEqual(@as(f32, 57), rack.audio_lanes[1].held[0].pitch);
    m.reset(m.state);

    // POLY 1: a second note releases the first
    rack.lanes[1].poly = 1;
    var evs: [8]NoteEvent = undefined;
    const in = [_]NoteEvent{ noteOn(72, 3), noteOn(74, 4) };
    const n = Rack.route(&rack.lanes[1], &in, &evs, true);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(machine.NoteKind.note_off, evs[1].kind);
    try testing.expectEqual(@as(i32, 3), evs[1].note_id);
    try testing.expectEqual(@as(u8, 1), rack.lanes[1].held_n);
    try testing.expectEqual(@as(i32, 4), rack.lanes[1].held[0].id);
    // a closed lane (MUTE, or another's SOLO) takes no new notes
    try testing.expectEqual(@as(usize, 0), Rack.route(&rack.lanes[0], &.{noteOn(40, 5)}, &evs, false));
    m.reset(m.state);

    // JSON: the lanes and their machines' settings come back
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(a);
    try m.write_state_json.?(m.state, &js, a);
    try testing.expect(std.mem.startsWith(u8, js.items, "{\"rack\":2,\"kind\":\"instrument\",\"lanes\":["));
    const rack2 = try Rack.create(a, &reg, .instrument);
    const m2 = rack2.machineInterface();
    defer m2.deinit.?(m2.state, a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, js.items, .{});
    defer parsed.deinit();
    m2.apply_state_json.?(m2.state, parsed.value);
    try testing.expectEqual(@as(usize, 2), rack2.count);
    try testing.expectEqual(@as(u8, 59), rack2.lanes[0].hi);
    try testing.expectEqual(@as(u8, 60), rack2.lanes[1].lo);
    try testing.expectEqual(@as(i8, -12), rack2.lanes[1].transpose);
    try testing.expectEqual(@as(u8, 1), rack2.lanes[1].poly);
    var js2: std.ArrayList(u8) = .empty;
    defer js2.deinit(a);
    try m2.write_state_json.?(m2.state, &js2, a);
    try testing.expectEqualStrings(js.items, js2.items);
    try testing.expect(std.mem.indexOf(u8, js.items, "\"cmi-filter\":60") != null);

    // and the split still plays after the load
    play(m2, &.{noteOn(45, 5)}, &out);
    try testing.expect(rms(out[512 * 2 ..]) > 0.01);
}

test "rack: the first form's parts load as lanes and play as they did" {
    const a = testing.allocator;
    var reg = registry_mod.Registry.init(a);
    defer reg.deinit();
    try reg.loadFyMachine("machines/unfairlight/unfairlight.fy");
    try reg.loadNative();
    const v1 =
        \\{"parts":[{"machine":"unfairlight","name":"LOW","lo":0,"hi":59,"vlo":1,"vhi":127,"transpose":0,"level":-3,"pan":-0.5,"poly":2,"mute":false,"params":{"cmi-filter":60}},
        \\ {"machine":"unfairlight","name":"HIGH","lo":60,"hi":127,"transpose":-12,"level":0,"pan":0,"poly":0,"mute":true}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, v1, .{});
    defer parsed.deinit();
    const rack = try Rack.create(a, &reg, .instrument);
    const m = rack.machineInterface();
    defer m.deinit.?(m.state, a);
    m.apply_state_json.?(m.state, parsed.value);
    try testing.expectEqual(@as(usize, 2), rack.count);
    try testing.expectEqualStrings("LOW", rack.lanes[0].labelSlice());
    try testing.expectEqual(@as(f32, -3), rack.lanes[0].level_db);
    try testing.expectEqual(@as(u8, 2), rack.lanes[0].poly);
    try testing.expect(rack.lanes[1].mute);
    try testing.expectEqual(@as(usize, 0), rack.lanes[0].effects.items.len);
    var out: [(512 * 8)]f32 = @splat(0);
    play(m, &.{noteOn(45, 1)}, &out);
    try testing.expect(rms(out[512 * 2 ..]) > 0.01);
    // the muted upper lane takes nothing
    m.reset(m.state);
    @memset(&out, 0);
    play(m, &.{noteOn(72, 2)}, &out);
    try testing.expectEqual(@as(f64, 0), rms(&out));
}

test "fxrack: one lane with an insert is that insert, sample for sample" {
    const a = testing.allocator;
    var reg = registry_mod.Registry.init(a);
    defer reg.deinit();
    try reg.loadFyMachine("machines/sat2/sat2.fy");
    try reg.loadNative();
    const sat = reg.findById("sat2").?;
    const alone = try reg.instantiate(sat);
    defer alone.deinit.?(alone.state, a);
    alone.reset(alone.state);
    const rack = try Rack.create(a, &reg, .effect);
    const m = rack.machineInterface();
    defer m.deinit.?(m.state, a);
    _ = try rack.addLane(sat);
    for ([_]Machine{ alone, rack.lanes[0].effects.items[0].mach }) |x| x.set_param.?(x.state, "sat-drive", 12);

    var in: [256 * 16]f32 = undefined;
    for (&in, 0..) |*x, i| x.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.031);
    var al: [in.len]f32 = undefined;
    var ar: [in.len]f32 = undefined;
    var bl: [in.len]f32 = undefined;
    var br: [in.len]f32 = undefined;
    process(alone, &in, &al, &ar);
    process(m, &in, &bl, &br);
    try testing.expect(rms(&al) > 0.05);
    try testing.expectEqualSlices(f32, &al, &bl);
    try testing.expectEqualSlices(f32, &ar, &br);
}

test "fxrack: a dry lane is held back to a latent lane, and the rack reports that latency" {
    const a = testing.allocator;
    var reg = registry_mod.Registry.init(a);
    defer reg.deinit();
    try reg.loadFyMachine("machines/limiter2/limiter2.fy");
    try reg.loadNative();
    const lim = reg.findById("limiter2").?;
    const rack = try Rack.create(a, &reg, .effect);
    const m = rack.machineInterface();
    defer m.deinit.?(m.state, a);
    _ = try rack.addLane(null); // dry
    const wet = try rack.addLane(lim);
    wet.mute = true; // only the dry path is heard
    rack.publishLanes();

    var in: [(256 * 8)]f32 = @splat(0);
    in[300] = 1;
    var ol: [in.len]f32 = undefined;
    var or_: [in.len]f32 = undefined;
    process(m, &in, &ol, &or_);
    const lat = m.latencySamples();
    try testing.expect(lat > 0 and lat < 1000);
    try testing.expectEqual(@as(f32, 1), ol[300 + lat]);
    try testing.expectEqual(@as(f32, 0), ol[300]);
}

test "rack: racks nest MAX_DEPTH deep, no deeper" {
    const a = testing.allocator;
    var reg = registry_mod.Registry.init(a);
    defer reg.deinit();
    try reg.loadNative();
    const fx = reg.findById("fxrack").?;
    const top = try Rack.create(a, &reg, .effect);
    const m = top.machineInterface();
    defer m.deinit.?(m.state, a);
    _ = try top.addLane(fx);
    const mid: *Rack = @ptrCast(@alignCast(top.lanes[0].effects.items[0].mach.state));
    try testing.expectEqual(@as(u8, 1), mid.level);
    _ = try mid.addLane(fx);
    const low: *Rack = @ptrCast(@alignCast(mid.lanes[0].effects.items[0].mach.state));
    try testing.expectEqual(@as(u8, 2), low.level);
    try testing.expectError(error.RackTooDeep, low.addLane(fx));
    // and the nesting round-trips
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(a);
    try top.writeJson(&js, a);
    try testing.expect(std.mem.indexOf(u8, js.items, "\"machine\":\"fxrack\",\"params\":{\"rk-m1\":0,") != null);
    try testing.expect(std.mem.indexOf(u8, js.items, "\"state\":{\"rack\":2,\"kind\":\"effect\"") != null);
}

fn fyOf(m: Machine) *fy_raw.FyRawMachine {
    return @ptrCast(@alignCast(m.state));
}

/// A sat2 FX Rack lane plus its registry, for the macro tests.
const SatRack = struct {
    reg: registry_mod.Registry,
    rack: *Rack,
    m: Machine,

    fn init(self: *SatRack, a: std.mem.Allocator) !void {
        self.reg = registry_mod.Registry.init(a);
        try self.reg.loadFyMachine("machines/sat2/sat2.fy");
        try self.reg.loadNative();
        self.rack = try Rack.create(a, &self.reg, .effect);
        self.m = self.rack.machineInterface();
        _ = try self.rack.addLane(self.reg.findById("sat2").?);
    }
    fn deinit(self: *SatRack, a: std.mem.Allocator) void {
        self.m.deinit.?(self.m.state, a);
        self.reg.deinit();
    }
    fn sat(self: *SatRack) Machine {
        return self.rack.lanes[0].effects.items[0].mach;
    }
};

test "rack: macros, names and mappings with formulas round-trip as JSON" {
    const a = testing.allocator;
    var t: SatRack = undefined;
    try t.init(a);
    defer t.deinit(a);
    const rack = t.rack;
    const sat = t.sat();
    rack.macro_names[1].set("DRIVE");
    rack.setMacro(1, 0.25, true);
    rack.setMacro(CHAIN, 3, true);
    const drive = sat.controlIndex("sat-drive").?;
    const m = try rack.addMapping(.{ .macro = 1, .lane = 0, .slot = rack.lanes[0].effects.items[0].uid, .control = @intCast(drive), .min = sat.control_knob.?(sat.state, drive, 0), .max = sat.control_knob.?(sat.state, drive, 24) });
    Rack.setFormula(m, "x^2");
    _ = try rack.addMapping(.{ .macro = 1, .lane = 0, .target = .level, .min = 0, .max = -12 });
    try testing.expectEqual(@as(usize, 2), rack.map_count);
    // the same macro and target again replaces the mapping
    _ = try rack.addMapping(.{ .macro = 1, .lane = 0, .target = .level, .min = 0, .max = -6 });
    try testing.expectEqual(@as(usize, 2), rack.map_count);
    try testing.expectEqualStrings("DRIVE", controlInfoImpl(rack, 1).label);
    try testing.expectEqualStrings("MACRO 3", controlInfoImpl(rack, 2).label);

    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(a);
    try rack.writeJson(&js, a);
    try testing.expect(std.mem.indexOf(u8, js.items, "\"maps\":[{\"macro\":2,\"lane\":1,\"insert\":1,\"control\":\"sat-drive\",\"min\":0,\"max\":24,\"formula\":\"x^2\"},{\"macro\":2,\"lane\":1,\"target\":\"level\",\"min\":0,\"max\":-6}]") != null);
    try testing.expect(std.mem.indexOf(u8, js.items, "\"chain\":3") != null);

    const back = try Rack.create(a, &t.reg, .effect);
    const bm = back.machineInterface();
    defer bm.deinit.?(bm.state, a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, js.items, .{});
    defer parsed.deinit();
    back.applyJson(parsed.value);
    try testing.expectEqual(@as(usize, 2), back.map_count);
    try testing.expectEqualStrings("x^2", back.maps[0].textSlice());
    try testing.expectEqual(@as(f32, 0.25), back.macroBase(1));
    try testing.expectEqual(@as(f32, 3), back.macroBase(CHAIN));
    var js2: std.ArrayList(u8) = .empty;
    defer js2.deinit(a);
    try back.writeJson(&js2, a);
    try testing.expectEqualStrings(js.items, js2.items);

    // removing the insert drops its mapping, the lane's level one stays
    rack.removeEffect(0, 0);
    try testing.expectEqual(@as(usize, 1), rack.map_count);
    try testing.expectEqual(TargetKind.level, rack.maps[0].target);
}

/// Blocks of 256 of `in` through effect `m`, the beat running at 120 BPM
/// from 0, with `view` as its automation.
fn processAuto(m: Machine, in: []const f32, out_l: []f32, out_r: []f32, view: ?*const snapshot.AutoView) void {
    var at: usize = 0;
    const bps = 120.0 / (60.0 * 48000.0);
    while (at + 256 <= in.len) : (at += 256) {
        var ctx = testCtx(&.{}, 256);
        ctx.ppq_position = @as(f64, @floatFromInt(at)) * bps;
        const ports = [_][*]const f32{ in[at..].ptr, in[at..].ptr };
        ctx.audio_in = &ports;
        ctx.audio_in_count = 2;
        ctx.automation = view;
        if (m.adopt_updates) |f| f(m.state);
        m.render(m.state, &ctx, out_l[at..][0..256], out_r[at..][0..256]);
    }
}

test "rack: an automated macro sweeps its target as automating the target does" {
    const a = testing.allocator;
    var t: SatRack = undefined;
    try t.init(a);
    defer t.deinit(a);
    const alone = try t.reg.instantiate(t.reg.findById("sat2").?);
    defer alone.deinit.?(alone.state, a);
    alone.reset(alone.state);
    const drive = alone.controlIndex("sat-drive").?;
    _ = try t.rack.addMapping(.{ .macro = 0, .lane = 0, .slot = t.rack.lanes[0].effects.items[0].uid, .control = @intCast(drive), .min = 0, .max = 1 });

    // One lane 0 → 1 over a beat, on sat-drive alone and on MACRO 1.
    var snap = std.mem.zeroes(snapshot.TrackSnapshot);
    snap.auto_points[0] = .{ .beat = 0, .value = 0 };
    snap.auto_points[1] = .{ .beat = 1, .value = 1 };
    snap.auto_point_count = 2;
    snap.lanes[0] = .{ .kind = .inst, .control = @intCast(drive), .points_start = 0, .points_count = 2 };
    snap.lane_count = 1;
    var cursors: [snapshot.MAX_LANES_PER_TRACK]u32 = @splat(0);
    const view = snapshot.AutoView{ .snap = &snap, .cursors = &cursors, .kind = .inst };
    var snap2 = snap;
    snap2.lanes[0].control = 0;
    var cursors2: [snapshot.MAX_LANES_PER_TRACK]u32 = @splat(0);
    const view2 = snapshot.AutoView{ .snap = &snap2, .cursors = &cursors2, .kind = .inst };

    var in: [256 * 120]f32 = undefined;
    for (&in, 0..) |*x, i| x.* = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.031);
    const al = try a.alloc(f32, in.len);
    defer a.free(al);
    const ar = try a.alloc(f32, in.len);
    defer a.free(ar);
    const bl = try a.alloc(f32, in.len);
    defer a.free(bl);
    const br = try a.alloc(f32, in.len);
    defer a.free(br);
    processAuto(alone, &in, al, ar, &view);
    processAuto(t.m, &in, bl, br, &view2);
    // it did sweep: the end is driven harder than the start
    try testing.expect(rms(al[al.len - 4096 ..]) > 1.5 * rms(al[0..4096]));
    try testing.expectEqualSlices(f32, al, bl);
    try testing.expectEqualSlices(f32, ar, br);
}

test "rack: a track lane down the rack's path automates the insert inside as on a track" {
    const a = testing.allocator;
    var t: SatRack = undefined;
    try t.init(a);
    defer t.deinit(a);
    const alone = try t.reg.instantiate(t.reg.findById("sat2").?);
    defer alone.deinit.?(alone.state, a);
    alone.reset(alone.state);
    const drive = alone.controlIndex("sat-drive").?;
    // A dry lane first, so the insert's lane isn't the first.
    _ = try t.rack.addLane(null);
    t.rack.moveLane(1, 0);
    const lane = &t.rack.lanes[1];
    const step = automation.Step{ .lane = lane.uid, .slot = lane.effects.items[0].uid };
    // The path resolves to that insert, and back to its place.
    const found = t.m.childAt(step).?;
    try testing.expectEqual(@as(u8, 1), found.lane);
    try testing.expectEqual(@as(u16, 1), found.pos);
    try testing.expectEqual(lane.effects.items[0].mach.state, found.mach.state);
    try testing.expectEqual(lane.effects.items[0].mach.state, t.m.inner(automation.Path.plus(.{}, step)).?.state);

    var snap = std.mem.zeroes(snapshot.TrackSnapshot);
    snap.auto_points[0] = .{ .beat = 0, .value = 0 };
    snap.auto_points[1] = .{ .beat = 1, .value = 1 };
    snap.auto_point_count = 2;
    snap.lanes[0] = .{ .kind = .fx, .fx_uid = 3, .control = @intCast(drive), .points_start = 0, .points_count = 2 };
    snap.lane_count = 1;
    var cursors: [snapshot.MAX_LANES_PER_TRACK]u32 = @splat(0);
    const view = snapshot.AutoView{ .snap = &snap, .cursors = &cursors, .kind = .fx, .fx_uid = 3 };
    var snap2 = snap;
    snap2.lanes[0].path = automation.Path.plus(.{}, step);
    var cursors2: [snapshot.MAX_LANES_PER_TRACK]u32 = @splat(0);
    const view2 = snapshot.AutoView{ .snap = &snap2, .cursors = &cursors2, .kind = .fx, .fx_uid = 3 };

    var in: [256 * 120]f32 = undefined;
    for (&in, 0..) |*x, i| x.* = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.031);
    const al = try a.alloc(f32, in.len);
    defer a.free(al);
    const ar = try a.alloc(f32, in.len);
    defer a.free(ar);
    const bl = try a.alloc(f32, in.len);
    defer a.free(bl);
    const br = try a.alloc(f32, in.len);
    defer a.free(br);
    processAuto(alone, &in, al, ar, &view);
    // The dry lane is silent here: only the insert's lane is heard.
    t.rack.lanes[0].mute = true;
    t.rack.publishLanes();
    processAuto(t.m, &in, bl, br, &view2);
    try testing.expect(rms(al[al.len - 4096 ..]) > 1.5 * rms(al[0..4096]));
    try testing.expectEqualSlices(f32, al, bl);
    try testing.expectEqualSlices(f32, ar, br);

    // Removing the lane before it leaves the path on the same insert.
    t.rack.removeLane(0);
    try testing.expectEqual(lane.effects.items.len, 1);
    try testing.expectEqual(t.rack.lanes[0].effects.items[0].mach.state, t.m.childAt(step).?.mach.state);
}

test "rack: a formula shapes the macro, a stepped target snaps, unmapping lets go" {
    const a = testing.allocator;
    var t: SatRack = undefined;
    try t.init(a);
    defer t.deinit(a);
    const rack = t.rack;
    const sat = t.sat();
    const f = fyOf(sat);
    const uid = rack.lanes[0].effects.items[0].uid;
    const mix = sat.controlIndex("sat-mix").?;
    const mode = sat.controlIndex("sat-mode").?;
    const m = try rack.addMapping(.{ .macro = 0, .lane = 0, .slot = uid, .control = @intCast(mix), .min = 0.2, .max = 0.6 });
    Rack.setFormula(m, "1 - x");
    const sw = try rack.addMapping(.{ .macro = 0, .lane = 0, .slot = uid, .control = @intCast(mode), .min = 0, .max = 3 });
    try testing.expect(sw.stepped);
    rack.setMacro(0, 0.25, true);
    rack.publishLanes();
    var in: [256 * 4]f32 = @splat(0.1);
    var ol: [in.len]f32 = undefined;
    var or_: [in.len]f32 = undefined;
    process(t.m, &in, &ol, &or_);
    try testing.expect(f.mod_on[mix]);
    try testing.expectApproxEqAbs(@as(f32, 0.2 + 0.4 * 0.75), f.mod_val[mix], 1e-6);
    try testing.expectEqual(@as(f32, 1), f.mod_val[mode]); // round(0.75)
    try testing.expectApproxEqAbs(@as(f32, 0.5), f.smooth_norm[mix], 1e-6);
    // A typo keeps the old program running.
    Rack.setFormula(&rack.maps[0], "1 - ");
    try testing.expect(rack.maps[0].bad);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rack.maps[0].value(0.25, &@as([MAX_MACROS]f32, @splat(0))), 1e-6);
    rack.removeMapping(0);
    rack.publishLanes();
    process(t.m, &in, &ol, &or_);
    try testing.expect(!f.mod_on[mix]);
    try testing.expect(f.mod_on[mode]);
}

test "rack: CHAIN closes the lanes whose zone it leaves" {
    const a = testing.allocator;
    var t: SatRack = undefined;
    try t.init(a);
    defer t.deinit(a);
    t.rack.lanes[0].clo = 10;
    t.rack.lanes[0].chi = 20;
    t.rack.publishLanes();
    var in: [256 * 8]f32 = undefined;
    for (&in, 0..) |*x, i| x.* = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.031);
    var ol: [in.len]f32 = undefined;
    var or_: [in.len]f32 = undefined;
    process(t.m, &in, &ol, &or_);
    try testing.expect(rms(ol[1024..]) < 1e-6);
    t.rack.setMacro(CHAIN, 15, false);
    process(t.m, &in, &ol, &or_);
    try testing.expect(rms(ol[1024..]) > 0.05);
}

test "rack: a macro reaches through a nested rack's macro" {
    const a = testing.allocator;
    var reg = registry_mod.Registry.init(a);
    defer reg.deinit();
    try reg.loadFyMachine("machines/sat2/sat2.fy");
    try reg.loadNative();
    const top = try Rack.create(a, &reg, .effect);
    const m = top.machineInterface();
    defer m.deinit.?(m.state, a);
    _ = try top.addLane(reg.findById("fxrack").?);
    const inner_m = top.lanes[0].effects.items[0].mach;
    const inner: *Rack = @ptrCast(@alignCast(inner_m.state));
    _ = try inner.addLane(reg.findById("sat2").?);
    const sat = inner.lanes[0].effects.items[0].mach;
    const mix = sat.controlIndex("sat-mix").?;
    _ = try inner.addMapping(.{ .macro = 2, .lane = 0, .slot = inner.lanes[0].effects.items[0].uid, .control = @intCast(mix), .min = 0, .max = 1 });
    _ = try top.addMapping(.{ .macro = 0, .lane = 0, .slot = top.lanes[0].effects.items[0].uid, .control = 2, .min = 0, .max = 0.5 });
    inner.publishLanes();
    top.publishLanes();
    top.setMacro(0, 1, true);
    var in: [256 * 4]f32 = @splat(0.1);
    var ol: [in.len]f32 = undefined;
    var or_: [in.len]f32 = undefined;
    process(m, &in, &ol, &or_);
    try testing.expectEqual(@as(f32, 0.5), inner.eff[2]);
    try testing.expectEqual(@as(f32, 0.5), fyOf(sat).mod_val[mix]);
}
