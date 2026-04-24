//! Workbench tiling layout with collapsible panes.
//!
//!   ┌─────────── top bar ──────────┐
//!   │browser│   arrangement lanes  │
//!   │       ├──────────────────────┤  ← splitter: machine_top
//!   │       │    clip editor*      │  * collapsible
//!   │       ├──────────────────────┤  ← splitter: clip_top (if visible)
//!   │       │    machine bay*      │
//!   ├─────────── status bar ───────┤
//!
//! Browser, clip editor, and machine bay are all collapsible. When a
//! pane is collapsed the splitter between it and its neighbor is
//! frozen, and the pane itself shrinks to a thin strip with an
//! expand button.

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

pub const Rects = struct {
    top_bar: c.rl.Rectangle,
    status_bar: c.rl.Rectangle,
    browser: c.rl.Rectangle,
    arrangement: c.rl.Rectangle,
    clip_editor: c.rl.Rectangle,
    machine_bay: c.rl.Rectangle,

    split_browser: c.rl.Rectangle,
    split_machine_top: c.rl.Rectangle,
    split_clip_top: c.rl.Rectangle,

    hit_browser: c.rl.Rectangle,
    hit_machine_top: c.rl.Rectangle,
    hit_clip_top: c.rl.Rectangle,

    pub fn zeroRect() c.rl.Rectangle {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
};

pub const Drag = enum { none, browser, machine_top, clip_top };

pub const State = struct {
    browser_w: f32 = 200,
    machine_bay_h: f32 = 160,
    clip_editor_h: f32 = 160,

    browser_collapsed: bool = false,
    machine_bay_collapsed: bool = false,
    clip_editor_visible: bool = false,

    drag: Drag = .none,

    pub fn effBrowserW(self: *const State) f32 {
        return if (self.browser_collapsed) theme.collapsedW() else theme.size(self.browser_w);
    }

    pub fn effMachineBayH(self: *const State) f32 {
        return if (self.machine_bay_collapsed) theme.collapsedH() else theme.size(self.machine_bay_h);
    }

    pub fn effClipEditorH(self: *const State) f32 {
        return theme.size(self.clip_editor_h);
    }

    pub fn compute(self: *const State, sw: f32, sh: f32) Rects {
        const sp = theme.splitterW();
        const pad = theme.splitterHitPad();

        const top = widgets.rect(0, 0, sw, theme.topBarH());
        const status = widgets.rect(0, sh - theme.statusBarH(), sw, theme.statusBarH());

        const main_y = theme.topBarH();
        const main_h = sh - theme.topBarH() - theme.statusBarH();

        const bw = self.effBrowserW();
        const browser = widgets.rect(0, main_y, bw, main_h);
        const center_x = bw + sp;
        const center_w = sw - bw - sp;

        const split_browser = widgets.rect(bw, main_y, sp, main_h);
        const hit_browser = widgets.rect(bw - pad, main_y, sp + pad * 2, main_h);

        const bay_h = self.effMachineBayH();
        const clip_h: f32 = if (self.clip_editor_visible) self.effClipEditorH() else 0;
        const clip_sp: f32 = if (self.clip_editor_visible) sp else 0;

        const arr_h = main_h - bay_h - sp - clip_h - clip_sp;
        const arr = widgets.rect(center_x, main_y, center_w, arr_h);

        var cursor_y = main_y + arr_h;
        var clip_split = Rects.zeroRect();
        var hit_clip = Rects.zeroRect();
        var clip_rect = Rects.zeroRect();
        if (self.clip_editor_visible) {
            clip_split = widgets.rect(center_x, cursor_y, center_w, sp);
            hit_clip = widgets.rect(center_x, cursor_y - pad, center_w, sp + pad * 2);
            cursor_y += sp;
            clip_rect = widgets.rect(center_x, cursor_y, center_w, clip_h);
            cursor_y += clip_h;
        }
        const machine_split = widgets.rect(center_x, cursor_y, center_w, sp);
        const hit_machine = widgets.rect(center_x, cursor_y - pad, center_w, sp + pad * 2);
        cursor_y += sp;
        const mbay = widgets.rect(center_x, cursor_y, center_w, bay_h);

        return .{
            .top_bar = top,
            .status_bar = status,
            .browser = browser,
            .arrangement = arr,
            .clip_editor = clip_rect,
            .machine_bay = mbay,
            .split_browser = split_browser,
            .split_machine_top = machine_split,
            .split_clip_top = clip_split,
            .hit_browser = hit_browser,
            .hit_machine_top = hit_machine,
            .hit_clip_top = hit_clip,
        };
    }

    pub fn handleInput(self: *State, sw: f32, sh: f32, m: widgets.Mouse) void {
        const rects = self.compute(sw, sh);

        const br_active = !self.browser_collapsed;
        const bay_active = !self.machine_bay_collapsed;

        const over_v = br_active and widgets.contains(rects.hit_browser, m.x, m.y);
        const over_h = (bay_active and widgets.contains(rects.hit_machine_top, m.x, m.y)) or
            (self.clip_editor_visible and widgets.contains(rects.hit_clip_top, m.x, m.y));

        if (self.drag == .browser or over_v) {
            c.rl.SetMouseCursor(c.rl.MOUSE_CURSOR_RESIZE_EW);
        } else if (self.drag == .machine_top or self.drag == .clip_top or over_h) {
            c.rl.SetMouseCursor(c.rl.MOUSE_CURSOR_RESIZE_NS);
        }

        if (self.drag == .none and m.left_pressed) {
            if (br_active and widgets.contains(rects.hit_browser, m.x, m.y)) {
                self.drag = .browser;
            } else if (bay_active and widgets.contains(rects.hit_machine_top, m.x, m.y)) {
                self.drag = .machine_top;
            } else if (self.clip_editor_visible and widgets.contains(rects.hit_clip_top, m.x, m.y)) {
                self.drag = .clip_top;
            }
        }

        if (self.drag != .none) {
            if (!m.left_down) {
                self.drag = .none;
            } else {
                switch (self.drag) {
                    .none => {},
                    .browser => {
                        const max_w = sw - theme.splitterW() - theme.minPane();
                        const clamped = std.math.clamp(m.x, theme.minPane(), max_w);
                        self.browser_w = theme.unscale(clamped);
                    },
                    .machine_top => {
                        const bay_top = m.y;
                        const bay_h = sh - theme.statusBarH() - bay_top;
                        const clip_part: f32 = if (self.clip_editor_visible) self.effClipEditorH() + theme.splitterW() else 0;
                        const max_h = sh - theme.topBarH() - theme.statusBarH() - clip_part - theme.minPane() - theme.splitterW();
                        self.machine_bay_h = theme.unscale(std.math.clamp(bay_h, theme.minPane(), max_h));
                    },
                    .clip_top => {
                        const clip_top_y = m.y;
                        const clip_bot_y = sh - theme.statusBarH() - self.effMachineBayH() - theme.splitterW();
                        const new_h = clip_bot_y - clip_top_y - theme.splitterW();
                        const max_h = sh - theme.topBarH() - theme.statusBarH() - self.effMachineBayH() - theme.splitterW() * 2 - theme.minPane();
                        self.clip_editor_h = theme.unscale(std.math.clamp(new_h, theme.minPane(), max_h));
                    },
                }
            }
        }
    }

    pub fn drawSplitters(self: *const State, rects: Rects, m: widgets.Mouse) void {
        const br_active = !self.browser_collapsed;
        const bay_active = !self.machine_bay_collapsed;
        drawSplitter(rects.split_browser, br_active and (self.drag == .browser or widgets.contains(rects.hit_browser, m.x, m.y)));
        drawSplitter(rects.split_machine_top, bay_active and (self.drag == .machine_top or widgets.contains(rects.hit_machine_top, m.x, m.y)));
        if (self.clip_editor_visible) {
            drawSplitter(rects.split_clip_top, self.drag == .clip_top or widgets.contains(rects.hit_clip_top, m.x, m.y));
        }
    }
};

fn drawSplitter(r: c.rl.Rectangle, hot: bool) void {
    const color = if (hot) theme.splitter_hover else theme.splitter_bg;
    c.rl.DrawRectangleRec(r, color);
}
