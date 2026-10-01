//! Color picker (docs/06 §Palette): the panel a track's color strip
//! opens, in the arrangement header or on a mixer strip. A grid of
//! `style.track_shades` (a column per hue, a row per shade) hung from the
//! strip; a click picks one and closes.
//! Modal like a dialog (main suppresses the input behind it while
//! `active`); Esc or a click outside closes it.

const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const menu = @import("menu.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;

pub const State = struct {
    active: bool = false,
    /// The track whose color it sets.
    track: usize = 0,
    /// The strip's corner: the panel hangs from it.
    x: i32 = 0,
    y: i32 = 0,
    /// Opened this frame: the press that opened it isn't a click outside.
    fresh: bool = false,

    pub fn open(st: *State, track: usize, at: [2]i32) void {
        st.* = .{ .active = true, .track = track, .x = at[0], .y = at[1], .fresh = true };
    }
};

const SW: i32 = 16;
const GAP: i32 = 4;
const COLS: i32 = style.track.len;
const TITLE_H: i32 = 20;
const PAD: i32 = 8;

/// Draw the picker for a track drawn in `current`; the picked color.
pub fn draw(ui: *Ui, screen: Rect, st: *State, current: Color) ?Color {
    if (!st.active) return null;
    if (!menu.active()) ui.unsuppressInput();
    ui.pushId("color-picker");
    defer ui.popId();

    const n: i32 = @intCast(style.track_shades.len);
    const rows = @divFloor(n + COLS - 1, COLS);
    const w = COLS * SW + (COLS - 1) * GAP + 2 * PAD;
    const h = TITLE_H + rows * SW + (rows - 1) * GAP + 2 * PAD - 4;
    var x = st.x;
    if (x + w > screen.right() - 4) x = screen.right() - 4 - w;
    if (x < screen.x + 4) x = screen.x + 4;
    var y = st.y;
    if (y + h > screen.bottom() - 4) y = screen.bottom() - 4 - h;
    const r = Rect.xywh(x, y, w, h);

    const in = &ui.in;
    const fresh = st.fresh;
    st.fresh = false;
    if (in.keyPressed(c.rl.KEY_ESCAPE) or (!fresh and (in.pressed or in.right_pressed) and !r.contains(in.ix(), in.iy()))) {
        st.active = false;
        return null;
    }

    var body = ui.plate(r, .{ .outline = .all, .chamfer = 3 });
    const head = body.cutTop(TITLE_H - 2);
    _ = ui.engraved(&ui.fonts.body_bold, head.x + 7, head.y + @divFloor(head.h - 16, 2) + 1, "COLOR", style.text);
    ui.rect(Rect.xywh(body.x + 4, body.y, body.w - 8, 1), style.face_lo);
    ui.rect(Rect.xywh(body.x + 4, body.y + 1, body.w - 8, 1), style.face_hi);
    body = body.insetXY(PAD, 4);

    var picked: ?Color = null;
    for (style.track_shades, 0..) |col, i| {
        const k: i32 = @intCast(i);
        const sr = Rect.xywh(body.x + @mod(k, COLS) * (SW + GAP), body.y + @divFloor(k, COLS) * (SW + GAP), SW, SW);
        const b = ui.behaviorEx(ui.id(.{ "swatch", i }), sr, .{ .focusable = false });
        const on = col.r == current.r and col.g == current.g and col.b == current.b;
        // A 1px well edge, the accent ring on the current one and on hover.
        ui.rect(sr, if (on) style.accent else if (b.hover) style.text else style.chassis);
        ui.rect(sr.insetXY(if (on) 2 else 1, if (on) 2 else 1), col);
        if (b.pressed and !fresh) picked = col;
    }
    if (picked != null) st.active = false;
    return picked;
}
