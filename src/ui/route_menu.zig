//! The routing menu (docs/23 §UI): a track's output and sends, opened from
//! an arrangement header or a mixer strip. It edits nothing itself: `tick`
//! returns a `RouteEdit` that main applies with one undo step. Choices that
//! would close a loop are disabled.

const std = @import("std");
const menu = @import("menu.zig");
const routing = @import("../routing.zig");
const Track = @import("../track.zig").Track;

/// A routing edit, applied by main with an undo step. The `new_bus`
/// variants create the bus first.
pub const RouteEdit = struct {
    track: usize,
    what: union(enum) {
        output: u8, // a bus index, or routing.NONE for the master
        output_new_bus,
        send_toggle: u8,
        send_new_bus,
        /// Create the send (it doesn't exist yet) at a level.
        send_add: struct { bus: u8, level: f32 },
        send_pre: struct { bus: u8, pre: bool },
    },
};

/// What the menu shows at its root: both submenus (a header's name), the
/// output list itself (a strip's output field), or one send's options.
pub const Mode = enum { all, output, send };

const KEY: u64 = 0x2007_E000_0000_0001;
const NEW_BUS: u32 = 0x100;
const PRE: u32 = 0x201;
const POST: u32 = 0x202;
const REMOVE: u32 = 0x203;

var track_idx: usize = 0;
var mode: Mode = .all;
var send_bus: u8 = 0;
var labels: [routing.MAX_TRACKS][routing.MAX_TRACKS + 8]u8 = undefined;

pub fn open(ti: usize, m: Mode, x: i32, y: i32) void {
    track_idx = ti;
    mode = m;
    menu.openAt(KEY, x, y);
}

/// A send knob's menu: pre/post, remove.
pub fn openSend(ti: usize, bus: u8, x: i32, y: i32) void {
    send_bus = bus;
    open(ti, .send, x, y);
}

pub fn tick(tracks: []Track) ?RouteEdit {
    if (!menu.isOpen(KEY)) return null;
    const ti = track_idx;
    if (ti >= tracks.len) {
        menu.close();
        return null;
    }
    switch (mode) {
        .all => {
            const top = [_]menu.Item{
                .{ .label = "Output", .id = 1, .submenu = true },
                .{ .label = "Sends", .id = 2, .submenu = true },
            };
            _ = menu.pick(KEY, &top);
            const which = menu.subOpen(KEY, 0) orelse return null;
            return list(tracks, ti, which == 1, 1);
        },
        .output => return list(tracks, ti, true, 0),
        .send => {
            const t = &tracks[ti];
            const s = t.sendTo(send_bus) orelse {
                menu.close();
                return null;
            };
            const items = [_]menu.Item{
                .{ .label = if (!s.pre) "\u{2022} Post-fader" else "Post-fader", .id = POST },
                .{ .label = if (s.pre) "\u{2022} Pre-fader" else "Pre-fader", .id = PRE },
                .{ .separator = true },
                .{ .label = "Remove send", .id = REMOVE },
            };
            return switch (menu.pick(KEY, &items) orelse return null) {
                PRE => .{ .track = ti, .what = .{ .send_pre = .{ .bus = send_bus, .pre = true } } },
                POST => .{ .track = ti, .what = .{ .send_pre = .{ .bus = send_bus, .pre = false } } },
                REMOVE => .{ .track = ti, .what = .{ .send_toggle = send_bus } },
                else => null,
            };
        },
    }
}

/// The output list (Master, the buses, New bus) or the sends list (the
/// buses to toggle, New bus), ticked at menu `level`.
fn list(tracks: []Track, ti: usize, outputs: bool, level: usize) ?RouteEdit {
    const t = &tracks[ti];
    var nodes: [routing.MAX_TRACKS]routing.Node = undefined;
    const n = @min(tracks.len, routing.MAX_TRACKS);
    for (tracks[0..n], 0..) |*u, i| nodes[i] = u.routingNode();
    const graph = routing.Routing.build(nodes[0..n]);
    const self_idx: u8 = @intCast(ti);

    var items: [routing.MAX_TRACKS + 3]menu.Item = undefined;
    var k: usize = 0;
    if (outputs) {
        items[k] = .{ .label = if (t.output == routing.NONE) "\u{2022} Master" else "Master", .id = routing.NONE };
        k += 1;
    }
    for (tracks[0..n], 0..) |*u, j| {
        if (!u.isBus() or j == ti) continue;
        const bus: u8 = @intCast(j);
        const on = if (outputs) t.output == bus else t.sendTo(bus) != null;
        const lbl = std.fmt.bufPrint(&labels[j], "{s}{s}", .{ if (on) "\u{2022} " else "", u.name() }) catch u.name();
        items[k] = .{ .label = lbl, .id = bus, .enabled = on or !graph.wouldCycle(self_idx, bus) };
        k += 1;
    }
    items[k] = .{ .separator = true };
    k += 1;
    items[k] = .{ .label = "New bus", .id = NEW_BUS, .enabled = tracks.len < routing.MAX_TRACKS };
    k += 1;
    const id = (if (level == 0) menu.pick(KEY, items[0..k]) else menu.subPick(KEY, level, items[0..k])) orelse return null;
    if (outputs) {
        if (id == NEW_BUS) return .{ .track = ti, .what = .output_new_bus };
        return .{ .track = ti, .what = .{ .output = @intCast(id) } };
    }
    if (id == NEW_BUS) return .{ .track = ti, .what = .send_new_bus };
    return .{ .track = ti, .what = .{ .send_toggle = @intCast(id) } };
}

/// Whether `from` may route into bus `to` (a new output or send).
pub fn canRoute(tracks: []Track, from: usize, to: usize) bool {
    if (from == to or to >= tracks.len or !tracks[to].isBus()) return false;
    var nodes: [routing.MAX_TRACKS]routing.Node = undefined;
    const n = @min(tracks.len, routing.MAX_TRACKS);
    for (tracks[0..n], 0..) |*u, i| nodes[i] = u.routingNode();
    return !routing.Routing.build(nodes[0..n]).wouldCycle(@intCast(from), @intCast(to));
}
