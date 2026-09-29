//! The control catalogue (docs/06 §Control catalogue). One call per
//! family, variants as options, fixed sizes. Every control takes its cell
//! rect, a key (explicit id within the current scope) and the value it
//! edits, and returns whether the value changed.
//!
//! Interaction contract (docs/06 §Interaction contract): drag to set,
//! Shift = fine, double-click = reset, arrows step when focused, the wheel
//! only with ⌘, hover/drag reports to the title display.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const geom = @import("geom.zig");
const style = @import("style.zig");
const sprites = @import("sprites.zig");
const font_mod = @import("font.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;
pub const Size = sprites.Size;
pub const SliderKind = sprites.SliderKind;
pub const LedShape = sprites.LedShape;

/// Pointer travel (window points) for a full 0→1 sweep.
const DRAG_RANGE: f32 = 200;
const FINE: f32 = 10;
const LEGEND_H: i32 = 12;

fn dragDelta(ui: *const Ui) f32 {
    // Up = increase, measured in window points so the feel doesn't change
    // with UI zoom.
    return -ui.in.dy * ui.renderer.zoom;
}

fn fineK(ui: *const Ui) f32 {
    return if (ui.in.shift) FINE else 1;
}

fn legendCol(ui: *const Ui, wid: core.Id, disabled: bool) Color {
    if (disabled) return style.text_mute;
    return if (ui.isHot(wid)) style.text else style.text_dim;
}

fn fmtNorm(buf: []u8, v: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "?";
}

/// Steps a focused control with the arrow keys; returns the signed step
/// count (+ = up/right).
fn arrowSteps(ui: *const Ui, wid: core.Id) i32 {
    if (ui.focus != wid) return 0;
    var n: i32 = 0;
    if (ui.in.keyPressed(c.rl.KEY_UP) or ui.in.keyPressed(c.rl.KEY_RIGHT)) n += 1;
    if (ui.in.keyPressed(c.rl.KEY_DOWN) or ui.in.keyPressed(c.rl.KEY_LEFT)) n -= 1;
    return n;
}

/// Wheel steps, only with ⌘ held (the wheel belongs to the viewport).
fn wheelSteps(ui: *const Ui, r: Rect) f32 {
    if (!ui.in.cmd or ui.in.wheel_y == 0) return 0;
    if (!r.contains(ui.in.ix(), ui.in.iy())) return 0;
    return ui.in.wheel_y;
}

/// Draw a tile's right/bottom seam and return the area inside it.
fn seamed(ui: *Ui, r: Rect) Rect {
    ui.rect(Rect.xywh(r.right() - 1, r.y, 1, r.h), style.edge);
    ui.rect(Rect.xywh(r.x, r.bottom() - 1, r.w - 1, 1), style.edge);
    return Rect.xywh(r.x, r.y, r.w - 1, r.h - 1);
}

fn focusRing(ui: *Ui, wid: core.Id, r: Rect) void {
    if (!ui.focus_visible or ui.focus != wid or ui.active == wid) return;
    ui.bevel(r, style.accent, style.accent);
}

// ── Knob ─────────────────────────────────────────────────────────────

pub const KnobVariant = enum { plain, bipolar, stepped, encoder };

pub const KnobOpts = struct {
    size: Size = .m,
    variant: KnobVariant = .plain,
    label: []const u8 = "",
    default: f32 = 0,
    /// Detent count for `stepped`.
    steps: u8 = 0,
    /// Pre-formatted value ("1.25k"); null shows the 0..1 norm.
    readout: ?[]const u8 = null,
    show_readout: bool = true,
    /// Where modulation currently pushes the value (0..1), if modulated.
    mod: ?f32 = null,
    disabled: bool = false,
};

/// Natural cell size of a knob: legend · knob · readout (if shown).
pub fn knobCell(size: Size, readout: bool) [2]i32 {
    const g = sprites.knobGeom(size);
    return .{ g.d + 8, LEGEND_H + g.d + if (readout) LEGEND_H else 0 };
}

pub fn knob(ui: *Ui, r: Rect, key: anytype, v: *f32, o: KnobOpts) bool {
    const wid = ui.id(key);
    const art = &ui.art.knobs[@intFromEnum(o.size)];
    const g = art.geom;
    const cell = knobCell(o.size, o.show_readout);
    const box = r.center(cell[0], cell[1]);
    const kr = Rect.xywh(box.x + @divFloor(box.w - g.d, 2), box.y + LEGEND_H, g.d, g.d);

    const b = ui.behavior(wid, box, o.disabled);
    const before = v.*;
    const n_steps: f32 = @floatFromInt(@max(o.steps, 2) - 1);
    if (b.pressed) ui.drag_acc = v.*;
    if (b.double) {
        v.* = o.default;
    } else if (b.held) {
        const d = dragDelta(ui) / (DRAG_RANGE * fineK(ui));
        switch (o.variant) {
            .plain, .bipolar => v.* = std.math.clamp(v.* + d, 0, 1),
            .stepped => {
                ui.drag_acc = std.math.clamp(ui.drag_acc + d * 1.5, 0, 1);
                v.* = @round(ui.drag_acc * n_steps) / n_steps;
            },
            .encoder => v.* = v.* + d - @floor(v.* + d),
        }
    }
    const steps: f32 = @as(f32, @floatFromInt(arrowSteps(ui, wid))) + wheelSteps(ui, box);
    if (steps != 0) {
        const unit: f32 = if (o.variant == .stepped) 1 / n_steps else 0.01 / fineK(ui);
        v.* = if (o.variant == .encoder) v.* + steps * unit - @floor(v.* + steps * unit) else std.math.clamp(v.* + steps * unit, 0, 1);
    }

    var vbuf: [16]u8 = undefined;
    const readout = o.readout orelse fmtNorm(&vbuf, v.*);
    if (ui.isHot(wid)) ui.setTouch(o.label, readout);

    // Legend.
    if (o.label.len > 0) {
        ui.textIn(&ui.fonts.legend, Rect.xywh(box.x, box.y, box.w, LEGEND_H), o.label, legendCol(ui, wid, o.disabled), .center, true);
    }

    const t = std.math.clamp(v.*, 0, 1);
    const hot = ui.isHot(wid);
    const lit = if (o.disabled) style.text_mute else if (hot) style.accent else style.arc_on;

    // Value arc / LED ring.
    if (o.variant == .encoder) {
        const dots: usize = if (o.size == .s) 7 else 11;
        const rad = (g.arc_r0 + g.arc_r1) / 2;
        for (0..dots) |i| {
            const ti = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(dots - 1));
            const p = ringPoint(g, ti, rad);
            const on = ti <= t + 0.5 / @as(f32, @floatFromInt(dots - 1)) and ti >= t - 0.5 / @as(f32, @floatFromInt(dots - 1));
            led(ui, kr.x + p[0] - 1, kr.y + p[1] - 1, .round3, if (on) .on else .off, style.led_amber);
        }
    } else {
        const lo, const hi = switch (o.variant) {
            .bipolar => .{ @min(0.5, t), @max(0.5, t) },
            else => .{ 0, t },
        };
        for (art.arc.slice()) |p| {
            const on = p.t >= lo and p.t <= hi and !(o.variant == .bipolar and hi == lo);
            ui.px(kr.x + p.x, kr.y + p.y, if (on) lit else style.arc_off);
        }
        if (o.variant == .stepped) {
            for (0..@max(o.steps, 2)) |i| {
                const ti = @as(f32, @floatFromInt(i)) / n_steps;
                const p = nearest(art.mod.slice(), ti);
                const here = @abs(ti - t) < 0.001;
                ui.px(kr.x + p.x, kr.y + p.y, if (here) lit else style.text_mute);
            }
        }
    }
    if (o.mod) |mv| {
        const m = std.math.clamp(mv, 0, 1);
        const lo = @min(m, t);
        const hi = @max(m, t);
        for (art.mod.slice()) |p| {
            if (p.t >= lo and p.t <= hi) ui.px(kr.x + p.x, kr.y + p.y, style.mod);
        }
    }

    // Cap + pointer.
    ui.sprite(art.cap, kr.x, kr.y, .{ .r = 255, .g = 255, .b = 255 });
    pointer(ui, kr, g, t, if (o.disabled) style.text_mute else style.pointer);

    // Readout.
    if (o.show_readout) {
        const col = if (ui.active == wid) style.accent else if (o.disabled) style.face_hi else style.text_mute;
        ui.textIn(&ui.fonts.legend, Rect.xywh(box.x - 4, kr.bottom(), box.w + 8, LEGEND_H), readout, col, .center, false);
    }
    focusRing(ui, wid, kr.inset(-1));
    return v.* != before;
}

fn ringPoint(g: sprites.KnobGeom, t: f32, rad: f32) [2]i32 {
    const a = std.math.degreesToRadians(sprites.SWEEP_MIN + t * sprites.SWEEP_RANGE);
    const cxy: f32 = @as(f32, @floatFromInt(g.d)) / 2;
    return .{ @intFromFloat(@floor(cxy + @sin(a) * rad)), @intFromFloat(@floor(cxy - @cos(a) * rad)) };
}

fn nearest(ring: []const sprites.RingPx, t: f32) sprites.RingPx {
    var best = ring[0];
    for (ring) |p| {
        if (@abs(p.t - t) < @abs(best.t - t)) best = p;
    }
    return best;
}

/// Pointer line on the cap: every pixel whose centre lies within the
/// pointer's half-width of the segment. Exact, no AA.
fn pointer(ui: *Ui, kr: Rect, g: sprites.KnobGeom, t: f32, col: Color) void {
    const a = std.math.degreesToRadians(sprites.SWEEP_MIN + t * sprites.SWEEP_RANGE);
    const dx = @sin(a);
    const dy = -@cos(a);
    const cxy: f32 = @as(f32, @floatFromInt(g.d)) / 2;
    const r0 = g.cap_r * 0.3;
    const r1 = g.cap_r - 1.6;
    const ax = cxy + dx * r0;
    const ay = cxy + dy * r0;
    const len = r1 - r0;
    var y: i32 = 0;
    while (y < g.d) : (y += 1) {
        var x: i32 = 0;
        while (x < g.d) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5 - ax;
            const py = @as(f32, @floatFromInt(y)) + 0.5 - ay;
            const along = px * dx + py * dy;
            if (along < 0 or along > len) continue;
            const across = @abs(px * dy - py * dx);
            if (across <= g.pointer_w) ui.px(kr.x + x, kr.y + y, col);
        }
    }
}

// ── Slider / fader ───────────────────────────────────────────────────

pub const SliderOpts = struct {
    kind: SliderKind = .slider,
    horizontal: bool = false,
    bipolar: bool = false,
    default: f32 = 0,
    label: []const u8 = "",
    readout: ?[]const u8 = null,
    show_readout: bool = true,
    /// Scale ticks along the slot; 0 = none (slider inside a toolbar).
    ticks: u8 = 11,
    mod: ?f32 = null,
    disabled: bool = false,
};

/// Width (across the slot) of a vertical slider's cell.
pub fn sliderWidth(kind: SliderKind) i32 {
    // Room for ticks either side and a 4-character readout with a gap.
    return @max(sprites.sliderGeom(kind).cap_w + 12, 28);
}

pub fn slider(ui: *Ui, r: Rect, key: anytype, v: *f32, o: SliderOpts) bool {
    const wid = ui.id(key);
    const art = &ui.art.sliders[@intFromEnum(o.kind)];
    const g = art.geom;
    const before = v.*;

    var area = r;
    const legend_r = if (o.label.len > 0) area.cutTop(LEGEND_H) else Rect{};
    const readout_r = if (o.show_readout) area.cutBottom(LEGEND_H) else Rect{};

    // Along-axis geometry.
    const along_len = if (o.horizontal) area.w else area.h;
    const travel = @max(1, along_len - g.cap_h);
    const b = ui.behavior(wid, area, o.disabled);
    if (b.double) {
        v.* = o.default;
    } else if (b.held) {
        const d = if (o.horizontal) ui.in.dx * ui.renderer.zoom else dragDelta(ui);
        v.* = std.math.clamp(v.* + d / (@as(f32, @floatFromInt(travel)) * ui.renderer.zoom * fineK(ui)), 0, 1);
    }
    const steps: f32 = @as(f32, @floatFromInt(arrowSteps(ui, wid))) + wheelSteps(ui, area);
    if (steps != 0) v.* = std.math.clamp(v.* + steps * 0.01 / fineK(ui), 0, 1);

    var vbuf: [16]u8 = undefined;
    const readout = o.readout orelse fmtNorm(&vbuf, v.*);
    if (ui.isHot(wid)) ui.setTouch(o.label, readout);
    if (o.label.len > 0) ui.textIn(&ui.fonts.legend, legend_r, o.label, legendCol(ui, wid, o.disabled), .center, true);
    if (o.show_readout) {
        const col = if (ui.active == wid) style.accent else style.text_mute;
        ui.textIn(&ui.fonts.legend, readout_r, readout, col, .center, false);
    }

    const t = std.math.clamp(v.*, 0, 1);
    const off: i32 = @intFromFloat(@round(t * @as(f32, @floatFromInt(travel))));
    const half = @divFloor(g.cap_h, 2);
    if (!o.horizontal) {
        const cx = area.x + @divFloor(area.w, 2);
        const top = area.y + half;
        const bot = top + travel;
        // Ticks either side of the slot.
        const n: i32 = @max(o.ticks, 2);
        var i: i32 = if (o.ticks == 0) n else 0;
        while (i < n) : (i += 1) {
            const ty = top + @divFloor(i * travel, n - 1);
            const centre = o.bipolar and i * 2 == n - 1;
            const len: i32 = if (centre or i == 0 or i == n - 1) 4 else 2;
            const col = if (centre) style.text_dim else style.text_mute;
            ui.rect(Rect.xywh(cx - @divFloor(g.cap_w, 2) - 1 - len, ty, len, 1), col);
            ui.rect(Rect.xywh(cx + @divFloor(g.cap_w, 2) + 1, ty, len, 1), col);
        }
        const slot = Rect.xywh(cx - @divFloor(g.slot_w, 2), top - 2, g.slot_w, travel + 5);
        _ = ui.well(slot, style.well);
        if (o.mod) |mv| {
            const mo: i32 = @intFromFloat(@round(std.math.clamp(mv, 0, 1) * @as(f32, @floatFromInt(travel))));
            const y0 = bot - @max(off, mo);
            ui.rect(Rect.xywh(slot.x + 1, y0, @max(1, slot.w - 2), @max(1, @as(i32, @intCast(@abs(off - mo))))), style.mod);
        }
        ui.sprite(art.cap_v, cx - @divFloor(g.cap_w, 2), bot - off - half, capTint(ui, wid, o.disabled));
        focusRing(ui, wid, Rect.xywh(cx - @divFloor(g.cap_w, 2) - 1, bot - off - half - 1, g.cap_w + 2, g.cap_h + 2));
    } else {
        const cy = area.y + @divFloor(area.h, 2);
        const left = area.x + half;
        const n: i32 = @max(o.ticks, 2);
        var i: i32 = if (o.ticks == 0) n else 0;
        while (i < n) : (i += 1) {
            const tx = left + @divFloor(i * travel, n - 1);
            const centre = o.bipolar and i * 2 == n - 1;
            const len: i32 = if (centre or i == 0 or i == n - 1) 4 else 2;
            ui.rect(Rect.xywh(tx, cy - @divFloor(g.cap_w, 2) - 1 - len, 1, len), if (centre) style.text_dim else style.text_mute);
        }
        const slot = Rect.xywh(left - 2, cy - @divFloor(g.slot_w, 2), travel + 5, g.slot_w);
        _ = ui.well(slot, style.well);
        ui.sprite(art.cap_h, left + off - half, cy - @divFloor(g.cap_w, 2), capTint(ui, wid, o.disabled));
    }
    return v.* != before;
}

fn capTint(ui: *const Ui, wid: core.Id, disabled: bool) Color {
    if (disabled) return .{ .r = 150, .g = 150, .b = 150 };
    // Hot caps brighten a touch; the sprite is authored at full white tint.
    return if (ui.isHot(wid)) .{ .r = 255, .g = 255, .b = 255 } else .{ .r = 235, .g = 235, .b = 235 };
}

// ── Toggle lever ─────────────────────────────────────────────────────

pub const ToggleOpts = struct {
    positions: u8 = 2,
    label: []const u8 = "",
    /// Printed beside the lever, top to bottom.
    marks: []const []const u8 = &.{},
    disabled: bool = false,
};

/// Lever and its marks, side by side: the group the cell centres.
fn toggleGroupW(ui: *const Ui, marks: []const []const u8) i32 {
    var mw: i32 = 0;
    for (marks) |m| mw = @max(mw, ui.fonts.legend.measure(m));
    return sprites.LEVER_W + if (mw > 0) 2 + mw else 0;
}

pub fn toggleCell(ui: *const Ui, o: ToggleOpts) [2]i32 {
    return .{ @max(40, toggleGroupW(ui, o.marks) + 4), LEGEND_H + sprites.LEVER_H };
}

/// `v` = position index, 0 = up.
pub fn toggle(ui: *Ui, r: Rect, key: anytype, v: *u8, o: ToggleOpts) bool {
    const wid = ui.id(key);
    const before = v.*;
    const n = @max(o.positions, 2);
    var area = r;
    const legend_r = if (o.label.len > 0) area.cutTop(LEGEND_H) else Rect{};
    const lever = Rect.xywh(area.x + @divFloor(area.w - toggleGroupW(ui, o.marks), 2), area.y, sprites.LEVER_W, sprites.LEVER_H);

    const b = ui.behavior(wid, area, o.disabled);
    if (b.pressed) {
        if (n == 2) {
            v.* = 1 - @min(v.*, 1);
        } else {
            const upper = ui.in.iy() < lever.y + @divFloor(lever.h, 2);
            if (upper and v.* > 0) v.* -= 1 else if (!upper and v.* < n - 1) v.* += 1;
        }
    }
    const k = arrowSteps(ui, wid);
    if (k > 0 and v.* > 0) v.* -= 1;
    if (k < 0 and v.* < n - 1) v.* += 1;

    if (o.label.len > 0) ui.textIn(&ui.fonts.legend, legend_r, o.label, legendCol(ui, wid, o.disabled), .center, true);
    const frame: usize = if (n == 2) (if (v.* == 0) 0 else 2) else @min(v.*, 2);
    ui.sprite(ui.art.lever[frame], lever.x, lever.y, capTint(ui, wid, o.disabled));
    for (o.marks, 0..) |m, i| {
        const my = if (o.marks.len == 1) lever.y + 8 else lever.y + 1 + @divFloor(@as(i32, @intCast(i)) * (lever.h - LEGEND_H - 2), @as(i32, @intCast(o.marks.len - 1)));
        const on = i == v.*;
        _ = ui.engraved(&ui.fonts.legend, lever.right() + 2, my, m, if (on) style.text else style.text_mute);
    }
    if (ui.isHot(wid) and o.marks.len > v.*) ui.setTouch(o.label, o.marks[v.*]);
    focusRing(ui, wid, lever.inset(-1));
    return v.* != before;
}

// ── Slide switch ─────────────────────────────────────────────────────

pub const SlideOpts = struct {
    label: []const u8 = "",
    marks: []const []const u8 = &.{},
    positions: u8 = 2,
    disabled: bool = false,
};

const SLIDE_PITCH: i32 = 10;

/// Position pitch: wide enough that each mark sits over its position.
fn slidePitch(ui: *const Ui, marks: []const []const u8) i32 {
    var p = SLIDE_PITCH;
    for (marks) |m| p = @max(p, ui.fonts.legend.measure(m) + 2);
    return p;
}

pub fn slideCell(ui: *const Ui, o: SlideOpts) [2]i32 {
    return .{ @as(i32, @max(o.positions, 2)) * slidePitch(ui, o.marks) + 12, LEGEND_H * 2 + 12 };
}

pub fn slide(ui: *Ui, r: Rect, key: anytype, v: *u8, o: SlideOpts) bool {
    const wid = ui.id(key);
    const before = v.*;
    const n: i32 = @max(o.positions, 2);
    var area = r;
    const legend_r = if (o.label.len > 0) area.cutTop(LEGEND_H) else Rect{};
    const marks_r = if (o.marks.len > 0) area.cutTop(LEGEND_H) else Rect{};
    const pitch = slidePitch(ui, o.marks);
    const slot = Rect.xywh(area.x + @divFloor(area.w - n * pitch - 2, 2), area.y + 1, n * pitch + 2, 10);

    const b = ui.behavior(wid, area, o.disabled);
    if (b.held) {
        const rel = ui.in.ix() - slot.x - 1;
        v.* = @intCast(std.math.clamp(@divFloor(rel, pitch), 0, n - 1));
    }
    const k = arrowSteps(ui, wid);
    if (k > 0 and v.* < n - 1) v.* += 1;
    if (k < 0 and v.* > 0) v.* -= 1;

    if (o.label.len > 0) ui.textIn(&ui.fonts.legend, legend_r, o.label, legendCol(ui, wid, o.disabled), .center, true);
    for (o.marks, 0..) |m, i| {
        const cx = slot.x + 1 + @as(i32, @intCast(i)) * pitch + @divFloor(pitch, 2);
        const w = ui.fonts.legend.measure(m);
        _ = ui.engraved(&ui.fonts.legend, cx - @divFloor(w, 2), marks_r.y, m, if (i == v.*) style.text else style.text_mute);
    }
    const inner = ui.well(slot, style.well);
    const thumb = Rect.xywh(inner.x + @as(i32, v.*) * pitch, inner.y, pitch, inner.h);
    _ = ui.plate(thumb, .{ .fill = style.cap, .outline = .none });
    ui.rect(Rect.xywh(thumb.x + @divFloor(thumb.w, 2), thumb.y + 2, 1, thumb.h - 4), style.edge);
    if (ui.isHot(wid) and o.marks.len > v.*) ui.setTouch(o.label, o.marks[v.*]);
    focusRing(ui, wid, slot.inset(-1));
    return v.* != before;
}

// ── Buttons ──────────────────────────────────────────────────────────

pub const ButtonKind = enum { momentary, latch };

pub const ButtonOpts = struct {
    kind: ButtonKind = .momentary,
    label: []const u8 = "",
    /// LED inside the cap (left of the label), in this colour.
    led: ?Color = null,
    /// The LED lit in this colour while the button is off, instead of dark
    /// (a bypass: green running, red bypassed).
    led_off: ?Color = null,
    /// What the touch display shows while hovered, instead of the label
    /// and ON/OFF.
    touch_name: ?[]const u8 = null,
    touch_value: ?[]const u8 = null,
    /// A label wider than the cap slides while hovered (Ui.marquee).
    marquee: bool = false,
    /// Cap itself lights in this colour when on (808 style).
    lit: ?Color = null,
    /// A shape printed on the cap (transport ▶ ■ ●), lit in `glyph_on`
    /// while the button is on.
    glyph: ?LedShape = null,
    glyph_on: Color = style.accent,
    /// The cap shows only its LED; `label` names it (tooltip, title
    /// display) and is printed above by the caller (panel latch).
    led_only: bool = false,
    /// Toolbar tile: the cap is a section of the bar it sits in, full
    /// height, sharing the bar's 1px seams instead of floating inside it.
    flush: bool = false,
    disabled: bool = false,
};

pub fn buttonHeight(size: Size) i32 {
    return switch (size) {
        .s => 16,
        .m => 20,
        .l => 24,
    };
}

/// Returns true on click. For `latch`, `on` is toggled on click.
pub fn button(ui: *Ui, r: Rect, key: anytype, on: ?*bool, o: ButtonOpts) bool {
    const wid = ui.id(key);
    const b = ui.behaviorEx(wid, r, .{ .disabled = o.disabled, .focusable = false });
    var clicked = b.clicked;
    if (arrowSteps(ui, wid) != 0 or (ui.focus == wid and ui.in.keyPressed(c.rl.KEY_ENTER))) clicked = true;
    if (clicked and o.kind == .latch) {
        if (on) |p| p.* = !p.*;
    }
    const is_on = if (on) |p| p.* else false;
    const down = b.held and b.hover or (o.kind == .latch and is_on);
    cap(ui, r, down, is_on, ui.isHot(wid), o);
    if (ui.isHot(wid) and (o.label.len > 0 or o.touch_name != null))
        ui.setTouch(o.touch_name orelse o.label, o.touch_value orelse if (is_on) "ON" else "OFF");
    focusRing(ui, wid, r);
    return clicked;
}

fn cap(ui: *Ui, r: Rect, down: bool, is_on: bool, hot: bool, o: ButtonOpts) void {
    const body = if (o.flush) seamed(ui, r) else blk: {
        ui.rect(r, style.edge);
        break :blk r.inset(1);
    };
    var fill = style.cap;
    if (o.lit) |lc| {
        if (is_on) fill = style.cap.mix(lc, 0.6);
    }
    if (down) {
        ui.rect(body, fill.shade(-8));
        ui.bevel(body, style.face_lo.shade(-6), fill.shade(4));
    } else {
        const g: i32 = style.materials.gradient;
        ui.vgrad(body, fill.shade(@divFloor(g, 2) + 2), fill.shade(-@divFloor(g, 2) - 2));
        ui.bevel(body, if (o.lit != null and is_on) fill.shade(40) else style.face_hi.shade(if (hot) 14 else 0), style.face_lo);
    }
    if (o.lit) |lc| {
        // Lit cap throws a faint glow onto the plate around it (not on
        // flush tiles: their neighbours are caps too).
        if (is_on and !o.flush) ui.rect(r.inset(-1), lc.alpha(40));
    }
    const shift: i32 = if (down) 1 else 0;
    const label = if (o.led_only) "" else o.label;
    var content = body.insetXY(3, 0);
    content.y += shift;
    if (o.led) |lc| {
        // LED + label are one group, centred in the cap (LED_GAP apart),
        // so the LED never hugs the edge on wide caps.
        const LED_GAP = 4;
        const group = if (label.len > 0) 3 + LED_GAP + ui.fonts.legend.measure(label) else 3;
        const lx = content.x + @max(1, @divFloor(content.w - group, 2));
        const lit_col = if (is_on) lc else o.led_off orelse lc;
        led(ui, lx, content.y + @divFloor(content.h - 3, 2), .round3, if (is_on or o.led_off != null) .on else .off, lit_col);
        content = Rect.xywh(lx + 3 + LED_GAP, content.y, content.right() - (lx + 3 + LED_GAP), content.h);
    }
    if (o.glyph) |shape| {
        const sz = sprites.ledSize(shape);
        const gx = content.x + @divFloor(content.w - sz[0], 2);
        const gy = content.y + @divFloor(content.h - sz[1], 2);
        if (is_on) led(ui, gx, gy, shape, .on, o.glyph_on) else ledShape(ui, gx, gy, shape, if (hot) style.text else style.text_dim);
    }
    if (label.len > 0) {
        const f = &ui.fonts.legend;
        const col = if (o.disabled) style.text_mute else if (o.lit != null and is_on) style.text else style.text_dim;
        if (o.marquee)
            ui.marquee(f, content, label, col, if (o.led != null) .left else .center, !down, hot)
        else
            ui.textIn(f, content, label, col, if (o.led != null) .left else .center, !down);
    }
}

/// Joined caps, exactly one down.
pub const STEPPER_W: i32 = 16;

/// Up/down pair stacked in one narrow tile beside a readout (▲ on top,
/// ▼ below, flush halves). Returns +1, -1 or 0.
pub fn stepper(ui: *Ui, r: Rect, key: anytype) i32 {
    ui.pushId(key);
    defer ui.popId();
    var col = r;
    const up = col.cutTop(@divFloor(r.h, 2));
    var d: i32 = 0;
    if (button(ui, up, "up", null, .{ .glyph = .tri_up, .flush = true })) d += 1;
    if (button(ui, col, "down", null, .{ .glyph = .tri_down, .flush = true })) d -= 1;
    return d;
}

pub fn segmented(ui: *Ui, r: Rect, key: anytype, v: *u8, labels: []const []const u8) bool {
    return segmentedEx(ui, r, key, v, labels, .{});
}

/// Segmented group as toolbar tiles (see `ButtonOpts.flush`).
pub fn segmentedFlush(ui: *Ui, r: Rect, key: anytype, v: *u8, labels: []const []const u8) bool {
    return segmentedEx(ui, r, key, v, labels, .{ .flush = true });
}

const SegOpts = struct {
    /// Toolbar tiles (see `ButtonOpts.flush`).
    flush: bool = false,
    /// Caps stacked top to bottom instead of side by side.
    vertical: bool = false,
    led: ?Color = null,
    /// Names the group in the title display.
    name: []const u8 = "",
};

fn segmentedEx(ui: *Ui, r: Rect, key: anytype, v: *u8, labels: []const []const u8, o: SegOpts) bool {
    const before = v.*;
    ui.pushId(key);
    defer ui.popId();
    const n: i32 = @intCast(labels.len);
    for (labels, 0..) |lab, i| {
        const k: i32 = @intCast(i);
        const cell = if (o.vertical) r.cell(1, n, 0, k) else r.cell(n, 1, k, 0);
        // Joined: neighbours share one outline row / column.
        const cr = if (i == 0 or o.flush)
            cell
        else if (o.vertical)
            Rect.xywh(cell.x, cell.y - 1, cell.w, cell.h + 1)
        else
            Rect.xywh(cell.x - 1, cell.y, cell.w + 1, cell.h);
        const wid = ui.id(i);
        const b = ui.behaviorEx(wid, cr, .{ .focusable = false });
        if (b.pressed) v.* = @intCast(i);
        const on = v.* == i;
        cap(ui, cr, on, on, ui.isHot(wid), .{ .label = lab, .flush = o.flush, .led = o.led });
        if (ui.isHot(wid)) ui.setTouch(o.name, lab);
    }
    return v.* != before;
}

// ── Panel forms ──────────────────────────────────────────────────────
//
// Machine panels lay controls out in legend-topped cells (docs/15). These
// are the catalogue's faders and buttons in that form, sized by the
// panel's tier.

/// Panel fader: the slider kind and travel for a tier. Panels print no
/// readouts; the title display shows the value while it's touched.
pub fn faderKind(size: Size) SliderKind {
    return if (size == .s) .mini else .slider;
}

fn faderTravel(size: Size) i32 {
    return switch (size) {
        .l => 72,
        .m => 56,
        .s => 40,
    };
}

pub fn faderCell(ui: *const Ui, size: Size, label: []const u8) [2]i32 {
    const kind = faderKind(size);
    return .{ @max(sliderWidth(kind), ui.fonts.legend.measure(label) + 4), LEGEND_H + sprites.sliderGeom(kind).cap_h + faderTravel(size) };
}

const LATCH_W: i32 = 24;

pub const LatchOpts = struct {
    size: Size = .m,
    label: []const u8 = "",
    led: Color = style.led_red,
};

pub fn latchCell(ui: *const Ui, o: LatchOpts) [2]i32 {
    return .{ @max(LATCH_W, ui.fonts.legend.measure(o.label) + 4), LEGEND_H + buttonHeight(o.size) };
}

/// Latching panel button: legend over a cap whose LED shows the state.
pub fn latch(ui: *Ui, r: Rect, key: anytype, on: *bool, o: LatchOpts) bool {
    var area = r;
    ui.textIn(&ui.fonts.legend, area.cutTop(LEGEND_H), o.label, style.text_dim, .center, true);
    const h = buttonHeight(o.size);
    const cap_r = area.takeTop(h).center(LATCH_W, h);
    return button(ui, cap_r, key, on, .{ .kind = .latch, .label = o.label, .led = o.led, .led_only = true });
}

pub const RadioOpts = struct {
    size: Size = .m,
    label: []const u8 = "",
    led: Color = style.led_red,
    /// Caps stacked top to bottom (the 106's range buttons).
    vertical: bool = false,
};

fn radioCapW(ui: *const Ui, labels: []const []const u8) i32 {
    var w: i32 = 0;
    for (labels) |l| w = @max(w, ui.fonts.legend.measure(l));
    // LED, gap, label, cap padding.
    return @max(LATCH_W, 3 + 4 + w + 8);
}

/// The joined caps' size: a row of caps, or a column of them.
fn radioCaps(ui: *const Ui, labels: []const []const u8, o: RadioOpts) [2]i32 {
    const n: i32 = @intCast(labels.len);
    const w = radioCapW(ui, labels);
    const h = buttonHeight(o.size);
    return if (o.vertical) .{ w, n * h } else .{ n * w, h };
}

pub fn radioCell(ui: *const Ui, labels: []const []const u8, o: RadioOpts) [2]i32 {
    const caps = radioCaps(ui, labels, o);
    return .{ @max(caps[0], ui.fonts.legend.measure(o.label) + 4), LEGEND_H + caps[1] };
}

/// Radio buttons: legend over joined LED caps, exactly one down.
pub fn radio(ui: *Ui, r: Rect, key: anytype, v: *u8, labels: []const []const u8, o: RadioOpts) bool {
    var area = r;
    ui.textIn(&ui.fonts.legend, area.cutTop(LEGEND_H), o.label, style.text_dim, .center, true);
    const sz = radioCaps(ui, labels, o);
    const caps = area.takeTop(sz[1]).center(sz[0], sz[1]);
    return segmentedEx(ui, caps, key, v, labels, .{ .vertical = o.vertical, .led = o.led, .name = o.label });
}

// ── Selectors ────────────────────────────────────────────────────────

const LIST_ROW: i32 = 14;

pub fn listCell(ui: *const Ui, options: []const []const u8) [2]i32 {
    var w: i32 = 0;
    for (options) |o| w = @max(w, ui.fonts.legend.measure(o));
    return .{ @max(40, 8 + w + 4), LEGEND_H + @as(i32, @intCast(options.len)) * LIST_ROW };
}

/// Vertical option column (octave, waveform): click or drag through.
pub fn list(ui: *Ui, r: Rect, key: anytype, v: *u8, options: []const []const u8, label: []const u8) bool {
    const wid = ui.id(key);
    const before = v.*;
    var area = r;
    const legend_r = if (label.len > 0) area.cutTop(LEGEND_H) else Rect{};
    const rows = Rect.xywh(area.x, area.y, area.w, @as(i32, @intCast(options.len)) * LIST_ROW);
    if (options.len == 0) return false;
    const b = ui.behavior(wid, rows, false);
    if (b.held) {
        const i = @divFloor(ui.in.iy() - rows.y, LIST_ROW);
        v.* = @intCast(std.math.clamp(i, 0, @as(i32, @intCast(options.len)) - 1));
    }
    const k = arrowSteps(ui, wid);
    if (k > 0 and v.* > 0) v.* -= 1;
    if (k < 0 and v.* + 1 < options.len) v.* += 1;

    if (label.len > 0) ui.textIn(&ui.fonts.legend, legend_r, label, legendCol(ui, wid, false), .center, true);
    for (options, 0..) |opt, i| {
        const row = Rect.xywh(rows.x, rows.y + @as(i32, @intCast(i)) * LIST_ROW, rows.w, LIST_ROW);
        const on = i == v.*;
        led(ui, row.x + 2, row.y + 5, .round3, if (on) .on else .off, style.led_amber);
        _ = ui.engraved(&ui.fonts.legend, row.x + 8, row.y + 1, opt, if (on) style.text else style.text_mute);
    }
    if (ui.isHot(wid) and v.* < options.len) ui.setTouch(label, options[v.*]);
    focusRing(ui, wid, rows);
    return v.* != before;
}

/// Value in a display with ‹ › steppers. Drag vertically to step too.
pub fn displaySelect(ui: *Ui, r: Rect, key: anytype, v: *u8, options: []const []const u8) bool {
    return displaySelectEx(ui, r, key, v, options, "");
}

/// Panel form: legend over a display select sized to its longest option.
pub fn displayFieldCell(ui: *const Ui, options: []const []const u8) [2]i32 {
    var w: i32 = 0;
    for (options) |o| w = @max(w, ui.fonts.legend.measure(o));
    // ‹ › caps, well bevel + margin, one spare cell.
    return .{ 20 + w + CELL_W + 4, LEGEND_H + displayHeight(false) };
}

pub fn displayField(ui: *Ui, r: Rect, key: anytype, v: *u8, options: []const []const u8, label: []const u8) bool {
    var area = r;
    ui.textIn(&ui.fonts.legend, area.cutTop(LEGEND_H), label, style.text_dim, .center, true);
    return displaySelectEx(ui, area.takeTop(displayHeight(false)), key, v, options, label);
}

fn displaySelectEx(ui: *Ui, r: Rect, key: anytype, v: *u8, options: []const []const u8, label: []const u8) bool {
    const wid = ui.id(key);
    const before = v.*;
    const n: i32 = @intCast(options.len);
    var area = r;
    const left = area.cutLeft(10);
    const right = area.cutRight(10);
    ui.pushId(key);
    const bl = ui.behaviorEx(ui.id("prev"), left, .{ .focusable = false });
    const br = ui.behaviorEx(ui.id("next"), right, .{ .focusable = false });
    ui.popId();
    const bm = ui.behavior(wid, area, false);
    if (bl.clicked and v.* > 0) v.* -= 1;
    if (br.clicked and @as(i32, v.*) < n - 1) v.* += 1;
    if (bm.pressed) ui.drag_acc = 0;
    if (bm.held) {
        ui.drag_acc += dragDelta(ui) / 24;
        while (ui.drag_acc >= 1 and @as(i32, v.*) < n - 1) : (ui.drag_acc -= 1) v.* += 1;
        while (ui.drag_acc <= -1 and v.* > 0) : (ui.drag_acc += 1) v.* -= 1;
    }
    const k = arrowSteps(ui, wid);
    if (k > 0 and @as(i32, v.*) < n - 1) v.* += 1;
    if (k < 0 and v.* > 0) v.* -= 1;

    _ = ui.plate(left, .{ .fill = style.cap, .outline = .all });
    _ = ui.plate(right, .{ .fill = style.cap, .outline = .all });
    ledShape(ui, left.x + 2, left.y + @divFloor(left.h - 7, 2), .tri_left, if (bl.held) style.text else style.text_dim);
    ledShape(ui, right.x + 4, right.y + @divFloor(right.h - 7, 2), .tri_right, if (br.held) style.text else style.text_dim);
    if (v.* < options.len) {
        display(ui, area.insetXY(-1, 0), options[v.*], .{ .color = if (ui.isHot(wid)) style.vfd else style.vfd.mix(style.well, 0.15) });
        if (ui.isHot(wid)) ui.setTouch(label, options[v.*]);
    }
    focusRing(ui, wid, area);
    return v.* != before;
}

// ── LEDs ─────────────────────────────────────────────────────────────

pub const LedState = enum { off, dim, on, blink };

/// An LED of `shape` with its top-left at (x, y).
pub fn led(ui: *Ui, x: i32, y: i32, shape: LedShape, state: LedState, col: Color) void {
    const art = &ui.art.leds[@intFromEnum(shape)];
    var st = state;
    if (st == .blink) {
        // Host clock: every blinking LED is in phase.
        ui.animate();
        st = if (@mod(@floor(ui.in.time * 2.5), 2) == 0) .on else .off;
    }
    switch (st) {
        .on => {
            ui.sprite(art.halo, x - sprites.HALO, y - sprites.HALO, col.alpha(110));
            ui.sprite(art.body, x, y, col);
            ui.sprite(art.lens, x, y, .{ .r = 255, .g = 255, .b = 255 });
        },
        .dim => {
            ui.sprite(art.halo, x - sprites.HALO, y - sprites.HALO, col.alpha(35));
            ui.sprite(art.body, x, y, col.mix(style.well, 0.45));
        },
        .off, .blink => {
            ui.sprite(art.body, x, y, col.mix(style.well, 0.8));
            ui.sprite(art.lens, x, y, .{ .r = 255, .g = 255, .b = 255, .a = 60 });
        },
    }
}

/// Where a control cell's automation LED goes: just after its centred
/// legend, in the legend row.
pub fn autoLedPos(ui: *const Ui, cell: Rect, label: []const u8) [2]i32 {
    const lw = ui.fonts.legend.measure(label);
    return .{ cell.x + @divFloor(cell.w + lw, 2) + 2, cell.y + @divFloor(LEGEND_H - 4, 2) };
}

/// The automated-control LED (docs/22 §Automated controls): a square 4 at
/// (x, y). Lit while a lane drives the control; a hollow ring while the
/// hand overrides it. Returns true when clicked.
pub fn autoLed(ui: *Ui, x: i32, y: i32, key: anytype, overridden: bool) bool {
    const wid = ui.id(key);
    const b = ui.behaviorEx(wid, Rect.xywh(x - 2, y - 2, 8, 8), .{ .prio = 3, .focusable = false });
    if (overridden) {
        const col = if (b.hover) style.auto else style.auto.mix(style.well, 0.25);
        ui.rect(Rect.xywh(x, y, 4, 1), col);
        ui.rect(Rect.xywh(x, y + 3, 4, 1), col);
        ui.rect(Rect.xywh(x, y + 1, 1, 2), col);
        ui.rect(Rect.xywh(x + 3, y + 1, 1, 2), col);
        ui.rect(Rect.xywh(x + 1, y + 1, 2, 2), style.well);
    } else {
        led(ui, x, y, .square4, .on, style.auto);
    }
    return b.clicked;
}

/// A flat shape tinted `col` (arrows on steppers, printed marks).
fn ledShape(ui: *Ui, x: i32, y: i32, shape: LedShape, col: Color) void {
    ui.sprite(ui.art.leds[@intFromEnum(shape)].body, x, y, col);
}

/// Rectangular bar LED of any grid length.
pub fn ledBar(ui: *Ui, r: Rect, state: LedState, col: Color) void {
    switch (state) {
        .on, .blink => {
            ui.rect(r.inset(-2), col.alpha(22));
            ui.rect(r.inset(-1), col.alpha(50));
            ui.rect(r, col);
            ui.rect(Rect.xywh(r.x, r.y, r.w, 1), col.mix(.{ .r = 255, .g = 255, .b = 255 }, 0.4));
        },
        .dim => ui.rect(r, col.mix(style.well, 0.45)),
        .off => ui.rect(r, col.mix(style.well, 0.82)),
    }
}

pub const LadderOpts = struct {
    segs: u8 = 16,
    horizontal: bool = false,
};

/// Segmented meter. `level` and `peak` are 0..1. The peak falls back
/// slowly (afterglow) from widget memory, keyed by `key`.
pub fn ladder(ui: *Ui, r: Rect, key: anytype, level: f32, o: LadderOpts) void {
    const wid = ui.id(key);
    const hold = ui.memo(wid, 0);
    const lv = std.math.clamp(level, 0, 1);
    if (lv >= hold.*) hold.* = lv else {
        hold.* = @max(lv, hold.* - 0.012);
        ui.animate();
    }
    const inner = ui.well(r, style.well);
    const n: i32 = o.segs;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const col = if (t0 >= 0.9) style.rec else if (t0 >= 0.7) style.led_yellow else style.led_green;
        const seg = if (o.horizontal) blk: {
            const x0 = inner.x + 1 + @divFloor(i * (inner.w - 1), n);
            const x1 = inner.x + 1 + @divFloor((i + 1) * (inner.w - 1), n);
            break :blk Rect.xywh(x0, inner.y + 1, x1 - x0 - 1, inner.h - 2);
        } else blk: {
            const y1 = inner.bottom() - 1 - @divFloor(i * (inner.h - 1), n);
            const y0 = inner.bottom() - 1 - @divFloor((i + 1) * (inner.h - 1), n);
            break :blk Rect.xywh(inner.x + 1, y0 + 1, inner.w - 2, y1 - y0 - 1);
        };
        const st: LedState = if (t0 < lv) .on else if (t0 < hold.* and t0 + 1.0 / @as(f32, @floatFromInt(n)) >= hold.*) .on else .off;
        ledBarFlat(ui, seg, st, col);
    }
}

// ── Pro meter ────────────────────────────────────────────────────────

pub const MeterScale = enum {
    /// Graduate when there is room for labels, else bare.
    auto,
    none,
    /// Labels left of (or above) the bar.
    before,
    /// Labels right of (or below) the bar.
    after,
};

pub const MeterOpts = struct {
    horizontal: bool = false,
    scale: MeterScale = .auto,
    /// Latching clip LED at the top (right) end; click to reset.
    clip_led: bool = true,
};

const METER_MARKS = [_]f32{ 0, -3, -6, -12, -18, -24, -36, -48 };
const METER_FLOOR: f32 = -60;
/// Display fall rate (dB/s), peak-hold time (s) and hold fall (dB/s).
const METER_FALL: f32 = 26;
const PEAK_HOLD: f32 = 1.2;
const PEAK_FALL: f32 = 18;
const SCALE_W: i32 = 20;
const CLIP_H: i32 = 5;

/// dB → 0..1 position. Piecewise linear with more resolution near the
/// top, where mixing decisions happen (like hardware bargraphs).
pub fn meterPos(db: f32) f32 {
    const pts = [_][2]f32{ .{ -60, 0 }, .{ -48, 0.1 }, .{ -36, 0.22 }, .{ -24, 0.38 }, .{ -18, 0.48 }, .{ -12, 0.61 }, .{ -6, 0.78 }, .{ -3, 0.88 }, .{ 0, 1 } };
    if (db <= pts[0][0]) return 0;
    for (1..pts.len) |i| {
        if (db <= pts[i][0]) {
            const a = pts[i - 1];
            const b = pts[i];
            return a[1] + (b[1] - a[1]) * (db - a[0]) / (b[0] - a[0]);
        }
    }
    return 1;
}

/// Inverse of meterPos (bisection; exact enough for colour zoning).
fn meterDb(t: f32) f32 {
    var lo: f32 = METER_FLOOR;
    var hi: f32 = 0;
    for (0..14) |_| {
        const mid = (lo + hi) / 2;
        if (meterPos(mid) < t) lo = mid else hi = mid;
    }
    return (lo + hi) / 2;
}

pub fn linToDb(v: f32) f32 {
    return if (v <= 0.000_001) -120 else 20 * std.math.log10(v);
}

fn zoneColor(db: f32) Color {
    return if (db > -3) style.rec else if (db > -12) style.led_yellow else style.led_green;
}

const Ballistics = struct { peak: f32, rms: f32, hold: f32 };

/// Per-bar state in widget memory: displayed peak and RMS fall at
/// METER_FALL, the held peak holds PEAK_HOLD then falls at PEAK_FALL.
fn ballistics(ui: *Ui, wid: core.Id, peak_db: f32, rms_db: f32) Ballistics {
    const dt = ui.in.dt;
    const peak = ui.memo(wid, METER_FLOOR);
    const rms = ui.memo(wid +% 1, METER_FLOOR);
    const hold = ui.memo(wid +% 2, METER_FLOOR);
    const hold_t = ui.memo(wid +% 3, 0);
    peak.* = @max(peak_db, peak.* - METER_FALL * dt);
    rms.* = @max(rms_db, rms.* - METER_FALL * dt);
    if (peak_db >= hold.*) {
        hold.* = peak_db;
        hold_t.* = PEAK_HOLD;
    } else if (hold_t.* > 0) {
        hold_t.* -= dt;
    } else {
        hold.* = @max(METER_FLOOR, hold.* - PEAK_FALL * dt);
    }
    if (peak.* > METER_FLOOR or hold.* > METER_FLOOR) ui.animate();
    return .{ .peak = peak.*, .rms = rms.*, .hold = hold.* };
}

/// One bar: segments coloured by dB zone. RMS body at full brightness,
/// peak above it a step dimmer, a bright peak-hold segment, unlit
/// segments as dark ghost glass.
fn meterBar(ui: *Ui, r: Rect, b: Ballistics, horizontal: bool) void {
    const inner = ui.well(r, style.well);
    const len = if (horizontal) inner.w else inner.h;
    const across = if (horizontal) inner.h else inner.w;
    const pitch: i32 = if (across >= 6) 3 else 2; // segment + 1px gap
    const n = @divFloor(len, pitch);
    if (n <= 0) return;
    const nf: f32 = @floatFromInt(n);
    const peak_p = meterPos(b.peak);
    const rms_p = meterPos(b.rms);
    const hold_i: i32 = @intFromFloat(@floor(meterPos(b.hold) * nf - 0.001));
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const t = (@as(f32, @floatFromInt(i)) + 0.5) / nf;
        const zc = zoneColor(meterDb(t));
        const col = if (t <= rms_p)
            zc
        else if (t <= peak_p)
            zc.mix(style.well, 0.35)
        else if (i == hold_i and b.hold > METER_FLOOR)
            zc.mix(style.text, 0.25)
        else
            zc.mix(style.well, 0.86);
        const seg = if (horizontal)
            Rect.xywh(inner.x + i * pitch, inner.y, pitch - 1, inner.h)
        else
            Rect.xywh(inner.x, inner.bottom() - (i + 1) * pitch + 1, inner.w, pitch - 1);
        ui.rect(seg, col);
    }
}

/// dB graduation in `r`, positioned against `axis` (the bar's long extent).
fn meterScale(ui: *Ui, r: Rect, axis: Rect, horizontal: bool, side: Ui.Align) void {
    const f = &ui.fonts.legend;
    for (METER_MARKS) |db| {
        const p = meterPos(db);
        var buf: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{@as(u32, @intFromFloat(@abs(db)))}) catch "";
        const col = if (db == 0) style.text_dim else style.text_mute;
        const w = f.measure(s);
        if (horizontal) {
            const x = axis.x + @as(i32, @intFromFloat(@round(p * @as(f32, @floatFromInt(axis.w - 1)))));
            ui.rect(Rect.xywh(x, r.y, 1, 2), col);
            _ = ui.text(f, geom.fit(x - @divFloor(w, 2), r.x, r.right() - w), r.y + 1, s, col);
        } else {
            const y = axis.bottom() - 1 - @as(i32, @intFromFloat(@round(p * @as(f32, @floatFromInt(axis.h - 1)))));
            const ty = geom.fit(y - 6, r.y - 2, r.bottom() - 10);
            switch (side) {
                .left => {
                    ui.rect(Rect.xywh(r.x, y, 2, 1), col);
                    _ = ui.text(f, r.x + 3, ty, s, col);
                },
                .right => {
                    ui.rect(Rect.xywh(r.right() - 2, y, 2, 1), col);
                    _ = ui.text(f, r.right() - 3 - w, ty, s, col);
                },
                .center => {
                    ui.rect(Rect.xywh(r.x, y, 2, 1), col);
                    ui.rect(Rect.xywh(r.right() - 2, y, 2, 1), col);
                    _ = ui.text(f, r.x + @divFloor(r.w - w, 2), ty, s, col);
                },
            }
        }
    }
}

/// Clip indicator: latches on any sample at or above 0 dBFS; click resets.
fn clipLed(ui: *Ui, r: Rect, wid: core.Id, peak_db: f32) void {
    const held = ui.memo(wid +% 4, 0);
    if (peak_db >= 0) held.* = 1;
    if (ui.behaviorEx(wid +% 5, r, .{ .focusable = false }).clicked) held.* = 0;
    const inner = ui.well(r, style.well);
    const on = held.* > 0;
    ui.rect(inner, if (on) style.rec else style.rec.mix(style.well, 0.82));
    if (on) ui.rect(Rect.xywh(inner.x, inner.y, inner.w, 1), style.rec.mix(style.text, 0.4));
}

/// Pro mono meter. `peak` and `rms` are linear amplitude (1.0 = 0 dBFS).
pub fn meter(ui: *Ui, r: Rect, key: anytype, peak: f32, rms: f32, o: MeterOpts) void {
    const wid = ui.id(key);
    const pdb = linToDb(peak);
    const b = ballistics(ui, wid, pdb, linToDb(rms));
    var area = r;
    const graduate = switch (o.scale) {
        .none => false,
        .auto => if (o.horizontal) area.h >= 20 else area.w >= SCALE_W + 6,
        .before, .after => true,
    };
    // Scale first, so the clip LED sits over the bar only.
    var sc = Rect{};
    if (graduate) {
        sc = if (o.horizontal)
            (if (o.scale == .before) area.cutTop(12) else area.cutBottom(12))
        else
            (if (o.scale == .after) area.cutRight(SCALE_W) else area.cutLeft(SCALE_W));
    }
    const clip_r = if (!o.clip_led) Rect{} else if (o.horizontal) area.cutRight(CLIP_H + 1) else area.cutTop(CLIP_H);
    meterBar(ui, area, b, o.horizontal);
    if (graduate) {
        const side: Ui.Align = if (o.horizontal or o.scale == .after) .left else .right;
        meterScale(ui, if (o.horizontal) sc else Rect.xywh(sc.x, area.y, sc.w, area.h), area.inset(1), o.horizontal, side);
    }
    if (o.clip_led) clipLed(ui, clip_r, wid, pdb);
}

/// Stereo pair sharing one centre scale (SSL-style) when it fits.
/// A vertical dB scale in `r`, graduated against the bar `bar` (same top,
/// same height, clip LED excluded) — for scales shared by separate meters.
pub fn meterScaleBetween(ui: *Ui, r: Rect, bar: Rect) void {
    const axis = Rect.xywh(r.x, bar.y + CLIP_H, r.w, bar.h - CLIP_H);
    meterScale(ui, axis, axis.inset(1), false, .center);
}

pub fn meterStereo(ui: *Ui, r: Rect, key: anytype, peak: [2]f32, rms: [2]f32, o: MeterOpts) void {
    ui.pushId(key);
    defer ui.popId();
    const bare = MeterOpts{ .horizontal = o.horizontal, .scale = .none, .clip_led = o.clip_led };
    const graduate = o.scale != .none and (if (o.horizontal) r.h >= 26 else r.w >= SCALE_W + 10);
    var a = r;
    if (!graduate) {
        const first = if (o.horizontal) a.cutTop(@divFloor(r.h, 2)) else a.cutLeft(@divFloor(r.w, 2));
        meter(ui, first, "l", peak[0], rms[0], bare);
        meter(ui, a, "r", peak[1], rms[1], bare);
        return;
    }
    const clip: i32 = if (o.clip_led) CLIP_H else 0;
    if (o.horizontal) {
        const bar_h = @divFloor(r.h - 12, 2);
        meter(ui, a.cutTop(bar_h), "l", peak[0], rms[0], bare);
        const sc = a.cutTop(12);
        meter(ui, a, "r", peak[1], rms[1], bare);
        const axis = Rect.xywh(r.x, sc.y, r.w - (if (o.clip_led) clip + 1 else 0), sc.h);
        meterScale(ui, sc, axis.inset(1), true, .left);
    } else {
        const bar_w = @divFloor(r.w - SCALE_W, 2);
        meter(ui, a.cutLeft(bar_w), "l", peak[0], rms[0], bare);
        const sc = a.cutLeft(SCALE_W);
        meter(ui, a, "r", peak[1], rms[1], bare);
        const axis = Rect.xywh(sc.x, r.y + clip, sc.w, r.h - clip);
        meterScale(ui, axis, axis.inset(1), false, .center);
    }
}

/// Meter segments: no halo (they sit shoulder to shoulder).
fn ledBarFlat(ui: *Ui, r: Rect, st: LedState, col: Color) void {
    ui.rect(r, switch (st) {
        .on, .blink => col,
        .dim => col.mix(style.well, 0.45),
        .off => col.mix(style.well, 0.85),
    });
}

// ── Displays ─────────────────────────────────────────────────────────

pub const DisplayOpts = struct {
    color: Color = style.vfd,
    align_: Ui.Align = .left,
    /// Draw the unlit cell grid.
    ghost: bool = true,
    /// Each matrix dot is 2×2 logical px (transport readouts).
    large: bool = false,
    /// Toolbar tile: the well spans the full rect and ends in the bar's
    /// right/bottom seam.
    flush: bool = false,
};

pub const CELL_W: i32 = 6;
pub const CELL_H: i32 = 12;

pub fn displayHeight(large: bool) i32 {
    return if (large) CELL_H * 2 + 4 else CELL_H + 4;
}

/// Dot-matrix readout (docs/06 §Displays). Tamzen 6×12 is the matrix face:
/// its caps are 5×7, the classic LCD cell.
pub fn display(ui: *Ui, r: Rect, s: []const u8, o: DisplayOpts) void {
    displayLines(ui, r, &.{s}, o);
}

/// A display of several rows, stacked and centred in the well.
pub fn displayLines(ui: *Ui, r: Rect, lines: []const []const u8, o: DisplayOpts) void {
    const inner = ui.well(if (o.flush) seamed(ui, r) else r, style.well);
    const m = style.materials;
    const f = &ui.fonts.legend;
    const k: i32 = if (o.large) 2 else 1;
    const cw = CELL_W * k;
    const ch = CELL_H * k;
    const cells = @divFloor(inner.w - 2 * k, cw);
    if (cells <= 0) return;
    const rows: i32 = @intCast(lines.len);
    const top = inner.y + @divFloor(inner.h - ch * rows, 2);
    ui.clip(inner);
    for (lines, 0..) |s, row| {
        const text_w = @min(f.measure(s) * k, cells * cw);
        const x0 = inner.x + k + switch (o.align_) {
            .left => 0,
            .center => @divFloor(cells * cw - text_w, 2 * cw) * cw,
            .right => cells * cw - text_w,
        };
        const y0 = top + @as(i32, @intCast(row)) * ch;
        // Ghost cells: the unlit 5×7 cap box of every cell.
        if (o.ghost and m.ghost_alpha > 0) {
            var i: i32 = 0;
            while (i < cells) : (i += 1) ui.rect(Rect.xywh(inner.x + k + i * cw, y0 + 2 * k, 5 * k, 7 * k), o.color.alpha(m.ghost_alpha));
        }
        // Halo, then lit glyphs.
        var pen = x0;
        var it = font_mod.Utf8Iter{ .s = s };
        while (it.next()) |cp| {
            if (pen + cw > inner.right()) break;
            const idx = f.index(cp);
            const g = &f.glyphs[idx];
            const halo = ui.art.display_halo[idx];
            if (m.halo_alpha > 0 and halo.w > 0) ui.spriteScaled(halo, pen + (g.dx - 1) * k, y0 + (g.dy - 1) * k, k, o.color.alpha(m.halo_alpha));
            if (g.src.w > 0) ui.spriteScaled(g.src, pen + g.dx * k, y0 + g.dy * k, k, o.color);
            pen += g.advance * k;
        }
    }
    // Dot gaps: once a matrix dot spans 2+ device px, a 1-device-px
    // well-coloured mesh on every dot boundary turns solid glyphs into a
    // dot matrix.
    const ds = ui.deviceScale();
    const dot_dev = ds * @as(f32, @floatFromInt(k));
    if (dot_dev >= 2) {
        const gap = 1.0 / ds;
        const gap_col = style.well.alpha(200);
        const h = ch * rows;
        var x: i32 = inner.x + k;
        while (x < inner.right()) : (x += k) ui.frect(@as(f32, @floatFromInt(x + k)) - gap, @floatFromInt(top), gap, @floatFromInt(h), gap_col);
        var y: i32 = top;
        while (y < top + h) : (y += k) ui.frect(@floatFromInt(inner.x), @as(f32, @floatFromInt(y + k)) - gap, @floatFromInt(inner.w), gap, gap_col);
    }
    ui.unclip();
}

/// Scope/curve display with afterglow: the last few frames' traces fade
/// behind the current one. `pts` are 0..1 (bottom→top), spread across r.
pub fn scope(ui: *Ui, r: Rect, key: anytype, pts: []const f32, col: Color) void {
    const inner = ui.well(r, style.well);
    const tr = ui.trail(ui.id(key));
    // Record this frame.
    tr.head = (tr.head + 1) % core.TRAIL;
    const n = @min(pts.len, core.TRAIL_PTS);
    @memcpy(tr.pts[tr.head][0..n], pts[0..n]);
    tr.lens[tr.head] = n;

    ui.clip(inner);
    // Graticule: centre line.
    ui.rect(Rect.xywh(inner.x, inner.y + @divFloor(inner.h, 2), inner.w, 1), col.alpha(22));
    var age: usize = core.TRAIL;
    while (age > 0) {
        age -= 1;
        const slot = (tr.head + core.TRAIL - age) % core.TRAIL;
        const len = tr.lens[slot];
        if (len < 2) continue;
        const a: u8 = if (age == 0) 255 else @intCast(90 / age);
        trace(ui, inner, tr.pts[slot][0..len], col.alpha(a));
    }
    ui.unclip();
    ui.animate();
}

/// Static curve (envelope view): no afterglow needed, it only changes on
/// edit, but it keeps the same glass.
pub fn curve(ui: *Ui, r: Rect, pts: []const f32, col: Color) void {
    const inner = ui.well(r, style.well);
    ui.clip(inner);
    trace(ui, inner, pts, col);
    ui.unclip();
}

fn trace(ui: *Ui, inner: Rect, pts: []const f32, col: Color) void {
    const w: f32 = @floatFromInt(inner.w - 3);
    const h: f32 = @floatFromInt(inner.h - 3);
    const x0: f32 = @as(f32, @floatFromInt(inner.x)) + 1.5;
    const y0: f32 = @as(f32, @floatFromInt(inner.y)) + 1.5;
    const k = w / @as(f32, @floatFromInt(pts.len - 1));
    for (1..pts.len) |i| {
        const xa = x0 + @as(f32, @floatFromInt(i - 1)) * k;
        const xb = x0 + @as(f32, @floatFromInt(i)) * k;
        ui.line(xa, y0 + h * (1 - pts[i - 1]), xb, y0 + h * (1 - pts[i]), col);
    }
}

// ── Faceplates ───────────────────────────────────────────────────────

/// Module strip: a faceplate with an engraved title. Returns the body.
pub fn strip(ui: *Ui, r: Rect, title: []const u8) Rect {
    var body = ui.plate(r, .{});
    const head = body.cutTop(LEGEND_H + 2);
    if (title.len > 0) _ = ui.engraved(&ui.fonts.legend, head.x + 3, head.y + 1, title, style.text_dim);
    return body;
}

/// Machine title strip: name + title display (preset, or the touched
/// parameter while one is being touched in this machine's scope).
pub fn titleStrip(ui: *Ui, r: Rect, name: []const u8, preset: []const u8) void {
    var body = ui.plate(r, .{ .chamfer = 2 });
    const f = &ui.fonts.body_bold;
    const name_w = f.measure(name) + 8;
    const name_r = body.cutLeft(name_w);
    ui.textIn(f, name_r.insetXY(4, 0), name, style.text, .left, true);
    const disp_r = body.insetXY(2, 1);
    const t = &ui.touch;
    var buf: [48]u8 = undefined;
    const live = t.scope == ui.scopeId() and ui.in.time - t.time < core.TOUCH_HOLD;
    const s = if (live)
        std.fmt.bufPrint(&buf, "{s} {s}{s}", .{ t.labelStr(), t.valueStr(), if (t.automated) " A" else "" }) catch preset
    else
        preset;
    display(ui, disp_r, s, .{});
}

// ── Splitters ────────────────────────────────────────────────────────

pub const SplitAxis = enum {
    /// Panes stacked top/bottom; the seam is horizontal.
    rows,
    /// Panes side by side; the seam is vertical.
    cols,
};

pub const SplitOpts = struct {
    axis: SplitAxis = .rows,
    /// `size` measures the last pane (bottom/right) instead of the first.
    from_end: bool = false,
    /// Minimum of the sized pane and of the other one.
    min: i32 = 40,
    min_other: i32 = 40,
    /// Sizes the pane snaps to while dragged (natural-size tiers); empty
    /// means continuous.
    snap: []const i32 = &.{},
    /// Double-click collapses to this size and back (0 = no collapse).
    collapsed: i32 = 0,
};

const SPLIT_GRAB: i32 = 3;

/// Split `r` in two at a draggable seam. `size` is the persistent size of
/// the sized pane (logical px); the caller owns it. The seam is the first
/// pane's own right/bottom seam line: there is no separate divider.
pub fn split(ui: *Ui, r: Rect, key: anytype, size: *i32, o: SplitOpts) [2]Rect {
    const wid = ui.id(key);
    const rows = o.axis == .rows;
    const start = if (rows) r.y else r.x;
    const extent = if (rows) r.h else r.w;

    const first_len = if (o.from_end) extent - size.* else size.*;
    const line = start + first_len - 1;
    const hit = if (rows)
        Rect.xywh(r.x, line - SPLIT_GRAB, r.w, 2 * SPLIT_GRAB + 1)
    else
        Rect.xywh(line - SPLIT_GRAB, r.y, 2 * SPLIT_GRAB + 1, r.h);

    const b = ui.behaviorEx(wid, hit, .{ .prio = 1, .focusable = false });
    const mouse = if (rows) ui.in.iy() else ui.in.ix();
    const grab = ui.memo(wid, 0);
    if (b.pressed) grab.* = @floatFromInt(mouse - line);
    if (b.double and o.collapsed > 0) {
        const restore = ui.memo(wid +% 1, @floatFromInt(size.*));
        if (size.* == o.collapsed) {
            size.* = @intFromFloat(restore.*);
        } else {
            restore.* = @floatFromInt(size.*);
            size.* = o.collapsed;
        }
    } else if (b.held) {
        size.* = dragSize(o, extent, mouse - @as(i32, @intFromFloat(grab.*)) - start);
    }
    size.* = clampSize(o, extent, size.*);

    if (ui.isHot(wid)) {
        ui.requestCursor(if (rows) c.rl.MOUSE_CURSOR_RESIZE_NS else c.rl.MOUSE_CURSOR_RESIZE_EW, 2);
    }
    const final_first = if (o.from_end) extent - size.* else size.*;
    const seam = start + final_first - 1;
    if (ui.isHot(wid)) {
        ui.overlayRect(if (rows) Rect.xywh(r.x, seam, r.w, 1) else Rect.xywh(seam, r.y, 1, r.h), style.accent);
    }
    var a = r;
    const first = if (rows) a.cutTop(final_first) else a.cutLeft(final_first);
    return .{ first, a };
}

/// Pane size for a seam dragged to `line` (offset from the split's start):
/// the first pane then spans line + 1 px. Snaps to tiers when given.
fn dragSize(o: SplitOpts, extent: i32, line: i32) i32 {
    const first = line + 1;
    const want = if (o.from_end) extent - first else first;
    return if (o.snap.len > 0) nearestSize(o.snap, want, o.collapsed) else want;
}

fn clampSize(o: SplitOpts, extent: i32, size: i32) i32 {
    const lo = if (o.collapsed > 0) @min(o.collapsed, o.min) else o.min;
    const hi = @max(lo, extent - o.min_other);
    return std.math.clamp(size, lo, hi);
}

fn nearestSize(snap: []const i32, want: i32, collapsed: i32) i32 {
    var best = snap[0];
    for (snap) |t| if (@abs(t - want) < @abs(best - want)) {
        best = t;
    };
    if (collapsed > 0 and @abs(collapsed - want) < @abs(best - want)) best = collapsed;
    return best;
}

test "splitter drag math: continuous, from_end, tiers, collapse, clamps" {
    const t = std.testing;
    // Continuous, first pane sized: seam at offset 99 → 100 px.
    try t.expectEqual(@as(i32, 100), dragSize(.{}, 500, 99));
    // from_end: the bottom pane gets what's below the seam.
    try t.expectEqual(@as(i32, 400), dragSize(.{ .from_end = true }, 500, 99));
    // Tiers: snap to the nearest; collapse is a tier too.
    const tiers = [_]i32{ 131, 147, 163 };
    const o = SplitOpts{ .from_end = true, .min = 131, .snap = &tiers, .collapsed = 20 };
    try t.expectEqual(@as(i32, 163), dragSize(o, 800, 800 - 200 - 1));
    try t.expectEqual(@as(i32, 147), dragSize(o, 800, 800 - 150 - 1));
    try t.expectEqual(@as(i32, 20), dragSize(o, 800, 800 - 30 - 1));
    // Clamps: never below min (collapse excepted), never squeezing the other pane.
    try t.expectEqual(@as(i32, 20), clampSize(o, 800, 20));
    try t.expectEqual(@as(i32, 40), clampSize(.{ .min = 40, .min_other = 40 }, 500, 5));
    try t.expectEqual(@as(i32, 460), clampSize(.{ .min = 40, .min_other = 40 }, 500, 490));
}
