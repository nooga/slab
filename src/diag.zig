//! Logs and crash reports for end users (docs/46). See native_diag.c.

const std = @import("std");
const storage = @import("storage.zig");

extern fn slab_diag_start(dir: [*:0]const u8, version: [*:0]const u8) c_int;

/// ~/Library/Logs/Slab ($SLAB_LOGS overrides it).
pub fn dir(buf: []u8) []const u8 {
    if (std.c.getenv("SLAB_LOGS")) |e| return std.fmt.bufPrint(buf, "{s}", .{std.mem.span(e)}) catch "";
    const h = if (std.c.getenv("HOME")) |e| std.mem.span(e) else "";
    return std.fmt.bufPrint(buf, "{s}/Library/Logs/Slab", .{h}) catch "";
}

/// Start the log and the crash handler. Call first thing.
pub fn start(version: []const u8) void {
    var db: [storage.MAX_PATH]u8 = undefined;
    var zd: [storage.MAX_PATH + 1]u8 = undefined;
    var vb: [64]u8 = undefined;
    const d = std.mem.printSentinel(&zd, "{s}", .{dir(&db)}, 0) catch return;
    const v = std.mem.printSentinel(&vb, "{s}", .{version}, 0) catch return;
    _ = slab_diag_start(d.ptr, v.ptr);
}
