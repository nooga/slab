//! Piano-roll clip editor.
//!
//! Modes:
//!   • select (default) — click a note to select, shift-click to
//!     toggle, drag empty area to box-select, drag a note to move all
//!     selected notes, drag a note's right edge to resize.
//!   • draw (pencil)    — click-drag on empty grid creates a note;
//!     click on existing note deletes it.
//!
//! Focused shortcuts:
//!   • Delete / Backspace → remove selected notes
//!   • Wheel              → horizontal zoom around mouse
//!   • Shift+Wheel        → horizontal scroll
//!
//! Visuals:
//!   • Clip-end line in red + a dimmed overlay past the clip length
//!   • Selected notes get a bright border
//!   • Box-select drag shows a rubber band

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const snap_mod = @import("snap.zig");
const track_mod = @import("../track.zig");
const clip_mod = @import("../clip.zig");
const Clip = clip_mod.Clip;
const Note = clip_mod.Note;
const ClipRef = clip_mod.ClipRef;

// ── Grid constants ───────────────────────────────────────────────────

const KEY_LO: u8 = 36; // C2 (bottom row)
const KEY_HI: u8 = 84; // C6 (top row; inclusive)
fn keyboardW() f32 {
    return theme.size(28);
}
fn rulerH() f32 {
    return theme.size(14);
}
const MIN_NOTE_BEATS: f64 = 0.25;
const DEFAULT_NOTE_BEATS: f64 = 0.5;
fn resizeEdgeW() f32 {
    return theme.fine(4);
}
const BOX_MIN_DRAG: f32 = 3;
const PX_PER_BEAT_MAX: f32 = 96;
const ROW_H_MIN: f32 = 6;
const ROW_H_MAX: f32 = 24;

// ── Module state ─────────────────────────────────────────────────────

const Mode = enum { select, draw };

var mode: Mode = .draw;
var px_per_beat: f32 = 24;
var row_h: f32 = 10;
var scroll_x: f32 = 0;
var scroll_y: f32 = 0;
var initialized_scroll: bool = false;
var last_clip_key: u64 = 0; // to detect clip switch → clear selection

fn overviewH() f32 {
    return theme.size(22);
}
fn velocityLaneH() f32 {
    return theme.size(50);
}

// Draw-mode in-progress note.
var draw_active: bool = false;
var draw_start_beat: f64 = 0;
var draw_current_beat: f64 = 0;
var draw_pitch: u8 = 60;
var draw_start_x: f32 = 0;

// Box select.
var box_active: bool = false;
var box_start_x: f32 = 0;
var box_start_y: f32 = 0;

// Move drag.
const MoveSnap = struct { idx: u32, start_beat: f64, pitch: u8 };
var move_active: bool = false;
var move_start_mouse_x: f32 = 0;
var move_start_mouse_y: f32 = 0;
var move_snaps: std.ArrayList(MoveSnap) = .empty;

// Resize drag (right edge).
const ResizeSnap = struct { idx: u32, length: f64 };
var resize_active: bool = false;
var resize_start_mouse_x: f32 = 0;
var resize_snaps: std.ArrayList(ResizeSnap) = .empty;

// Velocity lane drag.
const VelocityDragMode = enum { none, one, selected };
var velocity_active: bool = false;
var velocity_drag_idx: usize = 0;
var velocity_drag_mode: VelocityDragMode = .none;

// Overview-strip drag.
var overview_drag: bool = false;
var overview_drag_offset: f32 = 0; // mouse→viewport-left offset at drag start

// Scroll activity — scrollbar fades in on recent scroll or cursor
// near the right edge, fades out ~1.5 s after activity ends.
var last_scroll_time: f64 = 0;
fn scrollbarW() f32 {
    return theme.fine(6);
}
const SCROLLBAR_HOVER_RANGE: f32 = 28;
const SCROLLBAR_FADE_VISIBLE: f64 = 0.9;
const SCROLLBAR_FADE_LINGER: f64 = 0.6;

// Vertical-scrollbar drag.
var sb_drag: bool = false;
var sb_drag_start_mouse_y: f32 = 0;
var sb_drag_start_scroll_y: f32 = 0;

// Drag keys so we can coexist with other module drags.
const BOX_KEY: u64 = 0xB0B0_0001_5ADB_E1EC;
const MOVE_KEY: u64 = 0x507E_0001_AAAA_BBBB;
const RESIZE_KEY: u64 = 0xBEEF_1000_0000_0001;
const DRAW_KEY: u64 = 0xD00D_2222_3333_4444;
const VELOCITY_KEY: u64 = 0x7110_C17E_AAAA_0001;
const OVERVIEW_KEY: u64 = 0x00FE_7_AAAA_BBBB;
const SB_KEY: u64 = 0x5CB0_1111_2222_3333;
const PR_CONTEXT_KEY: u64 = 0xC077_7E17_BBBB_0001;

pub fn deinit(alloc: std.mem.Allocator) void {
    move_snaps.deinit(alloc);
    resize_snaps.deinit(alloc);
}

pub fn cancelInteractions() bool {
    const had_active = draw_active or box_active or move_active or resize_active or velocity_active or overview_drag or sb_drag;
    cancelAllDrags();
    return had_active;
}

pub const Result = struct {
    minimize: bool = false,
    close: bool = false,
    audition_pitch: ?u8 = null,
    command: widgets.EditCommand = .none,
    command_beat: ?f64 = null,
    command_pitch: ?u8 = null,
    rename_rect: ?c.rl.Rectangle = null,
};

const ContextTarget = struct {
    beat: f64 = 0,
    pitch: ?u8 = null,
};

var context_target: ContextTarget = .{};

pub fn deleteSelectedNotes(tracks: []track_mod.Track, selected: ?ClipRef) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    if (resolved.clip.selectedCount() == 0) return false;
    resolved.clip.removeSelected();
    return true;
}

pub fn clearSelection(tracks: []track_mod.Track, selected: ?ClipRef) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    const changed = resolved.clip.selectedCount() > 0;
    resolved.clip.deselectAll();
    return changed;
}

pub fn selectAllNotes(tracks: []track_mod.Track, selected: ?ClipRef) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    var changed = false;
    for (resolved.clip.notes.items) |*note| {
        if (!note.selected) changed = true;
        note.selected = true;
    }
    return changed;
}

pub fn copySelectedNotes(tracks: []track_mod.Track, selected: ?ClipRef, alloc: std.mem.Allocator, out: *std.ArrayList(Note)) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    out.clearRetainingCapacity();
    var min_start: f64 = std.math.inf(f64);
    for (resolved.clip.notes.items) |note| {
        if (!note.selected) continue;
        min_start = @min(min_start, note.start_beat);
    }
    if (min_start == std.math.inf(f64)) return false;
    for (resolved.clip.notes.items) |note| {
        if (!note.selected) continue;
        var copied = note;
        copied.start_beat -= min_start;
        copied.selected = true;
        out.append(alloc, copied) catch |err| {
            std.log.err("copy note failed: {s}", .{@errorName(err)});
        };
    }
    return out.items.len > 0;
}

pub fn pasteNotes(tracks: []track_mod.Track, selected: ?ClipRef, alloc: std.mem.Allocator, notes: []const Note, arrangement_beat: f64, target_pitch: ?u8, edit_snap: snap_mod.Setting) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    if (notes.len == 0) return false;
    const local_target = snap_mod.snapPositive(edit_snap, @max(0.0, arrangement_beat - resolved.clip.start_beat), false);
    const pitch_delta: i32 = if (target_pitch) |pitch| blk: {
        var min_pitch: u8 = notes[0].pitch;
        for (notes) |note| min_pitch = @min(min_pitch, note.pitch);
        break :blk @as(i32, @intCast(pitch)) - @as(i32, @intCast(min_pitch));
    } else 0;
    resolved.clip.deselectAll();
    var changed = false;
    for (notes) |src| {
        var note = src;
        note.start_beat = local_target + src.start_beat;
        note.pitch = @intCast(std.math.clamp(@as(i32, @intCast(src.pitch)) + pitch_delta, 0, 127));
        note.selected = true;
        resolved.clip.addNote(alloc, note) catch |err| {
            std.log.err("paste note failed: {s}", .{@errorName(err)});
            continue;
        };
        changed = true;
    }
    return changed;
}

pub fn nudgeSelectedNotes(tracks: []track_mod.Track, selected: ?ClipRef, beat_delta: f64, pitch_delta: i32, edit_snap: snap_mod.Setting) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    var changed = false;
    for (resolved.clip.notes.items) |*note| {
        if (!note.selected) continue;
        const next_start = snap_mod.snapPositive(edit_snap, note.start_beat + beat_delta, false);
        const next_pitch_i = std.math.clamp(@as(i32, @intCast(note.pitch)) + pitch_delta, 0, 127);
        const next_pitch: u8 = @intCast(next_pitch_i);
        if (next_start != note.start_beat or next_pitch != note.pitch) changed = true;
        note.start_beat = next_start;
        note.pitch = next_pitch;
    }
    return changed;
}

pub fn duplicateSelectedNotes(tracks: []track_mod.Track, selected: ?ClipRef, alloc: std.mem.Allocator, edit_snap: snap_mod.Setting) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    if (resolved.clip.selectedCount() == 0) return false;

    var first_start: f64 = std.math.inf(f64);
    var last_end: f64 = 0;
    for (resolved.clip.notes.items) |note| {
        if (!note.selected) continue;
        first_start = @min(first_start, note.start_beat);
        last_end = @max(last_end, note.start_beat + note.length_beats);
    }
    const raw_offset = @max(last_end - first_start, MIN_NOTE_BEATS);
    const snapped_offset = snap_mod.snapNearest(edit_snap, raw_offset, false);
    const offset = if (snapped_offset >= minNoteBeats(edit_snap)) snapped_offset else raw_offset;
    const original_len = resolved.clip.notes.items.len;

    var i: usize = 0;
    while (i < original_len) : (i += 1) {
        if (!resolved.clip.notes.items[i].selected) continue;
        var note = resolved.clip.notes.items[i];
        resolved.clip.notes.items[i].selected = false;
        note.start_beat += offset;
        note.selected = true;
        resolved.clip.addNote(alloc, note) catch |err| {
            std.log.err("duplicate note failed: {s}", .{@errorName(err)});
        };
    }
    return true;
}

pub fn quantizeSelectedNotes(tracks: []track_mod.Track, selected: ?ClipRef, edit_snap: snap_mod.Setting) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    var changed = false;
    for (resolved.clip.notes.items) |*note| {
        if (!note.selected) continue;
        const next_start = snap_mod.snapPositive(edit_snap, note.start_beat, false);
        const next_len = @max(minNoteBeats(edit_snap), snap_mod.snapNearest(edit_snap, note.length_beats, false));
        if (next_start != note.start_beat or next_len != note.length_beats) changed = true;
        note.start_beat = next_start;
        note.length_beats = next_len;
    }
    return changed;
}

pub fn draw(
    r: c.rl.Rectangle,
    tracks: []track_mod.Track,
    alloc: std.mem.Allocator,
    selected: ?ClipRef,
    edit_snap: snap_mod.Setting,
    can_paste_notes: bool,
    m: widgets.Mouse,
) Result {
    c.rl.DrawRectangleRec(r, theme.pane_bg);

    const header = widgets.rect(r.x, r.y, r.width, theme.paneHeaderH());
    const res = widgets.paneHeader(header, .{
        .title = clipEditorTitle(tracks, selected),
        .has_close = true,
        .left_tool = .pencil,
        .left_tool_active = mode == .draw,
    }, m);
    if (res.left_tool) {
        mode = if (mode == .draw) .select else .draw;
        cancelAllDrags();
    }

    const body = widgets.rect(r.x + 1, r.y + theme.paneHeaderH() + 1, r.width - 2, r.height - theme.paneHeaderH() - 2);

    const clip_opt = resolveClip(tracks, selected);
    if (clip_opt == null) {
        widgets.drawLabelF("no clip selected", body.x + 6, body.y + 6, theme.fsBody(), theme.text_mute);
        return .{ .minimize = res.minimize, .close = res.close };
    }
    const resolved = clip_opt.?;

    maybeResetOnClipChange(selected, resolved.clip);
    const pres = drawPianoRoll(body, resolved.clip, resolved.color, alloc, edit_snap, can_paste_notes, m);

    return .{
        .minimize = res.minimize,
        .close = res.close,
        .audition_pitch = pres.audition_pitch,
        .command = pres.command,
        .command_beat = pres.command_beat,
        .command_pitch = pres.command_pitch,
        .rename_rect = if (selected != null) res.title_rect else null,
    };
}

// ── Resolution + reset on switch ─────────────────────────────────────

const Resolved = struct {
    clip: *Clip,
    color: c.rl.Color,
};

fn resolveClip(tracks: []track_mod.Track, selected: ?ClipRef) ?Resolved {
    const s = selected orelse return null;
    if (s.track >= tracks.len) return null;
    const t = &tracks[s.track];
    if (s.clip >= t.clips.items.len) return null;
    return .{ .clip = &t.clips.items[s.clip], .color = t.color };
}

fn maybeResetOnClipChange(selected: ?ClipRef, clip: *Clip) void {
    const key = if (selected) |s| widgets.keyFromIds(0xC11EC011, s.track, s.clip) else 0;
    if (key != last_clip_key) {
        last_clip_key = key;
        clip.deselectAll();
        initialized_scroll = false;
        // Cancel any in-progress drag state.
        cancelAllDrags();
    }
}

fn cancelAllDrags() void {
    draw_active = false;
    box_active = false;
    move_active = false;
    resize_active = false;
    velocity_active = false;
    velocity_drag_mode = .none;
    overview_drag = false;
    sb_drag = false;
    widgets.cancelDrag();
}

// ── Title ─────────────────────────────────────────────────────────────

fn clipEditorTitle(tracks: []track_mod.Track, selected: ?ClipRef) [*:0]const u8 {
    const S = struct {
        var buf: [96:0]u8 = undefined;
    };
    const resolved = resolveClip(tracks, selected) orelse return "CLIP";
    const cname = resolved.clip.name();
    const n = @min(cname.len, 80);
    const prefix = "CLIP — ";
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) S.buf[i] = prefix[i];
    var j: usize = 0;
    while (j < n) : ({
        i += 1;
        j += 1;
    }) S.buf[i] = cname[j];
    S.buf[i] = 0;
    return @ptrCast(&S.buf[0]);
}

// ── Piano roll draw + input ──────────────────────────────────────────

const PianoRollResult = struct {
    audition_pitch: ?u8 = null,
    command: widgets.EditCommand = .none,
    command_beat: ?f64 = null,
    command_pitch: ?u8 = null,
};

fn drawPianoRoll(
    r: c.rl.Rectangle,
    clip: *Clip,
    track_color: c.rl.Color,
    alloc: std.mem.Allocator,
    edit_snap: snap_mod.Setting,
    can_paste_notes: bool,
    m: widgets.Mouse,
) PianoRollResult {
    // Overview strip, ruler, keyboard, grid — stacked vertically.
    const overview_rect = widgets.rect(r.x, r.y, r.width, overviewH());
    const ruler_rect = widgets.rect(r.x, r.y + overviewH(), r.width, rulerH());
    widgets.bevelSunken(ruler_rect, theme.pane_alt, theme.slab_hi, theme.slab_lo);

    const grid_top = ruler_rect.y + rulerH();
    const vel_h = @min(velocityLaneH(), @max(theme.size(28), r.height * 0.22));
    const grid_h = @max(theme.size(48), r.height - overviewH() - rulerH() - vel_h - 1);
    const kbd_rect = widgets.rect(r.x, grid_top, keyboardW(), grid_h);
    const grid_rect = widgets.rect(r.x + keyboardW(), grid_top, r.width - keyboardW(), grid_h);
    const vel_rect = widgets.rect(grid_rect.x, grid_rect.y + grid_rect.height + 1, grid_rect.width, vel_h);

    initScrollIfNeeded(grid_rect, clip.*);
    handleWheel(grid_rect, clip.*, m);
    clampScroll(grid_rect, clip.*);

    drawRuler(ruler_rect, grid_rect, edit_snap);
    drawKeyboard(kbd_rect);

    // Everything that scrolls must be clipped to the grid viewport —
    // otherwise notes and draw-previews bleed into the keyboard and
    // the adjacent panes.
    c.rl.BeginScissorMode(
        @intFromFloat(grid_rect.x),
        @intFromFloat(grid_rect.y),
        @intFromFloat(grid_rect.width),
        @intFromFloat(grid_rect.height),
    );
    drawGrid(grid_rect, edit_snap);
    drawExistingNotes(grid_rect, clip.*, track_color);
    drawClipEndOverlay(grid_rect, clip.*);

    if (draw_active) {
        const start = @min(draw_start_beat, draw_current_beat);
        const end = @max(draw_start_beat, draw_current_beat);
        const len = @max(end - start, minNoteBeats(edit_snap));
        const nr = noteRect(grid_rect, .{
            .pitch = draw_pitch,
            .start_beat = start,
            .length_beats = len,
        });
        c.rl.DrawRectangleRec(nr, lighten(track_color, 1.25));
        c.rl.DrawRectangleLinesEx(nr, 1, theme.text_fg);
    }
    if (box_active) {
        drawBoxSelect(grid_rect, m);
    }
    c.rl.EndScissorMode();

    // Lazy vertical scrollbar (after scissor so it overlays grid).
    drawAndHandleScrollbar(grid_rect, m);
    const velocity_consumed = handleVelocityLane(vel_rect, grid_rect, clip, m);
    drawVelocityLane(vel_rect, grid_rect, clip.*, track_color);

    // Overview is drawn AFTER the scissor block so its contents and
    // viewport-window outline aren't clipped.
    drawOverview(overview_rect, grid_rect, clip.*, track_color, m);

    var result = PianoRollResult{ .audition_pitch = if (velocity_consumed) null else handleInput(grid_rect, clip, alloc, edit_snap, m) };
    _ = widgets.openContextMenu(PR_CONTEXT_KEY, grid_rect, m);
    const has_selection = clip.selectedCount() > 0;
    const has_notes = clip.notes.items.len > 0;
    const pr_context_items = [_]widgets.MenuItem{
        .{ .label = "Copy", .command = .copy, .enabled = has_selection },
        .{ .label = "Cut", .command = .cut, .enabled = has_selection },
        .{ .label = "Paste", .command = .paste, .enabled = can_paste_notes },
        .{ .separator = true },
        .{ .label = "Duplicate", .command = .duplicate, .enabled = has_selection },
        .{ .label = "Quantize", .command = .quantize, .enabled = has_selection },
        .{ .label = "Delete", .command = .delete, .enabled = has_selection },
        .{ .separator = true },
        .{ .label = "Rename clip", .command = .rename },
        .{ .label = "Select all", .command = .select_all, .enabled = has_notes },
        .{ .label = "Clear selection", .command = .clear_selection, .enabled = has_selection },
    };
    result.command = widgets.contextMenu(PR_CONTEXT_KEY, &pr_context_items, m);
    if (result.command != .none) {
        result.command_beat = context_target.beat + clip.start_beat;
        result.command_pitch = context_target.pitch;
    }
    return result;
}

fn initScrollIfNeeded(grid: c.rl.Rectangle, clip: Clip) void {
    if (initialized_scroll) return;
    const rows = @as(f32, @floatFromInt(@as(u32, KEY_HI) - @as(u32, KEY_LO) + 1));
    px_per_beat = minPxPerBeat(grid, clip);

    var lo_pitch: u8 = 60;
    var hi_pitch: u8 = 60;
    if (clip.notes.items.len > 0) {
        lo_pitch = clip.notes.items[0].pitch;
        hi_pitch = clip.notes.items[0].pitch;
        for (clip.notes.items) |note| {
            if (note.pitch < lo_pitch) lo_pitch = note.pitch;
            if (note.pitch > hi_pitch) hi_pitch = note.pitch;
        }
        const span = @as(f32, @floatFromInt(@as(u32, hi_pitch) - @as(u32, lo_pitch) + 5));
        row_h = std.math.clamp(grid.height / span, ROW_H_MIN, ROW_H_MAX);
        const center_pitch = (@as(f32, @floatFromInt(lo_pitch)) + @as(f32, @floatFromInt(hi_pitch))) / 2.0;
        const center_row = @as(f32, @floatFromInt(KEY_HI)) - center_pitch;
        scroll_y = center_row * row_h - grid.height / 2.0;
        initialized_scroll = true;
        clampScroll(grid, clip);
        return;
    }

    const total = rows * row_h;
    if (grid.height < total) {
        // Start centered around the middle of the pitch range (≈ C4).
        scroll_y = (total - grid.height) / 2;
    } else {
        scroll_y = 0;
    }
    initialized_scroll = true;
}

fn minPxPerBeat(grid: c.rl.Rectangle, clip: Clip) f32 {
    return @max(1.0, grid.width / @max(@as(f32, @floatCast(clip.length_beats)), 1.0));
}

fn clampPxPerBeat(v: f32, grid: c.rl.Rectangle, clip: Clip) f32 {
    const min_px = minPxPerBeat(grid, clip);
    const max_px = @max(min_px, PX_PER_BEAT_MAX);
    return std.math.clamp(v, min_px, max_px);
}

fn clampScroll(grid: c.rl.Rectangle, clip: Clip) void {
    const rows = @as(f32, @floatFromInt(@as(u32, KEY_HI) - @as(u32, KEY_LO) + 1));
    const total_h = rows * row_h;
    const max_sy = @max(0, total_h - grid.height);
    if (scroll_y < 0) scroll_y = 0;
    if (scroll_y > max_sy) scroll_y = max_sy;
    px_per_beat = clampPxPerBeat(px_per_beat, grid, clip);
    if (scroll_x < 0) scroll_x = 0;
    const content_w = @as(f32, @floatCast(clip.length_beats)) * px_per_beat;
    const max_sx = @max(0, content_w - grid.width);
    if (scroll_x > max_sx) scroll_x = max_sx;
}

fn handleWheel(grid: c.rl.Rectangle, clip: Clip, m: widgets.Mouse) void {
    if (!widgets.contains(grid, m.x, m.y)) return;
    if (m.wheel_x == 0 and m.wheel_y == 0) return;

    const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
    const alt = c.rl.IsKeyDown(c.rl.KEY_LEFT_ALT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_ALT);

    if (shift) {
        // macOS translates Shift+scroll into a horizontal wheel delta,
        // while other platforms keep it on wheel_y. Take whichever is
        // non-zero.
        const w: f32 = if (m.wheel_y != 0) m.wheel_y else m.wheel_x;
        if (w != 0) {
            const mouse_beat = (m.x - grid.x + scroll_x) / px_per_beat;
            const factor: f32 = std.math.clamp(1.0 + w * 0.12, 0.5, 2.0);
            px_per_beat = clampPxPerBeat(px_per_beat * factor, grid, clip);
            scroll_x = mouse_beat * px_per_beat - (m.x - grid.x);
        }
    } else if (alt) {
        const w: f32 = if (m.wheel_y != 0) m.wheel_y else m.wheel_x;
        if (w != 0) {
            const mouse_row = (m.y - grid.y + scroll_y) / row_h;
            const factor: f32 = std.math.clamp(1.0 + w * 0.12, 0.5, 2.0);
            row_h = std.math.clamp(row_h * factor, ROW_H_MIN, ROW_H_MAX);
            scroll_y = mouse_row * row_h - (m.y - grid.y);
        }
    } else {
        // Plain scroll on both axes — trackpad 2-finger swipe or
        // wheel (mice only give wheel_y).
        scroll_x -= m.wheel_x * 30;
        scroll_y -= m.wheel_y * 30;
    }

    last_scroll_time = c.rl.GetTime();
}

fn drawRuler(ruler: c.rl.Rectangle, grid: c.rl.Rectangle, edit_snap: snap_mod.Setting) void {
    const grid_step = snap_mod.visualStep(edit_snap, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = grid.x + @as(f32, @floatCast(beat)) * px_per_beat - scroll_x;
        if (bx > grid.x + grid.width - 2) break;
        if (bx < grid.x - 4) {
            beat += grid_step;
            continue;
        }
        const is_beat = snap_mod.isBeat(beat);
        const is_bar = snap_mod.isBar(beat);
        const tick_h: f32 = if (is_bar) rulerH() - 4 else if (is_beat) 5 else 3;
        c.rl.DrawRectangle(
            @intFromFloat(bx),
            @intFromFloat(ruler.y + rulerH() - tick_h - 2),
            1,
            @intFromFloat(tick_h),
            if (is_bar) theme.grid_bar else if (is_beat) theme.grid_beat else theme.grid_sub,
        );
        if (is_bar) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "{d}", .{@as(u32, @intFromFloat(@round(beat / 4.0))) + 1}) catch "?";
            widgets.drawLabelF(s.ptr, bx + 2, ruler.y + 1, theme.fsTiny(), theme.text_dim);
        }
        beat += grid_step;
    }
}

fn drawKeyboard(r: c.rl.Rectangle) void {
    c.rl.DrawRectangleRec(r, theme.pane_alt);
    c.rl.BeginScissorMode(
        @intFromFloat(r.x),
        @intFromFloat(r.y),
        @intFromFloat(r.width),
        @intFromFloat(r.height),
    );
    defer c.rl.EndScissorMode();

    var pitch: u8 = KEY_HI;
    while (true) : (pitch -%= 1) {
        const y = pitchTopY(r, pitch);
        if (y + row_h < r.y) {
            if (pitch == KEY_LO) break;
            continue;
        }
        if (y > r.y + r.height) {
            if (pitch == KEY_LO) break;
            continue;
        }
        const is_black = isBlackKey(pitch);
        const fill = if (is_black) theme.slab_lo else theme.slab_fill;
        c.rl.DrawRectangle(
            @intFromFloat(r.x),
            @intFromFloat(y),
            @intFromFloat(r.width),
            @intFromFloat(row_h),
            fill,
        );
        c.rl.DrawRectangle(
            @intFromFloat(r.x),
            @intFromFloat(y + row_h - 1),
            @intFromFloat(r.width),
            1,
            theme.grid_bar,
        );
        if (pitch % 12 == 0) {
            var buf: [8]u8 = undefined;
            const octave = @as(i32, @intCast(pitch / 12)) - 1;
            const s = std.fmt.bufPrintZ(&buf, "C{d}", .{octave}) catch "C";
            widgets.drawLabelF(s.ptr, r.x + 3, y, theme.fsTiny(), theme.text_fg);
        }
        if (pitch == KEY_LO) break;
    }
}

fn drawGrid(r: c.rl.Rectangle, edit_snap: snap_mod.Setting) void {
    c.rl.DrawRectangleRec(r, theme.pane_bg);

    // Row shading matching black/white keys.
    var pitch: u8 = KEY_HI;
    while (true) : (pitch -%= 1) {
        const y = pitchTopY(r, pitch);
        if (y + row_h >= r.y and y <= r.y + r.height) {
            if (isBlackKey(pitch)) {
                c.rl.DrawRectangle(
                    @intFromFloat(r.x),
                    @intFromFloat(y),
                    @intFromFloat(r.width),
                    @intFromFloat(row_h),
                    theme.grid_row,
                );
            }
        }
        if (pitch == KEY_LO) break;
    }

    const grid_step = snap_mod.visualStep(edit_snap, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = r.x + @as(f32, @floatCast(beat)) * px_per_beat - scroll_x;
        if (bx > r.x + r.width - 1) break;
        if (bx >= r.x) {
            const is_beat = snap_mod.isBeat(beat);
            const is_bar = snap_mod.isBar(beat);
            c.rl.DrawRectangle(
                @intFromFloat(bx),
                @intFromFloat(r.y),
                1,
                @intFromFloat(r.height),
                if (is_bar) theme.grid_bar else if (is_beat) theme.grid_beat else theme.grid_sub,
            );
        }
        beat += grid_step;
    }
}

fn drawClipEndOverlay(r: c.rl.Rectangle, clip: Clip) void {
    const end_x = r.x + @as(f32, @floatCast(clip.length_beats)) * px_per_beat - scroll_x;
    // Dimmed overlay past the clip end (solid dark, no alpha — keeps
    // brutalist no-gradient rule).
    if (end_x < r.x + r.width) {
        const x0 = @max(end_x, r.x);
        c.rl.DrawRectangle(
            @intFromFloat(x0),
            @intFromFloat(r.y),
            @intFromFloat(r.x + r.width - x0),
            @intFromFloat(r.height),
            theme.bg,
        );
        // Red end line (draw after overlay so it's on top).
        if (end_x >= r.x and end_x < r.x + r.width) {
            c.rl.DrawRectangle(
                @intFromFloat(end_x),
                @intFromFloat(r.y),
                1,
                @intFromFloat(r.height),
                theme.accent_rec,
            );
        }
    }
}

fn drawExistingNotes(grid: c.rl.Rectangle, clip: Clip, track_color: c.rl.Color) void {
    for (clip.notes.items) |note| {
        const nr = noteRect(grid, note);
        if (nr.x + nr.width < grid.x or nr.x > grid.x + grid.width) continue;
        if (nr.y + nr.height < grid.y or nr.y > grid.y + grid.height) continue;
        c.rl.DrawRectangleRec(nr, track_color);
        const edge = if (note.selected) theme.text_fg else theme.slab_edge;
        c.rl.DrawRectangleLinesEx(nr, 1, edge);
    }
}

fn drawVelocityLane(r: c.rl.Rectangle, grid: c.rl.Rectangle, clip: Clip, track_color: c.rl.Color) void {
    widgets.bevelSunken(r, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("VEL", r.x + 4, r.y + 2, theme.fsTiny(), theme.text_mute);

    c.rl.BeginScissorMode(@intFromFloat(r.x + 1), @intFromFloat(r.y + 1), @intFromFloat(r.width - 2), @intFromFloat(r.height - 2));
    defer c.rl.EndScissorMode();

    const base_y = r.y + r.height - 4;
    const max_h = r.height - theme.size(14);
    for (clip.notes.items) |note| {
        const nr = noteRect(grid, note);
        if (nr.x + nr.width < r.x or nr.x > r.x + r.width) continue;
        const bar_h = @max(2, (@as(f32, @floatFromInt(note.velocity)) / 127.0) * max_h);
        const bar = widgets.rect(nr.x, base_y - bar_h, @max(nr.width, 3), bar_h);
        const fill = if (note.selected) lighten(track_color, 1.25) else dim(track_color, 0.72);
        c.rl.DrawRectangleRec(bar, fill);
        c.rl.DrawRectangleLinesEx(bar, 1, if (note.selected) theme.text_fg else theme.slab_edge);
    }
}

fn handleVelocityLane(r: c.rl.Rectangle, grid: c.rl.Rectangle, clip: *Clip, m: widgets.Mouse) bool {
    if (velocity_active) {
        if (!widgets.isDraggingKey(VELOCITY_KEY) or !m.left_down) {
            velocity_active = false;
            velocity_drag_mode = .none;
            widgets.cancelDrag();
            return true;
        }
        applyVelocityAt(r, clip, m.y);
        widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 3);
        return true;
    }

    if (!widgets.contains(r, m.x, m.y)) return false;
    widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 1);
    if (!m.left_pressed or widgets.hasActiveDrag()) return true;
    const idx = findVelocityBarAt(r, grid, clip.*, m.x) orelse return true;
    if (!widgets.tryStartDrag(VELOCITY_KEY)) return true;
    velocity_active = true;
    velocity_drag_idx = idx;
    if (clip.notes.items[idx].selected) {
        velocity_drag_mode = .selected;
    } else {
        clip.deselectAll();
        clip.notes.items[idx].selected = true;
        velocity_drag_mode = .one;
    }
    applyVelocityAt(r, clip, m.y);
    return true;
}

fn applyVelocityAt(r: c.rl.Rectangle, clip: *Clip, y: f32) void {
    const top = r.y + theme.size(10);
    const bottom = r.y + r.height - 4;
    const norm = 1.0 - std.math.clamp((y - top) / @max(1, bottom - top), 0.0, 1.0);
    const velocity: u8 = @intFromFloat(std.math.clamp(@round(norm * 127.0), 1, 127));
    switch (velocity_drag_mode) {
        .none => {},
        .one => if (velocity_drag_idx < clip.notes.items.len) {
            clip.notes.items[velocity_drag_idx].velocity = velocity;
        },
        .selected => for (clip.notes.items) |*note| {
            if (note.selected) note.velocity = velocity;
        },
    }
}

fn findVelocityBarAt(r: c.rl.Rectangle, grid: c.rl.Rectangle, clip: Clip, x: f32) ?usize {
    var i = clip.notes.items.len;
    while (i > 0) {
        i -= 1;
        const nr = noteRect(grid, clip.notes.items[i]);
        const bar = widgets.rect(nr.x, r.y, @max(nr.width, 3), r.height);
        if (widgets.contains(bar, x, r.y + r.height / 2)) return i;
    }
    return null;
}

fn drawBoxSelect(grid: c.rl.Rectangle, m: widgets.Mouse) void {
    const x0 = @min(box_start_x, m.x);
    const y0 = @min(box_start_y, m.y);
    const x1 = @max(box_start_x, m.x);
    const y1 = @max(box_start_y, m.y);
    // Clip to grid.
    const cx0 = std.math.clamp(x0, grid.x, grid.x + grid.width);
    const cy0 = std.math.clamp(y0, grid.y, grid.y + grid.height);
    const cx1 = std.math.clamp(x1, grid.x, grid.x + grid.width);
    const cy1 = std.math.clamp(y1, grid.y, grid.y + grid.height);
    const rr = widgets.rect(cx0, cy0, cx1 - cx0, cy1 - cy0);
    // Semi-transparent yellow fill + solid accent border.
    const fill = c.rl.ColorAlpha(theme.accent_hi, 0.25);
    c.rl.DrawRectangleRec(rr, fill);
    c.rl.DrawRectangleLinesEx(rr, 1, theme.accent_hi);
}

fn pitchTopY(r: c.rl.Rectangle, pitch: u8) f32 {
    const pitch_row: i32 = @as(i32, @intCast(KEY_HI)) - @as(i32, @intCast(pitch));
    return r.y + @as(f32, @floatFromInt(pitch_row)) * row_h - scroll_y;
}

fn noteRect(grid: c.rl.Rectangle, note: Note) c.rl.Rectangle {
    const y = pitchTopY(grid, note.pitch);
    const x = grid.x + @as(f32, @floatCast(note.start_beat)) * px_per_beat - scroll_x;
    const w = @max(@as(f32, @floatCast(note.length_beats)) * px_per_beat, 2);
    return widgets.rect(x, y + 1, w, row_h - 2);
}

// ── Input ────────────────────────────────────────────────────────────

fn handleInput(
    grid: c.rl.Rectangle,
    clip: *Clip,
    alloc: std.mem.Allocator,
    edit_snap: snap_mod.Setting,
    m: widgets.Mouse,
) ?u8 {
    if (updateInProgressDrag(grid, clip, alloc, edit_snap, m)) return null;

    if (widgets.contains(grid, m.x, m.y) and !widgets.hasActiveDrag()) {
        if (findNoteAt(grid, clip.*, m.x, m.y)) |h| {
            widgets.requestCursor(if (h.edge_resize) c.rl.MOUSE_CURSOR_RESIZE_EW else c.rl.MOUSE_CURSOR_POINTING_HAND, 1);
        }
    }

    if (!m.left_pressed and !m.right_pressed) return null;
    if (!widgets.contains(grid, m.x, m.y)) return null;
    if (widgets.hasActiveDrag()) return null;

    if (m.right_pressed) {
        context_target = .{
            .beat = snap_mod.snapDownPositive(edit_snap, beatAtX(grid, m.x), altBypassSnap()),
            .pitch = pitchAtY(grid, m.y),
        };
        if (findNoteAt(grid, clip.*, m.x, m.y)) |h| {
            if (!clip.notes.items[h.idx].selected) {
                clip.deselectAll();
                clip.notes.items[h.idx].selected = true;
            }
        }
        _ = widgets.openContextMenu(PR_CONTEXT_KEY, grid, m);
        return null;
    }

    const pitch = pitchAtY(grid, m.y) orelse return null;
    const beat = snap_mod.snapDownPositive(edit_snap, beatAtX(grid, m.x), altBypassSnap());
    const hit = findNoteAt(grid, clip.*, m.x, m.y);
    const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);

    // Note-level interactions work identically in both modes: click
    // selects (shift toggles), drag moves, edge drag resizes.
    if (hit) |h| {
        if (h.edge_resize) {
            if (!clip.notes.items[h.idx].selected) {
                if (!shift) clip.deselectAll();
                clip.notes.items[h.idx].selected = true;
            }
            beginResize(alloc, clip.*, m) catch {};
        } else {
            if (shift) {
                clip.notes.items[h.idx].selected = !clip.notes.items[h.idx].selected;
            } else if (!clip.notes.items[h.idx].selected) {
                clip.deselectAll();
                clip.notes.items[h.idx].selected = true;
            }
            beginMove(alloc, clip.*, m) catch {};
        }
        return clip.notes.items[h.idx].pitch;
    }

    // Empty-grid click: the only behaviour that depends on mode.
    switch (mode) {
        .draw => {
            if (!widgets.tryStartDrag(DRAW_KEY)) return null;
            draw_active = true;
            draw_pitch = pitch;
            draw_start_beat = beat;
            draw_current_beat = beat + defaultNoteBeats(edit_snap);
            draw_start_x = m.x;
        },
        .select => {
            if (!shift) clip.deselectAll();
            if (!widgets.tryStartDrag(BOX_KEY)) return null;
            box_active = true;
            box_start_x = m.x;
            box_start_y = m.y;
        },
    }
    return pitch;
}

const Hit = struct { idx: u32, edge_resize: bool };

fn findNoteAt(grid: c.rl.Rectangle, clip: Clip, x: f32, y: f32) ?Hit {
    var i: usize = clip.notes.items.len;
    while (i > 0) {
        i -= 1;
        const nr = noteRect(grid, clip.notes.items[i]);
        if (!widgets.contains(nr, x, y)) continue;
        const near_right = x >= nr.x + nr.width - resizeEdgeW();
        return .{ .idx = @intCast(i), .edge_resize = near_right };
    }
    return null;
}

fn updateInProgressDrag(
    grid: c.rl.Rectangle,
    clip: *Clip,
    alloc: std.mem.Allocator,
    edit_snap: snap_mod.Setting,
    m: widgets.Mouse,
) bool {
    if (draw_active) {
        updateDraw(grid, clip, alloc, edit_snap, m);
        return true;
    }
    if (box_active) {
        updateBox(grid, clip, m);
        return true;
    }
    if (move_active) {
        updateMove(grid, clip, edit_snap, m);
        return true;
    }
    if (resize_active) {
        updateResize(grid, clip, edit_snap, m);
        return true;
    }
    return false;
}

fn updateDraw(grid: c.rl.Rectangle, clip: *Clip, alloc: std.mem.Allocator, edit_snap: snap_mod.Setting, m: widgets.Mouse) void {
    if (!widgets.isDraggingKey(DRAW_KEY) or !m.left_down) {
        const start = @min(draw_start_beat, draw_current_beat);
        const end = @max(draw_start_beat, draw_current_beat);
        const len = @max(end - start, minNoteBeats(edit_snap));
        clip.addNote(alloc, .{
            .pitch = draw_pitch,
            .start_beat = start,
            .length_beats = len,
            .selected = false,
        }) catch |err| std.log.err("add note failed: {s}", .{@errorName(err)});
        draw_active = false;
        widgets.cancelDrag();
        return;
    }
    if (@abs(m.x - draw_start_x) >= BOX_MIN_DRAG) {
        draw_current_beat = snap_mod.snapPositive(edit_snap, beatAtX(grid, m.x), altBypassSnap());
    }
}

fn updateBox(grid: c.rl.Rectangle, clip: *Clip, m: widgets.Mouse) void {
    if (!widgets.isDraggingKey(BOX_KEY) or !m.left_down) {
        // Apply selection if we actually dragged.
        const dx = m.x - box_start_x;
        const dy = m.y - box_start_y;
        if (@abs(dx) >= BOX_MIN_DRAG or @abs(dy) >= BOX_MIN_DRAG) {
            const x0 = @min(box_start_x, m.x);
            const y0 = @min(box_start_y, m.y);
            const x1 = @max(box_start_x, m.x);
            const y1 = @max(box_start_y, m.y);
            const box_r = widgets.rect(x0, y0, x1 - x0, y1 - y0);
            for (clip.notes.items) |*n| {
                const nr = noteRect(grid, n.*);
                if (rectsOverlap(nr, box_r)) n.selected = true;
            }
        }
        box_active = false;
        widgets.cancelDrag();
    }
}

fn beginMove(alloc: std.mem.Allocator, clip: Clip, m: widgets.Mouse) !void {
    if (!widgets.tryStartDrag(MOVE_KEY)) return;
    move_snaps.clearRetainingCapacity();
    for (clip.notes.items, 0..) |n, i| {
        if (n.selected) {
            try move_snaps.append(alloc, .{
                .idx = @intCast(i),
                .start_beat = n.start_beat,
                .pitch = n.pitch,
            });
        }
    }
    if (move_snaps.items.len == 0) {
        widgets.cancelDrag();
        return;
    }
    move_active = true;
    move_start_mouse_x = m.x;
    move_start_mouse_y = m.y;
}

fn updateMove(grid: c.rl.Rectangle, clip: *Clip, edit_snap: snap_mod.Setting, m: widgets.Mouse) void {
    _ = grid;
    if (!widgets.isDraggingKey(MOVE_KEY) or !m.left_down) {
        move_active = false;
        widgets.cancelDrag();
        return;
    }
    widgets.requestCursor(c.rl.MOUSE_CURSOR_POINTING_HAND, 3);
    const d_beats = snap_mod.snapNearest(edit_snap, @as(f64, (m.x - move_start_mouse_x) / px_per_beat), altBypassSnap());
    const d_rows = std.math.clamp(@as(i32, @intFromFloat(@round((m.y - move_start_mouse_y) / row_h))), -127, 127);
    for (move_snaps.items) |s| {
        if (s.idx >= clip.notes.items.len) continue;
        const n = &clip.notes.items[s.idx];
        const new_start = s.start_beat + d_beats;
        n.start_beat = if (new_start < 0) 0 else new_start;
        const new_pitch: i32 = @as(i32, @intCast(s.pitch)) - d_rows; // up = higher pitch
        n.pitch = @intCast(std.math.clamp(new_pitch, 0, 127));
    }
}

fn beginResize(alloc: std.mem.Allocator, clip: Clip, m: widgets.Mouse) !void {
    if (!widgets.tryStartDrag(RESIZE_KEY)) return;
    resize_snaps.clearRetainingCapacity();
    for (clip.notes.items, 0..) |n, i| {
        if (n.selected) {
            try resize_snaps.append(alloc, .{
                .idx = @intCast(i),
                .length = n.length_beats,
            });
        }
    }
    if (resize_snaps.items.len == 0) {
        widgets.cancelDrag();
        return;
    }
    resize_active = true;
    resize_start_mouse_x = m.x;
}

fn updateResize(grid: c.rl.Rectangle, clip: *Clip, edit_snap: snap_mod.Setting, m: widgets.Mouse) void {
    _ = grid;
    if (!widgets.isDraggingKey(RESIZE_KEY) or !m.left_down) {
        resize_active = false;
        widgets.cancelDrag();
        return;
    }
    widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
    const d_beats = snap_mod.snapNearest(edit_snap, @as(f64, (m.x - resize_start_mouse_x) / px_per_beat), altBypassSnap());
    for (resize_snaps.items) |s| {
        if (s.idx >= clip.notes.items.len) continue;
        const n = &clip.notes.items[s.idx];
        const new_len = s.length + d_beats;
        n.length_beats = if (new_len < minNoteBeats(edit_snap)) minNoteBeats(edit_snap) else new_len;
    }
}

// ── Vertical scrollbar (lazy) ────────────────────────────────────────

fn drawAndHandleScrollbar(grid: c.rl.Rectangle, m: widgets.Mouse) void {
    const rows = @as(f32, @floatFromInt(@as(u32, KEY_HI) - @as(u32, KEY_LO) + 1));
    const content_h = rows * row_h;
    if (content_h <= grid.height) return; // nothing to scroll

    const now = c.rl.GetTime();
    const since_scroll = now - last_scroll_time;
    const near_right = m.x >= grid.x + grid.width - SCROLLBAR_HOVER_RANGE and
        m.x <= grid.x + grid.width and
        m.y >= grid.y and m.y <= grid.y + grid.height;

    // Alpha fade: 1.0 when scrolling or near-right, then linger
    // SCROLLBAR_FADE_LINGER before fading out over SCROLLBAR_FADE_VISIBLE.
    var alpha: f32 = 0;
    if (near_right or sb_drag) {
        alpha = 1.0;
    } else if (since_scroll < SCROLLBAR_FADE_LINGER) {
        alpha = 1.0;
    } else if (since_scroll < SCROLLBAR_FADE_LINGER + SCROLLBAR_FADE_VISIBLE) {
        const t = (since_scroll - SCROLLBAR_FADE_LINGER) / SCROLLBAR_FADE_VISIBLE;
        alpha = 1.0 - @as(f32, @floatCast(t));
    }
    if (alpha <= 0 and !sb_drag) return;

    const bar_x = grid.x + grid.width - scrollbarW();
    const track = widgets.rect(bar_x, grid.y, scrollbarW(), grid.height);
    c.rl.DrawRectangleRec(track, c.rl.ColorAlpha(theme.slab_edge, alpha * 0.6));

    const thumb_h = @max(16.0, (grid.height / content_h) * grid.height);
    const scroll_range = content_h - grid.height;
    const track_range = grid.height - thumb_h;
    const thumb_y = grid.y + (scroll_y / scroll_range) * track_range;
    const thumb = widgets.rect(bar_x + 1, thumb_y, scrollbarW() - 2, thumb_h);

    const hover_thumb = widgets.contains(thumb, m.x, m.y);
    const thumb_color = if (sb_drag or hover_thumb) theme.accent_hi else theme.slab_hi;
    c.rl.DrawRectangleRec(thumb, c.rl.ColorAlpha(thumb_color, alpha));

    // ── Input ─────────────────────────────────────────────────────────
    if (sb_drag) {
        if (!widgets.isDraggingKey(SB_KEY) or !m.left_down) {
            sb_drag = false;
            widgets.cancelDrag();
            return;
        }
        const dy = m.y - sb_drag_start_mouse_y;
        scroll_y = sb_drag_start_scroll_y + dy * (scroll_range / track_range);
        last_scroll_time = now;
        return;
    }

    if (!m.left_pressed) return;
    if (widgets.hasActiveDrag()) return;

    if (hover_thumb) {
        if (!widgets.tryStartDrag(SB_KEY)) return;
        sb_drag = true;
        sb_drag_start_mouse_y = m.y;
        sb_drag_start_scroll_y = scroll_y;
    } else if (widgets.contains(track, m.x, m.y)) {
        // Click on track above/below thumb → page jump.
        const page: f32 = grid.height * 0.8;
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
    grid: c.rl.Rectangle,
    clip: Clip,
    track_color: c.rl.Color,
    m: widgets.Mouse,
) void {
    if (strip.width <= 4 or strip.height <= 4 or grid.width <= 0 or grid.height <= 0) return;

    widgets.bevelSunken(strip, theme.pane_bg, theme.slab_hi, theme.slab_lo);
    const inner = widgets.rect(strip.x + 2, strip.y + 2, strip.width - 4, strip.height - 4);
    c.rl.DrawRectangleRec(inner, theme.pane_bg);

    // The strip represents the clip [0 .. length_beats] horizontally.
    // Pitch compresses into the strip's vertical span.
    const clip_beats: f32 = @max(@as(f32, @floatCast(clip.length_beats)), 1.0);
    const px_per_beat_ov = inner.width / clip_beats;
    const rows: f32 = @floatFromInt(@as(u32, KEY_HI) - @as(u32, KEY_LO));
    const px_per_row_ov = inner.height / (rows + 1);

    // Notes as short horizontal dashes.
    for (clip.notes.items) |note| {
        const n_x = inner.x + @as(f32, @floatCast(note.start_beat)) * px_per_beat_ov;
        const n_w = @max(@as(f32, @floatCast(note.length_beats)) * px_per_beat_ov, 1.0);
        const pitch_idx: f32 = @as(f32, @floatFromInt(@as(u32, KEY_HI) - @as(u32, note.pitch)));
        const n_y = inner.y + pitch_idx * px_per_row_ov;
        c.rl.DrawRectangle(
            @intFromFloat(@max(n_x, inner.x)),
            @intFromFloat(std.math.clamp(n_y, inner.y, inner.y + inner.height - 1)),
            @intFromFloat(@min(n_w, inner.x + inner.width - n_x)),
            1,
            track_color,
        );
    }

    // Viewport window — reflects grid's currently visible beat range.
    const view_beat_l = scroll_x / px_per_beat;
    const view_beat_r = (scroll_x + grid.width) / px_per_beat;
    const vp_x = inner.x + view_beat_l * px_per_beat_ov;
    const vp_w = @max(1.0, (view_beat_r - view_beat_l) * px_per_beat_ov);
    const vp_x_clamped = std.math.clamp(vp_x, inner.x, inner.x + inner.width);
    const vp_right = std.math.clamp(vp_x + vp_w, inner.x, inner.x + inner.width);
    const vp = widgets.rect(vp_x_clamped, inner.y, vp_right - vp_x_clamped, inner.height);
    c.rl.DrawRectangleRec(vp, c.rl.ColorAlpha(theme.accent_hi, 0.2));
    c.rl.DrawRectangleLinesEx(vp, 1, theme.accent_hi);

    handleOverviewInput(inner, grid, clip, m);
}

fn handleOverviewInput(
    inner: c.rl.Rectangle,
    grid: c.rl.Rectangle,
    clip: Clip,
    m: widgets.Mouse,
) void {
    const clip_beats: f32 = @max(@as(f32, @floatCast(clip.length_beats)), 1.0);
    const px_per_beat_ov = inner.width / clip_beats;
    const view_beat_l = scroll_x / px_per_beat;
    const vp_x = inner.x + view_beat_l * px_per_beat_ov;
    const vp_w = @max(1.0, (grid.width / px_per_beat) * px_per_beat_ov);

    if (widgets.contains(inner, m.x, m.y) and (m.wheel_x != 0 or m.wheel_y != 0)) {
        const w: f32 = if (m.wheel_y != 0) m.wheel_y else m.wheel_x;
        const anchor_beat = (m.x - inner.x) / px_per_beat_ov;
        const factor: f32 = std.math.clamp(1.0 + w * 0.12, 0.5, 2.0);
        px_per_beat = clampPxPerBeat(px_per_beat * factor, grid, clip);
        scroll_x = anchor_beat * px_per_beat - grid.width / 2.0;
        if (scroll_x < 0) scroll_x = 0;
        last_scroll_time = c.rl.GetTime();
        return;
    }

    if (overview_drag) {
        if (!widgets.isDraggingKey(OVERVIEW_KEY) or !m.left_down) {
            overview_drag = false;
            widgets.cancelDrag();
            return;
        }
        const want_vp_x = m.x - overview_drag_offset;
        const want_beat_l = (want_vp_x - inner.x) / px_per_beat_ov;
        scroll_x = want_beat_l * px_per_beat;
        if (scroll_x < 0) scroll_x = 0;
        return;
    }

    if (!m.left_pressed) return;
    if (!widgets.contains(inner, m.x, m.y)) return;
    if (widgets.hasActiveDrag()) return;

    const on_vp = m.x >= vp_x and m.x <= vp_x + vp_w;
    if (!widgets.tryStartDrag(OVERVIEW_KEY)) return;
    overview_drag = true;
    if (on_vp) {
        overview_drag_offset = m.x - vp_x;
    } else {
        // Click outside viewport → jump so that the clicked position
        // becomes the centre.
        const want_vp_x = m.x - vp_w / 2;
        const want_beat_l = (want_vp_x - inner.x) / px_per_beat_ov;
        scroll_x = want_beat_l * px_per_beat;
        if (scroll_x < 0) scroll_x = 0;
        overview_drag_offset = vp_w / 2;
    }
}

// ── Utilities ────────────────────────────────────────────────────────

fn beatAtX(grid: c.rl.Rectangle, x: f32) f64 {
    return @as(f64, (x - grid.x + scroll_x) / px_per_beat);
}

fn pitchAtY(grid: c.rl.Rectangle, y: f32) ?u8 {
    if (y < grid.y or y >= grid.y + grid.height) return null;
    const row = @as(i32, @intFromFloat((y - grid.y + scroll_y) / row_h));
    const pitch = @as(i32, @intCast(KEY_HI)) - row;
    if (pitch < @as(i32, @intCast(KEY_LO)) or pitch > @as(i32, @intCast(KEY_HI))) return null;
    return @intCast(pitch);
}

fn altBypassSnap() bool {
    return c.rl.IsKeyDown(c.rl.KEY_LEFT_ALT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_ALT);
}

fn minNoteBeats(edit_snap: snap_mod.Setting) f64 {
    return @min(edit_snap.beats() orelse MIN_NOTE_BEATS, MIN_NOTE_BEATS);
}

fn defaultNoteBeats(edit_snap: snap_mod.Setting) f64 {
    return @max(edit_snap.beats() orelse DEFAULT_NOTE_BEATS, MIN_NOTE_BEATS);
}

fn isBlackKey(pitch: u8) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

fn lighten(color: c.rl.Color, factor: f32) c.rl.Color {
    const r: f32 = @as(f32, @floatFromInt(color.r)) * factor;
    const g: f32 = @as(f32, @floatFromInt(color.g)) * factor;
    const b: f32 = @as(f32, @floatFromInt(color.b)) * factor;
    return .{
        .r = @intFromFloat(@min(r, 255)),
        .g = @intFromFloat(@min(g, 255)),
        .b = @intFromFloat(@min(b, 255)),
        .a = color.a,
    };
}

fn dim(color: c.rl.Color, factor: f32) c.rl.Color {
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(color.r)) * factor),
        .g = @intFromFloat(@as(f32, @floatFromInt(color.g)) * factor),
        .b = @intFromFloat(@as(f32, @floatFromInt(color.b)) * factor),
        .a = color.a,
    };
}

fn rectsOverlap(a: c.rl.Rectangle, b: c.rl.Rectangle) bool {
    return !(a.x + a.width < b.x or b.x + b.width < a.x or
        a.y + a.height < b.y or b.y + b.height < a.y);
}
