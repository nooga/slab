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
pub const SIDE_W: i32 = 232;
const PICK_MENU_KEY: u64 = 0x5241434b; // "RACK"
/// The longest latency lanes are aligned over: what a lane's line holds.
const MAX_ALIGN = chain_mod.DRY_LEN - MAX_BLOCK;

/// The registry paths: a directory with presets/ and no .fy.
pub const PATH = "machines/rack/rack";
pub const FX_PATH = "machines/fxrack/fxrack";

pub const Kind = enum { instrument, effect };

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
    instrument: Machine = silent,
    /// Registry index of the instrument; null in an effect rack.
    reg_idx: ?u8 = null,
    effects: std.ArrayList(Effect) = .empty,
    /// The line that holds this lane back to the slowest lane (audio).
    line: *chain_mod.DryLine,
    label: [MAX_LABEL + 1]u8 = [_]u8{0} ** (MAX_LABEL + 1),
    label_len: u8 = 0,
    // Settings are copied from the UI configuration at block boundaries.
    lo: u8 = 0,
    hi: u8 = 127,
    vlo: u8 = 1,
    vhi: u8 = 127,
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

    fn setLabel(self: *Lane, s: []const u8) void {
        const n = @min(s.len, MAX_LABEL);
        @memcpy(self.label[0..n], s[0..n]);
        self.label[n] = 0;
        self.label_len = @intCast(n);
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

const LaneVersion = struct { lanes: [MAX_LANES]Lane = undefined, count: usize = 0, generation: u64 = 0 };
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
    publication_depth: usize = 0,
    audio_lanes: [MAX_LANES]Lane = undefined,
    audio_count: usize = 0,

    // UI
    selected: usize = 0,
    /// The selected lane's machine on the panel: -1 its instrument, else
    /// an insert.
    selected_fx: i32 = -1,
    presets: presets_mod.List = .{},
    current_preset: i32 = -1,

    // audio scratch
    sl: [MAX_BLOCK]f32 = undefined,
    sr: [MAX_BLOCK]f32 = undefined,
    fl: [MAX_BLOCK]f32 = undefined,
    fr: [MAX_BLOCK]f32 = undefined,
    events: [MAX_EVENTS]NoteEvent = undefined,

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
            .panel_w_fn = panelWImpl,
            .host_titlebar = true,
            // Lanes get the notes, bends included; most of them play it.
            .takes_expression = self.kind == .instrument,
            .panel_w = SIDE_W + 200,
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

    fn newLane(self: *Rack, inst: Machine, reg_idx: ?u8) !*Lane {
        if (self.count >= MAX_LANES) return error.RackFull;
        const ch = try chain_mod.State.create(self.alloc, inst);
        errdefer ch.destroy(self.alloc);
        const line = try self.alloc.create(chain_mod.DryLine);
        @memset(std.mem.asBytes(line), 0);
        self.lanes[self.count] = .{ .chain = ch, .instrument = inst, .reg_idx = reg_idx, .line = line };
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
        l.chain.removeEffect(self.alloc, l.instrument, &l.effects, j) catch {};
    }

    pub fn replaceEffect(self: *Rack, i: usize, j: usize, reg_idx: usize) !void {
        if (i >= self.count) return error.InvalidLane;
        const l = &self.lanes[i];
        const m = try self.instantiate(reg_idx);
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
        self.publishLanes();
        self.retireLane(next_generation, &old);
        if (self.selected >= self.count and self.selected > 0) self.selected -= 1;
        self.selected_fx = -1;
    }

    pub fn clear(self: *Rack) !void {
        self.collect();
        if (self.retired.len + self.count > 128) return error.PublicationFull;
        const next_generation = self.generation + 1;
        const n = self.count;
        var old: [MAX_LANES]Lane = undefined;
        @memcpy(old[0..n], self.lanes[0..n]);
        self.count = 0;
        self.publishLanes();
        for (old[0..n]) |*l| self.retireLane(next_generation, l);
        self.selected = 0;
        self.selected_fx = -1;
    }

    /// Apply one machine's saved settings (params, then files, then zone
    /// edits, then its own state), as a project load does for a track's.
    fn applyMachineJson(m: Machine, po: std.json.ObjectMap) void {
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
        self.selected_fx = -1;
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
    }

    pub fn writeJson(self: *Rack, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        try out.print(alloc, "{{\"rack\":2,\"kind\":\"{s}\",\"lanes\":[", .{@tagName(self.kind)});
        for (self.lanes[0..self.count], 0..) |*l, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"name\":");
            try jsonString(out, alloc, l.labelSlice());
            try out.print(alloc, ",\"lo\":{d},\"hi\":{d},\"vlo\":{d},\"vhi\":{d},\"transpose\":{d},\"level\":{d},\"pan\":{d},\"poly\":{d},\"mute\":{s},\"solo\":{s}", .{
                l.lo, l.hi, l.vlo, l.vhi, l.transpose, l.level_db, l.pan, l.poly, if (l.mute) "true" else "false", if (l.solo) "true" else "false",
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
        try out.appendSlice(alloc, "]}");
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
    const in: []const NoteEvent = if (ctx.note_in) |p| p[0..ctx.note_in_count] else &.{};
    const total = self.latency();
    var solo = false;
    for (self.audio_lanes[0..self.audio_count]) |*p| solo = solo or p.solo;
    for (self.audio_lanes[0..self.audio_count]) |*p| {
        // The lanes' machines aren't the track's: no automation reaches them.
        var sub = ctx.*;
        sub.automation = null;
        sub.note_out = null;
        sub.note_out_cap = 0;
        sub.note_out_count = null;
        sub.audio_in = null;
        sub.audio_in_count = 0;
        // MUTE, or another lane's SOLO, closes the lane's input: no new
        // notes, no audio in. What it holds rings out and is heard.
        const open = !p.mute and (!solo or p.solo);
        if (self.kind == .instrument) {
            const n = Rack.route(p, in, &self.events, open);
            sub.note_in = if (n > 0) &self.events else null;
            sub.note_in_count = @intCast(n);
            @memset(self.sl[0..frames], 0);
            @memset(self.sr[0..frames], 0);
            const m = &p.chain.audio_machine;
            m.render(m.state, &sub, self.sl[0..frames], self.sr[0..frames]);
        } else {
            sub.note_in = null;
            sub.note_in_count = 0;
            if (open) {
                @memcpy(self.sl[0..frames], in_l[0..frames]);
                @memcpy(self.sr[0..frames], in_r[0..frames]);
            } else {
                @memset(self.sl[0..frames], 0);
                @memset(self.sr[0..frames], 0);
            }
        }
        var out = engine.RenderedPair{ .l = self.sl[0..frames], .r = self.sr[0..frames] };
        if (p.chain.audio_effect_count > 0) {
            out = engine.renderEffects(p.chain, sub, self.sl[0..frames], self.sr[0..frames], self.fl[0..frames], self.fr[0..frames], .{ .on = true, .wake = p.held_n > 0 });
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
            for (0..frames) |k| {
                const w = (line.w + k) & mask;
                line.l[w] = out.l[k];
                line.r[w] = out.r[k];
                const rd = (line.w + k + chain_mod.DRY_LEN - d) & mask;
                out.l[k] = line.l[rd];
                out.r[k] = line.r[rd];
            }
            line.w = (line.w + frames) & mask;
        }
        const g = std.math.pow(f32, 10, p.level_db / 20);
        const gl = g * @min(1, 1 - p.pan);
        const gr = g * @min(1, 1 + p.pan);
        for (l[0..frames], r[0..frames], out.l, out.r) |*ol, *or_, a, b| {
            ol.* += a * gl;
            or_.* += b * gr;
        }
    }
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
    var any = false;
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
    var any = false;
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
//   ┌ LANES ───────────┐┌ the selected machine's own panel ┐
//   │ 1 ALTO1        ● ││                                  │
//   │ 2 ALTO2          ││                                  │
//   │ [key map lanes]  ││                                  │
//   │ LO HI VLO VHI    ││  (instrument racks)              │
//   │ TRN POLY LVL PAN ││                                  │
//   │ [MACHINE] [+][−] ││                                  │
//   │ FX: inserts [−]  ││                                  │
//   │ [+ FX] [+ LANE]  ││                                  │
//   └──────────────────┘└──────────────────────────────────┘

/// The machine the panel shows: the selected lane's instrument or insert.
fn shown(self: *Rack) ?*Machine {
    if (self.selected >= self.count) return null;
    const l = &self.lanes[self.selected];
    if (self.selected_fx >= 0 and self.selected_fx < l.effects.items.len) return &l.effects.items[@intCast(self.selected_fx)].mach;
    if (l.reg_idx != null) return &l.instrument;
    return null;
}

fn panelWImpl(state: *anyopaque) f32 {
    const self: *Rack = @ptrCast(@alignCast(state));
    var w: f32 = 200;
    if (shown(self)) |m| w = if (m.panel_w_fn) |f| f(m.state) else if (m.panel_w > 0) m.panel_w else 200;
    return @as(f32, @floatFromInt(SIDE_W)) + w;
}

const ROW_H: i32 = 16;
const FIELD_H: i32 = 20;

fn noteName(buf: []u8, k: u8) []const u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const oct = @as(i32, k / 12) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[k % 12], oct }) catch "?";
}

/// A labelled readout with ▴▾ steps in its glass; returns the step (+/-1,
/// x `big` with Shift).
fn field(ui: *Ui, r: Rect, key: []const u8, label: []const u8, value: []const u8, big: i32) i32 {
    ui.pushId(key);
    defer ui.popId();
    var row = r;
    const lab = row.cutLeft(28);
    ui.textIn(&ui.fonts.legend, lab, label, ui_style.text_dim, .left, true);
    ctl.display(ui, row, value, .{ .flush = true });
    const d = ctl.glassSteps(ui, row, "step");
    return if (ui.in.shift) d * big else d;
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

fn drawPanelImpl(state: *anyopaque, ui: *Ui, rect: Rect) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.collect();
    defer self.publishLanes();
    var body = rect;
    var side = body.cutLeft(SIDE_W);
    ui.rect(side, ui_style.chassis);
    side = ctl.strip(ui, side.inset(4), "LANES");
    const inst = self.kind == .instrument;

    // lane list
    var i: usize = 0;
    while (i < MAX_LANES) : (i += 1) {
        const row = side.cutTop(ROW_H);
        if (i >= self.count) {
            ui.rect(row.insetXY(0, 1), ui_style.well.alpha(120));
            continue;
        }
        const p = &self.lanes[i];
        ui.pushId(i);
        defer ui.popId();
        var on = i == self.selected;
        var lb: [48]u8 = undefined;
        var a: [4]u8 = undefined;
        var b: [4]u8 = undefined;
        const text = if (inst)
            std.fmt.bufPrint(&lb, "{d} {s}  {s}-{s}", .{ i + 1, p.labelSlice(), noteName(&a, p.lo), noteName(&b, p.hi) }) catch "?"
        else
            std.fmt.bufPrint(&lb, "{d} {s}  {d} FX", .{ i + 1, p.labelSlice(), p.effects.items.len }) catch "?";
        if (ctl.button(ui, row, "sel", &on, .{ .kind = .latch, .label = text, .flush = true, .lit = LANE_COLORS[i] })) {
            if (self.selected != i) self.selected_fx = -1;
            self.selected = i;
        }
    }
    _ = side.cutTop(4);

    if (inst) {
        // key map: a lane per lane over the 128 keys
        const map = side.cutTop(@intCast(4 * MAX_LANES / 2 + 4));
        ui.rect(map, ui_style.well);
        const lane_h: i32 = 2;
        for (self.lanes[0..self.count], 0..) |*p, pi| {
            const x0 = map.x + 2 + @divFloor((map.w - 4) * @as(i32, p.lo), 128);
            const x1 = map.x + 2 + @divFloor((map.w - 4) * (@as(i32, p.hi) + 1), 128);
            const col = if (p.mute) ui_style.text_mute else LANE_COLORS[pi];
            ui.rect(Rect.xywh(x0, map.y + 2 + @as(i32, @intCast(pi)) * lane_h, @max(1, x1 - x0), lane_h), if (pi == self.selected) col else col.alpha(140));
        }
        // octave ticks at the Cs
        var k: i32 = 0;
        while (k < 128) : (k += 12) ui.rect(Rect.xywh(map.x + 2 + @divFloor((map.w - 4) * k, 128), map.bottom() - 3, 1, 3), ui_style.text_mute);
        _ = side.cutTop(4);
    }

    if (self.selected < self.count) {
        const p = &self.lanes[self.selected];
        var s = p.*; // edit a copy, publish at the block boundary
        var buf: [16]u8 = undefined;
        var half: Rect = undefined;
        var left: Rect = undefined;
        if (inst) {
            half = side.cutTop(FIELD_H);
            left = half.cutLeft(@divFloor(half.w, 2) - 2);
            _ = half.cutLeft(4);
            step7(&s.lo, field(ui, left, "lo", "LO", noteName(&buf, s.lo), 12), 0, s.hi);
            step7(&s.hi, field(ui, half, "hi", "HI", noteName(&buf, s.hi), 12), s.lo, 127);
            _ = side.cutTop(2);
            half = side.cutTop(FIELD_H);
            left = half.cutLeft(@divFloor(half.w, 2) - 2);
            _ = half.cutLeft(4);
            step7(&s.vlo, field(ui, left, "vlo", "VLO", std.fmt.bufPrint(&buf, "{d}", .{s.vlo}) catch "?", 16), 1, s.vhi);
            step7(&s.vhi, field(ui, half, "vhi", "VHI", std.fmt.bufPrint(&buf, "{d}", .{s.vhi}) catch "?", 16), s.vlo, 127);
            _ = side.cutTop(2);
            half = side.cutTop(FIELD_H);
            left = half.cutLeft(@divFloor(half.w, 2) - 2);
            _ = half.cutLeft(4);
            const dt = field(ui, left, "trn", "TRN", std.fmt.bufPrint(&buf, "{s}{d}", .{ if (s.transpose > 0) "+" else "", s.transpose }) catch "?", 12);
            s.transpose = @intCast(std.math.clamp(@as(i32, s.transpose) + dt, -48, 48));
            const dp = field(ui, half, "poly", "POLY", if (s.poly == 0) "ALL" else std.fmt.bufPrint(&buf, "{d}", .{s.poly}) catch "?", 4);
            s.poly = @intCast(std.math.clamp(@as(i32, s.poly) + dp, 0, 32));
            _ = side.cutTop(2);
        }
        half = side.cutTop(FIELD_H);
        left = half.cutLeft(@divFloor(half.w, 2) - 2);
        _ = half.cutLeft(4);
        const dl = field(ui, left, "lvl", "LVL", std.fmt.bufPrint(&buf, "{d:.0}dB", .{s.level_db}) catch "?", 6);
        s.level_db = std.math.clamp(s.level_db + @as(f32, @floatFromInt(dl)), -60, 12);
        const dpan = field(ui, half, "pan", "PAN", std.fmt.bufPrint(&buf, "{d:.1}", .{s.pan}) catch "?", 5);
        s.pan = std.math.clamp(s.pan + 0.1 * @as(f32, @floatFromInt(dpan)), -1, 1);
        if (@abs(s.pan) < 0.05) s.pan = 0;
        _ = side.cutTop(4);

        var btns = side.cutTop(FIELD_H);
        const mute_r = btns.cutRight(36);
        _ = ctl.button(ui, mute_r, "mute", &s.mute, .{ .kind = .latch, .label = "MUTE", .led = ui_style.accent });
        _ = btns.cutRight(2);
        const solo_r = btns.cutRight(36);
        _ = ctl.button(ui, solo_r, "solo", &s.solo, .{ .kind = .latch, .label = "SOLO", .led = ui_style.accent });
        if (s.lo != p.lo or s.hi != p.hi or s.vlo != p.vlo or s.vhi != p.vhi or s.transpose != p.transpose or
            s.poly != p.poly or s.level_db != p.level_db or s.pan != p.pan or s.mute != p.mute or s.solo != p.solo)
        {
            p.lo = s.lo;
            p.hi = s.hi;
            p.vlo = s.vlo;
            p.vhi = s.vhi;
            p.transpose = s.transpose;
            p.poly = s.poly;
            p.level_db = s.level_db;
            p.pan = s.pan;
            p.mute = s.mute;
            p.solo = s.solo;
            self.publishLanes();
        }
        _ = btns.cutRight(4);
        const del_r = btns.cutRight(20);
        if (ctl.button(ui, del_r, "del", null, .{ .label = "\u{2212}" })) {
            self.removeLane(self.selected);
            return;
        }
        menu.tip(ui, del_r, "Remove lane");
        _ = btns.cutRight(4);
        if (inst) {
            const mkey = pane.keyFromIds(PICK_MENU_KEY, @intFromPtr(self), 1);
            var sel_inst = self.selected_fx < 0;
            if (ctl.button(ui, btns, "machine", &sel_inst, .{ .kind = .latch, .label = self.reg.entries[p.reg_idx orelse 0].nameSlice(), .flush = true })) {
                if (self.selected_fx < 0 and !menu.isOpen(mkey)) {
                    bay.scanRegistryPresets(self.reg);
                    menu.openBelow(mkey, btns);
                }
                self.selected_fx = -1;
            }
            menu.tip(ui, btns, "This lane's instrument: click again to replace it");
            if (bay.machinePickerMenuFor(mkey, self.reg, .instruments)) |pick| {
                self.replaceInstrument(self.selected, pick.reg_idx) catch {};
                const np = &self.lanes[self.selected];
                if (pick.preset) |pi| if (np.instrument.apply_preset) |ap| {
                    ap(np.instrument.state, pi);
                    labelFromPreset(np, np.instrument, pi);
                };
            }
        }
        _ = side.cutTop(4);

        // the lane's inserts
        var j: usize = 0;
        while (j < p.effects.items.len) : (j += 1) {
            var row = side.cutTop(ROW_H);
            if (row.h < ROW_H) break;
            const fx = &p.effects.items[j];
            ui.pushId(@as(usize, 0x100) + j);
            defer ui.popId();
            const rm = row.cutRight(20);
            _ = row.cutRight(2);
            const byp = row.cutRight(28);
            _ = row.cutRight(2);
            var lb: [48]u8 = undefined;
            var on = self.selected_fx == @as(i32, @intCast(j));
            const name = if (fx.idx) |fi| self.reg.entries[fi].nameSlice() else fx.mach.name;
            if (ctl.button(ui, row, "fx", &on, .{ .kind = .latch, .label = std.fmt.bufPrint(&lb, "FX{d} {s}", .{ j + 1, name }) catch "?", .flush = true })) self.selected_fx = @intCast(j);
            var active = !fx.bypass.load(.monotonic);
            if (ctl.button(ui, byp, "on", &active, .{ .kind = .latch, .label = "ON", .led = ui_style.accent })) self.setEffectBypass(self.selected, j, !active);
            if (ctl.button(ui, rm, "rm", null, .{ .label = "\u{2212}" })) {
                self.removeEffect(self.selected, j);
                self.selected_fx = -1;
                break;
            }
        }
        if (p.effects.items.len < MAX_LANE_EFFECTS) {
            const add = side.cutTop(FIELD_H);
            const fkey = pane.keyFromIds(PICK_MENU_KEY, @intFromPtr(self), 3);
            if (ctl.button(ui, add, "addfx", null, .{ .label = "+ FX" }) and !menu.isOpen(fkey)) {
                bay.scanRegistryPresets(self.reg);
                menu.openBelow(fkey, add);
            }
            menu.tip(ui, add, "Add an insert to this lane");
            if (bay.machinePickerMenuFor(fkey, self.reg, .effects)) |pick| {
                if (self.addEffect(self.selected, pick.reg_idx)) {
                    const fx = &self.lanes[self.selected].effects.items[self.lanes[self.selected].effects.items.len - 1];
                    if (pick.preset) |pi| if (fx.mach.apply_preset) |ap| ap(fx.mach.state, pi);
                    self.selected_fx = @intCast(self.lanes[self.selected].effects.items.len - 1);
                } else |_| {}
            }
            _ = side.cutTop(4);
        }
    }

    // add a lane
    if (self.count < MAX_LANES) {
        const add = side.cutTop(FIELD_H);
        const akey = pane.keyFromIds(PICK_MENU_KEY, @intFromPtr(self), 2);
        if (inst) {
            if (ctl.button(ui, add, "add", null, .{ .label = "+ LANE" }) and !menu.isOpen(akey)) {
                bay.scanRegistryPresets(self.reg);
                menu.openBelow(akey, add);
            }
            menu.tip(ui, add, "Add a lane: another instrument layered or split");
            if (bay.machinePickerMenuFor(akey, self.reg, .instruments)) |pick| {
                if (self.addLane(pick.reg_idx)) |np| {
                    self.selected = self.count - 1;
                    self.selected_fx = -1;
                    if (pick.preset) |pi| if (np.instrument.apply_preset) |ap| {
                        ap(np.instrument.state, pi);
                        labelFromPreset(np, np.instrument, pi);
                    };
                } else |_| {}
            }
        } else {
            if (ctl.button(ui, add, "add", null, .{ .label = "+ LANE" })) {
                if (self.addLane(null)) |_| {
                    self.selected = self.count - 1;
                    self.selected_fx = -1;
                } else |_| {}
            }
            menu.tip(ui, add, "Add a lane: a dry path to put inserts on");
        }
    }

    // the selected machine's own panel
    if (shown(self)) |m| {
        ui.pushId(m.state);
        defer ui.popId();
        m.draw_panel(m.state, ui, body);
    } else {
        ui.rect(body, ui_style.well);
        ui.textIn(&ui.fonts.body, body, if (self.count == 0) "Add a lane" else "Dry: add an insert", ui_style.text_mute, .center, true);
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

    var out = [_]f32{0} ** (512 * 24);
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
    var out = [_]f32{0} ** (512 * 8);
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

    var in = [_]f32{0} ** (256 * 8);
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
    try testing.expect(std.mem.indexOf(u8, js.items, "\"machine\":\"fxrack\",\"state\":{\"rack\":2,\"kind\":\"effect\"") != null);
}
