//! Byte-snapshot undo/redo stack.

const std = @import("std");

pub const History = struct {
    undo_stack: std.ArrayList([]u8) = .empty,
    redo_stack: std.ArrayList([]u8) = .empty,
    max_depth: usize = 64,

    pub fn deinit(self: *History, alloc: std.mem.Allocator) void {
        self.clearList(alloc, &self.undo_stack);
        self.clearList(alloc, &self.redo_stack);
        self.undo_stack.deinit(alloc);
        self.redo_stack.deinit(alloc);
    }

    pub fn pushUndo(self: *History, alloc: std.mem.Allocator, snapshot: []u8) !void {
        if (self.undo_stack.items.len > 0) {
            const last = self.undo_stack.items[self.undo_stack.items.len - 1];
            if (std.mem.eql(u8, last, snapshot)) {
                alloc.free(snapshot);
                return;
            }
        }
        try self.undo_stack.append(alloc, snapshot);
        self.clearList(alloc, &self.redo_stack);
        while (self.undo_stack.items.len > self.max_depth) {
            const old = self.undo_stack.orderedRemove(0);
            alloc.free(old);
        }
    }

    pub fn undo(self: *History, alloc: std.mem.Allocator, current: []u8) !?[]u8 {
        if (self.undo_stack.items.len == 0) {
            alloc.free(current);
            return null;
        }
        try self.redo_stack.append(alloc, current);
        return self.undo_stack.orderedRemove(self.undo_stack.items.len - 1);
    }

    pub fn redo(self: *History, alloc: std.mem.Allocator, current: []u8) !?[]u8 {
        if (self.redo_stack.items.len == 0) {
            alloc.free(current);
            return null;
        }
        try self.undo_stack.append(alloc, current);
        return self.redo_stack.orderedRemove(self.redo_stack.items.len - 1);
    }

    fn clearList(self: *History, alloc: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
        _ = self;
        for (list.items) |snapshot| alloc.free(snapshot);
        list.clearRetainingCapacity();
    }
};

test "undo redo returns prior snapshots" {
    const alloc = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(alloc);

    try h.pushUndo(alloc, try alloc.dupe(u8, "one"));
    try h.pushUndo(alloc, try alloc.dupe(u8, "two"));

    const undo_snapshot = (try h.undo(alloc, try alloc.dupe(u8, "three"))).?;
    defer alloc.free(undo_snapshot);
    try std.testing.expectEqualStrings("two", undo_snapshot);

    const redo_snapshot = (try h.redo(alloc, try alloc.dupe(u8, "two-again"))).?;
    defer alloc.free(redo_snapshot);
    try std.testing.expectEqualStrings("three", redo_snapshot);
}

test "duplicate snapshots are ignored" {
    const alloc = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(alloc);

    try h.pushUndo(alloc, try alloc.dupe(u8, "same"));
    try h.pushUndo(alloc, try alloc.dupe(u8, "same"));
    try std.testing.expectEqual(@as(usize, 1), h.undo_stack.items.len);
}
