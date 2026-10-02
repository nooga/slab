//! The wavetable editor (docs/15 §Wavetable editor): a table's frames in
//! a strip, the selected frame large to draw on, its harmonics to paint,
//! and the tools that fill, process, add and morph frames. It edits a
//! wavetable_edit.Doc; the owner takes the doc's dirty range each frame
//! and rebuilds what the oscillator plays. Concoction opens it from an
//! oscillator's view; the gallery's CONCOCTION page prototypes it.

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const c = @import("../c.zig");
const wte = @import("../wavetable_edit.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;
const Doc = wte.Doc;

const TOOLS = [_][]const u8{ "DRAW", "LINE", "STEP" };
const GRIDS = [_][]const u8{ "OFF", "4", "8", "16", "32", "64" };
const GRID_N = [_]u16{ 0, 4, 8, 16, 32, 64 };
const COUNTS = [_][]const u8{ "1", "2", "4", "8", "16", "32", "64", "128", "256" };
const SHAPES = [_][]const u8{ "SINE", "TRI", "SAW", "SQR", "NOISE" };
const OPS = [_][]const u8{ "NORM", "DC", "INV", "REV", "SMTH" };
const SCOPES = [_][]const u8{ "FRAME", "ALL" };
const MORPHS = [_][]const u8{ "XFADE", "SPECTRAL" };

/// Harmonics shown and painted.
pub const BARS = 64;
/// The harmonic bars' floor, dB under full scale.
const FLOOR_DB: f32 = 60;
/// Levels a gridded pen snaps to: eighths.
const Y_STEPS: f32 = 8;

const THUMB_W: i32 = 40;
const HEAD_H: i32 = 20;
const STRIP_H: i32 = 66;
const TOOLS_H: i32 = 44;
const HARM_W: i32 = BARS * 6 + 20;

/// What the editor remembers between frames: its tool settings, the
/// gesture in progress, the strip's scroll and the selected frame's
/// harmonics.
pub const View = struct {
    tool: u8 = 0,
    grid: u8 = 0,
    scope: u8 = 0,
    morph: u8 = 1,
    count: u8 = 4,
    /// First frame the strip shows.
    scroll: usize = 0,
    follow_sel: usize = std.math.maxInt(usize),
    // The pen: where the drag is, and where a LINE started.
    last: [2]f32 = .{ 0, 0 },
    anchor: [2]f32 = .{ 0, 0 },
    // The harmonics pen: the bar it last painted.
    last_bar: i32 = -1,
    last_amp: f32 = 0,
    // The selected frame's harmonics, for the doc version they were read at.
    cached: u64 = std.math.maxInt(u64),
    cached_sel: usize = 0,
    mag: [BARS]f32 = undefined,
    ph: [BARS]f32 = undefined,
};

pub const Opts = struct {
    /// Caption: which oscillator, which table.
    name: []const u8 = "",
    /// Offer SAVE (write the table to a file).
    can_save: bool = false,
};

pub const Result = struct { done: bool = false, save: bool = false };

pub fn editor(ui: *Ui, r: Rect, doc: *Doc, v: *View, o: Opts) Result {
    ui.pushId("wted");
    defer ui.popId();
    var res = Result{};
    var area = r;

    var head = area.cutTop(HEAD_H);
    if (ctl.button(ui, head.cutRight(56), "done", null, .{ .label = "DONE", .flush = true })) res.done = true;
    if (o.can_save) {
        if (ctl.button(ui, head.cutRight(56), "save", null, .{ .label = "SAVE", .flush = true })) res.save = true;
    }
    if (ctl.button(ui, head.cutRight(56), "redo", null, .{ .label = "REDO", .flush = true, .disabled = !doc.canRedo() })) doc.redo();
    if (ctl.button(ui, head.cutRight(56), "undo", null, .{ .label = "UNDO", .flush = true, .disabled = !doc.canUndo() })) doc.undo();
    ctl.titleStrip(ui, head, "WAVETABLE", o.name);

    frameStrip(ui, area.cutTop(STRIP_H), doc, v);
    tools(ui, area.cutBottom(TOOLS_H), doc, v);
    var main = area;
    harmonics(ui, main.cutRight(HARM_W), doc, v);
    wave(ui, main, doc, v);
    return res;
}

// ── Frame strip ──────────────────────────────────────────────────────

fn frameStrip(ui: *Ui, r: Rect, doc: *Doc, v: *View) void {
    var body = ctl.strip(ui, r, "FRAMES");
    body = body.insetXY(4, 0);
    _ = body.cutBottom(3);

    // Count, then the frame buttons, on the right.
    var side = body.cutRight(4 * 44 + 56);
    v.count = countIndex(doc.count, v.count);
    const before = v.count;
    _ = ctl.displayField(ui, side.cutLeft(52), "count", &v.count, &COUNTS, "COUNT");
    if (v.count != before) {
        doc.checkpoint();
        doc.resize(@as(usize, 1) << @intCast(v.count));
    }
    _ = side.cutLeft(4);
    const by = side.y + ctl.LEGEND_H;
    ui.textIn(&ui.fonts.legend, Rect.xywh(side.x, side.y, 4 * 44, ctl.LEGEND_H), "FRAME", style.text_dim, .center, true);
    if (ctl.button(ui, Rect.xywh(side.x, by, 44, 20), "dup", null, .{ .label = "DUP", .disabled = doc.count == wte.MAX_FRAMES })) {
        doc.checkpoint();
        doc.duplicate(doc.sel);
    }
    if (ctl.button(ui, Rect.xywh(side.x + 44, by, 44, 20), "del", null, .{ .label = "DEL", .disabled = doc.count == 1 })) {
        doc.checkpoint();
        doc.remove(doc.sel);
    }
    var key = doc.isKey(doc.sel);
    const fixed = doc.sel == 0 or doc.sel + 1 == doc.count;
    if (ctl.button(ui, Rect.xywh(side.x + 88, by, 44, 20), "key", &key, .{ .label = "KEY", .kind = .latch, .led = style.led_amber, .disabled = fixed })) {
        doc.toggleKey(doc.sel);
    }
    if (ctl.button(ui, Rect.xywh(side.x + 132, by, 44, 20), "morph", null, .{ .label = "MORPH", .disabled = doc.count < 3 })) {
        doc.checkpoint();
        doc.morph(if (v.morph == 0) .crossfade else .spectral);
    }
    _ = body.cutRight(4);

    const well = ui.well(body, style.well);
    const fit: usize = @intCast(@max(1, @divFloor(well.w, THUMB_W + 1)));
    // Keep the selected frame in view when it moves; the wheel scrolls.
    if (doc.sel != v.follow_sel) {
        if (doc.sel < v.scroll) v.scroll = doc.sel;
        if (doc.sel >= v.scroll + fit) v.scroll = doc.sel + 1 - fit;
        v.follow_sel = doc.sel;
    }
    if (well.contains(ui.in.ix(), ui.in.iy())) {
        const w = ui.in.wheel_y + ui.in.wheel_x;
        if (w < 0) v.scroll += 1;
        if (w > 0 and v.scroll > 0) v.scroll -= 1;
    }
    v.scroll = @min(v.scroll, doc.count -| fit);

    ui.clip(well);
    defer ui.unclip();
    var f = v.scroll;
    var x = well.x + 1;
    while (f < doc.count and x < well.right()) : (f += 1) {
        thumb(ui, Rect.xywh(x, well.y + 1, THUMB_W, well.h - 2), doc, f);
        x += THUMB_W + 1;
    }
    if (doc.count > fit) {
        // Where the view sits in the table.
        const track = Rect.xywh(well.x, well.bottom() - 2, well.w, 2);
        const tw: f32 = @floatFromInt(track.w);
        const n: f32 = @floatFromInt(doc.count);
        const x0: i32 = @intFromFloat(tw * @as(f32, @floatFromInt(v.scroll)) / n);
        const x1: i32 = @intFromFloat(tw * @as(f32, @floatFromInt(v.scroll + fit)) / n);
        ui.rect(Rect.xywh(track.x + x0, track.y, @max(2, x1 - x0), 2), style.text_mute);
    }
}

fn countIndex(count: usize, cur: u8) u8 {
    if (count == @as(usize, 1) << @intCast(cur)) return cur;
    var i: u8 = 0;
    while (i + 1 < COUNTS.len and (@as(usize, 1) << @intCast(i + 1)) <= count) i += 1;
    return i;
}

/// One frame: its cycle, its number, a key mark; click selects it,
/// double-click makes it a key.
fn thumb(ui: *Ui, r: Rect, doc: *Doc, f: usize) void {
    const wid = ui.id(.{ "thumb", f });
    const b = ui.behaviorEx(wid, r, .{ .focusable = false });
    if (b.pressed) {
        doc.sel = f;
        if (b.double) doc.toggleKey(f);
    }
    const sel = doc.sel == f;
    const hot = ui.isHot(wid);
    ui.rect(r, if (sel) style.vfd.alpha(36) else if (hot) style.pane else style.well);
    if (sel) ui.bevel(r, style.vfd, style.vfd);
    const pen = if (sel) style.vfd_hi else style.vfd.alpha(150);
    const wave_r = Rect.xywh(r.x + 2, r.y + 12, r.w - 4, r.h - 14);
    const mid: f32 = @as(f32, @floatFromInt(wave_r.y)) + @as(f32, @floatFromInt(wave_r.h)) / 2;
    const amp: f32 = @as(f32, @floatFromInt(wave_r.h)) / 2 - 1;
    const data = doc.frameConst(f);
    const n: usize = @intCast(wave_r.w);
    var prev: [2]f32 = undefined;
    for (0..n + 1) |i| {
        const k = @min(i * wte.N / n, wte.N - 1);
        const pt = [2]f32{ @as(f32, @floatFromInt(wave_r.x)) + @as(f32, @floatFromInt(i)), mid - data[k] * amp };
        if (i > 0) ui.line(prev[0], prev[1], pt[0], pt[1], pen);
        prev = pt;
    }
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f + 1}) catch "";
    const nx = ui.text(&ui.fonts.legend, r.x + 3, r.y + 1, s, if (sel) style.vfd_hi else style.text_mute);
    if (doc.isKey(f)) keyMark(ui, r.x + 3 + nx + 3, r.y + 4, if (doc.keys.isSet(f)) style.accent else style.text_mute);
}

/// A 5×5 diamond: a keyframe.
fn keyMark(ui: *Ui, x: i32, y: i32, col: Color) void {
    const rows = [_][2]i32{ .{ 2, 1 }, .{ 1, 3 }, .{ 0, 5 }, .{ 1, 3 }, .{ 2, 1 } };
    for (rows, 0..) |row, i| ui.rect(Rect.xywh(x + row[0], y + @as(i32, @intCast(i)), row[1], 1), col);
}

// ── The wave ─────────────────────────────────────────────────────────

const Plot = struct {
    r: Rect,
    fn x(p: Plot, t: f32) f32 {
        return @as(f32, @floatFromInt(p.r.x)) + t * @as(f32, @floatFromInt(p.r.w - 1));
    }
    fn y(p: Plot, val: f32) f32 {
        return p.mid() - val * p.amp();
    }
    fn mid(p: Plot) f32 {
        return @as(f32, @floatFromInt(p.r.y)) + @as(f32, @floatFromInt(p.r.h)) / 2;
    }
    fn amp(p: Plot) f32 {
        return @as(f32, @floatFromInt(p.r.h)) / 2 - 4;
    }
    /// The pointer as (phase, level).
    fn at(p: Plot, ui: *const Ui) [2]f32 {
        const t = (ui.in.mx - @as(f32, @floatFromInt(p.r.x))) / @as(f32, @floatFromInt(p.r.w - 1));
        const val = (p.mid() - ui.in.my) / p.amp();
        return .{ std.math.clamp(t, 0, 1), std.math.clamp(val, -1, 1) };
    }
};

fn wave(ui: *Ui, r: Rect, doc: *Doc, v: *View) void {
    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "FRAME {d}/{d}", .{ doc.sel + 1, doc.count }) catch "";
    var body = ctl.strip(ui, r, title);
    body = body.insetXY(4, 0);
    _ = body.cutBottom(4);
    const inner = ui.well(body, style.well);
    const p = Plot{ .r = inner.insetXY(4, 0) };
    const grid = GRID_N[v.grid];

    // The pen.
    const wid = ui.id("pen");
    const b = ui.behaviorEx(wid, inner, .{ .focusable = false });
    const over = inner.contains(ui.in.ix(), ui.in.iy());
    if (over or b.held) ui.requestCursor(c.rl.MOUSE_CURSOR_CROSSHAIR, 1);
    var pt = p.at(ui);
    if (grid > 0) pt = snap(pt, grid, v.tool == 1);
    if (b.pressed) {
        doc.checkpoint();
        v.anchor = pt;
        v.last = pt;
        penStroke(doc, v, pt, grid);
    } else if (b.held and v.tool != 1) {
        penStroke(doc, v, pt, grid);
    }
    if (b.released and v.tool == 1) doc.drawLine(doc.sel, v.anchor[0], v.anchor[1], pt[0], pt[1]);

    ui.clip(inner);
    defer ui.unclip();
    // Grid: the center line, quarter levels, and the pen's grid.
    ui.rect(Rect.xywh(inner.x, @intFromFloat(p.mid()), inner.w, 1), style.vfd.alpha(40));
    for ([_]f32{ -1, -0.5, 0.5, 1 }) |lv| ui.rect(Rect.xywh(inner.x, @intFromFloat(p.y(lv)), inner.w, 1), style.vfd.alpha(14));
    if (grid > 0) {
        for (1..grid) |g| {
            const gx: i32 = @intFromFloat(p.x(@as(f32, @floatFromInt(g)) / @as(f32, @floatFromInt(grid))));
            ui.rect(Rect.xywh(gx, inner.y, 1, inner.h), style.vfd.alpha(if (g * 4 % grid == 0) 26 else 12));
        }
    }
    // The neighbours, faint: what the frame morphs from and to.
    if (doc.sel > 0) curve(ui, p, doc.frameConst(doc.sel - 1), style.mod.alpha(70), false);
    if (doc.sel + 1 < doc.count) curve(ui, p, doc.frameConst(doc.sel + 1), style.text_mute.alpha(90), false);
    curve(ui, p, doc.frameConst(doc.sel), style.vfd_hi, true);
    if (b.held and v.tool == 1) ui.line(p.x(v.anchor[0]), p.y(v.anchor[1]), p.x(pt[0]), p.y(pt[1]), style.accent);

    if (over or b.held) {
        ui.rect(Rect.xywh(@intFromFloat(p.x(pt[0])), inner.y, 1, inner.h), style.vfd.alpha(30));
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:0>4} {s}{d:.2}", .{ @as(u32, @intFromFloat(@round(pt[0] * (wte.N - 1)))), if (pt[1] >= 0) "+" else "", pt[1] }) catch "";
        ui.textIn(&ui.fonts.legend, Rect.xywh(inner.x, inner.y + 2, inner.w - 4, 12), s, style.vfd.alpha(200), .right, false);
    }
    const tip = switch (v.tool) {
        0 => "DRAW: DRAG TO PAINT",
        1 => "LINE: DRAG FROM START TO END",
        else => if (grid > 0) "STEP: ONE LEVEL PER GRID CELL" else "STEP: SET A GRID",
    };
    ui.textIn(&ui.fonts.legend, Rect.xywh(inner.x + 4, inner.y + 2, inner.w, 12), tip, style.vfd.alpha(90), .left, false);
}

fn penStroke(doc: *Doc, v: *View, pt: [2]f32, grid: u16) void {
    if (v.tool == 2 and grid > 0) {
        const gn: f32 = @floatFromInt(grid);
        // Every cell the pointer crossed since last frame takes the level.
        const c0 = @min(@floor(v.last[0] * gn), gn - 1);
        const c1 = @min(@floor(pt[0] * gn), gn - 1);
        var cl = @min(c0, c1);
        while (cl <= @max(c0, c1)) : (cl += 1) doc.fillStep(doc.sel, cl / gn, (cl + 1) / gn - 1.0 / @as(f32, wte.N), pt[1]);
    } else {
        doc.drawLine(doc.sel, v.last[0], v.last[1], pt[0], pt[1]);
    }
    v.last = pt;
}

/// The pen on the grid: levels to eighths, and a LINE's ends to the
/// grid's columns.
fn snap(pt: [2]f32, grid: u16, columns: bool) [2]f32 {
    var out = pt;
    out[1] = @round(pt[1] * Y_STEPS) / Y_STEPS;
    if (columns) {
        const gn: f32 = @floatFromInt(grid);
        out[0] = @round(pt[0] * gn) / gn;
    }
    return out;
}

/// A cycle across the plot, one point a pixel; `fill` shades it down to
/// the center line.
fn curve(ui: *Ui, p: Plot, data: []const f32, col: Color, fill: bool) void {
    // One point a pixel column, so the fill has no gaps.
    const n: usize = @intCast(@max(p.r.w, 2));
    const mid = p.mid();
    var prev: [2]f32 = undefined;
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
        const k = @min(@as(usize, @intFromFloat(@round(t * (wte.N - 1)))), wte.N - 1);
        const ix = p.r.x + @as(i32, @intCast(i));
        const pt = [2]f32{ @floatFromInt(ix), p.y(data[k]) };
        if (fill) {
            const y0: i32 = @intFromFloat(@min(pt[1], mid));
            const y1: i32 = @intFromFloat(@max(pt[1], mid));
            ui.rect(Rect.xywh(ix, y0, 1, @max(1, y1 - y0)), style.vfd.alpha(34));
        }
        if (i > 0) ui.line(prev[0], prev[1], pt[0], pt[1], col);
        prev = pt;
    }
}

// ── Harmonics ────────────────────────────────────────────────────────

fn harmonics(ui: *Ui, r: Rect, doc: *Doc, v: *View) void {
    var body = ctl.strip(ui, r, "HARMONICS");
    body = body.insetXY(4, 0);
    _ = body.cutBottom(4);
    const inner = ui.well(body, style.well);
    var area = inner.insetXY(4, 3);
    const scale = area.cutBottom(12);
    if (v.cached != doc.version or v.cached_sel != doc.sel) {
        doc.harmonics(doc.sel, &v.mag, &v.ph);
        v.cached = doc.version;
        v.cached_sel = doc.sel;
    }

    // The pen: drag across the bars to set their levels.
    const wid = ui.id("bars");
    const b = ui.behaviorEx(wid, inner, .{ .focusable = false });
    const fh: f32 = @floatFromInt(area.h);
    const bar_at = struct {
        fn f(a: Rect, mx: f32) i32 {
            return std.math.clamp(@as(i32, @intFromFloat(@floor((mx - @as(f32, @floatFromInt(a.x))) / 6))), 0, BARS - 1);
        }
    }.f;
    const amp_at = (@as(f32, @floatFromInt(area.bottom())) - ui.in.my) / fh;
    const amp = levelAmp(std.math.clamp(amp_at, 0, 1));
    const bar = bar_at(area, ui.in.mx);
    if (b.pressed) {
        doc.checkpoint();
        v.last_bar = bar;
        v.last_amp = amp;
        if (b.double) doc.setHarmonic(doc.sel, @intCast(bar + 1), 0) else doc.setHarmonic(doc.sel, @intCast(bar + 1), amp);
    } else if (b.held and (bar != v.last_bar or amp != v.last_amp)) {
        // Every bar between last frame's and this one, the level ramped.
        const lo = @min(bar, v.last_bar);
        const hi = @max(bar, v.last_bar);
        var k = lo;
        while (k <= hi) : (k += 1) {
            const t: f32 = if (hi > lo) @as(f32, @floatFromInt(k - v.last_bar)) / @as(f32, @floatFromInt(bar - v.last_bar)) else 1;
            doc.setHarmonic(doc.sel, @intCast(k + 1), v.last_amp + (amp - v.last_amp) * t);
        }
        v.last_bar = bar;
        v.last_amp = amp;
    }

    // Level lines every 12 dB, then the bars.
    var db: f32 = 0;
    while (db < FLOOR_DB) : (db += 12) {
        const ly = area.y + @as(i32, @intFromFloat(@round(db / FLOOR_DB * fh)));
        ui.rect(Rect.xywh(area.x, ly, area.w, 1), style.vfd.alpha(14));
    }
    const hover = inner.contains(ui.in.ix(), ui.in.iy()) or b.held;
    for (0..BARS) |i| {
        const bx = area.x + @as(i32, @intCast(i)) * 6;
        const lvl = ampLevel(v.mag[i]);
        const bh: i32 = @intFromFloat(@round(lvl * fh));
        const is_hot = hover and i == bar;
        ui.rect(Rect.xywh(bx, area.y, 5, area.h), if (is_hot) style.vfd.alpha(30) else style.vfd.alpha(10));
        if (bh > 0) ui.rect(Rect.xywh(bx, area.bottom() - bh, 5, bh), if (is_hot) style.vfd_hi else style.vfd.alpha(if (i % 8 == 0) 230 else 190));
    }
    // Harmonic numbers under every eighth bar.
    var h: usize = 1;
    while (h <= BARS) : (h += 8) {
        var buf: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{h}) catch "";
        _ = ui.text(&ui.fonts.legend, area.x + @as(i32, @intCast(h - 1)) * 6, scale.y + 1, s, style.text_mute);
    }
    if (hover) {
        var buf: [24]u8 = undefined;
        const m = v.mag[@intCast(bar)];
        const s = if (m < 1e-4)
            std.fmt.bufPrint(&buf, "H{d} OFF", .{bar + 1}) catch ""
        else
            std.fmt.bufPrint(&buf, "H{d} {d:.1}DB", .{ bar + 1, 20 * std.math.log10(m) }) catch "";
        ui.textIn(&ui.fonts.legend, Rect.xywh(area.x, area.y, area.w, 12), s, style.vfd_hi, .right, false);
    }
}

/// A harmonic's amplitude as a bar height 0..1 (−60..0 dB).
fn ampLevel(a: f32) f32 {
    if (a < 1e-6) return 0;
    return std.math.clamp(1 + 20 * std.math.log10(a) / FLOOR_DB, 0, 1);
}

/// A bar height back to an amplitude; the bottom pixel row is silence.
fn levelAmp(l: f32) f32 {
    if (l < 0.02) return 0;
    return std.math.pow(f32, 10, (l - 1) * FLOOR_DB / 20);
}

// ── Tools ────────────────────────────────────────────────────────────

fn tools(ui: *Ui, r: Rect, doc: *Doc, v: *View) void {
    var row = ui.plate(r, .{}).insetXY(6, 3);
    _ = ctl.segmented(ui, labeled(ui, &row, "PEN", TOOLS.len * 44), "tool", &v.tool, &TOOLS);
    _ = row.cutLeft(8);
    _ = ctl.displayField(ui, row.cutLeft(52), "grid", &v.grid, &GRIDS, "GRID");
    _ = row.cutLeft(20);
    _ = ctl.segmented(ui, labeled(ui, &row, "APPLY TO", SCOPES.len * 48), "scope", &v.scope, &SCOPES);
    _ = row.cutLeft(8);
    if (buttons(ui, labeled(ui, &row, "FILL", SHAPES.len * 44), "shape", &SHAPES)) |i| {
        doc.checkpoint();
        const shape: wte.Shape = @enumFromInt(i);
        if (v.scope == 0) doc.setShape(doc.sel, shape) else for (0..doc.count) |f| doc.setShape(f, shape);
    }
    _ = row.cutLeft(8);
    if (buttons(ui, labeled(ui, &row, "PROCESS", OPS.len * 44), "op", &OPS)) |i| {
        doc.checkpoint();
        const op: wte.Op = @enumFromInt(i);
        if (v.scope == 0) doc.apply(doc.sel, op) else doc.applyAll(op);
    }
    _ = row.cutLeft(20);
    _ = ctl.segmented(ui, labeled(ui, &row, "MORPH BY", MORPHS.len * 64), "morph_mode", &v.morph, &MORPHS);
}

/// The next `w` pixels of the row: a legend, and the 20 px control
/// under it.
fn labeled(ui: *Ui, row: *Rect, legend: []const u8, w: i32) Rect {
    const cell = row.cutLeft(w);
    ui.textIn(&ui.fonts.legend, cell.takeTop(ctl.LEGEND_H), legend, style.text_dim, .center, true);
    return Rect.xywh(cell.x, cell.y + ctl.LEGEND_H, w, 20);
}

/// Joined momentary caps; the one clicked.
fn buttons(ui: *Ui, r: Rect, key: anytype, labels: []const []const u8) ?usize {
    ui.pushId(key);
    defer ui.popId();
    var out: ?usize = null;
    const n: i32 = @intCast(labels.len);
    for (labels, 0..) |lab, i| {
        const cell = r.cell(n, 1, @intCast(i), 0);
        const cr = if (i == 0) cell else Rect.xywh(cell.x - 1, cell.y, cell.w + 1, cell.h);
        if (ctl.button(ui, cr, i, null, .{ .label = lab })) out = i;
    }
    return out;
}
