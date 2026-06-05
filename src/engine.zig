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

pub const MAX_BLOCK = audio.BLOCK_FRAMES * 4;
pub const MAX_EVENTS_PER_TRACK = 128;

pub const Engine = struct {
    transport: *Transport,
    tracks: []Track,
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

    pub fn auditionNote(self: *Engine, track_idx: usize, pitch: u8) void {
        self.audition_track.store(@intCast(@min(track_idx, std.math.maxInt(u32))), .monotonic);
        self.audition_pitch_bits.store(@bitCast(@as(f32, @floatFromInt(pitch))), .monotonic);
        _ = self.audition_request.fetchAdd(1, .release);
    }

    pub fn renderCallback(ctx: *anyopaque, out: [*]f32, frames: u32) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        self.render(out, frames);
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
                    for (t.effects[0..t.effect_count]) |*fx| fx.reset(fx.state);
                    t.setMeter(0, 0);
                }
                self.was_playing = false;
            }
            if (!self.renderAudition(out_slice, frames)) {
                for (self.tracks) |*t| t.setMeter(0, 0);
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
            for (t.effects[0..t.effect_count]) |*fx| fx.reset(fx.state);
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
                for (old.effects[0..old.effect_count]) |*fx| fx.reset(fx.state);
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
        t.machine.render(t.machine.state, &ctx, l, r);
        const rendered = renderEffects(t, ctx, l, r, fx_l_buf[0..n], fx_r_buf[0..n]);
        const final_l = rendered.l;
        const final_r = rendered.r;
        const v = t.volume();
        var peak_l: f32 = 0;
        var peak_r: f32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const sl = final_l[i] * v;
            const sr = final_r[i] * v;
            out[i * 2] += sl;
            out[i * 2 + 1] += sr;
            peak_l = @max(peak_l, @abs(sl));
            peak_r = @max(peak_r, @abs(sr));
        }
        t.setMeter(peak_l, peak_r);

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
            };

            const track_probe = trackProbeEnabled();
            const inst_start = if (track_probe) probeNowNs() else 0;
            t.machine.render(t.machine.state, &ctx, l, r);
            const inst_ns = if (track_probe) probeNowNs() - inst_start else 0;
            const fx_start = if (track_probe) probeNowNs() else 0;
            const rendered = renderEffects(t, ctx, l, r, fx_l_buf[0..frames], fx_r_buf[0..frames]);
            const fx_ns = if (track_probe) probeNowNs() - fx_start else 0;
            const final_l = rendered.l;
            const final_r = rendered.r;

            const v = t.volume();
            var peak_l: f32 = 0;
            var peak_r: f32 = 0;
            var i: usize = 0;
            while (i < frames) : (i += 1) {
                const sl = final_l[i] * v;
                const sr2 = final_r[i] * v;
                out[i * 2] += sl;
                out[i * 2 + 1] += sr2;
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
                            t.effect_count,
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

    for (t.effects[0..t.effect_count]) |*fx| {
        @memset(next_l, 0);
        @memset(next_r, 0);
        const in_ports = [_][*]const f32{ cur_l.ptr, cur_r.ptr };
        var ctx = base_ctx;
        ctx.note_in = null;
        ctx.note_in_count = 0;
        ctx.audio_in = @ptrCast(&in_ports[0]);
        ctx.audio_in_count = 2;
        fx.render(fx.state, &ctx, next_l, next_r);

        const old_l = cur_l;
        const old_r = cur_r;
        cur_l = next_l;
        cur_r = next_r;
        next_l = old_l;
        next_r = old_r;
    }

    return .{ .l = cur_l, .r = cur_r };
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
