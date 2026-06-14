//! Audio clip editor — the clip-editor pane's view for an *audio* clip
//! (the piano roll handles note clips). Shows the whole source waveform
//! with the played window highlighted; the window's start/end edges and a
//! gain control are draggable. Editing writes the clip's source window
//! (`start_sec`/`dur_sec`) and `gain`; the clip's beat-length reflows from
//! the window at the current tempo, exactly like the timeline trim handles.

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const track_mod = @import("../track.zig");
const clip_mod = @import("../clip.zig");
const ClipRef = clip_mod.ClipRef;
const audio_pool_mod = @import("../audio_pool.zig");
const waveform = @import("../waveform.zig");
const clip_editor = @import("clip_editor.zig");

const Result = clip_editor.Result;

const EDGE_SALT: u64 = 0xA0D0_C11E_ED17_0001;
const GAIN_SALT: u64 = 0xA0D0_C11E_6A11_0002;
const MIN_SEC: f64 = 0.01;
const MAX_GAIN: f64 = 2.0;

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

    const clip = resolveAudioClip(tracks, selected) orelse {
        widgets.drawLabelF("no audio clip selected", body.x + 6, body.y + 6, theme.fsBody(), theme.text_mute);
        return .{ .minimize = res.minimize, .close = res.close };
    };
    const src = pool.get(clip.audio.source) orelse {
        widgets.drawLabelF("missing audio source", body.x + 6, body.y + 6, theme.fsBody(), theme.text_mute);
        return .{ .minimize = res.minimize, .close = res.close };
    };
    const source_sec = src.seconds();
    if (source_sec <= 0 or src.cache.sample_count == 0) {
        widgets.drawLabelF("empty audio source", body.x + 6, body.y + 6, theme.fsBody(), theme.text_mute);
        return .{ .minimize = res.minimize, .close = res.close };
    }

    // ── Layout: waveform on top, a control row at the bottom ──────────
    const row_h = theme.size(20);
    const wave_h = @max(8, body.height - row_h - 4);
    const wave = widgets.rect(body.x + 4, body.y + 4, body.width - 8, wave_h);

    // Whole-source waveform.
    c.rl.DrawRectangleRec(wave, theme.slab_edge);
    const wave_in = widgets.rect(wave.x + 1, wave.y + 1, wave.width - 2, wave.height - 2);
    waveform.draw(wave_in, &src.cache, 0, @floatFromInt(src.cache.sample_count), theme.accent_hi);

    const w = wave_in.width;
    const start_sec = clip.audio.start_sec;
    const end_sec = @min(source_sec, start_sec + clip.audio.dur_sec);
    const x_start = wave_in.x + @as(f32, @floatCast(start_sec / source_sec)) * w;
    const x_end = wave_in.x + @as(f32, @floatCast(end_sec / source_sec)) * w;

    // Dim the trimmed-off regions (outside the played window).
    const dimcol = c.rl.ColorAlpha(theme.bg, 0.55);
    if (x_start > wave_in.x)
        c.rl.DrawRectangleRec(widgets.rect(wave_in.x, wave_in.y, x_start - wave_in.x, wave_in.height), dimcol);
    if (x_end < wave_in.x + w)
        c.rl.DrawRectangleRec(widgets.rect(x_end, wave_in.y, wave_in.x + w - x_end, wave_in.height), dimcol);

    // Draggable window edges.
    const new_start = edgeHandle(clip, wave_in, x_start, source_sec, EDGE_SALT, 0, m);
    const new_end = edgeHandle(clip, wave_in, x_end, source_sec, EDGE_SALT, 1, m);

    var s0 = start_sec;
    var s1 = end_sec;
    if (new_start) |v| s0 = std.math.clamp(v, 0, s1 - MIN_SEC);
    if (new_end) |v| s1 = std.math.clamp(v, s0 + MIN_SEC, source_sec);
    if (new_start != null or new_end != null) {
        clip.audio.start_sec = s0;
        clip.audio.dur_sec = s1 - s0;
        clip.length_beats = @max(0.01, (s1 - s0) * bpm / 60.0);
    }

    // Fade handles — small markers near the top, dragged inward to set the
    // fade-in (from the window start) and fade-out (from the window end).
    const dur = clip.audio.dur_sec;
    const px_per_sec: f64 = @as(f64, w) / source_sec;
    const fi = std.math.clamp(clip.audio.fade_in_sec, 0, dur);
    const fo = std.math.clamp(clip.audio.fade_out_sec, 0, dur - fi);
    const fade_y = wave_in.y;
    const in_x = x_start + @as(f32, @floatCast(fi * px_per_sec));
    const out_x = x_end - @as(f32, @floatCast(fo * px_per_sec));
    // Ramp guides.
    c.rl.DrawLineEx(.{ .x = x_start, .y = wave_in.y + wave_in.height }, .{ .x = in_x, .y = fade_y }, 1.0, theme.text_mute);
    c.rl.DrawLineEx(.{ .x = out_x, .y = fade_y }, .{ .x = x_end, .y = wave_in.y + wave_in.height }, 1.0, theme.text_mute);

    if (fadeHandle(clip, wave_in, in_x, fade_y, EDGE_SALT, 2, m)) |hx| {
        const v = (@as(f64, hx - x_start) / px_per_sec);
        clip.audio.fade_in_sec = std.math.clamp(v, 0, dur);
    }
    if (fadeHandle(clip, wave_in, out_x, fade_y, EDGE_SALT, 3, m)) |hx| {
        const v = (@as(f64, x_end - hx) / px_per_sec);
        clip.audio.fade_out_sec = std.math.clamp(v, 0, dur);
    }

    // ── Control row: gain slider + numeric readouts ──────────────────
    const row = widgets.rect(body.x + 4, wave.y + wave.height + 2, body.width - 8, row_h);
    const gain_w = @min(row.width * 0.45, theme.size(160));
    const gain_rect = widgets.rect(row.x, row.y + 2, gain_w, row.height - 4);
    drawGainSlider(clip, gain_rect, m);

    var buf: [96:0]u8 = undefined;
    const info = std.fmt.bufPrintZ(&buf, "start {d:.2}s   len {d:.2}s   gain {d:.2}x", .{
        clip.audio.start_sec,
        clip.audio.dur_sec,
        clip.audio.gain,
    }) catch "";
    widgets.drawLabelF(info.ptr, gain_rect.x + gain_rect.width + theme.size(10), row.y + (row.height - theme.fsBody()) / 2, theme.fsBody(), theme.text_dim);

    return .{
        .minimize = res.minimize,
        .close = res.close,
        .rename_rect = if (selected != null) res.title_rect else null,
    };
}

/// A draggable vertical window edge. Returns the new source-second position
/// while dragging, else null. `id` distinguishes start (0) from end (1).
fn edgeHandle(clip: *clip_mod.Clip, area: c.rl.Rectangle, x: f32, source_sec: f64, salt: u64, id: u64, m: widgets.Mouse) ?f64 {
    const key = widgets.keyFromIds(salt, @intFromPtr(clip), id);
    const dragging = widgets.isDraggingKey(key);
    // Reserve the top strip for the fade handles that sit on the same x.
    const hot = widgets.contains(area, m.x, m.y) and @abs(m.x - x) <= theme.fine(4) and m.y > area.y + theme.size(9);

    var out: ?f64 = null;
    if (dragging) {
        if (m.left_down) {
            const frac = std.math.clamp((m.x - area.x) / area.width, 0, 1);
            out = @as(f64, frac) * source_sec;
        } else widgets.cancelDrag();
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

/// A small square fade handle near the top edge, dragged horizontally.
/// Returns the new handle x while dragging, else null.
fn fadeHandle(clip: *clip_mod.Clip, area: c.rl.Rectangle, x: f32, y: f32, salt: u64, id: u64, m: widgets.Mouse) ?f32 {
    const sz = theme.size(7);
    const box = widgets.rect(x - sz / 2, y, sz, sz);
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
        if (m.left_down) {
            const frac = std.math.clamp((m.x - r.x) / r.width, 0, 1);
            clip.audio.gain = @floatCast(@as(f64, frac) * MAX_GAIN);
        } else widgets.cancelDrag();
    } else if (hot and m.left_pressed and !widgets.hasActiveDrag()) {
        _ = widgets.tryStartDrag(key);
        clip.audio.gain = @floatCast(std.math.clamp((m.x - r.x) / r.width, 0, 1) * MAX_GAIN);
    }
    // Unity tick + fill up to the current gain.
    const unity_x = r.x + r.width * @as(f32, @floatCast(1.0 / MAX_GAIN));
    const frac = std.math.clamp(@as(f32, clip.audio.gain) / @as(f32, @floatCast(MAX_GAIN)), 0, 1);
    c.rl.DrawRectangleRec(widgets.rect(r.x + 1, r.y + 1, (r.width - 2) * frac, r.height - 2), c.rl.ColorAlpha(theme.accent_hi, 0.5));
    c.rl.DrawLine(@intFromFloat(unity_x), @intFromFloat(r.y), @intFromFloat(unity_x), @intFromFloat(r.y + r.height), theme.text_mute);
    widgets.drawLabelF("GAIN", r.x + 4, r.y + (r.height - theme.fsTiny()) / 2, theme.fsTiny(), theme.text_dim);
}

fn resolveAudioClip(tracks: []track_mod.Track, selected: ?ClipRef) ?*clip_mod.Clip {
    const s = selected orelse return null;
    if (s.track >= tracks.len) return null;
    const t = &tracks[s.track];
    if (s.clip >= t.clips.items.len) return null;
    const clip = &t.clips.items[s.clip];
    if (!clip.isAudio()) return null;
    return clip;
}

var title_buf: [clip_mod.MAX_NAME + 16:0]u8 = undefined;
fn title(tracks: []track_mod.Track, selected: ?ClipRef) [*:0]const u8 {
    const clip = resolveAudioClip(tracks, selected) orelse return "Audio";
    const s = std.fmt.bufPrintZ(&title_buf, "Audio — {s}", .{clip.name()}) catch "Audio";
    return s.ptr;
}
