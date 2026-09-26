//! Bottom pane — hosts the selected track's machine panel. In expanded
//! mode the machine's own title strip is the strip title; unused space is
//! filled by a packed placeholder cell with the collapse button.

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const Track = @import("../track.zig").Track;
const registry_mod = @import("../machine_registry.zig");
const Registry = registry_mod.Registry;
const presets_mod = @import("../presets.zig");
const ui_core = @import("core.zig");
const ui_style = @import("style.zig");

/// Legacy f32 rect → new-core logical rect (the app runs the Ui at zoom 1).
fn uiRect(r: c.rl.Rectangle) ui_core.Rect {
    return ui_core.Rect.xywh(@intFromFloat(@round(r.x)), @intFromFloat(@round(r.y)), @intFromFloat(@round(r.width)), @intFromFloat(@round(r.height)));
}

/// Which device on the selected track a titlebar action targets: the
/// instrument slot, or effect `i` in the insert chain.
pub const DeviceRef = union(enum) {
    instrument,
    effect: usize,
};

pub const Result = struct {
    minimize: bool = false,
    poly_voices: ?u8 = null,

    // Trailing "+" — add a brand-new device to the chain.
    add_machine: ?usize = null, // registry index to add
    add_preset: ?u8 = null, // preset (by sorted index) to apply after add

    // Name block — swap an existing device for another machine.
    replace_ref: ?DeviceRef = null,
    replace_machine: ?usize = null, // registry index to swap in
    replace_preset: ?u8 = null, // preset to apply after the swap

    // Delete confirmed via the "[-]" popup.
    remove_ref: ?DeviceRef = null,

    // Preset block actions, scoped to a device.
    preset_apply_ref: ?DeviceRef = null,
    preset_apply: ?u8 = null,
    preset_save_ref: ?DeviceRef = null, // open name entry to save a new preset
    preset_rename_ref: ?DeviceRef = null,
    preset_rename_index: ?u8 = null, // current preset to rename
    preset_anchor: c.rl.Rectangle = zeroRect, // where to float the name-entry field

    // Drag-reorder: move effect `from` to slot `to` (effects only).
    reorder_from: ?usize = null,
    reorder_to: ?usize = null,
};

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

var poly_dropdown_track: ?usize = null;
var bay_scroll_x: f32 = 0; // horizontal scroll of the device chain

// Effect drag-reorder state. `active` is set once the pointer crosses the
// drag threshold from the grab; `src` is the effect index being dragged and
// `grab_x` the pointer x at press (to render the card following the cursor).
const ReorderDrag = struct {
    armed: bool = false, // pressed on an effect bar, not yet past threshold
    active: bool = false,
    src: usize = 0,
    press_x: f32 = 0,
    press_y: f32 = 0,
    cur_x: f32 = 0,
};
var fx_drag: ReorderDrag = .{};
const DRAG_THRESHOLD: f32 = 6;

// Note-activity LED glow, keyed by track index. Bumped to 1.0 when the
// engine's note sequence advances, decayed each frame for a soft pulse.
var led_seen: [16]u32 = [_]u32{0} ** 16;
var led_glow: [16]f32 = [_]f32{0} ** 16;

fn lerpColor(a: c.rl.Color, b: c.rl.Color, t: f32) c.rl.Color {
    const k = std.math.clamp(t, 0, 1);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * k),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * k),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * k),
        .a = 255,
    };
}

// A small square titlebar button (enable toggle / delete). Returns true
// on click. `lit` brightens the fill; `danger` tints red on hover.
fn titlebarButton(btn: c.rl.Rectangle, icon: widgets.Icon, lit: bool, danger: bool, hint: [*:0]const u8, m: widgets.Mouse) bool {
    const hover = widgets.contains(btn, m.x, m.y) and !widgets.hasActiveDrag();
    const pressed = hover and m.left_down;
    const fill = if (pressed)
        theme.slab_lo
    else if (hover and danger)
        theme.accent_rec
    else if (hover or lit)
        theme.slab_hi
    else
        theme.slab_fill;
    widgets.bevelRaised(btn, fill, theme.slab_hi, theme.slab_lo);
    const icol = if (lit) theme.accent_hi else theme.text_dim;
    const isz = theme.fsTiny();
    widgets.drawIcon(icon, btn.x + (btn.width - isz) / 2, btn.y + (btn.height - isz) / 2, isz, if (hover and danger) theme.text_fg else icol);
    widgets.tooltip(btn, hint, m);
    return hover and m.left_pressed;
}

// Note-activity LED — a small filled indicator, not interactive.
fn drawNoteLed(r: c.rl.Rectangle, glow: f32, m: widgets.Mouse) void {
    const base = c.rl.Color{ .r = 28, .g = 52, .b = 34, .a = 255 };
    const col = lerpColor(base, theme.accent_play, glow);
    const d = theme.fine(7);
    const cx = r.x + r.width / 2;
    const cy = r.y + r.height / 2;
    c.rl.DrawRectangle(@intFromFloat(cx - d / 2), @intFromFloat(cy - d / 2), @intFromFloat(d), @intFromFloat(d), col);
    c.rl.DrawRectangleLinesEx(widgets.rect(cx - d / 2 - 1, cy - d / 2 - 1, d + 2, d + 2), 1, theme.slab_edge);
    widgets.tooltip(r, "Note activity", m);
}


const DeviceCtrls = struct {
    toggle: bool = false, // mute / bypass clicked
    delete_clicked: bool = false, // "[-]" clicked → caller opens confirm popup
    name_clicked: bool = false, // name block clicked → caller opens replace menu
    preset_clicked: bool = false, // preset block clicked → caller opens preset menu
    name_rect: c.rl.Rectangle = zeroRect,
    preset_rect: c.rl.Rectangle = zeroRect,
};

const zeroRect = c.rl.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };

// Subtle accent tint for the device-name block — a desaturated lean toward
// the amber accent so the name reads as the focal, clickable identity block
// without shouting (BeOS-tab flavored, kept brutalist).
fn nameTint(hover: bool) c.rl.Color {
    return lerpColor(theme.slab_fill, theme.accent_hi, if (hover) 0.30 else 0.16);
}

// A clickable titlebar text block: 1px raised bevel, centered-left label.
// Returns true on press. `fill` lets the name block carry its accent tint.
fn barBlock(r: c.rl.Rectangle, label: [*:0]const u8, fill: c.rl.Color, m: widgets.Mouse) bool {
    if (r.width <= 0) return false;
    widgets.bevelRaised(r, fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF(label, r.x + theme.size(6), r.y + (r.height - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_fg);
    return widgets.contains(r, m.x, m.y) and !widgets.hasActiveDrag() and m.left_pressed;
}

// Host-drawn device titlebar, brutalist BeOS-rack flavored:
//
//   [ - ][  NAME ● ][ preset ]······spacer······[ mute ]
//
// Delete first, accent-tinted name (click → replace), optional preset block
// (click → preset menu), a neutral spacer, and the mute/bypass toggle last.
// The note-activity LED sits at the name block's right edge (instruments).
fn drawDeviceBar(
    bar: c.rl.Rectangle,
    name: []const u8,
    preset_label: ?[*:0]const u8,
    active: bool,
    glow: ?f32,
    icon_on: widgets.Icon,
    icon_off: widgets.Icon,
    hint_on: [*:0]const u8,
    hint_off: [*:0]const u8,
    del_hint: [*:0]const u8,
    m: widgets.Mouse,
) DeviceCtrls {
    var res = DeviceCtrls{};
    const bw = theme.size(16);
    const pad = theme.size(6);

    // Fixed end buttons.
    const del = widgets.rect(bar.x, bar.y, bw, bar.height);
    const mute = widgets.rect(bar.x + bar.width - bw, bar.y, bw, bar.height);

    if (titlebarButton(del, .minus, false, true, del_hint, m)) res.delete_clicked = true;
    {
        const icon = if (active) icon_on else icon_off;
        const hint = if (active) hint_on else hint_off;
        if (titlebarButton(mute, icon, active, false, hint, m)) res.toggle = true;
    }

    const chrome_left = del.x + bw;
    const chrome_right = mute.x;
    const avail = @max(0, chrome_right - chrome_left);

    // Name block — fit to content (plus LED), capped so it leaves room for
    // the preset block and spacer.
    var nbuf: [64:0]u8 = [_:0]u8{0} ** 64;
    const nlen = @min(name.len, 63);
    @memcpy(nbuf[0..nlen], name[0..nlen]);
    nbuf[nlen] = 0;
    const led_w: f32 = if (glow != null) theme.size(14) else 0;
    const name_text_w = widgets.measureTextF(@ptrCast(&nbuf[0]), theme.fsTiny());
    const name_w = @min(pad * 2 + name_text_w + led_w, @max(theme.size(40), avail * 0.55));
    const name_rect = widgets.rect(chrome_left, bar.y, name_w, bar.height);
    res.name_rect = name_rect;
    const name_hover = widgets.contains(name_rect, m.x, m.y) and !widgets.hasActiveDrag();
    if (barBlock(name_rect, @ptrCast(&nbuf[0]), nameTint(name_hover), m)) res.name_clicked = true;
    widgets.tooltip(name_rect, "Replace machine", m);
    if (glow) |g| {
        const led_r = widgets.rect(name_rect.x + name_rect.width - led_w, name_rect.y, led_w, name_rect.height);
        drawNoteLed(led_r, g, m);
    }

    // Preset block — neutral bevel, current preset label.
    var preset_right = chrome_left + name_w;
    if (preset_label) |pl| {
        const pt_w = widgets.measureTextF(pl, theme.fsTiny());
        const preset_w = @min(pad * 2 + pt_w, @max(0, chrome_right - (chrome_left + name_w) - theme.size(8)));
        if (preset_w > theme.size(12)) {
            const preset_rect = widgets.rect(chrome_left + name_w, bar.y, preset_w, bar.height);
            res.preset_rect = preset_rect;
            const ph = widgets.contains(preset_rect, m.x, m.y) and !widgets.hasActiveDrag();
            const pfill = if (ph) theme.slab_hi else theme.slab_fill;
            if (barBlock(preset_rect, pl, pfill, m)) res.preset_clicked = true;
            widgets.tooltip(preset_rect, "Preset", m);
            preset_right = preset_rect.x + preset_rect.width;
        }
    }

    // Spacer — flat neutral chrome filling the gap before the mute button.
    if (chrome_right - preset_right > 0) {
        widgets.bevelRaised(widgets.rect(preset_right, bar.y, chrome_right - preset_right, bar.height), theme.slab_fill, theme.slab_hi, theme.slab_lo);
    }
    return res;
}

const AddPick = struct {
    reg_idx: usize,
    preset: ?u8 = null,
};

// Scan every registry machine's preset directory into add_scan_cache, so the
// picker's hover drill-down doesn't hit the filesystem each frame.
fn scanRegistryPresets(reg: *const Registry) void {
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
fn machinePickerMenu(menu_key: u64, reg: *const Registry, m: widgets.Mouse) ?AddPick {
    if (!widgets.menuOpen(menu_key)) return null;
    const menu_count = @min(reg.count, registry_mod.MAX_MACHINES);
    var items: [registry_mod.MAX_MACHINES]widgets.MenuItem = undefined;
    var n: usize = 0;
    for (reg.entries[0..menu_count], 0..) |*e, i| {
        items[n] = .{ .label = e.nameZ(), .id = @intCast(i), .submenu = add_scan_cache[i].count > 0 };
        n += 1;
    }
    if (widgets.menuPickId(menu_key, items[0..n], m)) |id| return .{ .reg_idx = @intCast(id) };

    if (widgets.menuSubOpen(menu_key, 0)) |mach_id| {
        const list = &add_scan_cache[mach_id];
        var pitems: [presets_mod.MAX_PRESETS + 1]widgets.MenuItem = undefined;
        pitems[0] = .{ .label = "(default)", .id = DEFAULT_ITEM_ID };
        const pn = 1 + presetTopItems(list, pitems[1..]);
        if (widgets.menuSubTick(menu_key, 1, pitems[0..pn], m)) |sel| {
            return .{ .reg_idx = @intCast(mach_id), .preset = if (sel == DEFAULT_ITEM_ID) null else @intCast(sel) };
        }
        if (widgets.menuSubOpen(menu_key, 1)) |dir_id| {
            if (dir_id >= DIR_ID_BASE) {
                var ditems: [presets_mod.MAX_PRESETS]widgets.MenuItem = undefined;
                const dn = presetDirItems(list, dir_id - DIR_ID_BASE, &ditems);
                if (widgets.menuSubTick(menu_key, 2, ditems[0..dn], m)) |sel| {
                    return .{ .reg_idx = @intCast(mach_id), .preset = @intCast(sel) };
                }
            }
        }
    }
    return null;
}

// "+" button at the right end of the device chain → add a machine.
fn drawAddButton(btn: c.rl.Rectangle, reg: *const Registry, m: widgets.Mouse) ?AddPick {
    const open = widgets.menuOpen(ADD_MENU_KEY);
    const hover = widgets.contains(btn, m.x, m.y) and !widgets.hasActiveDrag();
    const fill = if (open or hover) theme.slab_hi else theme.slab_fill;
    widgets.bevelRaised(btn, fill, theme.slab_hi, theme.slab_lo);
    const isz = theme.fsBody();
    widgets.drawIcon(.plus, btn.x + (btn.width - isz) / 2, btn.y + (btn.height - isz) / 2, isz, theme.text_fg);
    widgets.tooltip(btn, "Add machine", m);
    if (hover and m.left_pressed and !open) {
        scanRegistryPresets(reg);
        widgets.openMenuAt(ADD_MENU_KEY, btn.x, btn.y + btn.height);
    }
    return machinePickerMenu(ADD_MENU_KEY, reg, m);
}

// Beveled "Delete machine?" confirm popup, anchored under the "[-]" button.
// Opened by the caller; returns true only when the user picks Delete.
// Click-away closes via the deferred-menu's outside-click handling.
fn deleteConfirmMenu(key: u64, m: widgets.Mouse) bool {
    if (!widgets.menuOpen(key)) return false;
    const items = [_]widgets.MenuItem{
        .{ .label = "Delete machine?", .enabled = false },
        .{ .separator = true },
        .{ .label = "Delete", .id = CONFIRM_DELETE_ID },
        .{ .label = "Cancel", .id = 2 },
    };
    if (widgets.menuPickId(key, &items, m)) |id| return id == CONFIRM_DELETE_ID;
    return false;
}

pub fn draw(ui: *ui_core.Ui, r: c.rl.Rectangle, device: ?*Track, track_idx: ?usize, is_bus: bool, collapsed: bool, reg: *const Registry, m: widgets.Mouse) Result {
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    var result = Result{};

    const header_h = @min(r.height, theme.paneHeaderH());

    if (collapsed) {
        const res = drawPlaceholder(r, header_h, true, null, m);
        return .{ .minimize = res.minimize };
    }

    const t = device orelse {
        // Nothing selected.
        const res = drawPlaceholder(r, header_h, false, "select a track", m);
        return .{ .minimize = res.minimize };
    };

    // Audio tracks with no instrument start the chain straight at the
    // effects (no placeholder card); machines are added via the trailing
    // "+". Buses (master/return) likewise have no instrument slot.
    const DEFAULT_PANEL_W = theme.size(200);
    const has_instrument = !is_bus and t.machine_idx != null;
    const inst_pw: f32 = if (!has_instrument)
        0
    else if (t.machine.panel_w > 0)
        theme.size(t.machine.panel_w)
    else
        DEFAULT_PANEL_W;

    // Measure the chain ((instrument) + effects + trailing "+") to decide
    // whether a horizontal minimap is needed at the bottom of the bay.
    var content_w: f32 = inst_pw;
    for (t.effects.items) |*fx| {
        content_w += if (fx.mach.panel_w > 0) theme.size(fx.mach.panel_w) else DEFAULT_PANEL_W;
    }
    content_w += header_h;
    const overflow = content_w > r.width;
    const minimap_h: f32 = if (overflow) theme.size(11) else 0;
    const dev_h = r.height - minimap_h;
    const max_scroll = @max(0, content_w - r.width);

    // Horizontal scroll (trackpad h-wheel / Shift+wheel).
    {
        const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
        const wheel: f32 = if (m.wheel_x != 0) m.wheel_x else if (shift) m.wheel_y else 0;
        if (wheel != 0 and widgets.contains(r, m.x, m.y)) bay_scroll_x -= wheel * theme.size(40);
    }
    bay_scroll_x = std.math.clamp(bay_scroll_x, 0, max_scroll);

    // ── Device chain ─────────────────────────────────────────────────
    // Panels (new Ui) scroll with the chain: clip them to the bay.
    ui.clip(uiRect(r));
    defer ui.unclip();
    var x = r.x - bay_scroll_x;

    // Instrument slot — audio tracks with an instrument. Not draggable: the
    // instrument is always first in the signal path.
    if (has_instrument) {
        // Note-activity LED glow, keyed by the shown audio track index.
        var glow: f32 = 0;
        if (track_idx) |ti| {
            if (ti < led_glow.len) {
                const seq = t.noteSeq();
                if (seq != led_seen[ti]) {
                    led_glow[ti] = 1.0;
                    led_seen[ti] = seq;
                } else led_glow[ti] = @max(0, led_glow[ti] - 0.05);
                glow = led_glow[ti];
            }
        }
        const card = widgets.rect(x, r.y, inst_pw, dev_h);
        const out = drawDevice(ui, card, header_h, &t.machine, .instrument, t.isEnabled(), glow, true, reg, &result, m);
        if (out.toggle) t.toggleEnabled();
        x += inst_pw;
    }

    // ── Effects (draggable to reorder) ───────────────────────────────
    // Find the drop slot for an active drag and the x of its insertion bar.
    var drop_idx: usize = t.effects.items.len;
    var drop_x: f32 = x;
    {
        var ex = x;
        for (t.effects.items, 0..) |*fx, i| {
            const fw = if (fx.mach.panel_w > 0) theme.size(fx.mach.panel_w) else DEFAULT_PANEL_W;
            if (fx_drag.active and fx_drag.cur_x < ex + fw / 2 and drop_idx == t.effects.items.len) {
                drop_idx = i;
                drop_x = ex;
            }
            ex += fw;
        }
        // Cursor past every effect → insertion bar at the chain tail.
        if (drop_idx == t.effects.items.len) drop_x = ex;
    }

    for (t.effects.items, 0..) |*fx, i| {
        const fx_w = if (fx.mach.panel_w > 0) theme.size(fx.mach.panel_w) else DEFAULT_PANEL_W;
        const card = widgets.rect(x, r.y, fx_w, dev_h);
        // Effects never auto-open replace on press — the drag state machine
        // distinguishes a click from a drag and opens it on release.
        const out = drawDevice(ui, card, header_h, &fx.mach, .{ .effect = i }, !t.effectBypassed(i), null, false, reg, &result, m);
        if (out.toggle) t.toggleEffectBypass(i);

        // Arm a reorder drag when the name block is pressed (deferred: a
        // clean click without movement opens the replace menu on release).
        if (out.name_pressed and !fx_drag.armed and !fx_drag.active and !widgets.menuActive()) {
            fx_drag = .{ .armed = true, .src = i, .press_x = m.x, .press_y = m.y, .cur_x = m.x };
        }

        // The dragged card reads as grabbed: a 2px accent border.
        if (fx_drag.active and fx_drag.src == i) {
            c.rl.DrawRectangleLinesEx(card, 2, theme.accent_hi);
        }
        x += fx_w;
    }

    // Drag state machine: promote to active past the threshold, draw the
    // insertion bar, and on release either reorder or open the replace menu.
    if (fx_drag.armed or fx_drag.active) {
        fx_drag.cur_x = m.x;
        if (fx_drag.armed and !fx_drag.active and m.left_down) {
            if (@abs(m.x - fx_drag.press_x) + @abs(m.y - fx_drag.press_y) > DRAG_THRESHOLD) fx_drag.active = true;
        }
        if (fx_drag.active) {
            c.rl.DrawRectangle(@intFromFloat(drop_x - 1), @intFromFloat(r.y), 2, @intFromFloat(dev_h), theme.accent_hi);
        }
        if (!m.left_down) {
            if (fx_drag.active and fx_drag.src < t.effects.items.len) {
                // Convert the boundary slot into a destination index.
                var to = drop_idx;
                if (to > fx_drag.src) to -= 1; // removing src shifts the tail left
                if (to != fx_drag.src) {
                    result.reorder_from = fx_drag.src;
                    result.reorder_to = to;
                }
            } else if (fx_drag.armed and fx_drag.src < t.effects.items.len) {
                // A click, not a drag → open the effect's replace menu.
                const fx = &t.effects.items[fx_drag.src];
                const replace_key = widgets.keyFromIds(REPLACE_MENU_KEY, @intFromPtr(fx.mach.state), 0);
                if (!widgets.menuOpen(replace_key)) {
                    scanRegistryPresets(reg);
                    widgets.openMenuAt(replace_key, m.x, r.y + header_h);
                }
            }
            fx_drag = .{};
        }
    }

    // Trailing placeholder + the "+" at the right end of the chain.
    const plus_x = x;
    if (x < r.x + r.width) {
        const res = drawPlaceholder(widgets.rect(x, r.y, r.x + r.width - x, dev_h), header_h, false, null, m);
        result.minimize = res.minimize;
    }
    if (plus_x + header_h <= r.x + r.width) {
        if (drawAddButton(widgets.rect(plus_x, r.y, header_h, header_h), reg, m)) |pick| {
            result.add_machine = pick.reg_idx;
            result.add_preset = pick.preset;
        }
    }

    // ── Minimap (only when the chain overflows the bay) ──────────────
    if (overflow) {
        const strip = widgets.rect(r.x, r.y + dev_h, r.width, minimap_h);
        widgets.bevelSunken(strip, theme.pane_bg, theme.slab_hi, theme.slab_lo);
        const inner = widgets.rect(strip.x + 2, strip.y + 2, strip.width - 4, strip.height - 4);
        const scale = inner.width / content_w;
        // Device blocks (instrument brighter than effects; buses have none).
        var bx = inner.x;
        if (!is_bus) {
            c.rl.DrawRectangle(@intFromFloat(bx), @intFromFloat(inner.y), @intFromFloat(@max(1, inst_pw * scale - 1)), @intFromFloat(inner.height), theme.slab_hi);
            bx += inst_pw * scale;
        }
        for (t.effects.items) |*fx| {
            const fw = (if (fx.mach.panel_w > 0) theme.size(fx.mach.panel_w) else DEFAULT_PANEL_W) * scale;
            c.rl.DrawRectangle(@intFromFloat(bx), @intFromFloat(inner.y), @intFromFloat(@max(1, fw - 1)), @intFromFloat(inner.height), theme.slab_fill);
            bx += fw;
        }
        // Viewport window + drag/click to scroll (centres on the cursor).
        const vp = widgets.rect(inner.x + bay_scroll_x * scale, inner.y, @max(2.0, r.width * scale), inner.height);
        c.rl.DrawRectangleRec(vp, c.rl.ColorAlpha(theme.accent_hi, 0.25));
        c.rl.DrawRectangleLinesEx(vp, 1, theme.accent_hi);
        if (m.left_down and widgets.contains(strip, m.x, m.y)) {
            bay_scroll_x = std.math.clamp((m.x - inner.x) / scale - r.width / 2, 0, max_scroll);
        }
    }
    return result;
}

fn machineControlsRect(panel: c.rl.Rectangle, panel_w: f32) c.rl.Rectangle {
    if (panel_w <= 0) return panel;
    const visible_w = @min(panel.width, theme.size(panel_w));
    return widgets.rect(panel.x, panel.y, visible_w, panel.height);
}

const PresetAction = struct {
    apply: ?u8 = null,
    save: bool = false,
    rename: ?u8 = null, // index of the preset to rename (the current one)
};

const DIR_ID_BASE: u32 = 10000;
// Backing for bank-submenu row labels: one slot per distinct preset
// subdirectory. Capped — banks beyond this just don't get a submenu row.
var dir_label_bufs: [16][presets_mod.MAX_NAME + 1:0]u8 = undefined;
// Persistent backing for the open preset menu's item labels (see
// presetMenu — the menu draws deferred, so a stack list would dangle).
var preset_menu_list: presets_mod.List = .{};

// Top-level menu rows for a sorted preset list: plain leaves (id = flat
// list index), then one hover-submenu row per distinct subdirectory.
fn presetTopItems(list: *const presets_mod.List, items: []widgets.MenuItem) usize {
    var n: usize = 0;
    for (list.names[0..list.count], 0..) |*nm, i| {
        if (std.mem.indexOfScalar(u8, nm.slice(), '/') != null) continue;
        if (n >= items.len) return n;
        items[n] = .{ .label = nm.z(), .id = @intCast(i) };
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
            buf[l] = 0;
            items[n] = .{ .label = @ptrCast(&buf[0]), .id = @intCast(DIR_ID_BASE + ord), .submenu = true };
            n += 1;
        }
        ord += 1;
    }
    return n;
}

// Rows of the ord-th distinct subdirectory: id = flat list index, label =
// the name after the slash (NUL follows in Name storage, so no copy).
fn presetDirItems(list: *const presets_mod.List, dir_ord: usize, items: []widgets.MenuItem) usize {
    var n: usize = 0;
    var ord: usize = 0;
    var last: []const u8 = "";
    for (list.names[0..list.count], 0..) |*nm, i| {
        const sl = std.mem.indexOfScalar(u8, nm.slice(), '/') orelse continue;
        const dirn = nm.slice()[0..sl];
        if (!std.mem.eql(u8, dirn, last)) {
            last = dirn;
            ord += 1;
        }
        if (ord - 1 != dir_ord) continue;
        if (n >= items.len) return n;
        items[n] = .{ .label = @ptrCast(&nm.text[sl + 1]), .id = @intCast(i) };
        n += 1;
    }
    return n;
}

const Machine = @import("../machine.zig").Machine;

const DeviceOut = struct {
    toggle: bool = false, // mute / bypass clicked
    name_pressed: bool = false, // name block pressed (caller may arm a drag)
};

fn isInstrument(ref: DeviceRef) bool {
    return switch (ref) {
        .instrument => true,
        .effect => false,
    };
}

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

// Draw one device card: the host titlebar (delete / name / preset / mute),
// its menus, and the machine's own panel body. Folds the name (replace),
// preset, and delete-confirm outcomes into `result`, scoped to `ref`.
// Returns the mute/bypass toggle and whether the name block was pressed.
fn drawDevice(
    ui: *ui_core.Ui,
    card: c.rl.Rectangle,
    header_h: f32,
    mach: *Machine,
    ref: DeviceRef,
    active: bool,
    glow: ?f32,
    auto_name_menu: bool,
    reg: *const Registry,
    result: *Result,
    m: widgets.Mouse,
) DeviceOut {
    var out = DeviceOut{};
    const body = widgets.rect(card.x, card.y + header_h, card.width, card.height - header_h);

    if (!mach.host_titlebar) {
        mach.draw_panel(mach.state, ui, uiRect(card));
        if (!active) ui.rect(uiRect(card), ui_style.chassis.alpha(115));
        return out;
    }

    const is_inst = isInstrument(ref);
    var pbuf: [40]u8 = undefined;
    const preset_label: ?[*:0]const u8 = if (hasPresets(mach)) currentPresetLabel(&pbuf, mach) else null;
    const ctrls = drawDeviceBar(
        widgets.rect(card.x, card.y, card.width, header_h),
        mach.name,
        preset_label,
        active,
        glow,
        if (is_inst) .speaker_high else .plugs_connected,
        if (is_inst) .speaker_slash else .plugs,
        if (is_inst) "Enabled — click to silence" else "Active — click to bypass",
        if (is_inst) "Silenced — click to enable" else "Bypassed — click to enable",
        if (is_inst) "Remove machine" else "Remove effect",
        m,
    );
    out.toggle = ctrls.toggle;
    out.name_pressed = ctrls.name_clicked;

    // Delete → confirm popup, keyed per device.
    const confirm_key = widgets.keyFromIds(CONFIRM_MENU_KEY, @intFromPtr(mach.state), 0);
    if (ctrls.delete_clicked and !widgets.menuOpen(confirm_key)) {
        widgets.openMenuAt(confirm_key, card.x, card.y + header_h);
    }
    if (deleteConfirmMenu(confirm_key, m)) result.remove_ref = ref;

    // Name → replace machine picker, keyed per device. Effects defer the
    // open to the drag state machine (auto_name_menu = false), but the open
    // menu is always driven here.
    const replace_key = widgets.keyFromIds(REPLACE_MENU_KEY, @intFromPtr(mach.state), 0);
    if (auto_name_menu and ctrls.name_clicked and !widgets.menuOpen(replace_key)) {
        scanRegistryPresets(reg);
        widgets.openMenuAt(replace_key, ctrls.name_rect.x, ctrls.name_rect.y + header_h);
    }
    if (machinePickerMenu(replace_key, reg, m)) |pick| {
        result.replace_ref = ref;
        result.replace_machine = pick.reg_idx;
        result.replace_preset = pick.preset;
    }

    // Preset → preset menu (choose / save / rename).
    if (preset_label != null) {
        const pa = presetMenu(ctrls.preset_rect, ctrls.preset_clicked, mach, m);
        if (pa.apply) |p| {
            result.preset_apply_ref = ref;
            result.preset_apply = p;
        }
        if (pa.save) {
            result.preset_save_ref = ref;
            result.preset_anchor = ctrls.preset_rect;
        }
        if (pa.rename) |idx| {
            result.preset_rename_ref = ref;
            result.preset_rename_index = idx;
            result.preset_anchor = ctrls.preset_rect;
        }
    }

    mach.draw_panel(mach.state, ui, uiRect(body));
    // Silenced/bypassed: the panel dims (drawn in the Ui list, over it).
    if (!active) ui.rect(uiRect(body), ui_style.chassis.alpha(115));
    return out;
}

// Clicking the preset block opens the preset menu: preset leaves, one hover
// submenu per subdirectory, then Save…/Rename… rows. Save…/Rename… defer to
// a host text-entry overlay (the caller routes them through RenameState).
fn presetMenu(preset_rect: c.rl.Rectangle, clicked: bool, mach: *const Machine, m: widgets.Mouse) PresetAction {
    const count: usize = if (mach.preset_count) |cf| cf(mach.state) else 0;
    const can_save = mach.save_preset != null or mach.save_preset_named != null;
    const cur_idx: i32 = if (mach.current_preset) |cf| cf(mach.state) else -1;
    const can_rename = mach.rename_preset != null and cur_idx >= 0;
    if (count == 0 and !can_save) return .{};

    const key = widgets.keyFromIds(PRESET_MENU_KEY, @intFromPtr(mach.state), 1);
    if (clicked and !widgets.menuOpen(key)) widgets.openMenuAt(key, preset_rect.x, preset_rect.y + preset_rect.height);

    // Deferred-draw menu: the backing list must outlive this call (a stack
    // local would dangle into drawContextMenu). Module-level, repopulated
    // only for the menu that is actually open.
    if (widgets.menuOpen(key)) {
        preset_menu_list = .{};
        if (mach.preset_name) |nf| {
            var i: usize = 0;
            while (i < count and i < presets_mod.MAX_PRESETS) : (i += 1) {
                preset_menu_list.names[i] = presets_mod.Name.set(std.mem.span(nf(mach.state, @intCast(i))));
            }
            preset_menu_list.count = i;
        }
    }

    var items: [presets_mod.MAX_PRESETS + 3]widgets.MenuItem = undefined;
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
    if (widgets.menuPickId(key, items[0..n], m)) |id| {
        if (id == SAVE_ITEM_ID) return .{ .save = true };
        if (id == RENAME_ITEM_ID) return .{ .rename = @intCast(cur_idx) };
        return .{ .apply = @intCast(id) };
    }
    if (widgets.menuSubOpen(key, 0)) |dir_id| {
        if (dir_id >= DIR_ID_BASE) {
            var ditems: [presets_mod.MAX_PRESETS]widgets.MenuItem = undefined;
            const dn = presetDirItems(&preset_menu_list, dir_id - DIR_ID_BASE, &ditems);
            if (widgets.menuSubTick(key, 1, ditems[0..dn], m)) |id| {
                return .{ .apply = @intCast(id) };
            }
        }
    }
    return .{};
}

fn drawPolyDropdown(panel: c.rl.Rectangle, track_idx: usize, voices: u8, header_h: f32, m: widgets.Mouse) ?u8 {
    const w = theme.size(54);
    const h = @min(header_h, panel.height);
    const r = widgets.rect(panel.x + panel.width - w, panel.y, w, h);
    const hover = widgets.contains(r, m.x, m.y) and !widgets.hasActiveDrag();
    const pressed = hover and m.left_down;
    const clicked = hover and m.left_released;
    const fill = if (pressed) theme.slab_lo else if (hover or poly_dropdown_track == track_idx) theme.slab_hi else theme.slab_fill;
    widgets.bevelRaised(r, fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF(polyLabel(voices), r.x + 4, r.y + (r.height - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_fg);
    widgets.drawLabelF("v", r.x + r.width - 8, r.y + (r.height - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_dim);
    widgets.tooltip(r, "Polyphony mode", m);
    if (clicked) {
        poly_dropdown_track = if (poly_dropdown_track != null and poly_dropdown_track.? == track_idx) null else track_idx;
    }

    if (poly_dropdown_track != null and poly_dropdown_track.? == track_idx) {
        const opts = [_]u8{ 1, 4, 8, 16 };
        const row_h = theme.size(18);
        const menu = widgets.rect(r.x, r.y + r.height + 1, r.width, row_h * opts.len + 2);
        c.rl.DrawRectangleRec(menu, theme.slab_edge);
        c.rl.DrawRectangleRec(widgets.rect(menu.x + 1, menu.y + 1, menu.width - 2, menu.height - 2), theme.pane_bg);
        for (opts, 0..) |opt, i| {
            const row = widgets.rect(menu.x + 1, menu.y + 1 + @as(f32, @floatFromInt(i)) * row_h, menu.width - 2, row_h);
            const row_hover = widgets.contains(row, m.x, m.y);
            if (row_hover) c.rl.DrawRectangleRec(row, theme.slab_hi);
            const active = normalizeVoices(voices) == opt;
            const col = if (active) theme.accent_hi else theme.text_fg;
            widgets.drawLabelF(polyLabel(opt), row.x + 5, row.y + (row.height - theme.fsBody()) / 2 - 1, theme.fsBody(), col);
            if (row_hover and m.left_released) {
                poly_dropdown_track = null;
                return opt;
            }
        }
        if (m.left_pressed and !widgets.contains(menu, m.x, m.y) and !widgets.contains(r, m.x, m.y)) {
            poly_dropdown_track = null;
        }
    }
    return null;
}

fn normalizeVoices(v: u8) u8 {
    if (v >= 16) return 16;
    if (v >= 8) return 8;
    if (v >= 4) return 4;
    return 1;
}

fn polyLabel(v: u8) [*:0]const u8 {
    return switch (normalizeVoices(v)) {
        4 => "P4",
        8 => "P8",
        16 => "P16",
        else => "MONO",
    };
}

fn drawPlaceholder(r: c.rl.Rectangle, header_h: f32, collapsed: bool, hint: ?[*:0]const u8, m: widgets.Mouse) widgets.HeaderResult {
    if (r.width <= 0 or r.height <= 0) return .{};
    const header = widgets.rect(r.x, r.y, r.width, @min(header_h, r.height));
    const res = widgets.paneHeader(header, .{ .title = "", .collapsed = collapsed }, m);
    if (r.height > header.height) {
        c.rl.DrawRectangleRec(widgets.rect(r.x, r.y + header.height, r.width, r.height - header.height), theme.pane_bg);
        if (hint) |h| widgets.drawLabelF(h, r.x + theme.size(6), r.y + header.height + theme.size(6), theme.fsBody(), theme.text_mute);
    }
    return res;
}

fn drawEmptyPanel(r: c.rl.Rectangle, header_h: f32) void {
    widgets.bevelRaised(widgets.rect(r.x, r.y, r.width, @min(header_h, r.height)), theme.slab_fill, theme.slab_hi, theme.slab_lo);
    if (r.height > header_h) {
        c.rl.DrawRectangleRec(widgets.rect(r.x, r.y + header_h, r.width, r.height - header_h), theme.pane_bg);
        widgets.drawLabelF("select a track", r.x + 4, r.y + header_h + 6, theme.fsBody(), theme.text_mute);
    }
}
