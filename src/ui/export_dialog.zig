//! The Export sheet (docs/27 §The Export sheet): a preset up top, four
//! tabs (TRACKS, FORMAT, LEVEL, FILES & TAGS), the range and tail pinned
//! beside the tabs, and a footer that sums the export up. The settings
//! are the project's (export_settings.Settings) and each track's stem
//! choices live on the track; this file only holds what's on screen.
//! While the render runs the sheet shows its progress, then the report.
//! A `dialog` (modal; main suppresses the input behind it while `active`).

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const dialog = @import("dialog.zig");
const text_field = @import("text_field.zig");
const export_mod = @import("../export.zig");
const exporter = @import("../exporter.zig");
const markers_mod = @import("../markers.zig");
const xs = @import("../export_settings.zig");
const track_mod = @import("../track.zig");
const routing = @import("../routing.zig");
const storage = @import("../storage.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const TextBuf = text_field.TextBuf;

pub const Range = xs.Range;
pub const TAIL_MAX = xs.TAIL_MAX;

pub const Tab = enum(u8) { tracks = 0, format = 1, level = 2, files = 3 };

pub const State = struct {
    active: bool = false,
    tab: u8 = 0,
    /// The track list's scroll, px.
    scroll: i32 = 0,
    /// The text fields' editing buffers; they follow the settings while
    /// not being edited.
    folder: TextBuf = .{},
    mix_name: TextBuf = .{},
    stem_name: TextBuf = .{},
    title: TextBuf = .{},
    artist: TextBuf = .{},
    album: TextBuf = .{},
    year: TextBuf = .{},
    /// SAVE…: the preset's name being typed, in the title bar.
    naming: bool = false,
    preset_name: TextBuf = .{ .limit = 24 },
    /// A text field had the keyboard last frame: Enter and Esc are its.
    editing: bool = false,
    /// Set when anything changed (the project is dirty); main clears it.
    changed: bool = false,
    /// CHOOSE… was pressed: main opens the folder panel.
    want_folder: bool = false,
    /// The user presets changed: main saves them.
    presets_changed: bool = false,
    /// The last export's report: shown until DONE, then kept for LEVEL.
    card: ?Card = null,
    showing_card: bool = false,
    /// The last export's first file, for SHOW FILES.
    last_buf: [storage.MAX_PATH]u8 = undefined,
    last_len: usize = 0,

    pub fn last(self: *const State) []const u8 {
        return self.last_buf[0..self.last_len];
    }

    pub fn setLast(self: *State, path: []const u8) void {
        self.last_len = @min(path.len, self.last_buf.len);
        @memcpy(self.last_buf[0..self.last_len], path[0..self.last_len]);
    }
};

/// What the sheet works on, from main.
pub const Context = struct {
    settings: *xs.Settings,
    presets: *xs.UserPresets,
    tracks: []track_mod.Track,
    project: []const u8,
    bpm: f64,
    /// Each range's length in seconds; null where there's none (no loop,
    /// nothing selected, no sections).
    range_secs: [4]?f64,
    /// The song's sections, for SECTIONS: a file each.
    sections: []const markers_mod.Section = &.{},
};

/// Live render telemetry, sampled by main each frame from the worker job.
pub const Progress = struct {
    fraction: f32, // 0..1
    elapsed_s: f64, // wall-clock since start
    speed_x: f64, // rendered-audio-seconds / wall-seconds
    rendered_s: f64, // audio seconds produced so far
    total_s: f64, // audio seconds total
};

/// An export's report card (docs/27 §Normalize and the loudness report).
pub const Card = struct {
    has_mix: bool = false,
    lufs: f64 = -70,
    lra: f64 = 0,
    true_peak: f64 = -180,
    gain_db: f64 = 0,
    files: usize = 0,
    secs: f64 = 0,
    stem_names: [MAX_STEMS][24]u8 = undefined,
    stem_name_len: [MAX_STEMS]u8 = undefined,
    stem_lufs: [MAX_STEMS]f64 = undefined,
    stem_count: usize = 0,

    pub const MAX_STEMS = 32;

    pub fn addStem(self: *Card, name: []const u8, lufs: f64) void {
        if (self.stem_count == MAX_STEMS) return;
        const n = @min(name.len, 24);
        @memcpy(self.stem_names[self.stem_count][0..n], name[0..n]);
        self.stem_name_len[self.stem_count] = @intCast(n);
        self.stem_lufs[self.stem_count] = lufs;
        self.stem_count += 1;
    }
};

pub const Result = enum { none, cancel, render, reveal };

pub const W: i32 = 640;
pub const H: i32 = 460;
const ROW_H: i32 = 20;
const TAB_W: i32 = 92;
const LABEL_W: i32 = 84;
const SEGS: i32 = 32;

/// Open the sheet on its first tab's list, at the top.
pub fn open(state: *State) void {
    state.active = true;
    state.scroll = 0;
    state.naming = false;
    state.showing_card = false;
}

/// Draw the sheet centered in `screen`. `progress != null` while the
/// render runs.
pub fn draw(ui: *Ui, screen: Rect, state: *State, cx: Context, progress: ?Progress) Result {
    if (!state.active) return .none;
    if (state.showing_card) if (state.card) |*card| return drawCard(ui, screen, state, card);
    const f = dialog.begin(ui, screen, "export-sheet", "EXPORT", W, H);
    defer dialog.end(ui);
    if (progress) |p| {
        var body = f.body;
        _ = body.cutTop(40);
        drawProgress(ui, body, p);
        var bar = f.buttons;
        var buf: [160]u8 = undefined;
        summaryText(ui, bar.cutLeft(bar.w - 90), summary(&buf, cx), style.text_dim);
        if (dialog.buttons(ui, bar, &.{"CANCEL"}, null) != null or f.escape) return .cancel;
        return .none;
    }
    const editing = state.editing;
    state.editing = false;
    const before = snapshot(cx);

    presetBar(ui, f.title, state, cx);
    var body = f.body;
    // The tabs run the sheet's width, flush under the title rule.
    const strip = Rect.xywh(body.x - 8, body.y - 6, body.w + 16, ROW_H + 2);
    _ = ctl.tabs(ui, strip, "tabs", &state.tab, &.{ "TRACKS", "FORMAT", "LEVEL", "FILES & TAGS" }, TAB_W, !editing);
    rangeBar(ui, Rect.xywh(strip.x + 4 * TAB_W, strip.y, strip.w - 4 * TAB_W, strip.h - 1), cx);
    _ = body.cutTop(strip.h - 6 + 10);

    switch (@as(Tab, @enumFromInt(@min(state.tab, 3)))) {
        .tracks => tracksTab(ui, body, state, cx),
        .format => formatTab(ui, body, cx),
        .level => levelTab(ui, body, state, cx),
        .files => filesTab(ui, body, state, cx),
    }

    if (!std.mem.eql(u8, &before, &snapshot(cx))) {
        state.changed = true;
        // An edit leaves the preset: it reads CUSTOM until one matches.
        if (presetIndex(cx)) |i| {
            cx.settings.preset.set(if (i < xs.BUILTIN.len) xs.BUILTIN[i].name else cx.presets.names[i - xs.BUILTIN.len].get());
        } else cx.settings.preset.set("CUSTOM");
    }

    var bar = f.buttons;
    var buf: [160]u8 = undefined;
    const missing = rangeMissing(cx);
    const nothing = !cx.settings.recipe.mix and xs.stemCount(&cx.settings.recipe, cx.tracks) == 0;
    const sum = if (missing) |m| m else if (nothing) "NOTHING TO WRITE: TURN ON THE MIX OR SOME STEMS" else summary(&buf, cx);
    summaryText(ui, bar.cutLeft(bar.w - 2 * 76 - 12), sum, if (missing != null or nothing) style.rec else style.text_dim);
    const ok = missing == null and !nothing;
    if (dialog.buttons(ui, bar, &.{ "CANCEL", "EXPORT" }, 1)) |i| return if (i == 0) .cancel else if (ok) .render else .none;
    if (editing) return .none;
    if (f.escape) return .cancel;
    if (f.enter and ok) return .render;
    return .none;
}

/// The bytes that say whether anything changed this frame.
fn snapshot(cx: Context) [@sizeOf(xs.Settings) + routing.MAX_TRACKS * @sizeOf(track_mod.StemPlan)]u8 {
    var out: [@sizeOf(xs.Settings) + routing.MAX_TRACKS * @sizeOf(track_mod.StemPlan)]u8 = @splat(0);
    @memcpy(out[0..@sizeOf(xs.Settings)], std.mem.asBytes(cx.settings));
    for (cx.tracks, 0..) |*t, i| {
        const at = @sizeOf(xs.Settings) + i * @sizeOf(track_mod.StemPlan);
        @memcpy(out[at..][0..@sizeOf(track_mod.StemPlan)], std.mem.asBytes(&t.stem));
    }
    return out;
}

// ── Preset ───────────────────────────────────────────────────────────

/// The preset the settings match: a built-in, then a user one (offset by
/// the built-ins).
fn presetIndex(cx: Context) ?usize {
    const r = &cx.settings.recipe;
    const name = cx.settings.preset.get();
    // The named one first: two presets can hold the same recipe.
    for (&xs.BUILTIN, 0..) |*p, i| if (std.mem.eql(u8, p.name, name) and p.recipe.eql(r)) return i;
    if (cx.presets.find(name)) |i| if (cx.presets.recipes[i].eql(r)) return xs.BUILTIN.len + i;
    for (&xs.BUILTIN, 0..) |*p, i| if (p.recipe.eql(r)) return i;
    for (0..cx.presets.count) |i| if (cx.presets.recipes[i].eql(r)) return xs.BUILTIN.len + i;
    return null;
}

fn presetBar(ui: *Ui, r_: Rect, state: *State, cx: Context) void {
    var r = r_;
    ui.pushId("preset");
    defer ui.popId();
    const s = cx.settings;
    if (state.naming) {
        // SAVE…: type a name; Enter saves it, Esc gives up.
        const ok_r = r.cutRight(52).center(52, 16);
        _ = r.cutRight(4);
        const field_r = r.cutRight(180).center(180, 16);
        _ = r.cutRight(6);
        ui.textIn(&ui.fonts.legend, r, "SAVE AS", style.text_dim, .right, true);
        const ev = text_field.field(ui, field_r, "name", &state.preset_name, .{ .focus = !state.editing and ui.focus != ui.id("name") });
        state.editing = true;
        const save = ctl.button(ui, ok_r, "save", null, .{ .label = "SAVE" }) or ev == .commit;
        if (save and state.preset_name.len > 0) {
            var nb: [24]u8 = undefined;
            const name = std.ascii.upperString(&nb, state.preset_name.text());
            cx.presets.put(name, s.recipe);
            s.preset.set(name);
            state.presets_changed = true;
            state.naming = false;
        } else if (save or ev == .cancel) state.naming = false;
        return;
    }
    var names: [xs.BUILTIN.len + xs.UserPresets.MAX + 1][]const u8 = undefined;
    for (xs.BUILTIN, 0..) |p, i| names[i] = p.name;
    for (0..cx.presets.count) |i| names[xs.BUILTIN.len + i] = cx.presets.names[i].get();
    const n = xs.BUILTIN.len + cx.presets.count;
    const at = presetIndex(cx);
    const user = if (at) |i| i >= xs.BUILTIN.len else false;
    if (user) {
        if (ctl.button(ui, r.cutRight(20).center(20, 16), "delete", null, .{ .label = "X", .touch_name = "DELETE PRESET", .touch_value = s.preset.get() })) {
            cx.presets.remove(at.? - xs.BUILTIN.len);
            state.presets_changed = true;
            s.preset.set("CUSTOM");
            return;
        }
        _ = r.cutRight(4);
    }
    if (ctl.button(ui, r.cutRight(52).center(52, 16), "save", null, .{ .label = "SAVE…", .touch_name = "SAVE AS A PRESET" })) {
        state.naming = true;
        state.preset_name = TextBuf.init(if (at == null) "" else s.preset.get(), 24);
        state.preset_name.selectAll();
    }
    _ = r.cutRight(6);
    var v: u8 = @intCast(at orelse n);
    names[n] = "CUSTOM";
    const sel_r = r.cutRight(150).center(150, ctl.displayHeight(false));
    if (ctl.displaySelectEx(ui, sel_r, "pick", &v, names[0..n], "PRESET", .{ .align_ = .left, .shown = if (at == null) "CUSTOM" else null, .dim = at == null })) {
        if (v < xs.BUILTIN.len) {
            s.recipe = xs.BUILTIN[v].recipe;
            s.preset.set(xs.BUILTIN[v].name);
        } else if (v < n) {
            s.recipe = cx.presets.recipes[v - xs.BUILTIN.len];
            s.preset.set(names[v]);
        }
    }
    _ = r.cutRight(6);
    // What the chosen preset is for.
    const about = if (at) |i| (if (i < xs.BUILTIN.len) xs.BUILTIN[i].about else "YOUR PRESET") else "EDITED";
    ui.textIn(&ui.fonts.legend, r, about, style.text_mute, .right, false);
}

// ── Range and tail, beside the tabs ──────────────────────────────────

const TAILS = [_][]const u8{ "AUTO", "WRAP", "1 S", "2 S", "4 S", "8 S", "15 S", "30 S" };
const TAIL_SECS = [_]f32{ 0, 0, 1, 2, 4, 8, 15, 30 };

fn tailIndex(r: *const xs.Recipe) u8 {
    if (r.wrap) return 1;
    if (r.tail_auto) return 0;
    for (TAIL_SECS[2..], 2..) |sec, i| if (r.tail_sec <= sec) return @intCast(i);
    return TAILS.len - 1;
}

fn setTail(r: *xs.Recipe, i: u8) void {
    r.wrap = i == 1;
    r.tail_auto = i <= 1;
    if (i >= 2) r.tail_sec = TAIL_SECS[@min(i, TAIL_SECS.len - 1)];
}

fn rangeBar(ui: *Ui, r_: Rect, cx: Context) void {
    var r = r_.insetXY(8, 0);
    const rec = &cx.settings.recipe;
    const h = ctl.displayHeight(false);
    var tail = tailIndex(rec);
    const tail_r = r.cutRight(64).center(64, h);
    _ = r.cutRight(4);
    ui.textIn(&ui.fonts.legend, r.cutRight(30), "TAIL", style.text_dim, .right, true);
    _ = r.cutRight(10);
    if (ctl.displaySelectEx(ui, tail_r, "tail", &tail, &TAILS, "TAIL", .{ .align_ = .left })) setTail(rec, tail);
    var range: u8 = @intFromEnum(rec.range);
    const range_r = r.cutRight(88).center(88, h);
    _ = r.cutRight(4);
    ui.textIn(&ui.fonts.legend, r.cutRight(40), "RANGE", style.text_dim, .right, true);
    if (ctl.displaySelectEx(ui, range_r, "range", &range, &.{ "PROJECT", "LOOP", "SELECTION", "SECTIONS" }, "RANGE", .{ .align_ = .left })) rec.range = @enumFromInt(range);
}

/// Why the chosen range can't render, if it can't.
fn rangeMissing(cx: Context) ?[]const u8 {
    return switch (cx.settings.recipe.range) {
        .project => if (cx.range_secs[0] == null) "THE PROJECT HAS NO CLIPS TO EXPORT" else null,
        .loop => if (cx.range_secs[1] == null) "NO LOOP: SET ONE ON THE RULER, OR PICK ANOTHER RANGE" else null,
        .selection => if (cx.range_secs[2] == null) "NOTHING SELECTED: SELECT CLIPS, OR PICK ANOTHER RANGE" else null,
        .sections => if (cx.range_secs[3] == null) "NO SECTIONS: ADD THEM IN THE LANE ABOVE THE RULER" else null,
    };
}

// ── TRACKS ───────────────────────────────────────────────────────────

const SIGNALS = [_][]const u8{ "INSTR", "FX", "FADER" };
const SIGNALS_D = [_][]const u8{ "DEFAULT", "INSTR", "FX", "FADER" };
const CHANNELS = [_][]const u8{ "STEREO", "MONO", "AUTO" };
const CHANNELS_D = [_][]const u8{ "DEFAULT", "STEREO", "MONO", "AUTO" };

/// The track list's columns, left to right after the LED.
const Cols = struct {
    led: Rect,
    name: Rect,
    kind: Rect,
    signal: Rect,
    channels: Rect,
    file: Rect,

    fn of(row: Rect) Cols {
        var r = row;
        var c: Cols = undefined;
        c.led = r.cutLeft(20);
        c.file = r.cutRight(170);
        _ = r.cutRight(8);
        c.channels = r.cutRight(76);
        _ = r.cutRight(4);
        c.signal = r.cutRight(76);
        _ = r.cutRight(8);
        c.kind = r.cutRight(52);
        c.name = r;
        return c;
    }
};

fn kindOf(tracks: []const track_mod.Track, ti: usize) []const u8 {
    const t = &tracks[ti];
    if (!t.isBus()) return "TRACK";
    for (tracks) |*u| if (u.output == ti) return "GROUP";
    for (tracks) |*u| for (u.sends[0..u.send_count]) |*snd| if (snd.bus == ti) return "RETURN";
    return "BUS";
}

fn tracksTab(ui: *Ui, body_in: Rect, state: *State, cx: Context) void {
    var body = body_in;
    const s = cx.settings;
    const rec = &s.recipe;
    ui.pushId("tracks");
    defer ui.popId();

    // Column legends.
    {
        const c = Cols.of(body.cutTop(14));
        const lg = &ui.fonts.legend;
        ui.textIn(lg, c.name, "SOURCE", style.text_mute, .left, true);
        ui.textIn(lg, c.kind, "KIND", style.text_mute, .left, true);
        ui.textIn(lg, c.signal, "SIGNAL", style.text_mute, .left, true);
        ui.textIn(lg, c.channels, "CHANNELS", style.text_mute, .left, true);
        ui.textIn(lg, c.file, "FILE", style.text_mute, .left, true);
        _ = body.cutTop(2);
    }
    const foot = body.cutBottom(ROW_H);
    _ = body.cutBottom(6);
    const well = ui.well(body, style.pane);

    // The mix and the stems' defaults, fixed at the top.
    var top = well;
    var name_buf: [256]u8 = undefined;
    {
        const row = top.cutTop(ROW_H + 2);
        ui.rect(row, style.face.shade(-14));
        const c = Cols.of(row.insetXY(4, 1));
        _ = ctl.ledToggle(ui, c.led, "mix", &rec.mix, false);
        ui.textIn(&ui.fonts.body_bold, c.name, "MIX", if (rec.mix) style.text else style.text_mute, .left, false);
        ui.textIn(&ui.fonts.legend, c.kind, "MASTER", style.text_mute, .left, false);
        ui.textIn(&ui.fonts.legend, c.signal.insetXY(3, 0), "MASTER OUT", style.text_mute, .left, false);
        var ch: u8 = @intFromEnum(rec.mix_channels);
        if (ctl.displaySelectEx(ui, c.channels.center(c.channels.w, ctl.displayHeight(false)), "mix-ch", &ch, &CHANNELS, "MIX CHANNELS", .{ .align_ = .left, .disabled = !rec.mix })) rec.mix_channels = @enumFromInt(ch);
        fileCell(ui, c.file, if (rec.mix) mixFile(&name_buf, cx) else "-", rec.mix);
    }
    {
        const row = top.cutTop(ROW_H + 2);
        ui.rect(row, style.face.shade(-14));
        ui.rect(Rect.xywh(row.x, row.bottom() - 1, row.w, 1), style.edge);
        const c = Cols.of(row.insetXY(4, 1));
        _ = ctl.ledToggle(ui, c.led, "stems", &rec.stems, false);
        ui.textIn(&ui.fonts.body_bold, c.name, "STEMS", if (rec.stems) style.text else style.text_mute, .left, false);
        ui.textIn(&ui.fonts.legend, c.kind, "DEFAULTS", style.text_mute, .left, false);
        const h = ctl.displayHeight(false);
        var sig: u8 = @intFromEnum(rec.stem_signal);
        if (ctl.displaySelectEx(ui, c.signal.center(c.signal.w, h), "sig", &sig, &SIGNALS, "STEM SIGNAL", .{ .align_ = .left, .disabled = !rec.stems })) rec.stem_signal = @enumFromInt(sig);
        var ch: u8 = @intFromEnum(rec.stem_channels);
        if (ctl.displaySelectEx(ui, c.channels.center(c.channels.w, h), "ch", &ch, &CHANNELS, "STEM CHANNELS", .{ .align_ = .left, .disabled = !rec.stems })) rec.stem_channels = @enumFromInt(ch);
        const n = xs.stemCount(rec, cx.tracks);
        var cb: [48]u8 = undefined;
        fileCell(ui, c.file, if (rec.stems) std.fmt.bufPrint(&cb, "{d} OF {d} SOURCES", .{ n, cx.tracks.len }) catch "" else "OFF", rec.stems);
    }

    // The tracks, scrolling under them.
    const list = top;
    const content_h: i32 = @as(i32, @intCast(cx.tracks.len)) * ROW_H;
    const max_scroll = @max(0, content_h - list.h);
    if (list.contains(ui.in.ix(), ui.in.iy()) and !ui.in.cmd and ui.in.wheel_y != 0) {
        state.scroll -= @intFromFloat(ui.in.wheel_y * ROW_H);
    }
    state.scroll = std.math.clamp(state.scroll, 0, max_scroll);
    ui.clip(list);
    const auto = xs.autoSet(cx.tracks);
    var nn: usize = 0;
    for (cx.tracks, 0..) |*t, ti| {
        const on_now = xs.stemOn(cx.tracks, ti, auto);
        if (rec.stems and on_now) nn += 1;
        const y = list.y + @as(i32, @intCast(ti)) * ROW_H - state.scroll;
        if (y + ROW_H <= list.y or y >= list.bottom()) continue;
        const row = Rect.xywh(list.x, y, list.w - 6, ROW_H);
        if (ti % 2 == 1) ui.rect(row, style.pane_alt);
        ui.pushId(ti);
        defer ui.popId();
        const c = Cols.of(row.insetXY(4, 0));
        const live = rec.stems;
        var on = on_now;
        if (ctl.ledToggle(ui, c.led, "on", &on, !live)) t.stem.on = on;
        const name_r = c.name;
        ui.rect(Rect.xywh(name_r.x, name_r.y + 4, 4, name_r.h - 8), @bitCast(t.color));
        ui.textIn(&ui.fonts.body, Rect.xywh(name_r.x + 10, name_r.y, name_r.w - 10, name_r.h), t.name(), if (live and on) style.text else style.text_mute, .left, false);
        ui.textIn(&ui.fonts.legend, c.kind, kindOf(cx.tracks, ti), style.text_mute, .left, false);
        const h = ctl.displayHeight(false);
        const usable = live and on;
        var sig = t.stem.signal;
        const sig_shown = if (sig == 0) SIGNALS[@intFromEnum(rec.stem_signal)] else null;
        if (ctl.displaySelectEx(ui, c.signal.center(c.signal.w, h), "sig", &sig, &SIGNALS_D, "SIGNAL", .{ .align_ = .left, .shown = sig_shown, .dim = sig == 0, .disabled = !usable })) t.stem.signal = sig;
        var ch = t.stem.channels;
        const ch_shown = if (ch == 0) CHANNELS[@intFromEnum(rec.stem_channels)] else null;
        if (ctl.displaySelectEx(ui, c.channels.center(c.channels.w, h), "ch", &ch, &CHANNELS_D, "CHANNELS", .{ .align_ = .left, .shown = ch_shown, .dim = ch == 0, .disabled = !usable })) t.stem.channels = ch;
        fileCell(ui, c.file, if (usable) stemFile(&name_buf, cx, nn, t.name()) else "-", usable);
    }
    ui.unclip();
    if (max_scroll > 0) {
        // A thin bar: where the view is in the list.
        const track_r = Rect.xywh(list.right() - 4, list.y + 1, 3, list.h - 2);
        ui.rect(track_r, style.well);
        const th = @max(12, @divFloor(list.h * list.h, content_h));
        const ty = track_r.y + @divFloor((track_r.h - th) * state.scroll, max_scroll);
        ui.rect(Rect.xywh(track_r.x, ty, 3, th), style.face_hi);
    }

    // Quick picks for the whole list.
    var f = foot;
    ui.textIn(&ui.fonts.legend, f.cutLeft(52), "SELECT", style.text_dim, .left, true);
    const picks = [_][]const u8{ "ALL", "NONE", "TRACKS", "BUSES", "DEFAULT" };
    for (picks, 0..) |lab, i| {
        if (ctl.button(ui, f.cutLeft(64).center(64, 16), lab, null, .{ .label = lab, .disabled = !rec.stems })) {
            for (cx.tracks) |*t| t.stem.on = switch (i) {
                0 => true,
                1 => false,
                2 => !t.isBus(),
                3 => t.isBus(),
                else => null,
            };
            if (i == 4) for (cx.tracks) |*t| {
                t.stem = .{};
            };
        }
        _ = f.cutLeft(4);
    }
    ui.textIn(&ui.fonts.legend, f, "DEFAULT: EVERY TRACK THAT PLAYS", style.text_mute, .right, false);
}

fn fileCell(ui: *Ui, r: Rect, s: []const u8, on: bool) void {
    ui.marquee(&ui.fonts.legend, r, s, if (on) style.text_dim else style.text_mute, .left, false, ui.in.ix() >= r.x and ui.in.ix() < r.right() and ui.in.iy() >= r.y and ui.in.iy() < r.bottom());
}

/// The fields a file's name is filled from; with SECTIONS, the first
/// section's.
fn nameFields(cx: Context, nn: usize, track: []const u8, date: []const u8) export_mod.NameFields {
    const sec = cx.settings.recipe.range == .sections and cx.sections.len > 0;
    return .{ .project = cx.project, .nn = nn, .track = track, .date = date, .bpm = cx.bpm, .sn = if (sec) 1 else 0, .section = if (sec) cx.sections[0].name.get() else "" };
}

/// The template a file is named by: with SECTIONS, a file per section.
fn template(buf: []u8, cx: Context, t: []const u8, stem: bool) []const u8 {
    return if (cx.settings.recipe.range == .sections) export_mod.sectionTemplate(buf, t, stem) else t;
}

fn mixFile(buf: []u8, cx: Context) []const u8 {
    var db: [10]u8 = undefined;
    var nb: [200]u8 = undefined;
    var tb: [256]u8 = undefined;
    const name = export_mod.fillName(&nb, template(&tb, cx, cx.settings.recipe.mix_name.get(), false), nameFields(cx, 0, "", export_mod.today(&db)));
    return std.fmt.bufPrint(buf, "{s}{s}", .{ name, cx.settings.recipe.container.ext() }) catch "";
}

fn stemFile(buf: []u8, cx: Context, nn: usize, track: []const u8) []const u8 {
    var db: [10]u8 = undefined;
    var nb: [200]u8 = undefined;
    var tb: [256]u8 = undefined;
    const name = export_mod.fillName(&nb, template(&tb, cx, cx.settings.recipe.stem_name.get(), true), nameFields(cx, nn, track, export_mod.today(&db)));
    return std.fmt.bufPrint(buf, "{s}{s}", .{ name, cx.settings.recipe.container.ext() }) catch "";
}

// ── FORMAT ───────────────────────────────────────────────────────────

const FORMATS = [_][]const u8{ "WAV", "AIFF", "FLAC", "ALAC (M4A)", "AAC (M4A)" };
const FORMAT_ABOUT = [_][]const u8{
    "UNCOMPRESSED; PLAYS EVERYWHERE",
    "UNCOMPRESSED; APPLE'S WAV",
    "LOSSLESS; ABOUT HALF THE SIZE OF WAV",
    "APPLE LOSSLESS; FOR MUSIC AND IOS",
    "LOSSY AND SMALL; FOR PREVIEWS",
};
const DEPTHS = [_][]const u8{ "16-BIT", "24-BIT", "32-BIT FLOAT" };
const RATES = [_][]const u8{ "44.1 KHZ", "48 KHZ", "88.2 KHZ", "96 KHZ" };
const KBPS = [_][]const u8{ "128 KB/S", "192 KB/S", "256 KB/S", "320 KB/S" };
const LEVELS = [_][]const u8{ "0 FASTEST", "1", "2", "3", "4", "5 DEFAULT", "6", "7", "8 SMALLEST" };

fn select(ui: *Ui, body: *Rect, key: []const u8, label: []const u8, v: *u8, options: []const []const u8, o: ctl.SelectOpts) bool {
    const r = dialog.rowW(ui, body, label, ROW_H, LABEL_W);
    const w = @min(r.w, 150);
    var oo = o;
    oo.align_ = .left;
    return ctl.displaySelectEx(ui, Rect.xywh(r.x, r.y + @divFloor(r.h - ctl.displayHeight(false), 2), w, ctl.displayHeight(false)), key, v, options, label, oo);
}

fn formatTab(ui: *Ui, body_in: Rect, cx: Context) void {
    ui.pushId("format");
    defer ui.popId();
    const rec = &cx.settings.recipe;
    var left = body_in;
    var right = left.cutRight(@divFloor(left.w, 2) - 8);
    _ = left.cutRight(16);

    dialog.section(ui, &left, "FILE");
    var cont: u8 = @intFromEnum(rec.container);
    if (select(ui, &left, "format", "FORMAT", &cont, &FORMATS, .{})) rec.container = @enumFromInt(cont);
    dialog.hint(ui, &left, FORMAT_ABOUT[cont], LABEL_W);
    if (rec.container == .aac) {
        _ = select(ui, &left, "kbps", "BITRATE", &rec.aac_kbps, &KBPS, .{});
    } else {
        var bits: u8 = @intFromEnum(rec.bits);
        const opts: []const []const u8 = if (rec.container.intOnly()) DEPTHS[0..2] else &DEPTHS;
        if (rec.container.intOnly() and bits == 2) bits = 1;
        if (select(ui, &left, "depth", "DEPTH", &bits, opts, .{})) rec.bits = @enumFromInt(bits);
    }
    _ = select(ui, &left, "rate", "SAMPLE RATE", &rec.rate, &RATES, .{});
    if (rec.container == .flac) {
        _ = select(ui, &left, "level", "COMPRESSION", &rec.flac_level, &LEVELS, .{});
        dialog.hint(ui, &left, "THE SAME AUDIO AT ANY LEVEL; HIGHER IS SMALLER, SLOWER", LABEL_W);
    }

    dialog.section(ui, &right, "CONVERSION");
    const sixteen = rec.bits == .pcm16 and rec.container != .aac;
    var dither: u8 = if (rec.dither) 0 else 1;
    if (select(ui, &right, "dither", "DITHER", &dither, &.{ "TPDF", "OFF" }, .{ .disabled = !sixteen })) rec.dither = dither == 0;
    dialog.hint(ui, &right, if (sixteen) "MASKS THE ROUNDING TO 16 BITS" else "ONLY FOR 16-BIT FILES", LABEL_W);
    dialog.hint(ui, &right, "RENDERED AT 48 KHZ; OTHER RATES", LABEL_W);
    dialog.hint(ui, &right, "ARE CONVERTED AFTERWARDS", LABEL_W);

    dialog.section(ui, &right, "SIZE");
    var buf: [64]u8 = undefined;
    const secs = cx.range_secs[@intFromEnum(rec.range)] orelse 0;
    const per = bytesPerSec(rec);
    const files = fileCount(cx);
    const row = dialog.rowW(ui, &right, "ESTIMATE", ROW_H, LABEL_W);
    var sb: [16]u8 = undefined;
    ctl.display(ui, row.center(row.w, ctl.displayHeight(false)), std.fmt.bufPrint(&buf, "{d} FILE{s}  {s}", .{ files, if (files == 1) "" else "S", sizeText(&sb, per * secs * @as(f64, @floatFromInt(outputCount(cx)))) }) catch "", .{ .align_ = .left });
}

/// Stereo bytes per second, about (FLAC and ALAC at their typical ratio).
fn bytesPerSec(rec: *const xs.Recipe) f64 {
    const f = rec.format();
    const raw: f64 = @floatFromInt(f.sample_rate * 2 * f.bits.bytes());
    return switch (rec.container) {
        .wav, .aiff => raw,
        .flac, .alac => raw * 0.6,
        .aac => @as(f64, @floatFromInt(f.aac_kbps)) * 1000 / 8,
    };
}

fn sizeText(buf: []u8, bytes: f64) []const u8 {
    if (bytes >= 1e9) return std.fmt.bufPrint(buf, "{d:.1} GB", .{bytes / 1e9}) catch "";
    if (bytes >= 1e6) return std.fmt.bufPrint(buf, "{d:.0} MB", .{bytes / 1e6}) catch "";
    return std.fmt.bufPrint(buf, "{d:.0} KB", .{bytes / 1e3}) catch "";
}

/// The mix and the stems: what the song is written as.
fn outputCount(cx: Context) usize {
    const rec = &cx.settings.recipe;
    return @intFromBool(rec.mix) + xs.stemCount(rec, cx.tracks);
}

/// Files written: SECTIONS cuts each output into a file per section (the
/// same audio, so the same size).
fn fileCount(cx: Context) usize {
    const n = outputCount(cx);
    return if (cx.settings.recipe.range == .sections) n * @max(1, cx.sections.len) else n;
}

// ── LEVEL ────────────────────────────────────────────────────────────

const NORMALIZE = [_][]const u8{ "OFF", "TO A PEAK", "TO A LOUDNESS" };
const LUFS_NAMES = [_][]const u8{ "-9 LUFS CLUB", "-14 LUFS STREAMING", "-16 LUFS APPLE", "-23 LUFS BROADCAST" };
const PEAK_NAMES = [_][]const u8{ "-0.1 DBTP", "-1 DBTP", "-3 DBTP" };
const CEILING_NAMES = [_][]const u8{ "-1 DBTP", "-2 DBTP", "-0.3 DBTP" };

fn levelTab(ui: *Ui, body_in: Rect, state: *State, cx: Context) void {
    ui.pushId("level");
    defer ui.popId();
    const rec = &cx.settings.recipe;
    var left = body_in;
    var right = left.cutRight(@divFloor(left.w, 2) - 8);
    _ = left.cutRight(16);

    dialog.section(ui, &left, "NORMALIZE");
    var mode: u8 = @intFromEnum(rec.normalize);
    if (select(ui, &left, "mode", "MIX", &mode, &NORMALIZE, .{ .disabled = !rec.mix })) rec.normalize = @enumFromInt(mode);
    switch (rec.normalize) {
        .off => dialog.hint(ui, &left, if (rec.mix) "WRITTEN AS MIXED" else "TURN ON THE MIX TO NORMALIZE", LABEL_W),
        .peak => {
            _ = select(ui, &left, "peak", "TARGET", &rec.peak_target, &PEAK_NAMES, .{});
            dialog.hint(ui, &left, "THE TRUE PEAK, 4X OVERSAMPLED, LANDS HERE", LABEL_W);
        },
        .loudness => {
            _ = select(ui, &left, "lufs", "TARGET", &rec.lufs_target, &LUFS_NAMES, .{});
            _ = select(ui, &left, "ceiling", "CEILING", &rec.ceiling, &CEILING_NAMES, .{});
            dialog.hint(ui, &left, "INTEGRATED LOUDNESS (BS.1770), NEVER PAST", LABEL_W);
            dialog.hint(ui, &left, "THE CEILING: A LOUD MIX STOPS SHORT", LABEL_W);
        },
    }
    dialog.section(ui, &left, "STEMS");
    var gain: u8 = @intFromEnum(rec.stem_gain);
    const normalizing = rec.normalize != .off and rec.mix;
    if (select(ui, &left, "gain", "GAIN", &gain, &.{ "SAME AS THE MIX", "AS MIXED" }, .{ .disabled = !normalizing or !rec.stems })) rec.stem_gain = @enumFromInt(gain);
    dialog.hint(ui, &left, if (rec.stem_gain == .mix) "THEY KEEP THEIR BALANCE AND SUM TO THE MIX" else "EACH AT ITS LEVEL IN THE SONG", LABEL_W);

    dialog.section(ui, &right, "LAST EXPORT");
    if (state.card) |*card| if (card.has_mix) {
        var b: [48]u8 = undefined;
        readout(ui, &right, "LOUDNESS", std.fmt.bufPrint(&b, "{d:.1} LUFS", .{card.lufs}) catch "", style.vfd);
        readout(ui, &right, "RANGE", std.fmt.bufPrint(&b, "{d:.1} LU", .{card.lra}) catch "", style.vfd);
        readout(ui, &right, "TRUE PEAK", std.fmt.bufPrint(&b, "{d:.1} DBTP", .{card.true_peak}) catch "", if (card.true_peak > -1) style.rec else style.vfd);
        readout(ui, &right, "GAIN", gainText(&b, card.gain_db), style.vfd);
        return;
    };
    dialog.hint(ui, &right, "EXPORT THE MIX ONCE TO SEE ITS NUMBERS", 0);
}

fn readout(ui: *Ui, body: *Rect, label: []const u8, s: []const u8, col: core.Color) void {
    const r = dialog.rowW(ui, body, label, ROW_H, LABEL_W);
    ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), s, .{ .align_ = .left, .color = col });
}

fn gainText(buf: []u8, db: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d:.1} DB", .{ if (db >= 0) "+" else "", db }) catch "";
}

// ── FILES & TAGS ─────────────────────────────────────────────────────

/// A text field on `field`: it shows the setting until edited, and
/// writes it back as it changes. `placeholder` stands in when empty.
fn textRow(ui: *Ui, r: Rect, key: []const u8, tb: *TextBuf, value: *xs.Field, placeholder: []const u8, state: *State) void {
    const wid = ui.id(key);
    const focused = ui.focus == wid;
    if (!focused) tb.* = TextBuf.init(value.get(), text_field.CAP);
    const ev = text_field.field(ui, r, key, tb, .{});
    if (ev == .changed or ev == .commit) value.set(tb.text());
    if (ui.focus == wid) state.editing = true;
    if (tb.len == 0 and ui.focus != wid) ui.textIn(&ui.fonts.body, r.insetXY(4, 0), placeholder, style.text_mute, .left, false);
}

fn filesTab(ui: *Ui, body_in: Rect, state: *State, cx: Context) void {
    ui.pushId("files");
    defer ui.popId();
    const s = cx.settings;
    const rec = &s.recipe;
    var body = body_in;

    dialog.section(ui, &body, "WHERE");
    {
        var r = dialog.rowW(ui, &body, "FOLDER", ROW_H, LABEL_W);
        if (ctl.button(ui, r.cutRight(76), "choose", null, .{ .label = "CHOOSE…" })) state.want_folder = true;
        _ = r.cutRight(6);
        textRow(ui, r, "folder", &state.folder, &s.folder, "~/Music/Slab/Exports/{project}", state);
    }
    textRow(ui, dialog.rowW(ui, &body, "MIX NAME", ROW_H, LABEL_W), "mix", &state.mix_name, &rec.mix_name, "{project}", state);
    textRow(ui, dialog.rowW(ui, &body, "STEM NAME", ROW_H, LABEL_W), "stem", &state.stem_name, &rec.stem_name, "{nn} {track}", state);
    dialog.hint(ui, &body, "{project} {track} {nn} {section} {sn} {date} {bpm}   / MAKES A FOLDER", LABEL_W);
    {
        var r = dialog.rowW(ui, &body, "IF IT EXISTS", ROW_H, LABEL_W);
        var ex: u8 = @intFromEnum(rec.exists);
        if (ctl.displaySelectEx(ui, r.cutLeft(150).center(150, ctl.displayHeight(false)), "exists", &ex, &.{ "ADD A NUMBER", "REPLACE IT" }, "IF IT EXISTS", .{ .align_ = .left })) rec.exists = @enumFromInt(ex);
        _ = r.cutLeft(12);
        _ = ctl.button(ui, r.cutLeft(150), "reveal", &s.reveal, .{ .kind = .latch, .label = "SHOW IN FINDER", .led = style.led_amber });
    }
    {
        // Where the first file lands.
        const r = dialog.rowW(ui, &body, "FIRST FILE", ROW_H, LABEL_W);
        var fb: [storage.MAX_PATH]u8 = undefined;
        var db: [10]u8 = undefined;
        const folder = xs.resolveFolder(&fb, s.folder.get(), nameFields(cx, 0, "", export_mod.today(&db)));
        var pb: [storage.MAX_PATH]u8 = undefined;
        var nb: [256]u8 = undefined;
        const name = if (rec.mix) mixFile(&nb, cx) else stemFile(&nb, cx, 1, if (cx.tracks.len > 0) cx.tracks[0].name() else "track");
        const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ folder, name }) catch "";
        ui.marquee(&ui.fonts.legend, r, path, style.text_dim, .left, false, r.contains(ui.in.ix(), ui.in.iy()));
    }

    dialog.section(ui, &body, "TAGS, IN EVERY FILE");
    {
        var r = dialog.rowW(ui, &body, "TITLE", ROW_H, LABEL_W);
        const half = @divFloor(r.w - 8, 2);
        textRow(ui, r.cutLeft(half), "title", &state.title, &s.title, cx.project, state);
        _ = r.cutLeft(8);
        ui.textIn(&ui.fonts.legend, r.cutLeft(52), "ARTIST", style.text_dim, .left, true);
        textRow(ui, r, "artist", &state.artist, &s.artist, "", state);
    }
    {
        var r = dialog.rowW(ui, &body, "ALBUM", ROW_H, LABEL_W);
        const half = @divFloor(r.w - 8, 2);
        textRow(ui, r.cutLeft(half), "album", &state.album, &s.album, "", state);
        _ = r.cutLeft(8);
        ui.textIn(&ui.fonts.legend, r.cutLeft(52), "YEAR", style.text_dim, .left, true);
        textRow(ui, r.cutLeft(64), "year", &state.year, &s.year, "", state);
    }
    dialog.hint(ui, &body, "STEMS ARE TITLED \"TITLE - TRACK\"; EVERY FILE ALSO NAMES THE SLAB", LABEL_W);
    dialog.hint(ui, &body, "VERSION AND THE PROJECT IT CAME FROM", LABEL_W);
}

// ── Footer ───────────────────────────────────────────────────────────

fn summaryText(ui: *Ui, r: Rect, s: []const u8, col: core.Color) void {
    ui.marquee(&ui.fonts.legend, r.insetXY(0, 0), s, col, .left, false, r.contains(ui.in.ix(), ui.in.iy()));
}

/// "8 FILES · FLAC 24/48 · -14 LUFS · 3:12 · 210 MB"
fn summary(buf: []u8, cx: Context) []const u8 {
    const rec = &cx.settings.recipe;
    const f = rec.format();
    const files = fileCount(cx);
    var fb: [32]u8 = undefined;
    const fmt = switch (rec.container) {
        .aac => std.fmt.bufPrint(&fb, "AAC {d}", .{f.aac_kbps}) catch "",
        else => std.fmt.bufPrint(&fb, "{s} {s}/{s}", .{
            ([_][]const u8{ "WAV", "AIFF", "FLAC", "ALAC", "AAC" })[@intFromEnum(rec.container)],
            ([_][]const u8{ "16", "24", "32F" })[@intFromEnum(f.bits)],
            ([_][]const u8{ "44.1", "48", "88.2", "96" })[@min(rec.rate, 3)],
        }) catch "",
    };
    var lb: [24]u8 = undefined;
    const level = switch (rec.normalize) {
        .off => "AS MIXED",
        .peak => std.fmt.bufPrint(&lb, "PEAK {d} DBTP", .{rec.target()}) catch "",
        .loudness => std.fmt.bufPrint(&lb, "{d} LUFS", .{rec.target()}) catch "",
    };
    const secs = cx.range_secs[@intFromEnum(rec.range)] orelse 0;
    const total: u64 = @intFromFloat(@round(secs));
    var sb: [16]u8 = undefined;
    var tail_b: [16]u8 = undefined;
    const tail = if (rec.wrap) " WRAPPED" else if (rec.tail_auto) " + TAIL" else std.fmt.bufPrint(&tail_b, " + {d} S", .{rec.tail_sec}) catch "";
    return std.fmt.bufPrint(buf, "{d} FILE{s} · {s} · {s} · {d}:{d:0>2}{s} · ABOUT {s}", .{
        files,                                                                   if (files == 1) "" else "S", fmt, level, total / 60, total % 60, tail,
        sizeText(&sb, bytesPerSec(rec) * secs * @as(f64, @floatFromInt(outputCount(cx)))),
    }) catch "";
}

// ── Progress and the report ──────────────────────────────────────────

pub fn drawProgress(ui: *Ui, body_in: Rect, p: Progress) void {
    var body = body_in;
    const frac = std.math.clamp(p.fraction, 0, 1);
    {
        var r = dialog.row(ui, &body, "PROGRESS", ROW_H);
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{frac * 100}) catch "";
        ctl.display(ui, r.cutRight(4 * ctl.CELL_W + 4).center(4 * ctl.CELL_W + 4, ctl.displayHeight(false)), s, .{ .align_ = .right, .color = style.play });
        _ = r.cutRight(6);
        const inner = ui.well(r.center(r.w, 12), style.well).inset(1);
        const lit: i32 = @intFromFloat(@round(frac * @as(f32, @floatFromInt(SEGS))));
        var i: i32 = 0;
        while (i < SEGS) : (i += 1) {
            const x0 = inner.x + @divFloor(i * inner.w, SEGS);
            const x1 = inner.x + @divFloor((i + 1) * inner.w, SEGS);
            ctl.ledBar(ui, Rect.xywh(x0, inner.y, x1 - x0 - 1, inner.h), if (i < lit) .on else .off, style.play);
        }
        ui.animate();
    }
    {
        const r = dialog.row(ui, &body, "AUDIO", ROW_H);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.1} / {d:.1} S", .{ p.rendered_s, p.total_s }) catch "";
        ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), s, .{});
    }
    {
        const r = dialog.row(ui, &body, "SPEED", ROW_H);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.1} S  {d:.1}X RT", .{ p.elapsed_s, p.speed_x }) catch "";
        ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), s, .{});
    }
}

/// The report: the mix's numbers on a strip of readouts, then each stem's
/// loudness as a bar against the loudest.
fn drawCard(ui: *Ui, screen: Rect, state: *State, card: *const Card) Result {
    // Sized to what it shows.
    const stem_rows: i32 = @intCast((card.stem_count + 1) / 2);
    const h = dialog.TITLE_H + dialog.BUTTONS_H + 12 + ROW_H + 8 +
        (if (card.has_mix) 18 + ctl.LEGEND_H + ctl.displayHeight(true) + 12 else 0) +
        (if (stem_rows > 0) 18 + stem_rows * 16 else 0) + 8;
    const f = dialog.begin(ui, screen, "export-card", "EXPORTED", W, @min(H, h));
    defer dialog.end(ui);
    var body = f.body;
    var buf: [48]u8 = undefined;
    {
        const r = body.cutTop(ROW_H);
        ui.textIn(&ui.fonts.body, r, std.fmt.bufPrint(&buf, "{d} FILE{s}, {d:.1} S EACH", .{ card.files, if (card.files == 1) "" else "S", card.secs }) catch "", style.text, .left, false);
        _ = body.cutTop(8);
    }
    if (card.has_mix) {
        dialog.section(ui, &body, "THE MIX");
        var strip = body.cutTop(ctl.LEGEND_H + ctl.displayHeight(true));
        _ = body.cutTop(12);
        const cw = @divFloor(strip.w - 18, 4);
        var gb: [16]u8 = undefined;
        var lb: [16]u8 = undefined;
        var rb: [16]u8 = undefined;
        var pb: [16]u8 = undefined;
        const vals = [_][]const u8{
            std.fmt.bufPrint(&lb, "{d:.1}", .{card.lufs}) catch "",
            std.fmt.bufPrint(&rb, "{d:.1}", .{card.lra}) catch "",
            std.fmt.bufPrint(&pb, "{d:.1}", .{card.true_peak}) catch "",
            gainText(&gb, card.gain_db),
        };
        const labels = [_][]const u8{ "LUFS", "LRA, LU", "TRUE PEAK, DBTP", "GAIN" };
        for (vals, labels, 0..) |v, lab, i| {
            var cell = strip.cutLeft(cw);
            if (i < 3) _ = strip.cutLeft(6);
            ui.textIn(&ui.fonts.legend, cell.cutTop(ctl.LEGEND_H), lab, style.text_dim, .left, true);
            const hot = i == 2 and card.true_peak > -1;
            ctl.display(ui, cell, v, .{ .large = true, .align_ = .right, .color = if (hot) style.rec else style.vfd });
        }
    }
    if (card.stem_count > 0) {
        dialog.section(ui, &body, "STEMS, AGAINST THE LOUDEST");
        var loudest: f64 = -70;
        for (card.stem_lufs[0..card.stem_count]) |l| loudest = @max(loudest, l);
        const rows: i32 = @intCast((card.stem_count + 1) / 2);
        const rh: i32 = @min(16, @divFloor(body.h, @max(1, rows)));
        const col_w = @divFloor(body.w - 16, 2);
        for (0..card.stem_count) |i| {
            const k: i32 = @intCast(i);
            const x = body.x + @mod(k, 2) * (col_w + 16);
            const y = body.y + @divFloor(k, 2) * rh;
            const name = card.stem_names[i][0..card.stem_name_len[i]];
            ui.textIn(&ui.fonts.legend, Rect.xywh(x, y, 100, rh), name, style.text, .left, false);
            const lu = card.stem_lufs[i] - loudest;
            const v = if (card.stem_lufs[i] <= -70) "-" else std.fmt.bufPrint(&buf, "{d:.1}", .{lu}) catch "";
            ui.textIn(&ui.fonts.legend, Rect.xywh(x + col_w - 36, y, 36, rh), v, style.text_dim, .right, false);
            // 0 LU fills the bar; -30 LU leaves it empty.
            const bar = Rect.xywh(x + 104, y + @divFloor(rh - 8, 2), col_w - 104 - 42, 8);
            const inner = ui.well(bar, style.well).inset(1);
            const frac: f64 = if (card.stem_lufs[i] <= -70) 0 else std.math.clamp(1 + lu / 30, 0, 1);
            ui.rect(Rect.xywh(inner.x, inner.y, @intFromFloat(@round(frac * @as(f64, @floatFromInt(inner.w)))), inner.h), style.vfd.mix(style.well, 0.2));
        }
    }
    const pick = dialog.buttons(ui, f.buttons, &.{ "SHOW FILES", "DONE" }, 1);
    if (pick) |i| {
        if (i == 0) return .reveal;
        state.showing_card = false;
        state.active = false;
        return .none;
    }
    if (f.escape or f.enter) {
        state.showing_card = false;
        state.active = false;
    }
    return .none;
}

test "the footer sums up every format" {
    var s = xs.Settings{};
    var presets = xs.UserPresets{};
    const cx = Context{ .settings = &s, .presets = &presets, .tracks = &.{}, .project = "song", .bpm = 120, .range_secs = .{ 192.4, null, null, null } };
    var buf: [160]u8 = undefined;
    inline for (std.meta.fields(export_mod.Container)) |f| {
        s.recipe.container = @enumFromInt(f.value);
        inline for (std.meta.fields(export_mod.Bits)) |b| {
            s.recipe.bits = @enumFromInt(b.value);
            const out = summary(&buf, cx);
            try std.testing.expect(std.mem.startsWith(u8, out, "1 FILE · "));
        }
    }
    s.recipe.container = .wav;
    try std.testing.expect(std.mem.indexOf(u8, summary(&buf, cx), "WAV 32F/48") != null);
}
