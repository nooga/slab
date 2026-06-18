//! Transport toolbar — OpenTTD-packed. No outer bevel on the bar; each
//! element carries its own bevel and abuts its neighbours with a 1 px
//! separator. Readout fields use the double (raised + sunken) bevel.
//!
//! Buttons:   ▶/■  ●                (transport)
//! Fields:   [ ● 120.0 BPM ]  [TAP]  [ 1.1.1 BAR ]
//! The LED on the BPM pulses with the beat.

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const snap_mod = @import("snap.zig");
const Transport = @import("../transport.zig").Transport;
const meter_mod = @import("../meter.zig");

const GAP: f32 = 0;
const GROUP_GAP: f32 = 0;
// Tap tempo ring buffer.
const TAP_MAX = 4;
var tap_times: [TAP_MAX]f64 = .{ 0, 0, 0, 0 };
var tap_count: usize = 0;
var tap_last: f64 = 0;

// Logo wordmark texture, loaded once (lazily, so the GL context exists) from
// the repo-relative path — same convention as fonts.zig. Mipmapped + trilinear
// for a clean downscale of the large source image into the small plate.
var logo_tex: c.rl.Texture2D = undefined;
var logo_loaded = false;
var logo_ok = false;

fn logoTexture() ?c.rl.Texture2D {
    if (!logo_loaded) {
        logo_loaded = true;
        var t = c.rl.LoadTexture("slab.png");
        if (t.id != 0) {
            c.rl.GenTextureMipmaps(&t);
            c.rl.SetTextureFilter(t, c.rl.TEXTURE_FILTER_TRILINEAR);
            logo_tex = t;
            logo_ok = true;
        }
    }
    return if (logo_ok) logo_tex else null;
}

pub const Result = struct {
    open_project: bool = false,
    save_project: bool = false,
    save_project_as: bool = false,
    render_audio: bool = false,
};

const FILE_MENU_KEY: u64 = 0x5346494c45; // "SFILE"

pub fn draw(r: c.rl.Rectangle, transport: *Transport, meter_state: *meter_mod.MeterState, edit_snap: *snap_mod.Setting, project_path: []const u8, project_path_chosen: bool, dirty: bool, m: widgets.Mouse) Result {
    const meter_map = meter_state.liveMap();
    var result: Result = .{};

    // Bar background — flat, no bevel.
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    // Bottom hairline separates bar from the panes below.
    c.rl.DrawRectangle(
        @intFromFloat(r.x),
        @intFromFloat(r.y + r.height - 1),
        @intFromFloat(r.width),
        1,
        theme.slab_edge,
    );

    const y = r.y + 1;
    const h = r.height - 2;
    var x = r.x + 2;
    const btn_w = theme.size(22);
    const tap_w = theme.size(30);
    const field_w_bpm = theme.size(80);
    const field_w_pos = theme.size(74);
    const snap_btn_w = theme.size(18);
    const snap_field_w = theme.size(54);

    // ── File: one dropdown button showing the project name ───────────
    {
        var name_buf: [64:0]u8 = [_:0]u8{0} ** 64;
        const name = fileLabel(&name_buf, project_path, project_path_chosen, dirty);
        const fs = theme.fsBody();
        const icon_sz = fs;
        const nw = widgets.measureTextF(name, fs);
        const file_w = theme.size(6) + icon_sz + theme.size(4) + nw + theme.size(4) + icon_sz + theme.size(6);
        const file_rect = widgets.rect(x, y, file_w, h);
        const open = widgets.menuOpen(FILE_MENU_KEY);
        const hover = widgets.contains(file_rect, m.x, m.y) and !widgets.hasActiveDrag();
        const fill = if (open or hover) theme.slab_hi else theme.slab_fill;
        widgets.bevelRaised(file_rect, fill, theme.slab_hi, theme.slab_lo);
        widgets.drawIcon(.file, file_rect.x + theme.size(6), y + (h - icon_sz) / 2, icon_sz, theme.text_dim);
        widgets.drawLabelF(name, file_rect.x + theme.size(6) + icon_sz + theme.size(4), y + (h - fs) / 2 - 1, fs, if (dirty) theme.accent_hi else theme.text_fg);
        widgets.drawIcon(.caret_down, file_rect.x + file_w - icon_sz - theme.size(4), y + (h - icon_sz) / 2, icon_sz, theme.text_dim);
        widgets.tooltip(file_rect, "Project file", m);
        if (hover and m.left_pressed and !open) widgets.openMenuAt(FILE_MENU_KEY, file_rect.x, file_rect.y + file_rect.height);
        // Labels carry no keybind text — the menu renderer draws the
        // right-aligned shortcut hint from the command (see commandShortcut).
        const file_items = [_]widgets.MenuItem{
            .{ .label = "Open\u{2026}", .command = .file_open },
            .{ .label = "Save", .command = .file_save },
            .{ .label = "Save As\u{2026}", .command = .file_save_as },
            .{ .separator = true },
            .{ .label = "Render Audio\u{2026}", .command = .render_audio },
        };
        switch (widgets.contextMenu(FILE_MENU_KEY, &file_items, m)) {
            .file_open => result.open_project = true,
            .file_save => result.save_project = true,
            .file_save_as => result.save_project_as = true,
            .render_audio => result.render_audio = true,
            else => {},
        }
        x += file_w + GROUP_GAP;
    }

    drawSeparator(widgets.rect(x, y, theme.size(10), h));
    x += theme.size(10) + GROUP_GAP;

    // ── Transport buttons ─────────────────────────────────────────────
    const playing = transport.isPlaying();
    const play_icon: widgets.Icon = if (playing) .stop else .play;
    const play_fill: ?c.rl.Color = if (playing) theme.accent_play else null;
    if (widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), play_icon, play_fill, if (playing) "Stop  Space" else "Play  Space", m)) {
        transport.toggle();
    }
    x += btn_w + GAP;

    _ = widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), .record, null, "Record arm", m);
    x += btn_w + GROUP_GAP;

    const loop_fill: ?c.rl.Color = if (transport.loopEnabled()) theme.accent_hi else null;
    if (widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), .repeat, loop_fill, "Loop on/off", m)) {
        transport.toggleLoop();
    }
    x += btn_w + GROUP_GAP;

    // ── BPM: -  [LED 124.0 BPM]  +   (field drags/scrolls like a knob) ─
    const step_w = theme.size(16);
    if (widgets.buttonTip(widgets.rect(x, y, step_w, h), "-", "BPM -1", m)) {
        transport.setBpm(@round(transport.bpm()) - 1);
    }
    x += step_w + GAP;
    bpmField(widgets.rect(x, y, field_w_bpm, h), transport, meter_map, m);
    x += field_w_bpm + GAP;
    if (widgets.buttonTip(widgets.rect(x, y, step_w, h), "+", "BPM +1", m)) {
        transport.setBpm(@round(transport.bpm()) + 1);
    }
    x += step_w + GAP;

    // ── Tap tempo button ─────────────────────────────────────────────
    if (widgets.buttonTip(widgets.rect(x, y, tap_w, h), "TAP", "Tap tempo", m)) {
        handleTap(transport);
    }
    x += tap_w + GROUP_GAP;

    // ── Position field ───────────────────────────────────────────────
    const pos_rect = widgets.rect(x, y, field_w_pos, h);
    posField(pos_rect, transport, meter_map);
    x += field_w_pos + GROUP_GAP;

    // ── Meter (time signature) field ─────────────────────────────────
    const field_w_meter = theme.size(54);
    meterField(widgets.rect(x, y, field_w_meter, h), meter_state, m);
    x += field_w_meter + GROUP_GAP;

    drawSeparator(widgets.rect(x, y, theme.size(10), h));
    x += theme.size(10) + GROUP_GAP;

    if (widgets.buttonTip(widgets.rect(x, y, snap_btn_w, h), "-", "Coarser snap  [", m)) {
        edit_snap.* = edit_snap.*.coarser();
    }
    x += snap_btn_w + GAP;
    const snap_rect = widgets.rect(x, y, snap_field_w, h);
    snapField(snap_rect, edit_snap.*);
    widgets.tooltip(snap_rect, edit_snap.tooltip(), m);
    x += snap_field_w + GAP;
    if (widgets.buttonTip(widgets.rect(x, y, snap_btn_w, h), "+", "Finer snap  ]", m)) {
        edit_snap.* = edit_snap.*.finer();
    }
    x += snap_btn_w;

    // ── Logo plate (right) + blank-bevel filler ─────────────────────
    const title = "SLAB";
    const title_size = theme.fsTitle();
    const tw = widgets.measureTextF(title, title_size);
    const icon_sz = title_size;
    const pad = theme.size(3);
    const tex = logoTexture();
    const logo_w = if (tex) |t| blk: {
        const aspect = @as(f32, @floatFromInt(t.width)) / @as(f32, @floatFromInt(t.height));
        break :blk (h - pad * 2) * aspect + pad * 2;
    } else theme.size(8) + icon_sz + theme.size(5) + tw + theme.size(8);
    const logo_x = r.x + r.width - logo_w;

    // Inert raised bevel fills the empty space between the controls and the
    // logo so the bar reads as one complete instrument panel.
    const fill_x = x + GROUP_GAP;
    if (logo_x - fill_x > theme.size(4)) {
        widgets.bevelRaised(widgets.rect(fill_x, y, logo_x - fill_x - GROUP_GAP, h), theme.slab_fill, theme.slab_hi, theme.slab_lo);
    }

    // Logo plate: the slab.png wordmark on raised chrome, fit to plate height.
    // Falls back to the waveform glyph + amber wordmark if the image is absent.
    widgets.bevelRaised(widgets.rect(logo_x, y, logo_w, h), theme.slab_fill, theme.slab_hi, theme.slab_lo);
    if (tex) |t| {
        const dh = h - pad * 2;
        const dw = dh * (@as(f32, @floatFromInt(t.width)) / @as(f32, @floatFromInt(t.height)));
        const dest = widgets.rect(logo_x + pad, y + pad, dw, dh);
        const src = c.rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(t.width), .height = @floatFromInt(t.height) };
        c.rl.DrawTexturePro(t, src, dest, c.rl.Vector2{ .x = 0, .y = 0 }, 0, c.rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 });
    } else {
        widgets.drawIcon(.waveform, logo_x + theme.size(8), r.y + (r.height - icon_sz) / 2, icon_sz, theme.accent_hi);
        widgets.drawLabelF(title, logo_x + theme.size(8) + icon_sz + theme.size(5), r.y + (r.height - title_size) / 2 - 1, title_size, theme.accent_hi);
    }

    return result;
}

fn fileLabel(buf: *[64:0]u8, path: []const u8, chosen: bool, dirty: bool) [*:0]const u8 {
    if (!chosen) return if (dirty) "*Untitled" else "Untitled";
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/') start = i + 1;
    }
    const base = path[start..];
    var off: usize = 0;
    if (dirty) {
        buf[0] = '*';
        off = 1;
    }
    const n = @min(base.len, 63 - off);
    @memcpy(buf[off .. off + n], base[0..n]);
    buf[off + n] = 0;
    return @ptrCast(&buf[0]);
}

fn drawSeparator(r: c.rl.Rectangle) void {
    widgets.bevelRaised(r, theme.slab_fill, theme.slab_hi, theme.slab_lo);
}

const BPM_SALT: u64 = 0x42504d44; // "BPMD"

fn bpmField(r: c.rl.Rectangle, transport: *Transport, meter_map: meter_mod.MeterMap, m: widgets.Mouse) void {
    // Drag vertically / scroll to edit, like a knob.
    const new_bpm = widgets.dragValueV(r, BPM_SALT, transport.bpm(), 20.0, 400.0, 0.5, 1.0, m);
    if (new_bpm != transport.bpm()) transport.setBpm(new_bpm);

    const inner = widgets.displayField(r);

    // Metronome LED — pulses at the start of each beat, red on the bar's
    // downbeat (meter-aware), green on other beats.
    const beats = transport.beats();
    const beat_frac = @mod(beats, 1);
    const is_downbeat = meter_map.beatToBarPos(beats).beat == 0;
    const pulse_on = transport.isPlaying() and beat_frac < 0.12;
    const led_color = if (is_downbeat) theme.accent_rec else theme.accent_play;

    const led_sz = theme.fine(6);
    const led_rect = widgets.rect(inner.x + 2, inner.y + (inner.height - led_sz) / 2, led_sz, led_sz);
    widgets.led(led_rect, pulse_on, led_color);

    // BPM value (monospace for stability).
    var buf: [16]u8 = undefined;
    const bpm_str = std.fmt.bufPrintZ(&buf, "{d:.1}", .{transport.bpm()}) catch "?";
    widgets.drawLabelF(
        bpm_str.ptr,
        led_rect.x + led_rect.width + 4,
        inner.y + 1,
        theme.fsBody(),
        theme.text_fg,
    );

    // "BPM" caption, right side.
    const cap = "BPM";
    const cap_w = widgets.measureTextF(cap, theme.fsTiny());
    widgets.drawLabelF(
        cap,
        inner.x + inner.width - cap_w - 2,
        inner.y + inner.height - theme.fsTiny() - 1,
        theme.fsTiny(),
        theme.text_mute,
    );
}

fn posField(r: c.rl.Rectangle, transport: *const Transport, meter_map: meter_mod.MeterMap) void {
    const inner = widgets.displayField(r);

    var buf: [32]u8 = undefined;
    const pos = meter_map.beatToBarPos(transport.beats());
    // bar.beat.sub — sub is the 1/16-of-quarter division of the meter-beat
    // (1..4 for a quarter beat, 1..2 for an eighth), matching 4/4 habit.
    const sub = pos.tick / (meter_mod.PPQN / 4) + 1;
    const s = std.fmt.bufPrintZ(&buf, "{d}.{d}.{d}", .{ pos.bar + 1, pos.beat + 1, sub }) catch "?";
    widgets.drawLabelF(s.ptr, inner.x + 3, inner.y + 1, theme.fsBody(), theme.text_fg);

    const cap = "BAR";
    const cap_w = widgets.measureTextF(cap, theme.fsTiny());
    widgets.drawLabelF(
        cap,
        inner.x + inner.width - cap_w - 2,
        inner.y + inner.height - theme.fsTiny() - 1,
        theme.fsTiny(),
        theme.text_mute,
    );
}

const METER_SALT: u64 = 0x4d54524e; // "MTRN"
const DENOM_MENU_KEY: u64 = 0x44_45_4e_4f_4d_4d_4e_55; // "DENOMMNU"

// Denominator choices — powers of two plus a few non-power values
// (irrational meters). Each item's id IS the denominator.
const DENOM_ITEMS = [_]widgets.MenuItem{
    .{ .label = "/1", .id = 1 },
    .{ .label = "/2", .id = 2 },
    .{ .label = "/3", .id = 3 },
    .{ .label = "/4", .id = 4 },
    .{ .label = "/6", .id = 6 },
    .{ .label = "/8", .id = 8 },
    .{ .label = "/12", .id = 12 },
    .{ .label = "/16", .id = 16 },
    .{ .label = "/32", .id = 32 },
};

/// Base meter (bar 0) editor: vertical-drag/scroll anywhere on the field
/// to set the numerator; right-click for a denominator menu. Edits stage
/// through MeterState and the engine adopts at the next bar boundary.
fn meterField(r: c.rl.Rectangle, state: *meter_mod.MeterState, m: widgets.Mouse) void {
    const base = state.liveMap().points[0];

    const new_num = widgets.dragValueV(r, METER_SALT, @floatFromInt(base.numerator), 1, 32, 0.1, 1.0, m);
    var num: u8 = @intFromFloat(@round(new_num));
    if (num < 1) num = 1;
    if (num != base.numerator) state.editMeterAt(0, num, base.denominator);

    // Right-click → denominator menu.
    if (m.right_pressed and widgets.contains(r, m.x, m.y)) widgets.openMenuAt(DENOM_MENU_KEY, m.x, m.y);
    if (widgets.menuOpen(DENOM_MENU_KEY)) {
        if (widgets.menuPickId(DENOM_MENU_KEY, &DENOM_ITEMS, m)) |id| {
            state.editMeterAt(0, base.numerator, @intCast(id));
        }
    }

    const inner = widgets.displayField(r);
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{d}/{d}", .{ base.numerator, base.denominator }) catch "?";
    widgets.drawLabelF(s.ptr, inner.x + 3, inner.y + 1, theme.fsBody(), theme.text_fg);

    const cap = "METER";
    const cap_w = widgets.measureTextF(cap, theme.fsTiny());
    widgets.drawLabelF(cap, inner.x + inner.width - cap_w - 2, inner.y + inner.height - theme.fsTiny() - 1, theme.fsTiny(), theme.text_mute);

    widgets.tooltip(r, "Meter: drag numerator, right-click denominator", m);
}

fn snapField(r: c.rl.Rectangle, edit_snap: snap_mod.Setting) void {
    const inner = widgets.displayField(r);
    const label = edit_snap.label();
    const tw = widgets.measureTextF(label, theme.fsBody());
    widgets.drawLabelF(label, inner.x + (inner.width - tw) / 2, inner.y + 1, theme.fsBody(), theme.text_fg);
}

fn handleTap(transport: *Transport) void {
    const now = c.rl.GetTime();
    // If too long since last tap, reset the buffer.
    if (tap_count > 0 and (now - tap_last) > 2.0) {
        tap_count = 0;
    }
    tap_last = now;
    if (tap_count < TAP_MAX) {
        tap_times[tap_count] = now;
        tap_count += 1;
    } else {
        // Shift left.
        var i: usize = 0;
        while (i < TAP_MAX - 1) : (i += 1) tap_times[i] = tap_times[i + 1];
        tap_times[TAP_MAX - 1] = now;
    }

    if (tap_count >= 2) {
        // Average interval between taps.
        var sum: f64 = 0;
        var n: usize = 0;
        var i: usize = 1;
        const end = tap_count;
        while (i < end) : (i += 1) {
            sum += tap_times[i] - tap_times[i - 1];
            n += 1;
        }
        if (n > 0) {
            const interval = sum / @as(f64, @floatFromInt(n));
            if (interval > 0.1) {
                const bpm: f32 = @floatCast(60.0 / interval);
                transport.setBpm(bpm);
            }
        }
    }
}
