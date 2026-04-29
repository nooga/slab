//! Bottom pane — hosts the selected track's machine panel. In expanded
//! mode the machine's own title strip is the strip title; unused space is
//! filled by a packed placeholder cell with the collapse button.

const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const Track = @import("../track.zig").Track;

pub const Result = struct {
    minimize: bool = false,
    close: bool = false,
    poly_voices: ?u8 = null,
    preset_index: ?u8 = null,
};

var poly_dropdown_track: ?usize = null;
var preset_dropdown_track: ?usize = null;

pub fn draw(r: c.rl.Rectangle, tracks: []Track, selected: ?usize, collapsed: bool, m: widgets.Mouse) Result {
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    var result = Result{};

    const header_h = @min(r.height, theme.paneHeaderH());

    if (collapsed) {
        const res = drawPlaceholder(r, header_h, true, m);
        return .{ .minimize = res.minimize };
    }

    var x = r.x;
    if (selected) |idx| {
        if (idx < tracks.len) {
            const t = &tracks[idx];
            const DEFAULT_PANEL_W = theme.size(200);
            const pw = @min(if (t.machine.panel_w > 0) theme.size(t.machine.panel_w) else DEFAULT_PANEL_W, r.width);
            const panel_rect = widgets.rect(x, r.y, pw, r.height);
            t.machine.draw_panel(t.machine.state, panel_rect, m);
            if (t.machine_idx != null) {
                const controls_rect = machineControlsRect(panel_rect, t.machine.panel_w);
                if (drawPresetDropdown(controls_rect, idx, &t.machine, header_h, m)) |preset| {
                    result.preset_index = preset;
                }
                if (drawPolyDropdown(controls_rect, idx, t.poly_voices, header_h, m)) |voices| {
                    result.poly_voices = voices;
                }
            }
            x += pw;
            for (t.effects[0..t.effect_count]) |*fx| {
                if (x >= r.x + r.width) break;
                const fx_w = @min(if (fx.panel_w > 0) theme.size(fx.panel_w) else DEFAULT_PANEL_W, r.x + r.width - x);
                fx.draw_panel(fx.state, widgets.rect(x, r.y, fx_w, r.height), m);
                x += fx_w;
            }
        } else {
            const empty_w = @min(theme.size(200), r.width);
            drawEmptyPanel(widgets.rect(x, r.y, empty_w, r.height), header_h);
            x += empty_w;
        }
    } else {
        const empty_w = @min(theme.size(200), r.width);
        drawEmptyPanel(widgets.rect(x, r.y, empty_w, r.height), header_h);
        x += empty_w;
    }

    if (x < r.x + r.width) {
        const rest = widgets.rect(x, r.y, r.x + r.width - x, r.height);
        const res = drawPlaceholder(rest, header_h, false, m);
        result.minimize = res.minimize;
        return result;
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

    const poly_w = theme.size(54);
    const w = theme.size(78);
    const h = @min(header_h, panel.height);
    const r = widgets.rect(panel.x + panel.width - poly_w - w, panel.y, w, h);
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

fn drawPlaceholder(r: c.rl.Rectangle, header_h: f32, collapsed: bool, m: widgets.Mouse) widgets.HeaderResult {
    if (r.width <= 0 or r.height <= 0) return .{};
    const header = widgets.rect(r.x, r.y, r.width, @min(header_h, r.height));
    const res = widgets.paneHeader(header, .{ .title = "", .collapsed = collapsed }, m);
    if (r.height > header.height) {
        c.rl.DrawRectangleRec(widgets.rect(r.x, r.y + header.height, r.width, r.height - header.height), theme.pane_bg);
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
