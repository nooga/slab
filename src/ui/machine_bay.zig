//! Machine bay — the selected track's device chain on the new Ui (docs/06,
//! docs/15). Each device is a column: a flush title strip
//!
//!   [×][NAME ●][ title display: preset / touched param ][▾][ON]
//!
//! over the machine's own panel. The chain scrolls sideways (trackpad
//! h-swipe or Shift+wheel) with a minimap when it overflows; effects
//! reorder by dragging their name tile. Menus (add / replace / presets /
//! delete confirm) are still the legacy widgets, anchored via `bridge`.

const std = @import("std");
const c = @import("../c.zig");
const pane = @import("pane_input.zig");
const menu = @import("menu.zig");
const bridge = @import("bridge.zig");
const track_mod = @import("../track.zig");
const Track = track_mod.Track;
const Effect = track_mod.Effect;
const registry_mod = @import("../machine_registry.zig");
const Registry = registry_mod.Registry;
const presets_mod = @import("../presets.zig");
const ui_core = @import("core.zig");
const ui_style = @import("style.zig");
const ctl = @import("controls.zig");
const Machine = @import("../machine.zig").Machine;

const Ui = ui_core.Ui;
const Rect = ui_core.Rect;

/// Which device on the selected track a titlebar action targets: the
/// instrument slot, or effect `i` in the insert chain.
pub const DeviceRef = union(enum) {
    instrument,
    effect: usize,
};

pub const Result = struct {
    minimize: bool = false,

    // Trailing "+" — add a brand-new device to the chain.
    add_machine: ?usize = null, // registry index to add
    add_preset: ?u16 = null, // preset (by sorted index) to apply after add

    // Name tile — swap an existing device for another machine.
    replace_ref: ?DeviceRef = null,
    replace_machine: ?usize = null, // registry index to swap in
    replace_preset: ?u16 = null, // preset to apply after the swap

    // Delete confirmed via the × popup.
    remove_ref: ?DeviceRef = null,

    // Preset actions, scoped to a device.
    preset_apply_ref: ?DeviceRef = null,
    preset_apply: ?u16 = null,
    preset_save_ref: ?DeviceRef = null, // open name entry to save a new preset
    preset_rename_ref: ?DeviceRef = null,
    preset_rename_index: ?u16 = null, // current preset to rename
    preset_anchor: c.rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, // where to float the name-entry field

    // Drag-reorder: move effect `from` to slot `to` (effects only).
    reorder_from: ?usize = null,
    reorder_to: ?usize = null,
};

pub const TITLE_H: i32 = 20;
const MINIMAP_H: i32 = 8;
const DEFAULT_PANEL_W: i32 = 200;
const DRAG_THRESHOLD: f32 = 6;

const ADD_MENU_KEY: u64 = 0x4d414444; // "MADD"
const REPLACE_MENU_KEY: u64 = 0x5245504c; // "REPL"
const PRESET_MENU_KEY: u64 = 0x50524553; // "PRES"
const CONFIRM_MENU_KEY: u64 = 0x434f4e46; // "CONF"
const SAVE_ITEM_ID: u32 = 9001;
const RENAME_ITEM_ID: u32 = 9002;
const DEFAULT_ITEM_ID: u32 = 9000;
const CONFIRM_DELETE_ID: u32 = 1;

// Preset lists per registry machine, scanned when the add/replace menu opens
// so hover drill-down doesn't hit the filesystem every frame.
var add_scan_cache: [registry_mod.MAX_MACHINES]presets_mod.List = undefined;

var bay_scroll_x: i32 = 0; // horizontal scroll of the device chain

// Effect drag-reorder: armed on a name-tile press, active once the pointer
// travels past DRAG_THRESHOLD; a release without travel is a click (opens
// the replace menu).
const ReorderDrag = struct {
    armed: bool = false,
    active: bool = false,
    src: usize = 0,
    press_x: f32 = 0,
};
var fx_drag: ReorderDrag = .{};

// Note-activity LED glow, keyed by track index. Bumped to 1.0 when the
// engine's note sequence advances, decayed each frame for a soft pulse.
var led_seen: [16]u32 = [_]u32{0} ** 16;
var led_glow: [16]f32 = [_]f32{0} ** 16;

fn panelW(mach: *const Machine) i32 {
    if (mach.panel_w_fn) |f| return @intFromFloat(@round(f(mach.state)));
    return if (mach.panel_w > 0) @intFromFloat(@round(mach.panel_w)) else DEFAULT_PANEL_W;
}

/// An effect card: its panel plus the I/O meter column.
fn effectW(fx: *const Effect) i32 {
    return panelW(&fx.mach) + IO_W;
}

/// IN | scale | OUT: two stereo bars sharing one graduated scale.
const IO_W: i32 = 48;
const IO_BAR_W: i32 = 10;

fn ioMeters(ui: *Ui, r: Rect, fx: *const Effect) void {
    ui.pushId("io");
    defer ui.popId();
    var body = ctl.strip(ui, r, "");
    const legend = body.cutTop(12);
    const pk = fx.io();
    var bars = body.insetXY(3, 2);
    const in_r = bars.cutLeft(IO_BAR_W);
    const out_r = bars.cutRight(IO_BAR_W);
    ui.textIn(&ui.fonts.legend, Rect.xywh(in_r.x - 3, legend.y, in_r.w + 6, 12), "IN", ui_style.text_dim, .center, true);
    ui.textIn(&ui.fonts.legend, Rect.xywh(out_r.x - 3, legend.y, out_r.w + 6, 12), "OUT", ui_style.text_dim, .center, true);
    ctl.meterStereo(ui, in_r, "in", pk.in, pk.in, .{ .scale = .none });
    ctl.meterStereo(ui, out_r, "out", pk.out, pk.out, .{ .scale = .none });
    ctl.meterScaleBetween(ui, bars, in_r);
    ui.animate();
}

pub fn draw(ui: *Ui, r_legacy: c.rl.Rectangle, device: ?*Track, track_idx: ?usize, is_bus: bool, collapsed: bool, reg: *const Registry) Result {
    var result = Result{};
    const r = bridge.fromRl(r_legacy);
    if (r.empty()) return result;
    ui.pushId("bay");
    defer ui.popId();

    // Right column: the fold button over a blank plate, never scrolled.
    var area = r;
    var fold_col = area.cutRight(TITLE_H);
    const fold = fold_col.cutTop(TITLE_H);
    if (ctl.button(ui, fold, "fold", null, .{ .glyph = if (collapsed) .tri_up else .tri_down, .flush = true })) result.minimize = true;
    menu.tip(ui, fold, if (collapsed) "Show machine bay" else "Hide machine bay");
    if (!fold_col.empty()) _ = ui.plate(fold_col, .{});

    if (collapsed) {
        _ = ui.plate(area.takeTop(TITLE_H), .{});
        return result;
    }
    const t = device orelse {
        emptyBay(ui, area, "SELECT A TRACK");
        return result;
    };

    // Measure the chain: (instrument) + effects + the trailing "+".
    const has_instrument = !is_bus and t.machine_idx != null;
    const inst_w: i32 = if (has_instrument) panelW(&t.machine) else 0;
    var content_w: i32 = inst_w + TITLE_H;
    for (t.effects.items) |*fx| content_w += effectW(fx);
    const overflow = content_w > area.w;
    const minimap = if (overflow) area.cutBottom(MINIMAP_H) else Rect{};
    const max_scroll = @max(0, content_w - area.w);

    // Horizontal scroll: trackpad h-swipe, or Shift+wheel.
    if (area.contains(ui.in.ix(), ui.in.iy())) {
        const wheel: f32 = if (ui.in.wheel_x != 0) ui.in.wheel_x else if (ui.in.shift) ui.in.wheel_y else 0;
        bay_scroll_x -= @intFromFloat(@round(wheel * 40));
    }
    bay_scroll_x = std.math.clamp(bay_scroll_x, 0, max_scroll);

    ui.clip(area);
    var x = area.x - bay_scroll_x;

    if (has_instrument) {
        var glow: f32 = 0;
        if (track_idx) |ti| if (ti < led_glow.len) {
            const seq = t.noteSeq();
            if (seq != led_seen[ti]) {
                led_glow[ti] = 1.0;
                led_seen[ti] = seq;
            } else led_glow[ti] = @max(0, led_glow[ti] - 0.05);
            glow = led_glow[ti];
            if (glow > 0) ui.animate();
        };
        const out = drawDevice(ui, Rect.xywh(x, area.y, inst_w, area.h), &t.machine, .instrument, null, t.isEnabled(), glow, reg, &result);
        if (out.toggle) t.toggleEnabled();
        x += inst_w;
    }

    // Effects. The drop slot for an active drag is the first card whose
    // midpoint lies right of the pointer.
    var drop_idx: usize = t.effects.items.len;
    var drop_x: i32 = x;
    {
        var ex = x;
        for (t.effects.items, 0..) |*fx, i| {
            const fw = effectW(fx);
            if (fx_drag.active and ui.in.mx < @as(f32, @floatFromInt(ex + @divFloor(fw, 2))) and drop_idx == t.effects.items.len) {
                drop_idx = i;
                drop_x = ex;
            }
            ex += fw;
        }
        if (drop_idx == t.effects.items.len) drop_x = ex;
    }
    for (t.effects.items, 0..) |*fx, i| {
        const fw = effectW(fx);
        const card = Rect.xywh(x, area.y, fw, area.h);
        const out = drawDevice(ui, card, &fx.mach, .{ .effect = i }, fx, !t.effectBypassed(i), null, reg, &result);
        if (out.toggle) t.toggleEffectBypass(i);
        if (out.name_pressed and !fx_drag.armed) fx_drag = .{ .armed = true, .src = i, .press_x = ui.in.mx };
        if (out.name_released and fx_drag.armed and fx_drag.src == i) {
            if (fx_drag.active) {
                var to = drop_idx;
                if (to > fx_drag.src) to -= 1; // removing src shifts the tail left
                if (to != fx_drag.src) {
                    result.reorder_from = fx_drag.src;
                    result.reorder_to = to;
                }
            } else {
                // A click, not a drag → the effect's replace menu.
                const key = pane.keyFromIds(REPLACE_MENU_KEY, @intFromPtr(fx.mach.state), 0);
                if (!menu.isOpen(key)) {
                    scanRegistryPresets(reg);
                    menu.openBelow(key, out.name_rect);
                }
            }
            fx_drag = .{};
        }
        if (fx_drag.active and fx_drag.src == i) ui.overlayRect(card, ui_style.accent.alpha(40));
        x += fw;
    }
    if (fx_drag.armed and ui.in.down and @abs(ui.in.mx - fx_drag.press_x) > DRAG_THRESHOLD) fx_drag.active = true;
    if (fx_drag.armed and !ui.in.down and !ui.in.released) fx_drag = .{};
    if (fx_drag.active) ui.overlayRect(Rect.xywh(drop_x - 1, area.y, 2, area.h), ui_style.accent);

    // Trailing "+" tile, then blank plates to the bay's right edge.
    if (x < area.right()) {
        const plus = Rect.xywh(x, area.y, TITLE_H, TITLE_H);
        var add_open = menu.isOpen(ADD_MENU_KEY);
        if (ctl.button(ui, plus, "add", &add_open, .{ .label = "+", .flush = true }) and !menu.isOpen(ADD_MENU_KEY)) {
            scanRegistryPresets(reg);
            menu.openBelow(ADD_MENU_KEY, plus);
        }
        menu.tip(ui, plus, "Add machine");
        _ = ui.plate(Rect.xywh(x + TITLE_H, area.y, area.right() - x - TITLE_H, TITLE_H), .{});
        _ = ui.plate(Rect.xywh(x, area.y + TITLE_H, area.right() - x, area.h - TITLE_H), .{});
    }
    if (machinePickerMenu(ADD_MENU_KEY, reg)) |pick| {
        result.add_machine = pick.reg_idx;
        result.add_preset = pick.preset;
    }
    ui.unclip();

    if (overflow) drawMinimap(ui, minimap, area.w, content_w, max_scroll, inst_w, t, is_bus);
    return result;
}

fn emptyBay(ui: *Ui, r: Rect, hint: []const u8) void {
    var a = r;
    _ = ui.plate(a.cutTop(TITLE_H), .{});
    const body = ui.plate(a, .{});
    ui.textIn(&ui.fonts.legend, body, hint, ui_style.text_mute, .center, true);
}

/// Overview of the chain with the visible window; click or drag to jump.
fn drawMinimap(ui: *Ui, r: Rect, view_w: i32, content_w: i32, max_scroll: i32, inst_w: i32, t: *Track, is_bus: bool) void {
    const inner = ui.well(r, ui_style.well);
    if (inner.w <= 0 or content_w <= 0) return;
    const k = @as(f32, @floatFromInt(inner.w)) / @as(f32, @floatFromInt(content_w));
    var bx: f32 = @floatFromInt(inner.x);
    if (!is_bus and inst_w > 0) {
        const w = @as(f32, @floatFromInt(inst_w)) * k;
        ui.rect(Rect.xywh(@intFromFloat(bx), inner.y, @max(1, @as(i32, @intFromFloat(w)) - 1), inner.h), ui_style.face_hi);
        bx += w;
    }
    for (t.effects.items) |*fx| {
        const w = @as(f32, @floatFromInt(effectW(fx))) * k;
        ui.rect(Rect.xywh(@intFromFloat(bx), inner.y, @max(1, @as(i32, @intFromFloat(w)) - 1), inner.h), ui_style.face);
        bx += w;
    }
    const vp = Rect.xywh(inner.x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(bay_scroll_x)) * k)), inner.y, @max(2, @as(i32, @intFromFloat(@as(f32, @floatFromInt(view_w)) * k))), inner.h);
    ui.rect(vp, ui_style.accent.alpha(50));
    ui.bevel(vp, ui_style.accent, ui_style.accent);
    const b = ui.behaviorEx(ui.id("minimap"), r, .{ .focusable = false });
    if (b.held) {
        const cx = (ui.in.mx - @as(f32, @floatFromInt(inner.x))) / k - @as(f32, @floatFromInt(view_w)) / 2;
        bay_scroll_x = std.math.clamp(@as(i32, @intFromFloat(cx)), 0, max_scroll);
    }
}

const DeviceOut = struct {
    toggle: bool = false, // mute / bypass clicked
    name_pressed: bool = false, // name tile pressed (effects arm a drag)
    name_released: bool = false,
    name_rect: Rect = .{},
};

fn isInstrument(ref: DeviceRef) bool {
    return switch (ref) {
        .instrument => true,
        .effect => false,
    };
}

// Draw one device column: the title strip, its menus, and the machine's
// panel body. Folds the name (replace), preset and delete-confirm outcomes
// into `result`, scoped to `ref`.
fn drawDevice(ui: *Ui, card: Rect, mach: *Machine, ref: DeviceRef, fx: ?*const Effect, active: bool, glow: ?f32, reg: *const Registry, result: *Result) DeviceOut {
    var out = DeviceOut{};
    ui.pushId(mach.state);
    defer ui.popId();
    const scope = ui.scopeId();
    if (!mach.host_titlebar) {
        drawPanel(ui, mach, card, scope);
        if (!active) ui.rect(card, ui_style.chassis.alpha(115));
        return out;
    }
    const is_inst = isInstrument(ref);
    var bar = card.takeTop(TITLE_H);
    var body = Rect.xywh(card.x, card.y + TITLE_H, card.w, card.h - TITLE_H);
    if (fx) |e| ioMeters(ui, body.cutRight(IO_W), e);

    // × delete → confirm popup.
    const del = bar.cutLeft(18);
    const confirm_key = pane.keyFromIds(CONFIRM_MENU_KEY, @intFromPtr(mach.state), 0);
    var confirm_open = menu.isOpen(confirm_key);
    if (ctl.button(ui, del, "del", &confirm_open, .{ .label = "\u{D7}", .flush = true }) and !menu.isOpen(confirm_key)) {
        menu.openBelow(confirm_key, del);
    }
    menu.tip(ui, del, if (is_inst) "Remove machine" else "Remove effect");
    if (deleteConfirmMenu(confirm_key)) result.remove_ref = ref;

    // Power / bypass on the right.
    const pwr = bar.cutRight(40);
    var on = active;
    if (ctl.button(ui, pwr, "power", &on, .{ .kind = .latch, .label = if (active) "ON" else if (is_inst) "OFF" else "BYP", .led = ui_style.led_green, .flush = true })) out.toggle = true;
    menu.tip(ui, pwr, if (is_inst) (if (active) "Enabled: click to silence" else "Silenced: click to enable") else (if (active) "Active: click to bypass" else "Bypassed: click to enable"));

    // Name tile: click → replace (instruments); press-drag → reorder (effects).
    const name = mach.name;
    const led_w: i32 = if (glow != null) 10 else 0;
    const name_w = @min(ui.fonts.body_bold.measure(name) + 14 + led_w, @max(40, @divFloor(bar.w, 2)));
    const name_r = bar.cutLeft(name_w);
    out.name_rect = name_r;
    const nid = ui.id("name");
    const nb = ui.behaviorEx(nid, name_r, .{ .focusable = false });
    out.name_pressed = nb.pressed;
    out.name_released = nb.released;
    _ = ctl.button(ui, name_r, "name-cap", null, .{ .flush = true, .disabled = true });
    ui.textIn(&ui.fonts.body_bold, Rect.xywh(name_r.x + 6, name_r.y, name_r.w - 8 - led_w, name_r.h - 1), name, if (ui.isHot(nid)) ui_style.text else ui_style.text_dim, .left, true);
    if (glow) |g| ctl.led(ui, name_r.right() - led_w - 2, name_r.y + @divFloor(name_r.h - 1 - 5, 2), .round5, if (g > 0.2) .on else .off, ui_style.led_green);
    menu.tip(ui, name_r, if (is_inst) "Replace machine" else "Drag to reorder, click to replace");
    const replace_key = pane.keyFromIds(REPLACE_MENU_KEY, @intFromPtr(mach.state), 0);
    if (is_inst and nb.clicked and !menu.isOpen(replace_key)) {
        scanRegistryPresets(reg);
        menu.openBelow(replace_key, name_r);
    }
    if (machinePickerMenu(replace_key, reg)) |pick| {
        result.replace_ref = ref;
        result.replace_machine = pick.reg_idx;
        result.replace_preset = pick.preset;
    }

    // Title display (preset name, or the touched parameter) + preset caret.
    // Clicking either opens the preset menu.
    if (hasPresets(mach)) {
        const caret = bar.cutRight(16);
        var pbuf: [40]u8 = undefined;
        const preset = std.mem.span(currentPresetLabel(&pbuf, mach));
        const disp = bar;
        const pid = ui.id("preset");
        const pb = ui.behaviorEx(pid, disp, .{ .focusable = false });
        const key = pane.keyFromIds(PRESET_MENU_KEY, @intFromPtr(mach.state), 1);
        var popen = menu.isOpen(key);
        const caret_clicked = ctl.button(ui, caret, "preset-caret", &popen, .{ .glyph = .tri_down, .glyph_on = ui_style.text, .flush = true });
        titleDisplay(ui, disp, scope, preset, ui.isHot(pid));
        menu.tip(ui, disp, "Preset");
        const pa = presetMenu(disp, pb.clicked or caret_clicked, mach);
        if (pa.apply) |p| {
            result.preset_apply_ref = ref;
            result.preset_apply = p;
        }
        if (pa.save) {
            result.preset_save_ref = ref;
            result.preset_anchor = bridge.toRl(disp);
        }
        if (pa.rename) |idx| {
            result.preset_rename_ref = ref;
            result.preset_rename_index = idx;
            result.preset_anchor = bridge.toRl(disp);
        }
    } else {
        titleDisplay(ui, bar, scope, "", false);
    }

    drawPanel(ui, mach, body, scope);
    // Silenced/bypassed: the panel dims (drawn in the Ui list, over it).
    if (!active) ui.rect(body, ui_style.chassis.alpha(115));
    return out;
}

/// The machine's panel, with every touch in it reported under the device's
/// scope (a voice pool draws its first voice's panel, a panel scopes its
/// own controls; neither changes whose title display they feed).
fn drawPanel(ui: *Ui, mach: *Machine, r: Rect, scope: ui_core.Id) void {
    ui.touch_scope = scope;
    defer ui.touch_scope = null;
    mach.draw_panel(mach.state, ui, r);
}

/// The device's title display: the preset name, or `LABEL value` while a
/// control in this machine's panel is being touched (docs/06 §Displays).
fn titleDisplay(ui: *Ui, r: Rect, panel_scope: ui_core.Id, preset: []const u8, hot: bool) void {
    const t = &ui.touch;
    var buf: [48]u8 = undefined;
    const live = t.scope == panel_scope and ui.in.time - t.time < ui_core.TOUCH_HOLD;
    const s = if (live)
        std.fmt.bufPrint(&buf, "{s} {s}", .{ t.labelStr(), t.valueStr() }) catch preset
    else
        preset;
    if (live) ui.animate();
    ctl.display(ui, r, s, .{ .flush = true, .color = if (hot or live) ui_style.vfd else ui_style.vfd.mix(ui_style.well, 0.15) });
}

pub const AddPick = struct {
    reg_idx: usize,
    preset: ?u16 = null,
};

// Scan every registry machine's preset directory into add_scan_cache, so the
// picker's hover drill-down doesn't hit the filesystem each frame.
pub fn scanRegistryPresets(reg: *const Registry) void {
    const menu_count = @min(reg.count, registry_mod.MAX_MACHINES);
    for (reg.entries[0..menu_count], 0..) |*e, i| {
        var dbuf: [512]u8 = undefined;
        add_scan_cache[i] = if (presets_mod.dirFromMachinePath(&dbuf, e.pathSlice())) |dir|
            presets_mod.scan(dir)
        else
            presets_mod.List{};
    }
}


// Drive an already-open machine-picker menu (by key): a flat machine list,
// each machine with presets carrying a hover submenu (+ a deeper level for
// preset subdirectories). Returns the pick when a row is chosen. Shared by
// the trailing "+" (add) and the name block (replace).
fn machinePickerMenu(menu_key: u64, reg: *const Registry) ?AddPick {
    return machinePickerMenuFor(menu_key, reg, .all);
}

/// Which machines a picker offers: all, or the fy instruments a rack's
/// parts can be.
pub const PickerFilter = enum { all, instruments };

pub fn machinePickerMenuFor(menu_key: u64, reg: *const Registry, filter: PickerFilter) ?AddPick {
    if (!menu.isOpen(menu_key)) return null;
    const menu_count = @min(reg.count, registry_mod.MAX_MACHINES);
    var items: [registry_mod.MAX_MACHINES]menu.Item = undefined;
    var n: usize = 0;
    for (reg.entries[0..menu_count], 0..) |*e, i| {
        if (filter == .instruments and (e.native != .none or !e.in_notes)) continue;
        items[n] = .{ .label = std.mem.span(e.nameZ()), .id = @intCast(i), .submenu = add_scan_cache[i].count > 0 };
        n += 1;
    }
    if (menu.pick(menu_key, items[0..n])) |id| return .{ .reg_idx = @intCast(id) };

    if (menu.subOpen(menu_key, 0)) |mach_id| {
        const list = &add_scan_cache[mach_id];
        var pitems: [presets_mod.MAX_PRESETS + 1]menu.Item = undefined;
        pitems[0] = .{ .label = "(default)", .id = DEFAULT_ITEM_ID };
        const pn = 1 + presetTopItems(list, pitems[1..]);
        if (menu.subPick(menu_key, 1, pitems[0..pn])) |sel| {
            return .{ .reg_idx = @intCast(mach_id), .preset = if (sel == DEFAULT_ITEM_ID) null else @intCast(sel) };
        }
        if (menu.subOpen(menu_key, 1)) |dir_id| {
            if (dir_id >= DIR_ID_BASE) {
                var ditems: [presets_mod.MAX_PRESETS]menu.Item = undefined;
                const dn = presetDirItems(list, dir_id - DIR_ID_BASE, &ditems);
                if (menu.subPick(menu_key, 2, ditems[0..dn])) |sel| {
                    if (sel < DIR2_ID_BASE) return .{ .reg_idx = @intCast(mach_id), .preset = @intCast(sel) };
                }
                if (menu.subOpen(menu_key, 2)) |sub_id| {
                    if (sub_id >= DIR2_ID_BASE) {
                        var sitems: [presets_mod.MAX_PRESETS]menu.Item = undefined;
                        const sn = presetSubDirItems(list, dir_id - DIR_ID_BASE, sub_id - DIR2_ID_BASE, &sitems);
                        if (menu.subPick(menu_key, 3, sitems[0..sn])) |sel| {
                            return .{ .reg_idx = @intCast(mach_id), .preset = @intCast(sel) };
                        }
                    }
                }
            }
        }
    }
    return null;
}

// Beveled "Delete machine?" confirm popup, anchored under the "[-]" button.
// Opened by the caller; returns true only when the user picks Delete.
// Click-away closes via the deferred-menu's outside-click handling.
fn deleteConfirmMenu(key: u64) bool {
    if (!menu.isOpen(key)) return false;
    const items = [_]menu.Item{
        .{ .label = "Delete machine?", .enabled = false },
        .{ .separator = true },
        .{ .label = "Delete", .id = CONFIRM_DELETE_ID },
        .{ .label = "Cancel", .id = 2 },
    };
    if (menu.pick(key, &items)) |id| return id == CONFIRM_DELETE_ID;
    return false;
}

const PresetAction = struct {
    apply: ?u16 = null,
    save: bool = false,
    rename: ?u16 = null, // index of the preset to rename (the current one)
};

const DIR_ID_BASE: u32 = 10000;
// Second-level bank rows (a collection's disks): DIR2_ID_BASE + their order
// inside the open bank.
const DIR2_ID_BASE: u32 = 20000;
// Backing for bank-submenu row labels: one slot per distinct preset
// subdirectory. Capped — banks beyond this just don't get a submenu row.
var dir_label_bufs: [64][presets_mod.MAX_NAME + 1:0]u8 = undefined;
var dir2_label_bufs: [128][presets_mod.MAX_NAME + 1:0]u8 = undefined;
// Persistent backing for the open preset menu's item labels (see
// presetMenu — the menu draws deferred, so a stack list would dangle).
var preset_menu_list: presets_mod.List = .{};

// Top-level menu rows for a sorted preset list: plain leaves (id = flat
// list index), then one hover-submenu row per distinct subdirectory.
fn presetTopItems(list: *const presets_mod.List, items: []menu.Item) usize {
    var n: usize = 0;
    for (list.names[0..list.count], 0..) |*nm, i| {
        if (std.mem.indexOfScalar(u8, nm.slice(), '/') != null) continue;
        if (n >= items.len) return n;
        items[n] = .{ .label = std.mem.span(nm.z()), .id = @intCast(i) };
        n += 1;
    }
    var ord: usize = 0;
    var last: []const u8 = "";
    for (list.names[0..list.count]) |*nm| {
        const sl = std.mem.indexOfScalar(u8, nm.slice(), '/') orelse continue;
        const dirn = nm.slice()[0..sl];
        if (std.mem.eql(u8, dirn, last)) continue;
        last = dirn;
        if (ord < dir_label_bufs.len and n < items.len) {
            const buf = &dir_label_bufs[ord];
            const l = @min(dirn.len, presets_mod.MAX_NAME);
            @memcpy(buf[0..l], dirn[0..l]);
            items[n] = .{ .label = buf[0..l], .id = @intCast(DIR_ID_BASE + ord), .submenu = true };
            n += 1;
        }
        ord += 1;
    }
    return n;
}


// Rows of the ord-th distinct subdirectory: id = flat list index, label =
// the name after the slash.
fn presetDirItems(list: *const presets_mod.List, dir_ord: usize, items: []menu.Item) usize {
    // leaves first, then one submenu row per distinct second-level folder
    var n: usize = 0;
    var it = BankIter{ .list = list, .dir_ord = dir_ord };
    while (it.next()) |e| {
        if (std.mem.indexOfScalar(u8, e.rest, '/') != null) continue;
        if (n >= items.len) return n;
        items[n] = .{ .label = e.rest, .id = @intCast(e.index) };
        n += 1;
    }
    var ord: usize = 0;
    var last: []const u8 = "";
    it = BankIter{ .list = list, .dir_ord = dir_ord };
    while (it.next()) |e| {
        const sl = std.mem.indexOfScalar(u8, e.rest, '/') orelse continue;
        const sub = e.rest[0..sl];
        if (std.mem.eql(u8, sub, last)) continue;
        last = sub;
        if (ord < dir2_label_bufs.len and n < items.len) {
            const buf = &dir2_label_bufs[ord];
            const l = @min(sub.len, presets_mod.MAX_NAME);
            @memcpy(buf[0..l], sub[0..l]);
            items[n] = .{ .label = buf[0..l], .id = @intCast(DIR2_ID_BASE + ord), .submenu = true };
            n += 1;
        }
        ord += 1;
    }
    return n;
}

// Rows of the sub_ord-th second-level folder inside bank dir_ord.
fn presetSubDirItems(list: *const presets_mod.List, dir_ord: usize, sub_ord: usize, items: []menu.Item) usize {
    var n: usize = 0;
    var ord: usize = 0;
    var last: []const u8 = "";
    var it = BankIter{ .list = list, .dir_ord = dir_ord };
    while (it.next()) |e| {
        const sl = std.mem.indexOfScalar(u8, e.rest, '/') orelse continue;
        const sub = e.rest[0..sl];
        if (!std.mem.eql(u8, sub, last)) {
            last = sub;
            ord += 1;
        }
        if (ord - 1 != sub_ord) continue;
        if (n >= items.len) return n;
        items[n] = .{ .label = e.rest[sl + 1 ..], .id = @intCast(e.index) };
        n += 1;
    }
    return n;
}

// The entries of the dir_ord-th distinct top-level bank, in list order:
// the flat index and the name after the bank's slash.
const BankIter = struct {
    list: *const presets_mod.List,
    dir_ord: usize,
    i: usize = 0,
    ord: usize = 0,
    last: []const u8 = "",

    const Entry = struct { index: usize, rest: []const u8 };

    fn next(self: *BankIter) ?Entry {
        while (self.i < self.list.count) {
            const idx = self.i;
            self.i += 1;
            const nm = self.list.names[idx].slice();
            const sl = std.mem.indexOfScalar(u8, nm, '/') orelse continue;
            const dirn = nm[0..sl];
            if (!std.mem.eql(u8, dirn, self.last)) {
                self.last = dirn;
                self.ord += 1;
            }
            if (self.ord - 1 != self.dir_ord) continue;
            return .{ .index = idx, .rest = nm[sl + 1 ..] };
        }
        return null;
    }
};

// Whether a machine exposes a preset block (any preset facility at all).
fn hasPresets(mach: *const Machine) bool {
    const count: usize = if (mach.preset_count) |cf| cf(mach.state) else 0;
    return count > 0 or mach.save_preset != null or mach.save_preset_named != null;
}

// Current preset name for the preset block, or "init" when none is selected.
fn currentPresetLabel(buf: []u8, mach: *const Machine) [*:0]const u8 {
    if (mach.current_preset) |cpf| {
        const idx = cpf(mach.state);
        if (idx >= 0) {
            if (mach.preset_name) |nf| {
                const nm = std.mem.span(nf(mach.state, @intCast(idx)));
                const l = @min(nm.len, buf.len - 1);
                @memcpy(buf[0..l], nm[0..l]);
                buf[l] = 0;
                return @ptrCast(&buf[0]);
            }
        }
    }
    return "init";
}

// Clicking the preset block opens the preset menu: preset leaves, one hover
// submenu per subdirectory, then Save…/Rename… rows. Save…/Rename… defer to
// a host text-entry overlay (the caller routes them through RenameState).
fn presetMenu(preset_rect: Rect, clicked: bool, mach: *const Machine) PresetAction {
    const count: usize = if (mach.preset_count) |cf| cf(mach.state) else 0;
    const can_save = mach.save_preset != null or mach.save_preset_named != null;
    const cur_idx: i32 = if (mach.current_preset) |cf| cf(mach.state) else -1;
    const can_rename = mach.rename_preset != null and cur_idx >= 0;
    if (count == 0 and !can_save) return .{};

    const key = pane.keyFromIds(PRESET_MENU_KEY, @intFromPtr(mach.state), 1);
    if (clicked and !menu.isOpen(key)) menu.openBelow(key, preset_rect);

    // Deferred-draw menu: the backing list must outlive this call (a stack
    // local would dangle into drawContextMenu). Module-level, repopulated
    // only for the menu that is actually open.
    if (menu.isOpen(key)) {
        preset_menu_list = .{};
        if (mach.preset_name) |nf| {
            var i: usize = 0;
            while (i < count and i < presets_mod.MAX_PRESETS) : (i += 1) {
                preset_menu_list.names[i] = presets_mod.Name.set(std.mem.span(nf(mach.state, @intCast(i))));
            }
            preset_menu_list.count = i;
        }
    }

    var items: [presets_mod.MAX_PRESETS + 3]menu.Item = undefined;
    var n = presetTopItems(&preset_menu_list, items[0..presets_mod.MAX_PRESETS]);
    if (can_save or can_rename) {
        if (n > 0) {
            items[n] = .{ .separator = true };
            n += 1;
        }
        if (can_save) {
            items[n] = .{ .label = "Save preset…", .id = SAVE_ITEM_ID };
            n += 1;
        }
        if (can_rename) {
            items[n] = .{ .label = "Rename…", .id = RENAME_ITEM_ID };
            n += 1;
        }
    }
    if (menu.pick(key, items[0..n])) |id| {
        if (id == SAVE_ITEM_ID) return .{ .save = true };
        if (id == RENAME_ITEM_ID) return .{ .rename = @intCast(cur_idx) };
        return .{ .apply = @intCast(id) };
    }
    if (menu.subOpen(key, 0)) |dir_id| {
        if (dir_id >= DIR_ID_BASE) {
            var ditems: [presets_mod.MAX_PRESETS]menu.Item = undefined;
            const dn = presetDirItems(&preset_menu_list, dir_id - DIR_ID_BASE, &ditems);
            if (menu.subPick(key, 1, ditems[0..dn])) |id| {
                if (id < DIR2_ID_BASE) return .{ .apply = @intCast(id) };
            }
            if (menu.subOpen(key, 1)) |sub_id| {
                if (sub_id >= DIR2_ID_BASE) {
                    var sitems: [presets_mod.MAX_PRESETS]menu.Item = undefined;
                    const sn = presetSubDirItems(&preset_menu_list, dir_id - DIR_ID_BASE, sub_id - DIR2_ID_BASE, &sitems);
                    if (menu.subPick(key, 2, sitems[0..sn])) |id| {
                        return .{ .apply = @intCast(id) };
                    }
                }
            }
        }
    }
    return .{};
}

