//! Built wavetables shared between instances (docs/25 §Content identity).
//! Building a table is the slow part of loading a wavetable synth: every
//! frame takes a dozen FFTs. Instances that load the same file content get
//! one read-only table, counted, and the last to let go frees it. A table
//! someone edits in place has to be their own first (`isShared`).
//!
//! UI thread only (instances are made and loaded there); the lock is for
//! tests and headless tools that build from several threads.

const std = @import("std");
const wavetable = @import("wavetable.zig");

const MAX = 64;

const Entry = struct {
    key: u64 = 0,
    len: usize = 0,
    table: wavetable.Table = .{},
    alloc: std.mem.Allocator = undefined,
    refs: usize = 0,
};

var entries: [MAX]Entry = [_]Entry{.{}} ** MAX;
var lock: std.atomic.Mutex = .unlocked;

fn take() void {
    while (!lock.tryLock()) std.Thread.yield() catch {};
}

fn key(samples: []const f64, frame_hint: usize, normalize: bool) u64 {
    var h = std.hash.Wyhash.init(0x51ab_7ab1e);
    h.update(std.mem.sliceAsBytes(samples));
    h.update(std.mem.asBytes(&frame_hint));
    h.update(&.{@intFromBool(normalize)});
    return h.final();
}

/// The table for these samples, built once and shared. Give it back with
/// `release`. When the cache is full the table is built unshared, and
/// `release` frees it like any other.
pub fn acquire(alloc: std.mem.Allocator, samples: []const f64, frame_hint: usize, normalize: bool) wavetable.Error!wavetable.Table {
    const k = key(samples, frame_hint, normalize);
    take();
    for (&entries) |*e| if (e.refs > 0 and e.key == k and e.len == samples.len) {
        e.refs += 1;
        lock.unlock();
        return e.table;
    };
    lock.unlock();

    // Build outside the lock; a second builder of the same content keeps
    // whichever table lands first.
    var t = try wavetable.build(alloc, samples, frame_hint, normalize);
    take();
    defer lock.unlock();
    for (&entries) |*e| if (e.refs > 0 and e.key == k and e.len == samples.len) {
        e.refs += 1;
        t.deinit(alloc);
        return e.table;
    };
    for (&entries) |*e| if (e.refs == 0) {
        e.* = .{ .key = k, .len = samples.len, .table = t, .alloc = alloc, .refs = 1 };
        return t;
    };
    return t;
}

/// Let go of a table from `acquire`, or free one that was never shared.
/// Leaves `t` empty.
pub fn release(alloc: std.mem.Allocator, t: *wavetable.Table) void {
    if (t.data.len == 0) return;
    take();
    for (&entries) |*e| if (e.refs > 0 and e.table.data.ptr == t.data.ptr) {
        e.refs -= 1;
        if (e.refs == 0) {
            e.table.deinit(e.alloc);
            e.* = .{};
        }
        lock.unlock();
        t.* = .{};
        return;
    };
    lock.unlock();
    t.deinit(alloc);
}

/// True when other instances may be reading `t`'s cells.
pub fn isShared(t: wavetable.Table) bool {
    if (t.data.len == 0) return false;
    take();
    defer lock.unlock();
    for (entries) |e| if (e.refs > 0 and e.table.data.ptr == t.data.ptr) return true;
    return false;
}

test "wavetable cache: same content shares one table, the last release frees it" {
    const alloc = std.testing.allocator;
    var a: [2048]f64 = undefined;
    for (&a, 0..) |*v, i| v.* = @sin(2 * std.math.pi * @as(f64, @floatFromInt(i)) / 2048.0);
    var b = a;
    b[7] += 0.5;
    var t1 = try acquire(alloc, &a, 0, true);
    var t2 = try acquire(alloc, &a, 0, true);
    var t3 = try acquire(alloc, &b, 0, true);
    var t4 = try acquire(alloc, &a, 0, false);
    try std.testing.expectEqual(t1.data.ptr, t2.data.ptr);
    try std.testing.expect(t3.data.ptr != t1.data.ptr);
    try std.testing.expect(t4.data.ptr != t1.data.ptr);
    try std.testing.expect(isShared(t1));
    release(alloc, &t1);
    try std.testing.expect(isShared(t2));
    release(alloc, &t2);
    release(alloc, &t3);
    release(alloc, &t4);
    try std.testing.expectEqual(@as(usize, 0), t2.data.len);
    // An unshared table is freed by release too (the allocator checks).
    var own = try wavetable.build(alloc, &a, 0, true);
    try std.testing.expect(!isShared(own));
    release(alloc, &own);
}
