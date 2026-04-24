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

const DragMode = enum { none, move, resize_r };

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

// Overview-strip drag.
var ov_drag: bool = false;
var ov_drag_offset: f32 = 0;

// Ruler scrub.
const RULER_KEY: u64 = 0x5C0B_0001_AAAA_BBBB;
var ruler_drag: bool = false;

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

pub fn draw(
    r: c.rl.Rectangle,
    tracks: []Track,
    alloc: std.mem.Allocator,
    selected_track: *?usize,
    selected_clip: *?ClipRef,
    transport: *Transport,
    m: widgets.Mouse,
) void {
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

    // ── Wheel input (scroll / zoom) ──────────────────────────────────
    handleWheel(widgets.rect(timeline_x, r.y, timeline_w, r.height), m);

    // ── Continue an in-progress clip drag ─────────────────────────────
    continueDrag(tracks, m);

    // Clamp scrolls once we know content extent.
    const content_beats = contentBeats(tracks);
    const lanes_h = r.y + r.height - (r.y + overviewH() + rulerH());
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
    drawBeatTicks(ruler_rect, timeline_x, timeline_w, timeline_x0);
    c.rl.EndScissorMode();

    // Click / drag the ruler to scrub the playhead.
    handleRulerScrub(ruler_rect, timeline_x0, transport, m);

    // ── Per-track lane + clips ───────────────────────────────────────
    const lanes_top = r.y + overviewH() + rulerH();
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
        drawTimelineLane(lane_timeline, t.*, ti, lane_is_sel);

        // Hit-test pass (reverse order, topmost first).
        var i: usize = t.clips.items.len;
        while (i > 0) {
            i -= 1;
            const clip = &t.clips.items[i];
            const clip_rect = clipRect(lane_timeline, clip.*, timeline_x0);
            if (!press_consumed and widgets.contains(clip_rect, m.x, m.y)) {
                if (m.left_pressed and !widgets.hasActiveDrag()) {
                    const ref: ClipRef = .{ .track = @intCast(ti), .clip = @intCast(i) };
                    selected_clip.* = ref;
                    selected_track.* = ti;
                    press_consumed = true;
                    const mode: DragMode = if (m.x >= clip_rect.x + clip_rect.width - resizeEdgeW())
                        .resize_r
                    else
                        .move;
                    beginDrag(ref, clip.*, m, mode);
                }
            }
        }

        // Draw pass (forward order).
        for (t.clips.items, 0..) |*clip, ci| {
            const clip_rect = clipRect(lane_timeline, clip.*, timeline_x0);
            const is_sel = blk: {
                if (selected_clip.*) |s| if (s.track == ti and s.clip == ci) break :blk true;
                break :blk false;
            };
            drawClip(clip_rect, clip.*, t.color, is_sel);
        }

        // Double-click on empty timeline area → create clip.
        if (!press_consumed and m.double_clicked and widgets.contains(lane_timeline, m.x, m.y)) {
            const beat = snap(@as(f64, (m.x - timeline_x0 + scroll_x) / px_per_beat));
            const start = if (beat < 0) 0 else beat;
            createClipOnTrack(t, alloc, ti, start, selected_clip);
            selected_track.* = ti;
            press_consumed = true;
        }

        // Single click on empty timeline area → track-only selection.
        if (!press_consumed and m.left_pressed and widgets.contains(lane_timeline, m.x, m.y) and !widgets.hasActiveDrag()) {
            selected_track.* = ti;
            selected_clip.* = null;
            press_consumed = true;
        }
    }

    c.rl.EndScissorMode();

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
            // Clear clip selection unless the clicked track already
            // owns the currently-selected clip.
            if (selected_clip.*) |s| {
                if (s.track != ti) selected_clip.* = null;
            }
        }
    }
    c.rl.EndScissorMode();

    // Lazy vertical scrollbar.
    const lanes_rect = widgets.rect(r.x, lanes_top, r.width, r.y + r.height - lanes_top);
    drawAndHandleScrollbar(lanes_rect, @as(f32, @floatFromInt(tracks.len)) * theme.laneH(), m);

    // Overview strip on top (rendered last so nothing scissor-clips it).
    drawOverview(overview_rect, timeline_w, tracks, content_beats, transport, m);
}

fn handleWheel(zone: c.rl.Rectangle, m: widgets.Mouse) void {
    if (!widgets.contains(zone, m.x, m.y)) return;
    if (m.wheel_x == 0 and m.wheel_y == 0) return;
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
    var max_end: f64 = DEFAULT_CONTENT_BEATS;
    for (tracks) |t| {
        for (t.clips.items) |clip| {
            const end = clip.start_beat + clip.length_beats;
            if (end > max_end) max_end = end;
        }
    }
    return max_end + CONTENT_PAD_BEATS;
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

// ── Clip drag ────────────────────────────────────────────────────────

fn beginDrag(ref: ClipRef, clip: Clip, m: widgets.Mouse, mode: DragMode) void {
    const key = widgets.keyFromIds(DRAG_SALT, ref.track, ref.clip);
    if (!widgets.tryStartDrag(key)) return;
    drag_mode = mode;
    drag_ref = ref;
    drag_start_beat = clip.start_beat;
    drag_start_length = clip.length_beats;
    drag_start_mouse_x = m.x;
}

fn continueDrag(tracks: []Track, m: widgets.Mouse) void {
    if (drag_mode == .none) return;
    const key = widgets.keyFromIds(DRAG_SALT, drag_ref.track, drag_ref.clip);
    if (!widgets.isDraggingKey(key)) {
        drag_mode = .none;
        return;
    }

    if (!m.left_down) {
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

    switch (drag_mode) {
        .none => {},
        .move => {
            const new_start = drag_start_beat + d_beats;
            clip.start_beat = if (new_start < 0) 0 else new_start;
        },
        .resize_r => {
            const new_len = drag_start_length + d_beats;
            clip.length_beats = if (new_len < MIN_CLIP_BEATS) MIN_CLIP_BEATS else new_len;
        },
    }
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
            if (is_bar) theme.text_dim else theme.slab_lo,
        );
        if (is_bar) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "{d}", .{beat / 4 + 1}) catch "?";
            widgets.drawLabelF(s.ptr, bx + 2, ruler.y + 1, theme.fsTiny(), theme.text_dim);
        }
        beat += 1;
    }
}

fn drawTimelineLane(r: c.rl.Rectangle, t: Track, idx: usize, selected: bool) void {
    const bg = if (selected) theme.pane_alt else if (idx % 2 == 0) theme.pane_bg else theme.pane_alt;
    c.rl.DrawRectangleRec(r, bg);
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
    if (widgets.contains(mute_r, m.x, m.y) and m.left_released and !widgets.hasActiveDrag()) {
        t.mute.store(!is_muted, .monotonic);
    }

    const is_solo = t.solo.load(.monotonic);
    const solo_fill = if (is_solo) theme.accent_hi else theme.slab_fill;
    widgets.bevelRaised(solo_r, solo_fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("S", solo_r.x + 4, solo_r.y, theme.fsTiny(), theme.text_fg);
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

    const click_region = widgets.rect(content_x, r.y + 1, content_w - btn_w * 2 - 4, theme.size(14));
    if (widgets.contains(click_region, m.x, m.y) and m.left_pressed and !widgets.hasActiveDrag()) {
        return true;
    }
    return false;
}

fn createClipOnTrack(t: *Track, alloc: std.mem.Allocator, track_idx: usize, start_beat: f64, selected: *?ClipRef) void {
    var buf: [clip_mod.MAX_NAME]u8 = undefined;
    const name_str = std.fmt.bufPrint(&buf, "Clip {d}", .{t.clips.items.len + 1}) catch "Clip";
    const new_clip = Clip.init(name_str, start_beat, DEFAULT_CLIP_BEATS);
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

// ── Ruler scrub ──────────────────────────────────────────────────────

fn handleRulerScrub(ruler: c.rl.Rectangle, timeline_x0: f32, transport: *Transport, m: widgets.Mouse) void {
    if (ruler_drag) {
        if (!widgets.isDraggingKey(RULER_KEY) or !m.left_down) {
            ruler_drag = false;
            widgets.cancelDrag();
            return;
        }
        const beat = @as(f64, (m.x - timeline_x0 + scroll_x) / px_per_beat);
        transport.seekToBeats(beat);
        return;
    }

    if (!m.left_pressed) return;
    if (!widgets.contains(ruler, m.x, m.y)) return;
    if (widgets.hasActiveDrag()) return;

    if (!widgets.tryStartDrag(RULER_KEY)) return;
    ruler_drag = true;
    const beat = @as(f64, (m.x - timeline_x0 + scroll_x) / px_per_beat);
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

    handleOverviewInput(inner, vp_w, px_per_beat_ov, m);
}

fn handleOverviewInput(
    inner: c.rl.Rectangle,
    vp_w: f32,
    px_per_beat_ov: f32,
    m: widgets.Mouse,
) void {
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
