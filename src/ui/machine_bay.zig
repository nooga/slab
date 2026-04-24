//! Bottom pane — hosts the selected track's machine panel. Collapses
//! to a thin horizontal strip (same height as the title bar). Close
//! button is offered here so the whole device chain can be hidden.

const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const Track = @import("../track.zig").Track;

pub const Result = struct {
    minimize: bool = false,
    close: bool = false,
};

pub fn draw(r: c.rl.Rectangle, tracks: []Track, selected: ?usize, collapsed: bool, m: widgets.Mouse) Result {
    c.rl.DrawRectangleRec(r, theme.pane_bg);

    var title_buf: [64:0]u8 = undefined;
    const title: [*:0]const u8 = if (selected) |idx| blk: {
        const prefix = "DEVICES — ";
        const name = tracks[idx].name();
        var i: usize = 0;
        while (i < prefix.len and i < 63) : (i += 1) title_buf[i] = prefix[i];
        var j: usize = 0;
        while (i < 63 and j < name.len) : ({
            i += 1;
            j += 1;
        }) title_buf[i] = name[j];
        title_buf[i] = 0;
        break :blk @ptrCast(&title_buf[0]);
    } else "DEVICES";

    // Header strip. When collapsed, the header is essentially the
    // whole pane.
    const header_h = @min(r.height, theme.paneHeaderH());
    const header = widgets.rect(r.x, r.y, r.width, header_h);
    const res = widgets.paneHeader(header, .{ .title = title, .collapsed = collapsed }, m);

    if (!collapsed) {
        // Panels sit flush below the bay header — no inner padding.
        // Multiple panels would be separated by 1px slab_edge gaps.
        const body = widgets.rect(r.x, r.y + header_h, r.width, r.height - header_h);
        if (selected) |idx| {
            const t = &tracks[idx];
            const DEFAULT_PANEL_W = theme.size(200);
            const pw = if (t.machine.panel_w > 0) theme.size(t.machine.panel_w) else DEFAULT_PANEL_W;
            const panel_rect = widgets.rect(body.x, body.y, @min(pw, body.width), body.height);
            t.machine.draw_panel(t.machine.state, panel_rect, m);
        } else {
            widgets.drawLabelF("select a track", body.x + 6, body.y + 6, theme.fsBody(), theme.text_mute);
        }
    }

    return .{ .minimize = res.minimize, .close = res.close };
}
