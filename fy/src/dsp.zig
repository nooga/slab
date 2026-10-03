const std = @import("std");
const Asm = @import("asm.zig");
const compat = @import("compat.zig");

const HOLD_REGS = [_]u5{ 12, 13, 14, 15 };
const PairRegs = struct {
    first: u5,
    second: u5,
};

const MovRegs = struct {
    dst: u5,
    src: u5,
};

const Literal = struct {
    reg: u5,
    value: u64,
    end: usize,
};

const AddRegs = struct {
    dst: u5,
    lhs: u5,
    rhs: u5,
};

const FloatBinOp = struct {
    dst: u5,
    lhs: u5,
    rhs: u5,
    op: enum { add, mul },
};

fn isAnyLocalBranch(instr: u32) bool {
    return (instr & 0xfc000000) == 0x14000000 or
        (instr & 0x7e000000) == 0x34000000 or
        (instr & 0xff000010) == 0x54000000;
}

fn isBl(instr: u32) bool {
    return (instr & 0xfc000000) == 0x94000000;
}

fn isBlr(instr: u32) bool {
    return (instr & 0xfffffc1f) == 0xd63f0000;
}

fn pushReg(instr: u32) ?u5 {
    inline for (0..32) |n| {
        if (instr == Asm.@".push Xn"(n)) return @intCast(n);
    }
    return null;
}

fn popReg(instr: u32) ?u5 {
    inline for (0..32) |n| {
        if (instr == Asm.@".pop Xn"(n)) return @intCast(n);
    }
    return null;
}

fn isPairStackOp(instr: u32) bool {
    return instr == Asm.@".push x0, x1" or
        instr == Asm.@".push x1, x0" or
        instr == Asm.@".push x2, x3" or
        instr == Asm.@".pop x0, x1" or
        instr == Asm.@".pop x1, x0" or
        instr == Asm.@".pop x2, x3";
}

fn pairPushRegs(instr: u32) ?PairRegs {
    if (instr == Asm.@".push x0, x1") return .{ .first = 0, .second = 1 };
    if (instr == Asm.@".push x1, x0") return .{ .first = 1, .second = 0 };
    if (instr == Asm.@".push x2, x3") return .{ .first = 3, .second = 2 };
    return null;
}

fn pairPopRegs(instr: u32) ?PairRegs {
    if (instr == Asm.@".pop x0, x1") return .{ .first = 0, .second = 1 };
    if (instr == Asm.@".pop x1, x0") return .{ .first = 1, .second = 0 };
    if (instr == Asm.@".pop x2, x3") return .{ .first = 2, .second = 3 };
    return null;
}

fn isWideMoveToReg(instr: u32, reg: u5) bool {
    return (instr & 0x1f) == reg and
        ((instr & 0xff800000) == 0xd2800000 or
            (instr & 0xff800000) == 0xf2800000);
}

fn isMovz(instr: u32) bool {
    return (instr & 0xff800000) == 0xd2800000;
}

fn retargetPendingX0Literal(out: *compat.ArrayList(u32), dst: u5) bool {
    if (out.items.len == 0 or !isWideMoveToReg(out.items[out.items.len - 1], 0)) return false;

    var start = out.items.len - 1;
    while (start > 0 and !isMovz(out.items[start]) and isWideMoveToReg(out.items[start - 1], 0)) {
        start -= 1;
    }
    if (!isMovz(out.items[start])) return false;

    var i = start;
    while (i < out.items.len) : (i += 1) {
        out.items[i] = (out.items[i] & ~@as(u32, 0x1f)) | @as(u32, dst);
    }
    return true;
}

fn appendMov(out: *compat.ArrayList(u32), dst: u5, src: u5) !void {
    if (src == 0 and retargetPendingX0Literal(out, dst)) return;
    if (dst != src) try out.append(Asm.@"mov Xd, Xn"(dst, src));
}

fn movRegs(instr: u32) ?MovRegs {
    if ((instr & 0xffe0ffe0) != 0xaa0003e0) return null;
    return .{
        .dst = @intCast(instr & 0x1f),
        .src = @intCast((instr >> 16) & 0x1f),
    };
}

fn addReg(dst: u5, lhs: u5, rhs: u5) u32 {
    return 0x8b000000 | @as(u32, dst) | (@as(u32, lhs) << 5) | (@as(u32, rhs) << 16);
}

fn addRegs(instr: u32) ?AddRegs {
    if ((instr & 0xffe00000) != 0x8b000000) return null;
    return .{
        .dst = @intCast(instr & 0x1f),
        .lhs = @intCast((instr >> 5) & 0x1f),
        .rhs = @intCast((instr >> 16) & 0x1f),
    };
}

fn fmovXFromD(instr: u32) ?MovRegs {
    if ((instr & 0xfffffc00) != (Asm.@"fmov Xd, Dn"(0, 0) & 0xfffffc00)) return null;
    return .{
        .dst = @intCast(instr & 0x1f),
        .src = @intCast((instr >> 5) & 0x1f),
    };
}

fn fmovDFromX(instr: u32) ?MovRegs {
    if ((instr & 0xfffffc00) != (Asm.@"fmov Dd, Xn"(0, 0) & 0xfffffc00)) return null;
    return .{
        .dst = @intCast(instr & 0x1f),
        .src = @intCast((instr >> 5) & 0x1f),
    };
}

fn sameRegOp(instr: u32, pattern: u32) ?u5 {
    if ((instr & 0xfffffc00) != (pattern & 0xfffffc00)) return null;
    const reg: u5 = @intCast(instr & 0x1f);
    if (((instr >> 5) & 0x1f) != reg) return null;
    return reg;
}

fn floatBinOp(instr: u32) ?FloatBinOp {
    const op = instr & 0xffe0fc00;
    if (op != 0x1e602800 and op != 0x1e600800) return null;

    return .{
        .dst = @intCast(instr & 0x1f),
        .lhs = @intCast((instr >> 5) & 0x1f),
        .rhs = @intCast((instr >> 16) & 0x1f),
        .op = if (op == 0x1e602800) .add else .mul,
    };
}

fn wideMoveShift(instr: u32) u6 {
    return @intCast(((instr >> 21) & 0x3) * 16);
}

fn wideMoveImm(instr: u32) u64 {
    return @as(u64, (instr >> 5) & 0xffff);
}

fn parseLiteral(code: []const u32, start: usize) ?Literal {
    if (start >= code.len or !isMovz(code[start])) return null;

    const reg: u5 = @intCast(code[start] & 0x1f);
    var value = wideMoveImm(code[start]) << wideMoveShift(code[start]);
    var end = start + 1;

    while (end < code.len and
        isWideMoveToReg(code[end], reg) and
        !isMovz(code[end]))
    {
        const shift = wideMoveShift(code[end]);
        const mask = @as(u64, 0xffff) << shift;
        value = (value & ~mask) | (wideMoveImm(code[end]) << shift);
        end += 1;
    }

    return .{ .reg = reg, .value = value, .end = end };
}

fn appendLiteral(out: *compat.ArrayList(u32), reg: u5, value: u64) !void {
    const rr: u32 = reg;
    try out.append(0xd2800000 | rr | (@as(u32, @truncate(value)) & 0xffff) << 5);
    if (value > 0xffff) {
        try out.append(0xf2a00000 | rr | (@as(u32, @truncate(value >> 16)) & 0xffff) << 5);
    }
    if (value > 0xffffffff) {
        try out.append(0xf2c00000 | rr | (@as(u32, @truncate(value >> 32)) & 0xffff) << 5);
    }
    if (value > 0xffffffffffff) {
        try out.append(0xf2e00000 | rr | (@as(u32, @truncate(value >> 48)) & 0xffff) << 5);
    }
}

fn writeF64ScalarLiteralReturn(code: *compat.ArrayList(u32), value: f64) bool {
    var out: [6]u32 = undefined;
    var len: usize = 0;
    const bits: u64 = @bitCast(value);

    out[len] = 0xd2800000 | (@as(u32, @truncate(bits)) & 0xffff) << 5;
    len += 1;
    if (bits > 0xffff) {
        out[len] = 0xf2a00000 | (@as(u32, @truncate(bits >> 16)) & 0xffff) << 5;
        len += 1;
    }
    if (bits > 0xffffffff) {
        out[len] = 0xf2c00000 | (@as(u32, @truncate(bits >> 32)) & 0xffff) << 5;
        len += 1;
    }
    if (bits > 0xffffffffffff) {
        out[len] = 0xf2e00000 | (@as(u32, @truncate(bits >> 48)) & 0xffff) << 5;
        len += 1;
    }
    out[len] = Asm.@"fmov Dd, Xn"(0, 0);
    len += 1;
    out[len] = Asm.ret;
    len += 1;

    if (code.items.len < len) return false;
    std.mem.copyForwards(u32, code.items[0..len], out[0..len]);
    code.shrinkRetainingCapacity(len);
    return true;
}

fn optimizeF64LiteralOps(code: *compat.ArrayList(u32)) bool {
    var x_known = [_]bool{false} ** 32;
    var x_value: [32]u64 = undefined;
    var d_known = [_]bool{false} ** 32;
    var d_value: [32]f64 = undefined;
    var saw_float_op = false;

    var i: usize = 0;
    while (i < code.items.len) {
        const instr = code.items[i];

        if (instr == Asm.ret) {
            if (!saw_float_op or !d_known[0]) return false;
            return writeF64ScalarLiteralReturn(code, d_value[0]);
        }

        if (parseLiteral(code.items, i)) |literal| {
            x_known[literal.reg] = true;
            x_value[literal.reg] = literal.value;
            i = literal.end;
            continue;
        }

        if (movRegs(instr)) |mov| {
            x_known[mov.dst] = x_known[mov.src];
            if (x_known[mov.src]) x_value[mov.dst] = x_value[mov.src];
            i += 1;
            continue;
        }

        if (sameRegOp(instr, Asm.@"lsr Xn, Xn, #2"(0))) |reg| {
            if (!x_known[reg]) return false;
            x_value[reg] >>= 2;
            i += 1;
            continue;
        }

        if (sameRegOp(instr, Asm.@"lsl Xn, Xn, #2"(0))) |reg| {
            if (!x_known[reg]) return false;
            x_value[reg] <<= 2;
            i += 1;
            continue;
        }

        if (sameRegOp(instr, Asm.@"add Xn, Xn, #2"(0))) |reg| {
            if (!x_known[reg]) return false;
            x_value[reg] +%= 2;
            i += 1;
            continue;
        }

        if (fmovDFromX(instr)) |mov| {
            if (!x_known[mov.src]) return false;
            d_known[mov.dst] = true;
            d_value[mov.dst] = @bitCast(x_value[mov.src]);
            i += 1;
            continue;
        }

        if (fmovXFromD(instr)) |mov| {
            if (!d_known[mov.src]) return false;
            x_known[mov.dst] = true;
            x_value[mov.dst] = @bitCast(d_value[mov.src]);
            i += 1;
            continue;
        }

        if (floatBinOp(instr)) |op| {
            if (!d_known[op.lhs] or !d_known[op.rhs]) return false;
            d_known[op.dst] = true;
            d_value[op.dst] = switch (op.op) {
                .add => d_value[op.lhs] + d_value[op.rhs],
                .mul => d_value[op.lhs] * d_value[op.rhs],
            };
            saw_float_op = true;
            i += 1;
            continue;
        }

        return false;
    }

    return false;
}

fn optimizeLiteralIntegerAdds(allocator: std.mem.Allocator, code: *compat.ArrayList(u32)) !void {
    var out = compat.ArrayList(u32).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(code.items.len);

    var i: usize = 0;
    var changed = false;
    while (i < code.items.len) {
        if (parseLiteral(code.items, i)) |a| {
            if (parseLiteral(code.items, a.end)) |b| {
                if (b.end < code.items.len) {
                    if (addRegs(code.items[b.end])) |add| {
                        const matches_ordered = add.lhs == b.reg and add.rhs == a.reg;
                        const matches_swapped = add.lhs == a.reg and add.rhs == b.reg;
                        if (matches_ordered or matches_swapped) {
                            try appendLiteral(&out, add.dst, a.value +% b.value);
                            i = b.end + 1;
                            changed = true;
                            continue;
                        }
                    }
                }
            }
        }

        try out.append(code.items[i]);
        i += 1;
    }

    if (!changed) {
        out.deinit();
        return;
    }

    code.clearRetainingCapacity();
    try code.appendSlice(out.items);
    out.deinit();
}

fn optimizeIntegerAddMovChains(allocator: std.mem.Allocator, code: *compat.ArrayList(u32)) !void {
    var out = compat.ArrayList(u32).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(code.items.len);

    var i: usize = 0;
    var changed = false;
    while (i < code.items.len) {
        if (i + 3 < code.items.len and
            code.items[i + 2] == Asm.@"add x0, x0, x1")
        {
            if (movRegs(code.items[i])) |mov_top| {
                if (movRegs(code.items[i + 1])) |mov_next| {
                    if (movRegs(code.items[i + 3])) |mov_result| {
                        if (mov_top.dst == 0 and mov_next.dst == 1 and mov_result.src == 0) {
                            try out.append(addReg(mov_result.dst, mov_top.src, mov_next.src));
                            i += 4;
                            changed = true;
                            continue;
                        }
                    }
                }
            }
        }

        try out.append(code.items[i]);
        i += 1;
    }

    if (!changed) {
        out.deinit();
        return;
    }

    code.clearRetainingCapacity();
    try code.appendSlice(out.items);
    out.deinit();
    try optimizeLiteralIntegerAdds(allocator, code);
}

fn flush(out: *compat.ArrayList(u32), stack: []const u5) !void {
    var i: usize = 0;
    while (i < stack.len) : (i += 1) {
        try out.append(Asm.@".push Xn"(stack[i]));
    }
}

fn needsRealFyStack(instr: u32) bool {
    return instr == Asm.@"ldr x0, [x21, x0, lsl #3]" or
        instr == Asm.@"sub x0, x22, x21";
}

/// Optimize straight-line DSP code by keeping fy stack values in caller-saved
/// registers instead of eagerly spilling every push/pop to the fy data stack.
/// Branch/call bodies are deliberately skipped for now; control-flow-aware
/// flushing belongs in the next pass.
pub fn optimizeRegisterStack(allocator: std.mem.Allocator, code: *compat.ArrayList(u32)) !void {
    if (code.items.len == 0) return;
    for (code.items) |instr| {
        if (isAnyLocalBranch(instr) or isBl(instr) or isBlr(instr)) return;
    }

    var out = compat.ArrayList(u32).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(code.items.len);

    var stack: [HOLD_REGS.len]u5 = undefined;
    var depth: usize = 0;
    var changed = false;

    for (code.items, 0..) |instr, i| {
        if (pairPushRegs(instr)) |regs| {
            if (depth + 2 <= HOLD_REGS.len) {
                const first_hold = HOLD_REGS[depth];
                try appendMov(&out, first_hold, regs.first);
                stack[depth] = first_hold;
                depth += 1;

                const second_hold = HOLD_REGS[depth];
                try appendMov(&out, second_hold, regs.second);
                stack[depth] = second_hold;
                depth += 1;
                changed = true;
                continue;
            }
            try flush(&out, stack[0..depth]);
            depth = 0;
            try out.append(instr);
            continue;
        }

        if (pairPopRegs(instr)) |regs| {
            if (depth >= 2) {
                depth -= 1;
                try appendMov(&out, regs.first, stack[depth]);
                depth -= 1;
                try appendMov(&out, regs.second, stack[depth]);
                changed = true;
                continue;
            }
            try flush(&out, stack[0..depth]);
            depth = 0;
            try out.append(instr);
            continue;
        }

        if (pushReg(instr)) |src| {
            if (depth < HOLD_REGS.len) {
                const hold = HOLD_REGS[depth];
                try appendMov(&out, hold, src);
                stack[depth] = hold;
                depth += 1;
                changed = true;
                continue;
            }
            try flush(&out, stack[0..depth]);
            depth = 0;
            try out.append(instr);
            continue;
        }

        if (popReg(instr)) |dst| {
            if (depth > 0) {
                depth -= 1;
                try appendMov(&out, dst, stack[depth]);
                changed = true;
                continue;
            }
            try out.append(instr);
            continue;
        }

        if (isPairStackOp(instr) or
            (instr == Asm.@"ldp x29, x30, [sp], #0x10" and i + 1 < code.items.len and code.items[i + 1] == Asm.ret) or
            instr == Asm.ret)
        {
            try flush(&out, stack[0..depth]);
            depth = 0;
            try out.append(instr);
            continue;
        }

        if (needsRealFyStack(instr) and depth > 0) {
            try flush(&out, stack[0..depth]);
            depth = 0;
        }
        try out.append(instr);
    }

    if (depth > 0) {
        try flush(&out, stack[0..depth]);
        depth = 0;
    }

    if (!changed) {
        out.deinit();
        return;
    }

    code.clearRetainingCapacity();
    try code.appendSlice(out.items);
    out.deinit();
    try optimizeIntegerAddMovChains(allocator, code);
}

/// Strip the frame pointer/link-register save/restore from straight-line DSP
/// leaf words. This is only valid when the body has no branches or calls, so
/// there are no relocation offsets to repair and LR is still live for `ret`.
pub fn optimizeLeafFrame(code: *compat.ArrayList(u32)) void {
    if (code.items.len < 4) return;
    if (code.items[0] != Asm.@"stp x29, x30, [sp, #0x10]!" or
        code.items[1] != Asm.@"mov x29, sp" or
        code.items[code.items.len - 2] != Asm.@"ldp x29, x30, [sp], #0x10" or
        code.items[code.items.len - 1] != Asm.ret)
    {
        return;
    }

    for (code.items[2 .. code.items.len - 2]) |instr| {
        if (isAnyLocalBranch(instr) or isBl(instr) or isBlr(instr) or instr == Asm.ret) return;
    }

    const body_len = code.items.len - 4;
    std.mem.copyForwards(u32, code.items[0..body_len], code.items[2 .. code.items.len - 2]);
    code.items[body_len] = Asm.ret;
    code.shrinkRetainingCapacity(body_len + 1);
}

/// Convert a straight-line DSP word from fy-stack result ABI to scalar `x0`
/// result ABI. The normal word remains unchanged; callers use this on a cloned
/// body for host/kernel-style scalar benchmarks.
pub fn optimizeScalarReturn(code: *compat.ArrayList(u32)) bool {
    if (code.items.len < 2 or code.items[code.items.len - 1] != Asm.ret) return false;

    for (code.items[0 .. code.items.len - 1]) |instr| {
        if (isAnyLocalBranch(instr) or isBl(instr) or isBlr(instr) or instr == Asm.ret) return false;
    }

    const push_index = code.items.len - 2;
    const src = pushReg(code.items[push_index]) orelse return false;

    if (src == 0) {
        code.items[push_index] = Asm.ret;
        code.shrinkRetainingCapacity(push_index + 1);
        return true;
    }

    var start = push_index;
    while (start > 0 and !isMovz(code.items[start - 1]) and isWideMoveToReg(code.items[start - 1], src)) {
        start -= 1;
    }

    if (start > 0 and isMovz(code.items[start - 1]) and isWideMoveToReg(code.items[start - 1], src)) {
        start -= 1;
        var i = start;
        while (i < push_index) : (i += 1) {
            if (!isWideMoveToReg(code.items[i], src)) break;
            code.items[i] = (code.items[i] & ~@as(u32, 0x1f)) | @as(u32, 0);
        } else {
            code.items[push_index] = Asm.ret;
            code.shrinkRetainingCapacity(push_index + 1);
            return true;
        }
    }

    code.items[push_index] = Asm.@"mov Xd, Xn"(0, src);
    return true;
}

/// Convert a straight-line DSP word ending in tagged-float result publication
/// into an f64 scalar ABI that returns the sample in `d0`.
pub fn optimizeF64ScalarReturn(code: *compat.ArrayList(u32)) bool {
    if (code.items.len < 6 or code.items[code.items.len - 1] != Asm.ret) return false;

    for (code.items[0 .. code.items.len - 1]) |instr| {
        if (isAnyLocalBranch(instr) or isBl(instr) or isBlr(instr) or instr == Asm.ret) return false;
    }

    const push_index = code.items.len - 2;
    const pushed_reg = pushReg(code.items[push_index]) orelse return false;

    var cursor = push_index;
    var x_reg = pushed_reg;
    if (cursor > 0) {
        if (movRegs(code.items[cursor - 1])) |mov| {
            if (mov.dst == pushed_reg) {
                x_reg = mov.src;
                cursor -= 1;
            }
        }
    }

    if (cursor < 4) return false;
    const suffix_start = cursor - 4;
    const fmov = fmovXFromD(code.items[suffix_start]) orelse return false;
    if (fmov.dst != x_reg or fmov.src != 0) return false;
    if (code.items[suffix_start + 1] != Asm.@"lsr Xn, Xn, #2"(x_reg) or
        code.items[suffix_start + 2] != Asm.@"lsl Xn, Xn, #2"(x_reg) or
        code.items[suffix_start + 3] != Asm.@"add Xn, Xn, #2"(x_reg))
    {
        return false;
    }

    code.items[suffix_start] = Asm.ret;
    code.shrinkRetainingCapacity(suffix_start + 1);
    _ = optimizeF64LiteralOps(code);
    return true;
}
