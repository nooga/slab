//! `slab --describe out.json`: dump every machine's controls (the builtins,
//! then the home folder's user machines) as
//! JSON — the param ids, ranges and options that projects and presets
//! reference. Read by tools/slabkit to validate generated songs, and the
//! source of the param tables in docs/19.

const std = @import("std");
const registry_mod = @import("machine_registry.zig");
const machine_desc = @import("machine_desc.zig");
const document_mod = @import("document.zig");
const FyHost = @import("fy_host.zig").FyHost;
const rack_mod = @import("machines/rack.zig");

pub fn run(alloc: std.mem.Allocator, out_path: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"schema\":1,\"machines\":[");
    var first = true;
    var user_machines: registry_mod.UserMachines = .{};
    user_machines.scan();
    var paths: [registry_mod.builtin_machines.len + registry_mod.MAX_USER_MACHINES][]const u8 = undefined;
    for (registry_mod.builtin_machines, 0..) |path, i| paths[i] = path;
    for (0..user_machines.count) |i| paths[registry_mod.builtin_machines.len + i] = user_machines.path(i);
    for (paths[0 .. registry_mod.builtin_machines.len + user_machines.count]) |path| {
        var host = FyHost.init(alloc);
        defer host.deinit();
        host.compileFile(path) catch |err| {
            std.log.err("machine {s} failed to compile: {s}", .{ path, @errorName(err) });
            continue;
        };
        const d = try alloc.create(machine_desc.Desc);
        defer alloc.destroy(d);
        d.* = try machine_desc.read(&host);
        defer if (d.derive_data != 0) std.c.free(@ptrFromInt(d.derive_data));

        if (!first) try out.append(alloc, ',');
        first = false;
        try writeMachine(alloc, &out, path, d);
    }
    // The native racks (docs/42): no fy manifest, a fixed control set.
    try writeRack(alloc, &out, rack_mod.PATH, "Rack", "instrument");
    try writeRack(alloc, &out, rack_mod.FX_PATH, "FX Rack", "effect");
    try out.appendSlice(alloc, "]}\n");
    try document_mod.writeFile(alloc, out_path, out.items);
}

fn writeMachine(alloc: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, d: *const machine_desc.Desc) !void {
    const id = std.fs.path.basename(std.fs.path.dirname(path) orelse path);
    try out.appendSlice(alloc, "\n{\"id\":");
    try document_mod.appendJsonString(alloc, out, id);
    try out.appendSlice(alloc, ",\"name\":");
    try document_mod.appendJsonString(alloc, out, d.nameSlice());
    // Relative for a builtin (to the factory root), absolute for a user
    // machine: slabkit finds presets beside it.
    try out.appendSlice(alloc, ",\"path\":");
    try document_mod.appendJsonString(alloc, out, path);
    try out.appendSlice(alloc, ",\"kind\":");
    try document_mod.appendJsonString(alloc, out, if (d.mode == .voice_sample) "instrument" else "effect");
    try fmt(alloc, out, ",\"voices\":{d},\"stereo\":{},\"note_pitch\":{},\"sidechain\":{}", .{ d.voices, d.stereo, d.note_pitch, d.sidechain });

    try out.appendSlice(alloc, ",\"note_labels\":[");
    for (d.noteLabels(), 0..) |*nl, i| {
        if (i > 0) try out.append(alloc, ',');
        try fmt(alloc, out, "{{\"pitch\":{d},\"label\":", .{nl.pitch});
        try document_mod.appendJsonString(alloc, out, nl.labelSlice());
        try out.append(alloc, '}');
    }

    try out.appendSlice(alloc, "],\"params\":[");
    for (d.controls[0..d.control_count], 0..) |*ctl, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "\n {\"id\":");
        try document_mod.appendJsonString(alloc, out, ctl.idSlice());
        try out.appendSlice(alloc, ",\"module\":");
        try document_mod.appendJsonString(alloc, out, ctl.moduleSlice());
        try out.appendSlice(alloc, ",\"label\":");
        try document_mod.appendJsonString(alloc, out, std.mem.span(ctl.labelZ()));
        // A switch is saved as its option index, so its range is 0..n-1.
        const is_switch = ctl.kind == .switch_sel;
        const lo = if (is_switch) 0 else ctl.min;
        const hi = if (is_switch) @as(f64, @floatFromInt(ctl.option_count)) - 1 else ctl.max;
        try fmt(alloc, out, ",\"type\":\"{s}\",\"min\":{d},\"max\":{d},\"default\":{d},\"curve\":\"{s}\"", .{
            switch (ctl.kind) {
                .direct_f64 => "float",
                .switch_sel => "switch",
                .int_range => "int",
            },
            lo, hi, ctl.default, @tagName(ctl.curve),
        });
        if (ctl.kind == .switch_sel) {
            // Projects store the option index; `value` is what the DSP sees.
            try out.appendSlice(alloc, ",\"options\":[");
            for (0..ctl.option_count) |o| {
                if (o > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, "{\"label\":");
                try document_mod.appendJsonString(alloc, out, std.mem.span(ctl.optionLabelZ(o)));
                try fmt(alloc, out, ",\"value\":{d}}}", .{ctl.option_values[o]});
            }
            try out.append(alloc, ']');
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
}

/// A rack's controls: macros `rk-m1`…`rk-m8` (0..1) and `rk-chain`
/// (0..127, the chain selector zones key on).
fn writeRack(alloc: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, name: []const u8, kind: []const u8) !void {
    const id = std.fs.path.basename(std.fs.path.dirname(path) orelse path);
    try out.appendSlice(alloc, ",\n{\"id\":");
    try document_mod.appendJsonString(alloc, out, id);
    try out.appendSlice(alloc, ",\"name\":");
    try document_mod.appendJsonString(alloc, out, name);
    try out.appendSlice(alloc, ",\"path\":");
    try document_mod.appendJsonString(alloc, out, path);
    try fmt(alloc, out, ",\"kind\":\"{s}\",\"native\":true,\"voices\":0,\"stereo\":true,\"note_pitch\":false,\"sidechain\":false,\"note_labels\":[],\"params\":[", .{kind});
    for (0..8) |i| try fmt(alloc, out, "\n {{\"id\":\"rk-m{d}\",\"module\":\"MACROS\",\"label\":\"MACRO {d}\",\"type\":\"float\",\"min\":0,\"max\":1,\"default\":0,\"curve\":\"linear\"}},", .{ i + 1, i + 1 });
    try out.appendSlice(alloc, "\n {\"id\":\"rk-chain\",\"module\":\"MACROS\",\"label\":\"CHAIN\",\"type\":\"int\",\"min\":0,\"max\":127,\"default\":0,\"curve\":\"linear\"}]}");
}

fn fmt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime f: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, f, args);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}
