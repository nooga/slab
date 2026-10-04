//! About Slab (docs/06 §About): the splash card with the credits printed
//! over the photo, and the version, LICENSES and CLOSE in its strip.
//! Opens from the transport bar's logo and from Slab > About Slab. Modal
//! (main suppresses the input behind it while `active`); a click outside
//! the card, Esc or Enter closes it.

const std = @import("std");
const build_options = @import("build_options");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const menu = @import("menu.zig");
const splash = @import("splash.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const State = struct {
    active: bool = false,
};

pub const Result = enum { none, close, licenses };

/// The credits panel over the photo's dark left side.
const PANEL_W: i32 = 360;
const LINE_H: i32 = 16;
const GAP: i32 = 8;

const Credit = struct { name: []const u8, note: []const u8 };

/// The third-party work in the app (NOTICE has the full texts).
const BUILT_WITH = [_]Credit{
    .{ .name = "fy", .note = "SLAB'S FORK, GPL-3.0" },
    .{ .name = "msfa, from Dexed", .note = "APACHE-2.0" },
    .{ .name = "raylib", .note = "ZLIB" },
    .{ .name = "miniaudio", .note = "MIT-0" },
    .{ .name = "Tamzen font", .note = "FREE" },
};

const SOUNDS = [_]Credit{
    .{ .name = "Versilian Community Samples", .note = "CC0" },
    .{ .name = "Voices made with Stable Audio 3", .note = "CC0" },
};

const THANKS = [_]Credit{
    .{ .name = "Sinsky, for tips on analog modeling", .note = "" },
};

pub fn draw(ui: *Ui, screen: Rect, state: *State) Result {
    if (!state.active) return .none;
    if (!menu.active()) ui.unsuppressInput();
    ui.pushId("about");
    defer ui.popId();

    ui.rect(screen, style.chassis.alpha(150));
    const r = screen.center(splash.W, splash.H);
    ui.rect(r, style.chassis);
    var img = r.inset(1);
    const strip = img.cutBottom(splash.STRIP_H);
    splash.photo(ui, img);
    credits(ui, img);

    // The strip: wordmark, version and copyright, then the buttons.
    var body = ui.plate(strip, .{ .outline = .none });
    ui.rect(Rect.xywh(strip.x, strip.y, strip.w, 1), style.edge);
    const name = body.cutLeft(52);
    ui.textIn(&ui.fonts.body_bold, name.insetXY(6, 0), "SLAB", style.text, .left, true);
    var res: Result = .none;
    if (ctl.button(ui, body.cutRight(64), "close", null, .{ .label = "CLOSE", .flush = true })) res = .close;
    if (ctl.button(ui, body.cutRight(76), "licenses", null, .{ .label = "LICENSES", .flush = true })) res = .licenses;
    _ = body.cutRight(6);
    var vbuf: [64]u8 = undefined;
    const ver = std.fmt.bufPrint(&vbuf, "VERSION {s} BETA  (C) 2026 MARCIN GASPEROWICZ", .{build_options.version}) catch "";
    ctl.display(ui, body.center(body.w, ctl.displayHeight(false)), ver, .{});
    ui.bevel(r, style.edge, style.edge);

    const in = &ui.in;
    if (in.keyPressed(c.rl.KEY_ESCAPE) or in.keyPressed(c.rl.KEY_ENTER) or in.keyPressed(c.rl.KEY_KP_ENTER)) res = .close;
    if ((in.pressed or in.right_pressed) and !r.contains(in.ix(), in.iy())) res = .close;
    if (res != .none) state.active = false;
    return res;
}

/// A dark glass panel down the left of the photo, with the credits.
fn credits(ui: *Ui, img: Rect) void {
    var p = Rect.xywh(img.x, img.y, PANEL_W, img.h);
    ui.rect(p, style.chassis.alpha(190));
    ui.rect(Rect.xywh(p.right(), p.y, 1, p.h), style.edge);
    p = p.insetXY(16, 14);

    line(ui, &p, &ui.fonts.body_bold, "SLAB AUDIO WORKSTATION", style.text);
    line(ui, &p, &ui.fonts.body, "Made by Marcin Gasperowicz", style.text_dim);
    _ = p.cutTop(GAP);
    section(ui, &p, "THANKS", &THANKS);
    section(ui, &p, "BUILT WITH", &BUILT_WITH);
    section(ui, &p, "SOUNDS", &SOUNDS);
    line(ui, &p, &ui.fonts.body, "Free software: GPL-3.0-or-later,", style.text_dim);
    line(ui, &p, &ui.fonts.body, "with the Slab Machine Exception.", style.text_dim);
    line(ui, &p, &ui.fonts.body, "Factory presets and sounds: CC0.", style.text_dim);
}

fn line(ui: *Ui, p: *Rect, f: *const core.Font, s: []const u8, col: style.Color) void {
    ui.textIn(f, p.cutTop(LINE_H), s, col, .left, true);
}

fn section(ui: *Ui, p: *Rect, title: []const u8, items: []const Credit) void {
    ui.textIn(&ui.fonts.legend, p.cutTop(LINE_H), title, style.text_dim, .left, true);
    for (items) |it| {
        const row = p.cutTop(LINE_H);
        ui.textIn(&ui.fonts.body, row, it.name, style.text, .left, true);
        if (it.note.len > 0) ui.textIn(&ui.fonts.legend, row, it.note, style.text_dim, .right, true);
    }
    _ = p.cutTop(GAP);
}
