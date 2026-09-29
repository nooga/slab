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
const automation = @import("automation.zig");
const routing = @import("routing.zig");

pub const MAX_BLOCK = audio.BLOCK_FRAMES * 4;
pub const MAX_EVENTS_PER_TRACK = 1024;
/// Expression events for a bent note go out every this many samples while
/// it sounds (docs/22 §Note expression): 0.67 ms at 48 kHz.
pub const EXPR_STEP: u32 = 32;

/// Fallback meter state (constant 4/4) used until the document installs
/// its own. Module-level so the address is stable for the field default.
var default_meter_state: meter.MeterState = .{};

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
    /// Panic request from the UI thread, served at the top of the next
    /// render (machine state belongs to the audio thread).
    panic_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    trace_counter: u32 = 0,

    /// Master bus. Audio tracks accumulate (planar) into master_l/r, then
    /// the master Track's FX chain + fader run before the interleaved
    /// write to the device. Set once at startup; address is stable.
    master: ?*Track = null,
    master_l: [MAX_BLOCK]f32 = undefined,
    master_r: [MAX_BLOCK]f32 = undefined,
    master_fx_l: [MAX_BLOCK]f32 = undefined,
    master_fx_r: [MAX_BLOCK]f32 = undefined,

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

    /// UI thread, before audio starts.
    pub fn initPdc(self: *Engine, alloc: std.mem.Allocator) !void {
        const h = try alloc.create(PdcHistory);
        h.clear();
        self.pdc = h;
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
            if (nd.key_count > 0) {
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
        self.resetAllMachines();
        self.chase_pending = true;
        var pos = start_sample;
        // The master is late by the project's latency: its first `skip`
        // frames are dropped, so the bounce lines up with the timeline. The
        // blocks stay where they'd be without it (machines with block-rate
        // randomness render the same), only the copy out is offset.
        var fallback: routing.Routing = undefined;
        self.computeLatencies(self.currentGraph(&fallback));
        const skip: usize = self.master_latency.load(.monotonic);
        var scratch: [MAX_BLOCK * audio.CHANNELS]f32 = undefined;
        var rendered: usize = 0;
        var done: usize = 0;
        while (done < total_frames) {
            if (cancel) |c| if (c.load(.monotonic)) break;
            const chunk: u32 = @intCast(@min(@as(usize, MAX_BLOCK), total_frames + skip - rendered));
            const dropped = if (rendered < skip) @min(chunk, skip - rendered) else 0;
            const direct = dropped == 0;
            const slice = if (direct) out[done * audio.CHANNELS ..][0 .. chunk * audio.CHANNELS] else scratch[0 .. chunk * audio.CHANNELS];
            self.renderChunk(slice, chunk, pos);
            masterSoftClip(slice);
            if (!direct) {
                const keep = slice[dropped * audio.CHANNELS ..];
                @memcpy(out[done * audio.CHANNELS ..][0..keep.len], keep);
            }
            done += chunk - dropped;
            rendered += chunk;
            pos += chunk;
            if (progress) |p| p.store(done, .monotonic);
        }
        self.resetAllMachines();
        self.was_playing = false;
    }

    fn render(self: *Engine, out: [*]f32, frames: u32) void {
        const n: usize = frames;
        const total = n * audio.CHANNELS;
        var out_slice = out[0..total];
        @memset(out_slice, 0);

        if (self.panic_request.swap(false, .acquire)) {
            self.resetAllMachines();
            self.audition_active = false;
            self.audition_seen = self.audition_request.load(.acquire);
        }

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
                self.release_from = self.transport.samplesToBeats(self.played_to);
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

        // Master output stage: linear pass-through up to ±0.7, then a smooth
        // soft-knee saturator that asymptotes toward ±1.0. Internal mix is
        // 32-bit float with effectively unlimited headroom, just like Live's
        // master bus — this stage only kicks in when the sum gets hot, and
        // replaces the device-level hard-clip that produced "deep-fried"
        // output when many sources stacked.
        const trace_audio = audioTraceEnabled();
        const trace_signal = signalProbeEnabled();
        const pre_clip_peak = if (trace_audio) peakInterleaved(out_slice) else 0;
        const pre_stats = if (trace_signal) signalStatsInterleaved(out_slice) else SignalStats{};
        masterSoftClip(out_slice);
        const post_stats = if (trace_signal) signalStatsInterleaved(out_slice) else SignalStats{};
        if (trace_audio) {
            const post_clip_peak = peakInterleaved(out_slice);
            self.trace_counter +%= 1;
            if (pre_clip_peak > KNEE or self.trace_counter % 256 == 0) {
                std.debug.print(
                    "audio master frame={} playing={} pre={d:.3} post={d:.3} knee={d:.3}\n",
                    .{ self.transport.samples(), playing, pre_clip_peak, post_clip_peak, KNEE },
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

    fn nextRenderChunk(self: *Engine, max_frames: u32, pos: u64) usize {
        if (!self.transport.loopEnabled()) return max_frames;
        const start_b = self.transport.loopStartBeats();
        const end_b = self.transport.loopEndBeats();
        if (end_b <= start_b) return max_frames;
        const start_s = self.transport.beatsToSamples(start_b);
        const end_s = self.transport.beatsToSamples(end_b);
        if (end_s <= start_s or pos < start_s or pos >= end_s) return max_frames;
        const to_end = end_s - pos;
        if (to_end == 0) return max_frames;
        return @intCast(@min(@as(u64, max_frames), to_end));
    }

    fn advanceRenderPos(self: *Engine, pos: u64, frames: u32) u64 {
        var next = pos + frames;
        if (!self.transport.loopEnabled()) return next;
        const start_b = self.transport.loopStartBeats();
        const end_b = self.transport.loopEndBeats();
        if (end_b <= start_b) return next;
        const start_s = self.transport.beatsToSamples(start_b);
        const end_s = self.transport.beatsToSamples(end_b);
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
        self.release_from = self.transport.samplesToBeats(pos + frames);
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
        const beat = self.transport.beats();
        const inst_view = snap_mod.AutoView{ .snap = snap, .cursors = &t.auto_cursors, .kind = .inst };
        const ctx = machine.MachineCtx{
            .sample_rate = @floatFromInt(self.transport.sample_rate),
            .block_size = @intCast(n),
            .block_start = 0,
            .tempo_bpm = @floatCast(self.transport.bpm()),
            .ppq_position = beat,
            .transport_state = .stopped,
            .note_in = if (event_count > 0) @ptrCast(&events[0]) else null,
            .note_in_count = @intCast(event_count),
            .automation = if (snap.lane_count > 0) &inst_view else null,
        };

        if (send_on) t.pulseNote();
        t.machine.render(t.machine.state, &ctx, l, r);
        const rendered = renderEffects(t, ctx, l, r, fx_l_buf[0..n], fx_r_buf[0..n]);
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
        // Planar L/R scratch — the machine ABI is channel-planar. Each
        // track renders into its pre tap (self.pre_l/r); this pair is the
        // effect chain's ping-pong partner, then the post-fader signal.
        var fx_l_buf: [MAX_BLOCK]f32 = undefined;
        var fx_r_buf: [MAX_BLOCK]f32 = undefined;

        // Tracks accumulate into the master bus (planar), not into `out`,
        // so the master FX chain can process the sum in finishMaster.
        @memset(self.master_l[0..frames], 0);
        @memset(self.master_r[0..frames], 0);

        var fallback: routing.Routing = undefined;
        const graph = self.currentGraph(&fallback);
        var muted: u32 = 0;
        var soloed: u32 = 0;
        for (self.tracks[0..graph.count], 0..) |*t, i| {
            if (t.mute.load(.monotonic)) muted |= routing.bit(@intCast(i));
            if (t.solo.load(.monotonic)) soloed |= routing.bit(@intCast(i));
        }
        const heard = graph.audible(muted, soloed);
        const live = graph.rendered(heard);
        self.computeLatencies(graph);
        for (graph.nodes[0..graph.count], 0..) |nd, i| if (nd.is_bus) {
            @memset(self.bus_l[i][0..frames], 0);
            @memset(self.bus_r[i][0..frames], 0);
        };

        const sr = self.transport.sample_rate;
        const bpm = self.transport.bpm();
        const spb = self.transport.samplesPerBeat();
        const beat_start = self.transport.samplesToBeats(block_start);
        const beat_end = self.transport.samplesToBeats(block_start + frames);
        const chase = self.chase_pending;
        self.chase_pending = false;
        const release_at = self.release_from;
        self.release_from = null;
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

        var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

        for (graph.renderOrder()) |ti| {
            const t = &self.tracks[ti];
            const node = &graph.nodes[ti];
            if (live & routing.bit(ti) == 0) {
                if (self.pdc) |h| h.silence(ti, frames);
                t.setMeter(0, 0);
                continue;
            }
            const is_heard = heard & routing.bit(ti) != 0;

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
            const n_events = gatherEvents(snap, beat_start, beat_end, spb, frames, chase, release_at, &events);

            const inst_view = snap_mod.AutoView{ .snap = snap, .cursors = &t.auto_cursors, .kind = .inst };
            const ctx = machine.MachineCtx{
                .sample_rate = @floatFromInt(sr),
                .block_size = frames,
                .block_start = block_start,
                .tempo_bpm = @floatCast(bpm),
                .ppq_position = beat_start,
                .transport_state = .playing,
                .note_in = if (n_events > 0) @ptrCast(&events[0]) else null,
                .note_in_count = @intCast(n_events),
                .bar = bar_info.bar,
                .beat_in_bar = beat_start - bar_info.bar_start_beat,
                .bar_len_beats = bar_info.bar_len_beats,
                .automation = if (snap.lane_count > 0) &inst_view else null,
            };

            // Note-activity LED: pulse when a note-on is dispatched this block.
            for (events[0..n_events]) |ev| {
                if (ev.kind == .note_on) {
                    t.pulseNote();
                    break;
                }
            }

            const track_probe = trackProbeEnabled();
            const inst_start = if (track_probe) probeNowNs() else 0;
            if (!node.is_bus) {
                // Disabled instrument → feed silence into the effect chain.
                if (t.isEnabled()) t.machine.render(t.machine.state, &ctx, l, r);
                // Audio clips mix on top of the instrument output, into the
                // same planar L/R, so the track's insert chain processes the sum.
                mixAudioClips(snap, block_start, frames, spb, sr, l, r);
                // Late for a key that arrives later still (PDC).
                if (self.pdc) |h| {
                    h.put(ti, .input, l, r);
                    const d = self.lat_in[ti];
                    if (d > 0) h.read(ti, .input, h.w[ti], d, l, r);
                }
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
            const rendered = renderEffectsKeyed(t, ctx, l, r, fx_l_buf[0..frames], fx_r_buf[0..frames], keys);
            const fx_ns = if (track_probe) probeNowNs() - fx_start else 0;
            // The chain may end in the scratch pair; the pre tap is `l`/`r`.
            if (rendered.l.ptr != l.ptr) {
                @memcpy(l, rendered.l);
                @memcpy(r, rendered.r);
            }
            const final_l: []const f32 = l;
            const final_r: []const f32 = r;

            // Fader gains at the block's ends; automated volume/pan ramp
            // between them per sample (docs/22 §Track volume and pan).
            const g0 = faderGains(t, snap, beat_start);
            const g1 = faderGains(t, snap, beat_end);
            const v = g0.v;
            const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(frames));
            // Post-fader signal into the free scratch pair, then summed into
            // the output and the post-fader sends.
            const post_l = fx_l_buf[0..frames];
            const post_r = fx_r_buf[0..frames];
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
            // The taps' history, for paths that must arrive later (PDC).
            const hist_at = if (self.pdc) |h| h.write(ti, final_l, final_r, post_l, post_r) else 0;
            self.hist_at[ti] = hist_at;
            var dly_l: [MAX_BLOCK]f32 = undefined;
            var dly_r: [MAX_BLOCK]f32 = undefined;
            if (is_heard) {
                const dst_l = if (node.output == routing.NONE) self.master_l[0..frames] else self.bus_l[node.output][0..frames];
                const dst_r = if (node.output == routing.NONE) self.master_r[0..frames] else self.bus_r[node.output][0..frames];
                const out_in = if (node.output == routing.NONE) self.lat_master_in else self.lat_in[node.output];
                const out_tap = self.tapped(ti, .post, hist_at, out_in -| self.lat_out[ti], post_l, post_r, &dly_l, &dly_r);
                for (dst_l, out_tap.l) |*d, x| d.* += x;
                for (dst_r, out_tap.r) |*d, x| d.* += x;
                for (node.sendSlots(), 0..) |s, si| {
                    // The track's send list can be shorter than the
                    // published one for a frame after a send is removed.
                    if (si >= t.send_count) break;
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
                t.setMeter(peak_l, peak_r);
            } else t.setMeter(0, 0);
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

        self.finishMaster(out, frames);
    }

    /// Master bus post-processing: run the master Track's FX chain over the
    /// accumulated planar bus, apply the master fader, write interleaved to
    /// `out`, and update the master meter. With no master configured (or no
    /// FX) it is fader/passthrough. The top-level masterSoftClip then runs
    /// once over the whole device buffer.
    fn finishMaster(self: *Engine, out: []f32, frames: u32) void {
        const n: usize = frames;
        var l: []f32 = self.master_l[0..n];
        var r: []f32 = self.master_r[0..n];
        var mv: f32 = 1.0;
        var mpl: f32 = 1.0;
        var mpr: f32 = 1.0;
        if (self.master) |mb| {
            if (mb.effectCount() > 0) {
                const base = machine.MachineCtx{
                    .sample_rate = @floatFromInt(self.transport.sample_rate),
                    .block_size = frames,
                    .block_start = 0,
                    .tempo_bpm = @floatCast(self.transport.bpm()),
                    .ppq_position = 0,
                    .transport_state = if (self.transport.isPlaying()) .playing else .stopped,
                };
                const rendered = renderEffects(mb, base, l, r, self.master_fx_l[0..n], self.master_fx_r[0..n]);
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

// Soft-knee saturator. Linear inside ±KNEE so quiet/normal mixes are
// bit-perfect; above KNEE it bends smoothly and asymptotes toward ±1.0
// regardless of input magnitude. Curve is C¹-continuous at ±KNEE.
//
//   y = x                                 for |x| ≤ K
//   y = sgn(x) · (K + (1-K)·t / (t + R))  for |x| > K, t = |x| - K
//
// R controls the knee shape; R = 1 - K gives a clean smooth transition.
const KNEE: f32 = 0.7;
const KNEE_R: f32 = 0.3; // 1 - KNEE

inline fn softClip(x: f32) f32 {
    const ax = @abs(x);
    if (ax <= KNEE) return x;
    const sign: f32 = if (x < 0) -1.0 else 1.0;
    const over = ax - KNEE;
    return sign * (KNEE + KNEE_R * (over / (over + KNEE_R)));
}

fn masterSoftClip(buf: []f32) void {
    for (buf) |*s| s.* = softClip(s.*);
}

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
    var n = instLatency(t, is_bus);
    for (t.effects.items, 0..) |*fx, i| {
        if (!t.effectBypassed(i)) n += fx.mach.latencySamples();
    }
    return n;
}

fn instLatency(t: *const Track, is_bus: bool) u32 {
    return if (!is_bus and t.isEnabled()) t.machine.latencySamples() else 0;
}

fn renderEffects(
    t: *Track,
    base_ctx: machine.MachineCtx,
    src_l: []f32,
    src_r: []f32,
    scratch_l: []f32,
    scratch_r: []f32,
) RenderedPair {
    return renderEffectsKeyed(t, base_ctx, src_l, src_r, scratch_l, scratch_r, null);
}

fn renderEffectsKeyed(
    t: *Track,
    base_ctx: machine.MachineCtx,
    src_l: []f32,
    src_r: []f32,
    scratch_l: []f32,
    scratch_r: []f32,
    keys: ?Keys,
) RenderedPair {
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
        fx.setIo(in_peak, .{ blockPeak(next_l), blockPeak(next_r) });

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
    samples_per_beat: f64,
    sample_rate: u32,
    l: []f32,
    r: []f32,
) void {
    const block_lo: f64 = @floatFromInt(block_start);
    const block_hi: f64 = block_lo + @as(f64, @floatFromInt(frames));

    for (snap.audio_clips[0..snap.audio_clip_count]) |clip| {
        const data = clip.data orelse continue;
        if (clip.len == 0 or clip.source_rate <= 0) continue;

        const clip_start = clip.start_beat * samples_per_beat;
        const clip_end = (clip.start_beat + clip.length_beats) * samples_per_beat;
        const lo = @max(block_lo, clip_start);
        const hi = @min(block_hi, clip_end);
        if (hi <= lo) continue;

        // Source samples advanced per engine output sample.
        const engine_rate: f64 = @floatFromInt(sample_rate);
        const step = clip.source_rate / engine_rate;
        const len = clip.len;

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
            if (src_pos < 0) {
                if (clip.reversed) break; // read past the source head
                continue;
            }
            const idx0f = @floor(src_pos);
            const idx0: usize = @intFromFloat(idx0f);
            if (idx0 >= len) {
                if (clip.reversed) continue; // window runs past the source end: silent until it's back in
                break; // source exhausted — rest of clip is silent
            }
            const frac: f32 = @floatCast(src_pos - idx0f);
            const s0: f32 = @floatCast(data[idx0]);
            const s1: f32 = if (idx0 + 1 < len) @floatCast(data[idx0 + 1]) else s0;
            // Linear fade-in/out envelope over the played window.
            var fade: f64 = 1.0;
            if (clip.fade_in_samples > 0 and pos < clip.fade_in_samples)
                fade = pos / clip.fade_in_samples;
            if (clip.fade_out_samples > 0) {
                const remaining = clip.dur_samples - pos;
                if (remaining < clip.fade_out_samples)
                    fade = @min(fade, @max(0.0, remaining) / clip.fade_out_samples);
            }
            const v = (s0 + (s1 - s0) * frac) * clip.gain * @as(f32, @floatCast(fade));
            l[i] += v;
            r[i] += v;
        }
    }
}

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
        const in_block = clip_end > beat_start and clip.start_beat < beat_end;
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

test "mixAudioClips: places source at clip start and resamples by rate" {
    // Source: a ramp 0,1,2,3,... at 24 kHz; engine at 48 kHz → step 0.5.
    var data: [8]f64 = undefined;
    for (&data, 0..) |*s, i| s.* = @floatFromInt(i);

    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{
        .start_beat = 1.0,
        .length_beats = 4.0,
        .data = &data,
        .len = data.len,
        .source_rate = 24_000,
        .gain = 1.0,
    };

    const spb: f64 = 100.0; // samples per beat → clip starts at sample 100
    var l = [_]f32{0} ** 8;
    var r = [_]f32{0} ** 8;
    // Block starting exactly at the clip's first sample.
    mixAudioClips(&snap, 100, 8, spb, 48_000, &l, &r);

    // step = 24000/48000 = 0.5 → src positions 0,0.5,1,1.5,... interpolated.
    try testing.expectApproxEqAbs(@as(f32, 0.0), l[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), l[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.5), l[3], 1e-5);
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
    mixAudioClips(&snap, 0, 8, spb, 48_000, &l, &r);
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
    mixAudioClips(&snap, 0, 4, 100.0, 48_000, &l, &r);
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
    mixAudioClips(&snap, 0, 8, 100.0, 48_000, &l, &r);
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
    mixAudioClips(&snap, 0, 6, 6.0, 48_000, &l, &r);
    // 7, 6, 5, 4, 3, 2 with the fade-in on the first two (0, 0.5).
    try testing.expectApproxEqAbs(@as(f32, 0), l[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3), l[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5), l[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2), l[5], 1e-5);
}

test "mixAudioClips: missing source data is skipped" {
    var snap = snap_mod.TrackSnapshot{};
    snap.audio_clip_count = 1;
    snap.audio_clips[0] = .{ .start_beat = 0, .length_beats = 4, .data = null };
    var l = [_]f32{0} ** 4;
    var r = [_]f32{0} ** 4;
    mixAudioClips(&snap, 0, 4, 10.0, 48_000, &l, &r);
    for (l) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "softClip: linear pass-through inside the knee" {
    try testing.expectEqual(@as(f32, 0.0), softClip(0.0));
    try testing.expectEqual(@as(f32, 0.5), softClip(0.5));
    try testing.expectEqual(@as(f32, -0.5), softClip(-0.5));
    try testing.expectEqual(@as(f32, KNEE), softClip(KNEE));
}

test "softClip: continuous at the knee" {
    const eps: f32 = 1e-6;
    const below = softClip(KNEE - eps);
    const above = softClip(KNEE + eps);
    try testing.expect(@abs(below - above) < 1e-3);
}

test "softClip: bounded in (-1, 1) for arbitrary input" {
    const inputs = [_]f32{ 1.0, 1.5, 4.0, 100.0, -1.0, -1.5, -4.0, -100.0 };
    for (inputs) |x| {
        const y = softClip(x);
        try testing.expect(y > -1.0);
        try testing.expect(y < 1.0);
        // sign preserved
        if (x > 0) try testing.expect(y > 0);
        if (x < 0) try testing.expect(y < 0);
    }
}

test "softClip: monotonic" {
    var prev = softClip(-10.0);
    var x: f32 = -10.0;
    while (x <= 10.0) : (x += 0.1) {
        const y = softClip(x);
        try testing.expect(y >= prev);
        prev = y;
    }
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
