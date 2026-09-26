//! Rect conversion between the new Ui and the legacy panes' raylib rects
//! while their interaction code migrates (docs/06 §Migration). The app runs
//! the Ui at zoom 1, so logical px == points.

const c = @import("../c.zig");
const geom = @import("geom.zig");

pub const Rect = geom.Rect;

pub fn toRl(r: Rect) c.rl.Rectangle {
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .width = @floatFromInt(r.w), .height = @floatFromInt(r.h) };
}

pub fn fromRl(r: c.rl.Rectangle) Rect {
    return Rect.xywh(@intFromFloat(@round(r.x)), @intFromFloat(@round(r.y)), @intFromFloat(@round(r.width)), @intFromFloat(@round(r.height)));
}
