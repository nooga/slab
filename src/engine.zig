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

pub const MAX_BLOCK = audio.BLOCK_FRAMES * 4;
pub const MAX_EVENTS_PER_TRACK = 128;

/// Fallback meter store (constant 4/4) used until the document installs
/// its own. Module-level so the address is stable for the field default.
var default_meter_store: meter.MeterStore = .{};

pub const Engine = struct {
    transport: *Transport,
    tracks: []Track,
    /// Document-owned meter store (read-only on the audio thread). Points
    /// to a constant 4/4 until the document installs its own; must outlive
    /// the engine. Reading `.map()` per block picks up project loads
    /// without a refresh.
    meter_store: *const meter.MeterStore = &default_meter_store,
    was_playing: bool = false,
    audition_request: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    audition_track: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    audition_pitch_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 60))),
    audition_seen: u32 = 0,
    audition_active: bool = false,
    audition_remaining: u32 = 0,
    audition_pitch: f32 = 60,
    audition_track_local: usize = 0,
    trace_counter: u32 = 0,

    /// Master bus. Audio tracks accumulate (planar) into master_l/r, then
    /// the master Track's FX chain + fader run before the interleaved
    /// write to the device. Set once at startup; address is stable.
    master: ?*Track = null,
    master_l: [MAX_BLOCK]f32 = undefined,
    master_r: [MAX_BLOCK]f32 = undefined,
    master_fx_l: [MAX_BLOCK]f32 = undefined,
    master_fx_r: [MAX_BLOCK]f32 = undefined,

    pub fn auditionNote(self: *Engine, track_idx: usize, pitch: u8) void {
        self.audition_track.store(@intCast(@min(track_idx, std.math.maxInt(u32))), .monotonic);
        self.audition_pitch_bits.store(@bitCast(@as(f32, @floatFromInt(pitch))), .monotonic);
        _ = self.audition_request.fetchAdd(1, .release);
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
        var done: usize = 0;
        var pos = start_sample;
        while (done < total_frames) {
            if (cancel) |c| if (c.load(.monotonic)) break;
            const chunk: u32 = @intCast(@min(@as(usize, MAX_BLOCK), total_frames - done));
            const slice = out[done * audio.CHANNELS ..][0 .. chunk * audio.CHANNELS];
            self.renderChunk(slice, chunk, pos);
            masterSoftClip(slice);
            done += chunk;
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
            }
            if (!self.renderAudition(out_slice, frames)) {
                for (self.tracks) |*t| t.setMeter(0, 0);
                if (self.master) |mb| mb.setMeter(0, 0);
            }
        } else {
            self.was_playing = true;

            // Chunk the callback block down to MAX_BLOCK if needed.
            var done: usize = 0;
            var pos = self.transport.samples();
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

            self.transport.seekToSample(pos);
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
        self.resetAllMachines();
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

        const ctx = machine.MachineCtx{
            .sample_rate = @floatFromInt(self.transport.sample_rate),
            .block_size = @intCast(n),
            .block_start = 0,
            .tempo_bpm = @floatCast(self.transport.bpm()),
            .ppq_position = 0,
            .transport_state = .stopped,
            .note_in = if (event_count > 0) @ptrCast(&events[0]) else null,
            .note_in_count = @intCast(event_count),
        };

        const t = &self.tracks[self.audition_track_local];
        if (send_on) t.pulseNote();
        t.machine.render(t.machine.state, &ctx, l, r);
        const rendered = renderEffects(t, ctx, l, r, fx_l_buf[0..n], fx_r_buf[0..n]);
        const final_l = rendered.l;
        const final_r = rendered.r;
        const v = t.volume();
        const pg = t.panGains();
        const vl = v * pg.l;
        const vr = v * pg.r;
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
        // Planar L/R scratch buffers — the machine ABI is
        // channel-planar. For our Zig machines we also hand L/R
        // slices directly to render(), so we don't have to thread
        // the full audio_out port table yet.
        var l_buf: [MAX_BLOCK]f32 = undefined;
        var r_buf: [MAX_BLOCK]f32 = undefined;
        var fx_l_buf: [MAX_BLOCK]f32 = undefined;
        var fx_r_buf: [MAX_BLOCK]f32 = undefined;

        // Tracks accumulate into the master bus (planar), not into `out`,
        // so the master FX chain can process the sum in finishMaster.
        @memset(self.master_l[0..frames], 0);
        @memset(self.master_r[0..frames], 0);

        var any_solo = false;
        for (self.tracks) |*t| {
            if (t.solo.load(.monotonic)) {
                any_solo = true;
                break;
            }
        }

        const sr = self.transport.sample_rate;
        const bpm = self.transport.bpm();
        const spb = self.transport.samplesPerBeat();
        const beat_start = self.transport.samplesToBeats(block_start);
        const beat_end = self.transport.samplesToBeats(block_start + frames);
        // Meter position for this block (homogeneous within the block).
        const bar_info = self.meter_store.map().barInfoAtBeat(beat_start);

        var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

        for (self.tracks) |*t| {
            const muted = t.mute.load(.monotonic) or (any_solo and !t.solo.load(.monotonic));
            if (muted) {
                t.setMeter(0, 0);
                continue;
            }

            const l = l_buf[0..frames];
            const r = r_buf[0..frames];
            @memset(l, 0);
            @memset(r, 0);

            // Load the snapshot pointer once per track per block.
            // See snapshot.zig for the double-buffer invariant.
            const snap = t.currentSnapshot();
            const n_events = gatherEvents(snap, beat_start, beat_end, spb, frames, &events);

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
            // Disabled instrument → feed silence into the effect chain.
            if (t.isEnabled()) t.machine.render(t.machine.state, &ctx, l, r);
            // Audio clips mix on top of the instrument output, into the same
            // planar L/R, so the track's insert chain processes the sum.
            mixAudioClips(snap, block_start, frames, spb, sr, l, r);
            const inst_ns = if (track_probe) probeNowNs() - inst_start else 0;
            const fx_start = if (track_probe) probeNowNs() else 0;
            const rendered = renderEffects(t, ctx, l, r, fx_l_buf[0..frames], fx_r_buf[0..frames]);
            const fx_ns = if (track_probe) probeNowNs() - fx_start else 0;
            const final_l = rendered.l;
            const final_r = rendered.r;

            const v = t.volume();
            const pg = t.panGains();
            const vl = v * pg.l;
            const vr = v * pg.r;
            var peak_l: f32 = 0;
            var peak_r: f32 = 0;
            var i: usize = 0;
            while (i < frames) : (i += 1) {
                const sl = final_l[i] * vl;
                const sr2 = final_r[i] * vr;
                self.master_l[i] += sl;
                self.master_r[i] += sr2;
                const al = @abs(sl);
                const ar = @abs(sr2);
                if (al > peak_l) peak_l = al;
                if (ar > peak_r) peak_r = ar;
            }
            t.setMeter(peak_l, peak_r);
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
            const pg = mb.panGains();
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

fn renderEffects(
    t: *Track,
    base_ctx: machine.MachineCtx,
    src_l: []f32,
    src_r: []f32,
    scratch_l: []f32,
    scratch_r: []f32,
) RenderedPair {
    var cur_l = src_l;
    var cur_r = src_r;
    var next_l = scratch_l;
    var next_r = scratch_r;

    for (t.effects.items, 0..) |*fx, i| {
        if (t.effectBypassed(i)) continue; // bypassed → pass through untouched
        @memset(next_l, 0);
        @memset(next_r, 0);
        const in_ports = [_][*]const f32{ cur_l.ptr, cur_r.ptr };
        var ctx = base_ctx;
        ctx.note_in = null;
        ctx.note_in_count = 0;
        ctx.audio_in = @ptrCast(&in_ports[0]);
        ctx.audio_in_count = 2;
        fx.mach.render(fx.mach.state, &ctx, next_l, next_r);

        const old_l = cur_l;
        const old_r = cur_r;
        cur_l = next_l;
        cur_r = next_r;
        next_l = old_l;
        next_r = old_r;
    }

    return .{ .l = cur_l, .r = cur_r };
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
            const src_pos = clip.start_sample + (a - clip_start) * step;
            if (src_pos < 0) continue;
            const idx0f = @floor(src_pos);
            const idx0: usize = @intFromFloat(idx0f);
            if (idx0 >= len) break; // source exhausted — rest of clip is silent
            const frac: f32 = @floatCast(src_pos - idx0f);
            const s0: f32 = @floatCast(data[idx0]);
            const s1: f32 = if (idx0 + 1 < len) @floatCast(data[idx0 + 1]) else s0;
            // Linear fade-in/out envelope over the played window.
            const pos = src_pos - clip.start_sample; // samples into the window
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

fn gatherEvents(
    snap: *const snap_mod.TrackSnapshot,
    beat_start: f64,
    beat_end: f64,
    samples_per_beat: f64,
    frames: u32,
    out: *[MAX_EVENTS_PER_TRACK]machine.NoteEvent,
) usize {
    var count: usize = 0;

    for (snap.clips[0..snap.clip_count]) |clip| {
        const clip_end = clip.start_beat + clip.length_beats;
        if (clip_end <= beat_start) continue;
        if (clip.start_beat >= beat_end) continue;

        const note_slice = snap.notes[clip.notes_start..][0..clip.notes_count];
        for (note_slice) |note| {
            const abs_on = clip.start_beat + note.start_beat;
            const abs_off_raw = abs_on + note.length_beats;
            const abs_off = @min(abs_off_raw, clip_end);

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
                        .note_id = -1,
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
                        .note_id = -1,
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

    // Block covers beats [0..2): expect note-on at beat 0 (offset 0).
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, &events);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(events[0].kind == .note_on);
    try testing.expectEqual(@as(f32, 60), events[0].pitch);
    try testing.expectEqual(@as(u32, 0), events[0].sample_offset);
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

    // Block covers beats [1..3): note-off at beat 1 = sample offset 0.
    const n = gatherEvents(&snap, 1.0, 3.0, spb, frames, &events);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(events[0].kind == .note_off);
    try testing.expectEqual(@as(u32, 0), events[0].sample_offset);
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
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, &events);
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
    const n = gatherEvents(&snap, 4.0, 6.0, spb, frames, &events);
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
    const n = gatherEvents(&snap, 0, 4.0, spb, frames, &events);
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
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, &events);
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
