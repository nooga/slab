//! The library browser (docs/25 §The browser): the app's left column,
//! listing every item `library.zig` finds, to drag onto the arrangement
//! or the machine bay. Prototyped in the gallery (gallery_browser.zig);
//! this is that UI on real data.
//!
//!   - search as you type (any letter while the browser has focus; ⌘F
//!     from anywhere), every word must match the name, folder or kind
//!   - source tabs (ALL PROJECT USER FACTORY PACKS ONLINE) and kind chips
//!     with live counts; ★ narrows to favorites
//!   - folders that fold (⌥-click: all), a sticky header, an overlay
//!     scrollbar, click / ⇧ / ⌘ selection, ↑↓ ←→ ↩ Esc
//!   - hover ★ and ▶, auto-audition of samples, a preview pane
//!   - drags: main resolves the target (`dragging`, `endDrag`)
//!
//! The browser never touches the document: it reports what was asked
//! (`Result`) and main does it, undoably.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const menu = @import("menu.zig");
const text_field = @import("text_field.zig");
const library = @import("../library.zig");
const storage = @import("../storage.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;
const Kind = library.Kind;
const Source = library.Source;
const Item = library.Item;

const KIND_CHIPS = [_][]const u8{ "PRESET", "TABLE", "CLIP", "SAMPLE", "SONG" };
const KIND_NAMES = [_][]const u8{ "preset", "wavetable", "clip", "sample", "song" };
const SOURCE_NAMES = [_][]const u8{ "PROJECT", "USER", "FACTORY", "PACK" };
const SOURCE_TABS = [_][]const u8{ "ALL", "PROJECT", "USER", "FACTORY", "PACKS", "ONLINE" };
const TAB_PACKS: u8 = 4;
const TAB_ONLINE: u8 = 5;

const MAX_SEL = 256;
const MAX_OPEN = 512;
const MAX_NOTES = 512;

const Row = struct {
    header: bool,
    /// The item, or a header's first item.
    item: u32,
    /// A header's item count in this view.
    count: u32 = 0,
};

/// What main should do this frame.
pub const Result = struct {
    /// Load or insert the selection on the selected track (↩, a
    /// double-click, LOAD, the menu).
    load: bool = false,
    /// Play this item (a sample) through the preview voice.
    audition: ?u32 = null,
    stop_audition: bool = false,
    /// The selected item changed: main loads what the preview shows.
    selected: ?u32 = null,
    /// Show this file in Finder.
    reveal: ?[]const u8 = null,
    /// Rescan the library.
    rescan: bool = false,
    /// A line for the status bar.
    status: ?[]const u8 = null,
};

/// What the preview pane draws for the selection, filled by main.
pub const Wave = struct {
    data: []const f64 = &.{},
    /// Samples per wavetable frame; 0 for a sample.
    frame: usize = 0,
};

pub const State = struct {
    rows: std.ArrayList(Row) = .empty,
    generation: u32 = std.math.maxInt(u32),

    tab: u8 = 0,
    kinds: u8 = 0,
    fav_only: bool = false,
    query: text_field.TextBuf = .{ .limit = 48 },
    focus_query: bool = false,

    open: [MAX_OPEN]u64 = undefined,
    n_open: usize = 0,

    sel: [MAX_SEL]u32 = undefined,
    n_sel: usize = 0,
    cursor: ?u32 = null,
    anchor: ?u32 = null,
    reveal: bool = false,

    scroll: f32 = 0,
    scroll_to: f32 = 0,
    scroll_t: f64 = -10,

    press_item: ?u32 = null,
    press_x: f32 = 0,
    press_y: f32 = 0,
    press_mods: bool = false,
    dragging: bool = false,

    auto_aud: bool = true,
    /// The item playing through the preview voice, and where it is.
    playing: ?u32 = null,
    play_at: ?u32 = null,
    wave: Wave = .{},
    /// The selected clip's notes, read from its file.
    clip_for: ?u32 = null,
    notes: [MAX_NOTES][3]f32 = undefined, // pitch, start, len
    n_notes: usize = 0,
    clip_len: f32 = 4,

    preview_h: i32 = 184,
    msg: [160]u8 = undefined,

    pub fn deinit(st: *State, alloc: std.mem.Allocator) void {
        st.rows.deinit(alloc);
    }

    fn isOpen(st: *const State, key: u64) bool {
        for (st.open[0..st.n_open]) |k| if (k == key) return true;
        return false;
    }

    fn setOpen(st: *State, key: u64, on: bool) void {
        for (st.open[0..st.n_open], 0..) |k, i| if (k == key) {
            if (!on) {
                st.open[i] = st.open[st.n_open - 1];
                st.n_open -= 1;
            }
            return;
        };
        if (on and st.n_open < MAX_OPEN) {
            st.open[st.n_open] = key;
            st.n_open += 1;
        }
    }

    fn isSelected(st: *const State, i: u32) bool {
        for (st.sel[0..st.n_sel]) |s| if (s == i) return true;
        return false;
    }

    fn selectOnly(st: *State, i: u32) void {
        st.sel[0] = i;
        st.n_sel = 1;
        st.cursor = i;
        st.anchor = i;
    }

    fn toggleSel(st: *State, i: u32) void {
        for (st.sel[0..st.n_sel], 0..) |s, k| if (s == i) {
            std.mem.copyForwards(u32, st.sel[k .. st.n_sel - 1], st.sel[k + 1 .. st.n_sel]);
            st.n_sel -= 1;
            return;
        };
        if (st.n_sel < MAX_SEL) {
            st.sel[st.n_sel] = i;
            st.n_sel += 1;
        }
    }

    /// The selection, in list order.
    pub fn selection(st: *const State) []const u32 {
        return st.sel[0..st.n_sel];
    }

    /// The item ↩ and drags act on first.
    pub fn current(st: *const State) ?u32 {
        return st.cursor;
    }

    /// Screenshot hooks: SLAB_BROWSER_TAB=0..5, SLAB_BROWSER_QUERY=words.
    pub fn devSetup(st: *State) void {
        if (std.c.getenv("SLAB_BROWSER_TAB")) |v| st.tab = std.fmt.parseInt(u8, std.mem.span(v), 10) catch 0;
        if (std.c.getenv("SLAB_BROWSER_QUERY")) |v| st.query.set(std.mem.span(v));
    }

    /// ⌘F: focus the search field.
    pub fn focusSearch(st: *State) void {
        st.focus_query = true;
        st.query.selectAll();
    }

    fn say(st: *State, res: *Result, comptime fmt: []const u8, args: anytype) void {
        res.status = std.fmt.bufPrint(&st.msg, fmt, args) catch null;
    }
};

var query_wid: core.Id = 0;
var list_wid: core.Id = 0;

/// The search field has the keyboard: main's shortcuts stand down.
pub fn typing(ui: *const Ui) bool {
    return query_wid != 0 and ui.focus == query_wid;
}

/// A drag from the list is in flight.
pub fn dragging(st: *const State) bool {
    return st.dragging;
}

/// The drag ended (dropped or cancelled).
pub fn endDrag(ui: *Ui, st: *State) void {
    st.dragging = false;
    st.press_item = null;
    if (ui.active != 0 and !ui.in.down) ui.active = 0;
}

fn groupKey(it: *const Item) u64 {
    return std.hash.Wyhash.hash(@intFromEnum(it.kind), it.folder);
}

// ── Filtering ────────────────────────────────────────────────────────

fn sourceIn(tab: u8, s: Source) bool {
    return switch (tab) {
        0 => true,
        1 => s == .project,
        2 => s == .user,
        3 => s == .factory or s == .pack,
        else => false,
    };
}

fn kindIn(mask: u8, k: Kind) bool {
    return mask == 0 or (mask & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(k))))) != 0;
}

fn matches(it: *const Item, query: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |w| {
        if (std.ascii.indexOfIgnoreCase(it.name, w) == null and
            std.ascii.indexOfIgnoreCase(it.folder, w) == null and
            !std.ascii.startsWithIgnoreCase(KIND_NAMES[@intFromEnum(it.kind)], w)) return false;
    }
    return true;
}

fn passes(st: *const State, it: *const Item) bool {
    if (!sourceIn(st.tab, it.source)) return false;
    if (!kindIn(st.kinds, it.kind)) return false;
    if (st.fav_only and !it.fav) return false;
    return matches(it, st.query.text());
}

fn buildRows(alloc: std.mem.Allocator, st: *State, items: []const Item) void {
    st.rows.clearRetainingCapacity();
    const searching = st.query.len > 0 or st.fav_only;
    var i: usize = 0;
    while (i < items.len) {
        const key = groupKey(&items[i]);
        var j = i;
        var count: u32 = 0;
        while (j < items.len and groupKey(&items[j]) == key) : (j += 1) {
            if (passes(st, &items[j])) count += 1;
        }
        if (count > 0) {
            st.rows.append(alloc, .{ .header = true, .item = @intCast(i), .count = count }) catch return;
            if (searching or st.isOpen(key)) {
                var k = i;
                while (k < j) : (k += 1) {
                    if (!passes(st, &items[k])) continue;
                    st.rows.append(alloc, .{ .header = false, .item = @intCast(k) }) catch return;
                }
            }
        }
        i = j;
    }
}

fn rowOf(st: *const State, item: u32) ?usize {
    for (st.rows.items, 0..) |r, k| if (!r.header and r.item == item) return k;
    return null;
}

// ── Draw ─────────────────────────────────────────────────────────────

const ROW_H: i32 = 18;
const CHIP_H: i32 = 18;
const HEAD_H: i32 = 24;
const CTX_MENU: u64 = 0xB0B5E0;

/// The browser in `r`. `focused`: the browser pane has the keyboard.
pub fn draw(ui: *Ui, r: Rect, st: *State, lib: *library.Library, focused: bool) Result {
    var res = Result{};
    ui.pushId("browser");
    defer ui.popId();
    const items = lib.items.items;
    if (st.generation != lib.generation) {
        // A rescan: indices moved, so the selection goes.
        st.generation = lib.generation;
        st.n_sel = 0;
        st.cursor = null;
        st.anchor = null;
        st.playing = null;
        st.clip_for = null;
        st.wave = .{};
    }
    var col = r;

    // Title bar.
    var bar = col.cutTop(HEAD_H);
    const title = ui.plate(bar.cutLeft(84), .{});
    ui.textIn(&ui.fonts.body_bold, title.insetXY(6, 0), "BROWSER", style.text, .left, true);
    const auto_r = bar.cutRight(56);
    _ = ctl.button(ui, auto_r, "auto", &st.auto_aud, .{ .kind = .latch, .label = "AUTO", .led = style.led_green, .flush = true });
    menu.tip(ui, auto_r, "Play samples as you select them");
    const ref_r = bar.cutRight(44);
    if (ctl.button(ui, ref_r, "rescan", null, .{ .label = "SCAN", .flush = true })) res.rescan = true;
    menu.tip(ui, ref_r, "Look for new files");
    _ = ui.plate(bar, .{});

    // Search.
    const srow = col.cutTop(28);
    const splate = ui.plate(srow, .{});
    var sr = splate.insetXY(4, 3);
    if (st.query.len > 0) {
        const clear_r = sr.cutRight(20);
        _ = sr.cutRight(2);
        if (ctl.button(ui, clear_r, "clear", null, .{ .label = "\u{D7}" })) {
            st.query.set("");
            st.focus_query = true;
        }
    }
    query_wid = ui.id("query");
    typeAhead(ui, st, focused);
    const ev = text_field.field(ui, sr, "query", &st.query, .{ .focus = st.focus_query });
    st.focus_query = false;
    if (st.query.len == 0 and ui.focus != query_wid) {
        ui.textIn(&ui.fonts.body, sr.insetXY(5, 0), "Search", style.text_mute, .left, false);
        ui.textIn(&ui.fonts.legend, sr.insetXY(5, 0), "\u{2318}F", style.text_mute, .right, false);
    }
    if (ev == .changed) {
        st.scroll_to = 0;
        st.reveal = true;
    }

    const before_tab = st.tab;
    _ = ctl.segmentedFlush(ui, col.cutTop(22), "tabs", &st.tab, &SOURCE_TABS);
    if (st.tab != before_tab) {
        st.scroll_to = 0;
        st.scroll = 0;
    }
    if (!lib.scanned) {
        const w = ui.well(col, style.pane);
        ui.textIn(&ui.fonts.legend, w, "LOOKING FOR FILES\u{2026}", style.text_mute, .center, false);
        return res;
    }
    if (st.tab == TAB_PACKS) {
        packsView(ui, col, items, &res);
        return res;
    }
    if (st.tab == TAB_ONLINE) {
        onlineView(ui, col);
        return res;
    }

    const counts = chipCounts(st, items);
    chips(ui, col.cutTop(chipsHeight(ui, col.w, counts)), st, counts);
    footer(ui, col.cutBottom(18), st);
    const panes = ctl.split(ui, col, "preview-h", &st.preview_h, .{ .from_end = true, .min = 96, .min_other = 96, .collapsed = 20 });
    buildRows(lib.alloc, st, items);
    const before_cursor = st.cursor;
    list(ui, panes[0], st, lib, ev, focused, &res);
    preview(ui, panes[1], st, items, &res);
    if (st.cursor != before_cursor) if (st.cursor) |cur| {
        res.selected = cur;
        if (st.auto_aud and items[cur].kind == .sample) res.audition = cur;
        if (st.clip_for != cur) readClip(lib.alloc, st, &items[cur], cur);
    };
    return res;
}

/// A letter typed while the browser has focus starts a search.
fn typeAhead(ui: *Ui, st: *State, focused: bool) void {
    const in = &ui.in;
    if (menu.active() or !focused or ui.focus == query_wid or in.cmd or in.nchars == 0) return;
    if (ui.focus != 0 and ui.focus != list_wid) return;
    for (in.chars[0..in.nchars]) |ch| if (ch > 32 and ch < 127) {
        st.focus_query = true;
        st.query.set("");
        return;
    };
}

const Counts = struct { kinds: [KIND_CHIPS.len]u32 = [_]u32{0} ** KIND_CHIPS.len, favs: u32 = 0 };

/// What each chip counts: the source and search, ignoring the kind mask.
fn chipCounts(st: *const State, items: []const Item) Counts {
    var n = Counts{};
    for (items) |*it| {
        if (!sourceIn(st.tab, it.source) or !matches(it, st.query.text())) continue;
        if (it.fav) n.favs += 1;
        if (st.fav_only and !it.fav) continue;
        n.kinds[@intFromEnum(it.kind)] += 1;
    }
    return n;
}

fn chipW(ui: *const Ui, buf: []u8, k: ?usize, n: Counts) i32 {
    const s = if (k) |i| std.fmt.bufPrint(buf, "{s} {d}", .{ KIND_CHIPS[i], n.kinds[i] }) catch "" else std.fmt.bufPrint(buf, "\u{2605} {d}", .{n.favs}) catch "";
    return ui.fonts.legend.measure(s) + 8;
}

/// One row of chips, or two when the column is too narrow for one.
fn chipsHeight(ui: *const Ui, w: i32, n: Counts) i32 {
    var buf: [24]u8 = undefined;
    var total: i32 = 8 + chipW(ui, &buf, null, n);
    for (0..KIND_CHIPS.len) |k| total += chipW(ui, &buf, k, n) + 2;
    // The row is the plate inside its bevel and seam, inset 4 a side.
    return if (total > w - 12) 2 * CHIP_H + 10 else CHIP_H + 8;
}

fn chips(ui: *Ui, r: Rect, st: *State, n: Counts) void {
    ui.pushId("chips");
    defer ui.popId();
    const body = ui.plate(r, .{});
    var area = body.insetXY(4, 3);
    var row = area.cutTop(CHIP_H);
    const counts = n.kinds;
    const favs = n.favs;
    {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\u{2605} {d}", .{favs}) catch "";
        const w = ui.fonts.legend.measure(s) + 8;
        if (chip(ui, row.cutLeft(w), "fav", s, st.fav_only, favs == 0 and !st.fav_only)) {
            st.fav_only = !st.fav_only;
            st.scroll_to = 0;
        }
        _ = row.cutLeft(2);
    }
    for (KIND_CHIPS, 0..) |lab, k| {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s} {d}", .{ lab, counts[k] }) catch lab;
        const w = ui.fonts.legend.measure(s) + 8;
        if (w > row.w and area.h >= CHIP_H) {
            _ = area.cutTop(2);
            row = area.cutTop(CHIP_H);
        }
        if (w > row.w) break;
        const bit = @as(u8, 1) << @intCast(k);
        const on = st.kinds & bit != 0;
        if (chip(ui, row.cutLeft(w), k, s, on, counts[k] == 0 and !on)) {
            if (ui.in.shift or ui.in.cmd) st.kinds ^= bit else st.kinds = if (st.kinds == bit) 0 else bit;
            st.scroll_to = 0;
        }
        _ = row.cutLeft(2);
    }
}

fn chip(ui: *Ui, r: Rect, key: anytype, label: []const u8, on: bool, empty: bool) bool {
    const b = ui.behaviorEx(ui.id(key), r, .{ .focusable = false });
    const inner = ui.well(r, if (on) style.accent.alpha(70) else style.well);
    if (b.hover and !on) ui.rect(inner, style.text.alpha(14));
    const col = if (on) style.text else if (empty) style.text_mute else if (b.hover) style.text else style.text_dim;
    ui.textIn(&ui.fonts.legend, inner, label, col, .center, false);
    return b.clicked;
}

fn footer(ui: *Ui, r: Rect, st: *State) void {
    const body = ui.plate(r, .{});
    var buf: [48]u8 = undefined;
    var shown: usize = 0;
    for (st.rows.items) |rw| {
        if (rw.header) shown += rw.count;
    }
    const s = if (st.n_sel > 1)
        std.fmt.bufPrint(&buf, "{d} SELECTED", .{st.n_sel}) catch ""
    else
        std.fmt.bufPrint(&buf, "{d} ITEMS", .{shown}) catch "";
    ui.textIn(&ui.fonts.legend, body.insetXY(5, 0), s, style.text_dim, .right, true);
    if (body.w > 260) ui.textIn(&ui.fonts.legend, body.insetXY(5, 0), "\u{2191}\u{2193} MOVE  \u{2190}\u{2192} FOLD  \u{21A9} LOAD", style.text_mute, .left, true);
}

// ── The list ─────────────────────────────────────────────────────────

fn list(ui: *Ui, r: Rect, st: *State, lib: *library.Library, ev: text_field.Event, focused: bool, res: *Result) void {
    ui.pushId("list");
    defer ui.popId();
    const in = &ui.in;
    const items = lib.items.items;
    const well = ui.well(r, style.pane);
    const n_rows: i32 = @intCast(st.rows.items.len);
    const content_h = n_rows * ROW_H;
    const max_scroll: f32 = @floatFromInt(@max(0, content_h - well.h));
    const over = well.contains(in.ix(), in.iy());

    keys(ui, st, items, ev, focused, well, res);

    if (over and in.wheel_y != 0 and !menu.active()) {
        st.scroll_to -= in.wheel_y * @as(f32, ROW_H) * 3;
        st.scroll_t = in.time;
        st.reveal = false;
    }
    if (st.dragging and in.mx >= @as(f32, @floatFromInt(well.x)) and in.mx < @as(f32, @floatFromInt(well.right()))) {
        const top: f32 = @floatFromInt(well.y + 16);
        const bot: f32 = @floatFromInt(well.bottom() - 16);
        if (in.my < top and in.my > top - 40) st.scroll_to -= (top - in.my) * in.dt * 20;
        if (in.my > bot and in.my < bot + 40) st.scroll_to += (in.my - bot) * in.dt * 20;
        st.scroll_t = in.time;
    }
    if (st.reveal) if (st.cursor) |cur| if (rowOf(st, cur)) |k| {
        const y: f32 = @floatFromInt(@as(i32, @intCast(k)) * ROW_H);
        const vh: f32 = @floatFromInt(well.h);
        if (y - @as(f32, ROW_H) < st.scroll_to) st.scroll_to = y - @as(f32, ROW_H);
        if (y + @as(f32, ROW_H) > st.scroll_to + vh) st.scroll_to = y + @as(f32, ROW_H) - vh;
        st.reveal = false;
    };
    st.scroll_to = std.math.clamp(st.scroll_to, 0, max_scroll);
    st.scroll += (st.scroll_to - st.scroll) * @min(1, in.dt * 18);
    if (@abs(st.scroll_to - st.scroll) < 0.5) st.scroll = st.scroll_to else ui.animate();
    st.scroll = std.math.clamp(st.scroll, 0, max_scroll);
    const scroll_px: i32 = @intFromFloat(@round(st.scroll));

    ui.clip(well);
    const first: usize = @intCast(@max(0, @divFloor(scroll_px, ROW_H)));
    var k = first;
    while (k < st.rows.items.len) : (k += 1) {
        const y = well.y + @as(i32, @intCast(k)) * ROW_H - scroll_px;
        if (y >= well.bottom()) break;
        drawRow(ui, st, lib, k, Rect.xywh(well.x, y, well.w, ROW_H), well, res);
    }
    stickyHeader(ui, st, items, well, scroll_px);
    ui.unclip();
    scrollbar(ui, st, well, content_h, max_scroll);
    if (st.rows.items.len == 0) emptyState(ui, well, st);
    contextMenu(ui, st, lib, res);
}

fn emptyState(ui: *Ui, r: Rect, st: *State) void {
    const mid = Rect.xywh(r.x, r.y + @divFloor(r.h, 2) - 24, r.w, 16);
    const sub = Rect.xywh(r.x, mid.bottom() + 4, r.w, 14);
    if (st.query.len > 0) {
        var buf: [80]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "Nothing matches \"{s}\"", .{st.query.text()}) catch "Nothing matches";
        ui.textIn(&ui.fonts.body, mid, s, style.text_dim, .center, false);
        ui.textIn(&ui.fonts.legend, sub, "TRY FEWER WORDS, OR ALL SOURCES", style.text_mute, .center, false);
    } else if (st.fav_only) {
        ui.textIn(&ui.fonts.body, mid, "No favorites here yet", style.text_dim, .center, false);
        ui.textIn(&ui.fonts.legend, sub, "HOVER AN ITEM AND CLICK \u{2605}", style.text_mute, .center, false);
    } else {
        ui.textIn(&ui.fonts.body, mid, "Nothing here yet", style.text_dim, .center, false);
        ui.textIn(&ui.fonts.legend, sub, "SAVE TO LIBRARY FROM A TRACK OR MACHINE", style.text_mute, .center, false);
    }
}

fn drawRow(ui: *Ui, st: *State, lib: *library.Library, k: usize, row: Rect, well: Rect, res: *Result) void {
    const rw = st.rows.items[k];
    const items = lib.items.items;
    const it = &items[rw.item];
    const in = &ui.in;
    if (rw.header) {
        headerRow(ui, st, items, rw, row, false);
        return;
    }
    ui.pushId(@as(usize, rw.item));
    defer ui.popId();
    const wid = ui.id("row");
    const b = ui.behaviorEx(wid, row.intersect(well), .{});
    const selected = st.isSelected(rw.item);

    if (b.pressed) {
        list_wid = wid;
        st.press_item = rw.item;
        st.press_x = in.mx;
        st.press_y = in.my;
        st.press_mods = in.shift or in.cmd;
        if (in.cmd) {
            st.toggleSel(rw.item);
            st.cursor = rw.item;
            st.anchor = rw.item;
        } else if (in.shift and st.anchor != null) {
            selectRange(st, st.anchor.?, rw.item);
            st.cursor = rw.item;
        } else if (!selected) {
            st.selectOnly(rw.item);
        } else {
            st.cursor = rw.item;
        }
        if (b.double) res.load = true;
    }
    if (b.held and !st.dragging and st.press_item != null) {
        if (@abs(in.mx - st.press_x) + @abs(in.my - st.press_y) > 5 and st.isSelected(st.press_item.?)) st.dragging = true;
    }
    if (b.released and !st.dragging and !st.press_mods and st.n_sel > 1 and b.clicked) st.selectOnly(rw.item);
    if (b.hover and in.right_pressed) {
        if (!selected) st.selectOnly(rw.item);
        st.cursor = rw.item;
        menu.openAt(CTX_MENU, in.ix(), in.iy());
    }

    if (selected) ui.rect(row, style.accent.alpha(if (ui.focus == wid or ui.focus == list_wid) 70 else 40)) else if (b.hover) ui.rect(row, style.text.alpha(12));
    if (st.cursor != null and st.cursor.? == rw.item and st.n_sel > 1) ui.rect(Rect.xywh(row.x, row.y, 2, row.h), style.accent);

    var x = row.x + 16;
    kindIcon(ui, x, row.y + 5, it.kind, if (selected) style.text else style.text_dim);
    x += 12;
    if (st.tab == 0) {
        const letters = [_][]const u8{ "P", "U", "", "L" };
        const lt = letters[@intFromEnum(it.source)];
        if (lt.len > 0) {
            const br = Rect.xywh(x, row.y + 4, 9, 10);
            ui.rect(br, sourceColor(it.source).alpha(60));
            ui.textIn(&ui.fonts.legend, br, lt, style.text, .center, false);
        }
        x += 12;
    }

    // Hover actions: ★ always for a favorite, ▶ for what can play.
    var right = Rect.xywh(row.right() - 44, row.y, 40, row.h);
    const playing = st.playing != null and st.playing.? == rw.item;
    const fav_id = ui.id("fav");
    const play_id = ui.id("play");
    const show = b.hover or ui.isHot(fav_id) or ui.isHot(play_id);
    const fav_r = right.cutRight(18);
    if (show or it.fav) {
        if (iconButton(ui, fav_r, "fav", "\u{2605}", it.fav, style.led_yellow)) lib.setFav(rw.item, !it.fav);
        menu.tip(ui, fav_r, if (it.fav) "Remove from favorites" else "Add to favorites");
    }
    const play_r = right.cutRight(18);
    if (it.kind == .sample and (show or playing)) {
        if (iconButton(ui, play_r, "play", if (playing) "\u{25A0}" else "\u{25B6}", playing, style.play)) {
            if (playing) res.stop_audition = true else res.audition = rw.item;
        }
        menu.tip(ui, play_r, "Play");
    }

    const name_r = Rect.xywh(x, row.y, right.x - x - 2, row.h);
    highlighted(ui, name_r, shownName(it), st.query.text(), if (selected) style.text else style.text_dim, playing);
    if (b.hover and !st.dragging) {
        var rb: [storage.MAX_PATH]u8 = undefined;
        menu.tip(ui, name_r, storage.ref(&rb, it.path));
    }
}

fn headerRow(ui: *Ui, st: *State, items: []const Item, rw: Row, row: Rect, sticky: bool) void {
    const it = &items[rw.item];
    ui.pushId(.{ "head", @as(usize, rw.item), sticky });
    defer ui.popId();
    const key = groupKey(it);
    const b = ui.behaviorEx(ui.id("h"), row, .{ .focusable = false });
    const searching = st.query.len > 0 or st.fav_only;
    const is_open = searching or st.isOpen(key);
    if (b.clicked and !searching) {
        if (ui.in.alt) {
            const want = !is_open;
            for (st.rows.items) |o| if (o.header) st.setOpen(groupKey(&items[o.item]), want);
        } else st.setOpen(key, !is_open);
    }
    ui.rect(row, if (sticky) style.pane_alt else style.pane);
    if (b.hover) ui.rect(row, style.text.alpha(10));
    ui.rect(Rect.xywh(row.x, row.bottom() - 1, row.w, 1), style.edge);
    ui.textIn(&ui.fonts.legend, Rect.xywh(row.x + 4, row.y, 10, row.h), if (is_open) "\u{25BE}" else "\u{25B8}", if (searching) style.text_mute else style.text_dim, .left, false);
    var x = row.x + 16;
    kindIcon(ui, x, row.y + 5, it.kind, style.text_mute);
    x += 12;
    var cb: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&cb, "{d}", .{rw.count}) catch "";
    const cw = ui.fonts.legend.measure(cs) + 8;
    var fb: [96]u8 = undefined;
    const avail = row.right() - cw - x - 4;
    var eb: [100]u8 = undefined;
    const folder = ellipsizeEnd(&eb, &ui.fonts.legend_bold, upper(&fb, it.folder), avail);
    x += ui.text(&ui.fonts.legend_bold, x, row.y + 3, folder, style.text);
    const suffix = "  PRESETS";
    if (it.kind == .preset and x + ui.fonts.legend.measure(suffix) <= row.right() - cw - 4) _ = ui.text(&ui.fonts.legend, x, row.y + 3, suffix, style.text_mute);
    ui.textIn(&ui.fonts.legend, row.insetXY(6, 0), cs, style.text_mute, .right, false);
}

fn stickyHeader(ui: *Ui, st: *State, items: []const Item, well: Rect, scroll_px: i32) void {
    const rows = st.rows.items;
    if (rows.len == 0 or scroll_px <= 0) return;
    const top: usize = @intCast(@divFloor(scroll_px, ROW_H));
    if (top >= rows.len) return;
    var h = top;
    while (h > 0 and !rows[h].header) h -= 1;
    if (!rows[h].header) return;
    if (h == top and @mod(scroll_px, ROW_H) == 0) return;
    var y = well.y;
    if (top + 1 < rows.len and rows[top + 1].header) {
        const next_y = well.y + @as(i32, @intCast(top + 1)) * ROW_H - scroll_px;
        y = @min(y, next_y - ROW_H);
    }
    const r = Rect.xywh(well.x, y, well.w, ROW_H);
    headerRow(ui, st, items, rows[h], r, true);
    ui.rect(Rect.xywh(r.x, r.bottom(), r.w, 1), style.edge.alpha(120));
}

fn scrollbar(ui: *Ui, st: *State, well: Rect, content_h: i32, max_scroll: f32) void {
    if (max_scroll <= 0) return;
    const in = &ui.in;
    const track = Rect.xywh(well.right() - 8, well.y, 8, well.h);
    const wid = ui.id("scrollbar");
    const b = ui.behaviorEx(wid, track, .{ .prio = 1, .focusable = false });
    const vh: f32 = @floatFromInt(well.h);
    const ch: f32 = @floatFromInt(content_h);
    const thumb_h: i32 = @max(20, @as(i32, @intFromFloat(vh * vh / ch)));
    const travel: f32 = @floatFromInt(well.h - thumb_h);
    const ty = well.y + @as(i32, @intFromFloat(@round(st.scroll / max_scroll * travel)));
    if (b.pressed) {
        const grab = ui.memo(wid, 0);
        const on_thumb = in.iy() >= ty and in.iy() < ty + thumb_h;
        grab.* = if (on_thumb) @floatFromInt(in.iy() - ty) else @floatFromInt(@divFloor(thumb_h, 2));
    }
    if (b.held) {
        const grab = ui.memo(wid, 0).*;
        const pos = (in.my - grab - @as(f32, @floatFromInt(well.y))) / @max(1, travel);
        st.scroll_to = std.math.clamp(pos, 0, 1) * max_scroll;
        st.scroll = st.scroll_to;
        st.scroll_t = in.time;
    }
    const since = in.time - st.scroll_t;
    if (!(b.hover or b.held or since < 1.2)) return;
    if (since < 1.2) ui.animate();
    const fade: f32 = if (b.hover or b.held) 1 else @floatCast(std.math.clamp((1.2 - since) / 0.4, 0, 1));
    const w: i32 = if (b.hover or b.held) 6 else 3;
    ui.rect(Rect.xywh(track.right() - w - 1, ty, w, thumb_h), style.text_dim.alpha(@intFromFloat(fade * @as(f32, if (b.held) 200 else 120))));
}

fn keys(ui: *Ui, st: *State, items: []const Item, ev: text_field.Event, focused: bool, well: Rect, res: *Result) void {
    const in = &ui.in;
    if (menu.active() or st.dragging) return;
    const query_focus = ui.focus == query_wid;
    if (ev == .commit) {
        if (st.cursor == null) firstItem(st);
        res.load = st.cursor != null;
        return;
    }
    if (ev == .cancel) {
        st.query.set("");
        return;
    }
    if (!(focused or query_focus)) return;
    if (!query_focus and in.keyPressed(c.rl.KEY_ESCAPE)) {
        if (st.query.len > 0) st.query.set("") else st.n_sel = 0;
        return;
    }
    const page: i32 = @max(1, @divFloor(well.h, ROW_H) - 1);
    var step: i32 = 0;
    if (in.keyPressed(c.rl.KEY_DOWN)) step = 1;
    if (in.keyPressed(c.rl.KEY_UP)) step = -1;
    if (!query_focus) {
        if (in.keyPressed(c.rl.KEY_PAGE_DOWN)) step = page;
        if (in.keyPressed(c.rl.KEY_PAGE_UP)) step = -page;
    }
    if (step != 0) return moveCursor(st, step, in.shift and !query_focus);
    if (query_focus) return;
    if (in.keyPressed(c.rl.KEY_LEFT) or in.keyPressed(c.rl.KEY_RIGHT)) {
        const cur = st.cursor orelse return;
        const right = in.keyPressed(c.rl.KEY_RIGHT);
        st.setOpen(groupKey(&items[cur]), right);
        if (!right) {
            st.n_sel = 0;
            st.cursor = null;
        }
        return;
    }
    if (in.keyPressed(c.rl.KEY_ENTER) and st.cursor != null) res.load = true;
    if (in.cmd and in.keyPressed(c.rl.KEY_A)) {
        st.n_sel = 0;
        for (st.rows.items) |rw| if (!rw.header and st.n_sel < MAX_SEL) {
            st.sel[st.n_sel] = rw.item;
            st.n_sel += 1;
        };
    }
}

fn firstItem(st: *State) void {
    for (st.rows.items) |rw| if (!rw.header) {
        st.selectOnly(rw.item);
        return;
    };
}

fn moveCursor(st: *State, step: i32, extend: bool) void {
    const rows = st.rows.items;
    if (rows.len == 0) return;
    var at: i32 = -1;
    if (st.cursor) |cur| if (rowOf(st, cur)) |k| {
        at = @intCast(k);
    };
    var k: i32 = std.math.clamp(at + step, 0, @as(i32, @intCast(rows.len)) - 1);
    const dir: i32 = if (step < 0) -1 else 1;
    while (k >= 0 and k < rows.len and rows[@intCast(k)].header) k += dir;
    if (k < 0 or k >= rows.len) return;
    const item = rows[@intCast(k)].item;
    if (extend and st.anchor != null) {
        selectRange(st, st.anchor.?, item);
        st.cursor = item;
    } else st.selectOnly(item);
    st.reveal = true;
}

fn selectRange(st: *State, a: u32, b: u32) void {
    const ka = rowOf(st, a) orelse return st.selectOnly(b);
    const kb = rowOf(st, b) orelse return;
    st.n_sel = 0;
    for (st.rows.items[@min(ka, kb) .. @max(ka, kb) + 1]) |rw| if (!rw.header and st.n_sel < MAX_SEL) {
        st.sel[st.n_sel] = rw.item;
        st.n_sel += 1;
    };
}

fn verbOf(k: Kind) []const u8 {
    return switch (k) {
        .preset => "Load on Track",
        .table => "Load into Oscillator",
        .song => "Open Song",
        else => "Insert on Track",
    };
}

fn contextMenu(ui: *Ui, st: *State, lib: *library.Library, res: *Result) void {
    if (!menu.isOpen(CTX_MENU)) return;
    const cur = st.cursor orelse return;
    const it = &lib.items.items[cur];
    const many = st.n_sel > 1;
    const items = [_]menu.Item{
        .{ .label = verbOf(it.kind), .id = 1, .shortcut = "\u{21A9}" },
        .{ .label = "Play", .id = 2, .enabled = it.kind == .sample },
        .{ .separator = true },
        .{ .label = if (it.fav) "Remove from Favorites" else "Add to Favorites", .id = 3 },
        .{ .label = "Copy Reference", .id = 4 },
        .{ .label = "Show in Finder", .id = 5, .enabled = !many },
        .{ .separator = true },
        .{ .label = "Publish\u{2026}", .id = 7, .enabled = false },
    };
    const picked = menu.pick(CTX_MENU, &items) orelse return;
    switch (picked) {
        1 => res.load = true,
        2 => res.audition = cur,
        3 => {
            const want = !it.fav;
            for (st.sel[0..st.n_sel]) |s| lib.setFav(s, want);
        },
        4 => {
            var rb: [storage.MAX_PATH]u8 = undefined;
            const ref = storage.ref(&rb, it.path);
            ui.setClipboard(ref);
            st.say(res, "Copied {s}", .{ref});
        },
        5 => res.reveal = it.path,
        else => {},
    }
}

// ── Preview ──────────────────────────────────────────────────────────

fn preview(ui: *Ui, r: Rect, st: *State, items: []const Item, res: *Result) void {
    ui.pushId("preview");
    defer ui.popId();
    var body = ui.plate(r, .{});
    const head = body.cutTop(18);
    const folded = r.h <= 24;
    const cur = st.cursor orelse {
        ui.textIn(&ui.fonts.legend, head.insetXY(4, 0), "PREVIEW", style.text_dim, .left, true);
        if (!folded) ui.textIn(&ui.fonts.legend, body, "SELECT AN ITEM", style.text_mute, .center, true);
        return;
    };
    const it = &items[cur];
    var hb: [160]u8 = undefined;
    var fb: [96]u8 = undefined;
    var nb: [96]u8 = undefined;
    const crumb = std.fmt.bufPrint(&hb, "{s} \u{25B8} {s} \u{25B8} {s}", .{ SOURCE_NAMES[@intFromEnum(it.source)], upper(&fb, it.folder), upper(&nb, shownName(it)) }) catch "";
    var eb: [160]u8 = undefined;
    ui.textIn(&ui.fonts.legend, head.insetXY(4, 0), ellipsizeMiddle(&eb, &ui.fonts.legend, crumb, head.w - 8), style.text_dim, .left, true);
    if (folded) return;

    var acts = body.cutBottom(24).insetXY(4, 2);
    const verb: []const u8 = switch (it.kind) {
        .preset, .table => "LOAD",
        .song => "OPEN",
        else => "INSERT",
    };
    if (ctl.button(ui, acts.cutLeft(64), "load", null, .{ .label = verb })) res.load = true;
    _ = acts.cutLeft(3);
    if (it.kind == .sample) {
        const playing = st.playing != null and st.playing.? == cur;
        var p = playing;
        if (ctl.button(ui, acts.cutLeft(28), "play", &p, .{ .kind = .latch, .glyph = .tri_right, .glyph_on = style.play })) {
            if (playing) res.stop_audition = true else res.audition = cur;
        }
        _ = acts.cutLeft(3);
    }
    const reveal_r = acts.cutRight(64);
    if (ctl.button(ui, reveal_r, "reveal", null, .{ .label = "FINDER" })) res.reveal = it.path;
    menu.tip(ui, reveal_r, "Show in Finder");

    // The reference (click copies).
    var refb: [storage.MAX_PATH]u8 = undefined;
    const ref = storage.ref(&refb, it.path);
    const ref_r = body.cutBottom(14).insetXY(4, 0);
    const rb = ui.behaviorEx(ui.id("ref"), ref_r, .{ .focusable = false });
    var eb2: [storage.MAX_PATH]u8 = undefined;
    ui.textIn(&ui.fonts.legend, ref_r, ellipsizeMiddle(&eb2, &ui.fonts.legend, ref, ref_r.w), if (rb.hover) style.text else style.text_mute, .left, false);
    if (rb.hover) ui.requestCursor(c.rl.MOUSE_CURSOR_POINTING_HAND, 3);
    if (rb.clicked) {
        ui.setClipboard(ref);
        st.say(res, "Copied {s}", .{ref});
    }
    menu.tip(ui, ref_r, "Click to copy the reference");

    const lic_r = body.cutBottom(14).insetXY(4, 0);
    const lic: []const u8 = switch (it.source) {
        .pack => if (it.shareable) "FROM A PACK \u{B7} FREE TO SHARE" else "FROM A PACK \u{B7} YOURS, NOT TO SHARE",
        .factory => "SHIPS WITH SLAB",
        .project => "IN THIS PROJECT",
        .user => "IN YOUR LIBRARY",
    };
    ui.textIn(&ui.fonts.legend, lic_r, lic, if (it.shareable) style.text_mute else style.led_red.mix(style.text_dim, 0.4), .left, false);

    const pic = body.insetXY(4, 3);
    if (pic.h < 24) return;
    switch (it.kind) {
        .sample => samplePic(ui, pic, st),
        .table => tablePic(ui, pic, st),
        .clip => clipPic(ui, pic, st),
        .preset => textPic(ui, pic, upper(&fb, it.folder), "PRESET"),
        .song => textPic(ui, pic, upper(&nb, leaf(it.name)), "SONG"),
    }
}

fn textPic(ui: *Ui, r: Rect, big: []const u8, small: []const u8) void {
    const inner = ui.well(r, style.well);
    ctl.vfdText(ui, inner.x + 6, inner.y + 6, big, style.vfd);
    ui.textIn(&ui.fonts.legend, Rect.xywh(inner.x + 6, inner.bottom() - 16, inner.w - 12, 12), small, style.vfd.alpha(140), .left, false);
}

/// Min/max per column, from a stride through the data (no full scan).
fn samplePic(ui: *Ui, r: Rect, st: *State) void {
    const inner = ui.well(r, style.well);
    const d = st.wave.data;
    if (d.len == 0 or st.wave.frame != 0) return;
    ui.clip(inner);
    defer ui.unclip();
    const mid = inner.y + @divFloor(inner.h, 2);
    const half: f32 = @floatFromInt(@divFloor(inner.h, 2) - 2);
    const w: usize = @intCast(@max(1, inner.w));
    for (0..w) |x| {
        const a = x * d.len / w;
        const b = @max(a + 1, (x + 1) * d.len / w);
        const stride = @max(1, (b - a) / 48);
        var lo: f64 = 0;
        var hi: f64 = 0;
        var i = a;
        while (i < b) : (i += stride) {
            lo = @min(lo, d[i]);
            hi = @max(hi, d[i]);
        }
        const y0 = mid - @as(i32, @intFromFloat(@as(f32, @floatCast(hi)) * half));
        const y1 = mid - @as(i32, @intFromFloat(@as(f32, @floatCast(lo)) * half));
        ui.rect(Rect.xywh(inner.x + @as(i32, @intCast(x)), y0, 1, @max(1, y1 - y0 + 1)), style.vfd.alpha(200));
    }
    if (st.play_at) |at| if (at < d.len) {
        const px: i32 = @intCast(@as(usize, at) * w / d.len);
        ui.rect(Rect.xywh(inner.x + px, inner.y, 1, inner.h), style.accent);
        ui.animate();
    };
}

/// Stacked frames, the way a wavetable synth draws one.
fn tablePic(ui: *Ui, r: Rect, st: *State) void {
    const inner = ui.well(r, style.well);
    const d = st.wave.data;
    const fs = st.wave.frame;
    if (fs == 0 or d.len < fs) return;
    ui.clip(inner);
    defer ui.unclip();
    const frames = d.len / fs;
    const shown: usize = @min(frames, 16);
    const n = 64;
    const dx: f32 = 3;
    const dy: f32 = @as(f32, @floatFromInt(inner.h)) / 48;
    const w: f32 = @as(f32, @floatFromInt(inner.w)) - dx * @as(f32, @floatFromInt(shown)) - 8;
    const amp: f32 = @as(f32, @floatFromInt(inner.h)) * 0.22;
    var f: usize = shown;
    while (f > 0) {
        f -= 1;
        const src = f * (frames - 1) / @max(1, shown - 1);
        const ff: f32 = @floatFromInt(f);
        const x0 = @as(f32, @floatFromInt(inner.x + 4)) + ff * dx;
        const y0 = @as(f32, @floatFromInt(inner.bottom())) - amp - 6 - ff * dy * 2;
        var px: f32 = x0;
        var py: f32 = y0;
        for (0..n) |i| {
            const u = @as(f32, @floatFromInt(i)) / (n - 1);
            const v: f32 = @floatCast(d[src * fs + @min(fs - 1, @as(usize, @intFromFloat(u * @as(f32, @floatFromInt(fs - 1)))))]);
            const x = x0 + u * w;
            const y = y0 - v * amp;
            if (i > 0) ui.line(px, py, x, y, style.vfd.alpha(@intFromFloat(60 + 140 * (1 - ff / @as(f32, @floatFromInt(shown))))));
            px = x;
            py = y;
        }
    }
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d} FRAMES", .{frames}) catch "";
    ui.textIn(&ui.fonts.legend, inner.insetXY(4, 2).takeTop(12), s, style.vfd.alpha(160), .right, false);
}

fn clipPic(ui: *Ui, r: Rect, st: *State) void {
    const inner = ui.well(r, style.well);
    if (st.n_notes == 0) {
        ui.textIn(&ui.fonts.legend, inner, "NO NOTES", style.text_mute, .center, false);
        return;
    }
    ui.clip(inner);
    defer ui.unclip();
    var lo: f32 = 127;
    var hi: f32 = 0;
    for (st.notes[0..st.n_notes]) |n| {
        lo = @min(lo, n[0]);
        hi = @max(hi, n[0]);
    }
    const span = @max(12, hi - lo + 1);
    const beats = @max(1, st.clip_len);
    const bw = @as(f32, @floatFromInt(inner.w)) / beats;
    var b: f32 = 0;
    while (b <= beats) : (b += 1) {
        const x: i32 = inner.x + @as(i32, @intFromFloat(b * bw));
        ui.rect(Rect.xywh(x, inner.y, 1, inner.h), if (@mod(b, 4) == 0) style.grid_bar else style.grid_sub);
    }
    const lh = @max(2, @as(f32, @floatFromInt(inner.h - 4)) / span);
    for (st.notes[0..st.n_notes]) |n| {
        const y = @as(f32, @floatFromInt(inner.bottom() - 2)) - (n[0] - lo + 1) * lh;
        ui.rect(Rect.xywh(inner.x + @as(i32, @intFromFloat(n[1] * bw)), @intFromFloat(y), @max(2, @as(i32, @intFromFloat(n[2] * bw)) - 1), @max(1, @as(i32, @intFromFloat(lh)) - 1)), style.vfd);
    }
}

/// The notes of a .slabclip, for its picture.
fn readClip(alloc: std.mem.Allocator, st: *State, it: *const Item, idx: u32) void {
    st.clip_for = idx;
    st.n_notes = 0;
    if (it.kind != .clip) return;
    const data = readFile(alloc, it.path) orelse return;
    defer alloc.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const cv = parsed.value.object.get("clip") orelse return;
    if (cv != .object) return;
    st.clip_len = if (cv.object.get("len")) |l| num(l) else 4;
    const nv = cv.object.get("notes") orelse return;
    if (nv != .array) return;
    for (nv.array.items) |n| {
        if (n != .object or st.n_notes >= MAX_NOTES) continue;
        const p = n.object.get("pitch") orelse continue;
        st.notes[st.n_notes] = .{ num(p), if (n.object.get("start")) |v| num(v) else 0, if (n.object.get("len")) |v| num(v) else 0.25 };
        st.n_notes += 1;
    }
}

fn num(v: std.json.Value) f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => 0,
    };
}

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern fn close(fd: c_int) c_int;

fn readFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    if (path.len >= zb.len) return null;
    @memcpy(zb[0..path.len], path);
    zb[path.len] = 0;
    const fd = open(&zb, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (out.items.len < 4 << 20) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        out.appendSlice(alloc, chunk[0..@intCast(n)]) catch {
            out.deinit(alloc);
            return null;
        };
    }
    return out.toOwnedSlice(alloc) catch null;
}

// ── Packs and online ─────────────────────────────────────────────────

/// The library's packs: one card each, from what `library` found.
fn packsView(ui: *Ui, r: Rect, items: []const Item, res: *Result) void {
    ui.pushId("packs");
    defer ui.popId();
    const area = ui.well(r, style.pane);
    var col = area.inset(6);
    var lb: [storage.MAX_PATH]u8 = undefined;
    const lib_dir = storage.library(&lb);
    ui.textIn(&ui.fonts.legend, col.cutTop(14), "SAMPLE PACKS IN YOUR LIBRARY", style.text_mute, .left, false);
    _ = col.cutTop(4);
    // Packs are the lib folders that samples came from.
    var seen: [16][]const u8 = undefined;
    var counts: [16]u32 = undefined;
    var shareable: [16]bool = undefined;
    var n: usize = 0;
    for (items) |*it| {
        if (it.source != .pack or it.kind != .sample) continue;
        if (it.path.len <= lib_dir.len + 1) continue;
        const rest = it.path[lib_dir.len + 1 ..];
        const id = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        var k: usize = 0;
        while (k < n and !std.mem.eql(u8, seen[k], id)) k += 1;
        if (k == n) {
            if (n == seen.len) continue;
            seen[n] = id;
            counts[n] = 0;
            shareable[n] = it.shareable;
            n += 1;
        }
        counts[k] += 1;
    }
    for (0..n) |k| {
        if (col.h < 60) break;
        ui.pushId(k);
        defer ui.popId();
        var card = ui.plate(col.cutTop(60), .{ .outline = .all, .chamfer = 2 }).insetXY(6, 4);
        _ = col.cutTop(6);
        var top = card.cutTop(18);
        ctl.led(ui, top.x, top.y + 6, .round5, .on, style.led_green);
        _ = top.cutLeft(10);
        var nb: [64]u8 = undefined;
        ui.textIn(&ui.fonts.body_bold, top, upper(&nb, seen[k]), style.text, .left, true);
        var mb: [96]u8 = undefined;
        const meta = std.fmt.bufPrint(&mb, "INSTALLED \u{B7} {d} SAMPLES \u{B7} {s}", .{ counts[k], if (shareable[k]) "FREE TO SHARE" else "YOURS, NOT TO SHARE" }) catch "";
        ui.textIn(&ui.fonts.legend, card.cutTop(14), meta, style.text_dim, .left, false);
        const acts = card.cutBottom(20);
        if (ctl.button(ui, acts.takeLeft(64), "reveal", null, .{ .label = "FINDER" })) {
            // The pack's folder: the first sample's path up to it.
            for (items) |*it| if (it.source == .pack and it.path.len > lib_dir.len + 1 + seen[k].len and std.mem.startsWith(u8, it.path[lib_dir.len + 1 ..], seen[k])) {
                res.reveal = it.path[0 .. lib_dir.len + 1 + seen[k].len];
                break;
            };
        }
    }
    if (n == 0) ui.textIn(&ui.fonts.legend, col.takeTop(14), "NONE YET", style.text_mute, .left, false);
    _ = col.cutTop(8);
    const lines = [_][]const u8{
        "DOWNLOADS, AND PACKS YOU BRING YOUR",
        "OWN FILES FOR, ARRIVE WITH PHASE 5",
        "(DOCS/25 \u{A7}PACKS).",
    };
    for (lines) |l| ui.textIn(&ui.fonts.legend, col.cutTop(13), l, style.text_mute, .left, false);
}

fn onlineView(ui: *Ui, r: Rect) void {
    const area = ui.well(r, style.pane);
    const mid = Rect.xywh(area.x, area.y + @divFloor(area.h, 2) - 40, area.w, 16);
    ui.textIn(&ui.fonts.body_bold, mid, "THE ONLINE REPOSITORY", style.text_dim, .center, true);
    const lines = [_][]const u8{
        "SEARCH HERE WILL REACH SHARED PRESETS,",
        "TABLES, CLIPS AND SONGS.",
        "",
        "ARRIVES IN PHASE 7 (DOCS/25).",
    };
    var y = mid.bottom() + 8;
    for (lines) |l| {
        ui.textIn(&ui.fonts.legend, Rect.xywh(area.x, y, area.w, 12), l, style.text_mute, .center, false);
        y += 13;
    }
}

// ── Drag ghost and drop hints (drawn by main) ────────────────────────

/// What's being dragged, under the pointer. `ok`: the target takes it.
pub fn drawGhost(ui: *Ui, st: *const State, items: []const Item, ok: bool) void {
    if (!st.dragging) return;
    const cur = st.cursor orelse return;
    const it = &items[cur];
    var nb: [96]u8 = undefined;
    const name = upper(&nb, shownName(it));
    const f = &ui.fonts.legend;
    const w = @min(320, f.measure(name) + 28 + (if (st.n_sel > 1) @as(i32, 20) else 0));
    const r = Rect.xywh(ui.in.ix() + 10, ui.in.iy() + 6, w, 18);
    if (st.n_sel > 1) {
        ui.rect(Rect.xywh(r.x + 3, r.y + 3, r.w, r.h), style.edge);
        ui.rect(Rect.xywh(r.x + 3, r.y + 3, r.w - 1, r.h - 1), style.face_lo);
    }
    ui.rect(r, style.edge);
    ui.rect(r.inset(1), if (ok) style.face_hi else style.face_lo);
    kindIcon(ui, r.x + 6, r.y + 6, it.kind, if (ok) style.text else style.text_mute);
    ui.clip(r);
    ui.textIn(f, Rect.xywh(r.x + 16, r.y, r.w - 16, r.h), name, if (ok) style.text else style.text_mute, .left, false);
    ui.unclip();
    if (st.n_sel > 1) {
        var cb: [8]u8 = undefined;
        const cs = std.fmt.bufPrint(&cb, "{d}", .{st.n_sel}) catch "";
        const br = Rect.xywh(r.right() - 18, r.y + 3, 14, 12);
        ui.rect(br, style.accent);
        ui.textIn(f, br, cs, style.edge, .center, false);
    }
    ui.requestCursor(if (ok) c.rl.MOUSE_CURSOR_DEFAULT else c.rl.MOUSE_CURSOR_NOT_ALLOWED, 9);
    ui.animate();
}

/// A drop target lit: amber when it takes the drag, red when it won't.
pub fn drawTarget(ui: *Ui, r: Rect, ok: bool, label: []const u8) void {
    const col = if (ok) style.accent else style.rec;
    ui.rect(r, col.alpha(30));
    outline(ui, r, col);
    if (label.len > 0 and r.h >= 14) ui.textIn(&ui.fonts.legend, Rect.xywh(r.x + 6, r.bottom() - 14, r.w - 12, 12), label, col, .right, false);
}

/// Where a clip would land in a lane: its length from the beat.
pub fn drawLanding(ui: *Ui, lane: Rect, x0: i32, x1: i32) void {
    const r = Rect.xywh(x0, lane.y + 3, @max(4, x1 - x0), lane.h - 7);
    ui.rect(r, style.accent.alpha(50));
    outline(ui, r, style.accent);
    ui.rect(Rect.xywh(x0 - 1, lane.y, 1, lane.h), style.accent);
}

pub fn drawNewTrack(ui: *Ui, r: Rect, on: bool) void {
    const zone = Rect.xywh(r.x + 8, r.y + 8, r.w - 16, @min(r.h - 16, 44));
    if (zone.h < 16) return;
    dashed(ui, zone, if (on) style.accent else style.text_mute);
    ui.textIn(&ui.fonts.legend, zone, "DROP HERE FOR A NEW TRACK", if (on) style.accent else style.text_mute, .center, false);
}

fn outline(ui: *Ui, r: Rect, col: Color) void {
    ui.rect(Rect.xywh(r.x, r.y, r.w, 1), col);
    ui.rect(Rect.xywh(r.x, r.bottom() - 1, r.w, 1), col);
    ui.rect(Rect.xywh(r.x, r.y, 1, r.h), col);
    ui.rect(Rect.xywh(r.right() - 1, r.y, 1, r.h), col);
}

fn dashed(ui: *Ui, r: Rect, col: Color) void {
    var x = r.x;
    while (x < r.right()) : (x += 6) {
        ui.rect(Rect.xywh(x, r.y, @min(3, r.right() - x), 1), col);
        ui.rect(Rect.xywh(x, r.bottom() - 1, @min(3, r.right() - x), 1), col);
    }
    var y = r.y;
    while (y < r.bottom()) : (y += 6) {
        ui.rect(Rect.xywh(r.x, y, 1, @min(3, r.bottom() - y)), col);
        ui.rect(Rect.xywh(r.right() - 1, y, 1, @min(3, r.bottom() - y)), col);
    }
}

// ── Small parts ──────────────────────────────────────────────────────

const ICONS = [_][7][]const u8{
    .{ ".###.", "#...#", "#.#.#", "#.#.#", "#...#", ".###.", "....." },
    .{ ".#...", "#.#.#", "...#.", ".#...", "#.#.#", "...#.", "....." },
    .{ "##...", ".....", "..###", ".....", "#..##", ".....", "....." },
    .{ "..#..", ".##..", "####.", "#####", "####.", ".##..", "..#.." },
    .{ "#####", ".....", "###..", ".....", "#####", ".....", "....." },
};

fn kindIcon(ui: *Ui, x: i32, y: i32, k: Kind, col: Color) void {
    for (ICONS[@intFromEnum(k)], 0..) |row, ry| for (row, 0..) |ch, rx| {
        if (ch == '#') ui.px(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), col);
    };
}

fn sourceColor(s: Source) Color {
    return switch (s) {
        .project => style.track[4],
        .user => style.track[2],
        .factory => style.text_mute,
        .pack => style.track[6],
    };
}

fn iconButton(ui: *Ui, r: Rect, key: anytype, glyph: []const u8, on: bool, on_col: Color) bool {
    const b = ui.behaviorEx(ui.id(key), r, .{ .focusable = false });
    if (b.hover) ui.rect(r.insetXY(1, 2), style.text.alpha(20));
    ui.textIn(&ui.fonts.legend, r, glyph, if (on) on_col else if (b.hover) style.text else style.text_mute, .center, false);
    return b.clicked;
}

/// A name's last part: "BD/BD0010" shows as "BD0010", the path stays in
/// the tooltip and the preview's reference.
fn leaf(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
}

/// What a row shows: the leaf, without a pack's name repeated in front
/// ("Reverb Roland TR-808 Sample Pack_Kick Accent" under that pack's
/// group shows as "Kick Accent").
fn shownName(it: *const Item) []const u8 {
    const l = leaf(it.name);
    const group = if (std.mem.lastIndexOf(u8, it.folder, "\u{B7} ")) |i| it.folder[i + "\u{B7} ".len ..] else it.folder;
    if (group.len > 0 and l.len > group.len + 1 and std.ascii.startsWithIgnoreCase(l, group)) {
        const rest = std.mem.trimStart(u8, l[group.len..], " _-");
        if (rest.len > 0) return rest;
    }
    return l;
}

fn upper(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |ch, i| buf[i] = if (ch == '_') ' ' else std.ascii.toUpper(ch);
    return buf[0..n];
}

fn ellipsizeEnd(buf: []u8, f: *const core.Font, s: []const u8, w: i32) []const u8 {
    if (f.measure(s) <= w) return s;
    var n = s.len;
    while (n > 0) : (n -= 1) {
        const out = std.fmt.bufPrint(buf, "{s}\u{2026}", .{s[0..n]}) catch return s;
        if (f.measure(out) <= w) return out;
    }
    return "";
}

fn ellipsizeMiddle(buf: []u8, f: *const core.Font, s: []const u8, w: i32) []const u8 {
    if (f.measure(s) <= w or s.len < 8) return s;
    var keep = s.len;
    while (keep > 4) : (keep -= 1) {
        const head = keep / 3;
        const tail = keep - head;
        const out = std.fmt.bufPrint(buf, "{s}\u{2026}{s}", .{ s[0..head], s[s.len - tail ..] }) catch return s;
        if (f.measure(out) <= w) return out;
    }
    return s;
}

/// `s` in `r`, the spans matching a query word bold and underlined.
fn highlighted(ui: *Ui, r: Rect, s: []const u8, query: []const u8, col: Color, playing: bool) void {
    var mark = [_]bool{false} ** 128;
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |w| {
        if (std.ascii.indexOfIgnoreCase(s, w)) |at| {
            for (at..@min(at + w.len, mark.len)) |i| mark[i] = true;
        }
    }
    const f = &ui.fonts.body;
    const fb = &ui.fonts.body_bold;
    ui.clip(r);
    defer ui.unclip();
    var x = r.x;
    const y = r.y + @divFloor(r.h - f.lineHeight(), 2);
    var i: usize = 0;
    while (i < s.len and x < r.right()) {
        const m = i < mark.len and mark[i];
        var j = i;
        while (j < s.len and (j < mark.len and mark[j]) == m) j += 1;
        if (m) {
            const w = fb.measure(s[i..j]);
            ui.rect(Rect.xywh(x, y + f.lineHeight() - 2, w, 1), style.text.alpha(90));
            x += ui.text(fb, x, y, s[i..j], style.text);
        } else x += ui.text(f, x, y, s[i..j], if (playing) style.play else col);
        i = j;
    }
}

test "browser search matches name, folder or kind" {
    const it = Item{ .kind = .preset, .source = .factory, .name = "crisp-saw-bass", .folder = "Concoction", .path = "/x" };
    try std.testing.expect(matches(&it, "conc BASS"));
    try std.testing.expect(matches(&it, "preset saw"));
    try std.testing.expect(!matches(&it, "pad"));
}
