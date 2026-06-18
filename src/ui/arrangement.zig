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
const snap_mod = @import("snap.zig");
const track_mod = @import("../track.zig");
const Track = track_mod.Track;
const clip_mod = @import("../clip.zig");
const Clip = clip_mod.Clip;
const ClipRef = clip_mod.ClipRef;
const Transport = @import("../transport.zig").Transport;
const audio_pool_mod = @import("../audio_pool.zig");
const waveform = @import("../waveform.zig");
const meter_mod = @import("../meter.zig");

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

const DragMode = enum { none, move, resize_r, resize_l, fade_in, fade_out };
const ClipDragSnap = struct {
    track: u32,
    clip: u32,
    start_beat: f64,
};

// Module-scope state.
var px_per_beat: f32 = 24;
// Current project tempo, captured at the top of draw() so drag handlers
// (which don't take the transport) can convert beats↔source-seconds.
var cur_bpm: f64 = 120;
// Live meter map for this frame's grid, captured at the top of draw().
var default_meter_pts = [_]meter_mod.MeterPoint{.{ .start_bar = 0, .numerator = 4, .denominator = 4 }};
var cur_meter: meter_mod.MeterMap = .{ .points = &default_meter_pts };
var scroll_x: f32 = 0;
var scroll_y: f32 = 0;
var last_scroll_time: f64 = 0;

var drag_mode: DragMode = .none;
var drag_ref: ClipRef = .{ .track = 0, .clip = 0 };
var drag_start_beat: f64 = 0;
var drag_start_length: f64 = 0;
var drag_start_mouse_x: f32 = 0;
// Audio source window captured at the start of a left-edge trim.
var drag_start_audio_start_sec: f64 = 0;
var drag_start_audio_dur_sec: f64 = 0;
// Fade length captured at the start of a fade-handle drag.
var drag_start_fade_sec: f64 = 0;
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
const ARR_CONTEXT_KEY: u64 = 0xC077_7E17_AAAA_0001;

pub const CopiedClip = struct {
    rel_track: i32,
    clip: Clip,
};

pub const Result = struct {
    add_track: bool = false,
    command: widgets.EditCommand = .none,
    command_beat: ?f64 = null,
    command_track: ?usize = null,
    rename_clip: ?ClipRef = null,
    rename_track: ?usize = null,
    rename_rect: ?c.rl.Rectangle = null,
};

pub const RenameTarget = struct {
    kind: enum { none, track, clip } = .none,
    track: usize = 0,
    clip: usize = 0,
};

/// Which lane the machine bay reads — the audio selection (`selected_track`)
/// or the master bus. Owned by main; the arrangement flips it as the user
/// clicks the track area vs the master strip.
pub const DeviceSel = enum { audio, master };

/// Height of the pinned master strip at the bottom of the track bay.
fn masterStripH() f32 {
    return theme.laneH();
}

const ContextTarget = struct {
    beat: f64 = 0,
    track: ?usize = null,
};

var context_target: ContextTarget = .{};

pub fn cancelInteractions() bool {
    const had_active = drag_mode != .none or box_active or ov_drag or ruler_drag or loop_start_drag or loop_end_drag or sbv_drag;
    drag_mode = .none;
    box_active = false;
    ov_drag = false;
    ruler_drag = false;
    loop_start_drag = false;
    loop_end_drag = false;
    sbv_drag = false;
    widgets.cancelDrag();
    return had_active;
}

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

pub fn clearSelection(tracks: []Track, focused_clip: *?ClipRef) bool {
    var changed = false;
    for (tracks) |*t| {
        for (t.clips.items) |*clip| {
            if (clip.selected) changed = true;
            clip.selected = false;
        }
    }
    if (focused_clip.* != null) changed = true;
    focused_clip.* = null;
    return changed;
}

pub fn selectAllClips(tracks: []Track, selected_track: *?usize, focused_clip: *?ClipRef) bool {
    var changed = false;
    var primary: ?ClipRef = null;
    for (tracks, 0..) |*t, ti| {
        for (t.clips.items, 0..) |*clip, ci| {
            if (!clip.selected) changed = true;
            clip.selected = true;
            if (primary == null) primary = .{ .track = @intCast(ti), .clip = @intCast(ci) };
        }
    }
    focused_clip.* = primary;
    if (primary) |p| selected_track.* = p.track;
    return changed;
}

pub fn hasSelectedClips(tracks: []Track) bool {
    return selectedClipRange(tracks) != null;
}

fn hasAnyClips(tracks: []Track) bool {
    for (tracks) |t| {
        if (t.clips.items.len > 0) return true;
    }
    return false;
}

pub fn copySelectedClips(tracks: []Track, alloc: std.mem.Allocator, out: *std.ArrayList(CopiedClip)) bool {
    out.clearRetainingCapacity();
    var min_track: ?usize = null;
    var min_start: f64 = std.math.inf(f64);
    for (tracks, 0..) |*t, ti| {
        for (t.clips.items) |clip| {
            if (!clip.selected) continue;
            if (min_track == null or ti < min_track.?) min_track = ti;
            min_start = @min(min_start, clip.start_beat);
        }
    }
    const base_track = min_track orelse return false;
    errdefer {
        for (out.items) |*item| item.clip.deinit(alloc);
        out.clearRetainingCapacity();
    }
    for (tracks, 0..) |*t, ti| {
        for (t.clips.items) |*clip| {
            if (!clip.selected) continue;
            var copied = clip.clone(alloc) catch |err| {
                std.log.err("copy clip failed: {s}", .{@errorName(err)});
                continue;
            };
            copied.start_beat -= min_start;
            copied.selected = true;
            for (copied.notes.items) |*n| n.selected = false;
            out.append(alloc, .{
                .rel_track = @as(i32, @intCast(ti)) - @as(i32, @intCast(base_track)),
                .clip = copied,
            }) catch |err| {
                std.log.err("copy clip append failed: {s}", .{@errorName(err)});
                copied.deinit(alloc);
            };
        }
    }
    return out.items.len > 0;
}

pub fn pasteClips(
    tracks: []Track,
    alloc: std.mem.Allocator,
    selected_track: *?usize,
    focused_clip: *?ClipRef,
    items: []const CopiedClip,
    target_beat: f64,
    target_track: ?usize,
    edit_snap: snap_mod.Setting,
) bool {
    if (items.len == 0 or tracks.len == 0) return false;
    const base_track = target_track orelse selected_track.* orelse 0;
    deselectAllClips(tracks);
    var first: ?ClipRef = null;
    var changed = false;
    for (items) |*item| {
        const target_i_signed = @as(i32, @intCast(base_track)) + item.rel_track;
        if (target_i_signed < 0 or target_i_signed >= @as(i32, @intCast(tracks.len))) continue;
        const target_i: usize = @intCast(target_i_signed);
        var clip = item.clip.clone(alloc) catch |err| {
            std.log.err("paste clip clone failed: {s}", .{@errorName(err)});
            continue;
        };
        clip.start_beat = snap_mod.snapPositive(edit_snap, target_beat + clip.start_beat, false);
        clip.selected = true;
        tracks[target_i].addClip(alloc, clip) catch |err| {
            std.log.err("paste clip failed: {s}", .{@errorName(err)});
            clip.deinit(alloc);
            continue;
        };
        changed = true;
        if (first == null) first = .{
            .track = @intCast(target_i),
            .clip = @intCast(tracks[target_i].clips.items.len - 1),
        };
    }
    focused_clip.* = first;
    if (first) |p| selected_track.* = p.track;
    return changed;
}

pub fn loopSelectedClips(tracks: []Track, transport: *Transport) bool {
    if (selectedClipRange(tracks)) |range| {
        transport.setLoopBeats(range.start, range.end);
        return true;
    }
    return false;
}

pub fn loopArrangement(tracks: []Track, transport: *Transport) bool {
    transport.setLoopBeats(0, @max(4.0, contentEndBeats(tracks)));
    return true;
}

pub fn splitSelectedClipsAt(tracks: []Track, alloc: std.mem.Allocator, focused_clip: *?ClipRef, beat: f64, bpm: f64) bool {
    var changed = false;
    var first: ?ClipRef = null;
    for (tracks, 0..) |*t, ti| {
        const original_len = t.clips.items.len;
        var ci: usize = 0;
        while (ci < original_len) : (ci += 1) {
            var clip = &t.clips.items[ci];
            if (!clip.selected) continue;
            const local = beat - clip.start_beat;
            if (local <= minClipBeats(.note_16) or local >= clip.length_beats - minClipBeats(.note_16)) continue;

            // Audio clip: carve the source window at the split point. The
            // right part reads from where the left part stopped.
            if (clip.isAudio()) {
                const split_sec = local * 60.0 / @max(1.0, bpm);
                var right_a = Clip.initAudio(clip.name(), beat, clip.start_beat + clip.length_beats - beat, clip.audio.source);
                right_a.selected = true;
                right_a.audio.gain = clip.audio.gain;
                right_a.audio.start_sec = clip.audio.start_sec + split_sec;
                right_a.audio.dur_sec = @max(0.0, clip.audio.dur_sec - split_sec);
                clip.audio.dur_sec = split_sec;
                clip.length_beats = local;
                clip.selected = false;
                t.addClip(alloc, right_a) catch |err| {
                    std.log.err("split audio clip append failed: {s}", .{@errorName(err)});
                    continue;
                };
                changed = true;
                if (first == null) first = .{ .track = @intCast(ti), .clip = @intCast(t.clips.items.len - 1) };
                continue;
            }

            var right = Clip.init(clip.name(), beat, clip.start_beat + clip.length_beats - beat);
            right.selected = true;
            errdefer right.deinit(alloc);

            var ni: usize = 0;
            while (ni < clip.notes.items.len) {
                var note = clip.notes.items[ni];
                if (note.start_beat >= local) {
                    _ = clip.notes.orderedRemove(ni);
                    note.start_beat -= local;
                    note.selected = false;
                    right.addNote(alloc, note) catch |err| {
                        std.log.err("split clip note move failed: {s}", .{@errorName(err)});
                        continue;
                    };
                } else {
                    const note_end = note.start_beat + note.length_beats;
                    if (note_end > local) {
                        clip.notes.items[ni].length_beats = @max(minClipBeats(.note_16), local - note.start_beat);
                    }
                    ni += 1;
                }
            }

            clip.length_beats = local;
            clip.selected = false;
            t.addClip(alloc, right) catch |err| {
                std.log.err("split clip append failed: {s}", .{@errorName(err)});
                right.deinit(alloc);
                continue;
            };
            changed = true;
            if (first == null) first = .{ .track = @intCast(ti), .clip = @intCast(t.clips.items.len - 1) };
        }
    }
    if (first) |p| focused_clip.* = p;
    return changed;
}

pub fn nudgeSelectedClips(tracks: []Track, alloc: std.mem.Allocator, focused_clip: *?ClipRef, beat_delta: f64, track_delta: i32, edit_snap: snap_mod.Setting) bool {
    if (track_delta != 0) {
        return nudgeSelectedClipsTracks(tracks, alloc, focused_clip, track_delta);
    }
    if (beat_delta == 0) return false;
    var changed = false;
    for (tracks) |*t| {
        for (t.clips.items) |*clip| {
            if (!clip.selected) continue;
            const next = snap_mod.snapPositive(edit_snap, clip.start_beat + beat_delta, false);
            if (next != clip.start_beat) changed = true;
            clip.start_beat = next;
        }
    }
    return changed;
}

pub fn duplicateSelectedClips(tracks: []Track, alloc: std.mem.Allocator, selected_track: *?usize, focused_clip: *?ClipRef, edit_snap: snap_mod.Setting) bool {
    var first: ?ClipRef = null;
    var changed = false;

    for (tracks, 0..) |*t, ti| {
        const original_len = t.clips.items.len;
        var ci: usize = 0;
        while (ci < original_len) : (ci += 1) {
            const src = &t.clips.items[ci];
            if (!src.selected) continue;
            var dup = src.clone(alloc) catch |err| {
                std.log.err("duplicate clip failed: {s}", .{@errorName(err)});
                continue;
            };
            src.selected = false;
            const raw_start = src.start_beat + src.length_beats;
            const snapped_start = snap_mod.snapPositive(edit_snap, raw_start, false);
            dup.start_beat = if (snapped_start > src.start_beat) snapped_start else raw_start;
            dup.selected = true;
            for (dup.notes.items) |*n| n.selected = false;
            t.addClip(alloc, dup) catch |err| {
                std.log.err("duplicate clip append failed: {s}", .{@errorName(err)});
                dup.deinit(alloc);
                continue;
            };
            changed = true;
            if (first == null) first = .{ .track = @intCast(ti), .clip = @intCast(t.clips.items.len - 1) };
        }
    }
    focused_clip.* = first;
    if (first) |p| selected_track.* = p.track;
    return changed;
}

fn nudgeSelectedClipsTracks(tracks: []Track, alloc: std.mem.Allocator, focused_clip: *?ClipRef, delta: i32) bool {
    var moved: [MAX_DRAG_CLIPS]struct { clip: Clip, target: usize } = undefined;
    var moved_count: usize = 0;

    var ti: usize = tracks.len;
    while (ti > 0) {
        ti -= 1;
        var ci: usize = tracks[ti].clips.items.len;
        while (ci > 0) {
            ci -= 1;
            if (!tracks[ti].clips.items[ci].selected) continue;
            const target_signed = @as(i32, @intCast(ti)) + delta;
            if (target_signed < 0 or target_signed >= @as(i32, @intCast(tracks.len))) continue;
            if (moved_count >= MAX_DRAG_CLIPS) return moved_count > 0;
            moved[moved_count] = .{
                .clip = tracks[ti].clips.orderedRemove(ci),
                .target = @intCast(target_signed),
            };
            moved_count += 1;
        }
    }

    var first: ?ClipRef = null;
    for (moved[0..moved_count]) |*entry| {
        entry.clip.selected = true;
        tracks[entry.target].addClip(alloc, entry.clip) catch |err| {
            std.log.err("nudge clips between tracks failed: {s}", .{@errorName(err)});
            entry.clip.deinit(alloc);
            continue;
        };
        if (first == null) first = .{ .track = @intCast(entry.target), .clip = @intCast(tracks[entry.target].clips.items.len - 1) };
    }
    focused_clip.* = first;
    return moved_count > 0;
}

pub fn draw(
    r: c.rl.Rectangle,
    tracks: []Track,
    master: *Track,
    device_sel: *DeviceSel,
    pool: *const audio_pool_mod.AudioPool,
    alloc: std.mem.Allocator,
    selected_track: *?usize,
    selected_clip: *?ClipRef,
    transport: *Transport,
    meter_map: meter_mod.MeterMap,
    edit_snap: snap_mod.Setting,
    can_paste_clips: bool,
    rename_target: RenameTarget,
    m: widgets.Mouse,
) Result {
    var result: Result = .{};
    cur_meter = meter_map;
    c.rl.DrawRectangleRec(r, theme.pane_bg);

    // Audio clips are unwarped: their beat-length is derived from the source
    // window at the current tempo, so changing bpm rescales them against the
    // bar grid. Do this before any interaction/draw uses length_beats.
    cur_bpm = @max(1.0, @as(f64, transport.bpm()));
    reflowAudioClips(tracks, cur_bpm);

    var master_clicked = false;

    const header_w = theme.trackHeaderW();
    const timeline_x = r.x;
    const timeline_w = r.width - header_w;
    const header_x = r.x + timeline_w;
    const timeline_x0 = timeline_x + 2;

    // Pinned master strip at the bottom; the scrollable lane band shrinks
    // by its height.
    const master_h = masterStripH();
    const lanes_bottom = r.y + r.height - master_h;

    // ── Layout slices ────────────────────────────────────────────────
    const overview_rect = widgets.rect(timeline_x, r.y, timeline_w, overviewH());
    const ruler_rect = widgets.rect(timeline_x, r.y + overviewH(), timeline_w, rulerH());
    const hdr_top = widgets.rect(header_x, r.y, header_w, overviewH() + rulerH());

    // Header column "ruler" block (spans overview + ruler rows).
    widgets.bevelSunken(hdr_top, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("TRACKS", header_x + 4, r.y + 4, theme.fsTiny(), theme.text_dim);
    const add_sz = @min(hdr_top.height - 4, theme.size(18));
    const tool_x = hdr_top.x + hdr_top.width - add_sz - 2;
    const add_rect = widgets.rect(tool_x, hdr_top.y + 2, add_sz, add_sz);
    if (widgets.iconButtonTip(add_rect, .plus, null, "Add track", m)) {
        result.add_track = true;
    }
    // Loop controls moved off the track header — right-click the timeline for
    // Loop selection / Loop arrangement / Clear loop, plus ruler drag.

    // Clamp scrolls once we know content extent.
    const content_beats = contentBeats(tracks);
    const lanes_top = r.y + overviewH() + rulerH();
    const lanes_h = @max(0, lanes_bottom - lanes_top);

    // ── Wheel input (scroll / zoom) ──────────────────────────────────
    handleWheel(widgets.rect(timeline_x, r.y, timeline_w, r.height), m);

    // ── Continue an in-progress clip drag ─────────────────────────────
    continueDrag(tracks, alloc, selected_clip, edit_snap, m, lanes_top);
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
    drawBeatTicks(ruler_rect, timeline_x, timeline_w, timeline_x0, edit_snap);
    c.rl.EndScissorMode();

    handleLoopBounds(ruler_rect, timeline_x0, transport, edit_snap, m);
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
        @intFromFloat(lanes_bottom - lanes_top),
    );
    // Lane backgrounds first, then the loop region, so the loop marquee sits
    // behind the clips (drawn below).
    for (tracks, 0..) |*t, ti| {
        const ly = lanes_top + @as(f32, @floatFromInt(ti)) * theme.laneH() - scroll_y;
        if (ly + theme.laneH() <= lanes_top) continue;
        if (ly >= lanes_bottom) break;
        const lane_timeline = widgets.rect(timeline_x, ly, timeline_w, theme.laneH());
        const lane_is_sel = selected_track.* != null and selected_track.*.? == ti;
        drawTimelineLane(lane_timeline, t.*, ti, lane_is_sel, timeline_x0, edit_snap);
    }
    drawLoopRegion(widgets.rect(timeline_x, lanes_top, timeline_w, lanes_bottom - lanes_top), timeline_x0, transport);
    for (tracks, 0..) |*t, ti| {
        const ly = lanes_top + @as(f32, @floatFromInt(ti)) * theme.laneH() - scroll_y;
        if (ly + theme.laneH() <= lanes_top) continue;
        if (ly >= lanes_bottom) break;
        const lane_timeline = widgets.rect(timeline_x, ly, timeline_w, theme.laneH());
        const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);

        // Hit-test pass (reverse order, topmost first).
        var i: usize = t.clips.items.len;
        while (i > 0) {
            i -= 1;
            const clip = &t.clips.items[i];
            const clip_rect = clipRect(lane_timeline, clip.*, timeline_x0);
            if (!press_consumed and widgets.contains(clip_rect, m.x, m.y)) {
                // Audio fade handles live in the top corners (see drawClip);
                // detect them first so they win over move/trim in that zone.
                const fade_zone_h = @min(theme.size(10), clip_rect.height * 0.5);
                var fade_in_hover = false;
                var fade_out_hover = false;
                if (clip.isAudio() and clip.audio.dur_sec > 0 and m.y <= clip_rect.y + fade_zone_h) {
                    const dur = clip.audio.dur_sec;
                    const in_frac: f32 = @floatCast(std.math.clamp(clip.audio.fade_in_sec / dur, 0, 1));
                    const out_frac: f32 = @floatCast(std.math.clamp(clip.audio.fade_out_sec / dur, 0, 1));
                    const in_x = clip_rect.x + in_frac * clip_rect.width;
                    const out_x = clip_rect.x + clip_rect.width - out_frac * clip_rect.width;
                    const hit = theme.size(6);
                    fade_in_hover = @abs(m.x - in_x) <= hit;
                    fade_out_hover = !fade_in_hover and @abs(m.x - out_x) <= hit;
                }
                const edge_hover = !fade_out_hover and m.x >= clip_rect.x + clip_rect.width - resizeEdgeW();
                // Audio clips can be trimmed from the left edge (carving into
                // the source window); note clips only resize on the right.
                const left_edge_hover = clip.isAudio() and !fade_in_hover and m.x <= clip_rect.x + resizeEdgeW() and !edge_hover;
                if (!widgets.hasActiveDrag()) {
                    widgets.requestCursor(if (edge_hover or left_edge_hover or fade_in_hover or fade_out_hover) c.rl.MOUSE_CURSOR_RESIZE_EW else c.rl.MOUSE_CURSOR_POINTING_HAND, 1);
                    // Full clip name on hover-and-pause (the body label is truncated).
                    var tip_buf: [clip_mod.MAX_NAME + 1:0]u8 = undefined;
                    const nm = clip.name();
                    const cn = @min(nm.len, clip_mod.MAX_NAME);
                    @memcpy(tip_buf[0..cn], nm[0..cn]);
                    tip_buf[cn] = 0;
                    widgets.tooltip(clip_rect, @ptrCast(&tip_buf[0]), m);
                }
                if (m.double_clicked and !widgets.hasActiveDrag()) {
                    const ref: ClipRef = .{ .track = @intCast(ti), .clip = @intCast(i) };
                    deselectAllClips(tracks);
                    clip.selected = true;
                    selected_clip.* = ref;
                    selected_track.* = ti;
                    result.rename_clip = ref;
                    press_consumed = true;
                    break;
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
                    const mode: DragMode =
                        if (fade_in_hover) .fade_in else if (fade_out_hover) .fade_out else if (edge_hover) .resize_r else if (left_edge_hover) .resize_l else .move;
                    beginDrag(tracks, ref, clip.*, m, mode);
                }
                if (m.right_pressed and !widgets.hasActiveDrag()) {
                    const ref: ClipRef = .{ .track = @intCast(ti), .clip = @intCast(i) };
                    if (!clip.selected) {
                        deselectAllClips(tracks);
                        clip.selected = true;
                    }
                    selected_clip.* = ref;
                    selected_track.* = ti;
                    context_target = .{ .beat = beatAtX(timeline_x0, m.x), .track = ti };
                    _ = widgets.openContextMenu(ARR_CONTEXT_KEY, r, m);
                    press_consumed = true;
                }
            }
        }

        // Draw pass (forward order).
        for (t.clips.items, 0..) |*clip, ci| {
            const clip_rect = clipRect(lane_timeline, clip.*, timeline_x0);
            const editing = rename_target.kind == .clip and rename_target.track == ti and rename_target.clip == ci;
            drawClip(clip_rect, clip.*, t.color, clip.selected, editing, pool);
            if (editing) result.rename_rect = clipNameRect(clip_rect);
        }

        // Double-click on empty timeline area → create clip.
        if (!press_consumed and m.double_clicked and widgets.contains(lane_timeline, m.x, m.y)) {
            const beat = snap_mod.snapDownPositive(edit_snap, @as(f64, (m.x - timeline_x0 + scroll_x) / px_per_beat), altBypassSnap());
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

        if (!press_consumed and m.right_pressed and widgets.contains(lane_timeline, m.x, m.y) and !widgets.hasActiveDrag()) {
            selected_track.* = ti;
            selected_clip.* = null;
            deselectAllClips(tracks);
            context_target = .{ .beat = beatAtX(timeline_x0, m.x), .track = ti };
            _ = widgets.openContextMenu(ARR_CONTEXT_KEY, r, m);
            press_consumed = true;
        }
    }

    // Empty area below the last track (still inside the timeline) → start a
    // box-select from "nowhere": a plain click clears the whole selection,
    // a drag marquees from blank space. Right-click clears + opens the menu.
    if (!press_consumed and !widgets.hasActiveDrag()) {
        const lanes_zone = widgets.rect(timeline_x, lanes_top, timeline_w, lanes_bottom - lanes_top);
        if (widgets.contains(lanes_zone, m.x, m.y)) {
            const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
            if (m.left_pressed) {
                beginBoxSelect(null, m, shift);
                press_consumed = true;
            } else if (m.right_pressed) {
                selected_track.* = null;
                selected_clip.* = null;
                deselectAllClips(tracks);
                context_target = .{ .beat = beatAtX(timeline_x0, m.x), .track = null };
                _ = widgets.openContextMenu(ARR_CONTEXT_KEY, r, m);
                press_consumed = true;
            }
        }
    }

    c.rl.EndScissorMode();
    drawBoxSelectOverlay(timeline_x, timeline_w, lanes_top, lanes_bottom, m);

    // Playhead spans the ruler and all lanes (stops above the master strip).
    const playhead_top = r.y + overviewH();
    c.rl.BeginScissorMode(
        @intFromFloat(timeline_x),
        @intFromFloat(playhead_top),
        @intFromFloat(timeline_w),
        @intFromFloat(lanes_bottom - playhead_top),
    );
    const beats_pos: f32 = @floatCast(transport.beats());
    const playhead_x = timeline_x0 + beats_pos * px_per_beat - scroll_x;
    c.rl.DrawRectangle(
        @intFromFloat(playhead_x),
        @intFromFloat(playhead_top),
        1,
        @intFromFloat(lanes_bottom - playhead_top),
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
        @intFromFloat(lanes_bottom - lanes_top),
    );
    for (tracks, 0..) |*t, ti| {
        const ly = lanes_top + @as(f32, @floatFromInt(ti)) * theme.laneH() - scroll_y;
        if (ly + theme.laneH() <= lanes_top) continue;
        if (ly >= lanes_bottom) break;
        const lane_header = widgets.rect(header_x, ly, header_w, theme.laneH());
        const lane_is_sel = selected_track.* != null and selected_track.*.? == ti;
        const editing = rename_target.kind == .track and rename_target.track == ti;
        const hres = drawLaneHeader(lane_header, t, ti, lane_is_sel, editing, m);
        if (editing) result.rename_rect = hres.name_rect;
        switch (hres.action) {
            .none => {},
            .select => {
                selected_track.* = ti;
                deselectAllClips(tracks);
                selected_clip.* = null;
            },
            .rename => {
                selected_track.* = ti;
                deselectAllClips(tracks);
                selected_clip.* = null;
                result.rename_track = ti;
            },
        }
    }
    c.rl.EndScissorMode();

    // Lazy vertical scrollbar.
    const lanes_rect = widgets.rect(r.x, lanes_top, r.width, lanes_bottom - lanes_top);
    drawAndHandleScrollbar(lanes_rect, @as(f32, @floatFromInt(tracks.len)) * theme.laneH(), m);

    // Pinned master strip at the bottom of the track bay.
    {
        const strip = widgets.rect(r.x, lanes_bottom, r.width, master_h);
        if (drawMasterStrip(strip, header_x, header_w, timeline_x, timeline_w, master, device_sel.* == .master, m)) {
            master_clicked = true;
        }
    }

    // Flip the bay between master and audio: clicking the master strip parks
    // on master; clicking anywhere in the track lanes/headers returns to the
    // audio selection (even re-clicking the already-selected track).
    if (master_clicked) {
        device_sel.* = .master;
    } else if (m.left_pressed and widgets.contains(widgets.rect(r.x, lanes_top, r.width, lanes_h), m.x, m.y)) {
        device_sel.* = .audio;
    }

    // Overview strip on top (rendered last so nothing scissor-clips it).
    drawOverview(overview_rect, timeline_w, tracks, content_beats, transport, m);
    if (widgets.openContextMenu(ARR_CONTEXT_KEY, r, m)) {
        context_target = .{ .beat = beatAtX(timeline_x0, m.x), .track = selected_track.* };
    }
    const has_selection = hasSelectedClips(tracks);
    const has_clips = hasAnyClips(tracks);
    const arr_context_items = [_]widgets.MenuItem{
        .{ .label = "Import audio\u{2026}", .command = .import_audio, .enabled = tracks.len > 0 },
        .{ .separator = true },
        .{ .label = "Copy", .command = .copy, .enabled = has_selection },
        .{ .label = "Cut", .command = .cut, .enabled = has_selection },
        .{ .label = "Paste", .command = .paste, .enabled = can_paste_clips },
        .{ .separator = true },
        .{ .label = "Duplicate", .command = .duplicate, .enabled = has_selection },
        .{ .label = "Split at playhead", .command = .split_at_playhead, .enabled = has_selection },
        .{ .label = "Delete", .command = .delete, .enabled = has_selection },
        .{ .separator = true },
        .{ .label = "Rename", .command = .rename, .enabled = has_selection },
        .{ .label = "Select all", .command = .select_all, .enabled = has_clips },
        .{ .label = "Clear selection", .command = .clear_selection, .enabled = has_selection },
        .{ .separator = true },
        .{ .label = "Loop selection", .command = .loop_selection, .enabled = has_selection },
        .{ .label = "Loop arrangement", .command = .loop_arrangement, .enabled = has_clips },
        .{ .label = "Clear loop", .command = .clear_loop, .enabled = true },
    };
    result.command = widgets.contextMenu(ARR_CONTEXT_KEY, &arr_context_items, m);
    if (result.command != .none) {
        result.command_beat = context_target.beat;
        result.command_track = context_target.track;
    }
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

fn altBypassSnap() bool {
    return c.rl.IsKeyDown(c.rl.KEY_LEFT_ALT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_ALT);
}

fn minClipBeats(edit_snap: snap_mod.Setting) f64 {
    return @min(edit_snap.beats() orelse MIN_CLIP_BEATS, MIN_CLIP_BEATS);
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

/// Recompute every audio clip's `length_beats` from its source window at
/// `bpm`. The window (`dur_sec`) is tempo-independent, so this keeps the
/// clip's bar-span correct as the project tempo changes.
pub fn reflowAudioClips(tracks: []Track, bpm: f64) void {
    for (tracks) |*t| {
        for (t.clips.items) |*clip| {
            if (!clip.isAudio()) continue;
            clip.length_beats = @max(MIN_CLIP_BEATS, clip.audio.dur_sec * bpm / 60.0);
        }
    }
}

fn beginBoxSelect(track_idx: ?usize, m: widgets.Mouse, shift: bool) void {
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
    drag_start_audio_start_sec = clip.audio.start_sec;
    drag_start_audio_dur_sec = clip.audio.dur_sec;
    drag_start_fade_sec = switch (mode) {
        .fade_in => clip.audio.fade_in_sec,
        .fade_out => clip.audio.fade_out_sec,
        else => 0,
    };
    drag_track_delta = 0;
    drag_snap_count = 0;
    if (mode == .move) {
        snapshotSelectedClips(tracks);
    }
}

fn continueDrag(tracks: []Track, alloc: std.mem.Allocator, selected_clip: *?ClipRef, edit_snap: snap_mod.Setting, m: widgets.Mouse, lanes_top: f32) void {
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
    const d_beats = snap_mod.snapNearest(edit_snap, @as(f64, dx / px_per_beat), altBypassSnap());
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
            clip.length_beats = if (new_len < minClipBeats(edit_snap)) minClipBeats(edit_snap) else new_len;
            // For audio, resizing trims the source window so reflow keeps it.
            if (clip.isAudio()) clip.audio.dur_sec = clip.length_beats * 60.0 / cur_bpm;
        },
        .fade_in, .fade_out => {
            // Fades drag unsnapped in seconds, clamped to the window length.
            widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
            const raw_beats = @as(f64, dx / px_per_beat);
            const delta_sec = raw_beats * 60.0 / cur_bpm;
            const dur = clip.audio.dur_sec;
            if (drag_mode == .fade_in) {
                clip.audio.fade_in_sec = std.math.clamp(drag_start_fade_sec + delta_sec, 0, dur);
            } else {
                clip.audio.fade_out_sec = std.math.clamp(drag_start_fade_sec - delta_sec, 0, dur);
            }
        },
        .resize_l => {
            // Audio only: move the left edge while the right edge stays fixed,
            // carving into (or back out of) the front of the source window.
            widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
            const min_len = minClipBeats(edit_snap);
            const right_beat = drag_start_beat + drag_start_length;
            // Clamp the move so the window stays within [0, source] and the
            // clip keeps a minimum length.
            const sec_per_beat = 60.0 / cur_bpm;
            const max_back = drag_start_audio_start_sec / sec_per_beat; // can't trim before source start
            var delta = d_beats;
            if (delta < -max_back) delta = -max_back; // expanding left limited by source head
            if (delta > drag_start_length - min_len) delta = drag_start_length - min_len;
            if (drag_start_beat + delta < 0) delta = -drag_start_beat;
            const new_start = drag_start_beat + delta;
            clip.start_beat = new_start;
            clip.length_beats = right_beat - new_start;
            const delta_sec = delta * sec_per_beat;
            clip.audio.start_sec = @max(0.0, drag_start_audio_start_sec + delta_sec);
            clip.audio.dur_sec = @max(0.0, drag_start_audio_dur_sec - delta_sec);
        },
    }
}

fn finishClipDrag(tracks: []Track, alloc: std.mem.Allocator, selected_clip: *?ClipRef, m: widgets.Mouse, lanes_top: f32) void {
    if (drag_mode == .none) return;
    // Only a body move relocates between tracks; resizes stay on their lane.
    if (drag_mode != .move) return;
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

fn drawBeatTicks(ruler: c.rl.Rectangle, timeline_x: f32, timeline_w: f32, timeline_x0: f32, edit_snap: snap_mod.Setting) void {
    const right = timeline_x + timeline_w - 2;

    // Fine sub-grid (uniform snap guide), drawn under the meter lines.
    const step = snap_mod.visualStep(edit_snap, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = beatToX(timeline_x0, beat);
        if (bx > right) break;
        if (bx >= timeline_x) {
            c.rl.DrawRectangle(@intFromFloat(bx), @intFromFloat(ruler.y + rulerH() - 5), 1, 3, theme.grid_sub);
        }
        beat += step;
    }

    // Meter-driven bar lines + numbers and per-bar beat lines.
    const first_beat = @max(0.0, beatAtX(timeline_x0, timeline_x));
    var bar = cur_meter.beatToBarPos(first_beat).bar;
    while (true) {
        const bstart = cur_meter.barStartBeat(bar);
        const bx = beatToX(timeline_x0, bstart);
        if (bx > right) break;
        const seg = cur_meter.segmentForBar(bar);
        const unit = seg.unitBeats();
        var k: u8 = 0;
        while (k < seg.numerator) : (k += 1) {
            const x = beatToX(timeline_x0, bstart + @as(f64, @floatFromInt(k)) * unit);
            if (x > right) break;
            if (x < timeline_x) continue;
            const is_bar = k == 0;
            const tick_h: f32 = if (is_bar) rulerH() - 4 else 5;
            c.rl.DrawRectangle(
                @intFromFloat(x),
                @intFromFloat(ruler.y + rulerH() - tick_h - 2),
                1,
                @intFromFloat(tick_h),
                if (is_bar) theme.grid_bar else theme.grid_beat,
            );
        }
        if (bx >= timeline_x - 20) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "{d}", .{bar + 1}) catch "?";
            widgets.drawLabelF(s.ptr, bx + 2, ruler.y + 1, theme.fsTiny(), theme.text_dim);
            // Where the meter changes (a segment starts on this bar), label
            // the new signature in accent, right of the bar number.
            if (seg.start_bar == bar) {
                const nw = widgets.measureTextF(s.ptr, theme.fsTiny());
                var mbuf: [12]u8 = undefined;
                const ms = std.fmt.bufPrintZ(&mbuf, "{d}/{d}", .{ seg.numerator, seg.denominator }) catch "?";
                widgets.drawLabelF(ms.ptr, bx + 2 + nw + 3, ruler.y + 1, theme.fsTiny(), theme.accent_hi);
            }
        }
        bar += 1;
    }
}

fn drawTimelineLane(r: c.rl.Rectangle, t: Track, idx: usize, selected: bool, timeline_x0: f32, edit_snap: snap_mod.Setting) void {
    const bg = if (selected) theme.pane_alt else if (idx % 2 == 0) theme.pane_bg else theme.pane_alt;
    c.rl.DrawRectangleRec(r, bg);

    const right = r.x + r.width - 1;

    // Fine sub-grid (uniform), then meter-driven beat and bar lines on top.
    const step = snap_mod.visualStep(edit_snap, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = beatToX(timeline_x0, beat);
        if (bx > right) break;
        if (bx >= r.x) c.rl.DrawRectangle(@intFromFloat(bx), @intFromFloat(r.y), 1, @intFromFloat(r.height), theme.grid_sub);
        beat += step;
    }

    const first_beat = @max(0.0, beatAtX(timeline_x0, r.x));
    var bar = cur_meter.beatToBarPos(first_beat).bar;
    while (true) {
        const bstart = cur_meter.barStartBeat(bar);
        if (beatToX(timeline_x0, bstart) > right) break;
        const seg = cur_meter.segmentForBar(bar);
        const unit = seg.unitBeats();
        var k: u8 = 0;
        while (k < seg.numerator) : (k += 1) {
            const x = beatToX(timeline_x0, bstart + @as(f64, @floatFromInt(k)) * unit);
            if (x > right) break;
            if (x < r.x) continue;
            c.rl.DrawRectangle(@intFromFloat(x), @intFromFloat(r.y), 1, @intFromFloat(r.height), if (k == 0) theme.grid_bar else theme.grid_beat);
        }
        bar += 1;
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

fn drawClip(r: c.rl.Rectangle, clip: Clip, color: c.rl.Color, selected: bool, editing_name: bool, pool: *const audio_pool_mod.AudioPool) void {
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

    // Name — truncated with an ellipsis so a short clip's label never spills
    // past its body (the full name is available via the hover tooltip).
    if (!editing_name) {
        var name_buf: [clip_mod.MAX_NAME + 5:0]u8 = undefined;
        fitLabelZ(&name_buf, clip.name(), r.width - 6, theme.fsTiny());
        widgets.drawLabelF(@ptrCast(&name_buf[0]), r.x + 3, r.y, theme.fsTiny(), theme.bg);
    }

    // Audio clip → draw its waveform across the body (the source mapped to
    // the clip width). Zoomable for free via the peak pyramid.
    if (clip.isAudio()) {
        const body_top = r.y + strip_h + 1;
        const body_h = r.height - strip_h - 2;
        if (body_h > 2 and r.width > 1) {
            if (pool.get(clip.audio.source)) |src| {
                if (src.cache.sample_count > 0) {
                    const wf_rect = widgets.rect(r.x + 1, body_top, r.width - 2, body_h);
                    const wcol = if (selected) theme.text_fg else theme.accent_hi;
                    // Draw only this clip's source window.
                    const rate = src.sample.sample_rate;
                    const win_start = clip.audio.start_sec * rate;
                    const total: f64 = @floatFromInt(src.cache.sample_count);
                    const win_end = @min(total, win_start + clip.audio.dur_sec * rate);
                    waveform.draw(wf_rect, &src.cache, win_start, win_end, wcol);
                }
            }
            // Fade ramp guides + grab handles in the top corners. The handle
            // x's match the hit zone in the draw()-side hit-test.
            const dur = clip.audio.dur_sec;
            if (dur > 0) {
                const top = r.y;
                const bot = body_top + body_h;
                const in_frac: f32 = @floatCast(std.math.clamp(clip.audio.fade_in_sec / dur, 0, 1));
                const out_frac: f32 = @floatCast(std.math.clamp(clip.audio.fade_out_sec / dur, 0, 1));
                const in_x = r.x + in_frac * r.width;
                const out_x = r.x + r.width - out_frac * r.width;
                if (clip.audio.fade_in_sec > 0) {
                    shadeClipFade(r.x + 1, in_x, body_top, body_h, true);
                    c.rl.DrawLineEx(.{ .x = r.x + 1, .y = bot }, .{ .x = in_x, .y = top }, 1.0, theme.bg);
                }
                if (clip.audio.fade_out_sec > 0) {
                    shadeClipFade(out_x, r.x + r.width - 1, body_top, body_h, false);
                    c.rl.DrawLineEx(.{ .x = out_x, .y = top }, .{ .x = r.x + r.width - 1, .y = bot }, 1.0, theme.bg);
                }
                // Handle dots (always shown so the affordance is discoverable).
                const hs = theme.fine(3);
                c.rl.DrawRectangleRec(widgets.rect(in_x - hs, top, hs * 2, hs + 1), theme.bg);
                c.rl.DrawRectangleRec(widgets.rect(out_x - hs, top, hs * 2, hs + 1), theme.bg);
            }
        }
        return;
    }

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

/// Shade an audio clip's attenuated fade wedge as per-column bars (a filled
/// triangle): tall at the silent edge, shrinking to nothing at full level.
fn shadeClipFade(x0: f32, x1: f32, top: f32, h: f32, fade_in: bool) void {
    const span = x1 - x0;
    if (span < 1 or h < 1) return;
    const col = c.rl.ColorAlpha(theme.bg, 0.5);
    var x = @floor(x0);
    while (x < x1) : (x += 1) {
        const p = std.math.clamp((x - x0) / span, 0, 1);
        const atten: f32 = if (fade_in) 1 - p else p;
        const hh = h * atten;
        if (hh >= 1) c.rl.DrawLineEx(.{ .x = x, .y = top }, .{ .x = x, .y = top + hh }, 1.0, col);
    }
}

/// Copy `name` into `dst` (NUL-terminated), truncating with a trailing "…"
/// until it fits within `max_w` pixels at `size`. Empties `dst` if nothing
/// fits.
fn fitLabelZ(dst: *[clip_mod.MAX_NAME + 5:0]u8, name: []const u8, max_w: f32, size: f32) void {
    const ell = "\u{2026}"; // … (3 bytes)
    var n = @min(name.len, clip_mod.MAX_NAME);
    @memcpy(dst[0..n], name[0..n]);
    dst[n] = 0;
    if (max_w <= 0) {
        dst[0] = 0;
        return;
    }
    if (widgets.measureTextF(@ptrCast(&dst[0]), size) <= max_w) return;
    while (n > 0) : (n -= 1) {
        @memcpy(dst[0 .. n - 1], name[0 .. n - 1]);
        @memcpy(dst[n - 1 ..][0..ell.len], ell);
        dst[n - 1 + ell.len] = 0;
        if (widgets.measureTextF(@ptrCast(&dst[0]), size) <= max_w) return;
    }
    dst[0] = 0;
}

const HeaderAction = enum { none, select, rename };
const HeaderResult = struct {
    action: HeaderAction = .none,
    name_rect: c.rl.Rectangle,
};

fn drawLaneHeader(r: c.rl.Rectangle, t: *Track, idx: usize, selected: bool, editing_name: bool, m: widgets.Mouse) HeaderResult {
    // Background mirrors the timeline lane striping; the selected row goes a
    // step brighter. Flat fill in both states (no bevel inset) so content
    // doesn't jitter 1px when selection toggles.
    const bg = if (selected) theme.slab_fill else if (idx % 2 == 0) theme.pane_bg else theme.pane_alt;
    c.rl.DrawRectangleRec(r, bg);
    c.rl.DrawRectangle(
        @intFromFloat(r.x),
        @intFromFloat(r.y + r.height - 1),
        @intFromFloat(r.width),
        1,
        theme.slab_edge,
    );

    // Track-colour spine, plus an amber accent stripe when selected. The
    // accent column is always reserved so the content x stays fixed.
    const spine_w = theme.fine(4);
    const accent_w = theme.fine(2);
    c.rl.DrawRectangle(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(spine_w), @intFromFloat(r.height), t.color);
    if (selected) {
        c.rl.DrawRectangle(@intFromFloat(r.x + spine_w), @intFromFloat(r.y), @intFromFloat(accent_w), @intFromFloat(r.height), theme.accent_hi);
    }

    const content_x = r.x + spine_w + accent_w + theme.size(5);

    const meter_w = theme.fine(4);
    const meter_gap: f32 = 1;
    const meter_total = meter_w * 2 + meter_gap;
    const meter_x = r.x + r.width - meter_total - 3;
    const meter_y = r.y + 2;
    const meter_h = r.height - 4;
    const peaks = t.meter();
    widgets.meter(widgets.rect(meter_x, meter_y, meter_w, meter_h), peaks.l);
    widgets.meter(widgets.rect(meter_x + meter_w + meter_gap, meter_y, meter_w, meter_h), peaks.r);

    const content_w = meter_x - content_x - 4;

    const row1_y = r.y + 2;
    const btn_h = theme.size(12);
    const btn_w = theme.size(14);
    const solo_r = widgets.rect(content_x + content_w - btn_w, row1_y, btn_w, btn_h);
    const mute_r = widgets.rect(solo_r.x - btn_w - 2, row1_y, btn_w, btn_h);

    // Index badge then the name. The badge is dimmed; the name brightens
    // on the selected row.
    const idx_w = theme.size(12);
    var idx_buf: [8:0]u8 = undefined;
    const idx_s = std.fmt.bufPrintZ(&idx_buf, "{d}", .{idx + 1}) catch "?";
    widgets.drawLabelF(idx_s.ptr, content_x, row1_y + 1, theme.fsTiny(), theme.text_mute);

    const name_x = content_x + idx_w;
    const name_w = @max(8.0, content_w - idx_w - btn_w * 2 - 4);
    const name_rect = widgets.rect(name_x, row1_y, name_w, btn_h);
    if (!editing_name) {
        var name_buf: [track_mod.MAX_NAME + 1:0]u8 = undefined;
        const n = t.name();
        const copy_n = @min(n.len, track_mod.MAX_NAME);
        @memcpy(name_buf[0..copy_n], n[0..copy_n]);
        name_buf[copy_n] = 0;
        widgets.drawLabelF(@ptrCast(&name_buf[0]), name_x, row1_y + 1, theme.fsBody(), if (selected) theme.text_fg else theme.text_dim);
    }

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

    // Pan bar above the volume fader, when the row is tall enough to hold it.
    const pan_h = theme.size(7);
    const pan_y = row2_y - pan_h - 2;
    if (pan_y > row1_y + btn_h + 2) {
        const pan_r = widgets.rect(content_x, pan_y, content_w, pan_h);
        var pan_v: f32 = t.pan();
        if (widgets.panBar(pan_r, &pan_v, m)) t.setPan(pan_v);
        widgets.tooltip(pan_r, "Pan (double-click to center)", m);
    }

    const click_region = widgets.rect(content_x, r.y + 1, content_w - btn_w * 2 - 4, theme.size(14));
    if (widgets.contains(click_region, m.x, m.y) and m.left_pressed and !widgets.hasActiveDrag()) {
        return .{ .action = if (m.double_clicked) .rename else .select, .name_rect = name_rect };
    }
    return .{ .action = .none, .name_rect = name_rect };
}

/// Pinned master strip: blank timeline (left) + a header (right) with the
/// MASTER label, volume fader and stereo meter. Returns true when the strip
/// is clicked (to select the master for the machine bay).
fn drawMasterStrip(strip: c.rl.Rectangle, header_x: f32, header_w: f32, timeline_x: f32, timeline_w: f32, master: *Track, selected: bool, m: widgets.Mouse) bool {
    // Blank timeline area — master has no clips.
    c.rl.DrawRectangleRec(widgets.rect(timeline_x, strip.y, timeline_w, strip.height), theme.pane_bg);
    // Top separator across the whole strip.
    c.rl.DrawRectangle(@intFromFloat(strip.x), @intFromFloat(strip.y), @intFromFloat(strip.width), 1, theme.slab_edge);

    const hdr = widgets.rect(header_x, strip.y, header_w, strip.height);
    c.rl.DrawRectangleRec(hdr, if (selected) theme.slab_fill else theme.pane_alt);

    const spine_w = theme.fine(4);
    const accent_w = theme.fine(2);
    c.rl.DrawRectangle(@intFromFloat(hdr.x), @intFromFloat(hdr.y), @intFromFloat(spine_w), @intFromFloat(hdr.height), theme.slab_hi);
    if (selected) {
        c.rl.DrawRectangle(@intFromFloat(hdr.x + spine_w), @intFromFloat(hdr.y), @intFromFloat(accent_w), @intFromFloat(hdr.height), theme.accent_hi);
    }

    const content_x = hdr.x + spine_w + accent_w + theme.size(5);
    const meter_w = theme.fine(4);
    const meter_gap: f32 = 1;
    const meter_total = meter_w * 2 + meter_gap;
    const meter_x = hdr.x + hdr.width - meter_total - 3;
    const peaks = master.meter();
    widgets.meter(widgets.rect(meter_x, hdr.y + 2, meter_w, hdr.height - 4), peaks.l);
    widgets.meter(widgets.rect(meter_x + meter_w + meter_gap, hdr.y + 2, meter_w, hdr.height - 4), peaks.r);

    const content_w = meter_x - content_x - 4;
    widgets.drawLabelF("MASTER", content_x, hdr.y + 3, theme.fsBody(), if (selected) theme.text_fg else theme.text_dim);

    const fader_h = theme.size(12);
    const vol_r = widgets.rect(content_x, hdr.y + hdr.height - fader_h - 3, content_w, fader_h);
    var v_norm: f32 = std.math.clamp(master.volume() / 1.25, 0.0, 1.0);
    if (widgets.hFader(vol_r, &v_norm, m)) master.setVolume(v_norm * 1.25);
    widgets.tooltip(vol_r, "Master volume", m);

    // Pan bar above the volume fader, when the strip is tall enough.
    const pan_h = theme.size(7);
    const pan_y = vol_r.y - pan_h - 2;
    if (pan_y > hdr.y + 3 + theme.fsBody() + 1) {
        const pan_r = widgets.rect(content_x, pan_y, content_w, pan_h);
        var pan_v: f32 = master.pan();
        if (widgets.panBar(pan_r, &pan_v, m)) master.setPan(pan_v);
        widgets.tooltip(pan_r, "Master pan (double-click to center)", m);
    }

    // Click anywhere on the strip (not consumed by the fader) → select master.
    return m.left_pressed and widgets.contains(strip, m.x, m.y) and !widgets.hasActiveDrag();
}

fn clipNameRect(r: c.rl.Rectangle) c.rl.Rectangle {
    return widgets.rect(r.x + 2, r.y + 1, @max(8, r.width - 4), 11);
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

fn handleLoopBounds(ruler: c.rl.Rectangle, timeline_x0: f32, transport: *Transport, edit_snap: snap_mod.Setting, m: widgets.Mouse) void {
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
        const beat = snap_mod.snapNearest(edit_snap, beatAtX(timeline_x0, m.x), altBypassSnap());
        const s = transport.loopStartBeats();
        const e = transport.loopEndBeats();
        if (loop_start_drag) {
            transport.setLoopBeats(@max(0, @min(beat, e - minClipBeats(edit_snap))), e);
        } else {
            transport.setLoopBeats(s, @max(s + minClipBeats(edit_snap), beat));
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
