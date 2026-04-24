//! Registry of fy machines.  Each entry owns its own FyHost so word
//! names (phase-cell, gain-cell, …) don't alias across machines.

const std = @import("std");
const machine = @import("machine.zig");
const fy_host_mod = @import("fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const fy_machine_mod = @import("machines/fy_machine.zig");
const FyMachine = fy_machine_mod.FyMachine;

pub const MAX_MACHINES = 8;
pub const MAX_NAME = 32;

pub const Entry = struct {
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    host: *FyHost,         // heap-allocated, owned by this entry
    fy_machine: FyMachine, // references host

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn machineInterface(self: *Entry) machine.Machine {
        return self.fy_machine.machineInterface();
    }
};

pub const Registry = struct {
    entries: [MAX_MACHINES]Entry = undefined,
    count: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries[0..self.count]) |*e| {
            e.host.deinit();
            self.alloc.destroy(e.host);
        }
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
        if (self.count >= MAX_MACHINES) return error.RegistryFull;

        const host = try self.alloc.create(FyHost);
        errdefer self.alloc.destroy(host);
        host.* = FyHost.init(self.alloc);
        errdefer host.deinit();

        try host.registerSlabBuiltins();
        try host.compileFile(path);

        const audio_cb = try host.createAudioCallback(audio_word);
        const ui_cb = try host.createAudioCallback(ui_word);

        var e = Entry{
            .host = host,
            .fy_machine = FyMachine.init(host, display_name, audio_cb, ui_cb),
        };
        e.fy_machine.panel_w = panel_w;
        const n = @min(display_name.len, MAX_NAME);
        @memcpy(e.name[0..n], display_name[0..n]);
        e.name_len = @intCast(n);

        self.entries[self.count] = e;
        self.count += 1;
    }
};
