//! Startup splash (docs/06 §Splash), the 2000s way: the app opens as a
//! small borderless window showing splash.png with a packed status strip
//! (wordmark, dot-matrix status, LED progress), redrawn between machine
//! compiles; when booting is done the same window becomes the decorated,
//! resizable workbench.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");

const Ui = core.Ui;
const Rect = core.Rect;

/// Splash window size (logical px), the image's aspect.
pub const W: c_int = 720;
pub const H: c_int = 426;
const STRIP_H: i32 = 20;
const SEGS: i32 = 24;

var tex: c.rl.Texture2D = undefined;
var state: enum { unloaded, ok, missing } = .unloaded;

/// Open the app window as the splash: borderless, centred, image-sized.
pub fn openWindow(flags: c_uint) void {
    c.rl.SetConfigFlags(flags | c.rl.FLAG_WINDOW_UNDECORATED);
    c.rl.InitWindow(W, H, "slab");
}

/// Turn the splash window into the workbench: decorations back, resizable,
/// `w`×`h`, centred on the monitor it's on. Drops the image.
pub fn becomeWorkbench(w: c_int, h: c_int) void {
    unload();
    c.rl.ClearWindowState(c.rl.FLAG_WINDOW_UNDECORATED);
    c.rl.SetWindowState(c.rl.FLAG_WINDOW_RESIZABLE);
    c.rl.SetWindowSize(w, h);
    const mon = c.rl.GetCurrentMonitor();
    const pos = c.rl.GetMonitorPosition(mon);
    const mw = c.rl.GetMonitorWidth(mon);
    const mh = c.rl.GetMonitorHeight(mon);
    c.rl.SetWindowPosition(@as(c_int, @intFromFloat(pos.x)) + @divFloor(mw - w, 2), @as(c_int, @intFromFloat(pos.y)) + @max(0, @divFloor(mh - h, 2)));
}

fn texture() ?c.rl.Texture2D {
    if (state == .unloaded) {
        var t = c.rl.LoadTexture("splash.png");
        if (t.id != 0) {
            // Photographic and scaled down: the one place filtering is right.
            c.rl.GenTextureMipmaps(&t);
            c.rl.SetTextureFilter(t, c.rl.TEXTURE_FILTER_TRILINEAR);
            tex = t;
            state = .ok;
        } else state = .missing;
    }
    return if (state == .ok) tex else null;
}

pub fn unload() void {
    if (state == .ok) c.rl.UnloadTexture(tex);
    state = .unloaded;
}

/// Present one boot frame: `status` on the display, `progress` 0..1 on the
/// LED bar.
pub fn bootFrame(ui: *Ui, status: []const u8, progress: f32) void {
    ui.beginFrame();
    draw(ui, Rect.xywh(0, 0, W, H), status, progress);
    ui.endFrame();
    ui.present();
}

fn draw(ui: *Ui, screen: Rect, status: []const u8, progress: f32) void {
    ui.rect(screen, style.chassis);
    var img = screen;
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

    // Status strip: a faceplate under the picture, framed by a hard edge.
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
        ctl.ledBar(ui, Rect.xywh(x0, inner.y, x1 - x0 - 1, inner.h), if (i < lit) .on else .off, style.phosphor);
    }
    // Hard 1px frame around the whole borderless window.
    ui.bevel(screen, style.edge, style.edge);
}
