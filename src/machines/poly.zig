//! Host-side polyphony wrapper.
//!
//! Each voice is a complete child Machine instance. The wrapper only
//! handles note routing and summing; the child machine remains monophonic.

const std = @import("std");
const audio = @import("../audio.zig");
const machine = @import("../machine.zig");
const widgets = @import("../ui/widgets.zig");
const c = @import("../c.zig");

pub const MAX_VOICES = 16;
const MAX_EVENTS_PER_VOICE = 128;
const MAX_BLOCK = audio.BLOCK_FRAMES * 4;
const RELEASE_TAIL_BLOCKS = 96;

pub const PolyMachine = struct {
    voices: [MAX_VOICES]machine.Machine = undefined,
    voice_count: u8 = 0,
    active: [MAX_VOICES]bool = [_]bool{false} ** MAX_VOICES,
    note_id: [MAX_VOICES]i32 = [_]i32{0} ** MAX_VOICES,
    channel: [MAX_VOICES]u8 = [_]u8{0} ** MAX_VOICES,
    pitch: [MAX_VOICES]f32 = [_]f32{0} ** MAX_VOICES,
    age: [MAX_VOICES]u64 = [_]u64{0} ** MAX_VOICES,
    tail_blocks: [MAX_VOICES]u16 = [_]u16{0} ** MAX_VOICES,
    clock: u64 = 0,
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    panel_w: f32 = 0,
    trace_counter: u32 = 0,

    pub fn init(name: []const u8, voice_count: u8) PolyMachine {
        var self = PolyMachine{ .voice_count = @min(voice_count, MAX_VOICES) };
        const n = @min(name.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], name[0..n]);
        self.name_len = n;
        return self;
    }

    pub fn machineInterface(self: *PolyMachine) machine.Machine {
        return .{
            .name = self.name_buf[0..self.name_len],
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .deinit = deinitImpl,
            .sync_params = syncParamsImpl,
            .preset_count = presetCountImpl,
            .preset_name = presetNameImpl,
            .apply_preset = applyPresetImpl,
            .write_params_json = writeParamsJsonImpl,
            .set_param = setParamImpl,
            .panel_w = self.panel_w,
        };
    }
};

fn renderImpl(state: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    @memset(l, 0);
    @memset(r, 0);
    const n = @min(l.len, @min(r.len, MAX_BLOCK));

    if (ctx.note_in == null or ctx.note_in_count == 0) {
        var counts: [MAX_VOICES]usize = [_]usize{0} ** MAX_VOICES;
        var routed: [MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent = undefined;
        renderPolySegment(self, ctx, l[0..n], r[0..n], &routed, &counts, 0, n, 0);
        retireTails(self);
        return;
    }

    const events = ctx.note_in.?[0..ctx.note_in_count];
    var event_scratch: [MAX_EVENTS_PER_VOICE]machine.NoteEvent = undefined;
    var pos: usize = 0;
    var ei: usize = 0;

    while (pos < n) {
        const next_event_pos = if (ei < events.len) @min(@as(usize, @intCast(events[ei].sample_offset)), n) else n;
        if (next_event_pos > pos) {
            var counts: [MAX_VOICES]usize = [_]usize{0} ** MAX_VOICES;
            var routed: [MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent = undefined;
            renderPolySegment(self, ctx, l[pos..next_event_pos], r[pos..next_event_pos], &routed, &counts, pos, next_event_pos, 0);
            pos = next_event_pos;
            continue;
        }

        var group_count: usize = 0;
        while (ei < events.len and @min(@as(usize, @intCast(events[ei].sample_offset)), n) == pos) : (ei += 1) {
            event_scratch[group_count] = events[ei];
            event_scratch[group_count].sample_offset = 0;
            group_count += 1;
        }

        const segment_end = if (ei < events.len) @min(@as(usize, @intCast(events[ei].sample_offset)), n) else n;
        var seg_ctx = ctx.*;
        seg_ctx.block_start = ctx.block_start + pos;
        seg_ctx.block_size = @intCast(segment_end - pos);
        seg_ctx.note_in = if (group_count > 0) @ptrCast(event_scratch[0..group_count].ptr) else null;
        seg_ctx.note_in_count = @intCast(group_count);

        var counts: [MAX_VOICES]usize = [_]usize{0} ** MAX_VOICES;
        var routed: [MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent = undefined;
        routeEvents(self, &seg_ctx, &routed, &counts);
        renderPolySegment(self, &seg_ctx, l[pos..segment_end], r[pos..segment_end], &routed, &counts, pos, segment_end, group_count);
        pos = segment_end;
    }

    retireTails(self);
}

fn renderPolySegment(
    self: *PolyMachine,
    ctx: *const machine.MachineCtx,
    l: []f32,
    r: []f32,
    routed: *[MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent,
    counts: *[MAX_VOICES]usize,
    segment_start: usize,
    segment_end: usize,
    event_count: usize,
) void {
    const frames = l.len;
    if (frames == 0) return;

    const rendered_count = renderedVoiceCount(self, counts);
    const poly_gain = polyGain(rendered_count);
    traceSegment(self, ctx, rendered_count, poly_gain, segment_start, segment_end, event_count);

    var vi: usize = 0;
    while (vi < self.voice_count) : (vi += 1) {
        if (!self.active[vi] and counts[vi] == 0 and self.tail_blocks[vi] == 0) continue;

        var vl_buf: [MAX_BLOCK]f32 = undefined;
        var vr_buf: [MAX_BLOCK]f32 = undefined;
        const vl = vl_buf[0..frames];
        const vr = vr_buf[0..frames];
        @memset(vl, 0);
        @memset(vr, 0);

        var vctx = ctx.*;
        vctx.block_size = @intCast(frames);
        vctx.note_in = if (counts[vi] > 0) @ptrCast(&routed[vi][0]) else null;
        vctx.note_in_count = @intCast(counts[vi]);
        self.voices[vi].render(self.voices[vi].state, &vctx, vl, vr);

        var i: usize = 0;
        while (i < frames) : (i += 1) {
            l[i] += vl[i] * poly_gain;
            r[i] += vr[i] * poly_gain;
        }
    }
}

fn retireTails(self: *PolyMachine) void {
    for (0..self.voice_count) |vi| {
        if (self.tail_blocks[vi] == 0) continue;
        self.tail_blocks[vi] -= 1;
        if (self.tail_blocks[vi] == 0) {
            self.active[vi] = false;
        }
    }
}

fn renderedVoiceCount(self: *const PolyMachine, counts: *const [MAX_VOICES]usize) usize {
    _ = counts;
    var n: usize = 0;
    for (0..self.voice_count) |vi| {
        if (self.active[vi] or self.tail_blocks[vi] > 0) n += 1;
    }
    return n;
}

fn activeVoiceCount(self: *const PolyMachine) usize {
    var n: usize = 0;
    for (0..self.voice_count) |vi| {
        if (self.active[vi]) n += 1;
    }
    return n;
}

fn tailVoiceCount(self: *const PolyMachine) usize {
    var n: usize = 0;
    for (0..self.voice_count) |vi| {
        if (self.tail_blocks[vi] > 0) n += 1;
    }
    return n;
}

fn polyTraceEnabled() bool {
    return std.c.getenv("SLAB_POLY_TRACE") != null;
}

fn traceSegment(
    self: *PolyMachine,
    ctx: *const machine.MachineCtx,
    rendered_count: usize,
    poly_gain: f32,
    segment_start: usize,
    segment_end: usize,
    event_count: usize,
) void {
    if (!polyTraceEnabled()) return;
    self.trace_counter +%= 1;
    if (event_count == 0 and rendered_count <= 1 and self.trace_counter % 256 != 0) return;
    std.debug.print(
        "poly \"{s}\" block={} seg={}..{} events={} rendered={} active={} tails={} gain={d:.3}\n",
        .{
            self.name_buf[0..self.name_len],
            ctx.block_start,
            segment_start,
            segment_end,
            event_count,
            rendered_count,
            activeVoiceCount(self),
            tailVoiceCount(self),
            poly_gain,
        },
    );
    traceEvents(self, ctx);
}

fn polyGain(rendered_count: usize) f32 {
    return switch (rendered_count) {
        0, 1 => 1.0,
        2 => 0.70710677,
        3 => 0.57735026,
        4 => 0.5,
        5 => 0.4472136,
        6 => 0.40824828,
        7 => 0.37796447,
        8 => 0.35355338,
        9 => 0.33333334,
        10 => 0.31622776,
        11 => 0.30151135,
        12 => 0.28867513,
        13 => 0.2773501,
        14 => 0.26726124,
        15 => 0.2581989,
        else => 0.25,
    };
}

fn routeEvents(
    self: *PolyMachine,
    ctx: *const machine.MachineCtx,
    routed: *[MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent,
    counts: *[MAX_VOICES]usize,
) void {
    if (ctx.note_in == null or ctx.note_in_count == 0) return;
    const events = ctx.note_in.?[0..ctx.note_in_count];
    for (events) |ev| {
        switch (ev.kind) {
            .note_on => {
                if (ev.velocity <= 0) {
                    routeNoteOff(self, ev, routed, counts);
                } else {
                    const vi = allocVoiceForNoteOn(self, ev);
                    self.clock +%= 1;
                    self.active[vi] = true;
                    self.note_id[vi] = ev.note_id;
                    self.channel[vi] = ev.channel;
                    self.pitch[vi] = ev.pitch;
                    self.age[vi] = self.clock;
                    self.tail_blocks[vi] = 0;
                    pushEvent(vi, ev, routed, counts);
                }
            },
            .note_off => routeNoteOff(self, ev, routed, counts),
            .reset => {
                for (0..self.voice_count) |vi| {
                    self.active[vi] = false;
                    pushEvent(vi, ev, routed, counts);
                }
            },
            else => {
                if (findVoice(self, ev)) |vi| {
                    pushEvent(vi, ev, routed, counts);
                } else {
                    for (0..self.voice_count) |vi| pushEvent(vi, ev, routed, counts);
                }
            },
        }
    }
}

fn routeNoteOff(
    self: *PolyMachine,
    ev: machine.NoteEvent,
    routed: *[MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent,
    counts: *[MAX_VOICES]usize,
) void {
    if (findVoiceForNoteOff(self, ev)) |vi| {
        self.tail_blocks[vi] = RELEASE_TAIL_BLOCKS;
        pushEvent(vi, ev, routed, counts);
        return;
    }
}

fn allocVoiceForNoteOn(self: *const PolyMachine, ev: machine.NoteEvent) usize {
    if (findCurrentVoice(self, ev)) |vi| return vi;
    if (findTailingVoice(self, ev)) |vi| return vi;
    return allocVoice(self);
}

fn allocVoice(self: *const PolyMachine) usize {
    for (0..self.voice_count) |vi| {
        if (!self.active[vi]) return vi;
    }
    for (0..self.voice_count) |vi| {
        if (self.tail_blocks[vi] > 0) return vi;
    }
    var oldest: usize = 0;
    var oldest_age = self.age[0];
    for (1..self.voice_count) |vi| {
        if (self.age[vi] < oldest_age) {
            oldest = vi;
            oldest_age = self.age[vi];
        }
    }
    return oldest;
}

fn findTailingVoice(self: *const PolyMachine, ev: machine.NoteEvent) ?usize {
    var best: ?usize = null;
    var best_tail: u16 = 0;
    for (0..self.voice_count) |vi| {
        if (!voiceMatches(self, vi, ev)) continue;
        if (self.tail_blocks[vi] == 0) continue;
        if (best == null or self.tail_blocks[vi] > best_tail) {
            best = vi;
            best_tail = self.tail_blocks[vi];
        }
    }
    return best;
}

fn findVoiceForNoteOff(self: *const PolyMachine, ev: machine.NoteEvent) ?usize {
    return findCurrentVoice(self, ev) orelse findVoice(self, ev);
}

fn findCurrentVoice(self: *const PolyMachine, ev: machine.NoteEvent) ?usize {
    var best: ?usize = null;
    var best_age: u64 = 0;
    for (0..self.voice_count) |vi| {
        if (!voiceMatches(self, vi, ev)) continue;
        if (self.tail_blocks[vi] != 0) continue;
        if (best == null or self.age[vi] > best_age) {
            best = vi;
            best_age = self.age[vi];
        }
    }
    return best;
}

fn findVoice(self: *const PolyMachine, ev: machine.NoteEvent) ?usize {
    for (0..self.voice_count) |vi| {
        if (voiceMatches(self, vi, ev)) return vi;
    }
    return null;
}

fn voiceMatches(self: *const PolyMachine, vi: usize, ev: machine.NoteEvent) bool {
    if (vi >= self.voice_count) return false;
    if (!self.active[vi]) return false;
    if (self.channel[vi] != ev.channel) return false;
    if (ev.note_id >= 0 and self.note_id[vi] == ev.note_id) return true;
    if (ev.note_id < 0 and @abs(self.pitch[vi] - ev.pitch) < 0.01) return true;
    return false;
}

fn traceEvents(self: *const PolyMachine, ctx: *const machine.MachineCtx) void {
    if (ctx.note_in == null or ctx.note_in_count == 0) return;
    const events = ctx.note_in.?[0..ctx.note_in_count];
    for (events) |ev| {
        std.debug.print(
            "  event {s} off={} pitch={d:.1} vel={d:.2} active=[",
            .{ noteKindName(ev.kind), ev.sample_offset, ev.pitch, ev.velocity },
        );
        for (0..self.voice_count) |vi| {
            if (vi != 0) std.debug.print(" ", .{});
            if (self.active[vi]) {
                std.debug.print("{d:.1}/{d}", .{ self.pitch[vi], self.tail_blocks[vi] });
            } else {
                std.debug.print("--", .{});
            }
        }
        std.debug.print("]\n", .{});
    }
}

fn noteKindName(kind: machine.NoteKind) []const u8 {
    return switch (kind) {
        .note_on => "on",
        .note_off => "off",
        .note_hold => "hold",
        .pressure => "pressure",
        .slide => "slide",
        .glide => "glide",
        .reset => "reset",
        .cc => "cc",
        .program_change => "program",
    };
}

fn pushEvent(
    vi: usize,
    ev: machine.NoteEvent,
    routed: *[MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent,
    counts: *[MAX_VOICES]usize,
) void {
    if (vi >= MAX_VOICES) return;
    const n = counts[vi];
    if (n >= MAX_EVENTS_PER_VOICE) return;
    routed[vi][n] = ev;
    counts[vi] = n + 1;
}

fn drawPanelImpl(state: *anyopaque, r: c.rl.Rectangle, m: widgets.Mouse) void {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    if (self.voice_count == 0) return;
    self.voices[0].draw_panel(self.voices[0].state, r, m);
    if (m.left_pressed or m.left_down or m.left_released) syncChildParams(self);
}

fn syncChildParams(self: *PolyMachine) void {
    if (self.voice_count <= 1) return;
    const master = self.voices[0];
    const sync = master.sync_params orelse return;
    var vi: usize = 1;
    while (vi < self.voice_count) : (vi += 1) {
        if (self.voices[vi].sync_params == null) continue;
        sync(self.voices[vi].state, master.state);
    }
}

fn syncParamsImpl(dst_state: *anyopaque, src_state: *anyopaque) void {
    const dst: *PolyMachine = @ptrCast(@alignCast(dst_state));
    const src: *PolyMachine = @ptrCast(@alignCast(src_state));
    if (dst.voice_count == 0 or src.voice_count == 0) return;
    const sync = dst.voices[0].sync_params orelse return;
    sync(dst.voices[0].state, src.voices[0].state);
    syncChildParams(dst);
}

fn presetCountImpl(state: *anyopaque) u8 {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    if (self.voice_count == 0) return 0;
    const f = self.voices[0].preset_count orelse return 0;
    return f(self.voices[0].state);
}

fn presetNameImpl(state: *anyopaque, index: u8) [*:0]const u8 {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    if (self.voice_count == 0) return "";
    const f = self.voices[0].preset_name orelse return "";
    return f(self.voices[0].state, index);
}

fn applyPresetImpl(state: *anyopaque, index: u8) void {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    if (self.voice_count == 0) return;
    const f = self.voices[0].apply_preset orelse return;
    f(self.voices[0].state, index);
    syncChildParams(self);
}

// Project persistence: dump voice 0's settings; apply each param to every
// voice so all voices stay identical (mirrors syncChildParams).
fn writeParamsJsonImpl(state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    if (self.voice_count == 0) {
        try out.appendSlice(alloc, "{}");
        return;
    }
    const f = self.voices[0].write_params_json orelse {
        try out.appendSlice(alloc, "{}");
        return;
    };
    try f(self.voices[0].state, out, alloc);
}

fn setParamImpl(state: *anyopaque, id: []const u8, value: f64) void {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    for (0..self.voice_count) |vi| {
        if (self.voices[vi].set_param) |f| f(self.voices[vi].state, id, value);
    }
}

fn resetImpl(state: *anyopaque) void {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    for (0..self.voice_count) |vi| {
        self.active[vi] = false;
        self.tail_blocks[vi] = 0;
        self.voices[vi].reset(self.voices[vi].state);
    }
}

fn deinitImpl(state: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *PolyMachine = @ptrCast(@alignCast(state));
    for (0..self.voice_count) |vi| {
        if (self.voices[vi].deinit) |deinit_fn| {
            deinit_fn(self.voices[vi].state, alloc);
        }
    }
    alloc.destroy(self);
}

const testing = std.testing;

const CountingVoice = struct {
    calls: u32 = 0,
    value: f32 = 0,
};

fn countingRender(state: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    _ = ctx;
    const v: *CountingVoice = @ptrCast(@alignCast(state));
    v.calls += 1;
    for (l, r) |*sl, *sr| {
        sl.* = v.value;
        sr.* = v.value;
    }
}

fn countingReset(state: *anyopaque) void {
    const v: *CountingVoice = @ptrCast(@alignCast(state));
    v.calls = 0;
}

fn countingDraw(_: *anyopaque, _: c.rl.Rectangle, _: widgets.Mouse) void {}

test "poly wrapper does not render inactive voices" {
    var states = [_]CountingVoice{
        .{ .value = 0.25 },
        .{ .value = 10.0 },
        .{ .value = 10.0 },
        .{ .value = 10.0 },
    };
    var poly = PolyMachine.init("test", 4);
    for (0..4) |i| {
        poly.voices[i] = .{
            .name = "count",
            .state = &states[i],
            .render = countingRender,
            .draw_panel = countingDraw,
            .reset = countingReset,
        };
    }

    var events = [_]machine.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_on,
        .channel = 0,
        .note_id = 1,
        .pitch = 60,
        .velocity = 1,
    }};
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48000;
    ctx.block_size = 16;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 16;
    var r = [_]f32{0} ** 16;
    renderImpl(&poly, &ctx, &l, &r);

    try testing.expectEqual(@as(u32, 1), states[0].calls);
    try testing.expectEqual(@as(u32, 0), states[1].calls);
    try testing.expectEqual(@as(u32, 0), states[2].calls);
    try testing.expectEqual(@as(u32, 0), states[3].calls);
    for (l, r) |sl, sr| {
        try testing.expectApproxEqAbs(@as(f32, 0.25), sl, 0.000001);
        try testing.expectApproxEqAbs(@as(f32, 0.25), sr, 0.000001);
    }
}

test "poly wrapper keeps release voice owned until tail expires" {
    var states = [_]CountingVoice{
        .{ .value = 0.25 },
        .{ .value = 0.5 },
    };
    var poly = PolyMachine.init("test", 2);
    for (0..2) |i| {
        poly.voices[i] = .{
            .name = "count",
            .state = &states[i],
            .render = countingRender,
            .draw_panel = countingDraw,
            .reset = countingReset,
        };
    }

    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48000;
    ctx.block_size = 16;
    var l = [_]f32{0} ** 16;
    var r = [_]f32{0} ** 16;

    var on = [_]machine.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_on,
        .channel = 0,
        .note_id = 11,
        .pitch = 60,
        .velocity = 1,
    }};
    ctx.note_in = @ptrCast(on[0..].ptr);
    ctx.note_in_count = on.len;
    renderImpl(&poly, &ctx, &l, &r);
    try testing.expect(poly.active[0]);

    var off = [_]machine.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_off,
        .channel = 0,
        .note_id = 11,
        .pitch = 60,
        .velocity = 0,
    }};
    ctx.note_in = @ptrCast(off[0..].ptr);
    ctx.note_in_count = off.len;
    renderImpl(&poly, &ctx, &l, &r);
    try testing.expect(poly.active[0]);
    try testing.expect(poly.tail_blocks[0] > 0);

    ctx.note_in = null;
    ctx.note_in_count = 0;
    var i: usize = 0;
    while (i < RELEASE_TAIL_BLOCKS) : (i += 1) {
        renderImpl(&poly, &ctx, &l, &r);
    }
    try testing.expect(!poly.active[0]);
}

test "poly wrapper retriggers same pitch on tailing voice" {
    var states = [_]CountingVoice{
        .{ .value = 0.25 },
        .{ .value = 0.5 },
    };
    var poly = PolyMachine.init("test", 2);
    for (0..2) |i| {
        poly.voices[i] = .{
            .name = "count",
            .state = &states[i],
            .render = countingRender,
            .draw_panel = countingDraw,
            .reset = countingReset,
        };
    }

    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48000;
    ctx.block_size = 16;
    var l = [_]f32{0} ** 16;
    var r = [_]f32{0} ** 16;

    var on = [_]machine.NoteEvent{.{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 1 }};
    ctx.note_in = @ptrCast(on[0..].ptr);
    ctx.note_in_count = on.len;
    renderImpl(&poly, &ctx, &l, &r);

    var off = [_]machine.NoteEvent{.{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 0 }};
    ctx.note_in = @ptrCast(off[0..].ptr);
    ctx.note_in_count = off.len;
    renderImpl(&poly, &ctx, &l, &r);
    try testing.expect(poly.tail_blocks[0] > 0);

    renderImpl(&poly, &ctx, &l, &r);
    const tail_after_extra_off = poly.tail_blocks[0];
    try testing.expect(tail_after_extra_off > 0);

    ctx.note_in = @ptrCast(on[0..].ptr);
    ctx.note_in_count = on.len;
    renderImpl(&poly, &ctx, &l, &r);

    try testing.expect(poly.active[0]);
    try testing.expectEqual(@as(u16, 0), poly.tail_blocks[0]);
    try testing.expect(!poly.active[1]);
}

test "poly wrapper note-off prefers current voice over same-pitch release tail" {
    var poly = PolyMachine.init("test", 2);
    poly.active[0] = true;
    poly.pitch[0] = 60;
    poly.channel[0] = 0;
    poly.note_id[0] = -1;
    poly.age[0] = 1;
    poly.tail_blocks[0] = 42;
    poly.active[1] = true;
    poly.pitch[1] = 60;
    poly.channel[1] = 0;
    poly.note_id[1] = -1;
    poly.age[1] = 2;
    poly.tail_blocks[1] = 0;

    var routed: [MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent = undefined;
    var counts: [MAX_VOICES]usize = [_]usize{0} ** MAX_VOICES;
    const ev = machine.NoteEvent{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 0 };
    routeNoteOff(&poly, ev, &routed, &counts);

    try testing.expectEqual(@as(usize, 0), counts[0]);
    try testing.expectEqual(@as(usize, 1), counts[1]);
    try testing.expectEqual(@as(u16, 42), poly.tail_blocks[0]);
    try testing.expectEqual(@as(u16, RELEASE_TAIL_BLOCKS), poly.tail_blocks[1]);
}

test "poly wrapper ignores unmatched note-off" {
    var poly = PolyMachine.init("test", 4);
    var routed: [MAX_VOICES][MAX_EVENTS_PER_VOICE]machine.NoteEvent = undefined;
    var counts: [MAX_VOICES]usize = [_]usize{0} ** MAX_VOICES;
    const ev = machine.NoteEvent{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 0 };
    routeNoteOff(&poly, ev, &routed, &counts);

    for (0..4) |vi| {
        try testing.expectEqual(@as(usize, 0), counts[vi]);
        try testing.expect(!poly.active[vi]);
        try testing.expectEqual(@as(u16, 0), poly.tail_blocks[vi]);
    }
}

test "poly wrapper applies overlap gain compensation" {
    var states = [_]CountingVoice{
        .{ .value = 1.0 },
        .{ .value = 1.0 },
    };
    var poly = PolyMachine.init("test", 2);
    for (0..2) |i| {
        poly.voices[i] = .{
            .name = "count",
            .state = &states[i],
            .render = countingRender,
            .draw_panel = countingDraw,
            .reset = countingReset,
        };
    }

    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 60, .velocity = 1 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 2, .pitch = 64, .velocity = 1 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48000;
    ctx.block_size = 16;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 16;
    var r = [_]f32{0} ** 16;
    renderImpl(&poly, &ctx, &l, &r);

    try testing.expectApproxEqAbs(@as(f32, 1.4142135), l[0], 0.00001);
    try testing.expectApproxEqAbs(@as(f32, 1.4142135), r[0], 0.00001);
}
