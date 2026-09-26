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
    fms20_lpf4,
    fms20_lpf4_cubic,
    fms20_svf,
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

    pub fn beginLocalFrame(self: *Builder, arity: usize) Error!void {
        if (arity > 16) return Error.RegisterExhausted;
        if (self.stack.items.len < arity) return Error.StackUnderflow;
        var frame = LocalFrame{ .len = arity };
        const base = self.stack.items.len - arity;
        var i: usize = 0;
        while (i < arity) : (i += 1) {
            frame.args[i] = self.stack.items[base + i];
        }
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
        if (std.mem.eql(u8, word, "fms20-lpf4")) {
            try self.addMs20Lpf4(.fms20_lpf4);
            return;
        }
        if (std.mem.eql(u8, word, "fms20-lpf4-cubic")) {
            try self.addMs20Lpf4(.fms20_lpf4_cubic);
            return;
        }
        if (std.mem.eql(u8, word, "fms20-svf")) {
            try self.addMs20Svf();
            return;
        }
        return Error.UnsupportedWord;
    }

    // fms20-svf ( state params input g damping -- out )
    // state  -> *SvfState  { f64 ic1, ic2, fb_dc, out_dc }       (offsets 0,8,16,24)
    // params -> *SvfParams; only the STATIC profile is read from it:
    //   drive@16 resonance@24 fb_gain@32 fb_clip@40 out_clip@48
    //   leak@56 fb_dc_coeff@64 out_dc_coeff@72
    // g and damping are per-sample stack args (params.g@0/damping@8 are ignored
    // here) so a voice can envelope-modulate cutoff per sample.
    // Full g-wet MS-20 topology (4x oversampled nonlinear feedback SVF).
    fn addMs20Svf(self: *Builder) Error!void {
        const damping = try self.pop();
        const g = try self.pop();
        const input = try self.pop();
        const params = try self.pop();
        const state = try self.pop();
        try self.expectTy(state, .ptr);
        try self.expectTy(params, .ptr);
        try self.expectTy(input, .f64);
        try self.expectTy(g, .f64);
        try self.expectTy(damping, .f64);
        const id = try self.addValue(.{
            .op = .fms20_svf,
            .ty = .f64,
            .a = state,
            .b = params,
            .c = input,
            .d = g,
            .e = damping,
        });
        try self.stack.append(id);
    }

    fn addMs20Lpf4(self: *Builder, op: Op) Error!void {
        const drive = try self.pop();
        const damping = try self.pop();
        const g = try self.pop();
        const input = try self.pop();
        const ic2 = try self.pop();
        const ic1 = try self.pop();
        try self.expectTy(ic1, .ptr);
        try self.expectTy(ic2, .ptr);
        try self.expectTy(input, .f64);
        try self.expectTy(g, .f64);
        try self.expectTy(damping, .f64);
        try self.expectTy(drive, .f64);
        const id = try self.addValue(.{
            .op = op,
            .ty = .f64,
            .a = ic1,
            .b = ic2,
            .c = input,
            .d = g,
            .e = damping,
            .f = drive,
        });
        try self.stack.append(id);
    }

    pub fn emit(self: *Builder, out: *compat.ArrayList(u32)) Error!void {
        return self.emitWithArgAbi(out, .tagged);
    }

    // True if the value `id` (an arg) is used as a pointer operand anywhere
    // (load_f64 / ptr_add base, a store pointer, or an fms20 state pointer).
    // Such an arg lives in an x-register, so its d(8+i) reg is free scratch.
    fn argUsedAsPtr(self: *const Builder, id: usize) bool {
        for (self.values.items) |v| {
            switch (v.op) {
                .load_f64, .load_ptr, .ptr_add => if (v.a == id) return true,
                .ptr_add_idx => if (v.a == id) return true,
                .fms20_lpf4, .fms20_lpf4_cubic, .fms20_svf => if (v.a == id or v.b == id) return true,
                else => {},
            }
        }
        for (self.stores.items) |s| if (s.ptr == id) return true;
        return false;
    }

    pub fn emitWithArgAbi(self: *Builder, out: *compat.ArrayList(u32), arg_abi: ArgAbi) Error!void {
        const has_outputs = self.stack.items.len != 0;
        if (self.stores.items.len == 0 and !has_outputs) return Error.BadStackEffect;

        const locs = self.allocator.alloc(Loc, self.values.items.len) catch return Error.OutOfMemory;
        defer self.allocator.free(locs);
        @memset(locs, .none);

        const remaining_uses = self.allocator.alloc(u32, self.values.items.len) catch return Error.OutOfMemory;
        defer self.allocator.free(remaining_uses);
        @memset(remaining_uses, 0);
        self.countUses(remaining_uses);

        var cg = Codegen{
            .builder = self,
            .out = out,
            .locs = locs,
            .remaining_uses = remaining_uses,
            .arg_abi = arg_abi,
        };

        // D-register pool. In raw_registers mode an f64 arg i lives in
        // RAW_D_ARG_REGS[i]=d(8+i) and must not be allocated as scratch; a
        // pointer arg lives in an x-register, so its d(8+i) is free. We free
        // d(8+i) only when arg i is provably used as a pointer (load/ptr+/store/
        // fms20 base) — conservative, so a true f64 arg is always reserved.
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

        const spill_stores = self.stores.items.len > 1;
        const spill_frame_bytes: u12 = @intCast(std.mem.alignForward(usize, self.stores.items.len * 16, 16));
        if (spill_stores) {
            try out.append(Asm.sub_sp_imm(spill_frame_bytes));
            for (self.stores.items, 0..) |store, i| {
                const val_reg = try cg.valueD(store.value);
                const ptr_reg = try cg.valueX(store.ptr);
                const offset: u12 = @intCast(i * 16);
                try out.append(Asm.str_d_imm(val_reg, 31, offset));
                try out.append(Asm.str_x_imm(ptr_reg, 31, offset + 8));
                cg.consumeValue(store.value);
                cg.consumeValue(store.ptr);
            }
        }

        if (has_outputs) {
            const output_locs = self.allocator.alloc(Loc, self.stack.items.len) catch return Error.OutOfMemory;
            defer self.allocator.free(output_locs);
            for (self.stack.items, 0..) |value, i| {
                const ty = self.values.items[value].ty;
                output_locs[i] = if (ty == .f64)
                    .{ .d = try cg.valueD(value) }
                else if (ty == .ptr or ty == .int)
                    .{ .x = try cg.valueX(value) }
                else
                    return Error.TypeMismatch;
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
                try out.append(Asm.add_sp_imm(spill_frame_bytes));
            } else {
                for (self.stores.items) |store| {
                    const val_reg = try cg.valueD(store.value);
                    const ptr_reg = try cg.valueX(store.ptr);
                    try out.append(Asm.str_d_imm(val_reg, ptr_reg, 0));
                    cg.consumeValue(store.value);
                    cg.consumeValue(store.ptr);
                }
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
            for (self.stack.items) |value| cg.consumeValue(value);
        } else {
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
                try out.append(Asm.add_sp_imm(spill_frame_bytes));
            } else {
                for (self.stores.items) |store| {
                    const val_reg = try cg.valueD(store.value);
                    const ptr_reg = try cg.valueX(store.ptr);
                    try out.append(Asm.str_d_imm(val_reg, ptr_reg, 0));
                    cg.consumeValue(store.value);
                    cg.consumeValue(store.ptr);
                }
            }
            if (arg_abi != .raw_registers and self.initial_arity > 0) {
                try out.append(Asm.add_imm(21, 21, @intCast(self.initial_arity * 8)));
            }
        }
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
                .fadsr_linear, .fadsr_cap, .fms20_lpf4, .fms20_lpf4_cubic => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                    remaining_uses[value.c] += 1;
                    remaining_uses[value.d] += 1;
                    remaining_uses[value.e] += 1;
                    remaining_uses[value.f] += 1;
                },
                .fms20_svf => {
                    remaining_uses[value.a] += 1;
                    remaining_uses[value.b] += 1;
                    remaining_uses[value.c] += 1;
                    remaining_uses[value.d] += 1;
                    remaining_uses[value.e] += 1;
                },
            }
        }
        for (self.stores.items) |store| {
            remaining_uses[store.ptr] += 1;
            remaining_uses[store.value] += 1;
        }
        for (self.stack.items) |value| remaining_uses[value] += 1;
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

const Codegen = struct {
    builder: *Builder,
    out: *compat.ArrayList(u32),
    locs: []Loc,
    remaining_uses: []u32,
    arg_abi: ArgAbi,
    next_d: usize = 0,
    next_x: usize = 0,
    d_pool: [32]u5 = undefined,
    d_pool_len: usize = 0,
    free_d: [32]u5 = undefined,
    free_d_count: usize = 0,
    free_x: [RAW_X_SCRATCH_REGS.len]u5 = undefined,
    free_x_count: usize = 0,

    fn allocD(self: *Codegen) Error!u5 {
        if (self.free_d_count > 0) {
            self.free_d_count -= 1;
            return self.free_d[self.free_d_count];
        }
        if (self.next_d >= self.d_pool_len) return Error.RegisterExhausted;
        const reg = self.d_pool[self.next_d];
        self.next_d += 1;
        return reg;
    }

    fn allocX(self: *Codegen) Error!u5 {
        if (self.free_x_count > 0) {
            self.free_x_count -= 1;
            return self.free_x[self.free_x_count];
        }
        const regs = if (self.arg_abi == .raw_registers) RAW_X_SCRATCH_REGS[0..] else X_REGS[0..];
        if (self.next_x >= regs.len) return Error.RegisterExhausted;
        const reg = regs[self.next_x];
        self.next_x += 1;
        return reg;
    }

    fn releaseD(self: *Codegen, reg: u5) void {
        std.debug.assert(self.free_d_count < self.free_d.len);
        self.free_d[self.free_d_count] = reg;
        self.free_d_count += 1;
    }

    fn releaseX(self: *Codegen, reg: u5) void {
        std.debug.assert(self.free_x_count < self.free_x.len);
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
    }

    fn valueX(self: *Codegen, id: usize) Error!u5 {
        if (self.locs[id] == .x) return self.locs[id].x;
        const value = self.builder.values.items[id];
        if (value.ty != .ptr and value.ty != .int) return Error.TypeMismatch;

        if (value.op == .arg and self.arg_abi == .raw_registers) {
            if (value.arg_index >= RAW_X_ARG_REGS.len) return Error.RegisterExhausted;
            const reg = RAW_X_ARG_REGS[value.arg_index];
            self.locs[id] = .{ .x = reg };
            return reg;
        }

        const reg = try self.allocX();
        switch (value.op) {
            .arg => {
                const offset = (self.builder.initial_arity - 1 - value.arg_index) * 8;
                try self.out.append(Asm.ldr_x_imm(reg, 21, @intCast(offset)));
                if (self.arg_abi == .tagged) {
                    try self.out.append(Asm.@"asr Xn, Xn, #2"(reg));
                }
            },
            .int_const => {
                for (Asm.movImm64(reg, @as(u64, @bitCast(value.int_value)))) |instr| try self.out.append(instr);
            },
            .ptr_add => {
                const base = try self.valueX(value.a);
                try self.out.append(Asm.add_imm(reg, base, @intCast(value.int_value)));
                self.consumeValue(value.a);
            },
            .load_ptr => {
                const ptr = try self.valueX(value.a);
                try self.out.append(Asm.ldr_x_imm(reg, ptr, 0));
                self.consumeValue(value.a);
            },
            .ptr_add_idx => {
                const base = try self.valueX(value.a);
                const idx = try self.valueD(value.b);
                const xi = try self.allocX();
                try self.out.append(Asm.@"fcvtzs Xd, Dn"(xi, idx));
                try self.out.append(Asm.@"add Xd, Xn, Xm, lsl #3"(reg, base, xi));
                self.releaseX(xi);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
            },
            else => return Error.TypeMismatch,
        }
        self.locs[id] = .{ .x = reg };
        return reg;
    }

    fn valueD(self: *Codegen, id: usize) Error!u5 {
        if (self.locs[id] == .d) return self.locs[id].d;
        const value = self.builder.values.items[id];
        if (value.ty != .f64) return Error.TypeMismatch;

        if (value.op == .arg and self.arg_abi == .raw_registers) {
            if (value.arg_index >= RAW_D_ARG_REGS.len) return Error.RegisterExhausted;
            const reg = RAW_D_ARG_REGS[value.arg_index];
            self.locs[id] = .{ .d = reg };
            return reg;
        }

        const reg = try self.allocD();
        switch (value.op) {
            .arg => {
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
            },
            .f64_const => try self.emitF64Const(reg, value.float_value),
            .load_f64 => {
                const ptr = try self.valueX(value.a);
                try self.out.append(Asm.ldr_d_imm(reg, ptr, 0));
                self.consumeValue(value.a);
            },
            .fadd, .fsub, .fmul, .fdiv => {
                const a = try self.valueD(value.a);
                const b = try self.valueD(value.b);
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
            },
            .fclamp => {
                const x = try self.valueD(value.a);
                const lo = try self.valueD(value.b);
                const hi = try self.valueD(value.c);
                try self.out.append(Asm.@"fmax Dd, Dn, Dm"(reg, x, lo));
                try self.out.append(Asm.@"fmin Dd, Dn, Dm"(reg, reg, hi));
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
            },
            .ffrac => {
                // frac(x) = x - floor(x)
                const x = try self.valueD(value.a);
                const fl = try self.allocD();
                try self.out.append(Asm.@"frintm Dd, Dn"(fl, x));
                try self.out.append(Asm.@"fsub Dd, Dn, Dm"(reg, x, fl));
                self.releaseD(fl);
                self.consumeValue(value.a);
            },
            .fwrap01 => {
                const x = try self.valueD(value.a);
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
            },
            .fsel_lt => {
                const a = try self.valueD(value.a);
                const b = try self.valueD(value.b);
                const if_true = try self.valueD(value.c);
                const if_false = try self.valueD(value.d);
                try self.out.append(Asm.@"fcmp Dn, Dm"(a, b));
                try self.out.append(Asm.@"fcsel Dd, Dn, Dm, cond"(reg, if_true, if_false, Asm.COND_LT));
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                self.consumeValue(value.d);
            },
            .fcapramp => {
                const phase = try self.valueD(value.a);
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
            },
            .fpolyblep => {
                const phase = try self.valueD(value.a);
                const dt = try self.valueD(value.b);
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
            },
            .fpulseblep => {
                const phase = try self.valueD(value.a);
                const dt = try self.valueD(value.b);
                const width = try self.valueD(value.c);
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
            },
            .fadsr_linear => {
                const time = try self.valueD(value.a);
                const attack = try self.valueD(value.b);
                const decay = try self.valueD(value.c);
                const sustain = try self.valueD(value.d);
                const gate = try self.valueD(value.e);
                const release = try self.valueD(value.f);
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
            },
            .fadsr_cap => {
                const time = try self.valueD(value.a);
                const attack = try self.valueD(value.b);
                const decay = try self.valueD(value.c);
                const sustain = try self.valueD(value.d);
                const gate = try self.valueD(value.e);
                const release = try self.valueD(value.f);
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
            },
            .fms20_lpf4, .fms20_lpf4_cubic => {
                const use_cubic_clip = value.op == .fms20_lpf4_cubic;
                const ic1_ptr = try self.valueX(value.a);
                const ic2_ptr = try self.valueX(value.b);
                const input = try self.valueD(value.c);
                const g = try self.valueD(value.d);
                const damping = try self.valueD(value.e);
                const drive = try self.valueD(value.f);

                const ic1 = try self.allocD();
                const ic2 = try self.allocD();
                const one = try self.allocD();
                const two = try self.allocD();
                const clip_state = try self.allocD();
                const clip_out = try self.allocD();
                const c27 = try self.allocD();
                const c9 = try self.allocD();
                const neg_one = try self.allocD();
                const s0 = try self.allocD();
                const s1 = try self.allocD();
                const s2 = try self.allocD();
                const s3 = try self.allocD();
                const s4 = try self.allocD();
                const s5 = try self.allocD();
                const s6 = try self.allocD();

                try self.out.append(Asm.ldr_d_imm(ic1, ic1_ptr, 0));
                try self.out.append(Asm.ldr_d_imm(ic2, ic2_ptr, 0));
                try self.emitF64Const(one, 1.0);
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(two, one, one));
                try self.emitF64Const(clip_state, 1.05);
                try self.emitF64Const(clip_out, 1.8);
                if (use_cubic_clip) {
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(c27, two, one));
                    try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(c27, one, c27));
                    try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(c9, one, two));
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(c9, one, c9));
                } else {
                    try self.emitF64Const(c27, 27.0);
                    try self.emitF64Const(c9, 9.0);
                }
                try self.emitF64Const(neg_one, -1.0);

                if (use_cubic_clip) {
                    try self.emitCubicClipInto(s0, input, drive, one, neg_one, c27, c9, s3, s4, s5);
                } else {
                    try self.emitTanhRationalInto(s0, input, drive, one, c27, c9, neg_one, s3, s4, s5);
                }

                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s3, two, damping));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s2, s3, g));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s3, s3, g));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s3, s3, one));
                try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s4, g, g));
                try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s3, s3, s4));
                try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(s1, one, s3));

                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s3, s2, ic1));
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(s3, s0, s3));
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(s3, s3, ic2));
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s3, s3, s1));

                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s4, g, s3));
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s5, s4, ic1));
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s4, s4, s5));
                    if (use_cubic_clip) {
                        try self.emitCubicClipInto(ic1, s4, clip_state, one, neg_one, c27, c9, s3, s4, s6);
                    } else {
                        try self.emitTanhRationalInto(ic1, s4, clip_state, one, c27, c9, neg_one, s3, s4, s6);
                    }

                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s4, g, s5));
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(reg, s4, ic2));
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s4, s4, reg));
                    if (use_cubic_clip) {
                        try self.emitCubicClipInto(ic2, s4, clip_state, one, neg_one, c27, c9, s3, s4, s6);
                    } else {
                        try self.emitTanhRationalInto(ic2, s4, clip_state, one, c27, c9, neg_one, s3, s4, s6);
                    }
                }

                if (use_cubic_clip) {
                    try self.emitCubicClipInto(reg, reg, clip_out, one, neg_one, c27, c9, s0, s1, s2);
                } else {
                    try self.emitTanhRationalInto(reg, reg, clip_out, one, c27, c9, neg_one, s0, s1, s2);
                }
                try self.out.append(Asm.str_d_imm(ic1, ic1_ptr, 0));
                try self.out.append(Asm.str_d_imm(ic2, ic2_ptr, 0));
                self.releaseD(ic1);
                self.releaseD(ic2);
                self.releaseD(one);
                self.releaseD(two);
                self.releaseD(clip_state);
                self.releaseD(clip_out);
                self.releaseD(c27);
                self.releaseD(c9);
                self.releaseD(neg_one);
                self.releaseD(s0);
                self.releaseD(s1);
                self.releaseD(s2);
                self.releaseD(s3);
                self.releaseD(s4);
                self.releaseD(s5);
                self.releaseD(s6);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.c);
                self.consumeValue(value.d);
                self.consumeValue(value.e);
                self.consumeValue(value.f);
            },
            .fms20_svf => {
                // ( state params input g damping -- out )  full g-wet topology.
                const state_ptr = try self.valueX(value.a);
                const params_ptr = try self.valueX(value.b);
                const x = try self.valueD(value.c);
                const g = try self.valueD(value.d);
                const damping = try self.valueD(value.e);

                // Live filter state (offsets 0,8,16,24 in SvfState).
                const ic1 = try self.allocD();
                const ic2 = try self.allocD();
                const fb_dc = try self.allocD();
                const out_dc = try self.allocD();
                try self.out.append(Asm.ldr_d_imm(ic1, state_ptr, 0));
                try self.out.append(Asm.ldr_d_imm(ic2, state_ptr, 8));
                try self.out.append(Asm.ldr_d_imm(fb_dc, state_ptr, 16));
                try self.out.append(Asm.ldr_d_imm(out_dc, state_ptr, 24));

                // Constants for the rational-tanh clip. (0.20 and res*fb_gain
                // are recomputed in the loop to keep register pressure low.)
                const one = try self.allocD();
                const neg_one = try self.allocD();
                const c27 = try self.allocD();
                const c9 = try self.allocD();
                try self.emitF64Const(one, 1.0);
                try self.emitF64Const(neg_one, -1.0);
                try self.emitF64Const(c27, 27.0);
                try self.emitF64Const(c9, 9.0);

                // Loop-invariants, computed once: 2*damping+g, h=1/(1+2dg+g^2), x*drive.
                const a2dg = try self.allocD();
                const h = try self.allocD();
                const xd = try self.allocD();
                {
                    const drive = try self.allocD();
                    const tmp = try self.allocD();
                    try self.out.append(Asm.ldr_d_imm(drive, params_ptr, 16));
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(a2dg, damping, damping)); // 2*damping
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(tmp, a2dg, g)); // 2*damping*g
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(a2dg, a2dg, g)); // 2*damping+g
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(h, one, tmp)); // 1+2dg
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(tmp, g, g)); // g*g
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(h, h, tmp)); // 1+2dg+g*g
                    try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(h, one, h)); // 1/denom
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(xd, x, drive));
                    self.releaseD(drive);
                    self.releaseD(tmp);
                }
                // x (input) and damping are dead after the precompute; free
                // their registers so the loop scratch can reuse them. This
                // keeps register pressure low enough to inline into a voice.
                self.consumeValue(value.c);
                self.consumeValue(value.e);

                const s0 = try self.allocD();
                const s1 = try self.allocD();
                const s2 = try self.allocD();
                const s3 = try self.allocD();
                const cf = try self.allocD(); // per-iter coeff loaded from params
                const fb = try self.allocD(); // feedback

                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    // fb_dc += fb_dc_coeff * (ic2 - fb_dc)
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(s0, ic2, fb_dc));
                    try self.out.append(Asm.ldr_d_imm(cf, params_ptr, 64)); // fb_dc_coeff
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s0, s0, cf));
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(fb_dc, fb_dc, s0));
                    // feedback = clip((ic2 - fb_dc) * (res*fb_gain), fb_clip)
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(s0, ic2, fb_dc));
                    try self.out.append(Asm.ldr_d_imm(cf, params_ptr, 24)); // resonance
                    try self.out.append(Asm.ldr_d_imm(s1, params_ptr, 32)); // fb_gain
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(cf, cf, s1)); // res*fb_gain
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s0, s0, cf));
                    try self.out.append(Asm.ldr_d_imm(cf, params_ptr, 40)); // fb_clip
                    try self.emitTanhRationalInto(fb, s0, cf, one, c27, c9, neg_one, s1, s2, s3);
                    // driven = clip(x*drive - feedback, 1.0)
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(s0, xd, fb));
                    try self.emitTanhRationalInto(s0, s0, one, one, c27, c9, neg_one, s1, s2, s3);
                    // hp = (driven - (2*damping+g)*ic1 - ic2) * h
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s1, a2dg, ic1));
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(s0, s0, s1));
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(s0, s0, ic2));
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s0, s0, h)); // s0 = hp
                    // bp = g*hp + ic1 ; next_ic1 = g*hp + bp ; ic1 = leak*next_ic1
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s1, g, s0)); // g*hp
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s2, s1, ic1)); // bp
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s3, s1, s2)); // next_ic1
                    try self.out.append(Asm.ldr_d_imm(cf, params_ptr, 56)); // leak
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(ic1, s3, cf));
                    // lp = g*bp + ic2 ; next_ic2 = g*bp + lp ; ic2 = leak*next_ic2
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s1, g, s2)); // g*bp
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s3, s1, ic2)); // lp
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s0, s1, s3)); // next_ic2
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(ic2, s0, cf)); // cf still = leak
                    // colored = clip(lp + 0.20*bp, out_clip)
                    try self.emitF64Const(s1, 0.20);
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s0, s1, s2)); // 0.20*bp
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s0, s3, s0)); // lp + 0.20*bp
                    try self.out.append(Asm.ldr_d_imm(cf, params_ptr, 48)); // out_clip
                    try self.emitTanhRationalInto(s0, s0, cf, one, c27, c9, neg_one, s1, s2, s3);
                    // out_dc += out_dc_coeff*(colored - out_dc) ; out = colored - out_dc
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(s1, s0, out_dc));
                    try self.out.append(Asm.ldr_d_imm(cf, params_ptr, 72)); // out_dc_coeff
                    try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s1, s1, cf));
                    try self.out.append(Asm.@"fadd Dd, Dn, Dm"(out_dc, out_dc, s1));
                    try self.out.append(Asm.@"fsub Dd, Dn, Dm"(reg, s0, out_dc));
                }

                try self.out.append(Asm.str_d_imm(ic1, state_ptr, 0));
                try self.out.append(Asm.str_d_imm(ic2, state_ptr, 8));
                try self.out.append(Asm.str_d_imm(fb_dc, state_ptr, 16));
                try self.out.append(Asm.str_d_imm(out_dc, state_ptr, 24));

                self.releaseD(ic1);
                self.releaseD(ic2);
                self.releaseD(fb_dc);
                self.releaseD(out_dc);
                self.releaseD(one);
                self.releaseD(neg_one);
                self.releaseD(c27);
                self.releaseD(c9);
                self.releaseD(a2dg);
                self.releaseD(h);
                self.releaseD(xd);
                self.releaseD(s0);
                self.releaseD(s1);
                self.releaseD(s2);
                self.releaseD(s3);
                self.releaseD(cf);
                self.releaseD(fb);
                self.consumeValue(value.a);
                self.consumeValue(value.b);
                self.consumeValue(value.d);
            },
            else => return Error.TypeMismatch,
        }
        self.locs[id] = .{ .d = reg };
        return reg;
    }

    fn emitTanhRationalInto(
        self: *Codegen,
        dst: u5,
        x: u5,
        amount: u5,
        hi: u5,
        c27: u5,
        c9: u5,
        neg_one: u5,
        s0: u5,
        s1: u5,
        s2: u5,
    ) Error!void {
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s0, x, amount));
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s1, s0, s0));
        try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s2, c27, s1));
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s2, s0, s2));
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s1, c9, s1));
        try self.out.append(Asm.@"fadd Dd, Dn, Dm"(s1, c27, s1));
        try self.out.append(Asm.@"fdiv Dd, Dn, Dm"(dst, s2, s1));
        try self.out.append(Asm.@"fmax Dd, Dn, Dm"(dst, dst, neg_one));
        try self.out.append(Asm.@"fmin Dd, Dn, Dm"(dst, dst, hi));
    }

    fn emitCubicClipInto(
        self: *Codegen,
        dst: u5,
        x: u5,
        amount: u5,
        hi: u5,
        lo: u5,
        one_third: u5,
        gain: u5,
        s0: u5,
        s1: u5,
        s2: u5,
    ) Error!void {
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s0, x, amount));
        try self.out.append(Asm.@"fmax Dd, Dn, Dm"(s0, s0, lo));
        try self.out.append(Asm.@"fmin Dd, Dn, Dm"(s0, s0, hi));
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s1, s0, s0));
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s2, s1, s0));
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(s2, s2, one_third));
        try self.out.append(Asm.@"fsub Dd, Dn, Dm"(dst, s0, s2));
        try self.out.append(Asm.@"fmul Dd, Dn, Dm"(dst, dst, gain));
    }

    fn emitF64Const(self: *Codegen, reg: u5, value: f64) Error!void {
        if (fmovF64Imm(reg, value)) |instr| {
            try self.out.append(instr);
            return;
        }
        const x = try self.allocX();
        for (Asm.movImm64(x, @bitCast(value))) |instr| try self.out.append(instr);
        try self.out.append(Asm.@"fmov Dd, Xn"(reg, x));
        self.releaseX(x);
    }
};

fn fmovF64Imm(reg: u5, value: f64) ?u32 {
    const base: u32 = switch (@as(u64, @bitCast(value))) {
        @as(u64, @bitCast(@as(f64, 2.5))) => 0x1e609000,
        @as(u64, @bitCast(@as(f64, 4.0))) => 0x1e621000,
        @as(u64, @bitCast(@as(f64, -4.0))) => 0x1e721000,
        @as(u64, @bitCast(@as(f64, 27.0))) => 0x1e677000,
        @as(u64, @bitCast(@as(f64, 9.0))) => 0x1e645000,
        @as(u64, @bitCast(@as(f64, 1.0))) => 0x1e6e1000,
        @as(u64, @bitCast(@as(f64, -1.0))) => 0x1e7e1000,
        @as(u64, @bitCast(@as(f64, 0.125))) => 0x1e681000,
        else => return null,
    };
    return base | @as(u32, reg);
}
