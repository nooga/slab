//! Modal dialogs (docs/06 §Dialogs): a dimmed screen and a centred
//! faceplate with an engraved title, a body for catalogue controls and a
//! row of buttons. Modal: the host suppresses input for everything drawn
//! before the dialog (`Ui.suppressInput` while it is open); `begin` hands
//! the input back to the dialog's own widgets.
//!
//!     const f = dialog.begin(ui, screen, "render", "RENDER AUDIO", 280, 150);
//!     defer dialog.end(ui);
//!     ... controls in f.body ...
//!     switch (dialog.buttons(ui, f.buttons, &.{ "CANCEL", "RENDER" }, 1) orelse ...)

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const menu = @import("menu.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const TITLE_H: i32 = 20;
pub const BUTTONS_H: i32 = 28;
const BUTTON_W: i32 = 76;
const BUTTON_H: i32 = 20;

pub const Frame = struct {
    /// The title bar right of the title, for controls of its own.
    title: Rect,
    /// Content area between the title and the button row.
    body: Rect,
    /// Button row (pass to `buttons`).
    buttons: Rect,
    /// Enter / Esc pressed this frame (the default and cancel actions).
    enter: bool,
    escape: bool,
};

/// Open the dialog frame for this frame. `w`×`h` is the whole dialog.
pub fn begin(ui: *Ui, screen: Rect, key: anytype, title: []const u8, w: i32, h: i32) Frame {
    // A menu opened from inside the dialog keeps the input modal to itself.
    if (!menu.active()) ui.unsuppressInput();
    ui.pushId(key);
    ui.rect(screen, style.chassis.alpha(150));
    const r = screen.center(w, h);
    var body = ui.plate(r, .{ .outline = .all, .chamfer = 3 });
    const head = body.cutTop(TITLE_H - 2);
    const tw = ui.engraved(&ui.fonts.body_bold, head.x + 7, head.y + @divFloor(head.h - 16, 2) + 1, title, style.text);
    ui.rect(Rect.xywh(body.x + 4, body.y, body.w - 8, 1), style.face_lo);
    ui.rect(Rect.xywh(body.x + 4, body.y + 1, body.w - 8, 1), style.face_hi);
    _ = body.cutTop(2);
    const btns = body.cutBottom(BUTTONS_H);
    const in = &ui.in;
    return .{
        .title = Rect.xywh(tw + 12, head.y, head.right() - tw - 16, head.h),
        .body = body.insetXY(8, 6),
        .buttons = btns.insetXY(8, 0),
        .enter = in.keyPressed(c.rl.KEY_ENTER) or in.keyPressed(c.rl.KEY_KP_ENTER),
        .escape = in.keyPressed(c.rl.KEY_ESCAPE),
    };
}

pub fn end(ui: *Ui) void {
    ui.popId();
}

/// Right-aligned button row; `default` is lit (Enter's action). Returns
/// the clicked button's index.
pub fn buttons(ui: *Ui, r: Rect, labels: []const []const u8, default: ?usize) ?usize {
    var rest = r;
    var out: ?usize = null;
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        const br = rest.cutRight(BUTTON_W).center(BUTTON_W, BUTTON_H);
        _ = rest.cutRight(6);
        var lit = true;
        const is_default = default != null and default.? == i;
        if (ctl.button(ui, br, i, if (is_default) &lit else null, .{ .label = labels[i], .lit = if (is_default) style.play else null })) out = i;
    }
    return out;
}

/// A labelled row inside a dialog body: engraved legend on the left, the
/// returned rect for the control on the right.
pub fn row(ui: *Ui, body: *Rect, label: []const u8, h: i32) Rect {
    var r = body.cutTop(h);
    _ = body.cutTop(6);
    const lab = r.cutLeft(52);
    ui.textIn(&ui.fonts.legend, lab, label, style.text_dim, .left, true);
    return r;
}

/// `row` with a label column `lw` wide.
pub fn rowW(ui: *Ui, body: *Rect, label: []const u8, h: i32, lw: i32) Rect {
    var r = body.cutTop(h);
    _ = body.cutTop(6);
    const lab = r.cutLeft(lw);
    ui.textIn(&ui.fonts.legend, lab, label, style.text_dim, .left, true);
    return r;
}

/// A section's head: an engraved legend and a rule to its right.
pub fn section(ui: *Ui, body: *Rect, label: []const u8) void {
    const r = body.cutTop(14);
    _ = body.cutTop(4);
    const w = ui.fonts.legend.measure(label);
    ui.textIn(&ui.fonts.legend, Rect.xywh(r.x, r.y, w + 2, r.h), label, style.text, .left, true);
    const y = r.y + @divFloor(r.h, 2);
    ui.rect(Rect.xywh(r.x + w + 8, y, r.w - w - 8, 1), style.face_lo);
    ui.rect(Rect.xywh(r.x + w + 8, y + 1, r.w - w - 8, 1), style.face_hi);
}

/// A line of explanation under a control, indented to the controls'
/// column (`indent`).
pub fn hint(ui: *Ui, body: *Rect, text: []const u8, indent: i32) void {
    const r = body.cutTop(12);
    _ = body.cutTop(6);
    ui.textIn(&ui.fonts.legend, Rect.xywh(r.x + indent, r.y, r.w - indent, r.h), text, style.text_mute, .left, false);
}

/// A yes/no question: `lines` of text over CANCEL and `ok`. Enter picks
/// `ok`, Esc cancels. Returns the answer once given.
pub fn confirm(ui: *Ui, screen: Rect, key: anytype, title: []const u8, lines: []const []const u8, ok: []const u8) ?bool {
    const h = TITLE_H + BUTTONS_H + 16 + @as(i32, @intCast(lines.len)) * 16;
    const f = begin(ui, screen, key, title, 360, h);
    defer end(ui);
    var body = f.body;
    for (lines, 0..) |ln, i| {
        const r = body.cutTop(16);
        ui.textIn(&ui.fonts.body, r, ln, if (i + 1 == lines.len and lines.len > 1) style.text_dim else style.text, .left, false);
    }
    if (buttons(ui, f.buttons, &.{ "CANCEL", ok }, 1)) |i| return i == 1;
    if (f.escape) return false;
    if (f.enter) return true;
    return null;
}
