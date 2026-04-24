//! Arrangement pane — track lanes × time, with clips on the timeline
//! and compact inline mixer strips on the right end of each lane.
//!
//! Interaction:
//!   • Click clip              → select (auto-opens clip editor)
//!   • Double-click empty lane → create 1-bar clip, select it
//!   • Drag clip body          → move (beat-snapped)
//!   • Drag clip right edge    → resize (beat-snapped)

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const track_mod = @import("../track.zig");
const Track = track_mod.Track;
const clip_mod = @import("../clip.zig");
const Clip = clip_mod.Clip;
const ClipRef = clip_mod.ClipRef;
const Transport = @import("../transport.zig").Transport;

fn rulerH() f32 {
    return theme.size(14);
}
fn overviewH() f32 {
    return theme.size(22);
}
fn resizeEdgeW() f32 {
    return theme.fine(4);
}
const DEFAULT_CLIP_BEATS: f64 = 4.0;
const MIN_CLIP_BEATS: f64 = 0.25;
const PX_PER_BEAT_MIN: f32 = 6;
const PX_PER_BEAT_MAX: f32 = 96;
const DEFAULT_CONTENT_BEATS: f64 = 32;
const CONTENT_PAD_BEATS: f64 = 8;

const DRAG_SALT: u64 = 0xC114_4ABA_BEEF_0001;
const OVERVIEW_KEY: u64 = 0xCAFE_F00D_1234_5678;
const BOX_KEY: u64 = 0xB02B_51EC_7AAA_0001;
const LOOP_START_KEY: u64 = 0x1009_570A_AAAA_0001;
const LOOP_END_KEY: u64 = 0x1009_E0D0_AAAA_0001;
const BOX_MIN_DRAG: f32 = 3;
const MAX_DRAG_CLIPS: usize = 256;

const DragMode = enum { none, move, resize_r };
const ClipDragSnap = struct {
    track: u32,
    clip: u32,
    start_beat: f64,
};

// Module-scope state.
var px_per_beat: f32 = 24;
var scroll_x: f32 = 0;
var scroll_y: f32 = 0;
var last_scroll_time: f64 = 0;

var drag_mode: DragMode = .none;
var drag_ref: ClipRef = .{ .track = 0, .clip = 0 };
var drag_start_beat: f64 = 0;
var drag_start_length: f64 = 0;
var drag_start_mouse_x: f32 = 0;
var drag_snaps: [MAX_DRAG_CLIPS]ClipDragSnap = undefined;
var drag_snap_count: usize = 0;
var drag_track_delta: i32 = 0;

var box_active: bool = false;
var box_start_x: f32 = 0;
var box_start_y: f32 = 0;
var box_start_track: ?usize = null;
var box_shift: bool = false;

// Overview-strip drag.
var ov_drag: bool = false;
var ov_drag_offset: f32 = 0;

// Ruler scrub.
const RULER_KEY: u64 = 0x5C0B_0001_AAAA_BBBB;
var ruler_drag: bool = false;
var loop_start_drag: bool = false;
var loop_end_drag: bool = false;

// Vertical scrollbar (lazy) — mirrors clip_editor.
fn scrollbarW() f32 {
    return theme.fine(6);
}
const SCROLLBAR_HOVER_RANGE: f32 = 28;
const SCROLLBAR_FADE_VISIBLE: f64 = 0.9;
const SCROLLBAR_FADE_LINGER: f64 = 0.6;
const SBV_KEY: u64 = 0xACAB_1234_AAAA_9999;
var sbv_drag: bool = false;
var sbv_drag_start_mouse_y: f32 = 0;
var sbv_drag_start_scroll_y: f32 = 0;

pub const Result = struct {
    add_track: bool = false,
};

pub fn deleteSelectedClips(tracks: []Track, alloc: std.mem.Allocator, focused_clip: *?ClipRef) bool {
    var deleted = false;
    for (tracks) |*t| {
        var i: usize = 0;
        while (i < t.clips.items.len) {
            if (t.clips.items[i].selected) {
                var removed = t.clips.orderedRemove(i);
                removed.deinit(alloc);
                deleted = true;
            } else {
                i += 1;
            }
        }
    }
    if (deleted) focused_clip.* = null;
    return deleted;
}

pub fn draw(
    r: c.rl.Rectangle,
    tracks: []Track,
    alloc: std.mem.Allocator,
    selected_track: *?usize,
    selected_clip: *?ClipRef,
    transport: *Transport,
    m: widgets.Mouse,
) Result {
    var result: Result = .{};
    c.rl.DrawRectangleRec(r, theme.pane_bg);

    const header_w = theme.trackHeaderW();
    const timeline_x = r.x;
    const timeline_w = r.width - header_w;
    const header_x = r.x + timeline_w;
    const timeline_x0 = timeline_x + 2;

    // ── Layout slices ────────────────────────────────────────────────
    const overview_rect = widgets.rect(timeline_x, r.y, timeline_w, overviewH());
    const ruler_rect = widgets.rect(timeline_x, r.y + overviewH(), timeline_w, rulerH());
    const hdr_top = widgets.rect(header_x, r.y, header_w, overviewH() + rulerH());

    // Header column "ruler" block (spans overview + ruler rows).
    widgets.bevelSunken(hdr_top, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("TRACKS", header_x + 4, r.y + 4, theme.fsTiny(), theme.text_dim);
    const add_sz = @min(hdr_top.height - 4, theme.size(18));
    var tool_x = hdr_top.x + hdr_top.width - add_sz - 2;
    const add_rect = widgets.rect(tool_x, hdr_top.y + 2, add_sz, add_sz);
    if (widgets.iconButtonTip(add_rect, .plus, null, "Add track", m)) {
        result.add_track = true;
    }
    tool_x -= add_sz + 1;
    if (widgets.iconButtonTip(widgets.rect(tool_x, hdr_top.y + 2, add_sz, add_sz), .x, null, "Clear loop", m)) {
        transport.clearLoop();
    }
    tool_x -= add_sz + 1;
    if (widgets.iconButtonTip(widgets.rect(tool_x, hdr_top.y + 2, add_sz, add_sz), .repeat, null, "Loop selected clips", m)) {
        if (selectedClipRange(tracks)) |range| transport.setLoopBeats(range.start, range.end);
    }
    tool_x -= add_sz + 1;
    if (widgets.iconButtonTip(widgets.rect(tool_x, hdr_top.y + 2, add_sz, add_sz), .repeat, theme.slab_lo, "Loop entire arrangement", m)) {
        const end = @max(4.0, contentEndBeats(tracks));
        transport.setLoopBeats(0, end);
    }

    // Clamp scrolls once we know content extent.
    const content_beats = contentBeats(tracks);
    const lanes_h = r.y + r.height - (r.y + overviewH() + rulerH());
    const lanes_top = r.y + overviewH() + rulerH();

    // ── Wheel input (scroll / zoom) ──────────────────────────────────
    handleWheel(widgets.rect(timeline_x, r.y, timeline_w, r.height), m);

    // ── Continue an in-progress clip drag ─────────────────────────────
    continueDrag(tracks, alloc, selected_clip, m, lanes_top);
    updateBoxSelect(tracks, selected_track, selected_clip, m, timeline_x, timeline_w, timeline_x0, lanes_top);

    clampScroll(content_beats, timeline_w);
    clampScrollY(tracks.len, lanes_h);

    // ── Ruler ────────────────────────────────────────────────────────
    widgets.bevelSunken(ruler_rect, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    c.rl.BeginScissorMode(
        @intFromFloat(ruler_rect.x),
        @intFromFloat(ruler_rect.y),
        @intFromFloat(ruler_rect.width),
        @intFromFloat(ruler_rect.height),
    );
    drawLoopRegion(ruler_rect, timeline_x0, transport);
    drawBeatTicks(ruler_rect, timeline_x, timeline_w, timeline_x0);
    c.rl.EndScissorMode();

    handleLoopBounds(ruler_rect, timeline_x0, transport, m);
    // Click / drag the ruler to scrub the playhead.
    if (!loop_start_drag and !loop_end_drag) handleRulerScrub(ruler_rect, timeline_x0, transport, m);

    // ── Per-track lane + clips ───────────────────────────────────────
    var press_consumed = false;

    // Scissor-clip the timeline zone so clips don't bleed into the
    // header column or above/below the lanes.
    c.rl.BeginScissorMode(
        @intFromFloat(timeline_x),
        @intFromFloat(lanes_top),
        @intFromFloat(timeline_w),
        @intFromFloat(r.y + r.height - lanes_top),
    );
    for (tracks, 0..) |*t, ti| {
        const ly = lanes_top + @as(f32, @floatFromInt(ti)) * theme.laneH() - scroll_y;
        if (ly + theme.laneH() <= lanes_top) continue;
        if (ly >= r.y + r.height) break;
        const lane_timeline = widgets.rect(timeline_x, ly, timeline_w, theme.laneH());
        const lane_is_sel = selected_track.* != null and selected_track.*.? == ti;
        drawTimelineLane(lane_timeline, t.*, ti, lane_is_sel, timeline_x0);
        const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);

        // Hit-test pass (reverse order, topmost first).
        var i: usize = t.clips.items.len;
        while (i > 0) {
            i -= 1;
            const clip = &t.clips.items[i];
            const clip_rect = clipRect(lane_timeline, clip.*, timeline_x0);
            if (!press_consumed and widgets.contains(clip_rect, m.x, m.y)) {
                const edge_hover = m.x >= clip_rect.x + clip_rect.width - resizeEdgeW();
                if (!widgets.hasActiveDrag()) {
                    widgets.requestCursor(if (edge_hover) c.rl.MOUSE_CURSOR_RESIZE_EW else c.rl.MOUSE_CURSOR_POINTING_HAND, 1);
                }
                if (m.left_pressed and !widgets.hasActiveDrag()) {
                    const ref: ClipRef = .{ .track = @intCast(ti), .clip = @intCast(i) };
                    if (shift) {
                        clip.selected = !clip.selected;
                    } else if (!clip.selected) {
                        deselectAllClips(tracks);
                        clip.selected = true;
                    }
                    if (!clip.selected) {
                        selected_clip.* = null;
                        press_consumed = true;
                        break;
                    }
                    selected_clip.* = ref;
                    selected_track.* = ti;
                    press_consumed = true;
                    const mode: DragMode = if (edge_hover) .resize_r else .move;
                    beginDrag(tracks, ref, clip.*, m, mode);
                }
            }
        }

        // Draw pass (forward order).
        for (t.clips.items) |*clip| {
            const clip_rect = clipRect(lane_timeline, clip.*, timeline_x0);
            drawClip(clip_rect, clip.*, t.color, clip.selected);
        }

        // Double-click on empty timeline area → create clip.
        if (!press_consumed and m.double_clicked and widgets.contains(lane_timeline, m.x, m.y)) {
            const beat = snap(@as(f64, (m.x - timeline_x0 + scroll_x) / px_per_beat));
            const start = if (beat < 0) 0 else beat;
            deselectAllClips(tracks);
            createClipOnTrack(t, alloc, ti, start, selected_clip);
            selected_track.* = ti;
            press_consumed = true;
        }

        // Single click on empty timeline area → track-only selection.
        if (!press_consumed and m.left_pressed and widgets.contains(lane_timeline, m.x, m.y) and !widgets.hasActiveDrag()) {
            beginBoxSelect(ti, m, shift);
            press_consumed = true;
        }
    }

    c.rl.EndScissorMode();
    drawBoxSelectOverlay(timeline_x, timeline_w, lanes_top, r.y + r.height, m);

    // Playhead spans the ruler and all lanes. Scissor to the
    // timeline zone so it doesn't cross into the track-header column.
    const playhead_top = r.y + overviewH();
    c.rl.BeginScissorMode(
        @intFromFloat(timeline_x),
        @intFromFloat(playhead_top),
        @intFromFloat(timeline_w),
        @intFromFloat(r.y + r.height - playhead_top),
    );
    const beats_pos: f32 = @floatCast(transport.beats());
    const playhead_x = timeline_x0 + beats_pos * px_per_beat - scroll_x;
    c.rl.DrawRectangle(
        @intFromFloat(playhead_x),
        @intFromFloat(playhead_top),
        1,
        @intFromFloat(r.y + r.height - playhead_top),
        theme.accent_hi,
    );
    c.rl.EndScissorMode();

    c.rl.BeginScissorMode(
        @intFromFloat(timeline_x),
        @intFromFloat(lanes_top),
        @intFromFloat(timeline_w),
        @intFromFloat(r.y + r.height - lanes_top),
    );
    drawLoopRegion(widgets.rect(timeline_x, lanes_top, timeline_w, r.y + r.height - lanes_top), timeline_x0, transport);
    c.rl.EndScissorMode();

    // Track headers — live in the right column but scroll vertically
    // with the lanes. Scissor to the lane band so they don't leak
    // into the overview strip or beyond the bottom.
    c.rl.BeginScissorMode(
        @intFromFloat(header_x),
        @intFromFloat(lanes_top),
        @intFromFloat(header_w),
        @intFromFloat(r.y + r.height - lanes_top),
    );
    for (tracks, 0..) |*t, ti| {
        const ly = lanes_top + @as(f32, @floatFromInt(ti)) * theme.laneH() - scroll_y;
        if (ly + theme.laneH() <= lanes_top) continue;
        if (ly >= r.y + r.height) break;
        const lane_header = widgets.rect(header_x, ly, header_w, theme.laneH());
        const lane_is_sel = selected_track.* != null and selected_track.*.? == ti;
        if (drawLaneHeader(lane_header, t, lane_is_sel, m)) {
            selected_track.* = ti;
            deselectAllClips(tracks);
            // Clear clip selection unless the clicked track already
            // owns the currently-selected clip.
            selected_clip.* = null;
        }
    }
    c.rl.EndScissorMode();

    // Lazy vertical scrollbar.
    const lanes_rect = widgets.rect(r.x, lanes_top, r.width, r.y + r.height - lanes_top);
    drawAndHandleScrollbar(lanes_rect, @as(f32, @floatFromInt(tracks.len)) * theme.laneH(), m);

    // Overview strip on top (rendered last so nothing scissor-clips it).
    drawOverview(overview_rect, timeline_w, tracks, content_beats, transport, m);
    return result;
}

fn handleWheel(zone: c.rl.Rectangle, m: widgets.Mouse) void {
    if (!widgets.contains(zone, m.x, m.y)) return;
    if (m.wheel_x == 0 and m.wheel_y == 0) return;
    if (m.y < zone.y + overviewH()) return;
    const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
    const alt = c.rl.IsKeyDown(c.rl.KEY_LEFT_ALT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_ALT);

    if (shift) {
        // macOS flips Shift+wheel onto the horizontal axis — take
        // whichever is non-zero.
        const w: f32 = if (m.wheel_y != 0) m.wheel_y else m.wheel_x;
        if (w != 0) {
            const timeline_x0 = zone.x + 2;
            const mouse_beat = (m.x - timeline_x0 + scroll_x) / px_per_beat;
            const factor: f32 = std.math.clamp(1.0 + w * 0.12, 0.5, 2.0);
            px_per_beat = std.math.clamp(px_per_beat * factor, PX_PER_BEAT_MIN, PX_PER_BEAT_MAX);
            scroll_x = mouse_beat * px_per_beat - (m.x - timeline_x0);
        }
    } else if (alt) {
        // No vertical track-zoom yet — swallow so it doesn't fall
        // through to plain scroll.
    } else {
        scroll_x -= m.wheel_x * 30;
        scroll_y -= m.wheel_y * 30;
    }
    last_scroll_time = c.rl.GetTime();
}

fn contentBeats(tracks: []Track) f64 {
    return contentEndBeats(tracks) + CONTENT_PAD_BEATS;
}

fn contentEndBeats(tracks: []Track) f64 {
    var max_end: f64 = DEFAULT_CONTENT_BEATS;
    for (tracks) |t| {
        for (t.clips.items) |clip| {
            const end = clip.start_beat + clip.length_beats;
            if (end > max_end) max_end = end;
        }
    }
    return max_end;
}

fn selectedClipRange(tracks: []Track) ?struct { start: f64, end: f64 } {
    var found = false;
    var start: f64 = 0;
    var end: f64 = 0;
    for (tracks) |t| {
        for (t.clips.items) |clip| {
            if (!clip.selected) continue;
            if (!found) {
                found = true;
                start = clip.start_beat;
                end = clip.start_beat + clip.length_beats;
            } else {
                start = @min(start, clip.start_beat);
                end = @max(end, clip.start_beat + clip.length_beats);
            }
        }
    }
    return if (found) .{ .start = start, .end = end } else null;
}

fn clampScroll(content_beats: f64, timeline_w: f32) void {
    const max_sx = @max(0.0, @as(f32, @floatCast(content_beats)) * px_per_beat - timeline_w);
    if (scroll_x < 0) scroll_x = 0;
    if (scroll_x > max_sx) scroll_x = max_sx;
}

fn clampScrollY(n_tracks: usize, lanes_h: f32) void {
    const content_h = @as(f32, @floatFromInt(n_tracks)) * theme.laneH();
    const max_sy = @max(0.0, content_h - lanes_h);
    if (scroll_y < 0) scroll_y = 0;
    if (scroll_y > max_sy) scroll_y = max_sy;
}

// ── Clip selection ───────────────────────────────────────────────────

fn deselectAllClips(tracks: []Track) void {
    for (tracks) |*t| {
        for (t.clips.items) |*clip| clip.selected = false;
    }
}

fn beginBoxSelect(track_idx: usize, m: widgets.Mouse, shift: bool) void {
    if (!widgets.tryStartDrag(BOX_KEY)) return;
    box_active = true;
    box_start_x = m.x;
    box_start_y = m.y;
    box_start_track = track_idx;
    box_shift = shift;
}

fn updateBoxSelect(
    tracks: []Track,
    selected_track: *?usize,
    selected_clip: *?ClipRef,
    m: widgets.Mouse,
    timeline_x: f32,
    timeline_w: f32,
    timeline_x0: f32,
    lanes_top: f32,
) void {
    if (!box_active) return;
    if (widgets.isDraggingKey(BOX_KEY) and m.left_down) return;

    const dx = m.x - box_start_x;
    const dy = m.y - box_start_y;
    if (@abs(dx) < BOX_MIN_DRAG and @abs(dy) < BOX_MIN_DRAG) {
        deselectAllClips(tracks);
        selected_track.* = box_start_track;
        selected_clip.* = null;
    } else {
        if (!box_shift) deselectAllClips(tracks);
        const box_r = normalizedRect(box_start_x, box_start_y, m.x, m.y);
        var primary: ?ClipRef = null;
        for (tracks, 0..) |*t, ti| {
            const ly = lanes_top + @as(f32, @floatFromInt(ti)) * theme.laneH() - scroll_y;
            const lane = widgets.rect(timeline_x, ly, timeline_w, theme.laneH());
            for (t.clips.items, 0..) |*clip, ci| {
                const clip_r = clipRect(lane, clip.*, timeline_x0);
                if (rectsOverlap(clip_r, box_r)) {
                    clip.selected = true;
                    primary = .{ .track = @intCast(ti), .clip = @intCast(ci) };
                }
            }
        }
        selected_clip.* = primary;
        if (primary) |p| selected_track.* = p.track;
    }
    box_active = false;
    box_start_track = null;
    widgets.cancelDrag();
}

fn drawBoxSelectOverlay(timeline_x: f32, timeline_w: f32, lanes_top: f32, lanes_bottom: f32, m: widgets.Mouse) void {
    if (!box_active) return;
    if (@abs(m.x - box_start_x) < BOX_MIN_DRAG and @abs(m.y - box_start_y) < BOX_MIN_DRAG) return;
    const rr = normalizedRect(box_start_x, box_start_y, m.x, m.y);
    const clipped = intersectRect(rr, widgets.rect(timeline_x, lanes_top, timeline_w, lanes_bottom - lanes_top)) orelse return;
    c.rl.DrawRectangleRec(clipped, c.rl.ColorAlpha(theme.accent_hi, 0.2));
    c.rl.DrawRectangleLinesEx(clipped, 1, theme.accent_hi);
}

fn normalizedRect(x0: f32, y0: f32, x1: f32, y1: f32) c.rl.Rectangle {
    const nx0 = @min(x0, x1);
    const ny0 = @min(y0, y1);
    const nx1 = @max(x0, x1);
    const ny1 = @max(y0, y1);
    return widgets.rect(nx0, ny0, nx1 - nx0, ny1 - ny0);
}

fn rectsOverlap(a: c.rl.Rectangle, b: c.rl.Rectangle) bool {
    return a.x < b.x + b.width and a.x + a.width > b.x and
        a.y < b.y + b.height and a.y + a.height > b.y;
}

fn intersectRect(a: c.rl.Rectangle, b: c.rl.Rectangle) ?c.rl.Rectangle {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.width, b.x + b.width);
    const y1 = @min(a.y + a.height, b.y + b.height);
    if (x1 <= x0 or y1 <= y0) return null;
    return widgets.rect(x0, y0, x1 - x0, y1 - y0);
}

// ── Clip drag ────────────────────────────────────────────────────────

fn beginDrag(tracks: []Track, ref: ClipRef, clip: Clip, m: widgets.Mouse, mode: DragMode) void {
    const key = widgets.keyFromIds(DRAG_SALT, ref.track, ref.clip);
    if (!widgets.tryStartDrag(key)) return;
    drag_mode = mode;
    drag_ref = ref;
    drag_start_beat = clip.start_beat;
    drag_start_length = clip.length_beats;
    drag_start_mouse_x = m.x;
    drag_track_delta = 0;
    drag_snap_count = 0;
    if (mode == .move) {
        snapshotSelectedClips(tracks);
    }
}

fn continueDrag(tracks: []Track, alloc: std.mem.Allocator, selected_clip: *?ClipRef, m: widgets.Mouse, lanes_top: f32) void {
    if (drag_mode == .none) return;
    const key = widgets.keyFromIds(DRAG_SALT, drag_ref.track, drag_ref.clip);
    if (!widgets.isDraggingKey(key)) {
        drag_mode = .none;
        return;
    }

    if (!m.left_down) {
        finishClipDrag(tracks, alloc, selected_clip, m, lanes_top);
        widgets.cancelDrag();
        drag_mode = .none;
        return;
    }

    if (drag_ref.track >= tracks.len) {
        widgets.cancelDrag();
        drag_mode = .none;
        return;
    }
    const t = &tracks[drag_ref.track];
    if (drag_ref.clip >= t.clips.items.len) {
        widgets.cancelDrag();
        drag_mode = .none;
        return;
    }
    const clip = &t.clips.items[drag_ref.clip];

    const dx = m.x - drag_start_mouse_x;
    const d_beats = snap(@as(f64, dx / px_per_beat));
    drag_track_delta = @as(i32, @intFromFloat(@floor((m.y - lanes_top + scroll_y) / theme.laneH()))) - @as(i32, @intCast(drag_ref.track));

    switch (drag_mode) {
        .none => {},
        .move => {
            widgets.requestCursor(c.rl.MOUSE_CURSOR_POINTING_HAND, 3);
            if (drag_snap_count > 0) {
                for (drag_snaps[0..drag_snap_count]) |s| {
                    if (s.track >= tracks.len) continue;
                    const st = &tracks[s.track];
                    if (s.clip >= st.clips.items.len) continue;
                    const new_start = s.start_beat + d_beats;
                    st.clips.items[s.clip].start_beat = if (new_start < 0) 0 else new_start;
                }
            } else {
                const new_start = drag_start_beat + d_beats;
                clip.start_beat = if (new_start < 0) 0 else new_start;
            }
        },
        .resize_r => {
            widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
            const new_len = drag_start_length + d_beats;
            clip.length_beats = if (new_len < MIN_CLIP_BEATS) MIN_CLIP_BEATS else new_len;
        },
    }
}

fn finishClipDrag(tracks: []Track, alloc: std.mem.Allocator, selected_clip: *?ClipRef, m: widgets.Mouse, lanes_top: f32) void {
    if (drag_mode == .none) return;
    if (drag_ref.track >= tracks.len) return;
    const src_t = &tracks[drag_ref.track];
    if (drag_ref.clip >= src_t.clips.items.len) return;

    const target_i_signed = @as(i32, @intFromFloat(@floor((m.y - lanes_top + scroll_y) / theme.laneH())));
    if (target_i_signed < 0) return;
    const target_i: usize = @intCast(target_i_signed);
    if (target_i >= tracks.len or target_i == drag_ref.track) return;

    if (drag_snap_count > 0) {
        moveSelectedClipsBetweenTracks(tracks, alloc, selected_clip, target_i_signed - @as(i32, @intCast(drag_ref.track)));
        return;
    }

    var moved = src_t.clips.orderedRemove(drag_ref.clip);
    moved.selected = true;
    tracks[target_i].addClip(alloc, moved) catch |err| {
        std.log.err("move clip failed: {s}", .{@errorName(err)});
        moved.deinit(alloc);
        return;
    };
    selected_clip.* = .{
        .track = @intCast(target_i),
        .clip = @intCast(tracks[target_i].clips.items.len - 1),
    };
}

fn snapshotSelectedClips(tracks: []Track) void {
    drag_snap_count = 0;
    for (tracks, 0..) |*t, ti| {
        for (t.clips.items, 0..) |clip, ci| {
            if (!clip.selected) continue;
            if (drag_snap_count >= MAX_DRAG_CLIPS) return;
            drag_snaps[drag_snap_count] = .{
                .track = @intCast(ti),
                .clip = @intCast(ci),
                .start_beat = clip.start_beat,
            };
            drag_snap_count += 1;
        }
    }
}

fn moveSelectedClipsBetweenTracks(tracks: []Track, alloc: std.mem.Allocator, selected_clip: *?ClipRef, delta: i32) void {
    if (delta == 0) return;
    var moved: [MAX_DRAG_CLIPS]struct { clip: Clip, target: usize, primary: bool } = undefined;
    var moved_count: usize = 0;

    var s_i = drag_snap_count;
    while (s_i > 0) {
        s_i -= 1;
        const s = drag_snaps[s_i];
        if (s.track >= tracks.len) continue;
        const target_signed = @as(i32, @intCast(s.track)) + delta;
        if (target_signed < 0 or target_signed >= @as(i32, @intCast(tracks.len))) continue;
        const st = &tracks[s.track];
        if (s.clip >= st.clips.items.len) continue;
        if (!st.clips.items[s.clip].selected) continue;
        moved[moved_count] = .{
            .clip = st.clips.orderedRemove(s.clip),
            .target = @intCast(target_signed),
            .primary = s.track == drag_ref.track and s.clip == drag_ref.clip,
        };
        moved_count += 1;
    }

    var primary_ref: ?ClipRef = null;
    for (moved[0..moved_count]) |*entry| {
        entry.clip.selected = true;
        const target = entry.target;
        tracks[target].addClip(alloc, entry.clip) catch |err| {
            std.log.err("move selected clips failed: {s}", .{@errorName(err)});
            entry.clip.deinit(alloc);
            continue;
        };
        if (entry.primary) {
            primary_ref = .{
                .track = @intCast(target),
                .clip = @intCast(tracks[target].clips.items.len - 1),
            };
        }
    }
    selected_clip.* = primary_ref;
}

// ── Rendering helpers ────────────────────────────────────────────────

fn drawBeatTicks(ruler: c.rl.Rectangle, timeline_x: f32, timeline_w: f32, timeline_x0: f32) void {
    var beat: u32 = 0;
    while (true) {
        const bx = timeline_x0 + @as(f32, @floatFromInt(beat)) * px_per_beat - scroll_x;
        if (bx > timeline_x + timeline_w - 2) break;
        if (bx < timeline_x - 20) {
            beat += 1;
            continue;
        }
        const is_bar = beat % 4 == 0;
        const tick_h: f32 = if (is_bar) rulerH() - 4 else 5;
        c.rl.DrawRectangle(
            @intFromFloat(bx),
            @intFromFloat(ruler.y + rulerH() - tick_h - 2),
            1,
            @intFromFloat(tick_h),
            if (is_bar) theme.grid_bar else theme.grid_beat,
        );
        if (is_bar) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "{d}", .{beat / 4 + 1}) catch "?";
            widgets.drawLabelF(s.ptr, bx + 2, ruler.y + 1, theme.fsTiny(), theme.text_dim);
        }
        beat += 1;
    }
}

fn drawTimelineLane(r: c.rl.Rectangle, t: Track, idx: usize, selected: bool, timeline_x0: f32) void {
    const bg = if (selected) theme.pane_alt else if (idx % 2 == 0) theme.pane_bg else theme.pane_alt;
    c.rl.DrawRectangleRec(r, bg);

    var beat: u32 = 0;
    while (true) {
        const bx = timeline_x0 + @as(f32, @floatFromInt(beat)) * px_per_beat - scroll_x;
        if (bx > r.x + r.width - 1) break;
        if (bx >= r.x) {
            const is_bar = beat % 4 == 0;
            c.rl.DrawRectangle(
                @intFromFloat(bx),
                @intFromFloat(r.y),
                1,
                @intFromFloat(r.height),
                if (is_bar) theme.grid_bar else theme.grid_beat,
            );
        }
        beat += 1;
    }

    c.rl.DrawRectangle(@intFromFloat(r.x), @intFromFloat(r.y), 2, @intFromFloat(r.height), t.color);
    c.rl.DrawRectangle(
        @intFromFloat(r.x),
        @intFromFloat(r.y + r.height - 1),
        @intFromFloat(r.width),
        1,
        theme.slab_edge,
    );
}

fn clipRect(lane: c.rl.Rectangle, clip: Clip, timeline_x0: f32) c.rl.Rectangle {
    const x = timeline_x0 + @as(f32, @floatCast(clip.start_beat)) * px_per_beat - scroll_x;
    const w = @as(f32, @floatCast(clip.length_beats)) * px_per_beat;
    return widgets.rect(x, lane.y + 2, w, lane.height - 4);
}

fn drawClip(r: c.rl.Rectangle, clip: Clip, color: c.rl.Color, selected: bool) void {
    // Body — dimmed track color
    const body = dim(color, 0.55);
    c.rl.DrawRectangleRec(r, body);

    // Top strip with brighter color carrying the clip name.
    const strip_h: f32 = 11;
    const strip = widgets.rect(r.x, r.y, r.width, strip_h);
    c.rl.DrawRectangleRec(strip, color);

    // Border
    const edge = if (selected) theme.text_fg else theme.slab_edge;
    c.rl.DrawRectangleLinesEx(r, 1, edge);

    // Name
    var name_buf: [clip_mod.MAX_NAME + 1:0]u8 = undefined;
    const n = clip.name();
    const copy_n = @min(n.len, clip_mod.MAX_NAME);
    @memcpy(name_buf[0..copy_n], n[0..copy_n]);
    name_buf[copy_n] = 0;
    widgets.drawLabelF(
        @ptrCast(&name_buf[0]),
        r.x + 3,
        r.y,
        theme.fsTiny(),
        theme.bg,
    );

    // Tiny note ticks in the body to hint content (only if there are notes).
    if (clip.notes.items.len > 0) {
        const body_top = r.y + strip_h + 1;
        const body_h = r.height - strip_h - 2;
        const pitch_lo: f32 = 36; // C2
        const pitch_hi: f32 = 84; // C6
        for (clip.notes.items) |note| {
            const nx = r.x + @as(f32, @floatCast(note.start_beat)) * px_per_beat;
            const nw = @max(@as(f32, @floatCast(note.length_beats)) * px_per_beat, 1);
            if (nx + nw < r.x or nx > r.x + r.width) continue;
            const pitch_n = (@as(f32, @floatFromInt(note.pitch)) - pitch_lo) / (pitch_hi - pitch_lo);
            const ny = body_top + (1 - std.math.clamp(pitch_n, 0, 1)) * body_h - 1;
            const x0 = @max(nx, r.x + 1);
            const x1 = @min(nx + nw, r.x + r.width - 1);
            if (x1 > x0) {
                c.rl.DrawRectangle(@intFromFloat(x0), @intFromFloat(ny), @intFromFloat(x1 - x0), 1, theme.text_fg);
            }
        }
    }
}

fn drawLaneHeader(r: c.rl.Rectangle, t: *Track, selected: bool, m: widgets.Mouse) bool {
    const bg = if (selected) theme.slab_fill else theme.pane_bg;
    c.rl.DrawRectangleRec(r, bg);
    c.rl.DrawRectangle(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.width), 1, theme.slab_edge);
    c.rl.DrawRectangle(
        @intFromFloat(r.x),
        @intFromFloat(r.y + r.height - 1),
        @intFromFloat(r.width),
        1,
        theme.slab_edge,
    );
    c.rl.DrawRectangle(@intFromFloat(r.x), @intFromFloat(r.y), 3, @intFromFloat(r.height), t.color);

    const meter_w = theme.fine(4);
    const meter_gap: f32 = 1;
    const meter_total = meter_w * 2 + meter_gap;
    const meter_x = r.x + r.width - meter_total - 3;
    const meter_y = r.y + 2;
    const meter_h = r.height - 4;
    const peaks = t.meter();
    widgets.meter(widgets.rect(meter_x, meter_y, meter_w, meter_h), peaks.l);
    widgets.meter(widgets.rect(meter_x + meter_w + meter_gap, meter_y, meter_w, meter_h), peaks.r);

    const content_x = r.x + 5;
    const content_w = meter_x - content_x - 4;

    const row1_y = r.y + 2;
    const btn_h = theme.size(12);
    const btn_w = theme.size(14);
    const solo_r = widgets.rect(content_x + content_w - btn_w, row1_y, btn_w, btn_h);
    const mute_r = widgets.rect(solo_r.x - btn_w - 2, row1_y, btn_w, btn_h);

    var name_buf: [track_mod.MAX_NAME + 1:0]u8 = undefined;
    const n = t.name();
    const copy_n = @min(n.len, track_mod.MAX_NAME);
    @memcpy(name_buf[0..copy_n], n[0..copy_n]);
    name_buf[copy_n] = 0;
    widgets.drawLabelF(@ptrCast(&name_buf[0]), content_x, row1_y + 1, theme.fsBody(), theme.text_fg);

    const is_muted = t.mute.load(.monotonic);
    const mute_fill = if (is_muted) theme.accent_rec else theme.slab_fill;
    widgets.bevelRaised(mute_r, mute_fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("M", mute_r.x + 3, mute_r.y, theme.fsTiny(), theme.text_fg);
    widgets.tooltip(mute_r, if (is_muted) "Unmute track" else "Mute track", m);
    if (widgets.contains(mute_r, m.x, m.y) and m.left_released and !widgets.hasActiveDrag()) {
        t.mute.store(!is_muted, .monotonic);
    }

    const is_solo = t.solo.load(.monotonic);
    const solo_fill = if (is_solo) theme.accent_hi else theme.slab_fill;
    widgets.bevelRaised(solo_r, solo_fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("S", solo_r.x + 4, solo_r.y, theme.fsTiny(), theme.text_fg);
    widgets.tooltip(solo_r, if (is_solo) "Unsolo track" else "Solo track", m);
    if (widgets.contains(solo_r, m.x, m.y) and m.left_released and !widgets.hasActiveDrag()) {
        t.solo.store(!is_solo, .monotonic);
    }

    const fader_h = theme.size(12);
    const row2_y = r.y + r.height - fader_h - 3;
    const vol_r = widgets.rect(content_x, row2_y, content_w, fader_h);
    var v_norm: f32 = std.math.clamp(t.volume() / 1.25, 0.0, 1.0);
    if (widgets.hFader(vol_r, &v_norm, m)) {
        t.setVolume(v_norm * 1.25);
    }
    widgets.tooltip(vol_r, "Track volume", m);

    const click_region = widgets.rect(content_x, r.y + 1, content_w - btn_w * 2 - 4, theme.size(14));
    if (widgets.contains(click_region, m.x, m.y) and m.left_pressed and !widgets.hasActiveDrag()) {
        return true;
    }
    return false;
}

fn createClipOnTrack(t: *Track, alloc: std.mem.Allocator, track_idx: usize, start_beat: f64, selected: *?ClipRef) void {
    var buf: [clip_mod.MAX_NAME]u8 = undefined;
    const name_str = std.fmt.bufPrint(&buf, "Clip {d}", .{t.clips.items.len + 1}) catch "Clip";
    var new_clip = Clip.init(name_str, start_beat, DEFAULT_CLIP_BEATS);
    new_clip.selected = true;
    t.addClip(alloc, new_clip) catch |err| {
        std.log.err("create clip failed: {s}", .{@errorName(err)});
        return;
    };
    selected.* = .{ .track = @intCast(track_idx), .clip = @intCast(t.clips.items.len - 1) };
}

/// Snap a beat value to the current grid (currently fixed at 1/4 beat
/// = sixteenth-note granularity).
fn snap(beats: f64) f64 {
    const grid: f64 = 0.25;
    return @round(beats / grid) * grid;
}

fn beatToX(timeline_x0: f32, beat: f64) f32 {
    return timeline_x0 + @as(f32, @floatCast(beat)) * px_per_beat - scroll_x;
}

fn beatAtX(timeline_x0: f32, x: f32) f64 {
    return @as(f64, (x - timeline_x0 + scroll_x) / px_per_beat);
}

fn drawLoopRegion(r: c.rl.Rectangle, timeline_x0: f32, transport: *const Transport) void {
    if (!transport.loopEnabled()) return;
    const s = transport.loopStartBeats();
    const e = transport.loopEndBeats();
    if (e <= s) return;
    const x0 = beatToX(timeline_x0, s);
    const x1 = beatToX(timeline_x0, e);
    const lx0 = std.math.clamp(x0, r.x, r.x + r.width);
    const lx1 = std.math.clamp(x1, r.x, r.x + r.width);
    if (lx1 > lx0) {
        c.rl.DrawRectangleRec(widgets.rect(lx0, r.y, lx1 - lx0, r.height), c.rl.ColorAlpha(theme.accent_hi, 0.14));
    }
    if (x0 >= r.x and x0 <= r.x + r.width) {
        c.rl.DrawRectangle(@intFromFloat(x0), @intFromFloat(r.y), 2, @intFromFloat(r.height), theme.accent_hi);
    }
    if (x1 >= r.x and x1 <= r.x + r.width) {
        c.rl.DrawRectangle(@intFromFloat(x1), @intFromFloat(r.y), 2, @intFromFloat(r.height), theme.accent_hi);
    }
}

// ── Ruler scrub ──────────────────────────────────────────────────────

fn handleLoopBounds(ruler: c.rl.Rectangle, timeline_x0: f32, transport: *Transport, m: widgets.Mouse) void {
    if (!transport.loopEnabled()) return;
    const start_x = beatToX(timeline_x0, transport.loopStartBeats());
    const end_x = beatToX(timeline_x0, transport.loopEndBeats());
    const start_hit = widgets.rect(start_x - 4, ruler.y, 8, ruler.height);
    const end_hit = widgets.rect(end_x - 4, ruler.y, 8, ruler.height);

    if (loop_start_drag or loop_end_drag) {
        widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
        const key = if (loop_start_drag) LOOP_START_KEY else LOOP_END_KEY;
        if (!widgets.isDraggingKey(key) or !m.left_down) {
            loop_start_drag = false;
            loop_end_drag = false;
            widgets.cancelDrag();
            return;
        }
        const beat = snap(beatAtX(timeline_x0, m.x));
        const s = transport.loopStartBeats();
        const e = transport.loopEndBeats();
        if (loop_start_drag) {
            transport.setLoopBeats(@max(0, @min(beat, e - 0.25)), e);
        } else {
            transport.setLoopBeats(s, @max(s + 0.25, beat));
        }
        return;
    }

    const over_start = widgets.contains(start_hit, m.x, m.y);
    const over_end = widgets.contains(end_hit, m.x, m.y);
    if (over_start or over_end) widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);
    if (!m.left_pressed or widgets.hasActiveDrag()) return;
    if (over_start and widgets.tryStartDrag(LOOP_START_KEY)) {
        loop_start_drag = true;
    } else if (over_end and widgets.tryStartDrag(LOOP_END_KEY)) {
        loop_end_drag = true;
    }
}

fn handleRulerScrub(ruler: c.rl.Rectangle, timeline_x0: f32, transport: *Transport, m: widgets.Mouse) void {
    if (ruler_drag) {
        if (!widgets.isDraggingKey(RULER_KEY) or !m.left_down) {
            ruler_drag = false;
            widgets.cancelDrag();
            return;
        }
        const beat = beatAtX(timeline_x0, m.x);
        transport.seekToBeats(beat);
        return;
    }

    if (!m.left_pressed) return;
    if (!widgets.contains(ruler, m.x, m.y)) return;
    if (widgets.hasActiveDrag()) return;

    if (!widgets.tryStartDrag(RULER_KEY)) return;
    ruler_drag = true;
    const beat = beatAtX(timeline_x0, m.x);
    transport.seekToBeats(beat);
}

// ── Lazy vertical scrollbar ──────────────────────────────────────────

fn drawAndHandleScrollbar(area: c.rl.Rectangle, content_h: f32, m: widgets.Mouse) void {
    if (content_h <= area.height) return;

    const now = c.rl.GetTime();
    const since_scroll = now - last_scroll_time;
    const near_right = m.x >= area.x + area.width - SCROLLBAR_HOVER_RANGE and
        m.x <= area.x + area.width and
        m.y >= area.y and m.y <= area.y + area.height;

    var alpha: f32 = 0;
    if (near_right or sbv_drag) {
        alpha = 1.0;
    } else if (since_scroll < SCROLLBAR_FADE_LINGER) {
        alpha = 1.0;
    } else if (since_scroll < SCROLLBAR_FADE_LINGER + SCROLLBAR_FADE_VISIBLE) {
        const t = (since_scroll - SCROLLBAR_FADE_LINGER) / SCROLLBAR_FADE_VISIBLE;
        alpha = 1.0 - @as(f32, @floatCast(t));
    }
    if (alpha <= 0 and !sbv_drag) return;

    const bar_x = area.x + area.width - scrollbarW();
    const track = widgets.rect(bar_x, area.y, scrollbarW(), area.height);
    c.rl.DrawRectangleRec(track, c.rl.ColorAlpha(theme.slab_edge, alpha * 0.6));

    const thumb_h = @max(16.0, (area.height / content_h) * area.height);
    const scroll_range = content_h - area.height;
    const track_range = area.height - thumb_h;
    const thumb_y = area.y + (scroll_y / scroll_range) * track_range;
    const thumb = widgets.rect(bar_x + 1, thumb_y, scrollbarW() - 2, thumb_h);

    const hover_thumb = widgets.contains(thumb, m.x, m.y);
    const thumb_color = if (sbv_drag or hover_thumb) theme.accent_hi else theme.slab_hi;
    c.rl.DrawRectangleRec(thumb, c.rl.ColorAlpha(thumb_color, alpha));

    if (sbv_drag) {
        if (!widgets.isDraggingKey(SBV_KEY) or !m.left_down) {
            sbv_drag = false;
            widgets.cancelDrag();
            return;
        }
        const dy = m.y - sbv_drag_start_mouse_y;
        scroll_y = sbv_drag_start_scroll_y + dy * (scroll_range / track_range);
        last_scroll_time = now;
        return;
    }

    if (!m.left_pressed) return;
    if (widgets.hasActiveDrag()) return;

    if (hover_thumb) {
        if (!widgets.tryStartDrag(SBV_KEY)) return;
        sbv_drag = true;
        sbv_drag_start_mouse_y = m.y;
        sbv_drag_start_scroll_y = scroll_y;
    } else if (widgets.contains(track, m.x, m.y)) {
        const page: f32 = area.height * 0.8;
        if (m.y < thumb.y) {
            scroll_y -= page;
        } else {
            scroll_y += page;
        }
        last_scroll_time = now;
    }
}

// ── Overview / minimap strip ─────────────────────────────────────────

fn drawOverview(
    strip: c.rl.Rectangle,
    timeline_w: f32,
    tracks: []Track,
    content_beats: f64,
    transport: *const Transport,
    m: widgets.Mouse,
) void {
    _ = timeline_w;
    widgets.bevelSunken(strip, theme.pane_bg, theme.slab_hi, theme.slab_lo);
    const inner = widgets.rect(strip.x + 2, strip.y + 2, strip.width - 4, strip.height - 4);
    c.rl.DrawRectangleRec(inner, theme.pane_bg);

    const cb: f32 = @max(@as(f32, @floatCast(content_beats)), 1.0);
    const px_per_beat_ov = inner.width / cb;

    // Each track gets a thin horizontal slice.
    if (tracks.len > 0) {
        const lane_h = @max(1.0, inner.height / @as(f32, @floatFromInt(tracks.len)));
        for (tracks, 0..) |*t, i| {
            const ly = inner.y + @as(f32, @floatFromInt(i)) * lane_h;
            for (t.clips.items) |clip| {
                const cx = inner.x + @as(f32, @floatCast(clip.start_beat)) * px_per_beat_ov;
                const cw = @max(@as(f32, @floatCast(clip.length_beats)) * px_per_beat_ov, 1.0);
                const x0 = std.math.clamp(cx, inner.x, inner.x + inner.width);
                const x1 = std.math.clamp(cx + cw, inner.x, inner.x + inner.width);
                if (x1 > x0) {
                    c.rl.DrawRectangle(
                        @intFromFloat(x0),
                        @intFromFloat(ly),
                        @intFromFloat(x1 - x0),
                        @intFromFloat(@max(1.0, lane_h - 1)),
                        t.color,
                    );
                }
            }
        }
    }

    // Viewport window.
    const view_beat_l = scroll_x / px_per_beat;
    const visible_beats = inner.width * 0 + (strip.width / px_per_beat); // nb: inner.width of strip equals timeline_w-4, close enough
    _ = visible_beats;
    const actual_visible_beats = (strip.width - 4) / px_per_beat;
    const view_beat_r = view_beat_l + actual_visible_beats;
    const vp_x = inner.x + view_beat_l * px_per_beat_ov;
    const vp_w = @max(1.0, (view_beat_r - view_beat_l) * px_per_beat_ov);
    const vp_x_cl = std.math.clamp(vp_x, inner.x, inner.x + inner.width);
    const vp_right_cl = std.math.clamp(vp_x + vp_w, inner.x, inner.x + inner.width);
    const vp = widgets.rect(vp_x_cl, inner.y, vp_right_cl - vp_x_cl, inner.height);
    c.rl.DrawRectangleRec(vp, c.rl.ColorAlpha(theme.accent_hi, 0.2));
    c.rl.DrawRectangleLinesEx(vp, 1, theme.accent_hi);

    // Playhead tick on the minimap.
    const beats_pos: f32 = @floatCast(transport.beats());
    const ph_x = inner.x + beats_pos * px_per_beat_ov;
    if (ph_x >= inner.x and ph_x <= inner.x + inner.width) {
        c.rl.DrawRectangle(@intFromFloat(ph_x), @intFromFloat(inner.y), 1, @intFromFloat(inner.height), theme.accent_hi);
    }

    handleOverviewInput(inner, vp_w, px_per_beat_ov, cb, strip.width - 4, m);
}

fn handleOverviewInput(
    inner: c.rl.Rectangle,
    vp_w: f32,
    px_per_beat_ov: f32,
    content_beats: f32,
    viewport_w: f32,
    m: widgets.Mouse,
) void {
    if (widgets.contains(inner, m.x, m.y) and (m.wheel_x != 0 or m.wheel_y != 0)) {
        const w: f32 = if (m.wheel_y != 0) m.wheel_y else m.wheel_x;
        const anchor_beat = (m.x - inner.x) / px_per_beat_ov;
        const factor: f32 = std.math.clamp(1.0 + w * 0.12, 0.5, 2.0);
        const min_px = @max(1.0, viewport_w / @max(content_beats, 1.0));
        px_per_beat = std.math.clamp(px_per_beat * factor, min_px, PX_PER_BEAT_MAX);
        scroll_x = anchor_beat * px_per_beat - viewport_w / 2.0;
        if (scroll_x < 0) scroll_x = 0;
        last_scroll_time = c.rl.GetTime();
        return;
    }

    if (ov_drag) {
        if (!widgets.isDraggingKey(OVERVIEW_KEY) or !m.left_down) {
            ov_drag = false;
            widgets.cancelDrag();
            return;
        }
        const want_vp_x = m.x - ov_drag_offset;
        const want_beat_l = (want_vp_x - inner.x) / px_per_beat_ov;
        scroll_x = want_beat_l * px_per_beat;
        if (scroll_x < 0) scroll_x = 0;
        last_scroll_time = c.rl.GetTime();
        return;
    }

    if (!m.left_pressed) return;
    if (!widgets.contains(inner, m.x, m.y)) return;
    if (widgets.hasActiveDrag()) return;

    const view_beat_l = scroll_x / px_per_beat;
    const vp_x = inner.x + view_beat_l * px_per_beat_ov;
    const on_vp = m.x >= vp_x and m.x <= vp_x + vp_w;

    if (!widgets.tryStartDrag(OVERVIEW_KEY)) return;
    ov_drag = true;
    if (on_vp) {
        ov_drag_offset = m.x - vp_x;
    } else {
        const want_vp_x = m.x - vp_w / 2;
        const want_beat_l = (want_vp_x - inner.x) / px_per_beat_ov;
        scroll_x = want_beat_l * px_per_beat;
        if (scroll_x < 0) scroll_x = 0;
        ov_drag_offset = vp_w / 2;
    }
}

fn dim(color: c.rl.Color, factor: f32) c.rl.Color {
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(color.r)) * factor),
        .g = @intFromFloat(@as(f32, @floatFromInt(color.g)) * factor),
        .b = @intFromFloat(@as(f32, @floatFromInt(color.b)) * factor),
        .a = color.a,
    };
}
