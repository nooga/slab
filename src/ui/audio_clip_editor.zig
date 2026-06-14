//! Audio clip editor — the clip-editor pane's view for an *audio* clip (the
//! piano roll handles note clips). It mirrors the piano roll's navigation:
//! a beat ruler + grid, horizontal zoom (Shift+wheel) and pan, and a minimap
//! overview. The whole source waveform is drawn in the track colour along a
//! beat axis (source seconds → beats at the project tempo, since playback is
//! unwarped). The played window's start/end and the fade-in/out are editable
//! with on-waveform handles, and the trimmed + faded regions are shaded.

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const snap_mod = @import("snap.zig");
const track_mod = @import("../track.zig");
const clip_mod = @import("../clip.zig");
const ClipRef = clip_mod.ClipRef;
const audio_pool_mod = @import("../audio_pool.zig");
const waveform = @import("../waveform.zig");
const clip_editor = @import("clip_editor.zig");

const Result = clip_editor.Result;

const EDGE_SALT: u64 = 0xA0D0_C11E_ED17_0001;
const GAIN_SALT: u64 = 0xA0D0_C11E_6A11_0002;
const OV_KEY: u64 = 0xA0D0_0FE0_7A6C_0003;
const MIN_SEC: f64 = 0.01;
const MAX_GAIN: f64 = 2.0;
const PX_PER_BEAT_MAX: f32 = 400;

fn overviewH() f32 {
    return theme.size(18);
}
fn rulerH() f32 {
    return theme.size(12);
}
fn ctrlH() f32 {
    return theme.size(20);
}

// Beat-axis view state (persisted across frames, refit when the clip changes).
var px_per_beat: f32 = 48;
var scroll_x: f32 = 0;
var view_key: u64 = 0;

pub fn draw(
    r: c.rl.Rectangle,
    tracks: []track_mod.Track,
    pool: *const audio_pool_mod.AudioPool,
    selected: ?ClipRef,
    bpm: f64,
    m: widgets.Mouse,
) Result {
    c.rl.DrawRectangleRec(r, theme.pane_bg);

    const header = widgets.rect(r.x, r.y, r.width, theme.paneHeaderH());
    const res = widgets.paneHeader(header, .{ .title = title(tracks, selected), .has_close = true }, m);

    const body = widgets.rect(r.x + 1, r.y + theme.paneHeaderH() + 1, r.width - 2, r.height - theme.paneHeaderH() - 2);

    const resolved = resolveAudioClip(tracks, selected) orelse {
        widgets.drawLabelF("no audio clip selected", body.x + 6, body.y + 6, theme.fsBody(), theme.text_mute);
        return .{ .minimize = res.minimize, .close = res.close };
    };
    const clip = resolved.clip;
    const track_color = resolved.color;
    const src = pool.get(clip.audio.source) orelse {
        widgets.drawLabelF("missing audio source", body.x + 6, body.y + 6, theme.fsBody(), theme.text_mute);
        return .{ .minimize = res.minimize, .close = res.close };
    };
    const source_sec = src.seconds();
    if (source_sec <= 0 or src.cache.sample_count == 0) {
        widgets.drawLabelF("empty audio source", body.x + 6, body.y + 6, theme.fsBody(), theme.text_mute);
        return .{ .minimize = res.minimize, .close = res.close };
    }

    const rate = src.sample.sample_rate;
    const sec_per_beat = 60.0 / @max(1.0, bpm);
    const source_beats: f64 = @max(0.001, source_sec / sec_per_beat);

    // ── Layout: overview · ruler · grid · control row ────────────────
    const ov_rect = widgets.rect(body.x, body.y, body.width, overviewH());
    const ruler_rect = widgets.rect(body.x, ov_rect.y + ov_rect.height, body.width, rulerH());
    const ctrl_rect = widgets.rect(body.x, body.y + body.height - ctrlH(), body.width, ctrlH());
    const grid = widgets.rect(body.x, ruler_rect.y + ruler_rect.height, body.width, @max(8, ctrl_rect.y - (ruler_rect.y + ruler_rect.height) - 1));

    // Refit zoom/scroll when the edited clip (or its source) changes.
    const key = @intFromPtr(clip) ^ (@as(u64, clip.audio.source) << 1);
    if (key != view_key) {
        view_key = key;
        px_per_beat = fitPx(grid, source_beats);
        scroll_x = 0;
    }
    handleWheel(grid, source_beats, m);
    clampView(grid, source_beats);

    // Conversions.
    const ws_b = clip.audio.start_sec / sec_per_beat;
    const we_b = (clip.audio.start_sec + clip.audio.dur_sec) / sec_per_beat;

    // ── Ruler ────────────────────────────────────────────────────────
    widgets.bevelSunken(ruler_rect, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    c.rl.BeginScissorMode(@intFromFloat(ruler_rect.x), @intFromFloat(ruler_rect.y), @intFromFloat(ruler_rect.width), @intFromFloat(ruler_rect.height));
    drawRulerTicks(ruler_rect, grid);
    c.rl.EndScissorMode();

    // ── Grid + waveform ──────────────────────────────────────────────
    c.rl.DrawRectangleRec(grid, theme.pane_bg);
    c.rl.BeginScissorMode(@intFromFloat(grid.x), @intFromFloat(grid.y), @intFromFloat(grid.width), @intFromFloat(grid.height));
    drawGridLines(grid);

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
            const s_l = std.math.clamp(bl * sec_per_beat * rate, 0, total);
            const s_r = std.math.clamp(br * sec_per_beat * rate, 0, total);
            waveform.draw(widgets.rect(vx0, grid.y, vx1 - vx0, grid.height), &src.cache, s_l, s_r, track_color);
        }
    }

    // Dim the trimmed-off regions (outside the played window).
    const dimcol = c.rl.ColorAlpha(theme.bg, 0.6);
    const xs = beatToX(grid, ws_b);
    const xe = beatToX(grid, we_b);
    if (xs > grid.x) c.rl.DrawRectangleRec(widgets.rect(grid.x, grid.y, @min(xs, grid.x + grid.width) - grid.x, grid.height), dimcol);
    if (xe < grid.x + grid.width) c.rl.DrawRectangleRec(widgets.rect(@max(xe, grid.x), grid.y, grid.x + grid.width - @max(xe, grid.x), grid.height), dimcol);

    // Fade ramps + shaded (attenuated) wedges.
    const fi_b = @min(clip.audio.fade_in_sec, clip.audio.dur_sec) / sec_per_beat;
    const fo_b = @min(clip.audio.fade_out_sec, clip.audio.dur_sec) / sec_per_beat;
    const in_x = beatToX(grid, ws_b + fi_b);
    const out_x = beatToX(grid, we_b - fo_b);
    if (fi_b > 0) shadeFade(grid, xs, in_x, true);
    if (fo_b > 0) shadeFade(grid, out_x, xe, false);
    if (fi_b > 0) c.rl.DrawLineEx(.{ .x = xs, .y = grid.y + grid.height }, .{ .x = in_x, .y = grid.y }, 1.0, theme.text_mute);
    if (fo_b > 0) c.rl.DrawLineEx(.{ .x = out_x, .y = grid.y }, .{ .x = xe, .y = grid.y + grid.height }, 1.0, theme.text_mute);

    c.rl.EndScissorMode();

    // ── Window edge handles (full height, below the fade strip) ──────
    var s0 = clip.audio.start_sec;
    var s1 = clip.audio.start_sec + clip.audio.dur_sec;
    if (edgeHandle(clip, grid, xs, EDGE_SALT, 0, m)) |nx|
        s0 = std.math.clamp(beatAtX(grid, nx) * sec_per_beat, 0, s1 - MIN_SEC);
    if (edgeHandle(clip, grid, xe, EDGE_SALT, 1, m)) |nx|
        s1 = std.math.clamp(beatAtX(grid, nx) * sec_per_beat, s0 + MIN_SEC, source_sec);
    if (s0 != clip.audio.start_sec or s1 != clip.audio.start_sec + clip.audio.dur_sec) {
        clip.audio.start_sec = s0;
        clip.audio.dur_sec = s1 - s0;
        clip.length_beats = @max(0.01, (s1 - s0) / sec_per_beat);
    }

    // ── Fade handles (top strip) ─────────────────────────────────────
    const dur = clip.audio.dur_sec;
    if (fadeHandle(clip, grid, in_x, EDGE_SALT, 2, m)) |nx| {
        const v = (beatAtX(grid, nx) - ws_b) * sec_per_beat;
        clip.audio.fade_in_sec = std.math.clamp(v, 0, dur);
    }
    if (fadeHandle(clip, grid, out_x, EDGE_SALT, 3, m)) |nx| {
        const v = (we_b - beatAtX(grid, nx)) * sec_per_beat;
        clip.audio.fade_out_sec = std.math.clamp(v, 0, dur);
    }

    // ── Minimap overview ─────────────────────────────────────────────
    drawOverview(ov_rect, grid, src, track_color, source_beats, m);

    // ── Control row: gain slider + readouts ──────────────────────────
    const gain_w = @min(ctrl_rect.width * 0.4, theme.size(150));
    const gain_rect = widgets.rect(ctrl_rect.x, ctrl_rect.y + 3, gain_w, ctrl_rect.height - 6);
    drawGainSlider(clip, gain_rect, m);
    var buf: [128:0]u8 = undefined;
    const info = std.fmt.bufPrintZ(&buf, "start {d:.2}s   len {d:.2}s   fade {d:.2}/{d:.2}s   gain {d:.2}x", .{
        clip.audio.start_sec, clip.audio.dur_sec, clip.audio.fade_in_sec, clip.audio.fade_out_sec, clip.audio.gain,
    }) catch "";
    widgets.drawLabelF(info.ptr, gain_rect.x + gain_rect.width + theme.size(10), ctrl_rect.y + (ctrl_rect.height - theme.fsBody()) / 2, theme.fsBody(), theme.text_dim);

    return .{
        .minimize = res.minimize,
        .close = res.close,
        .rename_rect = if (selected != null) res.title_rect else null,
    };
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

fn handleWheel(grid: c.rl.Rectangle, source_beats: f64, m: widgets.Mouse) void {
    if (!widgets.contains(grid, m.x, m.y)) return;
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

fn drawRulerTicks(ruler: c.rl.Rectangle, grid: c.rl.Rectangle) void {
    const step = snap_mod.visualStep(.note_16, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = beatToX(grid, beat);
        if (bx > ruler.x + ruler.width - 2) break;
        if (bx >= ruler.x - 4) {
            const is_bar = snap_mod.isBar(beat);
            const is_beat = snap_mod.isBeat(beat);
            const th: f32 = if (is_bar) rulerH() - 4 else if (is_beat) 5 else 3;
            c.rl.DrawRectangle(@intFromFloat(bx), @intFromFloat(ruler.y + rulerH() - th - 2), 1, @intFromFloat(th), if (is_bar) theme.grid_bar else if (is_beat) theme.grid_beat else theme.grid_sub);
            if (is_bar) {
                var b: [8]u8 = undefined;
                const s = std.fmt.bufPrintZ(&b, "{d}", .{@as(u32, @intFromFloat(@round(beat / 4.0))) + 1}) catch "?";
                widgets.drawLabelF(s.ptr, bx + 2, ruler.y + 1, theme.fsTiny(), theme.text_dim);
            }
        }
        beat += step;
    }
}

fn drawGridLines(grid: c.rl.Rectangle) void {
    const step = snap_mod.visualStep(.note_16, px_per_beat);
    var beat: f64 = 0;
    while (true) {
        const bx = beatToX(grid, beat);
        if (bx > grid.x + grid.width - 1) break;
        if (bx >= grid.x) {
            const is_bar = snap_mod.isBar(beat);
            const is_beat = snap_mod.isBeat(beat);
            c.rl.DrawRectangle(@intFromFloat(bx), @intFromFloat(grid.y), 1, @intFromFloat(grid.height), if (is_bar) theme.grid_bar else if (is_beat) theme.grid_beat else theme.grid_sub);
        }
        beat += step;
    }
}

/// Shade the attenuated wedge of a fade as per-column vertical bars (a filled
/// triangle, brutalist no-AA). For a fade-in the shading is tall at the left
/// (silent) edge and shrinks to nothing; mirrored for a fade-out.
fn shadeFade(grid: c.rl.Rectangle, x0: f32, x1: f32, fade_in: bool) void {
    const lo = @max(@min(x0, x1), grid.x);
    const hi = @min(@max(x0, x1), grid.x + grid.width);
    const span = x1 - x0;
    if (hi <= lo or @abs(span) < 1) return;
    const col = c.rl.ColorAlpha(theme.bg, 0.5);
    var x = @floor(lo);
    while (x < hi) : (x += 1) {
        const p = std.math.clamp((x - x0) / span, 0, 1); // 0 at x0 → 1 at x1
        const atten: f32 = if (fade_in) 1 - p else p;
        const h = grid.height * atten;
        if (h >= 1) c.rl.DrawLineEx(.{ .x = x, .y = grid.y }, .{ .x = x, .y = grid.y + h }, 1.0, col);
    }
}

fn drawOverview(strip: c.rl.Rectangle, grid: c.rl.Rectangle, src: *const audio_pool_mod.Source, track_color: c.rl.Color, source_beats: f64, m: widgets.Mouse) void {
    widgets.bevelSunken(strip, theme.pane_bg, theme.slab_hi, theme.slab_lo);
    const inner = widgets.rect(strip.x + 2, strip.y + 2, strip.width - 4, strip.height - 4);
    if (inner.width < 2 or inner.height < 2) return;
    waveform.draw(inner, &src.cache, 0, @floatFromInt(src.cache.sample_count), dim(track_color, 0.7));

    // Viewport window.
    const content_w = @as(f32, @floatCast(source_beats)) * px_per_beat;
    if (content_w <= 0) return;
    const vx = inner.x + (scroll_x / content_w) * inner.width;
    const vw = @max(2.0, (grid.width / content_w) * inner.width);
    const vp = widgets.rect(std.math.clamp(vx, inner.x, inner.x + inner.width), inner.y, @min(vw, inner.x + inner.width - vx), inner.height);
    c.rl.DrawRectangleRec(vp, c.rl.ColorAlpha(theme.accent_hi, 0.2));
    c.rl.DrawRectangleLinesEx(vp, 1, theme.accent_hi);

    // Click / drag to centre the viewport on the cursor.
    if (widgets.contains(strip, m.x, m.y) and m.left_down) {
        const frac = std.math.clamp((m.x - inner.x) / inner.width, 0, 1);
        scroll_x = frac * content_w - grid.width / 2;
    }
}

// ── Handles ──────────────────────────────────────────────────────────

fn edgeHandle(clip: *clip_mod.Clip, area: c.rl.Rectangle, x: f32, salt: u64, id: u64, m: widgets.Mouse) ?f32 {
    const key = widgets.keyFromIds(salt, @intFromPtr(clip), id);
    const dragging = widgets.isDraggingKey(key);
    // Reserve the top strip for fade handles sitting on the same x.
    const hot = widgets.contains(area, m.x, m.y) and @abs(m.x - x) <= theme.fine(4) and m.y > area.y + theme.size(9);
    var out: ?f32 = null;
    if (dragging) {
        if (m.left_down) out = std.math.clamp(m.x, area.x, area.x + area.width) else widgets.cancelDrag();
    } else if (hot and m.left_pressed and !widgets.hasActiveDrag()) {
        _ = widgets.tryStartDrag(key);
    }
    if (hot or dragging) widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);
    const lw: f32 = if (hot or dragging) 2.0 else 1.0;
    c.rl.DrawLineEx(.{ .x = x, .y = area.y }, .{ .x = x, .y = area.y + area.height }, lw, theme.accent_play);
    const tab = theme.fine(3);
    c.rl.DrawRectangleRec(widgets.rect(x - tab, area.y, tab * 2 + 1, tab + 1), theme.accent_play);
    return out;
}

fn fadeHandle(clip: *clip_mod.Clip, area: c.rl.Rectangle, x: f32, salt: u64, id: u64, m: widgets.Mouse) ?f32 {
    const sz = theme.size(7);
    const box = widgets.rect(x - sz / 2, area.y, sz, sz);
    const key = widgets.keyFromIds(salt, @intFromPtr(clip), id);
    const dragging = widgets.isDraggingKey(key);
    const hot = widgets.contains(box, m.x, m.y);
    var out: ?f32 = null;
    if (dragging) {
        if (m.left_down) out = std.math.clamp(m.x, area.x, area.x + area.width) else widgets.cancelDrag();
    } else if (hot and m.left_pressed and !widgets.hasActiveDrag()) {
        _ = widgets.tryStartDrag(key);
    }
    if (hot or dragging) widgets.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 3);
    c.rl.DrawRectangleRec(box, if (hot or dragging) theme.text_fg else theme.accent_hi);
    return out;
}

fn drawGainSlider(clip: *clip_mod.Clip, r: c.rl.Rectangle, m: widgets.Mouse) void {
    widgets.bevelSunken(r, theme.pane_bg, theme.slab_hi, theme.slab_lo);
    const key = widgets.keyFromIds(GAIN_SALT, @intFromPtr(clip), 0);
    const dragging = widgets.isDraggingKey(key);
    const hot = widgets.contains(r, m.x, m.y);
    if (dragging) {
        if (m.left_down) clip.audio.gain = @floatCast(std.math.clamp((m.x - r.x) / r.width, 0, 1) * MAX_GAIN) else widgets.cancelDrag();
    } else if (hot and m.left_pressed and !widgets.hasActiveDrag()) {
        _ = widgets.tryStartDrag(key);
        clip.audio.gain = @floatCast(std.math.clamp((m.x - r.x) / r.width, 0, 1) * MAX_GAIN);
    }
    const unity_x = r.x + r.width * @as(f32, @floatCast(1.0 / MAX_GAIN));
    const frac = std.math.clamp(@as(f32, clip.audio.gain) / @as(f32, @floatCast(MAX_GAIN)), 0, 1);
    c.rl.DrawRectangleRec(widgets.rect(r.x + 1, r.y + 1, (r.width - 2) * frac, r.height - 2), c.rl.ColorAlpha(theme.accent_hi, 0.5));
    c.rl.DrawLine(@intFromFloat(unity_x), @intFromFloat(r.y), @intFromFloat(unity_x), @intFromFloat(r.y + r.height), theme.text_mute);
    widgets.drawLabelF("GAIN", r.x + 4, r.y + (r.height - theme.fsTiny()) / 2, theme.fsTiny(), theme.text_dim);
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

var title_buf: [clip_mod.MAX_NAME + 16:0]u8 = undefined;
fn title(tracks: []track_mod.Track, selected: ?ClipRef) [*:0]const u8 {
    const resolved = resolveAudioClip(tracks, selected) orelse return "Audio";
    const s = std.fmt.bufPrintZ(&title_buf, "Audio \u{2014} {s}", .{resolved.clip.name()}) catch "Audio";
    return s.ptr;
}

fn dim(col: c.rl.Color, f: f32) c.rl.Color {
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(col.r)) * f),
        .g = @intFromFloat(@as(f32, @floatFromInt(col.g)) * f),
        .b = @intFromFloat(@as(f32, @floatFromInt(col.b)) * f),
        .a = col.a,
    };
}
