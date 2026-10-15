//! Musical typing (docs/40): the computer keyboard plays the selected
//! track. PIANO is one chromatic row (A W S E D F T G Y H U J K O L P ; '),
//! GRID is four rows in fourths like a Push (in key when a scale is set),
//! CHORD plays diatonic chords on the bottom row under an in-key melody on
//! the two rows above it. What it plays records into clips (`Take`).

const std = @import("std");
const c = @import("../c.zig");

pub const Layout = enum(u8) {
    piano,
    grid,
    chord,

    pub fn label(l: Layout) []const u8 {
        return LAYOUT_LABELS[@intFromEnum(l)];
    }
};
pub const LAYOUT_LABELS = [_][]const u8{ "PIANO", "GRID", "CHORD" };

/// Chord shapes in scale degrees above the chord's root, so every chord
/// stays in key.
pub const ChordType = enum(u8) {
    triad,
    seventh,
    sus2,
    sus4,
    ninth,
    power,

    pub fn label(t: ChordType) []const u8 {
        return CHORD_LABELS[@intFromEnum(t)];
    }

    fn degrees(t: ChordType) []const i32 {
        return switch (t) {
            .triad => &.{ 0, 2, 4 },
            .seventh => &.{ 0, 2, 4, 6 },
            .sus2 => &.{ 0, 1, 4 },
            .sus4 => &.{ 0, 3, 4 },
            .ninth => &.{ 0, 2, 4, 6, 8 },
            .power => &.{ 0, 4, 7 },
        };
    }
};
pub const CHORD_LABELS = [_][]const u8{ "TRIAD", "7TH", "SUS2", "SUS4", "9TH", "POWER" };

/// The piano roll's key: `mask` bit i = i semitones above `root`.
pub const Scale = struct {
    root: u8 = 0,
    mask: u12 = 0xfff,
    on: bool = false,
};
const MAJOR: u12 = 0b101010110101;

pub var enabled = false;
pub var layout: Layout = .piano;
/// The base C is C`octave` (60 = C4, the piano roll's naming).
pub var octave: i8 = 4;
pub var velocity: u8 = 100;
pub var chord_type: ChordType = .triad;
/// REC with KEYS on: write what's played into a clip while the
/// transport runs (main drives the `take`).
pub var recording = false;
pub var take: Take = .{};

pub const OCTAVE_MIN: i8 = -1;
pub const OCTAVE_MAX: i8 = 8;
const VELOCITIES = [_]u8{ 1, 20, 40, 60, 80, 100, 127 };

// Rows bottom to top, as a Push's pads.
const ROWS = [4][10]c_int{
    .{ c.rl.KEY_Z, c.rl.KEY_X, c.rl.KEY_C, c.rl.KEY_V, c.rl.KEY_B, c.rl.KEY_N, c.rl.KEY_M, c.rl.KEY_COMMA, c.rl.KEY_PERIOD, c.rl.KEY_SLASH },
    .{ c.rl.KEY_A, c.rl.KEY_S, c.rl.KEY_D, c.rl.KEY_F, c.rl.KEY_G, c.rl.KEY_H, c.rl.KEY_J, c.rl.KEY_K, c.rl.KEY_L, c.rl.KEY_SEMICOLON },
    .{ c.rl.KEY_Q, c.rl.KEY_W, c.rl.KEY_E, c.rl.KEY_R, c.rl.KEY_T, c.rl.KEY_Y, c.rl.KEY_U, c.rl.KEY_I, c.rl.KEY_O, c.rl.KEY_P },
    .{ c.rl.KEY_ONE, c.rl.KEY_TWO, c.rl.KEY_THREE, c.rl.KEY_FOUR, c.rl.KEY_FIVE, c.rl.KEY_SIX, c.rl.KEY_SEVEN, c.rl.KEY_EIGHT, c.rl.KEY_NINE, c.rl.KEY_ZERO },
};
/// PIANO: semitones above the base C.
const PIANO = [_]c_int{
    c.rl.KEY_A, c.rl.KEY_W, c.rl.KEY_S, c.rl.KEY_E, c.rl.KEY_D, c.rl.KEY_F, c.rl.KEY_T, c.rl.KEY_G,         c.rl.KEY_Y,
    c.rl.KEY_H, c.rl.KEY_U, c.rl.KEY_J, c.rl.KEY_K, c.rl.KEY_O, c.rl.KEY_L, c.rl.KEY_P, c.rl.KEY_SEMICOLON, c.rl.KEY_APOSTROPHE,
};
/// Octave and velocity: - = [ ] in every layout, and Z X C V on PIANO.
const CONTROLS = [_]c_int{ c.rl.KEY_MINUS, c.rl.KEY_EQUAL, c.rl.KEY_LEFT_BRACKET, c.rl.KEY_RIGHT_BRACKET };
const PIANO_CONTROLS = [_]c_int{ c.rl.KEY_Z, c.rl.KEY_X, c.rl.KEY_C, c.rl.KEY_V };

fn baseC(oct: i8) i32 {
    return 12 * (@as(i32, oct) + 1);
}

fn bit(p: i32) u128 {
    if (p < 0 or p > 127) return 0;
    return @as(u128, 1) << @intCast(p);
}

/// The pitch `degree` steps up `mask` from `root` (negative steps down).
pub fn degreePitch(root: i32, mask: u12, degree: i32) i32 {
    const n: i32 = @popCount(mask);
    if (n == 0) return root;
    var idx = @mod(degree, n);
    var semi: i32 = 0;
    for (0..12) |b| {
        if ((mask >> @intCast(b)) & 1 == 0) continue;
        if (idx == 0) {
            semi = @intCast(b);
            break;
        }
        idx -= 1;
    }
    return root + 12 * @divFloor(degree, n) + semi;
}

fn rowCol(key: c_int) ?[2]i32 {
    for (ROWS, 0..) |row, r| for (row, 0..) |k, col| {
        if (k == key) return .{ @intCast(r), @intCast(col) };
    };
    return null;
}

/// The pitches `key` plays (0 when it plays none).
pub fn pitchesFor(lay: Layout, key: c_int, oct: i8, scale: Scale, ct: ChordType) u128 {
    const base = baseC(oct);
    switch (lay) {
        .piano => {
            for (PIANO, 0..) |k, i| if (k == key) return bit(base + @as(i32, @intCast(i)));
            return 0;
        },
        .grid => {
            const rc = rowCol(key) orelse return 0;
            // Up a row is a fourth: five semitones, or three steps in key.
            if (scale.on) return bit(degreePitch(base + scale.root, scale.mask, rc[1] + 3 * rc[0]));
            return bit(base + rc[1] + 5 * rc[0]);
        },
        .chord => {
            const rc = rowCol(key) orelse return 0;
            const mask = if (scale.on) scale.mask else MAJOR;
            const root = base + scale.root;
            const n: i32 = @popCount(mask);
            return switch (rc[0]) {
                // Chords an octave under the melody, one per degree.
                0 => blk: {
                    var set: u128 = 0;
                    for (ct.degrees()) |d| set |= bit(degreePitch(root - 12, mask, rc[1] + d));
                    break :blk set;
                },
                1 => bit(degreePitch(root, mask, rc[1])),
                2 => bit(degreePitch(root, mask, rc[1] + n)),
                else => 0, // the number row picks the chord type
            };
        },
    }
}

fn inList(list: []const c_int, key: c_int) bool {
    for (list) |k| if (k == key) return true;
    return false;
}

/// Whether `key` belongs to musical typing in `lay` (so the panes'
/// unmodified shortcuts on it stand down).
pub fn layoutClaims(lay: Layout, key: c_int) bool {
    if (inList(&CONTROLS, key)) return true;
    return switch (lay) {
        .piano => inList(&PIANO, key) or inList(&PIANO_CONTROLS, key),
        .grid, .chord => rowCol(key) != null,
    };
}

// ── Live state ───────────────────────────────────────────────────────

const MAX_HELD = 48;
const Held = struct { key: c_int, pitches: u128 };
var held: [MAX_HELD]Held = undefined;
var held_n: usize = 0;
/// This frame a text field, menu or dialog owns the keys, or ⌘ is down.
var standing_down = true;

/// Whether musical typing takes `key` this frame.
pub fn claims(key: c_int) bool {
    return enabled and !standing_down and layoutClaims(layout, key);
}

/// The pitches the keys hold now.
pub fn sounding() u128 {
    var set: u128 = 0;
    for (held[0..held_n]) |h| set |= h.pitches;
    return set;
}

pub fn setEnabled(on: bool) void {
    enabled = on;
    if (!on) {
        held_n = 0;
        recording = false;
    }
}

pub fn octaveName(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "C{d}", .{octave}) catch "C";
}

fn stepVelocity(dir: i32) void {
    var i: usize = 0;
    while (i < VELOCITIES.len and VELOCITIES[i] < velocity) i += 1;
    if (dir < 0) {
        velocity = if (i == 0) VELOCITIES[0] else VELOCITIES[i - 1];
    } else {
        const at = if (i < VELOCITIES.len and VELOCITIES[i] == velocity) i + 1 else i;
        velocity = VELOCITIES[@min(at, VELOCITIES.len - 1)];
    }
}

pub fn stepOctave(dir: i32) void {
    octave = @intCast(std.math.clamp(@as(i32, octave) + dir, OCTAVE_MIN, OCTAVE_MAX));
}

/// Once a frame: let go of released keys, then (when free) take octave,
/// velocity, chord-type and note presses. `free` is false while a text
/// field, menu or dialog owns the keyboard or ⌘ is down.
pub fn poll(free: bool, scale: Scale) void {
    standing_down = !free;
    var i: usize = 0;
    while (i < held_n) {
        if (!c.rl.IsKeyDown(held[i].key)) {
            held[i] = held[held_n - 1];
            held_n -= 1;
        } else i += 1;
    }
    if (!enabled or !free) return;
    const pressed = c.rl.IsKeyPressed;
    const piano = layout == .piano;
    if (pressed(c.rl.KEY_MINUS) or (piano and pressed(c.rl.KEY_Z))) stepOctave(-1);
    if (pressed(c.rl.KEY_EQUAL) or (piano and pressed(c.rl.KEY_X))) stepOctave(1);
    if (pressed(c.rl.KEY_LEFT_BRACKET) or (piano and pressed(c.rl.KEY_C))) stepVelocity(-1);
    if (pressed(c.rl.KEY_RIGHT_BRACKET) or (piano and pressed(c.rl.KEY_V))) stepVelocity(1);
    if (layout == .chord) for (ROWS[3][0..CHORD_LABELS.len], 0..) |k, t| {
        if (pressed(k)) chord_type = @enumFromInt(t);
    };
    for (ROWS) |row| for (row) |k| tryPress(k, scale);
    tryPress(c.rl.KEY_APOSTROPHE, scale);
}

fn tryPress(key: c_int, scale: Scale) void {
    if (!c.rl.IsKeyPressed(key)) return;
    for (held[0..held_n]) |h| if (h.key == key) return;
    const p = pitchesFor(layout, key, octave, scale, chord_type);
    if (p == 0 or held_n >= MAX_HELD) return;
    held[held_n] = .{ .key = key, .pitches = p };
    held_n += 1;
}

// ── Recording ────────────────────────────────────────────────────────

/// A played note, in song beats.
pub const RecNote = struct { pitch: u8, start: f64, end: f64, velocity: u8 };

/// One recording pass: notes open on key presses and close on releases,
/// in song beats. A loop wrap closes what's held at the loop's end and
/// opens it again at its start.
pub const Take = struct {
    active: bool = false,
    /// The clip the pass writes (main's ClipRef: track, clip).
    target: ?[2]u32 = null,
    prev: u128 = 0,
    open: u128 = 0,
    open_start: [128]f64 = undefined,
    open_vel: [128]u8 = undefined,
    last_beat: f64 = 0,

    /// Keys already down when the pass starts aren't recorded.
    pub fn begin(self: *Take, held_now: u128, beat: f64) void {
        self.* = .{ .active = true, .prev = held_now, .last_beat = beat };
    }

    /// The notes that closed this frame go to `out` (room for 256).
    pub fn update(self: *Take, held_now: u128, vel: u8, beat: f64, out: []RecNote) usize {
        var n: usize = 0;
        if (beat + 1e-6 < self.last_beat) {
            const again = self.open & held_now;
            n += self.closeSet(self.open, self.last_beat, out[n..]);
            self.openSet(again, vel, beat);
        }
        n += self.closeSet(self.open & self.prev & ~held_now, beat, out[n..]);
        self.openSet(held_now & ~self.prev, vel, beat);
        self.prev = held_now;
        self.last_beat = beat;
        return n;
    }

    /// The pass ends: whatever's open closes where it stopped.
    pub fn finish(self: *Take, out: []RecNote) usize {
        const n = self.closeSet(self.open, self.last_beat, out);
        self.* = .{};
        return n;
    }

    fn openSet(self: *Take, set: u128, vel: u8, beat: f64) void {
        if (set == 0) return;
        for (0..128) |p| if (set & (@as(u128, 1) << @intCast(p)) != 0) {
            self.open_start[p] = beat;
            self.open_vel[p] = vel;
        };
        self.open |= set;
    }

    fn closeSet(self: *Take, set: u128, beat: f64, out: []RecNote) usize {
        if (set == 0) return 0;
        var n: usize = 0;
        for (0..128) |p| if (set & (@as(u128, 1) << @intCast(p)) != 0 and n < out.len) {
            out[n] = .{ .pitch = @intCast(p), .start = self.open_start[p], .end = beat, .velocity = self.open_vel[p] };
            n += 1;
        };
        self.open &= ~set;
        return n;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn only(set: u128) i32 {
    return @intCast(@ctz(set));
}

test "piano row is chromatic from the base C" {
    try testing.expectEqual(@as(i32, 60), only(pitchesFor(.piano, c.rl.KEY_A, 4, .{}, .triad)));
    try testing.expectEqual(@as(i32, 61), only(pitchesFor(.piano, c.rl.KEY_W, 4, .{}, .triad)));
    try testing.expectEqual(@as(i32, 72), only(pitchesFor(.piano, c.rl.KEY_K, 4, .{}, .triad)));
    try testing.expectEqual(@as(i32, 48), only(pitchesFor(.piano, c.rl.KEY_A, 3, .{}, .triad)));
    try testing.expectEqual(@as(u128, 0), pitchesFor(.piano, c.rl.KEY_Q, 4, .{}, .triad));
}

test "grid rows are fourths, in key with a scale" {
    // Chromatic: up a row is five semitones.
    try testing.expectEqual(@as(i32, 60), only(pitchesFor(.grid, c.rl.KEY_Z, 4, .{}, .triad)));
    try testing.expectEqual(@as(i32, 65), only(pitchesFor(.grid, c.rl.KEY_A, 4, .{}, .triad)));
    try testing.expectEqual(@as(i32, 61), only(pitchesFor(.grid, c.rl.KEY_X, 4, .{}, .triad)));
    // D major: Z = D, X = E, A = G (three steps up), 1 = F#5 (nine up).
    const d_major = Scale{ .root = 2, .mask = MAJOR, .on = true };
    try testing.expectEqual(@as(i32, 62), only(pitchesFor(.grid, c.rl.KEY_Z, 4, d_major, .triad)));
    try testing.expectEqual(@as(i32, 64), only(pitchesFor(.grid, c.rl.KEY_X, 4, d_major, .triad)));
    try testing.expectEqual(@as(i32, 67), only(pitchesFor(.grid, c.rl.KEY_A, 4, d_major, .triad)));
    try testing.expectEqual(@as(i32, 78), only(pitchesFor(.grid, c.rl.KEY_ONE, 4, d_major, .triad)));
}

test "chord row plays diatonic chords under the melody" {
    const c_major = Scale{ .root = 0, .mask = MAJOR, .on = true };
    // Z = C major an octave down, X = D minor, B (V) = G7 with 7TH.
    try testing.expectEqual(bit(48) | bit(52) | bit(55), pitchesFor(.chord, c.rl.KEY_Z, 4, c_major, .triad));
    try testing.expectEqual(bit(50) | bit(53) | bit(57), pitchesFor(.chord, c.rl.KEY_X, 4, c_major, .triad));
    try testing.expectEqual(bit(55) | bit(59) | bit(62) | bit(65), pitchesFor(.chord, c.rl.KEY_B, 4, c_major, .seventh));
    // A minor: Z = A minor triad.
    const a_minor = Scale{ .root = 9, .mask = 0b010110101101, .on = true };
    try testing.expectEqual(bit(57) | bit(60) | bit(64), pitchesFor(.chord, c.rl.KEY_Z, 4, a_minor, .triad));
    // The melody rows: A = root, Q = an octave up.
    try testing.expectEqual(@as(i32, 60), only(pitchesFor(.chord, c.rl.KEY_A, 4, c_major, .triad)));
    try testing.expectEqual(@as(i32, 62), only(pitchesFor(.chord, c.rl.KEY_S, 4, c_major, .triad)));
    try testing.expectEqual(@as(i32, 72), only(pitchesFor(.chord, c.rl.KEY_Q, 4, c_major, .triad)));
    // Scale off: major on the root.
    try testing.expectEqual(bit(48) | bit(52) | bit(55), pitchesFor(.chord, c.rl.KEY_Z, 4, .{}, .triad));
    try testing.expectEqual(@as(u128, 0), pitchesFor(.chord, c.rl.KEY_ONE, 4, c_major, .triad));
}

test "degrees wrap across octaves both ways" {
    try testing.expectEqual(@as(i32, 72), degreePitch(60, MAJOR, 7));
    try testing.expectEqual(@as(i32, 59), degreePitch(60, MAJOR, -1));
    try testing.expectEqual(@as(i32, 48), degreePitch(60, MAJOR, -7));
}

test "layouts claim their keys and the controls" {
    try testing.expect(layoutClaims(.piano, c.rl.KEY_S));
    try testing.expect(layoutClaims(.piano, c.rl.KEY_Z));
    try testing.expect(!layoutClaims(.piano, c.rl.KEY_Q));
    try testing.expect(layoutClaims(.grid, c.rl.KEY_Q));
    try testing.expect(layoutClaims(.chord, c.rl.KEY_ZERO));
    try testing.expect(layoutClaims(.grid, c.rl.KEY_LEFT_BRACKET));
    try testing.expect(!layoutClaims(.grid, c.rl.KEY_SPACE));
    try testing.expect(!layoutClaims(.grid, c.rl.KEY_TAB));
}

test "velocity steps through the fixed ladder" {
    const saved = velocity;
    defer velocity = saved;
    velocity = 100;
    stepVelocity(1);
    try testing.expectEqual(@as(u8, 127), velocity);
    stepVelocity(1);
    try testing.expectEqual(@as(u8, 127), velocity);
    stepVelocity(-1);
    try testing.expectEqual(@as(u8, 100), velocity);
    velocity = 90;
    stepVelocity(-1);
    try testing.expectEqual(@as(u8, 80), velocity);
}

test "a take records presses and releases, and splits at a loop wrap" {
    var t: Take = .{};
    var out: [256]RecNote = undefined;
    t.begin(bit(50), 0); // held before the pass: not recorded
    try testing.expectEqual(@as(usize, 0), t.update(bit(50) | bit(60), 90, 1, &out));
    try testing.expectEqual(@as(usize, 0), t.update(bit(60) | bit(64), 90, 2, &out));
    var n = t.update(bit(64), 90, 3, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(RecNote{ .pitch = 60, .start = 1, .end = 3, .velocity = 90 }, out[0]);
    // The loop wraps from 3.9 to 0.1: 64 closes at 3.9 and opens again.
    _ = t.update(bit(64), 90, 3.9, &out);
    n = t.update(bit(64), 90, 0.1, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(RecNote{ .pitch = 64, .start = 2, .end = 3.9, .velocity = 90 }, out[0]);
    n = t.finish(&out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(RecNote{ .pitch = 64, .start = 0.1, .end = 0.1, .velocity = 90 }, out[0]);
    try testing.expect(!t.active);
}
