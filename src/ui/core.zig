//! The `Ui` context (docs/06 §The `Ui` core): one input snapshot per
//! frame, explicit widget ids, hot/active/focus, the draw lists, and the
//! drawing helpers every control shares (text, plates, wells, bevels).
//! Widgets read `ui.in`, never raylib.

const std = @import("std");
const c = @import("../c.zig");
const geom = @import("geom.zig");
const style = @import("style.zig");
const atlas_mod = @import("atlas.zig");
const font_mod = @import("font.zig");
const sprites = @import("sprites.zig");
const draw = @import("draw.zig");
const tamzen = @import("tamzen");

pub const Rect = geom.Rect;
pub const Color = style.Color;
pub const Font = font_mod.Font;
pub const Id = u64;

// ── Input ────────────────────────────────────────────────────────────

pub const MAX_KEYS = 16;

pub const Input = struct {
    /// Pointer in logical pixels (float for sub-pixel drag deltas).
    mx: f32 = 0,
    my: f32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    down: bool = false,
    pressed: bool = false,
    released: bool = false,
    right_pressed: bool = false,
    double: bool = false,
    wheel_x: f32 = 0,
    wheel_y: f32 = 0,
    shift: bool = false,
    cmd: bool = false,
    alt: bool = false,
    keys: [MAX_KEYS]c_int = undefined,
    nkeys: usize = 0,
    time: f64 = 0,
    /// Seconds since the previous frame (clamped; 0 on the first).
    dt: f32 = 0,

    pub fn ix(in: *const Input) i32 {
        return @intFromFloat(@floor(in.mx));
    }

    pub fn iy(in: *const Input) i32 {
        return @intFromFloat(@floor(in.my));
    }

    pub fn keyPressed(in: *const Input, key: c_int) bool {
        for (in.keys[0..in.nkeys]) |k| if (k == key) return true;
        return false;
    }

    /// True if anything happened that needs a new frame.
    pub fn any(in: *const Input) bool {
        return in.dx != 0 or in.dy != 0 or in.down or in.pressed or in.released or
            in.right_pressed or in.wheel_x != 0 or in.wheel_y != 0 or in.nkeys > 0;
    }
};

const DBL_TIME: f64 = 0.35;
const DBL_DIST: f32 = 4;

// ── Fonts ────────────────────────────────────────────────────────────

pub const Fonts = struct {
    /// Tamzen 8×16 (9px caps ≈ macOS 13pt at 1 logical px per point):
    /// names, menus, body text.
    body: Font,
    body_bold: Font,
    /// Tamzen 6×12, used uppercase: faceplate legends, readouts, units.
    /// Its 5×7 caps double as the display dot-matrix face.
    legend: Font,
    legend_bold: Font,
};

// ── Touch (feeds title-strip displays) ───────────────────────────────

pub const Touch = struct {
    label: [24]u8 = undefined,
    label_len: usize = 0,
    value: [24]u8 = undefined,
    value_len: usize = 0,
    /// Scope id of the panel the touched control belongs to.
    scope: Id = 0,
    time: f64 = -10,

    pub fn labelStr(t: *const Touch) []const u8 {
        return t.label[0..t.label_len];
    }

    pub fn valueStr(t: *const Touch) []const u8 {
        return t.value[0..t.value_len];
    }
};

pub const TOUCH_HOLD: f64 = 1.0;

// ── Ui ───────────────────────────────────────────────────────────────

/// Small per-widget float state (peak hold, afterglow levels).
const Memo = struct { id: Id = 0, v: f32 = 0, used: u64 = 0 };
const MEMO_SLOTS = 512;

/// Afterglow history for scope-like displays: the last few frames.
pub const TRAIL = 4;
pub const TRAIL_PTS = 256;
pub const Trail = struct {
    id: Id = 0,
    used: u64 = 0,
    pts: [TRAIL][TRAIL_PTS]f32 = undefined,
    lens: [TRAIL]usize = [_]usize{0} ** TRAIL,
    head: usize = 0,
};
const TRAIL_SLOTS = 8;

const MAX_CMDS = 1 << 16;
const MAX_OVERLAY = 1 << 12;
const ID_DEPTH = 32;

pub const Ui = struct {
    in: Input = .{},
    fonts: Fonts,
    art: sprites.Art,
    renderer: draw.Renderer,

    dl: draw.DrawList,
    overlay: draw.DrawList,

    hot: Id = 0,
    /// Hot candidate for the next frame (the last widget under the pointer
    /// wins, so later-drawn widgets on top take precedence).
    hot_next: Id = 0,
    /// Priority of `hot_next`: a higher-priority widget (a splitter's grab
    /// zone) stays hot over lower ones drawn later on top of it.
    hot_next_prio: u8 = 0,
    /// Cursor requested this frame (highest priority wins), applied at
    /// the end of the frame.
    cursor: c_int = c.rl.MOUSE_CURSOR_DEFAULT,
    cursor_prio: u8 = 0,
    cursor_set: c_int = c.rl.MOUSE_CURSOR_DEFAULT,
    active: Id = 0,
    focus: Id = 0,

    ids: [ID_DEPTH]Id = undefined,
    id_depth: usize = 0,

    /// Continuous accumulator for the active drag (stepped controls snap
    /// from it so small drags still add up).
    drag_acc: f32 = 0,
    edit_began: bool = false,
    edit_ended: bool = false,

    touch: Touch = .{},
    wants_frame: bool = true,
    frame: u64 = 0,
    white: atlas_mod.Region,
    memos: [MEMO_SLOTS]Memo = [_]Memo{.{}} ** MEMO_SLOTS,
    trails: [TRAIL_SLOTS]Trail = [_]Trail{.{}} ** TRAIL_SLOTS,

    last_click_t: f64 = -1,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,
    prev_mx: f32 = 0,
    prev_my: f32 = 0,
    prev_time: f64 = -1,

    cmd_buf: []draw.Cmd,
    overlay_buf: []draw.Cmd,

    pub fn init(alloc: std.mem.Allocator) !*Ui {
        var atlas = try atlas_mod.Atlas.init(alloc);
        defer atlas.deinit(alloc);
        const fonts = Fonts{
            .body = try font_mod.loadBdf(&atlas, tamzen.r8x16),
            .body_bold = try font_mod.loadBdf(&atlas, tamzen.b8x16),
            .legend = try font_mod.loadBdf(&atlas, tamzen.r6x12),
            .legend_bold = try font_mod.loadBdf(&atlas, tamzen.b6x12),
        };
        const art = try sprites.build(&atlas, &fonts.legend);

        const ui = try alloc.create(Ui);
        errdefer alloc.destroy(ui);
        const cmd_buf = try alloc.alloc(draw.Cmd, MAX_CMDS);
        errdefer alloc.free(cmd_buf);
        const overlay_buf = try alloc.alloc(draw.Cmd, MAX_OVERLAY);
        ui.* = .{
            .fonts = fonts,
            .art = art,
            .renderer = draw.Renderer.init(&atlas),
            .white = atlas.white,
            .dl = .{ .cmds = cmd_buf },
            .overlay = .{ .cmds = overlay_buf },
            .cmd_buf = cmd_buf,
            .overlay_buf = overlay_buf,
        };
        return ui;
    }

    pub fn deinit(ui: *Ui, alloc: std.mem.Allocator) void {
        ui.renderer.deinit();
        alloc.free(ui.cmd_buf);
        alloc.free(ui.overlay_buf);
        alloc.destroy(ui);
    }

    // ── Frame ────────────────────────────────────────────────────────

    pub fn beginFrame(ui: *Ui) void {
        const z = ui.renderer.zoom;
        const mp = c.rl.GetMousePosition();
        var in = Input{
            .mx = mp.x / z,
            .my = mp.y / z,
            .down = c.rl.IsMouseButtonDown(c.rl.MOUSE_BUTTON_LEFT),
            .pressed = c.rl.IsMouseButtonPressed(c.rl.MOUSE_BUTTON_LEFT),
            .released = c.rl.IsMouseButtonReleased(c.rl.MOUSE_BUTTON_LEFT),
            .right_pressed = c.rl.IsMouseButtonPressed(c.rl.MOUSE_BUTTON_RIGHT),
            .shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT),
            .cmd = c.rl.IsKeyDown(c.rl.KEY_LEFT_SUPER) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SUPER),
            .alt = c.rl.IsKeyDown(c.rl.KEY_LEFT_ALT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_ALT),
            .time = c.rl.GetTime(),
        };
        const wv = c.rl.GetMouseWheelMoveV();
        in.wheel_x = wv.x;
        in.wheel_y = wv.y;
        in.dt = if (ui.prev_time < 0) 0 else @floatCast(@min(0.1, in.time - ui.prev_time));
        ui.prev_time = in.time;
        in.dx = in.mx - ui.prev_mx;
        in.dy = in.my - ui.prev_my;
        ui.prev_mx = in.mx;
        ui.prev_my = in.my;
        while (in.nkeys < MAX_KEYS) {
            const k = c.rl.GetKeyPressed();
            if (k == 0) break;
            in.keys[in.nkeys] = k;
            in.nkeys += 1;
        }
        if (in.pressed) {
            if (in.time - ui.last_click_t < DBL_TIME and
                @abs(in.mx - ui.last_click_x) < DBL_DIST and @abs(in.my - ui.last_click_y) < DBL_DIST)
            {
                in.double = true;
                ui.last_click_t = -1; // no triple-click chaining
            } else {
                ui.last_click_t = in.time;
            }
            ui.last_click_x = in.mx;
            ui.last_click_y = in.my;
        }
        ui.in = in;

        ui.frame += 1;
        ui.hot = ui.hot_next;
        ui.hot_next = 0;
        ui.hot_next_prio = 0;
        ui.cursor = c.rl.MOUSE_CURSOR_DEFAULT;
        ui.cursor_prio = 0;
        ui.edit_began = false;
        ui.edit_ended = false;
        ui.wants_frame = in.any() or ui.active != 0;
        ui.id_depth = 0;
        ui.dl.reset();
        ui.overlay.reset();
        if (in.pressed and ui.hot == 0) ui.focus = 0;
    }

    pub fn endFrame(ui: *Ui) void {
        std.debug.assert(ui.id_depth == 0); // unbalanced pushId/popId
        if (ui.in.released and ui.active != 0) {
            // A drag whose widget vanished mid-drag still ends cleanly.
            ui.active = 0;
            ui.edit_ended = true;
        }
        if (ui.in.time - ui.touch.time < TOUCH_HOLD + 0.1) ui.wants_frame = true;
        if (ui.cursor != ui.cursor_set) {
            c.rl.SetMouseCursor(ui.cursor);
            ui.cursor_set = ui.cursor;
        }
        c.rl.BeginDrawing();
        c.rl.ClearBackground(@bitCast(style.chassis));
        ui.renderer.flush(&.{ &ui.dl, &ui.overlay });
        c.rl.EndDrawing();
    }

    /// Ask for another frame (animations, afterglow, blinking).
    pub fn animate(ui: *Ui) void {
        ui.wants_frame = true;
    }

    pub fn deviceScale(ui: *const Ui) f32 {
        return ui.renderer.deviceScale();
    }

    /// Persistent float for widget `wid` (created at `init` on first use).
    /// Bounded: the least recently used slot is recycled.
    pub fn memo(ui: *Ui, wid: Id, init_v: f32) *f32 {
        var lru: usize = 0;
        for (&ui.memos, 0..) |*m, i| {
            if (m.id == wid) {
                m.used = ui.frame;
                return &m.v;
            }
            if (m.used < ui.memos[lru].used) lru = i;
        }
        ui.memos[lru] = .{ .id = wid, .v = init_v, .used = ui.frame };
        return &ui.memos[lru].v;
    }

    pub fn trail(ui: *Ui, wid: Id) *Trail {
        var lru: usize = 0;
        for (&ui.trails, 0..) |*t, i| {
            if (t.id == wid) {
                t.used = ui.frame;
                return t;
            }
            if (t.used < ui.trails[lru].used) lru = i;
        }
        ui.trails[lru] = .{ .id = wid, .used = ui.frame };
        return &ui.trails[lru];
    }

    // ── Ids ──────────────────────────────────────────────────────────

    pub fn pushId(ui: *Ui, key: anytype) void {
        const scoped = ui.id(key);
        if (ui.id_depth < ID_DEPTH) {
            ui.ids[ui.id_depth] = scoped;
            ui.id_depth += 1;
        }
    }

    pub fn popId(ui: *Ui) void {
        if (ui.id_depth > 0) ui.id_depth -= 1;
    }

    pub fn scopeId(ui: *const Ui) Id {
        return if (ui.id_depth > 0) ui.ids[ui.id_depth - 1] else 0x5_1AB;
    }

    /// Id of `key` within the current scope. Keys are values that identify
    /// the thing being edited (param index, pointer, name), never a rect.
    pub fn id(ui: *const Ui, key: anytype) Id {
        var h = std.hash.Wyhash.init(ui.scopeId());
        hashKey(&h, key);
        const v = h.final();
        return if (v == 0) 1 else v;
    }

    // ── Behaviour ────────────────────────────────────────────────────

    pub const Behavior = struct {
        hover: bool = false,
        pressed: bool = false,
        held: bool = false,
        released: bool = false,
        clicked: bool = false,
        double: bool = false,
    };

    /// Standard pointer behaviour for a widget occupying `r`.
    pub fn behavior(ui: *Ui, wid: Id, r: Rect, disabled: bool) Behavior {
        return ui.behaviorPrio(wid, r, disabled, 0);
    }

    /// `behavior` with a hover priority (see `hot_next_prio`).
    pub fn behaviorPrio(ui: *Ui, wid: Id, r: Rect, disabled: bool, prio: u8) Behavior {
        var b = Behavior{};
        const over = r.contains(ui.in.ix(), ui.in.iy());
        if (disabled) return b;
        if (over and (ui.active == 0 or ui.active == wid) and prio >= ui.hot_next_prio) {
            ui.hot_next = wid;
            ui.hot_next_prio = prio;
        }
        b.hover = ui.hot == wid and over;
        if (ui.active == wid) {
            b.held = true;
            if (!ui.in.down) {
                b.released = true;
                b.clicked = over;
                ui.active = 0;
                ui.edit_ended = true;
                b.held = false;
            }
        } else if (b.hover and ui.in.pressed and ui.active == 0) {
            ui.active = wid;
            ui.focus = wid;
            ui.drag_acc = 0;
            ui.edit_began = true;
            b.pressed = true;
            b.held = true;
            b.double = ui.in.double;
        }
        return b;
    }

    /// Request a pointer cursor for this frame; the highest priority wins.
    pub fn requestCursor(ui: *Ui, cursor: c_int, prio: u8) void {
        if (prio >= ui.cursor_prio) {
            ui.cursor = cursor;
            ui.cursor_prio = prio;
        }
    }

    pub fn isHot(ui: *const Ui, wid: Id) bool {
        return ui.hot == wid or ui.active == wid;
    }

    /// Report the touched control so title displays can show it.
    pub fn setTouch(ui: *Ui, label: []const u8, value: []const u8) void {
        const t = &ui.touch;
        t.label_len = @min(label.len, t.label.len);
        @memcpy(t.label[0..t.label_len], label[0..t.label_len]);
        t.value_len = @min(value.len, t.value.len);
        @memcpy(t.value[0..t.value_len], value[0..t.value_len]);
        t.scope = ui.scopeId();
        t.time = ui.in.time;
    }

    // ── Primitive emitters ───────────────────────────────────────────

    pub fn rect(ui: *Ui, r: Rect, col: Color) void {
        if (r.empty() or col.a == 0) return;
        ui.dl.push(.{ .rect = .{ .r = r, .c = col } });
    }

    /// Fractional-logical rect (device-pixel detail such as display dot
    /// gaps). Everything else uses whole-pixel `rect`.
    pub fn frect(ui: *Ui, x: f32, y: f32, w: f32, h: f32, col: Color) void {
        ui.dl.push(.{ .sprite = .{ .src = ui.white, .x = x, .y = y, .w = w, .h = h, .tint = col } });
    }

    pub fn px(ui: *Ui, x: i32, y: i32, col: Color) void {
        ui.dl.push(.{ .rect = .{ .r = Rect.xywh(x, y, 1, 1), .c = col } });
    }

    pub fn vgrad(ui: *Ui, r: Rect, top: Color, bot: Color) void {
        if (r.empty()) return;
        ui.dl.push(.{ .vgrad = .{ .r = r, .top = top, .bot = bot } });
    }

    pub fn sprite(ui: *Ui, src: atlas_mod.Region, x: i32, y: i32, tint: Color) void {
        ui.dl.push(.{ .sprite = .{
            .src = src,
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(src.w),
            .h = @floatFromInt(src.h),
            .tint = tint,
        } });
    }

    /// Sprite pixel-multiplied by an integer factor (large displays).
    pub fn spriteScaled(ui: *Ui, src: atlas_mod.Region, x: i32, y: i32, k: i32, tint: Color) void {
        ui.dl.push(.{ .sprite = .{
            .src = src,
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(@as(i32, src.w) * k),
            .h = @floatFromInt(@as(i32, src.h) * k),
            .tint = tint,
        } });
    }

    pub fn line(ui: *Ui, x0: f32, y0: f32, x1: f32, y1: f32, col: Color) void {
        ui.dl.push(.{ .line = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .c = col } });
    }

    /// A rect on the overlay list (drawn after everything else).
    pub fn overlayRect(ui: *Ui, r: Rect, col: Color) void {
        if (r.empty()) return;
        ui.overlay.push(.{ .rect = .{ .r = r, .c = col } });
    }

    pub fn clip(ui: *Ui, r: Rect) void {
        ui.dl.push(.{ .clip_push = r });
    }

    pub fn unclip(ui: *Ui) void {
        ui.dl.push(.clip_pop);
    }

    // ── Text ─────────────────────────────────────────────────────────

    /// Draw `s` with its line box's top-left at (x, y). Returns the advance.
    pub fn text(ui: *Ui, f: *const Font, x: i32, y: i32, s: []const u8, col: Color) i32 {
        var pen = x;
        var it = font_mod.Utf8Iter{ .s = s };
        while (it.next()) |cp| {
            const g = f.glyph(cp);
            if (g.src.w > 0) ui.sprite(g.src, pen + g.dx, y + g.dy, col);
            pen += g.advance;
        }
        return pen - x;
    }

    /// Faceplate legend: text printed into the plate (1px dark offset).
    pub fn engraved(ui: *Ui, f: *const Font, x: i32, y: i32, s: []const u8, col: Color) i32 {
        if (style.materials.engrave) _ = ui.text(f, x, y + 1, s, style.engrave);
        return ui.text(f, x, y, s, col);
    }

    pub const Align = enum { left, center, right };

    /// Text vertically centred in `r` on the font's cap band, aligned.
    pub fn textIn(ui: *Ui, f: *const Font, r: Rect, s: []const u8, col: Color, al: Align, engrave: bool) void {
        const w = f.measure(s);
        const x = switch (al) {
            .left => r.x,
            .center => r.x + @divFloor(r.w - w, 2),
            .right => r.right() - w,
        };
        const y = r.y + @divFloor(r.h - f.lineHeight(), 2);
        _ = if (engrave) ui.engraved(f, x, y, s, col) else ui.text(f, x, y, s, col);
    }

    // ── Surfaces (docs/06 §Materials) ────────────────────────────────

    /// 1px bevel lines on the edge of r.
    pub fn bevel(ui: *Ui, r: Rect, hi: Color, lo: Color) void {
        ui.rect(Rect.xywh(r.x, r.y, r.w, 1), hi);
        ui.rect(Rect.xywh(r.x, r.y + 1, 1, r.h - 1), hi);
        ui.rect(Rect.xywh(r.x + 1, r.bottom() - 1, r.w - 1, 1), lo);
        ui.rect(Rect.xywh(r.right() - 1, r.y + 1, 1, r.h - 2), lo);
    }

    pub fn noise(ui: *Ui, r: Rect) void {
        const m = style.materials;
        if (m.noise == 0) return;
        ui.dl.push(.{ .tile = .{ .src = ui.art.noise, .r = r, .tint = .{ .r = 255, .g = 255, .b = 255, .a = sprites.noiseTint(m.noise) } } });
    }

    pub fn chassis(ui: *Ui, r: Rect) void {
        ui.rect(r, style.chassis);
        ui.noise(r);
    }

    pub const Outline = enum {
        /// No edge (a thumb or cap inside another control).
        none,
        /// Edge on all four sides (a free-standing object).
        all,
        /// Edge on the right and bottom only. Plates that tile a region
        /// with no gaps then share exactly one 1px seam between them.
        seam,
    };

    pub const PlateOpts = struct {
        fill: Color = style.face,
        chamfer: u8 = 0,
        outline: Outline = .seam,
    };

    /// Raised faceplate: gradient, noise, bevel, optional chamfer.
    /// Returns the inner rect (inside bevel).
    pub fn plate(ui: *Ui, r: Rect, o: PlateOpts) Rect {
        const m = style.materials;
        const g: i32 = m.gradient;
        const top = o.fill.shade(@divFloor(g, 2));
        const bot = o.fill.shade(-@divFloor(g + 1, 2));
        var body = r;
        switch (o.outline) {
            .none => {},
            .all => {
                ui.rect(r, style.edge);
                body = r.inset(1);
            },
            .seam => {
                ui.rect(Rect.xywh(r.right() - 1, r.y, 1, r.h), style.edge);
                ui.rect(Rect.xywh(r.x, r.bottom() - 1, r.w - 1, 1), style.edge);
                body = Rect.xywh(r.x, r.y, r.w - 1, r.h - 1);
            },
        }
        ui.vgrad(body, top, bot);
        ui.noise(body);
        ui.bevel(body, style.face_hi, style.face_lo);
        if (o.chamfer > 0) ui.chamferCorners(r, o.chamfer, o.outline != .none);
        return body.inset(1);
    }

    /// Cut 45° corners into a plate, pixel-exact: the cut is filled with
    /// chassis, the new diagonal edge takes the outline, and the bevel
    /// continues along it (lit on the top-left cut, shadowed elsewhere).
    fn chamferCorners(ui: *Ui, r: Rect, n: u8, outline: bool) void {
        const k: i32 = n;
        var i: i32 = 0;
        while (i < k) : (i += 1) {
            const run = k - i; // pixels to cut on this row
            // top-left, top-right, bottom-left, bottom-right
            ui.rect(Rect.xywh(r.x, r.y + i, run, 1), style.chassis);
            ui.rect(Rect.xywh(r.right() - run, r.y + i, run, 1), style.chassis);
            ui.rect(Rect.xywh(r.x, r.bottom() - 1 - i, run, 1), style.chassis);
            ui.rect(Rect.xywh(r.right() - run, r.bottom() - 1 - i, run, 1), style.chassis);
        }
        i = 0;
        while (i <= k) : (i += 1) {
            const e = if (outline) style.edge else style.face_lo;
            // Diagonal outline pixels.
            ui.px(r.x + k - i, r.y + i, e);
            ui.px(r.right() - 1 - k + i, r.y + i, e);
            ui.px(r.x + k - i, r.bottom() - 1 - i, e);
            ui.px(r.right() - 1 - k + i, r.bottom() - 1 - i, e);
            if (outline and i > 0 and i < k) {
                // Bevel follows the diagonal one pixel inside.
                ui.px(r.x + k - i + 1, r.y + i, style.face_hi);
                ui.px(r.right() - 2 - k + i, r.y + i, style.face_hi.mix(style.face_lo, 0.5));
                ui.px(r.x + k - i + 1, r.bottom() - 1 - i, style.face_hi.mix(style.face_lo, 0.5));
                ui.px(r.right() - 2 - k + i, r.bottom() - 1 - i, style.face_lo);
            }
        }
    }

    /// Sunken well: displays, fields, slots. Flat, near-black.
    pub fn well(ui: *Ui, r: Rect, fill: Color) Rect {
        ui.rect(r, fill);
        ui.bevel(r, style.edge, style.well_hi);
        return r.inset(1);
    }

    /// A working surface (arrangement, piano roll): flat, no material.
    pub fn surface(ui: *Ui, r: Rect, fill: Color) void {
        ui.rect(r, fill);
    }
};

fn hashKey(h: *std.hash.Wyhash, key: anytype) void {
    const T = @TypeOf(key);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice) {
                h.update(std.mem.sliceAsBytes(key));
            } else if (p.size == .one and @typeInfo(p.child) == .array) {
                h.update(std.mem.sliceAsBytes(key[0..]));
            } else {
                const a: usize = @intFromPtr(key);
                h.update(std.mem.asBytes(&a));
            }
        },
        .comptime_int => {
            const v: i64 = key;
            h.update(std.mem.asBytes(&v));
        },
        .int, .bool => h.update(std.mem.asBytes(&key)),
        .@"enum" => {
            const v: u64 = @intFromEnum(key);
            h.update(std.mem.asBytes(&v));
        },
        .@"struct" => |s| inline for (s.fields) |f| hashKey(h, @field(key, f.name)),
        else => @compileError("unsupported id key type " ++ @typeName(T)),
    }
}

test "ids are scoped and key-derived" {
    var h1 = std.hash.Wyhash.init(1);
    hashKey(&h1, @as(u32, 7));
    var h2 = std.hash.Wyhash.init(2);
    hashKey(&h2, @as(u32, 7));
    try std.testing.expect(h1.final() != h2.final());
    var h3 = std.hash.Wyhash.init(1);
    hashKey(&h3, .{ "cutoff", @as(u8, 3) });
    var h4 = std.hash.Wyhash.init(1);
    hashKey(&h4, .{ "cutoff", @as(u8, 4) });
    try std.testing.expect(h3.final() != h4.final());
}
