//! Preset browser: any machine's presets, searchable, in place of its
//! panel while open (docs/06 §Preset browser). Banks down the left (the
//! first folder of a preset's name), the matching presets on the right,
//! a search field over both.
//!
//!   [ search ········································ ][×]
//!   ALL        │ gabriel2 / fishinet
//!   cmi-iix    │ gabriel2 / intruder        ← selected (amber)
//!   cmi-tour   │ gabriel2 / jung
//!
//! Every word typed must appear in the name (any case). Up/Down move and
//! load (audition), a click loads, a double-click or Enter loads and
//! closes, Esc closes. It asks the machine for names by index only, so
//! it works for every machine with presets, a rack included.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const text_field = @import("text_field.zig");
const presets_mod = @import("../presets.zig");
const Machine = @import("../machine.zig").Machine;

const Ui = core.Ui;
const Rect = core.Rect;

pub const Action = struct {
    apply: ?u16 = null,
};

const ROW_H: i32 = 14;
const MAX_BANKS = 128;

const State = struct {
    owner: usize = 0,
    query: text_field.TextBuf = .{ .limit = 48 },
    bank: ?usize = null, // index into banks; null = all
    sel: ?u16 = null,
    scroll: i32 = 0,
    focus_query: bool = false,
    reveal: bool = false,
};

var st: State = .{};
var results: [presets_mod.MAX_PRESETS]u16 = undefined;
var banks: [MAX_BANKS][]const u8 = undefined;

pub fn isOpenFor(state: *anyopaque) bool {
    return st.owner == @intFromPtr(state);
}

/// Open on machine `state`, the current preset selected.
pub fn open(state: *anyopaque, current: i32) void {
    const q = st.query;
    st = .{ .owner = @intFromPtr(state), .query = q, .focus_query = true, .reveal = true };
    st.query.selectAll();
    if (current >= 0) st.sel = @intCast(current);
}

pub fn close() void {
    st.owner = 0;
}

fn bankOf(name: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, name, '/')) |i| name[0..i] else "";
}

fn matches(name: []const u8, query: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |w| {
        if (std.ascii.indexOfIgnoreCase(name, w) == null) return false;
    }
    return true;
}

pub fn draw(ui: *Ui, rect: Rect, mach: *const Machine) Action {
    var act = Action{};
    const count: usize = if (mach.preset_count) |f| f(mach.state) else 0;
    const name_of = mach.preset_name orelse {
        close();
        return act;
    };
    ui.pushId("preset-browser");
    defer ui.popId();
    ui.rect(rect, style.chassis);
    var r = rect.inset(4);

    // search row
    var top = r.cutTop(20);
    const x_r = top.cutRight(20);
    if (ctl.button(ui, x_r, "close", null, .{ .label = "\u{D7}", .flush = true })) {
        close();
        return act;
    }
    _ = top.cutRight(4);
    const ev = text_field.field(ui, top, "query", &st.query, .{ .focus = st.focus_query });
    st.focus_query = false;
    if (ev == .changed) {
        st.scroll = 0;
        st.reveal = true;
    }
    _ = r.cutTop(4);

    // banks
    var nb: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b = bankOf(std.mem.span(name_of(mach.state, @intCast(i))));
        if (b.len == 0) continue;
        if (nb > 0 and std.mem.eql(u8, banks[nb - 1], b)) continue;
        if (nb >= MAX_BANKS) break;
        banks[nb] = b;
        nb += 1;
    }
    if (st.bank) |bi| if (bi >= nb) {
        st.bank = null;
    };
    if (nb > 0) {
        var col = r.cutLeft(@min(140, @divFloor(r.w, 3)));
        _ = r.cutLeft(4);
        const well = ui.well(col, style.well);
        col = well;
        var bi: usize = 0;
        while (bi <= nb) : (bi += 1) {
            if (col.h < ROW_H) break;
            const row = col.cutTop(ROW_H);
            const label = if (bi == 0) "ALL" else banks[bi - 1];
            const this: ?usize = if (bi == 0) null else bi - 1;
            ui.pushId(bi);
            defer ui.popId();
            const b = ui.behaviorEx(ui.id("bank"), row, .{ .focusable = false });
            if (b.clicked) {
                st.bank = this;
                st.scroll = 0;
            }
            const on = std.meta.eql(st.bank, this);
            if (on) ui.rect(row, style.accent.alpha(60));
            ui.textIn(&ui.fonts.legend, row.insetXY(4, 0), label, if (on or b.hover) style.text else style.text_dim, .left, false);
        }
    }

    // results
    var n: usize = 0;
    const q = st.query.text();
    i = 0;
    while (i < count) : (i += 1) {
        const name = std.mem.span(name_of(mach.state, @intCast(i)));
        if (st.bank) |bi| if (!std.mem.eql(u8, bankOf(name), banks[bi])) continue;
        if (!matches(name, q)) continue;
        results[n] = @intCast(i);
        n += 1;
    }
    const list = ui.well(r, style.well);
    const rows: i32 = @max(1, @divFloor(list.h, ROW_H));
    var sel_pos: ?usize = null;
    if (st.sel) |s| for (results[0..n], 0..) |ri, k| if (ri == s) {
        sel_pos = k;
        break;
    };

    // keys: Up/Down move and audition, Enter loads and closes, Esc closes
    if (ui.in.keyPressed(c.rl.KEY_ESCAPE)) {
        close();
        return act;
    }
    if (n > 0) {
        var step: i32 = 0;
        if (ui.in.keyPressed(c.rl.KEY_DOWN)) step = 1;
        if (ui.in.keyPressed(c.rl.KEY_UP)) step = -1;
        if (ui.in.keyPressed(c.rl.KEY_PAGE_DOWN)) step = rows;
        if (ui.in.keyPressed(c.rl.KEY_PAGE_UP)) step = -rows;
        if (step != 0) {
            const at: i32 = if (sel_pos) |p| @intCast(p) else -1;
            const to: usize = @intCast(std.math.clamp(at + step, 0, @as(i32, @intCast(n)) - 1));
            sel_pos = to;
            st.sel = results[to];
            act.apply = results[to];
            st.reveal = true;
        }
        if (ev == .commit or (ui.focus == 0 and ui.in.keyPressed(c.rl.KEY_ENTER))) {
            const p = sel_pos orelse 0;
            act.apply = results[p];
            close();
            return act;
        }
    }
    if (ev == .cancel) {
        close();
        return act;
    }

    // scroll: the wheel, and keeping the selection in view
    const max_scroll: i32 = @max(0, @as(i32, @intCast(n)) - rows);
    if (list.contains(ui.in.ix(), ui.in.iy()) and ui.in.wheel_y != 0) {
        st.scroll -= @intFromFloat(@round(ui.in.wheel_y * 3));
        st.reveal = false;
    }
    if (st.reveal) if (sel_pos) |p| {
        const pi: i32 = @intCast(p);
        if (pi < st.scroll) st.scroll = pi;
        if (pi >= st.scroll + rows) st.scroll = pi - rows + 1;
        st.reveal = false;
    };
    st.scroll = std.math.clamp(st.scroll, 0, max_scroll);

    ui.clip(list);
    defer ui.unclip();
    var y = list.y;
    var k: usize = @intCast(st.scroll);
    const cur: i32 = if (mach.current_preset) |f| f(mach.state) else -1;
    while (k < n and y < list.bottom()) : (k += 1) {
        const idx = results[k];
        const row = Rect.xywh(list.x, y, list.w, ROW_H);
        y += ROW_H;
        ui.pushId(@as(usize, idx));
        defer ui.popId();
        const b = ui.behaviorEx(ui.id("row"), row, .{ .focusable = false });
        if (b.pressed) {
            st.sel = idx;
            act.apply = idx;
            if (b.double) close();
        }
        const selected = st.sel != null and st.sel.? == idx;
        if (selected) ui.rect(row, style.accent.alpha(70)) else if (b.hover) ui.rect(row, style.text.alpha(16));
        var name = std.mem.span(name_of(mach.state, idx));
        if (st.bank != null) name = name[bankOf(name).len + 1 ..];
        var buf: [96]u8 = undefined;
        const shown = prettyPath(&buf, name);
        const col = if (selected) style.text else if (cur == idx) style.vfd else style.text_dim;
        ui.textIn(&ui.fonts.legend, row.insetXY(4, 0), shown, col, .left, false);
    }
    if (n == 0) ui.textIn(&ui.fonts.legend, list, "No presets match", style.text_mute, .center, false);
    // count, bottom right
    var cbuf: [24]u8 = undefined;
    const cs = std.fmt.bufPrint(&cbuf, "{d}/{d}", .{ n, count }) catch "";
    const cw = ui.fonts.legend.measure(cs) + 8;
    const badge = Rect.xywh(list.right() - cw, list.bottom() - ROW_H, cw, ROW_H);
    ui.rect(badge, style.well);
    ui.textIn(&ui.fonts.legend, badge, cs, style.text_mute, .center, false);
    return act;
}

/// "cmi-tour/gabriel2/fishinet" → "cmi-tour / gabriel2 / fishinet".
fn prettyPath(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (ch == '/') {
            if (n + 3 > buf.len) break;
            @memcpy(buf[n..][0..3], " / ");
            n += 3;
        } else {
            if (n + 1 > buf.len) break;
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

test "browser search: every word, any case" {
    try std.testing.expect(matches("cmi-tour/gabriel2/fishinet", "gab FISH"));
    try std.testing.expect(!matches("cmi-tour/gabriel2/fishinet", "gab piano"));
    try std.testing.expect(matches("anything", ""));
    try std.testing.expectEqualStrings("cmi-tour", bankOf("cmi-tour/gabriel2/fishinet"));
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a / b", prettyPath(&b, "a/b"));
}
