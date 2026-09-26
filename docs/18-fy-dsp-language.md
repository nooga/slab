# 18 — The fy `dsp:` language

Reference for writing kernels in fy's `dsp:` mode, as implemented in
`../fy/src/dsp2.zig` (value-graph builder and codegen) and
`../fy/src/main.zig` (`compileDsp2`, the parser side). docs/17 Track A
is the plan this implements; docs/04 §Kernel ABI covers what the host
passes in.

A `dsp:` word is compiled to a straight-line value graph (SSA), then to
ARM64 with registers allocated per word. There are no branches, no heap,
and no calls except explicit `call:` stages.

## Words and frames

```
dsp: ms20-ota-step | fs:Ms20OtaState x g k drive -- y |
  x drive f*  fs.fb f+ | e |
  fs.y1 | y1 |
  e y1 f- k-tanh-rational-shape-dsp2 g f*  y1 f+ | y1n |
  ...
  y1n -> fs.y1
  y2n
;
```

- **`| a b |` pops and binds.** The top values leave the stack and become
  named locals. Naming a local pushes its value; a local can be used any
  number of times. No cleanup is needed: nothing bound stays on the stack.
- **A later frame binds mid-word**: `x drive f* | e |` names a result. A
  new frame may reuse a name; the innermost binding wins, which is how a
  value is "updated" (`y1 … | y1 |`).
- **The leading frame is the declaration** when it contains `--`:
  `| s:State x -- y |` takes two inputs and leaves one output. The
  compiler checks the output count. Output names are documentation.
- **Paren declarations** `dsp: sq ( x -- y ) dup f* ;` still work for
  point-free words and are also checked. If a word has both, they must
  agree.
- Without a declaration the arity comes from the leading frame, or is
  searched (0..16) for the first arity that builds.

## Typed locals and fields

`s:Struct` gives a local a `ustruct:` type:

| Form | Meaning |
|---|---|
| `s.field` | load the field (f64 → `f@64`, ptr → `p@64`) |
| `s.field&` | the field's address (pass it to a stateful helper) |
| `value -> s.field` | store (f64 fields) |

Untyped pointers still use the struct accessors `ptr Struct.field@`,
`ptr Struct.field-p`, and the constants `Struct.size`, `Struct.field`
(offset), `Struct.field-size`.

## Memory order

- **A load sees an earlier store to the same field in the same word.**
  "Same field" means the same root pointer plus the same constant offset,
  including through `ptr+` and `s.field&` chains, so a helper that writes
  through `s.phase&` and a later `s.phase` read agree.
- A later store to a field replaces an earlier one.
- Stores are written to memory at the end of the word, so a load never
  observes a store from later in the program.
- **Indexed stores (`f!i`) have no constant address**: a later `f@i` in
  the same word reads memory as it was at word entry. Delay lines write
  one cell and read another, so this is what they want.

## Composition

A word that names another `dsp:` word inlines its body: the callee's
outputs are values in the caller, so stages return results.

```
dsp: k-juno-voice | io ctx state params -- |
  state params jn-mod | lfo env |
  state  ctx state params lfo jn-dco
  state params lfo env jn-cutoff  jn-ladder
  state params rot jn-hpf | y |
  io state params env y jn-vca
;
```

`call: word` is a real call: the stage is compiled separately and called
with the pointer args. A word containing `call:` may hold only one frame
(1..4 pointer args), references to those args, and `call:` lines. The
stages must write through memory (no stack outputs). Use it to outline
code, not to fit a register budget; spilling handles that now.

## Registers and spilling

A body that fits in registers compiles in one pass. One that does not is
compiled again with spilling. A dry pass records the order in which
values are requested. The real pass then evicts the live value whose
next use is furthest away (Belady) to a stack slot, or recomputes it if
it is a constant or an entry-stack arg. Destinations are allocated after
operands, so deep expressions don't hold a register per level.
`RegisterExhausted` now only means more than 8 pointer args, or a frame
over 4 KB of spill slots.

Constants: `fmov #imm` covers ±(16..31)/16·2^-3..2^4 (0.5, 1.0, 2.5,
27.0, …), `0.0` is `fmov d, xzr`, and other values cost one to four
`movz`/`movk` plus `fmov`.

## Word set

Stack: `dup drop drop2 swap nip over rot pick` (`pick` needs a constant
index).

Memory: `f@64 f!64 p@64 ptr+` (constant offset), `f@i f!i` (base + floor
of an f64 index × 8).

Math: `f+ f- f* f/ fclamp ffrac fwrap01 fsel-lt` (`a b t f -- a<b ? t : f`).

Fused (to be moved out to fy, docs/17 A5): `fcapramp fpolyblep
fpulseblep fadsr-linear fadsr-cap`.

Not yet (docs/17 A4): `fabs fmin fmax fsqrt floor`, compares and masks.
Build them from `fsel-lt`: `fabs` = `x 0.0 0.0 x f- x fsel-lt`,
`fmax a b` = `a b b a fsel-lt`.

## Errors

Build errors name the word, the token, the line, the stack depth and the
arity, including inside an inlined word:

```
dsp: k-ms20-voice-sample: type mismatch (f64 vs ptr/int) at `f!64`
  inside inlined `v-vca` (line 267); stack depth 0, arity 4
```

## Migrations (2026-09-26)

`tools/migrate/consuming_locals.py` and `tools/migrate/typed_fields.py`
rewrote every kernel. The first used a report from the compiler, built
with temporary instrumentation under the old non-consuming locals, that
named every drop/nip whose only job was removing a bound local. The
second typed the frame locals and rewrote the accessors. Both preserved
every golden bit-exactly except one intended change: the MS-20 filter
envelope now reads this sample's note age (it used to read the value from
before the increment, because stores were deferred).
