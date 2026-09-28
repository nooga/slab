//! Audio clip editor — the clip-editor pane's view for an *audio* clip (the
//! piano roll handles note clips). It mirrors the piano roll's navigation:
//! a beat ruler + grid, horizontal zoom (Shift+wheel) and pan, and a minimap
//! overview. The whole source waveform is drawn in the track colour along a
//! beat axis (source seconds → beats at the project tempo, since playback is
//! unwarped). The played window's start/end and the fade-in/out are editable
//! with on-waveform handles, and the trimmed + faded regions are shaded.

const std = @import("std");
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

const Result = clip_editor.Result;

const EDGE_SALT: u64 = 0xA0D0_C11E_ED17_0001;
const OV_KEY: u64 = 0xA0D0_0FE0_7A6C_0003;
const MIN_SEC: f64 = 0.01;
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
var view_key: u64 = 0;

pub fn draw(
    ui: *Ui,
    r: c.rl.Rectangle,
    tracks: []track_mod.Track,
    pool: *const audio_pool_mod.AudioPool,
    selected: ?ClipRef,
    bpm: f64,
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
    const sec_per_beat = 60.0 / @max(1.0, bpm);
    const source_beats: f64 = @max(0.001, source_sec / sec_per_beat);

    // ── Layout: overview · ruler · grid · control row ────────────────
    const ov_rect = pane.rect(body.x, body.y, body.width, overviewH());
    const ruler_rect = pane.rect(body.x, ov_rect.y + ov_rect.height, body.width, rulerH());
    const ctrl_rect = pane.rect(body.x, body.y + body.height - ctrlH(), body.width, ctrlH());
    const grid = pane.rect(body.x, ruler_rect.y + ruler_rect.height, body.width, @max(8, ctrl_rect.y - (ruler_rect.y + ruler_rect.height)));

    // Refit zoom/scroll when the edited clip (or its source) changes.
    const key = @intFromPtr(clip) ^ (@as(u64, clip.audio.source) << 1);
    if (key != view_key) {
        view_key = key;
        px_per_beat = fitPx(grid, source_beats);
        scroll_x = 0;
    }
    handleWheel(grid, source_beats, m);
    clampView(grid, source_beats);

    // Conversions. A reversed clip shows its source mirrored, so the grid
    // reads left to right the way it plays: display seconds d = source_sec - s.
    const rev = clip.audio.reversed;
    const win_d0 = if (rev) source_sec - (clip.audio.start_sec + clip.audio.dur_sec) else clip.audio.start_sec;
    const win_d1 = win_d0 + clip.audio.dur_sec;
    const ws_b = win_d0 / sec_per_beat;
    const we_b = win_d1 / sec_per_beat;

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
        if (vx1 > vx0 + 1) {
            const bl = xToBeat(grid, vx0);
            const br = xToBeat(grid, vx1);
            const total: f64 = @floatFromInt(src.cache.sample_count);
            const d_l = std.math.clamp(bl * sec_per_beat * rate, 0, total);
            const d_r = std.math.clamp(br * sec_per_beat * rate, 0, total);
            const s_l = if (rev) total - d_r else d_l;
            const s_r = if (rev) total - d_l else d_r;
            surf.waveformDir(ui, frect(vx0, grid.y + 2, vx1 - vx0, grid.height - 4), &src.cache, s_l, s_r, track_color, rev);
        }
    }

    // Dim the trimmed-off regions (outside the played window).
    const dimcol = ui_style.chassis.alpha(160);
    const xs = beatToX(grid, ws_b);
    const xe = beatToX(grid, we_b);
    if (xs > grid.x) ui.rect(frect(grid.x, grid.y, @min(xs, grid.x + grid.width) - grid.x, grid.height), dimcol);
    if (xe < grid.x + grid.width) ui.rect(frect(@max(xe, grid.x), grid.y, grid.x + grid.width - @max(xe, grid.x), grid.height), dimcol);

    // Fade ramps + shaded (attenuated) wedges.
    const fi_b = @min(clip.audio.fade_in_sec, clip.audio.dur_sec) / sec_per_beat;
    const fo_b = @min(clip.audio.fade_out_sec, clip.audio.dur_sec) / sec_per_beat;
    const in_x = beatToX(grid, ws_b + fi_b);
    const out_x = beatToX(grid, we_b - fo_b);
    if (fi_b > 0) shadeFade(ui, grid, xs, in_x, true);
    if (fo_b > 0) shadeFade(ui, grid, out_x, xe, false);
    if (fi_b > 0) ui.line(xs, grid.y + grid.height, in_x, grid.y, ui_style.text_dim);
    if (fo_b > 0) ui.line(out_x, grid.y, xe, grid.y + grid.height, ui_style.text_dim);

    // ── Window edge handles (full height, below the fade strip) ──────
    var s0 = win_d0;
    var s1 = win_d1;
    if (edgeHandle(ui, clip, grid, xs, EDGE_SALT, 0, m)) |nx|
        s0 = std.math.clamp(beatAtX(grid, nx) * sec_per_beat, 0, s1 - MIN_SEC);
    if (edgeHandle(ui, clip, grid, xe, EDGE_SALT, 1, m)) |nx|
        s1 = std.math.clamp(beatAtX(grid, nx) * sec_per_beat, s0 + MIN_SEC, source_sec);
    if (s0 != win_d0 or s1 != win_d1) {
        clip.audio.start_sec = if (rev) source_sec - s1 else s0;
        clip.audio.dur_sec = s1 - s0;
        clip.length_beats = @max(0.01, (s1 - s0) / sec_per_beat);
    }

    // ── Fade handles (top strip) ─────────────────────────────────────
    const dur = clip.audio.dur_sec;
    if (fadeHandle(ui, clip, grid, in_x, EDGE_SALT, 2, m)) |nx| {
        const v = (beatAtX(grid, nx) - ws_b) * sec_per_beat;
        clip.audio.fade_in_sec = std.math.clamp(v, 0, dur);
    }
    if (fadeHandle(ui, clip, grid, out_x, EDGE_SALT, 3, m)) |nx| {
        const v = (we_b - beatAtX(grid, nx)) * sec_per_beat;
        clip.audio.fade_out_sec = std.math.clamp(v, 0, dur);
    }
    ui.unclip();

    // The transport's position while it plays inside the clip, mapped
    // into the played window (ruler through grid).
    if (play_beat) |b| {
        const local = b - clip.start_beat;
        if (local >= 0 and local < clip.length_beats) {
            const px = beatToX(grid, ws_b + (we_b - ws_b) * local / @max(0.001, clip.length_beats));
            if (px >= grid.x and px < grid.x + grid.width)
                ui.rect(frect(@floor(px), ruler_rect.y, 1, grid.y + grid.height - ruler_rect.y), ui_style.accent);
        }
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
    var buf: [96]u8 = undefined;
    const info = std.fmt.bufPrint(&buf, "START {d:.2}S  LEN {d:.2}S  FADE {d:.2}/{d:.2}S  GAIN {d:.2}X", .{
        clip.audio.start_sec, clip.audio.dur_sec, clip.audio.fade_in_sec, clip.audio.fade_out_sec, clip.audio.gain,
    }) catch "";
    const disp_w = @min(row.w, @as(i32, @intCast(info.len)) * ctl.CELL_W + 4);
    if (disp_w > 8) ctl.display(ui, Rect.xywh(row.x, row.y + @divFloor(row.h - ctl.displayHeight(false), 2), disp_w, ctl.displayHeight(false)), info, .{});

    return res;
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
    var beat: f64 = 0;
    while (true) {
        const bx = beatToX(grid, beat);
        if (bx > ruler.x + ruler.width - 2) break;
        if (bx >= ruler.x - 4) {
            const is_bar = snap_mod.isBar(beat);
            const is_beat = snap_mod.isBeat(beat);
            const th: i32 = if (is_bar) 7 else if (is_beat) 4 else 2;
            ui.rect(Rect.xywh(ipx(bx), bot - th, 1, th), if (is_bar) ui_style.text_dim else if (is_beat) ui_style.text_mute else ui_style.face_lo);
            if (is_bar) {
                var b: [8]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "{d}", .{@as(u32, @intFromFloat(@round(beat / 4.0))) + 1}) catch "?";
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
    var beat: f64 = 0;
    while (true) {
        const bx = beatToX(grid, beat);
        if (bx > grid.x + grid.width - 1) break;
        if (bx >= grid.x) {
            const is_bar = snap_mod.isBar(beat);
            const is_beat = snap_mod.isBeat(beat);
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
