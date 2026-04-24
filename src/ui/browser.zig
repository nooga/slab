//! Left-side browser — shows available machines, lets you assign one
//! to the selected track by clicking.

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const registry_mod = @import("../machine_registry.zig");

pub const Result = struct {
    toggled: bool = false, // minimize / restore was clicked
    assigned: ?usize = null, // registry index to assign to selected track
};

pub fn draw(
    r: c.rl.Rectangle,
    collapsed: bool,
    reg: *const registry_mod.Registry,
    m: widgets.Mouse,
) Result {
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    if (collapsed) return .{ .toggled = drawCollapsed(r, m) };
    return drawExpanded(r, reg, m);
}

fn drawExpanded(r: c.rl.Rectangle, reg: *const registry_mod.Registry, m: widgets.Mouse) Result {
    const header = widgets.rect(r.x, r.y, r.width, theme.paneHeaderH());
    const hres = widgets.paneHeader(header, .{ .title = "MACHINES" }, m);

    const ROW_H = theme.size(20);
    var cy: f32 = r.y + theme.paneHeaderH() + 2;
    var assigned: ?usize = null;

    for (reg.entries[0..reg.count], 0..) |*entry, i| {
        const row = widgets.rect(r.x + 1, cy, r.width - 2, ROW_H);
        const hot = widgets.contains(row, m.x, m.y);
        if (hot) c.rl.DrawRectangleRec(row, theme.slab_fill);

        widgets.drawIcon(.faders, row.x + 3, row.y + (ROW_H - theme.fsBody()) / 2 - 1, theme.fsBody(), theme.text_dim);

        var name_buf: [33:0]u8 = undefined;
        const nsl = entry.nameSlice();
        @memcpy(name_buf[0..nsl.len], nsl);
        name_buf[nsl.len] = 0;
        widgets.drawLabelF(@ptrCast(&name_buf[0]), row.x + 3 + theme.fsBody() + 4, row.y + (ROW_H - theme.fsBody()) / 2, theme.fsBody(), if (hot) theme.text_fg else theme.text_dim);

        if (hot and m.left_released and !widgets.hasActiveDrag()) {
            assigned = i;
        }
        cy += ROW_H + 1;
    }

    if (cy < r.y + r.height) {
        widgets.drawLabelF("click to assign", r.x + 4, cy + 4, theme.fsTiny(), theme.text_mute);
    }

    return .{ .toggled = hres.minimize, .assigned = assigned };
}

fn drawCollapsed(r: c.rl.Rectangle, m: widgets.Mouse) bool {
    const btn = widgets.rect(r.x, r.y, r.width, r.width);
    const clicked = widgets.iconButton(btn, .plus, null, m);
    const letters = "MACHINES";
    var y = btn.y + btn.height + 4;
    for (letters) |ch| {
        var buf: [2:0]u8 = .{ ch, 0 };
        const tw = widgets.measureTextF(@ptrCast(&buf[0]), theme.fsTiny());
        widgets.drawLabelF(@ptrCast(&buf[0]), r.x + (r.width - tw) / 2, y, theme.fsTiny(), theme.text_dim);
        y += theme.fsTiny() + 1;
    }
    return clicked;
}
