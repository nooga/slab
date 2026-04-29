//! Brutalist palette. Five greys + a small accent set. No gradients,
//! no AA. See docs/06-ui-widgets.md.

const c = @import("../c.zig");
const std = @import("std");

fn rgb(r: u8, g: u8, b: u8) c.rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

// Greys — from deepest shadow to highlight.
pub const bg = rgb(20, 20, 22);
pub const pane_bg = rgb(32, 32, 34);
pub const pane_alt = rgb(40, 40, 42);
pub const slab_fill = rgb(64, 64, 68);
pub const slab_hi = rgb(100, 100, 104);
pub const slab_lo = rgb(40, 40, 42);
pub const slab_edge = rgb(12, 12, 14);
pub const grid_sub = rgb(58, 58, 64);
pub const grid_beat = rgb(70, 70, 76);
pub const grid_bar = rgb(86, 86, 92);
pub const grid_row = rgb(38, 38, 41);
pub const splitter_bg = rgb(16, 16, 18);
pub const splitter_hover = rgb(180, 150, 60);

// Text
pub const text_fg = rgb(220, 220, 215);
pub const text_dim = rgb(140, 140, 135);
pub const text_mute = rgb(90, 90, 90);

// Accents
pub const accent_play = rgb(80, 200, 100);
pub const accent_rec = rgb(215, 70, 60);
pub const accent_hi = rgb(215, 175, 80);

// Track colors — cycled when creating tracks.
pub const track_colors = [_]c.rl.Color{
    rgb(170, 100, 100),
    rgb(170, 150, 80),
    rgb(100, 160, 110),
    rgb(90, 140, 180),
    rgb(150, 110, 180),
    rgb(180, 130, 90),
};

// Runtime UI metrics. Keep the 1 px bevel/splitter unscaled; scale
// space and type around it so the brutalist edge language stays crisp.
pub var ui_scale: f32 = 1.15;
pub var font_scale: f32 = 1.15;

pub const UI_SCALE_MIN: f32 = 0.85;
pub const UI_SCALE_MAX: f32 = 1.75;
pub const FONT_SCALE_MIN: f32 = 0.9;
pub const FONT_SCALE_MAX: f32 = 1.8;

fn snap(v: f32) f32 {
    return @max(1, @round(v));
}

fn grid(v: f32) f32 {
    return @max(4, @round(v / 4.0) * 4.0);
}

fn dim(base: f32) f32 {
    return grid(base * ui_scale);
}

fn font(base: f32) f32 {
    return snap(base * font_scale);
}

pub fn setUiScale(scale: f32) void {
    ui_scale = std.math.clamp(scale, UI_SCALE_MIN, UI_SCALE_MAX);
}

pub fn setFontScale(scale: f32) void {
    font_scale = std.math.clamp(scale, FONT_SCALE_MIN, FONT_SCALE_MAX);
}

pub fn stepUiScale(delta: f32) void {
    setUiScale(ui_scale + delta);
    setFontScale(font_scale + delta);
}

pub fn resetScale() void {
    ui_scale = 1.15;
    font_scale = 1.15;
}

pub fn size(base: f32) f32 {
    return dim(base);
}

pub fn fine(base: f32) f32 {
    return snap(base * ui_scale);
}

pub fn unscale(px: f32) f32 {
    return px / ui_scale;
}

// Layout metrics — OpenTTD-compact, recomputed each frame.
pub fn topBarH() f32 {
    return dim(22);
}
pub fn statusBarH() f32 {
    return dim(28);
}
pub fn splitterW() f32 {
    return 1;
}
/// Mouse hit-test padding around the 1 px splitter (each side).
pub fn splitterHitPad() f32 {
    return snap(3 * ui_scale);
}
pub fn minPane() f32 {
    return dim(60);
}
/// Width a pane shrinks to when collapsed — just enough for a label +
/// expand button.
pub fn collapsedW() f32 {
    return dim(18);
}
pub fn collapsedH() f32 {
    return dim(18);
}
/// Pane header (title bar) height.
pub fn paneHeaderH() f32 {
    return dim(12);
}
/// Fixed per-track header strip width inside the arrangement lane.
pub fn trackHeaderW() f32 {
    return dim(170);
}
/// Track lane height.
pub fn laneH() f32 {
    return dim(44);
}

// Font sizes (bucketed).
pub fn fsTiny() f32 {
    return font(10);
}
pub fn fsBody() f32 {
    return font(12);
}
pub fn fsTitle() f32 {
    return font(16);
}
