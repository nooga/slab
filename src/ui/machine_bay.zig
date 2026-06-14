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

pub const Result = struct {
    minimize: bool = false,
    close: bool = false,
    poly_voices: ?u8 = null,
    preset_index: ?u8 = null,
    save_preset: bool = false, // save the instrument's current knobs as a preset
    add_machine: ?usize = null, // registry index to assign to the selected track
    add_preset: ?u8 = null, // preset (by sorted index) to apply after add
    remove_machine: bool = false, // delete the instrument on the selected track
    remove_effect: ?usize = null, // delete effect [i] on the selected track
};

const ADD_MENU_KEY: u64 = 0x4d414444; // "MADD"
const PRESET_MENU_KEY: u64 = 0x50524553; // "PRES"
const SAVE_ITEM_ID: u32 = 9001;
const DEFAULT_ITEM_ID: u32 = 9000;

// Preset lists per registry machine, scanned when the add menu opens so
// hover drill-down doesn't hit the filesystem every frame.
var add_scan_cache: [registry_mod.MAX_MACHINES]presets_mod.List = undefined;

var poly_dropdown_track: ?usize = null;
var bay_scroll_x: f32 = 0; // horizontal scroll of the device chain

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


const DeviceCtrls = struct { toggle: bool = false, remove: bool = false, title_rect: c.rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };

// Host-drawn device titlebar: a title bevel that ENDS before the control
// cells, then snug enable/bypass + delete cells abutting it (and a region
// reserved at the far right for the preset dropdown). The note LED, when
// present, sits inside the title bevel at its right edge.
//
//   [ ----- name ----- ● ][ v ][ x ]( preset )
//
fn drawDeviceBar(
    bar: c.rl.Rectangle,
    name: []const u8,
    active: bool,
    glow: ?f32,
    reserve_right: f32,
    icon_on: widgets.Icon,
    icon_off: widgets.Icon,
    hint_on: [*:0]const u8,
    hint_off: [*:0]const u8,
    del_hint: [*:0]const u8,
    m: widgets.Mouse,
) DeviceCtrls {
    var res = DeviceCtrls{};
    const bw = theme.size(16);
    const del = widgets.rect(bar.x + bar.width - reserve_right - bw, bar.y, bw, bar.height);
    const en = widgets.rect(del.x - bw, bar.y, bw, bar.height);
    const title_w = @max(0, en.x - bar.x);
    const title_bar = widgets.rect(bar.x, bar.y, title_w, bar.height);
    res.title_rect = title_bar;

    widgets.bevelRaised(title_bar, theme.slab_fill, theme.slab_hi, theme.slab_lo);
    const led_w: f32 = if (glow != null) theme.size(16) else 0;
    var nbuf: [64:0]u8 = [_:0]u8{0} ** 64;
    const nlen = @min(name.len, 63);
    @memcpy(nbuf[0..nlen], name[0..nlen]);
    nbuf[nlen] = 0;
    widgets.drawLabelF(@ptrCast(&nbuf[0]), title_bar.x + theme.size(6), title_bar.y + (title_bar.height - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_fg);
    if (glow) |g| {
        const led_r = widgets.rect(title_bar.x + title_bar.width - led_w, title_bar.y, led_w, title_bar.height);
        drawNoteLed(led_r, g, m);
    }

    if (title_w > theme.size(24)) {
        const icon = if (active) icon_on else icon_off;
        const hint = if (active) hint_on else hint_off;
        if (titlebarButton(en, icon, active, false, hint, m)) res.toggle = true;
        if (titlebarButton(del, .trash, false, true, del_hint, m)) res.remove = true;
    }
    return res;
}

const AddPick = struct {
    reg_idx: usize,
    preset: ?u8 = null,
};

// "+" button at the left of the machine-bay titlebar → machine picker.
// Machines with presets carry a hover submenu (and another level for
// preset subdirectories); "(default)" or a plain machine row adds bare.
fn drawAddButton(btn: c.rl.Rectangle, reg: *const Registry, m: widgets.Mouse) ?AddPick {
    const open = widgets.menuOpen(ADD_MENU_KEY);
    const hover = widgets.contains(btn, m.x, m.y) and !widgets.hasActiveDrag();
    const fill = if (open or hover) theme.slab_hi else theme.slab_fill;
    widgets.bevelRaised(btn, fill, theme.slab_hi, theme.slab_lo);
    const isz = theme.fsBody();
    widgets.drawIcon(.plus, btn.x + (btn.width - isz) / 2, btn.y + (btn.height - isz) / 2, isz, theme.text_fg);
    widgets.tooltip(btn, "Add machine", m);
    // Menu arrays are bounded; the registry itself grows, so clamp.
    const menu_count = @min(reg.count, registry_mod.MAX_MACHINES);
    if (hover and m.left_pressed and !open) {
        for (reg.entries[0..menu_count], 0..) |*e, i| {
            var dbuf: [512]u8 = undefined;
            add_scan_cache[i] = if (presets_mod.dirFromMachinePath(&dbuf, e.pathSlice())) |dir|
                presets_mod.scan(dir)
            else
                presets_mod.List{};
        }
        widgets.openMenuAt(ADD_MENU_KEY, btn.x, btn.y + btn.height);
    }
    if (!widgets.menuOpen(ADD_MENU_KEY)) return null;

    var items: [registry_mod.MAX_MACHINES]widgets.MenuItem = undefined;
    var n: usize = 0;
    for (reg.entries[0..menu_count], 0..) |*e, i| {
        items[n] = .{
            .label = e.nameZ(),
            .id = @intCast(i),
            .submenu = add_scan_cache[i].count > 0,
        };
        n += 1;
    }
    if (widgets.menuPickId(ADD_MENU_KEY, items[0..n], m)) |id| {
        return .{ .reg_idx = @intCast(id) };
    }

    if (widgets.menuSubOpen(ADD_MENU_KEY, 0)) |mach_id| {
        const list = &add_scan_cache[mach_id];
        var pitems: [presets_mod.MAX_PRESETS + 1]widgets.MenuItem = undefined;
        pitems[0] = .{ .label = "(default)", .id = DEFAULT_ITEM_ID };
        const pn = 1 + presetTopItems(list, pitems[1..]);
        if (widgets.menuSubTick(ADD_MENU_KEY, 1, pitems[0..pn], m)) |sel| {
            return .{
                .reg_idx = @intCast(mach_id),
                .preset = if (sel == DEFAULT_ITEM_ID) null else @intCast(sel),
            };
        }
        if (widgets.menuSubOpen(ADD_MENU_KEY, 1)) |dir_id| {
            if (dir_id >= DIR_ID_BASE) {
                var ditems: [presets_mod.MAX_PRESETS]widgets.MenuItem = undefined;
                const dn = presetDirItems(list, dir_id - DIR_ID_BASE, &ditems);
                if (widgets.menuSubTick(ADD_MENU_KEY, 2, ditems[0..dn], m)) |sel| {
                    return .{ .reg_idx = @intCast(mach_id), .preset = @intCast(sel) };
                }
            }
        }
    }
    return null;
}

pub fn draw(r: c.rl.Rectangle, device: ?*Track, track_idx: ?usize, is_bus: bool, collapsed: bool, reg: *const Registry, m: widgets.Mouse) Result {
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

    // A track with no instrument (e.g. an audio-clip track) still renders a
    // compact placeholder instrument slot, then the effect chain and the
    // trailing "+", so it can hold and chain audio→audio machines. Buses
    // (master/return) have no instrument slot at all.
    const DEFAULT_PANEL_W = theme.size(200);
    const no_instrument = !is_bus and t.machine_idx == null;
    const PLACEHOLDER_PW = theme.size(150);
    const inst_pw: f32 = if (is_bus)
        0
    else if (no_instrument)
        PLACEHOLDER_PW
    else if (t.machine.panel_w > 0)
        theme.size(t.machine.panel_w)
    else
        DEFAULT_PANEL_W;

    // Measure the chain ((instrument) + effects + trailing "+") to decide
    // whether a horizontal minimap is needed at the bottom of the bay.
    var content_w: f32 = inst_pw;
    for (t.effects[0..t.effect_count]) |*fx| {
        content_w += if (fx.panel_w > 0) theme.size(fx.panel_w) else DEFAULT_PANEL_W;
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
    var x = r.x - bay_scroll_x;

    // Instrument slot — audio tracks only. Buses start straight at effects.
    if (no_instrument) {
        // Empty instrument slot: a hint placeholder. Machines are added via
        // the trailing "+" (effects route to the chain, an instrument fills
        // this slot) — no separate add button here.
        const ph_rect = widgets.rect(x, r.y, inst_pw, dev_h);
        const res = drawPlaceholder(ph_rect, header_h, false, "no instrument — + adds fx", m);
        result.minimize = res.minimize;
        x += inst_pw;
    } else if (!is_bus) {
        const inst_rect = widgets.rect(x, r.y, inst_pw, dev_h);
        const inst_body = widgets.rect(x, r.y + header_h, inst_pw, dev_h - header_h);
        const inst_enabled = t.isEnabled();

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

        if (t.machine.host_titlebar) {
            var tbuf: [96]u8 = undefined;
            const ctrls = drawDeviceBar(
                widgets.rect(x, r.y, inst_pw, header_h),
                deviceTitle(&tbuf, &t.machine),
                inst_enabled,
                glow,
                0,
                .speaker_high,
                .speaker_slash,
                "Enabled — click to silence",
                "Silenced — click to enable",
                "Remove machine",
                m,
            );
            if (ctrls.toggle) t.toggleEnabled();
            if (ctrls.remove) result.remove_machine = true;
            if (t.machine_idx != null) {
                const pa = titlebarPresetMenu(ctrls.title_rect, &t.machine, m);
                if (pa.apply) |preset| result.preset_index = preset;
                if (pa.save) result.save_preset = true;
            }
            t.machine.draw_panel(t.machine.state, inst_body, m);
            if (!inst_enabled) c.rl.DrawRectangleRec(inst_body, c.rl.ColorAlpha(theme.bg, 0.45));
        } else {
            t.machine.draw_panel(t.machine.state, inst_rect, m);
            if (!inst_enabled) c.rl.DrawRectangleRec(inst_rect, c.rl.ColorAlpha(theme.bg, 0.45));
        }
        x += inst_pw;
    }

    for (t.effects[0..t.effect_count], 0..) |*fx, i| {
        const fx_w = if (fx.panel_w > 0) theme.size(fx.panel_w) else DEFAULT_PANEL_W;
        const fx_rect = widgets.rect(x, r.y, fx_w, dev_h);
        const fx_body = widgets.rect(x, r.y + header_h, fx_w, dev_h - header_h);
        const bypassed = t.effectBypassed(i);
        if (fx.host_titlebar) {
            const ctrls = drawDeviceBar(
                widgets.rect(x, r.y, fx_w, header_h),
                fx.name,
                !bypassed,
                null,
                0,
                .plugs_connected,
                .plugs,
                "Active — click to bypass",
                "Bypassed — click to enable",
                "Remove effect",
                m,
            );
            if (ctrls.toggle) t.toggleEffectBypass(i);
            if (ctrls.remove) result.remove_effect = i;
            fx.draw_panel(fx.state, fx_body, m);
            if (bypassed) c.rl.DrawRectangleRec(fx_body, c.rl.ColorAlpha(theme.bg, 0.45));
        } else {
            fx.draw_panel(fx.state, fx_rect, m);
            if (bypassed) c.rl.DrawRectangleRec(fx_rect, c.rl.ColorAlpha(theme.bg, 0.45));
        }
        x += fx_w;
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
        for (t.effects[0..t.effect_count]) |*fx| {
            const fw = (if (fx.panel_w > 0) theme.size(fx.panel_w) else DEFAULT_PANEL_W) * scale;
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
};

const DIR_ID_BASE: u32 = 10000;
var dir_label_bufs: [8][presets_mod.MAX_NAME + 1:0]u8 = undefined;
// Persistent backing for the open preset menu's item labels (see
// titlebarPresetMenu — the menu draws deferred, so a stack list would dangle).
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

// "name -> preset" titlebar label; plain name for preset-less machines.
fn deviceTitle(buf: []u8, mach: *const @import("../machine.zig").Machine) []const u8 {
    const count: usize = if (mach.preset_count) |cf| cf(mach.state) else 0;
    if (count == 0 and mach.save_preset == null) return mach.name;
    var cur: [*:0]const u8 = "init";
    if (mach.current_preset) |cpf| {
        const idx = cpf(mach.state);
        if (idx >= 0) {
            if (mach.preset_name) |nf| cur = nf(mach.state, @intCast(idx));
        }
    }
    return std.fmt.bufPrint(buf, "{s} -> {s}", .{ mach.name, std.mem.span(cur) }) catch mach.name;
}

// Clicking the machine name opens the preset menu: leaves, subdirectory
// submenus, and a Save row for machines that can snapshot their knobs.
fn titlebarPresetMenu(title_rect: c.rl.Rectangle, mach: *const @import("../machine.zig").Machine, m: widgets.Mouse) PresetAction {
    const count: usize = if (mach.preset_count) |cf| cf(mach.state) else 0;
    const can_save = mach.save_preset != null;
    if (count == 0 and !can_save) return .{};

    const key = widgets.keyFromIds(PRESET_MENU_KEY, @intFromPtr(mach.state), 1);
    const open_here = widgets.menuOpen(key);
    const hover = widgets.contains(title_rect, m.x, m.y) and !widgets.hasActiveDrag();
    if (hover) widgets.tooltip(title_rect, "Preset", m);
    if (hover and m.left_pressed and !open_here) widgets.openMenuAt(key, title_rect.x, title_rect.y + title_rect.height);

    // The menu's item labels point into this list, but the menu is drawn
    // *deferred* (drawContextMenu at end of frame), so the backing store must
    // outlive this call — a local would dangle (garbage labels). It is
    // module-level and only (re)populated for the menu that is actually open,
    // so a later machine's bar can't clobber the open menu's names.
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

    var items: [presets_mod.MAX_PRESETS + 2]widgets.MenuItem = undefined;
    var n = presetTopItems(&preset_menu_list, items[0 .. presets_mod.MAX_PRESETS]);
    if (can_save) {
        if (n > 0) {
            items[n] = .{ .separator = true };
            n += 1;
        }
        items[n] = .{ .label = "Save preset", .id = SAVE_ITEM_ID };
        n += 1;
    }
    if (widgets.menuPickId(key, items[0..n], m)) |id| {
        if (id == SAVE_ITEM_ID) return .{ .save = true };
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
