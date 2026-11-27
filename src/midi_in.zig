//! MIDI input (docs/44): CoreMIDI sources, decoded messages, and the live
//! state they leave (held notes, sustain, bend, controller values).
//!
//! `native_midi.c` frames the bytes on CoreMIDI's thread into a lock-free
//! ring; `poll` drains it on the UI thread once a frame, the way the
//! computer keyboard is read (docs/40). Nothing here runs on the audio
//! thread.

const std = @import("std");

extern fn slab_midi_start() c_int;
extern fn slab_midi_connect() c_int;
extern fn slab_midi_take_rescan() c_int;
extern fn slab_midi_source_name(i: c_int, buf: [*]u8, cap: c_int) c_int;
extern fn slab_midi_pop() u32;
extern fn slab_midi_take_dropped() c_uint;

pub const Kind = enum(u8) { note_off, note_on, poly_pressure, cc, program, pressure, bend };

/// One channel message. `a` and `b` are the data bytes; for `bend`, `a` is
/// the low and `b` the high 7 bits.
pub const Msg = struct {
    src: u8,
    kind: Kind,
    channel: u4,
    a: u8,
    b: u8,

    /// A pitch bend as -1...1.
    pub fn bendValue(m: Msg) f32 {
        const v: i32 = (@as(i32, m.b) << 7 | m.a) - 8192;
        return @as(f32, @floatFromInt(v)) / (if (v < 0) @as(f32, 8192) else @as(f32, 8191));
    }
};

/// Unpack a queued message (`src<<24 | status<<16 | a<<8 | b`).
pub fn decode(raw: u32) ?Msg {
    const st: u8 = @truncate(raw >> 16);
    if (st < 0x80 or st >= 0xF0) return null;
    var kind: Kind = switch (st >> 4) {
        0x8 => .note_off,
        0x9 => .note_on,
        0xA => .poly_pressure,
        0xB => .cc,
        0xC => .program,
        0xD => .pressure,
        else => .bend,
    };
    const a: u8 = @truncate(raw >> 8);
    const b: u8 = @truncate(raw);
    // A note-on at velocity 0 is a note-off.
    if (kind == .note_on and b == 0) kind = .note_off;
    return .{ .src = @truncate(raw >> 24), .kind = kind, .channel = @truncate(st), .a = a & 0x7F, .b = b & 0x7F };
}

// ── Live state ───────────────────────────────────────────────────────

// Held notes, the pedal and all-notes-off are per source and channel, as
// MIDI has them. A track listening to a source (docs/44 §Sources) plays
// that source's notes alone; the sources no track listens to play the
// selected track.

const Slot = struct {
    /// Notes the fingers hold now, and those the sustain pedal still holds.
    held: u128 = 0,
    sustained: u128 = 0,
    pedal: bool = false,
    /// Velocity each held note arrived with (1..127).
    vel: [128]u8 = @splat(100),
};

/// By source index (as `sourceName` lists them), then channel.
var slots: [MAX_SOURCES][16]Slot = @splat(@splat(.{}));
/// Pitch bend, -1...1; the last value of each controller.
pub var bend: f32 = 0;
pub var cc: [128]u8 = @splat(0);
/// Sources some track listens to (bit n = source n); main sets it each
/// frame. Their notes stay out of `sounding`.
pub var claimed: u16 = 0;

fn bit(p: u8) u128 {
    return @as(u128, 1) << @intCast(p);
}

/// The state slot of messages from source `src`. Sources past
/// MAX_SOURCES share the last one.
fn slotsOf(src: usize) *[16]Slot {
    return &slots[@min(src, MAX_SOURCES - 1)];
}

fn isClaimed(src: usize) bool {
    return src < MAX_SOURCES and claimed & (@as(u16, 1) << @intCast(src)) != 0;
}

/// The pitches sounding now from source `src`, on any channel: held, plus
/// those its pedals hold.
pub fn soundingFrom(src: usize) u128 {
    var set: u128 = 0;
    for (slotsOf(src)) |*c| set |= c.held | c.sustained;
    return set;
}

/// The velocity pitch `p` arrived with from source `src` (the loudest, when
/// several channels hold it); null when none holds it.
pub fn velFrom(src: usize, p: u8) ?u8 {
    var v: ?u8 = null;
    for (slotsOf(src)) |*c| if ((c.held | c.sustained) & bit(p) != 0) {
        v = @max(v orelse 0, c.vel[p]);
    };
    return v;
}

/// The pitches sounding now from the sources no track listens to (these
/// play the selected track).
pub fn sounding() u128 {
    var set: u128 = 0;
    for (0..MAX_SOURCES) |src| if (!isClaimed(src)) {
        set |= soundingFrom(src);
    };
    return set;
}

/// The velocity pitch `p` arrived with from an unclaimed source (the
/// loudest, when several hold it); null when none holds it.
pub fn velocityOf(p: u8) ?u8 {
    var v: ?u8 = null;
    for (0..MAX_SOURCES) |src| if (!isClaimed(src)) {
        if (velFrom(src, p)) |x| v = @max(v orelse 0, x);
    };
    return v;
}

/// Fold `m` into the live state.
pub fn apply(m: Msg) void {
    const c = &slotsOf(m.src)[m.channel];
    switch (m.kind) {
        .note_on => {
            c.held |= bit(m.a);
            c.sustained &= ~bit(m.a);
            c.vel[m.a] = @max(m.b, 1);
        },
        .note_off => {
            c.held &= ~bit(m.a);
            if (c.pedal) c.sustained |= bit(m.a);
        },
        .bend => bend = m.bendValue(),
        .cc => {
            cc[m.a] = m.b;
            switch (m.a) {
                64 => {
                    c.pedal = m.b >= 64;
                    if (!c.pedal) c.sustained = 0;
                },
                120, 123 => c.* = .{},
                else => {},
            }
        },
        else => {},
    }
}

/// Let go of everything.
pub fn allOff() void {
    slots = @splat(@splat(.{}));
}

// ── Devices ──────────────────────────────────────────────────────────

/// Sources Slab names and keeps apart (a split generator publishes one per
/// part); more are still played, sharing the last one's state.
pub const MAX_SOURCES = 16;
pub const NAME_MAX = 48;
var started = false;
/// SLAB_MIDI_LOG=1 prints every message (to learn what a device sends).
var log_all = false;
var names: [MAX_SOURCES][NAME_MAX]u8 = undefined;
var name_len: [MAX_SOURCES]u8 = @splat(0);
var count: usize = 0;
/// Set when the set of sources changed; `takeChanged` clears it.
var changed = false;

/// Open CoreMIDI and connect every source. Safe to call again.
pub fn start() void {
    if (started) return;
    started = slab_midi_start() == 0;
    log_all = std.c.getenv("SLAB_MIDI_LOG") != null;
    if (!started) std.log.warn("midi: CoreMIDI client failed to start", .{});
}

pub fn sourceCount() usize {
    return count;
}

pub fn sourceName(i: usize) []const u8 {
    return if (i < count) names[i][0..name_len[i]] else "";
}

/// The index of the source named `name` now, or null when none is
/// connected (a saved project's device, unplugged).
pub fn sourceIndex(name: []const u8) ?usize {
    if (name.len == 0) return null;
    for (0..count) |i| if (std.mem.eql(u8, sourceName(i), name)) return i;
    return null;
}

/// Tests: the sources present, as a rescan would leave them.
pub fn setSourcesForTest(list: []const []const u8) void {
    count = @min(list.len, MAX_SOURCES);
    for (list[0..count], 0..) |n, i| {
        const len = @min(n.len, NAME_MAX);
        @memcpy(names[i][0..len], n[0..len]);
        name_len[i] = @intCast(len);
    }
}

/// Set by the mapping layer: true for a message it consumes (a pad bound
/// to an action, anything while LEARN listens), which then never plays.
pub var claim: ?*const fn (Msg) bool = null;

/// Some device is connected.
pub fn connected() bool {
    return count > 0;
}

/// True once after the set of devices changed (for a status message).
pub fn takeChanged() bool {
    defer changed = false;
    return changed;
}

var prev_names: [MAX_SOURCES][NAME_MAX]u8 = undefined;
var prev_len: [MAX_SOURCES]u8 = @splat(0);
var prev_slots: [MAX_SOURCES][16]Slot = undefined;

fn rescan() void {
    prev_names = names;
    prev_len = name_len;
    const prev_count = count;
    const n: usize = @intCast(@max(slab_midi_connect(), 0));
    count = @min(n, MAX_SOURCES);
    for (0..count) |i| {
        const ok = slab_midi_source_name(@intCast(i), &names[i], NAME_MAX);
        name_len[i] = if (ok != 0) @intCast(std.mem.indexOfScalar(u8, &names[i], 0) orelse NAME_MAX) else 0;
    }
    followSources(prev_count);
    changed = true;
}

/// After a rescan, each source's live state follows it to its new index,
/// matched by name. A source gone can't send the note-offs for what it
/// held, so its notes let go; the others' play on.
fn followSources(prev_count: usize) void {
    prev_slots = slots;
    slots = @splat(@splat(.{}));
    var used: [MAX_SOURCES]bool = @splat(false);
    for (0..count) |i| {
        for (0..prev_count) |j| {
            if (used[j] or !std.mem.eql(u8, prev_names[j][0..prev_len[j]], sourceName(i))) continue;
            slots[i] = prev_slots[j];
            used[j] = true;
            break;
        }
    }
}

/// Once a frame: drain what arrived into the live state, then follow
/// device changes. The messages (up to `out.len`) are copied to `out` for
/// the layers above (learn, mappings); returns how many. Draining first
/// keeps each queued message with the source index it was sent under.
pub fn poll(out: []Msg) usize {
    if (!started) return 0;
    const rescan_due = slab_midi_take_rescan() != 0;
    var n: usize = 0;
    while (true) {
        const raw = slab_midi_pop();
        if (raw == 0) break;
        const m = decode(raw) orelse continue;
        if (claim == null or !claim.?(m)) apply(m);
        if (log_all) std.log.info("midi src={d} ch={d} {s} a={d} b={d}", .{ m.src, @as(u8, m.channel) + 1, @tagName(m.kind), m.a, m.b });
        if (n < out.len) {
            out[n] = m;
            n += 1;
        }
    }
    if (slab_midi_take_dropped() != 0) std.log.warn("midi: input ring overflowed", .{});
    if (rescan_due) rescan();
    return n;
}

// ── Tests ────────────────────────────────────────────────────────────

fn pack(src: u8, st: u8, a: u8, b: u8) u32 {
    return @as(u32, src) << 24 | @as(u32, st) << 16 | @as(u32, a) << 8 | b;
}

fn reset() void {
    allOff();
    claimed = 0;
    count = 0;
    bend = 0;
    cc = @splat(0);
}

test "decode: channel messages, note-on at velocity 0 is a note-off" {
    const on = decode(pack(0, 0x93, 60, 99)).?;
    try std.testing.expectEqual(Kind.note_on, on.kind);
    try std.testing.expectEqual(@as(u4, 3), on.channel);
    try std.testing.expectEqual(@as(u8, 99), on.b);
    try std.testing.expectEqual(Kind.note_off, decode(pack(0, 0x90, 60, 0)).?.kind);
    try std.testing.expectEqual(Kind.cc, decode(pack(2, 0xB9, 70, 5)).?.kind);
    try std.testing.expect(decode(pack(0, 0xF8, 0, 0)) == null);
    try std.testing.expect(decode(pack(0, 0x00, 0, 0)) == null);
}

test "bend spans -1 to 1 with the center at 8192" {
    const lo = decode(pack(0, 0xE0, 0, 0)).?.bendValue();
    const mid = decode(pack(0, 0xE0, 0, 64)).?.bendValue();
    const hi = decode(pack(0, 0xE0, 127, 127)).?.bendValue();
    try std.testing.expectEqual(@as(f32, -1), lo);
    try std.testing.expectEqual(@as(f32, 0), mid);
    try std.testing.expectEqual(@as(f32, 1), hi);
}

test "notes hold and release, velocity is kept" {
    reset();
    apply(decode(pack(0, 0x90, 60, 80)).?);
    apply(decode(pack(0, 0x90, 64, 120)).?);
    try std.testing.expectEqual(bit(60) | bit(64), sounding());
    try std.testing.expectEqual(@as(?u8, 120), velFrom(0, 64));
    apply(decode(pack(0, 0x80, 60, 0)).?);
    try std.testing.expectEqual(bit(64), sounding());
}

test "the sustain pedal holds released notes until it lifts" {
    reset();
    apply(decode(pack(0, 0xB0, 64, 127)).?);
    apply(decode(pack(0, 0x90, 60, 90)).?);
    apply(decode(pack(0, 0x80, 60, 0)).?);
    try std.testing.expectEqual(bit(60), sounding());
    // Struck again while held by the pedal, then released: still pedaled.
    apply(decode(pack(0, 0x90, 60, 90)).?);
    apply(decode(pack(0, 0x80, 60, 0)).?);
    try std.testing.expectEqual(bit(60), sounding());
    apply(decode(pack(0, 0xB0, 64, 0)).?);
    try std.testing.expectEqual(@as(u128, 0), sounding());
}

test "all notes off clears everything" {
    reset();
    apply(decode(pack(0, 0x90, 60, 90)).?);
    apply(decode(pack(0, 0xB0, 123, 0)).?);
    try std.testing.expectEqual(@as(u128, 0), sounding());
}

test "all notes off and the pedal act on their own channel" {
    reset();
    defer reset();
    apply(decode(pack(0, 0x90, 60, 90)).?);
    apply(decode(pack(0, 0x92, 62, 90)).?);
    apply(decode(pack(0, 0xB2, 123, 0)).?);
    try std.testing.expectEqual(bit(60), sounding());
    // A pedal on channel 3 doesn't hold channel 1's note.
    apply(decode(pack(0, 0xB2, 64, 127)).?);
    apply(decode(pack(0, 0x80, 60, 0)).?);
    try std.testing.expectEqual(@as(u128, 0), sounding());
}

test "claimed sources stay out of the selected track's notes" {
    reset();
    // Other modules' tests read this state.
    defer reset();
    apply(decode(pack(0, 0x90, 60, 90)).?);
    apply(decode(pack(1, 0x93, 64, 70)).?);
    apply(decode(pack(2, 0x99, 36, 110)).?);
    try std.testing.expectEqual(bit(60) | bit(64) | bit(36), sounding());
    claimed = 1 << 1 | 1 << 2;
    try std.testing.expectEqual(bit(60), sounding());
    try std.testing.expectEqual(bit(64), soundingFrom(1));
    try std.testing.expectEqual(bit(36), soundingFrom(2));
    try std.testing.expectEqual(@as(?u8, 70), velFrom(1, 64));
    try std.testing.expectEqual(@as(?u8, null), velocityOf(64));
    try std.testing.expectEqual(@as(?u8, 90), velocityOf(60));
}

test "a source keeps its notes across a rescan that moves it, and a gone one lets go" {
    reset();
    defer reset();
    setSourcesForTest(&.{ "keys", "undertone lead", "undertone drums" });
    apply(decode(pack(1, 0x93, 64, 70)).?);
    apply(decode(pack(2, 0x99, 36, 110)).?);
    // The keyboard is unplugged: the lead and drums move down one.
    prev_names = names;
    prev_len = name_len;
    setSourcesForTest(&.{ "undertone lead", "undertone drums" });
    followSources(3);
    try std.testing.expectEqual(bit(64), soundingFrom(0));
    try std.testing.expectEqual(bit(36), soundingFrom(1));
    try std.testing.expectEqual(@as(?usize, 1), sourceIndex("undertone drums"));
    // The drums go too: only theirs let go.
    prev_names = names;
    prev_len = name_len;
    setSourcesForTest(&.{"undertone lead"});
    followSources(2);
    try std.testing.expectEqual(bit(64), soundingFrom(0));
    try std.testing.expectEqual(@as(u128, 0), soundingFrom(1));
    try std.testing.expectEqual(@as(?usize, null), sourceIndex("undertone drums"));
}
