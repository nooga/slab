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
    load_f64,
    fadd,
    fmul,
    fdiv,
    fclamp,
};

const Value = struct {
    op: Op,
    ty: Ty,
    a: usize = 0,
    b: usize = 0,
    c: usize = 0,
    arg_index: usize = 0,
    int_value: i64 = 0,
    float_value: f64 = 0,
};

const Store = struct {
    ptr: usize,
    value: usize,
};

const Loc = union(enum) {
    none,
    x: u5,
    d: u5,
};

const D_REGS = [_]u5{ 0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
const X_REGS = [_]u5{ 9, 10, 11, 12, 13, 14, 15, 16, 17 };

pub const Builder = struct {
    allocator: std.mem.Allocator,
    values: compat.ArrayList(Value),
    stack: compat.ArrayList(usize),
    stores: compat.ArrayList(Store),
    initial_arity: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .values = compat.ArrayList(Value).init(allocator),
            .stack = compat.ArrayList(usize).init(allocator),
            .stores = compat.ArrayList(Store).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.values.deinit();
        self.stack.deinit();
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
        if (std.mem.eql(u8, word, "swap")) {
            if (self.stack.items.len < 2) return Error.StackUnderflow;
            const n = self.stack.items.len;
            std.mem.swap(usize, &self.stack.items[n - 1], &self.stack.items[n - 2]);
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
        if (std.mem.eql(u8, word, "f!64")) {
            const ptr = try self.pop();
            const value = try self.pop();
            try self.expectTy(ptr, .ptr);
            try self.expectTy(value, .f64);
            try self.stores.append(.{ .ptr = ptr, .value = value });
            return;
        }
        if (std.mem.eql(u8, word, "f+")) {
            try self.floatBin(.fadd);
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
        return Error.UnsupportedWord;
    }

    pub fn emit(self: *Builder, out: *compat.ArrayList(u32)) Error!void {
        if (self.stores.items.len == 0 or self.stack.items.len != 0) return Error.BadStackEffect;

        const locs = self.allocator.alloc(Loc, self.values.items.len) catch return Error.OutOfMemory;
        defer self.allocator.free(locs);
        @memset(locs, .none);

        var cg = Codegen{
            .builder = self,
            .out = out,
            .locs = locs,
        };
        for (self.stores.items) |store| {
            const val_reg = try cg.valueD(store.value);
            const ptr_reg = try cg.valueX(store.ptr);
            try out.append(Asm.str_d_imm(val_reg, ptr_reg, 0));
        }
        if (self.initial_arity > 0) {
            try out.append(Asm.add_imm(21, 21, @intCast(self.initial_arity * 8)));
        }
    }

    fn addValue(self: *Builder, value: Value) Error!usize {
        const id = self.values.items.len;
        try self.values.append(value);
        return id;
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
    word: []const u8,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    tokens: compat.ArrayList(BodyToken),

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{
            .allocator = allocator,
            .tokens = compat.ArrayList(BodyToken).init(allocator),
        };
    }

    pub fn deinit(self: *Program) void {
        self.tokens.deinit();
    }

    pub fn addNumber(self: *Program, value: i64) Error!void {
        try self.tokens.append(.{ .number = value });
    }

    pub fn addFloat(self: *Program, value: f64) Error!void {
        try self.tokens.append(.{ .float = value });
    }

    pub fn addWord(self: *Program, word: []const u8) Error!void {
        try self.tokens.append(.{ .word = word });
    }

    pub fn addTokens(self: *Program, tokens: []const BodyToken) Error!void {
        for (tokens) |tok| try self.tokens.append(tok);
    }

    pub fn build(self: *Program) Error!Builder {
        var arity: usize = 0;
        while (arity <= 16) : (arity += 1) {
            var b = Builder.init(self.allocator);
            errdefer b.deinit();
            var i: usize = 0;
            while (i < arity) : (i += 1) {
                const id = try b.addValue(.{ .op = .arg, .ty = .unknown, .arg_index = i });
                try b.stack.append(id);
            }
            var failed = false;
            for (self.tokens.items) |tok| {
                switch (tok) {
                    .number => |n| b.addNumber(n) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            failed = true;
                            break;
                        },
                    },
                    .float => |f| b.addFloat(f) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            failed = true;
                            break;
                        },
                    },
                    .word => |w| b.addWord(w) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        error.UnsupportedWord => return err,
                        else => {
                            failed = true;
                            break;
                        },
                    },
                }
            }
            if (failed) {
                b.deinit();
                continue;
            }
            if (b.stores.items.len > 0 and b.stack.items.len == 0) {
                b.initial_arity = arity;
                return b;
            }
            b.deinit();
        }
        return Error.BadStackEffect;
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
                else => {},
            }
        }
        allocator.free(cloned);
    }

    for (tokens, 0..) |tok, i| {
        cloned[i] = switch (tok) {
            .number => |n| .{ .number = n },
            .float => |f| .{ .float = f },
            .word => |w| blk: {
                const owned = allocator.dupe(u8, w) catch return Error.OutOfMemory;
                break :blk .{ .word = owned };
            },
        };
        cloned_count += 1;
    }
    return cloned;
}

pub fn freeTokens(allocator: std.mem.Allocator, tokens: []BodyToken) void {
    for (tokens) |tok| switch (tok) {
        .word => |w| allocator.free(w),
        else => {},
    };
    allocator.free(tokens);
}

const Codegen = struct {
    builder: *Builder,
    out: *compat.ArrayList(u32),
    locs: []Loc,
    next_d: usize = 0,
    next_x: usize = 0,

    fn allocD(self: *Codegen) Error!u5 {
        if (self.next_d >= D_REGS.len) return Error.RegisterExhausted;
        const reg = D_REGS[self.next_d];
        self.next_d += 1;
        return reg;
    }

    fn allocX(self: *Codegen) Error!u5 {
        if (self.next_x >= X_REGS.len) return Error.RegisterExhausted;
        const reg = X_REGS[self.next_x];
        self.next_x += 1;
        return reg;
    }

    fn valueX(self: *Codegen, id: usize) Error!u5 {
        if (self.locs[id] == .x) return self.locs[id].x;
        const value = self.builder.values.items[id];
        if (value.ty != .ptr and value.ty != .int) return Error.TypeMismatch;

        const reg = try self.allocX();
        switch (value.op) {
            .arg => {
                const offset = (self.builder.initial_arity - 1 - value.arg_index) * 8;
                try self.out.append(Asm.ldr_x_imm(reg, 21, @intCast(offset)));
                try self.out.append(Asm.@"asr Xn, Xn, #2"(reg));
            },
            .int_const => {
                for (Asm.movImm64(reg, @as(u64, @bitCast(value.int_value)))) |instr| try self.out.append(instr);
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

        const reg = try self.allocD();
        switch (value.op) {
            .arg => {
                const x = try self.allocX();
                const offset = (self.builder.initial_arity - 1 - value.arg_index) * 8;
                try self.out.append(Asm.ldr_x_imm(x, 21, @intCast(offset)));
                try self.out.append(Asm.@"lsr Xn, Xn, #2"(x));
                try self.out.append(Asm.@"lsl Xn, Xn, #2"(x));
                try self.out.append(Asm.@"fmov Dd, Xn"(reg, x));
            },
            .f64_const => try self.emitF64Const(reg, value.float_value),
            .load_f64 => {
                const ptr = try self.valueX(value.a);
                try self.out.append(Asm.ldr_d_imm(reg, ptr, 0));
            },
            .fadd, .fmul, .fdiv => {
                const a = try self.valueD(value.a);
                const b = try self.valueD(value.b);
                const instr = switch (value.op) {
                    .fadd => Asm.@"fadd Dd, Dn, Dm"(reg, a, b),
                    .fmul => Asm.@"fmul Dd, Dn, Dm"(reg, a, b),
                    .fdiv => Asm.@"fdiv Dd, Dn, Dm"(reg, a, b),
                    else => unreachable,
                };
                try self.out.append(instr);
            },
            .fclamp => {
                const x = try self.valueD(value.a);
                const lo = try self.valueD(value.b);
                const hi = try self.valueD(value.c);
                try self.out.append(Asm.@"fmax Dd, Dn, Dm"(reg, x, lo));
                try self.out.append(Asm.@"fmin Dd, Dn, Dm"(reg, reg, hi));
            },
            else => return Error.TypeMismatch,
        }
        self.locs[id] = .{ .d = reg };
        return reg;
    }

    fn emitF64Const(self: *Codegen, reg: u5, value: f64) Error!void {
        if (fmovF64Imm(reg, value)) |instr| {
            try self.out.append(instr);
            return;
        }
        const x = try self.allocX();
        for (Asm.movImm64(x, @bitCast(value))) |instr| try self.out.append(instr);
        try self.out.append(Asm.@"fmov Dd, Xn"(reg, x));
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
