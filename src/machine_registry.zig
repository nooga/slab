//! Registry of fy machines. Each entry is a manifest-driven raw (DSP2)
//! machine: loadFyMachine compiles the .fy in a throwaway host to read the
//! descriptor header, and instantiate() builds a fresh FyRawMachine (with its
//! own host) per track assignment so word names don't alias across machines.

const std = @import("std");
const machine = @import("machine.zig");
const fy_host_mod = @import("fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const fy_raw_machine_mod = @import("machines/fy_raw_machine.zig");
const machine_desc = @import("machine_desc.zig");

test {
    _ = fy_raw_machine_mod.FyRawMachine;
    _ = machine_desc;
    _ = @import("presets.zig");
    _ = @import("wav.zig");
    _ = @import("keymap.zig");
    _ = @import("waveform.zig");
    _ = @import("audio_pool.zig");
    _ = @import("fm_operator_test.zig");
    _ = @import("dx7_eg_test.zig");
    _ = @import("dsp_std_test.zig");
    _ = @import("oversample_test.zig");
    _ = @import("moog_ladder_test.zig");
    _ = @import("analog_test.zig");
    _ = @import("dx7_voice_test.zig");
    _ = @import("dx7_voice_render_test.zig");
    _ = @import("dx7_algorithms.zig");
    _ = @import("fm86_voice_test.zig");
}

/// Machines the DAW registers at startup, in menu order. The bench's `--all`
/// walks the same list.
pub const builtin_machines = [_][]const u8{
    "machines/ms20/ms20.fy",
    "machines/cream/cream.fy",
    "machines/fm86/fm86.fy",
    "machines/drum2/drum2.fy",
    "machines/delay2/delay2.fy",
    "machines/verb2/verb2.fy",
    "machines/comp2/comp2.fy",
    "machines/eq2/eq2.fy",
    "machines/sat2/sat2.fy",
    "machines/era/era.fy",
    "machines/gate2/gate2.fy",
    "machines/limiter2/limiter2.fy",
    "machines/chorus2/chorus2.fy",
    "machines/juno2/juno2.fy",
    "machines/rhodes/rhodes.fy",
    "machines/funk/funk.fy",
    "machines/sampler/sampler.fy",
};

// Soft cap used to size UI-side menu arrays; the registry itself is a
// heap slice and grows by doubling.
pub const MAX_MACHINES = 64;
pub const MAX_NAME = 32;
pub const MAX_PATH = 256;

pub const Entry = struct {
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    path: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: u16 = 0,
    raw_mode: fy_raw_machine_mod.Mode = .voice_sample,
    raw_state_size: usize = 0,
    panel_w: f32 = 0,
    params_size: usize = 0,
    in_notes: bool = false,
    out_notes: bool = false,
    in_audio: bool = false,
    out_audio: bool = false,

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn nameZ(self: *const Entry) [*:0]const u8 {
        return @ptrCast(&self.name[0]);
    }

    pub fn pathSlice(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }

    /// Stable machine id = the machine's directory name (e.g.
    /// `machines/ms20/ms20.fy` → `ms20`). Independent of the cosmetic
    /// display name, unique by construction, stable across renames — the
    /// key projects and presets reference machines by.
    pub fn idSlice(self: *const Entry) []const u8 {
        const path = self.pathSlice();
        const dir = std.fs.path.dirname(path) orelse return path;
        return std.fs.path.basename(dir);
    }
};

pub const Registry = struct {
    entries: []Entry = &.{},
    cap: usize = 0,
    count: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .alloc = alloc };
    }

    // Entries are only ever referenced transiently (per frame / during a
    // load), so doubling reallocation is safe; loads happen on the UI
    // thread at startup.
    fn ensureRoom(self: *Registry) !void {
        if (self.count < self.cap) return;
        const new_cap = if (self.cap == 0) 16 else self.cap * 2;
        const new_entries = try self.alloc.alloc(Entry, new_cap);
        @memcpy(new_entries[0..self.count], self.entries[0..self.count]);
        if (self.cap != 0) self.alloc.free(self.entries);
        self.entries = new_entries;
        self.cap = new_cap;
    }

    pub fn instantiate(self: *Registry, idx: usize) !machine.Machine {
        if (idx >= self.count) return error.InvalidMachineIndex;
        const e = &self.entries[idx];
        const raw = try fy_raw_machine_mod.FyRawMachine.create(self.alloc, e.pathSlice());
        return raw.machineInterface();
    }

    /// Resolve a stable machine id (directory name) to its current index.
    pub fn findById(self: *const Registry, id: []const u8) ?usize {
        for (self.entries[0..self.count], 0..) |*e, i| {
            if (std.mem.eql(u8, e.idSlice(), id)) return i;
        }
        return null;
    }

    pub fn deinit(self: *Registry) void {
        // Raw entries hold no live host (loadFyMachine compiles in a throwaway
        // host and keeps only the descriptor header); just free the slice.
        if (self.cap != 0) self.alloc.free(self.entries);
    }

    /// Register a manifest-driven raw machine: compile its .fy file in a
    /// throwaway host, read the descriptor returned by `manifest`, and keep
    /// only the header (name, mode, sizes, ports). instantiate() re-reads
    /// the full descriptor on the instance's own host.
    pub fn loadFyMachine(self: *Registry, path: []const u8) !void {
        try self.ensureRoom();

        var host = FyHost.init(self.alloc);
        defer host.deinit();
        try host.compileFile(path);
        const desc = try machine_desc.read(&host);
        // The descriptor's derive-data is a libc-malloc'd table built by the
        // throwaway manifest; only the instance keeps it, so free it here.
        defer if (desc.derive_data != 0) std.c.free(@ptrFromInt(desc.derive_data));

        var e = Entry{
            .raw_mode = desc.mode,
            .raw_state_size = desc.state_size,
            .params_size = desc.params_size,
            .panel_w = desc.panel_w,
            .in_notes = desc.mode == .voice_sample,
            .in_audio = desc.mode == .effect_block,
            .out_audio = true,
        };
        try copyEntryString(e.name[0..], &e.name_len, desc.nameSlice());
        try copyEntryString16(e.path[0..], &e.path_len, path);

        self.entries[self.count] = e;
        self.count += 1;
    }

};

fn copyEntryString(dest: []u8, len: *u8, src: []const u8) !void {
    if (src.len > dest.len) return error.RawManifestStringTooLong;
    @memset(dest, 0);
    @memcpy(dest[0..src.len], src);
    len.* = @intCast(src.len);
}

fn copyEntryString16(dest: []u8, len: *u16, src: []const u8) !void {
    if (src.len > dest.len) return error.RawManifestStringTooLong;
    @memset(dest, 0);
    @memcpy(dest[0..src.len], src);
    len.* = @intCast(src.len);
}

test "fy manifest loads MS-20 machine entry" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.loadFyMachine("machines/ms20/ms20.fy");
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    const e = &reg.entries[0];
    try std.testing.expectEqualStrings("SM-24 Mono", e.nameSlice());
    try std.testing.expectEqualStrings("machines/ms20/ms20.fy", e.pathSlice());
    // Stable id is the directory name, independent of the display name.
    try std.testing.expectEqualStrings("ms20", e.idSlice());
    try std.testing.expectEqual(@as(?usize, 0), reg.findById("ms20"));
    try std.testing.expectEqual(@as(?usize, null), reg.findById("nope"));
    try std.testing.expect(e.in_notes);
    try std.testing.expect(!e.in_audio);
    try std.testing.expectEqual(@as(usize, 392), e.raw_state_size);
    try std.testing.expectEqual(@as(usize, 496), e.params_size);
    try std.testing.expectEqual(@as(f32, 940.0), e.panel_w);
}

test "fy manifest loads the limiter machine (kernel + meter display)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    // Compiles kernels/07-effects/limiter.fy (the dsp2 words) and reads the
    // manifest — a syntax or stack error in the kernel surfaces here.
    try reg.loadFyMachine("machines/limiter2/limiter2.fy");
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    const e = &reg.entries[0];
    try std.testing.expectEqualStrings("Limiter", e.nameSlice());
    try std.testing.expectEqualStrings("limiter2", e.idSlice());
    try std.testing.expect(e.in_audio);
    try std.testing.expect(!e.in_notes);
}

test "fy manifest loads the EQ machine (biquad kernel + response display)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    // Compiles kernels/07-effects/eq.fy (trig + pow2 + the biquad stages)
    // and reads the manifest — a stack-effect or syntax error in any
    // coefficient/tick word surfaces here.
    try reg.loadFyMachine("machines/eq2/eq2.fy");
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    const e = &reg.entries[0];
    try std.testing.expectEqualStrings("EQ", e.nameSlice());
    try std.testing.expectEqualStrings("eq2", e.idSlice());
    try std.testing.expect(e.in_audio);
    try std.testing.expect(!e.in_notes);
}

test "EQ machine instantiates (per-block callers wire up)" {
    // loadFyMachine only reads the descriptor header; instantiate() runs
    // FyRawMachine.create, which compiles every per-block caller. A caller
    // failure here once silently aborted "add effect".
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.loadFyMachine("machines/eq2/eq2.fy");
    const m = try reg.instantiate(0);
    defer if (m.deinit) |d| d(m.state, std.testing.allocator);
}

test "fy manifest loads + instantiates the saturator machine" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.loadFyMachine("machines/sat2/sat2.fy");
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    const e = &reg.entries[0];
    try std.testing.expectEqualStrings("Saturator", e.nameSlice());
    try std.testing.expectEqualStrings("sat2", e.idSlice());
    try std.testing.expect(e.in_audio);
    try std.testing.expect(!e.in_notes);
    const m = try reg.instantiate(0);
    defer if (m.deinit) |d| d(m.state, std.testing.allocator);
}

test "fy manifest loads + instantiates the era converter machine" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.loadFyMachine("machines/era/era.fy");
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    const e = &reg.entries[0];
    try std.testing.expectEqualStrings("Era", e.nameSlice());
    try std.testing.expectEqualStrings("era", e.idSlice());
    try std.testing.expect(e.in_audio);
    try std.testing.expect(!e.in_notes);
    const m = try reg.instantiate(0);
    defer if (m.deinit) |d| d(m.state, std.testing.allocator);
}

test "fy manifest loads + instantiates the gate machine" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.loadFyMachine("machines/gate2/gate2.fy");
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    const e = &reg.entries[0];
    try std.testing.expectEqualStrings("Gate", e.nameSlice());
    try std.testing.expectEqualStrings("gate2", e.idSlice());
    try std.testing.expect(e.in_audio);
    try std.testing.expect(!e.in_notes);
    const m = try reg.instantiate(0);
    defer if (m.deinit) |d| d(m.state, std.testing.allocator);
}

// Loading + instantiating compiles delay2's block-prepare, which reads
// ctx.tempo for SYNC mode; the tempo -> echo-time behavior itself is tested
// in fy_raw_machine.zig ("delay SYNC follows ctx.tempo").
test "fy manifest loads + instantiates the delay machine" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.loadFyMachine("machines/delay2/delay2.fy");
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    const e = &reg.entries[0];
    try std.testing.expectEqualStrings("Delay", e.nameSlice());
    try std.testing.expectEqualStrings("delay2", e.idSlice());
    try std.testing.expect(e.in_audio);
    try std.testing.expect(!e.in_notes);
    const m = try reg.instantiate(0);
    defer if (m.deinit) |d| d(m.state, std.testing.allocator);
}

