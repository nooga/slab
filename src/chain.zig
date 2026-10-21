//! Chain: an instrument and a bounded insert chain, published from UI to
//! audio as one value (docs/42 §Model). The owner (a track, later a rack
//! lane) keeps the editable instrument and effect list; `State` holds what
//! crosses threads: the latest-value handoff, the retirement queue, the
//! audio thread's adopted copy and the dry lines bypassed latent effects
//! keep their latency in.
//!
//! UI prepares and publishes complete chains; audio owns its adopted chain
//! until the next adoption. Replaced machines retire on UI only after audio
//! acknowledges a chain without them.

const std = @import("std");
const machine = @import("machine.zig");
const routing = @import("routing.zig");
const handoff = @import("handoff.zig");

/// One slot in an insert chain: the effect machine, its registry index
/// (for persistence/forward-compat), and a per-effect bypass flag. UI
/// bypass edits publish with the complete chain; audio reads its adopted
/// copy. The editable ArrayList and its allocations are never traversed by
/// a render worker. Peak telemetry uses stable atomic storage shared by
/// both copies.
pub const Effect = struct {
    mach: machine.Machine,
    idx: ?u8 = null,
    /// Stable per-chain id that automation lanes address (docs/22 §Targets):
    /// it survives reordering the chain.
    uid: u16 = 0,
    version: u64 = 0,
    bypass: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Sidechain key (docs/23 §Sidechain keys): the track whose pre tap
    /// drives this effect's detector, or routing.NONE.
    key: u8 = routing.NONE,
    /// Block peaks the engine writes after each render and the bay's I/O
    /// meters read: in L, in R, out L, out R, as f32 bits.
    shared_io: ?*[4]std.atomic.Value(u32) = null,
    io_peak: [4]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0)),
    /// Audio thread: samples its input and output have both been silent,
    /// saturating; past the machine's hold it isn't rendered (docs/04
    /// §Idle skipping).
    quiet: u32 = 0,
    /// Audio thread (docs/07 §Declicking): the wet share the last chunk
    /// ended on; bypass crossfades it to 0 and back over a chunk.
    wet: f32 = 1,
    /// Audio thread: the dry line holding this bypassed effect's latency
    /// (-1: none). With one, the effect keeps rendering while bypassed and
    /// its dry path is delayed by its latency, so bypass neither re-times
    /// the PDC graph nor brings back stale buffers.
    dry_line: i8 = -1,

    pub fn setIo(self: *Effect, in: [2]f32, out: [2]f32) void {
        const v = [4]f32{ in[0], in[1], out[0], out[1] };
        for (self.shared_io orelse &self.io_peak, v) |*a, x| a.store(@bitCast(x), .monotonic);
    }

    pub fn io(self: *const Effect) struct { in: [2]f32, out: [2]f32 } {
        var v: [4]f32 = undefined;
        for (&v, self.shared_io orelse &self.io_peak) |*x, *a| x.* = @bitCast(a.load(.monotonic));
        return .{ .in = .{ v[0], v[1] }, .out = .{ v[2], v[3] } };
    }
};

pub const MAX_EFFECTS: usize = 128;
pub const DRY_LINES = 4;
/// A dry line's length: the largest latency it can hold, a power of two.
pub const DRY_LEN = 8192;
pub const DryLine = struct { l: [DRY_LEN]f32, r: [DRY_LEN]f32, w: usize };

const Retired = struct { mach: machine.Machine, io: ?*[4]std.atomic.Value(u32) = null };
const Published = struct { instrument: machine.Machine, effects: [MAX_EFFECTS]Effect = undefined, count: usize = 0, generation: u64 = 0, instrument_generation: u64 = 0 };
const PublishedEffect = struct { uid: u16, version: u64, bypass: bool };

/// What crosses threads for one chain. Large (the effect arrays and the dry
/// lines), so the owner heap-allocates it with `create`.
pub const State = struct {
    latest: handoff.Latest(Published),
    retired: handoff.Retirement(Retired, 128) = .{},

    // UI side.
    generation: u64 = 0,
    instrument_generation: u64 = 0,
    published_instrument_generation: u64 = std.math.maxInt(u64),
    published_count: usize = std.math.maxInt(usize),
    published_effects: [MAX_EFFECTS]PublishedEffect = undefined,
    next_uid: u16 = 1,

    // Audio side.
    audio_machine: machine.Machine,
    audio_instrument_generation: u64 = 0,
    audio_effects: [MAX_EFFECTS]Effect = undefined,
    audio_effect_count: usize = 0,
    previous_effects: [MAX_EFFECTS]Effect = undefined,
    /// Delay lines for bypassed latent effects (Effect.dry_line), touched
    /// on UI at creation so audio never takes their first faults.
    dry: [DRY_LINES]DryLine = undefined,
    dry_used: u8 = 0,

    pub fn create(alloc: std.mem.Allocator, instrument: machine.Machine) !*State {
        const s = try alloc.create(State);
        s.* = .{ .latest = .init(.{ .instrument = instrument }), .audio_machine = instrument };
        @memset(std.mem.asBytes(&s.dry), 0);
        return s;
    }

    /// Frees the machines waiting to retire and the state itself; the
    /// owner frees its live instrument and effects.
    pub fn destroy(self: *State, alloc: std.mem.Allocator) void {
        self.retired.drain(alloc, dispose);
        alloc.destroy(self);
    }

    fn dispose(alloc: std.mem.Allocator, old: Retired) void {
        if (old.mach.deinit) |d| d(old.mach.state, alloc);
        if (old.io) |io| alloc.destroy(io);
    }

    // ---- UI thread ----

    pub fn collect(self: *State, alloc: std.mem.Allocator) void {
        self.retired.collect(alloc, dispose);
    }

    fn reserve(self: *State, alloc: std.mem.Allocator) !void {
        self.collect(alloc);
        if (!self.retired.available()) return error.PublicationFull;
    }

    /// Publish the chain if it differs from the last one published.
    pub fn publish(self: *State, instrument: machine.Machine, effects: []Effect) void {
        var changed = self.published_instrument_generation != self.instrument_generation or self.published_count != effects.len;
        if (!changed) for (effects, 0..) |*fx, i| {
            const old = self.published_effects[i];
            if (old.uid != fx.uid or old.version != fx.version or old.bypass != fx.bypass.load(.monotonic)) {
                changed = true;
                break;
            }
        };
        if (!changed) return;
        self.published_instrument_generation = self.instrument_generation;
        self.published_count = effects.len;
        self.generation += 1;
        const v = self.latest.write();
        v.instrument = instrument;
        v.instrument_generation = self.instrument_generation;
        v.generation = self.generation;
        v.count = effects.len;
        std.debug.assert(v.count <= MAX_EFFECTS);
        for (effects, 0..) |*fx, i| {
            const bypass = fx.bypass.load(.monotonic);
            v.effects[i] = .{ .mach = fx.mach, .idx = fx.idx, .uid = fx.uid, .version = fx.version, .key = fx.key, .shared_io = fx.shared_io };
            v.effects[i].bypass.store(bypass, .monotonic);
            self.published_effects[i] = .{ .uid = fx.uid, .version = fx.version, .bypass = bypass };
        }
        self.latest.publish();
    }

    /// Swap the instrument; the old one retires once audio lets go of it.
    pub fn replaceInstrument(self: *State, alloc: std.mem.Allocator, instrument: *machine.Machine, effects: []Effect, mach: machine.Machine) !void {
        try self.reserve(alloc);
        const old = instrument.*;
        instrument.* = mach;
        self.instrument_generation += 1;
        self.publish(instrument.*, effects);
        self.retired.append(self.generation, .{ .mach = old });
    }

    pub fn addEffect(self: *State, alloc: std.mem.Allocator, instrument: machine.Machine, effects: *std.ArrayList(Effect), mach: machine.Machine, idx: u8) !void {
        if (effects.items.len >= MAX_EFFECTS) return error.TooManyEffects;
        const io = try alloc.create([4]std.atomic.Value(u32));
        errdefer alloc.destroy(io);
        io.* = @splat(.init(0));
        try effects.append(alloc, .{ .mach = mach, .idx = idx, .uid = self.next_uid, .shared_io = io });
        // 0 is no insert: a rack lane's instrument in automation paths.
        self.next_uid +%= 1;
        if (self.next_uid == 0) self.next_uid = 1;
        self.publish(instrument, effects.items);
    }

    pub fn removeEffect(self: *State, alloc: std.mem.Allocator, instrument: machine.Machine, effects: *std.ArrayList(Effect), i: usize) !void {
        if (i >= effects.items.len) return;
        try self.reserve(alloc);
        const old = effects.orderedRemove(i);
        self.publish(instrument, effects.items);
        self.retired.append(self.generation, .{ .mach = old.mach, .io = old.shared_io });
    }

    pub fn moveEffect(self: *State, instrument: machine.Machine, effects: *std.ArrayList(Effect), from: usize, to: usize) void {
        const n = effects.items.len;
        if (from >= n or to >= n or from == to) return;
        const e = effects.orderedRemove(from);
        effects.insertAssumeCapacity(@min(to, effects.items.len), e);
        self.publish(instrument, effects.items);
    }

    pub fn replaceEffect(self: *State, alloc: std.mem.Allocator, instrument: machine.Machine, effects: []Effect, i: usize, mach: machine.Machine, idx: u8) !void {
        if (i >= effects.len) return error.InvalidEffect;
        try self.reserve(alloc);
        const slot = &effects[i];
        const old = slot.mach;
        slot.mach = mach;
        slot.idx = idx;
        slot.version += 1;
        self.publish(instrument, effects);
        self.retired.append(self.generation, .{ .mach = old });
    }

    // ---- audio thread ----

    /// Take the newest published chain, if there is one; `apply` makes it
    /// the one that renders.
    pub fn adopt(self: *State) bool {
        if (!self.latest.adopt()) return false;
        machine.codeBarrier();
        return true;
    }

    /// The adopted version swaps the instrument or the inserts, not only
    /// bypass states.
    pub fn changes(self: *State) bool {
        const v = self.latest.current();
        if (v.instrument_generation != self.audio_instrument_generation or v.count != self.audio_effect_count) return true;
        for (v.effects[0..v.count], self.audioEffects()) |a, b| {
            if (a.uid != b.uid or a.version != b.version) return true;
        }
        return false;
    }

    /// Render the adopted chain from now on, carrying each surviving
    /// effect's audio state over by uid and version. Returns whether the
    /// instrument changed.
    pub fn apply(self: *State) bool {
        const v = self.latest.current();
        const previous = self.previous_effects[0..self.audio_effect_count];
        @memcpy(previous, self.audioEffects());
        for (v.effects[0..v.count], 0..) |fx, i| {
            const e = &self.audio_effects[i];
            e.* = fx;
            const bypass = fx.bypass.load(.monotonic);
            // New here: it starts where it stands, no fade.
            e.wet = if (bypass) 0 else 1;
            e.dry_line = -1;
            for (previous) |old| if (old.uid == fx.uid and old.version == fx.version) {
                e.quiet = old.quiet;
                e.wet = old.wet;
                e.dry_line = old.dry_line;
                const was = old.bypass.load(.monotonic);
                if (bypass and !was and e.dry_line < 0 and e.mach.latencySamples() > 0) {
                    // Keep its latency through the bypass (a free line, else
                    // the old way: the graph re-times).
                    if (@ctz(~self.dry_used) < DRY_LINES) {
                        const k: u3 = @intCast(@ctz(~self.dry_used));
                        e.dry_line = k;
                        self.dry_used |= @as(u8, 1) << k;
                        @memset(&self.dry[k].l, 0);
                        @memset(&self.dry[k].r, 0);
                        self.dry[k].w = 0;
                    }
                }
                // Back from a bypass it was not rendered through: its
                // buffers hold audio from before; start it clean.
                if (!bypass and was and e.dry_line < 0) e.mach.reset(e.mach.state);
                break;
            };
        }
        // Lines held by effects that are gone are free again.
        var used: u8 = 0;
        for (self.audio_effects[0..v.count]) |e| if (e.dry_line >= 0) {
            used |= @as(u8, 1) << @intCast(e.dry_line);
        };
        self.dry_used = used;
        const new_instrument = self.audio_instrument_generation != v.instrument_generation;
        self.audio_instrument_generation = v.instrument_generation;
        self.audio_machine = v.instrument;
        self.audio_effect_count = v.count;
        self.retired.acknowledge(v.generation);
        return new_instrument;
    }

    pub fn audioEffects(self: *State) []Effect {
        return self.audio_effects[0..self.audio_effect_count];
    }
};
