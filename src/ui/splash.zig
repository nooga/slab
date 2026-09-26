//! Startup splash (docs/06 §Splash), the 2000s way: a card centred in the
//! main window, splash.png above a packed status strip (wordmark,
//! dot-matrix status, LED progress). Redrawn on the empty chassis between
//! machine compiles; once the workbench is up it stays over the UI for a
//! moment and then vanishes (at once on any click or key).

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");

const Ui = core.Ui;
const Rect = core.Rect;

/// Card size (logical px): the image's aspect plus the strip.
const W: i32 = 720;
const H: i32 = 426;
const STRIP_H: i32 = 20;
const SEGS: i32 = 24;
/// How long the card stays over the live workbench.
const HOLD_S: f32 = 1.2;

var tex: c.rl.Texture2D = undefined;
var tex_state: enum { unloaded, ok, missing } = .unloaded;

/// Where the card is in its life.
var phase: enum { booting, over_ui, gone } = .booting;
/// Seconds the card has been over the workbench.
var shown_s: f32 = 0;

fn texture() ?c.rl.Texture2D {
    if (tex_state == .unloaded) {
        var t = c.rl.LoadTexture("splash.png");
        if (t.id != 0) {
            // Photographic and scaled down: the one place filtering is right.
            c.rl.GenTextureMipmaps(&t);
            c.rl.SetTextureFilter(t, c.rl.TEXTURE_FILTER_TRILINEAR);
            tex = t;
            tex_state = .ok;
        } else tex_state = .missing;
    }
    return if (tex_state == .ok) tex else null;
}

pub fn unload() void {
    if (tex_state == .ok) c.rl.UnloadTexture(tex);
    tex_state = .unloaded;
}

/// Present one boot frame on the empty chassis: `status` on the display,
/// `progress` 0..1 on the LED bar.
pub fn bootFrame(ui: *Ui, screen: Rect, status: []const u8, progress: f32) void {
    ui.beginFrame();
    ui.chassis(screen);
    card(ui, screen.center(W, H), status, progress);
    ui.endFrame();
    ui.present();
}

/// Booting is done: from now on the card sits over the workbench.
pub fn finishBoot() void {
    phase = .over_ui;
    shown_s = 0;
}

/// Draw the card over the workbench (call before `menu.draw`) until it
/// times out or the user clicks or types. It never takes the input.
pub fn overlay(ui: *Ui, screen: Rect) void {
    if (phase != .over_ui) return;
    const in = &ui.raw_in;
    if (shown_s >= HOLD_S or in.pressed or in.right_pressed or in.nkeys > 0) {
        phase = .gone;
        unload();
        return;
    }
    card(ui, screen.center(W, H), "READY", 1);
    shown_s += @max(in.dt, 1.0 / 120.0);
    ui.animate();
}

fn card(ui: *Ui, r: Rect, status: []const u8, progress: f32) void {
    ui.rect(r, style.chassis);
    var img = r.inset(1);
    const strip = img.cutBottom(STRIP_H);
    if (texture()) |t| {
        // Cover the area above the strip: scale to fill, centre, crop.
        const aw: f32 = @floatFromInt(img.w);
        const ah: f32 = @floatFromInt(img.h);
        const tw: f32 = @floatFromInt(t.width);
        const th: f32 = @floatFromInt(t.height);
        const k = @max(aw / tw, ah / th);
        const w: i32 = @intFromFloat(@ceil(tw * k));
        const h: i32 = @intFromFloat(@ceil(th * k));
        ui.clip(img);
        ui.texture(t, Rect.xywh(img.x + @divFloor(img.w - w, 2), img.y + @divFloor(img.h - h, 2), w, h), style.Color.hex(0xffffff));
        ui.unclip();
    }

    // Status strip: a faceplate under the picture.
    var body = ui.plate(strip, .{ .outline = .none });
    ui.rect(Rect.xywh(strip.x, strip.y, strip.w, 1), style.edge);
    const name = body.cutLeft(52);
    ui.textIn(&ui.fonts.body_bold, name.insetXY(6, 0), "SLAB", style.text, .left, true);
    const bar = body.cutRight(SEGS * 5 + 12);
    _ = body.cutRight(6);
    ctl.display(ui, body.center(body.w, ctl.displayHeight(false)), status, .{});
    const inner = ui.well(bar.center(bar.w - 8, 10), style.well).inset(1);
    const lit: i32 = @intFromFloat(@round(std.math.clamp(progress, 0, 1) * @as(f32, @floatFromInt(SEGS))));
    var i: i32 = 0;
    while (i < SEGS) : (i += 1) {
        const x0 = inner.x + @divFloor(i * inner.w, SEGS);
        const x1 = inner.x + @divFloor((i + 1) * inner.w, SEGS);
        ctl.ledBar(ui, Rect.xywh(x0, inner.y, x1 - x0 - 1, inner.h), if (i < lit) .on else .off, style.vfd);
    }
    // Hard 1px frame: the card floats like hardware, no shadow.
    ui.bevel(r, style.edge, style.edge);
}
