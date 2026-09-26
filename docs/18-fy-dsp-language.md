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

A field can be an inline array, `f64 taps 16`, or another ustruct,
`Dec4 dec`; both are passed by address (`s.dec&`), and `s.dec` alone is
an error. `S.field-size` is the whole extent.

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

Arithmetic: `f+ f- f* f/ fmin fmax fabs fneg fsqrt floor`, and the
exponent-bit primitives `fexp2i` (2^floor n), `flog2i` (floor log2 |x|)
and `fmant` (|x| with the exponent cleared: 1 ≤ m < 2), which dsp-std
builds `exp2`/`log2` on. Sugar: `fclamp` (`x lo hi`), `ffrac`
(`x - floor x`).

Masks and select:

| Word | Effect |
|---|---|
| `f< f<= f> f>= f=` | `a b -- mask`: all ones where true, zero where false (NaN is false) |
| `and or not` | combine masks |
| `select` | `m t f -- m ? t : f` |
| `mask>f` | `m -- 1.0 / 0.0` |
| `fsel-lt` | `a b t f -- a < b ? t : f`, sugar for `f<` + `select` |

A mask is a 64-bit pattern in a d-register, the shape NEON compares
produce, so the same code vectorizes (docs/17 A9). A compare used once by
a `select` compiles to `fcmp` + `fcsel`; a mask used more than once is
materialized and selects with `bsl`.

There are no DSP algorithms in the compiler. polyBLEP, pulse BLEP, the
ADSRs, the cap ramp and phase wrap are fy words in
`kernels/01-oscillators/primitives/` and `kernels/03-envelopes/primitives/`.

## dsp-std

`kernels/00-primitives/math.fy` is the math library. Every word is plain
fy on the ops above; the polynomial fits come from `tools/fit/minimax.py`
and pin the value at zero, so `0.0 db>lin` is exactly 1.0 and `0.0 tanh`
exactly 0.0. `src/dsp_std_test.zig` checks each against libm.

| Word | Max error |
|---|---|
| `exp2 exp pow db>lin` | 4.7e-11 relative |
| `log2 ln lin>db` | 1.1e-12 absolute (log2) |
| `sin cos sinpi cospi sin2pi` | 3e-11 absolute |
| `tan` | 3e-11 relative |
| `tan-warp` | 7e-9 relative, \|x\| < 1.45: the filter prewarp, half the cost of `tan` |
| `tanh` | 2.3e-11 absolute |
| `tanh-fast` | 1e-6 below \|x\| = 3, 1e-4 near 5: the tanh inside filter loops |

Oversampling is `kernels/00-primitives/oversample.fy`: `up2`/`dec2` and
`up4`/`dec4`, polyphase IIR halfbands (one multiply per allpass section,
17 per sample for 4x), flat to 20 kHz with aliases at −111 dB. A voice
renders four substeps inline and hands them to `dec4`; an effect runs
`up4` on its input first.

`tanh-rational` (`kernels/02-shapers/rational.fy`) is a soft-clip shaper
with its own character, not an approximation of `tanh`.

## Constants and tables

`:: NAME value ;` constants are inlined by `dsp:` words: floats as f64
literals (exact when the body is a single literal), integers as ints.

`table: name len body ;` builds `len + 1` f64 when the file loads. The
body is ordinary fy (heap, loops, libm through `bind:`), run for
i = 0.0 … len, leaving one number. `name` is the table's address and
`name-len` its length as a float; a `dsp:` word reads it with `f@i` or
`tbl-lerp` from `kernels/00-primitives/table.fy`:

```
table: curve 256  256.0 f/ dup f* ;
dsp: shape | x -- y |  curve  x curve-len f*  tbl-lerp ;
```

The extra cell at i = len keeps interpolation at the last index in bounds
(and equals cell 0 for a periodic body). A table lives until the fy
instance is torn down, so code compiled against an older definition stays
valid across a hot reload.

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
