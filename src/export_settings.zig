//! Export settings (docs/27 §Export): everything the Export sheet sets,
//! saved with the project so ⌘R repeats the last export, and the presets
//! that fill most of it in one pick. A `Recipe` is what a preset holds:
//! what's written, the range, format, level and names. `Settings` adds
//! what belongs to one project: the folder, the tags and the preset's
//! name. Each track's own stem choices live on the track (`StemPlan`).

const std = @import("std");
const export_mod = @import("export.zig");
const exporter = @import("exporter.zig");
const engine_mod = @import("engine.zig");
const track_mod = @import("track.zig");
const routing = @import("routing.zig");
const storage = @import("storage.zig");

pub const Range = enum(u8) { project = 0, loop = 1, selection = 2 };
/// Where a stem's signal is taken: the instrument, after the effects,
/// after the fader.
pub const Signal = enum(u8) { instr = 0, fx = 1, fader = 2 };
pub const Exists = enum(u8) { number = 0, replace = 1 };

pub const RATES = [_]u32{ 44_100, 48_000, 88_200, 96_000 };
pub const AAC_KBPS = [_]u16{ 128, 192, 256, 320 };
pub const LUFS_TARGETS = [_]f64{ -9, -14, -16, -23 };
pub const PEAK_TARGETS = [_]f64{ -0.1, -1, -3 };
pub const CEILINGS = [_]f64{ -1, -2, -0.3 };
/// The longest tail: AUTO renders up to this and stops at silence.
pub const TAIL_MAX: f32 = 30;

/// Bounded text, zero-filled past its length so `std.meta.eql` compares
/// two by their contents.
pub fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = @splat(0),
        len: u8 = 0,

        const Self = @This();

        pub fn init(s: []const u8) Self {
            var t = Self{};
            t.set(s);
            return t;
        }

        pub fn get(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *Self, s: []const u8) void {
            const k = @min(s.len, n);
            self.buf = @splat(0);
            @memcpy(self.buf[0..k], s[0..k]);
            self.len = @intCast(k);
        }
    };
}

pub const Name = Text(32);
pub const Field = Text(120);

pub const Recipe = struct {
    // What
    mix: bool = true,
    mix_channels: exporter.Channels = .stereo,
    stems: bool = false,
    stem_signal: Signal = .fader,
    stem_channels: exporter.Channels = .stereo,
    // Range
    range: Range = .project,
    tail_auto: bool = true,
    tail_sec: f32 = 2,
    wrap: bool = false,
    // Format
    container: export_mod.Container = .wav,
    bits: export_mod.Bits = .pcm24,
    /// An index into RATES.
    rate: u8 = 1,
    flac_level: u8 = 5,
    /// An index into AAC_KBPS.
    aac_kbps: u8 = 2,
    dither: bool = true,
    // Level
    normalize: exporter.Normalize = .off,
    /// Indexes into LUFS_TARGETS, PEAK_TARGETS and CEILINGS.
    lufs_target: u8 = 1,
    peak_target: u8 = 1,
    ceiling: u8 = 0,
    stem_gain: exporter.StemGain = .mix,
    // Names
    mix_name: Field = Field.init("{project}"),
    stem_name: Field = Field.init("{project} stems/{nn} {track}"),
    exists: Exists = .number,

    pub fn format(r: *const Recipe) export_mod.Format {
        return .{
            .container = r.container,
            .bits = if (r.container.intOnly() and r.bits == .float32) .pcm24 else r.bits,
            .sample_rate = RATES[@min(r.rate, RATES.len - 1)],
            .dither = r.dither,
            .flac_level = @intCast(@min(r.flac_level, 8)),
            .aac_kbps = AAC_KBPS[@min(r.aac_kbps, AAC_KBPS.len - 1)],
        };
    }

    pub fn target(r: *const Recipe) f64 {
        return switch (r.normalize) {
            .peak => PEAK_TARGETS[@min(r.peak_target, PEAK_TARGETS.len - 1)],
            else => LUFS_TARGETS[@min(r.lufs_target, LUFS_TARGETS.len - 1)],
        };
    }

    pub fn ceilingDb(r: *const Recipe) f64 {
        return CEILINGS[@min(r.ceiling, CEILINGS.len - 1)];
    }

    pub fn eql(a: *const Recipe, b: *const Recipe) bool {
        return std.meta.eql(a.*, b.*);
    }
};

pub const Settings = struct {
    recipe: Recipe = .{},
    /// The preset it started from; it reads CUSTOM once edited.
    preset: Name = Name.init("MASTER"),
    /// `~` is the home folder; the name fields fill in.
    folder: Field = Field.init("~/Music/Slab/Exports/{project}"),
    title: Field = .{},
    artist: Field = .{},
    album: Field = .{},
    year: Field = .{},
    /// Show the files in Finder when done.
    reveal: bool = true,
};

// ── Presets ──────────────────────────────────────────────────────────

pub const Preset = struct {
    name: []const u8,
    /// What it's for, under the name in the menu.
    about: []const u8,
    recipe: Recipe,
};

pub const BUILTIN = [_]Preset{
    .{ .name = "MASTER", .about = "WAV 24/48, as mixed", .recipe = .{} },
    .{ .name = "STREAMING", .about = "FLAC 24/48 at -14 LUFS", .recipe = .{ .container = .flac, .normalize = .loudness, .lufs_target = 1 } },
    .{ .name = "CD", .about = "WAV 16/44.1, dithered", .recipe = .{ .bits = .pcm16, .rate = 0 } },
    .{ .name = "STEMS FOR MIXING", .about = "mix and stems, WAV 24/48", .recipe = .{ .stems = true, .stem_channels = .auto } },
    .{ .name = "LOOP", .about = "the loop, its tail wrapped", .recipe = .{ .range = .loop, .wrap = true, .mix_name = Field.init("{project} loop") } },
    .{ .name = "PREVIEW", .about = "AAC 256 at -14 LUFS", .recipe = .{ .container = .aac, .normalize = .loudness, .lufs_target = 1, .mix_name = Field.init("{project} {date}") } },
    .{ .name = "BROADCAST", .about = "WAV 24/48 at -23 LUFS", .recipe = .{ .normalize = .loudness, .lufs_target = 3 } },
    .{ .name = "ARCHIVE", .about = "FLAC mix and stems, level 8", .recipe = .{ .container = .flac, .flac_level = 8, .stems = true, .stem_channels = .auto } },
};

/// User presets, from export-presets.json beside settings.json.
pub const UserPresets = struct {
    names: [MAX]Name = undefined,
    recipes: [MAX]Recipe = undefined,
    count: usize = 0,

    pub const MAX = 24;

    pub fn find(self: *const UserPresets, name: []const u8) ?usize {
        for (self.names[0..self.count], 0..) |*n, i| if (std.ascii.eqlIgnoreCase(n.get(), name)) return i;
        return null;
    }

    /// Add or replace `name`.
    pub fn put(self: *UserPresets, name: []const u8, r: Recipe) void {
        const i = self.find(name) orelse blk: {
            if (self.count == MAX) return;
            self.count += 1;
            break :blk self.count - 1;
        };
        self.names[i] = Name.init(name);
        self.recipes[i] = r;
    }

    pub fn remove(self: *UserPresets, i: usize) void {
        if (i >= self.count) return;
        for (i..self.count - 1) |k| {
            self.names[k] = self.names[k + 1];
            self.recipes[k] = self.recipes[k + 1];
        }
        self.count -= 1;
    }

    pub fn path(buf: []u8) []const u8 {
        var sb: [storage.MAX_PATH]u8 = undefined;
        const settings = storage.settingsPath(&sb);
        const dir = std.fs.path.dirname(settings) orelse ".";
        return std.fmt.bufPrint(buf, "{s}/export-presets.json", .{dir}) catch "";
    }

    pub fn load(self: *UserPresets, alloc: std.mem.Allocator) void {
        self.count = 0;
        var pb: [storage.MAX_PATH]u8 = undefined;
        const bytes = @import("document.zig").readFile(alloc, path(&pb)) catch return;
        defer alloc.free(bytes);
        self.parse(alloc, bytes);
    }

    pub fn parse(self: *UserPresets, alloc: std.mem.Allocator, bytes: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |v| {
            if (v != .object) continue;
            const name = v.object.get("name") orelse continue;
            if (name != .string) continue;
            var r = Recipe{};
            readFields(&r, v.object);
            self.put(name.string, r);
        }
    }

    pub fn save(self: *const UserPresets, alloc: std.mem.Allocator) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try self.write(alloc, &out);
        var pb: [storage.MAX_PATH]u8 = undefined;
        const p = path(&pb);
        if (std.fs.path.dirname(p)) |d| storage.makeParents(d);
        try @import("document.zig").writeFile(alloc, p, out.items);
    }

    pub fn write(self: *const UserPresets, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.append(alloc, '[');
        for (0..self.count) |i| {
            if (i > 0) try out.appendSlice(alloc, ",\n");
            try out.appendSlice(alloc, "{\"name\":");
            try jsonString(alloc, out, self.names[i].get());
            try writeFields(alloc, out, &self.recipes[i]);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]\n");
    }
};

// ── Stems ────────────────────────────────────────────────────────────

pub fn tapOf(s: Signal) engine_mod.CaptureTap {
    return switch (s) {
        .instr => .input,
        .fx => .pre,
        .fader => .post,
    };
}

/// Whether track `ti` writes a stem: its own choice, or by default every
/// track that plays (audible, with clips), and no bus.
pub fn stemOn(tracks: []track_mod.Track, ti: usize, auto_set: u32) bool {
    return tracks[ti].stem.on orelse (auto_set & routing.bit(@intCast(ti)) != 0);
}

/// The default rule's tracks (`stemOn`): exporter.stemSet's tracks.
pub fn autoSet(tracks: []track_mod.Track) u32 {
    return exporter.stemSet(tracks, .tracks);
}

pub fn signalOf(r: *const Recipe, t: *const track_mod.Track) Signal {
    return if (t.stem.signal == 0) r.stem_signal else @enumFromInt(@min(t.stem.signal - 1, 2));
}

pub fn channelsOf(r: *const Recipe, t: *const track_mod.Track) exporter.Channels {
    return if (t.stem.channels == 0) r.stem_channels else @enumFromInt(@min(t.stem.channels - 1, 2));
}

/// The exporter's per-track stems for these settings.
pub fn stems(r: *const Recipe, tracks: []track_mod.Track) [routing.MAX_TRACKS]exporter.Stem {
    var out: [routing.MAX_TRACKS]exporter.Stem = @splat(.{});
    if (!r.stems) return out;
    const auto = autoSet(tracks);
    for (tracks, 0..) |*t, ti| if (stemOn(tracks, ti, auto)) {
        out[ti] = .{ .tap = tapOf(signalOf(r, t)), .channels = channelsOf(r, t) };
    };
    return out;
}

pub fn stemCount(r: *const Recipe, tracks: []track_mod.Track) usize {
    var n: usize = 0;
    for (stems(r, tracks)[0..tracks.len]) |st| n += @intFromBool(st.tap != .none);
    return n;
}

/// `folder` with `~` expanded and the name fields filled in.
pub fn resolveFolder(buf: []u8, folder: []const u8, f: export_mod.NameFields) []const u8 {
    var tb: [storage.MAX_PATH]u8 = undefined;
    // fillName drops a leading `/`: fill what follows the root.
    var rest = folder;
    var root: []const u8 = "";
    var hb: [storage.MAX_PATH]u8 = undefined;
    if (std.mem.startsWith(u8, folder, "~")) {
        root = std.fmt.bufPrint(&hb, "{s}", .{std.mem.sliceTo(std.c.getenv("HOME") orelse "", 0)}) catch "";
        rest = folder[1..];
    } else if (std.mem.startsWith(u8, folder, "/")) {
        root = "";
    } else {
        root = ".";
    }
    const filled = export_mod.fillName(&tb, rest, f);
    const out = std.fmt.bufPrint(buf, "{s}/{s}", .{ root, filled }) catch return "";
    return if (out.len > 1 and out[out.len - 1] == '/') out[0 .. out.len - 1] else out;
}

// ── JSON ─────────────────────────────────────────────────────────────

/// `"export":{...}` for the project file.
pub fn append(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: *const Settings) !void {
    try out.appendSlice(alloc, ",\"export\":{\"preset\":");
    try jsonString(alloc, out, s.preset.get());
    try writeFields(alloc, out, &s.recipe);
    inline for (.{ "folder", "title", "artist", "album", "year" }) |k| {
        try out.appendSlice(alloc, ",\"" ++ k ++ "\":");
        try jsonString(alloc, out, @field(s, k).get());
    }
    try out.appendSlice(alloc, if (s.reveal) ",\"reveal\":true}" else ",\"reveal\":false}");
}

/// Read what the project's `"export"` object holds; the rest stays as is.
pub fn read(s: *Settings, o: std.json.ObjectMap) void {
    readFields(&s.recipe, o);
    if (o.get("preset")) |v| if (v == .string) s.preset.set(v.string);
    inline for (.{ "folder", "title", "artist", "album", "year" }) |k| {
        if (o.get(k)) |v| if (v == .string) @field(s, k).set(v.string);
    }
    if (o.get("reveal")) |v| if (v == .bool) {
        s.reveal = v.bool;
    };
}

/// The recipe's fields, each as `,"name":value`.
fn writeFields(alloc: std.mem.Allocator, out: *std.ArrayList(u8), r: *const Recipe) !void {
    inline for (std.meta.fields(Recipe)) |fd| {
        try out.appendSlice(alloc, ",\"" ++ fd.name ++ "\":");
        const v = @field(r.*, fd.name);
        switch (@typeInfo(fd.type)) {
            .bool => try out.appendSlice(alloc, if (v) "true" else "false"),
            .@"enum" => try jsonString(alloc, out, @tagName(v)),
            .int, .float => {
                var b: [32]u8 = undefined;
                try out.appendSlice(alloc, std.fmt.bufPrint(&b, "{d}", .{v}) catch "0");
            },
            .@"struct" => try jsonString(alloc, out, v.get()),
            else => @compileError("export setting " ++ fd.name),
        }
    }
}

fn readFields(r: *Recipe, o: std.json.ObjectMap) void {
    inline for (std.meta.fields(Recipe)) |fd| if (o.get(fd.name)) |v| {
        const p = &@field(r.*, fd.name);
        switch (@typeInfo(fd.type)) {
            .bool => if (v == .bool) {
                p.* = v.bool;
            },
            .@"enum" => if (v == .string) {
                if (std.meta.stringToEnum(fd.type, v.string)) |e| p.* = e;
            },
            .int => {
                const x: f64 = switch (v) {
                    .integer => |i| @floatFromInt(i),
                    .float => |f| f,
                    else => -1,
                };
                if (x >= 0 and x <= 255) p.* = @intFromFloat(x);
            },
            .float => switch (v) {
                .integer => |i| p.* = @floatFromInt(i),
                .float => |f| p.* = @floatCast(f),
                else => {},
            },
            .@"struct" => if (v == .string) p.set(v.string),
            else => {},
        }
    };
}

fn jsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        0...0x1f => {
            var b: [8]u8 = undefined;
            try out.appendSlice(alloc, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{ch}) catch "");
        },
        else => try out.append(alloc, ch),
    };
    try out.append(alloc, '"');
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "settings round-trip through JSON" {
    const alloc = testing.allocator;
    var s = Settings{};
    s.recipe = BUILTIN[3].recipe;
    s.recipe.container = .flac;
    s.recipe.tail_sec = 4.5;
    s.recipe.stem_name.set("x/{track} \"q\"");
    s.artist.set("nooga");
    s.preset.set("CUSTOM");
    s.reveal = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.append(alloc, '{');
    try out.appendSlice(alloc, "\"x\":0");
    try append(alloc, &out, &s);
    try out.append(alloc, '}');
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.items, .{});
    defer parsed.deinit();
    var back = Settings{};
    read(&back, parsed.value.object.get("export").?.object);
    try testing.expect(back.recipe.eql(&s.recipe));
    try testing.expectEqualStrings("nooga", back.artist.get());
    try testing.expectEqualStrings("CUSTOM", back.preset.get());
    try testing.expect(!back.reveal);
}

test "user presets: put replaces by name, JSON round-trips" {
    const alloc = testing.allocator;
    var u = UserPresets{};
    u.put("Club", BUILTIN[1].recipe);
    u.put("club", BUILTIN[2].recipe);
    try testing.expectEqual(@as(usize, 1), u.count);
    try testing.expect(u.recipes[0].eql(&BUILTIN[2].recipe));
    u.put("Demo", BUILTIN[5].recipe);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try u.write(alloc, &out);
    var v = UserPresets{};
    v.parse(alloc, out.items);
    try testing.expectEqual(@as(usize, 2), v.count);
    try testing.expectEqualStrings("Demo", v.names[1].get());
    try testing.expect(v.recipes[1].eql(&BUILTIN[5].recipe));
    v.remove(0);
    try testing.expectEqualStrings("Demo", v.names[0].get());
}

test "resolveFolder expands ~ and fills the fields" {
    var b: [storage.MAX_PATH]u8 = undefined;
    const home = std.mem.sliceTo(std.c.getenv("HOME") orelse "", 0);
    var want: [storage.MAX_PATH]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}/Music/Song", .{home}), resolveFolder(&b, "~/Music/{project}/", .{ .project = "Song" }));
    try testing.expectEqualStrings("/tmp/x", resolveFolder(&b, "/tmp/x", .{}));
}
