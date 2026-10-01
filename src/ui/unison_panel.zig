//! Unison panel (docs/08 §Unison): the context panel an instrument's UNI
//! chip opens. A small faceplate hung under the chip with the stack's
//! knobs: VOICES (a poly machine's pool), UNISON (voices per note), DETUNE,
//! SPREAD and BLEND, over a readout of what the pool plays. Modal like a
//! dialog (main suppresses the input behind it while `active`); Esc or a
//! click outside closes it.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const menu = @import("menu.zig");
const machine = @import("../machine.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Unison = machine.Unison;

pub const State = struct {
    active: bool = false,
    /// The track whose instrument it edits.
    track: usize = 0,
    /// The chip's bottom-right corner: the panel hangs from it.
    x: i32 = 0,
    y: i32 = 0,

    pub fn open(st: *State, track: usize, at: [2]i32) void {
        st.* = .{ .active = true, .track = track, .x = at[0], .y = at[1] };
    }
};

const TITLE_H: i32 = 20;
const READOUT_H: i32 = 24;
const PAD: i32 = 8;
const KNOB: ctl.Size = .m;

/// Draw the panel for `u`; true when a setting changed.
pub fn draw(ui: *Ui, screen: Rect, st: *State, u: *Unison) bool {
    if (!st.active) return false;
    if (!menu.active()) ui.unsuppressInput();
    ui.pushId("unison-panel");
    defer ui.popId();

    const poly = !u.mono();
    const cols: i32 = if (poly) 5 else 4;
    const cell = ctl.knobCell(KNOB, true);
    const cw = cell[0] + 8;
    const w = cols * cw + 2 * PAD;
    const h = TITLE_H + cell[1] + READOUT_H + 2 * PAD;
    var x = st.x - w;
    if (x + w > screen.right() - 4) x = screen.right() - 4 - w;
    if (x < screen.x + 4) x = screen.x + 4;
    var y = st.y;
    if (y + h > screen.bottom() - 4) y = screen.bottom() - 4 - h;
    const r = Rect.xywh(x, y, w, h);

    const in = &ui.in;
    if (in.keyPressed(c.rl.KEY_ESCAPE) or ((in.pressed or in.right_pressed) and !r.contains(in.ix(), in.iy()))) {
        st.active = false;
        return false;
    }

    var body = ui.plate(r, .{ .outline = .all, .chamfer = 3 });
    const head = body.cutTop(TITLE_H - 2);
    _ = ui.engraved(&ui.fonts.body_bold, head.x + 7, head.y + @divFloor(head.h - 16, 2) + 1, "UNISON", style.text);
    ui.rect(Rect.xywh(body.x + 4, body.y, body.w - 8, 1), style.face_lo);
    ui.rect(Rect.xywh(body.x + 4, body.y + 1, body.w - 8, 1), style.face_hi);
    body = body.insetXY(PAD, 4);

    var changed = false;
    var row = body.cutTop(cell[1]);
    var buf: [16]u8 = undefined;

    if (poly) {
        const pool = u.pool.load(.monotonic);
        var v: f32 = @as(f32, @floatFromInt(pool - 1)) / @as(f32, Unison.MAX_POOL - 1);
        const s = std.fmt.bufPrint(&buf, "{d}", .{pool}) catch "";
        const def: f32 = @as(f32, @floatFromInt(u.native - 1)) / @as(f32, Unison.MAX_POOL - 1);
        if (ctl.knob(ui, row.cutLeft(cw), "voices", &v, .{ .size = KNOB, .variant = .stepped, .steps = Unison.MAX_POOL, .label = "VOICES", .readout = s, .default = def })) {
            u.setPool(@intFromFloat(@round(v * (Unison.MAX_POOL - 1)) + 1));
            changed = true;
        }
    }
    {
        const n = u.voices();
        var v: f32 = @as(f32, @floatFromInt(n - 1)) / @as(f32, Unison.MAX_COUNT - 1);
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "";
        if (ctl.knob(ui, row.cutLeft(cw), "count", &v, .{ .size = KNOB, .variant = .stepped, .steps = Unison.MAX_COUNT, .label = "UNISON", .readout = s, .default = 0 })) {
            u.setCount(@intFromFloat(@round(v * (Unison.MAX_COUNT - 1)) + 1));
            changed = true;
        }
    }
    const off = u.voices() == 1;
    {
        // Square law: fine steps at the few-cent end.
        var v: f32 = @sqrt(u.detune() / Unison.MAX_DETUNE);
        const s = std.fmt.bufPrint(&buf, "{d:.0} CT", .{u.detune()}) catch "";
        if (ctl.knob(ui, row.cutLeft(cw), "detune", &v, .{ .size = KNOB, .label = "DETUNE", .readout = s, .default = @sqrt(Unison.DEF_DETUNE / Unison.MAX_DETUNE), .disabled = off })) {
            u.setDetune(v * v * Unison.MAX_DETUNE);
            changed = true;
        }
    }
    {
        var v: f32 = u.spread();
        const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{v * 100}) catch "";
        if (ctl.knob(ui, row.cutLeft(cw), "spread", &v, .{ .size = KNOB, .label = "SPREAD", .readout = s, .default = Unison.DEF_SPREAD, .disabled = off })) {
            u.setSpread(v);
            changed = true;
        }
    }
    {
        var v: f32 = u.blend();
        const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{v * 100}) catch "";
        if (ctl.knob(ui, row.cutLeft(cw), "blend", &v, .{ .size = KNOB, .label = "BLEND", .readout = s, .default = Unison.DEF_BLEND, .disabled = off })) {
            u.setBlend(v);
            changed = true;
        }
    }

    // What the pool plays now.
    _ = body.cutTop(4);
    var lbuf: [40]u8 = undefined;
    const n = u.voices();
    const line = if (!poly)
        (if (n == 1) "MONO" else std.fmt.bufPrint(&lbuf, "MONO  {d} VOICES", .{n}) catch "")
    else if (n == 1)
        std.fmt.bufPrint(&lbuf, "{d} NOTES", .{u.poolSize()}) catch ""
    else
        std.fmt.bufPrint(&lbuf, "{d} NOTE{s} x {d} VOICES", .{ u.notes(), if (u.notes() == 1) "" else "S", n }) catch "";
    ctl.display(ui, body.cutTop(ctl.displayHeight(false)), line, .{});
    return changed;
}
