//! MIDI mappings and learn (docs/44): which controller or pad does what.
//!
//! A binding ties a source (a CC or a note, on a channel or any) to a
//! destination: a transport/navigation ACTION, a KNOB slot (one of eight
//! controls of the selected track's instrument, paged), or a PARAM (one
//! control a mouse touch picked in LEARN, session only). Actions and knob
//! slots save to midi-map.json beside settings.json; the factory map fits
//! an Akai MPK mini 3.

const std = @import("std");
const midi_in = @import("midi_in.zig");
const automation = @import("automation.zig");
const storage = @import("storage.zig");

pub const Action = enum(u8) {
    play_stop,
    stop,
    record,
    loop,
    prev_track,
    next_track,
    page_prev,
    page_next,

    pub fn label(a: Action) []const u8 {
        return switch (a) {
            .play_stop => "PLAY/STOP",
            .stop => "STOP",
            .record => "REC",
            .loop => "LOOP",
            .prev_track => "PREV TRACK",
            .next_track => "NEXT TRACK",
            .page_prev => "PAGE -",
            .page_next => "PAGE +",
        };
    }
};

pub const KNOBS = 8;

/// A control a mouse touch picked: track index, then the automation target.
pub const Param = struct { track: u16, target: automation.Target };

pub const Dest = union(enum) {
    action: Action,
    knob: u8,
    param: Param,

    fn eql(a: Dest, b: Dest) bool {
        return switch (a) {
            .action => |x| b == .action and b.action == x,
            .knob => |x| b == .knob and b.knob == x,
            .param => |x| b == .param and b.param.track == x.track and b.param.target.eql(x.target),
        };
    }
};

pub const SourceKind = enum(u8) { cc, note };

/// `channel` 0 is any, else 1...16.
pub const Source = struct {
    kind: SourceKind,
    channel: u8 = 0,
    number: u8,

    fn matches(s: Source, m: midi_in.Msg) bool {
        const k: SourceKind = switch (m.kind) {
            .cc => .cc,
            .note_on, .note_off => .note,
            else => return false,
        };
        return s.kind == k and s.number == m.a and (s.channel == 0 or s.channel == @as(u8, m.channel) + 1);
    }
};

pub const Binding = struct { src: Source, dest: Dest };

pub const MAX = 128;
pub var list: [MAX]Binding = undefined;
pub var count: usize = 0;

/// The knob page: knob `k` drives control `page * 8 + k`.
pub var page: u8 = 0;

fn remove(i: usize) void {
    list[i] = list[count - 1];
    count -= 1;
}

/// Bind `src` to `dest`: the source's old binding and, for a knob slot or
/// param, the destination's old source go.
pub fn bind(src: Source, dest: Dest) void {
    var i: usize = 0;
    while (i < count) {
        const b = list[i];
        const same_src = b.src.kind == src.kind and b.src.number == src.number and (b.src.channel == src.channel or b.src.channel == 0 or src.channel == 0);
        const same_dest = dest != .action and b.dest.eql(dest);
        if (same_src or same_dest) remove(i) else i += 1;
    }
    if (count < MAX) {
        list[count] = .{ .src = src, .dest = dest };
        count += 1;
    }
}

pub fn clear() void {
    count = 0;
}

/// The Akai MPK mini 3 as it ships: knobs K1-K8 are CC 70-77; bank A's
/// pads (notes 36-43, channel 10) play; bank B's (44-51) run the
/// transport. The joystick (bend, CC 1) and the pedal need no binding.
pub fn factory() void {
    clear();
    for (0..KNOBS) |k| bind(.{ .kind = .cc, .number = @intCast(70 + k) }, .{ .knob = @intCast(k) });
    const acts = [_]Action{ .play_stop, .stop, .record, .loop, .prev_track, .next_track, .page_prev, .page_next };
    for (acts, 0..) |a, i| bind(.{ .kind = .note, .channel = 10, .number = @intCast(44 + i) }, .{ .action = a });
}

/// The binding `m` triggers.
pub fn find(m: midi_in.Msg) ?Binding {
    for (list[0..count]) |b| if (b.src.matches(m)) return b;
    return null;
}

// ── Learn ────────────────────────────────────────────────────────────

pub var learn_armed = false;
/// What LEARN binds: 0 the control last touched, then the actions, then
/// the knob slots.
pub var learn_pick: u8 = 0;

pub const N_ACTIONS = @typeInfo(Action).@"enum".field_names.len;
pub const LEARN_LABELS = blk: {
    var l: [1 + N_ACTIONS + KNOBS][]const u8 = undefined;
    l[0] = "CONTROL";
    for (0..N_ACTIONS) |i| l[1 + i] = @as(Action, @enumFromInt(i)).label();
    const names = [_][]const u8{ "KNOB 1", "KNOB 2", "KNOB 3", "KNOB 4", "KNOB 5", "KNOB 6", "KNOB 7", "KNOB 8" };
    for (0..KNOBS) |k| l[1 + N_ACTIONS + k] = names[k];
    break :blk l;
};

/// Whether `m` is consumed instead of played: LEARN takes every note and
/// controller; a note bound to an action is not a note.
pub fn claims(m: midi_in.Msg) bool {
    switch (m.kind) {
        .note_on, .note_off => {},
        .cc => return learn_armed and m.a != 64,
        else => return false,
    }
    if (learn_armed) return true;
    const b = find(m) orelse return false;
    return b.dest == .action;
}

/// Learn's result: what bound to what.
pub const Learned = struct { src: Source, dest: Dest };

/// LEARN is armed and `m` is the controller to bind: make the binding and
/// disarm. `touched` is the control the mouse last touched. Null while
/// nothing fits (a note-off, a note for a knob); the reason is in `why`.
pub fn learnFrom(m: midi_in.Msg, touched: ?Param, why: *[]const u8) ?Learned {
    if (!learn_armed) return null;
    const src: Source = switch (m.kind) {
        .cc => .{ .kind = .cc, .channel = m.channel + 1, .number = m.a },
        .note_on => .{ .kind = .note, .channel = m.channel + 1, .number = m.a },
        else => return null,
    };
    if (src.kind == .cc and src.number == 64) return null;
    const dest: Dest = if (learn_pick == 0) blk: {
        const p = touched orelse {
            why.* = "Touch a control first, then LEARN";
            return null;
        };
        if (src.kind != .cc) {
            why.* = "A control needs a knob or fader, not a pad";
            return null;
        }
        break :blk .{ .param = p };
    } else if (learn_pick <= N_ACTIONS) .{ .action = @enumFromInt(learn_pick - 1) } else blk: {
        if (src.kind != .cc) {
            why.* = "A knob slot needs a knob or fader, not a pad";
            return null;
        }
        break :blk .{ .knob = @intCast(learn_pick - 1 - N_ACTIONS) };
    };
    bind(src, dest);
    learn_armed = false;
    return .{ .src = src, .dest = dest };
}

/// A button that sends a controller (not a note) fires on crossing
/// halfway; true on that crossing.
var cc_high: [16][128]bool = @splat(@splat(false));

pub fn rising(m: midi_in.Msg) bool {
    const was = cc_high[m.channel][m.a];
    cc_high[m.channel][m.a] = m.b >= 64;
    return m.b >= 64 and !was;
}

/// A value 0..127 as a knob-space value for a control with this range.
pub fn knobValue(b: u8, stepped: bool, lo: f32, hi: f32) f32 {
    const t = @as(f32, @floatFromInt(b)) / 127.0;
    return if (stepped) @round(lo + t * (hi - lo)) else t;
}

// ── midi-map.json ────────────────────────────────────────────────────

const FileBinding = struct {
    kind: []const u8,
    channel: u8 = 0,
    number: u8,
    to: []const u8,
    action: []const u8 = "",
    index: u8 = 0,
};
const File = struct {
    slab: []const u8 = "midi-map",
    schema: u32 = 1,
    bindings: []const FileBinding = &.{},
};

pub fn path(buf: []u8) []const u8 {
    var sb: [storage.MAX_PATH]u8 = undefined;
    const sp = storage.settingsPath(&sb);
    const dir = std.fs.path.dirname(sp) orelse return "";
    return std.fmt.bufPrint(buf, "{s}/midi-map.json", .{dir}) catch "";
}

/// The saved map as JSON: actions and knob slots (a param binding names a
/// track by position and is not saved).
pub fn toJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    var fb: [MAX]FileBinding = undefined;
    var n: usize = 0;
    for (list[0..count]) |b| {
        var f = FileBinding{ .kind = @tagName(b.src.kind), .channel = b.src.channel, .number = b.src.number, .to = "" };
        switch (b.dest) {
            .action => |a| {
                f.to = "action";
                f.action = @tagName(a);
            },
            .knob => |k| {
                f.to = "knob";
                f.index = k;
            },
            .param => continue,
        }
        fb[n] = f;
        n += 1;
    }
    try out.print(alloc, "{f}\n", .{std.json.fmt(File{ .bindings = fb[0..n] }, .{ .whitespace = .indent_2 })});
}

/// Replace the map with the one in `bytes`. False (map unchanged) when it
/// doesn't parse.
pub fn fromJson(alloc: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(File, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    clear();
    for (parsed.value.bindings) |f| {
        const kind = std.meta.stringToEnum(SourceKind, f.kind) orelse continue;
        const src = Source{ .kind = kind, .channel = @min(f.channel, 16), .number = f.number & 0x7F };
        if (std.mem.eql(u8, f.to, "action")) {
            const a = std.meta.stringToEnum(Action, f.action) orelse continue;
            bind(src, .{ .action = a });
        } else if (std.mem.eql(u8, f.to, "knob") and f.index < KNOBS) {
            bind(src, .{ .knob = f.index });
        }
    }
    return true;
}

/// Load midi-map.json, or the factory map (written out so it can be
/// found and edited) when there is none.
pub fn load(alloc: std.mem.Allocator) void {
    var pb: [storage.MAX_PATH]u8 = undefined;
    const p = path(&pb);
    if (p.len > 0) if (storage.readFile(alloc, p)) |bytes| {
        defer alloc.free(bytes);
        if (fromJson(alloc, bytes)) return;
    };
    factory();
    save(alloc);
}

pub fn save(alloc: std.mem.Allocator) void {
    var pb: [storage.MAX_PATH]u8 = undefined;
    const p = path(&pb);
    if (p.len == 0) return;
    if (std.fs.path.dirname(p)) |d| storage.makeParents(d);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    toJson(alloc, &out) catch return;
    storage.writeFile(p, out.items);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn msg(kind: midi_in.Kind, ch: u4, a: u8, b: u8) midi_in.Msg {
    return .{ .src = 0, .kind = kind, .channel = ch, .a = a, .b = b };
}

test "factory: knobs are CC 70-77, bank B pads run the transport" {
    factory();
    const k3 = find(msg(.cc, 0, 72, 10)).?;
    try testing.expectEqual(@as(u8, 2), k3.dest.knob);
    const pad = find(msg(.note_on, 9, 46, 100)).?;
    try testing.expectEqual(Action.record, pad.dest.action);
    // Bank A pads and the keys are plain notes.
    try testing.expect(find(msg(.note_on, 9, 36, 100)) == null);
    try testing.expect(find(msg(.note_on, 0, 46, 100)) == null);
    try testing.expect(claims(msg(.note_on, 9, 46, 100)));
    try testing.expect(claims(msg(.note_off, 9, 46, 0)));
    try testing.expect(!claims(msg(.note_on, 9, 36, 100)));
}

test "learn binds the next controller and disarms" {
    factory();
    var why: []const u8 = "";
    learn_armed = true;
    learn_pick = 1 + @intFromEnum(Action.loop);
    // A pad becomes LOOP; the factory binding of that pad goes.
    const l = learnFrom(msg(.note_on, 9, 36, 90), null, &why).?;
    try testing.expectEqual(Action.loop, l.dest.action);
    try testing.expect(!learn_armed);
    try testing.expectEqual(Action.loop, find(msg(.note_on, 9, 36, 1)).?.dest.action);
    // Rebinding KNOB 1 to CC 20 frees CC 70.
    learn_armed = true;
    learn_pick = 1 + N_ACTIONS;
    _ = learnFrom(msg(.cc, 0, 20, 5), null, &why).?;
    try testing.expect(find(msg(.cc, 0, 70, 5)) == null);
    try testing.expectEqual(@as(u8, 0), find(msg(.cc, 0, 20, 5)).?.dest.knob);
}

test "learn: a control needs a touch and a knob" {
    factory();
    var why: []const u8 = "";
    learn_armed = true;
    learn_pick = 0;
    try testing.expect(learnFrom(msg(.cc, 0, 21, 5), null, &why) == null);
    try testing.expect(learn_armed);
    const p = Param{ .track = 2, .target = automation.Target.volume() };
    try testing.expect(learnFrom(msg(.note_on, 9, 36, 90), p, &why) == null);
    const l = learnFrom(msg(.cc, 0, 21, 5), p, &why).?;
    try testing.expectEqual(@as(u16, 2), l.dest.param.track);
    // A second control on the same CC replaces it.
    learn_armed = true;
    const p2 = Param{ .track = 3, .target = automation.Target.pan() };
    _ = learnFrom(msg(.cc, 0, 21, 5), p2, &why).?;
    try testing.expectEqual(@as(u16, 3), find(msg(.cc, 0, 21, 0)).?.dest.param.track);
}

test "claims: learn takes notes and controllers except the pedal" {
    factory();
    learn_armed = true;
    defer learn_armed = false;
    try testing.expect(claims(msg(.note_on, 0, 60, 90)));
    try testing.expect(claims(msg(.cc, 0, 70, 1)));
    try testing.expect(!claims(msg(.cc, 0, 64, 127)));
    try testing.expect(!claims(msg(.bend, 0, 0, 64)));
}

test "json round trip keeps actions and knobs, drops params" {
    factory();
    bind(.{ .kind = .cc, .number = 21 }, .{ .param = .{ .track = 1, .target = automation.Target.volume() } });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try toJson(testing.allocator, &out);
    clear();
    try testing.expect(fromJson(testing.allocator, out.items));
    try testing.expectEqual(@as(usize, 16), count);
    try testing.expectEqual(@as(u8, 7), find(msg(.cc, 0, 77, 0)).?.dest.knob);
    try testing.expectEqual(Action.page_next, find(msg(.note_on, 9, 51, 1)).?.dest.action);
    try testing.expect(!fromJson(testing.allocator, "not json"));
}

test "a button on a controller fires once per press" {
    try testing.expect(rising(msg(.cc, 0, 30, 127)));
    try testing.expect(!rising(msg(.cc, 0, 30, 127)));
    try testing.expect(!rising(msg(.cc, 0, 30, 0)));
    try testing.expect(rising(msg(.cc, 0, 30, 100)));
}

test "knob values: continuous 0..1, stepped rounds into the range" {
    try testing.expectEqual(@as(f32, 0), knobValue(0, false, 0, 1));
    try testing.expectEqual(@as(f32, 1), knobValue(127, false, 0, 1));
    try testing.expectEqual(@as(f32, 3), knobValue(127, true, 0, 3));
    try testing.expectEqual(@as(f32, 2), knobValue(64, true, 0, 3));
}
