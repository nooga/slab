const std = @import("std");
const Asm = @import("asm.zig");
const compat = @import("compat.zig");

pub const Error = error{
    BadStackEffect,
    NonConstantPick,
    OutOfMemory,
    RegisterExhausted,
    StackUnderflow,
    TypeMismatch,
    UnsupportedWord,
};

const Ty = enum {
    unknown,
    int,
    ptr,
    f64,
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
    fclamp,
    fwrap01,
    ffrac,
    fsel_lt,
    fcapramp,
    fpolyblep,
    fpulseblep,
    fadsr_linear,
    fadsr_cap,
};

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
            const pa = try self.addValue(.{ .op = .ptr_add_idx, .ty = .ptr, .a = base, .b = idx });
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
            const pa = try self.addValue(.{ .op = .ptr_add_idx, .ty = .ptr, .a = base, .b = idx });
            try self.stores.append(.{ .ptr = pa, .value = v });
            return;
        }
        if (std.mem.eql(u8, word, "f+")) {
            try self.floatBin(.fadd);
            return;
        }
        if (std.mem.eql(u8, word, "f-")) {
            try self.floatBin(.fsub);
            return;
        }
        if (std.mem.eql(u8, word, "f*")) {
            try self.floatBin(.fmul);
            return;
        }
        if (std.mem.eql(u8, word, "f/")) {
            try self.floatBin(.fdiv);
            return;
        }
        if (std.mem.eql(u8, word, "fclamp")) {
            const hi = try self.pop();
            const lo = try self.pop();
            const x = try self.pop();
            try self.expectTy(x, .f64);
            try self.expectTy(lo, .f64);
            try self.expectTy(hi, .f64);
            const id = try self.addValue(.{ .op = .fclamp, .ty = .f64, .a = x, .b = lo, .c = hi });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "ffrac")) {
            const x = try self.pop();
            try self.expectTy(x, .f64);
            const id = try self.addValue(.{ .op = .ffrac, .ty = .f64, .a = x });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "fwrap01")) {
            const x = try self.pop();
            try self.expectTy(x, .f64);
            const id = try self.addValue(.{ .op = .fwrap01, .ty = .f64, .a = x });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "fsel-lt")) {
            const if_false = try self.pop();
            const if_true = try self.pop();
            const b = try self.pop();
            const a = try self.pop();
            try self.expectTy(a, .f64);
            try self.expectTy(b, .f64);
            try self.expectTy(if_true, .f64);
            try self.expectTy(if_false, .f64);
            const id = try self.addValue(.{ .op = .fsel_lt, .ty = .f64, .a = a, .b = b, .c = if_true, .d = if_false });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "fcapramp")) {
            const phase = try self.pop();
            try self.expectTy(phase, .f64);
            const id = try self.addValue(.{ .op = .fcapramp, .ty = .f64, .a = phase });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "fpolyblep")) {
            const dt = try self.pop();
            const phase = try self.pop();
            try self.expectTy(phase, .f64);
            try self.expectTy(dt, .f64);
            const id = try self.addValue(.{ .op = .fpolyblep, .ty = .f64, .a = phase, .b = dt });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "fpulseblep")) {
            const width = try self.pop();
            const dt = try self.pop();
            const phase = try self.pop();
            try self.expectTy(phase, .f64);
            try self.expectTy(dt, .f64);
            try self.expectTy(width, .f64);
            const id = try self.addValue(.{ .op = .fpulseblep, .ty = .f64, .a = phase, .b = dt, .c = width });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "fadsr-linear")) {
            const release = try self.pop();
            const gate = try self.pop();
            const sustain = try self.pop();
            const decay = try self.pop();
            const attack = try self.pop();
            const time = try self.pop();
            try self.expectTy(time, .f64);
            try self.expectTy(attack, .f64);
            try self.expectTy(decay, .f64);
            try self.expectTy(sustain, .f64);
            try self.expectTy(gate, .f64);
            try self.expectTy(release, .f64);
            const id = try self.addValue(.{
                .op = .fadsr_linear,
                .ty = .f64,
                .a = time,
                .b = attack,
                .c = decay,
                .d = sustain,
                .e = gate,
                .f = release,
            });
            try self.stack.append(id);
            return;
        }
        if (std.mem.eql(u8, word, "fadsr-cap")) {
            const release = try self.pop();
            const gate = try self.pop();
            const sustain = try self.pop();
            const decay = try self.pop();
            const attack = try self.pop();
            const time = try self.pop();
            try self.expectTy(time, .f64);
            try self.expectTy(attack, .f64);
            try self.expectTy(decay, .f64);
            try self.expectTy(sustain, .f64);
            try self.expectTy(gate, .f64);
            try self.expectTy(release, .f64);
            const id = try self.addValue(.{
                .op = .fadsr_cap,
                .ty = .f64,
                .a = time,
                .b = attack,
                .c = decay,
                .d = sustain,
                .e = gate,
                .f = release,
            });
            try self.stack.append(id);
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
                .ptr_add_idx => if (v.a == id) return true,
                else => {},
            }
        }
        for (self.stores.items) |s| if (s.ptr == id) return true;
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
        const stash_bytes: usize = if (spill_stores) std.mem.alignForward(usize, self.stores.items.len * 16, 16) else 0;
        cg.slot_base = stash_bytes;
        const use_frame = spill_stores or mode == .spill;
        const frame_at = out.items.len;
        if (use_frame) try out.append(Asm.sub_sp_imm(@intCast(stash_bytes)));

        if (spill_stores) {
            for (self.stores.items, 0..) |store, i| {
                const mark = cg.pin_len;
                const val_reg = try cg.valueD(store.value);
                const ptr_reg = try cg.valueX(store.ptr);
                const offset: u12 = @intCast(i * 16);
                try out.append(Asm.str_d_imm(val_reg, 31, offset));
                try out.append(Asm.str_x_imm(ptr_reg, 31, offset + 8));
                cg.unpinTo(mark);
                cg.consumeValue(store.value);
                cg.consumeValue(store.ptr);
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
                const offset: u12 = @intCast(i * 16);
                try out.append(Asm.ldr_d_imm(val_reg, 31, offset));
                try out.append(Asm.ldr_x_imm(ptr_reg, 31, offset + 8));
                try out.append(Asm.str_d_imm(val_reg, ptr_reg, 0));
                cg.releaseD(val_reg);
                cg.releaseX(ptr_reg);
            }
        } else {
            for (self.stores.items) |store| {
                const mark = cg.pin_len;
                const val_reg = try cg.valueD(store.value);
                const ptr_reg = try cg.valueX(store.ptr);
                try out.append(Asm.str_d_imm(val_reg, ptr_reg, 0));
                cg.unpinTo(mark);
                cg.consumeValue(store.value);
                cg.consumeValue(store.ptr);
            }
        }
        if (use_frame) {
            const bytes = std.mem.alignForward(usize, cg.slot_base + @as(usize, cg.slot_count) * 8, 16);
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
                .ptr_add, .load_f64, .load_ptr, .fwrap01, .ffrac, .fcapramp => remaining_uses[value.a] += 1,
                .ptr_add_idx, .fadd, .fsub, .fmul, .fdiv, .fpolyblep => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                },
                .fclamp => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                    remaining_uses[value.c] += 1;
                },
                .fsel_lt => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                    remaining_uses[value.c] += 1;
                    remaining_uses[value.d] += 1;
                },
                .fpulseblep => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                    remaining_uses[value.c] += 1;
                },
                .fadsr_linear, .fadsr_cap => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                    remaining_uses[value.c] += 1;
                    remaining_uses[value.d] += 1;
                    remaining_uses[value.e] += 1;
                    remaining_uses[value.f] += 1;
                },
            }
        }
        for (self.stores.items) |store| {
            remaining_uses[store.ptr] += 1;
            remaining_uses[store.value] += 1;
        }
        for (self.stack.items) |value| remaining_uses[value] += 1;
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
        if (old != ty) return Error.TypeMismatch;
    }

    fn floatBin(self: *Builder, op: Op) Error!void {
        const b = try self.pop();
        const a = try self.pop();
        try self.expectTy(a, .f64);
        try self.expectTy(b, .f64);
        const id = try self.addValue(.{ .op = op, .ty = .f64, .a = a, .b = b });
        try self.stack.append(id);
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
};

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

    fn push(self: *Program, tok: BodyToken) Error!void {
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
            var failed: ?Failure = null;
            for (self.tokens.items, 0..) |tok, ti| {
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
                };
                r catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        failed = .{ .err = err, .token = ti, .depth = b.stack.items.len, .arity = arity };
                        break;
                    },
                };
            }
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
    slot_base: usize = 0,
    slot_count: u16 = 0,
    free_slots: [64]u16 = undefined,
    free_slot_count: usize = 0,

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

    fn slotOffset(self: *const Codegen, slot: u16) Error!u12 {
        const off = self.slot_base + @as(usize, slot) * 8;
        if (off > 4088) return Error.RegisterExhausted;
        return @intCast(off);
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
            try self.out.append(if (is_x) Asm.str_x_imm(reg, 31, off) else Asm.str_d_imm(reg, 31, off));
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
                try self.out.append(Asm.add_imm(reg, base, @intCast(value.int_value)));
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
            else => return Error.TypeMismatch,
        };
        self.unpinTo(mark);
        return self.settle(id, true, reg);
    }

    fn valueD(self: *Codegen, id: usize) Error!u5 {
        try self.request(id);
        if (self.locs[id] == .d) {
            try self.pin(false, self.locs[id].d);
            return self.locs[id].d;
        }
        const value = self.builder.values.items[id];
        if (value.ty != .f64) return Error.TypeMismatch;

        if (value.op == .arg and self.arg_abi == .raw_registers) {
            if (value.arg_index >= RAW_D_ARG_REGS.len) return Error.RegisterExhausted;
            const reg = RAW_D_ARG_REGS[value.arg_index];
            self.locs[id] = .{ .d = reg };
            return reg;
        }
        if (self.spill_slot[id]) |slot| {
            const reg = try self.allocD();
            try self.out.append(Asm.ldr_d_imm(reg, 31, try self.slotOffset(slot)));
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
            .fadd, .fsub, .fmul, .fdiv => {
                const a = try self.valueD(value.a);
                const b = try self.valueD(value.b);
                const reg = try self.allocD();
                const instr = switch (value.op) {
                    .fadd => Asm.@"fadd Dd, Dn, Dm"(reg, a, b),
                    .fsub => Asm.@"fsub Dd, Dn, Dm"(reg, a, b),
                    .fmul => Asm.@"fmul Dd, Dn, Dm"(reg, a, b),
                    .fdiv => Asm.@"fdiv Dd, Dn, Dm"(reg, a, b),
                    else => unreachable,
                };
                try self.out.append(instr);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                return reg;
            },
            .fclamp => {
                const x = try self.valueD(value.a);
                const lo = try self.valueD(value.b);
                const hi = try self.valueD(value.c);
                const reg = try self.allocD();
                try self.out.append(Asm.@"fmax Dd, Dn, Dm"(reg, x, lo));
                try self.out.append(Asm.@"fmin Dd, Dn, Dm"(reg, reg, hi));
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                return reg;
            },
            .ffrac => {
                // frac(x) = x - floor(x)
                const x = try self.valueD(value.a);
                const reg = try self.allocD();
                const fl = try self.allocD();
                try self.out.append(Asm.@"frintm Dd, Dn"(fl, x));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(reg, x, fl));
                self.releaseD(fl);
                self.consumeValue(value.a);
                return reg;
            },
            .fwrap01 => {
                const x = try self.valueD(value.a);
                const reg = try self.allocD();
                const zero = try self.allocD();
                try self.emitF64Const(zero, 0.0);
                const one = try self.allocD();
                try self.emitF64Const(one, 1.0);

                const xm1 = try self.allocD();
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(xm1, x, one));
                try self.out.append(Asm.@"fcmp Dn, Dm"(x, one));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, xm1, x, Asm.COND_GT));

                const xp1 = try self.allocD();
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(xp1, reg, one));
                try self.out.append(Asm.@"fcmp Dn, Dm"(reg, zero));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, xp1, reg, Asm.COND_LT));
                self.releaseD(zero);
                self.releaseD(one);
                self.releaseD(xm1);
                self.releaseD(xp1);
                self.consumeValue(value.a);
                return reg;
            },
            .fsel_lt => {
                const a = try self.valueD(value.a);
                const b = try self.valueD(value.b);
                const if_true = try self.valueD(value.c);
                const if_false = try self.valueD(value.d);
                const reg = try self.allocD();
                try self.out.append(Asm.@"fcmp Dn, Dm"(a, b));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, if_true, if_false, Asm.COND_LT));
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                self.consumeValue(value.d);
                return reg;
            },
            .fcapramp => {
                const phase = try self.valueD(value.a);
                const reg = try self.allocD();
                const two = try self.allocD();
                try self.emitF64Const(two, 2.0);
                const one = try self.allocD();
                try self.emitF64Const(one, 1.0);
                const scratch = try self.allocD();

                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch, two, phase));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(reg, phase, scratch));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(reg, reg, two));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(reg, reg, one));
                self.releaseD(two);
                self.releaseD(one);
                self.releaseD(scratch);
                self.consumeValue(value.a);
                return reg;
            },
            .fpolyblep => {
                const phase = try self.valueD(value.a);
                const dt = try self.valueD(value.b);
                const reg = try self.allocD();
                const zero = try self.allocD();
                try self.emitF64Const(zero, 0.0);
                const one = try self.allocD();
                try self.emitF64Const(one, 1.0);

                const scratch_a = try self.allocD();
                const scratch_b = try self.allocD();
                const scratch_c = try self.allocD();

                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_a, phase, dt));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_a, scratch_a));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(reg, scratch_a, scratch_a));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(reg, reg, scratch_b));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(reg, reg, one));
                try self.out.append(Asm.@"fcmp Dn, Dm"(phase, dt));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, zero, Asm.COND_LT));

                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, phase, one));
                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_a, scratch_a, dt));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_a, scratch_a));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_c, scratch_a, scratch_a));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_c, scratch_c, scratch_b));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_c, scratch_c, one));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, one, dt));
                try self.out.append(Asm.@"fcmp Dn, Dm"(scratch_a, phase));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, scratch_c, reg, Asm.COND_LT));
                self.releaseD(zero);
                self.releaseD(one);
                self.releaseD(scratch_a);
                self.releaseD(scratch_b);
                self.releaseD(scratch_c);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                return reg;
            },
            .fpulseblep => {
                const phase = try self.valueD(value.a);
                const dt = try self.valueD(value.b);
                const width = try self.valueD(value.c);
                const reg = try self.allocD();
                const zero = try self.allocD();
                try self.emitF64Const(zero, 0.0);
                const one = try self.allocD();
                try self.emitF64Const(one, 1.0);
                const neg_one = try self.allocD();
                try self.emitF64Const(neg_one, -1.0);
                const scratch_a = try self.allocD();
                const scratch_b = try self.allocD();
                const scratch_c = try self.allocD();

                try self.out.append(Asm.@"fcmp Dn, Dm"(phase, width));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, one, neg_one, Asm.COND_LT));

                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_a, phase, dt));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_a, scratch_a));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_c, scratch_a, scratch_a));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_c, scratch_c, scratch_b));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_c, scratch_c, one));
                try self.out.append(Asm.@"fcmp Dn, Dm"(phase, dt));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(scratch_c, scratch_c, zero, Asm.COND_LT));

                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_b, one, dt));
                try self.out.append(Asm.@"fcmp Dn, Dm"(scratch_b, phase));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, phase, one));
                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_a, scratch_a, dt));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_a, scratch_a));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_a, scratch_a, scratch_a));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_b, scratch_b, scratch_a));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_b, scratch_b, one));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(scratch_c, scratch_b, scratch_c, Asm.COND_LT));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(reg, reg, scratch_c));

                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, phase, width));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_b, scratch_a, one));
                try self.out.append(Asm.@"fcmp Dn, Dm"(scratch_a, zero));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(scratch_a, scratch_b, scratch_a, Asm.COND_LT));

                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_b, scratch_a, dt));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_c, scratch_b, scratch_b));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_b, scratch_b, scratch_b));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_c, scratch_b, scratch_c));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_c, scratch_c, one));
                try self.out.append(Asm.@"fcmp Dn, Dm"(scratch_a, dt));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(scratch_c, scratch_c, zero, Asm.COND_LT));

                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_b, one, dt));
                try self.out.append(Asm.@"fcmp Dn, Dm"(scratch_b, scratch_a));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_b, scratch_a, one));
                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_b, scratch_b, dt));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_a, scratch_b, scratch_b));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_b, scratch_b, scratch_b));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_a, scratch_a, scratch_b));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_a, scratch_a, one));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(scratch_c, scratch_a, scratch_c, Asm.COND_LT));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(reg, reg, scratch_c));
                self.releaseD(zero);
                self.releaseD(one);
                self.releaseD(neg_one);
                self.releaseD(scratch_a);
                self.releaseD(scratch_b);
                self.releaseD(scratch_c);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                return reg;
            },
            .fadsr_linear => {
                const time = try self.valueD(value.a);
                const attack = try self.valueD(value.b);
                const decay = try self.valueD(value.c);
                const sustain = try self.valueD(value.d);
                const gate = try self.valueD(value.e);
                const release = try self.valueD(value.f);
                const reg = try self.allocD();
                const zero = try self.allocD();
                try self.emitF64Const(zero, 0.0);
                const one = try self.allocD();
                try self.emitF64Const(one, 1.0);
                const scratch_a = try self.allocD();
                const scratch_b = try self.allocD();
                const scratch_c = try self.allocD();
                const scratch_d = try self.allocD();

                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(reg, time, attack));
                try self.out.append(Asm.@"fmax Dd, Dn, Dm"(reg, reg, zero));
                try self.out.append(Asm.@"fmin Dd, Dn, Dm"(reg, reg, one));

                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_a, attack, decay));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_b, time, attack));
                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_b, scratch_b, decay));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_c, one, sustain));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_b, scratch_c));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_b, one, scratch_b));
                try self.out.append(Asm.@"fcmp Dn, Dm"(time, attack));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, scratch_b, Asm.COND_LT));
                try self.out.append(Asm.@"fcmp Dn, Dm"(time, scratch_a));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, sustain, Asm.COND_LT));

                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_b, time, gate));
                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_b, scratch_b, release));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_b, one, scratch_b));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_b, sustain));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_d, gate, release));
                try self.out.append(Asm.@"fcmp Dn, Dm"(time, gate));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, scratch_b, Asm.COND_LT));
                try self.out.append(Asm.@"fcmp Dn, Dm"(time, scratch_d));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, zero, Asm.COND_LT));
                self.releaseD(zero);
                self.releaseD(one);
                self.releaseD(scratch_a);
                self.releaseD(scratch_b);
                self.releaseD(scratch_c);
                self.releaseD(scratch_d);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                self.consumeValue(value.d);
                self.consumeValue(value.e);
                self.consumeValue(value.f);
                return reg;
            },
            .fadsr_cap => {
                const time = try self.valueD(value.a);
                const attack = try self.valueD(value.b);
                const decay = try self.valueD(value.c);
                const sustain = try self.valueD(value.d);
                const gate = try self.valueD(value.e);
                const release = try self.valueD(value.f);
                const reg = try self.allocD();
                const zero = try self.allocD();
                try self.emitF64Const(zero, 0.0);
                const one = try self.allocD();
                try self.emitF64Const(one, 1.0);
                const scratch_a = try self.allocD();
                const scratch_b = try self.allocD();
                const scratch_c = try self.allocD();
                const scratch_d = try self.allocD();

                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_a, time, attack));
                try self.out.append(Asm.@"fmax Dd, Dn, Dm"(scratch_a, scratch_a, zero));
                try self.out.append(Asm.@"fmin Dd, Dn, Dm"(scratch_a, scratch_a, one));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, one, scratch_a));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_a, scratch_a));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_b, scratch_b));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(reg, one, scratch_b));

                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_c, attack, decay));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, time, attack));
                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_a, scratch_a, decay));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, one, scratch_a));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_a, scratch_a));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_b, scratch_b));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_d, one, sustain));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_b, scratch_d));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_b, sustain, scratch_b));
                try self.out.append(Asm.@"fcmp Dn, Dm"(time, attack));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, scratch_b, Asm.COND_LT));
                try self.out.append(Asm.@"fcmp Dn, Dm"(time, scratch_c));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, sustain, Asm.COND_LT));

                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, time, gate));
                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(scratch_a, scratch_a, release));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(scratch_a, one, scratch_a));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_a, scratch_a));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, scratch_b, scratch_b));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(scratch_b, sustain, scratch_b));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(scratch_c, gate, release));
                try self.out.append(Asm.@"fcmp Dn, Dm"(time, gate));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, scratch_b, Asm.COND_LT));
                try self.out.append(Asm.@"fcmp Dn, Dm"(time, scratch_c));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, reg, zero, Asm.COND_LT));
                self.releaseD(zero);
                self.releaseD(one);
                self.releaseD(scratch_a);
                self.releaseD(scratch_b);
                self.releaseD(scratch_c);
                self.releaseD(scratch_d);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                self.consumeValue(value.d);
                self.consumeValue(value.e);
                self.consumeValue(value.f);
                return reg;
            },
            else => return Error.TypeMismatch,
        }
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
