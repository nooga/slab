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
// Graphite: neutral greys with a faint blue cast, clean steps between
// layers (chassis < pane < face) so packed panels still read apart.
pub const chassis = Color.hex(0x111215);
pub const face = Color.hex(0x33363c);
pub const face_hi = Color.hex(0x4e525a);
pub const face_lo = Color.hex(0x23252a);
pub const edge = Color.hex(0x08090b);
pub const pane = Color.hex(0x1a1c20);
pub const pane_alt = Color.hex(0x1f2126);
pub const well = Color.hex(0x0a0b0d);
pub const well_hi = Color.hex(0x2a2d33); // sunken bevel's lit (bottom/right) edge

// ── Working-surface grid ─────────────────────────────────────────────
pub const grid_sub = Color.hex(0x22252a);
pub const grid_beat = Color.hex(0x2a2d33);
pub const grid_bar = Color.hex(0x3a3e46);
pub const key_white = Color.hex(0xc9ccd1);
pub const key_black = Color.hex(0x15161a);

// ── Text ─────────────────────────────────────────────────────────────
pub const text = Color.hex(0xeceef0);
pub const text_dim = Color.hex(0xa7abb2);
pub const text_mute = Color.hex(0x6f747c);
pub const engrave = Color.hex(0x000000).alpha(120);

// ── Accents ──────────────────────────────────────────────────────────
/// Amber: selection, playhead, focus, "active". Nothing else.
pub const accent = Color.hex(0xffb23e);
pub const play = Color.hex(0x3ddc84);
pub const rec = Color.hex(0xff4d4d);
pub const mod = Color.hex(0x6b8cff);
/// Display segments (mint VFD). Machines may override per panel.
pub const phosphor = Color.hex(0x5ef2d6);

// ── Controls ─────────────────────────────────────────────────────────
/// Knob value arc at rest; turns `accent` while hot/active.
pub const arc_on = Color.hex(0xc9ccd2);
pub const arc_off = Color.hex(0x15171a);
pub const cap = Color.hex(0x3d4047);
pub const pointer = Color.hex(0xf4f5f6);

// ── LED colours ──────────────────────────────────────────────────────
pub const led_red = Color.hex(0xff4d4d);
pub const led_green = Color.hex(0x3ddc84);
pub const led_amber = accent;
pub const led_blue = Color.hex(0x4aa8ff);
/// Meter "hot" zone (between green and clip red).
pub const led_yellow = Color.hex(0xf2d544);

// ── Track colours ────────────────────────────────────────────────────
/// Saturated but controlled; no amber/yellow (reserved for "active").
pub const track = [_]Color{
    Color.hex(0xec6a7a), // rose
    Color.hex(0x9ad45a), // lime
    Color.hex(0x4cc38a), // green
    Color.hex(0x3cc6c0), // teal
    Color.hex(0x4aa8f0), // sky
    Color.hex(0x7b7ff0), // indigo
    Color.hex(0xb56ce6), // violet
    Color.hex(0xe46ab6), // pink
};

/// Track colour as drawn: any colour snaps to the nearest entry of `track`,
/// so no track is ever amber/yellow whatever the project file says.
pub fn nearestTrack(col: Color) Color {
    var best = track[0];
    var best_d: i32 = std.math.maxInt(i32);
    for (track) |t| {
        const dr = @as(i32, t.r) - col.r;
        const dg = @as(i32, t.g) - col.g;
        const db = @as(i32, t.b) - col.b;
        const d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
        if (d < best_d) {
            best_d = d;
            best = t;
        }
    }
    return best;
}

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
