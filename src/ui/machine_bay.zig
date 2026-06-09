//! Bottom pane — hosts the selected track's machine panel. In expanded
//! mode the machine's own title strip is the strip title; unused space is
//! filled by a packed placeholder cell with the collapse button.

const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const Track = @import("../track.zig").Track;
const registry_mod = @import("../machine_registry.zig");
const Registry = registry_mod.Registry;

pub const Result = struct {
    minimize: bool = false,
    close: bool = false,
    poly_voices: ?u8 = null,
    preset_index: ?u8 = null,
    add_machine: ?usize = null, // registry index to assign to the selected track
};

const ADD_MENU_KEY: u64 = 0x4d414444; // "MADD"

var poly_dropdown_track: ?usize = null;
var preset_dropdown_track: ?usize = null;
var bay_scroll_x: f32 = 0; // horizontal scroll of the device chain

// "+" button at the left of the machine-bay titlebar → machine picker menu.
// Returns the chosen registry index when an item is clicked.
fn drawAddButton(btn: c.rl.Rectangle, reg: *const Registry, m: widgets.Mouse) ?usize {
    const open = widgets.menuOpen(ADD_MENU_KEY);
    const hover = widgets.contains(btn, m.x, m.y) and !widgets.hasActiveDrag();
    const fill = if (open or hover) theme.slab_hi else theme.slab_fill;
    widgets.bevelRaised(btn, fill, theme.slab_hi, theme.slab_lo);
    const isz = theme.fsBody();
    widgets.drawIcon(.plus, btn.x + (btn.width - isz) / 2, btn.y + (btn.height - isz) / 2, isz, theme.text_fg);
    widgets.tooltip(btn, "Add machine", m);
    if (hover and m.left_pressed and !open) widgets.openMenuAt(ADD_MENU_KEY, btn.x, btn.y + btn.height);
    var items: [registry_mod.MAX_MACHINES]widgets.MenuItem = undefined;
    var n: usize = 0;
    for (reg.entries[0..reg.count], 0..) |*e, i| {
        items[n] = .{ .label = e.nameZ(), .id = @intCast(i) };
        n += 1;
    }
    if (widgets.menuPickId(ADD_MENU_KEY, items[0..n], m)) |id| return @intCast(id);
    return null;
}

pub fn draw(r: c.rl.Rectangle, tracks: []Track, selected: ?usize, collapsed: bool, reg: *const Registry, m: widgets.Mouse) Result {
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    var result = Result{};

    const header_h = @min(r.height, theme.paneHeaderH());

    if (collapsed) {
        const res = drawPlaceholder(r, header_h, true, null, m);
        return .{ .minimize = res.minimize };
    }

    // No machine loaded (no track selected, or a track with nothing assigned)
    // → one continuous placeholder title bar across the whole bay with a hint,
    // instead of an empty machine panel / stub + a seam.
    const have_track = if (selected) |idx| idx < tracks.len else false;
    const have_machine = if (selected) |idx| (idx < tracks.len and tracks[idx].machine_idx != null) else false;
    if (!have_machine) {
        const hint: [*:0]const u8 = if (have_track) "no machine — click + to add one" else "select a track";
        const res = drawPlaceholder(r, header_h, false, hint, m);
        result.minimize = res.minimize;
        if (have_track) {
            if (drawAddButton(widgets.rect(r.x, r.y, header_h, header_h), reg, m)) |idx| result.add_machine = idx;
        }
        return result;
    }

    // Horizontal scroll of the device chain (trackpad h-wheel or shift+wheel).
    {
        const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
        const wheel: f32 = if (m.wheel_x != 0) m.wheel_x else if (shift) m.wheel_y else 0;
        if (wheel != 0 and widgets.contains(r, m.x, m.y)) bay_scroll_x -= wheel * theme.size(40);
        if (bay_scroll_x < 0) bay_scroll_x = 0;
    }
    var x = r.x - bay_scroll_x;
    {
        const idx = selected.?;
        {
            const t = &tracks[idx];
            const DEFAULT_PANEL_W = theme.size(200);
            const pw = if (t.machine.panel_w > 0) theme.size(t.machine.panel_w) else DEFAULT_PANEL_W;
            const panel_rect = widgets.rect(x, r.y, pw, r.height);
            if (t.machine.host_titlebar) {
                // Host-drawn title bar: name on the left, body below.
                widgets.bevelRaised(widgets.rect(x, r.y, pw, header_h), theme.slab_fill, theme.slab_hi, theme.slab_lo);
                var nbuf: [64:0]u8 = [_:0]u8{0} ** 64;
                const nlen = @min(t.machine.name.len, 64);
                @memcpy(nbuf[0..nlen], t.machine.name[0..nlen]);
                nbuf[nlen] = 0;
                widgets.drawLabelF(@ptrCast(&nbuf[0]), x + theme.size(6), r.y + (header_h - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_fg);
                t.machine.draw_panel(t.machine.state, widgets.rect(x, r.y + header_h, pw, r.height - header_h), m);
            } else {
                t.machine.draw_panel(t.machine.state, panel_rect, m);
            }
            if (t.machine_idx != null) {
                const controls_rect = machineControlsRect(panel_rect, t.machine.panel_w);
                if (drawPresetDropdown(controls_rect, idx, &t.machine, header_h, m)) |preset| {
                    result.preset_index = preset;
                }
                // Voice/polyphony select removed from the leaf title bar: poly
                // becomes a higher-order voice-pool machine (docs/15).
            }
            x += pw;
            for (t.effects[0..t.effect_count]) |*fx| {
                const fx_w = if (fx.panel_w > 0) theme.size(fx.panel_w) else DEFAULT_PANEL_W;
                fx.draw_panel(fx.state, widgets.rect(x, r.y, fx_w, r.height), m);
                x += fx_w;
            }
        }
    }

    // Clamp scroll for next frame so the chain + "+" stay reachable.
    const content_w = (x + bay_scroll_x - r.x) + header_h;
    const max_scroll = @max(0, content_w - r.width);
    if (bay_scroll_x > max_scroll) bay_scroll_x = max_scroll;

    // Trailing placeholder fills the rest of the bay; the "+" add-machine
    // button sits at its left — i.e. immediately to the right of the device
    // chain, not glued to the window edge.
    const plus_x = x;
    if (x < r.x + r.width) {
        const rest = widgets.rect(x, r.y, r.x + r.width - x, r.height);
        const res = drawPlaceholder(rest, header_h, false, null, m);
        result.minimize = res.minimize;
    }
    if (have_track and plus_x + header_h <= r.x + r.width) {
        if (drawAddButton(widgets.rect(plus_x, r.y, header_h, header_h), reg, m)) |idx| result.add_machine = idx;
    }
    return result;
}

fn machineControlsRect(panel: c.rl.Rectangle, panel_w: f32) c.rl.Rectangle {
    if (panel_w <= 0) return panel;
    const visible_w = @min(panel.width, theme.size(panel_w));
    return widgets.rect(panel.x, panel.y, visible_w, panel.height);
}

fn drawPresetDropdown(panel: c.rl.Rectangle, track_idx: usize, mach: *const @import("../machine.zig").Machine, header_h: f32, m: widgets.Mouse) ?u8 {
    const count_fn = mach.preset_count orelse return null;
    const name_fn = mach.preset_name orelse return null;
    const count = count_fn(mach.state);
    if (count == 0) return null;

    const w = theme.size(78);
    const h = @min(header_h, panel.height);
    const r = widgets.rect(panel.x + panel.width - w, panel.y, w, h);
    const hover = widgets.contains(r, m.x, m.y) and !widgets.hasActiveDrag();
    const pressed = hover and m.left_down;
    const clicked = hover and m.left_released;
    const fill = if (pressed) theme.slab_lo else if (hover or preset_dropdown_track == track_idx) theme.slab_hi else theme.slab_fill;
    widgets.bevelRaised(r, fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("PRESET", r.x + 4, r.y + (r.height - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_fg);
    widgets.drawLabelF("v", r.x + r.width - 8, r.y + (r.height - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_dim);
    widgets.tooltip(r, "Preset", m);
    if (clicked) {
        preset_dropdown_track = if (preset_dropdown_track != null and preset_dropdown_track.? == track_idx) null else track_idx;
        poly_dropdown_track = null;
    }

    if (preset_dropdown_track != null and preset_dropdown_track.? == track_idx) {
        const row_h = theme.size(18);
        const menu = widgets.rect(r.x, r.y + r.height + 1, r.width, row_h * @as(f32, @floatFromInt(count)) + 2);
        c.rl.DrawRectangleRec(menu, theme.slab_edge);
        c.rl.DrawRectangleRec(widgets.rect(menu.x + 1, menu.y + 1, menu.width - 2, menu.height - 2), theme.pane_bg);
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            const row = widgets.rect(menu.x + 1, menu.y + 1 + @as(f32, @floatFromInt(i)) * row_h, menu.width - 2, row_h);
            const row_hover = widgets.contains(row, m.x, m.y);
            if (row_hover) c.rl.DrawRectangleRec(row, theme.slab_hi);
            widgets.drawLabelF(name_fn(mach.state, i), row.x + 5, row.y + (row.height - theme.fsBody()) / 2 - 1, theme.fsBody(), theme.text_fg);
            if (row_hover and m.left_released) {
                preset_dropdown_track = null;
                return i;
            }
        }
        if (m.left_pressed and !widgets.contains(menu, m.x, m.y) and !widgets.contains(r, m.x, m.y)) {
            preset_dropdown_track = null;
        }
    }
    return null;
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
        preset_dropdown_track = null;
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
