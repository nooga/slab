//! Byte-snapshot undo/redo stack.
//!
//! Most steps are edits inside one project and carry only the document
//! bytes. Open and New Project switch projects, so their steps also carry
//! the project they leave (docs/25 §Undo across projects): undoing one
//! restores the path, the chosen flag and the storage root along with the
//! tracks, and its redo step carries the project undo left.

const std = @import("std");

/// Which project a document belongs to: its path, and whether the user
/// chose it (false for the untitled project).
pub const Project = struct {
    path: []const u8,
    chosen: bool,
};

pub const Entry = struct {
    doc: []u8,
    /// Set on steps that switch projects; owned.
    project: ?Project = null,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.doc);
        if (self.project) |p| alloc.free(p.path);
    }

    fn sameAs(self: Entry, other: Entry) bool {
        if (!std.mem.eql(u8, self.doc, other.doc)) return false;
        const a = self.project orelse return other.project == null;
        const b = other.project orelse return false;
        return a.chosen == b.chosen and std.mem.eql(u8, a.path, b.path);
    }
};

pub const History = struct {
    undo_stack: std.ArrayList(Entry) = .empty,
    redo_stack: std.ArrayList(Entry) = .empty,
    max_depth: usize = 64,

    pub fn deinit(self: *History, alloc: std.mem.Allocator) void {
        self.clearList(alloc, &self.undo_stack);
        self.clearList(alloc, &self.redo_stack);
        self.undo_stack.deinit(alloc);
        self.redo_stack.deinit(alloc);
    }

    /// An edit's step: `snapshot` is the document before it. The history
    /// owns it once this returns; on an error the caller still does.
    pub fn pushUndo(self: *History, alloc: std.mem.Allocator, snapshot: []u8) !void {
        try self.push(alloc, .{ .doc = snapshot });
    }

    /// A project switch's step: `snapshot` is the document before it (as
    /// for pushUndo), `left` the project it belonged to (copied).
    pub fn pushSwitch(self: *History, alloc: std.mem.Allocator, snapshot: []u8, left: Project) !void {
        const path = try alloc.dupe(u8, left.path);
        try self.push(alloc, .{ .doc = snapshot, .project = .{ .path = path, .chosen = left.chosen } });
    }

    fn push(self: *History, alloc: std.mem.Allocator, entry: Entry) !void {
        if (self.undo_stack.items.len > 0) {
            const last = self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.sameAs(entry)) {
                entry.deinit(alloc);
                return;
            }
        }
        self.undo_stack.append(alloc, entry) catch |err| {
            if (entry.project) |p| alloc.free(p.path);
            return err;
        };
        self.clearList(alloc, &self.redo_stack);
        while (self.undo_stack.items.len > self.max_depth) {
            const old = self.undo_stack.orderedRemove(0);
            old.deinit(alloc);
        }
    }

    /// Step back from `current` (owned) in project `here`. The caller
    /// owns the returned entry; when it carries a project, switch to it.
    pub fn undo(self: *History, alloc: std.mem.Allocator, current: []u8, here: Project) !?Entry {
        return step(alloc, &self.undo_stack, &self.redo_stack, current, here);
    }

    pub fn redo(self: *History, alloc: std.mem.Allocator, current: []u8, here: Project) !?Entry {
        return step(alloc, &self.redo_stack, &self.undo_stack, current, here);
    }

    /// Pop `from`, pushing `current` onto `to`. A switch's counterpart
    /// carries the project being left, so stepping back over it returns.
    fn step(alloc: std.mem.Allocator, from: *std.ArrayList(Entry), to: *std.ArrayList(Entry), current: []u8, here: Project) !?Entry {
        if (from.items.len == 0) {
            alloc.free(current);
            return null;
        }
        var back: Entry = .{ .doc = current };
        if (from.items[from.items.len - 1].project != null) {
            const path = alloc.dupe(u8, here.path) catch |err| {
                alloc.free(current);
                return err;
            };
            back.project = .{ .path = path, .chosen = here.chosen };
        }
        to.append(alloc, back) catch |err| {
            back.deinit(alloc);
            return err;
        };
        return from.pop().?;
    }

    fn clearList(self: *History, alloc: std.mem.Allocator, list: *std.ArrayList(Entry)) void {
        _ = self;
        for (list.items) |entry| entry.deinit(alloc);
        list.clearRetainingCapacity();
    }
};

const untitled: Project = .{ .path = "slab-project.slab", .chosen = false };

test "undo redo returns prior snapshots" {
    const alloc = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(alloc);

    try h.pushUndo(alloc, try alloc.dupe(u8, "one"));
    try h.pushUndo(alloc, try alloc.dupe(u8, "two"));

    const undo_entry = (try h.undo(alloc, try alloc.dupe(u8, "three"), untitled)).?;
    defer undo_entry.deinit(alloc);
    try std.testing.expectEqualStrings("two", undo_entry.doc);
    try std.testing.expect(undo_entry.project == null);

    const redo_entry = (try h.redo(alloc, try alloc.dupe(u8, "two-again"), untitled)).?;
    defer redo_entry.deinit(alloc);
    try std.testing.expectEqualStrings("three", redo_entry.doc);
    try std.testing.expect(redo_entry.project == null);
}

test "duplicate snapshots are ignored" {
    const alloc = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(alloc);

    try h.pushUndo(alloc, try alloc.dupe(u8, "same"));
    try h.pushUndo(alloc, try alloc.dupe(u8, "same"));
    try std.testing.expectEqual(@as(usize, 1), h.undo_stack.items.len);
    // The same bytes in another project are another step.
    try h.pushSwitch(alloc, try alloc.dupe(u8, "same"), untitled);
    try std.testing.expectEqual(@as(usize, 2), h.undo_stack.items.len);
}

test "a switch step returns to the project it left, and redo to the one undo left" {
    const alloc = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(alloc);
    const a: Project = .{ .path = "songs/a.slab", .chosen = true };
    const b: Project = .{ .path = "demos/b.slab", .chosen = true };

    try h.pushUndo(alloc, try alloc.dupe(u8, "a0")); // an edit in A
    try h.pushSwitch(alloc, try alloc.dupe(u8, "a1"), a); // open B

    const back = (try h.undo(alloc, try alloc.dupe(u8, "b"), b)).?;
    defer back.deinit(alloc);
    try std.testing.expectEqualStrings("a1", back.doc);
    try std.testing.expectEqualStrings("songs/a.slab", back.project.?.path);

    // The edit before the switch stays in A.
    const edit = (try h.undo(alloc, try alloc.dupe(u8, "a1"), a)).?;
    defer edit.deinit(alloc);
    try std.testing.expect(edit.project == null);

    const again = (try h.redo(alloc, try alloc.dupe(u8, "a0"), a)).?;
    defer again.deinit(alloc);
    try std.testing.expect(again.project == null);
    const fwd = (try h.redo(alloc, try alloc.dupe(u8, "a1"), a)).?;
    defer fwd.deinit(alloc);
    try std.testing.expectEqualStrings("b", fwd.doc);
    try std.testing.expectEqualStrings("demos/b.slab", fwd.project.?.path);
    try std.testing.expect(fwd.project.?.chosen);
}
