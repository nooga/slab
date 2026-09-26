//! Palette and material tokens (docs/06 §Palette, §Materials). Values are
//! tokens, never literals in widget code.

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn hex(v: u24) Color {
        return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
    }

    pub fn alpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    /// Linear mix toward `o` by t∈[0,1] (alpha taken from self).
    pub fn mix(c: Color, o: Color, t: f32) Color {
        const f = struct {
            fn ch(a: u8, b: u8, k: f32) u8 {
                const av: f32 = @floatFromInt(a);
                const bv: f32 = @floatFromInt(b);
                return @intFromFloat(@round(av + (bv - av) * k));
            }
        };
        return .{ .r = f.ch(c.r, o.r, t), .g = f.ch(c.g, o.g, t), .b = f.ch(c.b, o.b, t), .a = c.a };
    }

    /// Add `d` levels to each channel (clamped). For gradients.
    pub fn shade(c: Color, d: i32) Color {
        const f = struct {
            fn ch(v: u8, k: i32) u8 {
                return @intCast(std.math.clamp(@as(i32, v) + k, 0, 255));
            }
        };
        return .{ .r = f.ch(c.r, d), .g = f.ch(c.g, d), .b = f.ch(c.b, d), .a = c.a };
    }
};

const std = @import("std");

// ── Surfaces ─────────────────────────────────────────────────────────
pub const chassis = Color.hex(0x141416);
pub const face = Color.hex(0x404044);
pub const face_hi = Color.hex(0x646468);
pub const face_lo = Color.hex(0x28282a);
pub const edge = Color.hex(0x0c0c0e);
pub const pane = Color.hex(0x202022);
pub const pane_alt = Color.hex(0x28282a);
pub const well = Color.hex(0x0e0f10);
pub const well_hi = Color.hex(0x303034); // sunken bevel's lit (bottom/right) edge

// ── Text ─────────────────────────────────────────────────────────────
pub const text = Color.hex(0xe0e0db);
pub const text_dim = Color.hex(0xa0a09a);
pub const text_mute = Color.hex(0x747470);
pub const engrave = Color.hex(0x000000).alpha(110);

// ── Accents ──────────────────────────────────────────────────────────
/// Amber: selection, playhead, focus, "active". Nothing else.
pub const accent = Color.hex(0xd7af50);
pub const play = Color.hex(0x50c864);
pub const rec = Color.hex(0xd7463c);
pub const mod = Color.hex(0x40a0ff);
/// Display segments (VFD teal). Machines may override per panel.
pub const phosphor = Color.hex(0x3fe0cc);

// ── Controls ─────────────────────────────────────────────────────────
/// Knob value arc at rest; turns `accent` while hot/active.
pub const arc_on = Color.hex(0xb4b4ac);
pub const arc_off = Color.hex(0x1a1a1c);
pub const cap = Color.hex(0x4a4a4f);
pub const pointer = Color.hex(0xf0f0ea);

// ── LED colours ──────────────────────────────────────────────────────
pub const led_red = Color.hex(0xff3a2a);
pub const led_green = Color.hex(0x48f060);
pub const led_amber = accent;
pub const led_blue = Color.hex(0x50b0ff);
/// Meter "hot" zone (between green and clip red).
pub const led_yellow = Color.hex(0xe8d040);

// ── Material strengths (docs/06 §Strengths are tokens) ───────────────
pub const Materials = struct {
    /// Noise tile amplitude, in levels of 255 (±).
    noise: u8 = 3,
    /// Faceplate gradient: levels lighter at top than bottom.
    gradient: u8 = 6,
    /// Engraved legends on faceplates.
    engrave: bool = true,
    /// Display ghost cells, as alpha of the phosphor colour.
    ghost_alpha: u8 = 13,
    /// Display glyph halo alpha.
    halo_alpha: u8 = 60,
};

/// Live material settings (the gallery's "materials off" switch edits this).
pub var materials: Materials = .{};

pub const materials_off: Materials = .{ .noise = 0, .gradient = 0, .engrave = false, .ghost_alpha = 0, .halo_alpha = 0 };
