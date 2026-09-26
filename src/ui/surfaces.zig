//! Working surfaces (docs/06 §Working surfaces): the arrangement, piano
//! roll and their grids. Flat dark glass, no material: the user's work is
//! the brightest thing on it. Hardware (rulers, track headers, the key
//! column) is faceplate and sits around the glass.

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;

// ── Time axis ────────────────────────────────────────────────────────

pub const TimeView = struct {
    /// First visible beat.
    start: f32 = 0,
    /// Logical px per beat.
    ppb: f32 = 24,
    beats_per_bar: u8 = 4,
    /// Subdivisions per beat shown when there's room (≥ 6 px apart).
    sub: u8 = 4,

    pub fn x(v: TimeView, r: Rect, beat: f32) i32 {
        return r.x + @as(i32, @intFromFloat(@round((beat - v.start) * v.ppb)));
    }

    pub fn beatAt(v: TimeView, r: Rect, px: i32) f32 {
        return v.start + @as(f32, @floatFromInt(px - r.x)) / v.ppb;
    }

    pub fn end(v: TimeView, r: Rect) f32 {
        return v.beatAt(r, r.right());
    }
};

/// Vertical time grid: sub < beat < bar lines, alternate bars faintly
/// shaded so long rows stay readable.
pub fn timeGrid(ui: *Ui, r: Rect, v: TimeView, fill: Color) void {
    ui.rect(r, fill);
    const bpb: f32 = @floatFromInt(v.beats_per_bar);
    // Alternate bar shading.
    var bar = @floor(v.start / bpb);
    while (bar * bpb < v.end(r)) : (bar += 1) {
        if (@mod(bar, 2) == 1) {
            const x0 = @max(r.x, v.x(r, bar * bpb));
            const x1 = @min(r.right(), v.x(r, (bar + 1) * bpb));
            ui.rect(Rect.xywh(x0, r.y, x1 - x0, r.h), Color.hex(0xffffff).alpha(5));
        }
    }
    const sub: f32 = @floatFromInt(v.sub);
    const show_sub = v.ppb / sub >= 6;
    const step: f32 = if (show_sub) 1 / sub else 1;
    var t = @floor(v.start / step) * step;
    while (t < v.end(r)) : (t += step) {
        const is_bar = @mod(t, bpb) < 0.001;
        const is_beat = @mod(t, 1) < 0.001;
        const col = if (is_bar) style.grid_bar else if (is_beat) style.grid_beat else style.grid_sub;
        const xx = v.x(r, t);
        if (xx >= r.x and xx < r.right()) ui.rect(Rect.xywh(xx, r.y, 1, r.h), col);
    }
}

pub fn playhead(ui: *Ui, r: Rect, v: TimeView, beat: f32) void {
    const xx = v.x(r, beat);
    if (xx >= r.x and xx < r.right()) ui.rect(Rect.xywh(xx, r.y, 1, r.h), style.accent);
}

/// Ruler faceplate: bar numbers, beat ticks, the loop bracket and the
/// playhead marker. The loop lives here, not smeared across the lanes.
pub fn ruler(ui: *Ui, r: Rect, v: TimeView, loop: ?[2]f32, head: f32) void {
    const body = ui.plate(r, .{});
    ui.clip(body);
    const bpb: f32 = @floatFromInt(v.beats_per_bar);
    if (loop) |lp| {
        const x0 = v.x(body, lp[0]);
        const x1 = v.x(body, lp[1]);
        ui.rect(Rect.xywh(x0, body.bottom() - 5, x1 - x0, 5), style.accent.alpha(70));
        ui.rect(Rect.xywh(x0, body.bottom() - 5, x1 - x0, 1), style.accent);
        ui.rect(Rect.xywh(x0, body.bottom() - 5, 1, 5), style.accent);
        ui.rect(Rect.xywh(x1 - 1, body.bottom() - 5, 1, 5), style.accent);
    }
    var t = @floor(v.start);
    while (t < v.end(body)) : (t += 1) {
        const xx = v.x(body, t);
        const is_bar = @mod(t, bpb) < 0.001;
        const h: i32 = if (is_bar) 7 else 3;
        ui.rect(Rect.xywh(xx, body.bottom() - h, 1, h), if (is_bar) style.text_dim else style.text_mute);
        if (is_bar) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{@as(u32, @intFromFloat(t / bpb)) + 1}) catch "";
            _ = ui.engraved(&ui.fonts.legend, xx + 3, body.y, s, style.text_dim);
        }
    }
    // Playhead: a down-pointing marker on the ruler, the line continues
    // down the lanes (drawn by the lane owner with `playhead`).
    const hx = v.x(body, head);
    ctl.led(ui, hx - 3, body.bottom() - 4, .tri_down, .on, style.accent);
    ui.unclip();
}

// ── Arrangement ──────────────────────────────────────────────────────

pub const TrackUi = struct {
    name: []const u8,
    color: Color,
    mute: bool = false,
    solo: bool = false,
    arm: bool = false,
    volume: f32 = 0.75,
    level: f32 = 0,
    selected: bool = false,
};

/// Track header faceplate: colour bar, name, S/M/R, volume, meter.
/// Height is the lane height; two rows of 20 at the standard lane.
pub fn trackHeader(ui: *Ui, r: Rect, key: anytype, t: *TrackUi) void {
    ui.pushId(key);
    defer ui.popId();
    var body = ui.plate(r, .{ .fill = if (t.selected) style.face.shade(8) else style.face });
    // Identity bar (full lane height, left edge).
    ui.rect(Rect.xywh(body.x - 1, body.y - 1, 3, body.h + 1), t.color);
    _ = body.cutLeft(4);
    // Meter on the far right.
    const meter = body.cutRight(6);
    ctl.meter(ui, meter, "meter", t.level, t.level * 0.6, .{ .scale = .none });
    _ = body.cutRight(3);
    var row1 = body.cutTop(20);
    var buttons = row1.cutRight(3 * 17);
    _ = ctl.button(ui, buttons.cutLeft(17).insetXY(0, 2), "r", &t.arm, .{ .kind = .latch, .label = "R", .lit = style.rec });
    _ = ctl.button(ui, buttons.cutLeft(17).insetXY(0, 2), "m", &t.mute, .{ .kind = .latch, .label = "M", .lit = style.led_blue });
    _ = ctl.button(ui, buttons.insetXY(0, 2), "s", &t.solo, .{ .kind = .latch, .label = "S", .lit = style.led_yellow });
    ui.textIn(&ui.fonts.body, row1, t.name, if (t.selected) style.text else style.text_dim, .left, true);
    _ = ctl.slider(ui, body.takeTop(18), "vol", &t.volume, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 5, .default = 0.75 });
}

pub const MiniNote = struct { beat: f32, len: f32, pitch: u8, vel: f32 = 0.8 };

/// A clip on a lane: full-colour name band, tinted body with a note
/// preview, 1px darker edge; amber outline when selected.
pub fn clip(ui: *Ui, r: Rect, v: TimeView, start: f32, len: f32, name: []const u8, col: Color, notes: []const MiniNote, selected: bool) void {
    const x0 = v.x(r, start);
    const x1 = v.x(r, start + len);
    const cr = Rect.xywh(x0, r.y + 1, x1 - x0, r.h - 1);
    if (cr.right() <= r.x or cr.x >= r.right()) return;
    ui.clip(r);
    defer ui.unclip();
    const edge = col.mix(style.chassis, 0.6);
    ui.rect(cr, edge);
    const inner = cr.inset(1);
    var body = inner;
    const band = body.cutTop(12);
    ui.rect(band, col);
    ui.rect(body, col.mix(style.pane, 0.72));
    ui.clip(band);
    _ = ui.text(&ui.fonts.legend, band.x + 3, band.y, name, style.chassis);
    ui.unclip();
    // Note preview: pitch range fitted to the body.
    if (notes.len > 0) {
        var lo: u8 = 127;
        var hi: u8 = 0;
        for (notes) |n| {
            lo = @min(lo, n.pitch);
            hi = @max(hi, n.pitch);
        }
        const span: i32 = @max(1, @as(i32, hi) - @as(i32, lo) + 1);
        const nh: i32 = @max(1, @min(3, @divFloor(body.h - 4, span)));
        const note_col = col.mix(style.text, 0.35);
        for (notes) |n| {
            const nx0 = v.x(r, start + n.beat);
            const nx1 = v.x(r, start + n.beat + n.len);
            const ny = body.bottom() - 2 - nh - @divFloor((@as(i32, n.pitch) - lo) * (body.h - 4 - nh), @max(1, span - 1));
            ui.rect(Rect.xywh(nx0, ny, @max(1, nx1 - nx0 - 1), nh), note_col);
        }
    }
    if (selected) ui.bevel(cr, style.accent, style.accent);
}

/// Automation lane: a breakpoint line over flat glass. Points are
/// (beat, 0..1) pairs.
pub fn automation(ui: *Ui, r: Rect, v: TimeView, pts: []const [2]f32, col: Color) void {
    ui.clip(r);
    defer ui.unclip();
    const h: f32 = @floatFromInt(r.h - 4);
    const y0: f32 = @floatFromInt(r.y + 2);
    for (pts, 0..) |p, i| {
        const xx: f32 = @floatFromInt(v.x(r, p[0]));
        const yy = y0 + h * (1 - p[1]);
        if (i > 0) {
            const q = pts[i - 1];
            ui.line(@as(f32, @floatFromInt(v.x(r, q[0]))) + 0.5, y0 + h * (1 - q[1]) + 0.5, xx + 0.5, yy + 0.5, col);
        }
        const ix: i32 = @intFromFloat(xx);
        const iy: i32 = @intFromFloat(yy);
        ui.rect(Rect.xywh(ix - 1, iy - 1, 3, 3), col);
        ui.rect(Rect.xywh(ix, iy, 1, 1), style.chassis);
    }
}

// ── Piano roll ───────────────────────────────────────────────────────

pub const PitchView = struct {
    /// Pitch at the top row.
    top: u8 = 72,
    row_h: i32 = 10,

    pub fn y(p: PitchView, r: Rect, pitch: u8) i32 {
        return r.y + (@as(i32, p.top) - @as(i32, pitch)) * p.row_h;
    }

    pub fn rows(p: PitchView, r: Rect) i32 {
        return @divFloor(r.h + p.row_h - 1, p.row_h);
    }
};

fn isBlack(pitch: u8) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

/// Key column: one row per semitone, black keys as 62%-wide dark bars
/// over the white bed, octave labels on the Cs.
pub fn pianoKeys(ui: *Ui, r: Rect, p: PitchView) void {
    const body = ui.plate(r, .{});
    ui.clip(body);
    defer ui.unclip();
    ui.rect(body, style.key_white);
    const bw = @divFloor(body.w * 62, 100);
    var i: i32 = 0;
    while (i < p.rows(body)) : (i += 1) {
        const pitch_i = @as(i32, p.top) - i;
        if (pitch_i < 0) break;
        const pitch: u8 = @intCast(pitch_i);
        const yy = p.y(body, pitch);
        if (isBlack(pitch)) {
            ui.rect(Rect.xywh(body.x, yy, bw, p.row_h), style.key_black);
            ui.rect(Rect.xywh(body.x, yy, bw, 1), style.key_black.shade(30));
            // White-key seam behind the black key's middle.
            ui.rect(Rect.xywh(body.x + bw, yy + @divFloor(p.row_h, 2), body.w - bw, 1), style.key_white.shade(-50));
        } else {
            const n = pitch % 12;
            // Adjacent white keys (E|F, B|C) meet on a row boundary.
            if (n == 4 or n == 11) ui.rect(Rect.xywh(body.x, yy, body.w, 1), style.key_white.shade(-50));
            if (n == 0) {
                var buf: [6]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "C{d}", .{@as(i32, pitch / 12) - 2}) catch "";
                const w = ui.fonts.legend.measure(s);
                _ = ui.text(&ui.fonts.legend, body.right() - w - 2, yy + @divFloor(p.row_h - 12, 2), s, style.text_mute.shade(-30));
                ui.rect(Rect.xywh(body.x, yy + p.row_h - 1, body.w, 1), style.key_white.shade(-70));
            }
        }
    }
}

/// Note grid behind the notes: black-key rows darker, octave lines on B|C.
pub fn noteGrid(ui: *Ui, r: Rect, v: TimeView, p: PitchView) void {
    timeGrid(ui, r, v, style.pane_alt);
    ui.clip(r);
    defer ui.unclip();
    var i: i32 = 0;
    while (i < p.rows(r)) : (i += 1) {
        const pitch_i = @as(i32, p.top) - i;
        if (pitch_i < 0) break;
        const pitch: u8 = @intCast(pitch_i);
        const yy = p.y(r, pitch);
        if (isBlack(pitch)) ui.rect(Rect.xywh(r.x, yy, r.w, p.row_h), style.chassis.alpha(90));
        if (pitch % 12 == 0) ui.rect(Rect.xywh(r.x, yy + p.row_h - 1, r.w, 1), style.grid_bar);
    }
}

/// One note: body brightness follows velocity; amber outline when
/// selected.
pub fn note(ui: *Ui, r: Rect, v: TimeView, p: PitchView, n: MiniNote, col: Color, selected: bool) void {
    const x0 = v.x(r, n.beat);
    const x1 = v.x(r, n.beat + n.len);
    const nr = Rect.xywh(x0, p.y(r, n.pitch), @max(2, x1 - x0), p.row_h);
    const fill = col.mix(style.pane, 0.55 * (1 - n.vel));
    ui.rect(nr, col.mix(style.chassis, 0.55));
    ui.rect(nr.inset(1), fill);
    ui.rect(Rect.xywh(nr.x + 1, nr.y + 1, nr.w - 2, 1), fill.mix(style.text, 0.35));
    if (selected) ui.bevel(nr, style.accent, style.accent);
}

/// Velocity lane: a stem per note, height = velocity, lit cap on top.
pub fn velocityLane(ui: *Ui, r: Rect, v: TimeView, notes: []const MiniNote, col: Color) void {
    timeGrid(ui, r, v, style.pane);
    ui.clip(r);
    defer ui.unclip();
    const h = r.h - 3;
    for (notes) |n| {
        const xx = v.x(r, n.beat);
        const vh: i32 = @intFromFloat(@round(n.vel * @as(f32, @floatFromInt(h))));
        ui.rect(Rect.xywh(xx, r.bottom() - vh, 3, vh), col.mix(style.pane, 0.5));
        ui.rect(Rect.xywh(xx, r.bottom() - vh, 3, 2), col);
    }
}
