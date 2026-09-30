---
name: slab-machine
description: Write, change, or speed up a Slab machine (synth, drum machine, effect) and its fy dsp kernels. Use it for any work in machines/ or kernels/, a new machine, a machine's DSP or panel or presets, or making a machine or a song cheaper on the CPU.
---

# Slab machine development

A machine is a declaration (`machines/<id>/<id>.fy`) over a kernel (a
`dsp:` word in `kernels/NN-layer/*.fy`) that the host runs once per
sample through FyRawMachine (`src/machines/fy_raw_machine.zig`). The
docs are the source of truth. Read the parts the task needs; don't work
from memory.

## Read first

| For | Read |
|---|---|
| file layout, the manifest, modes, params/state, authoring flow | docs/02-machines.md |
| entry words and their stack effects, Ctx/Io fields, when each hook runs, idle skipping, `tail!` | docs/04-block-contract.md §Kernel ABI, §Idle skipping |
| the `dsp:` language: frames, typed locals, memory order, words, dsp-std, `times`, `table:` | docs/18-fy-dsp-language.md |
| **performance**: lanes, `ifte` branching, and the rules for a fast machine | docs/05-kernels.md §Writing fast machines, §Lane mode, §Branching |
| the kernel layers to build from | docs/13 §Kernel library as layers, then `kernels/` itself |
| panel layout and controls | docs/15-machine-panels.md, docs/06 |
| presets and the project format | docs/19-project-format.md |
| the bench: cases, sweeps, goldens, cost | docs/13 §Bench v2 |
| what existing machines expose | docs/20-machine-reference.md (generated) |

The vocabulary reference is the header comment of
`machines/lib/manifest.fy` plus its word definitions. The ABI structs
are in `kernels/00-primitives/ctx.fy`.

Good small models to copy: `machines/gate2` (a keyed effect),
`machines/delay2` (a host buffer, a sync switch), `machines/juno2` (a
poly voice with note hooks). `kernels/02-shapers/shapers.fy` and
`machines/sat2` show `ifte` modes and a bypassable oversampler.

## Workflow

1. Write the kernel: `ustruct`s for params (user fields, then derived
   fields) and state, then `block-prepare`/`derive` for the derived
   values, then the render word `| io:Io ctx:Ctx state:S params:P -- |`.
   Build from the kernel layers: math.fy, the osc and filter
   primitives, oversample.fy.
2. Write `machines/<id>/<id>.fy` with the includes and `: manifest …
   machine-desc ;`. Add its path to `src/machine_registry.zig`.
3. Run `zig build bench -- machines/<id>`. Read
   `scratch/bench/<id>/report.md` and look at the PNG sheets (don't dump
   samples). Run `--sweep=all` to check the knob response.
4. Time it with `zig build bench -Doptimize=ReleaseFast -- machines/<id>`
   (ns/sample, `## cost`). Work down the performance checklist.
5. Run `zig build test` (the whole suite; `-Dtest-filter` misses the
   registry tests), then `zig build bench -- --all --check --no-sheets`.
   Once it sounds right, record goldens with `--record`.
6. Add presets in `machines/<id>/presets/`, then regenerate docs/20 with
   `tools/slabkit/gen_reference.py`. Update the docs a behavior change
   touches in the same commit.

## Performance checklist

A song shares one core, 20.8 µs per sample at 48 kHz. The details are
in docs/05 §Writing fast machines.

- [ ] Knob-only math (`exp`, `tan-warp`, `db>lin`, coefficients) happens
      in `block-prepare`/`derive`. The render word only reads derived
      fields. Slow voice modulation goes in `control!`.
- [ ] Every mode, waveform switch, "off at 0" stage and bypassable
      oversampler sits behind `params.x … ifte`, not a `select` of every
      path. The guard reads only params, ctx, or fields the body never
      stores to. Stateful arms hold their state or zero it, by choice.
- [ ] The render word is lane-eligible: no stack outputs, no stores
      through params, no `call:` composition. The log must not say
      "renders without NEON lanes". Avoid per-sample branching on
      `ctx.chan`; seed per-channel state in `prepare` instead.
- [ ] It can go idle: no free-running noise or DC on silent input, and
      releases that reach true zero (under 1e-6). Declare `tail!` for
      sound stored outside `buffer`s; `-1.0 tail!` only if it really
      sounds from silence.
- [ ] Only the nonlinearity is oversampled.
- [ ] No long chains of complex word calls inside one `dsp:` word; split
      them into separate kernel calls.
- [ ] `voices!` fits the instrument.
- [ ] A/B each optimization with `--no-branches` / `--no-neon`. The
      output must be bit-identical, per `--check`.

## Gotchas that bite

- `prepare` runs **every block**, once per state region. Never reset
  voice state there; seed it lazily in note-on.
- `| a b |` pops its values. A `)` inside a `( comment )` ends the
  comment, so write "[0, 1)" with brackets.
- Loads see earlier stores to the same field, but `f!i` lands at the end
  of the word. An `f!i` inside an if-converted `ifte` arm becomes a
  conditional store, which keeps the word out of lane mode.
- A `ustruct` field named `size` shadows `Struct.size`, so
  `params-size!` gets that field's offset. Name it something else.
- Voice render words **accumulate** into `io.out-l`; effects write it.
- Control ids are the save format. Renaming one breaks presets and
  projects; reordering struct fields doesn't.
- Nothing on the audio thread allocates or locks. Buffers and assets are
  declared in the manifest and allocated by the host.
- `render-lite!` is legacy. Use `ifte` in new code.
- The fy CLI crashes on some paths. Iterate through slab (the bench,
  `zig build kernel-probe`), not the fy CLI.
