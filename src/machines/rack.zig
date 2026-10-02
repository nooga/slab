//! Rack: splits and layers of any instrument machines, as one instrument.
//!
//! Up to MAX_PARTS parts, each a machine from the registry with its own
//! settings, a key range, a velocity range, a transpose, level, pan and a
//! polyphony cap. A note goes to every part whose ranges hold it (split
//! and layer are the same thing: ranges that don't or do overlap); a part
//! at its polyphony cap releases its oldest note first, as the Fairlight's
//! registers do. Everything else (CCs, resets) goes to every part.
//!
//! A rack preset (machines/rack/presets/*.preset) and a project store the
//! parts as {"parts":[{"machine":id,"lo":…,"params":{…},"assets":{…}},…]},
//! each part's settings in its machine's own form, so any machine that
//! persists works inside a rack; tools (tools/library/cmi.py for CMI
//! instruments) write the same form.
//!
//! Threads: the audio thread renders under the rack's own fence
//! (`gate`), never under fy's callback lock, which each child takes for
//! itself. The UI builds a part (instantiate compiles, under the callback
//! lock) outside the fence and swaps it in inside, and edits settings
//! inside it; it never holds both locks.

const std = @import("std");
const machine = @import("../machine.zig");
const registry_mod = @import("../machine_registry.zig");
const presets_mod = @import("../presets.zig");
const fy_host_mod = @import("../fy_host.zig");
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

pub const MAX_PARTS = 8;
const MAX_BLOCK = 4096;
const MAX_EVENTS = 512;
const MAX_HELD = 32;
const MAX_LABEL = 31;
const PRESET_FILE = 256 * 1024;
pub const SIDE_W: i32 = 232;
const PICK_MENU_KEY: u64 = 0x5241434b; // "RACK"

/// The machine's registry path: a directory with presets/ and no .fy.
pub const PATH = "machines/rack/rack";

const Held = struct { channel: u8, id: i32, pitch: f32 };

pub const Part = struct {
    mach: Machine,
    reg_idx: u8,
    label: [MAX_LABEL + 1]u8 = [_]u8{0} ** (MAX_LABEL + 1),
    label_len: u8 = 0,
    // Settings: the UI writes them inside the fence, the audio thread reads
    // them under it.
    lo: u8 = 0,
    hi: u8 = 127,
    vlo: u8 = 1,
    vhi: u8 = 127,
    /// Semitones, whole: a part's fine tuning is its machine's.
    transpose: i8 = 0,
    level_db: f32 = 0,
    pan: f32 = 0,
    /// Notes at once, 0 = the machine's own voices.
    poly: u8 = 0,
    mute: bool = false,
    // Audio thread: the notes this part is holding, oldest first.
    held: [MAX_HELD]Held = undefined,
    held_n: u8 = 0,

    pub fn labelSlice(self: *const Part) []const u8 {
        return self.label[0..self.label_len];
    }

    fn setLabel(self: *Part, s: []const u8) void {
        const n = @min(s.len, MAX_LABEL);
        @memcpy(self.label[0..n], s[0..n]);
        self.label[n] = 0;
        self.label_len = @intCast(n);
    }

    fn takes(self: *const Part, pitch: f32, vel: f32) bool {
        if (self.mute) return false;
        const k: i32 = @intFromFloat(@round(pitch));
        const v: i32 = @intFromFloat(@round(std.math.clamp(vel, 0, 1) * 127));
        return k >= self.lo and k <= self.hi and v >= self.vlo and v <= self.vhi;
    }
};

pub const Rack = struct {
    alloc: std.mem.Allocator,
    reg: *registry_mod.Registry,
    parts: [MAX_PARTS]Part = undefined,
    count: usize = 0,
    gate: std.atomic.Mutex = .unlocked,

    // UI
    selected: usize = 0,
    presets: presets_mod.List = .{},
    current_preset: i32 = -1,

    // audio scratch
    sl: [MAX_BLOCK]f32 = undefined,
    sr: [MAX_BLOCK]f32 = undefined,
    events: [MAX_EVENTS]NoteEvent = undefined,

    pub fn create(alloc: std.mem.Allocator, reg: *registry_mod.Registry) !*Rack {
        const self = try alloc.create(Rack);
        self.* = .{ .alloc = alloc, .reg = reg };
        self.rescan();
        return self;
    }

    pub fn machineInterface(self: *Rack) Machine {
        return .{
            .name = "Rack",
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .deinit = deinitImpl,
            .preset_count = presetCountImpl,
            .preset_name = presetNameImpl,
            .apply_preset = applyPresetImpl,
            .save_preset_named = savePresetNamedImpl,
            .current_preset = currentPresetImpl,
            .mark_preset = markPresetImpl,
            .write_state_json = writeStateJsonImpl,
            .apply_state_json = applyStateJsonImpl,
            .panel_w_fn = panelWImpl,
            .host_titlebar = true,
            // Parts get the notes, bends included; most of them play it.
            .takes_expression = true,
            .panel_w = SIDE_W + 200,
        };
    }

    fn lock(self: *Rack) void {
        while (!self.gate.tryLock()) std.Thread.yield() catch {};
    }

    fn unlock(self: *Rack) void {
        self.gate.unlock();
    }

    fn rescan(self: *Rack) void {
        self.presets = presets_mod.scan(presetDir());
    }

    fn presetDir() []const u8 {
        return "machines/rack/presets";
    }

    // ── parts ────────────────────────────────────────────────────────

    /// A fresh machine for a part: instantiate compiles fy, which shares
    /// state with the audio thread's renders, so it runs under their lock.
    fn instantiate(self: *Rack, reg_idx: usize) !Machine {
        fy_host_mod.lockCallbacks();
        defer fy_host_mod.unlockCallbacks();
        const m = try self.reg.instantiate(reg_idx);
        m.reset(m.state);
        return m;
    }

    /// Append a part playing registry machine `reg_idx` over all keys.
    pub fn addPart(self: *Rack, reg_idx: usize) !*Part {
        if (self.count >= MAX_PARTS) return error.RackFull;
        const m = try self.instantiate(reg_idx);
        var p = Part{ .mach = m, .reg_idx = @intCast(reg_idx) };
        p.setLabel(self.reg.entries[reg_idx].nameSlice());
        self.lock();
        self.parts[self.count] = p;
        self.count += 1;
        self.unlock();
        return &self.parts[self.count - 1];
    }

    /// Swap part `i`'s machine for registry machine `reg_idx`, keeping its
    /// ranges and mix.
    pub fn replacePart(self: *Rack, i: usize, reg_idx: usize) !void {
        if (i >= self.count) return;
        const m = try self.instantiate(reg_idx);
        self.lock();
        const old = self.parts[i].mach;
        self.parts[i].mach = m;
        self.parts[i].reg_idx = @intCast(reg_idx);
        self.parts[i].held_n = 0;
        self.parts[i].setLabel(self.reg.entries[reg_idx].nameSlice());
        self.unlock();
        if (old.deinit) |d| d(old.state, self.alloc);
    }

    pub fn removePart(self: *Rack, i: usize) void {
        if (i >= self.count) return;
        self.lock();
        const old = self.parts[i].mach;
        var j = i;
        while (j + 1 < self.count) : (j += 1) self.parts[j] = self.parts[j + 1];
        self.count -= 1;
        self.unlock();
        if (old.deinit) |d| d(old.state, self.alloc);
        if (self.selected >= self.count and self.selected > 0) self.selected -= 1;
    }

    pub fn clear(self: *Rack) void {
        self.lock();
        const n = self.count;
        var old: [MAX_PARTS]Machine = undefined;
        for (self.parts[0..n], 0..) |*p, i| old[i] = p.mach;
        self.count = 0;
        self.unlock();
        for (old[0..n]) |m| if (m.deinit) |d| d(m.state, self.alloc);
        self.selected = 0;
    }

    /// Apply one part's saved machine settings (params, then files, then
    /// zone edits), as a project load does for a track's instrument.
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
    }

    /// Replace every part with those in `v` ({"parts":[…]}). Parts naming a
    /// machine the registry doesn't have are skipped.
    pub fn applyJson(self: *Rack, v: std.json.Value) void {
        if (v != .object) return;
        const pv = v.object.get("parts") orelse return;
        if (pv != .array) return;
        self.clear();
        for (pv.array.items) |item| {
            if (item != .object) continue;
            const po = item.object;
            const mid = if (po.get("machine")) |x| (if (x == .string) x.string else continue) else continue;
            const idx = self.reg.findById(mid) orelse continue;
            if (self.reg.entries[idx].native != .none) continue;
            const p = self.addPart(idx) catch continue;
            applyMachineJson(p.mach, po);
            self.lock();
            if (po.get("name")) |x| if (x == .string) p.setLabel(x.string);
            if (po.get("lo")) |x| p.lo = jsonU7(x);
            if (po.get("hi")) |x| p.hi = jsonU7(x);
            if (po.get("vlo")) |x| p.vlo = jsonU7(x);
            if (po.get("vhi")) |x| p.vhi = jsonU7(x);
            if (po.get("transpose")) |x| p.transpose = @intFromFloat(std.math.clamp(@round(jsonF64(x)), -48, 48));
            if (po.get("level")) |x| p.level_db = @floatCast(std.math.clamp(jsonF64(x), -60, 12));
            if (po.get("pan")) |x| p.pan = @floatCast(std.math.clamp(jsonF64(x), -1, 1));
            if (po.get("poly")) |x| p.poly = @intFromFloat(std.math.clamp(@round(jsonF64(x)), 0, 64));
            if (po.get("mute")) |x| p.mute = x == .bool and x.bool;
            self.unlock();
        }
        self.selected = 0;
    }

    pub fn writeJson(self: *Rack, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        try out.appendSlice(alloc, "{\"parts\":[");
        for (self.parts[0..self.count], 0..) |*p, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"machine\":");
            try jsonString(out, alloc, self.reg.entries[p.reg_idx].idSlice());
            try out.appendSlice(alloc, ",\"name\":");
            try jsonString(out, alloc, p.labelSlice());
            try out.print(alloc, ",\"lo\":{d},\"hi\":{d},\"vlo\":{d},\"vhi\":{d},\"transpose\":{d},\"level\":{d},\"pan\":{d},\"poly\":{d},\"mute\":{s}", .{
                p.lo, p.hi, p.vlo, p.vhi, p.transpose, p.level_db, p.pan, p.poly, if (p.mute) "true" else "false",
            });
            if (p.mach.write_params_json) |f| {
                try out.appendSlice(alloc, ",\"params\":");
                try f(p.mach.state, out, alloc);
            }
            if (p.mach.write_assets_json) |f| {
                const at = out.items.len;
                try out.appendSlice(alloc, ",\"assets\":");
                const before = out.items.len;
                try f(p.mach.state, out, alloc);
                if (out.items.len == before) out.shrinkRetainingCapacity(at);
            }
            if (p.mach.write_zones_json) |f| {
                const at = out.items.len;
                try out.appendSlice(alloc, ",\"zones\":");
                const before = out.items.len;
                try f(p.mach.state, out, alloc);
                if (out.items.len == before) out.shrinkRetainingCapacity(at);
            }
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]}");
    }

    // ── audio ────────────────────────────────────────────────────────

    /// Events for part `p` out of the block's `in`: its notes transposed,
    /// the oldest released first when it is at its cap, and everything
    /// that isn't a note. Returns how many.
    fn route(p: *Part, in: []const NoteEvent, out: []NoteEvent) usize {
        var n: usize = 0;
        for (in) |ev| {
            if (n + 2 > out.len) break;
            switch (ev.kind) {
                .note_on => if (ev.velocity > 0) {
                    if (!p.takes(ev.pitch, ev.velocity)) continue;
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

    fn findHeld(p: *const Part, ev: NoteEvent) ?usize {
        for (p.held[0..p.held_n], 0..) |h, i| {
            if (h.channel == ev.channel and h.id == ev.note_id) return i;
        }
        return null;
    }

    fn dropHeld(p: *Part, i: usize) void {
        var j = i;
        while (j + 1 < p.held_n) : (j += 1) p.held[j] = p.held[j + 1];
        p.held_n -= 1;
    }

    /// The note-off for a note this part holds, at the pitch it played.
    fn releaseHeld(p: *Part, ev: NoteEvent) ?NoteEvent {
        const i = findHeld(p, ev) orelse return null;
        var off = ev;
        off.kind = .note_off;
        off.pitch = p.held[i].pitch;
        dropHeld(p, i);
        return off;
    }
};

fn renderImpl(state: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    const frames = @min(@as(usize, ctx.block_size), @min(l.len, @min(r.len, MAX_BLOCK)));
    @memset(l[0..frames], 0);
    @memset(r[0..frames], 0);
    self.lock();
    defer self.unlock();
    const in: []const NoteEvent = if (ctx.note_in) |p| p[0..ctx.note_in_count] else &.{};
    for (self.parts[0..self.count]) |*p| {
        const n = Rack.route(p, in, &self.events);
        var sub = ctx.*;
        sub.note_in = if (n > 0) &self.events else null;
        sub.note_in_count = @intCast(n);
        sub.note_out = null;
        sub.note_out_cap = 0;
        sub.note_out_count = null;
        @memset(self.sl[0..frames], 0);
        @memset(self.sr[0..frames], 0);
        p.mach.render(p.mach.state, &sub, self.sl[0..frames], self.sr[0..frames]);
        const g = std.math.pow(f32, 10, p.level_db / 20);
        const gl = g * @min(1, 1 - p.pan);
        const gr = g * @min(1, 1 + p.pan);
        for (l[0..frames], r[0..frames], self.sl[0..frames], self.sr[0..frames]) |*ol, *or_, a, b| {
            ol.* += a * gl;
            or_.* += b * gr;
        }
    }
}

fn resetImpl(state: *anyopaque) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.lock();
    defer self.unlock();
    for (self.parts[0..self.count]) |*p| {
        p.held_n = 0;
        p.mach.reset(p.mach.state);
    }
}

fn deinitImpl(state: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    self.clear();
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
    const data = presets_mod.readFileBuf(buf, Rack.presetDir(), self.presets.names[index].slice()) orelse return;
    var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
    defer parsed.deinit();
    self.applyJson(parsed.value);
    self.current_preset = index;
}

fn savePresetNamedImpl(state: *anyopaque, name_z: [*:0]const u8) ?machine.PresetIndex {
    const self: *Rack = @ptrCast(@alignCast(state));
    const name = std.mem.trim(u8, std.mem.span(name_z), " \t\r\n");
    if (name.len == 0 or name.len > presets_mod.MAX_NAME or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.alloc);
    out.appendSlice(self.alloc, "{\"schema\":1,\"machine\":\"rack\",") catch return null;
    const at = out.items.len;
    self.writeJson(&out, self.alloc) catch return null;
    // splice the parts object's body into the preset object
    std.mem.copyForwards(u8, out.items[at..], out.items[at + 1 ..]);
    out.shrinkRetainingCapacity(out.items.len - 1);
    out.append(self.alloc, '\n') catch return null;
    if (!presets_mod.writeFile(Rack.presetDir(), name, out.items)) return null;
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
//   ┌ PARTS ───────────┐┌ the selected part's own panel ┐
//   │ 1 ALTO1        ● ││                               │
//   │ 2 ALTO2          ││                               │
//   │ [key map lanes]  ││                               │
//   │ LO HI VLO VHI    ││                               │
//   │ TRN POLY LVL PAN ││                               │
//   │ [MACHINE] [+][−] ││                               │
//   └──────────────────┘└───────────────────────────────┘

fn panelWImpl(state: *anyopaque) f32 {
    const self: *Rack = @ptrCast(@alignCast(state));
    var w: f32 = 200;
    if (self.selected < self.count) {
        const m = &self.parts[self.selected].mach;
        w = if (m.panel_w_fn) |f| f(m.state) else if (m.panel_w > 0) m.panel_w else 200;
    }
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

const PART_COLORS = [_]ui_style.Color{
    ui_style.led_green, ui_style.vfd, ui_style.accent, ui_style.led_green.mix(ui_style.vfd, 0.5),
    ui_style.vfd.mix(ui_style.text, 0.4), ui_style.accent.mix(ui_style.text, 0.4), ui_style.led_green.mix(ui_style.text, 0.4), ui_style.text_dim,
};

fn drawPanelImpl(state: *anyopaque, ui: *Ui, rect: Rect) void {
    const self: *Rack = @ptrCast(@alignCast(state));
    var body = rect;
    var side = body.cutLeft(SIDE_W);
    ui.rect(side, ui_style.chassis);
    side = ctl.strip(ui, side.inset(4), "PARTS");

    // part list
    var i: usize = 0;
    while (i < MAX_PARTS) : (i += 1) {
        const row = side.cutTop(ROW_H);
        if (i >= self.count) {
            ui.rect(row.insetXY(0, 1), ui_style.well.alpha(120));
            continue;
        }
        const p = &self.parts[i];
        ui.pushId(i);
        defer ui.popId();
        var on = i == self.selected;
        var lb: [48]u8 = undefined;
        var a: [4]u8 = undefined;
        var b: [4]u8 = undefined;
        const text = std.fmt.bufPrint(&lb, "{d} {s}  {s}-{s}", .{ i + 1, p.labelSlice(), noteName(&a, p.lo), noteName(&b, p.hi) }) catch "?";
        if (ctl.button(ui, row, "sel", &on, .{ .kind = .latch, .label = text, .flush = true, .lit = PART_COLORS[i] })) self.selected = i;
    }
    _ = side.cutTop(4);

    // key map: a lane per part over the 128 keys
    const map = side.cutTop(@intCast(4 * MAX_PARTS / 2 + 4));
    ui.rect(map, ui_style.well);
    const lane_h: i32 = 2;
    for (self.parts[0..self.count], 0..) |*p, pi| {
        const x0 = map.x + 2 + @divFloor((map.w - 4) * @as(i32, p.lo), 128);
        const x1 = map.x + 2 + @divFloor((map.w - 4) * (@as(i32, p.hi) + 1), 128);
        const col = if (p.mute) ui_style.text_mute else PART_COLORS[pi];
        ui.rect(Rect.xywh(x0, map.y + 2 + @as(i32, @intCast(pi)) * lane_h, @max(1, x1 - x0), lane_h), if (pi == self.selected) col else col.alpha(140));
    }
    // octave ticks at the Cs
    var k: i32 = 0;
    while (k < 128) : (k += 12) ui.rect(Rect.xywh(map.x + 2 + @divFloor((map.w - 4) * k, 128), map.bottom() - 3, 1, 3), ui_style.text_mute);
    _ = side.cutTop(4);

    if (self.selected < self.count) {
        const p = &self.parts[self.selected];
        var s = p.*; // edit a copy, publish inside the fence
        var buf: [16]u8 = undefined;
        var half = side.cutTop(FIELD_H);
        var left = half.cutLeft(@divFloor(half.w, 2) - 2);
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
        const mute_r = btns.cutRight(44);
        _ = ctl.button(ui, mute_r, "mute", &s.mute, .{ .kind = .latch, .label = "MUTE", .led = ui_style.accent });
        if (s.lo != p.lo or s.hi != p.hi or s.vlo != p.vlo or s.vhi != p.vhi or s.transpose != p.transpose or
            s.poly != p.poly or s.level_db != p.level_db or s.pan != p.pan or s.mute != p.mute)
        {
            self.lock();
            p.lo = s.lo;
            p.hi = s.hi;
            p.vlo = s.vlo;
            p.vhi = s.vhi;
            p.transpose = s.transpose;
            p.poly = s.poly;
            p.level_db = s.level_db;
            p.pan = s.pan;
            p.mute = s.mute;
            self.unlock();
        }
        _ = btns.cutRight(4);
        const del_r = btns.cutRight(20);
        if (ctl.button(ui, del_r, "del", null, .{ .label = "\u{2212}" })) {
            self.removePart(self.selected);
        } else {
            menu.tip(ui, del_r, "Remove part");
            _ = btns.cutRight(4);
            const mkey = pane.keyFromIds(PICK_MENU_KEY, @intFromPtr(self), 1);
            if (ctl.button(ui, btns, "machine", null, .{ .label = self.reg.entries[p.reg_idx].nameSlice() }) and !menu.isOpen(mkey)) {
                bay.scanRegistryPresets(self.reg);
                menu.openBelow(mkey, btns);
            }
            menu.tip(ui, btns, "Replace this part's machine");
            if (bay.machinePickerMenuFor(mkey, self.reg, .instruments)) |pick| {
                self.replacePart(self.selected, pick.reg_idx) catch {};
                const np = &self.parts[self.selected];
                if (pick.preset) |pi| if (np.mach.apply_preset) |ap| {
                    ap(np.mach.state, pi);
                    if (np.mach.preset_name) |pn| np.setLabel(std.fmt.bufPrint(&buf, "{s}", .{lastSegment(std.mem.span(pn(np.mach.state, pi)))}) catch "");
                };
            }
        }
        _ = side.cutTop(4);
    }

    // add a part
    if (self.count < MAX_PARTS) {
        const add = side.cutTop(FIELD_H);
        const akey = pane.keyFromIds(PICK_MENU_KEY, @intFromPtr(self), 2);
        if (ctl.button(ui, add, "add", null, .{ .label = "+ PART" }) and !menu.isOpen(akey)) {
            bay.scanRegistryPresets(self.reg);
            menu.openBelow(akey, add);
        }
        menu.tip(ui, add, "Add a part: another machine layered or split");
        if (bay.machinePickerMenuFor(akey, self.reg, .instruments)) |pick| {
            if (self.addPart(pick.reg_idx)) |np| {
                self.selected = self.count - 1;
                if (pick.preset) |pi| if (np.mach.apply_preset) |ap| {
                    ap(np.mach.state, pi);
                    var buf: [64]u8 = undefined;
                    if (np.mach.preset_name) |pn| np.setLabel(std.fmt.bufPrint(&buf, "{s}", .{lastSegment(std.mem.span(pn(np.mach.state, pi)))}) catch "");
                };
            } else |_| {}
        }
    }

    // the selected part's own panel
    if (self.selected < self.count) {
        const m = &self.parts[self.selected].mach;
        ui.pushId(m.state);
        defer ui.popId();
        m.draw_panel(m.state, ui, body);
    } else {
        ui.rect(body, ui_style.well);
        ui.textIn(&ui.fonts.body, body, "Add a part", ui_style.text_mute, .center, true);
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
        m.render(m.state, &ctx, out[at..][0..512], &r);
        first = false;
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

test "rack: a split sends each key to its part, transposed; POLY releases the oldest; parts round-trip as JSON" {
    const a = testing.allocator;
    var reg = registry_mod.Registry.init(a);
    defer reg.deinit();
    try reg.loadFyMachine("machines/unfairlight/unfairlight.fy");
    try reg.loadNative();
    const rack = try Rack.create(a, &reg);
    const m = rack.machineInterface();
    defer m.deinit.?(m.state, a);

    // lower half plays as keyed, upper half an octave down; both dark
    // enough that zero crossings count the fundamental
    const lo = try rack.addPart(0);
    lo.hi = 59;
    const hi = try rack.addPart(0);
    hi.lo = 60;
    hi.transpose = -12;
    for (rack.parts[0..2]) |*p| {
        p.mach.set_param.?(p.mach.state, "cmi-filter", 60);
        p.mach.set_param.?(p.mach.state, "cmi-loop", 1);
    }

    var out = [_]f32{0} ** (512 * 24);
    // A2 on the lower part: the bundled pluck (A3) an octave down
    play(m, &.{noteOn(45, 1)}, &out);
    try testing.expectApproxEqRel(@as(f64, 110), acHz(out[512 * 4 ..]), 0.01);
    try testing.expectEqual(@as(u8, 1), rack.parts[0].held_n);
    try testing.expectEqual(@as(u8, 0), rack.parts[1].held_n);
    play(m, &.{noteOff(45, 1)}, &out);
    try testing.expectEqual(@as(u8, 0), rack.parts[0].held_n);
    // A4 on the upper part, down an octave: A3
    m.reset(m.state);
    play(m, &.{noteOn(69, 2)}, &out);
    try testing.expectApproxEqRel(@as(f64, 220), acHz(out[512 * 4 ..]), 0.01);
    try testing.expectEqual(@as(u8, 1), rack.parts[1].held_n);
    try testing.expectEqual(@as(f32, 57), rack.parts[1].held[0].pitch);
    m.reset(m.state);

    // POLY 1: a second note releases the first
    rack.parts[1].poly = 1;
    var evs: [8]NoteEvent = undefined;
    const in = [_]NoteEvent{ noteOn(72, 3), noteOn(74, 4) };
    const n = Rack.route(&rack.parts[1], &in, &evs);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(machine.NoteKind.note_off, evs[1].kind);
    try testing.expectEqual(@as(i32, 3), evs[1].note_id);
    try testing.expectEqual(@as(u8, 1), rack.parts[1].held_n);
    try testing.expectEqual(@as(i32, 4), rack.parts[1].held[0].id);
    m.reset(m.state);

    // JSON: the parts and their machines' settings come back
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(a);
    try m.write_state_json.?(m.state, &js, a);
    const rack2 = try Rack.create(a, &reg);
    const m2 = rack2.machineInterface();
    defer m2.deinit.?(m2.state, a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, js.items, .{});
    defer parsed.deinit();
    m2.apply_state_json.?(m2.state, parsed.value);
    try testing.expectEqual(@as(usize, 2), rack2.count);
    try testing.expectEqual(@as(u8, 59), rack2.parts[0].hi);
    try testing.expectEqual(@as(u8, 60), rack2.parts[1].lo);
    try testing.expectEqual(@as(i8, -12), rack2.parts[1].transpose);
    try testing.expectEqual(@as(u8, 1), rack2.parts[1].poly);
    var js2: std.ArrayList(u8) = .empty;
    defer js2.deinit(a);
    try m2.write_state_json.?(m2.state, &js2, a);
    try testing.expectEqualStrings(js.items, js2.items);
    try testing.expect(std.mem.indexOf(u8, js.items, "\"cmi-filter\":60") != null);

    // and the split still plays after the load
    play(m2, &.{noteOn(45, 5)}, &out);
    try testing.expect(rms(out[512 * 2 ..]) > 0.01);
}
