//! Keymaps for the sampler: which sample plays for which key and velocity.
//!
//! A keymap loads from one of three sources:
//!   - a single WAV: one zone over the whole keyboard, root and loop from
//!     its `smpl` chunk when it has one;
//!   - an SFZ file: <global>/<master>/<group>/<region> opcodes (the subset
//!     below), sample paths relative to the file and its default_path;
//!   - a folder of WAVs: note names in the file names (Piano_C4.wav,
//!     "Str A#3 v2.wav") make a melodic multisample, each sample covering
//!     the keys half way to its neighbours, several at one root splitting
//!     the velocity range; a folder without note names is a drum kit, one
//!     one-shot per key, placed by General MIDI keywords (kick 36, snare
//!     38, closed hat 42, …) with the hats in one choke group.
//!
//! Every sample lands in one f64 pool with GUARD zeros around each, and a
//! zone addresses its sample by offset, so the fy voice reads everything
//! through one pointer (`Zone` in kernels/06-voices/sampler.fy mirrors the
//! struct below). Loading runs on the UI thread; the machine swaps the
//! finished keymap in under the callback fence.

const std = @import("std");
const wav = @import("wav.zig");

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
const O_RDONLY: c_int = 0;

const DIR = opaque {};
extern fn opendir(path: [*:0]const u8) ?*DIR;
extern fn readdir(dir: *DIR) ?*Dirent;
extern fn closedir(dir: *DIR) c_int;
// macOS arm64 dirent (see presets.zig).
const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};
const DT_DIR: u8 = 4;

pub const MAX_ZONES = 256;
/// Zero samples before and after each sample in the pool, so a 4-point
/// interpolator at either end reads silence, never a neighbour.
pub const GUARD = 4;
const MAX_FILES = 256;
const MAX_SFZ_BYTES = 1 << 20;

pub const LOOP_NONE: f64 = 0;
pub const LOOP_ON: f64 = 1;
/// Plays to the end whatever note-off does (drums).
pub const LOOP_ONESHOT: f64 = 2;

/// One zone: ZONE_CELLS f64 cells, mirrored by `Zone` in kernels/06-voices/sampler.fy.
pub const Zone = extern struct {
    start: f64 = 0, // the sample's first cell in the pool
    len: f64 = 0, // samples
    sr: f64 = 48_000, // the sample's native rate
    lo_key: f64 = 0,
    hi_key: f64 = 127,
    lo_vel: f64 = 0, // 0..127
    hi_vel: f64 = 127,
    root: f64 = -1, // MIDI note it sounds at unshifted; < 0: the machine's ROOT
    gain: f64 = 1,
    loop_mode: f64 = LOOP_NONE,
    loop_start: f64 = 0, // samples from start
    loop_end: f64 = 0, // exclusive; <= loop_start means no loop points
    group: f64 = 0, // choke: a note here silences zones with off_by == group
    off_by: f64 = 0,
    pan: f64 = 0, // -1..1
    // round robin: the zone plays on the rr_pos-th of every rr_len notes
    // on its key (SFZ seq_length / seq_position, rr_pos from 0)
    rr_len: f64 = 1,
    rr_pos: f64 = 0,
    // 1: a release zone, played at note-off (SFZ trigger=release), rt_decay
    // dB quieter for each second the note was held
    trigger: f64 = 0,
    rt_decay: f64 = 0,
};

pub const ZONE_CELLS = 19;
comptime {
    std.debug.assert(@sizeOf(Zone) == ZONE_CELLS * 8);
}

/// Per-zone adjustments on top of the machine's knobs, mirrored by
/// `ZoneEdits` in kernels/06-voices/sampler.fy. The host owns it and
/// injects a pointer; the voice reads its zone's cells at note-on and
/// writes `hit` / `last` for the panel.
pub const ZoneEdits = extern struct {
    level: [MAX_ZONES]f64 = [_]f64{0} ** MAX_ZONES, // dB
    tune: [MAX_ZONES]f64 = [_]f64{0} ** MAX_ZONES, // semitones
    decay: [MAX_ZONES]f64 = [_]f64{0} ** MAX_ZONES, // seconds to -60 dB; 0 = off
    tone: [MAX_ZONES]f64 = [_]f64{0} ** MAX_ZONES, // filter offset, octaves
    cut: [MAX_ZONES]f64 = [_]f64{0} ** MAX_ZONES, // choke: 0 the pack's, 1 none, n+1 group n
    hit: [MAX_ZONES]f64 = [_]f64{0} ** MAX_ZONES, // sequence number of the zone's newest note
    last: f64 = -1, // the zone of the newest note
};

pub const NAME_MAX = 31;
pub const Name = struct {
    buf: [NAME_MAX]u8 = undefined,
    len: u8 = 0,
    pub fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn set(text: []const u8) Name {
        var n = Name{};
        const k = @min(text.len, NAME_MAX);
        @memcpy(n.buf[0..k], text[0..k]);
        n.len = @intCast(k);
        return n;
    }
};

/// What fills a table's unused slots: a key range nothing falls in.
pub const unused_zone = Zone{ .lo_key = 1000, .hi_key = -1 };

pub const Keymap = struct {
    pool: []f64 = &.{},
    /// Always MAX_ZONES long (the voice's scan reads every slot); the
    /// first `count` are real, the rest `unused_zone`.
    zones: []Zone = &.{},
    count: usize = 0,
    /// Each zone's name: its sample's file stem.
    names: []Name = &.{},

    pub fn deinit(self: *Keymap, alloc: std.mem.Allocator) void {
        if (self.pool.len > 0) alloc.free(self.pool);
        if (self.zones.len > 0) alloc.free(self.zones);
        if (self.names.len > 0) alloc.free(self.names);
        self.* = .{};
    }

    /// Whether every zone sits on one key: a kit, whose keys get names.
    pub fn isKit(self: *const Keymap) bool {
        if (self.count == 0) return false;
        for (self.zones[0..self.count]) |z| if (z.lo_key != z.hi_key) return false;
        return true;
    }

    /// The zone's samples, without guards.
    pub fn samples(self: *const Keymap, z: Zone) []const f64 {
        const s: usize = @intFromFloat(z.start);
        const n: usize = @intFromFloat(z.len);
        return self.pool[s .. s + n];
    }
};

pub const Error = error{
    OpenFailed,
    ReadFailed,
    NoZones,
    TooManyZones,
    PathTooLong,
    OutOfMemory,
    BadVoiceFile,
} || wav.Error;

/// Load a keymap from a .wav, a .sfz or a folder.
pub fn load(alloc: std.mem.Allocator, path: []const u8) Error!Keymap {
    var b = Builder.init(alloc);
    defer b.deinit();
    if (endsWithIgnoreCase(path, ".sfz")) {
        try loadSfz(&b, path);
    } else if (isDir(path)) {
        try loadFolder(&b, path);
    } else {
        const si = try b.sample(path);
        const s = b.files.items[si].s;
        var z = Zone{ .root = s.root_key };
        if (s.loop_end > s.loop_start) {
            z.loop_mode = LOOP_ON;
            z.loop_start = @floatFromInt(s.loop_start);
            z.loop_end = @floatFromInt(s.loop_end);
        }
        try b.zone(si, z);
    }
    return b.finish();
}

// ── the sample library ─────────────────────────────────────────────────

/// Presets and projects name library samples "lib:<path>", relative to the
/// library root: $SLAB_LIBRARY, else ~/Music/Slab/Library. A preset that
/// ships with Slab then finds its samples on any machine that fetched the
/// library (tools/library/vcsl.py).
pub const LIB_PREFIX = "lib:";

pub fn libraryRoot(buf: []u8) []const u8 {
    if (std.c.getenv("SLAB_LIBRARY")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0 and s.len <= buf.len) {
            @memcpy(buf[0..s.len], s);
            return std.mem.trimEnd(u8, buf[0..s.len], "/");
        }
    }
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    return std.fmt.bufPrint(buf, "{s}/Music/Slab/Library", .{home}) catch "";
}

/// A "lib:" path as a file path; anything else unchanged.
pub fn resolvePath(buf: []u8, path: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, path, LIB_PREFIX)) return path;
    var rb: [512]u8 = undefined;
    const root = libraryRoot(&rb);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, path[LIB_PREFIX.len..] }) catch path;
}

/// A file under the library root as a "lib:" path; anything else unchanged.
pub fn portablePath(buf: []u8, path: []const u8) []const u8 {
    var rb: [512]u8 = undefined;
    const root = libraryRoot(&rb);
    if (root.len == 0 or path.len <= root.len + 1) return path;
    if (!std.mem.startsWith(u8, path, root) or path[root.len] != '/') return path;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ LIB_PREFIX, path[root.len + 1 ..] }) catch path;
}

test "library paths round-trip through lib:" {
    var rb: [512]u8 = undefined;
    const root = libraryRoot(&rb);
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    const full = resolvePath(&a, "lib:vcsl/Marimba/marimba.sfz");
    try std.testing.expect(std.mem.startsWith(u8, full, root));
    try std.testing.expectEqualStrings("lib:vcsl/Marimba/marimba.sfz", portablePath(&b, full));
    try std.testing.expectEqualStrings("/tmp/x.wav", resolvePath(&a, "/tmp/x.wav"));
    try std.testing.expectEqualStrings("/tmp/x.wav", portablePath(&b, "/tmp/x.wav"));
}

// ── builder: samples loaded once, zones referring to them ───────────────

const File = struct { path: []u8, s: wav.Sample };

const Builder = struct {
    alloc: std.mem.Allocator,
    files: std.ArrayList(File) = .empty,
    zones: std.ArrayList(Zone) = .empty,
    zone_file: std.ArrayList(usize) = .empty,
    // a zone's display name when its source gives one (SFZ labels)
    zone_label: std.ArrayList(?Name) = .empty,

    fn init(alloc: std.mem.Allocator) Builder {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *Builder) void {
        for (self.files.items) |*f| {
            self.alloc.free(f.path);
            f.s.deinit(self.alloc);
        }
        self.files.deinit(self.alloc);
        self.zones.deinit(self.alloc);
        self.zone_file.deinit(self.alloc);
        self.zone_label.deinit(self.alloc);
    }

    /// Index of the loaded sample at `path`, loading it the first time.
    fn sample(self: *Builder, path: []const u8) Error!usize {
        for (self.files.items, 0..) |f, i| if (std.mem.eql(u8, f.path, path)) return i;
        var s = if (endsWithIgnoreCase(path, ".vc")) try loadVc(self.alloc, path) else try wav.load(self.alloc, path);
        errdefer s.deinit(self.alloc);
        const owned = self.alloc.dupe(u8, path) catch return Error.OutOfMemory;
        errdefer self.alloc.free(owned);
        self.files.append(self.alloc, .{ .path = owned, .s = s }) catch return Error.OutOfMemory;
        return self.files.items.len - 1;
    }

    fn zone(self: *Builder, file: usize, z: Zone) Error!void {
        return self.zoneNamed(file, z, null);
    }

    fn zoneNamed(self: *Builder, file: usize, z: Zone, label: ?[]const u8) Error!void {
        if (self.zones.items.len >= MAX_ZONES) return Error.TooManyZones;
        self.zone_label.append(self.alloc, if (label) |l| Name.set(l) else null) catch return Error.OutOfMemory;
        var zz = z;
        const s = self.files.items[file].s;
        zz.len = @floatFromInt(s.data.len);
        // voice RAM has no rate of its own: 0, the playing machine's RATE
        zz.sr = if (s.sample_rate > 0) s.sample_rate else if (s.sample_rate < 0) 0 else 48_000;
        zz.loop_start = std.math.clamp(zz.loop_start, 0, zz.len);
        zz.loop_end = std.math.clamp(zz.loop_end, 0, zz.len);
        self.zones.append(self.alloc, zz) catch return Error.OutOfMemory;
        self.zone_file.append(self.alloc, file) catch return Error.OutOfMemory;
    }

    /// Lay the samples into one pool and point each zone at its sample.
    fn finish(self: *Builder) Error!Keymap {
        if (self.zones.items.len == 0) return Error.NoZones;
        var total: usize = GUARD;
        for (self.files.items) |f| total += f.s.data.len + GUARD;
        const pool = self.alloc.alloc(f64, total) catch return Error.OutOfMemory;
        errdefer self.alloc.free(pool);
        @memset(pool, 0);
        const starts = self.alloc.alloc(usize, self.files.items.len) catch return Error.OutOfMemory;
        defer self.alloc.free(starts);
        var at: usize = GUARD;
        for (self.files.items, 0..) |f, i| {
            starts[i] = at;
            @memcpy(pool[at .. at + f.s.data.len], f.s.data);
            at += f.s.data.len + GUARD;
        }
        const zones = self.alloc.alloc(Zone, MAX_ZONES) catch return Error.OutOfMemory;
        @memset(zones, unused_zone);
        const n = self.zones.items.len;
        @memcpy(zones[0..n], self.zones.items);
        for (zones[0..n], self.zone_file.items) |*z, fi| z.start = @floatFromInt(starts[fi]);
        const names = self.alloc.alloc(Name, n) catch {
            self.alloc.free(zones);
            return Error.OutOfMemory;
        };
        for (names, self.zone_file.items, self.zone_label.items) |*nm, fi, lb| nm.* = lb orelse Name.set(stem(std.fs.path.basename(self.files.items[fi].path)));
        return .{ .pool = pool, .zones = zones, .count = n, .names = names };
    }
};

// ── folders ──────────────────────────────────────────────────────────────

fn loadFolder(b: *Builder, dir: []const u8) Error!void {
    var names_buf: [MAX_FILES][256]u8 = undefined;
    var names_len: [MAX_FILES]usize = undefined;
    var n: usize = 0;
    {
        var zbuf: [1024:0]u8 = undefined;
        if (dir.len >= zbuf.len) return Error.PathTooLong;
        @memcpy(zbuf[0..dir.len], dir);
        zbuf[dir.len] = 0;
        const d = opendir(@ptrCast(&zbuf[0])) orelse return Error.OpenFailed;
        defer _ = closedir(d);
        while (readdir(d)) |e| {
            const name = e.d_name[0..e.d_namlen];
            if (name.len == 0 or name[0] == '.' or e.d_type == DT_DIR) continue;
            if (!(endsWithIgnoreCase(name, ".wav") or endsWithIgnoreCase(name, ".vc")) or name.len > 255) continue;
            if (n == MAX_FILES) break;
            @memcpy(names_buf[n][0..name.len], name);
            names_len[n] = name.len;
            n += 1;
        }
    }
    if (n == 0) return Error.NoZones;
    var names: [MAX_FILES][]const u8 = undefined;
    for (0..n) |i| names[i] = names_buf[i][0..names_len[i]];
    std.mem.sort([]const u8, names[0..n], {}, lessName);

    var specs: [MAX_FILES]Spec = undefined;
    for (names[0..n], 0..) |name, i| specs[i] = .{ .name = name, .root = noteFromName(stem(name)) };
    const melodic = for (specs[0..n]) |sp| {
        if (sp.root != null) break true;
    } else false;
    // A melodic folder drops the files without a note in their name.
    var used = n;
    if (melodic) {
        used = 0;
        for (specs[0..n]) |sp| if (sp.root != null) {
            specs[used] = sp;
            used += 1;
        };
        mapMelodic(specs[0..used]);
    } else mapDrums(specs[0..n]);

    for (specs[0..used]) |sp| {
        var pbuf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, sp.name }) catch return Error.PathTooLong;
        const si = try b.sample(full);
        const s = b.files.items[si].s;
        var z = sp.zone;
        if (!melodic) {
            z.loop_mode = LOOP_ONESHOT;
        } else if (s.loop_end > s.loop_start) {
            z.loop_mode = LOOP_ON;
            z.loop_start = @floatFromInt(s.loop_start);
            z.loop_end = @floatFromInt(s.loop_end);
        }
        try b.zone(si, z);
    }
}

const Spec = struct {
    name: []const u8,
    root: ?f64,
    zone: Zone = .{},
};

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessRoot(_: void, a: Spec, b: Spec) bool {
    if (a.root.? != b.root.?) return a.root.? < b.root.?;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Each root covers the keys half way to its neighbours; several files at
/// one root split 0..127 velocity evenly, in name order.
fn mapMelodic(specs: []Spec) void {
    std.mem.sort(Spec, specs, {}, lessRoot);
    var i: usize = 0;
    var prev_root: ?f64 = null;
    while (i < specs.len) {
        const root = specs[i].root.?;
        var j = i;
        while (j < specs.len and specs[j].root.? == root) j += 1;
        const next_root: ?f64 = if (j < specs.len) specs[j].root.? else null;
        const lo: f64 = if (prev_root) |p| @floor((p + root) / 2) + 1 else 0;
        const hi: f64 = if (next_root) |q| @floor((root + q) / 2) else 127;
        const layers: f64 = @floatFromInt(j - i);
        for (specs[i..j], 0..) |*sp, li| {
            const l: f64 = @floatFromInt(li);
            sp.zone = .{
                .lo_key = @max(lo, 0),
                .hi_key = @min(hi, 127),
                .root = root,
                .lo_vel = @floor(128 * l / layers),
                .hi_vel = @floor(128 * (l + 1) / layers) - 1,
            };
        }
        prev_root = root;
        i = j;
    }
}

/// General MIDI placement by keyword; the rest fill free keys from 36 up.
fn mapDrums(specs: []Spec) void {
    var used = [_]bool{false} ** 128;
    for (specs) |*sp| {
        const key = gmKey(stem(sp.name));
        if (key) |k| if (!used[k]) {
            used[k] = true;
            sp.zone = drumZone(k);
            continue;
        };
        sp.zone.lo_key = -1; // placed below
    }
    var next: usize = 36;
    for (specs) |*sp| {
        if (sp.zone.lo_key >= 0) continue;
        while (next < 127 and used[next]) next += 1;
        used[next] = true;
        sp.zone = drumZone(next);
    }
}

fn drumZone(key: usize) Zone {
    const k: f64 = @floatFromInt(key);
    // closed, pedal and open hats choke each other
    const hat = key == 42 or key == 44 or key == 46;
    return .{
        .lo_key = k,
        .hi_key = k,
        .root = k,
        .group = if (hat) 1 else 0,
        .off_by = if (hat) 1 else 0,
    };
}

fn gmKey(name: []const u8) ?usize {
    var words: [16][]const u8 = undefined;
    var nw: usize = 0;
    var it = std.mem.tokenizeAny(u8, name, " _-.()[]");
    while (it.next()) |w| {
        if (nw == words.len) break;
        words[nw] = w;
        nw += 1;
    }
    const has = struct {
        fn f(ws: []const []const u8, keys: []const []const u8) bool {
            for (ws) |w| for (keys) |k| {
                if (std.ascii.startsWithIgnoreCase(w, k)) return true;
            };
            return false;
        }
    }.f;
    const ws = words[0..nw];
    if (has(ws, &.{ "kick", "bd", "bassdrum" })) return 36;
    if (has(ws, &.{ "rim", "rs", "sidestick" })) return 37;
    if (has(ws, &.{ "snare", "sd", "snr" })) return 38;
    if (has(ws, &.{ "clap", "cp", "handclap" })) return 39;
    if (has(ws, &.{ "ohh", "oh", "openhat" }) or (has(ws, &.{ "hat", "hh", "hihat" }) and has(ws, &.{"open"}))) return 46;
    if (has(ws, &.{ "phh", "pedal" })) return 44;
    if (has(ws, &.{ "hat", "hh", "hihat", "chh", "ch" })) return 42;
    if (has(ws, &.{"tom"})) {
        if (has(ws, &.{ "lo", "low", "floor" })) return 41;
        if (has(ws, &.{ "hi", "high" })) return 48;
        return 45;
    }
    if (has(ws, &.{ "crash", "cy", "cymbal" })) return 49;
    if (has(ws, &.{"ride"})) return 51;
    if (has(ws, &.{"tamb"})) return 54;
    if (has(ws, &.{ "cowbell", "cb", "bell" })) return 56;
    if (has(ws, &.{"conga"})) return 63;
    if (has(ws, &.{ "shaker", "shk", "maraca" })) return 70;
    if (has(ws, &.{"clave"})) return 75;
    return null;
}

/// The note named in a file name (C4 = 60; C#4 Db4 Cs4 c4; the last one
/// wins), or a stem that is only digits 0..127 (a MIDI number).
pub fn noteFromName(name: []const u8) ?f64 {
    if (name.len > 0 and name.len <= 3) {
        if (std.fmt.parseInt(u8, name, 10)) |v| {
            if (v < 128) return @floatFromInt(v);
        } else |_| {}
    }
    var found: ?f64 = null;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (i > 0 and std.ascii.isAlphabetic(name[i - 1])) continue;
        if (parseNoteAt(name, i)) |r| {
            const end = i + r.len;
            if (end < name.len and std.ascii.isAlphanumeric(name[end])) continue;
            found = r.note;
        }
    }
    return found;
}

const NoteParse = struct { note: f64, len: usize };

/// A note name at name[i..]: letter, optional #/b/s, optional -, one digit.
fn parseNoteAt(name: []const u8, i: usize) ?NoteParse {
    const pcs = [_]i32{ 9, 11, 0, 2, 4, 5, 7 }; // a b c d e f g
    const c = std.ascii.toLower(name[i]);
    if (c < 'a' or c > 'g') return null;
    var pc = pcs[c - 'a'];
    var j = i + 1;
    if (j < name.len and (name[j] == '#' or name[j] == 's')) {
        pc += 1;
        j += 1;
    } else if (j < name.len and name[j] == 'b' and j + 1 < name.len and (std.ascii.isDigit(name[j + 1]) or name[j + 1] == '-')) {
        pc -= 1;
        j += 1;
    }
    var neg = false;
    if (j < name.len and name[j] == '-') {
        neg = true;
        j += 1;
    }
    if (j >= name.len or !std.ascii.isDigit(name[j])) return null;
    var oct: i32 = name[j] - '0';
    j += 1;
    if (neg) oct = -oct;
    const note = (oct + 1) * 12 + pc;
    if (note < 0 or note > 127) return null;
    return .{ .note = @floatFromInt(note), .len = j - i };
}

// ── SFZ ──────────────────────────────────────────────────────────────────

const MAX_OPS = 48;
const Op = struct { key: []const u8, val: []const u8 };
const Level = struct {
    ops: [MAX_OPS]Op = undefined,
    n: usize = 0,
    fn set(self: *Level, key: []const u8, val: []const u8) void {
        for (self.ops[0..self.n]) |*o| if (std.mem.eql(u8, o.key, key)) {
            o.val = val;
            return;
        };
        if (self.n < MAX_OPS) {
            self.ops[self.n] = .{ .key = key, .val = val };
            self.n += 1;
        }
    }
    fn get(self: *const Level, key: []const u8) ?[]const u8 {
        for (self.ops[0..self.n]) |o| if (std.mem.eql(u8, o.key, key)) return o.val;
        return null;
    }
};

/// A region with its inherited opcodes resolved, before its sample loads.
pub const SfzRegion = struct {
    sample: []const u8,
    zone: Zone,
    // Loop points given by opcodes; otherwise the file's.
    has_loop_mode: bool = false,
    has_loop_points: bool = false,
    // region_label, else group_label: the zone's name in the zone list and
    // the piano roll; zones sharing one edit as one sound
    label: ?[]const u8 = null,
};

fn loadSfz(b: *Builder, path: []const u8) Error!void {
    const text = try readFile(b.alloc, path);
    defer b.alloc.free(text);
    var regions: [MAX_ZONES]SfzRegion = undefined;
    var dpath_buf: [512]u8 = undefined;
    const r = parseSfz(text, &regions, &dpath_buf);
    const dir = std.fs.path.dirname(path) orelse ".";
    for (regions[0..r.count]) |reg| {
        var pbuf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&pbuf, "{s}/{s}{s}", .{ dir, r.default_path, reg.sample }) catch return Error.PathTooLong;
        for (full) |*ch| if (ch.* == '\\') {
            ch.* = '/';
        };
        const si = b.sample(full) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue, // a missing sample drops its region, not the map
        };
        const s = b.files.items[si].s;
        var z = reg.zone;
        if (!reg.has_loop_points and s.loop_end > s.loop_start) {
            z.loop_start = @floatFromInt(s.loop_start);
            z.loop_end = @floatFromInt(s.loop_end);
            // SFZ: a sample with loop points loops unless told otherwise.
            if (!reg.has_loop_mode) z.loop_mode = LOOP_ON;
        }
        try b.zoneNamed(si, z, reg.label);
    }
}

pub const SfzResult = struct { count: usize, default_path: []const u8 };

/// Parse SFZ text into regions (up to out.len). Supported opcodes: sample,
/// key, lokey, hikey, pitch_keycenter, lovel, hivel, tune, transpose,
/// volume, pan, loop_mode, loop_start, loop_end, group, off_by,
/// seq_length, seq_position, region_label, group_label, trigger
/// (attack, or release: played at note-off), rt_decay
/// and <control> default_path. Unknown
/// opcodes are ignored.
pub fn parseSfz(text: []const u8, out: []SfzRegion, dpath_buf: []u8) SfzResult {
    var control = Level{};
    var global = Level{};
    var master = Level{};
    var group = Level{};
    var region = Level{};
    const Hdr = enum { none, control, global, master, group, region };
    var cur: Hdr = .none;
    var count: usize = 0;

    var i: usize = 0;
    while (true) {
        // skip whitespace and comments
        while (i < text.len) {
            if (std.ascii.isWhitespace(text[i])) {
                i += 1;
            } else if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '/') {
                while (i < text.len and text[i] != '\n') i += 1;
            } else if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
                i += 2;
                while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
                i += 2;
            } else break;
        }
        const at_end = i >= text.len;
        const at_header = !at_end and text[i] == '<';
        if (at_end or at_header) {
            if (cur == .region and count < out.len) {
                if (resolveRegion(&region, &group, &master, &global)) |reg| {
                    out[count] = reg;
                    count += 1;
                }
            }
            if (at_end) break;
            const close_i = std.mem.indexOfScalarPos(u8, text, i, '>') orelse break;
            const name = text[i + 1 .. close_i];
            i = close_i + 1;
            region = .{};
            if (std.mem.eql(u8, name, "region")) {
                cur = .region;
            } else if (std.mem.eql(u8, name, "group")) {
                cur = .group;
                group = .{};
            } else if (std.mem.eql(u8, name, "master")) {
                cur = .master;
                master = .{};
                group = .{};
            } else if (std.mem.eql(u8, name, "global")) {
                cur = .global;
                global = .{};
                master = .{};
                group = .{};
            } else if (std.mem.eql(u8, name, "control")) {
                cur = .control;
            } else cur = .none;
            continue;
        }
        // opcode=value; a value runs to the next opcode, header or line end
        const eq = std.mem.indexOfScalarPos(u8, text, i, '=') orelse break;
        const key = std.mem.trim(u8, text[i..eq], " \t\r");
        var j = eq + 1;
        const vstart = j;
        var vend = j;
        while (j < text.len and text[j] != '\n' and text[j] != '<') {
            if (std.ascii.isWhitespace(text[j]) and nextIsOpcode(text, j)) break;
            if (j + 1 < text.len and text[j] == '/' and text[j + 1] == '/') break;
            j += 1;
            vend = j;
        }
        const val = std.mem.trim(u8, text[vstart..vend], " \t\r");
        i = j;
        switch (cur) {
            .control => control.set(key, val),
            .global => global.set(key, val),
            .master => master.set(key, val),
            .group => group.set(key, val),
            .region => region.set(key, val),
            .none => {},
        }
    }
    var dp: []const u8 = "";
    if (control.get("default_path")) |p| if (p.len <= dpath_buf.len) {
        @memcpy(dpath_buf[0..p.len], p);
        for (dpath_buf[0..p.len]) |*ch| if (ch.* == '\\') {
            ch.* = '/';
        };
        dp = dpath_buf[0..p.len];
    };
    return .{ .count = count, .default_path = dp };
}

fn nextIsOpcode(text: []const u8, ws: usize) bool {
    var k = ws;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    const s = k;
    while (k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '_')) k += 1;
    return k > s and k < text.len and text[k] == '=';
}

fn resolveRegion(region: *const Level, group: *const Level, master: *const Level, global: *const Level) ?SfzRegion {
    const levels = [_]*const Level{ region, group, master, global };
    const get = struct {
        fn f(ls: []const *const Level, key: []const u8) ?[]const u8 {
            for (ls) |l| if (l.get(key)) |v| return v;
            return null;
        }
    }.f;
    const sample = get(&levels, "sample") orelse return null;
    if (sample.len == 0 or sample[0] == '*') return null; // generators
    var release = false;
    if (get(&levels, "trigger")) |t| {
        if (std.mem.eql(u8, t, "release")) release = true else if (!std.mem.eql(u8, t, "attack")) return null;
    }

    var z = Zone{ .root = 60 };
    if (get(&levels, "key")) |v| if (parseSfzNote(v)) |k| {
        z.lo_key = k;
        z.hi_key = k;
        z.root = k;
    };
    if (get(&levels, "lokey")) |v| if (parseSfzNote(v)) |k| {
        z.lo_key = k;
    };
    if (get(&levels, "hikey")) |v| if (parseSfzNote(v)) |k| {
        z.hi_key = k;
    };
    if (get(&levels, "pitch_keycenter")) |v| if (parseSfzNote(v)) |k| {
        z.root = k;
    };
    if (num(get(&levels, "lovel"))) |v| z.lo_vel = v;
    if (num(get(&levels, "hivel"))) |v| z.hi_vel = v;
    // The root moves opposite to tuning: +100 cents sounds a semitone up.
    if (num(get(&levels, "tune"))) |v| z.root -= v / 100;
    if (num(get(&levels, "transpose"))) |v| z.root -= v;
    if (num(get(&levels, "volume"))) |v| z.gain = std.math.pow(f64, 10, v / 20);
    if (num(get(&levels, "pan"))) |v| z.pan = std.math.clamp(v / 100, -1, 1);
    if (num(get(&levels, "group"))) |v| z.group = v;
    if (num(get(&levels, "off_by"))) |v| z.off_by = v;
    if (release) z.trigger = 1;
    if (num(get(&levels, "rt_decay"))) |v| z.rt_decay = @max(v, 0);
    if (num(get(&levels, "seq_length"))) |v| z.rr_len = @max(@round(v), 1);
    if (num(get(&levels, "seq_position"))) |v| z.rr_pos = std.math.clamp(@round(v) - 1, 0, z.rr_len - 1);
    var reg = SfzRegion{ .sample = sample, .zone = z };
    reg.label = region.get("region_label") orelse get(&levels, "group_label") orelse get(&levels, "region_label");
    const lm = get(&levels, "loop_mode") orelse get(&levels, "loopmode");
    if (lm) |m| {
        reg.has_loop_mode = true;
        reg.zone.loop_mode = if (std.mem.startsWith(u8, m, "loop_")) LOOP_ON else if (std.mem.eql(u8, m, "one_shot")) LOOP_ONESHOT else LOOP_NONE;
    }
    const ls = num(get(&levels, "loop_start") orelse get(&levels, "loopstart"));
    const le = num(get(&levels, "loop_end") orelse get(&levels, "loopend"));
    if (ls != null and le != null) {
        reg.has_loop_points = true;
        reg.zone.loop_start = ls.?;
        reg.zone.loop_end = le.? + 1; // SFZ loop_end is inclusive
    }
    return reg;
}

fn num(v: ?[]const u8) ?f64 {
    const s = v orelse return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

/// An SFZ key: a MIDI number or a note name (c4 = 60, c#4, db4).
pub fn parseSfzNote(v: []const u8) ?f64 {
    if (std.fmt.parseFloat(f64, v)) |n| return n else |_| {}
    if (v.len == 0) return null;
    const r = parseNoteAt(v, 0) orelse return null;
    return if (r.len == v.len) r.note else null;
}

// ── helpers ──────────────────────────────────────────────────────────────

fn stem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn isDir(path: []const u8) bool {
    var zbuf: [1024:0]u8 = undefined;
    if (path.len >= zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const d = opendir(@ptrCast(&zbuf[0])) orelse return false;
    _ = closedir(d);
    return true;
}

// ── Anti-aliasing ahead of a stored rate ────────────────────────────────

/// A copy of `km`'s pool with each zone low-passed at `fc` Hz, as a
/// sampler's input filter does before it samples at `rate`: an 8-pole
/// Butterworth, causal like the hardware's. A zone whose rate is 0 (a .VC,
/// already voice RAM) or already below 2.2 x fc stays as it is. With `cap`,
/// only the first `cap` stored samples' worth (at `rate`) of each zone is
/// filtered, which is all a machine that stores that many ever plays.
pub fn antialias(alloc: std.mem.Allocator, km: *const Keymap, fc: f64, rate: f64, cap: usize) ![]f64 {
    const out = try alloc.alloc(f64, km.pool.len);
    @memcpy(out, km.pool);
    // the four sections' Q of an 8th-order Butterworth
    const qs = [_]f64{ 0.5097955791041592, 0.6013448869350453, 0.8999762231364156, 2.5629154477415055 };
    for (km.zones[0..km.count]) |z| {
        if (z.sr < 0.5 or fc * 2.2 >= z.sr) continue;
        const start: usize = @intFromFloat(z.start);
        var n: usize = @intFromFloat(z.len);
        if (cap > 0 and rate > 0) n = @min(n, @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(cap)) * z.sr / rate))) + 64);
        const x = out[start .. start + n];
        const w = @tan(std.math.pi * fc / z.sr);
        for (qs) |q| {
            // bilinear 2-pole lowpass, direct form I
            const k = 1 + w / q + w * w;
            const b0 = w * w / k;
            const a1 = 2 * (w * w - 1) / k;
            const a2 = (1 - w / q + w * w) / k;
            var x1: f64 = 0;
            var x2: f64 = 0;
            var y1: f64 = 0;
            var y2: f64 = 0;
            for (x) |*v| {
                const y = b0 * (v.* + 2 * x1 + x2) - a1 * y1 - a2 * y2;
                x2 = x1;
                x1 = v.*;
                y2 = y1;
                y1 = y;
                v.* = y;
            }
        }
    }
    return out;
}

test "antialias passes the band and stops what would fold" {
    const a = std.testing.allocator;
    const n = 48_000;
    var pool = try a.alloc(f64, n);
    defer a.free(pool);
    var zones = [_]Zone{.{}} ** 1;
    zones[0].start = 0;
    zones[0].len = n;
    zones[0].sr = 48_000;
    var km = Keymap{ .pool = pool, .zones = &zones, .count = 1 };
    const rms = struct {
        fn of(x: []const f64) f64 {
            var s: f64 = 0;
            for (x) |v| s += v * v;
            return @sqrt(s / @as(f64, @floatFromInt(x.len)));
        }
    }.of;
    // stored at 16 kHz, filtered at 0.45 x: 1 kHz passes, 12 kHz (which
    // would fold to 4 kHz) is 30 dB down (48 dB/oct, 0.74 oct over)
    for ([_]f64{ 1000, 12000 }, [_]bool{ true, false }) |f, pass| {
        for (pool, 0..) |*v, i| v.* = @sin(2 * std.math.pi * f * @as(f64, @floatFromInt(i)) / 48_000);
        const o = try antialias(a, &km, 0.45 * 16_000, 16_000, 0);
        defer a.free(o);
        const r = rms(o[4800..]) / rms(pool[4800..]);
        if (pass) try std.testing.expect(r > 0.97) else try std.testing.expect(r < 0.032);
    }
    // a zone already at or under the rate isn't touched
    zones[0].sr = 12_000;
    const o = try antialias(a, &km, 0.45 * 16_000, 16_000, 0);
    defer a.free(o);
    try std.testing.expectEqualSlices(f64, pool, o);
}

// ── Fairlight CMI voice files ───────────────────────────────────────────

/// A Series II / IIx `.VC` file: 21,888 bytes, 5,376 of voice parameters,
/// the 16,384-byte waveform RAM (unsigned 8-bit, 128 segments of 128) at
/// VC_RAM, then 128 more. (On disk each file follows a 128-byte header
/// sector, which is why disk tools read the RAM at 0x1580.) The loop is whole segments. The file stores no sample rate:
/// the sample's rate is -1, which makes a zone of rate 0, played at the
/// machine's RATE. Page 7's other settings (filter, envelope, vibrato) live
/// in the voice's control file, NAME.CO, which tools/library/cmi.py reads.
pub const VC_SIZE = 21_888;
pub const VC_RAM = 0x1500;
pub const VC_LOOP_START = 0x1332; // first loop segment
pub const VC_LOOP_END = 0x1333; // last loop segment, inclusive
pub const VC_LOOP_ON = 0x133B; // nonzero: loop

pub const VcParams = struct { loop_on: bool, loop_start: u8, loop_end: u8 };

pub fn vcParams(bytes: []const u8) ?VcParams {
    if (bytes.len < VC_RAM + 16_384) return null;
    return .{
        .loop_on = bytes[VC_LOOP_ON] != 0,
        .loop_start = bytes[VC_LOOP_START] & 0x7f,
        .loop_end = bytes[VC_LOOP_END] & 0x7f,
    };
}

fn loadVc(alloc: std.mem.Allocator, path: []const u8) Error!wav.Sample {
    const bytes = try readFile(alloc, path);
    defer alloc.free(bytes);
    const p = vcParams(bytes) orelse return Error.BadVoiceFile;
    const data = alloc.alloc(f64, 16_384) catch return Error.OutOfMemory;
    for (bytes[VC_RAM..][0..16_384], data) |b, *d| d.* = (@as(f64, @floatFromInt(b)) - 128) / 128;
    var s = wav.Sample{ .data = data, .sample_rate = -1 };
    if (p.loop_on and p.loop_end >= p.loop_start) {
        s.loop_start = @as(usize, p.loop_start) * 128;
        s.loop_end = (@as(usize, p.loop_end) + 1) * 128;
    }
    return s;
}

test "a .VC file loads its 8-bit RAM and segment loop" {
    var bytes = [_]u8{0} ** VC_SIZE;
    for (bytes[VC_RAM..][0..16_384], 0..) |*b, i| b.* = if (i % 128 < 64) 0xC0 else 0x40;
    bytes[VC_LOOP_ON] = 1;
    bytes[VC_LOOP_START] = 2;
    bytes[VC_LOOP_END] = 5;
    const path = "/tmp/slab-keymap-test.vc";
    {
        var zb: [64:0]u8 = undefined;
        @memcpy(zb[0..path.len], path);
        zb[path.len] = 0;
        const fd = open(@ptrCast(&zb[0]), 0x0601, @as(c_int, 0o644)); // O_WRONLY|O_CREAT|O_TRUNC
        try std.testing.expect(fd >= 0);
        defer _ = close(fd);
        try std.testing.expectEqual(@as(isize, VC_SIZE), write(fd, &bytes, bytes.len));
    }
    var km = try load(std.testing.allocator, path);
    defer km.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), km.count);
    const z = km.zones[0];
    try std.testing.expectEqual(@as(f64, 0), z.sr);
    try std.testing.expectEqual(@as(f64, 16_384), z.len);
    try std.testing.expectEqual(LOOP_ON, z.loop_mode);
    try std.testing.expectEqual(@as(f64, 256), z.loop_start);
    try std.testing.expectEqual(@as(f64, 768), z.loop_end);
    const at: usize = @intFromFloat(z.start);
    try std.testing.expectEqual(@as(f64, 0.5), km.pool[at]);
    try std.testing.expectEqual(@as(f64, -0.5), km.pool[at + 64]);
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) Error![]u8 {
    var zbuf: [1024:0]u8 = undefined;
    if (path.len >= zbuf.len) return Error.PathTooLong;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = open(@ptrCast(&zbuf[0]), O_RDONLY);
    if (fd < 0) return Error.OpenFailed;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n < 0) return Error.ReadFailed;
        if (n == 0) break;
        list.appendSlice(alloc, chunk[0..@intCast(n)]) catch return Error.OutOfMemory;
        if (list.items.len > MAX_SFZ_BYTES) return Error.TooLarge;
    }
    return list.toOwnedSlice(alloc) catch Error.OutOfMemory;
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "note names in file names" {
    try testing.expectEqual(@as(?f64, 60), noteFromName("Piano_C4"));
    try testing.expectEqual(@as(?f64, 58), noteFromName("Str A#3 v2"));
    try testing.expectEqual(@as(?f64, 61), noteFromName("db4"));
    try testing.expectEqual(@as(?f64, 58), noteFromName("BRASS-Bb3"));
    try testing.expectEqual(@as(?f64, 0), noteFromName("C-1"));
    try testing.expectEqual(@as(?f64, 64), noteFromName("064"));
    try testing.expectEqual(@as(?f64, null), noteFromName("Kick 808"));
    try testing.expectEqual(@as(?f64, null), noteFromName("Bass"));
    try testing.expectEqual(@as(?f64, null), noteFromName("Chord1"));
}

test "folder of roots splits keys half way and velocity by layer" {
    var specs = [_]Spec{
        .{ .name = "p_C4_v2", .root = 60 },
        .{ .name = "p_C3", .root = 48 },
        .{ .name = "p_C4_v1", .root = 60 },
        .{ .name = "p_G4", .root = 67 },
    };
    mapMelodic(&specs);
    try testing.expectEqualStrings("p_C3", specs[0].name);
    try testing.expectEqual(@as(f64, 0), specs[0].zone.lo_key);
    try testing.expectEqual(@as(f64, 54), specs[0].zone.hi_key);
    try testing.expectEqualStrings("p_C4_v1", specs[1].name);
    try testing.expectEqual(@as(f64, 55), specs[1].zone.lo_key);
    try testing.expectEqual(@as(f64, 63), specs[1].zone.hi_key);
    try testing.expectEqual(@as(f64, 0), specs[1].zone.lo_vel);
    try testing.expectEqual(@as(f64, 63), specs[1].zone.hi_vel);
    try testing.expectEqual(@as(f64, 64), specs[2].zone.lo_vel);
    try testing.expectEqual(@as(f64, 127), specs[2].zone.hi_vel);
    try testing.expectEqual(@as(f64, 64), specs[3].zone.lo_key);
    try testing.expectEqual(@as(f64, 127), specs[3].zone.hi_key);
}

test "drum folder: GM keywords, then free keys; hats choke" {
    var specs = [_]Spec{
        .{ .name = "808 Kick.wav", .root = null },
        .{ .name = "Snare_02.wav", .root = null },
        .{ .name = "Open Hat.wav", .root = null },
        .{ .name = "HH closed.wav", .root = null },
        .{ .name = "Zap.wav", .root = null },
        .{ .name = "Kick B.wav", .root = null },
    };
    mapDrums(&specs);
    try testing.expectEqual(@as(f64, 36), specs[0].zone.lo_key);
    try testing.expectEqual(@as(f64, 38), specs[1].zone.lo_key);
    try testing.expectEqual(@as(f64, 46), specs[2].zone.lo_key);
    try testing.expectEqual(@as(f64, 42), specs[3].zone.lo_key);
    try testing.expectEqual(@as(f64, 1), specs[2].zone.group);
    try testing.expectEqual(@as(f64, 1), specs[3].zone.off_by);
    try testing.expectEqual(@as(f64, 37), specs[4].zone.lo_key); // first free key
    try testing.expectEqual(@as(f64, 39), specs[5].zone.lo_key); // 36 taken
}

test "sfz: inheritance, note names, spaces in paths, loops, release zones" {
    const text =
        \\// a comment
        \\<control> default_path=samples\
        \\<global> volume=-6
        \\<group> lovel=0 hivel=63 loop_mode=loop_continuous
        \\<region> sample=Piano C4 soft.wav lokey=c4 hikey=e4 pitch_keycenter=c4 tune=50
        \\<region> sample=Piano G4 soft.wav key=67 loop_start=100 loop_end=199
        \\<group> lovel=64 trigger=release rt_decay=6
        \\<region> sample=rel.wav key=60
        \\<region> sample=legato.wav key=61 trigger=legato
        \\<group> group=1 off_by=1 loop_mode=one_shot
        \\<region> sample=hat.wav key=42 /* inline */ pan=-50
    ;
    var regions: [8]SfzRegion = undefined;
    var dp: [64]u8 = undefined;
    const r = parseSfz(text, &regions, &dp);
    try testing.expectEqual(@as(usize, 4), r.count);
    try testing.expectEqualStrings("samples/", r.default_path);
    const rel = regions[2];
    try testing.expectEqualStrings("rel.wav", rel.sample);
    try testing.expectEqual(@as(f64, 1), rel.zone.trigger);
    try testing.expectEqual(@as(f64, 6), rel.zone.rt_decay);
    const a = regions[0];
    try testing.expectEqualStrings("Piano C4 soft.wav", a.sample);
    try testing.expectEqual(@as(f64, 60), a.zone.lo_key);
    try testing.expectEqual(@as(f64, 64), a.zone.hi_key);
    try testing.expectApproxEqAbs(@as(f64, 59.5), a.zone.root, 1e-9);
    try testing.expectEqual(@as(f64, 63), a.zone.hi_vel);
    try testing.expectApproxEqAbs(@as(f64, 0.501), a.zone.gain, 1e-3);
    try testing.expectEqual(LOOP_ON, a.zone.loop_mode);
    try testing.expect(!a.has_loop_points);
    const b = regions[1];
    try testing.expectEqual(@as(f64, 67), b.zone.root);
    try testing.expect(b.has_loop_points);
    try testing.expectEqual(@as(f64, 200), b.zone.loop_end);
    const h = regions[3];
    try testing.expectEqualStrings("hat.wav", h.sample);
    try testing.expectEqual(LOOP_ONESHOT, h.zone.loop_mode);
    try testing.expectEqual(@as(f64, 1), h.zone.off_by);
    try testing.expectEqual(@as(f64, -0.5), h.zone.pan);
}
