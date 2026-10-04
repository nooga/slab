//! Locators and sections (docs/28 §Locators and sections): positions on
//! the beat axis with names. Locators are points; sections run back to
//! back, each until the next starts, the last until the END marker. None
//! of it touches timing: a section's TEMPO and METER are the tempo and
//! meter maps' points at its start, edited through it. UI-thread data,
//! saved with the project.

const std = @import("std");
const Text = @import("export_settings.zig").Text;

pub const Name = Text(32);
pub const MAX_SECTIONS: usize = 128;
pub const MAX_LOCATORS: usize = 256;
/// Section colors index `style.track`.
pub const COLORS: u8 = 12;

pub const Section = struct {
    beat: f64,
    name: Name = .{},
    color: u8 = 0,
};

pub const Locator = struct {
    beat: f64,
    name: Name = .{},
};

pub const Kind = enum { section, locator };

pub const Markers = struct {
    sections: [MAX_SECTIONS]Section = undefined,
    section_n: usize = 0,
    locators: [MAX_LOCATORS]Locator = undefined,
    locator_n: usize = 0,
    /// Where the song ends: the last section's end and the Export sheet's
    /// PROJECT range. Null: the last clip's end.
    end: ?f64 = null,

    pub fn clear(self: *Markers) void {
        self.* = .{};
    }

    pub fn sectionSlice(self: *const Markers) []const Section {
        return self.sections[0..self.section_n];
    }

    pub fn locatorSlice(self: *const Markers) []const Locator {
        return self.locators[0..self.locator_n];
    }

    /// Add a section starting at `beat`, named "SECTION n" when `name` is
    /// empty, colored after the one before it. One already there is
    /// returned instead. Null when full.
    pub fn addSection(self: *Markers, beat_in: f64, name: []const u8) ?usize {
        const beat = @max(0, beat_in);
        for (self.sectionSlice(), 0..) |s, i| if (@abs(s.beat - beat) < 1e-6) return i;
        if (self.section_n >= MAX_SECTIONS) return null;
        var i = self.section_n;
        while (i > 0 and self.sections[i - 1].beat > beat) : (i -= 1) self.sections[i] = self.sections[i - 1];
        var s = Section{ .beat = beat, .color = if (i > 0) (self.sections[i - 1].color + 1) % COLORS else 4 };
        if (name.len > 0) s.name.set(name) else {
            var buf: [32]u8 = undefined;
            s.name.set(std.fmt.bufPrint(&buf, "SECTION {d}", .{self.section_n + 1}) catch "SECTION");
        }
        self.sections[i] = s;
        self.section_n += 1;
        return i;
    }

    /// Add a locator at `beat` ("CUE n" when unnamed). Null when full.
    pub fn addLocator(self: *Markers, beat_in: f64, name: []const u8) ?usize {
        const beat = @max(0, beat_in);
        if (self.locator_n >= MAX_LOCATORS) return null;
        var i = self.locator_n;
        while (i > 0 and self.locators[i - 1].beat > beat) : (i -= 1) self.locators[i] = self.locators[i - 1];
        var l = Locator{ .beat = beat };
        if (name.len > 0) l.name.set(name) else {
            var buf: [32]u8 = undefined;
            l.name.set(std.fmt.bufPrint(&buf, "CUE {d}", .{self.locator_n + 1}) catch "CUE");
        }
        self.locators[i] = l;
        self.locator_n += 1;
        return i;
    }

    pub fn remove(self: *Markers, kind: Kind, i: usize) void {
        switch (kind) {
            .section => if (i < self.section_n) {
                std.mem.copyForwards(Section, self.sections[i .. self.section_n - 1], self.sections[i + 1 .. self.section_n]);
                self.section_n -= 1;
            },
            .locator => if (i < self.locator_n) {
                std.mem.copyForwards(Locator, self.locators[i .. self.locator_n - 1], self.locators[i + 1 .. self.locator_n]);
                self.locator_n -= 1;
            },
        }
    }

    /// Move section `i` to `beat`, kept between its neighbors (sections
    /// never pass each other). Returns where it landed.
    pub fn moveSection(self: *Markers, i: usize, beat: f64) f64 {
        if (i >= self.section_n) return beat;
        var lo: f64 = 0;
        var hi: f64 = std.math.inf(f64);
        if (i > 0) lo = self.sections[i - 1].beat + 1e-3;
        if (i + 1 < self.section_n) hi = self.sections[i + 1].beat - 1e-3;
        if (self.end) |e| if (i + 1 == self.section_n) {
            hi = e - 1e-3;
        };
        const b = std.math.clamp(beat, lo, @max(lo, hi));
        self.sections[i].beat = b;
        return b;
    }

    /// Move locator `i` to `beat`, re-sorting; returns its new index.
    pub fn moveLocator(self: *Markers, i: usize, beat: f64) usize {
        if (i >= self.locator_n) return i;
        var l = self.locators[i];
        l.beat = @max(0, beat);
        self.remove(.locator, i);
        var j = self.locator_n;
        while (j > 0 and self.locators[j - 1].beat > l.beat) : (j -= 1) self.locators[j] = self.locators[j - 1];
        self.locators[j] = l;
        self.locator_n += 1;
        return j;
    }

    /// The section playing at `beat`, if any.
    pub fn sectionAt(self: *const Markers, beat: f64, fallback_end: f64) ?usize {
        var k = self.section_n;
        while (k > 0) {
            k -= 1;
            if (self.sections[k].beat <= beat) return if (beat < self.sectionEnd(k, fallback_end)) k else null;
        }
        return null;
    }

    /// Where section `i` ends: the next section, else END, else
    /// `fallback_end` (the song's last clip), never before it starts.
    pub fn sectionEnd(self: *const Markers, i: usize, fallback_end: f64) f64 {
        const start = self.sections[i].beat;
        if (i + 1 < self.section_n) return self.sections[i + 1].beat;
        const e = self.end orelse fallback_end;
        return if (e > start) e else start + 4;
    }

    /// The nearest marker (section start, locator, END) after `beat`.
    pub fn next(self: *const Markers, beat: f64) ?f64 {
        var best: ?f64 = null;
        const eps = 1e-6;
        for (self.sectionSlice()) |s| if (s.beat > beat + eps and (best == null or s.beat < best.?)) {
            best = s.beat;
        };
        for (self.locatorSlice()) |l| if (l.beat > beat + eps and (best == null or l.beat < best.?)) {
            best = l.beat;
        };
        if (self.end) |e| if (e > beat + eps and (best == null or e < best.?)) {
            best = e;
        };
        return best;
    }

    /// The nearest marker before `beat`, else the song's start.
    pub fn prev(self: *const Markers, beat: f64) f64 {
        var best: f64 = 0;
        const eps = 1e-6;
        for (self.sectionSlice()) |s| if (s.beat < beat - eps and s.beat > best) {
            best = s.beat;
        };
        for (self.locatorSlice()) |l| if (l.beat < beat - eps and l.beat > best) {
            best = l.beat;
        };
        if (self.end) |e| if (e < beat - eps and e > best) {
            best = e;
        };
        return best;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "sections sort, name and color themselves, and end at the next" {
    var m: Markers = .{};
    _ = m.addSection(32, "VERSE");
    _ = m.addSection(0, "");
    try testing.expectEqual(@as(usize, 2), m.section_n);
    try testing.expectEqualStrings("SECTION 2", m.sections[0].name.get());
    try testing.expectEqualStrings("VERSE", m.sections[1].name.get());
    // Adding where one starts returns it.
    try testing.expectEqual(@as(?usize, 1), m.addSection(32, "X"));
    try testing.expectEqual(@as(f64, 32), m.sectionEnd(0, 100));
    try testing.expectEqual(@as(f64, 100), m.sectionEnd(1, 100));
    m.end = 64;
    try testing.expectEqual(@as(f64, 64), m.sectionEnd(1, 100));
    try testing.expectEqual(@as(?usize, 1), m.sectionAt(40, 100));
    try testing.expectEqual(@as(?usize, null), m.sectionAt(70, 100));
}

test "sections move between their neighbors; locators re-sort" {
    var m: Markers = .{};
    _ = m.addSection(0, "A");
    _ = m.addSection(16, "B");
    _ = m.addSection(32, "C");
    try testing.expectApproxEqAbs(@as(f64, 32 - 1e-3), m.moveSection(1, 40), 1e-9);
    try testing.expectEqual(@as(f64, 24), m.moveSection(1, 24));
    _ = m.addLocator(8, "");
    _ = m.addLocator(20, "DROP");
    try testing.expectEqual(@as(usize, 1), m.moveLocator(0, 30));
    try testing.expectEqualStrings("DROP", m.locators[0].name.get());
    m.remove(.section, 0);
    try testing.expectEqualStrings("B", m.sections[0].name.get());
}

test "next and prev step through every kind of marker" {
    var m: Markers = .{};
    _ = m.addSection(16, "");
    _ = m.addLocator(8, "");
    m.end = 48;
    try testing.expectEqual(@as(?f64, 8), m.next(0));
    try testing.expectEqual(@as(?f64, 16), m.next(8));
    try testing.expectEqual(@as(?f64, 48), m.next(16));
    try testing.expectEqual(@as(?f64, null), m.next(48));
    try testing.expectEqual(@as(f64, 16), m.prev(20));
    try testing.expectEqual(@as(f64, 0), m.prev(8));
}
