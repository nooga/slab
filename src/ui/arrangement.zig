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
const pane = @import("pane_input.zig");
const menu = @import("menu.zig");
const routing = @import("../routing.zig");
const route_menu = @import("route_menu.zig");
const track_order = @import("track_order.zig");
const bridge = @import("bridge.zig");
const ui_core = @import("core.zig");
const ui_style = @import("style.zig");
const ctl = @import("controls.zig");
const Ui = ui_core.Ui;
const Rect = ui_core.Rect;
const geom = @import("geom.zig");
const surf = @import("surfaces.zig");
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
const meter_gen = @import("../meter_gen.zig");
const tempo_mod = @import("../tempo.zig");
const arrange = @import("../arrange.zig");
const markers_mod = @import("../markers.zig");
const groove_mod = @import("../groove.zig");
const warp_mod = @import("../warp.zig");
const recorder_mod = @import("../recorder.zig");
const automation = @import("../automation.zig");
const auto_lane = @import("automation_lane.zig");
const machine_mod = @import("../machine.zig");
const lane_targets = @import("lane_targets.zig");
const follow_mod = @import("follow.zig");

/// Lane height and track-header width (logical px).
pub const LANE_H: f32 = 52;
const HEADER_W: f32 = 196;
/// One automation lane row under a track (docs/06 §Working surfaces).
pub const AUTO_H: f32 = 40;

/// Automation rows shown under a track: its lanes, or one placeholder row
/// to add the first.
fn autoRows(t: *const Track) usize {
    if (!t.lanes_shown) return 0;
    return @max(t.lanes.items.len, 1);
}

fn rowH(t: *const Track) f32 {
    return LANE_H + AUTO_H * @as(f32, @floatFromInt(autoRows(t)));
}

// Display order (docs/23 §Arrangement, ui/track_order.zig): tracks with
// their groups above them, then a RETURNS divider and the returns. Members
// of a folded group aren't shown. It follows index order; a header drag
// renumbers the tracks (headerDrop). Cheap enough (32 tracks) to rebuild
// on every call.

/// Height of the strip that opens the returns section.
const BUS_DIV_H: f32 = 16;

fn order(tracks: []const Track) track_order.Order {
    return track_order.Order.of(tracks);
}

fn isShown(tracks: []const Track, ti: usize) bool {
    return ti < tracks.len and order(tracks).shown[ti];
}

/// Whether track `ti` is selected: in the header multi-selection while
/// `sel` (the selected track) is in it, else just `sel`.
pub fn inSet(tracks: []const Track, sel: ?usize, ti: usize) bool {
    const s = sel orelse return false;
    if (s >= tracks.len) return false;
    if (!tracks[s].multi_sel) return s == ti;
    return ti < tracks.len and tracks[ti].multi_sel;
}

/// A press on header `ti`: plain selects it alone (narrowing on release
/// when it's already in a multi-selection, so the set can be dragged),
/// shift selects the shown rows from the anchor to it, ⌘ toggles it.
/// True for a plain press inside a multi-selection: narrow it on release
/// unless the press becomes a drag. Shared with the mixer.
pub fn headerSelect(tracks: []Track, sel: *?usize, ti: u8, shift: bool, cmd: bool) bool {
    if (cmd) {
        // Start from what's selected now.
        if (sel.*) |s| if (s < tracks.len and !tracks[s].multi_sel) {
            for (tracks) |*t| t.multi_sel = false;
            tracks[s].multi_sel = true;
        };
        if (sel.* == null) for (tracks) |*t| {
            t.multi_sel = false;
        };
        tracks[ti].multi_sel = !tracks[ti].multi_sel;
        if (tracks[ti].multi_sel) {
            sel.* = ti;
        } else {
            // The selected track left the set: another member stands in.
            sel.* = null;
            for (tracks, 0..) |*t, k| if (t.multi_sel) {
                sel.* = k;
                break;
            };
        }
        sel_anchor = ti;
        return false;
    }
    if (shift) if (sel_anchor orelse (if (sel.*) |s| @as(?u8, @intCast(s)) else null)) |anchor| if (anchor < tracks.len) {
        const o = order(tracks);
        var a: ?usize = null;
        var b: ?usize = null;
        for (o.rows[0..o.n], 0..) |row, k| {
            if (row.ti == anchor) a = k;
            if (row.ti == ti) b = k;
        }
        if (a != null and b != null) {
            for (tracks) |*t| t.multi_sel = false;
            for (o.rows[@min(a.?, b.?) .. @max(a.?, b.?) + 1]) |row| tracks[row.ti].multi_sel = true;
            sel_anchor = anchor;
            sel.* = ti;
            return false;
        }
    };
    const narrow = inSet(tracks, sel.*, ti) and tracks[ti].multi_sel;
    if (!narrow) for (tracks) |*t| {
        t.multi_sel = false;
    };
    sel.* = ti;
    sel_anchor = ti;
    return narrow;
}

/// Where a header drag at content y `cy` drops (track_order.dropAt): the
/// upper half of a row goes before it, the lower half after it, or into
/// an open group as its first member; below the section's last row is its
/// end. `line` is the content y of the line showing it.
fn headerDrop(tracks: []const Track, returns: bool, cy: f32) ?struct { drop: track_order.Drop, line: f32, depth: u8 } {
    const o = order(tracks);
    var tops: [routing.MAX_TRACKS + 1]f32 = undefined;
    var y: f32 = 0;
    for (o.rows[0..o.n], 0..) |row, k| {
        if (k == o.main_n) y += BUS_DIV_H;
        tops[k] = y;
        y += rowH(&tracks[row.ti]);
    }
    tops[o.n] = y;
    const lo: usize = if (returns) o.main_n else 0;
    const hi: usize = if (returns) o.n else o.main_n;
    if (hi == lo and returns) return null;
    var k = lo;
    while (k + 1 < hi and cy >= tops[k + 1]) k += 1;
    const d = if (hi == lo or cy >= tops[k] + rowH(&tracks[o.rows[k].ti]))
        track_order.dropEnd(&o, returns)
    else
        track_order.dropAt(&o, k, cy >= tops[k] + rowH(&tracks[o.rows[k].ti]) / 2);
    // The main section's end is above the RETURNS divider.
    const line = if (d.gap == o.main_n and !returns and o.main_n > 0)
        tops[o.main_n - 1] + rowH(&tracks[o.rows[o.main_n - 1].ti])
    else
        tops[d.gap];
    return .{ .drop = d.drop, .line = line, .depth = d.depth };
}

/// The dragged header's ghost at `y`: its name on a lifted plate, with
/// a count of the others moving with it.
fn drawHeaderGhost(ui: *Ui, tracks: []const Track, sel: ?usize, from: u8, header_x: f32, header_w: f32, y: f32, top: f32, bottom: f32) void {
    var others: usize = 0;
    if (inSet(tracks, sel, from)) {
        for (tracks, 0..) |_, k| {
            if (k != from and inSet(tracks, sel, k)) others += 1;
        }
    }
    const t = &tracks[from];
    const g = Rect.xywh(ipx(header_x) - 12, ipx(y), ipx(header_w), 22);
    ui.clip(bridge.fromRl(pane.rect(header_x - 12, top, header_w + 12, bottom - top)));
    defer ui.unclip();
    ui.rect(g, ui_style.face.shade(10).alpha(225));
    ui.rect(Rect.xywh(g.x, g.y, g.w, 1), ui_style.accent);
    ui.rect(Rect.xywh(g.x, g.bottom() - 1, g.w, 1), ui_style.accent);
    ui.rect(Rect.xywh(g.x, g.y, 1, g.h), ui_style.accent);
    ui.rect(Rect.xywh(g.right() - 1, g.y, 1, g.h), ui_style.accent);
    ui.rect(Rect.xywh(g.x + 2, g.y + 2, 3, g.h - 4), trackColor(t.color));
    var buf: [48]u8 = undefined;
    const label = if (others > 0) std.fmt.bufPrint(&buf, "{s}  +{d}", .{ t.name(), others }) catch t.name() else t.name();
    _ = ui.text(&ui.fonts.body, g.x + 10, g.y + 3, label, ui_style.text);
}

fn hasBuses(tracks: []const Track) bool {
    return order(tracks).hasReturns();
}

/// Top of track `ti`'s row, from the top of the lane content (past the
/// end for a hidden one).
fn rowTop(tracks: []const Track, ti: usize) f32 {
    const o = order(tracks);
    var y: f32 = 0;
    for (o.rows[0..o.n], 0..) |row, k| {
        if (k == o.main_n) y += BUS_DIV_H;
        if (row.ti == ti) return y;
        y += rowH(&tracks[row.ti]);
    }
    return y;
}

/// Top of the RETURNS divider (valid when there are returns).
fn busDividerTop(tracks: []const Track) f32 {
    const o = order(tracks);
    var y: f32 = 0;
    for (o.main()) |row| y += rowH(&tracks[row.ti]);
    return y;
}

fn contentH(tracks: []const Track) f32 {
    const o = order(tracks);
    var y: f32 = if (o.hasReturns()) BUS_DIV_H else 0;
    for (o.rows[0..o.n]) |row| y += rowH(&tracks[row.ti]);
    return y;
}

/// Audio track `ti`'s position among the shown audio rows (clip rows);
/// far out of range for a hidden one, so moves onto it find no target.
fn audioRank(tracks: []const Track, ti: usize) i32 {
    const o = order(tracks);
    var k: i32 = 0;
    for (o.main()) |row| {
        if (row.ti == ti) return k;
        if (!tracks[row.ti].isBus()) k += 1;
    }
    return if (ti >= tracks.len) k else -10_000;
}

/// The shown audio track at clip-row `rank`, if there is one.
fn audioAt(tracks: []const Track, rank: i32) ?usize {
    if (rank < 0) return null;
    const o = order(tracks);
    var k: i32 = 0;
    for (o.main()) |row| {
        if (tracks[row.ti].isBus()) continue;
        if (k == rank) return row.ti;
        k += 1;
    }
    return null;
}

/// The clip-row rank whose row holds content-relative `y`: -1 above the
/// first; a group row counts as the audio row after it; past the last
/// audio row (the returns, or below) it counts on in LANE_H steps, so a
/// drag there finds no target.
fn audioRankAtY(tracks: []const Track, y: f32) i32 {
    if (y < 0) return -1;
    const o = order(tracks);
    var top: f32 = 0;
    var k: i32 = 0;
    for (o.main()) |row| {
        const t = &tracks[row.ti];
        const h = rowH(t);
        if (y < top + h) return k;
        top += h;
        if (!t.isBus()) k += 1;
    }
    return k + @as(i32, @intFromFloat(@floor((y - top) / LANE_H)));
}

/// Bus `ti`'s letter (A, B, …) in display order, as Live letters returns.
fn busLetter(tracks: []const Track, ti: usize) u8 {
    var k: u8 = 0;
    for (tracks[0..ti]) |*t| if (t.isBus()) {
        k += 1;
    };
    return @as(u8, 'A') + @min(k, 25);
}

fn rulerH() f32 {
    return 16;
}
fn overviewH() f32 {
    return 24;
}
/// The section lane between the overview and the ruler (docs/28
/// §Locators and sections).
fn markerH() f32 {
    return 16;
}
fn resizeEdgeW() f32 {
    return 5;
}
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
/// The tempo map this frame (audio clips convert their seconds through it).
var cur_tempo: *const tempo_mod.TempoMap = &default_tempo;
var cur_pool: ?*const audio_pool_mod.AudioPool = null;
const default_tempo = tempo_mod.TempoMap.constant(120);
// Live meter map for this frame's grid, captured at the top of draw().
var default_meter_pts = [_]meter_mod.MeterPoint{.{ .start_bar = 0, .numerator = 4, .denominator = 4 }};
var cur_meter: meter_mod.MeterMap = .{ .points = &default_meter_pts };
var scroll_x: f32 = 0;
var follow: follow_mod.Follow = .{};
var scroll_y: f32 = 0;
var last_scroll_time: f64 = 0;
// A press on a track header's name: a drag from it moves the selected
// tracks (or just it, when it isn't in the selection).
var hdr_press: ?u8 = null;
var hdr_press_y: f32 = 0;
var hdr_dragging = false;
/// The press's distance below its row's top, so the ghost keeps it.
var hdr_grab_dy: f32 = 0;
/// A plain press on a track already in a multi-selection: the selection
/// narrows to it on release, unless the press became a drag.
var hdr_narrow = false;
/// The shift-click range's fixed end.
var sel_anchor: ?u8 = null;
/// A header's M or S switched this frame (drawLaneHeader): the caller
/// switches the rest of the selection with it.
var hdr_mute_set: ?bool = null;
var hdr_solo_set: ?bool = null;

var drag_mode: DragMode = .none;
var drag_ref: ClipRef = .{ .track = 0, .clip = 0 };
var drag_start_beat: f64 = 0;
var drag_start_length: f64 = 0;
var drag_start_mouse_x: f32 = 0;
// Audio source window captured at the start of a left-edge trim.
var drag_start_audio_start_sec: f64 = 0;
var drag_start_audio_dur_sec: f64 = 0;
var drag_start_audio_offset: f64 = 0;
// Fade length captured at the start of a fade-handle drag.
var drag_start_fade_sec: f64 = 0;
// ⌘ held when an edge drag began: it stretches instead of trimming
// (docs/29 §Editing).
var drag_stretch: bool = false;
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
    return 7;
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

pub const RouteEdit = route_menu.RouteEdit;

pub const Result = struct {
    add_track: bool = false,
    add_bus: bool = false,
    /// The MIX latch: show the mixer page (docs/23 §Mixer page).
    toggle_mixer: bool = false,
    route: ?RouteEdit = null,
    command: menu.EditCommand = .none,
    command_beat: ?f64 = null,
    command_track: ?usize = null,
    rename_clip: ?ClipRef = null,
    rename_track: ?usize = null,
    /// A header drag dropped: reroute and renumber the tracks (docs/23
    /// §Arrangement).
    move_tracks: ?track_order.Move = null,
    /// A color strip was clicked: open the color picker for the track,
    /// hung from this point.
    color_pick: ?ColorPick = null,
    rename_rect: ?c.rl.Rectangle = null,
    /// A tempo change picked from the ruler menu: main takes the undo
    /// snapshot and applies it (`applyTempoEdit`).
    tempo_edit: ?TempoEdit = null,
    /// A section/locator/END edit from the lane's menu: main takes the undo
    /// snapshot and applies it (`applyMarkerEdit`).
    marker_edit: ?MarkerEdit = null,
    /// Double-click or "Edit…": open the marker dialog on this one.
    marker_open: ?MarkerRef = null,
    /// The lane menu's section edits (docs/28 §Arranging by section): main
    /// takes the undo snapshot and runs it (arrange.zig).
    section_op: ?SectionOp = null,
    /// The ruler menu's Song groove: main takes the undo snapshot and
    /// sets it (a groove.zig pick: NONE or the pool's).
    song_groove: ?u8 = null,
};

pub const MarkerRef = struct { kind: markers_mod.Kind, index: usize };

pub const SectionOp = struct {
    kind: enum { duplicate, delete, earlier, later },
    index: usize,
};

pub const MarkerEdit = union(enum) {
    add_section: f64,
    add_locator: f64,
    remove: MarkerRef,
    set_end: f64,
    clear_end,
};

pub fn applyMarkerEdit(mk: *markers_mod.Markers, e: MarkerEdit) void {
    switch (e) {
        .add_section => |b| _ = mk.addSection(b, ""),
        .add_locator => |b| _ = mk.addLocator(b, ""),
        .remove => |r| mk.remove(r.kind, r.index),
        .set_end => |b| mk.end = b,
        .clear_end => mk.end = null,
    }
}

/// A ruler edit of the tempo map (docs/28 §Tempo map), at `beat`.
pub const TempoEdit = struct {
    kind: enum { add, remove, toggle_ramp },
    beat: f64,
};

/// Apply a ruler tempo edit to the live map.
pub fn applyTempoEdit(transport: *Transport, e: TempoEdit) void {
    const m = transport.tempo.edit();
    switch (e.kind) {
        .add => _ = m.put(e.beat, m.bpmAt(e.beat)),
        .remove => if (m.find(e.beat)) |i| m.remove(i),
        .toggle_ramp => {
            const i = m.segment(e.beat);
            m.points[i].ramp = !m.points[i].ramp;
        },
    }
    transport.tempo.publish();
}

pub const ColorPick = struct { track: usize, at: [2]i32 };

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
    return LANE_H;
}

const ContextTarget = struct {
    beat: f64 = 0,
    track: ?usize = null,
};

var context_target: ContextTarget = .{};

// ── Drops from the browser (docs/25 §The browser) ────────────────────

/// Where the last `draw` put things, for `dropHit`.
var geo: struct {
    timeline_x: f32 = 0,
    timeline_w: f32 = 0,
    timeline_x0: f32 = 0,
    header_x: f32 = 0,
    header_w: f32 = 0,
    lanes_top: f32 = 0,
    lanes_bottom: f32 = 0,
    drawn: bool = false,
} = .{};

pub const DropHit = struct {
    /// The track under the pointer; null below the last one (a new track).
    track: ?usize,
    /// Over the track's header rather than its lane.
    header: bool,
    /// The beat under the pointer (lanes; 0 elsewhere).
    beat: f64,
    /// The row's lane and header (or the empty area below the tracks).
    lane: Rect,
    head: Rect,
};

/// What a drop at (x, y) would land on, from the last drawn frame.
pub fn dropHit(tracks: []const Track, x: f32, y: f32) ?DropHit {
    const g = geo;
    if (!g.drawn or y < g.lanes_top or y >= g.lanes_bottom) return null;
    if (x < g.timeline_x or x >= g.header_x + g.header_w) return null;
    const on_head = x >= g.header_x;
    const beat: f64 = @max(0, (x - g.timeline_x0 + scroll_x) / px_per_beat);
    for (tracks, 0..) |*t, ti| {
        if (!isShown(tracks, ti)) continue;
        const ly = g.lanes_top + rowTop(tracks, ti) - scroll_y;
        const h = rowH(t);
        if (y < ly or y >= ly + h) continue;
        return .{
            .track = ti,
            .header = on_head,
            .beat = beat,
            .lane = bridge.fromRl(pane.rect(g.timeline_x, ly, g.timeline_w, LANE_H)),
            .head = bridge.fromRl(pane.rect(g.header_x, ly, g.header_w, LANE_H)),
        };
    }
    const end_y = g.lanes_top + contentH(tracks) - scroll_y;
    if (y < end_y) return null; // the returns divider
    const below = bridge.fromRl(pane.rect(g.timeline_x, end_y, g.timeline_w + g.header_w, g.lanes_bottom - end_y));
    return .{ .track = null, .header = false, .beat = beat, .lane = below, .head = below };
}

/// Screen x of `beat` in the last drawn frame.
pub fn beatX(beat: f64) f32 {
    return geo.timeline_x0 + @as(f32, @floatCast(beat)) * px_per_beat - scroll_x;
}

/// Clip bodies are being dragged (the browser takes them to save).
pub fn clipMoveActive() bool {
    return drag_mode == .move;
}

/// Put the dragged clips back where the drag found them and end it.
pub fn abortClipMove(tracks: []Track) void {
    if (drag_mode != .move) return;
    if (drag_snap_count > 0) {
        for (drag_snaps[0..drag_snap_count]) |s| {
            if (s.track >= tracks.len or s.clip >= tracks[s.track].clips.items.len) continue;
            tracks[s.track].clips.items[s.clip].start_beat = s.start_beat;
        }
    } else if (drag_ref.track < tracks.len and drag_ref.clip < tracks[drag_ref.track].clips.items.len) {
        tracks[drag_ref.track].clips.items[drag_ref.clip].start_beat = drag_start_beat;
    }
    _ = cancelInteractions();
}

pub fn cancelInteractions() bool {
    const had_active = drag_mode != .none or box_active or ov_drag or ruler_drag or tempo_drag != null or marker_drag != null or loop_start_drag or loop_end_drag or sbv_drag;
    drag_mode = .none;
    box_active = false;
    ov_drag = false;
    ruler_drag = false;
    tempo_drag = null;
    marker_drag = null;
    loop_start_drag = false;
    loop_end_drag = false;
    sbv_drag = false;
    pane.cancelDrag();
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
                // By audio rank, so a paste lays clips out over tracks, not buses.
                .rel_track = audioRank(tracks, ti) - audioRank(tracks, base_track),
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
    if (base_track >= tracks.len or tracks[base_track].isBus()) return false;
    deselectAllClips(tracks);
    var first: ?ClipRef = null;
    var changed = false;
    for (items) |*item| {
        const target_i = audioAt(tracks, audioRank(tracks, base_track) + item.rel_track) orelse continue;
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

/// Flip the selected audio clips' playback direction (with `selection`
/// false, or none selected: the focused clip). The window and fades stay
/// where they are; a warped clip mirrors its map (docs/29 §The model).
pub fn reverseAudioClips(tracks: []Track, pool: ?*const audio_pool_mod.AudioPool, focused: ?ClipRef, selection: bool) bool {
    const Flip = struct {
        fn one(clip: *Clip, p: ?*const audio_pool_mod.AudioPool) void {
            if (clip.audio.warp) {
                const src = (p orelse return).get(clip.audio.source) orelse return;
                warp_mod.mirror(clip, src.seconds());
            } else clip.audio.reversed = !clip.audio.reversed;
        }
    };
    var changed = false;
    if (selection) for (tracks) |*t| for (t.clips.items) |*clip| if (clip.selected and clip.isAudio()) {
        Flip.one(clip, pool);
        changed = true;
    };
    if (changed) return true;
    const f = focused orelse return false;
    if (f.track >= tracks.len or f.clip >= tracks[f.track].clips.items.len) return false;
    const clip = &tracks[f.track].clips.items[f.clip];
    if (!clip.isAudio()) return false;
    Flip.one(clip, pool);
    return true;
}

fn focusedWarped(tracks: []const Track, focused: ?ClipRef) bool {
    const f = focused orelse return false;
    if (f.track >= tracks.len or f.clip >= tracks[f.track].clips.items.len) return false;
    const cl = &tracks[f.track].clips.items[f.clip];
    return cl.isAudio() and cl.audio.warp and !cl.audio.reversed;
}

fn allSelectedAudioWarped(tracks: []const Track) bool {
    var any = false;
    for (tracks) |*t| for (t.clips.items) |*clip| if (clip.selected and clip.isAudio()) {
        if (!clip.audio.warp) return false;
        any = true;
    };
    return any;
}

/// Warp the selected audio clips on, or off when all of them already are
/// (with `selection` false, or none selected: the focused clip), keeping
/// each where it sits (docs/29 §The model).
pub fn toggleWarp(tracks: []Track, alloc: std.mem.Allocator, pool: ?*const audio_pool_mod.AudioPool, tmap: *const tempo_mod.TempoMap, focused: ?ClipRef, selection: bool) bool {
    const p = pool orelse return false;
    const Set = struct {
        fn one(a: std.mem.Allocator, clip: *Clip, pl: *const audio_pool_mod.AudioPool, m: *const tempo_mod.TempoMap, on: bool) bool {
            const src = pl.get(clip.audio.source) orelse return false;
            if (on) {
                // On the tempo its hits say, when sure; else as it sounds now.
                if (src.hits()) |h| if (warp_mod.detectAndFit(a, clip, h, src.seconds()) catch false) return true;
                warp_mod.warpOn(a, clip, m, src.seconds(), src.onsets()) catch return false;
            } else {
                warp_mod.warpOff(clip, src.seconds());
                clip.length_beats = @max(MIN_CLIP_BEATS, m.beatAfter(clip.start_beat, clip.audio.dur_sec) - clip.start_beat);
            }
            return true;
        }
    };
    var changed = false;
    if (selection and hasSelectedAudioClips(tracks)) {
        const on = !allSelectedAudioWarped(tracks);
        for (tracks) |*t| for (t.clips.items) |*clip| if (clip.selected and clip.isAudio()) {
            changed = Set.one(alloc, clip, p, tmap, on) or changed;
        };
        return changed;
    }
    const f = focused orelse return false;
    if (f.track >= tracks.len or f.clip >= tracks[f.track].clips.items.len) return false;
    const clip = &tracks[f.track].clips.items[f.clip];
    if (!clip.isAudio()) return false;
    return Set.one(alloc, clip, p, tmap, !clip.audio.warp);
}

/// Mute the selected clips, or unmute them when all of them already are
/// (with `selection` false, or none selected: the focused clip). Muted
/// clips stay on the timeline but don't play (docs/27).
pub fn toggleClipMute(tracks: []Track, focused: ?ClipRef, selection: bool) bool {
    if (selection and hasSelectedClips(tracks)) {
        const mute = !allSelectedMuted(tracks);
        for (tracks) |*t| for (t.clips.items) |*clip| if (clip.selected) {
            clip.muted = mute;
        };
        return true;
    }
    const f = focused orelse return false;
    if (f.track >= tracks.len or f.clip >= tracks[f.track].clips.items.len) return false;
    const clip = &tracks[f.track].clips.items[f.clip];
    clip.muted = !clip.muted;
    return true;
}

fn allSelectedMuted(tracks: []Track) bool {
    for (tracks) |t| for (t.clips.items) |clip| if (clip.selected and !clip.muted) return false;
    return true;
}

/// The focused clip is a bounce with a recipe (docs/27 §Provenance).
fn focusedIsBounce(tracks: []Track, focused: ?ClipRef) bool {
    const f = focused orelse return false;
    if (f.track >= tracks.len or f.clip >= tracks[f.track].clips.items.len) return false;
    return tracks[f.track].clips.items[f.clip].recipe != null;
}

fn hasSelectedAudioClips(tracks: []Track) bool {
    for (tracks) |t| for (t.clips.items) |clip| if (clip.selected and clip.isAudio()) return true;
    return false;
}

pub fn splitSelectedClipsAt(tracks: []Track, alloc: std.mem.Allocator, focused_clip: *?ClipRef, beat: f64, tmap: *const tempo_mod.TempoMap) bool {
    var changed = false;
    var first: ?ClipRef = null;
    for (tracks, 0..) |*t, ti| {
        const original_len = t.clips.items.len;
        var ci: usize = 0;
        while (ci < original_len) : (ci += 1) {
            const clip = &t.clips.items[ci];
            if (!clip.selected) continue;
            const local = beat - clip.start_beat;
            if (local <= minClipBeats(.note_16) or local >= clip.length_beats - minClipBeats(.note_16)) continue;
            // The right part (appended, selected) reads on from the cut.
            const did = arrange.splitClip(alloc, t, ci, beat, tmap) catch |err| {
                std.log.err("split clip failed: {s}", .{@errorName(err)});
                continue;
            };
            if (!did) continue;
            t.clips.items[ci].selected = false;
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
    ui: *Ui,
    r: c.rl.Rectangle,
    tracks: []Track,
    master: *Track,
    device_sel: *DeviceSel,
    pool: *const audio_pool_mod.AudioPool,
    alloc: std.mem.Allocator,
    selected_track: *?usize,
    selected_clip: *?ClipRef,
    transport: *Transport,
    meter_state: *meter_mod.MeterState,
    markers: *markers_mod.Markers,
    edit_snap: snap_mod.Setting,
    can_paste_clips: bool,
    rename_target: RenameTarget,
    recorder: ?*const recorder_mod.Recorder,
    m: pane.Mouse,
) Result {
    var result: Result = .{};
    // The track a live recording is being written to (first armed audio
    // track), so its lane shows the take growing in real time.
    const rec_track_idx: ?usize = blk: {
        const rec = recorder orelse break :blk null;
        if (!rec.isRecording()) break :blk null;
        for (tracks, 0..) |*t, i| {
            if (t.kind == .audio and t.isArmed()) break :blk i;
        }
        break :blk null;
    };
    cur_meter = meter_state.liveMap();
    ui.rect(bridge.fromRl(r), ui_style.pane);

    // Unwarped audio clips' beat-length is derived from the source window
    // through the tempo map, so a tempo edit rescales them against the bar
    // grid (warped ones keep theirs). Do this before any interaction/draw
    // uses length_beats.
    cur_tempo = transport.map();
    cur_pool = pool;
    reflowAudioClips(tracks, cur_tempo);

    var master_clicked = false;

    const header_w = HEADER_W;
    const timeline_x = r.x;
    const timeline_w = r.width - header_w;
    const header_x = r.x + timeline_w;
    const timeline_x0 = timeline_x + 2;

    // Pinned master strip at the bottom; the scrollable lane band shrinks
    // by its height.
    const master_h = masterStripH();
    const lanes_bottom = r.y + r.height - master_h;

    // ── Layout slices ────────────────────────────────────────────────
    const overview_rect = pane.rect(timeline_x, r.y, timeline_w, overviewH());
    const marker_rect = pane.rect(timeline_x, r.y + overviewH(), timeline_w, markerH());
    const ruler_rect = pane.rect(timeline_x, r.y + overviewH() + markerH(), timeline_w, rulerH());
    const hdr_top = pane.rect(header_x, r.y, header_w, overviewH() + markerH() + rulerH());

    // Header column block over the overview + ruler rows: TRACKS + add.
    {
        ui.pushId("tracks-head");
        defer ui.popId();
        var head = bridge.fromRl(hdr_top);
        const add_r = head.cutRight(20).takeTop(20);
        if (ctl.button(ui, add_r, "add", null, .{ .label = "+", .flush = true })) result.add_track = true;
        menu.tip(ui, add_r, "Add track");
        const mix_r = head.cutRight(36).takeTop(20);
        var mix_on = false;
        if (ctl.button(ui, mix_r, "mix", &mix_on, .{ .kind = .latch, .label = "MIX", .lit = ui_style.accent, .flush = true })) result.toggle_mixer = true;
        menu.tip(ui, mix_r, "Mixer (M)");
        const plate_r = Rect.xywh(head.x, head.y, head.w, head.h);
        const body = ui.plate(plate_r, .{});
        _ = ui.engraved(&ui.fonts.legend, body.x + 5, body.y + 3, "TRACKS", ui_style.text_dim);
        // Under MIX and +: add a bus.
        const bus_r = Rect.xywh(mix_r.x, add_r.bottom(), add_r.right() - mix_r.x, head.bottom() - add_r.bottom());
        if (bus_r.h >= 16) {
            if (ctl.button(ui, bus_r, "add-bus", null, .{ .label = "+ BUS", .flush = true })) result.add_bus = true;
            menu.tip(ui, bus_r, "Add bus");
        }
    }
    // Loop controls moved off the track header — right-click the timeline for
    // Loop selection / Loop arrangement / Clear loop, plus ruler drag.

    // Clamp scrolls once we know content extent.
    const content_beats = contentBeats(tracks);
    const lanes_top = r.y + overviewH() + markerH() + rulerH();
    const lanes_h = @max(0, lanes_bottom - lanes_top);
    geo = .{
        .timeline_x = timeline_x,
        .timeline_w = timeline_w,
        .timeline_x0 = timeline_x0,
        .header_x = header_x,
        .header_w = header_w,
        .lanes_top = lanes_top,
        .lanes_bottom = lanes_bottom,
        .drawn = true,
    };

    // ── Wheel input (scroll / zoom) ──────────────────────────────────
    handleWheel(pane.rect(timeline_x, r.y, timeline_w, r.height), m);
    // The headers are Ui widgets, and main hides the pointer from the
    // panes while one is hot or held; their wheel and drag read the Ui's
    // own input, which a menu or dialog still suppresses.
    const hm = pane.Mouse.fromInput(&ui.in);
    handleHeaderWheel(pane.rect(header_x, lanes_top, header_w, lanes_h), hm);

    // ── Continue an in-progress clip drag ─────────────────────────────
    continueDrag(tracks, alloc, selected_clip, edit_snap, m, lanes_top);
    updateBoxSelect(tracks, selected_track, selected_clip, m, timeline_x, timeline_w, timeline_x0, lanes_top);

    clampScroll(content_beats, timeline_w);
    clampScrollY(contentH(tracks), lanes_h);
    const timeline_zone = pane.rect(timeline_x, r.y, timeline_w, lanes_bottom - r.y);
    follow.step(
        &scroll_x,
        if (transport.isPlaying()) @as(f32, @floatCast(transport.beats())) * px_per_beat else null,
        timeline_w - (timeline_x0 - timeline_x),
        maxScrollX(content_beats, timeline_w),
        c.rl.GetFrameTime(),
        pane.hasActiveDrag() and pane.contains(timeline_zone, m.x, m.y),
    );

    // ── Ruler ────────────────────────────────────────────────────────
    ui.clip(bridge.fromRl(ruler_rect));
    _ = ui.plate(bridge.fromRl(ruler_rect), .{});
    drawLoopRegion(ui, ruler_rect, timeline_x0, transport);
    drawBeatTicks(ui, ruler_rect, timeline_x, timeline_w, timeline_x0, edit_snap);
    drawTempoMarks(ui, ruler_rect, timeline_x, timeline_w, timeline_x0);
    ui.unclip();

    handleTempoDrag(transport, m);
    handleLoopBounds(ruler_rect, timeline_x0, transport, edit_snap, m);
    // Click / drag the ruler to scrub the playhead.
    if (!loop_start_drag and !loop_end_drag) handleRulerScrub(ruler_rect, timeline_x0, transport, m);

    // Right-click the ruler → meter-change menu at the bar under the cursor.
    if (m.right_pressed and pane.contains(ruler_rect, m.x, m.y) and !pane.hasActiveDrag()) {
        const b = @max(0.0, beatAtX(timeline_x0, m.x));
        meter_menu_bar = cur_meter.beatToBarPos(b).bar;
        menu.openAt(METER_MENU_KEY, ipx(m.x), ipx(m.y));
    }
    meterMenuTick(meter_state, &result);

    // ── Section lane ─────────────────────────────────────────────────
    const song_end = lastClipEnd(tracks);
    ui.clip(bridge.fromRl(marker_rect));
    drawMarkerLane(ui, marker_rect, timeline_x, timeline_w, timeline_x0, markers, song_end);
    ui.unclip();
    handleMarkerLane(ui, marker_rect, timeline_x0, transport, markers, song_end, edit_snap, m, &result);
    markerMenuTick(transport, markers, song_end, &result);

    // ── Per-track lane + clips ───────────────────────────────────────
    var press_consumed = false;

    // Scissor-clip the timeline zone so clips don't bleed into the
    // header column or above/below the lanes.
    ui.clip(bridge.fromRl(pane.rect(timeline_x, lanes_top, timeline_w, lanes_bottom - lanes_top)));
    // Lane backgrounds first, then the loop region, so the loop marquee sits
    // behind the clips (drawn below).
    for (tracks, 0..) |*t, ti| {
        if (!isShown(tracks, ti)) continue;
        const ly = lanes_top + rowTop(tracks, ti) - scroll_y;
        if (ly + LANE_H <= lanes_top) continue;
        if (ly >= lanes_bottom) continue; // display order isn't index order
        const lane_timeline = pane.rect(timeline_x, ly, timeline_w, LANE_H);
        const lane_is_sel = inSet(tracks, selected_track.*, ti);
        drawTimelineLane(ui, lane_timeline, t.*, ti, lane_is_sel, timeline_x0, edit_snap);
        if (t.isBus()) {
            drawGroupClips(ui, lane_timeline, tracks, ti, timeline_x0);
            drawBusFeeds(ui, lane_timeline, tracks, ti);
        }
    }
    if (hasBuses(tracks)) {
        const dy = lanes_top + busDividerTop(tracks) - scroll_y;
        if (dy + BUS_DIV_H > lanes_top and dy < lanes_bottom) drawBusDivider(ui, pane.rect(timeline_x, dy, timeline_w, BUS_DIV_H));
    }
    for (tracks, 0..) |*t, ti| {
        if (!isShown(tracks, ti)) continue;
        const ly = lanes_top + rowTop(tracks, ti) - scroll_y;
        if (ly + rowH(t) <= lanes_top) continue;
        if (ly >= lanes_bottom) continue; // display order isn't index order
        // Automation rows under the clip row.
        if (autoRows(t) > 0) {
            if (drawAutomationRows(ui, alloc, tracks, t, ti, ly + LANE_H, timeline_x, timeline_w, timeline_x0, edit_snap, selected_track, selected_clip, m, press_consumed)) press_consumed = true;
        }
        if (ly + LANE_H <= lanes_top) continue;
        const lane_timeline = pane.rect(timeline_x, ly, timeline_w, LANE_H);
        const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);

        // Hit-test pass (reverse order, topmost first).
        var i: usize = t.clips.items.len;
        while (i > 0) {
            i -= 1;
            const clip = &t.clips.items[i];
            const clip_rect = clipRect(lane_timeline, clip.*, timeline_x0);
            if (!press_consumed and pane.contains(clip_rect, m.x, m.y)) {
                // Audio fade handles live in the top corners (see drawClip);
                // detect them first so they win over move/trim in that zone.
                const fade_zone_h = @min(12, clip_rect.height * 0.5);
                var fade_in_hover = false;
                var fade_out_hover = false;
                if (clip.isAudio() and clip.audio.dur_sec > 0 and m.y <= clip_rect.y + fade_zone_h) {
                    const dur = clip.audio.dur_sec;
                    const in_frac: f32 = @floatCast(std.math.clamp(clip.audio.fade_in_sec / dur, 0, 1));
                    const out_frac: f32 = @floatCast(std.math.clamp(clip.audio.fade_out_sec / dur, 0, 1));
                    const in_x = clip_rect.x + in_frac * clip_rect.width;
                    const out_x = clip_rect.x + clip_rect.width - out_frac * clip_rect.width;
                    const hit: f32 = 8;
                    fade_in_hover = @abs(m.x - in_x) <= hit;
                    fade_out_hover = !fade_in_hover and @abs(m.x - out_x) <= hit;
                }
                const edge_hover = !fade_out_hover and m.x >= clip_rect.x + clip_rect.width - resizeEdgeW();
                // Audio clips can be trimmed from the left edge (carving into
                // the source window); note clips only resize on the right.
                const left_edge_hover = clip.isAudio() and !fade_in_hover and m.x <= clip_rect.x + resizeEdgeW() and !edge_hover;
                if (!pane.hasActiveDrag()) {
                    pane.requestCursor(if (edge_hover or left_edge_hover or fade_in_hover or fade_out_hover) c.rl.MOUSE_CURSOR_RESIZE_EW else c.rl.MOUSE_CURSOR_POINTING_HAND, 1);
                    // Full clip name on hover-and-pause (the body label is truncated).
                    menu.tip(ui, bridge.fromRl(clip_rect), clip.name());
                }
                if (m.double_clicked and !pane.hasActiveDrag()) {
                    const ref: ClipRef = .{ .track = @intCast(ti), .clip = @intCast(i) };
                    deselectAllClips(tracks);
                    clip.selected = true;
                    selected_clip.* = ref;
                    selected_track.* = ti;
                    result.rename_clip = ref;
                    press_consumed = true;
                    break;
                }
                if (m.left_pressed and !pane.hasActiveDrag()) {
                    const ref: ClipRef = .{ .track = @intCast(ti), .clip = @intCast(i) };
                    deselectAllPoints(tracks);
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
                if (m.right_pressed and !pane.hasActiveDrag()) {
                    const ref: ClipRef = .{ .track = @intCast(ti), .clip = @intCast(i) };
                    if (!clip.selected) {
                        deselectAllClips(tracks);
                        clip.selected = true;
                    }
                    selected_clip.* = ref;
                    selected_track.* = ti;
                    context_target = .{ .beat = beatAtX(timeline_x0, m.x), .track = ti };
                    _ = menu.openContext(ui, ARR_CONTEXT_KEY, bridge.fromRl(r));
                    press_consumed = true;
                }
            }
        }

        // Draw pass (forward order).
        for (t.clips.items, 0..) |*clip, ci| {
            const clip_rect = clipRect(lane_timeline, clip.*, timeline_x0);
            const editing = rename_target.kind == .clip and rename_target.track == ti and rename_target.clip == ci;
            drawClip(ui, clip_rect, clip.*, t.color, clip.selected, editing, pool, t.time.rate());
            if (editing) result.rename_rect = clipNameRect(clip_rect);
        }

        // Live recording overlay — the take growing on the armed track.
        if (rec_track_idx == ti) {
            if (recorder) |rec| drawLiveRecordClip(ui, lane_timeline, rec, transport, timeline_x0);
        }

        // Double-click on empty timeline area → create clip.
        if (!press_consumed and m.double_clicked and pane.contains(lane_timeline, m.x, m.y)) {
            const beat = snap_mod.snapDownPositive(edit_snap, @as(f64, (m.x - timeline_x0 + scroll_x) / px_per_beat), altBypassSnap());
            const start = if (beat < 0) 0 else beat;
            deselectAllClips(tracks);
            createClipOnTrack(t, alloc, ti, start, selected_clip);
            selected_track.* = ti;
            press_consumed = true;
        }

        // Single click on empty timeline area → track-only selection.
        if (!press_consumed and m.left_pressed and pane.contains(lane_timeline, m.x, m.y) and !pane.hasActiveDrag()) {
            deselectAllPoints(tracks);
            beginBoxSelect(ti, m, shift);
            press_consumed = true;
        }

        if (!press_consumed and m.right_pressed and pane.contains(lane_timeline, m.x, m.y) and !pane.hasActiveDrag()) {
            selected_track.* = ti;
            selected_clip.* = null;
            deselectAllClips(tracks);
            context_target = .{ .beat = beatAtX(timeline_x0, m.x), .track = ti };
            _ = menu.openContext(ui, ARR_CONTEXT_KEY, bridge.fromRl(r));
            press_consumed = true;
        }
    }

    // Empty area below the last track (still inside the timeline) → start a
    // box-select from "nowhere": a plain click clears the whole selection,
    // a drag marquees from blank space. Right-click clears + opens the menu.
    if (!press_consumed and !pane.hasActiveDrag()) {
        const lanes_zone = pane.rect(timeline_x, lanes_top, timeline_w, lanes_bottom - lanes_top);
        if (pane.contains(lanes_zone, m.x, m.y)) {
            const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
            if (m.left_pressed) {
                beginBoxSelect(null, m, shift);
                press_consumed = true;
            } else if (m.right_pressed) {
                selected_track.* = null;
                selected_clip.* = null;
                deselectAllClips(tracks);
                context_target = .{ .beat = beatAtX(timeline_x0, m.x), .track = null };
                _ = menu.openContext(ui, ARR_CONTEXT_KEY, bridge.fromRl(r));
                press_consumed = true;
            }
        }
    }

    ui.unclip();
    drawBoxSelectOverlay(ui, timeline_x, timeline_w, lanes_top, lanes_bottom, m);

    // Playhead spans the ruler and all lanes (stops above the master strip).
    const playhead_top = r.y + overviewH();
    ui.clip(bridge.fromRl(pane.rect(timeline_x, playhead_top, timeline_w, lanes_bottom - playhead_top)));
    const beats_pos: f32 = @floatCast(transport.beats());
    const playhead_x = timeline_x0 + beats_pos * px_per_beat - scroll_x;
    ui.rect(Rect.xywh(ipx(playhead_x), ipx(playhead_top), 1, ipx(lanes_bottom - playhead_top)), ui_style.accent);
    ui.unclip();

    // Track headers — live in the right column but scroll vertically
    // with the lanes. Clipped to the lane band so they don't leak into
    // the overview strip or beyond the bottom.
    ui.clip(bridge.fromRl(pane.rect(header_x, lanes_top, header_w, lanes_bottom - lanes_top)));
    const play_beat = transport.beats();
    for (tracks, 0..) |*t, ti| {
        if (!isShown(tracks, ti)) continue;
        const ly = lanes_top + rowTop(tracks, ti) - scroll_y;
        if (ly + rowH(t) <= lanes_top) continue;
        if (ly >= lanes_bottom) continue; // display order isn't index order
        if (autoRows(t) > 0) drawAutomationHeaders(ui, alloc, t, ti, header_x, ly + LANE_H, header_w);
        const lane_header = pane.rect(header_x, ly, header_w, LANE_H);
        const lane_is_sel = inSet(tracks, selected_track.*, ti);
        const editing = rename_target.kind == .track and rename_target.track == ti;
        const o = order(tracks);
        var rails: [routing.MAX_TRACKS]ui_style.Color = undefined;
        var n_rails: usize = o.depth[ti];
        {
            var a = o.parent[ti];
            var k = n_rails;
            while (a != routing.NONE and k > 0) : (a = o.parent[a]) {
                k -= 1;
                rails[k] = trackColor(tracks[a].color);
            }
            n_rails -= k;
            if (k > 0) std.mem.copyForwards(ui_style.Color, rails[0..n_rails], rails[k .. k + n_rails]);
        }
        hdr_mute_set = null;
        hdr_solo_set = null;
        const hres = drawLaneHeader(ui, lane_header, t, ti, o.number[ti], if (t.isBus()) busLetter(tracks, ti) else null, lane_is_sel, editing, play_beat, .{ .rails = rails[0..n_rails], .group = o.is_group[ti] });
        if (editing) result.rename_rect = hres.name_rect;
        if (inSet(tracks, selected_track.*, ti)) for (tracks, 0..) |*u, k| if (inSet(tracks, selected_track.*, k)) {
            if (hdr_mute_set) |v| u.mute.store(v, .monotonic);
            if (hdr_solo_set) |v| u.solo.store(v, .monotonic);
        };
        switch (hres.action) {
            .none => {},
            .select => {
                hdr_narrow = headerSelect(tracks, selected_track, @intCast(ti), ui.in.shift, ui.in.cmd);
                deselectAllClips(tracks);
                selected_clip.* = null;
                device_sel.* = .audio;
                hdr_press = @intCast(ti);
                hdr_press_y = hm.y;
                hdr_grab_dy = hm.y - ly;
                hdr_dragging = false;
            },
            .color => result.color_pick = .{ .track = ti, .at = .{ hres.color_at[0], hres.color_at[1] } },
            .rename => {
                selected_track.* = ti;
                deselectAllClips(tracks);
                selected_clip.* = null;
                device_sel.* = .audio;
                result.rename_track = ti;
            },
        }
    }
    if (hasBuses(tracks)) {
        const dy = lanes_top + busDividerTop(tracks) - scroll_y;
        if (dy + BUS_DIV_H > lanes_top and dy < lanes_bottom) {
            const hr = ui.plate(bridge.fromRl(pane.rect(header_x, dy, header_w, BUS_DIV_H)), .{ .fill = ui_style.face.shade(-4) });
            _ = ui.engraved(&ui.fonts.legend, hr.x + 5, hr.y + 3, "RETURNS", ui_style.text_dim);
        }
    }
    // A header drag: past a few pixels it moves the selected tracks (the
    // pressed one alone when it isn't selected), shown as a ghost under
    // the pointer and a line where they'd land, indented to the group
    // they'd join; the lanes scroll near the edges.
    var drop_line: ?struct { y: f32, depth: u8 } = null;
    var ghost: ?u8 = null;
    if (hdr_press) |from| {
        if (from >= tracks.len) {
            hdr_press = null;
        } else {
            var set: [routing.MAX_TRACKS]bool = @splat(false);
            if (inSet(tracks, selected_track.*, from)) {
                for (0..tracks.len) |k| set[k] = inSet(tracks, selected_track.*, k);
            } else set[from] = true;
            const in_returns = blk: {
                const o = order(tracks);
                for (o.returns()) |row| if (row.ti == from) break :blk true;
                break :blk false;
            };
            const at = hm.y - lanes_top + scroll_y;
            if (!hm.left_down) {
                if (hdr_dragging) {
                    if (headerDrop(tracks, in_returns, at)) |d| result.move_tracks = track_order.moveSet(tracks, &set, d.drop);
                } else if (hdr_narrow) {
                    for (tracks) |*t| t.multi_sel = false;
                }
                hdr_press = null;
                hdr_dragging = false;
                hdr_narrow = false;
            } else {
                if (!hdr_dragging and @abs(hm.y - hdr_press_y) > 4) hdr_dragging = true;
                if (hdr_dragging) {
                    if (hm.y < lanes_top + 16) scroll_y -= 8;
                    if (hm.y > lanes_bottom - 16) scroll_y += 8;
                    scroll_y = std.math.clamp(scroll_y, 0, @max(0, contentH(tracks) - (lanes_bottom - lanes_top)));
                    ghost = from;
                    if (headerDrop(tracks, in_returns, at)) |d| if (track_order.moveSet(tracks, &set, d.drop) != null) {
                        drop_line = .{ .y = lanes_top + d.line - scroll_y, .depth = d.depth };
                    };
                    // Dim the rows being moved.
                    const o = order(tracks);
                    for (o.rows[0..o.n]) |row| {
                        var moving = set[row.ti];
                        var a = o.parent[row.ti];
                        while (a != routing.NONE) : (a = o.parent[a]) moving = moving or set[a];
                        if (!moving) continue;
                        const ry = lanes_top + rowTop(tracks, row.ti) - scroll_y;
                        ui.rect(bridge.fromRl(pane.rect(header_x, ry, header_w, rowH(&tracks[row.ti]))), ui_style.chassis.alpha(150));
                    }
                }
            }
        }
    }

    // Below the last track the header column is a blank plate (nothing
    // shows bare chassis, docs/06 §Packing).
    {
        const end_y = lanes_top + contentH(tracks) - scroll_y;
        if (end_y < lanes_bottom) _ = ui.plate(bridge.fromRl(pane.rect(header_x, @max(end_y, lanes_top), header_w, lanes_bottom - @max(end_y, lanes_top))), .{});
    }
    ui.unclip();
    if (drop_line) |dl| {
        ui.clip(bridge.fromRl(pane.rect(r.x, lanes_top, r.width, lanes_bottom - lanes_top)));
        const indent = ipx(header_x) + RAIL_W * @as(i32, dl.depth);
        ui.rect(Rect.xywh(ipx(r.x), ipx(dl.y) - 1, ipx(header_x) - ipx(r.x), 2), ui_style.accent.alpha(110));
        ui.rect(Rect.xywh(indent, ipx(dl.y) - 1, ipx(header_x + header_w) - indent, 2), ui_style.accent);
        ui.rect(Rect.xywh(indent, ipx(dl.y) - 4, 2, 8), ui_style.accent);
        ui.unclip();
    }
    if (ghost) |from| drawHeaderGhost(ui, tracks, selected_track.*, from, header_x, header_w, hm.y - hdr_grab_dy, lanes_top, lanes_bottom);

    // Lazy vertical scrollbar.
    const lanes_rect = pane.rect(r.x, lanes_top, r.width, lanes_bottom - lanes_top);
    drawAndHandleScrollbar(ui, lanes_rect, contentH(tracks), m);

    // Pinned master strip at the bottom of the track bay.
    {
        // Blank timeline (master has no clips) + top separator, then the
        // master header on the new Ui.
        ui.rect(bridge.fromRl(pane.rect(timeline_x, lanes_bottom, timeline_w, master_h)), ui_style.pane);
        ui.rect(bridge.fromRl(pane.rect(r.x, lanes_bottom, r.width, 1)), ui_style.edge);
        if (drawMasterHeader(ui, pane.rect(header_x, lanes_bottom, header_w, master_h), master, device_sel.* == .master)) {
            master_clicked = true;
        }
    }

    // Flip the bay between master and audio: clicking the master strip parks
    // on master; clicking anywhere in the track lanes/headers returns to the
    // audio selection (even re-clicking the already-selected track).
    if (master_clicked) {
        device_sel.* = .master;
    } else if (m.left_pressed and pane.contains(pane.rect(r.x, lanes_top, r.width, lanes_h), m.x, m.y)) {
        device_sel.* = .audio;
    }

    targetMenuTick(tracks, alloc);
    headerAutoMenuTick(tracks, alloc);
    result.route = route_menu.tick(tracks, selected_track.*);

    // Overview strip on top (rendered last so nothing scissor-clips it).
    drawOverview(ui, overview_rect, timeline_w, tracks, content_beats, transport, m);
    // The ruler owns right-click (meter menu); keep the arrangement menu off it.
    const rclick_on_ruler = m.right_pressed and (pane.contains(ruler_rect, m.x, m.y) or pane.contains(marker_rect, m.x, m.y));
    // A lane point's menu opened this frame keeps the press.
    const lane_menu_open = menu.active() and !menu.isOpen(ARR_CONTEXT_KEY);
    if (!rclick_on_ruler and !lane_menu_open and menu.openContext(ui, ARR_CONTEXT_KEY, bridge.fromRl(r))) {
        context_target = .{ .beat = beatAtX(timeline_x0, m.x), .track = selected_track.* };
    }
    const has_selection = hasSelectedClips(tracks);
    const has_clips = hasAnyClips(tracks);
    const arr_context_items = [_]menu.Item{
        .{ .label = "Import audio\u{2026}", .command = .import_audio, .enabled = tracks.len > 0 },
        .{ .separator = true },
        .{ .label = "Copy", .command = .copy, .enabled = has_selection },
        .{ .label = "Cut", .command = .cut, .enabled = has_selection },
        .{ .label = "Paste", .command = .paste, .enabled = can_paste_clips },
        .{ .separator = true },
        .{ .label = "Duplicate", .command = .duplicate, .enabled = has_selection },
        .{ .label = "Split at playhead", .command = .split_at_playhead, .enabled = has_selection },
        .{ .label = "Reverse", .command = .reverse, .enabled = hasSelectedAudioClips(tracks) },
        .{ .label = if (allSelectedAudioWarped(tracks)) "Unwarp" else "Warp", .command = .warp, .enabled = hasSelectedAudioClips(tracks) },
        .{ .label = "Slice to a sampler track", .command = .slice_to_sampler, .enabled = focusedWarped(tracks, selected_clip.*) },
        .{ .label = if (has_selection and allSelectedMuted(tracks)) "Unmute" else "Mute", .command = .mute_clips, .enabled = has_selection },
        .{ .label = "Delete", .command = .delete, .enabled = has_selection },
        .{ .label = "Bounce\u{2026}", .command = .bounce, .enabled = has_selection },
        .{ .label = "Re-bounce", .command = .rebounce, .enabled = focusedIsBounce(tracks, selected_clip.*) },
        .{ .label = "Thaw", .command = .thaw, .enabled = focusedIsBounce(tracks, selected_clip.*) },
        .{ .separator = true },
        .{ .label = "Rename", .command = .rename, .enabled = has_selection },
        .{ .label = "Save to Library", .command = .save_to_library, .enabled = has_selection },
        .{ .label = "Select all", .command = .select_all, .enabled = has_clips },
        .{ .label = "Clear selection", .command = .clear_selection, .enabled = has_selection },
        .{ .separator = true },
        .{ .label = "Loop selection", .command = .loop_selection, .enabled = has_selection },
        .{ .label = "Loop arrangement", .command = .loop_arrangement, .enabled = has_clips },
        .{ .label = "Clear loop", .command = .clear_loop, .enabled = true },
        .{ .separator = true },
        .{ .label = "Clear solos & mutes", .command = .clear_solo_mute, .enabled = anySoloOrMute(tracks) },
    };
    result.command = menu.command(ARR_CONTEXT_KEY, &arr_context_items);
    if (result.command != .none) {
        result.command_beat = context_target.beat;
        result.command_track = context_target.track;
    }
    return result;
}

fn handleWheel(zone: c.rl.Rectangle, m: pane.Mouse) void {
    if (!pane.contains(zone, m.x, m.y)) return;
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

/// Over the track headers the wheel scrolls the tracks up and down (the
/// lanes beside them follow). ⌘ leaves it to the header's controls.
fn handleHeaderWheel(zone: c.rl.Rectangle, m: pane.Mouse) void {
    if (!pane.contains(zone, m.x, m.y) or m.wheel_y == 0) return;
    if (c.rl.IsKeyDown(c.rl.KEY_LEFT_SUPER) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SUPER)) return;
    scroll_y -= m.wheel_y * 30;
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

pub fn anySoloOrMute(tracks: []const Track) bool {
    for (tracks) |*t| if (t.mute.load(.monotonic) or t.solo.load(.monotonic)) return true;
    return false;
}

/// Unmutes and unsolos every track; false when there was nothing to clear.
pub fn clearSolosAndMutes(tracks: []Track) bool {
    const any = anySoloOrMute(tracks);
    for (tracks) |*t| {
        t.mute.store(false, .monotonic);
        t.solo.store(false, .monotonic);
    }
    return any;
}

fn maxScrollX(content_beats: f64, timeline_w: f32) f32 {
    return @max(0.0, @as(f32, @floatCast(content_beats)) * px_per_beat - timeline_w);
}

fn clampScroll(content_beats: f64, timeline_w: f32) void {
    const max_sx = maxScrollX(content_beats, timeline_w);
    if (scroll_x < 0) scroll_x = 0;
    if (scroll_x > max_sx) scroll_x = max_sx;
}

fn clampScrollY(content_h: f32, lanes_h: f32) void {
    const max_sy = @max(0.0, content_h - lanes_h);
    if (scroll_y < 0) scroll_y = 0;
    if (scroll_y > max_sy) scroll_y = max_sy;
}

/// Seconds an audio clip spans from `start` for `len` beats.
fn cmdDown() bool {
    return c.rl.IsKeyDown(c.rl.KEY_LEFT_SUPER) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SUPER);
}

/// The length of an audio clip's source in seconds, if it has one.
fn sourceSeconds(clip: *const Clip) ?f64 {
    const pool = cur_pool orelse return null;
    const src = pool.get(clip.audio.source) orelse return null;
    const s = src.seconds();
    return if (s > 0) s else null;
}

/// ⌘-edge drag (docs/29 §Editing): the content scales to `new_len` beats,
/// warping the clip on first.
fn stretchClip(alloc: std.mem.Allocator, clip: *Clip, new_len: f64) void {
    if (!clip.audio.warp) {
        const len = sourceSeconds(clip) orelse return;
        const src = cur_pool.?.get(clip.audio.source).?;
        warp_mod.warpOn(alloc, clip, cur_tempo, len, src.onsets()) catch return;
    }
    if (clip.length_beats <= 0) return;
    warp_mod.stretch(clip, new_len / clip.length_beats);
}

fn clipSeconds(start: f64, len: f64) f64 {
    return cur_tempo.secondsAt(start + len) - cur_tempo.secondsAt(start);
}

// ── Clip selection ───────────────────────────────────────────────────

fn deselectAllClips(tracks: []Track) void {
    for (tracks) |*t| {
        for (t.clips.items) |*clip| clip.selected = false;
    }
}

/// Recompute every audio clip's `length_beats` from its source window
/// through the tempo map. The window (`dur_sec`) is tempo-independent, so
/// this keeps the clip's bar-span correct as the tempo changes.
pub fn reflowAudioClips(tracks: []Track, tmap: *const tempo_mod.TempoMap) void {
    for (tracks) |*t| {
        for (t.clips.items) |*clip| {
            if (!clip.isAudio() or clip.audio.warp) continue;
            clip.length_beats = @max(MIN_CLIP_BEATS, tmap.beatAfter(clip.start_beat, clip.audio.dur_sec) - clip.start_beat);
        }
    }
}

fn beginBoxSelect(track_idx: ?usize, m: pane.Mouse, shift: bool) void {
    if (!pane.tryStartDrag(BOX_KEY)) return;
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
    m: pane.Mouse,
    timeline_x: f32,
    timeline_w: f32,
    timeline_x0: f32,
    lanes_top: f32,
) void {
    if (!box_active) return;
    if (pane.isDraggingKey(BOX_KEY) and m.left_down) return;

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
            if (!isShown(tracks, ti)) continue;
            const ly = lanes_top + rowTop(tracks, ti) - scroll_y;
            const lane = pane.rect(timeline_x, ly, timeline_w, LANE_H);
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
    pane.cancelDrag();
}


fn normalizedRect(x0: f32, y0: f32, x1: f32, y1: f32) c.rl.Rectangle {
    const nx0 = @min(x0, x1);
    const ny0 = @min(y0, y1);
    const nx1 = @max(x0, x1);
    const ny1 = @max(y0, y1);
    return pane.rect(nx0, ny0, nx1 - nx0, ny1 - ny0);
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
    return pane.rect(x0, y0, x1 - x0, y1 - y0);
}

// ── Clip drag ────────────────────────────────────────────────────────

fn beginDrag(tracks: []Track, ref: ClipRef, clip: Clip, m: pane.Mouse, mode: DragMode) void {
    const key = pane.keyFromIds(DRAG_SALT, ref.track, ref.clip);
    if (!pane.tryStartDrag(key)) return;
    drag_mode = mode;
    drag_ref = ref;
    drag_start_beat = clip.start_beat;
    drag_start_length = clip.length_beats;
    drag_start_mouse_x = m.x;
    drag_start_audio_start_sec = clip.audio.start_sec;
    drag_start_audio_dur_sec = clip.audio.dur_sec;
    drag_start_audio_offset = clip.audio.offset_beats;
    drag_start_fade_sec = switch (mode) {
        .fade_in => clip.audio.fade_in_sec,
        .fade_out => clip.audio.fade_out_sec,
        else => 0,
    };
    drag_track_delta = 0;
    drag_snap_count = 0;
    drag_stretch = (mode == .resize_r or mode == .resize_l) and clip.isAudio() and cmdDown();
    if (mode == .move) {
        snapshotSelectedClips(tracks);
    }
}

fn continueDrag(tracks: []Track, alloc: std.mem.Allocator, selected_clip: *?ClipRef, edit_snap: snap_mod.Setting, m: pane.Mouse, lanes_top: f32) void {
    if (drag_mode == .none) return;
    const key = pane.keyFromIds(DRAG_SALT, drag_ref.track, drag_ref.clip);
    if (!pane.isDraggingKey(key)) {
        drag_mode = .none;
        return;
    }

    if (!m.left_down) {
        finishClipDrag(tracks, alloc, selected_clip, m, lanes_top);
        pane.cancelDrag();
        drag_mode = .none;
        return;
    }

    if (drag_ref.track >= tracks.len) {
        pane.cancelDrag();
        drag_mode = .none;
        return;
    }
    const t = &tracks[drag_ref.track];
    if (drag_ref.clip >= t.clips.items.len) {
        pane.cancelDrag();
        drag_mode = .none;
        return;
    }
    const clip = &t.clips.items[drag_ref.clip];

    const dx = m.x - drag_start_mouse_x;
    const d_beats = snap_mod.snapNearest(edit_snap, @as(f64, dx / px_per_beat), altBypassSnap());
    drag_track_delta = audioRankAtY(tracks, m.y - lanes_top + scroll_y) - audioRank(tracks, drag_ref.track);

    switch (drag_mode) {
        .none => {},
        .move => {
            pane.requestCursor(c.rl.MOUSE_CURSOR_POINTING_HAND, 3);
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
            pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
            const new_len = @max(drag_start_length + d_beats, minClipBeats(edit_snap));
            if (drag_stretch) {
                stretchClip(alloc, clip, new_len);
                return;
            }
            clip.length_beats = new_len;
            // Warped, the content runs on past either end: a plain trim.
            // Unwarped, resizing trims the source window so reflow keeps it,
            // up to the source's end. Reversed, the right edge plays the
            // window's head: it moves.
            if (clip.isAudio() and !clip.audio.warp) {
                if (!clip.audio.reversed) if (sourceSeconds(clip)) |len| {
                    const room = cur_tempo.beatAfter(clip.start_beat, len - clip.audio.start_sec) - clip.start_beat;
                    clip.length_beats = @max(@min(clip.length_beats, room), @min(MIN_CLIP_BEATS, room));
                };
                if (clip.audio.reversed) {
                    const tail = drag_start_audio_start_sec + drag_start_audio_dur_sec;
                    clip.length_beats = @min(clip.length_beats, cur_tempo.beatAfter(clip.start_beat, tail) - clip.start_beat); // can't read before the source start
                    clip.audio.dur_sec = clipSeconds(clip.start_beat, clip.length_beats);
                    clip.audio.start_sec = @max(0.0, tail - clip.audio.dur_sec);
                } else clip.audio.dur_sec = clipSeconds(clip.start_beat, clip.length_beats);
            }
        },
        .fade_in, .fade_out => {
            // Fades drag unsnapped in seconds, clamped to the window length.
            pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
            const raw_beats = @as(f64, dx / px_per_beat);
            const delta_sec = raw_beats * 60.0 / cur_tempo.bpmAt(clip.start_beat);
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
            pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
            const min_len = minClipBeats(edit_snap);
            const right_beat = drag_start_beat + drag_start_length;
            if (drag_stretch) {
                const new_start = std.math.clamp(drag_start_beat + d_beats, 0, right_beat - min_len);
                stretchClip(alloc, clip, right_beat - new_start);
                clip.start_beat = right_beat - clip.length_beats;
                return;
            }
            if (clip.audio.warp) {
                // Warped: trim in content beats; the audio stays on the grid.
                var delta = @min(d_beats, drag_start_length - min_len);
                if (drag_start_beat + delta < 0) delta = -drag_start_beat;
                clip.start_beat = drag_start_beat + delta;
                clip.length_beats = right_beat - clip.start_beat;
                clip.audio.offset_beats = drag_start_audio_offset + delta;
                return;
            }
            // Clamp the move so the window stays within [0, source] and the
            // clip keeps a minimum length.
            // Reversed, the left edge plays the window's tail, so the head
            // stays put and only the length changes.
            const rev = clip.audio.reversed;
            const max_back = if (rev) std.math.inf(f64) else drag_start_beat - cur_tempo.beatAfter(drag_start_beat, -drag_start_audio_start_sec); // can't trim before source start
            var delta = d_beats;
            if (delta < -max_back) delta = -max_back; // expanding left limited by source head
            if (delta > drag_start_length - min_len) delta = drag_start_length - min_len;
            if (drag_start_beat + delta < 0) delta = -drag_start_beat;
            const new_start = drag_start_beat + delta;
            clip.start_beat = new_start;
            clip.length_beats = right_beat - new_start;
            const delta_sec = cur_tempo.secondsAt(new_start) - cur_tempo.secondsAt(drag_start_beat);
            if (!rev) clip.audio.start_sec = @max(0.0, drag_start_audio_start_sec + delta_sec);
            clip.audio.dur_sec = @max(0.0, drag_start_audio_dur_sec - delta_sec);
        },
    }
}

fn finishClipDrag(tracks: []Track, alloc: std.mem.Allocator, selected_clip: *?ClipRef, m: pane.Mouse, lanes_top: f32) void {
    if (drag_mode == .none) return;
    // Only a body move relocates between tracks; resizes stay on their lane.
    if (drag_mode != .move) return;
    if (drag_ref.track >= tracks.len) return;
    const src_t = &tracks[drag_ref.track];
    if (drag_ref.clip >= src_t.clips.items.len) return;

    const target_rank = audioRankAtY(tracks, m.y - lanes_top + scroll_y);
    const target_i = audioAt(tracks, target_rank) orelse return;
    if (target_i == drag_ref.track) return;

    if (drag_snap_count > 0) {
        moveSelectedClipsBetweenTracks(tracks, alloc, selected_clip, target_rank - audioRank(tracks, drag_ref.track));
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
        // Moves go by audio rank: clips skip past buses.
        const target_signed: i32 = @intCast(audioAt(tracks, audioRank(tracks, s.track) + delta) orelse continue);
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

const METER_MENU_KEY: u64 = 0x4d_45_54_52_4d_4e_55_01; // "METRMNU"
const METER_REMOVE_ID: u32 = 1000;
const METER_GROUPS_ID: u32 = 1001;
const TEMPO_ADD_ID: u32 = 3000;
const TEMPO_RAMP_ID: u32 = 3001;
const TEMPO_REMOVE_ID: u32 = 3002;
const SONG_GROOVE_ID: u32 = 3003;
var song_groove_labels: [groove_mod.MAX_GROOVES + 1][40]u8 = undefined;
// Grouping submenu rows: DEFAULT, then GROUP_BASE + choice index.
const GROUP_DEFAULT_ID: u32 = 3000;
const GROUP_BASE: u32 = 3001;
// Main-thread label storage for the grouping rows (the menu draws them at
// the end of the frame).
var group_choices: [meter_mod.MAX_CHOICES]meter_mod.Groups = undefined;
var group_labels: [meter_mod.MAX_CHOICES + 1][72]u8 = undefined;
var group_title: [32]u8 = undefined;

/// "3+2+2", optionally with the current-choice bullet.
fn groupsLabel(buf: []u8, gs: []const u8, on: bool) []const u8 {
    var w: usize = 0;
    if (on) {
        const b = "\u{2022} ";
        @memcpy(buf[0..b.len], b);
        w = b.len;
    }
    for (gs, 0..) |g, i| {
        const part = std.fmt.bufPrint(buf[w..], "{s}{d}", .{ if (i > 0) "+" else "", g }) catch break;
        w += part.len;
    }
    return buf[0..w];
}
// Bar the meter menu targets (set when opened on a ruler right-click).
var meter_menu_bar: u32 = 0;

const MeterChoice = struct { label: []const u8, num: u8, den: u8 };
const METER_CHOICES = [_]MeterChoice{
    .{ .label = "4/4", .num = 4, .den = 4 },
    .{ .label = "3/4", .num = 3, .den = 4 },
    .{ .label = "2/4", .num = 2, .den = 4 },
    .{ .label = "5/4", .num = 5, .den = 4 },
    .{ .label = "6/8", .num = 6, .den = 8 },
    .{ .label = "7/8", .num = 7, .den = 8 },
    .{ .label = "5/8", .num = 5, .den = 8 },
    .{ .label = "9/8", .num = 9, .den = 8 },
    .{ .label = "12/8", .num = 12, .den = 8 },
};

// Algorithmic meter generators (docs/07 §generators). These REPLACE the
// whole meter map (materialize-on-run), so they ignore the target bar.
const METER_GEN_BASE: u32 = 2000;
const GenKind = enum { fib, euclid3, euclid5, additive223, additive332 };
const MeterGen = struct { label: []const u8, kind: GenKind };
const METER_GENS = [_]MeterGen{
    .{ .label = "Generate: Fibonacci /8", .kind = .fib },
    .{ .label = "Generate: Euclid 3/8", .kind = .euclid3 },
    .{ .label = "Generate: Euclid 5/8", .kind = .euclid5 },
    .{ .label = "Generate: Additive 2+2+3", .kind = .additive223 },
    .{ .label = "Generate: Additive 3+3+2", .kind = .additive332 },
};
// Main-thread scratch for generators (never touched by audio).
var gen_pts: [meter_mod.MAX_POINTS]meter_mod.MeterPoint = undefined;
var gen_nums: [64]u8 = undefined;

fn meterMenuTick(meter_state: *meter_mod.MeterState, result: *Result) void {
    if (!menu.isOpen(METER_MENU_KEY)) return;
    var items: [METER_CHOICES.len + 3 + METER_GENS.len + 5]menu.Item = undefined;
    inline for (METER_CHOICES, 0..) |ch, i| items[i] = .{ .label = ch.label, .id = @intCast(i) };
    // A change can be removed only if one starts exactly on the target bar
    // (and never bar 0, the base meter).
    const seg = meter_state.liveMap().segmentForBar(meter_menu_bar); // the edited map, not the one playing
    const can_remove = meter_menu_bar > 0 and seg.start_bar == meter_menu_bar;
    // Grouping of the meter this bar is in: 7/8 as 2+2+3, 3+2+2, ...
    const n_groups = meter_mod.groupingChoices(seg.numerator, &group_choices);
    const title = std.fmt.bufPrint(&group_title, "Grouping of {d}/{d}", .{ seg.numerator, seg.denominator }) catch "Grouping";
    items[METER_CHOICES.len] = .{ .separator = true };
    items[METER_CHOICES.len + 1] = .{ .label = title, .id = METER_GROUPS_ID, .submenu = true, .enabled = n_groups > 0 };
    items[METER_CHOICES.len + 2] = .{ .label = "Remove change here", .id = METER_REMOVE_ID, .enabled = can_remove };
    inline for (METER_GENS, 0..) |g, i| items[METER_CHOICES.len + 3 + i] = .{ .label = g.label, .id = METER_GEN_BASE + @as(u32, @intCast(i)) };
    // Tempo at the bar's downbeat: add a change, ramp the segment into the
    // next, remove the change starting here.
    const tb = cur_meter.barStartBeat(meter_menu_bar);
    const tm = cur_tempo;
    const at = tm.find(tb);
    const seg_i = tm.segment(tb);
    const t0 = METER_CHOICES.len + 3 + METER_GENS.len;
    items[t0] = .{ .separator = true };
    items[t0 + 1] = .{ .label = "Tempo change here", .id = TEMPO_ADD_ID, .enabled = at == null };
    items[t0 + 2] = .{ .label = if (tm.points[seg_i].ramp) "\u{2022} Ramp to next tempo" else "Ramp to next tempo", .id = TEMPO_RAMP_ID, .enabled = seg_i + 1 < tm.len };
    items[t0 + 3] = .{ .label = "Remove tempo change", .id = TEMPO_REMOVE_ID, .enabled = if (at) |i| i > 0 else false };
    items[t0 + 4] = .{ .label = "Song groove", .id = SONG_GROOVE_ID, .submenu = true, .enabled = groove_mod.active != null };

    if (menu.pick(METER_MENU_KEY, &items)) |id| {
        if (id == TEMPO_ADD_ID or id == TEMPO_RAMP_ID or id == TEMPO_REMOVE_ID) {
            result.tempo_edit = .{ .kind = switch (id) {
                TEMPO_ADD_ID => .add,
                TEMPO_RAMP_ID => .toggle_ramp,
                else => .remove,
            }, .beat = tb };
        } else if (id == METER_REMOVE_ID) {
            meter_state.removeChange(meter_menu_bar);
        } else if (id >= METER_GEN_BASE) {
            const g = METER_GENS[id - METER_GEN_BASE];
            const pts = switch (g.kind) {
                .fib => meter_gen.fibonacci(&gen_pts, &gen_nums, 8, 8, 13),
                .euclid3 => meter_gen.euclidean(&gen_pts, 3, 8, 8),
                .euclid5 => meter_gen.euclidean(&gen_pts, 5, 8, 8),
                .additive223 => meter_gen.additive(&gen_pts, &gen_nums, &.{ 2, 2, 3 }, 8, 4),
                .additive332 => meter_gen.additive(&gen_pts, &gen_nums, &.{ 3, 3, 2 }, 8, 4),
            };
            meter_state.stage(pts);
        } else {
            const ch = METER_CHOICES[id];
            meter_state.insertChange(meter_menu_bar, ch.num, ch.den);
        }
    }
    if (menu.subOpen(METER_MENU_KEY, 0)) |sid| if (sid == SONG_GROOVE_ID) if (groove_mod.active) |cx| {
        // STRAIGHT, then the pool; the current one bulleted.
        var sub: [groove_mod.MAX_GROOVES + 1]menu.Item = undefined;
        const n = cx.pool.count + 1;
        for (0..n) |i| {
            const pick: u8 = if (i == 0) groove_mod.PICK_NONE else @intCast(groove_mod.PICK_POOL + i - 1);
            const name = if (i == 0) "STRAIGHT" else cx.pool.grooves[i - 1].name.get();
            sub[i] = .{ .label = if (cx.song == pick) (std.fmt.bufPrint(&song_groove_labels[i], "\u{2022} {s}", .{name}) catch name) else name, .id = pick };
        }
        if (menu.subPick(METER_MENU_KEY, 1, sub[0..n])) |pick| result.song_groove = @intCast(pick);
    };
    if (menu.subOpen(METER_MENU_KEY, 0)) |sid| if (sid == METER_GROUPS_ID) {
        var sub: [meter_mod.MAX_CHOICES + 1]menu.Item = undefined;
        var dbuf: [meter_mod.MAX_GROUPS]u8 = undefined;
        const plain = meter_mod.MeterPoint{ .start_bar = 0, .numerator = seg.numerator, .denominator = seg.denominator };
        const dg = plain.groupsInto(&dbuf);
        const explicit = seg.hasGroups();
        {
            const lb = &group_labels[0];
            const bullet: []const u8 = if (!explicit) "\u{2022} " else "";
            var dtxt: [48]u8 = undefined;
            const inner: []const u8 = if (dg.len == 1) "downbeat only" else groupsLabel(&dtxt, dg, false);
            const txt: []const u8 = std.fmt.bufPrint(lb, "{s}Default ({s})", .{ bullet, inner }) catch "Default";
            sub[0] = .{ .label = txt, .id = GROUP_DEFAULT_ID };
        }
        for (group_choices[0..n_groups], 0..) |gc, i| {
            const on = explicit and gc.eql(seg.groups);
            sub[i + 1] = .{ .label = groupsLabel(&group_labels[i + 1], gc.slice(), on), .id = GROUP_BASE + @as(u32, @intCast(i)) };
        }
        if (menu.subPick(METER_MENU_KEY, 1, sub[0 .. n_groups + 1])) |gid| {
            const gs: meter_mod.Groups = if (gid == GROUP_DEFAULT_ID) .{} else group_choices[gid - GROUP_BASE];
            meter_state.setGroupsAtBar(meter_menu_bar, gs);
        }
    };
}



fn clipRect(lane: c.rl.Rectangle, clip: Clip, timeline_x0: f32) c.rl.Rectangle {
    const x = timeline_x0 + @as(f32, @floatCast(clip.start_beat)) * px_per_beat - scroll_x;
    const w = @as(f32, @floatCast(clip.length_beats)) * px_per_beat;
    return pane.rect(x, lane.y + 2, w, lane.height - 4);
}





const HeaderAction = enum { none, select, rename, color };
/// The header's pan mini, beside the volume mini on the bottom row.
const HEADER_PAN_W: i32 = 48;
const HeaderResult = struct {
    action: HeaderAction = .none,
    name_rect: c.rl.Rectangle,
    color_at: [2]i32 = .{ 0, 0 },
};


/// Track header on the new Ui (docs/06 §Working surfaces): faceplate with
/// the track-color spine (+ amber selection stripe), index and name, R/M/S
/// lit latches, pan and volume mini sliders, and a bare stereo meter.
/// `number` is the track's place among the audio tracks (1-based); a bus
/// shows its `bus_letter` instead.
/// Where a header sits among groups: its enclosing groups' colors,
/// outermost first, and whether it heads a group itself.
const Nest = struct {
    rails: []const ui_style.Color = &.{},
    group: bool = false,
};

pub const RAIL_W: i32 = 6;
/// The track-color spine; a click on it picks the color.
pub const SPINE_W: i32 = 5;

fn drawLaneHeader(ui: *Ui, r_legacy: c.rl.Rectangle, t: *Track, idx: usize, number: usize, bus_letter: ?u8, selected: bool, editing_name: bool, beat: f64, nest: Nest) HeaderResult {
    const r = bridge.fromRl(r_legacy);
    ui.pushId(t);
    defer ui.popId();
    var body = ui.plate(r, .{ .fill = if (selected) ui_style.face.shade(8) else ui_style.face });
    // Rails: one per enclosing group, in its color, then this row's spine
    // (full-height track color) and an amber stripe when selected.
    var sx = r.x;
    for (nest.rails) |col| {
        ui.rect(Rect.xywh(sx, r.y, RAIL_W - 1, r.h - 1), col.mix(ui_style.face, 0.35));
        sx += RAIL_W;
    }
    const spine = Rect.xywh(sx, r.y, SPINE_W, r.h - 1);
    const sb = ui.behaviorEx(ui.id("spine"), spine, .{ .focusable = false });
    ui.rect(spine, if (sb.hover) trackColor(t.color).mix(ui_style.text, 0.25) else trackColor(t.color));
    menu.tip(ui, spine, "Click to change the color");
    if (selected) ui.rect(Rect.xywh(sx + SPINE_W, r.y, 2, r.h - 1), ui_style.accent);
    _ = body.cutLeft(SPINE_W + 3 + sx - r.x);

    const peaks = t.meter();
    ctl.meterStereo(ui, body.cutRight(12).insetXY(0, 1), "meter", .{ peaks.l, peaks.r }, .{ peaks.l, peaks.r }, .{ .scale = .none });
    _ = body.cutRight(4);

    var row1 = body.cutTop(20);
    var btns = row1.cutRight(4 * 17);
    var shown = t.lanes_shown;
    const auto_r = btns.cutLeft(17).insetXY(0, 2);
    if (ctl.button(ui, auto_r, "autoshow", &shown, .{ .kind = .latch, .label = "A", .lit = ui_style.auto })) t.lanes_shown = shown;
    menu.tip(ui, auto_r, if (t.lanes_shown) "Hide automation lanes" else "Show automation lanes");
    const arm_r = btns.cutLeft(17).insetXY(0, 2);
    if (!t.isBus()) {
        var armed = t.isArmed();
        if (ctl.button(ui, arm_r, "arm", &armed, .{ .kind = .latch, .label = "R", .lit = ui_style.rec, .disabled = t.kind != .audio })) t.setArmed(armed);
        menu.tip(ui, arm_r, if (t.isArmed()) "Disarm (record)" else "Arm for recording");
    }
    var muted = t.mute.load(.monotonic);
    const mute_r = btns.cutLeft(17).insetXY(0, 2);
    if (ctl.button(ui, mute_r, "mute", &muted, .{ .kind = .latch, .label = "M", .lit = ui_style.led_blue })) {
        t.mute.store(muted, .monotonic);
        hdr_mute_set = muted;
    }
    menu.tip(ui, mute_r, if (muted) "Unmute track (\u{21E7}M clears all)" else "Mute track");
    var solo = t.solo.load(.monotonic);
    const solo_r = btns.insetXY(0, 2);
    if (ctl.button(ui, solo_r, "solo", &solo, .{ .kind = .latch, .label = "S", .lit = ui_style.led_yellow })) {
        t.solo.store(solo, .monotonic);
        hdr_solo_set = solo;
    }
    menu.tip(ui, solo_r, if (solo) "Unsolo track (\u{21E7}M clears all)" else "Solo track");

    // Index badge + name; the name row is also the select/rename target.
    var ibuf: [8]u8 = undefined;
    const idx_s = if (bus_letter) |l| std.fmt.bufPrint(&ibuf, "{c}", .{l}) catch "?" else std.fmt.bufPrint(&ibuf, "{d}", .{number}) catch "?";
    var fold_r: Rect = .{};
    if (nest.group) {
        fold_r = row1.cutLeft(12);
        const fb = ui.behaviorEx(ui.id("fold"), fold_r, .{ .focusable = false });
        if (fb.pressed) t.folded = !t.folded;
        ui.textIn(&ui.fonts.legend, fold_r, if (t.folded) "\u{25B8}" else "\u{25BE}", if (fb.hover) ui_style.text else ui_style.text_dim, .left, true);
        menu.tip(ui, fold_r, if (t.folded) "Unfold group" else "Fold group");
    }
    const idx_r = row1.cutLeft(14);
    ui.textIn(&ui.fonts.legend, idx_r, idx_s, ui_style.text_mute, .left, true);
    // Frozen (docs/28 §Freeze): a plate saying so, red once it's stale.
    if (t.freeze) |f| {
        const label = if (f.stale) "STALE" else "FROZEN";
        const br = row1.cutRight(ui.fonts.legend.measure(label) + 8).insetXY(2, 4);
        ui.rect(br, ui_style.well);
        ui.textIn(&ui.fonts.legend, br, label, if (f.stale) ui_style.rec else ui_style.led_blue, .center, false);
        menu.tip(ui, br, if (f.stale) "Frozen, but it changed since: right-click the name, Freeze again" else "Frozen: its audio plays instead of its machines (right-click the name to unfreeze)");
    }
    // Its own time (docs/28 §Polymeter and polytempo): "5/4", "3:2".
    if (!t.time.isDefault()) {
        var tb: [16]u8 = undefined;
        const meter_s: []const u8 = if (t.time.hasMeter()) (std.fmt.bufPrint(tb[0..8], "{d}/{d}", .{ t.time.num, t.time.den }) catch "") else "";
        const ratio_s: []const u8 = if (t.time.p != t.time.q) (std.fmt.bufPrint(tb[8..], "{d}:{d}", .{ t.time.p, t.time.q }) catch "") else "";
        var lb: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "{s}{s}{s}", .{ meter_s, if (meter_s.len > 0 and ratio_s.len > 0) " " else "", ratio_s }) catch "";
        const br = row1.cutRight(ui.fonts.legend.measure(label) + 8).insetXY(2, 4);
        ui.rect(br, ui_style.well);
        ui.textIn(&ui.fonts.legend, br, label, ui_style.vfd, .center, false);
        menu.tip(ui, br, "Its own meter or tempo ratio: right-click the name, Meter / Tempo ratio");
    }
    const name_r = row1;
    if (!editing_name) ui.marquee(&ui.fonts.body, name_r, t.name(), if (selected) ui_style.text else ui_style.text_dim, .left, true, name_r.contains(ui.in.ix(), ui.in.iy()));

    // Pan and volume share the bottom row, pan short on the left, so both
    // show at the default lane height. Automated, they show the lane's
    // value and a hand move overrides it (docs/22 §Manual changes).
    var mix_row = body.cutBottom(@min(body.h, 16));
    var pan_r = mix_row.cutLeft(HEADER_PAN_W);
    _ = mix_row.cutLeft(6);
    var vol_r = mix_row;
    const vol_auto = t.isAutomated(automation.Target.volume());
    if (vol_auto) _ = vol_r.cutRight(8);
    var v_norm: f32 = std.math.clamp(t.volumeAt(beat) / 1.25, 0.0, 1.0);
    const vol_base = t.volume();
    const pressed_now = ui.in.pressed;
    if (ctl.slider(ui, vol_r, "vol", &v_norm, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 5, .default = 1.0 / 1.25 })) t.setVolume(v_norm * 1.25);
    if (ui.active == ui.id("vol")) t.touch_vol = true;
    if (ui.in.right_pressed and vol_r.contains(ui.in.ix(), ui.in.iy())) openHeaderAutoMenu(idx, .volume, ui.in.ix(), ui.in.iy());
    if (vol_auto) headerOverride(ui, &t.vol_override, "vol", t.volume() != vol_base, pressed_now, Rect.xywh(vol_r.right(), vol_r.y, 8, vol_r.h));
    menu.tip(ui, vol_r, "Track volume");
    {
        const pan_auto = t.isAutomated(automation.Target.pan());
        if (pan_auto) _ = pan_r.cutRight(8);
        var p: f32 = (t.panAt(beat) + 1) / 2;
        const pan_base = t.pan();
        if (ctl.slider(ui, pan_r, "pan", &p, .{ .kind = .mini, .horizontal = true, .bipolar = true, .show_readout = false, .ticks = 3, .default = 0.5 })) t.setPan(p * 2 - 1);
        if (ui.active == ui.id("pan")) t.touch_pan = true;
        if (ui.in.right_pressed and pan_r.contains(ui.in.ix(), ui.in.iy())) openHeaderAutoMenu(idx, .pan, ui.in.ix(), ui.in.iy());
        if (pan_auto) headerOverride(ui, &t.pan_override, "pan", t.pan() != pan_base, pressed_now, Rect.xywh(pan_r.right(), pan_r.y, 8, pan_r.h));
        menu.tip(ui, pan_r, "Pan (double-click to center)");
    }

    const hit_x = if (nest.group) fold_r.right() else r.x;
    const name_hit = Rect.xywh(hit_x, r.y, name_r.right() - hit_x, 20);
    if (ui.in.right_pressed and name_hit.contains(ui.in.ix(), ui.in.iy())) {
        route_menu.open(idx, .all, ui.in.ix(), ui.in.iy());
    }
    menu.tip(ui, name_hit, if (nest.group) "Group: right-click to route" else if (t.isBus()) "Return: right-click to route" else "Right-click to route");
    const b = ui.behaviorEx(ui.id("name"), name_hit, .{ .focusable = false });
    const name_rl = bridge.toRl(name_r);
    if (sb.pressed) return .{ .action = .color, .name_rect = name_rl, .color_at = .{ spine.right(), spine.y } };
    if (b.pressed) return .{ .action = if (b.double) .rename else .select, .name_rect = name_rl };
    return .{ .action = .none, .name_rect = name_rl };
}

const HEADER_AUTO_MENU_KEY: u64 = 0xA070_4EAD_E700_0001;
var header_menu_track: usize = 0;
var header_menu_kind: automation.TargetKind = .volume;

fn openHeaderAutoMenu(ti: usize, kind: automation.TargetKind, x: i32, y: i32) void {
    header_menu_track = ti;
    header_menu_kind = kind;
    menu.openAt(HEADER_AUTO_MENU_KEY, x, y);
}

/// Show / Clear / Re-enable automation for a header volume or pan mini.
fn headerAutoMenuTick(tracks: []Track, alloc: std.mem.Allocator) void {
    if (!menu.isOpen(HEADER_AUTO_MENU_KEY)) return;
    if (header_menu_track >= tracks.len) {
        menu.close();
        return;
    }
    const t = &tracks[header_menu_track];
    const target: automation.Target = if (header_menu_kind == .volume) automation.Target.volume() else automation.Target.pan();
    const ov = if (header_menu_kind == .volume) &t.vol_override else &t.pan_override;
    const items = [_]menu.Item{
        .{ .label = "Show automation", .id = 1 },
        .{ .label = "Clear automation", .id = 2, .enabled = t.findLane(target) != null },
        .{ .label = "Re-enable automation", .id = 3, .enabled = ov.load(.monotonic) != 0 },
    };
    switch (menu.pick(HEADER_AUTO_MENU_KEY, &items) orelse return) {
        1 => {
            t.lanes_shown = true;
            _ = t.laneFor(alloc, target, false) catch {};
        },
        2 => for (t.lanes.items, 0..) |*l, li| if (l.target.eql(target)) {
            t.removeLane(alloc, li);
            break;
        },
        3 => ov.store(0, .monotonic),
        else => {},
    }
}

/// Override bookkeeping and LED for an automated header slider: a held drag
/// overrides until release, other edits until the transport starts.
fn headerOverride(ui: *Ui, ov: *std.atomic.Value(u8), key: []const u8, changed: bool, was_pressed: bool, led_cell: Rect) void {
    const held = ui.active == ui.id(key);
    if (changed) {
        ov.store(if (held and !was_pressed) 1 else 2, .monotonic);
    } else if (ov.load(.monotonic) == 1 and !held) {
        ov.store(0, .monotonic);
    }
    const overridden = ov.load(.monotonic) != 0;
    if (ctl.autoLed(ui, led_cell.x + 2, led_cell.y + @divFloor(led_cell.h - 4, 2), .{ key, "auto" }, overridden) and overridden) ov.store(0, .monotonic);
    if (overridden) menu.tip(ui, led_cell, "Overridden by hand: click to follow the lane again");
}

// ── Automation lanes (docs/22) ───────────────────────────────────────

/// Beat ↔ pixel scale of the arrangement (automation recording thins its
/// strokes to 1 px at this zoom).
pub fn pxPerBeat() f32 {
    return px_per_beat;
}

pub fn deselectAllPoints(tracks: []Track) void {
    for (tracks) |*t| for (t.lanes.items) |*l| l.deselectAll();
}

fn deselectPointsExcept(tracks: []Track, keep: *const automation.Lane) void {
    for (tracks) |*t| for (t.lanes.items) |*l| if (l != keep) l.deselectAll();
}

pub fn hasSelectedPoints(tracks: []Track) bool {
    for (tracks) |*t| for (t.lanes.items) |*l| if (l.selectedCount() > 0) return true;
    return false;
}

/// Delete key in the arrangement: selected lane points win over clips.
pub fn deleteSelectedPoints(tracks: []Track) bool {
    var any = false;
    for (tracks) |*t| for (t.lanes.items) |*l| if (l.selectedCount() > 0) {
        l.removeSelected();
        any = true;
    };
    return any;
}

/// The automation rows of track `ti` on the timeline. Returns true when a
/// press landed in one.
fn drawAutomationRows(
    ui: *Ui,
    alloc: std.mem.Allocator,
    tracks: []Track,
    t: *Track,
    ti: usize,
    y: f32,
    timeline_x: f32,
    timeline_w: f32,
    timeline_x0: f32,
    edit_snap: snap_mod.Setting,
    selected_track: *?usize,
    selected_clip: *?ClipRef,
    m: pane.Mouse,
    press_consumed: bool,
) bool {
    if (t.lanes.items.len == 0) {
        const r = pane.rect(timeline_x, y, timeline_w, AUTO_H);
        const ri = bridge.fromRl(r);
        ui.rect(ri, ui_style.pane.shade(-3));
        ui.rect(Rect.xywh(ri.x, ri.bottom() - 1, ri.w, 1), ui_style.chassis);
        _ = ui.text(&ui.fonts.legend, ri.x + 4, ri.y + 14, "NO LANES: + IN THE HEADER, OR RIGHT-CLICK A KNOB", ui_style.text_mute);
        return false;
    }
    var consumed = false;
    const selected = selected_track.* != null and selected_track.*.? == ti;
    for (t.lanes.items, 0..) |*lane, li| {
        const r = pane.rect(timeline_x, y + @as(f32, @floatFromInt(li)) * AUTO_H, timeline_w, AUTO_H);
        var nb: [64]u8 = undefined;
        const info = lane_targets.laneInfo(&nb, t, lane);
        const res = auto_lane.draw(ui, alloc, lane, .{
            .rect = r,
            .timeline_x0 = timeline_x0,
            .scroll_x = scroll_x,
            .px_per_beat = px_per_beat,
            .edit_snap = edit_snap,
            .color = trackColor(t.color),
            .lo = info.lo,
            .hi = info.hi,
            .key = pane.keyFromIds(0xA070_1A4E_0000_0001, @intFromPtr(t), li),
            .name = info.name,
            .fmt = .{ .ctx = &info.fmt, .f = lane_targets.formatLane, .parse = lane_targets.parseLane },
            .selected = selected,
        }, if (press_consumed) pane.neutral() else m);
        // Clips holding a lane for the same target play theirs.
        for (t.clips.items) |*clip| {
            if (clip.isAudio()) continue;
            const cl = clip.findLane(lane.target) orelse continue;
            auto_lane.drawOverlay(ui, .{
                .rect = r,
                .timeline_x0 = timeline_x0,
                .scroll_x = scroll_x,
                .px_per_beat = px_per_beat,
                .edit_snap = edit_snap,
                .color = trackColor(t.color),
                .lo = info.lo,
                .hi = info.hi,
                .key = 0,
            }, cl.points.items, clip.start_beat, clip.endBeat());
        }
        // The legend stays readable over the overlays.
        {
            const ri = bridge.fromRl(r);
            ui.clip(ri);
            _ = ui.text(&ui.fonts.legend, ri.x + 4, ri.y + 2, info.name, ui_style.text_mute);
            ui.unclip();
        }
        if (res.pressed) {
            consumed = true;
            selected_track.* = ti;
            selected_clip.* = null;
            deselectAllClips(tracks);
            deselectPointsExcept(tracks, lane);
        }
    }
    return consumed;
}

const TARGET_MENU_KEY: u64 = 0xA070_7A26_E700_0001;
var menu_track: usize = 0;
/// The lane the picker retargets, or null to add a new lane.
var menu_lane: ?usize = null;


fn openTargetMenu(ti: usize, lane: ?usize, r: Rect) void {
    menu_track = ti;
    menu_lane = lane;
    menu.openBelow(TARGET_MENU_KEY, r);
}

/// The lane header column for track `ti`'s automation rows.
fn drawAutomationHeaders(ui: *Ui, alloc: std.mem.Allocator, t: *Track, ti: usize, x: f32, y: f32, w: f32) void {
    ui.pushId(.{ t, "lanes" });
    defer ui.popId();
    if (t.lanes.items.len == 0) {
        var body = ui.plate(bridge.fromRl(pane.rect(x, y, w, AUTO_H)), .{ .fill = ui_style.face.shade(-6) });
        ui.rect(Rect.xywh(body.x - 1, body.y, 3, body.h), trackColor(t.color).mix(ui_style.face, 0.5));
        _ = body.cutLeft(6);
        const add_r = body.insetXY(0, 10).takeLeft(92);
        if (ctl.button(ui, add_r, "add", null, .{ .label = "+ ADD LANE", .flush = true })) openTargetMenu(ti, null, add_r);
        return;
    }
    var remove: ?usize = null;
    for (t.lanes.items, 0..) |*lane, li| {
        ui.pushId(li);
        defer ui.popId();
        var body = ui.plate(bridge.fromRl(pane.rect(x, y + @as(f32, @floatFromInt(li)) * AUTO_H, w, AUTO_H)), .{ .fill = ui_style.face.shade(-6) });
        ui.rect(Rect.xywh(body.x - 1, body.y, 3, body.h), trackColor(t.color).mix(ui_style.face, 0.5));
        _ = body.cutLeft(6);
        var row = body.insetXY(0, 11);
        const del_r = row.cutRight(17);
        _ = row.cutRight(2);
        const add_r = row.cutRight(17);
        _ = row.cutRight(4);
        var nb: [64]u8 = undefined;
        const info = lane_targets.laneInfo(&nb, t, lane);
        if (ctl.button(ui, row, "target", null, .{ .label = info.name, .flush = true })) openTargetMenu(ti, li, row);
        menu.tip(ui, row, "Pick what this lane drives");
        if (ctl.button(ui, add_r, "add", null, .{ .label = "+", .flush = true })) openTargetMenu(ti, null, add_r);
        menu.tip(ui, add_r, "Add a lane");
        if (ctl.button(ui, del_r, "del", null, .{ .label = "\u{00D7}", .flush = true })) remove = li;
        menu.tip(ui, del_r, "Remove this lane");
    }
    if (remove) |li| t.removeLane(alloc, li);
}

/// The lane target picker for the arrangement's lane headers.
fn targetMenuTick(tracks: []Track, alloc: std.mem.Allocator) void {
    if (!menu.isOpen(TARGET_MENU_KEY)) return;
    if (menu_track >= tracks.len) {
        menu.close();
        return;
    }
    const t = &tracks[menu_track];
    const picked = lane_targets.tick(TARGET_MENU_KEY, t, .{ .lanes = t.lanes.items }) orelse return;
    const pick = switch (picked) {
        .target => |pk| pk,
        .remove => return,
    };
    t.lanes_shown = true;
    if (t.findLane(pick.target) != null) return; // one lane per target
    if (menu_lane) |li| {
        if (li >= t.lanes.items.len) return;
        lane_targets.retarget(&t.lanes.items[li], pick);
    } else {
        _ = t.laneFor(alloc, pick.target, pick.stepped) catch {};
    }
}

/// Pinned master header: spine, MASTER, pan and volume, stereo meter.
/// Returns true when the header is clicked (select master for the bay).
fn drawMasterHeader(ui: *Ui, hdr_legacy: c.rl.Rectangle, master: *Track, selected: bool) bool {
    const r = bridge.fromRl(hdr_legacy);
    ui.pushId("master");
    defer ui.popId();
    var body = ui.plate(r, .{ .fill = if (selected) ui_style.face.shade(8) else ui_style.face.shade(-4) });
    ui.rect(Rect.xywh(r.x, r.y, 3, r.h - 1), ui_style.face_hi);
    if (selected) ui.rect(Rect.xywh(r.x + 3, r.y, 2, r.h - 1), ui_style.accent);
    _ = body.cutLeft(6);
    const peaks = master.meter();
    ctl.meterStereo(ui, body.cutRight(12).insetXY(0, 1), "meter", .{ peaks.l, peaks.r }, .{ peaks.l, peaks.r }, .{ .scale = .none });
    _ = body.cutRight(4);
    const title = body.cutTop(20);
    ui.textIn(&ui.fonts.body_bold, title, "MASTER", if (selected) ui_style.text else ui_style.text_dim, .left, true);
    var mix_row = body.cutBottom(@min(body.h, 16));
    const pan_r = mix_row.cutLeft(HEADER_PAN_W);
    _ = mix_row.cutLeft(6);
    const vol_r = mix_row;
    var v_norm: f32 = std.math.clamp(master.volume() / 1.25, 0.0, 1.0);
    if (ctl.slider(ui, vol_r, "vol", &v_norm, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 5, .default = 1.0 / 1.25 })) master.setVolume(v_norm * 1.25);
    menu.tip(ui, vol_r, "Master volume");
    {
        var p: f32 = (master.pan() + 1) / 2;
        if (ctl.slider(ui, pan_r, "pan", &p, .{ .kind = .mini, .horizontal = true, .bipolar = true, .show_readout = false, .ticks = 3, .default = 0.5 })) master.setPan(p * 2 - 1);
        menu.tip(ui, pan_r, "Master balance (double-click to center)");
    }
    return ui.behaviorEx(ui.id("select"), Rect.xywh(r.x, r.y, r.w, 20), .{ .focusable = false }).pressed;
}

/// Track color as drawn (docs/06 §Palette): snapped to the track palette.
pub fn trackColor(col: c.rl.Color) ui_style.Color {
    return ui_style.nearestTrack(.{ .r = col.r, .g = col.g, .b = col.b });
}

fn clipNameRect(r: c.rl.Rectangle) c.rl.Rectangle {
    return pane.rect(r.x + 2, r.y + 1, @max(8, r.width - 4), 12);
}

fn createClipOnTrack(t: *Track, alloc: std.mem.Allocator, track_idx: usize, start_beat: f64, selected: *?ClipRef) void {
    if (t.isBus()) return; // a bus plays what's routed to it, not clips
    var buf: [clip_mod.MAX_NAME]u8 = undefined;
    const name_str = std.fmt.bufPrint(&buf, "Clip {d}", .{t.clips.items.len + 1}) catch "Clip";
    // A "one-bar clip" is one bar of the current meter (3 beats in 3/4,
    // 3.5 in 7/8), not a fixed 4 beats.
    const len_beats = cur_meter.barLenBeats(cur_meter.beatToBarPos(start_beat).bar);
    var new_clip = Clip.init(name_str, start_beat, len_beats);
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


// ── Ruler scrub ──────────────────────────────────────────────────────

fn handleLoopBounds(ruler: c.rl.Rectangle, timeline_x0: f32, transport: *Transport, edit_snap: snap_mod.Setting, m: pane.Mouse) void {
    if (!transport.loopEnabled()) return;
    const start_x = beatToX(timeline_x0, transport.loopStartBeats());
    const end_x = beatToX(timeline_x0, transport.loopEndBeats());
    const start_hit = pane.rect(start_x - 4, ruler.y, 8, ruler.height);
    const end_hit = pane.rect(end_x - 4, ruler.y, 8, ruler.height);

    if (loop_start_drag or loop_end_drag) {
        pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
        const key = if (loop_start_drag) LOOP_START_KEY else LOOP_END_KEY;
        if (!pane.isDraggingKey(key) or !m.left_down) {
            loop_start_drag = false;
            loop_end_drag = false;
            pane.cancelDrag();
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

    const over_start = pane.contains(start_hit, m.x, m.y);
    const over_end = pane.contains(end_hit, m.x, m.y);
    if (over_start or over_end) pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);
    if (!m.left_pressed or pane.hasActiveDrag()) return;
    if (over_start and pane.tryStartDrag(LOOP_START_KEY)) {
        loop_start_drag = true;
    } else if (over_end and pane.tryStartDrag(LOOP_END_KEY)) {
        loop_end_drag = true;
    }
}

fn handleRulerScrub(ruler: c.rl.Rectangle, timeline_x0: f32, transport: *Transport, m: pane.Mouse) void {
    if (ruler_drag) {
        if (!pane.isDraggingKey(RULER_KEY) or !m.left_down) {
            ruler_drag = false;
            pane.cancelDrag();
            return;
        }
        const beat = beatAtX(timeline_x0, m.x);
        transport.seekToBeats(beat);
        return;
    }

    if (!m.left_pressed) return;
    if (!pane.contains(ruler, m.x, m.y)) return;
    if (pane.hasActiveDrag()) return;

    if (!pane.tryStartDrag(RULER_KEY)) return;
    ruler_drag = true;
    const beat = beatAtX(timeline_x0, m.x);
    transport.seekToBeats(beat);
}

// ── Lazy vertical scrollbar ──────────────────────────────────────────

fn drawAndHandleScrollbar(ui: *Ui, area: c.rl.Rectangle, content_h: f32, m: pane.Mouse) void {
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
    const track = pane.rect(bar_x, area.y, scrollbarW(), area.height);
    ui.rect(bridge.fromRl(track), ui_style.chassis.alpha(@intFromFloat(alpha * 160)));

    const thumb_h = @max(16.0, (area.height / content_h) * area.height);
    const scroll_range = content_h - area.height;
    const track_range = area.height - thumb_h;
    const thumb_y = area.y + (scroll_y / scroll_range) * track_range;
    const thumb = pane.rect(bar_x + 1, thumb_y, scrollbarW() - 2, thumb_h);

    const hover_thumb = pane.contains(thumb, m.x, m.y);
    const thumb_color = if (sbv_drag or hover_thumb) ui_style.accent else ui_style.face_hi;
    ui.rect(bridge.fromRl(thumb), thumb_color.alpha(@intFromFloat(alpha * 255)));

    if (sbv_drag) {
        if (!pane.isDraggingKey(SBV_KEY) or !m.left_down) {
            sbv_drag = false;
            pane.cancelDrag();
            return;
        }
        const dy = m.y - sbv_drag_start_mouse_y;
        scroll_y = sbv_drag_start_scroll_y + dy * (scroll_range / track_range);
        last_scroll_time = now;
        return;
    }

    if (!m.left_pressed) return;
    if (pane.hasActiveDrag()) return;

    if (hover_thumb) {
        if (!pane.tryStartDrag(SBV_KEY)) return;
        sbv_drag = true;
        sbv_drag_start_mouse_y = m.y;
        sbv_drag_start_scroll_y = scroll_y;
    } else if (pane.contains(track, m.x, m.y)) {
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
    ui: *Ui,
    strip: c.rl.Rectangle,
    timeline_w: f32,
    tracks: []Track,
    content_beats: f64,
    transport: *const Transport,
    m: pane.Mouse,
) void {
    _ = timeline_w;
    _ = ui.well(bridge.fromRl(strip), ui_style.well);
    const inner = pane.rect(strip.x + 2, strip.y + 2, strip.width - 4, strip.height - 4);

    const cb: f32 = @max(@as(f32, @floatCast(content_beats)), 1.0);
    const px_per_beat_ov = inner.width / cb;

    // Each track gets a thin horizontal slice.
    const ord = order(tracks);
    const n_audio = ord.audio_count;
    if (n_audio > 0) {
        const lane_h = @max(1.0, inner.height / @as(f32, @floatFromInt(n_audio)));
        for (tracks, 0..) |*t, i| {
            if (t.isBus()) continue; // no clips
            const ly = inner.y + @as(f32, @floatFromInt(ord.number[i] - 1)) * lane_h;
            for (t.clips.items) |clip| {
                const cx = inner.x + @as(f32, @floatCast(clip.start_beat)) * px_per_beat_ov;
                const cw = @max(@as(f32, @floatCast(clip.length_beats)) * px_per_beat_ov, 1.0);
                const x0 = std.math.clamp(cx, inner.x, inner.x + inner.width);
                const x1 = std.math.clamp(cx + cw, inner.x, inner.x + inner.width);
                if (x1 > x0) ui.rect(frect(x0, ly, x1 - x0, @max(1.0, lane_h - 1)), uiColor(t.color));
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
    const vp = pane.rect(vp_x_cl, inner.y, vp_right_cl - vp_x_cl, inner.height);
    ui.rect(bridge.fromRl(vp), ui_style.accent.alpha(40));
    ui.bevel(bridge.fromRl(vp), ui_style.accent, ui_style.accent);

    // Playhead tick on the minimap.
    const beats_pos: f32 = @floatCast(transport.beats());
    const ph_x = inner.x + beats_pos * px_per_beat_ov;
    if (ph_x >= inner.x and ph_x <= inner.x + inner.width) ui.rect(frect(ph_x, inner.y, 1, inner.height), ui_style.accent);

    handleOverviewInput(inner, vp_w, px_per_beat_ov, cb, strip.width - 4, m);
}

fn handleOverviewInput(
    inner: c.rl.Rectangle,
    vp_w: f32,
    px_per_beat_ov: f32,
    content_beats: f32,
    viewport_w: f32,
    m: pane.Mouse,
) void {
    if (pane.contains(inner, m.x, m.y) and (m.wheel_x != 0 or m.wheel_y != 0)) {
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
        if (!pane.isDraggingKey(OVERVIEW_KEY) or !m.left_down) {
            ov_drag = false;
            pane.cancelDrag();
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
    if (!pane.contains(inner, m.x, m.y)) return;
    if (pane.hasActiveDrag()) return;

    const view_beat_l = scroll_x / px_per_beat;
    const vp_x = inner.x + view_beat_l * px_per_beat_ov;
    const on_vp = m.x >= vp_x and m.x <= vp_x + vp_w;

    if (!pane.tryStartDrag(OVERVIEW_KEY)) return;
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

// ── New-Ui drawing helpers (docs/06 §Working surfaces) ───────────────

fn ipx(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

fn frect(x: f32, y: f32, w: f32, h: f32) Rect {
    const x0 = ipx(x);
    const y0 = ipx(y);
    return Rect.xywh(x0, y0, ipx(x + w) - x0, ipx(y + h) - y0);
}

fn uiColor(col: c.rl.Color) ui_style.Color {
    return trackColor(col);
}

fn drawBeatTicks(ui: *Ui, ruler: c.rl.Rectangle, timeline_x: f32, timeline_w: f32, timeline_x0: f32, edit_snap: snap_mod.Setting) void {
    const right = timeline_x + timeline_w - 2;
    const ry = ipx(ruler.y);
    const rh = ipx(ruler.height);

    // Fine sub-grid (uniform snap guide), under the meter lines.
    const step = snap_mod.visualStep(edit_snap, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = beatToX(timeline_x0, beat);
        if (bx > right) break;
        if (bx >= timeline_x) ui.rect(Rect.xywh(ipx(bx), ry + rh - 4, 1, 2), ui_style.text_mute.alpha(120));
        beat += step;
    }

    // Meter-driven bar lines + numbers and per-bar beat ticks.
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
            const acc = seg.accentAt(k);
            const h: i32 = switch (acc) {
                .downbeat => 8,
                .group => 5,
                .weak => 3,
            };
            ui.rect(Rect.xywh(ipx(x), ry + rh - 1 - h, 1, h), if (acc == .weak) ui_style.text_mute else ui_style.text_dim);
        }
        if (bx >= timeline_x - 20) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{bar + 1}) catch "?";
            const w = ui.engraved(&ui.fonts.legend, ipx(bx) + 3, ry + 1, s, ui_style.text_dim);
            // Where the meter changes, label the new signature.
            if (seg.start_bar == bar) {
                var mbuf: [12]u8 = undefined;
                const ms = std.fmt.bufPrint(&mbuf, "{d}/{d}", .{ seg.numerator, seg.denominator }) catch "?";
                _ = ui.engraved(&ui.fonts.legend, ipx(bx) + 3 + w + 4, ry + 1, ms, ui_style.vfd);
            }
        }
        bar += 1;
    }
}

// ── Tempo changes on the ruler (docs/28 §Tempo map) ─────────────────

const TEMPO_DRAG_KEY: u64 = 0x5C0B_0001_7E70_0001;
/// The tempo labels drawn this frame, for dragging.
const TempoHit = struct { r: Rect, index: usize };
var tempo_hits: [64]TempoHit = undefined;
var tempo_hit_n: usize = 0;
var tempo_drag: ?usize = null;
var tempo_drag_y: f32 = 0;
var tempo_drag_bpm: f64 = 0;

/// "140", "→140" where a ramp arrives, tenths when it isn't whole.
fn tempoLabel(buf: []u8, m: *const tempo_mod.TempoMap, i: usize) []const u8 {
    const p = m.points[i];
    const arrow: []const u8 = if (i > 0 and m.points[i - 1].ramp) "\u{2192}" else "";
    const whole = @round(p.bpm) == p.bpm;
    return if (whole)
        std.fmt.bufPrint(buf, "{s}{d}", .{ arrow, @as(i32, @intFromFloat(p.bpm)) }) catch "?"
    else
        std.fmt.bufPrint(buf, "{s}{d:.1}", .{ arrow, p.bpm }) catch "?";
}

/// Each tempo change after the start: a hairline and its value, after
/// the bar number and meter when it falls on a downbeat. Drag a value up
/// or down to change it.
fn drawTempoMarks(ui: *Ui, ruler: c.rl.Rectangle, timeline_x: f32, timeline_w: f32, timeline_x0: f32) void {
    tempo_hit_n = 0;
    const m = cur_tempo;
    if (m.len < 2) return;
    const right = timeline_x + timeline_w - 2;
    const ry = ipx(ruler.y);
    const rh = ipx(ruler.height);
    const f = &ui.fonts.legend;
    for (m.points[1..m.len], 1..) |p, i| {
        const x = beatToX(timeline_x0, p.beat);
        if (x > right) break;
        if (x < timeline_x - 40) continue;
        // On a downbeat, step past the bar number and its meter label.
        var off: i32 = 3;
        const pos = cur_meter.beatToBarPos(p.beat);
        if (@abs(cur_meter.barStartBeat(pos.bar) - p.beat) < 1e-6) {
            var nb: [8]u8 = undefined;
            off += f.measure(std.fmt.bufPrint(&nb, "{d}", .{pos.bar + 1}) catch "") + 4;
            const seg = cur_meter.segmentForBar(pos.bar);
            if (seg.start_bar == pos.bar) {
                var mb: [12]u8 = undefined;
                off += f.measure(std.fmt.bufPrint(&mb, "{d}/{d}", .{ seg.numerator, seg.denominator }) catch "") + 4;
            }
        }
        const xi = ipx(x);
        const lit = tempo_drag != null and tempo_drag.? == i;
        const col = if (lit) ui_style.accent else ui_style.vfd;
        ui.rect(Rect.xywh(xi, ry, 1, rh), col.alpha(140));
        var buf: [16]u8 = undefined;
        const s = tempoLabel(&buf, m, i);
        const w = ui.engraved(f, xi + off, ry + 1, s, col) - (xi + off);
        if (tempo_hit_n < tempo_hits.len) {
            tempo_hits[tempo_hit_n] = .{ .r = Rect.xywh(xi + off - 2, ry, w + 4, rh), .index = i };
            tempo_hit_n += 1;
        }
    }
}

/// Drag a tempo value: 1 BPM per 2 px, tenths with shift.
/// (The press took main's undo snapshot.)
fn handleTempoDrag(transport: *Transport, m: pane.Mouse) void {
    if (tempo_drag) |i| {
        pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 3);
        if (!pane.isDraggingKey(TEMPO_DRAG_KEY) or !m.left_down) {
            tempo_drag = null;
            pane.cancelDrag();
            return;
        }
        const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
        const dy: f64 = @floatCast(tempo_drag_y - m.y);
        const v = if (shift) @round((tempo_drag_bpm + dy * 0.1) * 10) / 10 else @round(tempo_drag_bpm + dy * 0.5);
        if (i < transport.map().len and transport.map().points[i].bpm != tempo_mod.clampBpm(v)) transport.setBpmAt(i, @floatCast(v));
        return;
    }
    for (tempo_hits[0..tempo_hit_n]) |h| {
        if (!pane.contains(bridge.toRl(h.r), m.x, m.y)) continue;
        pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 2);
        if (!m.left_pressed or pane.hasActiveDrag()) return;
        if (!pane.tryStartDrag(TEMPO_DRAG_KEY)) return;
        tempo_drag = h.index;
        tempo_drag_y = m.y;
        tempo_drag_bpm = transport.map().points[h.index].bpm;
        return;
    }
}

// ── The section lane (docs/28 §Locators and sections) ───────────────

const MARKER_DRAG_KEY: u64 = 0x5C0B_0001_3A4B_0001;
const MARKER_MENU_KEY: u64 = 0x5C0B_0001_3A4B_0002;
const MarkerGrab = union(enum) { section: usize, locator: usize, end };
var marker_drag: ?MarkerGrab = null;
/// What the lane's menu was opened on.
var marker_menu_beat: f64 = 0;
var marker_menu_bar_beat: f64 = 0;
var marker_menu_section: ?usize = null;
var marker_menu_locator: ?usize = null;

/// The end of the last clip (0 when there are none): where the last
/// section ends without an END marker.
fn lastClipEnd(tracks: []Track) f64 {
    var e: f64 = 0;
    for (tracks) |t| for (t.clips.items) |clip| {
        e = @max(e, clip.start_beat + clip.length_beats);
    };
    return e;
}

fn sectionColor(sec: markers_mod.Section) ui_style.Color {
    return ui_style.track[sec.color % ui_style.track.len];
}

/// A locator's or END's flag: the hairline and the label beside it.
fn flagRect(ui: *Ui, lane: Rect, x: i32, name: []const u8) Rect {
    return Rect.xywh(x, lane.y, ui.fonts.legend.measure(name) + 6, lane.h);
}

fn drawMarkerLane(ui: *Ui, lane_rl: c.rl.Rectangle, timeline_x: f32, timeline_w: f32, timeline_x0: f32, mk: *const markers_mod.Markers, song_end: f64) void {
    const lane = bridge.fromRl(lane_rl);
    ui.rect(lane, ui_style.well);
    ui.rect(Rect.xywh(lane.x, lane.bottom() - 1, lane.w, 1), ui_style.edge);
    const right = timeline_x + timeline_w;
    const f = &ui.fonts.legend;
    // Sections: tabs in their colors, the name on the left.
    for (mk.sectionSlice(), 0..) |sec, i| {
        const x0 = beatToX(timeline_x0, sec.beat);
        const x1 = beatToX(timeline_x0, mk.sectionEnd(i, song_end));
        if (x1 < timeline_x or x0 > right) continue;
        const a = ipx(@max(x0, timeline_x - 2));
        const b = ipx(@min(x1, right + 2));
        const col = sectionColor(sec);
        const tab = Rect.xywh(a, lane.y + 1, @max(1, b - a - 1), lane.h - 2);
        ui.rect(tab, col.mix(ui_style.chassis, 0.35));
        ui.rect(Rect.xywh(tab.x, tab.y, tab.w, 1), col);
        ui.rect(Rect.xywh(ipx(x0), lane.y, 1, lane.h), col);
        var buf: [40]u8 = undefined;
        // The name stays in view while the tab starts off-screen.
        const lx = @max(ipx(x0), ipx(timeline_x)) + 4;
        _ = ui.text(f, lx, lane.y + 3, fitLabel(ui, &buf, sec.name.get(), b - lx - 2), ui_style.chassis);
    }
    // Past END the lane goes dark.
    if (mk.end) |e| {
        const x = beatToX(timeline_x0, e);
        if (x < right) {
            const xi = ipx(@max(x, timeline_x));
            ui.rect(Rect.xywh(xi, lane.y, ipx(right) - xi, lane.h - 1), ui_style.chassis.alpha(160));
            if (x >= timeline_x - 40) {
                ui.rect(Rect.xywh(ipx(x), lane.y, 1, lane.h), ui_style.text);
                const fr = flagRect(ui, lane, ipx(x), "END");
                ui.rect(Rect.xywh(fr.x + 1, fr.y + 1, fr.w - 1, fr.h - 2), ui_style.face_lo);
                _ = ui.text(f, fr.x + 4, lane.y + 3, "END", ui_style.text);
            }
        }
    }
    // Locators: a hairline and a dark flag with the name.
    for (mk.locatorSlice()) |l| {
        const x = beatToX(timeline_x0, l.beat);
        if (x > right or x < timeline_x - 120) continue;
        const fr = flagRect(ui, lane, ipx(x), l.name.get());
        ui.rect(Rect.xywh(fr.x + 1, fr.y + 2, fr.w - 1, fr.h - 4), ui_style.face_lo);
        ui.rect(Rect.xywh(ipx(x), lane.y, 1, lane.h), ui_style.text);
        _ = ui.text(f, fr.x + 4, lane.y + 3, l.name.get(), ui_style.text);
    }
}

/// What the pointer is over: a locator's flag, END, a section's start
/// edge, or a section's body.
const MarkerHit = union(enum) { none, locator: usize, end, section_edge: usize, section: usize };

fn markerHit(ui: *Ui, lane: Rect, timeline_x0: f32, mk: *const markers_mod.Markers, song_end: f64, mx: f32) MarkerHit {
    const x: i32 = @intFromFloat(mx);
    var k = mk.locator_n;
    while (k > 0) {
        k -= 1;
        const l = mk.locators[k];
        const fr = flagRect(ui, lane, ipx(beatToX(timeline_x0, l.beat)), l.name.get());
        if (x >= fr.x - 2 and x < fr.right()) return .{ .locator = k };
    }
    if (mk.end) |e| {
        const fr = flagRect(ui, lane, ipx(beatToX(timeline_x0, e)), "END");
        if (x >= fr.x - 2 and x < fr.right()) return .end;
    }
    for (mk.sectionSlice(), 0..) |sec, i| {
        const sx = ipx(beatToX(timeline_x0, sec.beat));
        if (i > 0 and x >= sx - 3 and x <= sx + 3) return .{ .section_edge = i };
        const ex = ipx(beatToX(timeline_x0, mk.sectionEnd(i, song_end)));
        if (x >= sx and x < ex) return .{ .section = i };
    }
    return .none;
}

/// The bar start nearest `beat`.
/// Where a section edge or END lands: the nearest downbeat, or with ⌥
/// the nearest line of the edit grid (a pickup, a section off the bar).
fn sectionBeat(raw: f64, edit_snap: snap_mod.Setting) f64 {
    return if (altBypassSnap()) snap_mod.snapNearest(edit_snap, raw, false) else nearestBarBeat(raw);
}

fn nearestBarBeat(beat: f64) f64 {
    const pos = cur_meter.beatToBarPos(@max(0, beat));
    const a = cur_meter.barStartBeat(pos.bar);
    const b = cur_meter.barStartBeat(pos.bar + 1);
    return if (beat - a < b - beat) a else b;
}

fn handleMarkerLane(ui: *Ui, lane_rl: c.rl.Rectangle, timeline_x0: f32, transport: *Transport, mk: *markers_mod.Markers, song_end: f64, edit_snap: snap_mod.Setting, m: pane.Mouse, result: *Result) void {
    const lane = bridge.fromRl(lane_rl);
    if (marker_drag) |g| {
        pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
        if (!pane.isDraggingKey(MARKER_DRAG_KEY) or !m.left_down) {
            marker_drag = null;
            pane.cancelDrag();
            return;
        }
        const raw = @max(0, beatAtX(timeline_x0, m.x));
        switch (g) {
            // Sections and END sit on downbeats; locators on the grid.
            .section => |i| _ = mk.moveSection(i, sectionBeat(raw, edit_snap)),
            .end => mk.end = @max(sectionBeat(raw, edit_snap), if (mk.section_n > 0) mk.sections[mk.section_n - 1].beat + 1 else 0),
            .locator => |i| marker_drag = .{ .locator = mk.moveLocator(i, snap_mod.snapNearest(edit_snap, raw, altBypassSnap())) },
        }
        return;
    }
    if (!pane.contains(lane_rl, m.x, m.y)) return;
    const hit = markerHit(ui, lane, timeline_x0, mk, song_end, m.x);
    switch (hit) {
        .locator, .end, .section_edge => pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2),
        .section => |i| menu.tip(ui, Rect.xywh(@intFromFloat(m.x), lane.y, 1, lane.h), mk.sections[i].name.get()),
        .none => {},
    }
    if (m.right_pressed and !pane.hasActiveDrag()) {
        const b = @max(0, beatAtX(timeline_x0, m.x));
        marker_menu_beat = snap_mod.snapNearest(edit_snap, b, altBypassSnap());
        // The bar it's in, or with ⌥ the grid line (off the bar).
        marker_menu_bar_beat = if (altBypassSnap()) snap_mod.snapNearest(edit_snap, b, false) else cur_meter.barStartBeat(cur_meter.beatToBarPos(b).bar);
        marker_menu_section = switch (hit) {
            .section, .section_edge => |i| i,
            else => mk.sectionAt(b, song_end),
        };
        marker_menu_locator = switch (hit) {
            .locator => |i| i,
            else => null,
        };
        menu.openAt(MARKER_MENU_KEY, ipx(m.x), ipx(m.y));
        return;
    }
    if (m.double_clicked) {
        switch (hit) {
            .locator => |i| result.marker_open = .{ .kind = .locator, .index = i },
            .section, .section_edge => |i| result.marker_open = .{ .kind = .section, .index = i },
            // The press took main's undo snapshot.
            .none => {
                const b = @max(0, beatAtX(timeline_x0, m.x));
                const at = if (altBypassSnap()) snap_mod.snapNearest(edit_snap, b, false) else cur_meter.barStartBeat(cur_meter.beatToBarPos(b).bar);
                applyMarkerEdit(mk, .{ .add_section = at });
            },
            .end => {},
        }
        return;
    }
    if (!m.left_pressed or pane.hasActiveDrag()) return;
    switch (hit) {
        .section => |i| transport.seekToBeats(mk.sections[i].beat),
        .none => {},
        .locator, .end, .section_edge => {
            if (!pane.tryStartDrag(MARKER_DRAG_KEY)) return;
            marker_drag = switch (hit) {
                .locator => |i| .{ .locator = i },
                .section_edge => |i| .{ .section = i },
                else => .end,
            };
        },
    }
}

const MK_ADD_SECTION: u32 = 1;
const MK_ADD_LOCATOR: u32 = 2;
const MK_EDIT_SECTION: u32 = 3;
const MK_LOOP_SECTION: u32 = 4;
const MK_REMOVE_SECTION: u32 = 5;
const MK_EDIT_LOCATOR: u32 = 6;
const MK_REMOVE_LOCATOR: u32 = 7;
const MK_SET_END: u32 = 8;
const MK_CLEAR_END: u32 = 9;
const MK_DUPLICATE: u32 = 10;
const MK_EARLIER: u32 = 11;
const MK_LATER: u32 = 12;
const MK_DELETE_ALL: u32 = 13;

fn markerMenuTick(transport: *Transport, mk: *markers_mod.Markers, song_end: f64, result: *Result) void {
    if (!menu.isOpen(MARKER_MENU_KEY)) return;
    const sec = marker_menu_section;
    const loc = marker_menu_locator;
    const items = [_]menu.Item{
        .{ .label = "Add section here", .id = MK_ADD_SECTION, .enabled = mk.section_n < markers_mod.MAX_SECTIONS },
        .{ .label = "Add locator here", .id = MK_ADD_LOCATOR, .enabled = mk.locator_n < markers_mod.MAX_LOCATORS },
        .{ .separator = true },
        .{ .label = "Edit section\u{2026}", .id = MK_EDIT_SECTION, .enabled = sec != null },
        .{ .label = "Loop section", .id = MK_LOOP_SECTION, .enabled = sec != null },
        .{ .label = "Duplicate section", .id = MK_DUPLICATE, .enabled = sec != null },
        .{ .label = "Move section earlier", .id = MK_EARLIER, .enabled = sec != null and sec.? > 0 },
        .{ .label = "Move section later", .id = MK_LATER, .enabled = sec != null and sec.? + 1 < mk.section_n },
        .{ .label = "Delete section and its content", .id = MK_DELETE_ALL, .enabled = sec != null },
        .{ .label = "Remove section marker", .id = MK_REMOVE_SECTION, .enabled = sec != null },
        .{ .separator = true },
        .{ .label = "Edit locator\u{2026}", .id = MK_EDIT_LOCATOR, .enabled = loc != null },
        .{ .label = "Remove locator", .id = MK_REMOVE_LOCATOR, .enabled = loc != null },
        .{ .separator = true },
        .{ .label = "Set end here", .id = MK_SET_END },
        .{ .label = "Remove end", .id = MK_CLEAR_END, .enabled = mk.end != null },
    };
    const id = menu.pick(MARKER_MENU_KEY, &items) orelse return;
    switch (id) {
        MK_ADD_SECTION => result.marker_edit = .{ .add_section = marker_menu_bar_beat },
        MK_ADD_LOCATOR => result.marker_edit = .{ .add_locator = marker_menu_beat },
        MK_EDIT_SECTION => result.marker_open = .{ .kind = .section, .index = sec.? },
        MK_LOOP_SECTION => transport.setLoopBeats(mk.sections[sec.?].beat, mk.sectionEnd(sec.?, song_end)),
        MK_REMOVE_SECTION => result.marker_edit = .{ .remove = .{ .kind = .section, .index = sec.? } },
        MK_EDIT_LOCATOR => result.marker_open = .{ .kind = .locator, .index = loc.? },
        MK_REMOVE_LOCATOR => result.marker_edit = .{ .remove = .{ .kind = .locator, .index = loc.? } },
        MK_DUPLICATE => result.section_op = .{ .kind = .duplicate, .index = sec.? },
        MK_EARLIER => result.section_op = .{ .kind = .earlier, .index = sec.? },
        MK_LATER => result.section_op = .{ .kind = .later, .index = sec.? },
        MK_DELETE_ALL => result.section_op = .{ .kind = .delete, .index = sec.? },
        MK_SET_END => result.marker_edit = .{ .set_end = @max(marker_menu_bar_beat, if (mk.section_n > 0) mk.sections[mk.section_n - 1].beat + 1 else 0) },
        MK_CLEAR_END => result.marker_edit = .clear_end,
        else => {},
    }
}

/// The strip opening the bus section: a flat bar across the timeline.
fn drawBusDivider(ui: *Ui, r_: c.rl.Rectangle) void {
    const r = bridge.fromRl(r_);
    ui.rect(r, ui_style.face.shade(-4));
    ui.rect(Rect.xywh(r.x, r.y, r.w, 1), ui_style.edge);
    ui.rect(Rect.xywh(r.x, r.bottom() - 1, r.w, 1), ui_style.chassis);
}

/// What feeds bus `ti`, written into its lane: "← KIT · SNARE (send)".
fn drawBusFeeds(ui: *Ui, r_: c.rl.Rectangle, tracks: []Track, ti: usize) void {
    var buf: [160]u8 = undefined;
    var w: usize = 0;
    const arrow = "\u{2190} ";
    for (tracks, 0..) |*u, j| {
        if (j == ti) continue;
        const out = u.output == ti;
        const send = if (u.sendTo(@intCast(ti))) |_| true else false;
        if (!out and !send) continue;
        const sep = if (w == 0) arrow else " \u{00B7} ";
        const piece = std.fmt.bufPrint(buf[w..], "{s}{s}{s}", .{ sep, u.name(), if (send and !out) " (send)" else "" }) catch break;
        w += piece.len;
    }
    const r = bridge.fromRl(r_);
    const text = if (w == 0) "nothing routed here: right-click a track's name, Output or Sends" else buf[0..w];
    ui.textIn(&ui.fonts.legend, Rect.xywh(r.x + 6, r.y + 4, r.w - 12, 12), text, ui_style.text_mute, .left, true);
}

/// A group's lane: every member's clips (nested ones too) as silhouettes
/// in their track colors under the feeds line, one thin band per member
/// in display order, folded or not.
fn drawGroupClips(ui: *Ui, lane: c.rl.Rectangle, tracks: []Track, ti: usize, timeline_x0: f32) void {
    const o = order(tracks);
    if (!o.is_group[ti]) return;
    var members: [routing.MAX_TRACKS]u8 = undefined;
    var n: usize = 0;
    // Display order, hidden rows included: walk the full order by number.
    for (1..o.audio_count + 1) |num| {
        for (tracks, 0..) |*u, j| {
            if (u.isBus() or o.number[j] != num or !o.within(j, ti)) continue;
            members[n] = @intCast(j);
            n += 1;
        }
    }
    if (n == 0) return;
    const top: i32 = ipx(lane.y) + 18;
    const avail: i32 = ipx(lane.height) - 18 - 3;
    const band = @max(2, @divFloor(avail, @as(i32, @intCast(n))));
    for (members[0..n], 0..) |j, k| {
        const u = &tracks[j];
        const col = trackColor(u.color);
        const y = top + @as(i32, @intCast(k)) * band;
        if (y + band > top + avail + 1) break;
        for (u.clips.items) |*clip| {
            const cr = clipRect(lane, clip.*, timeline_x0);
            if (cr.x + cr.width < lane.x or cr.x > lane.x + lane.width) continue;
            ui.rect(Rect.xywh(ipx(cr.x), y, @max(1, ipx(cr.width) - 1), @max(1, band - 1)), col.mix(ui_style.well, 0.35));
        }
    }
}

fn drawTimelineLane(ui: *Ui, r_: c.rl.Rectangle, t: Track, idx: usize, selected: bool, timeline_x0: f32, edit_snap: snap_mod.Setting) void {
    const r = bridge.fromRl(r_);
    _ = idx;
    // A bus has no clips: a flat dark well, bar lines kept for its lanes.
    ui.rect(r, if (t.isBus()) (if (selected) ui_style.well.shade(6) else ui_style.well) else if (selected) ui_style.pane_alt else ui_style.pane);
    const right = r_.x + r_.width - 1;

    // Fine sub-grid (uniform), then meter-driven beat and bar lines.
    const step = snap_mod.visualStep(edit_snap, px_per_beat);
    if (step * px_per_beat >= 6) {
        var beat: f64 = 0;
        while (true) {
            const bx = beatToX(timeline_x0, beat);
            if (bx > right) break;
            if (bx >= r_.x) ui.rect(Rect.xywh(ipx(bx), r.y, 1, r.h), ui_style.grid_sub);
            beat += step;
        }
    }
    const first_beat = @max(0.0, beatAtX(timeline_x0, r_.x));
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
            if (x < r_.x) continue;
            ui.rect(Rect.xywh(ipx(x), r.y, 1, r.h), if (seg.accentAt(k) == .weak) ui_style.grid_beat else ui_style.grid_bar);
        }
        bar += 1;
    }
    ui.rect(Rect.xywh(r.x, r.bottom() - 1, r.w, 1), ui_style.chassis);
}

/// The in-progress take on the armed track: a red region from the take's
/// start to the playhead with a live waveform from the recorder's peaks.
fn drawLiveRecordClip(ui: *Ui, lane: c.rl.Rectangle, rec: *const recorder_mod.Recorder, transport: *Transport, timeline_x0: f32) void {
    const start_b = transport.samplesToBeats(rec.startSampleValue());
    const end_b = transport.beats();
    if (end_b <= start_b) return;
    const x = timeline_x0 + @as(f32, @floatCast(start_b)) * px_per_beat - scroll_x;
    const w = @as(f32, @floatCast(end_b - start_b)) * px_per_beat;
    if (w < 1) return;
    const r = frect(x, lane.y + 2, w, lane.height - 4);
    ui.rect(r, ui_style.rec.mix(ui_style.pane, 0.7));
    ui.rect(Rect.xywh(r.x, r.y, r.w, 12), ui_style.rec);
    _ = ui.text(&ui.fonts.legend, r.x + 3, r.y, "REC", ui_style.chassis);
    ui.bevel(r, ui_style.rec, ui_style.rec);
    const peaks = rec.livePeaks();
    const body_top = r.y + 13;
    const body_h = r.h - 14;
    if (peaks.len > 0 and body_h > 2) {
        const mid = body_top + @divFloor(body_h, 2);
        var col: i32 = 0;
        while (col < r.w and col < 4096) : (col += 1) {
            const frac = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(r.w));
            const pi = @min(peaks.len - 1, @as(usize, @intFromFloat(frac * @as(f32, @floatFromInt(peaks.len)))));
            const hh: i32 = @intFromFloat(peaks[pi] * @as(f32, @floatFromInt(body_h)) * 0.5);
            ui.rect(Rect.xywh(r.x + col, mid - hh, 1, 2 * hh + 1), ui_style.rec.mix(ui_style.text, 0.3));
        }
    }
}

/// Clip: 1px edge in the darkened track color, a 12px name band in full
/// color with dark legend text, a tinted body with the note / waveform
/// preview; amber outline when selected.
/// `note_rate`: the track's tempo ratio; its notes are in its own beats.
/// A warped clip's waveform, span by span through its markers (docs/29
/// §Editing): each linear stretch of content beats draws its source
/// seconds.
fn drawWarpedWave(ui: *Ui, body: Rect, clip: Clip, waves: waveform.Waves, rate: f64, total: f64, col: ui_style.Color) void {
    const map = warp_mod.Map{ .m = clip.warp_markers.items };
    const len_sec = total / rate;
    const o = clip.audio.offset_beats;
    const bw: f64 = @floatFromInt(body.w);
    var buf: [64]warp_mod.Map.Span = undefined;
    for (map.spans(o, o + clip.length_beats, len_sec, &buf)) |sp| {
        const x0 = body.x + @as(i32, @intFromFloat(@round((sp.b0 - o) / clip.length_beats * bw)));
        const x1 = body.x + @as(i32, @intFromFloat(@round((sp.b1 - o) / clip.length_beats * bw)));
        if (x1 <= x0) continue;
        const r = Rect.xywh(x0, body.y, x1 - x0, body.h);
        if (clip.audio.reversed)
            surf.waveformLanes(ui, r, waves, (len_sec - sp.s1) * rate, (len_sec - sp.s0) * rate, col, true)
        else
            surf.waveformLanes(ui, r, waves, sp.s0 * rate, sp.s1 * rate, col, false);
    }
}

fn drawClip(ui: *Ui, r_: c.rl.Rectangle, clip: Clip, color_: c.rl.Color, selected: bool, editing_name: bool, pool: *const audio_pool_mod.AudioPool, note_rate: f64) void {
    const r = bridge.fromRl(r_);
    if (r.w < 1 or r.h < 1) return;
    // A muted clip loses its track color.
    const color = if (clip.muted) uiColor(color_).mix(ui_style.face_lo, 0.75) else uiColor(color_);
    ui.rect(r, color.mix(ui_style.chassis, 0.6));
    const inner = r.inset(1);
    var body = inner;
    const band = body.cutTop(12);
    ui.rect(band, color);
    ui.rect(body, color.mix(ui_style.pane, 0.72));
    if (!editing_name) {
        var buf: [clip_mod.MAX_NAME + 4]u8 = undefined;
        ui.clip(band);
        _ = ui.text(&ui.fonts.legend, band.x + 2, band.y, fitLabel(ui, &buf, clip.name(), band.w - 4), ui_style.chassis);
        ui.unclip();
    }
    const preview = color.mix(ui_style.text, 0.35);

    if (clip.isAudio()) {
        if (body.h > 2 and body.w > 1) {
            if (pool.get(clip.audio.source)) |src| {
                if (src.cache.sample_count > 0) {
                    const rate = src.sample.sample_rate;
                    const total: f64 = @floatFromInt(src.cache.sample_count);
                    if (clip.audio.warp and warp_mod.valid(clip.warp_markers.items)) {
                        drawWarpedWave(ui, body, clip, src.waves(), rate, total, preview);
                    } else {
                        const win_start = clip.audio.start_sec * rate;
                        const want = clip.audio.dur_sec * rate;
                        const win_end = @min(total, win_start + want);
                        // A window past the source's end draws only what
                        // the source has, not stretched across the clip.
                        var wr = body;
                        if (want > 0 and win_end - win_start < want)
                            wr.w = @intFromFloat(@as(f64, @floatFromInt(body.w)) * @max(0.0, win_end - win_start) / want);
                        surf.waveformLanes(ui, wr, src.waves(), win_start, win_end, preview, clip.audio.reversed);
                    }
                }
            }
            if (clip.audio.warp) {
                const lbl = clip.audio.mode.label();
                const bw: i32 = @as(i32, @intCast(lbl.len)) * 6 + 4;
                if (band.w > bw + 40) {
                    const br = Rect.xywh(band.right() - bw - 1, band.y + 1, bw, band.h - 2);
                    ui.rect(br, ui_style.chassis);
                    ui.textIn(&ui.fonts.legend, br, lbl, color, .center, true);
                }
            }
            // Fade wedges + grab handles in the top corners (hit zones
            // match the draw()-side hit-test).
            const dur = clip.audio.dur_sec;
            if (dur > 0) {
                const in_frac: f32 = @floatCast(std.math.clamp(clip.audio.fade_in_sec / dur, 0, 1));
                const out_frac: f32 = @floatCast(std.math.clamp(clip.audio.fade_out_sec / dur, 0, 1));
                const in_x = r.x + @as(i32, @intFromFloat(in_frac * @as(f32, @floatFromInt(r.w))));
                const out_x = r.right() - @as(i32, @intFromFloat(out_frac * @as(f32, @floatFromInt(r.w))));
                if (clip.audio.fade_in_sec > 0) shadeClipFade(ui, body.x, in_x, body.y, body.h, true);
                if (clip.audio.fade_out_sec > 0) shadeClipFade(ui, out_x, body.right(), body.y, body.h, false);
                ui.rect(Rect.xywh(in_x - 3, r.y, 6, 4), ui_style.chassis);
                ui.rect(Rect.xywh(out_x - 3, r.y, 6, 4), ui_style.chassis);
            }
        }
    } else if (clip.notes.items.len > 0 and body.h > 2) {
        // Note ticks over C2..C6.
        const pitch_lo: f32 = 36;
        const pitch_hi: f32 = 84;
        const bh: f32 = @floatFromInt(body.h);
        for (clip.notes.items) |note| {
            const nx = r_.x + @as(f32, @floatCast(note.start_beat / note_rate)) * px_per_beat;
            const nw = @max(@as(f32, @floatCast(note.length_beats / note_rate)) * px_per_beat, 1);
            const x0 = @max(ipx(nx), body.x);
            const x1 = @min(ipx(nx + nw), body.right());
            if (x1 <= x0) continue;
            const pn = std.math.clamp((@as(f32, @floatFromInt(note.pitch)) - pitch_lo) / (pitch_hi - pitch_lo), 0, 1);
            const ny = body.y + @as(i32, @intFromFloat((1 - pn) * (bh - 2)));
            ui.rect(Rect.xywh(x0, ny, @max(1, x1 - x0 - 1), 1), preview);
        }
    }
    // A stale bounce (docs/27 §Provenance): a notch cut in the band's
    // right corner, until it's re-bounced.
    if (clip.recipe) |rc| if (rc.stale and band.w > 12) {
        var k: i32 = 0;
        while (k < 6) : (k += 1) ui.rect(Rect.xywh(band.right() - 6 + k, band.y, 6 - k, 1), ui_style.led_yellow);
        var j: i32 = 1;
        while (j < 6) : (j += 1) ui.rect(Rect.xywh(band.right() - 6 + j, band.y + j, 6 - j, 1), ui_style.led_yellow);
    };
    if (selected) ui.bevel(r, ui_style.accent, ui_style.accent);
}

/// An audio clip's attenuated fade wedge, as per-column bars.
fn shadeClipFade(ui: *Ui, x0: i32, x1: i32, top: i32, h: i32, fade_in: bool) void {
    const span = x1 - x0;
    if (span < 1 or h < 1) return;
    var x = x0;
    while (x < x1) : (x += 1) {
        const p = @as(f32, @floatFromInt(x - x0)) / @as(f32, @floatFromInt(span));
        const atten: f32 = if (fade_in) 1 - p else p;
        const hh: i32 = @intFromFloat(@as(f32, @floatFromInt(h)) * atten);
        if (hh >= 1) ui.rect(Rect.xywh(x, top, 1, hh), ui_style.chassis.alpha(128));
    }
}

/// `name` truncated with "…" to fit `max_w` in the legend face.
fn fitLabel(ui: *Ui, buf: []u8, name: []const u8, max_w: i32) []const u8 {
    const f = &ui.fonts.legend;
    if (max_w <= 0) return "";
    if (f.measure(name) <= max_w) return name;
    const ell = "\u{2026}";
    var n = @min(name.len, buf.len - ell.len);
    while (n > 0) : (n -= 1) {
        @memcpy(buf[0..n], name[0..n]);
        @memcpy(buf[n..][0..ell.len], ell);
        const s = buf[0 .. n + ell.len];
        if (f.measure(s) <= max_w) return s;
    }
    return "";
}

/// Loop bracket along the ruler's bottom edge (the loop lives in the ruler,
/// not across the lanes; docs/06 §Working surfaces).
fn drawLoopRegion(ui: *Ui, r_: c.rl.Rectangle, timeline_x0: f32, transport: *const Transport) void {
    if (!transport.loopEnabled()) return;
    const s = transport.loopStartBeats();
    const e = transport.loopEndBeats();
    if (e <= s) return;
    const r = bridge.fromRl(r_);
    const x0 = ipx(beatToX(timeline_x0, s));
    const x1 = ipx(beatToX(timeline_x0, e));
    const lx0 = geom.fit(x0, r.x, r.right());
    const lx1 = geom.fit(x1, r.x, r.right());
    const band = Rect.xywh(lx0, r.bottom() - 6, lx1 - lx0, 5);
    if (band.w > 0) {
        ui.rect(band, ui_style.accent.alpha(70));
        ui.rect(Rect.xywh(band.x, band.y, band.w, 1), ui_style.accent);
    }
    if (x0 >= r.x and x0 < r.right()) ui.rect(Rect.xywh(x0, r.bottom() - 6, 1, 5), ui_style.accent);
    if (x1 >= r.x and x1 < r.right()) ui.rect(Rect.xywh(x1 - 1, r.bottom() - 6, 1, 5), ui_style.accent);
}

fn drawBoxSelectOverlay(ui: *Ui, timeline_x: f32, timeline_w: f32, lanes_top: f32, lanes_bottom: f32, m: pane.Mouse) void {
    if (!box_active) return;
    if (@abs(m.x - box_start_x) < BOX_MIN_DRAG and @abs(m.y - box_start_y) < BOX_MIN_DRAG) return;
    const rr = normalizedRect(box_start_x, box_start_y, m.x, m.y);
    const clipped = intersectRect(rr, pane.rect(timeline_x, lanes_top, timeline_w, lanes_bottom - lanes_top)) orelse return;
    const b = bridge.fromRl(clipped);
    ui.rect(b, ui_style.accent.alpha(40));
    ui.bevel(b, ui_style.accent, ui_style.accent);
}


test "splitting a reversed audio clip: the left part plays the window's tail" {
    const alloc = std.testing.allocator;
    var tracks = [_]Track{try Track.init(alloc, "t", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, track_mod.testMachine())};
    defer tracks[0].deinit(alloc);
    var clip = Clip.initAudio("rev", 0, 4, 0);
    clip.audio.start_sec = 1;
    clip.audio.dur_sec = 2; // 4 beats at 120 bpm
    clip.audio.reversed = true;
    clip.selected = true;
    try tracks[0].addClip(alloc, clip);
    var focused: ?ClipRef = null;
    try std.testing.expect(splitSelectedClipsAt(tracks[0..], alloc, &focused, 1, &tempo_mod.TempoMap.constant(120)));
    const left = tracks[0].clips.items[0].audio;
    const right = tracks[0].clips.items[1].audio;
    // left: 1 beat = 0.5 s, the window's last half second
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), left.start_sec, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), left.dur_sec, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), right.start_sec, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), right.dur_sec, 1e-9);
    try std.testing.expect(left.reversed and right.reversed);
}

test "ruler tempo edits: add at the tempo in effect, ramp the segment, remove" {
    var transport = Transport{};
    transport.setBpm(100);
    applyTempoEdit(&transport, .{ .kind = .add, .beat = 16 });
    try std.testing.expectEqual(@as(usize, 2), transport.map().len);
    try std.testing.expectEqual(@as(f64, 100), transport.map().points[1].bpm);
    transport.setBpmAt(1, 140);
    applyTempoEdit(&transport, .{ .kind = .toggle_ramp, .beat = 4 });
    try std.testing.expect(transport.map().points[0].ramp);
    try std.testing.expectApproxEqAbs(@as(f64, 120), transport.map().bpmAt(8), 1e-9);
    applyTempoEdit(&transport, .{ .kind = .remove, .beat = 16 });
    try std.testing.expectEqual(@as(usize, 1), transport.map().len);
    // The first point stays.
    applyTempoEdit(&transport, .{ .kind = .remove, .beat = 0 });
    try std.testing.expectEqual(@as(usize, 1), transport.map().len);
}
