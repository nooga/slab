//! Procedural control art (docs/06 §How controls are made). Everything is
//! drawn pixel by pixel into the atlas at startup: no image assets, the
//! look is code. Static parts (knob caps, fader caps, levers, LED lenses,
//! display halos, the noise tile) are sprites; dynamic parts (value arcs,
//! pointers, display dots) are exact pixel runs emitted per frame from
//! tables built here.

const std = @import("std");
const style = @import("style.zig");
const atlas_mod = @import("atlas.zig");
const font_mod = @import("font.zig");
const Color = style.Color;
const Atlas = atlas_mod.Atlas;
const Region = atlas_mod.Region;

pub const Size = enum(u2) { s, m, l };

// ── Knobs ────────────────────────────────────────────────────────────

pub const KnobGeom = struct {
    /// Cell edge (the knob is d×d).
    d: i32,
    cap_r: f32,
    top_r: f32,
    arc_r0: f32,
    arc_r1: f32,
    mod_r0: f32,
    mod_r1: f32,
    pointer_w: f32,
};

pub fn knobGeom(size: Size) KnobGeom {
    return switch (size) {
        .l => .{ .d = 32, .cap_r = 11, .top_r = 7.5, .arc_r0 = 12.5, .arc_r1 = 14.5, .mod_r0 = 15, .mod_r1 = 16, .pointer_w = 0.7 },
        .m => .{ .d = 24, .cap_r = 7.5, .top_r = 5, .arc_r0 = 8.5, .arc_r1 = 10.5, .mod_r0 = 11, .mod_r1 = 12, .pointer_w = 0.6 },
        .s => .{ .d = 16, .cap_r = 4.5, .top_r = 3, .arc_r0 = 5.5, .arc_r1 = 6.8, .mod_r0 = 7, .mod_r1 = 8, .pointer_w = 0.55 },
    };
}

/// Knob sweep: 270° clockwise from 7:30 to 4:30.
pub const SWEEP_MIN: f32 = -135.0;
pub const SWEEP_RANGE: f32 = 270.0;

/// One pixel of a ring, with its position along the sweep (t∈[0,1]).
pub const RingPx = struct { x: i8, y: i8, t: f32 };

pub const Ring = struct {
    px: [320]RingPx = undefined,
    len: usize = 0,

    pub fn slice(r: *const Ring) []const RingPx {
        return r.px[0..r.len];
    }
};

pub const KnobArt = struct {
    geom: KnobGeom,
    cap: Region,
    arc: Ring,
    mod: Ring,
};

// ── Sliders ──────────────────────────────────────────────────────────

pub const SliderKind = enum(u2) { fader, slider, mini };

pub const SliderGeom = struct {
    /// Cap size, vertical orientation (w across the slot, h along it).
    cap_w: i32,
    cap_h: i32,
    /// Slot width (across).
    slot_w: i32,
};

pub fn sliderGeom(kind: SliderKind) SliderGeom {
    return switch (kind) {
        .fader => .{ .cap_w = 16, .cap_h = 28, .slot_w = 4 },
        .slider => .{ .cap_w = 12, .cap_h = 16, .slot_w = 4 },
        .mini => .{ .cap_w = 8, .cap_h = 10, .slot_w = 2 },
    };
}

pub const SliderArt = struct {
    geom: SliderGeom,
    cap_v: Region,
    cap_h: Region,
};

// ── Toggle lever ─────────────────────────────────────────────────────

pub const LEVER_W: i32 = 12;
pub const LEVER_H: i32 = 24;

// ── LEDs ─────────────────────────────────────────────────────────────

pub const LedShape = enum { round3, round5, round7, square4, square6, tri_up, tri_down, tri_left, tri_right };

pub const HALO: i32 = 3;

pub const LedArt = struct {
    body: Region,
    halo: Region,
    lens: Region,
};

// ── Everything ───────────────────────────────────────────────────────

pub const NOISE: u16 = 128;
/// Noise texel scale: see noiseTint().
const NOISE_BAKE: f32 = 48;
const NOISE_MAX: i32 = 4;

pub const Art = struct {
    noise: Region,
    knobs: [3]KnobArt,
    sliders: [3]SliderArt,
    /// Lever positions: up, mid, down.
    lever: [3]Region,
    leds: [std.meta.fields(LedShape).len]LedArt,
    /// Halo versions of each display-font glyph (same index as the font).
    display_halo: [256]Region,
};

pub fn build(a: *Atlas, display_font: *const font_mod.Font) !Art {
    var art: Art = undefined;
    art.noise = try buildNoise(a);
    inline for (.{ Size.s, Size.m, Size.l }, 0..) |sz, i| art.knobs[i] = try buildKnob(a, sz);
    inline for (.{ SliderKind.fader, SliderKind.slider, SliderKind.mini }, 0..) |k, i| art.sliders[i] = try buildSlider(a, k);
    for (0..3) |i| art.lever[i] = try buildLever(a, @intCast(i));
    inline for (std.meta.fields(LedShape), 0..) |f, i| art.leds[i] = try buildLed(a, @field(LedShape, f.name));
    for (&art.display_halo, 0..) |*h, i| {
        const g = &display_font.glyphs[i];
        h.* = if (g.present and g.src.w > 0) try buildHalo(a, g.src) else .{};
    }
    return art;
}

/// Tint alpha that makes the noise tile shift a mid-grey faceplate by
/// about `levels` (±) at its strongest texels.
pub fn noiseTint(levels: u8) u8 {
    const base: f32 = 64;
    const t = @as(f32, @floatFromInt(levels)) * 65025.0 / (base * NOISE_MAX * NOISE_BAKE);
    return @intFromFloat(@min(255, @round(t)));
}

// ── Builders ─────────────────────────────────────────────────────────

fn buildNoise(a: *Atlas) !Region {
    const r = try a.reserve(NOISE, NOISE);
    var rng = std.Random.DefaultPrng.init(0x51AB_0001);
    const rand = rng.random();
    var y: i32 = 0;
    while (y < NOISE) : (y += 1) {
        var x: i32 = 0;
        while (x < NOISE) : (x += 1) {
            // Triangular distribution: small deviations common, big rare.
            const n = rand.intRangeAtMost(i32, 0, NOISE_MAX) - rand.intRangeAtMost(i32, 0, NOISE_MAX);
            const mag: f32 = @floatFromInt(@abs(n));
            if (n > 0) {
                // White lifts a 64-grey ~3× faster than black darkens it;
                // bake white weaker so ± steps are symmetric.
                a.put(r, x, y, .{ .r = 255, .g = 255, .b = 255, .a = @intFromFloat(mag * NOISE_BAKE * 64.0 / 191.0) });
            } else if (n < 0) {
                a.put(r, x, y, .{ .r = 0, .g = 0, .b = 0, .a = @intFromFloat(mag * NOISE_BAKE) });
            }
        }
    }
    return r;
}

fn dist(x: i32, y: i32, cx: f32, cy: f32) f32 {
    const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
    const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
    return @sqrt(dx * dx + dy * dy);
}

/// Clockwise angle from 12 o'clock, degrees, (-180, 180].
fn compass(x: i32, y: i32, cx: f32, cy: f32) f32 {
    const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
    const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
    return std.math.radiansToDegrees(std.math.atan2(dx, -dy));
}

/// Light from the top-left: +1 at the top-left rim, -1 at bottom-right.
fn lightAt(x: i32, y: i32, cx: f32, cy: f32) f32 {
    const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
    const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
    const l = @sqrt(dx * dx + dy * dy);
    if (l < 0.001) return 0;
    return (-dx - dy) / (l * std.math.sqrt2);
}

fn buildKnob(a: *Atlas, size: Size) !KnobArt {
    const g = knobGeom(size);
    const d: u16 = @intCast(g.d);
    const reg = try a.reserve(d, d);
    const c: f32 = @as(f32, @floatFromInt(g.d)) / 2.0;

    var y: i32 = 0;
    while (y < g.d) : (y += 1) {
        var x: i32 = 0;
        while (x < g.d) : (x += 1) {
            const r = dist(x, y, c, c);
            if (r >= g.cap_r) continue;
            const vy = (@as(f32, @floatFromInt(y)) + 0.5 - (c - g.cap_r)) / (2 * g.cap_r); // 0 top → 1 bottom
            var col = style.cap.shade(@intFromFloat(@round(10 - 20 * vy)));
            const light = lightAt(x, y, c, c);
            if (r >= g.cap_r - 1) {
                col = style.edge; // outline separates the knob from the plate
            } else if (r >= g.cap_r - 2) {
                // Skirt rim catches the light top-left.
                col = if (light > 0.35) style.face_hi.shade(10) else if (light < -0.35) style.face_lo.shade(-8) else col;
            } else if (r < g.top_r) {
                // Top face: a step lighter; its own edge is lit top-left.
                col = col.shade(8);
                if (r >= g.top_r - 1) {
                    if (light > 0.3) col = col.shade(18) else if (light < -0.3) col = col.shade(-22);
                }
            }
            a.put(reg, x, y, col);
        }
    }
    return .{ .geom = g, .cap = reg, .arc = ring(g, g.arc_r0, g.arc_r1), .mod = ring(g, g.mod_r0, g.mod_r1) };
}

fn ring(g: KnobGeom, r0: f32, r1: f32) Ring {
    var out = Ring{};
    const c: f32 = @as(f32, @floatFromInt(g.d)) / 2.0;
    var y: i32 = 0;
    while (y < g.d) : (y += 1) {
        var x: i32 = 0;
        while (x < g.d) : (x += 1) {
            const r = dist(x, y, c, c);
            if (r < r0 or r >= r1) continue;
            const t = (compass(x, y, c, c) - SWEEP_MIN) / SWEEP_RANGE;
            if (t < 0 or t > 1) continue;
            if (out.len == out.px.len) break;
            out.px[out.len] = .{ .x = @intCast(x), .y = @intCast(y), .t = t };
            out.len += 1;
        }
    }
    std.mem.sort(RingPx, out.px[0..out.len], {}, struct {
        fn lt(_: void, p: RingPx, q: RingPx) bool {
            return p.t < q.t;
        }
    }.lt);
    return out;
}

fn buildSlider(a: *Atlas, kind: SliderKind) !SliderArt {
    const g = sliderGeom(kind);
    const w: u16 = @intCast(g.cap_w);
    const h: u16 = @intCast(g.cap_h);
    const v = try a.reserve(w, h);
    const hz = try a.reserve(h, w);
    var y: i32 = 0;
    while (y < g.cap_h) : (y += 1) {
        var x: i32 = 0;
        while (x < g.cap_w) : (x += 1) {
            const col = sliderCapPixel(g, kind, x, y);
            a.put(v, x, y, col);
            // Horizontal cap: rotate 90° so the light still comes from the
            // top-left (x↔y transpose keeps top/left highlights top/left).
            a.put(hz, y, x, col);
        }
    }
    return .{ .geom = g, .cap_v = v, .cap_h = hz };
}

fn sliderCapPixel(g: SliderGeom, kind: SliderKind, x: i32, y: i32) Color {
    const w = g.cap_w;
    const h = g.cap_h;
    if (x == 0 or y == 0 or x == w - 1 or y == h - 1) return style.edge;
    if (x == 1 or y == 1) return style.face_hi.shade(14);
    if (x == w - 2 or y == h - 2) return style.face_lo.shade(-6);
    const vy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
    var col = style.cap.shade(@intFromFloat(@round(8 - 14 * vy)));
    const mid = @divFloor(h, 2);
    // Centre indicator line across the cap.
    if (y == mid) return style.pointer;
    // Grip grooves: dark line + lit line pairs, spaced out from the centre.
    if (kind != .mini) {
        const off: i32 = @intCast(@abs(y - mid));
        if (off >= 3 and off <= @divFloor(h, 2) - 3) {
            const k = @mod(off - 3, 3);
            if (k == 0) col = col.shade(-18) else if (k == 1) col = col.shade(12);
        }
    }
    return col;
}

fn buildLever(a: *Atlas, pos: u2) !Region {
    const reg = try a.reserve(LEVER_W, LEVER_H);
    const cx: f32 = @as(f32, @floatFromInt(LEVER_W)) / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(LEVER_H)) / 2.0;
    // Bushing: hex-ish nut read as a disc, dark outline, lit top-left.
    var y: i32 = 0;
    while (y < LEVER_H) : (y += 1) {
        var x: i32 = 0;
        while (x < LEVER_W) : (x += 1) {
            const r = dist(x, y, cx, cy);
            if (r < 5) {
                var col = style.face.shade(-6);
                if (r >= 4) col = style.edge else if (lightAt(x, y, cx, cy) > 0.4) col = style.face_hi;
                a.put(reg, x, y, col);
            }
        }
    }
    // Lever: chrome bat from the bushing to a ball tip. pos 0=up 1=mid 2=down.
    const dir: f32 = switch (pos) {
        0 => -1,
        1 => 0,
        else => 1,
    };
    const tip_y = cy + dir * 8;
    const tip_r: f32 = if (pos == 1) 3.5 else 2.5;
    y = 0;
    while (y < LEVER_H) : (y += 1) {
        var x: i32 = 0;
        while (x < LEVER_W) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            // Shaft: tapered from 2.2 at the bushing to 1.4 at the tip.
            var in_shaft = false;
            if (pos != 1) {
                const along = (fy - cy) * dir;
                if (along >= 0 and along <= 8) {
                    const half = 2.2 - 0.8 * (along / 8);
                    in_shaft = @abs(fx - cx) < half;
                }
            }
            const in_tip = dist(x, y, cx, tip_y) < tip_r;
            if (!in_shaft and !in_tip) continue;
            // Chrome: bright left edge, dark right edge, mid body.
            const rel = (fx - cx) / (if (in_tip) tip_r else 2.2);
            var col = Color.hex(0xb8b8b4);
            if (rel < -0.35) col = Color.hex(0xf0f0ec) else if (rel > 0.45) col = Color.hex(0x606064);
            if (in_tip and dist(x, y, cx, tip_y) >= tip_r - 1 and lightAt(x, y, cx, tip_y) < -0.2) col = Color.hex(0x505054);
            a.put(reg, x, y, col);
        }
    }
    return reg;
}

fn ledMask(shape: LedShape, x: i32, y: i32) bool {
    return switch (shape) {
        .round3 => dist(x, y, 1.5, 1.5) < 1.6,
        .round5 => dist(x, y, 2.5, 2.5) < 2.5,
        .round7 => dist(x, y, 3.5, 3.5) < 3.5,
        .square4 => x >= 0 and x < 4 and y >= 0 and y < 4,
        .square6 => x >= 0 and x < 6 and y >= 0 and y < 6,
        // 7-wide triangles, pixel-exact stair edges.
        .tri_up => y >= 0 and y < 4 and @abs(x - 3) <= y,
        .tri_down => y >= 0 and y < 4 and @abs(x - 3) <= 3 - y,
        .tri_right => x >= 0 and x < 4 and @abs(y - 3) <= 3 - x,
        .tri_left => x >= 0 and x < 4 and @abs(y - 3) <= x,
    };
}

pub fn ledSize(shape: LedShape) [2]i32 {
    return switch (shape) {
        .round3 => .{ 3, 3 },
        .round5 => .{ 5, 5 },
        .round7 => .{ 7, 7 },
        .square4 => .{ 4, 4 },
        .square6 => .{ 6, 6 },
        .tri_up, .tri_down => .{ 7, 4 },
        .tri_left, .tri_right => .{ 4, 7 },
    };
}

fn buildLed(a: *Atlas, shape: LedShape) !LedArt {
    const sz = ledSize(shape);
    const body = try a.reserve(@intCast(sz[0]), @intCast(sz[1]));
    const halo = try a.reserve(@intCast(sz[0] + 2 * HALO), @intCast(sz[1] + 2 * HALO));
    const lens = try a.reserve(@intCast(sz[0]), @intCast(sz[1]));
    const white = Color{ .r = 255, .g = 255, .b = 255 };
    var y: i32 = 0;
    while (y < sz[1]) : (y += 1) {
        var x: i32 = 0;
        while (x < sz[0]) : (x += 1) {
            if (ledMask(shape, x, y)) a.put(body, x, y, white);
        }
    }
    // Lens: a bright texel a quarter in from the top-left (none on the
    // 3px LED, where it would swallow the whole body).
    if (sz[0] > 3) {
        const lx = @max(1, @divFloor(sz[0], 4));
        const ly = @max(1, @divFloor(sz[1], 4));
        if (ledMask(shape, lx, ly)) a.put(lens, lx, ly, white.alpha(170));
        if (shape == .round7) a.put(lens, lx + 1, ly, white.alpha(90));
    }
    // Halo: distance falloff around the body, precomputed so nothing
    // blurs at runtime.
    const hw = sz[0] + 2 * HALO;
    const hh = sz[1] + 2 * HALO;
    y = 0;
    while (y < hh) : (y += 1) {
        var x: i32 = 0;
        while (x < hw) : (x += 1) {
            var best: f32 = 99;
            var by: i32 = 0;
            while (by < sz[1]) : (by += 1) {
                var bx: i32 = 0;
                while (bx < sz[0]) : (bx += 1) {
                    if (!ledMask(shape, bx, by)) continue;
                    const dx: f32 = @floatFromInt(x - HALO - bx);
                    const dy: f32 = @floatFromInt(y - HALO - by);
                    best = @min(best, @sqrt(dx * dx + dy * dy));
                }
            }
            if (best > 0 and best <= @as(f32, HALO) + 0.5) {
                const k = 1.0 - best / @as(f32, HALO + 1);
                a.put(halo, x, y, white.alpha(@intFromFloat(255 * k * k)));
            }
        }
    }
    return .{ .body = body, .halo = halo, .lens = lens };
}

/// A glyph's halo: its coverage dilated by one pixel with falloff.
fn buildHalo(a: *Atlas, src: Region) !Region {
    const reg = try a.reserve(src.w + 2, src.h + 2);
    var y: i32 = 0;
    while (y < src.h + 2) : (y += 1) {
        var x: i32 = 0;
        while (x < src.w + 2) : (x += 1) {
            var acc: f32 = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (a.get(src, x - 1 + dx, y - 1 + dy).a == 0) continue;
                    acc += if (dx == 0 and dy == 0) 1.0 else if (dx == 0 or dy == 0) 0.6 else 0.35;
                }
            }
            if (acc > 0) a.put(reg, x, y, .{ .r = 255, .g = 255, .b = 255, .a = @intFromFloat(@min(255, acc * 70)) });
        }
    }
    return reg;
}

test "knob rings are sorted along the sweep and stay inside the cell" {
    var a = try Atlas.init(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    const k = try buildKnob(&a, .l);
    try std.testing.expect(k.arc.len > 100);
    var prev: f32 = -1;
    for (k.arc.slice()) |p| {
        try std.testing.expect(p.t >= prev);
        try std.testing.expect(p.x >= 0 and p.x < k.geom.d and p.y >= 0 and p.y < k.geom.d);
        prev = p.t;
    }
    // Sweep gap at the bottom: nothing straight below the centre.
    for (k.arc.slice()) |p| {
        try std.testing.expect(!(p.x == 15 or p.x == 16) or p.y < 16);
    }
}
