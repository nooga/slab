//! Audio clip editor — the clip-editor pane's view for an *audio* clip (the
//! piano roll handles note clips). It mirrors the piano roll's navigation:
//! a beat ruler + grid, horizontal zoom (Shift+wheel) and pan, and a minimap
//! overview. The whole source waveform is drawn in the track color along a
//! beat axis (source seconds → beats at the project tempo, since playback is
//! unwarped). The played window's start/end and the fade-in/out are editable
//! with on-waveform handles, and the trimmed + faded regions are shaded.
//! A warped clip (docs/29) is drawn on its own content beats instead,
//! through its markers, and its edges trim in beats.

const std = @import("std");
const tempo_mod = @import("../tempo.zig");
const follow_mod = @import("follow.zig");
const c = @import("../c.zig");
const pane = @import("pane_input.zig");
const menu = @import("menu.zig");
const bridge = @import("bridge.zig");
const ui_core = @import("core.zig");
const ui_style = @import("style.zig");
const ctl = @import("controls.zig");
const surf = @import("surfaces.zig");
const Ui = ui_core.Ui;
const Rect = ui_core.Rect;
const snap_mod = @import("snap.zig");
const track_mod = @import("../track.zig");
const clip_mod = @import("../clip.zig");
const ClipRef = clip_mod.ClipRef;
const audio_pool_mod = @import("../audio_pool.zig");
const clip_editor = @import("clip_editor.zig");
const warp_mod = @import("../warp.zig");

const Result = clip_editor.Result;

const EDGE_SALT: u64 = 0xA0D0_C11E_ED17_0001;
const OV_KEY: u64 = 0xA0D0_0FE0_7A6C_0003;
const MIN_SEC: f64 = 0.01;
const MIN_WARP_BEATS: f64 = 1.0 / 16.0;
const MARK_H: f32 = 12;
const MARK_KEY: u64 = 0xA0D0_3A2C_0000_0005;
const MARK_MENU_KEY: u64 = 0xA0D0_3A2C_0000_0006;
const WARP_MENU_KEY: u64 = 0xA0D0_3A2C_0000_0007;
const MAX_GAIN: f64 = 2.0;
const PX_PER_BEAT_MAX: f32 = 400;

fn overviewH() f32 {
    return 16;
}
fn rulerH() f32 {
    return 16;
}
fn ctrlH() f32 {
    return 20;
}

// Beat-axis view state (persisted across frames, refit when the clip changes).
var px_per_beat: f32 = 48;
var scroll_x: f32 = 0;
var follow: follow_mod.Follow = .{};
var view_key: u64 = 0;
/// The axis beat the song's beat 0 falls on, so a warped clip's grid is the
/// song's bars (0 for an unwarped clip: its source's start).
var grid0: f64 = 0;

pub fn draw(
    ui: *Ui,
    r: c.rl.Rectangle,
    tracks: []track_mod.Track,
    pool: *const audio_pool_mod.AudioPool,
    alloc: std.mem.Allocator,
    selected: ?ClipRef,
    tmap: *const tempo_mod.TempoMap,
    edit_snap: snap_mod.Setting,
    play_beat: ?f64,
    m: pane.Mouse,
) Result {
    ui.pushId("audio-editor");
    defer ui.popId();
    const resolved_opt = resolveAudioClip(tracks, selected);
    const name = if (resolved_opt) |res| res.clip.name() else "";
    const color: ?ui_style.Color = if (resolved_opt) |res| ui_style.nearestTrack(.{ .r = res.color.r, .g = res.color.g, .b = res.color.b }) else null;
    const head = clip_editor.paneHead(ui, bridge.fromRl(r), "AUDIO", name, color, null, 0);
    var res = Result{ .minimize = head.minimize, .close = head.close, .rename_rect = bridge.toRl(head.title) };
    const body = bridge.toRl(head.body);

    const resolved = resolved_opt orelse {
        clip_editor.emptyBody(ui, head.body, "NO AUDIO CLIP SELECTED");
        return res;
    };
    const clip = resolved.clip;
    ui.pushId(clip);
    defer ui.popId();
    const track_color = ui_style.nearestTrack(.{ .r = resolved.color.r, .g = resolved.color.g, .b = resolved.color.b });
    const src = pool.get(clip.audio.source) orelse {
        clip_editor.emptyBody(ui, head.body, "MISSING AUDIO SOURCE");
        return res;
    };
    const source_sec = src.seconds();
    if (source_sec <= 0 or src.cache.sample_count == 0) {
        clip_editor.emptyBody(ui, head.body, "EMPTY AUDIO SOURCE");
        return res;
    }

    const rate = src.sample.sample_rate;
    // The editor's grid runs at the tempo where the clip starts.
    const sec_per_beat = 60.0 / tmap.bpmAt(clip.start_beat);
    // Warped: the axis is content beats from `axis0` (the source's start
    // or the clip's, whichever is first).
    const wmap: ?warp_mod.Map = if (clip.audio.warp and warp_mod.valid(clip.warp_markers.items)) .{ .m = clip.warp_markers.items } else null;
    const axis0: f64 = if (wmap) |wm| @min(wm.beatAt(0), clip.audio.offset_beats) else 0;
    const source_beats: f64 = if (wmap) |wm|
        @max(0.001, @max(wm.beatAt(source_sec), clip.audio.offset_beats + clip.length_beats) - axis0)
    else
        @max(0.001, source_sec / sec_per_beat);

    // ── Layout: overview · ruler · grid · control row ────────────────
    const ov_rect = pane.rect(body.x, body.y, body.width, overviewH());
    const ruler_rect = pane.rect(body.x, ov_rect.y + ov_rect.height, body.width, rulerH());
    const ctrl_rect = pane.rect(body.x, body.y + body.height - ctrlH(), body.width, ctrlH());
    // Warped: a strip for the markers under the ruler.
    const strip_h: f32 = if (wmap != null) MARK_H else 0;
    const strip = pane.rect(body.x, ruler_rect.y + ruler_rect.height, body.width, strip_h);
    const grid_y = strip.y + strip_h;
    const grid = pane.rect(body.x, grid_y, body.width, @max(8, ctrl_rect.y - grid_y));
    grid0 = if (wmap != null) clip.audio.offset_beats - clip.start_beat - axis0 else 0;

    // Refit zoom/scroll when the edited clip (or its source) changes.
    const key = @intFromPtr(clip) ^ (@as(u64, clip.audio.source) << 1);
    if (key != view_key) {
        view_key = key;
        px_per_beat = fitPx(grid, source_beats);
        scroll_x = 0;
        follow.reset();
    }
    handleWheel(grid, source_beats, m);
    clampView(grid, source_beats);

    // Conversions. A reversed clip shows its source mirrored, so the grid
    // reads left to right the way it plays: display seconds d = source_sec - s.
    const rev = clip.audio.reversed;
    const win_d0 = if (rev) source_sec - (clip.audio.start_sec + clip.audio.dur_sec) else clip.audio.start_sec;
    const win_d1 = win_d0 + clip.audio.dur_sec;
    const ws_b = if (wmap != null) clip.audio.offset_beats - axis0 else win_d0 / sec_per_beat;
    const we_b = if (wmap != null) ws_b + clip.length_beats else win_d1 / sec_per_beat;

    // Where the transport is in the source, while it plays inside the clip.
    const play_src_b: ?f64 = if (play_beat) |b| blk: {
        const local = b - clip.start_beat;
        if (local < 0 or local >= clip.length_beats) break :blk null;
        break :blk ws_b + (we_b - ws_b) * local / @max(0.001, clip.length_beats);
    } else null;
    follow.step(
        &scroll_x,
        if (play_src_b) |pb| @as(f32, @floatCast(pb)) * px_per_beat else null,
        grid.width,
        @max(0, @as(f32, @floatCast(source_beats)) * px_per_beat - grid.width),
        c.rl.GetFrameTime(),
        pane.hasActiveDrag() and pane.contains(r, m.x, m.y),
    );

    // ── Ruler ────────────────────────────────────────────────────────
    ui.clip(bridge.fromRl(ruler_rect));
    drawRulerTicks(ui, ruler_rect, grid);
    ui.unclip();

    // ── Grid + waveform ──────────────────────────────────────────────
    ui.rect(bridge.fromRl(grid), ui_style.pane);
    ui.clip(bridge.fromRl(grid));
    drawGridLines(ui, grid);

    // Waveform across the source's beat extent, clipped to the visible grid
    // so a long/zoomed clip doesn't walk thousands of off-screen columns.
    {
        const src_x0 = beatToX(grid, 0);
        const src_x1 = beatToX(grid, source_beats);
        const vx0 = @max(src_x0, grid.x);
        const vx1 = @min(src_x1, grid.x + grid.width);
        if (wmap) |wm| {
            var buf: [64]warp_mod.Map.Span = undefined;
            const bl = xToBeat(grid, vx0) + axis0;
            const br = xToBeat(grid, vx1) + axis0;
            for (wm.spans(bl, br, source_sec, &buf)) |sp| {
                const x0 = beatToX(grid, sp.b0 - axis0);
                const x1 = beatToX(grid, sp.b1 - axis0);
                if (x1 <= x0 + 1) continue;
                const wr = frect(x0, grid.y + 2, x1 - x0, grid.height - 4);
                if (rev)
                    surf.waveformLanes(ui, wr, src.waves(), (source_sec - sp.s1) * rate, (source_sec - sp.s0) * rate, track_color, true)
                else
                    surf.waveformLanes(ui, wr, src.waves(), sp.s0 * rate, sp.s1 * rate, track_color, false);
            }
        } else if (vx1 > vx0 + 1) {
            const bl = xToBeat(grid, vx0);
            const br = xToBeat(grid, vx1);
            const total: f64 = @floatFromInt(src.cache.sample_count);
            const d_l = std.math.clamp(bl * sec_per_beat * rate, 0, total);
            const d_r = std.math.clamp(br * sec_per_beat * rate, 0, total);
            const s_l = if (rev) total - d_r else d_l;
            const s_r = if (rev) total - d_l else d_r;
            surf.waveformLanes(ui, frect(vx0, grid.y + 2, vx1 - vx0, grid.height - 4), src.waves(), s_l, s_r, track_color, rev);
        }
    }

    // The source's transients (docs/29 §Transients), as ticks hanging
    // from the top: taller for stronger hits.
    if (src.analysis) |an| if (src.onsets()) |on| {
        for (on, an.onsets.strength) |s_fwd, strength| {
            const s = if (rev) source_sec - s_fwd else s_fwd;
            const b = if (wmap) |wm| wm.beatAt(s) - axis0 else s / sec_per_beat;
            const x = beatToX(grid, b);
            if (x < grid.x or x >= grid.x + grid.width) continue;
            const h: f32 = 4 + 8 * strength;
            ui.rect(frect(@floor(x), grid.y, 1, h), ui_style.text_dim);
        }
    };

    // Dim the trimmed-off regions (outside the played window).
    const dimcol = ui_style.chassis.alpha(160);
    const xs = beatToX(grid, ws_b);
    const xe = beatToX(grid, we_b);
    if (xs > grid.x) ui.rect(frect(grid.x, grid.y, @min(xs, grid.x + grid.width) - grid.x, grid.height), dimcol);
    if (xe < grid.x + grid.width) ui.rect(frect(@max(xe, grid.x), grid.y, grid.x + grid.width - @max(xe, grid.x), grid.height), dimcol);

    // Fade ramps + shaded (attenuated) wedges.
    const fi_b = @min(clip.audio.fade_in_sec / sec_per_beat, we_b - ws_b);
    const fo_b = @min(clip.audio.fade_out_sec / sec_per_beat, we_b - ws_b);
    const in_x = beatToX(grid, ws_b + fi_b);
    const out_x = beatToX(grid, we_b - fo_b);
    if (fi_b > 0) shadeFade(ui, grid, xs, in_x, true);
    if (fo_b > 0) shadeFade(ui, grid, out_x, xe, false);
    if (fi_b > 0) ui.line(xs, grid.y + grid.height, in_x, grid.y, ui_style.text_dim);
    if (fo_b > 0) ui.line(out_x, grid.y, xe, grid.y + grid.height, ui_style.text_dim);

    // ── Window edge handles (full height, below the fade strip) ──────
    if (wmap != null) {
        // Warped: the edges trim in content beats; the clip stays put.
        var b0 = ws_b;
        var b1 = we_b;
        if (edgeHandle(ui, clip, grid, xs, EDGE_SALT, 0, m)) |nx|
            b0 = std.math.clamp(beatAtX(grid, nx), 0, b1 - MIN_WARP_BEATS);
        if (edgeHandle(ui, clip, grid, xe, EDGE_SALT, 1, m)) |nx|
            b1 = @max(beatAtX(grid, nx), b0 + MIN_WARP_BEATS);
        if (b0 != ws_b or b1 != we_b) {
            clip.audio.offset_beats = axis0 + b0;
            clip.length_beats = b1 - b0;
        }
    }
    var s0 = win_d0;
    var s1 = win_d1;
    if (wmap == null) if (edgeHandle(ui, clip, grid, xs, EDGE_SALT, 0, m)) |nx| {
        s0 = std.math.clamp(beatAtX(grid, nx) * sec_per_beat, 0, s1 - MIN_SEC);
    };
    if (wmap == null) if (edgeHandle(ui, clip, grid, xe, EDGE_SALT, 1, m)) |nx| {
        s1 = std.math.clamp(beatAtX(grid, nx) * sec_per_beat, s0 + MIN_SEC, source_sec);
    };
    if (s0 != win_d0 or s1 != win_d1) {
        clip.audio.start_sec = if (rev) source_sec - s1 else s0;
        clip.audio.dur_sec = s1 - s0;
        clip.length_beats = @max(0.01, (s1 - s0) / sec_per_beat);
    }

    // ── Fade handles (top strip) ─────────────────────────────────────
    const dur = (we_b - ws_b) * sec_per_beat;
    if (fadeHandle(ui, clip, grid, in_x, EDGE_SALT, 2, m)) |nx| {
        const v = (beatAtX(grid, nx) - ws_b) * sec_per_beat;
        clip.audio.fade_in_sec = std.math.clamp(v, 0, dur);
    }
    if (fadeHandle(ui, clip, grid, out_x, EDGE_SALT, 3, m)) |nx| {
        const v = (we_b - beatAtX(grid, nx)) * sec_per_beat;
        clip.audio.fade_out_sec = std.math.clamp(v, 0, dur);
    }
    ui.unclip();

    // ── Warp markers (docs/29 §Editing) ──────────────────────────────
    if (wmap != null) warpEdit(ui, alloc, clip, src, grid, strip, axis0, .{ .xs = xs, .xe = xe, .in_x = in_x, .out_x = out_x }, edit_snap, m, &res);

    // The transport's position while it plays inside the clip, mapped
    // into the played window (ruler through grid).
    if (play_src_b) |pb| {
        const px = beatToX(grid, pb);
        if (px >= grid.x and px < grid.x + grid.width)
            ui.rect(frect(@floor(px), ruler_rect.y, 1, grid.y + grid.height - ruler_rect.y), ui_style.accent);
    }

    // ── Minimap overview ─────────────────────────────────────────────
    drawOverview(ui, ov_rect, grid, src, track_color, source_beats, rev, m);

    // ── Control row: gain slider + dot-matrix readout ────────────────
    var row = ui.plate(bridge.fromRl(ctrl_rect), .{});
    const lbl = row.cutLeft(34);
    ui.textIn(&ui.fonts.legend, lbl, "GAIN", ui_style.text_dim, .center, true);
    const gain_r = row.cutLeft(@min(140, @divFloor(row.w * 2, 5))).insetXY(0, @divFloor(row.h - 14, 2));
    var g: f32 = @floatCast(std.math.clamp(clip.audio.gain / MAX_GAIN, 0, 1));
    if (ctl.slider(ui, gain_r, "gain", &g, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 0, .default = @floatCast(1.0 / MAX_GAIN) })) {
        clip.audio.gain = @floatCast(g * MAX_GAIN);
    }
    menu.tip(ui, gain_r, "Clip gain (double-click for unity)");
    _ = row.cutLeft(6);
    const rev_r = row.cutLeft(40);
    var rev_on = rev;
    if (ctl.button(ui, rev_r, "rev", &rev_on, .{ .kind = .latch, .label = "REV", .led = ui_style.accent, .flush = true })) res.command = .reverse;
    menu.tip(ui, rev_r, "Play the clip backwards");
    _ = row.cutLeft(6);
    const warp_r = row.cutLeft(44);
    var warp_on = wmap != null;
    if (ctl.button(ui, warp_r, "warp", &warp_on, .{ .kind = .latch, .label = "WARP", .led = ui_style.accent, .flush = true })) res.command = .warp;
    menu.tip(ui, warp_r, "Lock the audio to the beat: it follows the tempo (\u{2318}-drag an edge in the arrangement to stretch)");
    _ = row.cutLeft(6);
    if (wmap != null and clip.audio.warp) warpTools(ui, &row, clip, alloc, src);
    var buf: [96]u8 = undefined;
    const info = if (wmap != null and clip.audio.warp) std.fmt.bufPrint(&buf, "{d} MARKERS  START {d:.2}  LEN {d:.2} BEATS  GAIN {d:.2}X", .{
        clip.warp_markers.items.len, clip.audio.offset_beats, clip.length_beats, clip.audio.gain,
    }) catch "" else std.fmt.bufPrint(&buf, "START {d:.2}S  LEN {d:.2}S  FADE {d:.2}/{d:.2}S  GAIN {d:.2}X", .{
        clip.audio.start_sec, clip.audio.dur_sec, clip.audio.fade_in_sec, clip.audio.fade_out_sec, clip.audio.gain,
    }) catch "";
    const disp_w = @min(row.w, @as(i32, @intCast(info.len)) * ctl.CELL_W + 4);
    if (disp_w > 8) ctl.display(ui, Rect.xywh(row.x, row.y + @divFloor(row.h - ctl.displayHeight(false), 2), disp_w, ctl.displayHeight(false)), info, .{});

    return res;
}

/// The warp mode, and BEATS' own settings (docs/29 §BEATS).
const MODES = [_][]const u8{ "TAPE", "BEATS", "MIX", "VOICE", "SMEAR" };
const MODE_OF = [_]warp_mod.Mode{ .tape, .beats, .mix, .voice, .smear };
const SIZES = [_][]const u8{ "0.3S", "0.7S", "1.4S", "2.7S" };
const PRESERVES = [_][]const u8{ "HITS", "1/16", "1/8", "1/4" };
const GAPS = [_][]const u8{ "CUT", "LOOP" };

fn warpTools(ui: *Ui, row: *Rect, clip: *clip_mod.Clip, alloc: std.mem.Allocator, src: *const audio_pool_mod.Source) void {
    const a = &clip.audio;
    // SEG BPM: the source's tempo under the clip's start. Drag to set it
    // (the audio fills more or fewer beats), double-click to detect it.
    if (warp_mod.valid(clip.warp_markers.items)) {
        const br = row.cutLeft(64);
        const wid = ui.id("bpm");
        const bh = ui.behavior(wid, br, false);
        const now = warp_mod.Map.init(clip.warp_markers.items).bpmAt(a.offset_beats);
        if (bh.double) {
            if (src.hits()) |h| _ = warp_mod.detectAndFit(alloc, clip, h, src.seconds()) catch false;
        } else if (bh.held and ui.in.dy != 0) {
            const fine = ui.in.shift;
            const v = now - ui.in.dy * ui.renderer.zoom * @as(f32, if (fine) 0.01 else 0.1);
            warp_mod.setTempo(clip, std.math.clamp(@round(v * 100) / 100, 20, 999));
        }
        var buf: [16]u8 = undefined;
        const shown = warp_mod.Map.init(clip.warp_markers.items).bpmAt(a.offset_beats);
        const txt = std.fmt.bufPrint(&buf, "{d:.2}", .{shown}) catch "";
        ctl.display(ui, br.insetXY(0, @divFloor(br.h - ctl.displayHeight(false), 2)), txt, .{ .align_ = .right, .flush = true, .color = if (ui.active == wid) ui_style.vfd_hi else ui_style.vfd });
        if (ui.isHot(wid)) ui.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 1);
        menu.tip(ui, br, "SEG BPM: the tempo the audio was played in; drag (shift: finer), double-click to detect");
        _ = row.cutLeft(4);
    }
    const sel = struct {
        fn one(u: *Ui, rw: *Rect, w: i32, key: []const u8, v: *u8, opts: []const []const u8, tip: []const u8) void {
            const r = rw.cutLeft(w);
            _ = ctl.displaySelectEx(u, r.insetXY(0, @divFloor(r.h - ctl.displayHeight(false), 2)), key, v, opts, "", .{ .align_ = .left });
            menu.tip(u, r, tip);
            _ = rw.cutLeft(4);
        }
    };
    var mode: u8 = @intCast(std.mem.indexOfScalar(warp_mod.Mode, &MODE_OF, a.mode) orelse 0);
    sel.one(ui, row, 56, "mode", &mode, &MODES, "TAPE: speed and pitch together. BEATS: cut at the hits, for drums. MIX: keeps pitch, for anything. VOICE: one note at a time, no phasing. SMEAR: extreme stretch into texture");
    a.mode = MODE_OF[mode];
    if (a.mode == .tape) return;
    // TRANSPOSE and FINE drag: up for higher, double-click for 0.
    dragNum(ui, row, "transpose", &a.transpose, -48, 48, 0.1, "ST", "Transpose in semitones, apart from time; double-click 0");
    dragNum(ui, row, "fine", &a.fine, -50, 50, 0.25, "CT", "Fine tune in cents; double-click 0");
    _ = row.cutLeft(4);
    if (a.mode == .voice) {
        dragNum(ui, row, "grain", &a.grain_ms, 10, 80, 0.25, "MS", "Grain: shorter for high voices, longer for low ones; double-click 40");
        if (a.grain_ms == 0) a.grain_ms = 40;
        return;
    }
    if (a.mode == .smear) {
        sel.one(ui, row, 48, "size", &a.smear_size, &SIZES, "Window: longer smears more");
        return;
    }
    if (a.mode != .beats) return;
    var p: u8 = @intFromEnum(a.preserve);
    sel.one(ui, row, 48, "preserve", &p, &PRESERVES, "Where BEATS cuts: at the hits, or every 1/16, 1/8, 1/4");
    a.preserve = @enumFromInt(p);
    var g: u8 = @intFromEnum(a.gap);
    sel.one(ui, row, 48, "gap", &g, &GAPS, "When a slice runs out before the next: CUT to silence, or LOOP its tail");
    a.gap = @enumFromInt(g);
    // DECAY drags like the groove's AMOUNT: up for more.
    const dr = row.cutLeft(48);
    const wid = ui.id("decay");
    const b = ui.behavior(wid, dr, false);
    if (b.double) a.decay = 100 else if (b.held) {
        const v = @as(f32, @floatFromInt(a.decay)) - ui.in.dy * ui.renderer.zoom * 0.5;
        a.decay = @intFromFloat(std.math.clamp(@round(v), 1, 100));
    }
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}%", .{a.decay}) catch "";
    ctl.display(ui, dr.insetXY(0, @divFloor(dr.h - ctl.displayHeight(false), 2)), s, .{ .align_ = .right, .flush = true, .color = if (ui.active == wid) ui_style.vfd_hi else ui_style.vfd });
    if (ui.isHot(wid)) ui.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 1);
    menu.tip(ui, dr, "Decay: how much of each slice sounds before it fades; drag, double-click 100%");
    _ = row.cutLeft(6);
}

/// A number dragged up and down; double-click resets it (to 0, which
/// the caller may map to its own default).
fn dragNum(ui: *Ui, row: *Rect, key: []const u8, v: anytype, lo: @TypeOf(v.*), hi: @TypeOf(v.*), per_px: f32, unit: []const u8, tip: []const u8) void {
    const r = row.cutLeft(48);
    const wid = ui.id(key);
    const b = ui.behavior(wid, r, false);
    if (b.double) v.* = 0 else if (b.held) {
        drag_acc += -ui.in.dy * ui.renderer.zoom * per_px;
        const whole = @trunc(drag_acc);
        if (whole != 0) {
            drag_acc -= whole;
            v.* = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(v.*)) + whole, @as(f32, @floatFromInt(lo)), @as(f32, @floatFromInt(hi))));
        }
    }
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}{d}{s}", .{ if (lo < 0 and v.* > 0) "+" else "", v.*, unit }) catch "";
    ctl.display(ui, r.insetXY(0, @divFloor(r.h - ctl.displayHeight(false), 2)), s, .{ .align_ = .right, .flush = true, .color = if (ui.active == wid) ui_style.vfd_hi else ui_style.vfd });
    if (ui.isHot(wid)) ui.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 1);
    menu.tip(ui, r, tip);
    _ = row.cutLeft(2);
}

/// Sub-step drag motion carried between frames.
var drag_acc: f32 = 0;

// ── Warp markers ─────────────────────────────────────────────────────

/// Where the window's handles are, so markers and hits leave them be.
const Handles = struct { xs: f32, xe: f32, in_x: f32, out_x: f32 };

const MarkDrag = struct {
    /// Which marker: its source second (stable while it moves on the beat
    /// axis; updated when it slides).
    sec: f64,
    slide: bool,
    mx: f32,
    beat: f64,
};
var mark_drag: ?MarkDrag = null;
/// The marker a right-click picked, by its source second.
var menu_sec: f64 = 0;
var menu_beat: f64 = 0;

fn markerIndex(clip: *const clip_mod.Clip, sec: f64) ?usize {
    for (clip.warp_markers.items, 0..) |mk, i| if (mk.sec == sec) return i;
    return null;
}

/// Content beat `cb` on the song's grid, unless ⌥ or the grid is off.
fn snapContent(clip: *const clip_mod.Clip, cb: f64, edit_snap: snap_mod.Setting) f64 {
    const div = edit_snap.beats() orelse return cb;
    if (c.rl.IsKeyDown(c.rl.KEY_LEFT_ALT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_ALT)) return cb;
    const song0 = clip.start_beat - clip.audio.offset_beats;
    return @round((song0 + cb) / div) * div - song0;
}

/// The strip above the waveform holds the markers: drag one along the
/// beats (the audio around it stretches), ⌘-drag to slide the audio under
/// it, double-click the strip to add one, right-click for more. A hit in
/// the waveform can be dragged too: it becomes a marker.
fn warpEdit(ui: *Ui, alloc: std.mem.Allocator, clip: *clip_mod.Clip, src: *const audio_pool_mod.Source, grid: c.rl.Rectangle, strip: c.rl.Rectangle, axis0: f64, hd: Handles, edit_snap: snap_mod.Setting, m: pane.Mouse, res: *Result) void {
    const source_sec = src.seconds();
    const rev = clip.audio.reversed;
    const cmd = c.rl.IsKeyDown(c.rl.KEY_LEFT_SUPER) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SUPER);
    const key = pane.keyFromIds(MARK_KEY, @intFromPtr(clip), 0);

    // ── Dragging ──
    if (mark_drag) |*d| {
        if (!pane.isDraggingKey(key) or !m.left_down) {
            if (pane.isDraggingKey(key)) pane.cancelDrag();
            mark_drag = null;
        } else if (markerIndex(clip, d.sec)) |i| {
            pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
            const db = @as(f64, (m.x - d.mx) / px_per_beat);
            if (d.slide) {
                // The audio moves with the pointer; the marker keeps its beat.
                const map = warp_mod.Map.init(clip.warp_markers.items);
                const slope = map.slope(@min(i, clip.warp_markers.items.len - 2));
                const target = d.sec - db * slope;
                d.mx = m.x;
                warp_mod.slideMarker(clip, i, target);
                d.sec = clip.warp_markers.items[i].sec;
            } else {
                warp_mod.moveMarker(clip, i, snapContent(clip, d.beat + db, edit_snap));
            }
        } else mark_drag = null;
    }

    // ── The strip ──
    ui.rect(bridge.fromRl(strip), ui_style.well);
    const in_strip = pane.contains(strip, m.x, m.y);
    var hot: ?usize = null;
    var hot_d: f32 = 5;
    for (clip.warp_markers.items, 0..) |mk, i| {
        const x = beatToX(grid, mk.beat - axis0);
        if (in_strip and @abs(m.x - x) < hot_d) {
            hot_d = @abs(m.x - x);
            hot = i;
        }
    }
    for (clip.warp_markers.items, 0..) |mk, i| {
        const x = beatToX(grid, mk.beat - axis0);
        if (x < grid.x - 4 or x > grid.x + grid.width + 4) continue;
        const lit = (hot != null and hot.? == i) or (mark_drag != null and mark_drag.?.sec == mk.sec);
        const col = if (lit) ui_style.text else ui_style.text_dim;
        ui.rect(frect(@floor(x) - 2, strip.y + 2, 5, strip.height - 4), col);
        ui.rect(frect(@floor(x), grid.y, 1, grid.height), col.alpha(if (lit) 200 else 90));
    }
    if (hot != null) pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);

    // A hit under the pointer in the waveform, away from the handles.
    var hit_sec: ?f64 = null;
    const near_handle = @abs(m.x - hd.xs) <= 6 or @abs(m.x - hd.xe) <= 6 or (m.y < grid.y + 10 and (@abs(m.x - hd.in_x) <= 6 or @abs(m.x - hd.out_x) <= 6));
    if (mark_drag == null and !near_handle and pane.contains(grid, m.x, m.y) and !pane.hasActiveDrag()) {
        if (src.onsets()) |on| {
            const map = warp_mod.Map.init(clip.warp_markers.items);
            var best: f32 = 4;
            for (on) |s_fwd| {
                const s = if (rev) source_sec - s_fwd else s_fwd;
                const x = beatToX(grid, map.beatAt(s) - axis0);
                if (@abs(m.x - x) < best) {
                    best = @abs(m.x - x);
                    hit_sec = s;
                }
            }
        }
        if (hit_sec) |hs| {
            const x = beatToX(grid, warp_mod.Map.init(clip.warp_markers.items).beatAt(hs) - axis0);
            ui.rect(frect(@floor(x), grid.y, 1, grid.height), ui_style.text.alpha(120));
            pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);
        }
    }

    // ── Presses ──
    if (m.left_pressed and mark_drag == null and !pane.hasActiveDrag()) {
        if (hot) |i| {
            if (pane.tryStartDrag(key)) mark_drag = .{ .sec = clip.warp_markers.items[i].sec, .slide = cmd, .mx = m.x, .beat = clip.warp_markers.items[i].beat };
        } else if (hit_sec) |hs| {
            if (warp_mod.addMarkerAt(alloc, clip, hs) catch null) |i| if (pane.tryStartDrag(key)) {
                mark_drag = .{ .sec = clip.warp_markers.items[i].sec, .slide = cmd, .mx = m.x, .beat = clip.warp_markers.items[i].beat };
            };
        }
    }
    if (m.double_clicked and in_strip and hot == null) {
        const cb = snapContent(clip, xToBeat(grid, m.x) + axis0, edit_snap);
        _ = warp_mod.addMarker(alloc, clip, cb) catch null;
    }

    // ── Menus ──
    if (m.right_pressed and in_strip and hot != null) {
        menu_sec = clip.warp_markers.items[hot.?].sec;
        menu.openAt(MARK_MENU_KEY, ui.in.ix(), ui.in.iy());
    } else if (pane.contains(grid, m.x, m.y)) {
        if (menu.openContext(ui, WARP_MENU_KEY, bridge.fromRl(grid))) menu_beat = xToBeat(grid, m.x) + axis0;
    }
    const n = clip.warp_markers.items.len;
    const mk_items = [_]menu.Item{
        .{ .label = "Remove marker", .id = 1, .enabled = n > 2 },
        .{ .label = "Warp straight from here", .id = 2 },
        .{ .label = "Start the clip here", .id = 3 },
    };
    if (menu.pick(MARK_MENU_KEY, &mk_items)) |id| if (markerIndex(clip, menu_sec)) |i| switch (id) {
        1 => warp_mod.removeMarker(clip, i),
        2 => warp_mod.straightFrom(clip, i),
        3 => {
            const b = clip.warp_markers.items[i].beat;
            const end = clip.audio.offset_beats + clip.length_beats;
            if (b < end - MIN_WARP_BEATS) {
                clip.audio.offset_beats = b;
                clip.length_beats = end - b;
            }
        },
        else => {},
    };
    const has_hits = src.hits() != null;
    const w_items = [_]menu.Item{
        .{ .label = "Detect tempo", .id = 1, .enabled = has_hits and !rev },
        .{ .label = "Follow its beats (a take that drifts)", .id = 7, .enabled = has_hits and !rev },
        .{ .label = "Tempo \u{00D7}2", .id = 2 },
        .{ .label = "Tempo \u{00F7}2", .id = 3 },
        .{ .separator = true },
        .{ .label = "Add marker here", .id = 4 },
        .{ .label = "Quantize hits to grid", .id = 5, .enabled = has_hits and edit_snap.beats() != null },
        .{ .label = "Clear warp markers", .id = 6, .enabled = n > 2 },
        .{ .separator = true },
        .{ .label = "Extract groove", .id = 8, .enabled = has_hits and !rev },
        .{ .label = "Song follows this clip", .id = 9 },
    };
    if (menu.pick(WARP_MENU_KEY, &w_items)) |id| {
        const map = warp_mod.Map.init(clip.warp_markers.items);
        const bpm = map.bpmAt(clip.audio.offset_beats);
        switch (id) {
            1 => if (src.hits()) |h| {
                _ = warp_mod.detectAndFit(alloc, clip, h, source_sec) catch false;
            },
            2 => warp_mod.setTempo(clip, bpm * 2),
            3 => warp_mod.setTempo(clip, bpm / 2),
            4 => _ = warp_mod.addMarker(alloc, clip, snapContent(clip, menu_beat, edit_snap)) catch null,
            5 => if (src.hits()) |h| {
                // Reversed, the hits are mirrored in the clip's source.
                if (!rev) warp_mod.quantize(alloc, clip, h.sec, h.strength, 0.1, edit_snap.beats().?, clip.start_beat - clip.audio.offset_beats, 1) catch {};
            },
            6 => warp_mod.clearMarkers(alloc, clip) catch {},
            7 => if (src.hits()) |h| {
                _ = warp_mod.detectAndFollow(alloc, clip, h, source_sec) catch false;
            },
            8 => res.command = .extract_groove,
            9 => res.command = .song_follows_clip,
            else => {},
        }
    }
}

// ── Axis helpers ─────────────────────────────────────────────────────

fn beatToX(grid: c.rl.Rectangle, beat: f64) f32 {
    return grid.x + @as(f32, @floatCast(beat)) * px_per_beat - scroll_x;
}
fn xToBeat(grid: c.rl.Rectangle, x: f32) f64 {
    return @as(f64, (x - grid.x + scroll_x) / px_per_beat);
}
fn beatAtX(grid: c.rl.Rectangle, x: f32) f64 {
    return @max(0, xToBeat(grid, x));
}

fn fitPx(grid: c.rl.Rectangle, source_beats: f64) f32 {
    return @max(2.0, grid.width / @as(f32, @floatCast(@max(0.001, source_beats))));
}

fn clampView(grid: c.rl.Rectangle, source_beats: f64) void {
    const min_px = fitPx(grid, source_beats);
    px_per_beat = std.math.clamp(px_per_beat, min_px, @max(min_px, PX_PER_BEAT_MAX));
    const content_w = @as(f32, @floatCast(source_beats)) * px_per_beat;
    const max_sx = @max(0, content_w - grid.width);
    scroll_x = std.math.clamp(scroll_x, 0, max_sx);
}

fn handleWheel(grid: c.rl.Rectangle, source_beats: f64, m: pane.Mouse) void {
    if (!pane.contains(grid, m.x, m.y)) return;
    if (m.wheel_x == 0 and m.wheel_y == 0) return;
    const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
    if (shift) {
        const w: f32 = if (m.wheel_y != 0) m.wheel_y else m.wheel_x;
        if (w != 0) {
            const mouse_beat = (m.x - grid.x + scroll_x) / px_per_beat;
            const factor: f32 = std.math.clamp(1.0 + w * 0.12, 0.5, 2.0);
            const min_px = fitPx(grid, source_beats);
            px_per_beat = std.math.clamp(px_per_beat * factor, min_px, @max(min_px, PX_PER_BEAT_MAX));
            scroll_x = mouse_beat * px_per_beat - (m.x - grid.x);
        }
    } else {
        scroll_x -= (if (m.wheel_x != 0) m.wheel_x else m.wheel_y) * 30;
    }
}

// ── Drawing ──────────────────────────────────────────────────────────

fn ipx(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

fn frect(x: f32, y: f32, w: f32, h: f32) Rect {
    const x0 = ipx(x);
    const y0 = ipx(y);
    return Rect.xywh(x0, y0, ipx(x + w) - x0, ipx(y + h) - y0);
}

/// Ruler faceplate: sixteenth / beat / bar ticks and bar numbers.
fn drawRulerTicks(ui: *Ui, ruler: c.rl.Rectangle, grid: c.rl.Rectangle) void {
    const body = ui.plate(bridge.fromRl(ruler), .{});
    const bot = body.bottom();
    const step = snap_mod.visualStep(.note_16, px_per_beat);
    var beat: f64 = grid0 - @ceil(grid0 / 4) * 4;
    while (true) {
        const bx = beatToX(grid, beat);
        if (bx > ruler.x + ruler.width - 2) break;
        if (bx >= ruler.x - 4) {
            const is_bar = snap_mod.isBar(beat - grid0);
            const is_beat = snap_mod.isBeat(beat - grid0);
            const th: i32 = if (is_bar) 7 else if (is_beat) 4 else 2;
            ui.rect(Rect.xywh(ipx(bx), bot - th, 1, th), if (is_bar) ui_style.text_dim else if (is_beat) ui_style.text_mute else ui_style.face_lo);
            if (is_bar and beat - grid0 > -0.5) {
                var b: [8]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "{d}", .{@as(u32, @intFromFloat(@round((beat - grid0) / 4.0))) + 1}) catch "?";
                _ = ui.engraved(&ui.fonts.legend, ipx(bx) + 3, body.y, s, ui_style.text_dim);
            }
        }
        beat += step;
    }
}

fn drawGridLines(ui: *Ui, grid: c.rl.Rectangle) void {
    const step = snap_mod.visualStep(.note_16, px_per_beat);
    const gy = ipx(grid.y);
    const gh = ipx(grid.height);
    var beat: f64 = grid0 - @ceil(grid0 / 4) * 4;
    while (true) {
        const bx = beatToX(grid, beat);
        if (bx > grid.x + grid.width - 1) break;
        if (bx >= grid.x) {
            const is_bar = snap_mod.isBar(beat - grid0);
            const is_beat = snap_mod.isBeat(beat - grid0);
            ui.rect(Rect.xywh(ipx(bx), gy, 1, gh), if (is_bar) ui_style.grid_bar else if (is_beat) ui_style.grid_beat else ui_style.grid_sub);
        }
        beat += step;
    }
}

/// Shade the attenuated wedge of a fade as per-column bars (a filled
/// triangle, no AA). For a fade-in the shading is tall at the left (silent)
/// edge and shrinks to nothing; mirrored for a fade-out.
fn shadeFade(ui: *Ui, grid: c.rl.Rectangle, x0: f32, x1: f32, fade_in: bool) void {
    const lo = @max(@min(x0, x1), grid.x);
    const hi = @min(@max(x0, x1), grid.x + grid.width);
    const span = x1 - x0;
    if (hi <= lo or @abs(span) < 1) return;
    const col = ui_style.chassis.alpha(128);
    var x = @floor(lo);
    while (x < hi) : (x += 1) {
        const p = std.math.clamp((x - x0) / span, 0, 1); // 0 at x0 → 1 at x1
        const atten: f32 = if (fade_in) 1 - p else p;
        const h = grid.height * atten;
        if (h >= 1) ui.rect(frect(x, grid.y, 1, h), col);
    }
}

fn drawOverview(ui: *Ui, strip: c.rl.Rectangle, grid: c.rl.Rectangle, src: *const audio_pool_mod.Source, track_color: ui_style.Color, source_beats: f64, rev: bool, m: pane.Mouse) void {
    const inner_r = ui.well(bridge.fromRl(strip), ui_style.well);
    if (inner_r.w < 2 or inner_r.h < 2) return;
    const inner = bridge.toRl(inner_r);
    surf.waveformDir(ui, inner_r, &src.cache, 0, @floatFromInt(src.cache.sample_count), track_color.mix(ui_style.well, 0.35), rev);

    // Viewport window.
    const content_w = @as(f32, @floatCast(source_beats)) * px_per_beat;
    if (content_w <= 0) return;
    const vx = inner.x + (scroll_x / content_w) * inner.width;
    const vw = @max(2.0, (grid.width / content_w) * inner.width);
    const vp = frect(std.math.clamp(vx, inner.x, inner.x + inner.width), inner.y, @min(vw, inner.x + inner.width - vx), inner.height);
    ui.rect(vp, ui_style.accent.alpha(40));
    ui.bevel(vp, ui_style.accent, ui_style.accent);

    // Click / drag to centre the viewport on the cursor.
    if (pane.contains(strip, m.x, m.y) and m.left_down) {
        const frac = std.math.clamp((m.x - inner.x) / inner.width, 0, 1);
        scroll_x = frac * content_w - grid.width / 2;
    }
}

// ── Handles ──────────────────────────────────────────────────────────

const EDGE_GRAB: f32 = 4;
const FADE_STRIP: f32 = 9;
const FADE_BOX: f32 = 7;

/// Window edge: a full-height green line with a tab on top; 2px while hot.
fn edgeHandle(ui: *Ui, clip: *clip_mod.Clip, area: c.rl.Rectangle, x: f32, salt: u64, id: u64, m: pane.Mouse) ?f32 {
    const key = pane.keyFromIds(salt, @intFromPtr(clip), id);
    const dragging = pane.isDraggingKey(key);
    // Reserve the top strip for fade handles sitting on the same x.
    const hot = pane.contains(area, m.x, m.y) and @abs(m.x - x) <= EDGE_GRAB and m.y > area.y + FADE_STRIP;
    var out: ?f32 = null;
    if (dragging) {
        if (m.left_down) out = std.math.clamp(m.x, area.x, area.x + area.width) else pane.cancelDrag();
    } else if (hot and m.left_pressed and !pane.hasActiveDrag()) {
        _ = pane.tryStartDrag(key);
    }
    if (hot or dragging) pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);
    const lw: f32 = if (hot or dragging) 2 else 1;
    ui.rect(frect(x, area.y, lw, area.height), ui_style.play);
    ui.rect(frect(x - 3, area.y, 7, 4), ui_style.play);
    return out;
}

/// Fade handle: a small square on the fade's knee, in the top strip.
fn fadeHandle(ui: *Ui, clip: *clip_mod.Clip, area: c.rl.Rectangle, x: f32, salt: u64, id: u64, m: pane.Mouse) ?f32 {
    const box = pane.rect(x - @floor(FADE_BOX / 2), area.y, FADE_BOX, FADE_BOX);
    const key = pane.keyFromIds(salt, @intFromPtr(clip), id);
    const dragging = pane.isDraggingKey(key);
    const hot = pane.contains(box, m.x, m.y);
    var out: ?f32 = null;
    if (dragging) {
        if (m.left_down) out = std.math.clamp(m.x, area.x, area.x + area.width) else pane.cancelDrag();
    } else if (hot and m.left_pressed and !pane.hasActiveDrag()) {
        _ = pane.tryStartDrag(key);
    }
    if (hot or dragging) pane.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
    const br = frect(box.x, box.y, box.width, box.height);
    ui.rect(br, ui_style.edge);
    ui.rect(br.inset(1), if (hot or dragging) ui_style.text else ui_style.text_dim);
    return out;
}

// ── Resolve / title ──────────────────────────────────────────────────

const Resolved = struct { clip: *clip_mod.Clip, color: c.rl.Color };

fn resolveAudioClip(tracks: []track_mod.Track, selected: ?ClipRef) ?Resolved {
    const s = selected orelse return null;
    if (s.track >= tracks.len) return null;
    const t = &tracks[s.track];
    if (s.clip >= t.clips.items.len) return null;
    const clip = &t.clips.items[s.clip];
    if (!clip.isAudio()) return null;
    return .{ .clip = clip, .color = t.color };
}
