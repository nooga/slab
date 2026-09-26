//! Glue between the new Ui and the legacy widgets while panes migrate
//! (docs/06 §Migration). Deleted once menus and tooltips move onto the
//! new core. The app runs the Ui at zoom 1, so logical px == points.

const c = @import("../c.zig");
const geom = @import("geom.zig");
const widgets = @import("widgets.zig");

pub const Rect = geom.Rect;

pub fn toRl(r: Rect) c.rl.Rectangle {
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .width = @floatFromInt(r.w), .height = @floatFromInt(r.h) };
}

pub fn fromRl(r: c.rl.Rectangle) Rect {
    return Rect.xywh(@intFromFloat(@round(r.x)), @intFromFloat(@round(r.y)), @intFromFloat(@round(r.width)), @intFromFloat(@round(r.height)));
}

/// Legacy deferred tooltip over a new-core rect.
pub fn tip(r: Rect, text: [*:0]const u8, m: widgets.Mouse) void {
    if (r.empty()) return;
    widgets.tooltip(toRl(r), text, m);
}

/// Open a legacy menu anchored under a new-core rect.
pub fn openMenuBelow(key: u64, r: Rect) void {
    widgets.openMenuAt(key, @floatFromInt(r.x), @floatFromInt(r.bottom()));
}
