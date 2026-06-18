//! Algorithmic meter generators. Each produces a sequence of bar
//! numerators at a fixed denominator and materializes them into a
//! `MeterPoint` slice (consecutive equal bars collapse into one change
//! point, per the meter-map model in docs/07 §generators). The UI hands
//! the result to `MeterState.stage`, which adopts it at the next bar
//! boundary like any other edit.
//!
//! These run on the main thread, never the audio thread — plain Zig, no
//! allocation (caller-provided buffers), bounded and deterministic. The
//! plain-fy authoring path (a host `emit-meter-bar` hook) is a later
//! layer that produces the same `MeterPoint` slice.

const std = @import("std");
const meter = @import("meter.zig");
const MeterPoint = meter.MeterPoint;

/// Build meter points from a per-bar numerator list at a fixed
/// denominator, collapsing runs of equal meter into one point. `out` must
/// hold at least one point; the first point always starts at bar 0.
pub fn fromNumerators(out: []MeterPoint, nums: []const u8, den: u8) []const MeterPoint {
    if (out.len == 0) return out[0..0];
    var n: usize = 0;
    var prev: i32 = -1;
    for (nums, 0..) |num, bar_idx| {
        if (num < 1) continue;
        if (@as(i32, num) != prev) {
            if (n >= out.len) break;
            out[n] = .{ .start_bar = @intCast(bar_idx), .numerator = num, .denominator = den };
            n += 1;
            prev = num;
        }
    }
    if (n == 0) {
        out[0] = .{ .start_bar = 0, .numerator = 4, .denominator = 4 };
        return out[0..1];
    }
    out[0].start_bar = 0; // first point always governs from bar 0
    return out[0..n];
}

/// Fibonacci meter: the Fibonacci numbers in `[2, max_num]` cycled across
/// `bars` bars at `den` (e.g. max 13 → 2,3,5,8,13,2,3,…). Bounded; no
/// blow-up.
pub fn fibonacci(out: []MeterPoint, nums: []u8, bars: u32, den: u8, max_num: u8) []const MeterPoint {
    var fibs: [16]u8 = undefined;
    var fc: usize = 0;
    var a: u32 = 1;
    var b: u32 = 1;
    while (b <= max_num and fc < fibs.len) {
        if (b >= 2) {
            fibs[fc] = @intCast(b);
            fc += 1;
        }
        const t = a + b;
        a = b;
        b = t;
    }
    if (fc == 0) {
        fibs[0] = 2;
        fc = 1;
    }
    const count = @min(@as(usize, bars), nums.len);
    for (0..count) |i| nums[i] = fibs[i % fc];
    return fromNumerators(out, nums[0..count], den);
}

/// Euclidean meter: distribute `pulses` accents as evenly as possible over
/// `steps` denominator-units, spelling each inter-onset gap as its own bar
/// (E(3,8) → 3/8 + 3/8 + 2/8). Gives the additive feel via barlines.
pub fn euclidean(out: []MeterPoint, pulses: u8, steps: u8, den: u8) []const MeterPoint {
    if (pulses == 0 or steps == 0) return fromNumerators(out, &.{4}, 4);
    var nums: [64]u8 = undefined;
    var n: usize = 0;
    var i: u8 = 0;
    while (i < pulses and n < nums.len) : (i += 1) {
        const hi = (@as(u32, i + 1) * steps) / pulses;
        const lo = (@as(u32, i) * steps) / pulses;
        const g = hi - lo;
        if (g > 0) {
            nums[n] = @intCast(g);
            n += 1;
        }
    }
    return fromNumerators(out, nums[0..n], den);
}

/// Additive meter: a repeating numerator pattern (e.g. {2,2,3}) over
/// `repeats` cycles at `den`.
pub fn additive(out: []MeterPoint, nums: []u8, pattern: []const u8, den: u8, repeats: u32) []const MeterPoint {
    if (pattern.len == 0) return fromNumerators(out, &.{4}, 4);
    const total = @min(@as(usize, repeats) * pattern.len, nums.len);
    for (0..total) |i| nums[i] = pattern[i % pattern.len];
    return fromNumerators(out, nums[0..total], den);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "fromNumerators collapses equal runs and keeps bar indices" {
    var out: [meter.MAX_POINTS]MeterPoint = undefined;
    // 3,3,2 → points at bar 0 (3) and bar 2 (2).
    const pts = fromNumerators(&out, &.{ 3, 3, 2 }, 8);
    try testing.expectEqual(@as(usize, 2), pts.len);
    try testing.expectEqual(@as(u32, 0), pts[0].start_bar);
    try testing.expectEqual(@as(u8, 3), pts[0].numerator);
    try testing.expectEqual(@as(u32, 2), pts[1].start_bar);
    try testing.expectEqual(@as(u8, 2), pts[1].numerator);
}

test "fibonacci cycles the fib subset in range" {
    var out: [meter.MAX_POINTS]MeterPoint = undefined;
    var nums: [64]u8 = undefined;
    const pts = fibonacci(&out, &nums, 6, 8, 13);
    // 2,3,5,8,13,2 — all distinct from neighbours → 6 points.
    try testing.expectEqual(@as(usize, 6), pts.len);
    try testing.expectEqual(@as(u8, 2), pts[0].numerator);
    try testing.expectEqual(@as(u8, 3), pts[1].numerator);
    try testing.expectEqual(@as(u8, 5), pts[2].numerator);
    try testing.expectEqual(@as(u8, 8), pts[3].numerator);
    try testing.expectEqual(@as(u8, 13), pts[4].numerator);
    try testing.expectEqual(@as(u8, 2), pts[5].numerator);
    try testing.expectEqual(@as(u8, 8), pts[0].denominator);
}

test "euclidean 3/8 spells per-bar 2,3,3" {
    var out: [meter.MAX_POINTS]MeterPoint = undefined;
    // gaps: floor(8/3)=2, floor(16/3)-2=3, floor(24/3)-5=3 → 2,3,3.
    // The two trailing 3s collapse to one persisting point — lossless.
    const map = meter.MeterMap{ .points = euclidean(&out, 3, 8, 8) };
    try testing.expectEqual(@as(u8, 2), map.segmentForBar(0).numerator);
    try testing.expectEqual(@as(u8, 3), map.segmentForBar(1).numerator);
    try testing.expectEqual(@as(u8, 3), map.segmentForBar(2).numerator);
    try testing.expectEqual(@as(u8, 8), map.segmentForBar(0).denominator);
}

test "additive repeats a pattern" {
    var out: [meter.MAX_POINTS]MeterPoint = undefined;
    var nums: [64]u8 = undefined;
    // {5,7} ×3 → 5,7,5,7,5,7 → all alternate → 6 points.
    const pts = additive(&out, &nums, &.{ 5, 7 }, 8, 3);
    try testing.expectEqual(@as(usize, 6), pts.len);
    try testing.expectEqual(@as(u8, 5), pts[0].numerator);
    try testing.expectEqual(@as(u8, 7), pts[1].numerator);
    try testing.expectEqual(@as(u32, 5), pts[5].start_bar);
}
