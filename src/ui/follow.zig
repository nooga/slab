//! Playhead follow for the timeline views (arrangement, piano roll, audio
//! editor). While the transport plays, the view lets the playhead walk
//! across it until PIN of the width, then scrolls with it, so the motion
//! stays continuous. When the playhead leaves the view (a loop wrap, a
//! seek, starting play off-screen), the view glides over rather than
//! snapping and lands with the playhead at LAND.
//!
//! Scrolling by hand suspends following, until the playhead is back in the
//! lead-in part of the view, the transport seeks or wraps, or play stops.

const std = @import("std");

pub const PIN: f32 = 0.75;
pub const LAND: f32 = 0.25;
/// Glide time constant, seconds.
const GLIDE_TAU: f32 = 0.08;

pub const Follow = struct {
    last_scroll: ?f32 = null,
    last_ph: ?f32 = null,
    suspended: bool = false,
    gliding: bool = false,

    pub fn reset(self: *Follow) void {
        self.* = .{};
    }

    /// Run once a frame, after the view's own input and clamping. `ph` is
    /// the playhead in content pixels (0 = the view's scroll origin), null
    /// when the transport isn't playing here. `busy` holds the view still
    /// (a drag in progress) without suspending.
    pub fn step(self: *Follow, scroll_x: *f32, ph_opt: ?f32, view_w: f32, max_sx: f32, dt: f32, busy: bool) void {
        const ph = ph_opt orelse {
            self.reset();
            return;
        };
        defer {
            self.last_scroll = scroll_x.*;
            self.last_ph = ph;
        }
        if (self.last_scroll) |ls| {
            if (@abs(scroll_x.* - ls) > 0.5) {
                self.suspended = true;
                self.gliding = false;
            }
        }
        // Backwards, or further than a view in one frame: a seek or a wrap.
        if (self.last_ph) |lp| {
            if (ph < lp - 1 or ph - lp > view_w) self.suspended = false;
        }
        if (busy or view_w <= 0) return;

        const rel = ph - scroll_x.*;
        if (self.suspended) {
            if (rel < 0 or rel > view_w * PIN) return;
            self.suspended = false;
        }
        if (rel < 0 or rel > view_w) self.gliding = true;
        const hi = @max(0, max_sx);
        if (self.gliding) {
            const target = std.math.clamp(ph - view_w * LAND, 0, hi);
            const k = 1 - @exp(-@min(dt, 0.1) / GLIDE_TAU);
            scroll_x.* += (target - scroll_x.*) * k;
            if (@abs(target - scroll_x.*) < 1) {
                scroll_x.* = target;
                self.gliding = false;
            }
        } else if (rel > view_w * PIN) {
            scroll_x.* = std.math.clamp(ph - view_w * PIN, 0, hi);
        }
    }
};

const testing = std.testing;

test "the view pins the playhead once it reaches PIN, without jumping" {
    var f = Follow{};
    var sx: f32 = 0;
    var ph: f32 = 0;
    while (ph < 1000) : (ph += 5) {
        const before = sx;
        f.step(&sx, ph, 400, 10_000, 1.0 / 60.0, false);
        try testing.expect(sx - before <= 5.01);
        if (ph <= 300) try testing.expectEqual(@as(f32, 0), sx);
    }
    try testing.expectApproxEqAbs(@as(f32, 995 - 300), sx, 0.01);
}

test "a wrap glides back over several frames and lands at LAND" {
    var f = Follow{};
    var sx: f32 = 2000;
    f.step(&sx, 2200, 400, 10_000, 1.0 / 60.0, false);
    f.step(&sx, 500, 400, 10_000, 1.0 / 60.0, false);
    try testing.expect(sx < 2000 and sx > 500); // on its way, not snapped
    var i: usize = 0;
    while (i < 60) : (i += 1) f.step(&sx, 500, 400, 10_000, 1.0 / 60.0, false);
    try testing.expectApproxEqAbs(@as(f32, 400), sx, 0.01);
}

test "a hand scroll suspends until the playhead is back in the lead-in" {
    var f = Follow{};
    var sx: f32 = 0;
    f.step(&sx, 100, 400, 10_000, 1.0 / 60.0, false);
    sx = 1000; // the user looks ahead
    f.step(&sx, 105, 400, 10_000, 1.0 / 60.0, false);
    try testing.expectEqual(@as(f32, 1000), sx);
    var ph: f32 = 105;
    while (ph < 1100) : (ph += 5) f.step(&sx, ph, 400, 10_000, 1.0 / 60.0, false);
    try testing.expect(!f.suspended);
    try testing.expectEqual(@as(f32, 1000), sx);
    while (ph < 1400) : (ph += 5) f.step(&sx, ph, 400, 10_000, 1.0 / 60.0, false);
    try testing.expectApproxEqAbs(@as(f32, 1395 - 300), sx, 0.01);
}
