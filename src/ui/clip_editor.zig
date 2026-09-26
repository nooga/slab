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
//!   • Arrow keys         → nudge selected notes
//!   • Shift+Up/Down     → move selected notes by octave
//!   • Q / H / S          → quantize / humanize / snap to scale
//!   • Wheel              → horizontal zoom around mouse
//!   • Shift+Wheel        → horizontal scroll
//!
//! Visuals:
//!   • Clip-end line in red + a dimmed overlay past the clip length
//!   • Selected notes get a bright border
//!   • Box-select drag shows a rubber band

const std = @import("std");
const c = @import("../c.zig");
const pane = @import("pane_input.zig");
const menu = @import("menu.zig");
const bridge = @import("bridge.zig");
const ui_core = @import("core.zig");
const ui_style = @import("style.zig");
const ctl = @import("controls.zig");
const Ui = ui_core.Ui;
const Rect = ui_core.Rect;
const snap_mod = @import("snap.zig");
const track_mod = @import("../track.zig");
const machine_mod = @import("../machine.zig");
const clip_mod = @import("../clip.zig");
const Clip = clip_mod.Clip;
const Note = clip_mod.Note;
const ClipRef = clip_mod.ClipRef;
const meter_mod = @import("../meter.zig");

// ── Grid constants ───────────────────────────────────────────────────

// Active machine's note map (drum machines): mapped rows render as
// labelled lanes, the rest dim out. Set per frame from the resolved
// track's machine; empty = chromatic roll.
var note_map: []const machine_mod.NoteLabel = &.{};

fn mapLabel(pitch: u8) ?[*:0]const u8 {
    for (note_map) |*nl| {
        if (nl.pitch == pitch) return nl.labelZ();
    }
    return null;
}

const KEY_LO: u8 = 12; // C0 (bottom row)
const KEY_HI: u8 = 119; // B8 (top row; inclusive)

// ── Feel & key state (persistent across the session) ─────────────────
//
// swing delays odd grid steps on quantize (0 = straight); key_root + scale
// constrain edits and shade the in-key rows. scale_idx 0 is Off (chromatic).

pub var swing: f32 = 0; // 0..1 → up to half a grid step of delay on off-beats
pub var key_root: u8 = 0; // 0=C .. 11=B
pub var scale_idx: usize = 0;

const Scale = struct {
    name: [*:0]const u8,
    // Bit i set = semitone i above the root is in the scale.
    mask: u12,
};

const SCALES = [_]Scale{
    .{ .name = "Off", .mask = 0b111111111111 }, // chromatic — no constraint
    .{ .name = "Major", .mask = 0b101010110101 },
    .{ .name = "Minor", .mask = 0b010110101101 }, // natural minor
    .{ .name = "Dorian", .mask = 0b011010101101 },
    .{ .name = "Phrygian", .mask = 0b010110101011 },
    .{ .name = "Mixolyd", .mask = 0b011010110101 },
    .{ .name = "Penta", .mask = 0b001010010101 }, // major pentatonic
    .{ .name = "MinPenta", .mask = 0b010010101001 },
    .{ .name = "Harm.Min", .mask = 0b100110101101 },
};

const ROOT_NAMES = [_][*:0]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

fn scaleActive() bool {
    return scale_idx > 0 and scale_idx < SCALES.len and note_map.len == 0;
}

fn inScale(pitch: u8) bool {
    if (!scaleActive()) return true;
    const degree: u4 = @intCast((@as(u8, pitch) + 12 - (key_root % 12)) % 12);
    return (SCALES[scale_idx].mask >> degree) & 1 == 1;
}

fn isRootPitch(pitch: u8) bool {
    return scaleActive() and (pitch % 12) == (key_root % 12);
}

// Nearest in-scale pitch (search outward; falls back to the input).
fn snapPitchToScale(pitch: u8) u8 {
    if (!scaleActive()) return pitch;
    if (inScale(pitch)) return pitch;
    var off: i32 = 1;
    while (off <= 6) : (off += 1) {
        const up = @as(i32, pitch) + off;
        if (up <= 127 and inScale(@intCast(up))) return @intCast(up);
        const dn = @as(i32, pitch) - off;
        if (dn >= 0 and inScale(@intCast(dn))) return @intCast(dn);
    }
    return pitch;
}
fn keyboardW() f32 {
    return 32;
}
fn rulerH() f32 {
    return 16;
}
const MIN_NOTE_BEATS: f64 = 0.25;
const MIN_FINE_NOTE_BEATS: f64 = 0.0625;
const DEFAULT_NOTE_BEATS: f64 = 0.5;
fn resizeEdgeW() f32 {
    return 4;
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
// Live meter map + the edited clip's absolute start beat, captured per
// frame so the grid draws bars in project (absolute) beat space.
var ce_default_meter_pts = [_]meter_mod.MeterPoint{.{ .start_bar = 0, .numerator = 4, .denominator = 4 }};
var cur_meter: meter_mod.MeterMap = .{ .points = &ce_default_meter_pts };
var cur_clip_start: f64 = 0;
var last_clip_key: u64 = 0; // to detect clip switch → clear selection

fn overviewH() f32 {
    return 16;
}
fn velocityLaneH() f32 {
    return 48;
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
    return 6;
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
    command: menu.EditCommand = .none,
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

// Apply swing to a grid-snapped beat: delay odd grid steps toward the next
// one (0 = straight). Only acts on an 8th-note grid or finer. Shared by the
// grid lines, note drawing, and Quantize so the groove is consistent and
// visible everywhere.
fn applySwing(snapped: f64, edit_snap: snap_mod.Setting) f64 {
    if (swing <= 0) return snapped;
    const g = snap_mod.activeStep(edit_snap, false) orelse return snapped;
    if (g > 0.5001) return snapped; // swing is meaningless coarser than 1/8
    const idx = @round(snapped / g);
    if (@mod(@as(i64, @intFromFloat(idx)), 2) != 0) return snapped + @as(f64, swing) * 0.5 * g;
    return snapped;
}

pub fn quantizeSelectedNotes(tracks: []track_mod.Track, selected: ?ClipRef, edit_snap: snap_mod.Setting) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    var changed = false;
    for (resolved.clip.notes.items) |*note| {
        if (!note.selected) continue;
        const next_start = applySwing(snap_mod.snapPositive(edit_snap, note.start_beat, false), edit_snap);
        const next_len = @max(minNoteBeats(edit_snap), snap_mod.snapNearest(edit_snap, note.length_beats, false));
        if (next_start != note.start_beat or next_len != note.length_beats) changed = true;
        note.start_beat = next_start;
        note.length_beats = next_len;
    }
    return changed;
}

// ── Humanize: subtle random timing + velocity jitter ─────────────────

var humanize_rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x5eed_1234);
var humanize_seed_bump: u64 = 0;

pub fn humanizeSelectedNotes(tracks: []track_mod.Track, selected: ?ClipRef, edit_snap: snap_mod.Setting) bool {
    const resolved = resolveClip(tracks, selected) orelse return false;
    // Re-seed each call so repeated humanize keeps shuffling.
    humanize_seed_bump +%= 0x9E37_79B9_7F4A_7C15;
    humanize_rng.seed(0x5eed_1234 ^ humanize_seed_bump);
    const rnd = humanize_rng.random();
    // Timing spread: a fraction of the grid step (fallback 1/16 beat).
    const step = snap_mod.activeStep(edit_snap, false) orelse 0.25;
    const time_amt = step * 0.25; // up to ±25% of a grid step
    var changed = false;
    for (resolved.clip.notes.items) |*note| {
        if (!note.selected) continue;
        const dt = (rnd.float(f64) * 2.0 - 1.0) * time_amt;
        const start = @max(0.0, note.start_beat + dt);
        const dv: i32 = @intFromFloat(@round((rnd.float(f32) * 2.0 - 1.0) * 14.0));
        const vel: u8 = @intCast(std.math.clamp(@as(i32, note.velocity) + dv, 1, 127));
        if (start != note.start_beat or vel != note.velocity) changed = true;
        note.start_beat = start;
        note.velocity = vel;
    }
    return changed;
}

// ── Snap selected notes' pitches to the active scale ─────────────────

pub fn snapSelectedToScale(tracks: []track_mod.Track, selected: ?ClipRef) bool {
    if (!scaleActive()) return false;
    const resolved = resolveClip(tracks, selected) orelse return false;
    var changed = false;
    for (resolved.clip.notes.items) |*note| {
        if (!note.selected) continue;
        const np = snapPitchToScale(note.pitch);
        if (np != note.pitch) changed = true;
        note.pitch = np;
    }
    return changed;
}

// ── Header tools: KEY / SCALE / SWING, drawn into the pane header ─────

const KEYSCALE_MENU_KEY: u64 = 0x5CA1_E5E1_EC70_0001;

// ── Pane head (shared with the audio clip editor) ────────────────────

pub const HEAD_H: i32 = 20;

pub const Head = struct {
    body: Rect,
    /// Title tile (also the rename field's anchor).
    title: Rect,
    /// Room cut for the caller's tools, right of the title; empty when the
    /// bar is too narrow to keep the title legible.
    tools: Rect = .{},
    minimize: bool = false,
    close: bool = false,
};

/// Editor pane head: one 20px toolbar of flush tiles — optional DRAW latch,
/// the title (track-colour bar, engraved kind, clip name), the caller's
/// tools, collapse and close.
pub fn paneHead(ui: *Ui, r: Rect, kind: []const u8, name: []const u8, color: ?ui_style.Color, draw_mode: ?*bool, tools_w: i32) Head {
    var rest = r;
    var bar = rest.cutTop(HEAD_H);
    var out = Head{ .body = rest, .title = .{} };
    const close_r = bar.cutRight(18);
    out.close = ctl.button(ui, close_r, "close", null, .{ .label = "\u{D7}", .flush = true });
    menu.tip(ui, close_r, "Close panel");
    const min_r = bar.cutRight(18);
    out.minimize = ctl.button(ui, min_r, "min", null, .{ .label = "-", .flush = true });
    menu.tip(ui, min_r, "Collapse panel");
    if (draw_mode) |dm| {
        const dr = bar.cutLeft(52);
        _ = ctl.button(ui, dr, "draw", dm, .{ .kind = .latch, .label = "DRAW", .led = ui_style.accent, .flush = true });
        menu.tip(ui, dr, if (dm.*) "Draw tool: click to switch to select" else "Select tool: click to switch to draw");
    }
    if (tools_w > 0 and bar.w >= tools_w + 96) out.tools = bar.cutRight(tools_w);
    out.title = bar;
    var body = ui.plate(bar, .{});
    if (color) |col| ui.rect(body.cutLeft(3), col);
    const kw = ui.engraved(&ui.fonts.legend, body.x + 4, body.y + @divFloor(body.h - 12, 2), kind, ui_style.text_mute);
    _ = body.cutLeft(4 + kw + 8);
    ui.textIn(&ui.fonts.body_bold, body, name, ui_style.text_dim, .left, true);
    return out;
}

/// Empty editor body: flat glass with a centred engraved note.
pub fn emptyBody(ui: *Ui, r: Rect, msg: []const u8) void {
    ui.rect(r, ui_style.pane);
    ui.textIn(&ui.fonts.legend, r, msg, ui_style.text_mute, .center, false);
}

const TOOLS_W: i32 = 196;
const KS_W: i32 = 92;

// One combined "C Major" picker (root → scale submenu sets both) + a swing
// fader, flush tiles at the right end of the head.
fn drawHeaderTools(ui: *Ui, tools: Rect) void {
    // Key/scale picker menu (modal) — ticked unconditionally so it stays live
    // even if the strip is hidden by a narrow header. Top level is the 12
    // roots (each a submenu); a root expanded shows the scales. Clicking a
    // root sets the root and keeps the scale; clicking a scale sets both.
    if (menu.isOpen(KEYSCALE_MENU_KEY)) {
        var roots: [12]menu.Item = undefined;
        for (ROOT_NAMES, 0..) |nm, i| roots[i] = .{ .label = std.mem.span(nm), .id = @intCast(i), .submenu = true };
        if (menu.pick(KEYSCALE_MENU_KEY, &roots)) |rid| key_root = @intCast(rid);
        if (menu.subOpen(KEYSCALE_MENU_KEY, 0)) |rid| {
            var scales: [SCALES.len]menu.Item = undefined;
            for (SCALES, 0..) |sc, i| scales[i] = .{ .label = std.mem.span(sc.name), .id = @intCast(i) };
            if (menu.subPick(KEYSCALE_MENU_KEY, 1, &scales)) |sid| {
                key_root = @intCast(rid);
                scale_idx = @intCast(sid);
            }
        }
    }
    if (tools.empty()) return;

    var t = tools;
    {
        var buf: [24]u8 = undefined;
        const root = std.mem.span(ROOT_NAMES[key_root % 12]);
        const label = if (scale_idx == 0)
            root
        else
            (std.fmt.bufPrint(&buf, "{s} {s}", .{ root, std.mem.span(SCALES[scale_idx].name) }) catch root);
        const ks_r = t.cutLeft(KS_W);
        const open = menu.isOpen(KEYSCALE_MENU_KEY);
        if (ctl.button(ui, ks_r, "keyscale", null, .{ .label = label, .flush = true }) and !open) {
            menu.openBelow(KEYSCALE_MENU_KEY, ks_r);
        }
        menu.tip(ui, ks_r, "Key & scale: pick a root, then a scale");
    }
    {
        var body = ui.plate(t, .{});
        const lbl = body.cutLeft(18);
        ui.textIn(&ui.fonts.legend, lbl, "SW", ui_style.text_dim, .center, true);
        var buf: [8]u8 = undefined;
        const pct: i32 = @intFromFloat(@round(swing * 100));
        const s = std.fmt.bufPrint(&buf, "{d}%", .{pct}) catch "0%";
        ctl.display(ui, body.cutRight(4 * ctl.CELL_W + 4).insetXY(0, @divFloor(body.h - ctl.displayHeight(false), 2)), s, .{ .align_ = .right });
        _ = body.cutRight(2);
        const fr = body.insetXY(0, @divFloor(body.h - 14, 2));
        var v: f32 = swing;
        if (ctl.slider(ui, fr, "swing", &v, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 0 })) swing = v;
        menu.tip(ui, fr, "Swing: shifts off-beats on the grid, draw, and Quantize");
    }
}

pub fn draw(
    ui: *Ui,
    r: c.rl.Rectangle,
    tracks: []track_mod.Track,
    alloc: std.mem.Allocator,
    selected: ?ClipRef,
    meter_map: meter_mod.MeterMap,
    edit_snap: snap_mod.Setting,
    can_paste_notes: bool,
    m: pane.Mouse,
) Result {
    cur_meter = meter_map;
    ui.pushId("clip-editor");
    defer ui.popId();

    const clip_opt = resolveClip(tracks, selected);
    var draw_on = mode == .draw;
    const name = if (clip_opt) |res| res.clip.name() else "";
    const color: ?ui_style.Color = if (clip_opt) |res| ui_style.nearestTrack(.{ .r = res.color.r, .g = res.color.g, .b = res.color.b }) else null;
    const head = paneHead(ui, bridge.fromRl(r), "NOTES", name, color, if (clip_opt != null) &draw_on else null, if (clip_opt != null) TOOLS_W else 0);
    if (draw_on != (mode == .draw)) {
        mode = if (draw_on) .draw else .select;
        cancelAllDrags();
    }

    const resolved = clip_opt orelse {
        emptyBody(ui, head.body, "NO CLIP SELECTED");
        return .{ .minimize = head.minimize, .close = head.close };
    };

    note_map = resolved.note_labels;
    drawHeaderTools(ui, head.tools);
    maybeResetOnClipChange(selected, resolved.clip);
    const pres = drawPianoRoll(ui, bridge.toRl(head.body), resolved.clip, resolved.color, alloc, edit_snap, can_paste_notes, m);

    return .{
        .minimize = head.minimize,
        .close = head.close,
        .audition_pitch = pres.audition_pitch,
        .command = pres.command,
        .command_beat = pres.command_beat,
        .command_pitch = pres.command_pitch,
        .rename_rect = bridge.toRl(head.title),
    };
}

// ── Resolution + reset on switch ─────────────────────────────────────

const Resolved = struct {
    clip: *Clip,
    color: c.rl.Color,
    note_labels: []const machine_mod.NoteLabel = &.{},
};

fn resolveClip(tracks: []track_mod.Track, selected: ?ClipRef) ?Resolved {
    const s = selected orelse return null;
    if (s.track >= tracks.len) return null;
    const t = &tracks[s.track];
    if (s.clip >= t.clips.items.len) return null;
    return .{
        .clip = &t.clips.items[s.clip],
        .color = t.color,
        .note_labels = t.machine.note_labels,
    };
}

fn maybeResetOnClipChange(selected: ?ClipRef, clip: *Clip) void {
    const key = if (selected) |s| pane.keyFromIds(0xC11EC011, s.track, s.clip) else 0;
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
    pane.cancelDrag();
}


// ── Piano roll draw + input ──────────────────────────────────────────

const PianoRollResult = struct {
    audition_pitch: ?u8 = null,
    command: menu.EditCommand = .none,
    command_beat: ?f64 = null,
    command_pitch: ?u8 = null,
};

fn drawPianoRoll(
    ui: *Ui,
    r: c.rl.Rectangle,
    clip: *Clip,
    track_color_rl: c.rl.Color,
    alloc: std.mem.Allocator,
    edit_snap: snap_mod.Setting,
    can_paste_notes: bool,
    m: pane.Mouse,
) PianoRollResult {
    const track_color = ui_style.nearestTrack(.{ .r = track_color_rl.r, .g = track_color_rl.g, .b = track_color_rl.b });
    // Overview strip, ruler, keyboard + grid, velocity lane — stacked.
    const overview_rect = pane.rect(r.x, r.y, r.width, overviewH());
    const ruler_rect = pane.rect(r.x, r.y + overviewH(), r.width, rulerH());

    const grid_top = ruler_rect.y + rulerH();
    const vel_h = @round(@min(velocityLaneH(), @max(28, r.height * 0.22)));
    const grid_h = @max(48, r.height - overviewH() - rulerH() - vel_h);
    const kbd_rect = pane.rect(r.x, grid_top, keyboardW(), grid_h);
    const grid_rect = pane.rect(r.x + keyboardW(), grid_top, r.width - keyboardW(), grid_h);
    const vel_rect = pane.rect(grid_rect.x, grid_rect.y + grid_rect.height, grid_rect.width, vel_h);

    cur_clip_start = clip.start_beat;
    initScrollIfNeeded(grid_rect, clip.*);
    handleWheel(grid_rect, clip.*, m);
    clampScroll(grid_rect, clip.*);

    drawRuler(ui, ruler_rect, grid_rect, edit_snap);
    drawKeyboard(ui, kbd_rect);

    // Everything that scrolls is clipped to the grid viewport so notes and
    // draw-previews never bleed into the keyboard or the adjacent panes.
    ui.clip(bridge.fromRl(grid_rect));
    drawGrid(ui, grid_rect, edit_snap);
    drawExistingNotes(ui, grid_rect, clip.*, track_color);
    drawClipEndOverlay(ui, grid_rect, clip.*);

    if (draw_active) {
        const start = @min(draw_start_beat, draw_current_beat);
        const end = @max(draw_start_beat, draw_current_beat);
        const len = @max(end - start, minNoteBeats(edit_snap));
        const nr = frectRl(noteRect(grid_rect, .{
            .pitch = draw_pitch,
            .start_beat = start,
            .length_beats = len,
        }));
        ui.rect(nr, track_color.mix(ui_style.text, 0.3));
        ui.bevel(nr, ui_style.text, ui_style.text);
    }
    if (box_active) {
        drawBoxSelect(ui, grid_rect, m);
    }
    ui.unclip();

    // Lazy vertical scrollbar (over the grid).
    drawAndHandleScrollbar(ui, grid_rect, m);
    const velocity_consumed = handleVelocityLane(vel_rect, grid_rect, clip, m);
    drawVelocityLane(ui, pane.rect(r.x, vel_rect.y, keyboardW(), vel_h), vel_rect, grid_rect, clip.*, track_color);

    drawOverview(ui, overview_rect, grid_rect, clip.*, track_color, m);

    var result = PianoRollResult{ .audition_pitch = if (velocity_consumed) null else handleInput(ui, grid_rect, clip, alloc, edit_snap, m) };
    _ = menu.openContext(ui, PR_CONTEXT_KEY, bridge.fromRl(grid_rect));
    const has_selection = clip.selectedCount() > 0;
    const has_notes = clip.notes.items.len > 0;
    const pr_context_items = [_]menu.Item{
        .{ .label = "Copy", .command = .copy, .enabled = has_selection },
        .{ .label = "Cut", .command = .cut, .enabled = has_selection },
        .{ .label = "Paste", .command = .paste, .enabled = can_paste_notes },
        .{ .separator = true },
        .{ .label = "Duplicate", .command = .duplicate, .enabled = has_selection },
        .{ .label = "Octave up", .command = .octave_up, .enabled = has_selection },
        .{ .label = "Octave down", .command = .octave_down, .enabled = has_selection },
        .{ .label = "Quantize", .command = .quantize, .enabled = has_selection },
        .{ .label = "Humanize", .command = .humanize, .enabled = has_selection },
        .{ .label = "Snap to scale", .command = .snap_to_scale, .enabled = has_selection and scaleActive() },
        .{ .label = "Delete", .command = .delete, .enabled = has_selection },
        .{ .separator = true },
        .{ .label = "Rename clip", .command = .rename },
        .{ .label = "Select all", .command = .select_all, .enabled = has_notes },
        .{ .label = "Clear selection", .command = .clear_selection, .enabled = has_selection },
    };
    result.command = menu.command(PR_CONTEXT_KEY, &pr_context_items);
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

    if (note_map.len > 0) {
        // Empty clip on a drum machine: zoom to the declared lanes.
        var lo: u8 = note_map[0].pitch;
        var hi: u8 = note_map[0].pitch;
        for (note_map) |*nl| {
            lo = @min(lo, nl.pitch);
            hi = @max(hi, nl.pitch);
        }
        const span = @as(f32, @floatFromInt(@as(u32, hi) - @as(u32, lo) + 5));
        row_h = std.math.clamp(grid.height / span, ROW_H_MIN, ROW_H_MAX);
        const center_pitch = (@as(f32, @floatFromInt(lo)) + @as(f32, @floatFromInt(hi))) / 2.0;
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

fn handleWheel(grid: c.rl.Rectangle, clip: Clip, m: pane.Mouse) void {
    if (!pane.contains(grid, m.x, m.y)) return;
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

// Local clip-beat → x. Local beat 0 is the clip start (absolute
// cur_clip_start), so the grid lines up with the project meter.
fn ceBeatToX(x0: f32, local_beat: f64) f32 {
    return x0 + @as(f32, @floatCast(local_beat)) * px_per_beat - scroll_x;
}

// Local clip-beat at the left edge of the grid (where x == x0).
fn ceFirstLocalBeat() f64 {
    if (scroll_x <= 0) return 0;
    return @as(f64, @floatCast(scroll_x)) / @as(f64, @floatCast(px_per_beat));
}






fn ipx(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

fn frect(x: f32, y: f32, w: f32, h: f32) Rect {
    const x0 = ipx(x);
    const y0 = ipx(y);
    return Rect.xywh(x0, y0, ipx(x + w) - x0, ipx(y + h) - y0);
}

fn frectRl(r: c.rl.Rectangle) Rect {
    return frect(r.x, r.y, r.width, r.height);
}

/// Ruler faceplate: snap sub-ticks, meter-driven beat/bar ticks and bar
/// numbers, aligned to the grid below (the part over the keyboard is blank
/// plate).
fn drawRuler(ui: *Ui, ruler: c.rl.Rectangle, grid: c.rl.Rectangle, edit_snap: snap_mod.Setting) void {
    const rr = bridge.fromRl(ruler);
    ui.clip(rr);
    defer ui.unclip();
    const body = ui.plate(rr, .{});
    const x0 = grid.x;
    const right = grid.x + grid.width - 2;
    const bot = body.bottom();

    // Fine sub-grid (uniform snap guide).
    const grid_step = snap_mod.visualStep(edit_snap, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = ceBeatToX(x0, beat);
        if (bx > right) break;
        if (bx >= grid.x) ui.rect(Rect.xywh(ipx(bx), bot - 2, 1, 2), ui_style.face_lo);
        beat += grid_step;
    }

    // Meter-driven bar lines + numbers and per-bar beat lines (absolute).
    const first_abs = cur_clip_start + ceFirstLocalBeat();
    var bar = cur_meter.beatToBarPos(first_abs).bar;
    while (true) {
        const seg = cur_meter.segmentForBar(bar);
        const unit = seg.unitBeats();
        const abs_start = cur_meter.barStartBeat(bar);
        const bsx = ceBeatToX(x0, abs_start - cur_clip_start);
        if (bsx > right) break;
        var k: u8 = 0;
        while (k < seg.numerator) : (k += 1) {
            const x = ceBeatToX(x0, abs_start + @as(f64, @floatFromInt(k)) * unit - cur_clip_start);
            if (x > right) break;
            if (x < grid.x) continue;
            const acc = seg.accentAt(k);
            const tick_h: i32 = switch (acc) {
                .downbeat => 7,
                .group => 5,
                .weak => 3,
            };
            ui.rect(Rect.xywh(ipx(x), bot - tick_h, 1, tick_h), if (acc == .weak) ui_style.text_mute else ui_style.text_dim);
        }
        if (bsx >= grid.x - 20 and bsx + 3 >= grid.x) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{bar + 1}) catch "?";
            _ = ui.engraved(&ui.fonts.legend, ipx(bsx) + 3, body.y, s, ui_style.text_dim);
        }
        bar += 1;
    }
}

/// Key column (hardware): white bed with black-key bars and octave labels
/// on the Cs; with a drum note map, labelled lanes on faceplate and unmapped
/// rows dark.
fn drawKeyboard(ui: *Ui, r: c.rl.Rectangle) void {
    const kr = bridge.fromRl(r);
    ui.clip(kr);
    defer ui.unclip();
    const drum = note_map.len > 0;
    ui.rect(kr, if (drum) ui_style.face_lo else ui_style.key_white);
    const bw = @divFloor(kr.w * 62, 100);
    const seam = ui_style.key_white.shade(-50);

    var pitch: u8 = KEY_HI;
    while (true) : (pitch -%= 1) {
        const fy = pitchTopY(r, pitch);
        if (fy + row_h >= r.y and fy <= r.y + r.height) {
            const y = ipx(fy);
            const h = ipx(fy + row_h) - y;
            if (drum) {
                if (mapLabel(pitch)) |label| {
                    const row = Rect.xywh(kr.x, y, kr.w, h);
                    ui.rect(row, ui_style.face);
                    ui.rect(Rect.xywh(kr.x, y + h - 1, kr.w, 1), ui_style.edge);
                    ui.textIn(&ui.fonts.legend, row.insetXY(3, 0), std.mem.span(label), ui_style.text_dim, .left, true);
                } else {
                    ui.rect(Rect.xywh(kr.x, y + h - 1, kr.w, 1), ui_style.edge);
                }
            } else if (isBlackKey(pitch)) {
                ui.rect(Rect.xywh(kr.x, y, bw, h), ui_style.key_black);
                ui.rect(Rect.xywh(kr.x, y, bw, 1), ui_style.key_black.shade(30));
                // White-key seam behind the black key's middle.
                ui.rect(Rect.xywh(kr.x + bw, y + @divFloor(h, 2), kr.w - bw, 1), seam);
            } else {
                const n = pitch % 12;
                // Adjacent white keys (E|F, B|C) meet on a row boundary.
                if (n == 4 or n == 11) ui.rect(Rect.xywh(kr.x, y, kr.w, 1), seam);
                if (n == 0) {
                    ui.rect(Rect.xywh(kr.x, y + h - 1, kr.w, 1), ui_style.key_white.shade(-70));
                    if (h >= 8) {
                        var buf: [8]u8 = undefined;
                        const octave = @as(i32, @intCast(pitch / 12)) - 1;
                        const s = std.fmt.bufPrint(&buf, "C{d}", .{octave}) catch "C";
                        ui.textIn(&ui.fonts.legend, Rect.xywh(kr.x, y, kr.w - 2, h), s, ui_style.text_mute.shade(-30), .right, false);
                    }
                }
            }
        }
        if (pitch == KEY_LO) break;
    }
    // Seam against the grid.
    ui.rect(Rect.xywh(kr.right() - 1, kr.y, 1, kr.h), ui_style.edge);
}

/// Note grid (flat glass): lit rows for white keys / in-scale / mapped
/// pitches, root rows a step brighter, octave lines under the Cs, then the
/// swung snap sub-grid and the meter's beat and bar lines.
fn drawGrid(ui: *Ui, r: c.rl.Rectangle, edit_snap: snap_mod.Setting) void {
    const gr = bridge.fromRl(r);
    ui.rect(gr, ui_style.pane);

    var pitch: u8 = KEY_HI;
    while (true) : (pitch -%= 1) {
        const fy = pitchTopY(r, pitch);
        if (fy + row_h >= r.y and fy <= r.y + r.height) {
            const y = ipx(fy);
            const h = ipx(fy + row_h) - y;
            const lit = if (note_map.len > 0)
                mapLabel(pitch) != null
            else if (scaleActive())
                inScale(pitch)
            else
                !isBlackKey(pitch);
            if (lit) ui.rect(Rect.xywh(gr.x, y, gr.w, h), if (isRootPitch(pitch)) ui_style.pane_alt.shade(8) else ui_style.pane_alt);
            if (pitch % 12 == 0) ui.rect(Rect.xywh(gr.x, y + h - 1, gr.w, 1), ui_style.grid_beat);
        }
        if (pitch == KEY_LO) break;
    }

    const right = r.x + r.width - 1;

    // Fine sub-grid (uniform, swing applied so off-beat lines match where
    // drawn/quantized notes land; applySwing no-ops on beats/bars).
    const grid_step = snap_mod.visualStep(edit_snap, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = ceBeatToX(r.x, applySwing(beat, edit_snap));
        if (bx > right) break;
        if (bx >= r.x) ui.rect(Rect.xywh(ipx(bx), gr.y, 1, gr.h), ui_style.grid_sub);
        beat += grid_step;
    }

    // Meter-driven bar and beat lines (absolute beats, no swing).
    const first_abs = cur_clip_start + ceFirstLocalBeat();
    var bar = cur_meter.beatToBarPos(first_abs).bar;
    while (true) {
        const seg = cur_meter.segmentForBar(bar);
        const unit = seg.unitBeats();
        const abs_start = cur_meter.barStartBeat(bar);
        if (ceBeatToX(r.x, abs_start - cur_clip_start) > right) break;
        var k: u8 = 0;
        while (k < seg.numerator) : (k += 1) {
            const x = ceBeatToX(r.x, abs_start + @as(f64, @floatFromInt(k)) * unit - cur_clip_start);
            if (x > right) break;
            if (x < r.x) continue;
            ui.rect(Rect.xywh(ipx(x), gr.y, 1, gr.h), if (seg.accentAt(k) == .weak) ui_style.grid_beat else ui_style.grid_bar);
        }
        bar += 1;
    }
}

/// Past the clip end the glass goes to chassis; the end itself is a red line.
fn drawClipEndOverlay(ui: *Ui, r: c.rl.Rectangle, clip: Clip) void {
    const end_x = r.x + @as(f32, @floatCast(clip.length_beats)) * px_per_beat - scroll_x;
    if (end_x >= r.x + r.width) return;
    const x0 = @max(end_x, r.x);
    ui.rect(frect(x0, r.y, r.x + r.width - x0, r.height), ui_style.chassis);
    if (end_x >= r.x) ui.rect(frect(end_x, r.y, 1, r.height), ui_style.rec);
}

/// Notes: dark rim, body brightness follows velocity, a lit top line;
/// amber outline when selected.
fn drawExistingNotes(ui: *Ui, grid: c.rl.Rectangle, clip: Clip, col: ui_style.Color) void {
    const rim = col.mix(ui_style.chassis, 0.55);
    for (clip.notes.items) |note| {
        const fr = noteRect(grid, note);
        if (fr.x + fr.width < grid.x or fr.x > grid.x + grid.width) continue;
        if (fr.y + fr.height < grid.y or fr.y > grid.y + grid.height) continue;
        const nr = frectRl(fr);
        const vel = @as(f32, @floatFromInt(note.velocity)) / 127.0;
        const fill = col.mix(ui_style.pane, 0.55 * (1 - vel));
        ui.rect(nr, rim);
        if (nr.w > 2 and nr.h > 2) {
            ui.rect(nr.inset(1), fill);
            ui.rect(Rect.xywh(nr.x + 1, nr.y + 1, nr.w - 2, 1), fill.mix(ui_style.text, 0.35));
        }
        if (note.selected) ui.bevel(nr, ui_style.accent, ui_style.accent);
    }
}

/// Velocity lane: a faceplate label tile under the keyboard, then a 3px
/// stem per note (height = velocity) with a lit cap over flat glass;
/// selected stems carry an amber cap.
fn drawVelocityLane(ui: *Ui, label_r: c.rl.Rectangle, r: c.rl.Rectangle, grid: c.rl.Rectangle, clip: Clip, col: ui_style.Color) void {
    const lr = ui.plate(bridge.fromRl(label_r), .{});
    _ = ui.engraved(&ui.fonts.legend, lr.x + 3, lr.y + 1, "VEL", ui_style.text_dim);
    const vr = bridge.fromRl(r);
    ui.rect(vr, ui_style.pane);
    ui.rect(Rect.xywh(vr.x, vr.y, vr.w, 1), ui_style.edge);
    ui.clip(vr);
    defer ui.unclip();

    const base_y = r.y + r.height - velBottomPad();
    const max_h = base_y - (r.y + velTopPad());
    ui.rect(frect(r.x, base_y, r.width, 1), ui_style.grid_bar);
    for (clip.notes.items) |note| {
        const nr = noteRect(grid, note);
        if (nr.x + nr.width < r.x or nr.x > r.x + r.width) continue;
        const bar_h = @max(2, (@as(f32, @floatFromInt(note.velocity)) / 127.0) * max_h);
        const stem = frect(nr.x, base_y - bar_h, 3, bar_h);
        ui.rect(stem, if (note.selected) col else col.mix(ui_style.pane, 0.5));
        ui.rect(Rect.xywh(stem.x, stem.y, 3, 2), if (note.selected) ui_style.accent else col);
    }
}

fn velTopPad() f32 {
    return 6;
}
fn velBottomPad() f32 {
    return 3;
}

fn handleVelocityLane(r: c.rl.Rectangle, grid: c.rl.Rectangle, clip: *Clip, m: pane.Mouse) bool {
    if (velocity_active) {
        if (!pane.isDraggingKey(VELOCITY_KEY) or !m.left_down) {
            velocity_active = false;
            velocity_drag_mode = .none;
            pane.cancelDrag();
            return true;
        }
        applyVelocityAt(r, clip, m.y);
        pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 3);
        return true;
    }

    if (!pane.contains(r, m.x, m.y)) return false;
    pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 1);
    if (!m.left_pressed or pane.hasActiveDrag()) return true;
    const idx = findVelocityBarAt(r, grid, clip.*, m.x) orelse return true;
    if (!pane.tryStartDrag(VELOCITY_KEY)) return true;
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
    const top = r.y + velTopPad();
    const bottom = r.y + r.height - velBottomPad();
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
        const bar = pane.rect(nr.x, r.y, @max(nr.width, 3), r.height);
        if (pane.contains(bar, x, r.y + r.height / 2)) return i;
    }
    return null;
}

fn drawBoxSelect(ui: *Ui, grid: c.rl.Rectangle, m: pane.Mouse) void {
    const x0 = @min(box_start_x, m.x);
    const y0 = @min(box_start_y, m.y);
    const x1 = @max(box_start_x, m.x);
    const y1 = @max(box_start_y, m.y);
    // Clip to grid.
    const cx0 = std.math.clamp(x0, grid.x, grid.x + grid.width);
    const cy0 = std.math.clamp(y0, grid.y, grid.y + grid.height);
    const cx1 = std.math.clamp(x1, grid.x, grid.x + grid.width);
    const cy1 = std.math.clamp(y1, grid.y, grid.y + grid.height);
    const rr = frect(cx0, cy0, cx1 - cx0, cy1 - cy0);
    ui.rect(rr, ui_style.accent.alpha(40));
    ui.bevel(rr, ui_style.accent, ui_style.accent);
}

fn pitchTopY(r: c.rl.Rectangle, pitch: u8) f32 {
    const pitch_row: i32 = @as(i32, @intCast(KEY_HI)) - @as(i32, @intCast(pitch));
    return r.y + @as(f32, @floatFromInt(pitch_row)) * row_h - scroll_y;
}

fn noteRect(grid: c.rl.Rectangle, note: Note) c.rl.Rectangle {
    const y = pitchTopY(grid, note.pitch);
    const x = grid.x + @as(f32, @floatCast(note.start_beat)) * px_per_beat - scroll_x;
    const w = @max(@as(f32, @floatCast(note.length_beats)) * px_per_beat, 2);
    return pane.rect(x, y + 1, w, row_h - 2);
}

// ── Input ────────────────────────────────────────────────────────────

fn handleInput(
    ui: *Ui,
    grid: c.rl.Rectangle,
    clip: *Clip,
    alloc: std.mem.Allocator,
    edit_snap: snap_mod.Setting,
    m: pane.Mouse,
) ?u8 {
    if (updateInProgressDrag(grid, clip, alloc, edit_snap, m)) return null;

    if (pane.contains(grid, m.x, m.y) and !pane.hasActiveDrag()) {
        if (findNoteAt(grid, clip.*, m.x, m.y)) |h| {
            pane.requestCursor(if (h.edge_resize) c.rl.MOUSE_CURSOR_RESIZE_EW else c.rl.MOUSE_CURSOR_POINTING_HAND, 1);
        }
    }

    if (!m.left_pressed and !m.right_pressed) return null;
    if (!pane.contains(grid, m.x, m.y)) return null;
    if (pane.hasActiveDrag()) return null;

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
        _ = menu.openContext(ui, PR_CONTEXT_KEY, bridge.fromRl(grid));
        return null;
    }

    const pitch = pitchAtY(grid, m.y) orelse return null;
    // Drawn notes land on the swung grid (matches the shifted off-beat lines).
    const beat = blk: {
        const snapped = snap_mod.snapDownPositive(edit_snap, beatAtX(grid, m.x), altBypassSnap());
        break :blk if (altBypassSnap()) snapped else applySwing(snapped, edit_snap);
    };
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
            if (!pane.tryStartDrag(DRAW_KEY)) return null;
            draw_active = true;
            draw_pitch = snapPitchToScale(pitch);
            draw_start_beat = beat;
            draw_current_beat = beat + defaultNoteBeats(edit_snap);
            draw_start_x = m.x;
        },
        .select => {
            if (!shift) clip.deselectAll();
            if (!pane.tryStartDrag(BOX_KEY)) return null;
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
        if (!pane.contains(nr, x, y)) continue;
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
    m: pane.Mouse,
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

fn updateDraw(grid: c.rl.Rectangle, clip: *Clip, alloc: std.mem.Allocator, edit_snap: snap_mod.Setting, m: pane.Mouse) void {
    if (!pane.isDraggingKey(DRAW_KEY) or !m.left_down) {
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
        pane.cancelDrag();
        return;
    }
    if (@abs(m.x - draw_start_x) >= BOX_MIN_DRAG) {
        draw_current_beat = snap_mod.snapPositive(edit_snap, beatAtX(grid, m.x), altBypassSnap());
    }
}

fn updateBox(grid: c.rl.Rectangle, clip: *Clip, m: pane.Mouse) void {
    if (!pane.isDraggingKey(BOX_KEY) or !m.left_down) {
        // Apply selection if we actually dragged.
        const dx = m.x - box_start_x;
        const dy = m.y - box_start_y;
        if (@abs(dx) >= BOX_MIN_DRAG or @abs(dy) >= BOX_MIN_DRAG) {
            const x0 = @min(box_start_x, m.x);
            const y0 = @min(box_start_y, m.y);
            const x1 = @max(box_start_x, m.x);
            const y1 = @max(box_start_y, m.y);
            const box_r = pane.rect(x0, y0, x1 - x0, y1 - y0);
            for (clip.notes.items) |*n| {
                const nr = noteRect(grid, n.*);
                if (rectsOverlap(nr, box_r)) n.selected = true;
            }
        }
        box_active = false;
        pane.cancelDrag();
    }
}

fn beginMove(alloc: std.mem.Allocator, clip: Clip, m: pane.Mouse) !void {
    if (!pane.tryStartDrag(MOVE_KEY)) return;
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
        pane.cancelDrag();
        return;
    }
    move_active = true;
    move_start_mouse_x = m.x;
    move_start_mouse_y = m.y;
}

fn updateMove(grid: c.rl.Rectangle, clip: *Clip, edit_snap: snap_mod.Setting, m: pane.Mouse) void {
    _ = grid;
    if (!pane.isDraggingKey(MOVE_KEY) or !m.left_down) {
        move_active = false;
        pane.cancelDrag();
        return;
    }
    pane.requestCursor(c.rl.MOUSE_CURSOR_POINTING_HAND, 3);
    const d_beats = snap_mod.snapNearest(edit_snap, @as(f64, (m.x - move_start_mouse_x) / px_per_beat), altBypassSnap());
    const d_rows = std.math.clamp(@as(i32, @intFromFloat(@round((m.y - move_start_mouse_y) / row_h))), -127, 127);
    for (move_snaps.items) |s| {
        if (s.idx >= clip.notes.items.len) continue;
        const n = &clip.notes.items[s.idx];
        const new_start = s.start_beat + d_beats;
        n.start_beat = if (new_start < 0) 0 else new_start;
        const new_pitch: i32 = @as(i32, @intCast(s.pitch)) - d_rows; // up = higher pitch
        n.pitch = snapPitchToScale(@intCast(std.math.clamp(new_pitch, 0, 127)));
    }
}

fn beginResize(alloc: std.mem.Allocator, clip: Clip, m: pane.Mouse) !void {
    if (!pane.tryStartDrag(RESIZE_KEY)) return;
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
        pane.cancelDrag();
        return;
    }
    resize_active = true;
    resize_start_mouse_x = m.x;
}

fn updateResize(grid: c.rl.Rectangle, clip: *Clip, edit_snap: snap_mod.Setting, m: pane.Mouse) void {
    _ = grid;
    if (!pane.isDraggingKey(RESIZE_KEY) or !m.left_down) {
        resize_active = false;
        pane.cancelDrag();
        return;
    }
    pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
    const d_beats = snap_mod.snapNearest(edit_snap, @as(f64, (m.x - resize_start_mouse_x) / px_per_beat), altBypassSnap());
    const min_len = resizeMinNoteBeats(edit_snap, altBypassSnap());
    for (resize_snaps.items) |s| {
        if (s.idx >= clip.notes.items.len) continue;
        const n = &clip.notes.items[s.idx];
        const new_len = s.length + d_beats;
        n.length_beats = if (new_len < min_len) min_len else new_len;
    }
}

// ── Vertical scrollbar (lazy) ────────────────────────────────────────

fn drawAndHandleScrollbar(ui: *Ui, grid: c.rl.Rectangle, m: pane.Mouse) void {
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
    const track = pane.rect(bar_x, grid.y, scrollbarW(), grid.height);
    ui.rect(frectRl(track), ui_style.chassis.alpha(@intFromFloat(alpha * 160)));

    const thumb_h = @max(16.0, (grid.height / content_h) * grid.height);
    const scroll_range = content_h - grid.height;
    const track_range = grid.height - thumb_h;
    const thumb_y = grid.y + (scroll_y / scroll_range) * track_range;
    const thumb = pane.rect(bar_x + 1, thumb_y, scrollbarW() - 2, thumb_h);

    const hover_thumb = pane.contains(thumb, m.x, m.y);
    const thumb_color = if (sb_drag or hover_thumb) ui_style.accent else ui_style.face_hi;
    ui.rect(frectRl(thumb), thumb_color.alpha(@intFromFloat(alpha * 255)));

    // ── Input ─────────────────────────────────────────────────────────
    if (sb_drag) {
        if (!pane.isDraggingKey(SB_KEY) or !m.left_down) {
            sb_drag = false;
            pane.cancelDrag();
            return;
        }
        const dy = m.y - sb_drag_start_mouse_y;
        scroll_y = sb_drag_start_scroll_y + dy * (scroll_range / track_range);
        last_scroll_time = now;
        return;
    }

    if (!m.left_pressed) return;
    if (pane.hasActiveDrag()) return;

    if (hover_thumb) {
        if (!pane.tryStartDrag(SB_KEY)) return;
        sb_drag = true;
        sb_drag_start_mouse_y = m.y;
        sb_drag_start_scroll_y = scroll_y;
    } else if (pane.contains(track, m.x, m.y)) {
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
    ui: *Ui,
    strip: c.rl.Rectangle,
    grid: c.rl.Rectangle,
    clip: Clip,
    track_color: ui_style.Color,
    m: pane.Mouse,
) void {
    if (strip.width <= 4 or strip.height <= 4 or grid.width <= 0 or grid.height <= 0) return;

    _ = ui.well(bridge.fromRl(strip), ui_style.well);
    const inner = pane.rect(strip.x + 2, strip.y + 2, strip.width - 4, strip.height - 4);

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
        ui.rect(frect(@max(n_x, inner.x), std.math.clamp(n_y, inner.y, inner.y + inner.height - 1), @min(n_w, inner.x + inner.width - n_x), 1), track_color);
    }

    // Viewport window — reflects grid's currently visible beat range.
    const view_beat_l = scroll_x / px_per_beat;
    const view_beat_r = (scroll_x + grid.width) / px_per_beat;
    const vp_x = inner.x + view_beat_l * px_per_beat_ov;
    const vp_w = @max(1.0, (view_beat_r - view_beat_l) * px_per_beat_ov);
    const vp_x_clamped = std.math.clamp(vp_x, inner.x, inner.x + inner.width);
    const vp_right = std.math.clamp(vp_x + vp_w, inner.x, inner.x + inner.width);
    const vp = pane.rect(vp_x_clamped, inner.y, vp_right - vp_x_clamped, inner.height);
    ui.rect(frectRl(vp), ui_style.accent.alpha(40));
    ui.bevel(frectRl(vp), ui_style.accent, ui_style.accent);

    handleOverviewInput(inner, grid, clip, m);
}

fn handleOverviewInput(
    inner: c.rl.Rectangle,
    grid: c.rl.Rectangle,
    clip: Clip,
    m: pane.Mouse,
) void {
    const clip_beats: f32 = @max(@as(f32, @floatCast(clip.length_beats)), 1.0);
    const px_per_beat_ov = inner.width / clip_beats;
    const view_beat_l = scroll_x / px_per_beat;
    const vp_x = inner.x + view_beat_l * px_per_beat_ov;
    const vp_w = @max(1.0, (grid.width / px_per_beat) * px_per_beat_ov);

    if (pane.contains(inner, m.x, m.y) and (m.wheel_x != 0 or m.wheel_y != 0)) {
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
        if (!pane.isDraggingKey(OVERVIEW_KEY) or !m.left_down) {
            overview_drag = false;
            pane.cancelDrag();
            return;
        }
        const want_vp_x = m.x - overview_drag_offset;
        const want_beat_l = (want_vp_x - inner.x) / px_per_beat_ov;
        scroll_x = want_beat_l * px_per_beat;
        if (scroll_x < 0) scroll_x = 0;
        return;
    }

    if (!m.left_pressed) return;
    if (!pane.contains(inner, m.x, m.y)) return;
    if (pane.hasActiveDrag()) return;

    const on_vp = m.x >= vp_x and m.x <= vp_x + vp_w;
    if (!pane.tryStartDrag(OVERVIEW_KEY)) return;
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

fn resizeMinNoteBeats(edit_snap: snap_mod.Setting, snap_bypassed: bool) f64 {
    if (snap_bypassed) return @min(minNoteBeats(edit_snap), MIN_FINE_NOTE_BEATS);
    return minNoteBeats(edit_snap);
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



fn rectsOverlap(a: c.rl.Rectangle, b: c.rl.Rectangle) bool {
    return !(a.x + a.width < b.x or b.x + b.width < a.x or
        a.y + a.height < b.y or b.y + b.height < a.y);
}

test "scale membership, root, and snap" {
    note_map = &.{};
    // C Major.
    key_root = 0;
    scale_idx = 1;
    try std.testing.expect(inScale(60)); // C
    try std.testing.expect(!inScale(61)); // C#
    try std.testing.expect(inScale(62)); // D
    try std.testing.expect(inScale(64)); // E
    try std.testing.expect(!inScale(66)); // F#
    try std.testing.expect(inScale(67)); // G
    try std.testing.expect(isRootPitch(72)); // C
    try std.testing.expect(!isRootPitch(74)); // D
    try std.testing.expect(inScale(snapPitchToScale(61))); // off-key snaps in-key
    // A natural minor (same notes as C major).
    key_root = 9;
    scale_idx = 2;
    try std.testing.expect(inScale(69)); // A
    try std.testing.expect(inScale(60)); // C
    try std.testing.expect(!inScale(61)); // C#
    // Off = chromatic, everything passes.
    scale_idx = 0;
    try std.testing.expect(inScale(61));
    // reset module state
    key_root = 0;
    scale_idx = 0;
}

test "swing delays off-beats on a fine grid only" {
    swing = 0.5;
    // 1/8 grid: off-beats (idx odd) shift; downbeats stay put.
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), applySwing(0.0, .note_8), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), applySwing(0.5, .note_8), 1e-9); // 0.5 + 0.5*0.5*0.5
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), applySwing(1.0, .note_8), 1e-9);
    // 1/4 grid is too coarse — no swing.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), applySwing(1.0, .note_4), 1e-9);
    // swing off → identity.
    swing = 0;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), applySwing(0.5, .note_8), 1e-9);
}

test "option resize can go below sixteenth" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), resizeMinNoteBeats(.note_16, false), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0625), resizeMinNoteBeats(.note_16, true), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0625), resizeMinNoteBeats(.note_64, true), 1e-9);
}
