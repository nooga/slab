//! CoreML for the extractors (docs/30 §Stems), through native_ml.m: a
//! compiled model (.mlmodelc) run on named float32 tensors. Any thread
//! but the audio thread; one thread at a time per model.

const std = @import("std");

extern fn slab_ml_load(path: [*:0]const u8, err: [*]u8, err_len: c_int) ?*anyopaque;
extern fn slab_ml_free(model: ?*anyopaque) void;
extern fn slab_ml_predict(
    model: ?*anyopaque,
    n_in: c_int,
    in_names: [*]const [*:0]const u8,
    in_data: [*]const [*]const f32,
    ranks: [*]const c_int,
    shapes: [*]const c_long,
    n_out: c_int,
    out_names: [*]const [*:0]const u8,
    out_data: [*]const [*]f32,
    out_counts: [*]const c_long,
    err: [*]u8,
    err_len: c_int,
) c_int;

pub const MAX_IO = 4;
pub const MAX_RANK = 6;

pub const Input = struct {
    name: [*:0]const u8,
    data: []const f32,
    shape: []const usize,
};

pub const Output = struct {
    name: [*:0]const u8,
    data: []f32,
};

pub const Model = struct {
    handle: *anyopaque,
    /// Why the last call failed.
    err: [256]u8 = [_]u8{0} ** 256,

    pub fn load(path: []const u8) !Model {
        var pz: [1024:0]u8 = undefined;
        if (path.len >= pz.len) return error.PathTooLong;
        @memcpy(pz[0..path.len], path);
        pz[path.len] = 0;
        var m = Model{ .handle = undefined };
        m.handle = slab_ml_load(&pz, &m.err, m.err.len) orelse {
            std.log.err("CoreML: {s}", .{m.message()});
            return error.ModelLoadFailed;
        };
        return m;
    }

    pub fn deinit(self: *Model) void {
        slab_ml_free(self.handle);
    }

    pub fn message(self: *const Model) []const u8 {
        return std.mem.sliceTo(&self.err, 0);
    }

    /// Run the model: each output's buffer must hold exactly its tensor.
    pub fn predict(self: *Model, inputs: []const Input, outputs: []const Output) !void {
        var in_names: [MAX_IO][*:0]const u8 = undefined;
        var in_data: [MAX_IO][*]const f32 = undefined;
        var ranks: [MAX_IO]c_int = undefined;
        var shapes: [MAX_IO * MAX_RANK]c_long = undefined;
        var at: usize = 0;
        for (inputs, 0..) |in, i| {
            var count: usize = 1;
            for (in.shape) |d| count *= d;
            if (count != in.data.len) return error.ShapeMismatch;
            in_names[i] = in.name;
            in_data[i] = in.data.ptr;
            ranks[i] = @intCast(in.shape.len);
            for (in.shape) |d| {
                shapes[at] = @intCast(d);
                at += 1;
            }
        }
        var out_names: [MAX_IO][*:0]const u8 = undefined;
        var out_data: [MAX_IO][*]f32 = undefined;
        var out_counts: [MAX_IO]c_long = undefined;
        for (outputs, 0..) |o, i| {
            out_names[i] = o.name;
            out_data[i] = o.data.ptr;
            out_counts[i] = @intCast(o.data.len);
        }
        if (slab_ml_predict(self.handle, @intCast(inputs.len), &in_names, &in_data, &ranks, &shapes, @intCast(outputs.len), &out_names, &out_data, &out_counts, &self.err, self.err.len) != 0) {
            std.log.err("CoreML: {s}", .{self.message()});
            return error.PredictFailed;
        }
    }
};
