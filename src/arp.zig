//! Arpeggiator: a note machine that sits ahead of a track's instrument
//! (docs/45). Held notes go in, a rhythmic sequence of notes comes out,
//! locked to the song's beat grid whether or not the transport rolls.
//!
//! The parameters are atomics the UI writes; everything else (`held`,
//! the step counter, the sounding notes) belongs to the audio thread,
//! which runs `process` once per track per block. Nothing allocates:
//! the output buffer lives in the struct.

const std = @import("std");
const machine = @import("machine.zig");

const NoteEvent = machine.NoteEvent;

pub const MAX_HELD = 16;
pub const OCTAVES_MAX = 4;
pub const MAX_SEQ = MAX_HELD * OCTAVES_MAX;
pub const MAX_STEPS = 16;
pub const MAX_OUT = 512;
/// Ids the arp gives its notes start here, clear of clip and live ids.
const ID_BASE: i32 = 1 << 24;

pub const Mode = enum(u8) { up, down, up_down, down_up, converge, diverge, random, played, chord };
pub const MODE_LABELS = [_][]const u8{ "UP", "DOWN", "UP-DN", "DN-UP", "CONV", "DIV", "RAND", "PLAYED", "CHORD" };

/// Step lengths in beats (quarter notes).
pub const RATE_BEATS = [_]f64{ 1.0, 0.75, 0.5, 1.0 / 3.0, 0.375, 0.25, 1.0 / 6.0, 0.125 };
pub const RATE_LABELS = [_][]const u8{ "1/4", "1/8.", "1/8", "1/8T", "1/16.", "1/16", "1/16T", "1/32" };
pub const DEFAULT_RATE: u32 = 5;

pub const VelMode = enum(u8) { played, fixed };
pub const VEL_LABELS = [_][]const u8{ "PLAYED", "FIXED" };

/// What one step of the pattern does.
pub const Cell = enum(u2) { rest, note, accent, tie };
pub const CELL_LABELS = [_][]const u8{ "-", "o", "O", "~" };

pub const ALL_NOTES: u32 = blk: {
    var p: u32 = 0;
    for (0..MAX_STEPS) |i| p |= @as(u32, @intFromEnum(Cell.note)) << @intCast(2 * i);
    break :blk p;
};

pub const Arp = struct {
    // ── Parameters (UI writes, audio reads) ──────────────────────────
    on: std.atomic.Value(u32) = .init(1),
    mode: std.atomic.Value(u32) = .init(@intFromEnum(Mode.up)),
    rate: std.atomic.Value(u32) = .init(DEFAULT_RATE),
    octaves: std.atomic.Value(u32) = .init(1),
    gate_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.6))),
    swing_bits: std.atomic.Value(u32) = .init(0),
    vel_mode: std.atomic.Value(u32) = .init(@intFromEnum(VelMode.played)),
    vel_fixed: std.atomic.Value(u32) = .init(100),
    accent_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.5))),
    human_bits: std.atomic.Value(u32) = .init(0),
    latch: std.atomic.Value(u32) = .init(0),
    steps: std.atomic.Value(u32) = .init(MAX_STEPS),
    /// Two bits a step: a `Cell`.
    pattern: std.atomic.Value(u32) = .init(ALL_NOTES),

    /// The track has the slot (the bay shows it, the engine runs it).
    present: std.atomic.Value(u32) = .init(0),

    // ── Audio-thread state ───────────────────────────────────────────
    held: [MAX_HELD]Held = undefined,
    held_n: usize = 0,
    /// Latched and every key up: the next key starts a new set.
    fresh: bool = false,
    step_n: u32 = 0,
    next_k: i64 = 0,
    last_end: f64 = -1,
    act: [MAX_HELD]Sounding = undefined,
    act_n: usize = 0,
    off_beat: f64 = 0,
    next_id: i32 = ID_BASE,
    rng: u32 = 0x9E3779B9,
    was_on: bool = false,
    out: [MAX_OUT]NoteEvent = undefined,

    pub const Held = struct { pitch: u8, vel: u8, down: bool };
    const Sounding = struct { id: i32, pitch: u8 };

    pub fn getF(v: *const std.atomic.Value(u32)) f32 {
        return @bitCast(v.load(.monotonic));
    }

    pub fn setF(v: *std.atomic.Value(u32), x: f32) void {
        v.store(@bitCast(x), .monotonic);
    }

    pub fn cell(self: *const Arp, i: usize) Cell {
        return @enumFromInt((self.pattern.load(.monotonic) >> @intCast(2 * i)) & 3);
    }

    pub fn setCell(self: *Arp, i: usize, c: Cell) void {
        const sh: u5 = @intCast(2 * i);
        const old = self.pattern.load(.monotonic);
        self.pattern.store((old & ~(@as(u32, 3) << sh)) | @as(u32, @intFromEnum(c)) << sh, .monotonic);
    }

    /// Notes are still held or sounding (the track stays awake).
    pub fn busy(self: *const Arp) bool {
        return self.held_n > 0 or self.act_n > 0;
    }

    /// The slot was taken away: end the notes it was sounding, ahead of
    /// `events[0..n]`, and forget the rest. Returns the new count.
    pub fn flush(self: *Arp, events: []NoteEvent, n: usize) usize {
        const k = @min(self.act_n, events.len - n);
        if (k > 0) {
            std.mem.copyBackwards(NoteEvent, events[k .. n + k], events[0..n]);
            for (self.act[0..k], 0..) |a, i| events[i] = noteEvent(.note_off, 0, a.id, a.pitch, 0);
        }
        self.reset();
        return n + k;
    }

    /// Forget everything held and sounding (a panic, a track coming back).
    pub fn reset(self: *Arp) void {
        self.held_n = 0;
        self.act_n = 0;
        self.fresh = false;
        self.step_n = 0;
        self.last_end = -1;
        self.was_on = false;
    }

    fn rand(self: *Arp) u32 {
        var x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        return x;
    }

    fn unit(self: *Arp) f32 {
        return @as(f32, @floatFromInt(self.rand() >> 8)) / 16777216.0;
    }

    fn emit(self: *Arp, n: *usize, ev: NoteEvent) void {
        if (n.* < MAX_OUT) {
            self.out[n.*] = ev;
            n.* += 1;
        }
    }

    fn noteEvent(kind: machine.NoteKind, off: u32, id: i32, pitch: u8, vel: f32) NoteEvent {
        return .{ .sample_offset = off, .kind = kind, .channel = 0, .note_id = id, .pitch = @floatFromInt(pitch), .velocity = vel };
    }

    fn releaseAll(self: *Arp, n: *usize, off: u32) void {
        for (self.act[0..self.act_n]) |a| self.emit(n, noteEvent(.note_off, off, a.id, a.pitch, 0));
        self.act_n = 0;
    }

    fn press(self: *Arp, pitch: u8, vel: u8, latch: bool) void {
        if (latch and self.fresh) {
            self.held_n = 0;
            self.fresh = false;
        }
        for (self.held[0..self.held_n]) |*h| if (h.pitch == pitch) {
            h.vel = vel;
            h.down = true;
            return;
        };
        if (self.held_n == MAX_HELD) return;
        self.held[self.held_n] = .{ .pitch = pitch, .vel = vel, .down = true };
        self.held_n += 1;
    }

    fn release(self: *Arp, pitch: u8, latch: bool) void {
        var i: usize = 0;
        while (i < self.held_n) : (i += 1) if (self.held[i].pitch == pitch) {
            if (latch) {
                self.held[i].down = false;
            } else {
                var j = i;
                while (j + 1 < self.held_n) : (j += 1) self.held[j] = self.held[j + 1];
                self.held_n -= 1;
            }
            break;
        };
        if (latch) {
            var any = false;
            for (self.held[0..self.held_n]) |h| any = any or h.down;
            if (!any) self.fresh = true;
        }
    }

    /// The pitches the held notes expand to, in the mode's base order, and
    /// how many.
    fn build(self: *const Arp, mode: Mode, octaves: u32, seq: *[MAX_SEQ]Held) usize {
        var base: [MAX_HELD]Held = undefined;
        @memcpy(base[0..self.held_n], self.held[0..self.held_n]);
        if (mode != .played) std.mem.sort(Held, base[0..self.held_n], {}, lessPitch);
        const oct = if (mode == .chord) 1 else std.math.clamp(octaves, 1, OCTAVES_MAX);
        var n: usize = 0;
        for (0..oct) |o| for (base[0..self.held_n]) |h| {
            const p = @as(u32, h.pitch) + 12 * @as(u32, @intCast(o));
            if (p > 127) continue;
            seq[n] = .{ .pitch = @intCast(p), .vel = h.vel, .down = true };
            n += 1;
        };
        return n;
    }

    fn lessPitch(_: void, a: Held, b: Held) bool {
        return a.pitch < b.pitch;
    }

    /// Where in a sequence of `len` the `n`-th step lands.
    pub fn index(mode: Mode, n: u32, len: usize, rnd: u32) usize {
        const l: u32 = @intCast(len);
        if (l <= 1) return 0;
        return switch (mode) {
            .up, .played, .chord => n % l,
            .down => l - 1 - n % l,
            .up_down => bounce(n, l),
            .down_up => l - 1 - bounce(n, l),
            .converge => converge(n % l, l),
            .diverge => converge(l - 1 - n % l, l),
            .random => rnd % l,
        };
    }

    fn bounce(n: u32, l: u32) usize {
        const period = 2 * l - 2;
        const m = n % period;
        return if (m < l) m else period - m;
    }

    /// 0, last, 1, last-1, ... : the outside in.
    fn converge(m: u32, l: u32) usize {
        return if (m % 2 == 0) m / 2 else l - 1 - m / 2;
    }

    fn stepBeat(k: i64, step: f64, swing: f32) f64 {
        const odd = @mod(k, 2) == 1;
        return @as(f64, @floatFromInt(k)) * step + if (odd) @as(f64, swing) * step else 0;
    }

    /// One block: `in` are the track's notes this block (sorted by offset),
    /// `ppq` the beat at its start. Returns the notes to play instead,
    /// sorted by offset; valid until the next call.
    pub fn process(self: *Arp, in: []const NoteEvent, ppq: f64, bpm: f64, sr: f64, frames: u32) []const NoteEvent {
        var n: usize = 0;
        if (self.on.load(.monotonic) == 0) {
            if (self.was_on) {
                self.releaseAll(&n, 0);
                self.reset();
            }
            for (in) |ev| self.emit(&n, ev);
            return self.out[0..n];
        }
        self.was_on = true;

        const mode: Mode = @enumFromInt(@min(self.mode.load(.monotonic), @intFromEnum(Mode.chord)));
        const step = RATE_BEATS[@min(self.rate.load(.monotonic), RATE_BEATS.len - 1)];
        const octaves = self.octaves.load(.monotonic);
        const gate = std.math.clamp(getF(&self.gate_bits), 0.02, 1.0);
        const swing = std.math.clamp(getF(&self.swing_bits), 0, 0.75);
        const human = std.math.clamp(getF(&self.human_bits), 0, 1);
        const accent = std.math.clamp(getF(&self.accent_bits), 0, 1);
        const fixed = self.vel_mode.load(.monotonic) == @intFromEnum(VelMode.fixed);
        const fixed_vel: u8 = @intCast(std.math.clamp(self.vel_fixed.load(.monotonic), 1, 127));
        const latch = self.latch.load(.monotonic) != 0;
        const plen: u32 = std.math.clamp(self.steps.load(.monotonic), 1, MAX_STEPS);

        if (!latch and self.fresh) {
            // Latch went off: let go of what only it was holding.
            var i: usize = 0;
            while (i < self.held_n) {
                if (self.held[i].down) i += 1 else {
                    self.held[i] = self.held[self.held_n - 1];
                    self.held_n -= 1;
                }
            }
            self.fresh = false;
        }

        const bps = bpm / 60.0 / sr;
        const end = ppq + @as(f64, @floatFromInt(frames)) * bps;
        // A jump (a seek, a loop wrap, the first block): find the next step.
        if (self.last_end < 0 or @abs(ppq - self.last_end) > 1e-6) {
            self.next_k = @intFromFloat(@ceil(ppq / step - 1e-9));
        }
        self.last_end = end;

        var i: usize = 0;
        const inf = std.math.inf(f64);
        while (true) {
            const ev_off: f64 = if (i < in.len) @floatFromInt(in[i].sample_offset) else inf;
            const step_off = (stepBeat(self.next_k, step, swing) - ppq) / bps;
            const off_off: f64 = if (self.act_n > 0) (self.off_beat - ppq) / bps else inf;
            const t = @min(ev_off, @min(step_off, off_off));
            if (t >= @as(f64, @floatFromInt(frames))) break;
            const at: u32 = @intFromFloat(std.math.clamp(@round(t), 0, @as(f64, @floatFromInt(frames - 1))));

            if (off_off <= ev_off and off_off <= step_off) {
                self.releaseAll(&n, at);
            } else if (ev_off <= step_off) {
                const ev = in[i];
                i += 1;
                switch (ev.kind) {
                    .note_on => if (ev.velocity > 0 and ev.pitch >= 0 and ev.pitch < 128) {
                        const v: u8 = @intFromFloat(std.math.clamp(@round(ev.velocity * 127), 1, 127));
                        if (self.held_n == 0 or (latch and self.fresh)) self.step_n = 0;
                        self.press(@intFromFloat(@round(ev.pitch)), v, latch);
                    },
                    .note_off => if (ev.pitch >= 0 and ev.pitch < 128) self.release(@intFromFloat(@round(ev.pitch)), latch),
                    else => self.emit(&n, ev),
                }
            } else {
                const k = self.next_k;
                self.next_k += 1;
                self.playStep(&n, at, k, step, gate, .{ .mode = mode, .octaves = octaves, .plen = plen, .accent = accent, .fixed = fixed, .fixed_vel = fixed_vel, .human = human }, ppq + t * bps);
            }
        }
        // Any input events past the loop's end can't exist (offsets < frames).
        return self.out[0..n];
    }

    const StepParams = struct { mode: Mode, octaves: u32, plen: u32, accent: f32, fixed: bool, fixed_vel: u8, human: f32 };

    fn playStep(self: *Arp, n: *usize, at: u32, k: i64, step: f64, gate: f32, p: StepParams, now: f64) void {
        _ = k;
        const c = self.cell(self.step_n % p.plen);
        if (c == .tie and self.act_n > 0) {
            // The sounding notes hold through this step.
            self.off_beat = now + step * @as(f64, gate);
            self.step_n +%= 1;
            return;
        }
        var seq: [MAX_SEQ]Held = undefined;
        const len = self.build(p.mode, p.octaves, &seq);
        if (len == 0) return;
        self.step_n +%= 1;
        if (c == .rest or c == .tie) return;

        // The previous step's notes end where this one starts.
        self.releaseAll(n, at);
        const rnd = self.rand();
        const first = index(p.mode, self.step_n - 1, len, rnd);
        const count: usize = if (p.mode == .chord) len else 1;
        for (0..count) |j| {
            const h = seq[if (p.mode == .chord) j else first];
            var v: f32 = @floatFromInt(if (p.fixed) p.fixed_vel else h.vel);
            if (c == .accent) v += (127 - v) * p.accent;
            if (p.human > 0) v += (self.unit() * 2 - 1) * 24 * p.human;
            v = std.math.clamp(@round(v), 1, 127);
            const id = self.next_id;
            self.next_id = if (self.next_id == std.math.maxInt(i32)) ID_BASE else self.next_id + 1;
            self.emit(n, noteEvent(.note_on, at, id, h.pitch, v / 127.0));
            if (self.act_n < MAX_HELD) {
                self.act[self.act_n] = .{ .id = id, .pitch = h.pitch };
                self.act_n += 1;
            }
        }
        self.off_beat = now + step * @as(f64, gate);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const SR = 48000.0;

fn noteOn(at: u32, pitch: f32, vel: f32) NoteEvent {
    return .{ .sample_offset = at, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = pitch, .velocity = vel };
}

fn noteOff(o: u32, pitch: f32) NoteEvent {
    return .{ .sample_offset = o, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = pitch, .velocity = 0 };
}

/// The note-on pitches in `evs`, in order.
fn pitches(evs: []const NoteEvent, buf: []f32) []f32 {
    var n: usize = 0;
    for (evs) |e| if (e.kind == .note_on) {
        buf[n] = e.pitch;
        n += 1;
    };
    return buf[0..n];
}

/// Run `blocks` blocks of `frames` from beat 0 at `bpm`, the first
/// carrying `first`, appending every output note-on pitch.
fn run(a: *Arp, first: []const NoteEvent, blocks: usize, frames: u32, bpm: f64, got: []f32) usize {
    var n: usize = 0;
    var ppq: f64 = 0;
    for (0..blocks) |b| {
        const evs = a.process(if (b == 0) first else &.{}, ppq, bpm, SR, frames);
        for (evs) |e| if (e.kind == .note_on) {
            got[n] = e.pitch;
            n += 1;
        };
        ppq += @as(f64, @floatFromInt(frames)) * bpm / 60.0 / SR;
    }
    return n;
}

fn chordC() [3]NoteEvent {
    // Held in a scrambled order: E, C, G.
    return .{ noteOn(0, 64, 0.8), noteOn(0, 60, 0.8), noteOn(0, 67, 0.8) };
}

test "index: the shapes of each mode" {
    const L = 4;
    var got: [8]usize = undefined;
    for (0..8) |n| got[n] = Arp.index(.up_down, @intCast(n), L, 0);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 2, 1, 0, 1 }, &got);
    for (0..8) |n| got[n] = Arp.index(.down_up, @intCast(n), L, 0);
    try testing.expectEqualSlices(usize, &.{ 3, 2, 1, 0, 1, 2, 3, 2 }, &got);
    for (0..4) |n| got[n] = Arp.index(.converge, @intCast(n), L, 0);
    try testing.expectEqualSlices(usize, &.{ 0, 3, 1, 2 }, got[0..4]);
    for (0..4) |n| got[n] = Arp.index(.diverge, @intCast(n), L, 0);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 3, 0 }, got[0..4]);
    for (0..4) |n| got[n] = Arp.index(.down, @intCast(n), L, 0);
    try testing.expectEqualSlices(usize, &.{ 3, 2, 1, 0 }, got[0..4]);
    try testing.expectEqual(@as(usize, 0), Arp.index(.up_down, 5, 1, 0));
}

test "up arpeggiates ascending on the sixteenth grid, held notes re-sorted" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    var got: [32]f32 = undefined;
    const c = chordC();
    // One second at 120 BPM = 2 beats = eight sixteenths.
    const n = run(a, &c, 1, 48000, 120, &got);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualSlices(f32, &.{ 60, 64, 67, 60, 64, 67, 60, 64 }, got[0..n]);
}

test "steps land on the grid with gate-length notes" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    Arp.setF(&a.gate_bits, 0.5);
    const c = [_]NoteEvent{noteOn(0, 60, 1)};
    const evs = a.process(&c, 0, 120, SR, 48000);
    // A sixteenth at 120 BPM is 6000 samples; gate 0.5 ends at 3000.
    try testing.expectEqual(@as(u32, 0), evs[0].sample_offset);
    try testing.expectEqual(machine.NoteKind.note_off, evs[1].kind);
    try testing.expectEqual(@as(u32, 3000), evs[1].sample_offset);
    try testing.expectEqual(machine.NoteKind.note_on, evs[2].kind);
    try testing.expectEqual(@as(u32, 6000), evs[2].sample_offset);
    // Every note off matches the id of its note on.
    try testing.expectEqual(evs[0].note_id, evs[1].note_id);
}

test "octaves stack the sequence upward" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    a.octaves.store(2, .monotonic);
    const c = [_]NoteEvent{ noteOn(0, 60, 1), noteOn(0, 64, 1) };
    var got: [16]f32 = undefined;
    const n = run(a, &c, 1, 48000, 120, &got);
    try testing.expectEqualSlices(f32, &.{ 60, 64, 72, 76, 60, 64, 72, 76 }, got[0..n]);
}

test "chord mode plays everything on each step" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    a.mode.store(@intFromEnum(Mode.chord), .monotonic);
    a.rate.store(2, .monotonic); // 1/8
    const c = chordC();
    const evs = a.process(&c, 0, 120, SR, 24000); // one beat: two eighths
    var buf: [16]f32 = undefined;
    try testing.expectEqualSlices(f32, &.{ 60, 64, 67, 60, 64, 67 }, pitches(evs, &buf));
}

test "releasing every key stops new steps; the last note still ends" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    const first = [_]NoteEvent{ noteOn(0, 60, 1), noteOff(100, 60) };
    var got: [16]f32 = undefined;
    const n = run(a, &first, 2, 24000, 120, &got);
    // The note on at step 0 played; the key was up before step 1.
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 0), a.act_n);
}

test "latch keeps the notes until a new key is pressed after all are up" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    a.latch.store(1, .monotonic);
    const first = [_]NoteEvent{ noteOn(0, 60, 1), noteOn(0, 64, 1), noteOff(100, 60), noteOff(100, 64) };
    var got: [32]f32 = undefined;
    var n = run(a, &first, 1, 48000, 120, &got);
    try testing.expectEqual(@as(usize, 8), n); // still arpeggiating
    try testing.expect(a.fresh);
    // A new key replaces the latched pair.
    const evs = a.process(&.{noteOn(0, 55, 1)}, 2.0, 120, SR, 6000);
    var buf: [4]f32 = undefined;
    try testing.expectEqualSlices(f32, &.{55}, pitches(evs, &buf));
    n = a.held_n;
    try testing.expectEqual(@as(usize, 1), n);
}

test "rests skip a step, ties hold the note through it, accents hit harder" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    a.steps.store(4, .monotonic);
    a.setCell(1, .rest);
    a.setCell(2, .tie);
    a.setCell(3, .accent);
    Arp.setF(&a.gate_bits, 0.5);
    Arp.setF(&a.accent_bits, 1.0);
    const c = [_]NoteEvent{noteOn(0, 60, 0.5)};
    const evs = a.process(&c, 0, 120, SR, 24000); // four sixteenths
    var ons: usize = 0;
    var last_vel: f32 = 0;
    for (evs) |e| if (e.kind == .note_on) {
        ons += 1;
        last_vel = e.velocity;
    };
    // Step 0 plays, 1 rests, 2 ties (nothing sounds then: no note to hold
    // after the gate ended), 3 is the accent at full velocity.
    try testing.expectEqual(@as(usize, 2), ons);
    try testing.expectEqual(@as(f32, 1.0), last_vel);
}

test "swing delays the odd steps" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    Arp.setF(&a.swing_bits, 0.5);
    const c = [_]NoteEvent{noteOn(0, 60, 1)};
    const evs = a.process(&c, 0, 120, SR, 12000);
    var offs: [4]u32 = undefined;
    var n: usize = 0;
    for (evs) |e| if (e.kind == .note_on) {
        offs[n] = e.sample_offset;
        n += 1;
    };
    // Steps 0, 1 at 0 and 6000 + half a step.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 0), offs[0]);
    try testing.expectEqual(@as(u32, 9000), offs[1]);
}

test "bypass passes notes through and lets go of the arp's own" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    _ = a.process(&.{noteOn(0, 60, 1)}, 0, 120, SR, 1000);
    try testing.expect(a.act_n > 0);
    a.on.store(0, .monotonic);
    const evs = a.process(&.{noteOn(10, 72, 1)}, 0, 120, SR, 1000);
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expectEqual(machine.NoteKind.note_off, evs[0].kind);
    try testing.expectEqual(@as(f32, 72), evs[1].pitch);
    try testing.expect(!a.busy());
}

test "flush ends the sounding notes ahead of the block's own" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    _ = a.process(&.{noteOn(0, 60, 1)}, 0, 120, SR, 1000);
    var evs: [4]NoteEvent = undefined;
    evs[0] = noteOn(5, 72, 1);
    const n = a.flush(&evs, 1);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(machine.NoteKind.note_off, evs[0].kind);
    try testing.expectEqual(@as(f32, 60), evs[0].pitch);
    try testing.expectEqual(@as(f32, 72), evs[1].pitch);
    try testing.expect(!a.busy());
}

test "a seek re-finds the grid" {
    const a = try testing.allocator.create(Arp);
    defer testing.allocator.destroy(a);
    a.* = .{};
    _ = a.process(&.{noteOn(0, 60, 1)}, 0, 120, SR, 1000);
    // Jump to beat 10.1: the next sixteenth is 10.25, (0.15 beats) away.
    const evs = a.process(&.{}, 10.1, 120, SR, 24000);
    var first: ?u32 = null;
    for (evs) |e| if (e.kind == .note_on and first == null) {
        first = e.sample_offset;
    };
    try testing.expectEqual(@as(u32, 3600), first.?);
}
