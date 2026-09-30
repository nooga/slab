const std = @import("std");
const Asm = @import("asm.zig");
const compat = @import("compat.zig");

pub const Error = error{
    BadStackEffect,
    BadTimesCount,
    UnbalancedTimes,
    NonConstantPick,
    OutOfMemory,
    RegisterExhausted,
    StackUnderflow,
    TypeMismatch,
    UnsupportedWord,
    /// The word can't run in lane mode (Builder.emitLanes): a stack
    /// output, an f64 argument, or a store through a shared pointer.
    LaneUnsupported,
};

const Ty = enum {
    unknown,
    int,
    ptr,
    f64,
    /// All-ones or zero 64-bit pattern in a d-register (a compare result).
    mask,
};

const Op = enum {
    arg,
    int_const,
    f64_const,
    ptr_add,
    ptr_add_idx, // base ptr + floor(f64 index) * 8 — runtime element addressing
    load_f64,
    load_ptr, // load a 64-bit pointer from memory (host-injected buffer bases)
    fadd,
    fsub,
    fmul,
    fdiv,
    fmin,
    fmax,
    fabs,
    fneg,
    fsqrt,
    ffloor,
    fexp2i, // 2^floor(a), built from exponent bits
    flog2i, // floor(log2 |a|) from the exponent bits
    fmant, // |a| with the exponent set to 0: mantissa in [1, 2)
    fcmp, // mask; int_value is a Cmp
    mand,
    mor,
    mnot,
    mask_to_f, // 1.0 where set, 0.0 elsewhere
    select, // a ? b : c, a a mask
    // Lane mode only (Builder.emitLanes): every f64 is a 2 x f64 vector.
    load_lane2, // lane 0 from pointer a, lane 1 from pointer b
    load_splat, // one f64 from pointer a into both lanes
    ptr_add_idx_lane, // base a + trunc(lane int_value of f64 b) * 8
};

const Cmp = enum(i64) { lt, le, gt, ge, eq };

const Value = struct {
    op: Op,
    ty: Ty,
    a: usize = 0,
    b: usize = 0,
    c: usize = 0,
    d: usize = 0,
    e: usize = 0,
    f: usize = 0,
    arg_index: usize = 0,
    int_value: i64 = 0,
    float_value: f64 = 0,
};

const Store = struct {
    ptr: usize,
    value: usize,
    /// Lane mode: lane 1's pointer (lane 0's is `ptr`).
    ptr_b: ?usize = null,
};

/// Where an entry argument lives in lane mode: one x-register shared by
/// both lanes (a params block), or one per lane (per-channel state, io).
pub const LaneArg = union(enum) {
    uniform: u5,
    pair: [2]u5,
};

const LocalFrame = struct {
    args: [16]usize = undefined,
    len: usize = 0,
};

pub const LocalRef = struct {
    depth: usize,
    index: usize,
};

const Loc = union(enum) {
    none,
    x: u5,
    d: u5,
};

pub const ArgAbi = enum {
    tagged,
    raw,
    raw_registers,
};

const D_REGS = [_]u5{ 0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
const X_REGS = [_]u5{ 9, 10, 11, 12, 13, 14, 15, 16, 17 };
// x24 is reserved: composition wrappers stash a 4th pointer arg there
// across stage calls (x21..x23 hold args 0..2).
const RAW_X_SCRATCH_REGS = [_]u5{ 9, 10, 11, 12, 13, 14, 15, 16, 17, 19, 20, 25, 26, 27, 28 };
/// The callee-saved (AAPCS64) registers in RAW_X_SCRATCH_REGS: every raw
/// wrapper saves and restores these, or a raw body leaks its scratch values
/// into the caller's callee-saved registers.
pub const RAW_CALLEE_SAVED_X = [_]u5{ 19, 20, 25, 26, 27, 28 };
pub const RAW_X_ARG_REGS = [_]u5{ 0, 1, 2, 3, 4, 5, 6, 7 };
pub const RAW_D_ARG_REGS = [_]u5{ 8, 9, 10, 11, 12, 13, 14, 15 };

pub const Builder = struct {
    allocator: std.mem.Allocator,
    values: compat.ArrayList(Value),
    stack: compat.ArrayList(usize),
    args: compat.ArrayList(usize),
    local_frames: compat.ArrayList(LocalFrame),
    stores: compat.ArrayList(Store),
    initial_arity: usize = 0,
    /// Lane mode: f64 values are 2-lane vectors (see emitLanes).
    lanes: bool = false,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .values = compat.ArrayList(Value).init(allocator),
            .stack = compat.ArrayList(usize).init(allocator),
            .args = compat.ArrayList(usize).init(allocator),
            .local_frames = compat.ArrayList(LocalFrame).init(allocator),
            .stores = compat.ArrayList(Store).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.values.deinit();
        self.stack.deinit();
        self.args.deinit();
        self.local_frames.deinit();
        self.stores.deinit();
    }

    pub fn addNumber(self: *Builder, value: i64) Error!void {
        const id = try self.addValue(.{ .op = .int_const, .ty = .int, .int_value = value });
        try self.stack.append(id);
    }

    pub fn addFloat(self: *Builder, value: f64) Error!void {
        const id = try self.addValue(.{ .op = .f64_const, .ty = .f64, .float_value = value });
        try self.stack.append(id);
    }

    pub fn addLocalArg(self: *Builder, ref: LocalRef) Error!void {
        if (ref.depth >= self.local_frames.items.len) return Error.StackUnderflow;
        const frame_index = self.local_frames.items.len - 1 - ref.depth;
        const frame = self.local_frames.items[frame_index];
        if (ref.index >= frame.len) return Error.StackUnderflow;
        try self.stack.append(frame.args[ref.index]);
    }

    /// `| a b |` pops the top `arity` values and binds them, in order.
    pub fn beginLocalFrame(self: *Builder, arity: usize) Error!void {
        if (arity > 16) return Error.RegisterExhausted;
        if (self.stack.items.len < arity) return Error.StackUnderflow;
        var frame = LocalFrame{ .len = arity };
        const base = self.stack.items.len - arity;
        var i: usize = 0;
        while (i < arity) : (i += 1) {
            frame.args[i] = self.stack.items[base + i];
        }
        self.stack.shrinkRetainingCapacity(base);
        try self.local_frames.append(frame);
    }

    pub fn endLocalFrame(self: *Builder) Error!void {
        if (self.local_frames.items.len == 0) return Error.StackUnderflow;
        _ = self.local_frames.pop();
    }

    pub fn addWord(self: *Builder, word: []const u8) Error!void {
        if (std.mem.eql(u8, word, "dup")) {
            const a = try self.peek(0);
            try self.stack.append(a);
            return;
        }
        if (std.mem.eql(u8, word, "drop")) {
            _ = try self.pop();
            return;
        }
        if (std.mem.eql(u8, word, "drop2")) {
            _ = try self.pop();
            _ = try self.pop();
            return;
        }
        if (std.mem.eql(u8, word, "swap")) {
            if (self.stack.items.len < 2) return Error.StackUnderflow;
            const n = self.stack.items.len;
            std.mem.swap(usize, &self.stack.items[n - 1], &self.stack.items[n - 2]);
            return;
        }
        if (std.mem.eql(u8, word, "over")) {
            const a = try self.peek(1);
            try self.stack.append(a);
            return;
        }
        if (std.mem.eql(u8, word, "rot")) {
            // ( a b c -- b c a )
            if (self.stack.items.len < 3) return Error.StackUnderflow;
            const n = self.stack.items.len;
            const a = self.stack.items[n - 3];
            self.stack.items[n - 3] = self.stack.items[n - 2];
            self.stack.items[n - 2] = self.stack.items[n - 1];
            self.stack.items[n - 1] = a;
            return;
        }
        if (std.mem.eql(u8, word, "nip")) {
            if (self.stack.items.len < 2) return Error.StackUnderflow;
            const top = try self.pop();
            _ = try self.pop();
            try self.stack.append(top);
            return;
        }
        if (std.mem.eql(u8, word, "pick")) {
            const index_id = try self.pop();
            const index_value = self.values.items[index_id];
            if (index_value.op != .int_const or index_value.int_value < 0) return Error.NonConstantPick;
            const index: usize = @intCast(index_value.int_value);
            const picked = try self.peek(index);
            try self.stack.append(picked);
            return;
        }
        if (std.mem.eql(u8, word, "f@64")) {
            const ptr = try self.pop();
            try self.expectTy(ptr, .ptr);
            // Program order: a load sees this word's earlier store to the
            // same field (same root pointer + constant offset).
            if (self.findStore(ptr)) |si| {
                try self.stack.append(self.stores.items[si].value);
                return;
            }
            const id = try self.addValue(.{ .op = .load_f64, .ty = .f64, .a = ptr });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "p@64")) {
            const ptr = try self.pop();
            try self.expectTy(ptr, .ptr);
            const id = try self.addValue(.{ .op = .load_ptr, .ty = .ptr, .a = ptr });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "ptr+")) {
            const offset_id = try self.pop();
            const ptr = try self.pop();
            try self.expectTy(ptr, .ptr);
            const offset = self.values.items[offset_id];
            if (offset.op != .int_const or offset.int_value < 0) return Error.NonConstantPick;
            const id = try self.addValue(.{
                .op = .ptr_add,
                .ty = .ptr,
                .a = ptr,
                .int_value = offset.int_value,
            });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "f!64")) {
            const ptr = try self.pop();
            const value = try self.pop();
            try self.expectTy(ptr, .ptr);
            try self.expectTy(value, .f64);
            // A later store to the same field replaces the earlier one.
            if (self.findStore(ptr)) |si| {
                self.stores.items[si].value = value;
                return;
            }
            try self.stores.append(.{ .ptr = ptr, .value = value });
            return;
        }
        if (std.mem.eql(u8, word, "f@i")) {
            const idx = try self.pop();
            const base = try self.pop();
            try self.expectTy(base, .ptr);
            try self.expectTy(idx, .f64);
            const pa = try self.indexAddr(base, idx);
            if (self.findStore(pa)) |si| {
                try self.stack.append(self.stores.items[si].value);
                return;
            }
            const id = try self.addValue(.{ .op = .load_f64, .ty = .f64, .a = pa });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "f!i")) {
            const idx = try self.pop();
            const base = try self.pop();
            const v = try self.pop();
            try self.expectTy(base, .ptr);
            try self.expectTy(idx, .f64);
            try self.expectTy(v, .f64);
            const pa = try self.indexAddr(base, idx);
            if (self.findStore(pa)) |si| {
                self.stores.items[si].value = v;
                return;
            }
            try self.stores.append(.{ .ptr = pa, .value = v });
            return;
        }
        const bins = .{
            .{ "f+", Op.fadd },   .{ "f-", Op.fsub },     .{ "f*", Op.fmul },
            .{ "f/", Op.fdiv },   .{ "fmin", Op.fmin },   .{ "fmax", Op.fmax },
        };
        inline for (bins) |e| if (std.mem.eql(u8, word, e[0])) return self.floatBin(e[1]);
        const uns = .{
            .{ "fabs", Op.fabs },     .{ "fneg", Op.fneg },     .{ "fsqrt", Op.fsqrt },
            .{ "floor", Op.ffloor },  .{ "fexp2i", Op.fexp2i }, .{ "flog2i", Op.flog2i },
            .{ "fmant", Op.fmant },
        };
        inline for (uns) |e| if (std.mem.eql(u8, word, e[0])) {
            const x = try self.pop();
            try self.stack.append(try self.unary(e[1], x));
            return;
        };
        const cmps = .{
            .{ "f<", Cmp.lt }, .{ "f<=", Cmp.le }, .{ "f>", Cmp.gt }, .{ "f>=", Cmp.ge }, .{ "f=", Cmp.eq },
        };
        inline for (cmps) |e| if (std.mem.eql(u8, word, e[0])) {
            const b = try self.pop();
            const a = try self.pop();
            try self.stack.append(try self.compare(e[1], a, b));
            return;
        };
        if (std.mem.eql(u8, word, "and") or std.mem.eql(u8, word, "or")) {
            const b = try self.pop();
            const a = try self.pop();
            try self.expectTy(a, .mask);
            try self.expectTy(b, .mask);
            const op: Op = if (word[0] == 'a') .mand else .mor;
            try self.stack.append(try self.addValue(.{ .op = op, .ty = .mask, .a = a, .b = b }));
            return;
        }
        if (std.mem.eql(u8, word, "not") or std.mem.eql(u8, word, "mask>f")) {
            const a = try self.pop();
            try self.expectTy(a, .mask);
            const is_not = word[0] == 'n';
            try self.stack.append(try self.addValue(.{
                .op = if (is_not) .mnot else .mask_to_f,
                .ty = if (is_not) .mask else .f64,
                .a = a,
            }));
            return;
        }
        if (std.mem.eql(u8, word, "select")) {
            // ( m t f -- m ? t : f )
            const f = try self.pop();
            const t = try self.pop();
            const m = try self.pop();
            try self.stack.append(try self.selectValue(m, t, f));
            return;
        }
        // Sugar over the ops above.
        if (std.mem.eql(u8, word, "fsel-lt")) {
            // ( a b t f -- a < b ? t : f )
            const f = try self.pop();
            const t = try self.pop();
            const b = try self.pop();
            const a = try self.pop();
            const m = try self.compare(.lt, a, b);
            try self.stack.append(try self.selectValue(m, t, f));
            return;
        }
        if (std.mem.eql(u8, word, "fclamp")) {
            // ( x lo hi -- min(max(x, lo), hi) )
            const hi = try self.pop();
            const lo = try self.pop();
            const x = try self.pop();
            const m = try self.binValue(.fmax, x, lo);
            try self.stack.append(try self.binValue(.fmin, m, hi));
            return;
        }
        if (std.mem.eql(u8, word, "ffrac")) {
            // x - floor(x)
            const x = try self.pop();
            const fl = try self.unary(.ffloor, x);
            try self.stack.append(try self.binValue(.fsub, x, fl));
            return;
        }
        return Error.UnsupportedWord;
    }

    pub fn emit(self: *Builder, out: *compat.ArrayList(u32)) Error!void {
        return self.emitWithArgAbi(out, .tagged);
    }

    // True if the value `id` (an arg) is used as a pointer operand anywhere
    // (load_f64 / ptr_add base, or a store pointer).
    // Such an arg lives in an x-register, so its d(8+i) reg is free scratch.
    fn argUsedAsPtr(self: *const Builder, id: usize) bool {
        for (self.values.items) |v| {
            switch (v.op) {
                .load_f64, .load_ptr, .ptr_add => if (v.a == id) return true,
                .ptr_add_idx, .ptr_add_idx_lane, .load_splat => if (v.a == id) return true,
                .load_lane2 => if (v.a == id or v.b == id) return true,
                else => {},
            }
        }
        for (self.stores.items) |s| if (s.ptr == id or s.ptr_b == id) return true;
        return false;
    }

    /// Emit the word body. A body that fits in registers compiles in one
    /// plain pass. One that does not is compiled again with spilling: a dry
    /// pass records the order values are requested in, then the real pass
    /// evicts the live value whose next use is furthest away (Belady) to a
    /// stack slot, or drops it when it is cheap to recompute (a constant or
    /// an entry-stack arg).
    pub fn emitWithArgAbi(self: *Builder, out: *compat.ArrayList(u32), arg_abi: ArgAbi) Error!void {
        const start = out.items.len;
        self.emitMode(out, arg_abi, .plain, null) catch |err| {
            if (err != Error.RegisterExhausted) return err;
            out.shrinkRetainingCapacity(start);
            var trace = compat.ArrayList(usize).init(self.allocator);
            defer trace.deinit();
            var scratch = compat.ArrayList(u32).init(self.allocator);
            defer scratch.deinit();
            try self.emitMode(&scratch, arg_abi, .dry, &trace);
            try self.emitMode(out, arg_abi, .spill, &trace);
        };
    }

    /// Emit the body in lane mode: two instances of the word run at once,
    /// one per lane of every f64 register (NEON 2 x f64), each against its
    /// own pointers. `lane_args[i]` says where entry argument i is: shared
    /// or one x-register per lane. Each lane computes exactly what the
    /// scalar body computes for its pointers - the same IEEE operations in
    /// the same order - so the results are bit-identical to running the
    /// scalar body twice. The word must take pointers only, return nothing,
    /// and store only through per-lane pointers.
    pub fn emitLanes(self: *Builder, out: *compat.ArrayList(u32), lane_args: []const LaneArg) Error!void {
        if (self.stack.items.len != 0 or lane_args.len != self.initial_arity) return Error.LaneUnsupported;
        var lb = Builder.init(self.allocator);
        defer lb.deinit();
        lb.lanes = true;
        const n = self.values.items.len;
        const map0 = self.allocator.alloc(usize, n) catch return Error.OutOfMemory;
        defer self.allocator.free(map0);
        const map1 = self.allocator.alloc(usize, n) catch return Error.OutOfMemory;
        defer self.allocator.free(map1);
        // Same in both lanes: shared args, constants and what they derive.
        const uni = self.allocator.alloc(bool, n) catch return Error.OutOfMemory;
        defer self.allocator.free(uni);

        for (self.values.items, 0..) |v, i| {
            var nv = v;
            switch (v.op) {
                .arg => {
                    if (v.ty == .f64 or v.ty == .mask or v.ty == .int) return Error.LaneUnsupported;
                    switch (lane_args[v.arg_index]) {
                        .uniform => |r| {
                            map0[i] = try lb.addValue(.{ .op = .arg, .ty = .ptr, .arg_index = r });
                            map1[i] = map0[i];
                            uni[i] = true;
                        },
                        .pair => |rs| {
                            map0[i] = try lb.addValue(.{ .op = .arg, .ty = .ptr, .arg_index = rs[0] });
                            map1[i] = try lb.addValue(.{ .op = .arg, .ty = .ptr, .arg_index = rs[1] });
                            uni[i] = false;
                        },
                    }
                    continue;
                },
                .int_const, .f64_const => {
                    map0[i] = try lb.addValue(v);
                    map1[i] = map0[i];
                    uni[i] = true;
                    continue;
                },
                .ptr_add, .load_ptr => {
                    uni[i] = uni[v.a];
                    nv.a = map0[v.a];
                    map0[i] = try lb.addValue(nv);
                    if (uni[i]) {
                        map1[i] = map0[i];
                    } else {
                        nv.a = map1[v.a];
                        map1[i] = try lb.addValue(nv);
                    }
                    continue;
                },
                .ptr_add_idx => {
                    uni[i] = uni[v.a] and uni[v.b];
                    map0[i] = try lb.addValue(.{ .op = .ptr_add_idx_lane, .ty = .ptr, .a = map0[v.a], .b = map0[v.b], .int_value = 0 });
                    map1[i] = if (uni[i]) map0[i] else try lb.addValue(.{ .op = .ptr_add_idx_lane, .ty = .ptr, .a = map1[v.a], .b = map0[v.b], .int_value = 1 });
                    continue;
                },
                .load_f64 => {
                    uni[i] = uni[v.a];
                    map0[i] = if (uni[i])
                        try lb.addValue(.{ .op = .load_splat, .ty = .f64, .a = map0[v.a] })
                    else
                        try lb.addValue(.{ .op = .load_lane2, .ty = .f64, .a = map0[v.a], .b = map1[v.a] });
                    map1[i] = map0[i];
                    continue;
                },
                .fabs, .fneg, .fsqrt, .ffloor, .fexp2i, .flog2i, .fmant, .mnot, .mask_to_f => {
                    uni[i] = uni[v.a];
                    nv.a = map0[v.a];
                },
                .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcmp, .mand, .mor => {
                    uni[i] = uni[v.a] and uni[v.b];
                    nv.a = map0[v.a];
                    nv.b = map0[v.b];
                },
                .select => {
                    uni[i] = uni[v.a] and uni[v.b] and uni[v.c];
                    nv.a = map0[v.a];
                    nv.b = map0[v.b];
                    nv.c = map0[v.c];
                },
                .load_lane2, .load_splat, .ptr_add_idx_lane => return Error.LaneUnsupported,
            }
            map0[i] = try lb.addValue(nv);
            map1[i] = map0[i];
        }
        for (self.stores.items) |st| {
            // Two lanes storing to one address: which lane wins is not what
            // the scalar body run twice would leave.
            if (uni[st.ptr]) return Error.LaneUnsupported;
            try lb.stores.append(.{ .ptr = map0[st.ptr], .ptr_b = map1[st.ptr], .value = map0[st.value] });
        }

        const start = out.items.len;
        lb.emitMode(out, .raw_registers, .plain, null) catch |err| {
            if (err != Error.RegisterExhausted) return err;
            out.shrinkRetainingCapacity(start);
            var trace = compat.ArrayList(usize).init(self.allocator);
            defer trace.deinit();
            var scratch = compat.ArrayList(u32).init(self.allocator);
            defer scratch.deinit();
            try lb.emitMode(&scratch, .raw_registers, .dry, &trace);
            try lb.emitMode(out, .raw_registers, .spill, &trace);
        };
    }

    fn emitMode(self: *Builder, out: *compat.ArrayList(u32), arg_abi: ArgAbi, mode: Mode, trace: ?*compat.ArrayList(usize)) Error!void {
        const has_outputs = self.stack.items.len != 0;
        if (self.stores.items.len == 0 and !has_outputs) return Error.BadStackEffect;
        const n_values = self.values.items.len;

        const locs = self.allocator.alloc(Loc, n_values) catch return Error.OutOfMemory;
        defer self.allocator.free(locs);
        @memset(locs, .none);

        const remaining_uses = self.allocator.alloc(u32, n_values) catch return Error.OutOfMemory;
        defer self.allocator.free(remaining_uses);
        @memset(remaining_uses, 0);
        self.countUses(remaining_uses);

        const spill_slot = self.allocator.alloc(?u16, n_values) catch return Error.OutOfMemory;
        defer self.allocator.free(spill_slot);
        @memset(spill_slot, null);

        const cur_next = self.allocator.alloc(usize, n_values) catch return Error.OutOfMemory;
        defer self.allocator.free(cur_next);

        const depth = self.allocator.alloc(u32, n_values) catch return Error.OutOfMemory;
        defer self.allocator.free(depth);
        self.computeDepths(depth);
        @memset(cur_next, std.math.maxInt(usize));

        // next_pos[i]: the next trace position requesting the same value.
        var next_pos: []usize = &.{};
        defer if (next_pos.len > 0) self.allocator.free(next_pos);
        if (mode == .spill) {
            const t = trace.?.items;
            next_pos = self.allocator.alloc(usize, t.len) catch return Error.OutOfMemory;
            const last_seen = self.allocator.alloc(usize, n_values) catch return Error.OutOfMemory;
            defer self.allocator.free(last_seen);
            @memset(last_seen, std.math.maxInt(usize));
            var i = t.len;
            while (i > 0) {
                i -= 1;
                next_pos[i] = last_seen[t[i]];
                last_seen[t[i]] = i;
            }
        }

        var cg = Codegen{
            .builder = self,
            .out = out,
            .locs = locs,
            .remaining_uses = remaining_uses,
            .arg_abi = arg_abi,
            .mode = mode,
            .trace = if (mode == .dry) trace else null,
            .next_pos = next_pos,
            .cur_next = cur_next,
            .spill_slot = spill_slot,
            .depth = depth,
            .lanes = self.lanes,
        };

        // D-register pool. In raw_registers mode an f64 arg i lives in
        // RAW_D_ARG_REGS[i]=d(8+i) and must not be allocated as scratch; a
        // pointer arg lives in an x-register, so its d(8+i) is free. We free
        // d(8+i) only when arg i is provably used as a pointer (load/ptr+/store/
        // base) — conservative, so a true f64 arg is always reserved.
        {
            var n: usize = 0;
            var r: usize = 0;
            while (r < 8) : (r += 1) {
                cg.d_pool[n] = @intCast(r);
                n += 1;
            }
            r = 8;
            while (r < 16) : (r += 1) {
                const arg_i = r - 8;
                const reserved = if (arg_abi == .raw_registers)
                    (arg_i < self.initial_arity and !self.argUsedAsPtr(arg_i))
                else
                    true;
                if (!reserved) {
                    cg.d_pool[n] = @intCast(r);
                    n += 1;
                }
            }
            r = 16;
            while (r < 32) : (r += 1) {
                cg.d_pool[n] = @intCast(r);
                n += 1;
            }
            cg.d_pool_len = n;
        }

        // Stack frame: [0, stash) holds deferred stores (value, ptr) when
        // there is more than one; spill slots follow. The spill pass sizes
        // the frame once codegen is done and patches the `sub sp`.
        const spill_stores = self.stores.items.len > 1;
        // A stashed store: value, pointer (16 bytes); in lane mode the
        // 2-lane value and both lanes' pointers (32).
        const stash_stride: usize = if (self.lanes) 32 else 16;
        const stash_bytes: usize = if (spill_stores) std.mem.alignForward(usize, self.stores.items.len * stash_stride, 16) else 0;
        if (stash_bytes > 4080) return Error.RegisterExhausted;
        cg.slot_base = stash_bytes;
        const use_frame = spill_stores or mode == .spill;
        const frame_at = out.items.len;
        if (use_frame) try out.append(Asm.sub_sp_imm(@intCast(stash_bytes)));

        if (spill_stores) {
            for (self.stores.items, 0..) |store, i| {
                const mark = cg.pin_len;
                const val_reg = try cg.valueD(store.value);
                const ptr_reg = try cg.valueX(store.ptr);
                const offset: u12 = @intCast(i * stash_stride);
                if (self.lanes) {
                    const ptr_b = try cg.valueX(store.ptr_b.?);
                    try out.append(Asm.str_q_imm(val_reg, 31, offset));
                    try out.append(Asm.str_x_imm(ptr_reg, 31, offset + 16));
                    try out.append(Asm.str_x_imm(ptr_b, 31, offset + 24));
                } else {
                    try out.append(Asm.str_d_imm(val_reg, 31, offset));
                    try out.append(Asm.str_x_imm(ptr_reg, 31, offset + 8));
                }
                cg.unpinTo(mark);
                cg.consumeValue(store.value);
                cg.consumeValue(store.ptr);
                if (store.ptr_b) |pb| cg.consumeValue(pb);
            }
        }

        var output_locs: []Loc = &.{};
        defer if (output_locs.len > 0) self.allocator.free(output_locs);
        if (has_outputs) {
            // Output registers stay pinned until they are pushed.
            output_locs = self.allocator.alloc(Loc, self.stack.items.len) catch return Error.OutOfMemory;
            for (self.stack.items, 0..) |value, i| {
                const ty = self.values.items[value].ty;
                output_locs[i] = if (ty == .f64)
                    .{ .d = try cg.valueD(value) }
                else if (ty == .ptr or ty == .int)
                    .{ .x = try cg.valueX(value) }
                else
                    return Error.TypeMismatch;
            }
        }

        if (spill_stores) {
            for (self.stores.items, 0..) |_, i| {
                const val_reg = try cg.allocD();
                const ptr_reg = try cg.allocX();
                const offset: u12 = @intCast(i * stash_stride);
                if (self.lanes) {
                    try out.append(Asm.ldr_q_imm(val_reg, 31, offset));
                    try out.append(Asm.ldr_x_imm(ptr_reg, 31, offset + 16));
                    try out.append(Asm.str_d_imm(val_reg, ptr_reg, 0));
                    try out.append(Asm.ldr_x_imm(ptr_reg, 31, offset + 24));
                    try out.append(Asm.@"st1 {Vt.D}[1], [Xn]"(val_reg, ptr_reg));
                } else {
                    try out.append(Asm.ldr_d_imm(val_reg, 31, offset));
                    try out.append(Asm.ldr_x_imm(ptr_reg, 31, offset + 8));
                    try out.append(Asm.str_d_imm(val_reg, ptr_reg, 0));
                }
                cg.releaseD(val_reg);
                cg.releaseX(ptr_reg);
            }
        } else {
            for (self.stores.items) |store| {
                const mark = cg.pin_len;
                const val_reg = try cg.valueD(store.value);
                const ptr_reg = try cg.valueX(store.ptr);
                try out.append(Asm.str_d_imm(val_reg, ptr_reg, 0));
                if (store.ptr_b) |pb| {
                    const ptr_b = try cg.valueX(pb);
                    try out.append(Asm.@"st1 {Vt.D}[1], [Xn]"(val_reg, ptr_b));
                }
                cg.unpinTo(mark);
                cg.consumeValue(store.value);
                cg.consumeValue(store.ptr);
                if (store.ptr_b) |pb| cg.consumeValue(pb);
            }
        }
        if (use_frame) {
            const bytes = std.mem.alignForward(usize, cg.slot_base + @as(usize, cg.slot_count) * cg.slotSize(), 16);
            if (bytes > 4080) return Error.RegisterExhausted;
            out.items[frame_at] = Asm.sub_sp_imm(@intCast(bytes));
            try out.append(Asm.add_sp_imm(@intCast(bytes)));
        }
        if (arg_abi != .raw_registers and self.initial_arity > 0) {
            try out.append(Asm.add_imm(21, 21, @intCast(self.initial_arity * 8)));
        }
        for (output_locs) |loc| {
            switch (loc) {
                .d => |reg| {
                    try out.append(Asm.@"fmov Xd, Dn"(9, reg));
                    try out.append(Asm.@"lsr Xn, Xn, #2"(9));
                    try out.append(Asm.@"lsl Xn, Xn, #2"(9));
                    try out.append(Asm.@"add Xn, Xn, #2"(9));
                    try out.append(Asm.@".push Xn"(9));
                },
                .x => |reg| {
                    try out.append(Asm.@"lsl Xn, Xn, #2"(reg));
                    try out.append(Asm.@".push Xn"(reg));
                },
                .none => return Error.TypeMismatch,
            }
        }
        if (mode == .dry) return;
        std.debug.assert(mode != .spill or cg.tpos == next_pos.len);
    }

    pub fn outputCount(self: *const Builder) usize {
        return self.stack.items.len;
    }

    fn addValue(self: *Builder, value: Value) Error!usize {
        const id = self.values.items.len;
        try self.values.append(value);
        return id;
    }

    fn countUses(self: *const Builder, remaining_uses: []u32) void {
        for (self.values.items) |value| {
            switch (value.op) {
                .arg, .int_const, .f64_const => {},
                .ptr_add, .load_f64, .load_ptr, .fabs, .fneg, .fsqrt, .ffloor, .fexp2i, .flog2i, .fmant, .mnot, .mask_to_f, .load_splat => remaining_uses[value.a] += 1,
                .ptr_add_idx, .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcmp, .mand, .mor, .load_lane2, .ptr_add_idx_lane => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                },
                .select => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                    remaining_uses[value.c] += 1;
                },
            }
        }
        for (self.stores.items) |store| {
            remaining_uses[store.ptr] += 1;
            remaining_uses[store.value] += 1;
            if (store.ptr_b) |pb| remaining_uses[pb] += 1;
        }
        for (self.stack.items) |value| remaining_uses[value] += 1;
    }

    /// Longest operand chain under each value (values are in topological
    /// order: operands always have smaller ids). The codegen evaluates the
    /// deeper operand first, so a long chain, like an unrolled `times`
    /// accumulator, holds no registers of the levels above it.
    fn computeDepths(self: *const Builder, depth: []u32) void {
        for (self.values.items, 0..) |v, i| {
            const ops: [3]?usize = switch (v.op) {
                .arg, .int_const, .f64_const => .{ null, null, null },
                .ptr_add, .load_f64, .load_ptr, .fabs, .fneg, .fsqrt, .ffloor, .fexp2i, .flog2i, .fmant, .mnot, .mask_to_f, .load_splat => .{ v.a, null, null },
                .ptr_add_idx, .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcmp, .mand, .mor, .load_lane2, .ptr_add_idx_lane => .{ v.a, v.b, null },
                .select => .{ v.a, v.b, v.c },
            };
            var d: u32 = 0;
            for (ops) |o| if (o) |id| {
                d = @max(d, depth[id]);
            };
            depth[i] = d + 1;
        }
    }

    const AddrKey = struct { root: usize, off: i64 };

    /// Canonical address of a pointer value: its root (an arg or a loaded
    /// pointer) plus the constant offset of any ptr+ chain on top.
    fn addrKey(self: *const Builder, id: usize) AddrKey {
        var cur = id;
        var off: i64 = 0;
        while (self.values.items[cur].op == .ptr_add) {
            off += self.values.items[cur].int_value;
            cur = self.values.items[cur].a;
        }
        return .{ .root = cur, .off = off };
    }

    /// The pending store to the same canonical address, if any. Indexed
    /// stores (f!i) have no constant address and never match.
    fn findStore(self: *const Builder, ptr: usize) ?usize {
        const k = self.addrKey(ptr);
        if (self.values.items[k.root].op == .ptr_add_idx) return null;
        for (self.stores.items, 0..) |st, i| {
            const sk = self.addrKey(st.ptr);
            if (sk.root == k.root and sk.off == k.off) return i;
        }
        return null;
    }

    fn pop(self: *Builder) Error!usize {
        if (self.stack.items.len == 0) return Error.StackUnderflow;
        return self.stack.pop().?;
    }

    fn peek(self: *Builder, index_from_top: usize) Error!usize {
        if (index_from_top >= self.stack.items.len) return Error.StackUnderflow;
        return self.stack.items[self.stack.items.len - 1 - index_from_top];
    }

    fn expectTy(self: *Builder, id: usize, ty: Ty) Error!void {
        const old = self.values.items[id].ty;
        if (old == .unknown) {
            self.values.items[id].ty = ty;
            return;
        }
        // An integer literal used as a pointer is an absolute address (a
        // `table:`).
        if (old == .int and ty == .ptr and self.values.items[id].op == .int_const) {
            self.values.items[id].ty = .ptr;
            return;
        }
        if (old != ty) return Error.TypeMismatch;
    }

    /// The count for `times`: an integer constant (or an integral f64
    /// constant) in 0..MAX_TIMES, popped.
    fn popCount(self: *Builder) Error!usize {
        const id = try self.pop();
        const v = self.values.items[id];
        const n: f64 = switch (v.op) {
            .int_const => @floatFromInt(v.int_value),
            .f64_const => v.float_value,
            else => return Error.BadTimesCount,
        };
        if (!(n >= 0 and n <= MAX_TIMES) or @floor(n) != n) return Error.BadTimesCount;
        return @intFromFloat(n);
    }

    fn constF64(self: *const Builder, id: usize) ?f64 {
        const v = self.values.items[id];
        return if (v.op == .f64_const) v.float_value else null;
    }

    fn floatBin(self: *Builder, op: Op) Error!void {
        const b = try self.pop();
        const a = try self.pop();
        try self.stack.append(try self.binValue(op, a, b));
    }

    fn binValue(self: *Builder, op: Op, a: usize, b: usize) Error!usize {
        try self.expectTy(a, .f64);
        try self.expectTy(b, .f64);
        // Constant operands fold, so an unrolled `times` counter stays a
        // literal in every copy. IEEE results are the same as at run time.
        if (self.constF64(a)) |x| if (self.constF64(b)) |y| {
            const r: ?f64 = switch (op) {
                .fadd => x + y,
                .fsub => x - y,
                .fmul => x * y,
                .fdiv => x / y,
                else => null,
            };
            if (r) |val| return self.addValue(.{ .op = .f64_const, .ty = .f64, .float_value = val });
        };
        return self.addValue(.{ .op = op, .ty = .f64, .a = a, .b = b });
    }

    /// base + floor(idx) * 8. A constant index becomes a constant offset,
    /// so the access is a plain field: loads see earlier stores to it.
    fn indexAddr(self: *Builder, base: usize, idx: usize) Error!usize {
        if (self.constF64(idx)) |x| {
            const e = @floor(x);
            if (e >= 0 and e < 1 << 21) return self.addValue(.{
                .op = .ptr_add,
                .ty = .ptr,
                .a = base,
                .int_value = @as(i64, @intFromFloat(e)) * 8,
            });
        }
        return self.addValue(.{ .op = .ptr_add_idx, .ty = .ptr, .a = base, .b = idx });
    }

    fn unary(self: *Builder, op: Op, a: usize) Error!usize {
        try self.expectTy(a, .f64);
        return self.addValue(.{ .op = op, .ty = .f64, .a = a });
    }

    fn compare(self: *Builder, cmp: Cmp, a: usize, b: usize) Error!usize {
        try self.expectTy(a, .f64);
        try self.expectTy(b, .f64);
        return self.addValue(.{ .op = .fcmp, .ty = .mask, .a = a, .b = b, .int_value = @intFromEnum(cmp) });
    }

    fn selectValue(self: *Builder, m: usize, t: usize, f: usize) Error!usize {
        try self.expectTy(m, .mask);
        try self.expectTy(t, .f64);
        try self.expectTy(f, .f64);
        return self.addValue(.{ .op = .select, .ty = .f64, .a = m, .b = t, .c = f });
    }
};

pub const BodyToken = union(enum) {
    number: i64,
    float: f64,
    local_frame_begin: usize,
    local_frame_end,
    local_arg: LocalRef,
    word: []const u8,
    // `call: name` — a real (non-inlined) call to another dsp2 word. Only legal
    // in a pure-composition word; compiled via the composition emitter, not the
    // value-graph Builder.
    call_word: []const u8,
    // `[` … `]`: a quote. The only consumer is a directly following
    // `times`, which the builder unrolls (see Program.run).
    quote_begin,
    quote_end,
};

/// Most copies `n [ … ] times` may unroll: a guard against a typo'd count
/// building a huge body, not a real-time limit (every copy is straight-line
/// code with a known cost).
pub const MAX_TIMES = 1024;

/// True if the token stream contains any `call:` — i.e. this is a composition
/// word that must be emitted via the dedicated call-sequencing path rather than
/// the value-graph Builder.
pub fn isComposition(tokens: []const BodyToken) bool {
    for (tokens) |tok| switch (tok) {
        .call_word => return true,
        else => {},
    };
    return false;
}

/// Where a body token came from in the source, for error messages. `via`
/// names the inlined dsp: word whose body produced the token, if any.
pub const Origin = struct {
    word: []const u8 = "",
    line: usize = 0,
    via: ?[]const u8 = null,
    /// Byte offset of the token in `file`'s source (words only).
    pos: usize = 0,
    file: []const u8 = "",
};

/// Why a build failed: the error, the token it failed at (index into
/// `tokens`), the symbolic stack depth there, and the arity tried.
pub const Failure = struct {
    err: Error,
    token: usize,
    depth: usize,
    arity: usize,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    tokens: compat.ArrayList(BodyToken),
    origins: compat.ArrayList(Origin),
    /// Origin stamped onto every token appended until changed.
    cur: Origin = .{},
    /// Set by build() when it fails: the most informative attempt.
    fail: ?Failure = null,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{
            .allocator = allocator,
            .tokens = compat.ArrayList(BodyToken).init(allocator),
            .origins = compat.ArrayList(Origin).init(allocator),
        };
    }

    pub fn deinit(self: *Program) void {
        self.tokens.deinit();
        self.origins.deinit();
    }

    pub fn push(self: *Program, tok: BodyToken) Error!void {
        try self.tokens.append(tok);
        try self.origins.append(self.cur);
    }

    pub fn addNumber(self: *Program, value: i64) Error!void {
        try self.push(.{ .number = value });
    }

    pub fn addFloat(self: *Program, value: f64) Error!void {
        try self.push(.{ .float = value });
    }

    pub fn addLocalArg(self: *Program, ref: LocalRef) Error!void {
        try self.push(.{ .local_arg = ref });
    }

    pub fn beginLocalFrame(self: *Program, arity: usize) Error!void {
        try self.push(.{ .local_frame_begin = arity });
    }

    pub fn endLocalFrame(self: *Program) Error!void {
        try self.push(.local_frame_end);
    }

    pub fn addWord(self: *Program, word: []const u8) Error!void {
        try self.push(.{ .word = word });
    }

    pub fn addCallWord(self: *Program, word: []const u8) Error!void {
        try self.push(.{ .call_word = word });
    }

    /// Append an inlined body; its tokens are attributed to `via`.
    pub fn addTokens(self: *Program, tokens: []const BodyToken) Error!void {
        const saved = self.cur;
        defer self.cur = saved;
        if (self.cur.via == null) self.cur.via = if (self.cur.word.len > 0) self.cur.word else null;
        for (tokens) |tok| try self.push(tok);
    }

    /// Arity implied by the body: a leading `| … |` frame binds exactly
    /// its names from the entry stack.
    pub fn impliedArity(self: *const Program) ?usize {
        if (self.tokens.items.len == 0) return null;
        return switch (self.tokens.items[0]) {
            .local_frame_begin => |n| n,
            else => null,
        };
    }

    /// Build at a known arity, or (arity null) search 0..16 for the first
    /// arity that builds. On failure `fail` records the attempt that got
    /// furthest into the body, so the caller can point at a token.
    pub fn build(self: *Program) Error!Builder {
        return self.buildWith(null);
    }

    pub fn buildWith(self: *Program, known_arity: ?usize) Error!Builder {
        self.fail = null;
        var arity: usize = known_arity orelse 0;
        const last: usize = known_arity orelse 16;
        while (arity <= last) : (arity += 1) {
            var b = Builder.init(self.allocator);
            errdefer b.deinit();
            var i: usize = 0;
            while (i < arity) : (i += 1) {
                const id = try b.addValue(.{ .op = .arg, .ty = .unknown, .arg_index = i });
                try b.stack.append(id);
                try b.args.append(id);
            }
            var failed = try self.run(&b, 0, self.tokens.items.len, arity);
            if (failed == null and b.stores.items.len == 0 and b.stack.items.len == 0)
                failed = .{ .err = Error.BadStackEffect, .token = self.tokens.items.len, .depth = 0, .arity = arity };
            if (failed) |f| {
                if (self.fail == null or f.token > self.fail.?.token) self.fail = f;
                // Unknown words fail at every arity; stop searching (the
                // errdefer frees b).
                if (f.err == Error.UnsupportedWord) return f.err;
                b.deinit();
                continue;
            }
            b.initial_arity = arity;
            return b;
        }
        return if (self.fail) |f| f.err else Error.BadStackEffect;
    }

    /// Feed tokens[start..end] to the builder. `n [ … ] times` replays the
    /// quote's tokens n times into the same value graph, so the loop leaves
    /// no trace in the emitted code: each copy is ordinary straight-line
    /// dsp, and each copy must leave the stack as deep as it found it so
    /// the copies line up. n must be a compile-time integer (a literal or
    /// `::`). Returns the failure, if any; only OutOfMemory is raised.
    fn run(self: *Program, b: *Builder, start: usize, end: usize, arity: usize) Error!?Failure {
        var ti = start;
        while (ti < end) {
            const tok = self.tokens.items[ti];
            const r: Error!void = switch (tok) {
                .number => |n| b.addNumber(n),
                .float => |f| b.addFloat(f),
                .local_arg => |ref| b.addLocalArg(ref),
                .local_frame_begin => |frame_arity| b.beginLocalFrame(frame_arity),
                .local_frame_end => b.endLocalFrame(),
                .word => |w| b.addWord(w),
                // call_word never belongs in a value-graph build — composition
                // words are routed to the dedicated emitter before build().
                .call_word => return Error.UnsupportedWord,
                .quote_end => Error.UnsupportedWord,
                .quote_begin => {
                    const close = self.matchQuote(ti, end) orelse
                        return .{ .err = Error.UnsupportedWord, .token = ti, .depth = b.stack.items.len, .arity = arity };
                    const after = close + 1;
                    const is_times = after < end and switch (self.tokens.items[after]) {
                        .word => |w| std.mem.eql(u8, w, "times"),
                        else => false,
                    };
                    if (!is_times)
                        return .{ .err = Error.UnsupportedWord, .token = ti, .depth = b.stack.items.len, .arity = arity };
                    const n = b.popCount() catch |err| {
                        if (err == error.OutOfMemory) return err;
                        return .{ .err = err, .token = after, .depth = b.stack.items.len, .arity = arity };
                    };
                    var k: usize = 0;
                    while (k < n) : (k += 1) {
                        const depth = b.stack.items.len;
                        const frames = b.local_frames.items.len;
                        if (try self.run(b, ti + 1, close, arity)) |f| return f;
                        if (b.stack.items.len != depth or b.local_frames.items.len != frames)
                            return .{ .err = Error.UnbalancedTimes, .token = close, .depth = b.stack.items.len, .arity = arity };
                    }
                    ti = after + 1;
                    continue;
                },
            };
            r catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return .{ .err = err, .token = ti, .depth = b.stack.items.len, .arity = arity },
            };
            ti += 1;
        }
        return null;
    }

    /// Index of the quote_end matching the quote_begin at `open`.
    fn matchQuote(self: *const Program, open: usize, end: usize) ?usize {
        var depth: usize = 0;
        var i = open;
        while (i < end) : (i += 1) switch (self.tokens.items[i]) {
            .quote_begin => depth += 1,
            .quote_end => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        };
        return null;
    }
};

pub fn cloneTokens(allocator: std.mem.Allocator, tokens: []const BodyToken) Error![]BodyToken {
    const cloned = allocator.alloc(BodyToken, tokens.len) catch return Error.OutOfMemory;
    var cloned_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < cloned_count) : (i += 1) {
            switch (cloned[i]) {
                .word => |w| allocator.free(w),
                .call_word => |w| allocator.free(w),
                else => {},
            }
        }
        allocator.free(cloned);
    }

    for (tokens, 0..) |tok, i| {
        cloned[i] = switch (tok) {
            .number => |n| .{ .number = n },
            .float => |f| .{ .float = f },
            .local_frame_begin => |arity| .{ .local_frame_begin = arity },
            .local_frame_end => .local_frame_end,
            .quote_begin => .quote_begin,
            .quote_end => .quote_end,
            .local_arg => |ref| .{ .local_arg = ref },
            .word => |w| blk: {
                const owned = allocator.dupe(u8, w) catch return Error.OutOfMemory;
                break :blk .{ .word = owned };
            },
            .call_word => |w| blk: {
                const owned = allocator.dupe(u8, w) catch return Error.OutOfMemory;
                break :blk .{ .call_word = owned };
            },
        };
        cloned_count += 1;
    }
    return cloned;
}

pub fn freeTokens(allocator: std.mem.Allocator, tokens: []BodyToken) void {
    for (tokens) |tok| switch (tok) {
        .word => |w| allocator.free(w),
        .call_word => |w| allocator.free(w),
        else => {},
    };
    allocator.free(tokens);
}

const Mode = enum {
    /// Registers only; RegisterExhausted when they run out.
    plain,
    /// Unlimited fake registers; records the request trace. Output discarded.
    dry,
    /// Registers plus spilling, guided by the dry pass's trace.
    spill,
};

const Codegen = struct {
    builder: *Builder,
    out: *compat.ArrayList(u32),
    locs: []Loc,
    remaining_uses: []u32,
    arg_abi: ArgAbi,
    mode: Mode = .plain,
    next_d: usize = 0,
    next_x: usize = 0,
    d_pool: [32]u5 = undefined,
    d_pool_len: usize = 0,
    free_d: [32]u5 = undefined,
    free_d_count: usize = 0,
    free_x: [RAW_X_SCRATCH_REGS.len]u5 = undefined,
    free_x_count: usize = 0,

    // Spilling state. owner_*: the value living in a register, if any (only
    // pool registers; raw arg registers are never owned). Pins protect a
    // register from eviction while an instruction still needs it.
    owner_d: [32]?usize = [_]?usize{null} ** 32,
    owner_x: [32]?usize = [_]?usize{null} ** 32,
    pin_d: [32]u16 = [_]u16{0} ** 32,
    pin_x: [32]u16 = [_]u16{0} ** 32,
    pin_log: [1024]u8 = undefined,
    pin_len: usize = 0,
    trace: ?*compat.ArrayList(usize) = null,
    next_pos: []const usize = &.{},
    tpos: usize = 0,
    cur_next: []usize,
    spill_slot: []?u16,
    depth: []const u32,
    slot_base: usize = 0,
    slot_count: u16 = 0,
    free_slots: [64]u16 = undefined,
    free_slot_count: usize = 0,
    /// Lane mode: d-registers hold 2-lane vectors (full q), slots are 16.
    lanes: bool = false,

    /// Every operand request goes through here, in the same order in the
    /// dry and spill passes; that order is the clock for next-use distances.
    fn request(self: *Codegen, id: usize) Error!void {
        switch (self.mode) {
            .plain => {},
            .dry => try self.trace.?.append(id),
            .spill => {
                if (self.tpos < self.next_pos.len) {
                    self.cur_next[id] = self.next_pos[self.tpos];
                    self.tpos += 1;
                }
            },
        }
    }

    fn pin(self: *Codegen, is_x: bool, reg: u5) Error!void {
        if (self.mode != .spill) return;
        if (self.pin_len >= self.pin_log.len) return Error.RegisterExhausted;
        self.pin_log[self.pin_len] = @as(u8, reg) | (if (is_x) @as(u8, 0x80) else 0);
        self.pin_len += 1;
        if (is_x) self.pin_x[reg] += 1 else self.pin_d[reg] += 1;
    }

    fn unpinTo(self: *Codegen, mark: usize) void {
        if (self.mode != .spill) return;
        while (self.pin_len > mark) {
            self.pin_len -= 1;
            const e = self.pin_log[self.pin_len];
            const reg: u5 = @intCast(e & 0x1f);
            if (e & 0x80 != 0) self.pin_x[reg] -= 1 else self.pin_d[reg] -= 1;
        }
    }

    /// Cheap to recompute from scratch, so eviction just forgets it.
    fn isRemat(self: *const Codegen, id: usize) bool {
        const v = self.builder.values.items[id];
        return switch (v.op) {
            .f64_const, .int_const => true,
            .arg => self.arg_abi != .raw_registers,
            else => false,
        };
    }

    fn allocSlot(self: *Codegen) Error!u16 {
        if (self.free_slot_count > 0) {
            self.free_slot_count -= 1;
            return self.free_slots[self.free_slot_count];
        }
        const slot = self.slot_count;
        self.slot_count += 1;
        return slot;
    }

    fn slotSize(self: *const Codegen) usize {
        return if (self.lanes) 16 else 8;
    }

    fn slotOffset(self: *const Codegen, slot: u16) Error!u12 {
        const off = self.slot_base + @as(usize, slot) * self.slotSize();
        if (off + self.slotSize() > 4096) return Error.RegisterExhausted;
        return @intCast(off);
    }

    fn storeSlotD(self: *const Codegen, reg: u5, off: u12) u32 {
        return if (self.lanes) Asm.str_q_imm(reg, 31, off) else Asm.str_d_imm(reg, 31, off);
    }

    fn loadSlotD(self: *const Codegen, reg: u5, off: u12) u32 {
        return if (self.lanes) Asm.ldr_q_imm(reg, 31, off) else Asm.ldr_d_imm(reg, 31, off);
    }

    /// Free a register by spilling the unpinned value whose next use is
    /// furthest away. The register is returned to the caller, unowned.
    fn evict(self: *Codegen, is_x: bool) Error!u5 {
        const owners = if (is_x) &self.owner_x else &self.owner_d;
        const pins = if (is_x) &self.pin_x else &self.pin_d;
        var best: ?u5 = null;
        var best_next: usize = 0;
        var best_remat = false;
        for (owners, 0..) |o, r| {
            const id = o orelse continue;
            if (pins[r] != 0) continue;
            const nxt = self.cur_next[id];
            const remat = self.isRemat(id);
            // Furthest next use wins; on a tie prefer what needs no store.
            if (best == null or nxt > best_next or (nxt == best_next and remat and !best_remat)) {
                best = @intCast(r);
                best_next = nxt;
                best_remat = remat;
            }
        }
        const reg = best orelse return Error.RegisterExhausted;
        const id = owners[reg].?;
        if (!self.isRemat(id) and self.spill_slot[id] == null) {
            const slot = try self.allocSlot();
            self.spill_slot[id] = slot;
            const off = try self.slotOffset(slot);
            try self.out.append(if (is_x) Asm.str_x_imm(reg, 31, off) else self.storeSlotD(reg, off));
        }
        owners[reg] = null;
        self.locs[id] = .none;
        return reg;
    }

    fn allocD(self: *Codegen) Error!u5 {
        if (self.mode == .dry) return 0;
        if (self.free_d_count > 0) {
            self.free_d_count -= 1;
            return self.free_d[self.free_d_count];
        }
        if (self.next_d >= self.d_pool_len) {
            if (self.mode == .spill) return self.evict(false);
            return Error.RegisterExhausted;
        }
        const reg = self.d_pool[self.next_d];
        self.next_d += 1;
        return reg;
    }

    fn allocX(self: *Codegen) Error!u5 {
        if (self.mode == .dry) return 9;
        if (self.free_x_count > 0) {
            self.free_x_count -= 1;
            return self.free_x[self.free_x_count];
        }
        const regs = if (self.arg_abi == .raw_registers) RAW_X_SCRATCH_REGS[0..] else X_REGS[0..];
        if (self.next_x >= regs.len) {
            if (self.mode == .spill) return self.evict(true);
            return Error.RegisterExhausted;
        }
        const reg = regs[self.next_x];
        self.next_x += 1;
        return reg;
    }

    fn releaseD(self: *Codegen, reg: u5) void {
        if (self.mode == .dry) return;
        std.debug.assert(self.free_d_count < self.free_d.len);
        self.owner_d[reg] = null;
        self.free_d[self.free_d_count] = reg;
        self.free_d_count += 1;
    }

    fn releaseX(self: *Codegen, reg: u5) void {
        if (self.mode == .dry) return;
        std.debug.assert(self.free_x_count < self.free_x.len);
        self.owner_x[reg] = null;
        self.free_x[self.free_x_count] = reg;
        self.free_x_count += 1;
    }

    fn consumeValue(self: *Codegen, id: usize) void {
        if (self.remaining_uses[id] == 0) return;
        self.remaining_uses[id] -= 1;
        if (self.remaining_uses[id] != 0) return;

        const value = self.builder.values.items[id];
        const raw_arg = self.arg_abi == .raw_registers and value.op == .arg;
        switch (self.locs[id]) {
            .d => |reg| if (!raw_arg) self.releaseD(reg),
            .x => |reg| if (!raw_arg) self.releaseX(reg),
            .none => {},
        }
        self.locs[id] = .none;
        if (self.spill_slot[id]) |slot| {
            if (self.free_slot_count < self.free_slots.len) {
                self.free_slots[self.free_slot_count] = slot;
                self.free_slot_count += 1;
            }
            self.spill_slot[id] = null;
        }
    }

    /// Record `reg` as holding `id` and pin it for the requesting instruction.
    fn settle(self: *Codegen, id: usize, is_x: bool, reg: u5) Error!u5 {
        self.locs[id] = if (is_x) .{ .x = reg } else .{ .d = reg };
        if (self.mode == .spill) {
            if (is_x) self.owner_x[reg] = id else self.owner_d[reg] = id;
        }
        try self.pin(is_x, reg);
        return reg;
    }

    fn valueX(self: *Codegen, id: usize) Error!u5 {
        try self.request(id);
        if (self.locs[id] == .x) {
            try self.pin(true, self.locs[id].x);
            return self.locs[id].x;
        }
        const value = self.builder.values.items[id];
        if (value.ty != .ptr and value.ty != .int) return Error.TypeMismatch;

        if (value.op == .arg and self.arg_abi == .raw_registers) {
            if (value.arg_index >= RAW_X_ARG_REGS.len) return Error.RegisterExhausted;
            const reg = RAW_X_ARG_REGS[value.arg_index];
            self.locs[id] = .{ .x = reg };
            return reg;
        }
        if (self.spill_slot[id]) |slot| {
            const reg = try self.allocX();
            try self.out.append(Asm.ldr_x_imm(reg, 31, try self.slotOffset(slot)));
            return self.settle(id, true, reg);
        }

        const mark = self.pin_len;
        const reg: u5 = switch (value.op) {
            .arg => blk: {
                const reg = try self.allocX();
                const offset = (self.builder.initial_arity - 1 - value.arg_index) * 8;
                try self.out.append(Asm.ldr_x_imm(reg, 21, @intCast(offset)));
                if (self.arg_abi == .tagged) {
                    try self.out.append(Asm.@"asr Xn, Xn, #2"(reg));
                }
                break :blk reg;
            },
            .int_const => blk: {
                const reg = try self.allocX();
                for (Asm.movImm64(reg, @as(u64, @bitCast(value.int_value)))) |instr| try self.out.append(instr);
                break :blk reg;
            },
            .ptr_add => blk: {
                const base = try self.valueX(value.a);
                const reg = try self.allocX();
                // Offsets up to 16 MB: the low 12 bits, then the next 12
                // shifted (a zone table or a long tap line is past 4 KB).
                const off: u64 = @intCast(value.int_value);
                if (off >= 1 << 24) return Error.NonConstantPick;
                if (off < 1 << 12) {
                    try self.out.append(Asm.add_imm(reg, base, @intCast(off)));
                } else {
                    try self.out.append(Asm.add_imm(reg, base, @intCast(off & 0xfff)));
                    try self.out.append(Asm.add_imm_lsl12(reg, reg, @intCast(off >> 12)));
                }
                self.consumeValue(value.a);
                break :blk reg;
            },
            .load_ptr => blk: {
                const ptr = try self.valueX(value.a);
                const reg = try self.allocX();
                try self.out.append(Asm.ldr_x_imm(reg, ptr, 0));
                self.consumeValue(value.a);
                break :blk reg;
            },
            .ptr_add_idx => blk: {
                const base = try self.valueX(value.a);
                const idx = try self.valueD(value.b);
                const reg = try self.allocX();
                const xi = try self.allocX();
                try self.out.append(Asm.@"fcvtzs Xd, Dn"(xi, idx));
                try self.out.append(Asm.@"add Xd, Xn, Xm, lsl #3"(reg, base, xi));
                self.releaseX(xi);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                break :blk reg;
            },
            .ptr_add_idx_lane => blk: {
                // The scalar fcvtzs reads lane 0; lane 1 moves down first.
                const base = try self.valueX(value.a);
                const idx = try self.valueD(value.b);
                const reg = try self.allocX();
                const xi = try self.allocX();
                if (value.int_value == 0) {
                    try self.out.append(Asm.@"fcvtzs Xd, Dn"(xi, idx));
                } else {
                    const t = try self.allocD();
                    try self.out.append(Asm.@"mov Dd, Vn.D[1]"(t, idx));
                    try self.out.append(Asm.@"fcvtzs Xd, Dn"(xi, t));
                    self.releaseD(t);
                }
                try self.out.append(Asm.@"add Xd, Xn, Xm, lsl #3"(reg, base, xi));
                self.releaseX(xi);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                break :blk reg;
            },
            else => return Error.TypeMismatch,
        };
        self.unpinTo(mark);
        return self.settle(id, true, reg);
    }

    /// valueD for several operands, deepest first (ties in order). The
    /// operands are pure, so the order changes registers, not results.
    fn valuesD(self: *Codegen, comptime n: usize, ids: [n]usize) Error![n]u5 {
        var order: [n]usize = undefined;
        for (0..n) |i| order[i] = i;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            var j = i;
            while (j > 0 and self.depth[ids[order[j]]] > self.depth[ids[order[j - 1]]]) : (j -= 1) {
                std.mem.swap(usize, &order[j], &order[j - 1]);
            }
        }
        var regs: [n]u5 = undefined;
        for (order) |k| regs[k] = try self.valueD(ids[k]);
        return regs;
    }

    fn valueD(self: *Codegen, id: usize) Error!u5 {
        try self.request(id);
        if (self.locs[id] == .d) {
            try self.pin(false, self.locs[id].d);
            return self.locs[id].d;
        }
        const value = self.builder.values.items[id];
        if (value.ty != .f64 and value.ty != .mask) return Error.TypeMismatch;

        if (value.op == .arg and self.arg_abi == .raw_registers) {
            if (value.arg_index >= RAW_D_ARG_REGS.len) return Error.RegisterExhausted;
            const reg = RAW_D_ARG_REGS[value.arg_index];
            self.locs[id] = .{ .d = reg };
            return reg;
        }
        if (self.spill_slot[id]) |slot| {
            const reg = try self.allocD();
            try self.out.append(self.loadSlotD(reg, try self.slotOffset(slot)));
            return self.settle(id, false, reg);
        }

        const mark = self.pin_len;
        const reg = try self.computeD(value);
        self.unpinTo(mark);
        return self.settle(id, false, reg);
    }

    /// Materialize an f64 value. Operands are fetched (and pinned) first and
    /// the destination is allocated after them, so a deep expression does not
    /// hold one pending destination per level. Operands are consumed only
    /// after the last instruction, so the destination never aliases a live
    /// input of a multi-instruction sequence.
    fn computeD(self: *Codegen, value: Value) Error!u5 {
        if (self.lanes) return self.computeLanes(value);
        switch (value.op) {
            .arg => {
                const reg = try self.allocD();
                const offset = (self.builder.initial_arity - 1 - value.arg_index) * 8;
                if (self.arg_abi == .raw) {
                    try self.out.append(Asm.ldr_d_imm(reg, 21, @intCast(offset)));
                } else {
                    const x = try self.allocX();
                    try self.out.append(Asm.ldr_x_imm(x, 21, @intCast(offset)));
                    try self.out.append(Asm.@"lsr Xn, Xn, #2"(x));
                    try self.out.append(Asm.@"lsl Xn, Xn, #2"(x));
                    try self.out.append(Asm.@"fmov Dd, Xn"(reg, x));
                    self.releaseX(x);
                }
                return reg;
            },
            .f64_const => {
                const reg = try self.allocD();
                try self.emitF64Const(reg, value.float_value);
                return reg;
            },
            .load_f64 => {
                const ptr = try self.valueX(value.a);
                const reg = try self.allocD();
                try self.out.append(Asm.ldr_d_imm(reg, ptr, 0));
                self.consumeValue(value.a);
                return reg;
            },
            .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .mand, .mor => {
                const r = try self.valuesD(2, .{ value.a, value.b });
                const a = r[0];
                const b = r[1];
                const reg = try self.allocD();
                const instr = switch (value.op) {
                    .fadd => Asm.@"fadd Dd, Dn, Dm"(reg, a, b),
                    .fsub => Asm.@"fsub Dd, Dn, Dm"(reg, a, b),
                    .fmul => Asm.@"fmul Dd, Dn, Dm"(reg, a, b),
                    .fdiv => Asm.@"fdiv Dd, Dn, Dm"(reg, a, b),
                    .fmin => Asm.@"fmin Dd, Dn, Dm"(reg, a, b),
                    .fmax => Asm.@"fmax Dd, Dn, Dm"(reg, a, b),
                    .mand => Asm.@"and Vd.8B, Vn.8B, Vm.8B"(reg, a, b),
                    .mor => Asm.@"orr Vd.8B, Vn.8B, Vm.8B"(reg, a, b),
                    else => unreachable,
                };
                try self.out.append(instr);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                return reg;
            },
            .fabs, .fneg, .fsqrt, .ffloor, .mnot => {
                const a = try self.valueD(value.a);
                const reg = try self.allocD();
                try self.out.append(switch (value.op) {
                    .fabs => Asm.@"fabs Dd, Dn"(reg, a),
                    .fneg => Asm.@"fneg Dd, Dn"(reg, a),
                    .fsqrt => Asm.@"fsqrt Dd, Dn"(reg, a),
                    .ffloor => Asm.@"frintm Dd, Dn"(reg, a),
                    .mnot => Asm.@"mvn Vd.8B, Vn.8B"(reg, a),
                    else => unreachable,
                });
                self.consumeValue(value.a);
                return reg;
            },
            .fexp2i, .flog2i, .fmant => {
                const a = try self.valueD(value.a);
                const reg = try self.allocD();
                const x = try self.allocX();
                switch (value.op) {
                    .fexp2i => {
                        try self.out.append(Asm.@"fcvtms Xd, Dn"(x, a));
                        try self.out.append(Asm.@"add Xd, Xn, #1023"(x, x));
                        try self.out.append(Asm.@"lsl Xd, Xn, #52"(x, x));
                        try self.out.append(Asm.@"fmov Dd, Xn"(reg, x));
                    },
                    .flog2i => {
                        try self.out.append(Asm.@"fmov Xd, Dn"(x, a));
                        try self.out.append(Asm.@"lsr Xd, Xn, #52"(x, x));
                        try self.out.append(Asm.@"and Xd, Xn, #0x7ff"(x, x));
                        try self.out.append(Asm.@"sub Xd, Xn, #1023"(x, x));
                        try self.out.append(Asm.@"scvtf Dd, Xn"(reg, x));
                    },
                    .fmant => {
                        try self.out.append(Asm.@"fmov Xd, Dn"(x, a));
                        try self.out.append(Asm.@"and Xd, Xn, #0xfffffffffffff"(x, x));
                        try self.out.append(Asm.@"orr Xd, Xn, #0x3ff0000000000000"(x, x));
                        try self.out.append(Asm.@"fmov Dd, Xn"(reg, x));
                    },
                    else => unreachable,
                }
                self.releaseX(x);
                self.consumeValue(value.a);
                return reg;
            },
            .fcmp => {
                // Materialized mask. a<b is b>a; NaN compares false.
                const r = try self.valuesD(2, .{ value.a, value.b });
                const a = r[0];
                const b = r[1];
                const reg = try self.allocD();
                try self.out.append(switch (@as(Cmp, @enumFromInt(value.int_value))) {
                    .lt => Asm.@"fcmgt Dd, Dn, Dm"(reg, b, a),
                    .le => Asm.@"fcmge Dd, Dn, Dm"(reg, b, a),
                    .gt => Asm.@"fcmgt Dd, Dn, Dm"(reg, a, b),
                    .ge => Asm.@"fcmge Dd, Dn, Dm"(reg, a, b),
                    .eq => Asm.@"fcmeq Dd, Dn, Dm"(reg, a, b),
                });
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                return reg;
            },
            .mask_to_f => {
                const m = try self.valueD(value.a);
                const one = try self.allocD();
                try self.emitF64Const(one, 1.0);
                const reg = try self.allocD();
                try self.out.append(Asm.@"and Vd.8B, Vn.8B, Vm.8B"(reg, m, one));
                self.releaseD(one);
                self.consumeValue(value.a);
                return reg;
            },
            .select => {
                const mv = self.builder.values.items[value.a];
                const fresh = self.locs[value.a] == .none and self.spill_slot[value.a] == null;
                if (mv.op == .fcmp and fresh and self.remaining_uses[value.a] == 1) {
                    // The compare's only use: fcmp + fcsel, no mask register.
                    // The conditions are the ordered ones, so NaN selects
                    // the false arm exactly like the materialized mask.
                    const r = try self.valuesD(4, .{ mv.a, mv.b, value.b, value.c });
                    const a = r[0];
                    const b = r[1];
                    const t = r[2];
                    const f = r[3];
                    const reg = try self.allocD();
                    const cond: u4 = switch (@as(Cmp, @enumFromInt(mv.int_value))) {
                        .lt => Asm.COND_MI,
                        .le => Asm.COND_LS,
                        .gt => Asm.COND_GT,
                        .ge => Asm.COND_GE,
                        .eq => Asm.COND_EQ,
                    };
                    try self.out.append(Asm.@"fcmp Dn, Dm"(a, b));
                    try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, t, f, cond));
                    self.consumeValue(mv.a);
                    self.consumeValue(mv.b);
                    self.consumeValue(value.a);
                    self.consumeValue(value.b);
                    self.consumeValue(value.c);
                    return reg;
                }
                const r = try self.valuesD(3, .{ value.a, value.b, value.c });
                const m = r[0];
                const t = r[1];
                const f = r[2];
                const reg = try self.allocD();
                try self.out.append(Asm.@"fmov Dd, Dn"(reg, m));
                try self.out.append(Asm.@"bsl Vd.8B, Vn.8B, Vm.8B"(reg, t, f));
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                return reg;
            },
            else => return Error.TypeMismatch,
        }
    }

    /// computeD in lane mode: the same operations on both lanes.
    fn computeLanes(self: *Codegen, value: Value) Error!u5 {
        switch (value.op) {
            .f64_const => {
                const reg = try self.allocD();
                try self.emitF64Const(reg, value.float_value);
                try self.out.append(Asm.@"dup Vd.2D, Vn.D[0]"(reg, reg));
                return reg;
            },
            .load_lane2 => {
                const p0 = try self.valueX(value.a);
                const p1 = try self.valueX(value.b);
                const reg = try self.allocD();
                try self.out.append(Asm.ldr_d_imm(reg, p0, 0));
                try self.out.append(Asm.@"ld1 {Vt.D}[1], [Xn]"(reg, p1));
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                return reg;
            },
            .load_splat => {
                const p = try self.valueX(value.a);
                const reg = try self.allocD();
                try self.out.append(Asm.@"ld1r {Vt.2D}, [Xn]"(reg, p));
                self.consumeValue(value.a);
                return reg;
            },
            .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .mand, .mor, .fcmp => {
                const r = try self.valuesD(2, .{ value.a, value.b });
                const a = r[0];
                const b = r[1];
                const reg = try self.allocD();
                try self.out.append(switch (value.op) {
                    .fadd => Asm.@"fadd Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                    .fsub => Asm.@"fsub Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                    .fmul => Asm.@"fmul Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                    .fdiv => Asm.@"fdiv Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                    .fmin => Asm.@"fmin Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                    .fmax => Asm.@"fmax Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                    .mand => Asm.@"and Vd.16B, Vn.16B, Vm.16B"(reg, a, b),
                    .mor => Asm.@"orr Vd.16B, Vn.16B, Vm.16B"(reg, a, b),
                    .fcmp => switch (@as(Cmp, @enumFromInt(value.int_value))) {
                        .lt => Asm.@"fcmgt Vd.2D, Vn.2D, Vm.2D"(reg, b, a),
                        .le => Asm.@"fcmge Vd.2D, Vn.2D, Vm.2D"(reg, b, a),
                        .gt => Asm.@"fcmgt Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                        .ge => Asm.@"fcmge Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                        .eq => Asm.@"fcmeq Vd.2D, Vn.2D, Vm.2D"(reg, a, b),
                    },
                    else => unreachable,
                });
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                return reg;
            },
            .fabs, .fneg, .fsqrt, .ffloor, .mnot => {
                const a = try self.valueD(value.a);
                const reg = try self.allocD();
                try self.out.append(switch (value.op) {
                    .fabs => Asm.@"fabs Vd.2D, Vn.2D"(reg, a),
                    .fneg => Asm.@"fneg Vd.2D, Vn.2D"(reg, a),
                    .fsqrt => Asm.@"fsqrt Vd.2D, Vn.2D"(reg, a),
                    .ffloor => Asm.@"frintm Vd.2D, Vn.2D"(reg, a),
                    .mnot => Asm.@"mvn Vd.16B, Vn.16B"(reg, a),
                    else => unreachable,
                });
                self.consumeValue(value.a);
                return reg;
            },
            .fexp2i, .flog2i, .fmant => {
                // The scalar bit tricks, lane-wise, with the integer
                // constants splatted into a scratch vector.
                const a = try self.valueD(value.a);
                const reg = try self.allocD();
                const t = try self.allocD();
                const x = try self.allocX();
                switch (value.op) {
                    .fexp2i => {
                        try self.out.append(Asm.@"fcvtms Vd.2D, Vn.2D"(reg, a));
                        try self.splatBits(t, x, 1023);
                        try self.out.append(Asm.@"add Vd.2D, Vn.2D, Vm.2D"(reg, reg, t));
                        try self.out.append(Asm.@"shl Vd.2D, Vn.2D, #52"(reg, reg));
                    },
                    .flog2i => {
                        try self.out.append(Asm.@"ushr Vd.2D, Vn.2D, #52"(reg, a));
                        try self.splatBits(t, x, 0x7ff);
                        try self.out.append(Asm.@"and Vd.16B, Vn.16B, Vm.16B"(reg, reg, t));
                        try self.splatBits(t, x, 1023);
                        try self.out.append(Asm.@"sub Vd.2D, Vn.2D, Vm.2D"(reg, reg, t));
                        try self.out.append(Asm.@"scvtf Vd.2D, Vn.2D"(reg, reg));
                    },
                    .fmant => {
                        try self.splatBits(t, x, 0xfffffffffffff);
                        try self.out.append(Asm.@"and Vd.16B, Vn.16B, Vm.16B"(reg, a, t));
                        try self.splatBits(t, x, 0x3ff0000000000000);
                        try self.out.append(Asm.@"orr Vd.16B, Vn.16B, Vm.16B"(reg, reg, t));
                    },
                    else => unreachable,
                }
                self.releaseX(x);
                self.releaseD(t);
                self.consumeValue(value.a);
                return reg;
            },
            .mask_to_f => {
                const m = try self.valueD(value.a);
                const one = try self.allocD();
                try self.emitF64Const(one, 1.0);
                try self.out.append(Asm.@"dup Vd.2D, Vn.D[0]"(one, one));
                const reg = try self.allocD();
                try self.out.append(Asm.@"and Vd.16B, Vn.16B, Vm.16B"(reg, m, one));
                self.releaseD(one);
                self.consumeValue(value.a);
                return reg;
            },
            .select => {
                // No fcsel across lanes: always the mask and a bit select.
                const r = try self.valuesD(3, .{ value.a, value.b, value.c });
                const reg = try self.allocD();
                try self.out.append(Asm.@"orr Vd.16B, Vn.16B, Vm.16B"(reg, r[0], r[0]));
                try self.out.append(Asm.@"bsl Vd.16B, Vn.16B, Vm.16B"(reg, r[1], r[2]));
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                return reg;
            },
            else => return Error.TypeMismatch,
        }
    }

    /// 64-bit `bits` into both lanes of `v`, through `x`.
    fn splatBits(self: *Codegen, v: u5, x: u5, bits: u64) Error!void {
        for (Asm.movImm64(x, bits)) |instr| try self.out.append(instr);
        try self.out.append(Asm.@"dup Vd.2D, Xn"(v, x));
    }

    fn emitF64Const(self: *Codegen, reg: u5, value: f64) Error!void {
        if (fmovF64Imm(reg, value)) |instr| {
            try self.out.append(instr);
            return;
        }
        if (@as(u64, @bitCast(value)) == 0) {
            try self.out.append(Asm.@"fmov Dd, Xn"(reg, 31)); // fmov d, xzr
            return;
        }
        const x = try self.allocX();
        // movz the first non-zero halfword, movk the rest; zero halves cost
        // nothing (2.0 is one movz + fmov, not four moves + fmov).
        const bits: u64 = @bitCast(value);
        var first = true;
        var hw: u6 = 0;
        while (hw < 4) : (hw += 1) {
            const half: u32 = @intCast((bits >> (@as(u6, hw) * 16)) & 0xffff);
            if (half == 0 and !(first and hw == 3)) continue;
            const base: u32 = if (first) 0xD2800000 else 0xF2800000;
            try self.out.append(base | (@as(u32, hw) << 21) | (half << 5) | x);
            first = false;
        }
        try self.out.append(Asm.@"fmov Dd, Xn"(reg, x));
        self.releaseX(x);
    }
};

/// `fmov Dd, #imm` when `value` fits the 8-bit float immediate
/// (±(16..31)/16 · 2^-3..2^4, e.g. 0.5, 1.0, 2.5, 27.0).
fn fmovF64Imm(reg: u5, value: f64) ?u32 {
    const bits: u64 = @bitCast(value);
    var imm8: u32 = 0;
    while (imm8 < 256) : (imm8 += 1) {
        const sign: u64 = (imm8 >> 7) & 1;
        const b6: u64 = (imm8 >> 6) & 1;
        const exp: u64 = ((b6 ^ 1) << 10) | ((if (b6 == 1) @as(u64, 0xff) else 0) << 2) | ((imm8 >> 4) & 3);
        const frac: u64 = @as(u64, imm8 & 0xf) << 48;
        if ((sign << 63) | (exp << 52) | frac == bits) return 0x1E601000 | (imm8 << 13) | @as(u32, reg);
    }
    return null;
}
