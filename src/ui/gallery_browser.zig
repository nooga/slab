//! Gallery page BROWSER: the prototype of the library browser
//! (docs/25 §The browser) in the layout's left column, beside a mock
//! arrangement it drops into. The look stays pixel-exact; the behavior
//! is a modern file browser's:
//!
//!   - search as you type, from anywhere (any letter starts a search,
//!     ⌘F focuses it), every word must match, matches drawn bold
//!   - source tabs (ALL PROJECT USER FACTORY PACKS ONLINE) and kind chips
//!     that show live counts; ★ narrows to favorites
//!   - folders that fold, a sticky header for the folder in view, and an
//!     overlay scrollbar that shows while scrolling
//!   - click, ⇧-click range and ⌘-click selection; ↑↓ ←→ ↩ ␣ Esc
//!   - hover actions (★, ▶ audition), auto-audition on select
//!   - drag one or many items onto a track, a track header, the space
//!     below the tracks (a new track) or the machine strip; the target
//!     lights, a clip shows where it will land, a bad target says no
//!   - a right-click menu, tooltips, and a toast with Undo after a drop
//!   - a preview pane for the selection (split, folds on double-click)
//!   - pack cards for the Library (download, supply, installed)
//!
//! Factory presets are the real ones (machines/*/presets, with the
//! Project and User banks from storage); everything else is mock data.
//! Nothing here plays sound: audition is drawn, not heard.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const menu = @import("menu.zig");
const text_field = @import("text_field.zig");
const presets_mod = @import("../presets.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;

// ── Items ────────────────────────────────────────────────────────────

pub const Kind = enum(u8) { preset, table, clip, sample, song };
const KIND_CHIPS = [_][]const u8{ "PRESET", "TABLE", "CLIP", "SAMPLE", "SONG" };
const KIND_NAMES = [_][]const u8{ "preset", "wavetable", "clip", "sample", "song" };

const Source = enum(u8) { project, user, factory, pack };
const SOURCE_NAMES = [_][]const u8{ "PROJECT", "USER", "FACTORY", "PACK" };
const SOURCE_PREFIX = [_][]const u8{ "project:", "user:", "factory:", "lib:" };
const SOURCE_TABS = [_][]const u8{ "ALL", "PROJECT", "USER", "FACTORY", "PACKS", "ONLINE" };
const TAB_PACKS: u8 = 4;
const TAB_ONLINE: u8 = 5;

const Item = struct {
    name: [48]u8 = undefined,
    name_len: u8 = 0,
    folder: [24]u8 = undefined,
    folder_len: u8 = 0,
    kind: Kind,
    source: Source,
    /// Clip and sample length in beats; frames for a table.
    size: u8 = 4,
    seed: u32 = 0,
    fav: bool = false,
    /// From a pack that isn't redistributable: Publish refuses it.
    shareable: bool = true,

    fn nameS(it: *const Item) []const u8 {
        return it.name[0..it.name_len];
    }

    fn folderS(it: *const Item) []const u8 {
        return it.folder[0..it.folder_len];
    }
};

fn makeItem(kind: Kind, source: Source, folder: []const u8, name: []const u8, size: u8) Item {
    var it = Item{ .kind = kind, .source = source, .size = size };
    it.name_len = @intCast(@min(name.len, it.name.len));
    @memcpy(it.name[0..it.name_len], name[0..it.name_len]);
    const f = @min(folder.len, it.folder.len);
    for (folder[0..f], 0..) |ch, i| it.folder[i] = std.ascii.toUpper(ch);
    it.folder_len = @intCast(f);
    it.seed = @truncate(std.hash.Wyhash.hash(@intFromEnum(kind), name) ^ std.hash.Wyhash.hash(7, folder));
    return it;
}

const MAX_ITEMS = 4096;
const MAX_ROWS = MAX_ITEMS + 512;
const MAX_SEL = 256;
const MAX_OPEN = 256;

const Row = struct {
    header: bool,
    /// The item, or a header's first item.
    item: u16,
    /// A header's item count (this view).
    count: u16 = 0,
};

// ── The mock arrangement ─────────────────────────────────────────────

const BARS = 16;
const MAX_TRACKS = 8;
const MAX_CLIPS = 24;

const Clip = struct {
    start: u8,
    len: u8,
    name: [24]u8 = undefined,
    name_len: u8 = 0,
    kind: Kind,
    seed: u32,
};

const Track = struct {
    name: [16]u8 = undefined,
    name_len: u8 = 0,
    color: Color,
    preset: [32]u8 = undefined,
    preset_len: u8 = 0,
    table: [24]u8 = undefined,
    table_len: u8 = 0,
    clips: [MAX_CLIPS]Clip = undefined,
    n: u8 = 0,

    fn init(name: []const u8, color: Color, preset: []const u8) Track {
        var t = Track{ .color = color };
        setStr(&t.name, &t.name_len, name);
        setStr(&t.preset, &t.preset_len, preset);
        setStr(&t.table, &t.table_len, "BASIC");
        return t;
    }

    fn add(t: *Track, start: u8, len: u8, name: []const u8, kind: Kind, seed: u32) void {
        if (t.n >= MAX_CLIPS) return;
        var cl = Clip{ .start = start, .len = len, .kind = kind, .seed = seed };
        setStr(&cl.name, &cl.name_len, name);
        t.clips[t.n] = cl;
        t.n += 1;
    }

    /// First bar after every clip.
    fn end(t: *const Track) u8 {
        var e: u8 = 0;
        for (t.clips[0..t.n]) |cl| e = @max(e, cl.start + cl.len);
        return e;
    }
};

fn setStr(buf: anytype, len: *u8, s: []const u8) void {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    len.* = @intCast(n);
}

const Arrangement = struct {
    tracks: [MAX_TRACKS]Track = undefined,
    n: u8 = 0,
    sel: u8 = 0,
};

fn mockArrangement() Arrangement {
    var a = Arrangement{};
    a.tracks[0] = Track.init("BASS", style.track[0], "CONCOCTION · CRISP SAW BASS");
    a.tracks[0].add(0, 4, "BASS A", .clip, 11);
    a.tracks[0].add(4, 4, "BASS B", .clip, 12);
    a.tracks[1] = Track.init("CHORDS", style.track[4], "JUNO2 · WARM PAD");
    a.tracks[1].add(0, 8, "STABS", .clip, 21);
    a.tracks[2] = Track.init("ARP", style.track[5], "PROFIT5 · GLASS ARP");
    a.tracks[2].add(2, 2, "ARP 16TH", .clip, 31);
    a.tracks[3] = Track.init("DRUMS", style.track[2], "DRUM2 · 909 KIT");
    a.tracks[3].add(0, 4, "BEAT 1", .clip, 41);
    a.tracks[3].add(4, 4, "BEAT 1", .clip, 41);
    a.tracks[4] = Track.init("VOX", style.track[6], "SAMPLER · RAW");
    a.tracks[4].add(4, 2, "TAKE-1", .sample, 51);
    a.n = 5;
    return a;
}

// ── Packs ────────────────────────────────────────────────────────────

const PackState = enum { available, downloading, installed, supply, instructions };

const Pack = struct {
    name: []const u8,
    id: []const u8,
    license: []const u8,
    size: []const u8,
    state: PackState,
    progress: f32 = 0,
};

// ── State ────────────────────────────────────────────────────────────

const Drop = union(enum) {
    none,
    lane: struct { track: u8, bar: u8 },
    header: u8,
    new_track,
    machine,
    open_song,
};

const Toast = struct {
    text: [96]u8 = undefined,
    len: u8 = 0,
    t0: f64 = 0,
    undo: bool = false,
};

pub const State = struct {
    items: []Item,
    n_items: usize = 0,
    rows: []Row,
    n_rows: usize = 0,

    tab: u8 = 0,
    kinds: u8 = 0, // bit per Kind; 0 = every kind
    fav_only: bool = false,
    query: text_field.TextBuf = .{ .limit = 48 },
    focus_query: bool = false,

    open: [MAX_OPEN]u64 = undefined,
    n_open: usize = 0,

    sel: [MAX_SEL]u16 = undefined,
    n_sel: usize = 0,
    cursor: ?u16 = null,
    anchor: ?u16 = null,
    reveal: bool = false,

    scroll: f32 = 0,
    scroll_to: f32 = 0,
    scroll_t: f64 = -10,

    press_item: ?u16 = null,
    press_x: f32 = 0,
    press_y: f32 = 0,
    press_mods: bool = false,
    dragging: bool = false,
    drop: Drop = .none,

    audition: ?u16 = null,
    aud_t0: f64 = 0,
    auto_aud: bool = true,

    browser_w: i32 = 336,
    preview_h: i32 = 212,

    arr: Arrangement,
    undo: Arrangement,
    toast: Toast = .{},

    packs: [4]Pack = .{
        .{ .name = "Versilian Community Sample Library", .id = "vcsl", .license = "CC0 · FREE", .size = "6.1 GB", .state = .available },
        .{ .name = "Fairlight CMI disks", .id = "cmi", .license = "YOURS · NOT SHAREABLE", .size = "", .state = .supply },
        .{ .name = "Drum machine collection", .id = "drum-machines", .license = "YOURS · NOT SHAREABLE", .size = "2.3 GB", .state = .installed },
        .{ .name = "Studio Strings (example)", .id = "studio-strings", .license = "COMMERCIAL", .size = "14 GB", .state = .instructions },
    },

    pub fn init(alloc: std.mem.Allocator) !State {
        var st = State{
            .items = try alloc.alloc(Item, MAX_ITEMS),
            .rows = try alloc.alloc(Row, MAX_ROWS),
            .arr = mockArrangement(),
            .undo = undefined,
        };
        st.n_items = 0;
        try scanFactory(alloc, &st);
        addMocks(&st);
        std.mem.sort(Item, st.items[0..st.n_items], {}, itemLess);
        // Open the project's own folders, and the machine on the selected
        // track, the way a fresh browser would.
        for (st.items[0..st.n_items]) |*it| {
            if (it.source == .project or std.mem.eql(u8, it.folderS(), "CONCOCTION")) st.setOpen(groupKey(it), true);
            if (std.mem.eql(u8, it.nameS(), "crisp-saw-bass")) it.fav = true;
            if (std.mem.eql(u8, it.nameS(), "sync")) it.fav = true;
        }
        // Screenshot hooks: SLAB_BROWSER_TAB=0..5, SLAB_BROWSER_QUERY=words,
        // SLAB_BROWSER_SEL=n selects the n-th item in view.
        if (std.c.getenv("SLAB_BROWSER_TAB")) |v| st.tab = std.fmt.parseInt(u8, std.mem.span(v), 10) catch 0;
        if (std.c.getenv("SLAB_BROWSER_QUERY")) |v| st.query.set(std.mem.span(v));
        if (std.c.getenv("SLAB_BROWSER_SEL")) |v| {
            const want = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 0;
            buildRows(&st);
            var n: usize = 0;
            for (st.rows[0..st.n_rows]) |rw| if (!rw.header) {
                if (n == want) {
                    st.selectOnly(rw.item);
                    break;
                }
                n += 1;
            };
        }
        return st;
    }

    pub fn deinit(st: *State, alloc: std.mem.Allocator) void {
        alloc.free(st.items);
        alloc.free(st.rows);
    }

    fn add(st: *State, it: Item) void {
        if (st.n_items >= MAX_ITEMS) return;
        st.items[st.n_items] = it;
        st.n_items += 1;
    }

    fn isOpen(st: *const State, key: u64) bool {
        for (st.open[0..st.n_open]) |k| if (k == key) return true;
        return false;
    }

    fn setOpen(st: *State, key: u64, on: bool) void {
        for (st.open[0..st.n_open], 0..) |k, i| if (k == key) {
            if (!on) {
                st.open[i] = st.open[st.n_open - 1];
                st.n_open -= 1;
            }
            return;
        };
        if (on and st.n_open < MAX_OPEN) {
            st.open[st.n_open] = key;
            st.n_open += 1;
        }
    }

    fn isSelected(st: *const State, i: u16) bool {
        for (st.sel[0..st.n_sel]) |s| if (s == i) return true;
        return false;
    }

    fn selectOnly(st: *State, i: u16) void {
        st.sel[0] = i;
        st.n_sel = 1;
        st.cursor = i;
        st.anchor = i;
    }

    fn toggleSel(st: *State, i: u16) void {
        for (st.sel[0..st.n_sel], 0..) |s, k| if (s == i) {
            std.mem.copyForwards(u16, st.sel[k .. st.n_sel - 1], st.sel[k + 1 .. st.n_sel]);
            st.n_sel -= 1;
            return;
        };
        if (st.n_sel < MAX_SEL) {
            st.sel[st.n_sel] = i;
            st.n_sel += 1;
        }
    }

    fn say(st: *State, now: f64, undo: bool, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&st.toast.text, fmt, args) catch st.toast.text[0..0];
        st.toast.len = @intCast(s.len);
        st.toast.t0 = now;
        st.toast.undo = undo;
    }
};

fn itemLess(_: void, a: Item, b: Item) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    const f = std.mem.order(u8, a.folderS(), b.folderS());
    if (f != .eq) return f == .lt;
    if (a.source != b.source) return @intFromEnum(a.source) < @intFromEnum(b.source);
    return std.ascii.lessThanIgnoreCase(a.nameS(), b.nameS());
}

fn groupKey(it: *const Item) u64 {
    return std.hash.Wyhash.hash(@intFromEnum(it.kind), it.folderS());
}

// ── Data ─────────────────────────────────────────────────────────────

const DIR = opaque {};
const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};
extern fn opendir(path: [*:0]const u8) ?*DIR;
extern fn readdir(dir: *DIR) ?*Dirent;
extern fn closedir(dir: *DIR) c_int;

/// Every machine's presets, with the Project and User banks; generated
/// pack presets (cmi-*, vcsl-*) are listed as the pack's.
fn scanFactory(alloc: std.mem.Allocator, st: *State) !void {
    const found = try alloc.create(presets_mod.List);
    defer alloc.destroy(found);
    const d = opendir("machines") orelse return;
    defer _ = closedir(d);
    while (readdir(d)) |e| {
        const id = e.d_name[0..e.d_namlen];
        if (id[0] == '.' or std.mem.eql(u8, id, "lib") or std.mem.eql(u8, id, "raw_fixtures")) continue;
        var pb: [256]u8 = undefined;
        const dir = std.fmt.bufPrint(&pb, "machines/{s}/presets", .{id}) catch continue;
        found.* = presets_mod.scanMachine(dir, id);
        for (found.names[0..found.count]) |*nm| {
            const name = nm.slice();
            var src: Source = .factory;
            var rest = name;
            if (std.mem.startsWith(u8, name, "Project/")) {
                src = .project;
                rest = name["Project/".len..];
            } else if (std.mem.startsWith(u8, name, "User/")) {
                src = .user;
                rest = name["User/".len..];
            } else if (std.mem.startsWith(u8, name, "cmi") or std.mem.startsWith(u8, name, "vcsl")) {
                src = .pack;
            }
            var it = makeItem(.preset, src, id, rest, 0);
            if (src == .pack and std.mem.startsWith(u8, name, "cmi")) it.shareable = false;
            st.add(it);
        }
    }
}

fn addMocks(st: *State) void {
    const T = struct { k: Kind, s: Source, f: []const u8, n: []const u8, z: u8 };
    const mocks = [_]T{
        .{ .k = .preset, .s = .project, .f = "concoction", .n = "acid-lead", .z = 0 },
        .{ .k = .preset, .s = .user, .f = "concoction", .n = "sync-growl", .z = 0 },
        .{ .k = .preset, .s = .user, .f = "juno2", .n = "my-strings", .z = 0 },
        .{ .k = .table, .s = .project, .f = "wavetables", .n = "acid-bass-wt-a", .z = 16 },
        .{ .k = .table, .s = .user, .f = "wavetables", .n = "sync", .z = 32 },
        .{ .k = .table, .s = .user, .f = "wavetables", .n = "sync-2", .z = 32 },
        .{ .k = .table, .s = .user, .f = "wavetables", .n = "glass-stack", .z = 64 },
        .{ .k = .table, .s = .factory, .f = "wavetables", .n = "basic", .z = 16 },
        .{ .k = .table, .s = .factory, .f = "wavetables", .n = "pwm", .z = 16 },
        .{ .k = .table, .s = .factory, .f = "wavetables", .n = "vowel", .z = 16 },
        .{ .k = .table, .s = .factory, .f = "wavetables", .n = "fold", .z = 16 },
        .{ .k = .table, .s = .factory, .f = "wavetables", .n = "harm", .z = 16 },
        .{ .k = .clip, .s = .project, .f = "clips", .n = "bass a", .z = 16 },
        .{ .k = .clip, .s = .project, .f = "clips", .n = "bass b", .z = 16 },
        .{ .k = .clip, .s = .user, .f = "clips", .n = "arp 16th", .z = 8 },
        .{ .k = .clip, .s = .user, .f = "clips", .n = "chord stabs", .z = 16 },
        .{ .k = .clip, .s = .user, .f = "clips", .n = "two-step hats", .z = 4 },
        .{ .k = .clip, .s = .factory, .f = "clips", .n = "house bass 1", .z = 16 },
        .{ .k = .clip, .s = .factory, .f = "clips", .n = "techno 909 beat", .z = 16 },
        .{ .k = .clip, .s = .factory, .f = "clips", .n = "minor 7 voicings", .z = 32 },
        .{ .k = .clip, .s = .factory, .f = "clips", .n = "breakbeat amen-ish", .z = 16 },
        .{ .k = .sample, .s = .project, .f = "takes", .n = "take-1", .z = 8 },
        .{ .k = .sample, .s = .project, .f = "takes", .n = "take-2", .z = 6 },
        .{ .k = .sample, .s = .user, .f = "drums", .n = "my-kick", .z = 1 },
        .{ .k = .sample, .s = .user, .f = "drums", .n = "rim-click", .z = 1 },
        .{ .k = .sample, .s = .user, .f = "vox", .n = "vox-chop-a", .z = 2 },
        .{ .k = .sample, .s = .user, .f = "vox", .n = "breath", .z = 2 },
        .{ .k = .sample, .s = .factory, .f = "drums", .n = "kick", .z = 1 },
        .{ .k = .sample, .s = .factory, .f = "drums", .n = "snare", .z = 1 },
        .{ .k = .sample, .s = .pack, .f = "drum-machines", .n = "tr-808/bd-long", .z = 2 },
        .{ .k = .sample, .s = .pack, .f = "drum-machines", .n = "tr-909/hh-closed", .z = 1 },
        .{ .k = .sample, .s = .pack, .f = "drum-machines", .n = "linndrum/clap", .z = 1 },
        .{ .k = .song, .s = .factory, .f = "demos", .n = "night_drive", .z = 0 },
        .{ .k = .song, .s = .factory, .f = "demos", .n = "synthpop_8bar", .z = 0 },
        .{ .k = .song, .s = .user, .f = "projects", .n = "bass_study", .z = 0 },
        .{ .k = .song, .s = .user, .f = "projects", .n = "paper_boulevard", .z = 0 },
        .{ .k = .song, .s = .user, .f = "projects", .n = "voltage_riot", .z = 0 },
        .{ .k = .song, .s = .user, .f = "projects", .n = "glass_horizon", .z = 0 },
    };
    for (mocks) |m| {
        var it = makeItem(m.k, m.s, m.f, m.n, m.z);
        if (m.s == .pack) it.shareable = false;
        st.add(it);
    }
}

// ── Filtering ────────────────────────────────────────────────────────

fn sourceIn(tab: u8, s: Source) bool {
    return switch (tab) {
        0 => true,
        1 => s == .project,
        2 => s == .user,
        3 => s == .factory or s == .pack,
        else => false,
    };
}

fn kindIn(mask: u8, k: Kind) bool {
    return mask == 0 or (mask & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(k))))) != 0;
}

/// Every word appears in the name, the folder or the kind (any case).
fn matches(it: *const Item, query: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |w| {
        if (std.ascii.indexOfIgnoreCase(it.nameS(), w) == null and
            std.ascii.indexOfIgnoreCase(it.folderS(), w) == null and
            !std.ascii.startsWithIgnoreCase(KIND_NAMES[@intFromEnum(it.kind)], w)) return false;
    }
    return true;
}

fn passes(st: *const State, it: *const Item, kind_mask: u8) bool {
    if (!sourceIn(st.tab, it.source)) return false;
    if (!kindIn(kind_mask, it.kind)) return false;
    if (st.fav_only and !it.fav) return false;
    return matches(it, st.query.text());
}

/// Rows for this view: a header per folder, its items while it is open.
/// A search opens every folder.
fn buildRows(st: *State) void {
    st.n_rows = 0;
    const searching = st.query.len > 0 or st.fav_only;
    var i: usize = 0;
    while (i < st.n_items) {
        const key = groupKey(&st.items[i]);
        var j = i;
        var count: u16 = 0;
        while (j < st.n_items and groupKey(&st.items[j]) == key) : (j += 1) {
            if (passes(st, &st.items[j], st.kinds)) count += 1;
        }
        if (count > 0 and st.n_rows < MAX_ROWS) {
            st.rows[st.n_rows] = .{ .header = true, .item = @intCast(i), .count = count };
            st.n_rows += 1;
            if (searching or st.isOpen(key)) {
                var k = i;
                while (k < j) : (k += 1) {
                    if (!passes(st, &st.items[k], st.kinds) or st.n_rows >= MAX_ROWS) continue;
                    st.rows[st.n_rows] = .{ .header = false, .item = @intCast(k) };
                    st.n_rows += 1;
                }
            }
        }
        i = j;
    }
}

fn rowOf(st: *const State, item: u16) ?usize {
    for (st.rows[0..st.n_rows], 0..) |r, k| if (!r.header and r.item == item) return k;
    return null;
}

// ── Page ─────────────────────────────────────────────────────────────

const ROW_H: i32 = 18;
const CHIP_H: i32 = 18;
const HEAD_H: i32 = 24;
const CTX_MENU: u64 = 0xB0B5E;
const TOAST_S: f64 = 4.0;

pub fn page(ui: *Ui, screen: Rect, st: *State) void {
    ui.pushId("browser-page");
    defer ui.popId();
    const cols = ctl.split(ui, screen, "browser-w", &st.browser_w, .{ .axis = .cols, .min = 240, .min_other = 320, .collapsed = 0 });
    st.drop = .none;
    browser(ui, cols[0], st);
    var right = cols[1];
    const strip_r = right.cutBottom(116);
    arrangement(ui, right, st);
    machineStrip(ui, strip_r, st);
    finishDrag(ui, st);
    toast(ui, right, st);
    ghost(ui, st);
}

// ── Browser column ───────────────────────────────────────────────────

fn browser(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("browser");
    defer ui.popId();
    var col = r;

    // Title bar: name, auto-audition, item count.
    var bar = col.cutTop(HEAD_H);
    const title = ui.plate(bar.cutLeft(84), .{});
    ui.textIn(&ui.fonts.body_bold, title.insetXY(6, 0), "BROWSER", style.text, .left, true);
    const auto_r = bar.cutRight(64);
    _ = ctl.button(ui, auto_r, "auto", &st.auto_aud, .{ .kind = .latch, .label = "AUTO", .led = style.led_green, .flush = true });
    menu.tip(ui, auto_r, "Audition what you select");
    _ = ui.plate(bar, .{});

    // Search.
    const srow = col.cutTop(28);
    const splate = ui.plate(srow, .{});
    var sr = splate.insetXY(4, 3);
    const clear_r = sr.cutRight(if (st.query.len > 0) 20 else 0);
    if (st.query.len > 0) {
        _ = sr.cutRight(2);
        if (ctl.button(ui, clear_r, "clear", null, .{ .label = "\u{D7}" })) {
            st.query.set("");
            st.focus_query = true;
        }
    }
    const query_id = ui.id("query");
    query_wid = query_id;
    typeAhead(ui, st, query_id);
    const ev = text_field.field(ui, sr, "query", &st.query, .{ .focus = st.focus_query });
    st.focus_query = false;
    if (st.query.len == 0 and ui.focus != query_id) {
        ui.textIn(&ui.fonts.body, sr.insetXY(5, 0), "Search", style.text_mute, .left, false);
        const hint = "\u{2318}F";
        ui.textIn(&ui.fonts.legend, sr.insetXY(5, 0), hint, style.text_mute, .right, false);
    }
    if (ev == .changed) {
        st.scroll_to = 0;
        st.reveal = true;
    }

    // Sources.
    const before_tab = st.tab;
    _ = ctl.segmentedFlush(ui, col.cutTop(22), "tabs", &st.tab, &SOURCE_TABS);
    if (st.tab != before_tab) {
        st.scroll_to = 0;
        st.scroll = 0;
    }

    if (st.tab == TAB_PACKS) return packsView(ui, col, st);
    if (st.tab == TAB_ONLINE) return onlineView(ui, col, st);

    // Kind chips with live counts.
    chips(ui, col.cutTop(CHIP_H + 8), st);

    // Footer: key hints and the count.
    footer(ui, col.cutBottom(18), st);

    // List over preview.
    const panes = ctl.split(ui, col, "preview-h", &st.preview_h, .{ .from_end = true, .min = 120, .min_other = 96, .collapsed = 20 });
    buildRows(st);
    list(ui, panes[0], st, ev);
    preview(ui, panes[1], st);
}

/// A letter typed while nothing has focus starts a search; ⌘F focuses it.
fn typeAhead(ui: *Ui, st: *State, query_id: core.Id) void {
    const in = &ui.in;
    if (menu.active()) return;
    if (in.cmd and in.keyPressed(c.rl.KEY_F)) {
        st.focus_query = true;
        st.query.selectAll();
        return;
    }
    if (ui.focus != 0 and ui.focus != query_id) {
        // Another field (a rename) owns the keys.
        if (!isListFocus(ui)) return;
    }
    if (ui.focus == query_id or in.cmd or in.nchars == 0) return;
    for (in.chars[0..in.nchars]) |ch| if (ch > 32 and ch < 127) {
        st.focus_query = true;
        st.query.set("");
        return;
    };
}

/// The list rows take focus when pressed; keys then belong to the list.
var list_focus: core.Id = 0;
var query_wid: core.Id = 0;

fn isListFocus(ui: *const Ui) bool {
    return ui.focus == 0 or ui.focus == list_focus;
}

fn chips(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("chips");
    defer ui.popId();
    const body = ui.plate(r, .{});
    var row = body.insetXY(4, 3);
    // Counts under the current source and search, ignoring the kind mask.
    var counts = [_]u16{0} ** KIND_CHIPS.len;
    var favs: u16 = 0;
    for (st.items[0..st.n_items]) |*it| {
        if (!sourceIn(st.tab, it.source) or !matches(it, st.query.text())) continue;
        if (it.fav) favs += 1;
        if (st.fav_only and !it.fav) continue;
        counts[@intFromEnum(it.kind)] += 1;
    }
    // ★ first: favorites narrow every kind.
    {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\u{2605} {d}", .{favs}) catch "";
        const w = ui.fonts.legend.measure(s) + 8;
        if (chip(ui, row.cutLeft(w), "fav", s, st.fav_only, favs == 0 and !st.fav_only)) {
            st.fav_only = !st.fav_only;
            st.scroll_to = 0;
        }
        _ = row.cutLeft(2);
    }
    for (KIND_CHIPS, 0..) |lab, k| {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s} {d}", .{ lab, counts[k] }) catch lab;
        const w = ui.fonts.legend.measure(s) + 8;
        if (w > row.w) break;
        const bit = @as(u8, 1) << @intCast(k);
        const on = st.kinds & bit != 0;
        if (chip(ui, row.cutLeft(w), k, s, on, counts[k] == 0 and !on)) {
            // Click picks one kind; ⇧ or ⌘ adds it to the others.
            if (ui.in.shift or ui.in.cmd) st.kinds ^= bit else st.kinds = if (st.kinds == bit) 0 else bit;
            st.scroll_to = 0;
        }
        _ = row.cutLeft(2);
    }
}

/// A filter chip: a small well, lit when on. True on click.
fn chip(ui: *Ui, r: Rect, key: anytype, label: []const u8, on: bool, empty: bool) bool {
    const b = ui.behaviorEx(ui.id(key), r, .{ .focusable = false });
    const inner = ui.well(r, if (on) style.accent.alpha(70) else style.well);
    if (b.hover and !on) ui.rect(inner, style.text.alpha(14));
    const col = if (on) style.text else if (empty) style.text_mute else if (b.hover) style.text else style.text_dim;
    ui.textIn(&ui.fonts.legend, inner, label, col, .center, false);
    return b.clicked;
}

fn footer(ui: *Ui, r: Rect, st: *State) void {
    const body = ui.plate(r, .{});
    var buf: [48]u8 = undefined;
    var shown: usize = 0;
    for (st.rows[0..st.n_rows]) |rw| {
        if (rw.header) shown += rw.count;
    }
    const s = if (st.n_sel > 1)
        std.fmt.bufPrint(&buf, "{d} SELECTED", .{st.n_sel}) catch ""
    else
        std.fmt.bufPrint(&buf, "{d} ITEMS", .{shown}) catch "";
    ui.textIn(&ui.fonts.legend, body.insetXY(5, 0), s, style.text_dim, .right, true);
    ui.textIn(&ui.fonts.legend, body.insetXY(5, 0), "\u{2191}\u{2193} MOVE  \u{2190}\u{2192} FOLD  \u{21A9} LOAD  SPACE PLAY", style.text_mute, .left, true);
}

// ── The list ─────────────────────────────────────────────────────────

fn list(ui: *Ui, r: Rect, st: *State, ev: text_field.Event) void {
    ui.pushId("list");
    defer ui.popId();
    const in = &ui.in;
    const well = ui.well(r, style.pane);
    const n_rows: i32 = @intCast(st.n_rows);
    const content_h = n_rows * ROW_H;
    const max_scroll: f32 = @floatFromInt(@max(0, content_h - well.h));
    const over = well.contains(in.ix(), in.iy());

    keys(ui, st, ev, well);

    // Smooth scroll toward the target; the wheel moves the target.
    if (over and in.wheel_y != 0 and !menu.active()) {
        st.scroll_to -= in.wheel_y * @as(f32, ROW_H) * 3;
        st.scroll_t = in.time;
        st.reveal = false;
    }
    // Drag near an edge scrolls.
    if (st.dragging and in.mx >= @as(f32, @floatFromInt(well.x)) and in.mx < @as(f32, @floatFromInt(well.right()))) {
        const top: f32 = @floatFromInt(well.y + 16);
        const bot: f32 = @floatFromInt(well.bottom() - 16);
        if (in.my < top and in.my > top - 40) st.scroll_to -= (top - in.my) * in.dt * 20;
        if (in.my > bot and in.my < bot + 40) st.scroll_to += (in.my - bot) * in.dt * 20;
        st.scroll_t = in.time;
    }
    if (st.reveal) if (st.cursor) |cur| if (rowOf(st, cur)) |k| {
        const y: f32 = @floatFromInt(@as(i32, @intCast(k)) * ROW_H);
        const vh: f32 = @floatFromInt(well.h);
        if (y - @as(f32, ROW_H) < st.scroll_to) st.scroll_to = y - @as(f32, ROW_H); // room for the sticky header
        if (y + @as(f32, ROW_H) > st.scroll_to + vh) st.scroll_to = y + @as(f32, ROW_H) - vh;
        st.reveal = false;
    };
    st.scroll_to = std.math.clamp(st.scroll_to, 0, max_scroll);
    const k_s = @min(1, in.dt * 18);
    st.scroll += (st.scroll_to - st.scroll) * k_s;
    if (@abs(st.scroll_to - st.scroll) < 0.5) st.scroll = st.scroll_to else ui.animate();
    st.scroll = std.math.clamp(st.scroll, 0, max_scroll);
    const scroll_px: i32 = @intFromFloat(@round(st.scroll));

    ui.clip(well);
    const first: usize = @intCast(@max(0, @divFloor(scroll_px, ROW_H)));
    var k = first;
    while (k < st.n_rows) : (k += 1) {
        const y = well.y + @as(i32, @intCast(k)) * ROW_H - scroll_px;
        if (y >= well.bottom()) break;
        drawRow(ui, st, k, Rect.xywh(well.x, y, well.w, ROW_H), well);
    }
    stickyHeader(ui, st, well, scroll_px);
    ui.unclip();

    scrollbar(ui, st, well, content_h, max_scroll);

    if (st.n_rows == 0) emptyState(ui, well, st);

    contextMenu(ui, st);
}

fn emptyState(ui: *Ui, r: Rect, st: *State) void {
    const mid = Rect.xywh(r.x, r.y + @divFloor(r.h, 2) - 24, r.w, 16);
    if (st.query.len > 0) {
        var buf: [80]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "Nothing matches \"{s}\"", .{st.query.text()}) catch "Nothing matches";
        ui.textIn(&ui.fonts.body, mid, s, style.text_dim, .center, false);
        ui.textIn(&ui.fonts.legend, Rect.xywh(r.x, mid.bottom() + 4, r.w, 14), "TRY FEWER WORDS, OR ALL SOURCES", style.text_mute, .center, false);
    } else if (st.fav_only) {
        ui.textIn(&ui.fonts.body, mid, "No favorites here yet", style.text_dim, .center, false);
        ui.textIn(&ui.fonts.legend, Rect.xywh(r.x, mid.bottom() + 4, r.w, 14), "HOVER AN ITEM AND CLICK \u{2605}", style.text_mute, .center, false);
    } else {
        ui.textIn(&ui.fonts.body, mid, "Nothing here yet", style.text_dim, .center, false);
        ui.textIn(&ui.fonts.legend, Rect.xywh(r.x, mid.bottom() + 4, r.w, 14), "SAVE TO LIBRARY FROM ANY TRACK OR MACHINE", style.text_mute, .center, false);
    }
}

fn drawRow(ui: *Ui, st: *State, k: usize, row: Rect, well: Rect) void {
    const rw = st.rows[k];
    const it = &st.items[rw.item];
    const in = &ui.in;
    if (rw.header) {
        headerRow(ui, st, rw, row, false);
        return;
    }
    ui.pushId(@as(usize, rw.item));
    defer ui.popId();
    const visible = row.intersect(well);
    const wid = ui.id("row");
    const b = ui.behaviorEx(wid, visible, .{});
    const selected = st.isSelected(rw.item);

    if (b.pressed) {
        list_focus = wid;
        st.press_item = rw.item;
        st.press_x = in.mx;
        st.press_y = in.my;
        st.press_mods = in.shift or in.cmd;
        if (in.cmd) {
            st.toggleSel(rw.item);
            st.cursor = rw.item;
            st.anchor = rw.item;
        } else if (in.shift and st.anchor != null) {
            selectRange(st, st.anchor.?, rw.item);
            st.cursor = rw.item;
        } else if (!selected) {
            st.selectOnly(rw.item);
            autoAudition(st, in.time);
        } else {
            st.cursor = rw.item;
        }
        if (b.double) loadSelection(st, in.time);
    }
    if (b.held and !st.dragging and st.press_item != null) {
        if (@abs(in.mx - st.press_x) + @abs(in.my - st.press_y) > 5 and st.isSelected(st.press_item.?)) st.dragging = true;
    }
    if (b.released and !st.dragging and !st.press_mods and st.n_sel > 1 and b.clicked) {
        // A plain click inside a multi-selection narrows it (Finder).
        st.selectOnly(rw.item);
        autoAudition(st, in.time);
    }
    if (b.hover and in.right_pressed) {
        if (!selected) st.selectOnly(rw.item);
        st.cursor = rw.item;
        menu.openAt(CTX_MENU, in.ix(), in.iy());
    }

    // Background: selection, cursor, hover.
    const focused = isListFocus(ui) or ui.focus == wid;
    if (selected) ui.rect(row, style.accent.alpha(if (focused) 70 else 40)) else if (b.hover) ui.rect(row, style.text.alpha(12));
    if (st.cursor != null and st.cursor.? == rw.item and st.n_sel > 1) ui.rect(Rect.xywh(row.x, row.y, 2, row.h), style.accent);

    var x = row.x + 16;
    kindIcon(ui, x, row.y + 5, it.kind, if (selected) style.text else style.text_dim);
    x += 12;
    // Source badge in ALL: P U F L.
    if (st.tab == 0) {
        const letters = [_][]const u8{ "P", "U", "", "L" };
        const lt = letters[@intFromEnum(it.source)];
        if (lt.len > 0) {
            const br = Rect.xywh(x, row.y + 4, 9, 10);
            ui.rect(br, sourceColor(it.source).alpha(60));
            ui.textIn(&ui.fonts.legend, br, lt, style.text, .center, false);
        }
        x += 12;
    }

    // Right side: hover actions, else the detail.
    var right = Rect.xywh(row.right() - 48, row.y, 44, row.h);
    const playing = st.audition != null and st.audition.? == rw.item;
    if (b.hover or ui.isHot(ui.id("fav")) or ui.isHot(ui.id("play")) or playing or it.fav) {
        const fav_r = right.cutRight(18);
        if (b.hover or it.fav or ui.isHot(ui.id("fav"))) {
            if (iconButton(ui, fav_r, "fav", "\u{2605}", it.fav, style.led_yellow)) {
                it.fav = !it.fav;
            }
            menu.tip(ui, fav_r, if (it.fav) "Remove from favorites" else "Add to favorites");
        }
        const play_r = right.cutRight(18);
        if (b.hover or playing or ui.isHot(ui.id("play"))) {
            if (iconButton(ui, play_r, "play", if (playing) "\u{25A0}" else "\u{25B6}", playing, style.play)) {
                if (playing) st.audition = null else startAudition(st, rw.item, in.time);
            }
            menu.tip(ui, play_r, "Audition (space)");
        }
    } else {
        var buf: [16]u8 = undefined;
        const d = detail(&buf, it);
        ui.textIn(&ui.fonts.legend, right.insetXY(2, 0), d, style.text_mute, .right, false);
    }

    // Name, matches bold.
    const name_r = Rect.xywh(x, row.y, right.x - x - 4, row.h);
    var nb: [64]u8 = undefined;
    const shown = prettyName(&nb, it.nameS());
    highlighted(ui, name_r, shown, st.query.text(), if (selected) style.text else style.text_dim, playing);

    if (b.hover and !st.dragging) {
        var tb: [96]u8 = undefined;
        menu.tip(ui, name_r, refPath(&tb, it));
    }
}

fn headerRow(ui: *Ui, st: *State, rw: Row, row: Rect, sticky: bool) void {
    const it = &st.items[rw.item];
    ui.pushId(.{ "head", @as(usize, rw.item), sticky });
    defer ui.popId();
    const key = groupKey(it);
    const b = ui.behaviorEx(ui.id("h"), row, .{ .focusable = false });
    const searching = st.query.len > 0 or st.fav_only;
    const open = searching or st.isOpen(key);
    if (b.clicked and !searching) {
        if (ui.in.alt) {
            // ⌥-click folds or opens every folder, as in Finder.
            const want = !open;
            for (st.rows[0..st.n_rows]) |o| if (o.header) st.setOpen(groupKey(&st.items[o.item]), want);
        } else st.setOpen(key, !open);
    }
    ui.rect(row, if (sticky) style.pane_alt else style.pane);
    if (b.hover) ui.rect(row, style.text.alpha(10));
    ui.rect(Rect.xywh(row.x, row.bottom() - 1, row.w, 1), style.edge);
    ui.textIn(&ui.fonts.legend, Rect.xywh(row.x + 4, row.y, 10, row.h), if (open) "\u{25BE}" else "\u{25B8}", if (searching) style.text_mute else style.text_dim, .left, false);
    var x = row.x + 16;
    kindIcon(ui, x, row.y + 5, it.kind, style.text_mute);
    x += 12;
    x += ui.text(&ui.fonts.legend_bold, x, row.y + 3, it.folderS(), style.text);
    if (st.kinds == 0 or @popCount(st.kinds) > 1) {
        var kb: [16]u8 = undefined;
        const ks = std.fmt.bufPrint(&kb, "  {s}S", .{KIND_CHIPS[@intFromEnum(it.kind)]}) catch "";
        if (it.kind == .preset) _ = ui.text(&ui.fonts.legend, x, row.y + 3, ks, style.text_mute);
    }
    var cb: [8]u8 = undefined;
    const cs = std.fmt.bufPrint(&cb, "{d}", .{rw.count}) catch "";
    ui.textIn(&ui.fonts.legend, row.insetXY(6, 0), cs, style.text_mute, .right, false);
}

/// The folder of the top row stays pinned; the next folder's header
/// pushes it out as it arrives.
fn stickyHeader(ui: *Ui, st: *State, well: Rect, scroll_px: i32) void {
    if (st.n_rows == 0 or scroll_px <= 0) return;
    const top: usize = @intCast(@divFloor(scroll_px, ROW_H));
    if (top >= st.n_rows) return;
    var h = top;
    while (h > 0 and !st.rows[h].header) h -= 1;
    if (!st.rows[h].header) return;
    if (h == top and @mod(scroll_px, ROW_H) == 0) return;
    var y = well.y;
    if (top + 1 < st.n_rows and st.rows[top + 1].header) {
        const next_y = well.y + @as(i32, @intCast(top + 1)) * ROW_H - scroll_px;
        y = @min(y, next_y - ROW_H);
    }
    const r = Rect.xywh(well.x, y, well.w, ROW_H);
    headerRow(ui, st, st.rows[h], r, true);
    ui.rect(Rect.xywh(r.x, r.bottom(), r.w, 1), style.edge.alpha(120));
}

/// Overlay scrollbar: thin, shown while scrolling or hovered, draggable.
fn scrollbar(ui: *Ui, st: *State, well: Rect, content_h: i32, max_scroll: f32) void {
    if (max_scroll <= 0) return;
    const in = &ui.in;
    const track = Rect.xywh(well.right() - 8, well.y, 8, well.h);
    const wid = ui.id("scrollbar");
    const b = ui.behaviorEx(wid, track, .{ .prio = 1, .focusable = false });
    const vh: f32 = @floatFromInt(well.h);
    const ch: f32 = @floatFromInt(content_h);
    const thumb_h: i32 = @max(20, @as(i32, @intFromFloat(vh * vh / ch)));
    const travel: f32 = @floatFromInt(well.h - thumb_h);
    const ty = well.y + @as(i32, @intFromFloat(@round(st.scroll / max_scroll * travel)));
    if (b.pressed) {
        const grab = ui.memo(wid, 0);
        const on_thumb = in.iy() >= ty and in.iy() < ty + thumb_h;
        grab.* = if (on_thumb) @floatFromInt(in.iy() - ty) else @floatFromInt(@divFloor(thumb_h, 2));
    }
    if (b.held) {
        const grab = ui.memo(wid, 0).*;
        const pos = (in.my - grab - @as(f32, @floatFromInt(well.y))) / @max(1, travel);
        st.scroll_to = std.math.clamp(pos, 0, 1) * max_scroll;
        st.scroll = st.scroll_to;
        st.scroll_t = in.time;
    }
    const since = in.time - st.scroll_t;
    const show = b.hover or b.held or since < 1.2;
    if (!show) return;
    if (since < 1.2) ui.animate();
    const fade: f32 = if (b.hover or b.held) 1 else @floatCast(std.math.clamp((1.2 - since) / 0.4, 0, 1));
    const w: i32 = if (b.hover or b.held) 6 else 3;
    const thumb = Rect.xywh(track.right() - w - 1, ty, w, thumb_h);
    ui.rect(thumb, style.text_dim.alpha(@intFromFloat(fade * @as(f32, if (b.held) 200 else 120))));
}

fn keys(ui: *Ui, st: *State, ev: text_field.Event, well: Rect) void {
    const in = &ui.in;
    if (menu.active() or st.dragging) return;
    const query_focus = ui.focus == query_wid;
    if (!(isListFocus(ui) or query_focus) and ev == .none) return;

    // Search field: Enter loads the first hit, Esc clears.
    if (ev == .commit) {
        if (st.cursor == null) firstItem(st);
        loadSelection(st, in.time);
        return;
    }
    if (ev == .cancel) {
        st.query.set("");
        return;
    }
    if (!query_focus and in.keyPressed(c.rl.KEY_ESCAPE)) {
        if (st.query.len > 0) st.query.set("") else st.n_sel = 0;
        return;
    }

    const rows_per_page: i32 = @max(1, @divFloor(well.h, ROW_H) - 1);
    var step: i32 = 0;
    if (in.keyPressed(c.rl.KEY_DOWN)) step = 1;
    if (in.keyPressed(c.rl.KEY_UP)) step = -1;
    if (!query_focus) {
        if (in.keyPressed(c.rl.KEY_PAGE_DOWN)) step = rows_per_page;
        if (in.keyPressed(c.rl.KEY_PAGE_UP)) step = -rows_per_page;
    }
    if (step != 0) {
        moveCursor(st, step, in.shift and !query_focus);
        autoAudition(st, in.time);
        return;
    }
    if (query_focus) return;
    if (in.keyPressed(c.rl.KEY_LEFT) or in.keyPressed(c.rl.KEY_RIGHT)) {
        const cur = st.cursor orelse return;
        const key = groupKey(&st.items[cur]);
        st.setOpen(key, in.keyPressed(c.rl.KEY_RIGHT));
        st.reveal = true;
        if (in.keyPressed(c.rl.KEY_LEFT)) {
            st.n_sel = 0;
            st.cursor = null;
        }
        return;
    }
    if (in.keyPressed(c.rl.KEY_ENTER)) loadSelection(st, in.time);
    if (in.keyPressed(c.rl.KEY_SPACE)) {
        if (st.audition != null) st.audition = null else if (st.cursor) |cur| startAudition(st, cur, in.time);
    }
    if (in.cmd and in.keyPressed(c.rl.KEY_A)) {
        st.n_sel = 0;
        for (st.rows[0..st.n_rows]) |rw| if (!rw.header and st.n_sel < MAX_SEL) {
            st.sel[st.n_sel] = rw.item;
            st.n_sel += 1;
        };
    }
}

fn firstItem(st: *State) void {
    for (st.rows[0..st.n_rows]) |rw| if (!rw.header) {
        st.selectOnly(rw.item);
        return;
    };
}

fn moveCursor(st: *State, step: i32, extend: bool) void {
    var at: i32 = -1;
    if (st.cursor) |cur| if (rowOf(st, cur)) |k| {
        at = @intCast(k);
    };
    var k: i32 = std.math.clamp(at + step, 0, @as(i32, @intCast(st.n_rows)) - 1);
    // Skip headers in the direction of travel.
    const dir: i32 = if (step < 0) -1 else 1;
    while (k >= 0 and k < st.n_rows and st.rows[@intCast(k)].header) k += dir;
    if (k < 0 or k >= st.n_rows) return;
    const item = st.rows[@intCast(k)].item;
    if (extend and st.anchor != null) {
        selectRange(st, st.anchor.?, item);
        st.cursor = item;
    } else st.selectOnly(item);
    st.reveal = true;
}

fn selectRange(st: *State, a: u16, b: u16) void {
    const ka = rowOf(st, a) orelse return st.selectOnly(b);
    const kb = rowOf(st, b) orelse return;
    st.n_sel = 0;
    for (st.rows[@min(ka, kb) .. @max(ka, kb) + 1]) |rw| if (!rw.header and st.n_sel < MAX_SEL) {
        st.sel[st.n_sel] = rw.item;
        st.n_sel += 1;
    };
}

fn contextMenu(ui: *Ui, st: *State) void {
    if (!menu.isOpen(CTX_MENU)) return;
    const cur = st.cursor orelse return;
    const it = &st.items[cur];
    const many = st.n_sel > 1;
    const verb: []const u8 = switch (it.kind) {
        .preset => "Load on Track",
        .table => "Load into Oscillator",
        .song => "Open Song",
        else => "Insert on Track",
    };
    const items = [_]menu.Item{
        .{ .label = verb, .id = 1, .shortcut = "\u{21A9}" },
        .{ .label = "Audition", .id = 2, .shortcut = "SPACE" },
        .{ .separator = true },
        .{ .label = if (it.fav) "Remove from Favorites" else "Add to Favorites", .id = 3 },
        .{ .label = "Copy Reference", .id = 4 },
        .{ .label = "Show in Finder", .id = 5, .enabled = !many },
        .{ .separator = true },
        .{ .label = "Save to Library", .id = 6, .enabled = it.source == .project },
        .{ .label = "Rename", .id = 8, .enabled = !many and (it.source == .project or it.source == .user) },
        .{ .label = "Publish\u{2026}", .id = 7, .enabled = it.shareable and it.source != .factory and it.source != .pack },
    };
    const now = ui.in.time;
    const picked = menu.pick(CTX_MENU, &items) orelse return;
    var tb: [96]u8 = undefined;
    switch (picked) {
        1 => loadSelection(st, now),
        2 => startAudition(st, cur, now),
        3 => {
            const want = !it.fav;
            for (st.sel[0..st.n_sel]) |s| st.items[s].fav = want;
        },
        4 => {
            ui.setClipboard(refPath(&tb, it));
            st.say(now, false, "COPIED  {s}", .{refPath(&tb, it)});
        },
        5 => st.say(now, false, "WOULD REVEAL  {s}", .{refPath(&tb, it)}),
        6 => st.say(now, false, "SAVED {s} TO USER:", .{upperName(&tb, it.nameS())}),
        7 => st.say(now, false, "PUBLISH ARRIVES WITH THE ONLINE REPOSITORY", .{}),
        8 => st.say(now, false, "RENAME IN PLACE (NOT IN THE PROTOTYPE)", .{}),
        else => {},
    }
}

// ── Preview ──────────────────────────────────────────────────────────

fn preview(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("preview");
    defer ui.popId();
    var body = ui.plate(r, .{});
    const head = body.cutTop(18);
    const folded = r.h <= 24;
    const cur = st.cursor orelse {
        ui.textIn(&ui.fonts.legend, head.insetXY(4, 0), "PREVIEW", style.text_dim, .left, true);
        if (!folded) ui.textIn(&ui.fonts.legend, body, "SELECT AN ITEM", style.text_mute, .center, true);
        return;
    };
    const it = &st.items[cur];

    var tb: [64]u8 = undefined;
    var hb: [96]u8 = undefined;
    const crumb = std.fmt.bufPrint(&hb, "{s} \u{25B8} {s} \u{25B8} {s}", .{ SOURCE_NAMES[@intFromEnum(it.source)], it.folderS(), upperName(&tb, it.nameS()) }) catch "";
    ui.textIn(&ui.fonts.legend, head.insetXY(4, 0), crumb, style.text_dim, .left, true);
    if (folded) return;
    if (st.n_sel > 1) {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "+{d} MORE", .{st.n_sel - 1}) catch "";
        ui.textIn(&ui.fonts.legend, head.insetXY(4, 0), s, style.accent, .right, false);
    }

    // Actions along the bottom.
    var acts = body.cutBottom(24).insetXY(4, 2);
    const playing = st.audition != null and st.audition.? == cur;
    const verb: []const u8 = switch (it.kind) {
        .preset, .table => "LOAD",
        .song => "OPEN",
        else => "INSERT",
    };
    if (ctl.button(ui, acts.cutLeft(64), "load", null, .{ .label = verb })) loadSelection(st, ui.in.time);
    _ = acts.cutLeft(3);
    var p = playing;
    if (ctl.button(ui, acts.cutLeft(28), "play", &p, .{ .kind = .latch, .glyph = .tri_right, .glyph_on = style.play })) {
        if (playing) st.audition = null else startAudition(st, cur, ui.in.time);
    }
    _ = acts.cutLeft(3);
    var fav = it.fav;
    if (ctl.button(ui, acts.cutLeft(28), "fav", &fav, .{ .kind = .latch, .label = "\u{2605}", .lit = style.led_yellow })) it.fav = fav;
    const can_publish = it.shareable and (it.source == .user or it.source == .project);
    const pub_r = acts.cutRight(72);
    if (ctl.button(ui, pub_r, "publish", null, .{ .label = "PUBLISH", .disabled = !can_publish })) st.say(ui.in.time, false, "PUBLISH ARRIVES WITH THE ONLINE REPOSITORY", .{});
    menu.tip(ui, pub_r, if (!it.shareable) "Not yours to share: the pack's license forbids it" else if (can_publish) "Share it on the online repository" else "Factory items are already everyone's");

    // Reference line (click copies).
    var refb: [96]u8 = undefined;
    const ref = refPath(&refb, it);
    const ref_r = body.cutBottom(14).insetXY(4, 0);
    const rb = ui.behaviorEx(ui.id("ref"), ref_r, .{ .focusable = false });
    var eb: [96]u8 = undefined;
    ui.textIn(&ui.fonts.legend, ref_r, ellipsizeMiddle(&eb, &ui.fonts.legend, ref, ref_r.w), if (rb.hover) style.text else style.text_mute, .left, false);
    if (rb.hover) ui.requestCursor(c.rl.MOUSE_CURSOR_POINTING_HAND, 3);
    if (rb.clicked) {
        ui.setClipboard(ref);
        st.say(ui.in.time, false, "COPIED  {s}", .{ref});
    }
    menu.tip(ui, ref_r, "Click to copy the reference");

    // Tags and license.
    var tags = body.cutBottom(18).insetXY(4, 2);
    tagChips(ui, &tags, it);

    // The picture.
    const pic = body.insetXY(4, 3);
    if (pic.h < 24) return;
    const t: f32 = if (playing) @floatCast(ui.in.time - st.aud_t0) else -1;
    switch (it.kind) {
        .preset => presetPic(ui, pic, it, t),
        .table => tablePic(ui, pic, it, t),
        .clip => clipPic(ui, pic, it, t),
        .sample => samplePic(ui, pic, it, t),
        .song => songPic(ui, pic, it, t),
    }
    if (playing) ui.animate();
}

fn tagChips(ui: *Ui, r: *Rect, it: *const Item) void {
    const tag_sets = [_][]const []const u8{
        &.{ "BASS", "ANALOG" }, &.{ "PAD", "WIDE" },      &.{ "LEAD", "BRIGHT" }, &.{ "KEYS", "VINTAGE" },
        &.{ "FX", "MOTION" },   &.{ "DRUMS", "PUNCHY" }, &.{"PLUCK"},          &.{ "ARP", "SEQ" },
    };
    const Word = struct { w: []const u8, tag: []const u8 };
    const words = [_]Word{
        .{ .w = "bass", .tag = "BASS" },   .{ .w = "sub", .tag = "BASS" },    .{ .w = "pad", .tag = "PAD" },
        .{ .w = "string", .tag = "STRINGS" }, .{ .w = "lead", .tag = "LEAD" }, .{ .w = "key", .tag = "KEYS" },
        .{ .w = "pluck", .tag = "PLUCK" }, .{ .w = "arp", .tag = "ARP" },     .{ .w = "kick", .tag = "DRUMS" },
        .{ .w = "beat", .tag = "DRUMS" },  .{ .w = "hat", .tag = "DRUMS" },   .{ .w = "drum", .tag = "DRUMS" },
        .{ .w = "vox", .tag = "VOCAL" },   .{ .w = "chord", .tag = "CHORDS" }, .{ .w = "glue", .tag = "BUS" },
        .{ .w = "sync", .tag = "SYNC" },   .{ .w = "saw", .tag = "SAW" },     .{ .w = "fm", .tag = "FM" },
    };
    var found: [2][]const u8 = undefined;
    var nf: usize = 0;
    for (words) |wd| {
        if (nf == found.len) break;
        if (std.ascii.indexOfIgnoreCase(it.nameS(), wd.w) == null) continue;
        if (nf == 1 and std.mem.eql(u8, found[0], wd.tag)) continue;
        found[nf] = wd.tag;
        nf += 1;
    }
    const tags = if (nf > 0) found[0..nf] else tag_sets[it.seed % tag_sets.len];
    const f = &ui.fonts.legend;
    for (tags) |t| {
        const w = f.measure(t) + 8;
        if (w > r.w) return;
        const cr = r.cutLeft(w);
        ui.rect(cr, style.face_lo);
        ui.textIn(f, cr, t, style.text_dim, .center, false);
        _ = r.cutLeft(3);
    }
    const lic: []const u8 = switch (it.source) {
        .pack => if (it.shareable) "CC0" else "YOURS \u{B7} NOT SHAREABLE",
        .factory => "SLAB \u{B7} CC-BY",
        else => "YOURS",
    };
    ui.textIn(f, r.*, lic, if (it.shareable) style.text_mute else style.led_red.mix(style.text_dim, 0.4), .right, false);
}

// ── Pictures (procedural, from the item's seed) ─────────────────────

fn rnd(seed: u32, i: u32) f32 {
    var x = seed ^ (i *% 0x9E3779B9);
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return @as(f32, @floatFromInt(x & 0xffff)) / 65535.0;
}

/// One cycle of a seeded spectrum at phase `ph` (0..1), `morph` across frames.
fn wave(seed: u32, ph: f32, morph: f32) f32 {
    var v: f32 = 0;
    var h: u32 = 1;
    while (h <= 7) : (h += 1) {
        const a = rnd(seed, h) * (1 - morph) + rnd(seed, h + 50) * morph;
        const hf: f32 = @floatFromInt(h);
        v += a / hf * @sin(ph * std.math.tau * hf + rnd(seed, h + 9) * 3);
    }
    return std.math.clamp(v * 0.9, -1, 1);
}

fn polyline(ui: *Ui, xs: []const f32, ys: []const f32, col: Color) void {
    var i: usize = 1;
    while (i < xs.len) : (i += 1) ui.line(xs[i - 1], ys[i - 1], xs[i], ys[i], col);
}

fn presetPic(ui: *Ui, r: Rect, it: *const Item, t: f32) void {
    const inner = ui.well(r, style.well);
    ui.clip(inner);
    defer ui.unclip();
    const n = 96;
    var xs: [n]f32 = undefined;
    var ys: [n]f32 = undefined;
    const env: f32 = if (t < 0) 0.7 else @max(0.15, @exp(-t * 0.6));
    const ph0: f32 = if (t < 0) 0 else t * 0.7;
    const mid: f32 = @floatFromInt(inner.y + @divFloor(inner.h, 2));
    const amp: f32 = @floatFromInt(@divFloor(inner.h, 2) - 4);
    for (0..n) |i| {
        const u = @as(f32, @floatFromInt(i)) / (n - 1);
        xs[i] = @as(f32, @floatFromInt(inner.x)) + u * @as(f32, @floatFromInt(inner.w - 1));
        ys[i] = mid - wave(it.seed, u * 2 + ph0, 0.3 + 0.3 * @sin(ph0)) * amp * env;
    }
    ui.rect(Rect.xywh(inner.x, @intFromFloat(mid), inner.w, 1), style.vfd.alpha(24));
    polyline(ui, &xs, &ys, style.vfd);
    var nb: [32]u8 = undefined;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}", .{upperName(&nb, it.folderS())}) catch "";
    ui.textIn(&ui.fonts.legend, inner.insetXY(4, 2).takeTop(12), s, style.vfd.alpha(160), .left, false);
}

fn tablePic(ui: *Ui, r: Rect, it: *const Item, t: f32) void {
    const inner = ui.well(r, style.well);
    ui.clip(inner);
    defer ui.unclip();
    const frames: u32 = 12;
    const n = 64;
    const dx: f32 = 3;
    const dy: f32 = @as(f32, @floatFromInt(inner.h)) / 40;
    const w: f32 = @as(f32, @floatFromInt(inner.w)) - dx * frames - 8;
    const amp: f32 = @as(f32, @floatFromInt(inner.h)) * 0.22;
    const lit: i32 = if (t < 0) -1 else @intFromFloat(@mod(t * 6, @as(f32, @floatFromInt(frames))));
    var f: u32 = frames;
    while (f > 0) {
        f -= 1;
        const ff: f32 = @floatFromInt(f);
        const x0 = @as(f32, @floatFromInt(inner.x + 4)) + ff * dx;
        const y0 = @as(f32, @floatFromInt(inner.bottom())) - amp - 6 - ff * dy * 2;
        var xs: [n]f32 = undefined;
        var ys: [n]f32 = undefined;
        for (0..n) |i| {
            const u = @as(f32, @floatFromInt(i)) / (n - 1);
            xs[i] = x0 + u * w;
            ys[i] = y0 - wave(it.seed, u, ff / (frames - 1)) * amp;
        }
        const on = @as(i32, @intCast(f)) == lit;
        const a: u8 = @intFromFloat(60 + 140 * (1 - ff / frames));
        polyline(ui, &xs, &ys, if (on) style.vfd_hi else style.vfd.alpha(a));
    }
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d} FRAMES", .{it.size}) catch "";
    ui.textIn(&ui.fonts.legend, inner.insetXY(4, 2).takeTop(12), s, style.vfd.alpha(160), .right, false);
}

fn clipPic(ui: *Ui, r: Rect, it: *const Item, t: f32) void {
    const inner = ui.well(r, style.well);
    ui.clip(inner);
    defer ui.unclip();
    const beats: i32 = @max(4, it.size);
    const bw = @divFloor(inner.w, beats);
    var b: i32 = 0;
    while (b <= beats) : (b += 1) ui.rect(Rect.xywh(inner.x + b * bw, inner.y, 1, inner.h), if (@mod(b, 4) == 0) style.grid_bar else style.grid_sub);
    const lanes: i32 = 12;
    const lh = @max(2, @divFloor(inner.h - 4, lanes));
    var i: u32 = 0;
    const steps: u32 = @intCast(beats * 2);
    while (i < steps) : (i += 1) {
        if (rnd(it.seed, i) < 0.35) continue;
        const lane: i32 = @intFromFloat(rnd(it.seed, i + 100) * (lanes - 1));
        const len: i32 = if (rnd(it.seed, i + 200) > 0.7) 2 else 1;
        const x = inner.x + @as(i32, @intCast(i)) * @divFloor(bw, 2);
        const nr = Rect.xywh(x + 1, inner.bottom() - 2 - (lane + 1) * lh, @divFloor(bw, 2) * len - 1, lh - 1);
        ui.rect(nr, style.track[@intCast(it.seed % 8)]);
    }
    if (t >= 0) {
        const beat = @mod(t * 2, @as(f32, @floatFromInt(beats)));
        ui.rect(Rect.xywh(inner.x + @as(i32, @intFromFloat(beat * @as(f32, @floatFromInt(bw)))), inner.y, 1, inner.h), style.accent);
    }
}

fn samplePic(ui: *Ui, r: Rect, it: *const Item, t: f32) void {
    const inner = ui.well(r, style.well);
    ui.clip(inner);
    defer ui.unclip();
    const mid = inner.y + @divFloor(inner.h, 2);
    const hits: u32 = @max(1, it.size);
    var x: i32 = 0;
    while (x < inner.w) : (x += 1) {
        const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(inner.w));
        const local = @mod(u * @as(f32, @floatFromInt(hits)), 1);
        const env = @exp(-local * (4 + 6 * rnd(it.seed, 3)));
        const nz = 0.55 + 0.45 * rnd(it.seed, @intCast(x));
        const h: i32 = @intFromFloat(env * nz * @as(f32, @floatFromInt(@divFloor(inner.h, 2) - 3)));
        ui.rect(Rect.xywh(inner.x + x, mid - h, 1, 2 * h + 1), style.track[@intCast((it.seed >> 3) % 8)].alpha(200));
    }
    if (t >= 0) {
        const dur: f32 = @as(f32, @floatFromInt(hits)) * 0.5;
        if (t < dur) ui.rect(Rect.xywh(inner.x + @as(i32, @intFromFloat(t / dur * @as(f32, @floatFromInt(inner.w)))), inner.y, 1, inner.h), style.accent);
    }
}

fn songPic(ui: *Ui, r: Rect, it: *const Item, t: f32) void {
    const inner = ui.well(r, style.well);
    ui.clip(inner);
    defer ui.unclip();
    const tracks: u32 = 6 + it.seed % 4;
    const th = @max(3, @divFloor(inner.h - 18, @as(i32, @intCast(tracks))));
    const bars: i32 = 48;
    const bw = @max(1, @divFloor(inner.w, bars));
    var k: u32 = 0;
    while (k < tracks) : (k += 1) {
        var b: i32 = 0;
        while (b < bars) : (b += 4) {
            if (rnd(it.seed, k * 64 + @as(u32, @intCast(b))) < 0.3) continue;
            ui.rect(Rect.xywh(inner.x + b * bw, inner.y + 2 + @as(i32, @intCast(k)) * th, bw * 4 - 1, th - 1), style.track[k % style.track.len].alpha(170));
        }
    }
    var buf: [48]u8 = undefined;
    const bpm = 96 + it.seed % 48;
    const s = std.fmt.bufPrint(&buf, "{d} BPM \u{B7} {d} TRACKS \u{B7} {d}:{d:0>2}", .{ bpm, tracks, 2 + it.seed % 3, it.seed % 60 }) catch "";
    ui.textIn(&ui.fonts.legend, Rect.xywh(inner.x + 4, inner.bottom() - 14, inner.w - 8, 12), s, style.text_dim, .left, false);
    if (t >= 0) ui.rect(Rect.xywh(inner.x + @mod(@as(i32, @intFromFloat(t * 8)), inner.w), inner.y, 1, inner.h - 16), style.accent);
}

// ── Icons ────────────────────────────────────────────────────────────

const ICONS = [_][7][]const u8{
    // preset: a knob
    .{ ".###.", "#...#", "#.#.#", "#.#.#", "#...#", ".###.", "....." },
    // table: stacked waves
    .{ ".#...", "#.#.#", "...#.", ".#...", "#.#.#", "...#.", "....." },
    // clip: notes on a roll
    .{ "##...", ".....", "..###", ".....", "#..##", ".....", "....." },
    // sample: a waveform
    .{ "..#..", ".##..", "####.", "#####", "####.", ".##..", "..#.." },
    // song: a stack of tracks
    .{ "#####", ".....", "###..", ".....", "#####", ".....", "....." },
};

fn kindIcon(ui: *Ui, x: i32, y: i32, k: Kind, col: Color) void {
    for (ICONS[@intFromEnum(k)], 0..) |row, ry| for (row, 0..) |ch, rx| {
        if (ch == '#') ui.px(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), col);
    };
}

fn sourceColor(s: Source) Color {
    return switch (s) {
        .project => style.track[4],
        .user => style.track[2],
        .factory => style.text_mute,
        .pack => style.track[6],
    };
}

/// A small borderless icon button in a list row.
fn iconButton(ui: *Ui, r: Rect, key: anytype, glyph: []const u8, on: bool, on_col: Color) bool {
    const b = ui.behaviorEx(ui.id(key), r, .{ .focusable = false, .prio = 0 });
    if (b.hover) ui.rect(r.insetXY(1, 2), style.text.alpha(20));
    ui.textIn(&ui.fonts.legend, r, glyph, if (on) on_col else if (b.hover) style.text else style.text_mute, .center, false);
    return b.clicked;
}

// ── Text helpers ─────────────────────────────────────────────────────

/// "gabriel2/fishinet" → "gabriel2 / fishinet".
fn prettyName(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (ch == '/') {
            if (n + 3 > buf.len) break;
            @memcpy(buf[n..][0..3], " / ");
            n += 3;
        } else {
            if (n + 1 > buf.len) break;
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

fn upperName(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |ch, i| buf[i] = if (ch == '_' or ch == '-') ' ' else std.ascii.toUpper(ch);
    return buf[0..n];
}

fn detail(buf: []u8, it: *const Item) []const u8 {
    return switch (it.kind) {
        .preset => "",
        .table => std.fmt.bufPrint(buf, "{d} FR", .{it.size}) catch "",
        .clip => std.fmt.bufPrint(buf, "{d} BAR", .{@max(1, it.size / 4)}) catch "",
        .sample => std.fmt.bufPrint(buf, "{d}.{d}S", .{ it.size / 2, (it.size % 2) * 5 }) catch "",
        .song => "",
    };
}

/// The reference a project would store for this item (docs/25 §Roots).
fn refPath(buf: []u8, it: *const Item) []const u8 {
    var lb: [24]u8 = undefined;
    const folder = std.ascii.lowerString(&lb, it.folderS());
    return switch (it.kind) {
        .preset => switch (it.source) {
            .factory => std.fmt.bufPrint(buf, "factory:machines/{s}/presets/{s}.preset", .{ folder, it.nameS() }),
            .user => std.fmt.bufPrint(buf, "user:Presets/{s}/{s}.preset", .{ folder, it.nameS() }),
            .project => std.fmt.bufPrint(buf, "presets/{s}/{s}.preset", .{ folder, it.nameS() }),
            .pack => std.fmt.bufPrint(buf, "lib:presets/{s}/{s}.preset", .{ folder, it.nameS() }),
        },
        .table => switch (it.source) {
            .project => std.fmt.bufPrint(buf, "tables/{s}.wav", .{it.nameS()}),
            .user => std.fmt.bufPrint(buf, "user:Wavetables/{s}.wav", .{it.nameS()}),
            else => std.fmt.bufPrint(buf, "factory:wavetables/{s}.wav", .{it.nameS()}),
        },
        .clip => std.fmt.bufPrint(buf, "{s}Clips/{s}.slabclip", .{ SOURCE_PREFIX[@intFromEnum(it.source)], it.nameS() }),
        .sample => switch (it.source) {
            .project => std.fmt.bufPrint(buf, "audio/{s}.wav", .{it.nameS()}),
            .pack => std.fmt.bufPrint(buf, "lib:{s}/{s}.wav", .{ folder, it.nameS() }),
            else => std.fmt.bufPrint(buf, "{s}Samples/{s}/{s}.wav", .{ SOURCE_PREFIX[@intFromEnum(it.source)], folder, it.nameS() }),
        },
        .song => std.fmt.bufPrint(buf, "{s}{s}/{s}.slab", .{ SOURCE_PREFIX[@intFromEnum(it.source)], folder, it.nameS() }),
    } catch it.nameS();
}

/// `s` shortened to `w` pixels by cutting its middle: paths keep their
/// root and their file name.
fn ellipsizeMiddle(buf: []u8, f: *const core.Font, s: []const u8, w: i32) []const u8 {
    if (f.measure(s) <= w or s.len < 8) return s;
    const ell = "\u{2026}";
    var keep = s.len;
    while (keep > 4) : (keep -= 1) {
        const head = keep / 3;
        const tail = keep - head;
        const out = std.fmt.bufPrint(buf, "{s}{s}{s}", .{ s[0..head], ell, s[s.len - tail ..] }) catch return s;
        if (f.measure(out) <= w) return out;
    }
    return s;
}

/// Draw `s` in `r`, the spans matching any query word in bold white.
fn highlighted(ui: *Ui, r: Rect, s: []const u8, query: []const u8, col: Color, playing: bool) void {
    var mark = [_]bool{false} ** 64;
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |w| {
        if (std.ascii.indexOfIgnoreCase(s, w)) |at| {
            for (at..@min(at + w.len, mark.len)) |i| mark[i] = true;
        }
    }
    const f = &ui.fonts.body;
    const fb = &ui.fonts.body_bold;
    ui.clip(r);
    defer ui.unclip();
    var x = r.x;
    const y = r.y + @divFloor(r.h - f.lineHeight(), 2);
    var i: usize = 0;
    while (i < s.len) {
        const m = i < mark.len and mark[i];
        var j = i;
        while (j < s.len and (j < mark.len and mark[j]) == m) j += 1;
        if (m) {
            const w = fb.measure(s[i..j]);
            ui.rect(Rect.xywh(x, y + f.lineHeight() - 2, w, 1), style.text.alpha(90));
            x += ui.text(fb, x, y, s[i..j], style.text);
        } else x += ui.text(f, x, y, s[i..j], if (playing) style.play else col);
        i = j;
    }
}

// ── Actions ──────────────────────────────────────────────────────────

fn startAudition(st: *State, item: u16, now: f64) void {
    st.audition = item;
    st.aud_t0 = now;
}

fn autoAudition(st: *State, now: f64) void {
    if (!st.auto_aud) return;
    if (st.cursor) |cur| {
        if (st.items[cur].kind == .song) return; // songs are too long to start by accident
        startAudition(st, cur, now);
    }
}

/// ↩, double-click, LOAD: the selection goes to the selected track.
fn loadSelection(st: *State, now: f64) void {
    const cur = st.cursor orelse return;
    const it = &st.items[cur];
    const t = st.arr.sel;
    switch (it.kind) {
        .preset, .table => apply(st, .{ .header = t }, now),
        .song => apply(st, .open_song, now),
        else => apply(st, .{ .lane = .{ .track = t, .bar = st.arr.tracks[t].end() } }, now),
    }
}

fn accepts(it: *const Item, d: Drop) bool {
    return switch (d) {
        .none => false,
        .lane => it.kind == .clip or it.kind == .sample or it.kind == .preset,
        .header => it.kind == .preset or it.kind == .table,
        .new_track => it.kind != .song and it.kind != .table,
        .machine => it.kind == .preset or it.kind == .table,
        .open_song => it.kind == .song,
    };
}

fn clipBars(it: *const Item) u8 {
    return switch (it.kind) {
        .clip => @max(1, it.size / 4),
        .sample => @max(1, (it.size + 3) / 4),
        else => 1,
    };
}

/// Do what a drop on `d` means, for every selected item that fits.
fn apply(st: *State, d: Drop, now: f64) void {
    const cur = st.cursor orelse return;
    const first = &st.items[cur];
    st.undo = st.arr;
    var nb: [48]u8 = undefined;
    var placed: usize = 0;
    switch (d) {
        .none => return,
        .open_song => {
            st.say(now, true, "OPENED {s}", .{upperName(&nb, first.nameS())});
            return;
        },
        .new_track => {
            if (st.arr.n >= MAX_TRACKS) {
                st.say(now, false, "THE MOCK HOLDS {d} TRACKS", .{MAX_TRACKS});
                return;
            }
            const t = &st.arr.tracks[st.arr.n];
            const machine = if (first.kind == .preset) first.folderS() else if (first.kind == .sample) "SAMPLER" else "CONCOCTION";
            var pb: [48]u8 = undefined;
            const preset = std.fmt.bufPrint(&pb, "{s} \u{B7} {s}", .{ machine, if (first.kind == .preset) upperName(&nb, first.nameS()) else "INIT" }) catch "";
            var tn: [16]u8 = undefined;
            t.* = Track.init(upperName(&tn, first.nameS()[0..@min(first.name_len, 12)]), style.track[(st.arr.n * 3 + 1) % style.track.len], preset);
            st.arr.sel = st.arr.n;
            st.arr.n += 1;
            if (first.kind != .preset) {
                var bar: u8 = 0;
                for (st.sel[0..st.n_sel]) |s| {
                    const it = &st.items[s];
                    if (!accepts(it, .{ .lane = .{ .track = 0, .bar = 0 } }) or it.kind == .preset) continue;
                    t.add(bar, clipBars(it), upperName(&nb, it.nameS()), it.kind, it.seed);
                    bar += clipBars(it);
                    placed += 1;
                }
            }
            st.say(now, true, "NEW TRACK {s}", .{t.name[0..t.name_len]});
        },
        .lane => |l| {
            const t = &st.arr.tracks[l.track];
            st.arr.sel = l.track;
            if (first.kind == .preset) return apply(st, .{ .header = l.track }, now);
            var bar = l.bar;
            for (st.sel[0..st.n_sel]) |s| {
                const it = &st.items[s];
                if (it.kind != .clip and it.kind != .sample) continue;
                if (bar >= BARS) break;
                t.add(bar, @min(clipBars(it), BARS - bar), upperName(&nb, it.nameS()), it.kind, it.seed);
                bar += clipBars(it);
                placed += 1;
            }
            if (placed == 1)
                st.say(now, true, "INSERTED {s} ON {s} AT {d}.1", .{ upperName(&nb, first.nameS()), t.name[0..t.name_len], l.bar + 1 })
            else
                st.say(now, true, "INSERTED {d} CLIPS ON {s}", .{ placed, t.name[0..t.name_len] });
        },
        .header, .machine => {
            const ti: u8 = switch (d) {
                .header => |h| h,
                else => st.arr.sel,
            };
            const t = &st.arr.tracks[ti];
            st.arr.sel = ti;
            if (first.kind == .table) {
                setStr(&t.table, &t.table_len, upperName(&nb, first.nameS()));
                st.say(now, true, "{s} TABLE \u{2192} OSC A ON {s}", .{ t.table[0..t.table_len], t.name[0..t.name_len] });
            } else {
                var pb: [48]u8 = undefined;
                const preset = std.fmt.bufPrint(&pb, "{s} \u{B7} {s}", .{ first.folderS(), upperName(&nb, first.nameS()) }) catch "";
                setStr(&t.preset, &t.preset_len, preset);
                st.say(now, true, "LOADED {s} ON {s}", .{ preset, t.name[0..t.name_len] });
            }
        },
    }
}

fn finishDrag(ui: *Ui, st: *State) void {
    const in = &ui.in;
    if (!st.dragging) {
        if (!in.down) st.press_item = null;
        return;
    }
    if (in.keyPressed(c.rl.KEY_ESCAPE)) {
        st.dragging = false;
        st.press_item = null;
        ui.active = 0;
        return;
    }
    const cur = st.cursor orelse return;
    const ok = accepts(&st.items[cur], st.drop);
    ui.requestCursor(if (ok) c.rl.MOUSE_CURSOR_DEFAULT else c.rl.MOUSE_CURSOR_NOT_ALLOWED, 9);
    ui.animate();
    if (!in.down) {
        if (ok) apply(st, st.drop, in.time);
        st.dragging = false;
        st.press_item = null;
        ui.active = 0;
    }
}

/// What's being dragged, under the pointer.
fn ghost(ui: *Ui, st: *State) void {
    if (!st.dragging) return;
    const cur = st.cursor orelse return;
    const it = &st.items[cur];
    const ok = accepts(it, st.drop);
    var nb: [48]u8 = undefined;
    const name = upperName(&nb, it.nameS());
    const f = &ui.fonts.legend;
    const w = f.measure(name) + 28 + (if (st.n_sel > 1) @as(i32, 20) else 0);
    const r = Rect.xywh(ui.in.ix() + 10, ui.in.iy() + 6, w, 18);
    if (st.n_sel > 1) {
        ui.rect(Rect.xywh(r.x + 3, r.y + 3, r.w, r.h), style.edge);
        ui.rect(Rect.xywh(r.x + 3, r.y + 3, r.w - 1, r.h - 1), style.face_lo);
    }
    ui.rect(r, style.edge);
    ui.rect(r.inset(1), if (ok) style.face_hi else style.face_lo);
    kindIcon(ui, r.x + 6, r.y + 6, it.kind, if (ok) style.text else style.text_mute);
    ui.textIn(f, Rect.xywh(r.x + 16, r.y, r.w - 16, r.h), name, if (ok) style.text else style.text_mute, .left, false);
    if (st.n_sel > 1) {
        var cb: [8]u8 = undefined;
        const cs = std.fmt.bufPrint(&cb, "{d}", .{st.n_sel}) catch "";
        const br = Rect.xywh(r.right() - 18, r.y + 3, 14, 12);
        ui.rect(br, style.accent);
        ui.textIn(f, br, cs, style.edge, .center, false);
    }
}

fn toast(ui: *Ui, area: Rect, st: *State) void {
    if (st.toast.len == 0) return;
    const age = ui.in.time - st.toast.t0;
    if (age > TOAST_S) {
        st.toast.len = 0;
        return;
    }
    ui.animate();
    const s = st.toast.text[0..st.toast.len];
    const f = &ui.fonts.legend;
    const undo_w: i32 = if (st.toast.undo) 52 else 0;
    const w = f.measure(s) + 20 + undo_w;
    // Slides up in, fades out.
    const in_k: f32 = @floatCast(std.math.clamp(age / 0.15, 0, 1));
    const out_k: f32 = @floatCast(std.math.clamp((TOAST_S - age) / 0.4, 0, 1));
    const lift: i32 = @intFromFloat((1 - in_k) * 12);
    const r = Rect.xywh(area.right() - w - 12, area.bottom() - 36 + lift, w, 24);
    const a: u8 = @intFromFloat(255 * out_k);
    ui.rect(r, style.edge.alpha(a));
    ui.rect(r.inset(1), style.face.alpha(a));
    ui.rect(Rect.xywh(r.x + 1, r.y + 1, 2, r.h - 2), style.play.alpha(a));
    ui.textIn(f, Rect.xywh(r.x + 10, r.y, r.w - 10 - undo_w, r.h), s, style.text.alpha(a), .left, false);
    if (st.toast.undo) {
        const ur = Rect.xywh(r.right() - undo_w - 2, r.y + 3, undo_w - 2, r.h - 6);
        if (ctl.button(ui, ur, "toast-undo", null, .{ .label = "UNDO" })) {
            st.arr = st.undo;
            st.toast.len = 0;
        }
        // Hovering holds the toast.
        if (r.contains(ui.in.ix(), ui.in.iy())) st.toast.t0 = ui.in.time - 0.5;
    }
}

// ── The mock arrangement ─────────────────────────────────────────────

const HEADER_W: i32 = 168;
const TRACK_H: i32 = 52;

fn arrangement(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("arr");
    defer ui.popId();
    const in = &ui.in;
    var area = r;
    // Ruler.
    var ruler = area.cutTop(18);
    _ = ui.plate(ruler.cutLeft(HEADER_W), .{});
    const ruler_in = ui.well(ruler, style.well);
    const bar_w = @divFloor(ruler_in.w, BARS);
    var b: i32 = 0;
    while (b < BARS) : (b += 1) {
        var buf: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{b + 1}) catch "";
        _ = ui.text(&ui.fonts.legend, ruler_in.x + b * bar_w + 3, ruler_in.y + 2, s, style.text_dim);
        ui.rect(Rect.xywh(ruler_in.x + b * bar_w, ruler_in.y, 1, ruler_in.h), style.grid_bar);
    }

    const dragging = st.dragging and st.cursor != null;
    const it: ?*const Item = if (dragging) &st.items[st.cursor.?] else null;
    const mx = in.ix();
    const my = in.iy();

    // Opening a song lights the whole surface.
    if (it != null and it.?.kind == .song and area.contains(mx, my)) st.drop = .open_song;

    var y = area.y;
    var t: u8 = 0;
    while (t < st.arr.n) : (t += 1) {
        const tr = &st.arr.tracks[t];
        const row = Rect.xywh(area.x, y, area.w, TRACK_H);
        y += TRACK_H;
        ui.pushId(@as(usize, t));
        defer ui.popId();
        var lane = row;
        const head = lane.cutLeft(HEADER_W);
        // Header.
        const hb = ui.behaviorEx(ui.id("head"), head, .{ .focusable = false });
        if (hb.pressed) st.arr.sel = t;
        const hin = ui.plate(head, .{});
        ui.rect(Rect.xywh(hin.x, hin.y, 3, hin.h), tr.color);
        if (st.arr.sel == t) ui.rect(Rect.xywh(hin.x + 3, hin.y, hin.w - 3, hin.h), style.accent.alpha(28));
        ui.textIn(&ui.fonts.body_bold, Rect.xywh(hin.x + 8, hin.y + 4, hin.w - 12, 16), tr.name[0..tr.name_len], style.text, .left, true);
        ui.textIn(&ui.fonts.legend, Rect.xywh(hin.x + 8, hin.y + 22, hin.w - 12, 12), tr.preset[0..tr.preset_len], style.text_dim, .left, false);
        // Lane.
        ui.surface(lane, if (@mod(t, 2) == 0) style.pane else style.pane_alt);
        b = 0;
        while (b < BARS) : (b += 1) ui.rect(Rect.xywh(lane.x + b * bar_w, lane.y, 1, lane.h), style.grid_beat);
        ui.rect(Rect.xywh(lane.x, lane.bottom() - 1, lane.w, 1), style.edge);
        ui.clip(lane);
        for (tr.clips[0..tr.n]) |cl| {
            const cr = Rect.xywh(lane.x + @as(i32, cl.start) * bar_w + 1, lane.y + 3, @as(i32, cl.len) * bar_w - 1, lane.h - 7);
            drawClip(ui, cr, tr.color, cl.name[0..cl.name_len], cl.kind, cl.seed, 200);
        }
        ui.unclip();

        // Drop targets.
        if (it) |di| if (di.kind != .song) {
            if (head.contains(mx, my)) {
                st.drop = .{ .header = t };
                const ok = accepts(di, st.drop);
                ui.rect(head, (if (ok) style.accent else style.rec).alpha(40));
                outline(ui, head, if (ok) style.accent else style.rec);
                if (ok) ui.textIn(&ui.fonts.legend, Rect.xywh(head.x, head.bottom() - 14, head.w - 6, 12), if (di.kind == .table) "LOAD TABLE" else "LOAD PRESET", style.accent, .right, false);
            } else if (lane.contains(mx, my)) {
                const bar: u8 = @intCast(std.math.clamp(@divFloor(mx - lane.x, bar_w), 0, BARS - 1));
                st.drop = .{ .lane = .{ .track = t, .bar = bar } };
                const ok = accepts(di, st.drop);
                if (ok and di.kind != .preset) {
                    // Where it lands: the clip's length, from the bar under the pointer.
                    var total: i32 = 0;
                    for (st.sel[0..st.n_sel]) |s| {
                        if (st.items[s].kind == .clip or st.items[s].kind == .sample) total += clipBars(&st.items[s]);
                    }
                    const gr = Rect.xywh(lane.x + @as(i32, bar) * bar_w + 1, lane.y + 3, @min(total, @as(i32, BARS - @as(i32, bar))) * bar_w - 1, lane.h - 7);
                    ui.rect(gr, tr.color.alpha(70));
                    outline(ui, gr, style.accent);
                    ui.rect(Rect.xywh(gr.x - 1, lane.y, 1, lane.h), style.accent);
                } else if (ok) {
                    ui.rect(lane, style.accent.alpha(24));
                    outline(ui, lane, style.accent);
                } else {
                    ui.rect(lane, style.rec.alpha(24));
                }
            }
        };
    }
    // Below the tracks: a new track.
    const rest = Rect.xywh(area.x, y, area.w, area.bottom() - y);
    ui.surface(rest, style.chassis);
    if (rest.h > 0) {
        if (it) |di| {
            if (di.kind != .song and rest.contains(mx, my)) st.drop = .new_track;
            const want = accepts(di, .new_track);
            if (want) {
                const zone = Rect.xywh(rest.x + 8, rest.y + 8, rest.w - 16, @min(rest.h - 16, 44));
                const on = std.meta.activeTag(st.drop) == .new_track;
                dashed(ui, zone, if (on) style.accent else style.text_mute);
                ui.textIn(&ui.fonts.legend, zone, "DROP HERE FOR A NEW TRACK", if (on) style.accent else style.text_mute, .center, false);
            }
        } else if (rest.h > 40) {
            ui.textIn(&ui.fonts.legend, Rect.xywh(rest.x, rest.y + 12, rest.w, 14), "DRAG PRESETS, CLIPS AND SAMPLES FROM THE BROWSER", style.text_mute, .center, false);
        }
    }
    if (std.meta.activeTag(st.drop) == .open_song) {
        ui.rect(r, style.accent.alpha(30));
        outline(ui, r, style.accent);
        ui.textIn(&ui.fonts.body_bold, r, "DROP TO OPEN THIS SONG", style.accent, .center, true);
    }
}

fn drawClip(ui: *Ui, r: Rect, col: Color, name: []const u8, kind: Kind, seed: u32, a: u8) void {
    ui.rect(r, col.mix(style.edge, 0.55).alpha(a));
    ui.rect(Rect.xywh(r.x, r.y, r.w, 12), col.alpha(a));
    ui.textIn(&ui.fonts.legend, Rect.xywh(r.x + 3, r.y, r.w - 4, 12), name, style.edge, .left, false);
    const body = Rect.xywh(r.x + 2, r.y + 14, r.w - 4, r.h - 16);
    if (body.h <= 2) return;
    if (kind == .sample) {
        var x: i32 = 0;
        const mid = body.y + @divFloor(body.h, 2);
        while (x < body.w) : (x += 1) {
            const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(1, body.w)));
            const h: i32 = @intFromFloat(@exp(-@mod(u * 4, 1) * 5) * rnd(seed, @intCast(x)) * @as(f32, @floatFromInt(@divFloor(body.h, 2))));
            ui.rect(Rect.xywh(body.x + x, mid - h, 1, 2 * h + 1), col.alpha(a));
        }
    } else {
        var i: u32 = 0;
        const steps: u32 = @intCast(@max(1, @divFloor(body.w, 6)));
        while (i < steps) : (i += 1) {
            if (rnd(seed, i) < 0.4) continue;
            const lane = rnd(seed, i + 100);
            const ny = body.y + @as(i32, @intFromFloat(lane * @as(f32, @floatFromInt(body.h - 2))));
            ui.rect(Rect.xywh(body.x + @as(i32, @intCast(i)) * 6, ny, 5, 2), col.alpha(a));
        }
    }
}

fn outline(ui: *Ui, r: Rect, col: Color) void {
    ui.rect(Rect.xywh(r.x, r.y, r.w, 1), col);
    ui.rect(Rect.xywh(r.x, r.bottom() - 1, r.w, 1), col);
    ui.rect(Rect.xywh(r.x, r.y, 1, r.h), col);
    ui.rect(Rect.xywh(r.right() - 1, r.y, 1, r.h), col);
}

fn dashed(ui: *Ui, r: Rect, col: Color) void {
    var x = r.x;
    while (x < r.right()) : (x += 6) {
        ui.rect(Rect.xywh(x, r.y, @min(3, r.right() - x), 1), col);
        ui.rect(Rect.xywh(x, r.bottom() - 1, @min(3, r.right() - x), 1), col);
    }
    var y = r.y;
    while (y < r.bottom()) : (y += 6) {
        ui.rect(Rect.xywh(r.x, y, 1, @min(3, r.bottom() - y)), col);
        ui.rect(Rect.xywh(r.right() - 1, y, 1, @min(3, r.bottom() - y)), col);
    }
}

/// The selected track's machine: a preset and a table slot, both drop targets.
fn machineStrip(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("strip");
    defer ui.popId();
    const tr = &st.arr.tracks[st.arr.sel];
    var body = r;
    ctl.titleStrip(ui, body.cutTop(22), tr.name[0..tr.name_len], tr.preset[0..tr.preset_len]);
    const plate = ui.plate(body, .{});
    var row = plate.inset(8);
    const slot = row.cutLeft(@min(row.w, 260));
    _ = ui.engraved(&ui.fonts.legend, slot.x, slot.y, "OSC A TABLE", style.text_dim);
    const well_r = Rect.xywh(slot.x, slot.y + 14, slot.w, slot.h - 14);
    const inner = ui.well(well_r, style.well);
    ui.clip(inner);
    const n = 48;
    var xs: [n]f32 = undefined;
    var ys: [n]f32 = undefined;
    const seed: u32 = @truncate(std.hash.Wyhash.hash(0, tr.table[0..tr.table_len]));
    const mid: f32 = @floatFromInt(inner.y + @divFloor(inner.h, 2));
    for (0..n) |i| {
        const u = @as(f32, @floatFromInt(i)) / (n - 1);
        xs[i] = @as(f32, @floatFromInt(inner.x + 70)) + u * @as(f32, @floatFromInt(inner.w - 76));
        ys[i] = mid - wave(seed, u, 0.2) * @as(f32, @floatFromInt(@divFloor(inner.h, 2) - 4));
    }
    polyline(ui, &xs, &ys, style.vfd);
    ctl.vfdText(ui, inner.x + 4, inner.y + 4, tr.table[0..tr.table_len], style.vfd);
    ui.unclip();

    var hint = row;
    _ = hint.cutLeft(12);
    ui.textIn(&ui.fonts.legend, hint.takeTop(14), "DROP A PRESET HERE TO LOAD IT, OR A WAVETABLE ON THE TABLE", style.text_mute, .left, false);

    if (st.dragging) if (st.cursor) |cur| {
        const it = &st.items[cur];
        if (r.contains(ui.in.ix(), ui.in.iy())) {
            st.drop = .machine;
            const ok = accepts(it, .machine);
            const target = if (it.kind == .table) well_r else r;
            ui.rect(target, (if (ok) style.accent else style.rec).alpha(30));
            outline(ui, target, if (ok) style.accent else style.rec);
        }
    };
}

// ── Packs and online ─────────────────────────────────────────────────

fn packsView(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("packs");
    defer ui.popId();
    const area = ui.well(r, style.pane);
    var col = area.inset(6);
    ui.textIn(&ui.fonts.legend, col.cutTop(14), "SAMPLES TOO BIG TO SHIP, OR YOURS ALONE", style.text_mute, .left, false);
    _ = col.cutTop(4);
    const dt = ui.in.dt;
    for (&st.packs, 0..) |*p, i| {
        const h: i32 = switch (p.state) {
            .supply => 138,
            .instructions => 92,
            else => 74,
        };
        if (col.h < h) break;
        ui.pushId(i);
        defer ui.popId();
        packCard(ui, col.cutTop(h), p, st, dt);
        _ = col.cutTop(6);
    }
}

fn packCard(ui: *Ui, r: Rect, p: *Pack, st: *State, dt: f32) void {
    var body = ui.plate(r, .{ .outline = .all, .chamfer = 2 }).insetXY(6, 4);
    const f = &ui.fonts.legend;
    var top = body.cutTop(18);
    const Look = struct { col: Color, status: []const u8 };
    const look: Look = switch (p.state) {
        .available => .{ .col = style.led_blue, .status = "AVAILABLE" },
        .downloading => .{ .col = style.accent, .status = "DOWNLOADING" },
        .installed => .{ .col = style.led_green, .status = "INSTALLED" },
        .supply => .{ .col = style.led_yellow, .status = "NEEDS YOUR FILES" },
        .instructions => .{ .col = style.text_dim, .status = "BUY ELSEWHERE" },
    };
    const led_col = look.col;
    const status = look.status;
    ctl.led(ui, top.x, top.y + 6, .round5, if (p.state == .downloading) .blink else .on, led_col);
    _ = top.cutLeft(10);
    ui.textIn(&ui.fonts.body_bold, top, p.name, style.text, .left, true);
    var meta_buf: [64]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{s}  \u{B7}  {s}{s}{s}", .{ status, p.license, if (p.size.len > 0) "  \u{B7}  " else "", p.size }) catch "";
    ui.textIn(f, body.cutTop(14), meta, style.text_dim, .left, false);
    _ = body.cutTop(4);

    var acts = body.cutBottom(20);
    switch (p.state) {
        .available => {
            ui.textIn(f, body.cutTop(13), "41 SAMPLER INSTRUMENTS, ORCHESTRA TO FOLK", style.text_mute, .left, false);
            if (ctl.button(ui, acts.cutLeft(108), "get", null, .{ .label = "DOWNLOAD 6.1 GB" })) {
                p.state = .downloading;
                p.progress = 0;
            }
        },
        .downloading => {
            p.progress += dt / 6;
            ui.animate();
            if (p.progress >= 1) {
                p.state = .installed;
                p.size = "6.1 GB";
                st.say(ui.in.time, false, "VCSL INSTALLED \u{B7} 41 SAMPLER PRESETS ADDED", .{});
            }
            if (ctl.button(ui, acts.cutRight(64), "cancel", null, .{ .label = "CANCEL" })) p.state = .available;
            _ = acts.cutRight(6);
            const bar = ui.well(acts.insetXY(0, 5), style.well);
            ui.rect(Rect.xywh(bar.x, bar.y, @intFromFloat(@as(f32, @floatFromInt(bar.w)) * p.progress), bar.h), style.accent);
            var pb: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&pb, "{d:.1} / 6.1 GB", .{p.progress * 6.1}) catch "";
            ui.textIn(f, body.cutBottom(14), s, style.text_dim, .right, false);
        },
        .installed => {
            if (ctl.button(ui, acts.cutLeft(64), "reveal", null, .{ .label = "REVEAL" })) st.say(ui.in.time, false, "WOULD OPEN LIBRARY/{s}", .{p.id});
            _ = acts.cutLeft(4);
            if (ctl.button(ui, acts.cutLeft(64), "remove", null, .{ .label = "REMOVE" })) st.say(ui.in.time, false, "REMOVE ASKS FIRST (NOT IN THE PROTOTYPE)", .{});
        },
        .supply => {
            ui.textIn(f, body.cutTop(13), "COPY YOUR DISK IMAGES INTO ITS FOLDER.", style.text_dim, .left, false);
            _ = body.cutTop(3);
            expectRow(ui, body.cutTop(14), "IIX V1.4 LIBRARY  (*.VC)", 412);
            expectRow(ui, body.cutTop(14), "SERIES II WAV DUMPS  (*.WAV)", 0);
            _ = body.cutTop(4);
            const zone = body.cutTop(@min(body.h, 22));
            dashed(ui, zone, style.text_mute);
            ui.textIn(f, zone, "OR DROP A FOLDER OR ZIP ON THIS CARD", style.text_mute, .center, false);
            if (ctl.button(ui, acts.cutLeft(96), "folder", null, .{ .label = "SHOW FOLDER" })) st.say(ui.in.time, false, "WOULD OPEN LIBRARY/CMI/_SOURCES", .{});
            ui.textIn(f, acts.insetXY(8, 0), "IMPORTS ONCE FOUND", style.text_mute, .left, false);
        },
        .instructions => {
            ui.textIn(f, body.cutTop(13), "BUY IT FROM THE MAKER, THEN BRING THE FILES.", style.text_dim, .left, false);
            if (ctl.button(ui, acts.cutLeft(96), "link", null, .{ .label = "OPEN LINK" })) st.say(ui.in.time, false, "WOULD OPEN THE MAKER'S PAGE", .{});
            _ = acts.cutLeft(4);
            if (ctl.button(ui, acts.cutLeft(120), "have", null, .{ .label = "I HAVE THE FILES" })) p.state = .supply;
        },
    }
}

fn expectRow(ui: *Ui, r: Rect, label: []const u8, found: u32) void {
    const f = &ui.fonts.legend;
    var buf: [24]u8 = undefined;
    const ok = found > 0;
    ui.textIn(f, Rect.xywh(r.x, r.y, 12, r.h), if (ok) "\u{2713}" else "\u{2013}", if (ok) style.play else style.text_mute, .left, false);
    ui.textIn(f, Rect.xywh(r.x + 12, r.y, r.w - 12, r.h), label, style.text_dim, .left, false);
    const s = if (ok) std.fmt.bufPrint(&buf, "{d} FOUND", .{found}) catch "" else "NONE YET";
    ui.textIn(f, r, s, if (ok) style.play else style.text_mute, .right, false);
}

fn onlineView(ui: *Ui, r: Rect, st: *State) void {
    _ = st;
    const area = ui.well(r, style.pane);
    const mid = Rect.xywh(area.x, area.y + @divFloor(area.h, 2) - 40, area.w, 16);
    ui.textIn(&ui.fonts.body_bold, mid, "THE ONLINE REPOSITORY", style.text_dim, .center, true);
    const lines = [_][]const u8{
        "SEARCH HERE WILL REACH SHARED PRESETS,",
        "TABLES, CLIPS AND SONGS. DRAG ONE IN AND IT",
        "DOWNLOADS INTO CACHE/, CHECKED BY ITS HASH.",
        "",
        "ARRIVES IN PHASE 7 (DOCS/25).",
    };
    var y = mid.bottom() + 8;
    for (lines) |l| {
        ui.textIn(&ui.fonts.legend, Rect.xywh(area.x, y, area.w, 12), l, style.text_mute, .center, false);
        y += 13;
    }
}

test "browser search matches name, folder or kind" {
    const it = makeItem(.preset, .factory, "concoction", "crisp-saw-bass", 0);
    try std.testing.expect(matches(&it, "conc BASS"));
    try std.testing.expect(matches(&it, "preset saw"));
    try std.testing.expect(!matches(&it, "pad"));
    var b: [96]u8 = undefined;
    try std.testing.expectEqualStrings("factory:machines/concoction/presets/crisp-saw-bass.preset", refPath(&b, &it));
}
