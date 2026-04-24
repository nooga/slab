//! Fonts.
//!
//! Two SFNS rasters (body + large) kept close to actual display size
//! so downscale never exceeds ~2× — bilinear filtering then produces
//! clean AA on both retina and non-retina. One mono raster for
//! readouts. Extra DPI scale multiplier applied at raster time so we
//! stay above physical resolution on high-DPI displays.

const c = @import("../c.zig");
const icons_mod = @import("icons.zig");

pub var ui: c.rl.Font = undefined;
pub var ui_lg: c.rl.Font = undefined;
pub var mono: c.rl.Font = undefined;
pub var icons: c.rl.Font = undefined;
pub var loaded: bool = false;

// Rasterize at ~2× the target display size. On macOS without the
// HIGHDPI flag raylib already gives us a 2× framebuffer on retina
// displays and stretches our ortho projection over it, so drawing
// 12 px text from a 24 px raster effectively supersamples on retina
// while on non-retina it's a clean 2× bilinear downscale.
const UI_RASTER: c_int = 24; // body (8–14 px)
const UI_LG_RASTER: c_int = 36; // titles (15–22 px)
const MONO_RASTER: c_int = 24;
const ICON_RASTER: c_int = 32; // icons used mostly at 12–20 px

pub fn init() void {
    const ui_raster = UI_RASTER;
    const ui_lg_raster = UI_LG_RASTER;
    const mono_raster = MONO_RASTER;

    ui = tryLoad("/System/Library/Fonts/SFNS.ttf", ui_raster) orelse
        tryLoad("/System/Library/Fonts/HelveticaNeue.ttc", ui_raster) orelse
        c.rl.GetFontDefault();

    ui_lg = tryLoad("/System/Library/Fonts/SFNS.ttf", ui_lg_raster) orelse
        tryLoad("/System/Library/Fonts/HelveticaNeue.ttc", ui_lg_raster) orelse
        ui;

    mono = tryLoad("/System/Library/Fonts/SFNSMono.ttf", mono_raster) orelse
        tryLoad("/System/Library/Fonts/Menlo.ttc", mono_raster) orelse
        c.rl.GetFontDefault();

    // Icons — Phosphor Bold, shipped under vendor/phosphor.
    var icon_cps = icons_mod.all_codepoints;
    icons = tryLoadIcons("vendor/phosphor/Phosphor-Bold.ttf", ICON_RASTER, icon_cps[0..]) orelse
        c.rl.GetFontDefault();

    applyFilter(&ui);
    applyFilter(&ui_lg);
    applyFilter(&mono);
    applyFilter(&icons);

    loaded = true;
}

pub fn deinit() void {
    if (!loaded) return;
    const def = c.rl.GetFontDefault();
    if (ui.texture.id != def.texture.id) c.rl.UnloadFont(ui);
    if (ui_lg.texture.id != def.texture.id and ui_lg.texture.id != ui.texture.id)
        c.rl.UnloadFont(ui_lg);
    if (mono.texture.id != def.texture.id) c.rl.UnloadFont(mono);
    if (icons.texture.id != def.texture.id) c.rl.UnloadFont(icons);
    loaded = false;
}

fn tryLoad(path: [*:0]const u8, size: c_int) ?c.rl.Font {
    const f = c.rl.LoadFontEx(path, size, null, 0);
    if (f.texture.id == 0) return null;
    return f;
}

fn tryLoadIcons(path: [*:0]const u8, size: c_int, codepoints: []c_int) ?c.rl.Font {
    const f = c.rl.LoadFontEx(path, size, codepoints.ptr, @intCast(codepoints.len));
    if (f.texture.id == 0) return null;
    return f;
}

fn applyFilter(f: *c.rl.Font) void {
    if (f.texture.id > 0) {
        c.rl.SetTextureFilter(f.texture, c.rl.TEXTURE_FILTER_BILINEAR);
    }
}

// ── Draw/measure helpers ─────────────────────────────────────────────

inline fn pickUI(size: f32) c.rl.Font {
    return if (size >= 15) ui_lg else ui;
}

pub fn drawUI(text: [*:0]const u8, x: f32, y: f32, size: f32, color: c.rl.Color) void {
    const f = pickUI(size);
    c.rl.DrawTextEx(f, text, .{ .x = @round(x), .y = @round(y) }, size, 0, color);
}

pub fn drawMono(text: [*:0]const u8, x: f32, y: f32, size: f32, color: c.rl.Color) void {
    c.rl.DrawTextEx(mono, text, .{ .x = @round(x), .y = @round(y) }, size, 0, color);
}

pub fn measureUI(text: [*:0]const u8, size: f32) f32 {
    const f = pickUI(size);
    return c.rl.MeasureTextEx(f, text, size, 0).x;
}

pub fn measureMono(text: [*:0]const u8, size: f32) f32 {
    return c.rl.MeasureTextEx(mono, text, size, 0).x;
}
