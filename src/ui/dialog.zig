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
    _ = ui.engraved(&ui.fonts.body_bold, head.x + 7, head.y + @divFloor(head.h - 16, 2) + 1, title, style.text);
    ui.rect(Rect.xywh(body.x + 4, body.y, body.w - 8, 1), style.face_lo);
    ui.rect(Rect.xywh(body.x + 4, body.y + 1, body.w - 8, 1), style.face_hi);
    _ = body.cutTop(2);
    const btns = body.cutBottom(BUTTONS_H);
    const in = &ui.in;
    return .{
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
