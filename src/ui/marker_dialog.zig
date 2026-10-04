//! The marker dialog (docs/28 §Locators and sections): a section's or a
//! locator's NAME, a section's COLOR, and the TEMPO and METER it starts
//! with. TEMPO and METER aren't stored on the section: OK writes them into
//! the tempo and meter maps at its start, or, set to FOLLOW, removes the
//! change there so the section carries on from the one before. Edits a
//! copy; main applies it on OK as one undo step.

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const dialog = @import("dialog.zig");
const text_field = @import("text_field.zig");
const markers_mod = @import("../markers.zig");
const tempo_mod = @import("../tempo.zig");
const meter_mod = @import("../meter.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const MeterChoice = struct { label: []const u8, num: u8, den: u8 };
/// METER's list after FOLLOW.
pub const METERS = [_]MeterChoice{
    .{ .label = "2/4", .num = 2, .den = 4 },
    .{ .label = "3/4", .num = 3, .den = 4 },
    .{ .label = "4/4", .num = 4, .den = 4 },
    .{ .label = "5/4", .num = 5, .den = 4 },
    .{ .label = "6/4", .num = 6, .den = 4 },
    .{ .label = "7/4", .num = 7, .den = 4 },
    .{ .label = "3/8", .num = 3, .den = 8 },
    .{ .label = "5/8", .num = 5, .den = 8 },
    .{ .label = "6/8", .num = 6, .den = 8 },
    .{ .label = "7/8", .num = 7, .den = 8 },
    .{ .label = "9/8", .num = 9, .den = 8 },
    .{ .label = "11/8", .num = 11, .den = 8 },
    .{ .label = "12/8", .num = 12, .den = 8 },
    .{ .label = "13/8", .num = 13, .den = 8 },
    .{ .label = "5/16", .num = 5, .den = 16 },
    .{ .label = "7/16", .num = 7, .den = 16 },
};
const METER_LABELS = blk: {
    var l: [METERS.len + 1][]const u8 = undefined;
    l[0] = "FOLLOW";
    for (METERS, 1..) |m, i| l[i] = m.label;
    break :blk l;
};
/// `meter` when the change at the section's start isn't in METERS: it is
/// kept as it is.
pub const METER_KEEP: u8 = 255;

pub const State = struct {
    active: bool = false,
    kind: markers_mod.Kind = .section,
    index: usize = 0,
    /// Where it starts (the dialog's TEMPO/METER apply there).
    beat: f64 = 0,
    /// The section starts the song: it can't FOLLOW anything.
    first: bool = false,
    name: text_field.TextBuf = text_field.TextBuf.init("", 32),
    color: u8 = 0,
    /// A tempo change starts the section.
    tempo_on: bool = false,
    bpm: f64 = 120,
    /// 0 = FOLLOW, else 1 + METERS index, or METER_KEEP.
    meter: u8 = 0,
    /// What METER_KEEP shows.
    meter_buf: [8]u8 = undefined,
    meter_len: usize = 0,
    /// The name field had the keyboard last frame: Enter and Esc are its.
    editing: bool = false,
};

/// Open on section or locator `index`, reading its tempo and meter.
pub fn open(state: *State, mk: *const markers_mod.Markers, kind: markers_mod.Kind, index: usize, tempo: *const tempo_mod.TempoMap, meter: meter_mod.MeterMap) void {
    state.* = .{ .active = true, .kind = kind, .index = index };
    switch (kind) {
        .locator => {
            const l = mk.locators[index];
            state.beat = l.beat;
            state.name.set(l.name.get());
        },
        .section => {
            const s = mk.sections[index];
            state.beat = s.beat;
            state.name.set(s.name.get());
            state.color = s.color;
            state.first = s.beat <= 1e-6;
            state.tempo_on = state.first or tempo.find(s.beat) != null;
            state.bpm = tempo.bpmAt(s.beat);
            const bar = meter.beatToBarPos(s.beat).bar;
            const seg = meter.segmentForBar(bar);
            state.meter = if (seg.start_bar == bar or state.first) blk: {
                for (METERS, 1..) |m, i| if (m.num == seg.numerator and m.den == seg.denominator) break :blk @intCast(i);
                const t = std.fmt.bufPrint(&state.meter_buf, "{d}/{d}", .{ seg.numerator, seg.denominator }) catch "";
                state.meter_len = t.len;
                break :blk METER_KEEP;
            } else 0;
        },
    }
    state.name.selectAll();
}

pub const Result = enum { none, cancel, ok, delete };

const W: i32 = 360;
const LABEL_W: i32 = 64;
const ROW_H: i32 = 20;

pub fn draw(ui: *Ui, screen: Rect, state: *State) Result {
    if (!state.active) return .none;
    const section = state.kind == .section;
    const h: i32 = dialog.TITLE_H + dialog.BUTTONS_H + 12 + (if (section) 4 * (ROW_H + 6) + 18 else ROW_H + 6);
    const f = dialog.begin(ui, screen, "marker-dialog", if (section) "SECTION" else "LOCATOR", W, h);
    defer dialog.end(ui);
    const editing = state.editing;
    state.editing = false;
    var body = f.body;
    {
        const r = dialog.rowW(ui, &body, "NAME", ROW_H, LABEL_W);
        _ = text_field.field(ui, Rect.xywh(r.x, r.y, 200, r.h), "name", &state.name, .{ .focus = !editing and ui.focus == 0 });
        if (ui.focus == ui.id("name")) state.editing = true;
    }
    if (section) {
        {
            const r = dialog.rowW(ui, &body, "COLOR", ROW_H, LABEL_W);
            swatches(ui, r, state);
        }
        {
            var r = dialog.rowW(ui, &body, "TEMPO", ROW_H, LABEL_W);
            var on = state.tempo_on;
            const led = r.cutLeft(20);
            if (ctl.ledToggle(ui, led, "tempo-on", &on, state.first)) state.tempo_on = on;
            _ = r.cutLeft(4);
            bpmField(ui, r.cutLeft(88), state);
        }
        {
            var r = dialog.rowW(ui, &body, "METER", ROW_H, LABEL_W);
            const hh = ctl.displayHeight(false);
            var v: u8 = if (state.meter == METER_KEEP) 0 else state.meter;
            const shown: ?[]const u8 = if (state.meter == METER_KEEP) state.meter_buf[0..state.meter_len] else if (state.first and state.meter == 0) "4/4" else null;
            if (ctl.displaySelectEx(ui, r.cutLeft(88).center(88, hh), "meter", &v, &METER_LABELS, "METER", .{ .align_ = .left, .shown = shown })) state.meter = v;
        }
        dialog.hint(ui, &body, if (state.first) "THE SONG STARTS WITH THESE" else "OFF AND FOLLOW CARRY ON FROM THE SECTION BEFORE", 0);
    }
    var bar = f.buttons;
    if (ctl.button(ui, bar.cutLeft(76).center(76, 20), "delete", null, .{ .label = "DELETE" })) return .delete;
    if (dialog.buttons(ui, bar, &.{ "CANCEL", "OK" }, 1)) |i| return if (i == 0) .cancel else .ok;
    if (f.escape) return .cancel;
    if (f.enter) return .ok;
    return .none;
}

fn swatches(ui: *Ui, r: Rect, state: *State) void {
    ui.pushId("color");
    defer ui.popId();
    var x = r.x;
    for (0..markers_mod.COLORS) |i| {
        const cell = Rect.xywh(x, r.y + 2, 16, r.h - 4);
        x += 18;
        const wid = ui.id(i);
        const b = ui.behavior(wid, cell, false);
        if (b.pressed) state.color = @intCast(i);
        ui.rect(cell, style.edge);
        ui.rect(cell.inset(1), style.track[i]);
        if (state.color == i) {
            ui.rect(Rect.xywh(cell.x, cell.bottom() + 1, cell.w, 1), style.text);
        }
    }
}

/// The section's tempo: drag up/down (Shift fine), double-click for the
/// tempo it starts at now.
fn bpmField(ui: *Ui, r: Rect, state: *State) void {
    const wid = ui.id("bpm");
    const b = ui.behavior(wid, r, !state.tempo_on);
    if (b.held) {
        state.bpm -= @as(f64, ui.in.dy * ui.renderer.zoom * (if (ui.in.shift) @as(f32, 0.05) else 0.5));
        state.bpm = tempo_mod.clampBpm(state.bpm);
    }
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.1}", .{state.bpm}) catch "?";
    ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), if (state.tempo_on) s else "FOLLOW", .{ .align_ = .right, .color = if (!state.tempo_on) style.text_mute else if (ui.active == wid) style.vfd_hi else style.vfd });
    if (ui.isHot(wid)) ui.requestCursor(@import("../c.zig").rl.MOUSE_CURSOR_RESIZE_NS, 1);
}

/// Write the dialog into the markers and the maps: the name and color, a
/// tempo change at the section's start (or none: FOLLOW), a meter change
/// at its bar (or none).
pub fn apply(state: *const State, mk: *markers_mod.Markers, tempo: *tempo_mod.TempoState, meter: *meter_mod.MeterState) void {
    switch (state.kind) {
        .locator => if (state.index < mk.locator_n) mk.locators[state.index].name.set(state.name.text()),
        .section => {
            if (state.index >= mk.section_n) return;
            const sec = &mk.sections[state.index];
            sec.name.set(state.name.text());
            sec.color = state.color;
            const m = tempo.edit();
            if (state.tempo_on) {
                _ = m.put(sec.beat, state.bpm);
            } else if (m.find(sec.beat)) |i| m.remove(i);
            tempo.publish();
            const bar = meter.liveMap().beatToBarPos(sec.beat).bar;
            if (state.meter != METER_KEEP) {
                if (state.meter > 0) {
                    const ch = METERS[state.meter - 1];
                    meter.insertChange(bar, ch.num, ch.den);
                } else if (bar > 0) meter.removeChange(bar);
            }
        },
    }
}

test "OK writes a section's tempo and meter into the maps, FOLLOW takes them out" {
    var mk: markers_mod.Markers = .{};
    _ = mk.addSection(0, "INTRO");
    _ = mk.addSection(16, "VERSE");
    var tempo: tempo_mod.TempoState = .{};
    var meter: meter_mod.MeterState = .{};
    meter.liveStore().reset();
    meter.commitImmediate();
    var st: State = .{};
    open(&st, &mk, .section, 1, &tempo.live, meter.liveMap());
    try std.testing.expect(!st.tempo_on);
    try std.testing.expectEqual(@as(u8, 0), st.meter);
    st.tempo_on = true;
    st.bpm = 140;
    st.meter = 10; // 7/8
    st.name.set("CHORUS");
    apply(&st, &mk, &tempo, &meter);
    try std.testing.expectEqualStrings("CHORUS", mk.sections[1].name.get());
    try std.testing.expectEqual(@as(f64, 140), tempo.live.bpmAt(20));
    const seg = meter.liveMap().segmentForBar(4);
    try std.testing.expectEqual(@as(u32, 4), seg.start_bar);
    try std.testing.expectEqual(@as(u8, 7), seg.numerator);
    // Reopened, it reads them back; FOLLOW removes both.
    open(&st, &mk, .section, 1, &tempo.live, meter.liveMap());
    try std.testing.expect(st.tempo_on);
    try std.testing.expectEqual(@as(u8, 10), st.meter);
    st.tempo_on = false;
    st.meter = 0;
    apply(&st, &mk, &tempo, &meter);
    try std.testing.expectEqual(@as(usize, 1), tempo.live.len);
    try std.testing.expectEqual(@as(usize, 1), meter.liveMap().points.len);
}
