//! Registry of fy machines.  Each entry owns its own FyHost so word
//! names (phase-cell, gain-cell, …) don't alias across machines.

const std = @import("std");
const Fy = @import("fy").Fy;
const machine = @import("machine.zig");
const fy_host_mod = @import("fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const fy_machine_mod = @import("machines/fy_machine.zig");
const FyMachine = fy_machine_mod.FyMachine;
const poly_mod = @import("machines/poly.zig");
const fy_raw_machine_mod = @import("machines/fy_raw_machine.zig");
const machine_desc = @import("machine_desc.zig");

test {
    _ = fy_raw_machine_mod.FyRawMachine;
    _ = machine_desc;
    _ = @import("presets.zig");
    _ = @import("ms20_svf_test.zig");
}

// Soft cap used to size UI-side menu arrays; the registry itself is a
// heap slice and grows by doubling.
pub const MAX_MACHINES = 64;
pub const MAX_NAME = 32;
pub const MAX_PATH = 256;
pub const MAX_WORD = 64;

const EntryKind = enum {
    callback,
    raw_dsp2,
};

const RawMachine = extern struct {
    audio: Fy.Value,
    ui: Fy.Value,
    state_size: u32,
    params_size: u32,
    in_notes: u8,
    out_notes: u8,
    in_audio: u8,
    out_audio: u8,
    _pad: [4]u8,
};

pub const Entry = struct {
    kind: EntryKind = .callback,
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    path: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: u16 = 0,
    audio_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    audio_word_len: u8 = 0,
    ui_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    ui_word_len: u8 = 0,
    raw_mode: fy_raw_machine_mod.Mode = .voice_sample,
    raw_state_size: usize = 0,
    panel_w: f32 = 0,
    params_size: usize = 0,
    in_notes: bool = false,
    out_notes: bool = false,
    in_audio: bool = false,
    out_audio: bool = false,
    host: ?*FyHost = null, // heap-allocated, owned by this entry
    fy_machine: ?FyMachine = null, // references host

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn nameZ(self: *const Entry) [*:0]const u8 {
        return @ptrCast(&self.name[0]);
    }

    pub fn machineInterface(self: *Entry) machine.Machine {
        return self.fy_machine.?.machineInterface();
    }

    pub fn pathSlice(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn audioWordSlice(self: *const Entry) []const u8 {
        return self.audio_word[0..self.audio_word_len];
    }

    pub fn uiWordSlice(self: *const Entry) []const u8 {
        return self.ui_word[0..self.ui_word_len];
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
        if (e.kind == .raw_dsp2) {
            const raw = try fy_raw_machine_mod.FyRawMachine.create(self.alloc, e.pathSlice());
            return raw.machineInterface();
        }

        const host = try self.alloc.create(FyHost);
        errdefer self.alloc.destroy(host);
        host.* = FyHost.init(self.alloc);
        errdefer host.deinit();

        try host.registerSlabBuiltins();
        try host.compileFile(e.pathSlice());

        const audio_cb = try host.createAudioCallback(e.audioWordSlice());
        const ui_cb = try host.createAudioCallback(e.uiWordSlice());
        const reset_cb = tryOptionalResetCallback(host, e.audioWordSlice());

        const inst = try self.alloc.create(FyMachine);
        errdefer self.alloc.destroy(inst);
        inst.* = FyMachine.init(host, e.nameSlice(), audio_cb, ui_cb, reset_cb, e.params_size);
        inst.panel_w = e.panel_w;
        return inst.machineInterface();
    }

    pub fn instantiateWithPolyphony(self: *Registry, idx: usize, voices: u8) !machine.Machine {
        if (voices <= 1) return self.instantiate(idx);
        if (idx >= self.count) return error.InvalidMachineIndex;

        const voice_count = @min(voices, poly_mod.MAX_VOICES);
        const e = &self.entries[idx];
        const poly = try self.alloc.create(poly_mod.PolyMachine);
        errdefer self.alloc.destroy(poly);
        poly.* = poly_mod.PolyMachine.init(e.nameSlice(), voice_count);
        poly.panel_w = e.panel_w;

        var made: usize = 0;
        errdefer {
            for (0..made) |vi| {
                if (poly.voices[vi].deinit) |deinit_fn| {
                    deinit_fn(poly.voices[vi].state, self.alloc);
                }
            }
        }

        while (made < voice_count) : (made += 1) {
            poly.voices[made] = try self.instantiate(idx);
        }
        return poly.machineInterface();
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries[0..self.count]) |*e| {
            if (e.host) |host| {
                host.deinit();
                self.alloc.destroy(host);
            }
        }
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

        var e = Entry{
            .kind = .raw_dsp2,
            .raw_mode = desc.mode,
            .raw_state_size = desc.state_size,
            .params_size = desc.params_size,
            .panel_w = desc.panel_w,
            .in_notes = desc.mode == .voice_sample,
            .in_audio = desc.mode == .effect_sample or desc.mode == .effect_block,
            .out_audio = true,
        };
        try copyEntryString(e.name[0..], &e.name_len, desc.nameSlice());
        try copyEntryString16(e.path[0..], &e.path_len, path);

        self.entries[self.count] = e;
        self.count += 1;
    }

    /// Load a fy machine file into its own Fy instance and register it.
    pub fn load(
        self: *Registry,
        display_name: []const u8,
        path: []const u8,
        audio_word: []const u8,
        ui_word: []const u8,
        panel_w: f32,
    ) !void {
        try self.ensureRoom();

        const host = try self.alloc.create(FyHost);
        errdefer self.alloc.destroy(host);
        host.* = FyHost.init(self.alloc);
        errdefer host.deinit();

        try host.registerSlabBuiltins();
        try host.compileFile(path);

        const audio_cb = try host.createAudioCallback(audio_word);
        const ui_cb = try host.createAudioCallback(ui_word);
        const reset_cb = tryOptionalResetCallback(host, audio_word);
        const manifest_val = try host.callWord("manifest");
        const raw_ptr: usize = @intCast(@as(u64, @bitCast(manifest_val)) >> 2);
        const raw: *const RawMachine = @ptrFromInt(raw_ptr);
        const params_size: usize = @intCast(raw.params_size >> 2);

        var e = Entry{
            .kind = .callback,
            .host = host,
            .fy_machine = FyMachine.init(host, display_name, audio_cb, ui_cb, reset_cb, 0),
            .panel_w = panel_w,
            .params_size = params_size,
            .in_notes = raw.in_notes != 0,
            .out_notes = raw.out_notes != 0,
            .in_audio = raw.in_audio != 0,
            .out_audio = raw.out_audio != 0,
        };
        e.fy_machine.?.panel_w = panel_w;
        const n = @min(display_name.len, MAX_NAME);
        @memcpy(e.name[0..n], display_name[0..n]);
        e.name_len = @intCast(n);
        const path_n = @min(path.len, MAX_PATH);
        @memcpy(e.path[0..path_n], path[0..path_n]);
        e.path_len = @intCast(path_n);
        const audio_n = @min(audio_word.len, MAX_WORD);
        @memcpy(e.audio_word[0..audio_n], audio_word[0..audio_n]);
        e.audio_word_len = @intCast(audio_n);
        const ui_n = @min(ui_word.len, MAX_WORD);
        @memcpy(e.ui_word[0..ui_n], ui_word[0..ui_n]);
        e.ui_word_len = @intCast(ui_n);

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
    try std.testing.expectEqualStrings("raw-ms20", e.nameSlice());
    try std.testing.expectEqualStrings("machines/ms20/ms20.fy", e.pathSlice());
    try std.testing.expect(e.in_notes);
    try std.testing.expect(!e.in_audio);
    try std.testing.expectEqual(@as(usize, 144), e.raw_state_size);
    try std.testing.expectEqual(@as(usize, 360), e.params_size);
    try std.testing.expectEqual(@as(f32, 420.0), e.panel_w);
}

fn tryOptionalResetCallback(host: *FyHost, audio_word: []const u8) ?*const fn () callconv(.c) void {
    const reset_word =
        if (std.mem.eql(u8, audio_word, "mono1-audio"))
            "mono1-reset"
        else if (std.mem.eql(u8, audio_word, "chorus1-audio"))
            "chorus1-reset"
        else if (std.mem.eql(u8, audio_word, "comp1-audio"))
            "comp1-reset"
        else if (std.mem.eql(u8, audio_word, "fm1-audio"))
            "fm1-reset"
        else if (std.mem.eql(u8, audio_word, "delay1-audio"))
            "delay1-reset"
        else if (std.mem.eql(u8, audio_word, "verb1-audio"))
            "verb1-reset"
        else
            return null;
    return host.createAudioCallback(reset_word) catch null;
}
