//! Workbench tiling (docs/06 §Packing, §Splitters): panes tile the window
//! edge to edge in logical pixels; the seams between them are the new Ui's
//! splitters.
//!
//!   ┌──────────── transport bar ────────────┐
//!   │ arrangement                           │
//!   ├──────────────────────────────── seam ─┤  clip_top  (if visible)
//!   │ clip editor*                          │
//!   ├──────────────────────────────── seam ─┤  bay_top
//!   │ machine bay*                          │
//!   └───────────────────────────────────────┘
//!
//! `compute` is pure (callers recompute after state changes mid-frame);
//! `splitters` runs the seam interactions once per frame and draws the
//! seam lines. Both use the same arithmetic, so seams land where the
//! splitters put them. Rects are handed to the legacy panes as f32.

const c = @import("../c.zig");
const pane = @import("pane_input.zig");
const transport_bar = @import("transport_bar.zig");
const ui_core = @import("core.zig");
const ui_style = @import("style.zig");
const ctl = @import("controls.zig");
const machine_bay = @import("machine_bay.zig");

const Rect = ui_core.Rect;

pub const Rects = struct {
    top_bar: c.rl.Rectangle,
    status_bar: c.rl.Rectangle,
    browser: c.rl.Rectangle,
    arrangement: c.rl.Rectangle,
    clip_editor: c.rl.Rectangle,
    machine_bay: c.rl.Rectangle,

    pub fn zeroRect() c.rl.Rectangle {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
};

const MIN_ARRANGE: i32 = 120;
const MIN_CLIP: i32 = 96;
const MIN_BAY: i32 = 140;

pub const State = struct {
    /// Machine bay height (logical px) when expanded.
    bay_h: i32 = 300,
    /// Clip editor height when visible.
    clip_h: i32 = 240,

    machine_bay_collapsed: bool = false,
    clip_editor_visible: bool = false,
    /// The mixer page takes the arrangement's place (docs/23).
    mixer_visible: bool = false,

    /// The clip editor has a pane: on, and not covered by the mixer.
    pub fn clipShown(self: *const State) bool {
        return self.clip_editor_visible and !self.mixer_visible;
    }

    fn effBayH(self: *const State) i32 {
        return if (self.machine_bay_collapsed) machine_bay.TITLE_H else self.bay_h;
    }

    const Split = struct { top: Rect, main: Rect, arr: Rect, clip: Rect, bay: Rect };

    fn split(self: *const State, sw: i32, sh: i32) Split {
        var screen = Rect.xywh(0, 0, sw, sh);
        const top = screen.cutTop(transport_bar.HEIGHT);
        const main = screen;
        var rest = screen;
        const bay = rest.cutBottom(@min(self.effBayH(), @max(0, rest.h - MIN_ARRANGE)));
        // The mixer page takes the clip editor's room as well.
        const clip = if (self.clipShown()) rest.cutBottom(@min(self.clip_h, @max(0, rest.h - MIN_ARRANGE))) else Rect{};
        return .{ .top = top, .main = main, .arr = rest, .clip = clip, .bay = bay };
    }

    pub fn compute(self: *const State, sw_f: f32, sh_f: f32) Rects {
        const s = self.split(@intFromFloat(sw_f), @intFromFloat(sh_f));
        return .{
            .top_bar = rl(s.top),
            .status_bar = Rects.zeroRect(),
            .browser = Rects.zeroRect(),
            .arrangement = rl(s.arr),
            .clip_editor = rl(s.clip),
            .machine_bay = rl(s.bay),
        };
    }

    /// Seam interactions (drag, double-click fold) and the seam lines. Call
    /// once per frame, before `compute` is used for the panes.
    pub fn splitters(self: *State, ui: *ui_core.Ui, sw_f: f32, sh_f: f32) void {
        const s = self.split(@intFromFloat(sw_f), @intFromFloat(sh_f));
        // Bay seam: its top edge. Double-click folds it to its title strip.
        if (!self.machine_bay_collapsed) {
            _ = ctl.split(ui, s.main, "bay", &self.bay_h, .{
                .from_end = true,
                .min = MIN_BAY,
                .min_other = MIN_ARRANGE + (if (self.clipShown()) self.clip_h else 0),
                .collapsed = 0,
            });
        }
        // Clip editor seam, measured inside the region above the bay.
        if (self.clipShown()) {
            const above_bay = Rect.xywh(s.main.x, s.main.y, s.main.w, s.main.h - s.bay.h);
            _ = ctl.split(ui, above_bay, "clip", &self.clip_h, .{ .from_end = true, .min = MIN_CLIP, .min_other = MIN_ARRANGE });
        }
        // Legacy panes don't draw their own bottom seams: draw them here,
        // on the Ui list, so every pane boundary is exactly one dark pixel.
        const now = self.split(@intFromFloat(sw_f), @intFromFloat(sh_f));
        seam(ui, now.arr);
        if (self.clipShown()) seam(ui, now.clip);
    }
};

fn seam(ui: *ui_core.Ui, r: Rect) void {
    if (r.h > 0) ui.rect(Rect.xywh(r.x, r.bottom() - 1, r.w, 1), ui_style.edge);
}

fn rl(r: Rect) c.rl.Rectangle {
    return pane.rect(@floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
}
