//! Macro formulas (docs/42 §Mappings): a short expression over the macro
//! `x` and the rack's other macros `m1`…`m8`, compiled on the UI thread to
//! at most MAX_OPS postfix ops and evaluated on the audio thread with a
//! fixed stack. Evaluation allocates nothing and can't fail: division by
//! zero gives 0 and NaN becomes 0.
//!
//!   x  m1 … m8  numbers  + - * / ^  unary -  ( )
//!   min(a,b) max(a,b) clamp(v,lo,hi) lerp(a,b,t) step(v,n)
//!   abs exp log sqrt sin cos

const std = @import("std");

pub const MAX_OPS = 32;
pub const MAX_TEXT = 63;
const MAX_STACK = 16;

pub const Op = union(enum) {
    num: f32,
    /// 0 = x, 1..8 = m1..m8.
    reg: u8,
    neg,
    add,
    sub,
    mul,
    div,
    pow,
    min,
    max,
    clamp,
    lerp,
    step,
    abs,
    exp,
    log,
    sqrt,
    sin,
    cos,

    fn arity(op: Op) u8 {
        return switch (op) {
            .num, .reg => 0,
            .neg, .abs, .exp, .log, .sqrt, .sin, .cos => 1,
            .add, .sub, .mul, .div, .pow, .min, .max, .step => 2,
            .clamp, .lerp => 3,
        };
    }
};

/// A compiled formula. The empty program is the identity, `t = x`.
pub const Program = struct {
    ops: [MAX_OPS]Op = undefined,
    len: u8 = 0,

    /// `x` the macro, `m[i]` macro i+1, all 0..1. The result is 0..1.
    pub fn eval(self: *const Program, x: f32, m: *const [8]f32) f32 {
        if (self.len == 0) return std.math.clamp(x, 0, 1);
        var st: [MAX_STACK]f32 = undefined;
        var sp: usize = 0;
        for (self.ops[0..self.len]) |op| {
            const k = op.arity();
            // compile() proved the depth; the guards keep a corrupt program harmless
            if (sp < k or (k == 0 and sp >= MAX_STACK)) return 0;
            const a = if (k >= 1) st[sp - k] else 0;
            const b = if (k >= 2) st[sp - k + 1] else 0;
            const c = if (k >= 3) st[sp - k + 2] else 0;
            const v: f32 = switch (op) {
                .num => |n| n,
                .reg => |r| if (r == 0) x else m[r - 1],
                .neg => -a,
                .add => a + b,
                .sub => a - b,
                .mul => a * b,
                .div => if (b == 0) 0 else a / b,
                .pow => std.math.pow(f32, a, b),
                .min => @min(a, b),
                .max => @max(a, b),
                .clamp => std.math.clamp(a, @min(b, c), @max(b, c)),
                .lerp => a + (b - a) * c,
                // n positions over 0..1: step(x, 3) gives 0, 0.5, 1
                .step => blk: {
                    const n = @round(b);
                    if (!(n >= 2)) break :blk 0;
                    break :blk @round(std.math.clamp(a, 0, 1) * (n - 1)) / (n - 1);
                },
                .abs => @abs(a),
                .exp => @exp(a),
                .log => if (a > 0) @log(a) else 0,
                .sqrt => if (a > 0) @sqrt(a) else 0,
                .sin => @sin(a),
                .cos => @cos(a),
            };
            sp -= k;
            st[sp] = if (std.math.isFinite(v)) v else 0;
            sp += 1;
        }
        if (sp != 1) return 0;
        return std.math.clamp(st[0], 0, 1);
    }
};

pub const Error = error{ Syntax, TooLong };

/// Compile `src`; blank text is the identity.
pub fn compile(src: []const u8) Error!Program {
    var p = Parser{ .s = src };
    var prog = Program{};
    p.skip();
    if (p.i == src.len) return prog;
    var depth: usize = 0;
    try p.expr(&prog, &depth);
    p.skip();
    if (p.i != src.len or depth != 1) return error.Syntax;
    return prog;
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    fn peek(p: *Parser) u8 {
        p.skip();
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn emit(prog: *Program, depth: *usize, op: Op) Error!void {
        if (prog.len >= MAX_OPS) return error.TooLong;
        const k = op.arity();
        if (depth.* < k) return error.Syntax;
        depth.* = depth.* - k + 1;
        if (depth.* > MAX_STACK) return error.TooLong;
        prog.ops[prog.len] = op;
        prog.len += 1;
    }

    // expr := term (('+'|'-') term)*
    fn expr(p: *Parser, prog: *Program, d: *usize) Error!void {
        try p.term(prog, d);
        while (true) {
            const c = p.peek();
            if (c != '+' and c != '-') return;
            p.i += 1;
            try p.term(prog, d);
            try emit(prog, d, if (c == '+') .add else .sub);
        }
    }

    // term := unary (('*'|'/') unary)*
    fn term(p: *Parser, prog: *Program, d: *usize) Error!void {
        try p.unary(prog, d);
        while (true) {
            const c = p.peek();
            if (c != '*' and c != '/') return;
            p.i += 1;
            try p.unary(prog, d);
            try emit(prog, d, if (c == '*') .mul else .div);
        }
    }

    // unary := '-' unary | power
    fn unary(p: *Parser, prog: *Program, d: *usize) Error!void {
        if (p.peek() == '-') {
            p.i += 1;
            try p.unary(prog, d);
            return emit(prog, d, .neg);
        }
        return p.power(prog, d);
    }

    // power := atom ('^' unary)?   (right-associative, binds tighter than unary minus on its left)
    fn power(p: *Parser, prog: *Program, d: *usize) Error!void {
        try p.atom(prog, d);
        if (p.peek() == '^') {
            p.i += 1;
            try p.unary(prog, d);
            try emit(prog, d, .pow);
        }
    }

    fn atom(p: *Parser, prog: *Program, d: *usize) Error!void {
        const c = p.peek();
        if (c == '(') {
            p.i += 1;
            try p.expr(prog, d);
            if (p.peek() != ')') return error.Syntax;
            p.i += 1;
            return;
        }
        if ((c >= '0' and c <= '9') or c == '.') {
            const start = p.i;
            while (p.i < p.s.len and ((p.s[p.i] >= '0' and p.s[p.i] <= '9') or p.s[p.i] == '.')) p.i += 1;
            const v = std.fmt.parseFloat(f32, p.s[start..p.i]) catch return error.Syntax;
            return emit(prog, d, .{ .num = v });
        }
        if (!std.ascii.isAlphabetic(c)) return error.Syntax;
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isAlphanumeric(p.s[p.i])) p.i += 1;
        const name = p.s[start..p.i];
        if (std.mem.eql(u8, name, "x")) return emit(prog, d, .{ .reg = 0 });
        if (name.len == 2 and name[0] == 'm' and name[1] >= '1' and name[1] <= '8')
            return emit(prog, d, .{ .reg = name[1] - '0' });
        const funcs = .{
            .{ "min", Op.min }, .{ "max", Op.max },   .{ "clamp", Op.clamp }, .{ "lerp", Op.lerp },
            .{ "step", Op.step }, .{ "abs", Op.abs }, .{ "exp", Op.exp },     .{ "log", Op.log },
            .{ "sqrt", Op.sqrt }, .{ "sin", Op.sin }, .{ "cos", Op.cos },
        };
        inline for (funcs) |f| {
            if (std.mem.eql(u8, name, f[0])) {
                const op: Op = f[1];
                if (p.peek() != '(') return error.Syntax;
                p.i += 1;
                var n: u8 = 0;
                while (true) {
                    try p.expr(prog, d);
                    n += 1;
                    const sep = p.peek();
                    p.i += 1;
                    if (sep == ')') break;
                    if (sep != ',') return error.Syntax;
                }
                if (n != op.arity()) return error.Syntax;
                return emit(prog, d, op);
            }
        }
        if (std.mem.eql(u8, name, "pi")) return emit(prog, d, .{ .num = std.math.pi });
        return error.Syntax;
    }
};

const testing = std.testing;

fn run(src: []const u8, x: f32, m: [8]f32) !f32 {
    const p = try compile(src);
    return p.eval(x, &m);
}

test "formula: parses the docs' examples and evaluates them" {
    const z: [8]f32 = @splat(0);
    try testing.expectEqual(@as(f32, 0.25), try run("x^2", 0.5, z));
    try testing.expectEqual(@as(f32, 0.75), try run("1 - x", 0.25, z));
    try testing.expectEqual(@as(f32, 0), try run("clamp(2*x - 1, 0, 1)", 0.4, z));
    try testing.expectApproxEqAbs(@as(f32, 0.6), try run("clamp(2*x - 1, 0, 1)", 0.8, z), 1e-6);
    var m = z;
    m[3] = 0.25;
    try testing.expectApproxEqAbs(@as(f32, 0.6), try run("x * (1 - m4)", 0.8, m), 1e-6);
    // blank is the identity, clamped
    try testing.expectEqual(@as(f32, 0.3), try run("  ", 0.3, z));
    try testing.expectEqual(@as(f32, 1), try run("", 1.7, z));
}

test "formula: precedence, unary minus, functions, step" {
    const z: [8]f32 = @splat(0);
    try testing.expectApproxEqAbs(@as(f32, 0.7), try run("0.1 + 0.2 * 3", 0, z), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), try run("(0.1 + 0.2) * 3", 0, z), 1e-6);
    // -x^2 is -(x^2); 2^-1 parses
    try testing.expectEqual(@as(f32, 0), try run("-x^2", 0.5, z));
    try testing.expectEqual(@as(f32, 0.5), try run("2^-1", 0, z));
    try testing.expectEqual(@as(f32, 0.5), try run("-x^2 + 0.75", 0.5, z));
    try testing.expectEqual(@as(f32, 0.5), try run("step(x, 3)", 0.6, z));
    try testing.expectEqual(@as(f32, 1), try run("step(x, 3)", 0.8, z));
    try testing.expectEqual(@as(f32, 0.5), try run("lerp(0.2, 0.8, x)", 0.5, z));
    try testing.expectEqual(@as(f32, 0.2), try run("min(x, 0.2)", 0.5, z));
    try testing.expectApproxEqAbs(@as(f32, 0.5), try run("abs(x - 1)", 0.5, z), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), try run("sqrt(x)", 0.25, z), 1e-6);
}

test "formula: nothing fails at run time" {
    const z: [8]f32 = @splat(0);
    try testing.expectEqual(@as(f32, 0), try run("1 / x", 0, z));
    try testing.expectEqual(@as(f32, 0), try run("log(x)", 0, z));
    try testing.expectEqual(@as(f32, 0), try run("sqrt(0 - x)", 0.5, z));
    try testing.expectEqual(@as(f32, 0), try run("(0-1)^0.5", 0, z));
}

test "formula: typos and oversized programs are refused" {
    const bad = [_][]const u8{ "x +", "x x", "foo(x)", "min(x)", "clamp(x,1)", "(x", "x)", "m9", "y", "2 ** x", "step x" };
    for (bad) |s| try testing.expectError(error.Syntax, compile(s));
    try testing.expectError(error.TooLong, compile("x+x+x+x+x+x+x+x+x+x+x+x+x+x+x+x+x"));
}
