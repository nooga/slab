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

/// Notes the fingers hold now, and those the sustain pedal still holds.
pub var held: u128 = 0;
pub var sustained: u128 = 0;
/// Velocity each held note arrived with (1..127).
pub var vel: [128]u8 = @splat(100);
pub var sustain_down = false;
/// Pitch bend, -1...1; the last value of each controller.
pub var bend: f32 = 0;
pub var cc: [128]u8 = @splat(0);

fn bit(p: u8) u128 {
    return @as(u128, 1) << @intCast(p);
}

/// The pitches sounding now: held, plus those the pedal holds.
pub fn sounding() u128 {
    return held | sustained;
}

/// Fold `m` into the live state.
pub fn apply(m: Msg) void {
    switch (m.kind) {
        .note_on => {
            held |= bit(m.a);
            sustained &= ~bit(m.a);
            vel[m.a] = @max(m.b, 1);
        },
        .note_off => {
            held &= ~bit(m.a);
            if (sustain_down) sustained |= bit(m.a);
        },
        .bend => bend = m.bendValue(),
        .cc => {
            cc[m.a] = m.b;
            switch (m.a) {
                64 => {
                    sustain_down = m.b >= 64;
                    if (!sustain_down) sustained = 0;
                },
                120, 123 => allOff(),
                else => {},
            }
        },
        else => {},
    }
}

/// Let go of everything (all notes off, a device unplugged).
pub fn allOff() void {
    held = 0;
    sustained = 0;
    sustain_down = false;
}

// ── Devices ──────────────────────────────────────────────────────────

pub const MAX_SOURCES = 8;
const NAME_MAX = 48;
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

fn rescan() void {
    const n: usize = @intCast(@max(slab_midi_connect(), 0));
    count = @min(n, MAX_SOURCES);
    for (0..count) |i| {
        const ok = slab_midi_source_name(@intCast(i), &names[i], NAME_MAX);
        name_len[i] = if (ok != 0) @intCast(std.mem.indexOfScalar(u8, &names[i], 0) orelse NAME_MAX) else 0;
    }
    if (count == 0) allOff();
    changed = true;
}

/// Once a frame: follow device changes, then drain what arrived into the
/// live state. The messages (up to `out.len`) are copied to `out` for the
/// layers above (learn, mappings); returns how many.
pub fn poll(out: []Msg) usize {
    if (!started) return 0;
    if (slab_midi_take_rescan() != 0) rescan();
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
    return n;
}

// ── Tests ────────────────────────────────────────────────────────────

fn pack(src: u8, st: u8, a: u8, b: u8) u32 {
    return @as(u32, src) << 24 | @as(u32, st) << 16 | @as(u32, a) << 8 | b;
}

fn reset() void {
    allOff();
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
    try std.testing.expectEqual(@as(u8, 120), vel[64]);
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
