const std = @import("std");
const Asm = @import("asm.zig");
const compat = @import("compat.zig");

const HOLD_REGS = [_]u5{ 12, 13, 14, 15 };
const PairRegs = struct {
    first: u5,
    second: u5,
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

fn appendMov(out: *compat.ArrayList(u32), dst: u5, src: u5) !void {
    if (dst != src) try out.append(Asm.@"mov Xd, Xn"(dst, src));
}

fn flush(out: *compat.ArrayList(u32), stack: []const u5) !void {
    var i: usize = 0;
    while (i < stack.len) : (i += 1) {
        try out.append(Asm.@".push Xn"(stack[i]));
    }
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
}
