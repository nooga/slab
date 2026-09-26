const std = @import("std");
const Fy = @import("main.zig").Fy;

const TestCase = struct {
    input: []const u8,
    expected: Fy.Value,

    fn run(self: *const TestCase, fy: *Fy) !void {
        std.debug.print("\nfy> {s}\n", .{self.input});
        const input = self.input;
        const result = try fy.run(input);
        std.debug.print("exp {any}\n    {any}\n", .{ self.expected, result });
        try std.testing.expectEqual(self.expected, result);
    }
};

fn runCases(fy: *Fy, testCases: []const TestCase) !void {
    for (testCases) |testCase| {
        try testCase.run(fy);
    }
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn makeFyFloat(value: f64) Fy.Value {
    const bits: u64 = @bitCast(value);
    return @bitCast((bits & ~@as(u64, 3)) | 2);
}

fn getFyFloat(value: Fy.Value) f64 {
    const bits: u64 = @bitCast(value);
    return @bitCast(bits & ~@as(u64, 3));
}

test "Basic expressions and built-in words" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        .{ .input = "", .expected = Fy.makeInt(0) }, //
        .{ .input = "1", .expected = Fy.makeInt(1) },
        .{ .input = "-1", .expected = Fy.makeInt(-1) },
        .{ .input = "1 2", .expected = Fy.makeInt(2) },
        .{ .input = "1 2 +", .expected = Fy.makeInt(3) },
        .{ .input = "10 -10 +", .expected = Fy.makeInt(0) },
        .{ .input = "-5 0 - 6 +", .expected = Fy.makeInt(1) },
        .{ .input = "1 2 -", .expected = Fy.makeInt(-1) },
        .{ .input = "1 2 !-", .expected = Fy.makeInt(1) },
        .{ .input = "2 2 *", .expected = Fy.makeInt(4) },
        .{ .input = "12 3 /", .expected = Fy.makeInt(4) },
        .{ .input = "12 5 &", .expected = Fy.makeInt(4) },
        .{ .input = "1.5 2.25 f+ 3.75 f=", .expected = Fy.makeInt(1) },
        .{ .input = "5.0 2.0 f- 3.0 f=", .expected = Fy.makeInt(1) },
        .{ .input = "1.25 4.0 f* 5.0 f=", .expected = Fy.makeInt(1) },
        .{ .input = "9.0 2.0 f/ 4.5 f=", .expected = Fy.makeInt(1) },
        .{ .input = "10.0 2.0 3.0 fmadd 16.0 f=", .expected = Fy.makeInt(1) },
        .{ .input = "2.0 3.0 10.0 fma 16.0 f=", .expected = Fy.makeInt(1) },
        .{ .input = "10.0 20.0 0.25 fslew 12.5 f=", .expected = Fy.makeInt(1) },
        .{ .input = "-0.5 fclamp01 0.0 f=", .expected = Fy.makeInt(1) },
        .{ .input = "1.5 fclamp01 1.0 f=", .expected = Fy.makeInt(1) },
        .{ .input = "5.0 2.0 4.0 fclamp 4.0 f=", .expected = Fy.makeInt(1) },
        .{ .input = "1.25 fwrap01 0.25 f=", .expected = Fy.makeInt(1) },
        .{ .input = "-0.25 fwrap01 0.75 f=", .expected = Fy.makeInt(1) },
        .{ .input = "2.5 fneg -2.5 f=", .expected = Fy.makeInt(1) },
        .{ .input = "1.0 2.0 f<", .expected = Fy.makeInt(1) },
        .{ .input = "2.0 1.0 f>", .expected = Fy.makeInt(1) },
        .{ .input = "4 alloc dup 1.5 swap f!32 f@32 1.5 f=", .expected = Fy.makeInt(1) },
        .{ .input = "1 2 =", .expected = Fy.makeInt(0) },
        .{ .input = "1 1 =", .expected = Fy.makeInt(1) },
        .{ .input = "1 2 !=", .expected = Fy.makeInt(1) },
        .{ .input = "1 1 !=", .expected = Fy.makeInt(0) },
        .{ .input = "1 2 >", .expected = Fy.makeInt(0) },
        .{ .input = "2 1 >", .expected = Fy.makeInt(1) },
        .{ .input = "1 2 <", .expected = Fy.makeInt(1) },
        .{ .input = "2 1 <", .expected = Fy.makeInt(0) },
        .{ .input = "1 2 >=", .expected = Fy.makeInt(0) },
        .{ .input = "2 1 >=", .expected = Fy.makeInt(1) },
        .{ .input = "2 2 >=", .expected = Fy.makeInt(1) },
        .{ .input = "1 2 <=", .expected = Fy.makeInt(1) },
        .{ .input = "2 1 <=", .expected = Fy.makeInt(0) },
        .{ .input = "2 2 <=", .expected = Fy.makeInt(1) },
        .{ .input = "2 dup", .expected = Fy.makeInt(2) },
        .{ .input = "2 3 swap", .expected = Fy.makeInt(2) },
        .{ .input = "2 3 over", .expected = Fy.makeInt(2) },
        .{ .input = "2 3 4 5 over2", .expected = Fy.makeInt(3) },
        .{ .input = "2 3 nip", .expected = Fy.makeInt(3) },
        .{ .input = "2 3 tuck", .expected = Fy.makeInt(3) },
        .{ .input = "2 3 drop", .expected = Fy.makeInt(2) },
        .{ .input = "2 1+ 4 1- =", .expected = Fy.makeInt(1) },
        .{ .input = "depth", .expected = Fy.makeInt(0) },
        .{ .input = "5 6 7 8 depth", .expected = Fy.makeInt(4) },
        .{ .input = "1 2 3 rot", .expected = Fy.makeInt(1) },
        .{ .input = "1 2 3 -rot", .expected = Fy.makeInt(2) },
        .{ .input = "1 2 3 4 drop2", .expected = Fy.makeInt(2) },
        .{ .input = "3 2 dup2 * rot * +", .expected = Fy.makeInt(20) },
    });
}

test "User defined words" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        .{ .input = ": sqr dup * ;", .expected = Fy.makeInt(0) },
        .{ .input = "2 sqr", .expected = Fy.makeInt(4) },
        .{ .input = ":sqr dup *; 2 sqr", .expected = Fy.makeInt(4) },
        .{ .input = ": sqr dup * ; 2 sqr", .expected = Fy.makeInt(4) },
        .{ .input = ":a 1; a a +", .expected = Fy.makeInt(2) },
        .{ .input = ": a 2 +; :b 3 +; 1 a b 6 =", .expected = Fy.makeInt(1) },
        .{ .input = "1 a b", .expected = Fy.makeInt(6) },
        .{ .input = "2 dup :dup *; dup", .expected = Fy.makeInt(4) }, // warning: this breaks dup in this Fy instance forever
    });
}

test "Quotes" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        .{
            .input = "2 [dup +] do", //
            .expected = Fy.makeInt(4),
        },
        .{ .input = "[dup +] 3 swap do", .expected = Fy.makeInt(6) },
        .{ .input = ":dup+ [dup +]; 5 dup+ do", .expected = Fy.makeInt(10) },
        .{ .input = "10 dup+ do", .expected = Fy.makeInt(20) },
        .{ .input = "2 3 over over < [*] do?", .expected = Fy.makeInt(6) },
        .{ .input = "[2 *] 1 [1 +] do swap do", .expected = Fy.makeInt(4) },
        .{ .input = "2 3 \\* do", .expected = Fy.makeInt(6) },
        .{ .input = "2 2 3 \\* dip -", .expected = Fy.makeInt(1) },
        // locals basics
        .{ .input = "41 [ | x | x 1+] do", .expected = Fy.makeInt(42) },
        .{ .input = "10 20 [ | a b | a b + ] do", .expected = Fy.makeInt(30) },
        // header with zero locals is allowed and does nothing
        .{ .input = "7 [ | | 1+ ] do", .expected = Fy.makeInt(8) },
    });
}

test "Conditional do?/ifte and do variants" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    std.debug.print("[tests] do?/ifte/do variants\n", .{});

    try runCases(&fy, &[_]TestCase{
        // do? with quote: true executes, false skips
        .{ .input = "5 1 [1+] do?", .expected = Fy.makeInt(6) },
        .{ .input = "5 0 [1+] do?", .expected = Fy.makeInt(5) },

        // do? with single-word quote via backslash
        .{ .input = "5 1 \\1+ do?", .expected = Fy.makeInt(6) },
        .{ .input = "5 0 \\1+ do?", .expected = Fy.makeInt(5) },

        // do executes both a bracketed quote and a backslashed single-word quote
        .{ .input = "5 [1+] do", .expected = Fy.makeInt(6) },
        .{ .input = "5 \\1+ do", .expected = Fy.makeInt(6) },
        // empty quote is a no-op
        .{ .input = "5 [] do", .expected = Fy.makeInt(5) },

        // ifte with quotes: choose true/false branch by predicate
        .{ .input = "10 1 [1+] [1-] ifte", .expected = Fy.makeInt(11) },
        .{ .input = "10 0 [1+] [1-] ifte", .expected = Fy.makeInt(9) },

        // ifte with single-word quotes via backslash
        .{ .input = "10 1 \\1+ \\1- ifte", .expected = Fy.makeInt(11) },
        .{ .input = "10 0 \\1+ \\1- ifte", .expected = Fy.makeInt(9) },
        // locals + ifte interaction
        .{ .input = "3 1 [ | n | n 1+ ] [ | n | n 1- ] ifte", .expected = Fy.makeInt(4) },
    });
}

test "Quotes - list manipulation and caching" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        // push a quote, duplicate/drop leaves a quote object; verify it's not a string
        .{ .input = "[1 2 +] dup drop string?", .expected = Fy.makeInt(0) },
        // nested quotes executed via outer 'do'
        .{ .input = "[[dup +] do] 2 swap do", .expected = Fy.makeInt(4) },
        // times (alias) and retain ops
        .{ .input = "2 [1 +] times", .expected = Fy.makeInt(0) },
        .{ .input = "42 >r r@ r>", .expected = Fy.makeInt(42) },
        // quote concat and call (compose [1 +] twice)
        .{ .input = "2 [1 +] dup cat do", .expected = Fy.makeInt(4) },
    });
}

test "Loops - dotimes and repeat" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        // dotimes: starting from 0, apply [1+] three times -> 3
        .{ .input = "0 3 [1+] dotimes", .expected = Fy.makeInt(3) },
        // repeat: count down to zero with [1- dup], drop the duplicate -> 0
        .{ .input = "3 [1- dup] repeat drop", .expected = Fy.makeInt(0) },
    });
}

test "Print functions compile" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        .{ .input = "1 .", .expected = Fy.makeInt(0) },
        .{ .input = "1 .hex", .expected = Fy.makeInt(0) },
        .{ .input = "1 . .nl 2 .", .expected = Fy.makeInt(0) },
        .{ .input = "65 .c .nl", .expected = Fy.makeInt(0) },
        .{ .input = "1 spy", .expected = Fy.makeInt(1) },
    });
}

test "Comments are ignored" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        .{ .input = "( Comment before code ) 1 2 +", .expected = Fy.makeInt(3) },
        .{ .input = "1 2 + ( Comment ) ( Another comment )", .expected = Fy.makeInt(3) },
        .{ .input = "1 2 + ( Comment ) ( Another comment )", .expected = Fy.makeInt(3) },
        .{ .input = "(Comment before code) 1 2 +", .expected = Fy.makeInt(3) },
        .{ .input = "1 2 + ( Co(mm)ent ) (Another comment )", .expected = Fy.makeInt(3) },
        .{ .input = "1 ( Comment) 2 +", .expected = Fy.makeInt(3) },
    });
}

test "Character literals" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        .{ .input = "'a", .expected = Fy.makeInt('a') },
        .{ .input = "'b 'c +", .expected = Fy.makeInt('b' + 'c') },
        .{ .input = "'0 '9 +", .expected = Fy.makeInt('0' + '9') },
        .{ .input = "'x 'y swap", .expected = Fy.makeInt('x') },
        .{ .input = "'z 1 +", .expected = Fy.makeInt('z' + 1) },
        .{ .input = "'a 'a =", .expected = Fy.makeInt(1) },
        .{ .input = "'a 'b !=", .expected = Fy.makeInt(1) },
        .{ .input = "'m 'n >", .expected = Fy.makeInt(0) },
        .{ .input = "'p 'o <", .expected = Fy.makeInt(0) },
        .{ .input = "' ' drop", .expected = Fy.makeInt(' ') },
        .{ .input = "'a'b swap", .expected = Fy.makeInt('a') },
    });
}

test "String operations" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    // Helper function to debug string operations
    const debugString = (struct {
        fn check(f: *Fy, v: Fy.Value, label: []const u8) void {
            _ = label;
            if (Fy.isStr(v) and (f.heap.typeOf(v) orelse .String) == .String) {
                _ = Fy.getStrId(v);
                _ = f.heap.getString(v);
            }
        }
    }).check;

    // Run a single test case to debug string operations
    {
        const input = "\"hello\"";
        const result = try fy.run(input);
        debugString(&fy, result, "String 1");
    }
    {
        const input = "\"world\"";
        const result = try fy.run(input);
        debugString(&fy, result, "String 2");
    }
    {
        const input = "\"hello\" \"world\" s+";
        const result = try fy.run(input);
        debugString(&fy, result, "Concatenated");
    }
    {
        const input = "\"hello\" \"world\" s+ slen";
        const result = try fy.run(input);
        _ = result;
    }

    try runCases(&fy, &[_]TestCase{
        .{ .input = "\"hello\" string?", .expected = Fy.makeInt(1) },
        .{ .input = "\"hello\" slen", .expected = Fy.makeInt(5) },
        .{ .input = "\"hello\" \"world\" s+ string?", .expected = Fy.makeInt(1) },
        .{ .input = "\"hello\" \"world\" s+ slen", .expected = Fy.makeInt(10) },
        .{ .input = "\"hello\" string?", .expected = Fy.makeInt(1) },
        .{ .input = "123 string?", .expected = Fy.makeInt(0) },
        .{ .input = "\"hello\" int?", .expected = Fy.makeInt(0) },
        .{ .input = "123 int?", .expected = Fy.makeInt(1) },
    });
}

test "Recursion - self and nested" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        // factorial using self-recursion inside quotes
        .{ .input = ": fact dup 1 <= [drop 1] [dup 1- fact *] ifte; 5 fact", .expected = Fy.makeInt(120) },
        // sum down to 0 using nested recursion via a quoted call
        .{ .input = ": sumdown dup 0 <= [drop 0] [dup 1- [sumdown] do +] ifte; 4 sumdown", .expected = Fy.makeInt(10) },
    });
}

test "Recursion - mutual (even/odd)" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        .{ .input = ": even dup 0 = [drop 1] [1- odd] ifte ; : odd dup 0 = [drop 0] [1- even] ifte ; 10 even", .expected = Fy.makeInt(1) },
        .{ .input = "11 even", .expected = Fy.makeInt(0) },
        .{ .input = "0 odd", .expected = Fy.makeInt(0) },
    });
}

test "Map and reduce" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    try runCases(&fy, &[_]TestCase{
        // map applies function to each element
        .{ .input = "[1 2 3] [1+] map qhead", .expected = Fy.makeInt(2) },
        // reduce folds a list
        .{ .input = "0 [1 2 3] [+] reduce", .expected = Fy.makeInt(6) },
        // map with locals
        .{ .input = "[10 20 30] [ | n | n 1+ ] map qhead", .expected = Fy.makeInt(11) },
    });
}

test "Curry, compose, each, filter" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    try runCases(&fy, &[_]TestCase{
        // curry prepends value to quotation
        .{ .input = "3 5 [+] curry do", .expected = Fy.makeInt(8) },
        // compose chains two quotations
        .{ .input = "3 [2 *] [1+] compose do", .expected = Fy.makeInt(7) },
        // filter keeps matching elements
        .{ .input = "[1 2 3 4 5] [3 >] filter qhead", .expected = Fy.makeInt(4) },
        // filter length check
        .{ .input = "[1 2 3 4 5] [3 >] filter qlen", .expected = Fy.makeInt(2) },
        // each returns 0 (side-effect only)
        .{ .input = "[1 2 3] [drop] each", .expected = Fy.makeInt(0) },
        // qpush inlines single-item quotation (\ word syntax)
        .{ .input = "[1 2] [+] qpush qlen", .expected = Fy.makeInt(3) },
        // curry + map
        .{ .input = "[1 2 3] 10 [+] curry map qhead", .expected = Fy.makeInt(11) },
        // range generates [0..n-1]
        .{ .input = "5 range qlen", .expected = Fy.makeInt(5) },
        .{ .input = "5 range qhead", .expected = Fy.makeInt(0) },
        .{ .input = "5 range qtail qhead", .expected = Fy.makeInt(1) },
        // range + map
        .{ .input = "5 range [1+] map qhead", .expected = Fy.makeInt(1) },
    });
}

test "Adapter basic calls" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    // Build quote [1+] — parseQuoteToHeap expects opening [ already consumed
    var p1 = Fy.Parser.init("1+ ]");
    var c1 = Fy.Compiler.init(&fy, &p1);
    defer c1.deinit();
    const q_inc = try c1.parseQuoteToHeap();
    const f_inc_val = Fy.Builtins.resolveCallable(q_inc);
    try std.testing.expect(Fy.isInt(f_inc_val));
    const f_inc: usize = @intCast(Fy.getInt(f_inc_val));

    // Adapters set up their own x21/x22 from base/end params — no initVmStack needed
    const a1 = Fy.Builtins.getAdapt1(&fy);
    const tramp_end_aligned: usize = fy.tramp_stack_top;
    const base_val: Fy.Value = @bitCast(@as(i64, @intCast(tramp_end_aligned)));
    const end_val: Fy.Value = base_val;
    const r1 = a1(f_inc, base_val, end_val, Fy.makeInt(41));
    try std.testing.expectEqual(Fy.makeInt(42), r1);

    // Build quote [+]
    var p2 = Fy.Parser.init("+ ]");
    var c2 = Fy.Compiler.init(&fy, &p2);
    defer c2.deinit();
    const q_plus = try c2.parseQuoteToHeap();
    const f_plus_val = Fy.Builtins.resolveCallable(q_plus);
    try std.testing.expect(Fy.isInt(f_plus_val));
    const f_plus: usize = @intCast(Fy.getInt(f_plus_val));

    const a2 = Fy.Builtins.getAdapt2(&fy);
    const r2 = a2(f_plus, base_val, end_val, Fy.makeInt(2), Fy.makeInt(5));
    try std.testing.expectEqual(Fy.makeInt(7), r2);

    // Parse a quote with locals to ensure no crash
    var p3 = Fy.Parser.init("| n | n 1+ ]");
    var c3 = Fy.Compiler.init(&fy, &p3);
    defer c3.deinit();
    const q_inc2 = try c3.parseQuoteToHeap();
    const f_inc2_val = Fy.Builtins.resolveCallable(q_inc2);
    try std.testing.expect(Fy.isInt(f_inc2_val));
}

test "Memory operations - alloc, !32, @32, free" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        // Store 42 at allocated address, load it back
        .{ .input = "32 alloc dup 42 swap !32 @32", .expected = Fy.makeInt(42) },
        // Store and load multiple values
        .{ .input = "16 alloc dup 10 swap !32 dup 4 + 20 swap !32 dup @32 swap 4 + @32 +", .expected = Fy.makeInt(30) },
        // Raw f64 store/load keeps IEEE lane data in memory.
        .{ .input = "16 alloc dup 1.5 swap f!64 f@64 1.5 f=", .expected = Fy.makeInt(1) },
        // Free returns 0
        .{ .input = "8 alloc free", .expected = Fy.makeInt(0) },
    });
}

test "Callbacks - callback: with ccall" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();

    try runCases(&fy, &[_]TestCase{
        // 1-arg callback
        .{ .input = ": add-one 1 + ; :: cb callback: i:i add-one ; cb 41 ccall1", .expected = Fy.makeInt(42) },
        // 2-arg callback
        .{ .input = ": my-sub - ; :: sub-cb callback: ii:i my-sub ; sub-cb 10 3 ccall2", .expected = Fy.makeInt(7) },
    });
}

test "Type introspection - quote?, word?, word->str" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    try runCases(&fy, &[_]TestCase{
        .{ .input = "[1 2] quote?", .expected = Fy.makeInt(1) },
        .{ .input = "42 quote?", .expected = Fy.makeInt(0) },
        .{ .input = "\"hi\" quote?", .expected = Fy.makeInt(0) },
        .{ .input = "[hello] qhead word?", .expected = Fy.makeInt(1) },
        .{ .input = "42 word?", .expected = Fy.makeInt(0) },
        .{ .input = "\"test\" word?", .expected = Fy.makeInt(0) },
        .{ .input = "[1 2] word?", .expected = Fy.makeInt(0) },
        // word->str returns string, test via slen
        .{ .input = "[hello] qhead word->str slen", .expected = Fy.makeInt(5) },
        .{ .input = "42 word->str", .expected = Fy.makeInt(0) },
    });
}

test "Type introspection - qnth, qnth-type" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    try runCases(&fy, &[_]TestCase{
        // qnth — indexed access
        .{ .input = "[10 20 30] 0 qnth", .expected = Fy.makeInt(10) },
        .{ .input = "[10 20 30] 2 qnth", .expected = Fy.makeInt(30) },
        // qnth-type — type tags: 0=int, 1=float, 2=word, 3=string, 4=quote
        .{ .input = "[42] 0 qnth-type", .expected = Fy.makeInt(0) },
        .{ .input = "[3.14] 0 qnth-type", .expected = Fy.makeInt(1) },
        .{ .input = "[hello] 0 qnth-type", .expected = Fy.makeInt(2) },
        .{ .input = "[\"test\"] 0 qnth-type", .expected = Fy.makeInt(3) },
        .{ .input = "[[1 2]] 0 qnth-type", .expected = Fy.makeInt(4) },
        // mixed quote
        .{ .input = "[10 \"hi\" 2.5 foo [1]] 0 qnth-type", .expected = Fy.makeInt(0) },
        .{ .input = "[10 \"hi\" 2.5 foo [1]] 1 qnth-type", .expected = Fy.makeInt(3) },
        .{ .input = "[10 \"hi\" 2.5 foo [1]] 2 qnth-type", .expected = Fy.makeInt(1) },
        .{ .input = "[10 \"hi\" 2.5 foo [1]] 3 qnth-type", .expected = Fy.makeInt(2) },
        .{ .input = "[10 \"hi\" 2.5 foo [1]] 4 qnth-type", .expected = Fy.makeInt(4) },
    });
}

test "Macros - emit-lit" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    try runCases(&fy, &[_]TestCase{
        .{ .input = "macro: push42 42 emit-lit ; push42", .expected = Fy.makeInt(42) },
        .{ .input = "macro: push10 5 5 + emit-lit ; push10", .expected = Fy.makeInt(10) },
    });
}

test "Macros - emit-word" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    try runCases(&fy, &[_]TestCase{
        .{ .input = "macro: emit-add \"+\" emit-word ; 3 4 emit-add", .expected = Fy.makeInt(7) },
        .{ .input = "macro: emit-dup \"dup\" emit-word ; 5 emit-dup +", .expected = Fy.makeInt(10) },
    });
}

test "Macros - peek-quote and unpush" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    try runCases(&fy, &[_]TestCase{
        // const macro: compile-time evaluation of a quote
        .{ .input = "macro: const peek-quote unpush do emit-lit ; [6 7 *] const", .expected = Fy.makeInt(42) },
        .{ .input = "[3 4 +] const", .expected = Fy.makeInt(7) },
        .{ .input = "[10 2 * 1 +] const", .expected = Fy.makeInt(21) },
    });
}

test "noalloc: valid word compiles and runs" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);
    try runCases(&fy, &[_]TestCase{
        // Arithmetic and float ops are fine
        .{ .input = "noalloc: add3 3 + ; 10 add3", .expected = Fy.makeInt(13) },
        // Stack ops fine
        .{ .input = "noalloc: double dup + ; 7 double", .expected = Fy.makeInt(14) },
        // Conditional via ifte (quotes are compile-time, ifte is a stack op)
        .{ .input = "noalloc: abs dup 0 < [ 0 swap - ] [ ] ifte ; -5 abs", .expected = Fy.makeInt(5) },
        // Calling another noalloc: word is allowed
        .{ .input = "noalloc: sq dup * ; noalloc: sq2 sq 2 * ; 4 sq2", .expected = Fy.makeInt(32) },
    });
}

test "noalloc: rejects heap-allocating builtins" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    // Each of these should fail to compile
    const bad = [_][]const u8{
        "noalloc: bad qnil ; bad",
        "noalloc: bad alloc ; bad",
        "noalloc: bad 5 range ; bad",
        "noalloc: bad dup s+ ; bad",
        "noalloc: bad gc ; bad",
    };
    for (bad) |src| {
        const result = fy.run(src);
        try std.testing.expectError(error.UnknownWord, result);
    }
}

test "noalloc: rejects call to non-noalloc: user word" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    // Define a regular (allocating) word then try to call it from noalloc:
    _ = try fy.run(": normal qnil ;");
    const result = fy.run("noalloc: bad normal ; bad");
    try std.testing.expectError(error.UnknownWord, result);
}

test "compiler report and disasm expose noalloc float memory ops" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("noalloc: report-float dup 1.5 swap f!32 f@32 2.0 f* 3.0 f+ ;");
    try std.testing.expectEqual(Fy.makeInt(1), try fy.run("4 alloc report-float 6.0 f="));

    const report = fy.reportWord("report-float") orelse return error.MissingReport;
    try std.testing.expect(report.instruction_count > 0);
    try std.testing.expect(report.f32_store_count >= 1);
    try std.testing.expect(report.f32_load_count >= 1);
    try std.testing.expect(report.float_alu_count >= 2);
    try std.testing.expect(report.ret_count == 1);

    const disasm = try fy.disassembleWordAlloc(std.testing.allocator, "report-float");
    defer std.testing.allocator.free(disasm);
    try expectContains(disasm, "str s");
    try expectContains(disasm, "ldr s");
    try expectContains(disasm, "fmul d");
    try expectContains(disasm, "fadd d");

    const json = try report.writeJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try expectContains(json, "\"instruction_count\"");
    try expectContains(json, "\"float_alu_count\"");
    try expectContains(json, "\"f32_load_count\"");
}

test "DSP NEON f64x2 words operate on raw f64 buffers and report vector code" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\:: va 16 alloc ;
        \\:: vb 16 alloc ;
        \\:: vc 16 alloc ;
        \\1.0 va f!64 2.0 va 8 + f!64
        \\3.0 vb f!64 4.0 vb 8 + f!64
        \\dsp1: neon-add v2f+ ;
        \\dsp1: neon-mul v2f* ;
        \\dsp1: neon-fmadd v2fmadd ;
    );

    try std.testing.expectEqual(Fy.makeInt(1), try fy.run("vc va vb neon-add vc f@64 4.0 f= vc 8 + f@64 6.0 f= &"));
    try std.testing.expectEqual(Fy.makeInt(1), try fy.run("vc va vb neon-mul vc f@64 3.0 f= vc 8 + f@64 8.0 f= &"));
    try std.testing.expectEqual(Fy.makeInt(1), try fy.run("vc va vb neon-add vc vc va vb neon-fmadd vc f@64 7.0 f= vc 8 + f@64 14.0 f= &"));

    const report = fy.reportWord("neon-add") orelse return error.MissingReport;
    try std.testing.expectEqual(@as(usize, 1), report.neon_float_alu_count);
    try std.testing.expectEqual(@as(usize, 2), report.neon_load_count);
    try std.testing.expectEqual(@as(usize, 1), report.neon_store_count);

    const disasm = try fy.disassembleWordAlloc(std.testing.allocator, "neon-add");
    defer std.testing.allocator.free(disasm);
    try expectContains(disasm, "fadd v.2d");

    const json = try report.writeJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try expectContains(json, "\"neon_float_alu_count\"");
}

test "float integer conversions are inline machine code" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("noalloc: conv-roundtrip 3 i>f f>i ;");
    try std.testing.expectEqual(Fy.makeInt(3), try fy.run("conv-roundtrip"));

    const report = fy.reportWord("conv-roundtrip") orelse return error.MissingReport;
    try std.testing.expectEqual(@as(usize, 0), report.blr_count);

    const disasm = try fy.disassembleWordAlloc(std.testing.allocator, "conv-roundtrip");
    defer std.testing.allocator.free(disasm);
    try expectContains(disasm, "scvtf d, x");
    try expectContains(disasm, "fcvtzs x, d");
}

test "compiler report tracks branchy noalloc words" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("noalloc: report-abs dup 0 < [ 0 swap - ] [ ] ifte ;");
    try std.testing.expectEqual(Fy.makeInt(5), try fy.run("-5 report-abs"));

    const report = fy.reportWord("report-abs") orelse return error.MissingReport;
    try std.testing.expect(report.instruction_count > 0);
    try std.testing.expect(report.local_branch_count > 0);
    try std.testing.expect(report.ret_count == 1);

    const disasm = try fy.disassembleWordAlloc(std.testing.allocator, "report-abs");
    defer std.testing.allocator.free(disasm);
    try expectContains(disasm, "b");
}

test "compiler report and disasm follow hot-patched word body" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("noalloc: patchme 1.0 2.0 f+ ;");
    try std.testing.expectEqual(Fy.makeInt(1), try fy.run("patchme 3.0 f="));

    const add_disasm = try fy.disassembleWordAlloc(std.testing.allocator, "patchme");
    defer std.testing.allocator.free(add_disasm);
    try expectContains(add_disasm, "fadd d");

    const add_report = fy.reportWord("patchme") orelse return error.MissingReport;
    try std.testing.expect(add_report.float_alu_count >= 1);

    _ = try fy.run("noalloc: patchme 1.0 2.0 f* ;");
    try std.testing.expectEqual(Fy.makeInt(1), try fy.run("patchme 2.0 f="));

    const mul_disasm = try fy.disassembleWordAlloc(std.testing.allocator, "patchme");
    defer std.testing.allocator.free(mul_disasm);
    try expectContains(mul_disasm, "fmul d");

    const mul_report = fy.reportWord("patchme") orelse return error.MissingReport;
    try std.testing.expect(mul_report.float_alu_count >= 1);
    try std.testing.expect(mul_report.instruction_count == add_report.instruction_count);
}

test "benchmark wrapper calls a word repeatedly" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("noalloc: bench-plus 1 2 + ;");
    try std.testing.expectEqual(Fy.makeInt(3), try fy.callWordRepeated("bench-plus", 1000));
    try std.testing.expectEqual(Fy.makeInt(0), try fy.callWordRepeated("bench-plus", 0));
}

test "DSP scalar benchmark wrapper returns x0 without fy-stack result pop" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("dsp1: scalar-plus 1 2 + ;");
    try std.testing.expectEqual(Fy.makeInt(3), try fy.callDspScalarRepeated("scalar-plus", 1000));
    try std.testing.expectEqual(Fy.makeInt(0), try fy.callDspScalarRepeated("scalar-plus", 0));
    const scalar_report = try fy.reportDspScalarWord("scalar-plus");
    try std.testing.expectEqual(@as(usize, 0), scalar_report.push_count);
    try std.testing.expect(scalar_report.instruction_count <= 2);

    _ = try fy.run("dsp1: scalar-branch 5 dup 3 > [ 1 + ] [ 1 - ] ifte ;");
    try std.testing.expectError(error.UnsupportedDspScalar, fy.callDspScalarRepeated("scalar-branch", 1));
}

test "DSP f64 scalar benchmark wrapper returns d0 without tagged-float publication" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("dsp1: scalar-float 0.5 0.25 f* 0.125 f+ ;");
    try std.testing.expectEqual(@as(f64, 0.25), try fy.callDspF64ScalarRepeated("scalar-float", 1000));
    try std.testing.expectEqual(@as(f64, 0.0), try fy.callDspF64ScalarRepeated("scalar-float", 0));
    const scalar_report = try fy.reportDspF64ScalarWord("scalar-float");
    try std.testing.expectEqual(@as(usize, 0), scalar_report.push_count);
    try std.testing.expectEqual(@as(usize, 0), scalar_report.float_alu_count);
    try std.testing.expect(scalar_report.instruction_count <= 6);

    _ = try fy.run("dsp1: scalar-int 1 2 + ;");
    try std.testing.expectError(error.UnsupportedDspF64Scalar, fy.callDspF64ScalarRepeated("scalar-int", 1));
}

test "inline-noalloc copies straight-line inlineable callees" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("noalloc: plain-inc 1 + ; noalloc: plain-call 41 plain-inc ;");
    try std.testing.expectEqual(Fy.makeInt(42), try fy.run("plain-call"));
    const plain_report = fy.reportWord("plain-call") orelse return error.MissingReport;
    try std.testing.expectEqual(@as(usize, 1), plain_report.bl_count);

    _ = try fy.run("inline-noalloc: inline-inc 1 + ; inline-noalloc: inline-call 41 inline-inc ;");
    try std.testing.expectEqual(Fy.makeInt(42), try fy.run("inline-call"));
    const inline_report = fy.reportWord("inline-call") orelse return error.MissingReport;
    try std.testing.expectEqual(@as(usize, 0), inline_report.bl_count);
    try std.testing.expect(inline_report.instruction_count > plain_report.instruction_count);

    const disasm = try fy.disassembleWordAlloc(std.testing.allocator, "inline-call");
    defer std.testing.allocator.free(disasm);
    try std.testing.expect(std.mem.indexOf(u8, disasm, "bl") == null);

    _ = try fy.run("inline-noalloc: inline-inc 2 + ;");
    try std.testing.expectEqual(Fy.makeInt(43), try fy.run("41 inline-inc"));
    try std.testing.expectEqual(Fy.makeInt(42), try fy.run("inline-call"));
}

test "inline-noalloc falls back to calls for branchy callees" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("inline-noalloc: inline-abs dup 0 < [ 0 swap - ] [ ] ifte ; inline-noalloc: inline-abs-call -5 inline-abs ;");
    try std.testing.expectEqual(Fy.makeInt(5), try fy.run("inline-abs-call"));

    const callee_report = fy.reportWord("inline-abs") orelse return error.MissingReport;
    try std.testing.expect(callee_report.local_branch_count > 0);

    const caller_report = fy.reportWord("inline-abs-call") orelse return error.MissingReport;
    try std.testing.expectEqual(@as(usize, 1), caller_report.bl_count);
}

test "dsp1: marks words and inlines straight-line dsp callees" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("dsp1: dsp-inc 1 + ; dsp1: dsp-call 41 dsp-inc ;");
    try std.testing.expect(fy.isDspWord("dsp-inc"));
    try std.testing.expect(fy.isDspWord("dsp-call"));
    try std.testing.expectEqual(Fy.makeInt(42), try fy.run("dsp-call"));

    const report = fy.reportWord("dsp-call") orelse return error.MissingReport;
    try std.testing.expectEqual(@as(usize, 0), report.bl_count);
    try std.testing.expectEqual(@as(usize, 1), report.push_count);
    try std.testing.expectEqual(@as(usize, 0), report.pop_count);
    try std.testing.expectEqual(@as(usize, 0), report.stack_round_trip_pairs);
}

test "dsp1: register stack keeps straight-line arithmetic off the fy stack" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("inline-noalloc: stack-add 1 2 + ; dsp1: reg-add 1 2 + ;");
    try std.testing.expectEqual(Fy.makeInt(3), try fy.run("stack-add"));
    try std.testing.expectEqual(Fy.makeInt(3), try fy.run("reg-add"));

    const stack_report = fy.reportWord("stack-add") orelse return error.MissingReport;
    const reg_report = fy.reportWord("reg-add") orelse return error.MissingReport;

    try std.testing.expectEqual(@as(usize, 1), reg_report.push_count);
    try std.testing.expectEqual(@as(usize, 0), reg_report.pop_count);
    try std.testing.expectEqual(@as(usize, 0), reg_report.stack_round_trip_pairs);
    try std.testing.expect(reg_report.instruction_count <= 3);
    try std.testing.expect(reg_report.push_count < stack_report.push_count);
    try std.testing.expect(reg_report.pop_count < stack_report.pop_count);

    _ = try fy.run("dsp1: reg-add-neg -5 6 + ;");
    try std.testing.expectEqual(Fy.makeInt(1), try fy.run("reg-add-neg"));

    _ = try fy.run("dsp1: reg-over2 1 2 3 4 over2 + + + + + ;");
    try std.testing.expectEqual(Fy.makeInt(13), try fy.run("reg-over2"));
}

test "dsp1: register stack flushes before stack-memory words" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("dsp1: reg-pick 10 20 30 1 pick + + + ;");
    try std.testing.expectEqual(Fy.makeInt(80), try fy.run("reg-pick"));
}

test "dsp: rational f64 shaper lowers stack code to typed register code" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: rat
        \\  3 pick f@64
        \\  1 pick f*
        \\  -4.0 4.0 fclamp
        \\  dup dup f*
        \\  dup 27.0 f+
        \\  2 pick f*
        \\  1 pick 9.0 f* 27.0 f+
        \\  f/
        \\  -1.0 1.0 fclamp
        \\  swap drop swap drop
        \\  5 pick f!64
        \\  drop drop drop drop drop
        \\;
    );

    var out: f64 = 0;
    var input: f64 = 0.5;
    var table: [1]f64 = .{0};
    const span: i64 = 0;
    const drive: f64 = 2.5;
    const args = [_]Fy.Value{
        Fy.makeInt(@intCast(@intFromPtr(&out))),
        Fy.makeInt(@intCast(@intFromPtr(&input))),
        Fy.makeInt(@intCast(@intFromPtr(&table))),
        Fy.makeInt(span),
        makeFyFloat(drive),
    };

    _ = try fy.callWordRepeatedWithArgsNoResult("rat", 1, &args);
    const x = input * drive;
    const x2 = x * x;
    const expected = @min(@max(x * (27.0 + x2) / (27.0 + 9.0 * x2), -1.0), 1.0);
    try std.testing.expectApproxEqAbs(expected, out, 0.000000000001);

    const report = fy.reportWord("rat") orelse return error.MissingReport;
    try std.testing.expectEqual(@as(usize, 0), report.push_count);
    try std.testing.expectEqual(@as(usize, 0), report.pop_count);
    try std.testing.expect(report.instruction_count < 60);

    const disasm = try fy.disassembleWordAlloc(std.testing.allocator, "rat");
    defer std.testing.allocator.free(disasm);
    try expectContains(disasm, "fdiv d");
    try expectContains(disasm, "fmax d");
    try expectContains(disasm, "fmin d");
}

test "dsp: inlines called dsp2 word before typed codegen" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: rat-core
        \\  3 pick f@64
        \\  1 pick f*
        \\  -4.0 4.0 fclamp
        \\  dup dup f*
        \\  dup 27.0 f+
        \\  2 pick f*
        \\  1 pick 9.0 f* 27.0 f+
        \\  f/
        \\  -1.0 1.0 fclamp
        \\  swap drop swap drop
        \\  5 pick f!64
        \\  drop drop drop drop drop
        \\;
        \\dsp: rat-wrapper rat-core ;
    );

    var out: f64 = 0;
    var input: f64 = 0.5;
    var table: [1]f64 = .{0};
    const args = [_]Fy.Value{
        Fy.makeInt(@intCast(@intFromPtr(&out))),
        Fy.makeInt(@intCast(@intFromPtr(&input))),
        Fy.makeInt(@intCast(@intFromPtr(&table))),
        Fy.makeInt(0),
        makeFyFloat(2.5),
    };

    _ = try fy.callWordRepeatedWithArgsNoResult("rat-wrapper", 1, &args);
    const x = input * 2.5;
    const x2 = x * x;
    const expected = @min(@max(x * (27.0 + x2) / (27.0 + 9.0 * x2), -1.0), 1.0);
    try std.testing.expectApproxEqAbs(expected, out, 0.000000000001);

    const core_report = fy.reportWord("rat-core") orelse return error.MissingReport;
    const wrapper_report = fy.reportWord("rat-wrapper") orelse return error.MissingReport;
    try std.testing.expectEqual(core_report.instruction_count, wrapper_report.instruction_count);
    try std.testing.expectEqual(@as(usize, 0), wrapper_report.bl_count);
    try std.testing.expectEqual(@as(usize, 0), wrapper_report.push_count);
    try std.testing.expectEqual(@as(usize, 0), wrapper_report.pop_count);
}

test "dsp: supports nip and drop2 stack cleanup" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: keep-top 0.0 f+ nip ;
        \\dsp: cleanup
        \\  3 pick f@64
        \\  1 pick f*
        \\  5 pick f!64
        \\  drop2 nip drop2
        \\;
    );

    try std.testing.expectApproxEqAbs(3.5, getFyFloat(try fy.run("1.25 3.5 keep-top")), 0.000000000001);

    var out: f64 = 0;
    var input: f64 = 0.5;
    var unused: [1]f64 = .{0};
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out) },
        .{ .ptr = @intFromPtr(&input) },
        .{ .ptr = @intFromPtr(&unused) },
        .{ .int = 0 },
        .{ .f64 = 2.5 },
    };

    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("cleanup", 1, &args);
    try std.testing.expectApproxEqAbs(1.25, out, 0.000000000001);
}

test "dsp: raw repeated wrapper can advance output and input streams" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: stream-copy2
        \\  | out state params input |
        \\  input f@64
        \\  2.0
        \\  f*
        \\  out
        \\  f!64
        \\  drop2 drop2
        \\;
    );

    var out = [_]f64{0} ** 4;
    var input = [_]f64{ 0.25, -0.5, 0.75, -1.0 };
    var state: f64 = 0;
    var params: f64 = 0;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&input[0]) },
    };

    _ = try fy.callDsp2RawRepeatedWithAutoOutInNoResult("stream-copy2", out.len, &args);
    try std.testing.expectApproxEqAbs(0.5, out[0], 0.000000000001);
    try std.testing.expectApproxEqAbs(-1.0, out[1], 0.000000000001);
    try std.testing.expectApproxEqAbs(1.5, out[2], 0.000000000001);
    try std.testing.expectApproxEqAbs(-2.0, out[3], 0.000000000001);
}

test "dsp: cached raw repeated caller reuses wrapper with new slots" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: cached-copy2
        \\  | out state params input |
        \\  input f@64
        \\  2.0
        \\  f*
        \\  out
        \\  f!64
        \\  drop2 drop2
        \\;
    );

    var slots = Fy.Dsp2RawRepeatedSlots{};
    var caller = try fy.compileDsp2RawRepeatedCaller(
        "cached-copy2",
        &slots,
        &.{ .ptr, .ptr, .ptr, .ptr },
        true,
        true,
    );

    var state: f64 = 0;
    var params: f64 = 0;
    var out_a = [_]f64{0} ** 2;
    var in_a = [_]f64{ 0.5, -0.25 };
    const args_a = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out_a[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&in_a[0]) },
    };
    _ = try caller.call(out_a.len, &args_a);
    try std.testing.expectApproxEqAbs(1.0, out_a[0], 0.000000000001);
    try std.testing.expectApproxEqAbs(-0.5, out_a[1], 0.000000000001);

    var out_b = [_]f64{0} ** 3;
    var in_b = [_]f64{ 1.0, 1.25, -1.5 };
    const args_b = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out_b[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&in_b[0]) },
    };
    _ = try caller.call(out_b.len, &args_b);
    try std.testing.expectApproxEqAbs(2.0, out_b[0], 0.000000000001);
    try std.testing.expectApproxEqAbs(2.5, out_b[1], 0.000000000001);
    try std.testing.expectApproxEqAbs(-3.0, out_b[2], 0.000000000001);
}

test "dsp: ustruct accessors lower to raw IR" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("ustruct: U f64 x f64 y ;");
    _ = fy.run(
        \\dsp: sum-xy
        \\  dup U.x@
        \\  1 pick U.y@
        \\  f+
        \\  2 pick f!64
        \\  drop2
        \\;
    ) catch |err| {
        std.debug.print("sum-xy failed: {}\n", .{err});
        return err;
    };
    _ = fy.run(
        \\dsp: write-y
        \\  2.5 swap U.y! drop
        \\;
    ) catch |err| {
        std.debug.print("write-y failed: {}\n", .{err});
        return err;
    };
    _ = fy.run(
        \\dsp: write-y-p
        \\  3.5 1 pick U.y-p f!64 drop
        \\;
    ) catch |err| {
        std.debug.print("write-y-p failed: {}\n", .{err});
        return err;
    };
    _ = fy.run(
        \\dsp: grouped-sum
        \\  0.0
        \\  U@: x y ;
        \\  f+
        \\  3 pick f!64
        \\  drop2 drop
        \\;
    ) catch |err| {
        std.debug.print("grouped-sum failed: {}\n", .{err});
        return err;
    };
    _ = fy.run(
        \\dsp: local-sum
        \\  | out u |
        \\  u U.x@
        \\  u U.y@
        \\  f+
        \\  out f!64
        \\  drop2
        \\;
    ) catch |err| {
        std.debug.print("local-sum failed: {}\n", .{err});
        return err;
    };
    _ = fy.run(
        \\dsp: local-temp-sum
        \\  | out u |
        \\  u U.x@
        \\  u U.y@
        \\  f+
        \\  | sum |
        \\  sum
        \\  sum
        \\  f+
        \\  out f!64
        \\  drop
        \\  drop2
        \\;
    ) catch |err| {
        std.debug.print("local-temp-sum failed: {}\n", .{err});
        return err;
    };
    _ = fy.run(
        \\dsp: local-helper
        \\  | u |
        \\  u U.x@
        \\  | x |
        \\  x
        \\  x
        \\  f+
        \\  nip
        \\  nip
        \\;
        \\dsp: local-inline-sum
        \\  | out u |
        \\  u local-helper
        \\  out f!64
        \\  drop2
        \\;
    ) catch |err| {
        std.debug.print("local-inline-sum failed: {}\n", .{err});
        return err;
    };

    const U = extern struct {
        x: f64,
        y: f64,
    };
    var out: f64 = 0;
    var u = U{ .x = 1.25, .y = 0.75 };
    const sum_args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out) },
        .{ .ptr = @intFromPtr(&u) },
    };
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("sum-xy", 1, &sum_args);
    try std.testing.expectApproxEqAbs(2.0, out, 0.000000000001);
    out = 0;
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("grouped-sum", 1, &sum_args);
    try std.testing.expectApproxEqAbs(2.0, out, 0.000000000001);
    out = 0;
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("local-sum", 1, &sum_args);
    try std.testing.expectApproxEqAbs(2.0, out, 0.000000000001);
    out = 0;
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("local-temp-sum", 1, &sum_args);
    try std.testing.expectApproxEqAbs(4.0, out, 0.000000000001);
    out = 0;
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("local-inline-sum", 1, &sum_args);
    try std.testing.expectApproxEqAbs(2.5, out, 0.000000000001);

    const state_args = [_]Fy.Dsp2RawArg{.{ .ptr = @intFromPtr(&u) }};
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("write-y", 1, &state_args);
    try std.testing.expectApproxEqAbs(2.5, u.y, 0.000000000001);
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("write-y-p", 1, &state_args);
    try std.testing.expectApproxEqAbs(3.5, u.y, 0.000000000001);

    const report = try fy.reportDsp2RawWord("sum-xy");
    try std.testing.expectEqual(@as(usize, 0), report.bl_count);
    try std.testing.expectEqual(@as(usize, 0), report.push_count);
    try std.testing.expectEqual(@as(usize, 0), report.pop_count);
}

test "dsp: pure f64 helper is callable and inlines into pointer adapter" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: rat-shape
        \\  -4.0 4.0 fclamp
        \\  dup dup f*
        \\  dup 27.0 f+
        \\  2 pick f*
        \\  1 pick 9.0 f* 27.0 f+
        \\  f/
        \\  -1.0 1.0 fclamp
        \\  swap drop swap drop
        \\;
        \\dsp: rat-adapter
        \\  3 pick f@64
        \\  1 pick f*
        \\  rat-shape
        \\  5 pick f!64
        \\  drop drop drop drop drop
        \\;
    );

    const direct_input = 1.25;
    const direct = try fy.run("1.25 rat-shape");
    const direct_x2 = direct_input * direct_input;
    const direct_expected = @min(@max(direct_input * (27.0 + direct_x2) / (27.0 + 9.0 * direct_x2), -1.0), 1.0);
    try std.testing.expectApproxEqAbs(direct_expected, getFyFloat(direct), 0.000000000001);

    var out: f64 = 0;
    var input: f64 = 0.5;
    var table: [1]f64 = .{0};
    const args = [_]Fy.Value{
        Fy.makeInt(@intCast(@intFromPtr(&out))),
        Fy.makeInt(@intCast(@intFromPtr(&input))),
        Fy.makeInt(@intCast(@intFromPtr(&table))),
        Fy.makeInt(0),
        makeFyFloat(2.5),
    };

    _ = try fy.callWordRepeatedWithArgsNoResult("rat-adapter", 1, &args);
    const x = input * 2.5;
    const x2 = x * x;
    const expected = @min(@max(x * (27.0 + x2) / (27.0 + 9.0 * x2), -1.0), 1.0);
    try std.testing.expectApproxEqAbs(expected, out, 0.000000000001);

    const helper_report = fy.reportWord("rat-shape") orelse return error.MissingReport;
    const adapter_report = fy.reportWord("rat-adapter") orelse return error.MissingReport;
    try std.testing.expect(helper_report.push_count >= 1);
    try std.testing.expectEqual(@as(usize, 0), adapter_report.bl_count);
    try std.testing.expectEqual(@as(usize, 0), adapter_report.push_count);
    try std.testing.expectEqual(@as(usize, 0), adapter_report.pop_count);
}

test "dsp: raw repeated call uses untagged pointer and f64 args" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: rat-shape
        \\  -4.0 4.0 fclamp
        \\  dup dup f*
        \\  dup 27.0 f+
        \\  2 pick f*
        \\  1 pick 9.0 f* 27.0 f+
        \\  f/
        \\  -1.0 1.0 fclamp
        \\  swap drop swap drop
        \\;
        \\dsp: rat-adapter
        \\  3 pick f@64
        \\  1 pick f*
        \\  rat-shape
        \\  5 pick f!64
        \\  drop drop drop drop drop
        \\;
    );

    var out: f64 = 0;
    var input: f64 = 0.5;
    var table: [1]f64 = .{0};
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out) },
        .{ .ptr = @intFromPtr(&input) },
        .{ .ptr = @intFromPtr(&table) },
        .{ .int = 0 },
        .{ .f64 = 2.5 },
    };

    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("rat-adapter", 1, &args);
    const x = input * 2.5;
    const x2 = x * x;
    const expected = @min(@max(x * (27.0 + x2) / (27.0 + 9.0 * x2), -1.0), 1.0);
    try std.testing.expectApproxEqAbs(expected, out, 0.000000000001);

    const tagged_report = fy.reportWord("rat-adapter") orelse return error.MissingReport;
    const raw_report = try fy.reportDsp2RawWord("rat-adapter");
    try std.testing.expect(raw_report.instruction_count < tagged_report.instruction_count);
    try std.testing.expectEqual(@as(usize, 0), raw_report.push_count);
    try std.testing.expectEqual(@as(usize, 0), raw_report.pop_count);
}

test "dsp: branchless float select and wrap support oscillator helpers" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: choose-lt fsel-lt ;
        \\dsp: wrap fwrap01 ;
        \\dsp: phase-advance01 f+ fwrap01 ;
        \\dsp: cap fcapramp ;
        \\dsp: polyblep fpolyblep ;
        \\dsp: pulse fpulseblep ;
        \\dsp: adsr fadsr-linear ;
        \\dsp: adsr-cap fadsr-cap ;
    );

    try std.testing.expectApproxEqAbs(10.0, getFyFloat(try fy.run("0.25 0.5 10.0 20.0 choose-lt")), 0.000000000001);
    try std.testing.expectApproxEqAbs(20.0, getFyFloat(try fy.run("0.75 0.5 10.0 20.0 choose-lt")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.25, getFyFloat(try fy.run("1.25 wrap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.75, getFyFloat(try fy.run("-0.25 wrap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.15, getFyFloat(try fy.run("0.90 0.25 phase-advance01")), 0.000000000001);
    try std.testing.expectApproxEqAbs(-1.0, getFyFloat(try fy.run("0.0 cap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.5, getFyFloat(try fy.run("0.5 cap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(1.0, getFyFloat(try fy.run("1.0 cap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(-0.25, getFyFloat(try fy.run("0.05 0.10 polyblep")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.25, getFyFloat(try fy.run("0.95 0.10 polyblep")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.0, getFyFloat(try fy.run("0.50 0.10 polyblep")), 0.000000000001);
    try std.testing.expectApproxEqAbs(1.0, getFyFloat(try fy.run("0.25 0.10 0.50 pulse")), 0.000000000001);
    try std.testing.expectApproxEqAbs(-1.0, getFyFloat(try fy.run("0.75 0.10 0.50 pulse")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.75, getFyFloat(try fy.run("0.05 0.10 0.50 pulse")), 0.000000000001);
    try std.testing.expectApproxEqAbs(-0.75, getFyFloat(try fy.run("0.95 0.10 0.50 pulse")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.75, getFyFloat(try fy.run("0.45 0.10 0.50 pulse")), 0.000000000001);
    try std.testing.expectApproxEqAbs(-0.75, getFyFloat(try fy.run("0.55 0.10 0.50 pulse")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.5, getFyFloat(try fy.run("0.05 0.10 0.20 0.40 0.70 0.30 adsr")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.7, getFyFloat(try fy.run("0.20 0.10 0.20 0.40 0.70 0.30 adsr")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.4, getFyFloat(try fy.run("0.50 0.10 0.20 0.40 0.70 0.30 adsr")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.2, getFyFloat(try fy.run("0.85 0.10 0.20 0.40 0.70 0.30 adsr")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.0, getFyFloat(try fy.run("1.05 0.10 0.20 0.40 0.70 0.30 adsr")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.9375, getFyFloat(try fy.run("0.05 0.10 0.20 0.40 0.70 0.30 adsr-cap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.4375, getFyFloat(try fy.run("0.20 0.10 0.20 0.40 0.70 0.30 adsr-cap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.4, getFyFloat(try fy.run("0.50 0.10 0.20 0.40 0.70 0.30 adsr-cap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.025, getFyFloat(try fy.run("0.85 0.10 0.20 0.40 0.70 0.30 adsr-cap")), 0.000000000001);
    try std.testing.expectApproxEqAbs(0.0, getFyFloat(try fy.run("1.05 0.10 0.20 0.40 0.70 0.30 adsr-cap")), 0.000000000001);
}

test "dsp1: rejects heap allocation" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    const result = fy.run("dsp1: bad alloc ; bad");
    try std.testing.expectError(error.UnknownWord, result);
}

test "dsp: call: composition invokes a stage that writes via memory" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: t-stage | out | 2.5 out f!64 drop ;
        \\dsp: t-compose | out | out call: t-stage ;
    );

    const addr = fy.userWords.get("t-compose").?.image_addr.?;
    const f: *const fn (*f64) callconv(.c) void = @ptrFromInt(addr);
    var out: f64 = 0;
    f(&out);
    try std.testing.expectApproxEqAbs(2.5, out, 0.000000000001);
}

test "dsp: call: composition chains stages through state memory in order" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: t-a | state | 3.0 state f!64 drop ;
        \\dsp: t-b | out state | state f@64 2.0 f* out f!64 drop2 ;
        \\dsp: t-chain
        \\  | out state |
        \\  state call: t-a
        \\  out state call: t-b
        \\;
    );

    const addr = fy.userWords.get("t-chain").?.image_addr.?;
    const f: *const fn (*f64, *f64) callconv(.c) void = @ptrFromInt(addr);
    var out: f64 = 0;
    var state: f64 = 0;
    f(&out, &state);
    try std.testing.expectApproxEqAbs(3.0, state, 0.000000000001);
    try std.testing.expectApproxEqAbs(6.0, out, 0.000000000001);
}

test "dsp: composition repeated caller loops with auto-advanced output" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run(
        \\dsp: t-w | out | 1.5 out f!64 drop ;
        \\dsp: t-rep | out | out call: t-w ;
    );

    try std.testing.expect(fy.isCompositionWord("t-rep"));

    var slots: Fy.Dsp2RawRepeatedSlots = .{};
    var caller = try fy.compileDsp2CompositionCaller("t-rep", &slots, true, false);
    var out = [_]f64{0} ** 4;
    const args = [_]Fy.Dsp2RawArg{.{ .ptr = @intFromPtr(&out[0]) }};
    _ = try caller.call(4, &args);
    for (out) |v| try std.testing.expectApproxEqAbs(1.5, v, 0.000000000001);
}

test "dsp: 4-arg composition caller with auto-advanced out and in" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    // Effect ABI shape: out state params in. Stage 1 accumulates the input
    // into state, stage 2 writes state + params gain to out.
    _ = try fy.run(
        \\dsp: t-fx-acc | state in | state f@64 in f@64 f+ state f!64 drop2 ;
        \\dsp: t-fx-out | out state params | state f@64 params f@64 f* out f!64 drop2 drop ;
        \\dsp: t-fx
        \\  | out state params in |
        \\  state in call: t-fx-acc
        \\  out state params call: t-fx-out
        \\;
    );

    try std.testing.expect(fy.isCompositionWord("t-fx"));

    var slots: Fy.Dsp2RawRepeatedSlots = .{};
    var caller = try fy.compileDsp2CompositionCaller("t-fx", &slots, true, true);
    var out = [_]f64{0} ** 4;
    const in = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    var state: f64 = 0;
    var params: f64 = 10.0;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out[0]) },
        .{ .ptr = @intFromPtr(&state) },
        .{ .ptr = @intFromPtr(&params) },
        .{ .ptr = @intFromPtr(&in[0]) },
    };
    _ = try caller.call(4, &args);
    // running sums 1,3,6,10 × gain 10
    try std.testing.expectApproxEqAbs(10.0, out[0], 0.000000000001);
    try std.testing.expectApproxEqAbs(30.0, out[1], 0.000000000001);
    try std.testing.expectApproxEqAbs(60.0, out[2], 0.000000000001);
    try std.testing.expectApproxEqAbs(100.0, out[3], 0.000000000001);
}

test "struct/ustruct introspection: size, field offsets, field sizes" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    Fy.Builtins.fyPtr = @intFromPtr(&fy);

    _ = try fy.run("ustruct: IV f64 a f64 b f32 c f64 d ;");
    try runCases(&fy, &[_]TestCase{
        .{ .input = "IV.size", .expected = Fy.makeInt(32) }, // c pads to 8 for d
        .{ .input = "IV.a", .expected = Fy.makeInt(0) },
        .{ .input = "IV.b", .expected = Fy.makeInt(8) },
        .{ .input = "IV.c", .expected = Fy.makeInt(16) },
        .{ .input = "IV.d", .expected = Fy.makeInt(24) },
        .{ .input = "IV.c-size", .expected = Fy.makeInt(4) },
        .{ .input = "IV.d-size", .expected = Fy.makeInt(8) },
    });

    _ = try fy.run("struct: TV u32 n ptr p f32 g ;");
    try runCases(&fy, &[_]TestCase{
        .{ .input = "TV.n", .expected = Fy.makeInt(0) },
        .{ .input = "TV.p", .expected = Fy.makeInt(8) },
        .{ .input = "TV.g", .expected = Fy.makeInt(16) },
        .{ .input = "TV.p-size", .expected = Fy.makeInt(8) },
        .{ .input = "TV.size", .expected = Fy.makeInt(24) }, // 20 padded to ptr align
    });

    // Introspection constants are usable inside normal word definitions.
    _ = try fy.run(": iv-b-end IV.b IV.b-size + ;");
    try runCases(&fy, &[_]TestCase{
        .{ .input = "iv-b-end", .expected = Fy.makeInt(16) },
    });
}

test "dsp: ustruct introspection constants resolve as int consts" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    _ = try fy.run(
        \\ustruct: IC f64 a f64 b f64 c ;
        \\dsp: k-ic-third | out base | base IC.c ptr+ f@64 out f!64 drop2 ;
    );
    var vals = [_]f64{ 1.5, 2.5, 3.5 };
    var out: f64 = 0;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out) },
        .{ .ptr = @intFromPtr(&vals[0]) },
    };
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("k-ic-third", 1, &args);
    try std.testing.expectEqual(@as(f64, 3.5), out);
}

test "dsp: f@i / f!i runtime-indexed f64 access" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    _ = try fy.run(
        \\dsp: k-ring-rot | out base idx | base idx f@i  base idx 1.0 f+ f@i f+  out f!64  base idx f@i  base 0.5 f!i  drop2 drop ;
    );
    var cells = [_]f64{ 10.0, 20.0, 30.0, 40.0 };
    var out: f64 = 0;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out) },
        .{ .ptr = @intFromPtr(&cells[0]) },
        .{ .f64 = 1.0 },
    };
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("k-ring-rot", 1, &args);
    try std.testing.expectEqual(@as(f64, 50.0), out); // cells[1] + cells[2]
    try std.testing.expectEqual(@as(f64, 20.0), cells[0]); // stored old cells[1] at idx 0.5 -> floor 0
    try std.testing.expectEqual(@as(f64, 20.0), cells[1]);
}

test "dsp: p@64 loads a pointer through state" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    // state cell 0 holds a pointer to a buffer; read element idx from it.
    _ = try fy.run(
        \\dsp: k-pload | out state idx | state p@64 idx f@i out f!64 drop2 drop ;
    );
    var buffer = [_]f64{ 7.0, 8.0, 9.0 };
    var state = [_]u64{@intFromPtr(&buffer[0])};
    var out: f64 = 0;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out) },
        .{ .ptr = @intFromPtr(&state[0]) },
        .{ .f64 = 2.0 },
    };
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("k-pload", 1, &args);
    try std.testing.expectEqual(@as(f64, 9.0), out);
}

test "dsp: declared stack effect sets arity and checks outputs" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    _ = try fy.run(
        \\dsp: k-eff-add ( out a b -- ) | out a b | a b f+ out f!64 drop2 drop ;
    );
    var out: f64 = 0;
    const args = [_]Fy.Dsp2RawArg{
        .{ .ptr = @intFromPtr(&out) },
        .{ .f64 = 1.25 },
        .{ .f64 = 2.5 },
    };
    _ = try fy.callDsp2RawRepeatedWithArgsNoResult("k-eff-add", 1, &args);
    try std.testing.expectEqual(@as(f64, 3.75), out);
    // Declared one output, body leaves two.
    try std.testing.expectError(error.UnknownWord, fy.run("dsp: k-eff-bad ( a b -- c ) | a b | a b f+ a nip nip ;"));
    // A comment without `--` after the name is still just a comment.
    _ = try fy.run("dsp: k-eff-comment ( plain note ) | out a | a out f!64 drop2 ;");
}

test "dsp: build errors are reported, not swallowed" {
    var fy = Fy.init(std.testing.allocator);
    defer fy.deinit();
    try std.testing.expectError(error.UnknownWord, fy.run("dsp: k-err-typo | p | 1.0 2.0 fplus p f!64 drop ;"));
    try std.testing.expectError(error.UnknownWord, fy.run("dsp: k-err-under | x | x f+ nip ;"));
}
