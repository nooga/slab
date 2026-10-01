//! Mixer page (docs/23 §Mixer page): a strip per audio track, then the
//! buses, then the master pinned at the right edge. Toggled with M or the
//! MIX latch; it takes the arrangement's place and the machine bay below
//! follows the selected strip.
//!
//! A strip, top to bottom: title, inserts, a send knob per bus (turning
//! one up from nothing creates the send), output selector, pan, fader with
//! its meter and dB readout, then M/S/R. Groups show as bands across the
//! top, a level per nesting depth, spanning each group's strip and its
//! members'. A title drags its strip (with the selection) to a new place,
//! as an arrangement header does (docs/23 §Mixer page). Routing edits go out as
//! `route_menu.RouteEdit`s for main to apply with an undo step; levels,
//! pan, mute and solo are the tracks' atomics, set directly as the header
//! minis set them.

const std = @import("std");
const c = @import("../c.zig");
const bridge = @import("bridge.zig");
const ui_core = @import("core.zig");
const ui_style = @import("style.zig");
const ctl = @import("controls.zig");
const menu = @import("menu.zig");
const route_menu = @import("route_menu.zig");
const track_order = @import("track_order.zig");
const routing = @import("../routing.zig");
const automation = @import("../automation.zig");
const arrangement = @import("arrangement.zig");
const Track = @import("../track.zig").Track;
const Ui = ui_core.Ui;
const Rect = ui_core.Rect;

pub const STRIP_W: i32 = 84;
const HEAD_H: i32 = 20;
const TITLE_H: i32 = 22;
/// The color strip atop a title; a click on it picks the color.
const COLOR_H: i32 = 5;
/// One level of group bands.
const BAND_H: i32 = 12;
const INSERT_ROW_H: i32 = 12;
const INSERT_ROWS: i32 = 4;
const OUT_H: i32 = 16;
const BTN_H: i32 = 20;
const READOUT_H: i32 = 12;
const BUS_GAP: i32 = 8;
const FADER_W: i32 = 28;

var scroll_x: i32 = 0;
// A press on a strip's title: a drag from it moves the selected strips
// (or just it, when it isn't in the selection).
var press: ?u8 = null;
var press_x: i32 = 0;
var dragging = false;
var grab_dx: i32 = 0;
var narrow = false;

pub const Result = struct {
    route: ?route_menu.RouteEdit = null,
    /// The MIX latch was clicked: back to the arrangement.
    toggle: bool = false,
    add_track: bool = false,
    add_bus: bool = false,
    move_tracks: ?track_order.Move = null,
    color_pick: ?arrangement.ColorPick = null,
};

pub fn draw(
    ui: *Ui,
    r_legacy: c.rl.Rectangle,
    tracks: []Track,
    master: *Track,
    device_sel: *arrangement.DeviceSel,
    selected_track: *?usize,
    beat: f64,
) Result {
    var res: Result = .{};
    const r = bridge.fromRl(r_legacy);
    ui.rect(r, ui_style.chassis);
    var area = r;

    // Head: MIXER plate and the MIX latch that goes back.
    {
        ui.pushId("mixer-head");
        defer ui.popId();
        var head = area.cutTop(HEAD_H);
        var on = true;
        const mix_r = head.cutRight(40);
        if (ctl.button(ui, mix_r, "mix", &on, .{ .kind = .latch, .label = "MIX", .lit = ui_style.accent, .flush = true })) res.toggle = true;
        menu.tip(ui, mix_r, "Back to the arrangement (M)");
        const bus_r = head.cutRight(48);
        if (ctl.button(ui, bus_r, "add-bus", null, .{ .label = "+ BUS", .flush = true })) res.add_bus = true;
        menu.tip(ui, bus_r, "Add bus");
        const trk_r = head.cutRight(64);
        if (ctl.button(ui, trk_r, "add-track", null, .{ .label = "+ TRACK", .flush = true })) res.add_track = true;
        menu.tip(ui, trk_r, "Add track");
        const body = ui.plate(head, .{});
        _ = ui.engraved(&ui.fonts.legend, body.x + 5, body.y + 3, "MIXER", ui_style.text_dim);
    }

    // Tracks and groups (members of folded groups hidden) scroll; the
    // returns are pinned beside the master (docs/23 §Arrangement).
    const o = track_order.Order.of(tracks);
    const n_main: i32 = @intCast(o.main_n);
    const n_bus: i32 = @intCast(o.n - o.main_n);
    const send_rows: i32 = @divFloor(n_bus + 1, 2);
    // Group bands: as many levels as the deepest group nests.
    var levels: i32 = 0;
    for (o.main()) |row| levels = @max(levels, @as(i32, o.depth[row.ti]) + @intFromBool(o.is_group[row.ti]));
    const band = area.cutTop(levels * BAND_H);

    // Right to left: the master, then the returns beside it (pinned, like
    // a console's return section), then the tracks, which scroll sideways
    // when they don't fit.
    const master_r = area.cutRight(STRIP_W);
    const bus_w = @min(n_bus * STRIP_W, @max(0, area.w - STRIP_W - BUS_GAP));
    var bus_area = area.cutRight(bus_w);
    const bus_x0 = bus_area.x;
    if (n_bus > 0) _ = ui.plate(area.cutRight(BUS_GAP), .{ .fill = ui_style.face.shade(-8) });
    const tracks_area = area;

    // Tracks: horizontal scroll by the wheel (either axis) or the bar.
    const bar_h: i32 = 8;
    const content_w = n_main * STRIP_W;
    const overflow = content_w > tracks_area.w;
    var strips_r = tracks_area;
    const bar_r = if (overflow) strips_r.cutBottom(bar_h) else Rect{};
    if (tracks_area.contains(ui.in.ix(), ui.in.iy()) and !ui.in.cmd) {
        const wheel = if (ui.in.wheel_x != 0) ui.in.wheel_x else ui.in.wheel_y;
        scroll_x -= @intFromFloat(@round(wheel * 24));
    }
    const max_scroll = @max(0, content_w - strips_r.w);
    if (overflow) scrollBar(ui, bar_r, content_w, &scroll_x);
    scroll_x = std.math.clamp(scroll_x, 0, max_scroll);

    if (levels > 0) drawBands(ui, band, strips_r, tracks, &o, levels);
    ui.clip(strips_r);
    var x = strips_r.x - scroll_x;
    for (o.main()) |row| {
        drawStrip(ui, Rect.xywh(x, strips_r.y, STRIP_W, strips_r.h), tracks, &o, row.ti, send_rows, device_sel, selected_track, beat, &res);
        x += STRIP_W;
    }
    // Nothing shows bare chassis (docs/06 §Packing).
    if (x < strips_r.right()) _ = ui.plate(Rect.xywh(x, strips_r.y, strips_r.right() - x, strips_r.h), .{ .fill = ui_style.face.shade(-4) });
    ui.unclip();

    ui.clip(bus_area);
    for (o.returns()) |row| {
        drawStrip(ui, bus_area.cutLeft(STRIP_W), tracks, &o, row.ti, send_rows, device_sel, selected_track, beat, &res);
    }
    ui.unclip();

    drawMasterStrip(ui, master_r, master, send_rows, device_sel);
    dragStrips(ui, tracks, &o, selected_track, band, strips_r, bus_x0, &res);
    if (route_menu.tick(tracks)) |e| res.route = e;
    return res;
}

/// The rows every strip shares, so sections line up across the page.
const Rows = struct {
    title: Rect,
    inserts: Rect,
    sends: Rect,
    output: Rect,
    pan: Rect,
    fader: Rect,
    readout: Rect,
    buttons: Rect,

    fn of(r: Rect, send_rows: i32) Rows {
        var a = r;
        const knob = ctl.knobCell(.s, false);
        return .{
            .title = a.cutTop(TITLE_H),
            .inserts = a.cutTop(INSERT_ROWS * INSERT_ROW_H + 4),
            .sends = a.cutTop(send_rows * knob[1] + (if (send_rows > 0) @as(i32, 4) else 0)),
            .output = a.cutTop(OUT_H + 4),
            .pan = a.cutTop(ctl.knobCell(.m, false)[1] + 2),
            .buttons = a.cutBottom(BTN_H),
            .readout = a.cutBottom(READOUT_H),
            .fader = a,
        };
    }
};

fn drawStrip(
    ui: *Ui,
    r: Rect,
    tracks: []Track,
    o: *const track_order.Order,
    ti: usize,
    send_rows: i32,
    device_sel: *arrangement.DeviceSel,
    selected_track: *?usize,
    beat: f64,
    res: *Result,
) void {
    const t = &tracks[ti];
    ui.pushId(t);
    defer ui.popId();
    const selected = device_sel.* == .audio and arrangement.inSet(tracks, selected_track.*, ti);
    const body = ui.plate(r, .{ .fill = if (selected) ui_style.face.shade(8) else if (t.isBus() and !o.is_group[ti]) ui_style.face.shade(-4) else ui_style.face });
    const rows = Rows.of(body, send_rows);

    // Title: color bar, number or bus letter, name. Click selects (the
    // bay follows), right-click routes.
    {
        const tr = rows.title;
        // Edge to edge from the strip's top, so it joins the band above.
        const strip = Rect.xywh(r.x, r.y, r.w - 1, COLOR_H + tr.y - r.y);
        const cb = ui.behaviorEx(ui.id("color"), strip, .{ .focusable = false });
        ui.rect(strip, if (cb.hover) arrangement.trackColor(t.color).mix(ui_style.text, 0.25) else arrangement.trackColor(t.color));
        menu.tip(ui, strip, "Click to change the color");
        if (cb.pressed) res.color_pick = .{ .track = ti, .at = .{ strip.x, strip.bottom() } };
        if (selected) ui.rect(Rect.xywh(tr.x, tr.y + COLOR_H, tr.w, 2), ui_style.accent);
        var ibuf: [8]u8 = undefined;
        const tag = if (t.isBus()) std.fmt.bufPrint(&ibuf, "{c}", .{letterOf(tracks, ti)}) catch "?" else std.fmt.bufPrint(&ibuf, "{d}", .{o.number[ti]}) catch "?";
        var line = Rect.xywh(tr.x + 3, tr.y + COLOR_H + 1, tr.w - 6, tr.h - COLOR_H - 1);
        var fold_r: Rect = .{};
        if (o.is_group[ti]) {
            fold_r = line.cutLeft(10);
            const fb = ui.behaviorEx(ui.id("fold"), fold_r, .{ .focusable = false });
            if (fb.pressed) t.folded = !t.folded;
            ui.textIn(&ui.fonts.legend, fold_r, if (t.folded) "\u{25B8}" else "\u{25BE}", if (fb.hover) ui_style.text else ui_style.text_dim, .left, true);
            menu.tip(ui, fold_r, if (t.folded) "Unfold group" else "Fold group");
        }
        ui.textIn(&ui.fonts.legend, line.cutLeft(ui.fonts.legend.measure(tag) + 5), tag, ui_style.text_mute, .left, true);
        ui.marquee(&ui.fonts.body, line, t.name(), if (selected) ui_style.text else ui_style.text_dim, .left, true, tr.contains(ui.in.ix(), ui.in.iy()));
        const below = tr.y + COLOR_H;
        const title_hit = if (o.is_group[ti]) Rect.xywh(fold_r.right(), below, tr.right() - fold_r.right(), tr.bottom() - below) else Rect.xywh(tr.x, below, tr.w, tr.bottom() - below);
        const b = ui.behaviorEx(ui.id("title"), title_hit, .{ .focusable = false });
        if (b.pressed) {
            narrow = arrangement.headerSelect(tracks, selected_track, @intCast(ti), ui.in.shift, ui.in.cmd);
            device_sel.* = .audio;
            press = @intCast(ti);
            press_x = ui.in.ix();
            grab_dx = ui.in.ix() - r.x;
            dragging = false;
        }
        if (ui.in.right_pressed and title_hit.contains(ui.in.ix(), ui.in.iy())) route_menu.open(ti, .all, ui.in.ix(), ui.in.iy());
        menu.tip(ui, title_hit, "Click to edit in the bay, drag to move, right-click to route");
    }

    drawInserts(ui, rows.inserts, t, tracks);
    if (ui.behaviorEx(ui.id("inserts"), rows.inserts, .{ .focusable = false }).pressed) select(device_sel, selected_track, ti);

    // Sends: a knob per bus, two to a row, in bus order.
    {
        const cell = ctl.knobCell(.s, false);
        var k: i32 = 0;
        for (o.returns()) |ret| {
            const j = ret.ti;
            const col = @mod(k, 2);
            const row = @divFloor(k, 2);
            k += 1;
            const cr = Rect.xywh(rows.sends.x + 4 + col * @divFloor(rows.sends.w - 8, 2), rows.sends.y + 2 + row * cell[1], @divFloor(rows.sends.w - 8, 2), cell[1]);
            if (j == ti) continue;
            drawSendKnob(ui, cr, tracks, ti, @intCast(j), res);
        }
    }

    // Output selector.
    {
        var out_r = rows.output.insetXY(4, 2);
        out_r.h = OUT_H;
        var lbuf: [routing.MAX_TRACKS + 8]u8 = undefined;
        const dest = if (t.output == routing.NONE) "MASTER" else tracks[t.output].name();
        const lbl = std.fmt.bufPrint(&lbuf, "\u{2192} {s}", .{dest}) catch dest;
        if (ctl.button(ui, out_r, "output", null, .{ .label = lbl })) route_menu.open(ti, .output, out_r.x, out_r.bottom());
        menu.tip(ui, out_r, "Where this strip's signal goes");
    }

    // Pan.
    {
        var p: f32 = (t.panAt(beat) + 1) / 2;
        var pbuf: [16]u8 = undefined;
        const readout = fmtPan(&pbuf, p * 2 - 1);
        if (ctl.knob(ui, rows.pan, "pan", &p, .{ .size = .m, .variant = .bipolar, .label = "PAN", .default = 0.5, .show_readout = false, .readout = readout })) {
            t.setPan(p * 2 - 1);
            if (t.isAutomated(automation.Target.pan())) t.pan_override.store(if (ui.active == ui.id("pan")) 1 else 2, .monotonic);
        }
        if (ui.active == ui.id("pan")) t.touch_pan = true;
    }

    // Fader and meter.
    {
        var fr = rows.fader.insetXY(4, 2);
        const meter_r = fr.cutRight(fr.w - FADER_W - 2);
        var v: f32 = std.math.clamp(t.volumeAt(beat) / 1.25, 0.0, 1.0);
        var dbuf: [16]u8 = undefined;
        const db_s = fmtDb(&dbuf, v * 1.25);
        if (ctl.slider(ui, fr, "vol", &v, .{ .kind = .slider, .ticks = 11, .show_readout = false, .default = 1.0 / 1.25, .readout = db_s })) {
            t.setVolume(v * 1.25);
            if (t.isAutomated(automation.Target.volume())) t.vol_override.store(if (ui.active == ui.id("vol")) 1 else 2, .monotonic);
        }
        if (ui.active == ui.id("vol")) t.touch_vol = true;
        const peaks = t.meter();
        ctl.meterStereo(ui, meter_r.insetXY(2, 0), "meter", .{ peaks.l, peaks.r }, .{ peaks.l, peaks.r }, .{ .scale = .auto });
        ui.textIn(&ui.fonts.legend, rows.readout, db_s, ui_style.text_mute, .center, false);
    }

    // M S R.
    {
        var br = rows.buttons.insetXY(4, 2);
        const w = @divFloor(br.w, 3);
        var muted = t.mute.load(.monotonic);
        if (ctl.button(ui, br.cutLeft(w), "mute", &muted, .{ .kind = .latch, .label = "M", .lit = ui_style.led_blue })) t.mute.store(muted, .monotonic);
        var solo = t.solo.load(.monotonic);
        if (ctl.button(ui, br.cutLeft(w), "solo", &solo, .{ .kind = .latch, .label = "S", .lit = ui_style.led_yellow })) t.solo.store(solo, .monotonic);
        if (!t.isBus()) {
            var armed = t.isArmed();
            if (ctl.button(ui, br, "arm", &armed, .{ .kind = .latch, .label = "R", .lit = ui_style.rec })) t.setArmed(armed);
        }
    }
}

fn drawSendKnob(ui: *Ui, cr: Rect, tracks: []Track, ti: usize, bus: u8, res: *Result) void {
    const t = &tracks[ti];
    const existing = t.sendTo(bus);
    const level: f32 = if (existing) |s| s.level() else 0;
    // Half travel is 0 dB, full travel +6 dB (a linear gain of 2).
    var v: f32 = level / 2;
    var lbuf: [8]u8 = undefined;
    const pre = if (existing) |s| s.pre else false;
    const label = std.fmt.bufPrint(&lbuf, "{c}{s}", .{ letterOf(tracks, bus), if (pre) " PRE" else "" }) catch "?";
    var dbuf: [16]u8 = undefined;
    const readout = if (existing == null) "off" else fmtDb(&dbuf, level);
    const disabled = existing == null and !route_menu.canRoute(tracks, ti, bus);
    ui.pushId(.{ "send", bus });
    defer ui.popId();
    if (ctl.knob(ui, cr, "k", &v, .{ .size = .s, .label = label, .default = 0.5, .show_readout = false, .readout = readout, .disabled = disabled })) {
        if (existing) |s| s.setLevel(v * 2) else res.route = .{ .track = ti, .what = .{ .send_add = .{ .bus = bus, .level = v * 2 } } };
    }
    if (existing != null and ui.in.right_pressed and cr.contains(ui.in.ix(), ui.in.iy())) route_menu.openSend(ti, bus, ui.in.ix(), ui.in.iy());
    menu.tip(ui, cr, if (disabled) "Would feed back into itself" else if (existing != null) "Send level (right-click: pre/post, remove)" else "Turn up to send to this bus");
}

fn drawInserts(ui: *Ui, r: Rect, t: *const Track, tracks: []const Track) void {
    const w = ui.well(r.insetXY(4, 2), ui_style.well);
    const n = t.effects.items.len;
    const shown: usize = if (n > INSERT_ROWS) INSERT_ROWS - 1 else n;
    for (t.effects.items[0..shown], 0..) |*fx, i| {
        const row = Rect.xywh(w.x + 2, w.y + @as(i32, @intCast(i)) * INSERT_ROW_H, w.w - 4, INSERT_ROW_H);
        const off = t.effectBypassed(i);
        var nbuf: [64]u8 = undefined;
        const label = if (fx.mach.takes_key and fx.key < tracks.len)
            std.fmt.bufPrint(&nbuf, "{s} \u{2190} {s}", .{ fx.mach.name, tracks[fx.key].name() }) catch fx.mach.name
        else
            fx.mach.name;
        ui.marquee(&ui.fonts.legend, row, label, if (off) ui_style.text_mute else ui_style.text_dim, .left, false, true);
    }
    if (n > shown) {
        var buf: [16]u8 = undefined;
        const more = std.fmt.bufPrint(&buf, "+{d} more", .{n - shown}) catch "+";
        ui.textIn(&ui.fonts.legend, Rect.xywh(w.x + 2, w.y + @as(i32, @intCast(shown)) * INSERT_ROW_H, w.w - 4, INSERT_ROW_H), more, ui_style.text_mute, .left, false);
    } else if (n == 0) {
        ui.textIn(&ui.fonts.legend, Rect.xywh(w.x + 2, w.y, w.w - 4, INSERT_ROW_H), "no inserts", ui_style.text_mute, .left, false);
    }
}

fn drawMasterStrip(ui: *Ui, r: Rect, master: *Track, send_rows: i32, device_sel: *arrangement.DeviceSel) void {
    ui.pushId("master-strip");
    defer ui.popId();
    const selected = device_sel.* == .master;
    const body = ui.plate(r, .{ .fill = if (selected) ui_style.face.shade(8) else ui_style.face.shade(-4) });
    const rows = Rows.of(body, send_rows);
    {
        const tr = rows.title;
        ui.rect(Rect.xywh(tr.x, tr.y, tr.w, COLOR_H), ui_style.face_hi);
        if (selected) ui.rect(Rect.xywh(tr.x, tr.y + COLOR_H, tr.w, 2), ui_style.accent);
        ui.textIn(&ui.fonts.body_bold, Rect.xywh(tr.x + 3, tr.y + COLOR_H + 1, tr.w - 6, tr.h - COLOR_H - 1), "MASTER", if (selected) ui_style.text else ui_style.text_dim, .left, true);
        if (ui.behaviorEx(ui.id("title"), tr, .{ .focusable = false }).pressed) device_sel.* = .master;
    }
    drawInserts(ui, rows.inserts, master, &.{});
    if (ui.behaviorEx(ui.id("inserts"), rows.inserts, .{ .focusable = false }).pressed) device_sel.* = .master;
    {
        var p: f32 = (master.pan() + 1) / 2;
        var pbuf: [16]u8 = undefined;
        if (ctl.knob(ui, rows.pan, "bal", &p, .{ .size = .m, .variant = .bipolar, .label = "BAL", .default = 0.5, .show_readout = false, .readout = fmtPan(&pbuf, p * 2 - 1) })) master.setPan(p * 2 - 1);
    }
    {
        var fr = rows.fader.insetXY(4, 2);
        const meter_r = fr.cutRight(fr.w - FADER_W - 2);
        var v: f32 = std.math.clamp(master.volume() / 1.25, 0.0, 1.0);
        var dbuf: [16]u8 = undefined;
        const db_s = fmtDb(&dbuf, v * 1.25);
        if (ctl.slider(ui, fr, "vol", &v, .{ .kind = .slider, .ticks = 11, .show_readout = false, .default = 1.0 / 1.25, .readout = db_s })) master.setVolume(v * 1.25);
        const peaks = master.meter();
        ctl.meterStereo(ui, meter_r.insetXY(2, 0), "meter", .{ peaks.l, peaks.r }, .{ peaks.l, peaks.r }, .{ .scale = .auto, .clip_led = true });
        ui.textIn(&ui.fonts.legend, rows.readout, db_s, ui_style.text_mute, .center, false);
    }
    {
        const br = rows.buttons.insetXY(4, 2);
        var on = master.subsonic.load(.monotonic);
        if (ctl.button(ui, br, "subsonic", &on, .{ .kind = .latch, .label = "SUB 30" })) master.subsonic.store(on, .monotonic);
        menu.tip(ui, br, "Subsonic filter: 24 dB/oct highpass at 30 Hz before the master inserts");
    }
}

/// The group bands over the scrolling strips: per level, outermost on top,
/// a span in each group's color over its strip and its members' with its
/// name at the left. Below a strip's innermost group its color carries
/// on down to the strip's color bar; an ungrouped strip's band is
/// neutral.
fn drawBands(ui: *Ui, band: Rect, strips_r: Rect, tracks: []const Track, o: *const track_order.Order, levels: i32) void {
    ui.rect(band, ui_style.face.shade(-8));
    ui.clip(Rect.xywh(strips_r.x, band.y, strips_r.w, band.h));
    defer ui.unclip();
    const main = o.main();
    var lvl: i32 = 0;
    while (lvl < levels) : (lvl += 1) {
        const y = band.y + lvl * BAND_H;
        for (main, 0..) |row, k| {
            const at = bandAt(o, row.ti, lvl);
            if (at.group == routing.NONE) continue;
            const x0 = strips_r.x - scroll_x + @as(i32, @intCast(k)) * STRIP_W;
            const same_next = k + 1 < main.len and bandAt(o, main[k + 1].ti, lvl).group == at.group;
            const col = arrangement.trackColor(tracks[at.group].color);
            // The innermost level and its carry-on join what's below; a
            // group's span ends a pixel short of the next.
            ui.rect(Rect.xywh(x0, y, if (same_next) STRIP_W else STRIP_W - 1, if (at.inner) BAND_H else BAND_H - 1), col.mix(ui_style.face, 0.2));
            // The name once, where the group's span at its own level starts.
            const starts = k == 0 or bandAt(o, main[k - 1].ti, lvl).group != at.group;
            if (at.named and starts) {
                var end = k + 1;
                while (end < main.len and bandAt(o, main[end].ti, lvl).group == at.group) end += 1;
                const nr = Rect.xywh(x0 + 4, y, @as(i32, @intCast(end - k)) * STRIP_W - 6, BAND_H - 1);
                ui.clip(nr);
                ui.textIn(&ui.fonts.legend, nr, tracks[at.group].name(), ui_style.chassis, .left, true);
                ui.unclip();
            }
        }
    }
}

const BandAt = struct {
    group: u8,
    /// The strip's innermost group or below it.
    inner: bool,
    /// The group's own level, where its name goes.
    named: bool,
};

/// What strip `ti`'s band shows at level `lvl` (0: outermost): the group
/// it sits under that deep, counting a group as under itself, then its
/// innermost group carried on down; NONE for no group.
fn bandAt(o: *const track_order.Order, ti: u8, lvl: i32) BandAt {
    var chain: [routing.MAX_TRACKS]u8 = undefined;
    var n: usize = 0;
    if (o.is_group[ti]) {
        chain[0] = ti;
        n = 1;
    }
    var a = o.parent[ti];
    while (a != routing.NONE and n < chain.len) : (a = o.parent[a]) {
        chain[n] = a;
        n += 1;
    }
    if (n == 0) return .{ .group = routing.NONE, .inner = true, .named = false };
    // chain runs innermost first.
    const l: usize = @intCast(lvl);
    if (l >= n) return .{ .group = chain[0], .inner = true, .named = false };
    return .{ .group = chain[n - 1 - l], .inner = l == n - 1, .named = true };
}

/// A title drag in progress: past a few pixels it moves the selected
/// strips (or the pressed one alone), shown as a ghost of its title under
/// the pointer, the moved strips dimmed and a line where they'd land,
/// starting at the band level of the group they'd join. The strips scroll
/// near the edges.
fn dragStrips(ui: *Ui, tracks: []Track, o: *const track_order.Order, selected_track: *?usize, band: Rect, strips_r: Rect, bus_x0: i32, res: *Result) void {
    const from = press orelse return;
    if (from >= tracks.len) {
        press = null;
        return;
    }
    var set: [routing.MAX_TRACKS]bool = @splat(false);
    if (arrangement.inSet(tracks, selected_track.*, from)) {
        for (0..tracks.len) |k| set[k] = arrangement.inSet(tracks, selected_track.*, k);
    } else set[from] = true;
    var in_returns = false;
    for (o.returns()) |row| in_returns = in_returns or row.ti == from;
    const mx = ui.in.ix();
    if (!ui.in.down) {
        if (dragging) {
            if (dropAtX(o, in_returns, mx, strips_r, bus_x0)) |d| res.move_tracks = track_order.moveSet(tracks, &set, d.drop);
        } else if (narrow) {
            for (tracks) |*t| t.multi_sel = false;
        }
        press = null;
        dragging = false;
        narrow = false;
        return;
    }
    if (!dragging and @abs(mx - press_x) > 4) dragging = true;
    if (!dragging) return;
    if (!in_returns) {
        if (mx < strips_r.x + 16) scroll_x -= 8;
        if (mx > strips_r.right() - 16) scroll_x += 8;
        scroll_x = std.math.clamp(scroll_x, 0, @max(0, @as(i32, @intCast(o.main_n)) * STRIP_W - strips_r.w));
    }
    const top = band.y;
    const bottom = strips_r.bottom();
    // Dim the strips being moved.
    for (o.rows[0..o.n], 0..) |row, k| {
        var moving = set[row.ti];
        var a = o.parent[row.ti];
        while (a != routing.NONE) : (a = o.parent[a]) moving = moving or set[a];
        if (!moving) continue;
        const sx = stripX(o, k, strips_r, bus_x0);
        ui.rect(Rect.xywh(sx, strips_r.y, STRIP_W, strips_r.h), ui_style.chassis.alpha(150));
    }
    if (dropAtX(o, in_returns, mx, strips_r, bus_x0)) |d| if (track_order.moveSet(tracks, &set, d.drop) != null) {
        const lx = stripX(o, d.gap, strips_r, bus_x0) - 1;
        const ly = top + @as(i32, d.depth) * BAND_H;
        ui.rect(Rect.xywh(lx, top, 2, ly - top), ui_style.accent.alpha(110));
        ui.rect(Rect.xywh(lx, ly, 2, bottom - ly), ui_style.accent);
        ui.rect(Rect.xywh(lx - 3, ly, 8, 2), ui_style.accent);
    };
    // The ghost: the pressed strip's title, lifted.
    var others: usize = 0;
    if (arrangement.inSet(tracks, selected_track.*, from)) {
        for (0..tracks.len) |k| if (k != from and arrangement.inSet(tracks, selected_track.*, k)) {
            others += 1;
        };
    }
    const t = &tracks[from];
    const g = Rect.xywh(mx - grab_dx, strips_r.y + 10, STRIP_W, TITLE_H);
    ui.rect(g, ui_style.accent);
    ui.rect(g.insetXY(1, 1), ui_style.face.shade(10).alpha(235));
    ui.rect(Rect.xywh(g.x + 1, g.y + 1, g.w - 2, COLOR_H), arrangement.trackColor(t.color));
    var buf: [48]u8 = undefined;
    const label = if (others > 0) std.fmt.bufPrint(&buf, "{s} +{d}", .{ t.name(), others }) catch t.name() else t.name();
    _ = ui.text(&ui.fonts.legend, g.x + 4, g.y + COLOR_H + 4, label, ui_style.text);
}

/// The left edge of shown row `k`'s strip (row n: past the returns).
fn stripX(o: *const track_order.Order, k: usize, strips_r: Rect, bus_x0: i32) i32 {
    if (k < o.main_n) return strips_r.x - scroll_x + @as(i32, @intCast(k)) * STRIP_W;
    if (k == o.main_n) return if (o.n > o.main_n) bus_x0 else strips_r.x - scroll_x + @as(i32, @intCast(k)) * STRIP_W;
    return bus_x0 + @as(i32, @intCast(k - o.main_n)) * STRIP_W;
}

/// Where a title drag at x drops: left half of a strip before it, right
/// half after it (or into an open group, first); past the last, the end.
fn dropAtX(o: *const track_order.Order, returns: bool, mx: i32, strips_r: Rect, bus_x0: i32) ?track_order.DropAt {
    const lo: usize = if (returns) o.main_n else 0;
    const hi: usize = if (returns) o.n else o.main_n;
    if (hi == lo) return if (returns) null else track_order.dropEnd(o, false);
    const x0 = if (returns) bus_x0 else strips_r.x - scroll_x;
    const cx = mx - x0;
    if (cx < 0) return track_order.dropAt(o, lo, false);
    const k = lo + @as(usize, @intCast(@divFloor(cx, STRIP_W)));
    if (k >= hi) return track_order.dropEnd(o, returns);
    return track_order.dropAt(o, k, @mod(cx, STRIP_W) >= @divFloor(STRIP_W, 2));
}

/// A thin horizontal scroll bar: drag the thumb, or click the track to jump.
fn scrollBar(ui: *Ui, r: Rect, content_w: i32, scroll: *i32) void {
    const inner = ui.well(r, ui_style.well);
    const view = r.w;
    const thumb_w = @max(16, @divFloor(inner.w * view, content_w));
    const max_scroll = content_w - view;
    const travel = @max(1, inner.w - thumb_w);
    const b = ui.behaviorEx(ui.id("mixer-hscroll"), r, .{ .focusable = false });
    if (b.held) {
        const mx = ui.in.ix() - inner.x - @divFloor(thumb_w, 2);
        scroll.* = @divFloor(std.math.clamp(mx, 0, travel) * max_scroll, travel);
    }
    const tx = inner.x + @divFloor(std.math.clamp(scroll.*, 0, max_scroll) * travel, @max(1, max_scroll));
    ui.rect(Rect.xywh(tx, inner.y, thumb_w, inner.h), if (b.held) ui_style.accent else ui_style.text_mute);
}

fn select(device_sel: *arrangement.DeviceSel, selected_track: *?usize, ti: usize) void {
    selected_track.* = ti;
    device_sel.* = .audio;
}

fn letterOf(tracks: []const Track, ti: usize) u8 {
    var k: u8 = 0;
    for (tracks[0..ti]) |*t| {
        if (t.isBus()) k += 1;
    }
    return @as(u8, 'A') + @min(k, 25);
}

fn fmtDb(buf: []u8, gain: f32) []const u8 {
    if (gain <= 0.00001) return "-inf dB";
    return std.fmt.bufPrint(buf, "{d:.1} dB", .{20 * std.math.log10(gain)}) catch "?";
}

fn fmtPan(buf: []u8, p: f32) []const u8 {
    if (@abs(p) < 0.005) return "C";
    return std.fmt.bufPrint(buf, "{d:.0}{c}", .{ @abs(p) * 100, @as(u8, if (p < 0) 'L' else 'R') }) catch "?";
}
