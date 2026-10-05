//! Audio engine: gathers clip notes per block, dispatches to each
//! track's machine with a MachineCtx (channel-planar audio out, sorted
//! note_in), sums to master, writes interleaved stereo to the device.
//! No allocation on the audio thread.

const std = @import("std");
const audio = @import("audio.zig");
const machine = @import("machine.zig");
const Transport = @import("transport.zig").Transport;
const Track = @import("track.zig").Track;
const snap_mod = @import("snapshot.zig");
const meter = @import("meter.zig");
const tempo = @import("tempo.zig");
const groove_mod = @import("groove.zig");
const warp_mod = @import("warp.zig");
const stretch_mod = @import("stretch.zig");
const automation = @import("automation.zig");
const routing = @import("routing.zig");
const render_pool = @import("render_pool.zig");
const fy_host = @import("fy_host.zig");

pub const MAX_BLOCK = audio.BLOCK_FRAMES * 4;
pub const MAX_EVENTS_PER_TRACK = 1024;
/// Expression events for a bent note go out every this many samples while
/// it sounds (docs/22 §Note expression): 0.67 ms at 48 kHz.
pub const EXPR_STEP: u32 = 32;

/// Idle skipping (docs/04 §Idle skipping): a block whose peak is at or
/// under this is silence (−120 dBFS).
pub const IDLE_FLOOR: f32 = 1e-6;
/// How long a machine's input and output must stay silent before it is
/// skipped, unless its latency and tail are longer.
const IDLE_HOLD_S: f32 = 0.25;
/// An idle instrument wakes this far ahead of its next note, so its
/// smoothed controls settle on the automation before the note (the
/// smoothing is 20 ms, docs/22) and its chain renders with it.
const IDLE_WAKE_AHEAD_S: f64 = 0.1;

/// Fallback meter state (constant 4/4) used until the document installs
/// its own. Module-level so the address is stable for the field default.
var default_meter_state: meter.MeterState = .{};

// Node states in a block (docs/07 §Parallel rendering).
const NODE_WAIT: u8 = 0;
const NODE_READY: u8 = 1;
const NODE_RUNNING: u8 = 2;
const NODE_DONE: u8 = 3;

/// A destination index for the master, after the buses.
const MASTER_DEST: usize = routing.MAX_TRACKS;
/// One sum into a destination: node `node`'s output, or its send `send`.
const OUTPUT: u8 = 0xff;
const Contrib = struct { node: u8, send: u8 };

/// One render thread's buffers: the insert chain's ping-pong partner and
/// the block's events for the node it renders.
pub const Scratch = struct {
    fx_l: [MAX_BLOCK]f32,
    fx_r: [MAX_BLOCK]f32,
    events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent,
};

/// What every node of the block renders against; written before the block
/// opens, read-only while it runs.
const Block = struct {
    graph: *const routing.Routing = undefined,
    live: u32 = 0,
    heard: u32 = 0,
    frames: u32 = 0,
    block_start: u64 = 0,
    sr: u32 = 48_000,
    bpm: f64 = 120,
    spb: f64 = 0,
    beat_start: f64 = 0,
    beat_end: f64 = 0,
    chase: bool = false,
    release_at: ?f64 = null,
    /// Past an offline render's stop [Engine.offline_stop]: no notes or
    /// audio clips, only what still rings.
    ring_out: bool = false,
    bar_info: meter.MeterMap.BarInfo = undefined,
};

fn renderWork(e: *Engine, s: *Scratch) bool {
    return e.renderReady(s);
}
pub const RenderPool = render_pool.Pool(Engine, Scratch, renderWork);

/// One sample the preview voice plays (Engine.previewSample).
pub const Preview = struct {
    data: []const f64 = &.{},
    /// Source frames per output frame.
    step: f64 = 1,
};

/// Where an offline render copies a track's signal (docs/27 §Tap).
pub const CaptureTap = enum(u8) {
    none,
    /// The instrument and audio clips, before the inserts.
    input,
    /// After the inserts, before volume and pan.
    pre,
    /// After volume and pan.
    post,
};

/// An offline render's taps (docs/27 §Bounce selection): each tapped
/// track's signal is copied into its own buffers as the render runs, and
/// the render can stop itself once they all fall quiet. Set
/// `Engine.capture` before `renderOffline`; buffers are the caller's,
/// zeroed, `frames + PDC_MAX` long (a tap is up to the project's latency
/// late, `lat`).
pub const Capture = struct {
    tap: [routing.MAX_TRACKS]CaptureTap = @splat(.none),
    l: [routing.MAX_TRACKS][]f32 = @splat(&.{}),
    r: [routing.MAX_TRACKS][]f32 = @splat(&.{}),
    /// Non-zero: only these tracks are heard. Every other track is muted
    /// (still rendering when it keys something), buses keep their mute,
    /// solos are ignored, and these render even if their mute is on.
    sources: u32 = 0,
    /// Stop the render once every tap (and the master, with
    /// `watch_master`) has stayed below `QUIET` for `hold` frames past the
    /// first `min_frames`; `hold` 0 renders it all.
    min_frames: usize = 0,
    hold: usize = 0,
    watch_master: bool = false,
    /// The master's end of signal, in output frames (after the project's
    /// latency is dropped).
    master_loud_end: usize = 0,
    /// Written by the render: each track's latency at its tap (its signal
    /// starts that many frames into its buffer), each tap's end of signal
    /// (the frame after its last loud one), and the frames rendered.
    lat: [routing.MAX_TRACKS]u32 = @splat(0),
    loud_end: [routing.MAX_TRACKS]usize = @splat(0),
    rendered: usize = 0,

    /// −80 dBFS: under a 16-bit file's dither, and where slabkit trims.
    pub const QUIET: f32 = 1e-4;

    fn done(self: *const Capture, rendered: usize, out_frames: usize) bool {
        if (self.hold == 0 or rendered < self.min_frames) return false;
        if (self.watch_master and @max(self.master_loud_end, self.min_frames) + self.hold > out_frames) return false;
        for (self.tap, 0..) |tp, ti| {
            if (tp == .none) continue;
            if (@max(self.loud_end[ti], self.min_frames + self.lat[ti]) + self.hold > rendered) return false;
        }
        return true;
    }
};

/// The preview sits under a full mix: −6 dB.
const PREVIEW_GAIN: f64 = 0.5;

pub const Engine = struct {
    transport: *Transport,
    tracks: []Track,
    /// Document-owned meter state (must outlive the engine). The audio
    /// thread reads `.map()` per block and adopts staged edits at bar
    /// boundaries (docs/07 §runtime-change).
    meter_state: *meter.MeterState = &default_meter_state,
    /// Bar index from the previous chunk; a change marks a boundary at
    /// which a staged meter edit may be adopted.
    meter_last_bar: ?u32 = null,
    was_playing: bool = false,
    /// Where the last played block left the transport. Finding it elsewhere
    /// at the next block means the UI moved the playhead mid-play.
    played_to: u64 = 0,
    /// The next block starts somewhere the notes didn't lead to (play,
    /// a seek, a loop wrap): notes already sounding there start with it.
    chase_pending: bool = true,
    /// The beat the playhead jumped away from (a seek, a loop wrap): the
    /// next block sends note-offs to the notes that were sounding there,
    /// so their voices release instead of hanging or being cut (a click).
    release_from: ?f64 = null,
    audition_request: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    audition_track: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    audition_pitch_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 60))),
    audition_seen: u32 = 0,
    audition_active: bool = false,
    audition_remaining: u32 = 0,
    audition_pitch: f32 = 60,
    audition_track_local: usize = 0,
    /// The browser's audition (docs/25 §The browser): a sample played
    /// straight to the output, over whatever plays. The UI fills the slot
    /// it isn't publishing and bumps the request; the audio thread copies
    /// the slot at its next block. Pool sources are never freed, so the
    /// data stays valid however long it plays.
    preview_req: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    preview_slots: [2]Preview = .{ .{}, .{} },
    preview_slot: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    preview_seen: u32 = 0,
    /// The last request the audio thread took: data an older request
    /// published is no longer read once this passes it.
    preview_ack: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    preview: Preview = .{},
    preview_pos: f64 = 0,
    /// Where the preview is, in source frames (for the browser's playhead);
    /// maxInt once it has ended.
    preview_at: std.atomic.Value(u32) = std.atomic.Value(u32).init(std.math.maxInt(u32)),
    /// Panic request from the UI thread, served at the top of the next
    /// render (machine state belongs to the audio thread).
    panic_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    trace_counter: u32 = 0,
    /// An offline render's taps [Capture]; null otherwise. Only
    /// `renderOffline` reads it, with the device stopped.
    capture: ?*Capture = null,
    /// The first sample of the offline render the capture belongs to.
    capture_start: u64 = 0,
    /// Offline only: the transport stops here. Past it no notes start and
    /// audio clips are silent; the sounding notes are released and what
    /// they leave rings out (an export's tail, docs/27 §Range). Cleared
    /// by `renderOffline`.
    offline_stop: ?u64 = null,
    stop_released: bool = false,

    /// Master bus. Audio tracks accumulate (planar) into master_l/r, then
    /// the master Track's FX chain + fader run before the interleaved
    /// write to the device. Set once at startup; address is stable.
    master: ?*Track = null,
    master_l: [MAX_BLOCK]f32 = undefined,
    master_r: [MAX_BLOCK]f32 = undefined,
    master_fx_l: [MAX_BLOCK]f32 = undefined,
    master_fx_r: [MAX_BLOCK]f32 = undefined,
    /// What the output does past full scale [MasterClip].
    master_clip: MasterClip = .{},
    /// The master's optional subsonic highpass [Subsonic], before its FX.
    master_subsonic: Subsonic = .{},
    /// Idle skipping (docs/04 §Idle skipping), an optimization: an
    /// instrument with no note near and an effect whose input is silent,
    /// both silent past their hold, aren't rendered and output silence
    /// until a note or signal reaches them. Off renders every machine every
    /// block: for A/B timing, or a machine meant to sound from nothing that
    /// declares no `tail!`. `--no-idle-skip` on the command line.
    idle_skip: bool = true,

    /// Routing (docs/23), double-buffered like track snapshots: the UI
    /// builds into the unpublished slot and flips; the audio thread holds
    /// the published one for one renderChunk.
    routing_bufs: [2]routing.Routing = .{ .{}, .{} },
    routing_published: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Each track's pre tap (after inserts, before the fader), kept for the
    /// block so keys and pre-fader sends can read it.
    pre_l: [routing.MAX_TRACKS][MAX_BLOCK]f32 = undefined,
    pre_r: [routing.MAX_TRACKS][MAX_BLOCK]f32 = undefined,
    /// Bus inputs: outputs and sends routed to a bus sum here.
    bus_l: [routing.MAX_TRACKS][MAX_BLOCK]f32 = undefined,
    bus_r: [routing.MAX_TRACKS][MAX_BLOCK]f32 = undefined,
    /// Last block's gain per send slot, the start of this block's ramp;
    /// negative until the slot has played.
    send_prev: [routing.MAX_TRACKS][routing.MAX_SENDS]f32 = @splat(@splat(-1)),

    /// Delay compensation (docs/07 §PDC): each track's recent output, from
    /// which a path that arrives early at a sum is read late. Allocated
    /// once by `initPdc`; without it paths sum as they arrive.
    pdc: ?*PdcHistory = null,
    /// This block's latencies, samples: of each track's signal at its taps,
    /// and at each bus's input (the latest of what feeds it).
    lat_out: [routing.MAX_TRACKS]u32 = @splat(0),
    lat_in: [routing.MAX_TRACKS]u32 = @splat(0),
    lat_master_in: u32 = 0,
    /// Where each track's block starts in the history this block.
    hist_at: [routing.MAX_TRACKS]usize = @splat(0),
    /// The whole project's: how late the master output is (UI reads it).
    master_latency: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Parallel rendering (docs/07 §Parallel rendering). The block being
    /// rendered, each node's state in it and its count of inputs still to
    /// come, and each node's post-fader signal, summed after it renders.
    blk: Block = .{},
    node_state: [routing.MAX_TRACKS]std.atomic.Value(u8) = @splat(.init(NODE_WAIT)),
    node_pending: [routing.MAX_TRACKS]std.atomic.Value(u8) = @splat(.init(0)),
    post_l: [routing.MAX_TRACKS][MAX_BLOCK]f32 = undefined,
    post_r: [routing.MAX_TRACKS][MAX_BLOCK]f32 = undefined,
    /// Each node's place in the render order.
    blk_at: [routing.MAX_TRACKS]u8 = undefined,
    /// Each destination's contributions (buses by index, then the master),
    /// how far each is summed, and who is summing it.
    contribs: [routing.MAX_TRACKS * (routing.MAX_SENDS + 1)]Contrib = undefined,
    dest_start: [MASTER_DEST + 1]u16 = @splat(0),
    dest_len: [MASTER_DEST + 1]u8 = @splat(0),
    dest_cursor: [MASTER_DEST + 1]std.atomic.Value(u8) = @splat(.init(0)),
    dest_busy: [MASTER_DEST + 1]std.atomic.Value(bool) = @splat(.init(false)),
    nodes_done: std.atomic.Value(usize) = .init(0),
    /// Each node's smoothed render time (timebase ticks) and its priority this block:
    /// that plus the costliest chain it feeds.
    node_cost: [routing.MAX_TRACKS]f32 = @splat(0),
    node_prio: [routing.MAX_TRACKS]f32 = @splat(0),
    /// Workers helping this thread render; null renders on it alone. The
    /// output is the same either way.
    pool: ?*RenderPool = null,
    /// Per render thread (render_pool.slot: the audio thread, then the
    /// workers): timebase ticks spent rendering and mixing nodes, and the
    /// frames rendered beside them, for the UI's thread lamps
    /// (takeThreadLoad).
    thread_busy: [render_pool.MAX_WORKERS + 1]std.atomic.Value(u64) = @splat(.init(0)),
    busy_frames: std.atomic.Value(u64) = .init(0),

    /// UI thread, before audio starts.
    pub fn initPdc(self: *Engine, alloc: std.mem.Allocator) !void {
        const h = try alloc.create(PdcHistory);
        h.clear();
        self.pdc = h;
    }

    /// UI thread, before audio starts, with the engine at its final
    /// address: start `workers` render threads (0: render on the audio
    /// thread alone; `rt`: real-time workers, render_pool §Real-time).
    pub fn initPool(self: *Engine, alloc: std.mem.Allocator, workers: usize, rt: ?render_pool.Rt) !void {
        if (workers == 0) return;
        self.pool = try RenderPool.create(alloc, self, workers, rt);
    }

    /// UI thread: each render thread's load since the last call, as a
    /// fraction of the audio those blocks lasted (1: a thread busy for
    /// the whole budget), into `out`; the number of threads.
    pub fn takeThreadLoad(self: *Engine, out: []f32, sample_rate: u32) usize {
        const n = @min(out.len, 1 + if (self.pool) |p| p.n else 0);
        const frames = self.busy_frames.swap(0, .monotonic);
        var info: std.c.mach_timebase_info_data = undefined;
        _ = std.c.mach_timebase_info(&info);
        const budget_ns = @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(@max(sample_rate, 1)));
        for (out[0..n], self.thread_busy[0..n]) |*o, *b| {
            const ticks = b.swap(0, .monotonic);
            const ns = @as(f64, @floatFromInt(ticks)) * @as(f64, @floatFromInt(info.numer)) / @as(f64, @floatFromInt(info.denom));
            o.* = if (budget_ns > 0) @floatCast(ns / budget_ns) else 0;
        }
        return n;
    }

    pub fn deinitPool(self: *Engine, alloc: std.mem.Allocator) void {
        if (self.pool) |p| p.destroy(alloc);
        self.pool = null;
    }

    /// Forget the recent history: after the tracks are renumbered, its
    /// rows would belong to other tracks. Audio stopped.
    pub fn clearPdc(self: *Engine) void {
        if (self.pdc) |h| h.clear();
    }

    pub fn deinitPdc(self: *Engine, alloc: std.mem.Allocator) void {
        if (self.pdc) |h| alloc.destroy(h);
        self.pdc = null;
    }

    /// Each track's latency at its taps and each bus's at its input, in
    /// render order; the master's input takes the latest of its tracks.
    fn computeLatencies(self: *Engine, graph: *const routing.Routing) void {
        @memset(&self.lat_in, 0);
        var master_in: u32 = 0;
        for (graph.renderOrder()) |ti| {
            const nd = &graph.nodes[ti];
            // A keyed effect's input must be at least as late as its key
            // (the source's pre tap), so a late key makes the track later.
            if (nd.key_count > 0 and !self.tracks[ti].frozen.load(.acquire)) {
                const t = &self.tracks[ti];
                var p = instLatency(t, nd.is_bus);
                for (t.effects.items, 0..) |*fx, i| {
                    if (t.effectBypassed(i)) continue;
                    if (fx.mach.takes_key) if (nd.keyFor(fx.uid)) |src| {
                        self.lat_in[ti] = @max(self.lat_in[ti], self.lat_out[src] -| p);
                    };
                    p += fx.mach.latencySamples();
                }
                self.lat_in[ti] = @min(self.lat_in[ti], PDC_LIMIT);
            }
            const out = @min(self.lat_in[ti] + chainLatency(&self.tracks[ti], nd.is_bus), PDC_LIMIT);
            self.lat_out[ti] = out;
            if (nd.output == routing.NONE) {
                master_in = @max(master_in, out);
            } else self.lat_in[nd.output] = @max(self.lat_in[nd.output], out);
            for (nd.sendSlots()) |sl| self.lat_in[sl.bus] = @max(self.lat_in[sl.bus], out);
        }
        self.lat_master_in = master_in;
        const master_chain = if (self.master) |mb| chainLatency(mb, true) else 0;
        self.master_latency.store(master_in + master_chain, .monotonic);
    }

    /// The published routing, or plain track → master when it doesn't
    /// cover the track list yet (a track added since the last publish).
    fn currentGraph(self: *Engine, fallback: *routing.Routing) *const routing.Routing {
        const rt = &self.routing_bufs[self.routing_published.load(.acquire)];
        if (rt.count == self.tracks.len) return rt;
        var nodes: [routing.MAX_TRACKS]routing.Node = undefined;
        const n = @min(self.tracks.len, routing.MAX_TRACKS);
        for (self.tracks[0..n], 0..) |*t, i| nodes[i] = .{ .is_bus = t.isBus() };
        fallback.* = routing.Routing.build(nodes[0..n]);
        return fallback;
    }

    /// UI thread: rebuild the routing from the tracks and publish it.
    pub fn publishRouting(self: *Engine) void {
        const published = self.routing_published.load(.monotonic);
        const dst = &self.routing_bufs[1 - published];
        var nodes: [routing.MAX_TRACKS]routing.Node = undefined;
        const n = @min(self.tracks.len, routing.MAX_TRACKS);
        for (self.tracks[0..n], 0..) |*t, i| nodes[i] = t.routingNode();
        dst.* = routing.Routing.build(nodes[0..n]);
        self.routing_published.store(1 - published, .release);
    }

    /// Play `data` (mono, at `rate` Hz) through the preview voice; empty
    /// stops it. UI thread.
    /// Returns the request's number (see `preview_ack`).
    pub fn previewSample(self: *Engine, data: []const f64, rate: f64) u32 {
        const slot = 1 - self.preview_slot.load(.monotonic);
        const sr: f64 = @floatFromInt(@max(1, self.transport.sample_rate));
        self.preview_slots[slot] = .{ .data = data, .step = if (rate > 0) rate / sr else 1 };
        self.preview_slot.store(slot, .release);
        return self.preview_req.fetchAdd(1, .release) +% 1;
    }

    pub fn stopPreview(self: *Engine) u32 {
        return self.previewSample(&.{}, 1);
    }

    /// The preview's position in source frames, or null once it ended.
    pub fn previewFrame(self: *const Engine) ?u32 {
        const at = self.preview_at.load(.monotonic);
        return if (at == std.math.maxInt(u32)) null else at;
    }

    fn mixPreview(self: *Engine, out: []f32, frames: usize) void {
        const req = self.preview_req.load(.acquire);
        if (req != self.preview_seen) {
            self.preview_seen = req;
            self.preview = self.preview_slots[self.preview_slot.load(.acquire)];
            self.preview_pos = 0;
            self.preview_ack.store(req, .release);
        }
        const d = self.preview.data;
        if (d.len == 0) {
            self.preview_at.store(std.math.maxInt(u32), .monotonic);
            return;
        }
        // A short fade in, so a sample cut mid-file doesn't click in.
        for (0..frames) |i| {
            const p = self.preview_pos;
            const k: usize = @intFromFloat(p);
            if (k + 1 >= d.len) {
                self.preview.data = &.{};
                break;
            }
            const f = p - @as(f64, @floatFromInt(k));
            const v: f32 = @floatCast((d[k] * (1 - f) + d[k + 1] * f) * PREVIEW_GAIN * @min(1.0, p / 64.0));
            out[i * audio.CHANNELS] += v;
            out[i * audio.CHANNELS + 1] += v;
            self.preview_pos = p + self.preview.step;
        }
        self.preview_at.store(if (self.preview.data.len == 0) std.math.maxInt(u32) else @intFromFloat(self.preview_pos), .monotonic);
    }

    pub fn auditionNote(self: *Engine, track_idx: usize, pitch: u8) void {
        self.audition_track.store(@intCast(@min(track_idx, std.math.maxInt(u32))), .monotonic);
        self.audition_pitch_bits.store(@bitCast(@as(f32, @floatFromInt(pitch))), .monotonic);
        _ = self.audition_request.fetchAdd(1, .release);
    }

    /// Kill all sound: every machine and effect is reset on the audio
    /// thread's next block (hung notes, reverb and delay tails) and any
    /// audition is cut. Callable from the UI thread; the caller stops the
    /// transport if silence should stay.
    pub fn panic(self: *Engine) void {
        self.panic_request.store(true, .release);
    }

    pub fn renderCallback(ctx: *anyopaque, out: [*]f32, frames: u32) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        self.render(out, frames);
    }

    /// Offline (non-realtime) bounce. Renders `total_frames` starting at
    /// `start_sample` into the interleaved stereo `out` buffer (length must
    /// be `total_frames * CHANNELS`), reusing the exact per-block signal
    /// path as live playback — instruments, audio clips, insert FX, the
    /// master FX chain/fader, and the master soft-clip stage.
    ///
    /// MUST be called with the audio device stopped: it shares the Engine's
    /// scratch buffers and each machine's single state with the live
    /// callback. Machines are reset before (clean start) and after (so live
    /// playback resumes cleanly). Loop is ignored — a bounce is always a
    /// single linear pass over the requested range.
    ///
    /// `progress` (frames rendered so far) and `cancel` (abort request) are
    /// optional and let a UI thread poll / interrupt a render running on a
    /// worker thread. On cancel the pass stops early; the caller discards the
    /// buffer.
    pub fn renderOffline(
        self: *Engine,
        out: []f32,
        total_frames: usize,
        start_sample: u64,
        progress: ?*std.atomic.Value(usize),
        cancel: ?*std.atomic.Value(bool),
    ) void {
        {
            fy_host.lockCallbacks();
            defer fy_host.unlockCallbacks();
            self.resetAllMachines();
        }
        self.transport.tempo.commitImmediate();
        self.chase_pending = true;
        self.capture_start = start_sample;
        self.stop_released = false;
        defer self.offline_stop = null;
        var pos = start_sample;
        // The master is late by the project's latency: its first `skip`
        // frames are dropped, so the bounce lines up with the timeline. The
        // blocks stay where they'd be without it (machines with block-rate
        // randomness render the same), only the copy out is offset.
        var fallback: routing.Routing = undefined;
        self.computeLatencies(self.currentGraph(&fallback));
        const skip: usize = self.master_latency.load(.monotonic);
        if (self.capture) |cap| for (self.tracks, 0..) |*t, ti| {
            cap.lat[ti] = switch (cap.tap[ti]) {
                .none => 0,
                .input => self.lat_in[ti] + instLatency(t, t.isBus()),
                .pre, .post => self.lat_out[ti],
            };
            cap.loud_end[ti] = 0;
        };
        if (self.capture) |cap| cap.master_loud_end = 0;
        var scratch: [MAX_BLOCK * audio.CHANNELS]f32 = undefined;
        var rendered: usize = 0;
        var done: usize = 0;
        while (done < total_frames) {
            if (cancel) |c| if (c.load(.monotonic)) break;
            var chunk: u32 = self.tempoChunk(@intCast(@min(@as(usize, MAX_BLOCK), total_frames + skip - rendered)), pos);
            // A block ends on the stop.
            if (self.offline_stop) |stop| if (pos < stop) {
                chunk = @intCast(@min(@as(u64, chunk), stop - pos));
            };
            const dropped = if (rendered < skip) @min(chunk, skip - rendered) else 0;
            // An empty `out` keeps only the capture.
            const direct = dropped == 0 and out.len > 0;
            const slice = if (direct) out[done * audio.CHANNELS ..][0 .. chunk * audio.CHANNELS] else scratch[0 .. chunk * audio.CHANNELS];
            {
                fy_host.lockCallbacks();
                defer fy_host.unlockCallbacks();
                self.renderChunk(slice, chunk, pos);
            }
            self.master_clip.apply(slice);
            if (!direct and out.len > 0) {
                const keep = slice[dropped * audio.CHANNELS ..];
                @memcpy(out[done * audio.CHANNELS ..][0..keep.len], keep);
            }
            done += chunk - dropped;
            rendered += chunk;
            pos += chunk;
            if (progress) |p| p.store(done, .monotonic);
            if (self.capture) |cap| {
                cap.rendered = rendered;
                if (cap.watch_master) {
                    const kept = chunk - dropped;
                    const keep = slice[dropped * audio.CHANNELS ..][0 .. kept * audio.CHANNELS];
                    var k = keep.len;
                    while (k > 0) {
                        k -= 1;
                        if (@abs(keep[k]) > Capture.QUIET) {
                            cap.master_loud_end = done - kept + k / audio.CHANNELS + 1;
                            break;
                        }
                    }
                }
                if (cap.done(rendered, done)) break;
            }
        }
        fy_host.lockCallbacks();
        defer fy_host.unlockCallbacks();
        self.resetAllMachines();
        self.was_playing = false;
    }

    fn render(self: *Engine, out: [*]f32, frames: u32) void {
        // One hold of the fy callback lock covers every machine this block
        // renders, on every render thread: hot-patch and runtime asset
        // swaps wait for the block's end.
        fy_host.lockCallbacks();
        defer fy_host.unlockCallbacks();
        const n: usize = frames;
        const total = n * audio.CHANNELS;
        var out_slice = out[0..total];
        @memset(out_slice, 0);

        if (self.panic_request.swap(false, .acquire)) {
            self.resetAllMachines();
            self.audition_active = false;
            self.audition_seen = self.audition_request.load(.acquire);
        }

        self.adoptTempo();
        const playing = self.transport.isPlaying();
        if (!playing) {
            if (self.was_playing) {
                // play → stop transition: drop all sustained notes.
                for (self.tracks) |*t| {
                    t.machine.reset(t.machine.state);
                    for (t.effects.items) |*fx| fx.mach.reset(fx.mach.state);
                    t.setMeter(0, 0);
                }
                if (self.master) |mb| {
                    for (mb.effects.items) |*fx| fx.mach.reset(fx.mach.state);
                }
                self.was_playing = false;
                // Force the first block on resume to be a boundary, so a
                // meter edited while stopped is adopted immediately.
                self.meter_last_bar = null;
            }
            if (!self.renderAudition(out_slice, frames)) {
                for (self.tracks) |*t| t.setMeter(0, 0);
                if (self.master) |mb| mb.setMeter(0, 0);
            }
        } else {
            const start_pos = self.transport.samples();
            // A seek while playing: the notes held across the jump would
            // never see their note-offs, so the instruments let go. Effects
            // keep their tails.
            if (self.was_playing and start_pos != self.played_to) {
                self.release_from = self.beatAtSample(self.played_to);
                self.chase_pending = true;
            }
            if (!self.was_playing) self.chase_pending = true;
            self.was_playing = true;

            // Chunk the callback block down to MAX_BLOCK if needed.
            var done: usize = 0;
            var pos = start_pos;
            while (done < n) {
                const chunk = self.nextRenderChunk(@intCast(@min(MAX_BLOCK, n - done)), pos);
                self.renderChunk(
                    out_slice[done * audio.CHANNELS ..][0 .. chunk * audio.CHANNELS],
                    @intCast(chunk),
                    pos,
                );
                done += chunk;
                pos = self.advanceRenderPos(pos, @intCast(chunk));
            }

            // Unless the UI seeked while this block rendered: then its
            // position stands and the next block sees the jump.
            self.played_to = pos;
            _ = self.transport.sample_pos.cmpxchgStrong(start_pos, pos, .monotonic, .monotonic);
        }

        self.mixPreview(out_slice, n);

        // Master output stage [MasterClip]: the float mix has no headroom
        // limit; this decides only what happens past full scale.
        const trace_audio = audioTraceEnabled();
        const trace_signal = signalProbeEnabled();
        const pre_clip_peak = if (trace_audio) peakInterleaved(out_slice) else 0;
        const pre_stats = if (trace_signal) signalStatsInterleaved(out_slice) else SignalStats{};
        self.master_clip.apply(out_slice);
        const post_stats = if (trace_signal) signalStatsInterleaved(out_slice) else SignalStats{};
        if (trace_audio) {
            const post_clip_peak = peakInterleaved(out_slice);
            self.trace_counter +%= 1;
            if (pre_clip_peak > self.master_clip.knee or self.trace_counter % 256 == 0) {
                std.debug.print(
                    "audio master frame={} playing={} pre={d:.3} post={d:.3} knee={d:.3}\n",
                    .{ self.transport.samples(), playing, pre_clip_peak, post_clip_peak, self.master_clip.knee },
                );
            }
        }
        if (trace_signal) {
            if (!trace_audio) self.trace_counter +%= 1;
            if (pre_stats.suspicious() or post_stats.suspicious() or self.trace_counter % 512 == 0) {
                std.debug.print(
                    "signal master frame={} playing={} pre_peak={d:.3} pre_rms={d:.3} pre_jump={d:.3} post_peak={d:.3} post_rms={d:.3} post_jump={d:.3} nonfinite={}/{} nearclip={}/{}\n",
                    .{
                        self.transport.samples(),
                        playing,
                        pre_stats.peak,
                        pre_stats.rms,
                        pre_stats.max_delta,
                        post_stats.peak,
                        post_stats.rms,
                        post_stats.max_delta,
                        pre_stats.nonfinite_count,
                        post_stats.nonfinite_count,
                        pre_stats.near_clip_count,
                        post_stats.near_clip_count,
                    },
                );
            }
        }
    }

    fn resetAllMachines(self: *Engine) void {
        for (self.tracks) |*t| {
            t.machine.reset(t.machine.state);
            for (t.effects.items) |*fx| fx.mach.reset(fx.mach.state);
        }
        if (self.master) |mb| {
            for (mb.effects.items) |*fx| fx.mach.reset(fx.mach.state);
        }
        self.master_subsonic.reset();
    }

    /// A tap of track `ti` for this block, `delay` samples late: the block
    /// itself at 0, else read back from the history written at `at`.
    fn tapped(self: *Engine, ti: usize, tap: PdcHistory.Tap, at: usize, delay: u32, l: []const f32, r: []const f32, buf_l: *[MAX_BLOCK]f32, buf_r: *[MAX_BLOCK]f32) struct { l: []const f32, r: []const f32 } {
        const h = self.pdc orelse return .{ .l = l, .r = r };
        if (delay == 0) return .{ .l = l, .r = r };
        const n = l.len;
        h.read(ti, tap, at, delay, buf_l[0..n], buf_r[0..n]);
        return .{ .l = buf_l[0..n], .r = buf_r[0..n] };
    }

    /// The audio thread's tempo map.
    fn tmap(self: *const Engine) *const tempo.TempoMap {
        return &self.transport.tempo.audio;
    }

    fn beatAtSample(self: *const Engine, s: u64) f64 {
        return self.tmap().beatAtSample(@floatFromInt(s), self.transport.sample_rate);
    }

    fn sampleAtBeat(self: *const Engine, b: f64) u64 {
        return @intFromFloat(@max(0, self.tmap().sampleAt(b, self.transport.sample_rate)));
    }

    /// The tempo at the playhead.
    fn bpmNow(self: *const Engine) f64 {
        return self.tmap().bpmAt(self.beatAtSample(self.transport.samples()));
    }

    /// Take a tempo edit the UI published. The playhead keeps its beat:
    /// the sample counter (and where the last block stopped) move to where
    /// that beat now falls (docs/28 §Edits while playing).
    fn adoptTempo(self: *Engine) void {
        if (!self.transport.tempo.pending()) return;
        const pos = self.transport.samples();
        const beat = self.beatAtSample(pos);
        const played = self.beatAtSample(self.played_to);
        if (!self.transport.tempo.adopt()) return;
        const moved = self.sampleAtBeat(beat);
        if (self.transport.sample_pos.cmpxchgStrong(pos, moved, .monotonic, .monotonic) == null) {
            if (self.played_to == pos) self.played_to = moved else self.played_to = self.sampleAtBeat(played);
        }
    }

    /// Frames until the next tempo point, so a block never spans one.
    fn tempoChunk(self: *const Engine, max_frames: u32, pos: u64) u32 {
        const at = self.tmap().nextChangeSample(self.beatAtSample(pos), self.transport.sample_rate) orelse return max_frames;
        const next: u64 = @intFromFloat(@ceil(at));
        if (next <= pos) return max_frames;
        return @intCast(@min(@as(u64, max_frames), next - pos));
    }

    fn nextRenderChunk(self: *Engine, max_frames: u32, pos: u64) usize {
        const frames = self.tempoChunk(max_frames, pos);
        if (!self.transport.loopEnabled()) return frames;
        const start_b = self.transport.loopStartBeats();
        const end_b = self.transport.loopEndBeats();
        if (end_b <= start_b) return frames;
        const start_s = self.sampleAtBeat(start_b);
        const end_s = self.sampleAtBeat(end_b);
        if (end_s <= start_s or pos < start_s or pos >= end_s) return frames;
        const to_end = end_s - pos;
        if (to_end == 0) return frames;
        return @intCast(@min(@as(u64, frames), to_end));
    }

    fn advanceRenderPos(self: *Engine, pos: u64, frames: u32) u64 {
        var next = pos + frames;
        if (!self.transport.loopEnabled()) return next;
        const start_b = self.transport.loopStartBeats();
        const end_b = self.transport.loopEndBeats();
        if (end_b <= start_b) return next;
        const start_s = self.sampleAtBeat(start_b);
        const end_s = self.sampleAtBeat(end_b);
        if (end_s <= start_s or next < end_s) return next;

        const len = end_s - start_s;
        next = start_s + ((next - end_s) % len);
        if (audioTraceEnabled()) {
            std.debug.print(
                "audio loop wrap pos={} frames={} next={} loop={}..{}\n",
                .{ pos, frames, next, start_s, end_s },
            );
        }
        // Where the rendered stream stopped: the loop end rounded to a sample,
        // or past it when the playhead was seeked beyond the loop.
        self.release_from = self.beatAtSample(pos + frames);
        self.chase_pending = true;
        return next;
    }

    fn renderAudition(self: *Engine, out: []f32, frames: u32) bool {
        const req = self.audition_request.load(.acquire);
        var send_on = false;
        if (req != self.audition_seen) {
            if (self.audition_active and self.audition_track_local < self.tracks.len) {
                const old = &self.tracks[self.audition_track_local];
                old.machine.reset(old.machine.state);
                for (old.effects.items) |*fx| fx.mach.reset(fx.mach.state);
            }
            self.audition_seen = req;
            self.audition_active = true;
            self.audition_remaining = self.transport.sample_rate / 5;
            self.audition_pitch = @bitCast(self.audition_pitch_bits.load(.monotonic));
            self.audition_track_local = @min(@as(usize, @intCast(self.audition_track.load(.monotonic))), if (self.tracks.len > 0) self.tracks.len - 1 else 0);
            send_on = true;
        }
        if (!self.audition_active or self.tracks.len == 0) return false;

        var l_buf: [MAX_BLOCK]f32 = undefined;
        var r_buf: [MAX_BLOCK]f32 = undefined;
        var fx_l_buf: [MAX_BLOCK]f32 = undefined;
        var fx_r_buf: [MAX_BLOCK]f32 = undefined;
        const n: usize = @min(@as(usize, frames), MAX_BLOCK);
        const l = l_buf[0..n];
        const r = r_buf[0..n];
        @memset(l, 0);
        @memset(r, 0);
        @memset(self.master_l[0..n], 0);
        @memset(self.master_r[0..n], 0);

        var events: [2]machine.NoteEvent = undefined;
        var event_count: usize = 0;
        if (send_on) {
            events[event_count] = .{
                .sample_offset = 0,
                .kind = .note_on,
                .channel = 0,
                .note_id = -1,
                .pitch = self.audition_pitch,
                .velocity = 0.9,
            };
            event_count += 1;
        }
        if (self.audition_remaining <= frames) {
            events[event_count] = .{
                .sample_offset = if (self.audition_remaining > 0) self.audition_remaining - 1 else 0,
                .kind = .note_off,
                .channel = 0,
                .note_id = -1,
                .pitch = self.audition_pitch,
                .velocity = 0,
            };
            event_count += 1;
        }

        // Stopped: automation holds its value at the playhead.
        const t = &self.tracks[self.audition_track_local];
        const snap = t.currentSnapshot();
        const beat = self.beatAtSample(self.transport.samples());
        const inst_view = snap_mod.AutoView{ .snap = snap, .cursors = &t.auto_cursors, .kind = .inst };
        const ctx = machine.MachineCtx{
            .sample_rate = @floatFromInt(self.transport.sample_rate),
            .block_size = @intCast(n),
            .block_start = 0,
            .tempo_bpm = @floatCast(self.tmap().bpmAt(beat)),
            .ppq_position = beat,
            .transport_state = .stopped,
            .note_in = if (event_count > 0) @ptrCast(&events[0]) else null,
            .note_in_count = @intCast(event_count),
            .automation = if (snap.lane_count > 0) &inst_view else null,
        };

        if (send_on) t.pulseNote();
        t.machine.render(t.machine.state, &ctx, l, r);
        const rendered = renderEffects(t, ctx, l, r, fx_l_buf[0..n], fx_r_buf[0..n], .{});
        const final_l = rendered.l;
        const final_r = rendered.r;
        const g = faderGains(t, snap, beat);
        const vl = g.l;
        const vr = g.r;
        var peak_l: f32 = 0;
        var peak_r: f32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const sl = final_l[i] * vl;
            const sr = final_r[i] * vr;
            self.master_l[i] += sl;
            self.master_r[i] += sr;
            peak_l = @max(peak_l, @abs(sl));
            peak_r = @max(peak_r, @abs(sr));
        }
        t.setMeter(peak_l, peak_r);
        self.finishMaster(out, @intCast(n));

        if (self.audition_remaining <= frames) {
            self.audition_active = false;
            self.audition_remaining = 0;
        } else {
            self.audition_remaining -= frames;
        }
        return true;
    }

    fn renderChunk(self: *Engine, out: []f32, frames: u32, block_start: u64) void {
        _ = self.busy_frames.fetchAdd(frames, .monotonic);
        // Tracks accumulate into the master bus (planar), not into `out`,
        // so the master FX chain can process the sum in finishMaster.
        @memset(self.master_l[0..frames], 0);
        @memset(self.master_r[0..frames], 0);

        var fallback: routing.Routing = undefined;
        const graph = self.currentGraph(&fallback);
        var muted: u32 = 0;
        var soloed: u32 = 0;
        const sources: u32 = if (self.capture) |cap| cap.sources else 0;
        for (self.tracks[0..graph.count], 0..) |*t, i| {
            const b = routing.bit(@intCast(i));
            if (sources != 0) {
                // A capture hears its sources alone [Capture.sources].
                if (if (t.isBus()) t.mute.load(.monotonic) else sources & b == 0) muted |= b;
                continue;
            }
            if (t.mute.load(.monotonic)) muted |= b;
            if (t.solo.load(.monotonic)) soloed |= b;
        }
        const heard = graph.audible(muted, soloed);
        var live = graph.rendered(heard);
        if (self.capture) |cap| {
            live |= sources;
            for (cap.tap[0..graph.count], 0..) |tp, i| {
                if (tp != .none) live |= routing.bit(@intCast(i));
            }
        }
        self.computeLatencies(graph);
        for (graph.nodes[0..graph.count], 0..) |nd, i| if (nd.is_bus) {
            @memset(self.bus_l[i][0..frames], 0);
            @memset(self.bus_r[i][0..frames], 0);
        };

        const sr = self.transport.sample_rate;
        // The block never spans a tempo point (tempoChunk): on a step the
        // beats are linear in samples; over a ramp, near enough for a block.
        var beat_start = self.beatAtSample(block_start);
        var beat_end = self.beatAtSample(block_start + frames);
        const bpm = self.tmap().bpmAt(beat_start);
        const spb = if (beat_end > beat_start)
            @as(f64, @floatFromInt(frames)) / (beat_end - beat_start)
        else
            60.0 * @as(f64, @floatFromInt(sr)) / bpm;
        const chase = self.chase_pending;
        self.chase_pending = false;
        var release_at = self.release_from;
        self.release_from = null;
        // Past an offline stop the playhead holds there: the first block
        // releases what sounds, none starts anything.
        var ring_out = false;
        if (self.offline_stop) |stop| if (block_start >= stop) {
            const sb = self.beatAtSample(stop);
            beat_start = sb;
            beat_end = sb;
            ring_out = true;
            if (!self.stop_released) release_at = sb;
            self.stop_released = true;
        };
        // Meter position for this block (homogeneous within the block).
        // Adopt a staged meter edit only when we cross into a new bar, so
        // bars never re-lay under the playhead mid-bar (docs/07).
        var bar_info = self.meter_state.map().barInfoAtBeat(beat_start);
        const at_boundary = self.meter_last_bar == null or bar_info.bar != self.meter_last_bar.?;
        if (at_boundary) {
            self.meter_state.adoptIfPending();
            bar_info = self.meter_state.map().barInfoAtBeat(beat_start);
        }
        self.meter_last_bar = bar_info.bar;


        // Tracks render in parallel, mix in order (docs/07 §Parallel
        // rendering). Any thread renders a ready node (renderNode:
        // instrument, inserts, fader, PDC history). Each sum (a bus's
        // input, the master) takes its contributions in render order, one
        // thread at a time, whoever finishes the one it waits on
        // (advanceDest), so every buffer adds in the order a serial render
        // adds it and the output is bit-identical at any thread count. A
        // bus is ready once its input is summed; a keyed node once its keys
        // have rendered.
        self.blk = .{
            .graph = graph,
            .live = live,
            .heard = heard,
            .frames = frames,
            .block_start = block_start,
            .sr = sr,
            .bpm = bpm,
            .spb = spb,
            .beat_start = beat_start,
            .beat_end = beat_end,
            .chase = chase,
            .release_at = release_at,
            .ring_out = ring_out,
            .bar_info = bar_info,
        };
        const order = graph.renderOrder();
        var at: [routing.MAX_TRACKS]u8 = undefined;
        for (order, 0..) |ti, k| at[ti] = @intCast(k);
        self.blk_at = at;
        self.buildContribs(order);
        for (order) |ti| {
            var n: u8 = self.dest_len[ti];
            for (graph.nodes[ti].keySlots()) |ks| {
                if (at[ks.src] < at[ti]) n += 1;
            }
            self.node_pending[ti].store(n, .monotonic);
            self.node_state[ti].store(if (n == 0) NODE_READY else NODE_WAIT, .release);
        }
        // Critical path first: a node's priority is its own cost plus the
        // costliest chain it feeds, so the long chains start early.
        var k = order.len;
        while (k > 0) {
            k -= 1;
            const ti = order[k];
            var down: f32 = 0;
            var succ = graph.audio_succ[ti] | graph.key_succ[ti];
            while (succ != 0) : (succ &= succ - 1) {
                const j: usize = @ctz(succ);
                if (j < graph.count and at[j] > at[ti]) down = @max(down, self.node_prio[j]);
            }
            self.node_prio[ti] = self.node_cost[ti] + down;
        }
        self.nodes_done.store(0, .release);
        var scratch: Scratch = undefined;
        const helped = if (self.pool) |p| p.begin(order.len) else false;
        while (self.nodes_done.load(.acquire) < order.len) {
            if (!self.renderReady(&scratch)) std.atomic.spinLoopHint();
        }
        if (helped) self.pool.?.end();
        // Every node is in: finish the sums a busy flag left behind.
        for (0..MASTER_DEST + 1) |d| {
            while (self.dest_cursor[d].load(.acquire) < self.dest_len[d]) self.advanceDest(d);
        }

        self.finishMaster(out, frames);
    }

    /// Each destination's contributions this block, in render order: an
    /// output or a send of a node that renders before it (a bus copies its
    /// input when it starts, so later ones would land in a block it has
    /// already read; they are left out, as a serial render loses them).
    fn buildContribs(self: *Engine, order: []const u8) void {
        const graph = self.blk.graph;
        @memset(self.dest_len[0..], 0);
        var counts: [MASTER_DEST + 1]u16 = @splat(0);
        for (0..2) |pass| {
            if (pass == 1) {
                var start: u16 = 0;
                for (&self.dest_start, &counts) |*st, cnt| {
                    st.* = start;
                    start += cnt;
                }
            }
            var fill: [MASTER_DEST + 1]u16 = @splat(0);
            for (order) |ti| {
                const node = &graph.nodes[ti];
                const outs = node.sendSlots().len + 1;
                for (0..outs) |o| {
                    const bus = if (o == 0) node.output else node.sends[o - 1].bus;
                    const d: usize = if (bus == routing.NONE) MASTER_DEST else bus;
                    if (d != MASTER_DEST and self.blk_at[d] <= self.blk_at[ti]) continue;
                    if (pass == 0) {
                        counts[d] += 1;
                    } else {
                        self.contribs[self.dest_start[d] + fill[d]] = .{ .node = ti, .send = if (o == 0) OUTPUT else @intCast(o - 1) };
                        fill[d] += 1;
                    }
                }
            }
        }
        for (&self.dest_len, counts, &self.dest_cursor, &self.dest_busy) |*l, cnt, *cur, *busy| {
            l.* = @intCast(cnt);
            cur.store(0, .monotonic);
            busy.store(false, .monotonic);
        }
    }

    /// Sum into destination `d` every contribution at its cursor whose
    /// node has rendered, in order; a bus summed whole is ready. Any
    /// thread, one at a time per destination.
    fn advanceDest(self: *Engine, d: usize) void {
        const items = self.contribs[self.dest_start[d]..][0..self.dest_len[d]];
        while (true) {
            // seq_cst here, on the done store and on the look-again: a node
            // finishing while we hold the flag either sees it free or is seen.
            if (self.dest_busy[d].cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return;
            var k = self.dest_cursor[d].load(.monotonic);
            while (k < items.len and self.node_state[items[k].node].load(.acquire) == NODE_DONE) : (k += 1) {
                self.mixContrib(items[k]);
                if (d != MASTER_DEST) self.release(@intCast(d));
            }
            self.dest_cursor[d].store(k, .release);
            self.dest_busy[d].store(false, .seq_cst);
            // A node that finished while we held the flag found it taken:
            // look again so its sum isn't left waiting.
            if (k >= items.len or self.node_state[items[k].node].load(.seq_cst) != NODE_DONE) return;
        }
    }

    /// Nothing to render: advance any sum still waiting, in case a hand-off
    /// raced (cheap; most are done or held).
    fn sweepDests(self: *Engine) void {
        for (0..MASTER_DEST + 1) |d| {
            if (self.dest_cursor[d].load(.acquire) < self.dest_len[d]) self.advanceDest(d);
        }
    }

    /// One of node `j`'s inputs is in; the last makes it ready.
    fn release(self: *Engine, j: u8) void {
        if (self.node_pending[j].fetchSub(1, .acq_rel) == 1) self.node_state[j].store(NODE_READY, .release);
    }

    /// Render the most critical ready node, if there is one, then hand on
    /// what it feeds; any thread.
    fn renderReady(self: *Engine, scratch: *Scratch) bool {
        const graph = self.blk.graph;
        const order = graph.renderOrder();
        while (true) {
            var best: ?u8 = null;
            for (order) |ti| {
                if (self.node_state[ti].load(.monotonic) != NODE_READY) continue;
                if (best == null or self.node_prio[ti] > self.node_prio[best.?]) best = ti;
            }
            const ti = best orelse {
                self.sweepDests();
                return false;
            };
            if (self.node_state[ti].cmpxchgStrong(NODE_READY, NODE_RUNNING, .acquire, .monotonic) != null) continue;
            const t0 = std.c.mach_absolute_time();
            self.renderNode(ti, scratch);
            const t1 = std.c.mach_absolute_time();
            defer _ = self.thread_busy[render_pool.slot].fetchAdd(std.c.mach_absolute_time() - t0, .monotonic);
            const ns: f32 = @floatFromInt(t1 - t0);
            // Its cost (in timebase ticks; only their ratios matter) for the next blocks' priorities, smoothed.
            self.node_cost[ti] += (ns - self.node_cost[ti]) * 0.125;
            self.node_state[ti].store(NODE_DONE, .seq_cst);
            // What it keys can go; what it sums into takes it.
            const node = &graph.nodes[ti];
            var keyed = graph.key_succ[ti];
            while (keyed != 0) : (keyed &= keyed - 1) {
                const j: usize = @ctz(keyed);
                if (j >= graph.count or self.blk_at[j] <= self.blk_at[ti]) continue;
                for (graph.nodes[j].keySlots()) |ks| if (ks.src == ti) self.release(@intCast(j));
            }
            for (0..node.sendSlots().len + 1) |o| {
                const bus = if (o == 0) node.output else node.sends[o - 1].bus;
                self.advanceDest(if (bus == routing.NONE) MASTER_DEST else bus);
            }
            _ = self.nodes_done.fetchAdd(1, .acq_rel);
            return true;
        }
    }

    /// A node's own signal for the block: its instrument (or bus input),
    /// insert chain and fader, into its pre and post taps and its PDC
    /// history. Touches only this node's state and what feeds it, so nodes
    /// render on any thread.
    fn renderNode(self: *Engine, ti: u8, scratch: *Scratch) void {
        const b = &self.blk;
        const graph = b.graph;
        const live = b.live;
        const frames = b.frames;
        const block_start = b.block_start;
        const sr = b.sr;
        const bpm = b.bpm;
        const spb = b.spb;
        const beat_start = b.beat_start;
        const beat_end = b.beat_end;
        const chase = b.chase;
        const release_at = b.release_at;
        const bar_info = b.bar_info;
        const t = &self.tracks[ti];
        const node = &graph.nodes[ti];
        if (live & routing.bit(ti) == 0) {
            if (self.pdc) |h| h.silence(ti, frames);
            t.setMeter(0, 0);
            return;
        }

        // A bus starts from its summed input; a track from silence.
        const l = self.pre_l[ti][0..frames];
        const r = self.pre_r[ti][0..frames];
        if (node.is_bus) {
            @memcpy(l, self.bus_l[ti][0..frames]);
            @memcpy(r, self.bus_r[ti][0..frames]);
        } else {
            @memset(l, 0);
            @memset(r, 0);
        }

        // Load the snapshot pointer once per track per block.
        // See snapshot.zig for the double-buffer invariant.
        const snap = t.currentSnapshot();
        const n_events = gatherEvents(snap, beat_start, beat_end, spb, frames, chase, release_at, &scratch.events);
        // Frozen: its audio stands in for the instrument, audio clips and
        // inserts (docs/28 §Freeze); the fader on is as ever.
        const frozen = if (node.is_bus) null else snap.frozen;

        const inst_view = snap_mod.AutoView{ .snap = snap, .cursors = &t.auto_cursors, .kind = .inst };
        // The track's own time (docs/28 §Polymeter and polytempo).
        const lt = localTime(snap, beat_start, bpm, bar_info, self.meter_state.map());
        const ctx = machine.MachineCtx{
            .sample_rate = @floatFromInt(sr),
            .block_size = frames,
            .block_start = block_start,
            .tempo_bpm = @floatCast(lt.bpm),
            .ppq_position = lt.beat,
            .transport_state = .playing,
            .note_in = if (n_events > 0) @ptrCast(&scratch.events[0]) else null,
            .note_in_count = @intCast(n_events),
            .bar = lt.bar,
            .beat_in_bar = lt.beat_in_bar,
            .bar_len_beats = lt.bar_len,
            .automation = if (snap.lane_count > 0) &inst_view else null,
        };

        // Note-activity LED: pulse when a note-on is dispatched this block.
        for (scratch.events[0..n_events]) |ev| {
            if (ev.kind == .note_on) {
                t.pulseNote();
                break;
            }
        }

        const track_probe = trackProbeEnabled();
        const inst_start = if (track_probe) probeNowNs() else 0;
        // A note sounding or close keeps the whole track awake.
        var wake = false;
        if (frozen) |fz| {
            // Past an export's stop it falls silent like the rest would
            // have, its tail too (unfreeze to export a part with tails).
            if (!b.ring_out) playFrozen(fz, block_start, frames, sr, l, r);
            self.captureTap(ti, .input, block_start, l, r);
        } else if (!node.is_bus) {
            // Disabled instrument → feed silence into the effect chain.
            if (t.isEnabled()) {
                if (!self.idle_skip) {
                    t.machine.render(t.machine.state, &ctx, l, r);
                } else {
                    const ahead = IDLE_WAKE_AHEAD_S * bpm / 60.0;
                    // A control edit wakes it too, so its params and
                    // displays catch up (the edit may be all there is).
                    const edited = t.machine.takeWake();
                    wake = n_events > 0 or notesNear(snap, beat_start, beat_end + ahead);
                    if (edited) t.inst_quiet = 0;
                    const hold = t.machine.idleHold(@floatFromInt(sr), idleHoldSamples(sr));
                    // Asleep: `l`/`r` stay silent.
                    if (wake or hold == machine.TAIL_FOREVER or t.inst_quiet < hold) {
                        t.machine.render(t.machine.state, &ctx, l, r);
                        const loud = @max(blockPeak(l), blockPeak(r)) > IDLE_FLOOR;
                        t.inst_quiet = if (wake or loud) 0 else t.inst_quiet +| frames;
                    }
                }
            }
            // Audio clips mix on top of the instrument output, into the
            // same planar L/R, so the track's insert chain processes the sum.
            if (!b.ring_out) mixAudioClips(snap, block_start, frames, self.tmap(), sr, l, r);
            // Late for a key that arrives later still (PDC).
            if (self.pdc) |h| {
                h.put(ti, .input, l, r);
                const d = self.lat_in[ti];
                if (d > 0) h.read(ti, .input, h.w[ti], d, l, r);
            }
            self.captureTap(ti, .input, block_start, l, r);
        }
        const inst_ns = if (track_probe) probeNowNs() - inst_start else 0;
        const fx_start = if (track_probe) probeNowNs() else 0;
        const keys: ?Keys = if (node.key_count > 0) .{
            .node = node,
            .pre_l = &self.pre_l,
            .pre_r = &self.pre_r,
            .live = live,
            .hist = self.pdc,
            .hist_at = &self.hist_at,
            .lat_out = &self.lat_out,
            .lat = self.lat_in[ti] + instLatency(t, node.is_bus),
        } else null;
        if (frozen == null) {
            const rendered = renderEffectsKeyed(t, ctx, l, r, scratch.fx_l[0..frames], scratch.fx_r[0..frames], keys, .{ .on = self.idle_skip, .wake = wake });
            // The chain may end in the scratch pair; the pre tap is `l`/`r`.
            if (rendered.l.ptr != l.ptr) {
                @memcpy(l, rendered.l);
                @memcpy(r, rendered.r);
            }
        }
        const fx_ns = if (track_probe) probeNowNs() - fx_start else 0;
        const final_l: []const f32 = l;
        const final_r: []const f32 = r;
        self.captureTap(ti, .pre, block_start, final_l, final_r);

        // Fader gains at the block's ends; automated volume/pan ramp
        // between them per sample (docs/22 §Track volume and pan).
        const g0 = faderGains(t, snap, beat_start);
        const g1 = faderGains(t, snap, beat_end);
        const v = g0.v;
        const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(frames));
        // Post-fader signal into the free scratch pair, then summed into
        // the output and the post-fader sends.
        const post_l = self.post_l[ti][0..frames];
        const post_r = self.post_r[ti][0..frames];
        var peak_l: f32 = 0;
        var peak_r: f32 = 0;
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            const f = @as(f32, @floatFromInt(i)) * inv_n;
            const vl = g0.l + (g1.l - g0.l) * f;
            const vr = g0.r + (g1.r - g0.r) * f;
            const sl = final_l[i] * vl;
            const sr2 = final_r[i] * vr;
            post_l[i] = sl;
            post_r[i] = sr2;
            const al = @abs(sl);
            const ar = @abs(sr2);
            if (al > peak_l) peak_l = al;
            if (ar > peak_r) peak_r = ar;
        }
        self.captureTap(ti, .post, block_start, post_l, post_r);
        // The taps' history, for paths that must arrive later (PDC).
        const hist_at = if (self.pdc) |h| h.write(ti, final_l, final_r, post_l, post_r) else 0;
        self.hist_at[ti] = hist_at;
        if (b.heard & routing.bit(ti) != 0) t.setMeter(peak_l, peak_r) else t.setMeter(0, 0);
        if (track_probe) {
            const total_ns = inst_ns + fx_ns;
            const budget_ns = @divTrunc(@as(i128, @intCast(frames)) * std.time.ns_per_s, @as(i128, @intCast(sr)));
            if (trackProbeVerbose() or total_ns > @divTrunc(budget_ns, 4) or n_events > 0) {
                std.debug.print(
                    "track-probe \"{s}\" block={} frames={} events={} inst_ms={d:.3} fx_ms={d:.3} total_ms={d:.3} budget_ms={d:.3} effects={}\n",
                    .{
                        t.name(),
                        block_start,
                        frames,
                        n_events,
                        @as(f64, @floatFromInt(inst_ns)) / 1_000_000.0,
                        @as(f64, @floatFromInt(fx_ns)) / 1_000_000.0,
                        @as(f64, @floatFromInt(total_ns)) / 1_000_000.0,
                        @as(f64, @floatFromInt(budget_ns)) / 1_000_000.0,
                        t.effectCount(),
                    },
                );
            }
        }
        if (signalProbeEnabled()) {
            const stats = signalStatsPlanar(final_l, final_r, v);
            if (stats.suspicious() or (signalProbeVerbose() and (n_events > 0 or self.trace_counter % 512 == 0))) {
                std.debug.print(
                    "signal track \"{s}\" block={} beat={d:.3}..{d:.3} events={} peak={d:.3} rms={d:.3} jump={d:.3} nonfinite={} nearclip={} vol={d:.3}\n",
                    .{
                        t.name(),
                        block_start,
                        beat_start,
                        beat_end,
                        n_events,
                        stats.peak,
                        stats.rms,
                        stats.max_delta,
                        stats.nonfinite_count,
                        stats.near_clip_count,
                        v,
                    },
                );
            }
        }
        if (audioTraceEnabled() and (n_events > 0 or peak_l > 0.65 or peak_r > 0.65)) {
            std.debug.print(
                "audio track \"{s}\" beat={d:.3}..{d:.3} events={} peak=({d:.3},{d:.3}) vol={d:.3}\n",
                .{ t.name(), beat_start, beat_end, n_events, peak_l, peak_r, v },
            );
        }
    }

    /// Copy track `ti`'s `tap` for this block into the capture, if that's
    /// the tap it wants. Each track writes only its own buffers, so nodes
    /// still render on any thread.
    fn captureTap(self: *Engine, ti: u8, tap: CaptureTap, block_start: u64, l: []const f32, r: []const f32) void {
        const cap = self.capture orelse return;
        if (cap.tap[ti] != tap) return;
        const at: usize = @intCast(block_start - self.capture_start);
        const dst_l = cap.l[ti];
        const dst_r = cap.r[ti];
        if (at >= dst_l.len or at >= dst_r.len) return;
        const n = @min(l.len, dst_l.len - at, dst_r.len - at);
        @memcpy(dst_l[at..][0..n], l[0..n]);
        @memcpy(dst_r[at..][0..n], r[0..n]);
        var k = n;
        while (k > 0) {
            k -= 1;
            if (@abs(l[k]) > Capture.QUIET or @abs(r[k]) > Capture.QUIET) {
                cap.loud_end[ti] = at + k + 1;
                break;
            }
        }
    }

    /// Sum one output or send of a rendered node into its destination,
    /// delayed for PDC.
    fn mixContrib(self: *Engine, it: Contrib) void {
        const b = &self.blk;
        const ti = it.node;
        const frames = b.frames;
        if (b.live & routing.bit(ti) == 0 or b.heard & routing.bit(ti) == 0) return;
        const t = &self.tracks[ti];
        const node = &b.graph.nodes[ti];
        const hist_at = self.hist_at[ti];
        const post_l = self.post_l[ti][0..frames];
        const post_r = self.post_r[ti][0..frames];
        var dly_l: [MAX_BLOCK]f32 = undefined;
        var dly_r: [MAX_BLOCK]f32 = undefined;
        if (it.send == OUTPUT) {
            const dst_l = if (node.output == routing.NONE) self.master_l[0..frames] else self.bus_l[node.output][0..frames];
            const dst_r = if (node.output == routing.NONE) self.master_r[0..frames] else self.bus_r[node.output][0..frames];
            const out_in = if (node.output == routing.NONE) self.lat_master_in else self.lat_in[node.output];
            const out_tap = self.tapped(ti, .post, hist_at, out_in -| self.lat_out[ti], post_l, post_r, &dly_l, &dly_r);
            for (dst_l, out_tap.l) |*d, x| d.* += x;
            for (dst_r, out_tap.r) |*d, x| d.* += x;
            return;
        }
        // The track's send list can be shorter than the published one for
        // a frame after a send is removed.
        const si = it.send;
        if (si >= t.send_count) return;
        const s = node.sends[si];
        const final_l: []const f32 = self.pre_l[ti][0..frames];
        const final_r: []const f32 = self.pre_r[ti][0..frames];
        const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(frames));
        const lvl = t.sends[si].level();
        const prev = if (self.send_prev[ti][si] < 0) lvl else self.send_prev[ti][si];
        self.send_prev[ti][si] = lvl;
        const send_tap = self.tapped(ti, if (s.pre) .pre else .post, hist_at, self.lat_in[s.bus] -| self.lat_out[ti], if (s.pre) final_l else post_l, if (s.pre) final_r else post_r, &dly_l, &dly_r);
        const src_l = send_tap.l;
        const src_r = send_tap.r;
        const bl = self.bus_l[s.bus][0..frames];
        const br = self.bus_r[s.bus][0..frames];
        for (0..frames) |k| {
            const gk = prev + (lvl - prev) * (@as(f32, @floatFromInt(k)) * inv_n);
            bl[k] += src_l[k] * gk;
            br[k] += src_r[k] * gk;
        }
    }

    /// Master bus post-processing: run the master Track's FX chain over the
    /// accumulated planar bus, apply the master fader, write interleaved to
    /// `out`, and update the master meter. With no master configured (or no
    /// FX) it is fader/passthrough. The top-level master_clip then runs
    /// once over the whole device buffer.
    fn finishMaster(self: *Engine, out: []f32, frames: u32) void {
        const n: usize = frames;
        var l: []f32 = self.master_l[0..n];
        var r: []f32 = self.master_r[0..n];
        var mv: f32 = 1.0;
        var mpl: f32 = 1.0;
        var mpr: f32 = 1.0;
        if (self.master) |mb| {
            if (mb.subsonic.load(.monotonic))
                self.master_subsonic.process(l, r, @floatFromInt(self.transport.sample_rate))
            else
                self.master_subsonic.reset();
            if (mb.effectCount() > 0) {
                const base = machine.MachineCtx{
                    .sample_rate = @floatFromInt(self.transport.sample_rate),
                    .block_size = frames,
                    .block_start = 0,
                    .tempo_bpm = @floatCast(self.bpmNow()),
                    .ppq_position = 0,
                    .transport_state = if (self.transport.isPlaying()) .playing else .stopped,
                };
                const rendered = renderEffects(mb, base, l, r, self.master_fx_l[0..n], self.master_fx_r[0..n], .{ .on = self.idle_skip });
                l = rendered.l;
                r = rendered.r;
            }
            mv = mb.volume();
            const pg = mb.balanceGains();
            mpl = pg.l;
            mpr = pg.r;
        }
        const mvl = mv * mpl;
        const mvr = mv * mpr;
        var peak_l: f32 = 0;
        var peak_r: f32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const sl = l[i] * mvl;
            const sr = r[i] * mvr;
            out[i * 2] = sl;
            out[i * 2 + 1] = sr;
            peak_l = @max(peak_l, @abs(sl));
            peak_r = @max(peak_r, @abs(sr));
        }
        if (self.master) |mb| mb.setMeter(peak_l, peak_r);
    }
};

/// The master's subsonic filter (docs/19 §Track): a 4th-order Butterworth
/// highpass at 30 Hz, 24 dB/oct, on the master's input before its inserts.
/// Energy under 30 Hz is mostly felt, not heard, on a club rig and inaudible
/// on headphones, yet it moves meters, compressors and the limiter; the
/// switch takes it out of the mix in one place. Two RBJ sections at the
/// Butterworth Qs, f64 state, designed on the first block at a new rate.
pub const Subsonic = struct {
    pub const HZ: f64 = 30.0;
    const QS = [2]f64{ 0.5411961001461969, 1.3065629648763766 };

    rate: f64 = 0,
    b0: [2]f64 = .{ 1, 1 },
    b1: [2]f64 = .{ 0, 0 },
    a1: [2]f64 = .{ 0, 0 },
    a2: [2]f64 = .{ 0, 0 },
    /// [channel][section]: the TDF-II state pair.
    z1: [2][2]f64 = .{ .{ 0, 0 }, .{ 0, 0 } },
    z2: [2][2]f64 = .{ .{ 0, 0 }, .{ 0, 0 } },

    fn design(self: *Subsonic, sr: f64) void {
        const w0 = 2.0 * std.math.pi * HZ / sr;
        const cw = @cos(w0);
        for (QS, 0..) |q, k| {
            const alpha = @sin(w0) / (2.0 * q);
            const a0 = 1.0 + alpha;
            // b2 = b0 and b1 = -2 b0 for a highpass.
            self.b0[k] = (1.0 + cw) / 2.0 / a0;
            self.b1[k] = -(1.0 + cw) / a0;
            self.a1[k] = -2.0 * cw / a0;
            self.a2[k] = (1.0 - alpha) / a0;
        }
        self.rate = sr;
    }

    pub fn process(self: *Subsonic, l: []f32, r: []f32, sr: f64) void {
        if (sr != self.rate) self.design(sr);
        inline for (.{ l, r }, 0..) |buf, ch| {
            for (buf) |*s| {
                var x: f64 = s.*;
                inline for (0..2) |k| {
                    const y = self.b0[k] * x + self.z1[ch][k];
                    self.z1[ch][k] = self.b1[k] * x - self.a1[k] * y + self.z2[ch][k];
                    self.z2[ch][k] = self.b0[k] * x - self.a2[k] * y;
                    x = y;
                }
                s.* = @floatCast(x);
            }
        }
    }

    pub fn reset(self: *Subsonic) void {
        self.z1 = .{ .{ 0, 0 }, .{ 0, 0 } };
        self.z2 = .{ .{ 0, 0 }, .{ 0, 0 } };
    }
};

/// The master output stage: the last thing before the device or the file.
/// The mix itself is 32-bit float with no headroom limit; this only decides
/// what happens past full scale.
///
///   .soft  linear inside ±knee, then bends smoothly toward ±1.0 whatever
///          the input [C1 at the knee]:
///            y = sgn(x) · (K + (1-K)·t / (t + (1-K))),  t = |x| - K
///   .hard  clamp at ±1.0, what a converter does in other DAWs
///   .off   raw float out [the device clamps; a WAV keeps the overs]
///
/// The knee used to be 0.7 (−3.1 dBFS). A memoryless curve that low
/// compresses whatever rides on a loud sound: at a sum of 1.0 its slope is
/// 0.25, so quieter tracks lost 12 dB wherever a hot one peaked. At 0.95
/// (−0.45 dBFS) it is a safety net that leaves everything under full scale
/// alone; the master meter's clip LED shows the overs.
pub const MasterClip = struct {
    mode: Mode = .soft,
    knee: f32 = 0.95,

    pub const Mode = enum { off, soft, hard };

    pub inline fn sample(self: MasterClip, x: f32) f32 {
        return switch (self.mode) {
            .off => x,
            .hard => std.math.clamp(x, -1.0, 1.0),
            .soft => soft(x, self.knee),
        };
    }

    pub fn apply(self: MasterClip, buf: []f32) void {
        if (self.mode == .off) return;
        for (buf) |*s| s.* = self.sample(s.*);
    }

    inline fn soft(x: f32, k: f32) f32 {
        const ax = @abs(x);
        if (ax <= k) return x;
        const r = 1.0 - k;
        const sign: f32 = if (x < 0) -1.0 else 1.0;
        const over = ax - k;
        return sign * (k + r * (over / (over + r)));
    }
};

fn audioTraceEnabled() bool {
    return std.c.getenv("SLAB_AUDIO_TRACE") != null;
}

fn signalProbeEnabled() bool {
    return std.c.getenv("SLAB_SIGNAL_PROBE") != null or std.c.getenv("SLAB_AUDIO_PROBE") != null;
}

fn signalProbeVerbose() bool {
    return std.c.getenv("SLAB_SIGNAL_PROBE_VERBOSE") != null;
}

fn trackProbeEnabled() bool {
    return std.c.getenv("SLAB_TRACK_PROBE") != null;
}

fn trackProbeVerbose() bool {
    return std.c.getenv("SLAB_TRACK_PROBE_VERBOSE") != null;
}

fn probeNowNs() i128 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @divTrunc(@as(i128, @intCast(std.c.mach_absolute_time())) * @as(i128, @intCast(info.numer)), @as(i128, @intCast(info.denom)));
}

fn peakInterleaved(buf: []const f32) f32 {
    var peak: f32 = 0;
    for (buf) |s| {
        const a = @abs(s);
        if (a > peak) peak = a;
    }
    return peak;
}

const SignalStats = struct {
    peak: f32 = 0,
    rms: f32 = 0,
    max_delta: f32 = 0,
    nonfinite_count: usize = 0,
    near_clip_count: usize = 0,

    fn suspicious(self: SignalStats) bool {
        return self.nonfinite_count > 0 or self.near_clip_count > 0 or self.max_delta > 0.65;
    }
};

fn signalStatsInterleaved(buf: []const f32) SignalStats {
    var stats = SignalStats{};
    var sum_sq: f64 = 0;
    var count: usize = 0;
    var prev_l: f32 = 0;
    var prev_r: f32 = 0;
    var have_prev_l = false;
    var have_prev_r = false;

    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const s = buf[i];
        if (!std.math.isFinite(s)) {
            stats.nonfinite_count += 1;
            continue;
        }
        const a = @abs(s);
        if (a > stats.peak) stats.peak = a;
        if (a > 0.98) stats.near_clip_count += 1;
        sum_sq += @as(f64, s) * @as(f64, s);
        count += 1;

        if (i % 2 == 0) {
            if (have_prev_l) stats.max_delta = @max(stats.max_delta, @abs(s - prev_l));
            prev_l = s;
            have_prev_l = true;
        } else {
            if (have_prev_r) stats.max_delta = @max(stats.max_delta, @abs(s - prev_r));
            prev_r = s;
            have_prev_r = true;
        }
    }
    if (count > 0) stats.rms = @floatCast(@sqrt(sum_sq / @as(f64, @floatFromInt(count))));
    return stats;
}

fn signalStatsPlanar(l: []const f32, r: []const f32, gain: f32) SignalStats {
    var stats = SignalStats{};
    var sum_sq: f64 = 0;
    var count: usize = 0;
    var prev_l: f32 = 0;
    var prev_r: f32 = 0;
    var have_prev = false;
    const n = @min(l.len, r.len);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const sl = l[i] * gain;
        const sr = r[i] * gain;
        const samples = [_]f32{ sl, sr };
        for (samples, 0..) |s, ch| {
            if (!std.math.isFinite(s)) {
                stats.nonfinite_count += 1;
                continue;
            }
            const a = @abs(s);
            if (a > stats.peak) stats.peak = a;
            if (a > 0.98) stats.near_clip_count += 1;
            sum_sq += @as(f64, s) * @as(f64, s);
            count += 1;
            if (have_prev) {
                const prev = if (ch == 0) prev_l else prev_r;
                stats.max_delta = @max(stats.max_delta, @abs(s - prev));
            }
        }
        prev_l = sl;
        prev_r = sr;
        have_prev = true;
    }
    if (count > 0) stats.rms = @floatCast(@sqrt(sum_sq / @as(f64, @floatFromInt(count))));
    return stats;
}

const RenderedPair = struct {
    l: []f32,
    r: []f32,
};

/// Where a track's keyed effects find their keys (docs/23 §Sidechain
/// keys): the routing node naming each key's source, and the pre taps
/// rendered so far this block.
const Keys = struct {
    node: *const routing.Node,
    pre_l: *const [routing.MAX_TRACKS][MAX_BLOCK]f32,
    pre_r: *const [routing.MAX_TRACKS][MAX_BLOCK]f32,
    /// Sources rendered this block (the rest hold a stale block).
    live: u32,
    /// Delay compensation: a key is read late by how much earlier it is
    /// than the keyed effect's input, `lat` at the chain's start.
    hist: ?*const PdcHistory = null,
    hist_at: ?*const [routing.MAX_TRACKS]usize = null,
    lat_out: ?*const [routing.MAX_TRACKS]u32 = null,
    lat: u32 = 0,
};

/// Ring length of the PDC history, a power of two; the most a path can be
/// delayed leaves a block's room (170 ms at 48 kHz, well above any lookahead).
pub const PDC_MAX: usize = 8192;
const PDC_LIMIT: u32 = PDC_MAX - MAX_BLOCK;

pub const PdcHistory = struct {
    /// `input` is an instrument track's chain input (instrument and audio
    /// clips), delayed when a late key must meet it.
    pub const Tap = enum { pre, post, input };
    /// Per track and tap, L/R.
    bufs: [routing.MAX_TRACKS][3][2][PDC_MAX]f32,
    /// Per track: where the next block is written.
    w: [routing.MAX_TRACKS]usize,

    fn clear(self: *PdcHistory) void {
        for (&self.bufs) |*t| for (t) |*tap| for (tap) |*ch| @memset(ch, 0);
        @memset(&self.w, 0);
    }

    /// Stores one tap of track `ti`'s block at the write position, which
    /// `write` then moves past it.
    fn put(self: *PdcHistory, ti: usize, tap: Tap, l: []const f32, r: []const f32) void {
        const at = self.w[ti];
        for ([2][]const f32{ l, r }, 0..) |src, ch| {
            const ring = &self.bufs[ti][@intFromEnum(tap)][ch];
            for (src, 0..) |x, i| ring[(at + i) & (PDC_MAX - 1)] = x;
        }
    }

    /// Appends track `ti`'s taps for the block; returns where it starts.
    fn write(self: *PdcHistory, ti: usize, pre_l: []const f32, pre_r: []const f32, post_l: []const f32, post_r: []const f32) usize {
        const at = self.w[ti];
        self.put(ti, .pre, pre_l, pre_r);
        self.put(ti, .post, post_l, post_r);
        self.w[ti] = (at + pre_l.len) & (PDC_MAX - 1);
        return at;
    }

    /// A block of silence for a track that didn't render, so a delayed
    /// read after it comes back finds no stale audio.
    fn silence(self: *PdcHistory, ti: usize, frames: usize) void {
        const at = self.w[ti];
        for (&self.bufs[ti]) |*tap| for (tap) |*ring| {
            for (0..frames) |i| ring[(at + i) & (PDC_MAX - 1)] = 0;
        };
        self.w[ti] = (at + frames) & (PDC_MAX - 1);
    }

    /// The block written at `at`, `delay` samples late.
    fn read(self: *const PdcHistory, ti: usize, tap: Tap, at: usize, delay: u32, l: []f32, r: []f32) void {
        const k = @intFromEnum(tap);
        const start = at + PDC_MAX - @min(delay, PDC_LIMIT);
        for (l, r, 0..) |*dl, *dr, i| {
            const j = (start + i) & (PDC_MAX - 1);
            dl.* = self.bufs[ti][k][0][j];
            dr.* = self.bufs[ti][k][1][j];
        }
    }
};

/// Samples a track's signal is late at its taps: its instrument's (not a
/// bus's) and its active inserts'.
fn chainLatency(t: *const Track, is_bus: bool) u32 {
    if (!is_bus and t.frozen.load(.acquire)) return 0;
    var n = instLatency(t, is_bus);
    for (t.effects.items, 0..) |*fx, i| {
        if (!t.effectBypassed(i)) n += fx.mach.latencySamples();
    }
    return n;
}

const LocalTime = struct { bpm: f64, beat: f64, bar: u32, beat_in_bar: f64, bar_len: f64 };

/// Where a track is in its own time (docs/28 §Polymeter and polytempo):
/// with a tempo ratio, its beats run p/q as fast from the start of the
/// clip playing (from the song's start between clips); with a meter of
/// its own, its bars are counted in it. Else the song's.
fn localTime(snap: *const snap_mod.TrackSnapshot, beat: f64, bpm: f64, song_bar: meter.MeterMap.BarInfo, song_meter: meter.MeterMap) LocalTime {
    const tt = snap.time;
    if (tt.isDefault()) return .{ .bpm = bpm, .beat = beat, .bar = song_bar.bar, .beat_in_bar = beat - song_bar.bar_start_beat, .bar_len = song_bar.bar_len_beats };
    const r = tt.rate();
    var lb = beat * r;
    if (r != 1) for (snap.clips[0..snap.clip_count]) |c| {
        if (beat >= c.start_beat and beat < c.start_beat + c.length_beats) {
            lb = (beat - c.start_beat) * r;
            break;
        }
    };
    if (tt.hasMeter()) {
        const len = @as(f64, @floatFromInt(tt.num)) * 4 / @as(f64, @floatFromInt(@max(1, tt.den)));
        const bar = @floor(@max(0, lb) / len);
        return .{ .bpm = bpm * r, .beat = lb, .bar = @intFromFloat(bar), .beat_in_bar = lb - bar * len, .bar_len = len };
    }
    const info = song_meter.barInfoAtBeat(lb);
    return .{ .bpm = bpm * r, .beat = lb, .bar = info.bar, .beat_in_bar = lb - info.bar_start_beat, .bar_len = info.bar_len_beats };
}

fn instLatency(t: *const Track, is_bus: bool) u32 {
    return if (!is_bus and t.isEnabled() and !t.frozen.load(.acquire)) t.machine.latencySamples() else 0;
}

/// A frozen track's audio for the block at `block_start` (it starts at
/// the song's start), linear between source samples.
fn playFrozen(fz: snap_mod.FrozenSnap, block_start: u64, frames: u32, sample_rate: u32, l: []f32, r: []f32) void {
    const step = fz.step * 48_000.0 / @as(f64, @floatFromInt(sample_rate));
    const rd = fz.data_r orelse fz.data;
    for (0..frames) |i| {
        const pos = @as(f64, @floatFromInt(block_start + i)) * step;
        const k: usize = @intFromFloat(@floor(pos));
        if (k + 1 >= fz.len) {
            if (k < fz.len) {
                l[i] = @floatCast(fz.data[k]);
                r[i] = @floatCast(rd[k]);
            }
            continue;
        }
        const f = pos - @floor(pos);
        l[i] = @floatCast(fz.data[k] + (fz.data[k + 1] - fz.data[k]) * f);
        r[i] = @floatCast(rd[k] + (rd[k + 1] - rd[k]) * f);
    }
}

/// Idle skipping for one chain (docs/04 §Idle skipping).
const Idle = struct {
    on: bool = false,
    /// The track's instrument has a note sounding or close: every effect
    /// renders, whatever its input.
    wake: bool = false,
};

fn idleHoldSamples(sample_rate: u32) u32 {
    return @intFromFloat(IDLE_HOLD_S * @as(f32, @floatFromInt(sample_rate)));
}

fn renderEffects(
    t: *Track,
    base_ctx: machine.MachineCtx,
    src_l: []f32,
    src_r: []f32,
    scratch_l: []f32,
    scratch_r: []f32,
    idle: Idle,
) RenderedPair {
    return renderEffectsKeyed(t, base_ctx, src_l, src_r, scratch_l, scratch_r, null, idle);
}

fn renderEffectsKeyed(
    t: *Track,
    base_ctx: machine.MachineCtx,
    src_l: []f32,
    src_r: []f32,
    scratch_l: []f32,
    scratch_r: []f32,
    keys: ?Keys,
    idle: Idle,
) RenderedPair {
    const default_hold = idleHoldSamples(@intFromFloat(base_ctx.sample_rate));
    var cur_l = src_l;
    var cur_r = src_r;
    var next_l = scratch_l;
    var next_r = scratch_r;
    // How late the signal is entering each effect (PDC), and a delayed key.
    var lat: u32 = if (keys) |k| k.lat else 0;
    var key_l: [MAX_BLOCK]f32 = undefined;
    var key_r: [MAX_BLOCK]f32 = undefined;

    for (t.effects.items, 0..) |*fx, i| {
        const in_peak = [2]f32{ blockPeak(cur_l), blockPeak(cur_r) };
        if (t.effectBypassed(i)) {
            fx.setIo(in_peak, in_peak); // bypassed → pass through untouched
            continue;
        }
        @memset(next_l, 0);
        @memset(next_r, 0);
        var in_ports = [_][*]const f32{ cur_l.ptr, cur_r.ptr, cur_l.ptr, cur_r.ptr };
        var ctx = base_ctx;
        ctx.note_in = null;
        ctx.note_in_count = 0;
        ctx.audio_in = @ptrCast(&in_ports[0]);
        ctx.audio_in_count = 2;
        if (keys) |k| if (fx.mach.takes_key) if (k.node.keyFor(fx.uid)) |src| if (k.live & routing.bit(src) != 0) {
            in_ports[2] = &k.pre_l[src];
            in_ports[3] = &k.pre_r[src];
            if (k.hist) |h| {
                const d = lat -| k.lat_out.?[src];
                if (d > 0) {
                    const n = cur_l.len;
                    h.read(src, .pre, k.hist_at.?[src], d, key_l[0..n], key_r[0..n]);
                    in_ports[2] = &key_l;
                    in_ports[3] = &key_r;
                }
            }
            ctx.audio_in_count = 4;
        };
        lat += fx.mach.latencySamples();
        // Its input (and key) silent: asleep past its hold, so the chain
        // goes on from silence. Its PDC share stays counted above.
        const quiet_in = idle.on and !idle.wake and @max(in_peak[0], in_peak[1]) <= IDLE_FLOOR and
            (ctx.audio_in_count < 4 or @max(blockPeak(in_ports[2][0..cur_l.len]), blockPeak(in_ports[3][0..cur_l.len])) <= IDLE_FLOOR);
        // A control edit restarts its hold: it renders on until the edit
        // has settled into its params.
        if (idle.on and fx.mach.takeWake()) fx.quiet = 0;
        if (quiet_in) {
            const hold = fx.mach.idleHold(base_ctx.sample_rate, default_hold);
            if (hold != machine.TAIL_FOREVER and fx.quiet >= hold) {
                @memset(cur_l, 0);
                @memset(cur_r, 0);
                fx.setIo(in_peak, .{ 0, 0 });
                continue;
            }
        }
        // Retarget the instrument's lane view at this effect.
        var fx_view: snap_mod.AutoView = undefined;
        if (base_ctx.automation) |p| {
            const inst: *const snap_mod.AutoView = @ptrCast(@alignCast(p));
            fx_view = inst.*;
            fx_view.kind = .fx;
            fx_view.fx_uid = fx.uid;
            ctx.automation = &fx_view;
        }
        fx.mach.render(fx.mach.state, &ctx, next_l, next_r);
        const out_peak = [2]f32{ blockPeak(next_l), blockPeak(next_r) };
        fx.setIo(in_peak, out_peak);
        if (idle.on) fx.quiet = if (quiet_in and @max(out_peak[0], out_peak[1]) <= IDLE_FLOOR) fx.quiet +| @as(u32, @intCast(cur_l.len)) else 0;

        const old_l = cur_l;
        const old_r = cur_r;
        cur_l = next_l;
        cur_r = next_r;
        next_l = old_l;
        next_r = old_r;
    }

    return .{ .l = cur_l, .r = cur_r };
}

const FaderGains = struct { v: f32, l: f32, r: f32 };

/// Track volume × equal-power pan at `beat`, from the lanes unless the
/// hand overrides them (docs/22 §Precedence).
fn faderGains(t: *Track, snap: *const snap_mod.TrackSnapshot, beat: f64) FaderGains {
    var v = t.volume();
    var p = t.pan();
    if (t.vol_override.load(.monotonic) == 0) if (snap.faderValue(.volume, beat, &t.auto_cursors)) |k| {
        v = std.math.clamp(k * 1.25, 0, 1.25);
    };
    if (t.pan_override.load(.monotonic) == 0) if (snap.faderValue(.pan, beat, &t.auto_cursors)) |k| {
        p = std.math.clamp(k * 2 - 1, -1, 1);
    };
    const angle = (p + 1.0) * (std.math.pi / 4.0);
    return .{ .v = v, .l = v * @cos(angle), .r = v * @sin(angle) };
}

fn blockPeak(buf: []const f32) f32 {
    var p: f32 = 0;
    for (buf) |x| p = @max(p, @abs(x));
    return p;
}

/// Mix all audio clips overlapping this block into the planar L/R buffers.
/// Pure read + linear interpolation — no allocation. The source plays from
/// its top at native rate (natural resample to the engine rate); it stops
/// when either the timeline clip window or the source data runs out.
fn mixAudioClips(
    snap: *const snap_mod.TrackSnapshot,
    block_start: u64,
    frames: u32,
    map: *const tempo.TempoMap,
    sample_rate: u32,
    l: []f32,
    r: []f32,
) void {
    const block_lo: f64 = @floatFromInt(block_start);
    const block_hi: f64 = block_lo + @as(f64, @floatFromInt(frames));
    if (snap.stretch) |b| b.beginBlock();

    for (snap.audio_clips[0..snap.audio_clip_count]) |clip| {
        const data = clip.data orelse continue;
        if (clip.len == 0 or clip.source_rate <= 0) continue;

        const clip_start = map.sampleAt(clip.start_beat, sample_rate);
        const clip_end = map.sampleAt(clip.start_beat + clip.length_beats, sample_rate);
        const lo = @max(block_lo, clip_start);
        const hi = @min(block_hi, clip_end);
        if (hi <= lo) continue;
        if (clip.warped) {
            mixWarped(snap, clip, data, block_lo, lo, hi, clip_start, clip_end, frames, map, sample_rate, l, r);
            continue;
        }

        // Source samples advanced per engine output sample.
        const engine_rate: f64 = @floatFromInt(sample_rate);
        const step = clip.source_rate / engine_rate;
        const len = clip.len;
        const flen: f64 = @floatFromInt(len);

        var a = lo;
        while (a < hi) : (a += 1) {
            const i: usize = @intFromFloat(a - block_lo);
            if (i >= frames) break;
            const pos = (a - clip_start) * step; // samples into the window
            // Reversed: the window's last sample first, down to its first.
            const src_pos = if (clip.reversed)
                clip.start_sample + clip.dur_samples - 1 - pos
            else
                clip.start_sample + pos;
            if (src_pos <= -1) {
                if (clip.reversed) break; // read past the source head
                continue;
            }
            if (src_pos >= flen) {
                if (clip.reversed) continue; // window runs past the source end: silent until it's back in
                break; // source exhausted — rest of clip is silent
            }
            const v = warp_mod.read(data, clip.data_r, len, src_pos, step);
            // Linear fade-in/out envelope over the played window.
            var fade: f64 = 1.0;
            if (clip.fade_in_samples > 0 and pos < clip.fade_in_samples)
                fade = pos / clip.fade_in_samples;
            if (clip.fade_out_samples > 0) {
                const remaining = clip.dur_samples - pos;
                if (remaining < clip.fade_out_samples)
                    fade = @min(fade, @max(0.0, remaining) / clip.fade_out_samples);
            }
            const g = clip.gain * @as(f32, @floatCast(fade));
            l[i] += v[0] * g;
            r[i] += v[1] * g;
        }
    }
}

/// A warped clip (docs/29 §The path to the source): each output sample's
/// song beat through the track's ratio and the clip's offset to a content
/// beat, through the markers to a source second, read band-limited at the
/// local ratio. TAPE; the other modes play as it until they're built.
fn mixWarped(
    snap: *const snap_mod.TrackSnapshot,
    clip: snap_mod.AudioClipSnap,
    data: [*]const f64,
    block_lo: f64,
    lo: f64,
    hi: f64,
    clip_start: f64,
    clip_end: f64,
    frames: u32,
    map: *const tempo.TempoMap,
    sample_rate: u32,
    l: []f32,
    r: []f32,
) void {
    const wmap = warp_mod.Map{ .m = snap.warp_points[clip.warp_start..][0..clip.warp_count] };
    if (clip.mode == .beats and (clip.preserve != .hits or clip.onsets != null)) {
        mixBeats(clip, wmap, data, block_lo, lo, hi, clip_start, clip_end, frames, map, sample_rate, l, r);
        return;
    }
    if (warp_mod.stretches(clip.mode)) if (snap.stretch) |bank| {
        const t0: i64 = @intFromFloat(@floor(clip_start));
        if (clip.mode == .smear) {
            const n = stretch_mod.SMEAR_SIZES[@min(clip.smear_size, stretch_mod.SMEAR_SIZES.len - 1)];
            if (bank.getSmear(clip.uid, t0, n)) |sm| {
                mixStretched(sm, clip, wmap, data, block_lo, lo, hi, clip_start, clip_end, frames, map, sample_rate, l, r);
                return;
            }
        } else {
            const kind: stretch_mod.Kind = if (clip.mode == .voice) .voice else .mix;
            const grain: i64 = @intFromFloat(@as(f64, @floatFromInt(clip.grain_ms)) * @as(f64, @floatFromInt(sample_rate)) / 1000);
            if (bank.get(clip.uid, t0, kind, grain)) |st| {
                mixStretched(st, clip, wmap, data, block_lo, lo, hi, clip_start, clip_end, frames, map, sample_rate, l, r);
                return;
            }
        }
    };
    // No stretcher free: it plays as TAPE.
    const engine_rate: f64 = @floatFromInt(sample_rate);
    const flen: f64 = @floatFromInt(clip.len);
    const fade_in = clip.fade_in_samples / clip.source_rate * engine_rate;
    const fade_out = clip.fade_out_samples / clip.source_rate * engine_rate;
    const Pos = struct {
        fn at(c: snap_mod.AudioClipSnap, wm: warp_mod.Map, m: *const tempo.TempoMap, sr: u32, n: f64, a: f64) f64 {
            const b = m.beatAtSample(a, sr);
            const s = wm.secAt((b - c.start_beat) * c.rate + c.offset_beats) * c.source_rate;
            return if (c.reversed) n - 1 - s else s;
        }
    };
    var prev = Pos.at(clip, wmap, map, sample_rate, flen, lo - 1);
    var a = lo;
    while (a < hi) : (a += 1) {
        const i: usize = @intFromFloat(a - block_lo);
        if (i >= frames) break;
        const pos = Pos.at(clip, wmap, map, sample_rate, flen, a);
        const ratio = @abs(pos - prev);
        prev = pos;
        const v = warp_mod.read(data, clip.data_r, clip.len, pos, ratio);
        var fade: f64 = 1.0;
        const from_start = a - clip_start;
        const to_end = clip_end - a;
        if (fade_in > 0 and from_start < fade_in) fade = from_start / fade_in;
        if (fade_out > 0 and to_end < fade_out) fade = @min(fade, @max(0.0, to_end) / fade_out);
        const g = clip.gain * @as(f32, @floatCast(fade));
        l[i] += v[0] * g;
        r[i] += v[1] * g;
    }
}

/// MIX, VOICE and SMEAR (docs/29 §The algorithms): the clip through its
/// stretcher or smearer, whose frames ask the maps where the source is at
/// each output time.
fn mixStretched(
    st: anytype,
    clip: snap_mod.AudioClipSnap,
    wmap: warp_mod.Map,
    data: [*]const f64,
    block_lo: f64,
    lo: f64,
    hi: f64,
    clip_start: f64,
    clip_end: f64,
    frames: u32,
    map: *const tempo.TempoMap,
    sample_rate: u32,
    l: []f32,
    r: []f32,
) void {
    const engine_rate: f64 = @floatFromInt(sample_rate);
    const Ctx = struct {
        clip: snap_mod.AudioClipSnap,
        wmap: warp_mod.Map,
        map: *const tempo.TempoMap,
        sr: u32,
        step: f64,

        pub fn pos(self: @This(), t: f64) f64 {
            const b = self.map.beatAtSample(t, self.sr);
            return self.wmap.secAt((b - self.clip.start_beat) * self.clip.rate + self.clip.offset_beats) * self.clip.source_rate;
        }

        /// A transient between two source positions: a phase reset. Reversed
        /// clips have their hits' tails there, so they don't reset.
        pub fn hit(self: @This(), p0: f64, p1: f64) bool {
            const on = self.clip.onsets orelse return false;
            if (self.clip.reversed or p1 <= p0) return false;
            const s0 = p0 / self.clip.source_rate;
            const s1 = p1 / self.clip.source_rate;
            const xs = on[0..self.clip.onset_count];
            var lo_i: usize = 0;
            var hi_i: usize = xs.len;
            while (lo_i < hi_i) {
                const mid = (lo_i + hi_i) / 2;
                if (xs[mid] <= s0) lo_i = mid + 1 else hi_i = mid;
            }
            return lo_i < xs.len and xs[lo_i] <= s1;
        }
    };
    const ctx = Ctx{ .clip = clip, .wmap = wmap, .map = map, .sr = sample_rate, .step = clip.source_rate / engine_rate * clip.pitch };
    const src = stretch_mod.Source{ .l = data, .r = clip.data_r, .len = clip.len, .reversed = clip.reversed, .rate = clip.source_rate };
    const fade_in = clip.fade_in_samples / clip.source_rate * engine_rate;
    const fade_out = clip.fade_out_samples / clip.source_rate * engine_rate;
    var i: usize = @intFromFloat(@max(0, @ceil(lo - block_lo)));
    const end: usize = @min(frames, @as(usize, @intFromFloat(@max(0, @ceil(hi - block_lo)))));
    var gains: [256]f32 = undefined;
    while (i < end) {
        const n = @min(gains.len, end - i);
        for (gains[0..n], 0..) |*g, k| {
            const a = block_lo + @as(f64, @floatFromInt(i + k));
            var fade: f64 = 1.0;
            const from_start = a - clip_start;
            const to_end = clip_end - a;
            if (fade_in > 0 and from_start < fade_in) fade = @max(0, from_start) / fade_in;
            if (fade_out > 0 and to_end < fade_out) fade = @min(fade, @max(0.0, to_end) / fade_out);
            g.* = clip.gain * @as(f32, @floatCast(fade));
        }
        st.render(src, ctx, @as(i64, @intFromFloat(block_lo)) + @as(i64, @intCast(i)), l[i..][0..n], r[i..][0..n], gains[0..n]);
        i += n;
    }
}

/// BEATS (docs/29 §BEATS): the content cut into slices, at the source's
/// transients or on a grid of content beats; each slice starts where its
/// first moment maps to and plays at native speed. A stretched slice runs
/// out before the next starts (GAP: silence or its tail looped); a
/// squeezed one is cut. Slices meet in a 1 ms crossfade that ends on the
/// next one's hit, so the hit itself is untouched. Stateless: every
/// sample is computed from the maps, so seeks and loops cost nothing.
fn mixBeats(
    clip: snap_mod.AudioClipSnap,
    wmap: warp_mod.Map,
    data: [*]const f64,
    block_lo: f64,
    lo: f64,
    hi: f64,
    clip_start: f64,
    clip_end: f64,
    frames: u32,
    map: *const tempo.TempoMap,
    sample_rate: u32,
    l: []f32,
    r: []f32,
) void {
    const engine_rate: f64 = @floatFromInt(sample_rate);
    // Native speed, re-pitched by TRANSPOSE and FINE.
    const step = clip.source_rate / engine_rate * clip.pitch;
    const fade_in = clip.fade_in_samples / clip.source_rate * engine_rate;
    const fade_out = clip.fade_out_samples / clip.source_rate * engine_rate;
    const xf = 0.001 * engine_rate; // the seam
    const S = Slicer{
        .clip = clip,
        .wmap = wmap,
        .map = map,
        .sr = sample_rate,
        .len_sec = @as(f64, @floatFromInt(clip.len)) / clip.source_rate,
    };
    var k: i64 = std.math.minInt(i64);
    var cur: Slicer.Slice = undefined;
    var next: Slicer.Slice = undefined;
    var a = lo;
    while (a < hi) : (a += 1) {
        const i: usize = @intFromFloat(a - block_lo);
        if (i >= frames) break;
        const cb = S.contentAt(a);
        const kk = S.index(cb);
        if (kk != k) {
            k = kk;
            cur = S.slice(k);
            next = S.slice(k + 1);
        }
        var v = S.play(data, cur, next.t, a, step);
        // The next slice fades in over the last millisecond before its hit.
        if (a > next.t - xf) {
            const w: f32 = @floatCast((a - (next.t - xf)) / xf);
            const nv = S.play(data, next, std.math.inf(f64), a, step);
            v = .{ v[0] * (1 - w) + nv[0] * w, v[1] * (1 - w) + nv[1] * w };
        }
        var fade: f64 = 1.0;
        const from_start = a - clip_start;
        const to_end = clip_end - a;
        if (fade_in > 0 and from_start < fade_in) fade = from_start / fade_in;
        if (fade_out > 0 and to_end < fade_out) fade = @min(fade, @max(0.0, to_end) / fade_out);
        const g = clip.gain * @as(f32, @floatCast(fade));
        l[i] += v[0] * g;
        r[i] += v[1] * g;
    }
}

const Slicer = struct {
    clip: snap_mod.AudioClipSnap,
    wmap: warp_mod.Map,
    map: *const tempo.TempoMap,
    sr: u32,
    len_sec: f64,

    /// A slice: its first and last source second (in the clip's source,
    /// mirrored when reversed) and the output sample it starts on.
    const Slice = struct { s0: f64, s1: f64, t: f64, t_next: f64 };

    fn contentAt(self: Slicer, a: f64) f64 {
        return (self.map.beatAtSample(a, self.sr) - self.clip.start_beat) * self.clip.rate + self.clip.offset_beats;
    }

    fn outAt(self: Slicer, cb: f64) f64 {
        return self.map.sampleAt(self.clip.start_beat + (cb - self.clip.offset_beats) / self.clip.rate, self.sr);
    }

    /// Slice boundary `j` in source seconds: the source's start, then each
    /// transient (mirrored, reversed).
    fn bound(self: Slicer, j: i64) f64 {
        const n: i64 = self.clip.onset_count;
        if (j <= 0) return if (j == 0) 0 else -std.math.inf(f64);
        if (j > n) return std.math.inf(f64);
        const on = self.clip.onsets.?;
        return if (self.clip.reversed)
            self.len_sec - on[@intCast(n - j)]
        else
            on[@intCast(j - 1)];
    }

    fn index(self: Slicer, cb: f64) i64 {
        if (self.clip.preserve.beats()) |div| return @intFromFloat(@floor(cb / div));
        const s = self.wmap.secAt(cb);
        if (s < 0) return -1;
        var lo: i64 = 0;
        var hi: i64 = self.clip.onset_count + 1;
        while (hi - lo > 1) {
            const mid = @divFloor(lo + hi, 2);
            if (self.bound(mid) <= s) lo = mid else hi = mid;
        }
        return lo;
    }

    fn slice(self: Slicer, k: i64) Slice {
        if (self.clip.preserve.beats()) |div| {
            const b0 = @as(f64, @floatFromInt(k)) * div;
            const b1 = b0 + div;
            return .{ .s0 = self.wmap.secAt(b0), .s1 = self.wmap.secAt(b1), .t = self.outAt(b0), .t_next = self.outAt(b1) };
        }
        const s0 = self.bound(k);
        const s1 = @min(self.bound(k + 1), self.len_sec);
        // Before the source, or past its last slice: never sounds.
        if (std.math.isInf(s0)) return .{ .s0 = s0, .s1 = s1, .t = s0, .t_next = std.math.inf(f64) };
        const t = self.outAt(self.wmap.beatAt(s0));
        const t_next = if (std.math.isInf(self.bound(k + 1))) std.math.inf(f64) else self.outAt(self.wmap.beatAt(s1));
        return .{ .s0 = s0, .s1 = s1, .t = t, .t_next = t_next };
    }

    /// Slice `sl` at output sample `a`: its own audio at native speed from
    /// its start, then the gap; `until` is where the next one takes over
    /// (the decay's span).
    fn play(self: Slicer, data: [*]const f64, sl: Slice, until: f64, a: f64, step: f64) [2]f32 {
        if (std.math.isInf(sl.s0)) return .{ 0, 0 };
        const c = self.clip;
        const flen: f64 = @floatFromInt(c.len);
        const e = (a - sl.t) * step; // source samples into the slice
        const own = (sl.s1 - sl.s0) * c.source_rate;
        var p = e;
        var g: f32 = 1;
        if (e > own) switch (c.gap) {
            .cut => {
                // 2 ms out past its end.
                const over = (e - own) / (0.002 * c.source_rate);
                if (over >= 1) return .{ 0, 0 };
                g = @floatCast(1 - over);
            },
            .loop => {
                // Back and forth over its last half (at most 50 ms).
                const span = @max(1, @min(own / 2, 0.05 * c.source_rate));
                const ph = @mod(e - own, 2 * span);
                p = if (ph < span) own - ph else own - 2 * span + ph;
            },
        };
        if (c.decay < 1) {
            const span = @min(until, sl.t_next) - sl.t;
            if (span > 0 and !std.math.isInf(span)) {
                const env = 1 - (a - sl.t) / (@as(f64, c.decay) * span);
                g *= @floatCast(std.math.clamp(env, 0, 1));
            }
        }
        const s = sl.s0 * c.source_rate + p;
        const pos = if (c.reversed) flen - 1 - s else s;
        const v = warp_mod.read(data, c.data_r, c.len, pos, step);
        return .{ v[0] * g, v[1] * g };
    }
};

/// A chased note with less than this left (5 ms at 48 kHz) stays silent:
/// it would only click.
const CHASE_MIN_SAMPLES: f64 = 240;

fn gatherEvents(
    snap: *const snap_mod.TrackSnapshot,
    beat_start: f64,
    beat_end: f64,
    samples_per_beat: f64,
    frames: u32,
    /// Also start the notes already sounding at beat_start (chase).
    chase: bool,
    /// The playhead jumped here from this beat: end the notes that were
    /// sounding there, first thing in the block.
    release_at: ?f64,
    out: *[MAX_EVENTS_PER_TRACK]machine.NoteEvent,
) usize {
    var count: usize = 0;

    for (snap.clips[0..snap.clip_count]) |clip| {
        const clip_end = clip.start_beat + clip.length_beats;
        // A grooved note may play a little before its clip (docs/28 §Groove).
        const in_block = clip_end > beat_start and clip.start_beat - groove_mod.MAX_MOVE_BEATS < beat_end;
        const at_release = if (release_at) |rb| clip.start_beat < rb and clip_end > rb else false;
        if (!in_block and !at_release) continue;

        const note_slice = snap.notes[clip.notes_start..][0..clip.notes_count];
        for (note_slice, 0..) |note, j| {
            const abs_on = clip.start_beat + note.start_beat;
            const abs_off_raw = abs_on + note.length_beats;
            const abs_off = @min(abs_off_raw, clip_end);
            // The note's index in the snapshot is its id: note-offs and
            // expression find their voice by it, bent or not.
            const note_id: i32 = @intCast(clip.notes_start + j);
            if (note.hasExpression() and abs_on < beat_end and abs_off > beat_start and note.start_beat < clip.length_beats) {
                count = gatherExpression(snap, note, note_id, abs_on, abs_off, beat_start, samples_per_beat, frames, out, count);
            }

            // A jump: notes sounding where the playhead left end, notes under
            // where it landed start (chase). One sounding at both carries on.
            const audible = note.start_beat < clip.length_beats;
            const held = if (release_at) |rb| audible and abs_on < rb and abs_off > rb else false;
            const chased = chase and audible and abs_on < beat_start and abs_off > beat_start and
                (abs_off - beat_start) * samples_per_beat >= CHASE_MIN_SAMPLES;
            if (held != chased and count < MAX_EVENTS_PER_TRACK) {
                out[count] = .{
                    .sample_offset = 0,
                    .kind = if (held) .note_off else .note_on,
                    .channel = 0,
                    .note_id = note_id,
                    .pitch = @floatFromInt(note.pitch),
                    .velocity = if (held) 0 else @as(f32, @floatFromInt(note.velocity)) / 127.0,
                };
                count += 1;
            }
            if (abs_on >= beat_start and abs_on < beat_end) {
                if (count < MAX_EVENTS_PER_TRACK) {
                    const raw_fo: f64 = (abs_on - beat_start) * samples_per_beat;
                    var fo: u32 = 0;
                    if (raw_fo > 0) fo = @intFromFloat(@round(raw_fo));
                    if (fo >= frames) fo = frames - 1;
                    out[count] = .{
                        .sample_offset = fo,
                        .kind = .note_on,
                        .channel = 0,
                        .note_id = note_id,
                        .pitch = @floatFromInt(note.pitch),
                        .velocity = @as(f32, @floatFromInt(note.velocity)) / 127.0,
                    };
                    count += 1;
                }
            }
            if (abs_off > beat_start and abs_off <= beat_end) {
                if (count < MAX_EVENTS_PER_TRACK) {
                    const raw_fo: f64 = (abs_off - beat_start) * samples_per_beat;
                    var fo: u32 = 0;
                    if (raw_fo > 0) fo = @intFromFloat(@round(raw_fo));
                    if (fo >= frames) fo = frames - 1;
                    out[count] = .{
                        .sample_offset = fo,
                        .kind = .note_off,
                        .channel = 0,
                        .note_id = note_id,
                        .pitch = @floatFromInt(note.pitch),
                        .velocity = 0,
                    };
                    count += 1;
                }
            }
        }
    }

    // Sort ascending by sample_offset.
    std.mem.sort(machine.NoteEvent, out[0..count], {}, struct {
        fn lt(_: void, a: machine.NoteEvent, b: machine.NoteEvent) bool {
            if (a.sample_offset != b.sample_offset) return a.sample_offset < b.sample_offset;
            return noteKindOrder(a.kind) < noteKindOrder(b.kind);
        }
    }.lt);
    return count;
}

/// Whether a note sounds anywhere in [lo, hi) beats (idle skipping).
fn notesNear(snap: *const snap_mod.TrackSnapshot, lo: f64, hi: f64) bool {
    for (snap.clips[0..snap.clip_count]) |clip| {
        const clip_end = clip.start_beat + clip.length_beats;
        if (clip_end <= lo or clip.start_beat - groove_mod.MAX_MOVE_BEATS >= hi) continue;
        for (snap.notes[clip.notes_start..][0..clip.notes_count]) |note| {
            if (note.start_beat >= clip.length_beats) continue;
            const on = clip.start_beat + note.start_beat;
            const off = @min(on + note.length_beats, clip_end);
            if (on < hi and off > lo) return true;
        }
    }
    return false;
}

/// Expression events for one bent note inside this block: at its note-on
/// (if it starts here) and every EXPR_STEP samples while it sounds.
fn gatherExpression(
    snap: *const snap_mod.TrackSnapshot,
    note: snap_mod.NoteSnap,
    note_id: i32,
    abs_on: f64,
    abs_off: f64,
    beat_start: f64,
    samples_per_beat: f64,
    frames: u32,
    out: *[MAX_EVENTS_PER_TRACK]machine.NoteEvent,
    count_in: usize,
) usize {
    var count = count_in;
    const pts = snap.expr_points[note.expr_start..][0..note.expr_count];
    const base: f32 = @floatFromInt(note.pitch);
    var k: u32 = 0;
    // A note starting in this block gets its first value at its own onset.
    const on_off: f64 = (abs_on - beat_start) * samples_per_beat;
    if (on_off > 0) k = @intFromFloat(@round(on_off));
    while (k < frames and count < MAX_EVENTS_PER_TRACK) {
        const beat = beat_start + @as(f64, @floatFromInt(k)) / samples_per_beat;
        if (beat >= abs_off) break;
        if (beat >= abs_on - 1e-9) {
            const nb = @max(0, beat - abs_on);
            const bend: f32 = if (pts.len > 0) std.math.clamp(automation.eval(pts, nb), -48, 48) else 0;
            var dv = [3]f32{ 0.5, 0, 0 }; // pressure, slide, gain dB at rest
            for (0..3) |d| {
                const dp = note.dimPoints(snap, d);
                if (dp.len > 0) dv[d] = automation.eval(dp, nb);
            }
            out[count] = .{
                .sample_offset = k,
                .kind = .expression,
                .channel = 0,
                .note_id = note_id,
                .pitch = base + bend,
                .velocity = 0,
                .pressure = dv[0],
                .slide = dv[1],
                .value = dv[2],
            };
            count += 1;
        }
        k = (k / EXPR_STEP + 1) * EXPR_STEP;
    }
    return count;
}

fn noteKindOrder(kind: machine.NoteKind) u8 {
    return switch (kind) {
        .note_off, .reset => 0,
        .note_on => 1,
        else => 2,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeSnap(clips: []const struct {
    start: f64,
    len: f64,
    notes: []const struct { start: f64, len: f64, pitch: u8 },
}) snap_mod.TrackSnapshot {
    var s = snap_mod.TrackSnapshot{};
    for (clips) |c| {
        const ci = s.clip_count;
        s.clips[ci] = .{
            .start_beat = c.start,
            .length_beats = c.len,
            .notes_start = s.note_count,
            .notes_count = @intCast(c.notes.len),
        };
        s.clip_count += 1;
        for (c.notes) |n| {
            s.notes[s.note_count] = .{
                .start_beat = n.start,
                .length_beats = n.len,
                .pitch = n.pitch,
                .velocity = 100,
            };
            s.note_count += 1;
        }
    }
    return s;
}

test "gatherEvents: note-on and note-off in same block" {
    const spb = 48.0; // samples per beat (arbitrary)
    const frames: u32 = 96;
    // One clip [0..4], one note [0..1].
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{.{ .start = 0, .len = 1, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block covers beats [0..2): note-on at beat 0, note-off at beat 1.
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, false, null, &events);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(events[0].kind == .note_on);
    try testing.expectEqual(@as(f32, 60), events[0].pitch);
    try testing.expectEqual(@as(u32, 0), events[0].sample_offset);
    try testing.expect(events[1].kind == .note_off);
    try testing.expectEqual(@as(u32, 48), events[1].sample_offset);
}

test "gatherEvents: chase starts the notes already sounding, unless nearly over" {
    const spb = 24_000.0; // 120 BPM at 48 kHz
    const frames: u32 = 512;
    // Clip [0..8]: a pad [0..4], a note [1..2.005] with 2.5 ms left at
    // beat 2, and one [2.5..3] still to come.
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 8,
        .notes = &.{
            .{ .start = 0, .len = 4, .pitch = 48 },
            .{ .start = 1, .len = 1.005, .pitch = 60 },
            .{ .start = 2.5, .len = 0.5, .pitch = 64 },
        },
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;
    const b0 = 2.0;
    const b1 = b0 + @as(f64, frames) / spb;

    // Playing on: nothing starts, the short note ends.
    try testing.expectEqual(@as(usize, 1), gatherEvents(&snap, b0, b1, spb, frames, false, null, &events));
    try testing.expect(events[0].kind == .note_off);

    // After a seek to beat 2: the pad starts at the block's first sample;
    // the note with 120 samples left doesn't, and ends as usual.
    const n = gatherEvents(&snap, b0, b1, spb, frames, true, null, &events);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(events[0].kind == .note_on);
    try testing.expectEqual(@as(f32, 48), events[0].pitch);
    try testing.expectEqual(@as(u32, 0), events[0].sample_offset);
    try testing.expect(events[1].kind == .note_off);
    try testing.expectEqual(@as(f32, 60), events[1].pitch);
}

test "gatherEvents: note-off fires when note ends" {
    const spb = 48.0;
    const frames: u32 = 96;
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{.{ .start = 0, .len = 1, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block covers beats [0.5..2.5): note-off at beat 1 = sample offset 24.
    const n = gatherEvents(&snap, 0.5, 2.5, spb, frames, false, null, &events);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(events[0].kind == .note_off);
    try testing.expectEqual(@as(u32, 24), events[0].sample_offset);
    // An end on a block's first beat went out with the block before it.
    try testing.expectEqual(@as(usize, 0), gatherEvents(&snap, 1.0, 3.0, spb, frames, false, null, &events));
}

test "gatherEvents: note outside block produces no events" {
    const spb = 48.0;
    const frames: u32 = 96;
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{.{ .start = 3, .len = 1, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block covers beats [0..2): note starts at beat 3 — no events.
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, false, null, &events);
    try testing.expectEqual(@as(usize, 0), n);
}

test "gatherEvents: clip entirely before block is skipped" {
    const spb = 48.0;
    const frames: u32 = 96;
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 2,
        .notes = &.{.{ .start = 0, .len = 1, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block covers beats [4..6): clip ends at beat 2 — no events.
    const n = gatherEvents(&snap, 4.0, 6.0, spb, frames, false, null, &events);
    try testing.expectEqual(@as(usize, 0), n);
}

test "gatherEvents: events are sorted by sample_offset" {
    const spb = 48.0;
    const frames: u32 = 192;
    // Two notes starting at beats 1 and 0 (out of order in the note list).
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{
            .{ .start = 1, .len = 0.5, .pitch = 62 },
            .{ .start = 0, .len = 0.5, .pitch = 60 },
        },
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block [0..4): both note-ons fire. Sorted: pitch 60 (offset 0) < pitch 62 (offset 48).
    const n = gatherEvents(&snap, 0, 4.0, spb, frames, false, null, &events);
    try testing.expect(n >= 2);
    try testing.expect(events[0].sample_offset <= events[1].sample_offset);
}

test "gatherEvents: note clamped to clip end" {
    const spb = 48.0;
    const frames: u32 = 96;
    // Clip ends at beat 1; note extends past it to beat 2.
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 1,
        .notes = &.{.{ .start = 0, .len = 2, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block [0..2): note-on at 0, note-off clamped to clip end at beat 1.
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, false, null, &events);
    try testing.expectEqual(@as(usize, 2), n);
    // After sort: note-on (offset 0) < note-off (offset 48).
    try testing.expect(events[0].kind == .note_on);
    try testing.expect(events[1].kind == .note_off);
    try testing.expectEqual(@as(u32, 48), events[1].sample_offset);
}

/// A constant tempo of `spb` samples per beat at 48 kHz (past the BPM
/// limits, as the tests like round numbers).
fn spbMap(spb: f64) tempo.TempoMap {
    var m = tempo.TempoMap.constant(120);
    m.points[0].bpm = 60.0 * 48_000.0 / spb;
    return m;
}

test "mixAudioClips: places source at clip start and resamples by rate" {
    // A slow sine at 24 kHz, read from sample 64 so the kernel sees source
    // on both sides.
    var data: [256]f64 = undefined;
    for (&data, 0..) |*s, i| s.* = @sin(@as(f64, @floatFromInt(i)) * 0.05);

    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 1.0,
        .length_beats = 4.0,
        .data = &data,
        .len = data.len,
        .source_rate = 24_000,
        .start_sample = 64,
        .gain = 1.0,
    };

    const spb: f64 = 100.0; // samples per beat → clip starts at sample 100
    var l = [_]f32{0} ** 8;
    var r = [_]f32{0} ** 8;
    // Block starting exactly at the clip's first sample.
    mixAudioClips(&snap, 100, 8, &spbMap(spb), 48_000, &l, &r);

    // step = 24000/48000 = 0.5 → src positions 64, 64.5, 65, ... band-limited.
    for (l, 0..) |v, k| {
        const want = @sin((64 + @as(f64, @floatFromInt(k)) * 0.5) * 0.05);
        try testing.expectApproxEqAbs(@as(f32, @floatCast(want)), v, 1e-3);
    }
    try testing.expectEqual(@as(f32, @floatCast(data[64])), l[0]);
    // L and R are fed identically (mono source).
    for (l, r) |lv, rv| try testing.expectEqual(lv, rv);
}

test "mixAudioClips: silent before clip start and after source ends" {
    var data = [_]f64{ 0.5, 0.5 };
    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 1.0,
        .length_beats = 8.0,
        .data = &data,
        .len = data.len,
        .source_rate = 48_000,
        .gain = 1.0,
    };
    const spb: f64 = 4.0; // clip starts at sample 4

    var l = [_]f32{0} ** 8;
    var r = [_]f32{0} ** 8;
    // Block [0,8): samples 0..3 are before the clip, 4..5 read the source,
    // 6..7 are past the 2-sample source (silent).
    mixAudioClips(&snap, 0, 8, &spbMap(spb), 48_000, &l, &r);
    try testing.expectEqual(@as(f32, 0), l[0]);
    try testing.expectEqual(@as(f32, 0), l[3]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), l[4], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), l[5], 1e-5);
    try testing.expectEqual(@as(f32, 0), l[6]);
    try testing.expectEqual(@as(f32, 0), l[7]);
}

test "mixAudioClips: start_sample offsets into the source (split clips)" {
    var data: [8]f64 = undefined;
    for (&data, 0..) |*s, i| s.* = @floatFromInt(i);

    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 0,
        .length_beats = 4,
        .data = &data,
        .len = data.len,
        .source_rate = 48_000,
        .start_sample = 3, // begin reading at source sample 3
        .gain = 1.0,
    };
    var l = [_]f32{0} ** 4;
    var r = [_]f32{0} ** 4;
    // Engine rate == source rate → step 1, so out[i] = data[3+i].
    mixAudioClips(&snap, 0, 4, &spbMap(100.0), 48_000, &l, &r);
    try testing.expectApproxEqAbs(@as(f32, 3), l[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 4), l[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5), l[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 6), l[3], 1e-5);
}

test "mixAudioClips: linear fade-in/out ramps the window edges" {
    // 8-sample window, value 1.0 everywhere; fade in/out of 2 samples each.
    var data = [_]f64{1.0} ** 8;
    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 0,
        .length_beats = 8,
        .data = &data,
        .len = data.len,
        .source_rate = 48_000,
        .start_sample = 0,
        .dur_samples = 8,
        .fade_in_samples = 2,
        .fade_out_samples = 2,
        .gain = 1.0,
    };
    var l = [_]f32{0} ** 8;
    var r = [_]f32{0} ** 8;
    mixAudioClips(&snap, 0, 8, &spbMap(100.0), 48_000, &l, &r);
    // fade-in: pos 0 → 0.0, pos 1 → 0.5; middle → 1.0; fade-out near the end.
    try testing.expectApproxEqAbs(@as(f32, 0.0), l[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), l[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l[3], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l[4], 1e-5);
    // pos 7 → remaining 1 → 0.5; (pos 8 would be 0 but window/source end at 8).
    try testing.expectApproxEqAbs(@as(f32, 0.5), l[7], 1e-5);
}

test "mixAudioClips: a reversed clip reads its window end to start, fades in clip time" {
    var data = [_]f64{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 0,
        .length_beats = 1,
        .data = &data,
        .len = data.len,
        .source_rate = 48_000,
        .start_sample = 2, // window = source 2..7
        .dur_samples = 6,
        .fade_in_samples = 2,
        .gain = 1.0,
        .reversed = true,
    };
    var l = [_]f32{0} ** 6;
    var r = [_]f32{0} ** 6;
    mixAudioClips(&snap, 0, 6, &spbMap(6.0), 48_000, &l, &r);
    // 7, 6, 5, 4, 3, 2 with the fade-in on the first two (0, 0.5).
    try testing.expectApproxEqAbs(@as(f32, 0), l[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3), l[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5), l[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2), l[5], 1e-5);
}

test "mixAudioClips: a stereo source plays its channels apart" {
    var dl = [_]f64{ 1, 2, 3, 4 };
    var dr = [_]f64{ -1, -2, -3, -4 };
    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 0,
        .length_beats = 1,
        .data = &dl,
        .data_r = &dr,
        .len = dl.len,
        .source_rate = 48_000,
        .dur_samples = 4,
        .gain = 0.5,
    };
    var l = [_]f32{0} ** 4;
    var r = [_]f32{0} ** 4;
    mixAudioClips(&snap, 0, 4, &spbMap(4.0), 48_000, &l, &r);
    try testing.expectApproxEqAbs(@as(f32, 0.5), l[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), r[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), l[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -2.0), r[3], 1e-6);
}

test "mixAudioClips: a warped clip reads through its markers, offset and reversed" {
    var data: [512]f64 = undefined;
    for (&data, 0..) |*s, i| s.* = @sin(@as(f64, @floatFromInt(i)) * 0.02);
    var snap = snap_mod.TrackSnapshot{};
    // 8 source samples per beat; at 4 output samples per beat that's 2×.
    snap.warp_points[0] = .{ .sec = 0, .beat = 0 };
    snap.warp_points[1] = .{ .sec = 8.0 / 48_000.0, .beat = 1 };
    snap.warp_point_count = 2;
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 0,
        .length_beats = 16,
        .data = &data,
        .len = data.len,
        .source_rate = 48_000,
        .gain = 1.0,
        .warped = true,
        .offset_beats = 16, // from source sample 128
        .warp_start = 0,
        .warp_count = 2,
    };
    var l = [_]f32{0} ** 16;
    var r = [_]f32{0} ** 16;
    mixAudioClips(&snap, 0, 16, &spbMap(4.0), 48_000, &l, &r);
    for (l, 0..) |v, k| try testing.expectApproxEqAbs(@as(f32, @floatCast(data[128 + 2 * k])), v, 2e-3);

    // Reversed: the source mirrored, sample n−1−s.
    snap.audio_clips[0].reversed = true;
    @memset(&l, 0);
    @memset(&r, 0);
    mixAudioClips(&snap, 0, 16, &spbMap(4.0), 48_000, &l, &r);
    for (l, 0..) |v, k| try testing.expectApproxEqAbs(@as(f32, @floatCast(data[511 - 128 - 2 * k])), v, 2e-3);
}

test "mixAudioClips: BEATS plays each slice at native speed from where its hit lands" {
    const alloc = testing.allocator;
    // Two 1 kHz blips 0.6 s apart (100 BPM), the second at sample 28800.
    const data = try alloc.alloc(f64, 57_600);
    defer alloc.free(data);
    for (data, 0..) |*v, i| {
        const j = i % 28_800;
        const fj: f64 = @floatFromInt(j);
        // A blip, over a quiet hum for LOOP to have something to loop.
        v.* = 0.1 * @sin(2 * std.math.pi * 200 * fj / 48_000.0) + if (j < 2400) 0.8 * @sin(2 * std.math.pi * 1000 * fj / 48_000.0) else 0;
    }
    const onsets = [_]f64{0.6};
    var snap = try alloc.create(snap_mod.TrackSnapshot);
    defer alloc.destroy(snap);
    snap.* = .{};
    snap.warp_points[0] = .{ .sec = 0, .beat = 0 };
    snap.warp_points[1] = .{ .sec = 1.2, .beat = 2 };
    snap.warp_point_count = 2;
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 0,
        .length_beats = 2,
        .data = data.ptr,
        .len = @intCast(data.len),
        .source_rate = 48_000,
        .warped = true,
        .mode = .beats,
        .warp_count = 2,
        .onsets = &onsets,
        .onset_count = 1,
    };
    const l = try alloc.alloc(f32, 96_000);
    defer alloc.free(l);
    const r = try alloc.alloc(f32, 96_000);
    defer alloc.free(r);
    // At 120 BPM (24000 samples a beat) the second hit lands on 24000,
    // squeezed, and is the source sample for sample from there.
    for ([_]f64{ 24_000, 36_000 }) |spb| {
        @memset(l, 0);
        @memset(r, 0);
        mixAudioClips(snap, 0, 96_000, &spbMap(spb), 48_000, l, r);
        const at: usize = @intFromFloat(spb);
        for (0..2000) |k| try testing.expectApproxEqAbs(@as(f32, @floatCast(data[28_800 + k])), l[at + k], 1e-4);
        for (0..2000) |k| try testing.expectApproxEqAbs(@as(f32, @floatCast(data[k])), l[k], 1e-4);
        // At 80 BPM the first slice's own audio runs out at 28800: CUT is
        // silence until the next.
        if (spb == 36_000) try testing.expectEqual(@as(f32, 0), l[32_000]);
    }
    // LOOP fills that gap instead.
    snap.audio_clips[0].gap = .loop;
    @memset(l, 0);
    @memset(r, 0);
    mixAudioClips(snap, 0, 96_000, &spbMap(36_000), 48_000, l, r);
    var energy: f64 = 0;
    for (l[29_000..35_000]) |v| energy += v * v;
    try testing.expect(energy > 1);
    for (l) |v| try testing.expect(!std.math.isNan(v));
}

test "mixAudioClips: missing source data is skipped" {
    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{ .start_beat = 0, .length_beats = 4, .data = null };
    var l = [_]f32{0} ** 4;
    var r = [_]f32{0} ** 4;
    mixAudioClips(&snap, 0, 4, &spbMap(10.0), 48_000, &l, &r);
    for (l) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "Subsonic: Butterworth at 30 Hz, 24 dB/oct below, flat above" {
    const sr: f64 = 48000;
    const cases = [_]struct { hz: f64, db: f64, tol: f64 }{
        .{ .hz = 30, .db = -3.01, .tol = 0.05 },
        .{ .hz = 15, .db = -24.1, .tol = 0.2 }, // an octave down: 24 dB/oct
        .{ .hz = 120, .db = 0.0, .tol = 0.02 },
        .{ .hz = 1000, .db = 0.0, .tol = 0.001 },
    };
    for (cases) |cs| {
        var f = Subsonic{};
        var l: [4800]f32 = undefined;
        var r: [4800]f32 = undefined;
        var sum: f64 = 0;
        var n: usize = 0;
        // 3 s to settle, then the RMS over the last 0.5 s against a full-
        // scale sine's (the phase shift moves the peak between samples).
        while (n < 36000) : (n += 4800) {
            for (&l, &r, 0..) |*a, *b, i| {
                const v: f32 = @floatCast(@sin(2.0 * std.math.pi * cs.hz * @as(f64, @floatFromInt(n + i)) / sr));
                a.* = v;
                b.* = v;
            }
            f.process(&l, &r, sr);
            if (n >= 26400) for (l) |v| {
                sum += @as(f64, v) * v;
            };
        }
        const rms = @sqrt(sum / 9600.0);
        try testing.expectApproxEqAbs(cs.db, 20 * std.math.log10(rms * std.math.sqrt2), cs.tol);
    }
}

test "MasterClip soft: linear pass-through inside the knee" {
    const c = MasterClip{};
    try testing.expectEqual(@as(f32, 0.0), c.sample(0.0));
    try testing.expectEqual(@as(f32, 0.9), c.sample(0.9));
    try testing.expectEqual(@as(f32, -0.9), c.sample(-0.9));
    try testing.expectEqual(c.knee, c.sample(c.knee));
}

test "MasterClip soft: continuous at the knee" {
    const c = MasterClip{ .knee = 0.7 };
    const eps: f32 = 1e-6;
    try testing.expect(@abs(c.sample(0.7 - eps) - c.sample(0.7 + eps)) < 1e-3);
}

test "MasterClip soft: bounded in (-1, 1) and monotonic for any knee" {
    for ([_]f32{ 0.5, 0.7, 0.95 }) |k| {
        const c = MasterClip{ .knee = k };
        for ([_]f32{ 1.0, 1.5, 4.0, 100.0, -1.0, -1.5, -4.0, -100.0 }) |x| {
            const y = c.sample(x);
            try testing.expect(y > -1.0 and y < 1.0);
            try testing.expect((x > 0) == (y > 0));
        }
        var prev = c.sample(-10.0);
        var x: f32 = -10.0;
        while (x <= 10.0) : (x += 0.1) {
            const y = c.sample(x);
            try testing.expect(y >= prev);
            prev = y;
        }
    }
}

test "MasterClip hard clamps and off passes the overs" {
    const hard = MasterClip{ .mode = .hard };
    try testing.expectEqual(@as(f32, 1.0), hard.sample(3.0));
    try testing.expectEqual(@as(f32, -1.0), hard.sample(-3.0));
    try testing.expectEqual(@as(f32, 0.99), hard.sample(0.99));
    var buf = [_]f32{ 2.0, -2.0, 0.5 };
    (MasterClip{ .mode = .off }).apply(&buf);
    try testing.expectEqualSlices(f32, &.{ 2.0, -2.0, 0.5 }, &buf);
}

test "faderGains follows volume and pan lanes unless overridden" {
    const alloc = testing.allocator;
    var t = try Track.init(alloc, "t", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .{
        .name = "x",
        .state = undefined,
        .render = struct {
            fn f(_: *anyopaque, _: *const machine.MachineCtx, _: []f32, _: []f32) void {}
        }.f,
        .draw_panel = struct {
            fn f(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}
        }.f,
        .reset = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    });
    defer t.deinit(alloc);
    t.setVolume(1.0);
    const vol = try t.laneFor(alloc, automation.Target.volume(), false);
    _ = try vol.insert(alloc, .{ .beat = 0, .value = 0 });
    _ = try vol.insert(alloc, .{ .beat = 4, .value = 0.8 }); // 1.0 gain
    const pan = try t.laneFor(alloc, automation.Target.pan(), false);
    _ = try pan.insert(alloc, .{ .beat = 0, .value = 1 }); // hard right
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    t.publishSnapshot(&pool);
    const snap = t.currentSnapshot();

    const g0 = faderGains(&t, snap, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), g0.v, 1e-6);
    const g2 = faderGains(&t, snap, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.5), g2.v, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), g2.l, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), g2.r, 1e-6);

    t.vol_override.store(2, .monotonic);
    t.pan_override.store(2, .monotonic);
    const go = faderGains(&t, snap, 2);
    try testing.expectApproxEqAbs(@as(f32, 1.0), go.v, 1e-6);
    try testing.expectApproxEqAbs(go.l, go.r, 1e-6);
}

test "gatherEvents: note ids, and expression every EXPR_STEP samples for a bent note" {
    const spb = 480.0;
    const frames: u32 = 128;
    var snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{ .{ .start = 0, .len = 2, .pitch = 60 }, .{ .start = 0, .len = 2, .pitch = 64 } },
    }});
    // Note 0 bends up 12 semitones over its first beat; note 1 doesn't bend.
    snap.expr_points[0] = .{ .beat = 0, .value = 0 };
    snap.expr_points[1] = .{ .beat = 1, .value = 12 };
    snap.expr_point_count = 2;
    snap.notes[0].expr_start = 0;
    snap.notes[0].expr_count = 2;
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;
    const n = gatherEvents(&snap, 0.5, 0.5 + @as(f64, frames) / spb, spb, frames, false, null, &events);
    var exprs: usize = 0;
    for (events[0..n]) |ev| {
        try testing.expect(ev.note_id >= 0);
        if (ev.kind != .expression) continue;
        try testing.expectEqual(@as(i32, 0), ev.note_id);
        const beat = 0.5 + @as(f64, @floatFromInt(ev.sample_offset)) / spb;
        try testing.expectApproxEqAbs(@as(f32, @floatCast(60 + 12 * beat)), ev.pitch, 1e-3);
        try testing.expect(ev.sample_offset % EXPR_STEP == 0);
        exprs += 1;
    }
    try testing.expectEqual(@as(usize, frames / EXPR_STEP), exprs);
}

test "gatherEvents: pressure, slide and gain ride the expression event" {
    const alloc = testing.allocator;
    var t = try Track.init(alloc, "t", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .{
        .name = "x",
        .state = undefined,
        .render = struct {
            fn f(_: *anyopaque, _: *const machine.MachineCtx, _: []f32, _: []f32) void {}
        }.f,
        .draw_panel = struct {
            fn f(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}
        }.f,
        .reset = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    });
    defer t.deinit(alloc);
    var clip = @import("clip.zig").Clip.init("A", 0, 8);
    var n = @import("clip.zig").Note{ .pitch = 60, .start_beat = 0, .length_beats = 4 };
    _ = n.dim(.gain).add(.{ .beat = 0, .value = -30 }, -48, 12);
    _ = n.dim(.gain).add(.{ .beat = 2, .value = 0 }, -48, 12);
    try clip.addNote(alloc, n);
    try t.addClip(alloc, clip);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    t.publishSnapshot(&pool);
    const snap = t.currentSnapshot();
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;
    const cnt = gatherEvents(snap, 0, 2048.0 / 48_000.0, 48_000, 2048, false, null, &events);
    var first: ?machine.NoteEvent = null;
    for (events[0..cnt]) |ev| if (ev.kind == .expression and first == null) {
        first = ev;
    };
    try testing.expectEqual(@as(u32, 0), first.?.sample_offset);
    try testing.expectApproxEqAbs(@as(f32, -30), first.?.value, 0.1);
    try testing.expectEqual(@as(f32, 0.5), first.?.pressure);
    try testing.expectEqual(@as(f32, 60), first.?.pitch);
}

// ── Routing (docs/23) ────────────────────────────────────────────────

const RouteTestMachines = struct {
    /// Instrument: a constant `*f32` on both channels.
    fn dc(level: *f32) machine.Machine {
        return .{
            .name = "dc",
            .state = level,
            .render = struct {
                fn f(st: *anyopaque, _: *const machine.MachineCtx, l: []f32, r: []f32) void {
                    const v: *f32 = @ptrCast(@alignCast(st));
                    @memset(l, v.*);
                    @memset(r, v.*);
                }
            }.f,
            .draw_panel = struct {
                fn f(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}
            }.f,
            .reset = struct {
                fn f(_: *anyopaque) void {}
            }.f,
        };
    }

    /// Effect: input × `*f32`.
    fn gain(k: *f32) machine.Machine {
        var m = dc(k);
        m.name = "gain";
        m.render = struct {
            fn f(st: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
                const g: *f32 = @ptrCast(@alignCast(st));
                const ins = ctx.audio_in.?;
                for (l, 0..) |*x, i| x.* = ins[0][i] * g.*;
                for (r, 0..) |*x, i| x.* = ins[1][i] * g.*;
            }
        }.f;
        return m;
    }
};

test "routing: a group, a pre-fader send and a return sum as their paths" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var tenth: f32 = 0.1;
    var zero: f32 = 0;
    var two: f32 = 2;
    var four: f32 = 4;
    var tracks = [_]Track{
        try Track.init(alloc, "kit", col, RouteTestMachines.dc(&tenth)),
        try Track.init(alloc, "bass", col, RouteTestMachines.dc(&tenth)),
        try Track.init(alloc, "group", col, RouteTestMachines.dc(&zero)),
        try Track.init(alloc, "verb", col, RouteTestMachines.dc(&zero)),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    for (&tracks) |*t| t.setVolume(1.0);
    tracks[0].output = 2;
    try tracks[1].addSend(3, true, 0.5);
    tracks[2].kind = .bus;
    tracks[3].kind = .bus;
    try tracks[2].addEffect(alloc, RouteTestMachines.gain(&two), 0);
    try tracks[3].addEffect(alloc, RouteTestMachines.gain(&four), 0);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);

    var transport = Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, eng.routing_bufs[eng.routing_published.load(.monotonic)].renderOrder());

    const c = @cos(@as(f32, std.math.pi / 4.0)); // centre pan
    const kit = 0.1 * c * 2 * c; // through the group's ×2 and fader
    const bass = 0.1 * c;
    const verb = 0.1 * 0.5 * 4 * c; // pre tap (no pan) × send × return
    var out: [64 * 2]f32 = undefined;
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectApproxEqAbs(kit + bass + verb, out[10], 1e-6);
    try testing.expectApproxEqAbs(kit + bass + verb, out[11], 1e-6);

    // Muting the bass silences its dry signal and its send.
    tracks[1].mute.store(true, .monotonic);
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectApproxEqAbs(kit, out[10], 1e-6);
    tracks[1].mute.store(false, .monotonic);

    // Soloing the return keeps its source (the bass, dry too) and drops the kit.
    tracks[3].solo.store(true, .monotonic);
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectApproxEqAbs(bass + verb, out[10], 1e-6);
    tracks[3].solo.store(false, .monotonic);

    // Soloing the kit keeps the group it feeds.
    tracks[0].solo.store(true, .monotonic);
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectApproxEqAbs(kit, out[10], 1e-6);
}

test "capture: taps copy each track's signal, only the sources are heard, a quiet capture stops" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var tenth: f32 = 0.1;
    var zero: f32 = 0;
    var four: f32 = 4;
    var tracks = [_]Track{
        try Track.init(alloc, "kit", col, RouteTestMachines.dc(&tenth)),
        try Track.init(alloc, "bass", col, RouteTestMachines.dc(&tenth)),
        try Track.init(alloc, "verb", col, RouteTestMachines.dc(&zero)),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    for (&tracks) |*t| t.setVolume(1.0);
    try tracks[0].addSend(2, true, 0.5);
    try tracks[1].addSend(2, true, 0.5);
    tracks[2].kind = .bus;
    try tracks[1].addEffect(alloc, RouteTestMachines.gain(&four), 0);
    try tracks[2].addEffect(alloc, RouteTestMachines.gain(&four), 0);
    // A muted source still renders for its capture.
    tracks[1].mute.store(true, .monotonic);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);

    var transport = Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();

    const N = 256;
    var bufs: [4][N]f32 = @splat(@splat(0));
    var cap = Capture{ .sources = routing.bit(1) };
    cap.tap[1] = .input;
    cap.l[1] = &bufs[0];
    cap.r[1] = &bufs[1];
    cap.tap[2] = .post;
    cap.l[2] = &bufs[2];
    cap.r[2] = &bufs[3];
    eng.capture = &cap;
    defer eng.capture = null;
    eng.renderOffline(&.{}, 128, 0, null, null);

    const c = @cos(@as(f32, std.math.pi / 4.0));
    try testing.expectEqual(@as(usize, 128), cap.rendered);
    try testing.expectApproxEqAbs(@as(f32, 0.1), bufs[0][10], 1e-6); // bass before its ×4
    // The return hears the bass alone (the kit is muted for the capture).
    try testing.expectApproxEqAbs(0.1 * 4 * 0.5 * 4 * c, bufs[2][10], 1e-6);
    try testing.expectEqual(@as(usize, 128), cap.loud_end[1]);

    // A silent source with a hold stops the render past min_frames, at
    // the first block boundary after the hold.
    const M = MAX_BLOCK * 8;
    const ql = try alloc.alloc(f32, M);
    defer alloc.free(ql);
    const qr = try alloc.alloc(f32, M);
    defer alloc.free(qr);
    var quiet = Capture{ .sources = routing.bit(2), .min_frames = MAX_BLOCK, .hold = MAX_BLOCK / 2 };
    quiet.tap[2] = .pre;
    quiet.l[2] = ql;
    quiet.r[2] = qr;
    eng.capture = &quiet;
    eng.renderOffline(&.{}, M, 0, null, null);
    try testing.expectEqual(@as(usize, MAX_BLOCK * 2), quiet.rendered);
}

test "offline stop: audio clips fall silent at the stop, the master watch ends the render" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var zero: f32 = 0;
    var tracks = [_]Track{try Track.init(alloc, "loop", col, RouteTestMachines.dc(&zero))};
    defer tracks[0].deinit(alloc);
    tracks[0].setVolume(1.0);
    var transport = Transport{};
    transport.sample_rate = 48_000;
    // A constant 0.5 for 8 beats (2 s at 120 BPM): long past the stop.
    const data = try alloc.alloc(f64, 96_000);
    defer alloc.free(data);
    @memset(data, 0.5);
    tracks[0].publishSnapshot(&@import("audio_pool.zig").AudioPool.init(alloc));
    const snap = tracks[0].snap[1 - tracks[0].snap_published.load(.monotonic)];
    snap.* = tracks[0].currentSnapshot().*;
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{ .start_beat = 0, .length_beats = 4, .data = data.ptr, .len = @intCast(data.len), .source_rate = 48_000, .dur_samples = 96_000, .gain = 1 };
    tracks[0].snap_published.store(1 - tracks[0].snap_published.load(.monotonic), .release);

    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();
    const stop: usize = MAX_BLOCK * 3 + 17; // mid-block: the render splits there
    const total = MAX_BLOCK * 12;
    const out = try alloc.alloc(f32, total * 2);
    defer alloc.free(out);
    @memset(out, 9);
    var cap = Capture{ .min_frames = stop, .hold = MAX_BLOCK, .watch_master = true };
    eng.capture = &cap;
    defer eng.capture = null;
    eng.offline_stop = stop;
    eng.renderOffline(out, total, 0, null, null);
    try testing.expect(eng.offline_stop == null);
    const c = @cos(@as(f32, std.math.pi / 4.0));
    try testing.expectApproxEqAbs(0.5 * c, out[(stop - 1) * 2], 1e-6);
    try testing.expectEqual(@as(f32, 0), out[stop * 2]);
    try testing.expectEqual(stop, cap.master_loud_end);
    // Quiet for a hold past the stop: it ends well before `total`.
    try testing.expect(cap.rendered >= stop + MAX_BLOCK);
    try testing.expect(cap.rendered < stop + MAX_BLOCK * 3);
}

test "routing: a send level change ramps across the block" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var tenth: f32 = 0.1;
    var zero: f32 = 0;
    var tracks = [_]Track{
        try Track.init(alloc, "src", col, RouteTestMachines.dc(&tenth)),
        try Track.init(alloc, "ret", col, RouteTestMachines.dc(&zero)),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    tracks[0].setVolume(0); // only the pre send is heard
    tracks[1].setVolume(1.0);
    tracks[1].kind = .bus;
    try tracks[0].addSend(1, true, 1.0);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);
    var transport = Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();

    const c = @cos(@as(f32, std.math.pi / 4.0));
    var out: [64 * 2]f32 = undefined;
    eng.renderChunk(&out, 64, 0);
    try testing.expectApproxEqAbs(0.1 * c, out[0], 1e-6);
    tracks[0].sends[0].setLevel(0);
    eng.renderChunk(&out, 64, 64);
    try testing.expectApproxEqAbs(0.1 * c, out[0], 1e-6); // ramp starts at the old level
    try testing.expect(out[2 * 32] < 0.06 * c and out[2 * 32] > 0.04 * c); // halfway
    eng.renderChunk(&out, 64, 128);
    try testing.expectEqual(@as(f32, 0), out[0]);
}

test "routing: a keyed effect hears its key's pre tap, even from a muted track" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var kick_lvl: f32 = 0.25;
    var bass_lvl: f32 = 0.1;
    var unused: f32 = 0;
    // Effect: outputs its key L (0 without one), so the master shows it.
    var keyed = RouteTestMachines.gain(&unused);
    keyed.takes_key = true;
    keyed.render = struct {
        fn f(_: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
            const ins = ctx.audio_in.?;
            for (l, r, 0..) |*a, *b, i| {
                a.* = if (ctx.audio_in_count >= 4) ins[2][i] else 0;
                b.* = a.*;
            }
        }
    }.f;
    var tracks = [_]Track{
        try Track.init(alloc, "kick", col, RouteTestMachines.dc(&kick_lvl)),
        try Track.init(alloc, "bass", col, RouteTestMachines.dc(&bass_lvl)),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    for (&tracks) |*t| t.setVolume(1.0);
    try tracks[1].addEffect(alloc, keyed, 0);
    tracks[1].effects.items[0].key = 0;
    tracks[0].mute.store(true, .monotonic);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);
    var transport = Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();

    const c = @cos(@as(f32, std.math.pi / 4.0));
    var out: [64 * 2]f32 = undefined;
    eng.renderOffline(&out, 64, 0, null, null);
    // The kick is muted (not in the mix) but its pre tap keys the bass.
    try testing.expectApproxEqAbs(0.25 * c, out[10], 1e-6);

    // Without the manifest flag the effect gets no key.
    tracks[1].effects.items[0].mach.takes_key = false;
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectEqual(@as(f32, 0), out[10]);
}

test "a seek releases the notes it leaves, starts the ones it lands in, and keeps the ones in both" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const Rec = struct {
        var resets: usize = 0;
        var log: [16]struct { on: bool, pitch: f32, at: u32 } = undefined;
        var n: usize = 0;
        fn machine_() machine.Machine {
            var level: f32 = 0;
            var m = RouteTestMachines.dc(&level);
            m.render = struct {
                fn f(_: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
                    if (ctx.note_in) |ev| for (ev[0..ctx.note_in_count]) |e| {
                        if (e.kind != .note_on and e.kind != .note_off) continue;
                        if (n < log.len) log[n] = .{ .on = e.kind == .note_on, .pitch = e.pitch, .at = e.sample_offset };
                        n += 1;
                    };
                    @memset(l, 0);
                    @memset(r, 0);
                }
            }.f;
            m.reset = struct {
                fn f(_: *anyopaque) void {
                    resets += 1;
                }
            }.f;
            return m;
        }
    };
    var tracks = [_]Track{try Track.init(alloc, "keys", col, Rec.machine_())};
    defer for (&tracks) |*t| t.deinit(alloc);
    var clip = @import("clip.zig").Clip.init("A", 0, 16);
    try clip.addNote(alloc, .{ .pitch = 36, .start_beat = 0, .length_beats = 16, .velocity = 100 }); // in both
    try clip.addNote(alloc, .{ .pitch = 60, .start_beat = 0, .length_beats = 2, .velocity = 100 }); // left behind
    try clip.addNote(alloc, .{ .pitch = 67, .start_beat = 6, .length_beats = 4, .velocity = 100 }); // landed in
    try tracks[0].addClip(alloc, clip);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);

    var transport = Transport{};
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();

    var out: [64 * 2]f32 = undefined;
    transport.play();
    eng.render(&out, 64);
    eng.render(&out, 64);
    try testing.expectEqual(@as(usize, 2), Rec.n); // 36 and 60 on
    try testing.expectEqual(@as(u64, 128), transport.samples());

    transport.seekToBeats(8);
    const at = transport.samples();
    eng.render(&out, 64);
    try testing.expectEqual(@as(usize, 4), Rec.n);
    try testing.expect(!Rec.log[2].on and Rec.log[2].pitch == 60 and Rec.log[2].at == 0);
    try testing.expect(Rec.log[3].on and Rec.log[3].pitch == 67 and Rec.log[3].at == 0);
    try testing.expectEqual(at + 64, transport.samples());
    eng.render(&out, 64);
    try testing.expectEqual(@as(usize, 4), Rec.n);
    try testing.expectEqual(@as(usize, 0), Rec.resets); // released, never cut
}

test "tempo map: notes land where the map puts them, blocks split at a change, and an edit keeps the beat" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const Rec = struct {
        var ons: [8]u64 = undefined;
        var n: usize = 0;
        var crossed = false; // a block ran across sample 24000
        var slow_from: ?u64 = null; // first block start at 60 BPM
        fn machine_() machine.Machine {
            var level: f32 = 0;
            var m = RouteTestMachines.dc(&level);
            m.render = struct {
                fn f(_: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
                    if (ctx.block_start < 24000 and ctx.block_start + ctx.block_size > 24000) crossed = true;
                    if (ctx.tempo_bpm == 60 and slow_from == null) slow_from = ctx.block_start;
                    if (ctx.note_in) |ev| for (ev[0..ctx.note_in_count]) |e| {
                        if (e.kind != .note_on) continue;
                        if (n < ons.len) ons[n] = ctx.block_start + e.sample_offset;
                        n += 1;
                    };
                    @memset(l, 0);
                    @memset(r, 0);
                }
            }.f;
            return m;
        }
    };
    var tracks = [_]Track{try Track.init(alloc, "keys", col, Rec.machine_())};
    defer for (&tracks) |*t| t.deinit(alloc);
    var clip = @import("clip.zig").Clip.init("A", 0, 8);
    try clip.addNote(alloc, .{ .pitch = 60, .start_beat = 0.5, .length_beats = 0.25, .velocity = 100 });
    try clip.addNote(alloc, .{ .pitch = 62, .start_beat = 1.5, .length_beats = 0.25, .velocity = 100 });
    try clip.addNote(alloc, .{ .pitch = 64, .start_beat = 2, .length_beats = 0.25, .velocity = 100 });
    try tracks[0].addClip(alloc, clip);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);

    // 120 BPM for a beat (24000 samples), then 60 (48000 a beat).
    var transport = Transport{};
    _ = transport.tempo.edit().put(1, 60);
    transport.tempo.publish();
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();

    var out: [512 * 2]f32 = undefined;
    transport.play();
    while (transport.samples() < 80000) eng.render(&out, 512);
    try testing.expectEqual(@as(usize, 3), Rec.n);
    try testing.expectEqual(@as(u64, 12000), Rec.ons[0]);
    try testing.expectEqual(@as(u64, 48000), Rec.ons[1]);
    try testing.expectEqual(@as(u64, 72000), Rec.ons[2]);
    try testing.expect(!Rec.crossed);
    try testing.expectEqual(@as(?u64, 24000), Rec.slow_from);

    // Halve the tempo under the playhead: it stays on its beat.
    transport.stop();
    transport.seekToBeats(3);
    try testing.expectEqual(@as(u64, 120000), transport.samples());
    transport.play();
    transport.setBpm(30);
    eng.render(&out, 64);
    try testing.expectApproxEqAbs(@as(f64, 3), transport.beats(), 64.0 / 96000.0 + 1e-9);
    try testing.expectEqual(@as(u64, 24000 + 2 * 96000 + 64), transport.samples());
}

test "a loop wrap releases the note ending on the loop end, and the ones past it after a seek" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const Held = struct {
        var on: [128]i32 = [_]i32{0} ** 128;
        fn machine_() machine.Machine {
            var level: f32 = 0;
            var m = RouteTestMachines.dc(&level);
            m.render = struct {
                fn f(_: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
                    if (ctx.note_in) |ev| for (ev[0..ctx.note_in_count]) |e| {
                        const p: usize = @intFromFloat(e.pitch);
                        if (e.kind == .note_on) on[p] += 1;
                        if (e.kind == .note_off and on[p] > 0) on[p] -= 1;
                    };
                    @memset(l, 0);
                    @memset(r, 0);
                }
            }.f;
            return m;
        }
    };
    var tracks = [_]Track{try Track.init(alloc, "bass", col, Held.machine_())};
    defer for (&tracks) |*t| t.deinit(alloc);
    var clip = @import("clip.zig").Clip.init("A", 0, 8);
    try clip.addNote(alloc, .{ .pitch = 40, .start_beat = 2, .length_beats = 2, .velocity = 100 }); // ends on the loop end
    try clip.addNote(alloc, .{ .pitch = 50, .start_beat = 5, .length_beats = 3, .velocity = 100 }); // past the loop
    try tracks[0].addClip(alloc, clip);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);

    var transport = Transport{};
    transport.setBpm(121); // the loop end falls between samples
    transport.setLoopBeats(0, 4);
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();

    var out: [64 * 2]f32 = undefined;
    transport.play();
    while (transport.beats() < 3.5) eng.render(&out, 64);
    try testing.expectEqual(@as(i32, 1), Held.on[40]);
    while (transport.beats() >= 3.0) eng.render(&out, 64); // through the wrap
    try testing.expectEqual(@as(i32, 0), Held.on[40]);

    transport.seekToBeats(6); // beyond the loop: one block there, then wrapped into it
    eng.render(&out, 64);
    eng.render(&out, 64);
    try testing.expect(transport.beats() < 4);
    try testing.expectEqual(@as(i32, 0), Held.on[50]);
}

const PdcTestMachines = struct {
    /// Instrument: `*f32` on the project's first sample, then silence.
    fn impulse(level: *f32) machine.Machine {
        var m = RouteTestMachines.dc(level);
        m.name = "impulse";
        m.render = struct {
            fn f(st: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
                const v: *f32 = @ptrCast(@alignCast(st));
                @memset(l, 0);
                @memset(r, 0);
                if (ctx.block_start == 0) {
                    l[0] = v.*;
                    r[0] = v.*;
                }
            }
        }.f;
        return m;
    }

    /// Effect: the input `n` samples late, and says so.
    const Delay = struct {
        n: u32,
        ring: [2][64]f32 = @splat(@splat(0)),
        w: usize = 0,
    };
    fn delay(d: *Delay) machine.Machine {
        return .{
            .name = "delay",
            .state = d,
            .render = struct {
                fn f(st: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
                    const s: *Delay = @ptrCast(@alignCast(st));
                    const ins = ctx.audio_in.?;
                    for (0..l.len) |i| {
                        const at = (s.w + i) % 64;
                        const from = (s.w + i + 64 - s.n) % 64;
                        s.ring[0][at] = ins[0][i];
                        s.ring[1][at] = ins[1][i];
                        l[i] = s.ring[0][from];
                        r[i] = s.ring[1][from];
                    }
                    s.w = (s.w + l.len) % 64;
                }
            }.f,
            .draw_panel = struct {
                fn f(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}
            }.f,
            .reset = struct {
                fn f(_: *anyopaque) void {}
            }.f,
            .latency = struct {
                fn f(st: *anyopaque) u32 {
                    const s: *Delay = @ptrCast(@alignCast(st));
                    return s.n;
                }
            }.f,
        };
    }
};

test "PDC: a keyed effect meets its key on the same sample, late or early" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var kick_lvl: f32 = 0.25;
    var bass_lvl: f32 = 0.5;
    var unused: f32 = 0;
    // Effect: its input plus its key, so a misaligned key shows as two peaks.
    var keyed = RouteTestMachines.gain(&unused);
    keyed.takes_key = true;
    keyed.render = struct {
        fn f(_: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
            const ins = ctx.audio_in.?;
            for (l, r, 0..) |*a, *b, i| {
                a.* = ins[0][i] + if (ctx.audio_in_count >= 4) ins[2][i] else 0;
                b.* = a.*;
            }
        }
    }.f;
    var kick_d = PdcTestMachines.Delay{ .n = 10 };
    var bass_d = PdcTestMachines.Delay{ .n = 7 };
    var tracks = [_]Track{
        try Track.init(alloc, "kick", col, PdcTestMachines.impulse(&kick_lvl)),
        try Track.init(alloc, "bass", col, PdcTestMachines.impulse(&bass_lvl)),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    for (&tracks) |*t| t.setVolume(1.0);
    try tracks[0].addEffect(alloc, PdcTestMachines.delay(&kick_d), 0);
    try tracks[1].addEffect(alloc, PdcTestMachines.delay(&bass_d), 0);
    try tracks[1].addEffect(alloc, keyed, 1);
    tracks[1].effects.items[1].key = 0;
    tracks[0].mute.store(true, .monotonic);
    tracks[1].effects.items[0].bypass.store(true, .monotonic);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);
    var transport = Transport{};
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    try eng.initPdc(alloc);
    defer eng.deinitPdc(alloc);
    eng.publishRouting();

    const c = @cos(@as(f32, std.math.pi / 4.0));
    var out: [64 * 2]f32 = undefined;
    // A late key (the kick's insert): the bass waits for it.
    transport.play();
    eng.render(&out, 64);
    try testing.expectEqual(@as(?usize, 10), onlyPeakAt(&out));
    try testing.expectApproxEqAbs(0.75 * c, out[20], 1e-6);
    try testing.expectEqual(@as(u32, 10), eng.master_latency.load(.monotonic));

    // An early key (the bass's own insert before the keyed effect): the
    // key is read late instead.
    tracks[0].effects.items[0].bypass.store(true, .monotonic);
    tracks[1].effects.items[0].bypass.store(false, .monotonic);
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectEqual(@as(?usize, 0), onlyPeakAt(&out));
    try testing.expectEqual(@as(u32, 7), eng.master_latency.load(.monotonic));

    // Both: the later of the two sets the pace.
    tracks[0].effects.items[0].bypass.store(false, .monotonic);
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectEqual(@as(?usize, 0), onlyPeakAt(&out));
    try testing.expectApproxEqAbs(0.75 * c, out[0], 1e-6);
    try testing.expectEqual(@as(u32, 10), eng.master_latency.load(.monotonic));
}

fn onlyPeakAt(out: []const f32) ?usize {
    var at: ?usize = null;
    for (0..out.len / 2) |i| if (@abs(out[i * 2]) > 1e-6) {
        if (at != null) return null;
        at = i;
    };
    return at;
}

test "PDC: a latent track, a direct one and a send to a return all land on the same sample" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var quarter: f32 = 0.25;
    var zero: f32 = 0;
    var one: f32 = 1;
    var d = PdcTestMachines.Delay{ .n = 10 };
    var tracks = [_]Track{
        try Track.init(alloc, "direct", col, PdcTestMachines.impulse(&quarter)),
        try Track.init(alloc, "latent", col, PdcTestMachines.impulse(&quarter)),
        try Track.init(alloc, "verb", col, RouteTestMachines.dc(&zero)),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    for (&tracks) |*t| t.setVolume(1.0);
    try tracks[1].addEffect(alloc, PdcTestMachines.delay(&d), 0);
    tracks[2].kind = .bus;
    try tracks[2].addEffect(alloc, RouteTestMachines.gain(&one), 0);
    try tracks[0].addSend(2, false, 0.5); // the direct track also feeds the return
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);

    var transport = Transport{};
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    try eng.initPdc(alloc);
    defer eng.deinitPdc(alloc);
    eng.publishRouting();

    // Live: everything arrives with the latent track, 10 samples in.
    var out: [64 * 2]f32 = undefined;
    transport.play();
    eng.render(&out, 64);
    try testing.expectEqual(@as(?usize, 10), onlyPeakAt(&out));
    const c = @cos(@as(f32, std.math.pi / 4.0));
    try testing.expectApproxEqAbs(0.25 * c * (1 + 1 + 0.5 * c), out[20], 1e-6);
    try testing.expectEqual(@as(u32, 10), eng.master_latency.load(.monotonic));

    // A bounce drops the project's latency: the impulse is on sample 0.
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectEqual(@as(?usize, 0), onlyPeakAt(&out));

    // Without the latent insert nothing is delayed.
    tracks[1].effects.items[0].bypass.store(true, .monotonic);
    eng.renderOffline(&out, 64, 0, null, null);
    try testing.expectEqual(@as(?usize, 0), onlyPeakAt(&out));
    try testing.expectEqual(@as(u32, 0), eng.master_latency.load(.monotonic));
}

const IdleTestMachines = struct {
    /// Instrument: a linear decay from 1 at each note-on to exact silence
    /// in 1000 samples. Counts its renders.
    const Env = struct { env: f32 = 0, renders: usize = 0 };
    fn env(e: *Env) machine.Machine {
        var m = RouteTestMachines.dc(undefined);
        m.name = "env";
        m.state = e;
        m.render = struct {
            fn f(st: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
                const s: *Env = @ptrCast(@alignCast(st));
                s.renders += 1;
                const evs = if (ctx.note_in) |p| p[0..ctx.note_in_count] else &[_]machine.NoteEvent{};
                for (l, r, 0..) |*a, *b, i| {
                    for (evs) |ev| if (ev.kind == .note_on and ev.sample_offset == i) {
                        s.env = 1;
                    };
                    a.* = s.env;
                    b.* = s.env;
                    s.env = @max(0, s.env - 0.001);
                }
            }
        }.f;
        m.reset = struct {
            fn f(st: *anyopaque) void {
                const s: *Env = @ptrCast(@alignCast(st));
                s.env = 0;
            }
        }.f;
        return m;
    }

    /// Effect: its input, plus half of the first loud sample again `gap`
    /// samples later - sound it plays after its output has been silent.
    const Echo = struct { gap: u32, declare: u32 = 0, left: u32 = 0, val: f32 = 0, renders: usize = 0, wake_at: usize = 0, wake_calls: usize = 0 };
    fn echo(e: *Echo) machine.Machine {
        var m = RouteTestMachines.dc(undefined);
        m.name = "echo";
        m.state = e;
        m.render = struct {
            fn f(st: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
                const s: *Echo = @ptrCast(@alignCast(st));
                s.renders += 1;
                const ins = ctx.audio_in.?;
                for (l, r, 0..) |*a, *b, i| {
                    var y = ins[0][i];
                    if (s.left > 0) {
                        s.left -= 1;
                        if (s.left == 0) y += s.val;
                    } else if (ins[0][i] > 0.5) {
                        s.val = ins[0][i] * 0.5;
                        s.left = s.gap;
                    }
                    a.* = y;
                    b.* = y;
                }
            }
        }.f;
        m.reset = struct {
            fn f(st: *anyopaque) void {
                const s: *Echo = @ptrCast(@alignCast(st));
                s.left = 0;
            }
        }.f;
        m.tail = struct {
            fn f(st: *anyopaque, _: f64) u32 {
                const s: *Echo = @ptrCast(@alignCast(st));
                return s.declare;
            }
        }.f;
        m.take_wake = struct {
            fn f(st: *anyopaque) bool {
                const s: *Echo = @ptrCast(@alignCast(st));
                s.wake_calls += 1;
                return s.wake_calls == s.wake_at;
            }
        }.f;
        return m;
    }
};

/// One track, notes at beats 0 and 4 (0.5 s apart at 120 bpm is 24000
/// samples a beat), rendered for five beats.
fn idleTestRender(alloc: std.mem.Allocator, idle_skip: bool, e: *IdleTestMachines.Env, fx: []const machine.Machine, out: []f32) !void {
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var tracks = [_]Track{try Track.init(alloc, "t", col, IdleTestMachines.env(e))};
    defer for (&tracks) |*t| t.deinit(alloc);
    tracks[0].setVolume(1.0);
    for (fx, 0..) |m, i| try tracks[0].addEffect(alloc, m, @intCast(i));
    var clip = @import("clip.zig").Clip.init("A", 0, 8);
    try clip.addNote(alloc, .{ .pitch = 60, .start_beat = 0, .length_beats = 0.1, .velocity = 100 });
    try clip.addNote(alloc, .{ .pitch = 60, .start_beat = 4, .length_beats = 0.1, .velocity = 100 });
    try tracks[0].addClip(alloc, clip);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    tracks[0].publishSnapshot(&pool);
    var transport = Transport{};
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks, .idle_skip = idle_skip };
    try eng.initPdc(alloc);
    defer eng.deinitPdc(alloc);
    eng.publishRouting();
    eng.renderOffline(out, out.len / 2, 0, null, null);
}

test "idle skipping: an instrument and a latent effect sleep between notes and the mix is bit-exact" {
    const alloc = testing.allocator;
    const frames = 5 * 24000;
    const a = try alloc.alloc(f32, frames * 2);
    defer alloc.free(a);
    const b = try alloc.alloc(f32, frames * 2);
    defer alloc.free(b);
    var e_all = IdleTestMachines.Env{};
    var d_all = PdcTestMachines.Delay{ .n = 10 };
    try idleTestRender(alloc, false, &e_all, &.{PdcTestMachines.delay(&d_all)}, a);
    var e_idle = IdleTestMachines.Env{};
    var d_idle = PdcTestMachines.Delay{ .n = 10 };
    try idleTestRender(alloc, true, &e_idle, &.{PdcTestMachines.delay(&d_idle)}, b);

    try testing.expectEqualSlices(f32, a, b);
    // The second note lands on its sample (a bounce drops the latency),
    // at the centre pan's gain.
    const c = @cos(@as(f32, std.math.pi / 4.0));
    try testing.expectApproxEqAbs(c, b[96000 * 2], 1e-6);
    // Awake: the first note and its hold (13 of 118 blocks), 0.1 s before
    // the second note at 2 s to its hold's end (about 22 blocks).
    const blocks = e_all.renders;
    try testing.expect(e_idle.renders < blocks / 2);
    try testing.expect(e_idle.renders > blocks / 5);
}

test "idle skipping: a control edit wakes a sleeping effect for its hold" {
    const alloc = testing.allocator;
    const frames = 5 * 24000;
    const out = try alloc.alloc(f32, frames * 2);
    defer alloc.free(out);
    var renders: [2]usize = undefined;
    // Asked once, well into the silence between the notes (block 70 of
    // 118, about 1.5 s), where the echo sleeps.
    for (0..2) |i| {
        var e = IdleTestMachines.Env{};
        var echo = IdleTestMachines.Echo{ .gap = 1, .wake_at = if (i == 1) 70 else 0 };
        try idleTestRender(alloc, true, &e, &.{IdleTestMachines.echo(&echo)}, out);
        renders[i] = echo.renders;
    }
    // The wake renders the default hold again: 12000 samples, several blocks.
    try testing.expect(renders[1] > renders[0] + 3);
}

test "idle skipping: sound an effect keeps past its silent output plays when it declares a tail" {
    const alloc = testing.allocator;
    const frames = 5 * 24000;
    const out = try alloc.alloc(f32, frames * 2);
    defer alloc.free(out);
    const gap = 18000; // past the 12000-sample default hold
    const echo_at = gap; // the first loud sample is the note's first
    for ([_]struct { skip: bool, declare: u32, heard: bool }{
        .{ .skip = false, .declare = 0, .heard = true },
        .{ .skip = true, .declare = gap, .heard = true },
        .{ .skip = true, .declare = machine.TAIL_FOREVER, .heard = true },
        // Undeclared, it is skipped before the echo: why the tail exists.
        .{ .skip = true, .declare = 0, .heard = false },
    }) |case| {
        var e = IdleTestMachines.Env{};
        var echo = IdleTestMachines.Echo{ .gap = gap, .declare = case.declare };
        try idleTestRender(alloc, case.skip, &e, &.{IdleTestMachines.echo(&echo)}, out);
        const heard = out[echo_at * 2] > 0.3; // 0.5 × the centre pan's 0.71
        try testing.expectEqual(case.heard, heard);
    }
}

// ── Parallel rendering (docs/07 §Parallel rendering) ────────────────

const ParTestMachines = struct {
    /// Instrument: a sine at its own rate, so every track's samples are
    /// different floats and any change in summing order would show.
    const Osc = struct { phase: f32 = 0, inc: f32 };
    fn osc(o: *Osc) machine.Machine {
        var m = RouteTestMachines.dc(undefined);
        m.name = "osc";
        m.state = o;
        m.render = struct {
            fn f(st: *anyopaque, _: *const machine.MachineCtx, l: []f32, r: []f32) void {
                const s: *Osc = @ptrCast(@alignCast(st));
                for (l, r) |*a, *b| {
                    a.* = @sin(s.phase) * 0.3;
                    b.* = @cos(s.phase * 1.37) * 0.3;
                    s.phase += s.inc;
                }
            }
        }.f;
        m.reset = struct {
            fn f(st: *anyopaque) void {
                const s: *Osc = @ptrCast(@alignCast(st));
                s.phase = 0;
            }
        }.f;
        return m;
    }
};

test "parallel rendering: workers render a routed project bit-identical to one thread" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const n_src = 12;
    var oscs: [n_src]ParTestMachines.Osc = undefined;
    for (&oscs, 0..) |*o, i| o.* = .{ .inc = 0.01 + 0.0137 * @as(f32, @floatFromInt(i)) };
    var zero: f32 = 0;
    var gains = [_]f32{ 0.7, 1.3, 0.9, 1.1 };
    var dly = PdcTestMachines.Delay{ .n = 37 };
    // 0..11 sources, 12 group, 13 verb return, 14 delay return, 15 a bus
    // the group and the delay return feed.
    var tracks: [n_src + 4]Track = undefined;
    for (0..n_src) |i| tracks[i] = try Track.init(alloc, "src", col, ParTestMachines.osc(&oscs[i]));
    for (n_src..n_src + 4) |i| tracks[i] = try Track.init(alloc, "bus", col, RouteTestMachines.dc(&zero));
    defer for (&tracks) |*t| t.deinit(alloc);
    for (n_src..n_src + 4) |i| {
        tracks[i].kind = .bus;
        try tracks[i].addEffect(alloc, RouteTestMachines.gain(&gains[i - n_src]), 0);
    }
    try tracks[3].addEffect(alloc, PdcTestMachines.delay(&dly), 0); // a latent source
    for (0..n_src) |i| {
        if (i % 3 == 0) tracks[i].output = 12;
        if (i % 2 == 0) try tracks[i].addSend(13, i % 4 == 0, 0.3 + 0.05 * @as(f32, @floatFromInt(i)));
        if (i % 5 == 1) try tracks[i].addSend(14, false, 0.4);
    }
    tracks[12].output = 15;
    tracks[14].output = 15;
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);

    var transport = Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    try eng.initPdc(alloc);
    defer eng.deinitPdc(alloc);
    eng.publishRouting();

    const frames = 300 * 256;
    const serial = try alloc.alloc(f32, frames * 2);
    defer alloc.free(serial);
    const parallel = try alloc.alloc(f32, frames * 2);
    defer alloc.free(parallel);
    eng.renderOffline(serial, frames, 0, null, null);
    try eng.initPool(alloc, 4, null);
    defer eng.deinitPool(alloc);
    for (0..3) |_| {
        eng.renderOffline(parallel, frames, 0, null, null);
        try testing.expectEqualSlices(u32, @ptrCast(serial), @ptrCast(parallel));
    }
    // Real-time workers, moved between workgroups (none here: no device).
    eng.deinitPool(alloc);
    try eng.initPool(alloc, 4, .{ .period_ns = 256 * std.time.ns_per_s / 48_000 });
    eng.pool.?.setWorkgroup(null);
    eng.renderOffline(parallel, frames, 0, null, null);
    try testing.expectEqualSlices(u32, @ptrCast(serial), @ptrCast(parallel));
    eng.pool.?.setWorkgroup(null);
    var peak: f32 = 0;
    for (serial) |x| peak = @max(peak, @abs(x));
    try testing.expect(peak > 0.1);
}

test "polytempo and polymeter: a 3:2 track plays its clip's beats 1.5x as fast, its machines in 5/4 at 180" {
    const alloc = testing.allocator;
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var level: f32 = 0;
    var t = try Track.init(alloc, "poly", col, RouteTestMachines.dc(&level));
    defer t.deinit(alloc);
    t.time = .{ .num = 5, .den = 4, .p = 3, .q = 2 };
    var clip = @import("clip.zig").Clip.init("A", 8, 4);
    for (0..6) |k| try clip.addNote(alloc, .{ .pitch = 60, .start_beat = @floatFromInt(k), .length_beats = 0.5, .velocity = 100 });
    try t.addClip(alloc, clip);
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    t.publishSnapshot(&pool);
    const snap = t.currentSnapshot();
    // Six of its beats in four of the song's.
    for (snap.notes[0..snap.note_count], 0..) |n, k| {
        try testing.expectApproxEqAbs(@as(f64, @floatFromInt(k)) / 1.5, n.start_beat, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.5 / 1.5), n.length_beats, 1e-12);
    }
    var pts = meter.MeterMap.singlePoint(4, 4);
    const mm = meter.MeterMap{ .points = &pts };
    // Song beat 10 is two beats into the clip: its beat 3, in its own bars
    // of five.
    const lt = localTime(snap, 10, 120, mm.barInfoAtBeat(10), mm);
    try testing.expectApproxEqAbs(@as(f64, 180), lt.bpm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3), lt.beat, 1e-12);
    try testing.expectEqual(@as(u32, 0), lt.bar);
    try testing.expectApproxEqAbs(@as(f64, 5), lt.bar_len, 1e-12);
    const lt2 = localTime(snap, 12 - 1e-9, 120, mm.barInfoAtBeat(12), mm);
    try testing.expectEqual(@as(u32, 1), lt2.bar);
    try testing.expectApproxEqAbs(@as(f64, 1), lt2.beat_in_bar, 1e-6);
}
