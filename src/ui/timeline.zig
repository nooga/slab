//! The view every timeline shares (docs/31 §The shared code): zoom and
//! scroll on the beat axis, the wheel grammar, the minimap, the lazy
//! vertical scrollbar, meter-aware ruler ticks and grid lines, and the
//! playhead. The arrangement, the piano roll and the audio editor each
//! own a `View`; the rules live here once.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const pane = @import("pane_input.zig");
const bridge = @import("bridge.zig");
const gesture = @import("gesture.zig");
const snap_mod = @import("snap.zig");
const meter_mod = @import("../meter.zig");
const follow_mod = @import("follow.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const FRect = pane.FRect;

/// Pixels a wheel notch (or a swipe's unit) scrolls.
pub const WHEEL_STEP: f32 = 30;

pub fn zoomFactor(w: f32) f32 {
    return std.math.clamp(1.0 + w * 0.12, 0.5, 2.0);
}

/// Zoom limits and which axes the view has.
pub const Limits = struct {
    min_ppb: f32,
    max_ppb: f32,
    /// The view scrolls vertically (tracks, pitch rows).
    vertical: bool = true,
    /// ⌥-wheel zooms row height within this range; null: it doesn't.
    rows: ?[2]f32 = null,
};

pub const View = struct {
    px_per_beat: f32,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Row height for views whose rows zoom (the piano roll).
    row_h: f32 = 0,
    /// When the view last scrolled by hand (the scrollbar fades after).
    last_scroll: f64 = 0,
    follow: follow_mod.Follow = .{},

    /// `x0`: the screen x of beat 0 before scrolling.
    pub fn beatToX(v: *const View, x0: f32, beat: f64) f32 {
        return x0 + @as(f32, @floatCast(beat)) * v.px_per_beat - v.scroll_x;
    }

    pub fn xToBeat(v: *const View, x0: f32, x: f32) f64 {
        return @as(f64, (x - x0 + v.scroll_x) / v.px_per_beat);
    }

    /// The beat range [l, r) the view shows across `w` px.
    pub fn range(v: *const View, w: f32) [2]f64 {
        const l: f64 = v.scroll_x / v.px_per_beat;
        return .{ l, l + w / v.px_per_beat };
    }

    /// Zoom time by `factor`, keeping the beat `anchor` px into the view
    /// where it is.
    pub fn zoomTime(v: *View, factor: f32, anchor: f32, lim: Limits) void {
        const beat = (anchor + v.scroll_x) / v.px_per_beat;
        v.px_per_beat = std.math.clamp(v.px_per_beat * factor, lim.min_ppb, @max(lim.min_ppb, lim.max_ppb));
        v.scroll_x = beat * v.px_per_beat - anchor;
    }

    /// Zoom rows by `factor`, keeping the row `anchor` px down where it is.
    pub fn zoomRows(v: *View, factor: f32, anchor: f32, lo: f32, hi: f32) void {
        const row = (anchor + v.scroll_y) / v.row_h;
        v.row_h = std.math.clamp(v.row_h * factor, lo, hi);
        v.scroll_y = row * v.row_h - anchor;
    }

    /// Show the beats [l, r) across `w` px.
    pub fn zoomTo(v: *View, l: f64, r: f64, w: f32, lim: Limits) void {
        if (r <= l or w <= 0) return;
        v.px_per_beat = std.math.clamp(w / @as(f32, @floatCast(r - l)), lim.min_ppb, @max(lim.min_ppb, lim.max_ppb));
        v.scroll_x = @as(f32, @floatCast(l)) * v.px_per_beat;
    }

    /// Keep the view inside content `content_w` × `content_h` px seen
    /// through `w` × `h`.
    pub fn clamp(v: *View, w: f32, content_w: f32, h: f32, content_h: f32) void {
        v.scroll_x = std.math.clamp(v.scroll_x, 0, @max(0, content_w - w));
        v.scroll_y = std.math.clamp(v.scroll_y, 0, @max(0, content_h - h));
    }

    /// The wheel (docs/31 §View): it scrolls; ⇧ scrolls time; ⌘ zooms
    /// time and ⌥ zooms rows around the pointer. `x0`/`y0`: the view's
    /// top-left on screen. The caller checks the pointer is over the view.
    pub fn wheel(v: *View, x0: f32, y0: f32, m: pane.Mouse, md: gesture.Mods, lim: Limits, now: f64) void {
        if (m.wheel_x == 0 and m.wheel_y == 0) return;
        const w: f32 = if (m.wheel_y != 0) m.wheel_y else m.wheel_x;
        if (md.cmd) {
            v.zoomTime(zoomFactor(w), m.x - x0, lim);
        } else if (md.alt) {
            const rr = lim.rows orelse return;
            v.zoomRows(zoomFactor(w), m.y - y0, rr[0], rr[1]);
        } else if (md.shift or !lim.vertical) {
            v.scroll_x -= (if (m.wheel_x != 0) m.wheel_x else m.wheel_y) * WHEEL_STEP;
        } else {
            v.scroll_x -= m.wheel_x * WHEEL_STEP;
            v.scroll_y -= m.wheel_y * WHEEL_STEP;
        }
        v.last_scroll = now;
    }
};

/// The edit cursor: where the last click on empty space was, so a paste
/// from the keyboard lands there (docs/31 §Keys). Song beats.
pub const Cursor = struct {
    beat: f64,
    track: ?usize = null,
    pitch: ?u8 = null,
};

// ── Minimap ──────────────────────────────────────────────────────────

/// The minimap's window over the whole content (docs/31 §View): drag it
/// to pan, press outside it to jump there and keep dragging, drag its
/// edges to zoom, wheel over it to zoom around that beat. The caller
/// draws the content into `inner` first.
pub const Overview = struct {
    grab: Grab = .none,
    offset: f32 = 0,
    /// The window edge that stays put while the other is dragged.
    fixed: f64 = 0,

    const Grab = enum { none, pan, left, right };
    const EDGE: f32 = 3;

    pub fn cancel(o: *Overview) void {
        o.grab = .none;
    }

    pub fn run(
        o: *Overview,
        ui: *Ui,
        inner: FRect,
        v: *View,
        /// The beats the strip spans (a clip editor's can start before 0).
        content: [2]f64,
        view_w: f32,
        lim: Limits,
        play: ?f64,
        m: pane.Mouse,
        key: u64,
        now: f64,
    ) void {
        if (inner.width <= 0 or view_w <= 0) return;
        const lo: f32 = @floatCast(content[0]);
        const cb: f32 = @max(@as(f32, @floatCast(content[1] - content[0])), 1.0);
        const k = inner.width / cb; // overview px per beat
        const vr = v.range(view_w);
        const vx = inner.x + (@as(f32, @floatCast(vr[0])) - lo) * k;
        const vw = @max(2.0, @as(f32, @floatCast(vr[1] - vr[0])) * k);

        // Window.
        const x0 = std.math.clamp(vx, inner.x, inner.x + inner.width);
        const x1 = std.math.clamp(vx + vw, inner.x, inner.x + inner.width);
        if (x1 > x0) {
            const wr = bridge.fromRl(pane.rect(x0, inner.y, x1 - x0, inner.height));
            ui.rect(wr, style.accent.alpha(40));
            ui.bevel(wr, style.accent, style.accent);
        }
        if (play) |pb| {
            const px = inner.x + (@as(f32, @floatCast(pb)) - lo) * k;
            if (px >= inner.x and px < inner.x + inner.width) ui.rect(Rect.xywh(@intFromFloat(@floor(px)), @intFromFloat(inner.y), 1, @intFromFloat(inner.height)), style.accent);
        }

        const over = pane.contains(inner, m.x, m.y);
        const on_edge_l = vw >= 4 * EDGE and @abs(m.x - vx) <= EDGE;
        const on_edge_r = vw >= 4 * EDGE and @abs(m.x - (vx + vw)) <= EDGE;
        if ((over and (on_edge_l or on_edge_r)) or o.grab == .left or o.grab == .right)
            pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);

        if (over and (m.wheel_x != 0 or m.wheel_y != 0) and o.grab == .none) {
            const w: f32 = if (m.wheel_y != 0) m.wheel_y else m.wheel_x;
            const beat = lo + (m.x - inner.x) / k;
            v.px_per_beat = std.math.clamp(v.px_per_beat * zoomFactor(w), lim.min_ppb, @max(lim.min_ppb, lim.max_ppb));
            v.scroll_x = beat * v.px_per_beat - (m.x - vx) / vw * view_w;
            v.last_scroll = now;
            return;
        }

        if (o.grab != .none) {
            if (!pane.isDraggingKey(key) or !m.left_down) {
                if (pane.isDraggingKey(key)) pane.cancelDrag();
                o.grab = .none;
                return;
            }
            const beat: f64 = @max(lo, lo + (m.x - inner.x) / k);
            switch (o.grab) {
                .pan => v.scroll_x = (lo + (m.x - o.offset - inner.x) / k) * v.px_per_beat,
                .left => if (o.fixed - beat > 1e-3) v.zoomTo(beat, o.fixed, view_w, lim),
                .right => if (beat - o.fixed > 1e-3) v.zoomTo(o.fixed, beat, view_w, lim),
                .none => {},
            }
            v.last_scroll = now;
            return;
        }

        if (!m.left_pressed or !over or pane.hasActiveDrag()) return;
        if (!pane.tryStartDrag(key)) return;
        if (on_edge_l) {
            o.grab = .left;
            o.fixed = vr[1];
        } else if (on_edge_r) {
            o.grab = .right;
            o.fixed = vr[0];
        } else if (m.x >= vx and m.x <= vx + vw) {
            o.grab = .pan;
            o.offset = m.x - vx;
        } else {
            o.grab = .pan;
            o.offset = vw / 2;
            v.scroll_x = (lo + (m.x - o.offset - inner.x) / k) * v.px_per_beat;
        }
        v.last_scroll = now;
    }
};

// ── Vertical scrollbar ───────────────────────────────────────────────

const SB_W: f32 = 6;
const SB_HOVER: f32 = 28;
const SB_LINGER: f64 = 0.6;
const SB_FADE: f64 = 0.9;

/// The lazy vertical scrollbar along a view's right edge: shown while
/// scrolling or with the pointer near it, then fading. Drag the thumb, or
/// click the track to page.
pub const Scrollbar = struct {
    dragging: bool = false,
    grab_y: f32 = 0,
    grab_scroll: f32 = 0,

    pub fn cancel(s: *Scrollbar) void {
        s.dragging = false;
    }

    pub fn run(s: *Scrollbar, ui: *Ui, area: FRect, v: *View, content_h: f32, m: pane.Mouse, key: u64, now: f64) void {
        if (content_h <= area.height) return;
        const since = now - v.last_scroll;
        const near = m.x >= area.x + area.width - SB_HOVER and m.x <= area.x + area.width and
            m.y >= area.y and m.y <= area.y + area.height;
        var alpha: f32 = 0;
        if (near or s.dragging or since < SB_LINGER) {
            alpha = 1;
        } else if (since < SB_LINGER + SB_FADE) {
            alpha = 1 - @as(f32, @floatCast((since - SB_LINGER) / SB_FADE));
        }
        if (alpha <= 0 and !s.dragging) return;

        const bar_x = area.x + area.width - SB_W;
        const track = pane.rect(bar_x, area.y, SB_W, area.height);
        ui.rect(bridge.fromRl(track), style.chassis.alpha(@intFromFloat(alpha * 160)));
        const thumb_h = @max(16.0, (area.height / content_h) * area.height);
        const range = content_h - area.height;
        const track_range = area.height - thumb_h;
        const thumb = pane.rect(bar_x + 1, area.y + (v.scroll_y / range) * track_range, SB_W - 2, thumb_h);
        const hover = pane.contains(thumb, m.x, m.y);
        ui.rect(bridge.fromRl(thumb), (if (s.dragging or hover) style.accent else style.face_hi).alpha(@intFromFloat(alpha * 255)));

        if (s.dragging) {
            if (!pane.isDraggingKey(key) or !m.left_down) {
                if (pane.isDraggingKey(key)) pane.cancelDrag();
                s.dragging = false;
                return;
            }
            v.scroll_y = s.grab_scroll + (m.y - s.grab_y) * (range / track_range);
            v.last_scroll = now;
            return;
        }
        if (!m.left_pressed or pane.hasActiveDrag()) return;
        if (hover) {
            if (!pane.tryStartDrag(key)) return;
            s.dragging = true;
            s.grab_y = m.y;
            s.grab_scroll = v.scroll_y;
        } else if (pane.contains(track, m.x, m.y)) {
            v.scroll_y += if (m.y < thumb.y) -area.height * 0.8 else area.height * 0.8;
            v.last_scroll = now;
        }
    }
};

/// Click or drag a ruler to scrub; ⇧-drag across it to set the loop
/// (docs/31 §Rulers). Beats are the axis's own.
pub const Scrub = struct {
    active: bool = false,
    looping: bool = false,
    anchor: f64 = 0,

    pub const Out = union(enum) {
        seek: f64,
        /// The loop the drag has drawn so far, snapped.
        loop: [2]f64,
    };

    pub fn cancel(sc: *Scrub) void {
        sc.active = false;
    }

    pub fn run(sc: *Scrub, ruler: FRect, v: *const View, x0: f32, m: pane.Mouse, key: u64, edit_snap: snap_mod.Setting) ?Out {
        const md = gesture.mods();
        // Axis beats, unclamped: a clip editor's axis can start before 0.
        const beat = v.xToBeat(x0, m.x);
        if (!sc.active) {
            if (!m.left_pressed or !pane.contains(ruler, m.x, m.y) or pane.hasActiveDrag()) return null;
            if (!pane.tryStartDrag(key)) return null;
            sc.active = true;
            sc.looping = md.shift;
            sc.anchor = snap_mod.snapNearest(edit_snap, beat, md.alt);
        } else if (!pane.isDraggingKey(key) or !m.left_down) {
            if (pane.isDraggingKey(key)) pane.cancelDrag();
            sc.active = false;
            return null;
        }
        if (!sc.looping) return .{ .seek = beat };
        const b = snap_mod.snapNearest(edit_snap, beat, md.alt);
        if (@abs(b - sc.anchor) < 1e-9) return null;
        return .{ .loop = .{ @min(sc.anchor, b), @max(sc.anchor, b) } };
    }
};

// ── Ruler and grid ───────────────────────────────────────────────────

/// The beat axis as the ruler and grid see it: the view, the screen x of
/// local beat 0, and the song beat local beat 0 is (so bars come from the
/// song's meter map wherever the view starts).
pub const Axis = struct {
    view: *const View,
    x0: f32,
    origin: f64 = 0,
    meter: meter_mod.MeterMap,

    fn x(a: Axis, abs_beat: f64) f32 {
        return a.view.beatToX(a.x0, abs_beat - a.origin);
    }
    fn firstBar(a: Axis, left: f32) u32 {
        const abs = a.origin + a.view.xToBeat(a.x0, left);
        return a.meter.beatToBarPos(@max(0.0, abs)).bar;
    }
};

fn ipx(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

/// Ruler ticks on a faceplate body: a snap sub-grid, the meter's beats
/// (downbeat, group, weak) and bar numbers, with the new signature where
/// the meter changes. `left`/`right` bound it on screen.
pub fn rulerTicks(ui: *Ui, body: Rect, left: f32, right: f32, a: Axis, edit_snap: snap_mod.Setting) void {
    const bot = body.bottom();
    const step = snap_mod.visualStep(edit_snap, a.view.px_per_beat);
    // Sub-grid, counted from the first bar line in view.
    var bar = a.firstBar(left);
    var beat = a.meter.barStartBeat(bar);
    while (true) : (beat += step) {
        const bx = a.x(beat);
        if (bx > right) break;
        if (bx >= left) ui.rect(Rect.xywh(ipx(bx), bot - 2, 1, 2), style.face_lo);
    }
    while (true) : (bar += 1) {
        const bstart = a.meter.barStartBeat(bar);
        const bx = a.x(bstart);
        if (bx > right) break;
        const seg = a.meter.segmentForBar(bar);
        const unit = seg.unitBeats();
        var k: u8 = 0;
        while (k < seg.numerator) : (k += 1) {
            const tx = a.x(bstart + @as(f64, @floatFromInt(k)) * unit);
            if (tx > right) break;
            if (tx < left) continue;
            const acc = seg.accentAt(k);
            const h: i32 = switch (acc) {
                .downbeat => 7,
                .group => 5,
                .weak => 3,
            };
            ui.rect(Rect.xywh(ipx(tx), bot - h, 1, h), if (acc == .weak) style.text_mute else style.text_dim);
        }
        if (bx >= left - 20) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{bar + 1}) catch "?";
            const w = ui.engraved(&ui.fonts.legend, ipx(bx) + 3, body.y, s, style.text_dim);
            if (seg.start_bar == bar and bar > 0) {
                var mbuf: [12]u8 = undefined;
                const ms = std.fmt.bufPrint(&mbuf, "{d}/{d}", .{ seg.numerator, seg.denominator }) catch "?";
                _ = ui.engraved(&ui.fonts.legend, ipx(bx) + 3 + w + 4, body.y, ms, style.vfd);
            }
        }
    }
}

/// Grid lines down `r`: the snap sub-grid where it is at least 6 px apart,
/// then the meter's beat and bar lines.
pub fn gridLines(ui: *Ui, r: FRect, a: Axis, edit_snap: snap_mod.Setting) void {
    const right = r.x + r.width - 1;
    const y = ipx(r.y);
    const h = ipx(r.y + r.height) - y;
    var bar = a.firstBar(r.x);
    const step = snap_mod.visualStep(edit_snap, a.view.px_per_beat);
    if (step * a.view.px_per_beat >= 6) {
        var beat = a.meter.barStartBeat(bar);
        while (true) : (beat += step) {
            const bx = a.x(beat);
            if (bx > right) break;
            if (bx >= r.x) ui.rect(Rect.xywh(ipx(bx), y, 1, h), style.grid_sub);
        }
    }
    while (true) : (bar += 1) {
        const bstart = a.meter.barStartBeat(bar);
        if (a.x(bstart) > right) break;
        const seg = a.meter.segmentForBar(bar);
        const unit = seg.unitBeats();
        var k: u8 = 0;
        while (k < seg.numerator) : (k += 1) {
            const tx = a.x(bstart + @as(f64, @floatFromInt(k)) * unit);
            if (tx > right) break;
            if (tx < r.x) continue;
            ui.rect(Rect.xywh(ipx(tx), y, 1, h), if (seg.accentAt(k) == .weak) style.grid_beat else style.grid_bar);
        }
    }
}

/// The playhead: one 1px accent line from `top` to `bottom` at `x`, when
/// it is inside [left, right).
pub fn playhead(ui: *Ui, x: f32, left: f32, right: f32, top: f32, bottom: f32) void {
    if (x < left or x >= right) return;
    ui.rect(Rect.xywh(ipx(x), ipx(top), 1, ipx(bottom) - ipx(top)), style.accent);
}

const testing = std.testing;

test "zoom keeps the beat under the pointer" {
    var v = View{ .px_per_beat = 20, .scroll_x = 100 };
    const lim = Limits{ .min_ppb = 4, .max_ppb = 96 };
    const before = v.xToBeat(0, 250);
    v.zoomTime(2, 250, lim);
    try testing.expectEqual(@as(f32, 40), v.px_per_beat);
    try testing.expectApproxEqAbs(before, v.xToBeat(0, 250), 1e-6);
    v.zoomTime(100, 250, lim); // clamped
    try testing.expectEqual(@as(f32, 96), v.px_per_beat);
    try testing.expectApproxEqAbs(before, v.xToBeat(0, 250), 1e-6);
}

test "the wheel: scroll, shift scrolls time, cmd zooms time, alt zooms rows" {
    const lim = Limits{ .min_ppb = 4, .max_ppb = 96, .rows = .{ 6, 24 } };
    var m = std.mem.zeroes(pane.Mouse);
    m.x = 100;
    m.y = 50;
    m.wheel_y = 1;
    var v = View{ .px_per_beat = 20, .scroll_x = 200, .scroll_y = 200, .row_h = 10 };
    v.wheel(0, 0, m, .{}, lim, 0);
    try testing.expectEqual(@as(f32, 200), v.scroll_x);
    try testing.expectEqual(@as(f32, 170), v.scroll_y);
    v.wheel(0, 0, m, .{ .shift = true }, lim, 0);
    try testing.expectEqual(@as(f32, 170), v.scroll_x);
    v.wheel(0, 0, m, .{ .cmd = true }, lim, 0);
    try testing.expect(v.px_per_beat > 20);
    v.wheel(0, 0, m, .{ .alt = true }, lim, 0);
    try testing.expect(v.row_h > 10);
    // No vertical axis: a vertical wheel scrolls time.
    var a = View{ .px_per_beat = 20, .scroll_x = 200 };
    a.wheel(0, 0, m, .{}, .{ .min_ppb = 4, .max_ppb = 96, .vertical = false }, 0);
    try testing.expectEqual(@as(f32, 170), a.scroll_x);
    try testing.expectEqual(@as(f32, 0), a.scroll_y);
    // No rows: ⌥ does nothing.
    a.wheel(0, 0, m, .{ .alt = true }, .{ .min_ppb = 4, .max_ppb = 96 }, 0);
    try testing.expectEqual(@as(f32, 170), a.scroll_x);
}

test "zoomTo shows a range" {
    var v = View{ .px_per_beat = 20 };
    v.zoomTo(8, 16, 400, .{ .min_ppb = 4, .max_ppb = 96 });
    try testing.expectEqual(@as(f32, 50), v.px_per_beat);
    const r = v.range(400);
    try testing.expectApproxEqAbs(@as(f64, 8), r[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 16), r[1], 1e-9);
}
