//! Menus and tooltips on the new Ui (docs/06 §Menus and tooltips).
//!
//! One menu is open at a time, identified by an explicit u64 key. Callers
//! tick it every frame while it is open (`command` / `pick`, then
//! `subOpen` + `subPick` for each expanded child level) and the menu draws
//! itself at the end of the frame (`draw`, just before `Ui.render`), on top
//! of everything. An open menu is modal: the host hides the pointer from
//! the panes while `active()`, and the menu reads the raw input captured in
//! `beginFrame`.
//!
//! Pointer: hover selects, hovering a submenu row expands it, release on a
//! row picks it, a press outside closes. Keyboard: ↑/↓ move, → or ↩ opens a
//! submenu, ← backs out, ↩ picks, esc closes.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const controls = @import("controls.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Input = core.Input;

pub const EditCommand = enum {
    none,
    copy,
    cut,
    paste,
    duplicate,
    delete,
    select_all,
    clear_selection,
    loop_selection,
    loop_arrangement,
    clear_loop,
    file_open,
    file_save,
    file_save_as,
    file_new,
    file_clean_up,
    render_audio,
    split_at_playhead,
    quantize,
    humanize,
    snap_to_scale,
    octave_up,
    octave_down,
    rename,
    import_audio,
    reverse,
    warp,
    mute_clips,
    bounce,
    rebounce,
    thaw,
    clear_solo_mute,
    save_to_library,
    extract_groove,
    commit_groove,
    song_follows_clip,
    slice_to_sampler,
    audio_to_notes,
};

pub const Item = struct {
    label: []const u8 = "",
    command: EditCommand = .none,
    id: u32 = 0,
    enabled: bool = true,
    separator: bool = false,
    /// Hovering expands a child menu (drawn with a ▸); the caller supplies
    /// the child's items via `subPick`.
    submenu: bool = false,
    /// Right-aligned shortcut hint; derived from `command` when null.
    shortcut: ?[]const u8 = null,
};

/// Keybind hints, derived from the command (key symbols are synthesized
/// into the Tamzen legend face, see font.zig).
fn commandShortcut(cmd: EditCommand) ?[]const u8 {
    return switch (cmd) {
        .copy => "\u{2318}C",
        .cut => "\u{2318}X",
        .paste => "\u{2318}V",
        .select_all => "\u{2318}A",
        .duplicate => "D",
        .delete => "\u{232B}",
        .rename => "\u{21A9}",
        .quantize => "Q",
        .humanize => "H",
        .snap_to_scale => "S",
        .octave_up => "\u{21E7}\u{2191}",
        .octave_down => "\u{21E7}\u{2193}",
        .file_save => "\u{2318}S",
        .file_save_as => "\u{2318}\u{21E7}S",
        .file_open => "\u{2318}O",
        .file_new => "\u{2318}N",
        .render_audio => "\u{2318}R",
        .clear_solo_mute => "\u{21E7}M",
        .mute_clips => "0",
        .bounce => "\u{2318}B",
        else => null,
    };
}

// ── Metrics ──────────────────────────────────────────────────────────

pub const MAX_DEPTH = 4;
const MAX_ITEMS = 40;
const LABEL_MAX = 64;
const HINT_MAX = 16;
const ROW_H: i32 = 18;
const SEP_H: i32 = 7;
const PAD_X: i32 = 8;
const MIN_W: i32 = 112;
const HINT_GAP: i32 = 16;
/// A release this far from the opening point picks even before the menu
/// is armed (press-drag-release selection).
const DRAG_PICK: f32 = 8;

// ── State ────────────────────────────────────────────────────────────

/// One registered level: items are copied (labels included) because the
/// caller's buffers may not outlive the tick, and the draw is deferred.
const Level = struct {
    items: [MAX_ITEMS]Item = undefined,
    labels: [MAX_ITEMS][LABEL_MAX]u8 = undefined,
    hints: [MAX_ITEMS][HINT_MAX]u8 = undefined,
    len: usize = 0,
    rect: Rect = .{},
    /// Keyboard/hover selection.
    sel: ?usize = null,
    /// Select the first pickable row on the next tick (opened by keyboard).
    want_first: bool = false,

    fn rowRect(l: *const Level, i: usize) Rect {
        var y = l.rect.y + 1;
        for (l.items[0..i]) |it| y += if (it.separator) SEP_H else ROW_H;
        return Rect.xywh(l.rect.x + 1, y, l.rect.w - 2, if (l.items[i].separator) SEP_H else ROW_H);
    }
};

var key: u64 = 0;
var anchor_x: i32 = 0;
var anchor_y: i32 = 0;
/// The opening press must not count as an outside click.
var just_opened: bool = false;
/// The opening press must not pick either: a clamped menu can land under
/// the pointer. Armed once that press is released.
var armed: bool = true;
var open_mx: f32 = 0;
var open_my: f32 = 0;
var levels: [MAX_DEPTH]Level = [_]Level{.{}} ** MAX_DEPTH;
var level_count: usize = 0;
/// Last frame's level rects, for this frame's outside-click test.
var prev_rects: [MAX_DEPTH]Rect = undefined;
var prev_count: usize = 0;
/// Expansion path: which row is expanded at each level.
var path_id: [MAX_DEPTH]u32 = undefined;
var path_idx: [MAX_DEPTH]usize = undefined;
var expand_depth: usize = 0;
/// This frame's keys were handled by a level already.
var keys_done: bool = false;
var raw: Input = .{};
var screen_w: i32 = 0;
var screen_h: i32 = 0;

// ── Frame ────────────────────────────────────────────────────────────

/// Capture the raw input (call right after `Ui.beginFrame`, before any
/// `suppressInput`) and reset the per-frame registrations.
pub fn beginFrame(ui: *Ui, sw: i32, sh: i32) void {
    raw = ui.in;
    measure_font = &ui.fonts.body;
    hint_font = &ui.fonts.legend;
    screen_w = sw;
    screen_h = sh;
    prev_count = level_count;
    for (0..level_count) |i| prev_rects[i] = levels[i].rect;
    level_count = 0;
    for (&levels) |*l| l.len = 0;
    keys_done = false;
    tipBeginFrame();
}

pub fn active() bool {
    return key != 0;
}

pub fn isOpen(k: u64) bool {
    return key == k;
}

pub fn close() void {
    key = 0;
}

/// Open menu `k` with its top-left at (x, y) (clamped on screen).
pub fn openAt(k: u64, x: i32, y: i32) void {
    key = k;
    anchor_x = x;
    anchor_y = y;
    just_opened = true;
    armed = false;
    open_mx = raw.mx;
    open_my = raw.my;
    expand_depth = 0;
    for (&levels) |*l| {
        l.sel = null;
        l.want_first = false;
    }
    grid_open = false;
    tip_blocked = true;
}

/// Drop-down under a toolbar tile.
pub fn openBelow(k: u64, r: Rect) void {
    openAt(k, r.x, r.bottom());
}

/// Right-click in `r` opens context menu `k` at the pointer. Only when the
/// pointer belongs to the panes (no Ui widget hot or active, no modal).
pub fn openContext(ui: *Ui, k: u64, r: Rect) bool {
    const in = &ui.in;
    if (!in.right_pressed or ui.hot != 0 or ui.active != 0) return false;
    if (!r.contains(in.ix(), in.iy())) return false;
    openAt(k, in.ix(), in.iy());
    return true;
}

// ── Ticks ────────────────────────────────────────────────────────────

/// Root level of a command menu: the picked item's command, else `.none`.
pub fn command(k: u64, items: []const Item) EditCommand {
    if (tick(k, 0, items)) |i| return items[i].command;
    return .none;
}

/// Root level of a list menu: the picked item's `id`.
pub fn pick(k: u64, items: []const Item) ?u32 {
    if (tick(k, 0, items)) |i| return items[i].id;
    return null;
}

/// The id of the row expanded at `level`, if any: the caller builds that
/// child's items and ticks them with `subPick(k, level + 1, ...)`.
pub fn subOpen(k: u64, level: usize) ?u32 {
    if (key != k or expand_depth <= level) return null;
    return path_id[level];
}

pub fn subPick(k: u64, level: usize, items: []const Item) ?u32 {
    if (tick(k, level, items)) |i| return items[i].id;
    return null;
}

fn pickable(it: Item) bool {
    return it.enabled and !it.separator;
}

fn step(items: []const Item, from: ?usize, dir: i32) ?usize {
    const n: i32 = @intCast(items.len);
    if (n == 0) return null;
    var i: i32 = if (from) |f| @intCast(f) else if (dir > 0) -1 else n;
    var tries: i32 = 0;
    while (tries < n) : (tries += 1) {
        i = @mod(i + dir, n);
        if (pickable(items[@intCast(i)])) return @intCast(i);
    }
    return null;
}

fn expand(level: usize, i: usize, items: []const Item, by_key: bool) void {
    path_id[level] = items[i].id;
    path_idx[level] = i;
    expand_depth = level + 1;
    if (level + 1 < MAX_DEPTH) {
        levels[level + 1].sel = null;
        levels[level + 1].want_first = by_key;
    }
}

fn tick(k: u64, level: usize, items_in: []const Item) ?usize {
    if (key != k or level >= MAX_DEPTH or level > expand_depth) return null;
    const l = &levels[level];
    store(l, items_in);
    level_count = @max(level_count, level + 1);
    l.rect = levelRect(level, l);
    const items = l.items[0..l.len];
    if (l.want_first) {
        l.sel = step(items, null, 1);
        l.want_first = false;
    }

    // Pointer.
    const px = raw.ix();
    const py = raw.iy();
    const moved = raw.dx != 0 or raw.dy != 0 or raw.pressed or raw.released;
    var clicked: ?usize = null;
    for (items, 0..) |it, i| {
        if (it.separator or !l.rowRect(i).contains(px, py)) continue;
        if (moved) {
            l.sel = i;
            if (it.submenu and it.enabled) {
                if (!(expand_depth > level and path_idx[level] == i)) expand(level, i, items, false);
            } else if (expand_depth > level) {
                expand_depth = level;
            }
        }
        if (it.enabled and raw.released) clicked = i;
    }
    const dragged = @abs(raw.mx - open_mx) + @abs(raw.my - open_my) > DRAG_PICK;
    if (clicked) |ci| {
        if (!items[ci].submenu and (armed or dragged)) {
            close();
            return ci;
        }
    }
    if (!armed and !raw.down) armed = true;

    // Keyboard, on the deepest open level (once per frame).
    if (!keys_done and level == expand_depth) {
        keys_done = true;
        if (raw.keyPressed(c.rl.KEY_ESCAPE)) {
            close();
            return null;
        }
        if (raw.keyPressed(c.rl.KEY_DOWN)) l.sel = step(items, l.sel, 1);
        if (raw.keyPressed(c.rl.KEY_UP)) l.sel = step(items, l.sel, -1);
        if (raw.keyPressed(c.rl.KEY_LEFT) and level > 0) expand_depth = level - 1;
        if (l.sel) |si| {
            const it = items[si];
            const enter = raw.keyPressed(c.rl.KEY_ENTER) or raw.keyPressed(c.rl.KEY_KP_ENTER);
            if (it.submenu and it.enabled and (enter or raw.keyPressed(c.rl.KEY_RIGHT))) {
                expand(level, si, items, true);
            } else if (enter and pickable(it)) {
                close();
                return si;
            }
        }
    }

    // A press outside every level (as drawn last frame) closes.
    if (level == 0) {
        if (just_opened) {
            just_opened = false;
        } else if (raw.pressed or raw.right_pressed) {
            var inside = false;
            for (prev_rects[0..prev_count]) |pr| {
                if (pr.contains(px, py)) inside = true;
            }
            if (!inside) close();
        }
    }
    return null;
}

fn store(l: *Level, items: []const Item) void {
    const n = @min(items.len, MAX_ITEMS);
    for (items[0..n], 0..) |it, i| {
        var copy = it;
        const ln = @min(it.label.len, LABEL_MAX);
        @memcpy(l.labels[i][0..ln], it.label[0..ln]);
        copy.label = l.labels[i][0..ln];
        if (it.shortcut orelse commandShortcut(it.command)) |h| {
            const hn = @min(h.len, HINT_MAX);
            @memcpy(l.hints[i][0..hn], h[0..hn]);
            copy.shortcut = l.hints[i][0..hn];
        }
        l.items[i] = copy;
    }
    l.len = n;
}

// ── Layout ───────────────────────────────────────────────────────────

var measure_font: ?*const core.Font = null;
var hint_font: ?*const core.Font = null;

fn levelWidth(l: *const Level) i32 {
    const body = measure_font orelse return MIN_W;
    const legend = hint_font orelse return MIN_W;
    var w: i32 = MIN_W;
    for (l.items[0..l.len]) |it| {
        var extra: i32 = 0;
        if (it.submenu) {
            extra = HINT_GAP + 6;
        } else if (it.shortcut) |h| {
            extra = HINT_GAP + legend.measure(h);
        }
        w = @max(w, body.measure(it.label) + PAD_X * 2 + extra + 2);
    }
    return w;
}

fn levelRect(level: usize, l: *const Level) Rect {
    var h: i32 = 2;
    for (l.items[0..l.len]) |it| h += if (it.separator) SEP_H else ROW_H;
    const w = levelWidth(l);
    if (level == 0) {
        const x = @max(2, @min(anchor_x, screen_w - w - 2));
        const y = @max(2, @min(anchor_y, screen_h - h - 2));
        return Rect.xywh(x, y, w, h);
    }
    const parent = &levels[level - 1];
    const row = parent.rowRect(path_idx[level - 1]);
    var x = parent.rect.right() - 1;
    if (x + w > screen_w - 2) x = @max(2, parent.rect.x - w + 1); // flip left when cramped
    const y = @max(2, @min(row.y - 1, screen_h - h - 2));
    return Rect.xywh(x, y, w, h);
}

// ── Draw ─────────────────────────────────────────────────────────────

/// Draw the open menu and the pending tooltip. Call once per frame after
/// every pane ran, right before `Ui.render`.
pub fn draw(ui: *Ui) void {
    if (key != 0 and grid_open) {
        drawGrid(ui);
    } else if (key != 0) {
        for (levels[0..level_count], 0..) |*l, level| {
            if (l.len == 0) continue;
            drawLevel(ui, l, level);
        }
    }
    drawTip(ui);
}

fn drawLevel(ui: *Ui, l: *const Level, level: usize) void {
    // Floating hardware: a 1px hard edge around a faceplate.
    _ = ui.plate(l.rect, .{ .outline = .all });
    for (l.items[0..l.len], 0..) |it, i| {
        const row = l.rowRect(i);
        if (it.separator) {
            const y = row.y + @divFloor(row.h, 2);
            ui.rect(Rect.xywh(row.x + PAD_X, y, row.w - PAD_X * 2, 1), style.face_lo);
            ui.rect(Rect.xywh(row.x + PAD_X, y + 1, row.w - PAD_X * 2, 1), style.face_hi);
            continue;
        }
        const expanded = it.submenu and expand_depth > level and path_idx[level] == i;
        const lit = it.enabled and (expanded or l.sel == i);
        const inner = row.insetXY(1, 0);
        if (lit) ui.rect(inner, style.accent);
        const col = if (!it.enabled) style.text_mute else if (lit) style.chassis else style.text;
        ui.textIn(&ui.fonts.body, Rect.xywh(row.x + PAD_X, row.y, row.w - PAD_X * 2, row.h), it.label, col, .left, false);
        const hint_col = if (lit) style.chassis else style.text_mute;
        const hint_r = Rect.xywh(row.x + PAD_X, row.y, row.w - PAD_X * 2, row.h);
        if (it.submenu) {
            ui.textIn(&ui.fonts.legend, hint_r, "\u{25B8}", if (lit) style.chassis else style.text_dim, .right, false);
        } else if (it.shortcut) |h| {
            ui.textIn(&ui.fonts.legend, hint_r, h, hint_col, .right, false);
        }
    }
}

// ── Option grids ─────────────────────────────────────────────────────
//
// A display select's options (docs/06 §Selectors): the choices printed on
// the same glass as the field, under it, one column for a short list and
// a grid for a long one. Hover lights a cell, release or ↩ picks it, the
// arrows move, esc or a press outside closes. Same modal rules as a menu.

const GRID_MAX = 64;
const GRID_LABEL = 24;
const GRID_ROW: i32 = 14;
/// Options per column before the grid wraps into more columns.
const GRID_COL_ROWS: usize = 10;

var grid_open: bool = false;
var grid_labels: [GRID_MAX][GRID_LABEL]u8 = undefined;
var grid_lens: [GRID_MAX]usize = undefined;
var grid_n: usize = 0;
var grid_cur: usize = 0;
var grid_sel: ?usize = null;
var grid_field: Rect = .{};
var grid_rect: Rect = .{};
var grid_cols: usize = 1;
var grid_cell_w: i32 = 0;

/// Open option grid `k` under (or above, when cramped) `field`, with
/// option `cur` marked as the current value.
pub fn openGrid(k: u64, field: Rect, cur: usize) void {
    openAt(k, field.x, field.bottom());
    grid_open = true;
    grid_field = field;
    grid_cur = cur;
    grid_sel = cur;
    grid_n = 0;
}

fn gridRows() usize {
    return (grid_n + grid_cols - 1) / grid_cols;
}

fn gridCell(i: usize) Rect {
    const rows = gridRows();
    const col: i32 = @intCast(i / rows);
    const row: i32 = @intCast(i % rows);
    return Rect.xywh(grid_rect.x + 2 + col * grid_cell_w, grid_rect.y + 2 + row * GRID_ROW, grid_cell_w, GRID_ROW);
}

/// Tick option grid `k` every frame while it's open: the picked option.
pub fn grid(k: u64, options: []const []const u8) ?usize {
    if (key != k or !grid_open) return null;
    grid_n = @min(options.len, GRID_MAX);
    if (grid_n == 0) return null;
    var widest: i32 = 0;
    for (options[0..grid_n], 0..) |o, i| {
        const ln = @min(o.len, GRID_LABEL);
        @memcpy(grid_labels[i][0..ln], o[0..ln]);
        grid_lens[i] = ln;
        if (hint_font) |f| widest = @max(widest, f.measure(o[0..ln]));
    }
    grid_cols = (grid_n + GRID_COL_ROWS - 1) / GRID_COL_ROWS;
    const rows: i32 = @intCast(gridRows());
    const cols: i32 = @intCast(grid_cols);
    // A cell: marker, label, a spare dot cell each side.
    grid_cell_w = widest + controls.CELL_W * 3;
    if (cols == 1) grid_cell_w = @max(grid_cell_w, grid_field.w - 4);
    const w = cols * grid_cell_w + 4;
    const h = rows * GRID_ROW + 4;
    const x = @max(2, @min(grid_field.x, screen_w - w - 2));
    var y = grid_field.bottom() + 1;
    if (y + h > screen_h - 2) y = @max(2, grid_field.y - h - 1);
    grid_rect = Rect.xywh(x, y, w, h);

    const px = raw.ix();
    const py = raw.iy();
    const moved = raw.dx != 0 or raw.dy != 0 or raw.pressed or raw.released;
    var hit: ?usize = null;
    for (0..grid_n) |i| {
        if (gridCell(i).contains(px, py)) hit = i;
    }
    if (moved and hit != null) grid_sel = hit;
    const dragged = @abs(raw.mx - open_mx) + @abs(raw.my - open_my) > DRAG_PICK;
    if (raw.released and hit != null and (armed or dragged)) {
        close();
        return hit;
    }
    if (!armed and !raw.down) armed = true;

    const n: i32 = @intCast(grid_n);
    const r: i32 = rows;
    var s: i32 = @intCast(grid_sel orelse grid_cur);
    if (raw.keyPressed(c.rl.KEY_ESCAPE)) {
        close();
        return null;
    }
    if (raw.keyPressed(c.rl.KEY_DOWN)) s = @min(n - 1, s + 1);
    if (raw.keyPressed(c.rl.KEY_UP)) s = @max(0, s - 1);
    if (raw.keyPressed(c.rl.KEY_RIGHT) and s + r < n) s += r;
    if (raw.keyPressed(c.rl.KEY_LEFT) and s - r >= 0) s -= r;
    grid_sel = @intCast(s);
    if (raw.keyPressed(c.rl.KEY_ENTER) or raw.keyPressed(c.rl.KEY_KP_ENTER)) {
        close();
        return @intCast(s);
    }

    if (just_opened) {
        just_opened = false;
    } else if ((raw.pressed or raw.right_pressed) and !grid_rect.contains(px, py)) {
        close();
    }
    return null;
}

fn drawGrid(ui: *Ui) void {
    if (grid_n == 0) return;
    // Floating hardware: a hard edge, then the glass.
    _ = ui.plate(grid_rect, .{ .outline = .all });
    const glass = ui.well(grid_rect.inset(1), style.well);
    ui.clip(glass);
    for (0..grid_n) |i| {
        const cell = gridCell(i);
        const label = grid_labels[i][0..grid_lens[i]];
        const lit = grid_sel == i;
        const cur = grid_cur == i;
        if (lit) ui.rect(cell.insetXY(0, 1), style.vfd.alpha(40));
        const col = if (lit or cur) style.vfd else style.vfd.mix(style.well, 0.45);
        // The current value carries a lit marker cell.
        if (cur) ui.rect(Rect.xywh(cell.x + 2, cell.y + 5, 2, 4), style.vfd);
        controls.vfdText(ui, cell.x + controls.CELL_W, cell.y + 1, label, col);
    }
    controls.dotMesh(ui, glass, glass.y, glass.h, 1);
    ui.unclip();
}

// ── Tooltips ─────────────────────────────────────────────────────────

const TIP_DELAY: f64 = 0.45;
const TIP_MAX = 160;

/// When the pointer last moved (or a button/wheel was used).
var tip_rest: f64 = 0;
/// A press hides tips until the pointer moves again.
var tip_blocked: bool = false;
var tip_buf: [TIP_MAX]u8 = undefined;
var tip_len: usize = 0;
var tip_x: i32 = 0;
var tip_y: i32 = 0;

fn tipBeginFrame() void {
    const moved = raw.dx != 0 or raw.dy != 0;
    if (moved or raw.pressed or raw.right_pressed or raw.wheel_x != 0 or raw.wheel_y != 0) tip_rest = raw.time;
    if (raw.pressed or raw.right_pressed) tip_blocked = true else if (moved) tip_blocked = false;
    tip_len = 0;
}

/// Tooltip for `r`: shown once the pointer has rested over it for a
/// moment. Uses the Ui's (possibly suppressed) pointer, so modals, menus
/// and drags hide it. The text is copied.
pub fn tip(ui: *Ui, r: Rect, text: []const u8) void {
    const in = &ui.in;
    if (in.down or tip_blocked or key != 0) return;
    if (r.empty() or !r.contains(in.ix(), in.iy())) return;
    if (in.time - tip_rest < TIP_DELAY) {
        ui.animate(); // wake up when the delay has passed
        return;
    }
    tip_len = @min(text.len, TIP_MAX);
    @memcpy(tip_buf[0..tip_len], text[0..tip_len]);
    tip_x = in.ix();
    tip_y = in.iy();
}

fn drawTip(ui: *Ui) void {
    if (tip_len == 0) return;
    const s = tip_buf[0..tip_len];
    const f = &ui.fonts.legend;
    const w = f.measure(s) + 10;
    const h: i32 = 16;
    var x = tip_x + 12;
    var y = tip_y + 16;
    if (x + w > screen_w - 2) x = screen_w - w - 2;
    if (y + h > screen_h - 2) y = tip_y - h - 6;
    const r = Rect.xywh(@max(2, x), @max(2, y), w, h);
    ui.rect(r, style.edge);
    ui.rect(r.inset(1), style.face_hi);
    ui.textIn(f, r.insetXY(5, 0), s, style.text, .left, false);
}
