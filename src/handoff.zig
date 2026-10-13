//! Single-producer/single-consumer latest-value handoff. Three slots have
//! explicit ownership: producer, consumer, and the atomic exchange slot.
//! Publication coalesces intermediate versions. Neither side waits or
//! retries; a stalled producer cannot stop the consumer using its slot.
//! A consumer pointer remains valid until its next adopt(), not until
//! some assumed number of milliseconds elapses. All readers of that
//! pointer must finish before the consumer adopts again.
const std = @import("std");

pub const Slots = struct {
    const DIRTY: u32 = 4;
    exchange: std.atomic.Value(u32) = .init(1),
    writer: u32 = 2, // producer-owned
    reader: u32 = 0, // consumer-owned

    pub fn publish(self: *Slots) void {
        self.writer = self.exchange.swap(self.writer | DIRTY, .acq_rel) & 3;
    }
    pub fn pending(self: *const Slots) bool {
        return self.exchange.load(.acquire) & DIRTY != 0;
    }
    pub fn adopt(self: *Slots) bool {
        if (!self.pending()) return false;
        self.reader = self.exchange.swap(self.reader, .acq_rel) & 3;
        return true;
    }
};

pub fn Latest(comptime T: type) type {
    return struct {
        slots: [3]T,
        ownership: Slots = .{},
        const Self = @This();
        pub fn init(value: T) Self {
            return .{ .slots = .{ value, value, value } };
        }
        pub fn write(self: *Self) *T {
            return &self.slots[self.ownership.writer];
        }
        pub fn publish(self: *Self) void {
            self.ownership.publish();
        }
        pub fn pending(self: *const Self) bool {
            return self.ownership.pending();
        }
        pub fn adopt(self: *Self) bool {
            return self.ownership.adopt();
        }
        pub fn current(self: *const Self) *const T {
            return &self.slots[self.ownership.reader];
        }
    };
}

test "handoff: producer cannot overwrite a held consumer version" {
    var h = Latest(u64).init(0);
    h.write().* = 1;
    h.publish();
    try std.testing.expect(h.adopt());
    const held = h.current();
    for (2..10000) |i| {
        h.write().* = i;
        h.publish();
        try std.testing.expectEqual(@as(u64, 1), held.*);
    }
    try std.testing.expect(h.adopt());
    try std.testing.expectEqual(@as(u64, 9999), h.current().*);
    try std.testing.expect(!h.adopt());
    h.write().* = 10000; // stalled halfway through preparation
    try std.testing.expect(!h.adopt());
    try std.testing.expectEqual(@as(u64, 9999), h.current().*);
}

test "handoff: concurrent publication never tears payloads" {
    const Payload = struct { generation: u64 = 0, cells: [128]u64 = @splat(0) };
    const H = Latest(Payload);
    const Runner = struct {
        fn run(h: *H, done: *std.atomic.Value(bool)) void {
            for (1..50000) |i| {
                h.write().* = .{ .generation = i, .cells = @splat(i) };
                h.publish();
            }
            done.store(true, .release);
        }
    };
    var h = H.init(.{});
    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ &h, &done });
    defer thread.join();
    var last: u64 = 0;
    while (!done.load(.acquire) or h.pending()) {
        _ = h.adopt();
        const p = h.current();
        try std.testing.expect(p.generation >= last);
        last = p.generation;
        for (p.cells) |v| try std.testing.expectEqual(p.generation, v);
    }
    try std.testing.expectEqual(@as(u64, 49999), last);
}

/// Control-owned bounded retirement list. Audio only publishes an ack;
/// it never frees, scans this list, or waits for space. Ack generation N
/// means every resource superseded by publication <= N is no longer used.
pub fn Retirement(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct { generation: u64, value: T };
        entries: [capacity]Entry = undefined,
        len: usize = 0,
        ack: std.atomic.Value(u64) = .init(0),
        pub fn available(self: *const Self) bool {
            return self.len < capacity;
        }
        pub fn append(self: *Self, generation: u64, value: T) void {
            std.debug.assert(self.available());
            self.entries[self.len] = .{ .generation = generation, .value = value };
            self.len += 1;
        }
        pub fn acknowledge(self: *Self, generation: u64) void {
            self.ack.store(generation, .release);
        }
        pub fn collect(self: *Self, context: anytype, comptime dispose: anytype) void {
            const ack = self.ack.load(.acquire);
            var kept: usize = 0;
            for (self.entries[0..self.len]) |e| {
                if (e.generation <= ack) {
                    dispose(context, e.value);
                } else {
                    self.entries[kept] = e;
                    kept += 1;
                }
            }
            self.len = kept;
        }
        /// Teardown only, after every consumer has stopped.
        pub fn drain(self: *Self, context: anytype, comptime dispose: anytype) void {
            for (self.entries[0..self.len]) |e| dispose(context, e.value);
            self.len = 0;
        }
    };
}

test "handoff: retirement waits for acknowledgement and has bounded capacity" {
    const Dispose = struct {
        fn f(sum: *u64, value: u64) void {
            sum.* += value;
        }
    };
    var q = Retirement(u64, 2){};
    var disposed: u64 = 0;
    q.append(1, 10);
    q.append(3, 20);
    try std.testing.expect(!q.available());
    q.collect(&disposed, Dispose.f);
    try std.testing.expectEqual(@as(u64, 0), disposed);
    q.acknowledge(2);
    q.collect(&disposed, Dispose.f);
    try std.testing.expectEqual(@as(u64, 10), disposed);
    try std.testing.expectEqual(@as(usize, 1), q.len);
    q.acknowledge(3);
    q.collect(&disposed, Dispose.f);
    try std.testing.expectEqual(@as(u64, 30), disposed);
    try std.testing.expect(q.available());
}
