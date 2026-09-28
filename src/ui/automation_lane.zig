//! One automation lane on a working surface (docs/22 §Editing curves):
//! draws a lane's curve and handles its point, segment and tension
//! gestures. Written against the pane pointer (float rects, explicit drag
//! keys) like the arrangement and piano roll, and shared by every surface
//! that shows a lane.

const std = @import("std");
const c = @import("../c.zig");
const pane = @import("pane_input.zig");
const menu = @import("menu.zig");
const ui_core = @import("core.zig");
const ui_style = @import("style.zig");
const snap_mod = @import("snap.zig");
const automation = @import("../automation.zig");
const text_field = @import("text_field.zig");

const Ui = ui_core.Ui;
const Rect = ui_core.Rect;
const Color = ui_style.Color;
const Lane = automation.Lane;
const Point = automation.Point;

/// Formats a knob-space value in the target's units ("1.25 kHz").
pub const Formatter = struct {
    ctx: *const anyopaque,
    f: *const fn (ctx: *const anyopaque, knob: f32, buf: []u8) []const u8,
    /// The inverse, for Enter value…: typed text in the same units → knob.
    parse: ?*const fn (ctx: *const anyopaque, text: []const u8) ?f32 = null,

    fn format(self: Formatter, knob: f32, buf: []u8) []const u8 {
        return self.f(self.ctx, knob, buf);
    }
};

pub const View = struct {
    rect: pane.FRect,
    /// Beat ↔ x: x = timeline_x0 + beat * px_per_beat - scroll_x.
    timeline_x0: f32,
    scroll_x: f32,
    px_per_beat: f32,
    edit_snap: snap_mod.Setting,
    color: Color,
    /// Value range drawn bottom to top (0..1, or a stepped control's raw range).
    lo: f32 = 0,
    hi: f32 = 1,
    /// Unique per lane: drag key and menu key.
    key: u64,
    name: []const u8 = "",
    fmt: ?Formatter = null,
    selected: bool = false,
};

pub const Result = struct {
    /// Points changed this frame.
    edited: bool = false,
    /// A press landed in the lane (callers clear other selections).
    pressed: bool = false,
};

const HIT: f32 = 4;
const PAD_TOP: f32 = 3;
const PAD_BOT: f32 = 4;
const MAX_DRAG: usize = 4096;
const MAX_DRAW: usize = 2048;

const Mode = enum { none, move, segment, bend, box, draw };

var mode: Mode = .none;
var drag_lane: u64 = 0;
var start_x: f32 = 0;
var start_y: f32 = 0;
var seg: usize = 0;
var orig: [MAX_DRAG]Point = undefined;
var orig_n: usize = 0;
var draw_xs: [MAX_DRAW]f32 = undefined;
var draw_ys: [MAX_DRAW]f32 = undefined;
var draw_n: usize = 0;
/// The point a context menu acts on.
var menu_point: usize = 0;
/// Enter value…: a typed value for one point.
var entry_lane: u64 = 0;
var entry_point: usize = 0;
var entry_focus = false;
var entry_tb: text_field.TextBuf = .{ .limit = 24 };

/// A typed value is being entered (the host holds its key shortcuts).
pub fn entryActive() bool {
    return entry_lane != 0;
}

// ── Mapping ──────────────────────────────────────────────────────────

fn xOf(v: *const View, beat: f64) f32 {
    return v.timeline_x0 + @as(f32, @floatCast(beat)) * v.px_per_beat - v.scroll_x;
}

fn beatOf(v: *const View, x: f32) f64 {
    return @as(f64, (x - v.timeline_x0 + v.scroll_x) / v.px_per_beat);
}

fn innerH(v: *const View) f32 {
    return @max(1, v.rect.height - PAD_TOP - PAD_BOT);
}

fn yOf(v: *const View, value: f32) f32 {
    const span = @max(v.hi - v.lo, 1e-6);
    const t = std.math.clamp((value - v.lo) / span, 0, 1);
    return v.rect.y + PAD_TOP + (1 - t) * innerH(v);
}

fn valueOf(v: *const View, y: f32, stepped: bool) f32 {
    const t = std.math.clamp(1 - (y - v.rect.y - PAD_TOP) / innerH(v), 0, 1);
    const val = v.lo + t * (v.hi - v.lo);
    return if (stepped) @round(val) else val;
}

fn valueDelta(v: *const View, dy: f32) f32 {
    const fine: f32 = if (shiftDown()) 10 else 1;
    return -dy / innerH(v) * (v.hi - v.lo) / fine;
}

fn shiftDown() bool {
    return c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
}

fn altDown() bool {
    return c.rl.IsKeyDown(c.rl.KEY_LEFT_ALT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_ALT);
}

fn cmdDown() bool {
    return c.rl.IsKeyDown(c.rl.KEY_LEFT_SUPER) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SUPER);
}

// ── Hit testing ──────────────────────────────────────────────────────

fn pointAt(v: *const View, lane: *const Lane, mx: f32, my: f32) ?usize {
    var best: ?usize = null;
    var best_d: f32 = HIT + 1;
    for (lane.points.items, 0..) |p, i| {
        const d = @max(@abs(xOf(v, p.beat) - mx), @abs(yOf(v, p.value) - my));
        if (d <= HIT and d <= best_d) {
            best = i;
            best_d = d;
        }
    }
    return best;
}

/// The segment whose drawn line passes within HIT of the pointer.
fn segmentAt(v: *const View, lane: *const Lane, mx: f32, my: f32) ?usize {
    const pts = lane.points.items;
    if (pts.len < 2) return null;
    const beat = beatOf(v, mx);
    const i = automation.segmentIndex(pts, beat) orelse return null;
    if (i + 1 >= pts.len) return null;
    if (@abs(yOf(v, automation.eval(pts, beat)) - my) > HIT) return null;
    return i;
}

// ── Drawing ──────────────────────────────────────────────────────────

fn drawCurve(ui: *Ui, v: *const View, pts: []const Point, col: Color) void {
    const left = v.rect.x;
    const right = v.rect.x + v.rect.width;
    if (pts.len == 0) return;
    const dim = col.mix(ui_style.pane, 0.45);
    // Held before the first point and after the last.
    const x_first = xOf(v, pts[0].beat);
    if (x_first > left) ui.line(left, yOf(v, pts[0].value), @min(x_first, right), yOf(v, pts[0].value), dim);
    const x_last = xOf(v, pts[pts.len - 1].beat);
    if (x_last < right) ui.line(@max(x_last, left), yOf(v, pts[pts.len - 1].value), right, yOf(v, pts[pts.len - 1].value), dim);

    for (pts[0 .. pts.len - 1], 0..) |p, i| {
        const q = pts[i + 1];
        const x0 = xOf(v, p.beat);
        const x1 = xOf(v, q.beat);
        if (x1 < left or x0 > right) continue;
        const y0 = yOf(v, p.value);
        const y1 = yOf(v, q.value);
        switch (p.shape) {
            .hold => {
                ui.line(x0, y0, x1, y0, col);
                ui.line(x1, y0, x1, y1, col);
            },
            .linear => ui.line(x0, y0, x1, y1, col),
            .curve => {
                // Sample every 2px across the visible part of the segment.
                const a = @max(x0, left);
                const b = @min(x1, right);
                const w = @max(x1 - x0, 1e-3);
                var px = a;
                var py = yOf(v, p.value + (q.value - p.value) * automation.shapeAt(.curve, p.tension, (a - x0) / w));
                while (px < b) {
                    const nx = @min(px + 2, b);
                    const u = (nx - x0) / w;
                    const ny = yOf(v, p.value + (q.value - p.value) * automation.shapeAt(.curve, p.tension, u));
                    ui.line(px, py, nx, ny, col);
                    px = nx;
                    py = ny;
                }
            },
        }
    }
}

fn drawHandle(ui: *Ui, v: *const View, p: Point, col: Color, hot: bool) void {
    const x: i32 = @intFromFloat(@round(xOf(v, p.beat)));
    const y: i32 = @intFromFloat(@round(yOf(v, p.value)));
    if (p.selected) {
        ui.rect(Rect.xywh(x - 1, y - 1, 3, 3), ui_style.accent);
        return;
    }
    ui.rect(Rect.xywh(x - 1, y - 1, 3, 3), if (hot) ui_style.text else col);
    ui.px(x, y, ui_style.pane);
}

fn drawReadout(ui: *Ui, v: *const View, x: f32, y: f32, knob: f32) void {
    const f = v.fmt orelse return;
    var buf: [32]u8 = undefined;
    const s = f.format(knob, &buf);
    const w = ui.fonts.legend.measure(s) + 6;
    var rx: i32 = @intFromFloat(x + 6);
    const ry: i32 = @intFromFloat(@max(v.rect.y, y - 14));
    if (@as(f32, @floatFromInt(rx + w)) > v.rect.x + v.rect.width) rx = @intFromFloat(x - 6 - @as(f32, @floatFromInt(w)));
    ui.rect(Rect.xywh(rx, ry, w, 12), ui_style.well);
    _ = ui.text(&ui.fonts.legend, rx + 3, ry + 1, s, ui_style.text);
}

// ── Editing helpers ──────────────────────────────────────────────────

fn captureOrig(lane: *const Lane) void {
    orig_n = @min(lane.points.items.len, MAX_DRAG);
    @memcpy(orig[0..orig_n], lane.points.items[0..orig_n]);
}

/// Move the selection by (dbeat, dval) from the captured originals. Each
/// selected point stays between its unselected neighbours, so order holds.
fn applyMove(lane: *Lane, dbeat: f64, dval: f32, lo: f32, hi: f32) void {
    const n = @min(orig_n, lane.points.items.len);
    for (0..n) |i| {
        if (!orig[i].selected) continue;
        var lo_b: f64 = 0;
        var j = i;
        while (j > 0) {
            j -= 1;
            if (!orig[j].selected) {
                lo_b = orig[j].beat;
                break;
            }
        }
        var hi_b: f64 = std.math.inf(f64);
        for (orig[i + 1 .. n]) |q| if (!q.selected) {
            hi_b = q.beat;
            break;
        };
        const p = &lane.points.items[i];
        p.beat = std.math.clamp(orig[i].beat + dbeat, lo_b, hi_b);
        var val = std.math.clamp(orig[i].value + dval, lo, hi);
        if (lane.stepped) val = @round(val);
        p.value = val;
    }
}

/// Commit a freehand stroke: replace the points under its span with the
/// stroke thinned to 1 px.
fn commitDraw(alloc: std.mem.Allocator, v: *const View, lane: *Lane) bool {
    if (draw_n < 2) return false;
    var keep: [MAX_DRAW]bool = undefined;
    automation.thin(draw_xs[0..draw_n], draw_ys[0..draw_n], 1.0, keep[0..draw_n]);
    var b0 = beatOf(v, draw_xs[0]);
    var b1 = beatOf(v, draw_xs[draw_n - 1]);
    if (b1 < b0) std.mem.swap(f64, &b0, &b1);
    // Drop existing points inside the stroke's span.
    var w: usize = 0;
    for (lane.points.items) |p| {
        if (p.beat >= b0 and p.beat <= b1) continue;
        lane.points.items[w] = p;
        w += 1;
    }
    lane.points.items.len = w;
    for (0..draw_n) |i| {
        if (!keep[i]) continue;
        _ = lane.insert(alloc, .{ .beat = @max(0, beatOf(v, draw_xs[i])), .value = valueOf(v, draw_ys[i], lane.stepped) }) catch return true;
    }
    return true;
}

// ── Menu ─────────────────────────────────────────────────────────────

const M_HOLD: u32 = 1;
const M_LINEAR: u32 = 2;
const M_CURVE: u32 = 3;
const M_RESET: u32 = 4;
const M_DELETE: u32 = 5;
const M_ENTER: u32 = 6;

fn menuKey(v: *const View) u64 {
    return v.key ^ 0x3E7A_0000_0000_0001;
}

fn menuTick(v: *const View, lane: *Lane) bool {
    const k = menuKey(v);
    if (!menu.isOpen(k)) return false;
    if (menu_point >= lane.points.items.len) {
        menu.close();
        return false;
    }
    const p = &lane.points.items[menu_point];
    const items = [_]menu.Item{
        .{ .label = "Hold", .id = M_HOLD },
        .{ .label = "Linear", .id = M_LINEAR, .enabled = !lane.stepped },
        .{ .label = "Curve", .id = M_CURVE, .enabled = !lane.stepped },
        .{ .label = "Reset tension", .id = M_RESET, .enabled = p.tension != 0 },
        .{ .separator = true },
        .{ .label = "Enter value\u{2026}", .id = M_ENTER, .enabled = v.fmt != null and v.fmt.?.parse != null },
        .{ .label = "Delete point", .id = M_DELETE },
    };
    const picked = menu.pick(k, &items) orelse return false;
    switch (picked) {
        M_HOLD => p.shape = .hold,
        M_LINEAR => p.shape = .linear,
        M_CURVE => p.shape = .curve,
        M_RESET => p.tension = 0,
        M_DELETE => _ = lane.points.orderedRemove(menu_point),
        M_ENTER => {
            var buf: [32]u8 = undefined;
            entry_tb = text_field.TextBuf.init(v.fmt.?.format(p.value, &buf), 24);
            entry_tb.selectAll();
            entry_lane = v.key;
            entry_point = menu_point;
            entry_focus = true;
            return false;
        },
        else => return false,
    }
    return true;
}

// ── Frame ────────────────────────────────────────────────────────────

/// Draw `lane` in `v.rect` and handle its gestures for this frame.
pub fn draw(ui: *Ui, alloc: std.mem.Allocator, lane: *Lane, v: View, m: pane.Mouse) Result {
    var res = Result{};
    const r = v.rect;
    const ri = Rect.xywh(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.width), @intFromFloat(r.height));
    const over = pane.contains(r, m.x, m.y);
    const dragging = pane.isDraggingKey(v.key) and drag_lane == v.key;

    // ── Continue a drag ──
    if (dragging) {
        const dx = m.x - start_x;
        const dy = m.y - start_y;
        switch (mode) {
            .none => {},
            .move => {
                pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_ALL, 3);
                const dbeat = snap_mod.snapNearest(v.edit_snap, @as(f64, dx / v.px_per_beat), altDown());
                applyMove(lane, dbeat, valueDelta(&v, dy), v.lo, v.hi);
                res.edited = true;
            },
            .segment => {
                pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 3);
                const dv = valueDelta(&v, dy);
                for ([_]usize{ seg, seg + 1 }) |i| if (i < lane.points.items.len and i < orig_n) {
                    var val = std.math.clamp(orig[i].value + dv, v.lo, v.hi);
                    if (lane.stepped) val = @round(val);
                    lane.points.items[i].value = val;
                };
                res.edited = true;
            },
            .bend => if (seg + 1 < lane.points.items.len) {
                pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 3);
                const p = &lane.points.items[seg];
                const q = lane.points.items[seg + 1];
                const span = q.value - p.value;
                if (@abs(span) > 1e-6) {
                    const frac = (valueOf(&v, m.y, false) - p.value) / span;
                    p.shape = .curve;
                    p.tension = automation.tensionForMidpoint(frac);
                    res.edited = true;
                }
            },
            .box => {},
            .draw => if (draw_n < MAX_DRAW and (draw_n == 0 or @abs(m.x - draw_xs[draw_n - 1]) >= 1)) {
                draw_xs[draw_n] = std.math.clamp(m.x, r.x, r.x + r.width);
                draw_ys[draw_n] = m.y;
                draw_n += 1;
            },
        }
        if (!m.left_down) {
            switch (mode) {
                .box => {
                    const bx0 = @min(start_x, m.x);
                    const bx1 = @max(start_x, m.x);
                    const by0 = @min(start_y, m.y);
                    const by1 = @max(start_y, m.y);
                    if (!shiftDown()) lane.deselectAll();
                    for (lane.points.items) |*p| {
                        const px = xOf(&v, p.beat);
                        const py = yOf(&v, p.value);
                        if (px >= bx0 and px <= bx1 and py >= by0 and py <= by1) p.selected = true;
                    }
                },
                .draw => res.edited = commitDraw(alloc, &v, lane) or res.edited,
                else => {},
            }
            mode = .none;
            drag_lane = 0;
            pane.cancelDrag();
        }
    }

    // ── Hover and press ──
    const hot_point = if (over and !pane.hasActiveDrag()) pointAt(&v, lane, m.x, m.y) else null;
    const hot_seg = if (over and !pane.hasActiveDrag() and hot_point == null) segmentAt(&v, lane, m.x, m.y) else null;
    if (hot_point != null) {
        pane.requestCursor(c.rl.MOUSE_CURSOR_POINTING_HAND, 2);
    } else if (hot_seg != null) {
        pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 2);
    }

    if (over and !pane.hasActiveDrag()) {
        if (m.double_clicked) {
            res.pressed = true;
            if (hot_point) |i| {
                _ = lane.points.orderedRemove(i);
            } else {
                const beat = @max(0, snap_mod.snapNearest(v.edit_snap, beatOf(&v, m.x), altDown()));
                lane.deselectAll();
                const i = lane.insert(alloc, .{ .beat = beat, .value = valueOf(&v, m.y, lane.stepped) }) catch 0;
                if (i < lane.points.items.len) lane.points.items[i].selected = true;
            }
            res.edited = true;
        } else if (m.left_pressed) {
            res.pressed = true;
            start_x = m.x;
            start_y = m.y;
            if (hot_point) |i| {
                const p = &lane.points.items[i];
                if (shiftDown()) {
                    p.selected = !p.selected;
                } else if (!p.selected) {
                    lane.deselectAll();
                    p.selected = true;
                }
                if (p.selected and pane.tryStartDrag(v.key)) {
                    captureOrig(lane);
                    mode = .move;
                    drag_lane = v.key;
                }
            } else if (hot_seg) |i| {
                if (pane.tryStartDrag(v.key)) {
                    captureOrig(lane);
                    seg = i;
                    mode = if (altDown() and !lane.stepped) .bend else .segment;
                    drag_lane = v.key;
                }
            } else if (pane.tryStartDrag(v.key)) {
                drag_lane = v.key;
                if (cmdDown()) {
                    mode = .draw;
                    draw_n = 0;
                } else {
                    mode = .box;
                }
            }
        } else if (m.right_pressed) {
            if (hot_point) |i| {
                res.pressed = true;
                menu_point = i;
                menu.openAt(menuKey(&v), @intFromFloat(m.x), @intFromFloat(m.y));
            }
        }
    }
    if (menuTick(&v, lane)) res.edited = true;
    if (entry_lane == v.key) if (entryTick(ui, &v, lane)) {
        res.edited = true;
    };

    // ── Draw ──
    ui.clip(ri);
    ui.rect(ri, if (v.selected) ui_style.pane_alt.shade(-3) else ui_style.pane.shade(-3));
    ui.rect(Rect.xywh(ri.x, ri.bottom() - 1, ri.w, 1), ui_style.chassis);
    if (v.name.len > 0) _ = ui.text(&ui.fonts.legend, ri.x + 4, ri.y + 2, v.name, ui_style.text_mute);
    const col = v.color;
    if (lane.points.items.len == 0) {
        _ = ui.text(&ui.fonts.legend, ri.x + 4, ri.bottom() - 13, "DOUBLE-CLICK TO ADD A POINT", ui_style.text_mute.mix(ui_style.pane, 0.4));
    }
    drawCurve(ui, &v, lane.points.items, col);
    for (lane.points.items, 0..) |p, i| {
        const px = xOf(&v, p.beat);
        if (px < r.x - 3 or px > r.x + r.width + 3) continue;
        drawHandle(ui, &v, p, col, hot_point == i);
    }
    if (dragging and mode == .box and m.left_down) {
        const bx: i32 = @intFromFloat(@min(start_x, m.x));
        const by: i32 = @intFromFloat(@min(start_y, m.y));
        const bw: i32 = @intFromFloat(@abs(m.x - start_x));
        const bh: i32 = @intFromFloat(@abs(m.y - start_y));
        ui.rect(Rect.xywh(bx, by, bw, bh), ui_style.accent.alpha(28));
        ui.bevel(Rect.xywh(bx, by, bw, bh), ui_style.accent, ui_style.accent);
    }
    if (dragging and mode == .draw and draw_n > 1) {
        for (1..draw_n) |i| ui.line(draw_xs[i - 1], draw_ys[i - 1], draw_xs[i], draw_ys[i], ui_style.accent);
    }
    ui.unclip();

    // Readout: the dragged point, or the hovered one.
    if (dragging and (mode == .move or mode == .segment)) {
        const i = if (mode == .segment) seg else firstSelected(lane);
        if (i) |pi| if (pi < lane.points.items.len) {
            const p = lane.points.items[pi];
            drawReadout(ui, &v, xOf(&v, p.beat), yOf(&v, p.value), p.value);
        };
    } else if (hot_point) |i| {
        const p = lane.points.items[i];
        drawReadout(ui, &v, xOf(&v, p.beat), yOf(&v, p.value), p.value);
    }
    return res;
}

/// Draw a clip lane's curve over a track lane between song beats `from`
/// and `to` (docs/22 §Track lanes): the track curve under it dims, since
/// the clip's is what plays there. `points` are timed from `from`.
pub fn drawOverlay(ui: *Ui, v: View, points: []const Point, from: f64, to: f64) void {
    if (points.len == 0) return;
    const x0 = @max(xOf(&v, from), v.rect.x);
    const x1 = @min(xOf(&v, to), v.rect.x + v.rect.width);
    if (x1 <= x0) return;
    const span = Rect.xywh(@intFromFloat(@floor(x0)), @intFromFloat(v.rect.y), @intFromFloat(@ceil(x1 - x0)), @intFromFloat(v.rect.height - 1));
    ui.clip(span);
    defer ui.unclip();
    ui.rect(span, ui_style.pane.shade(-3).alpha(200));
    ui.rect(Rect.xywh(span.x, span.y, 1, span.h), v.color.mix(ui_style.pane, 0.5));
    var sv = v;
    sv.timeline_x0 += @as(f32, @floatCast(from)) * v.px_per_beat;
    drawCurve(ui, &sv, points, v.color.mix(ui_style.text, 0.35));
}

/// The Enter value… field over its point: Enter sets the point, Esc
/// cancels, a press elsewhere commits.
fn entryTick(ui: *Ui, v: *const View, lane: *Lane) bool {
    if (entry_point >= lane.points.items.len) {
        entry_lane = 0;
        return false;
    }
    const p = lane.points.items[entry_point];
    const x: i32 = @intFromFloat(xOf(v, p.beat) + 6);
    const y: i32 = @intFromFloat(@max(v.rect.y, yOf(v, p.value) - 8));
    const ev = text_field.field(ui, Rect.xywh(x, y, 72, 16), .{ "lane-entry", v.key }, &entry_tb, .{ .focus = entry_focus, .commit_on_blur = true });
    entry_focus = false;
    switch (ev) {
        .commit => {
            entry_lane = 0;
            const f = v.fmt orelse return false;
            const parse = f.parse orelse return false;
            var knob = parse(f.ctx, entry_tb.text()) orelse return false;
            knob = std.math.clamp(knob, v.lo, v.hi);
            if (lane.stepped) knob = @round(knob);
            lane.points.items[entry_point].value = knob;
            return true;
        },
        .cancel => entry_lane = 0,
        .none, .changed => {},
    }
    return false;
}

fn firstSelected(lane: *const Lane) ?usize {
    for (lane.points.items, 0..) |p, i| if (p.selected) return i;
    return null;
}

/// True while any lane drag is live (the arrangement holds off its own).
pub fn dragActive() bool {
    return mode != .none;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "moving a selection keeps it between its unselected neighbours" {
    const alloc = testing.allocator;
    var lane = Lane{ .target = automation.Target.volume() };
    defer lane.deinit(alloc);
    _ = try lane.insert(alloc, .{ .beat = 0, .value = 0.1 });
    _ = try lane.insert(alloc, .{ .beat = 4, .value = 0.5, .selected = true });
    _ = try lane.insert(alloc, .{ .beat = 5, .value = 0.6, .selected = true });
    _ = try lane.insert(alloc, .{ .beat = 8, .value = 0.9 });
    captureOrig(&lane);
    applyMove(&lane, 10, 0.7, 0, 1); // far right and past the top
    try testing.expectEqual(@as(f64, 8), lane.points.items[1].beat);
    try testing.expectEqual(@as(f64, 8), lane.points.items[2].beat);
    try testing.expectEqual(@as(f32, 1), lane.points.items[2].value);
    applyMove(&lane, -10, 0, 0, 1);
    try testing.expectEqual(@as(f64, 0), lane.points.items[1].beat);
    // Unselected points never move.
    try testing.expectEqual(@as(f64, 8), lane.points.items[3].beat);
}

test "a freehand stroke replaces the points under its span, thinned" {
    const alloc = testing.allocator;
    var lane = Lane{ .target = automation.Target.volume() };
    defer lane.deinit(alloc);
    _ = try lane.insert(alloc, .{ .beat = 0, .value = 0.5 });
    _ = try lane.insert(alloc, .{ .beat = 2, .value = 0.5 });
    _ = try lane.insert(alloc, .{ .beat = 20, .value = 0.5 });
    const v = View{ .rect = pane.rect(0, 0, 400, 40), .timeline_x0 = 0, .scroll_x = 0, .px_per_beat = 10, .edit_snap = .note_16, .color = ui_style.accent, .key = 1 };
    // A straight ramp from beat 1 to beat 9: thins to its two ends.
    draw_n = 0;
    var x: f32 = 10;
    while (x <= 90) : (x += 1) {
        draw_xs[draw_n] = x;
        draw_ys[draw_n] = 36 - (x - 10) * 0.4;
        draw_n += 1;
    }
    try testing.expect(commitDraw(alloc, &v, &lane));
    const pts = lane.points.items;
    try testing.expectEqual(@as(usize, 4), pts.len); // 0, stroke start, stroke end, 20
    try testing.expectApproxEqAbs(@as(f64, 1), pts[1].beat, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 9), pts[2].beat, 1e-6);
    try testing.expect(pts[2].value > pts[1].value);
}
