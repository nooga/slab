//! Single-line text entry (docs/06 §Text fields): `TextBuf` is the bounded
//! editing model (cursor, selection, word moves), `field` the widget that
//! drives it from the Ui input and draws it as a flat well with a caret.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");

const Ui = core.Ui;
const Rect = core.Rect;

// ── Model ────────────────────────────────────────────────────────────

pub const CAP = 128;

/// Bounded text with a cursor and an optional selection anchor. ASCII
/// only (what Tamzen draws); `limit` caps the length below `CAP`.
pub const TextBuf = struct {
    buf: [CAP]u8 = undefined,
    len: usize = 0,
    limit: usize = CAP,
    cursor: usize = 0,
    anchor: ?usize = null,

    pub fn init(s: []const u8, limit: usize) TextBuf {
        var t = TextBuf{ .limit = @min(limit, CAP) };
        t.set(s);
        return t;
    }

    pub fn text(t: *const TextBuf) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn set(t: *TextBuf, s: []const u8) void {
        const n = @min(s.len, t.limit);
        @memcpy(t.buf[0..n], s[0..n]);
        t.len = n;
        t.cursor = n;
        t.anchor = null;
    }

    pub fn selectAll(t: *TextBuf) void {
        t.anchor = 0;
        t.cursor = t.len;
    }

    pub fn selection(t: *const TextBuf) ?[2]usize {
        const a = t.anchor orelse return null;
        if (a == t.cursor) return null;
        return .{ @min(a, t.cursor), @max(a, t.cursor) };
    }

    pub fn selected(t: *const TextBuf) []const u8 {
        const s = t.selection() orelse return "";
        return t.buf[s[0]..s[1]];
    }

    fn remove(t: *TextBuf, a: usize, b: usize) void {
        std.mem.copyForwards(u8, t.buf[a .. t.len - (b - a)], t.buf[b..t.len]);
        t.len -= b - a;
        t.cursor = a;
        t.anchor = null;
    }

    /// Delete the selection; false when there is none.
    pub fn deleteSelection(t: *TextBuf) bool {
        const s = t.selection() orelse return false;
        t.remove(s[0], s[1]);
        return true;
    }

    /// Replace the selection (or insert at the cursor), dropping anything
    /// that isn't printable ASCII or doesn't fit.
    pub fn insert(t: *TextBuf, s: []const u8) void {
        _ = t.deleteSelection();
        t.anchor = null;
        for (s) |ch| {
            if (ch < 32 or ch > 126 or t.len >= t.limit) continue;
            std.mem.copyBackwards(u8, t.buf[t.cursor + 1 .. t.len + 1], t.buf[t.cursor..t.len]);
            t.buf[t.cursor] = ch;
            t.len += 1;
            t.cursor += 1;
        }
    }

    pub fn deleteBack(t: *TextBuf, word: bool) void {
        if (t.deleteSelection() or t.cursor == 0) return;
        t.remove(if (word) wordLeft(t.text(), t.cursor) else t.cursor - 1, t.cursor);
    }

    pub fn deleteForward(t: *TextBuf, word: bool) void {
        if (t.deleteSelection() or t.cursor >= t.len) return;
        const end = if (word) wordRight(t.text(), t.cursor) else t.cursor + 1;
        const at = t.cursor;
        t.remove(at, end);
    }

    /// Move the cursor; `extend` grows the selection instead of clearing it.
    pub fn moveTo(t: *TextBuf, pos: usize, extend: bool) void {
        if (extend) {
            if (t.anchor == null) t.anchor = t.cursor;
        } else t.anchor = null;
        t.cursor = @min(pos, t.len);
    }

    pub fn left(t: *TextBuf, word: bool, extend: bool) void {
        if (!extend) if (t.selection()) |s| return t.moveTo(s[0], false);
        t.moveTo(if (word) wordLeft(t.text(), t.cursor) else t.cursor -| 1, extend);
    }

    pub fn right(t: *TextBuf, word: bool, extend: bool) void {
        if (!extend) if (t.selection()) |s| return t.moveTo(s[1], false);
        t.moveTo(if (word) wordRight(t.text(), t.cursor) else t.cursor + 1, extend);
    }
};

fn wordLeft(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and s[i - 1] == ' ') i -= 1;
    while (i > 0 and s[i - 1] != ' ') i -= 1;
    return i;
}

fn wordRight(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i < s.len and s[i] != ' ') i += 1;
    while (i < s.len and s[i] == ' ') i += 1;
    return i;
}

// ── Widget ───────────────────────────────────────────────────────────

pub const Event = enum { none, changed, commit, cancel };

pub const FieldOpts = struct {
    /// Take focus now (an inline rename opens already editing). Pass it
    /// once; a field keeps focus until Enter, Esc or a press elsewhere.
    focus: bool = false,
    /// A press outside the field commits (inline rename); otherwise it
    /// just blurs.
    commit_on_blur: bool = false,
};

const PAD: i32 = 3;
const BLINK: f64 = 0.4;

/// Text field in `r`: a well with the text, amber selection and caret.
/// Edits while focused. Enter → `.commit`, Esc → `.cancel`.
pub fn field(ui: *Ui, r: Rect, key: anytype, t: *TextBuf, o: FieldOpts) Event {
    const wid = ui.id(key);
    const in = &ui.in;
    if (o.focus and ui.focus != wid) {
        ui.focus = wid;
        ui.focus_visible = false;
        ui.memo(wid, 0).* = @floatCast(in.time);
    }
    const f: *const core.Font = if (r.h >= 18) &ui.fonts.body else &ui.fonts.legend;
    const inner = r.inset(1);
    const tx = inner.x + PAD;
    const b = ui.behaviorEx(wid, r, .{});
    // Focus as of last frame: the core drops focus on a press elsewhere
    // before we run, and that press is the blur.
    const was = ui.memo(wid +% 1, 0);
    const blurred = was.* > 0.5 and ui.focus != wid;
    was.* = if (ui.focus == wid) 1 else 0;
    const focused = ui.focus == wid;
    // Caret blink restarts on every edit so the caret is visible while typing.
    const blink_t0 = ui.memo(wid, @floatCast(in.time));
    var ev: Event = .none;

    if (b.hover) ui.requestCursor(c.rl.MOUSE_CURSOR_IBEAM, 4);
    if (b.pressed) {
        if (b.double) t.selectAll() else t.moveTo(hit(f, t.text(), in.ix() - tx), false);
    } else if (b.held) {
        t.moveTo(hit(f, t.text(), in.ix() - tx), true);
    }
    if (blurred or (focused and in.pressed and !b.hover)) {
        if (ui.focus == wid) ui.focus = 0;
        was.* = 0;
        if (o.commit_on_blur) return .commit;
    }

    if (focused) {
        const before_len = t.len;
        const before_cur = t.cursor;
        const word = in.alt or in.cmd;
        for (in.keys[0..in.nkeys]) |k| switch (k) {
            c.rl.KEY_ESCAPE => {
                ui.focus = 0;
                return .cancel;
            },
            c.rl.KEY_ENTER, c.rl.KEY_KP_ENTER => {
                ui.focus = 0;
                return .commit;
            },
            c.rl.KEY_LEFT => t.left(word, in.shift),
            c.rl.KEY_RIGHT => t.right(word, in.shift),
            c.rl.KEY_HOME, c.rl.KEY_UP => t.moveTo(0, in.shift),
            c.rl.KEY_END, c.rl.KEY_DOWN => t.moveTo(t.len, in.shift),
            c.rl.KEY_BACKSPACE => t.deleteBack(word),
            c.rl.KEY_DELETE => t.deleteForward(word),
            c.rl.KEY_A => if (in.cmd) t.selectAll(),
            c.rl.KEY_C => if (in.cmd and t.selection() != null) ui.setClipboard(t.selected()),
            c.rl.KEY_X => if (in.cmd and t.selection() != null) {
                ui.setClipboard(t.selected());
                _ = t.deleteSelection();
            },
            c.rl.KEY_V => if (in.cmd) t.insert(ui.clipboard()),
            else => {},
        };
        if (!in.cmd) {
            var buf: [core.MAX_CHARS]u8 = undefined;
            var n: usize = 0;
            for (in.chars[0..in.nchars]) |ch| {
                if (ch >= 32 and ch <= 126) {
                    buf[n] = @intCast(ch);
                    n += 1;
                }
            }
            if (n > 0) t.insert(buf[0..n]);
        }
        if (t.len != before_len) ev = .changed;
        if (t.len != before_len or t.cursor != before_cur) blink_t0.* = @floatCast(in.time);
    }

    // Draw: a well; selection and caret only while focused.
    _ = ui.well(r, style.well);
    ui.clip(inner);
    defer ui.unclip();
    const ty = inner.y + @divFloor(inner.h - f.lineHeight(), 2);
    if (focused) {
        if (t.selection()) |s| {
            const x0 = tx + f.measure(t.text()[0..s[0]]);
            const x1 = tx + f.measure(t.text()[0..s[1]]);
            ui.rect(Rect.xywh(x0, inner.y + 1, x1 - x0, inner.h - 2), style.accent.alpha(90));
        }
    }
    _ = ui.text(f, tx, ty, t.text(), if (focused) style.text else style.text_dim);
    if (focused) {
        const phase = @mod(in.time - @as(f64, blink_t0.*), BLINK * 2);
        if (phase < BLINK) {
            const cx = tx + f.measure(t.text()[0..t.cursor]);
            ui.rect(Rect.xywh(cx, inner.y + 2, 1, inner.h - 4), style.accent);
        }
        ui.animate();
    }
    return ev;
}

/// Cursor position nearest to `x` (relative to the text origin).
fn hit(f: *const core.Font, s: []const u8, x: i32) usize {
    var best: usize = 0;
    var best_d: i32 = std.math.maxInt(i32);
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        const d: i32 = @intCast(@abs(f.measure(s[0..i]) - x));
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

test "TextBuf edits, selection and word moves" {
    var t = TextBuf.init("hello world", 16);
    try std.testing.expectEqual(@as(usize, 11), t.cursor);
    t.deleteBack(true);
    try std.testing.expectEqualStrings("hello ", t.text());
    t.insert("there\x01!");
    try std.testing.expectEqualStrings("hello there!", t.text());
    t.left(true, false);
    try std.testing.expectEqual(@as(usize, 6), t.cursor);
    t.right(true, true);
    try std.testing.expectEqualStrings("there!", t.selected());
    t.insert("you");
    try std.testing.expectEqualStrings("hello you", t.text());
    t.selectAll();
    t.deleteForward(false);
    try std.testing.expectEqualStrings("", t.text());
    t.insert("0123456789abcdefXYZ");
    try std.testing.expectEqual(@as(usize, 16), t.len);
    t.moveTo(0, false);
    t.deleteForward(false);
    try std.testing.expectEqualStrings("123456789abcdef", t.text());
}
