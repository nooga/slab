# 09 — Hot-reload and livecoding

The "pop the face off" gesture. Users edit machine source in Slab's
built-in editor or in VSCode, save, and the running
audio picks up the change on the next block. This is the signature
capability of the product — the architecture has to earn it.

## What we inherit from fy

fy already ships a word-level hot-patch model via a TCP listener
and a trampoline indirection layer. From the fy docs:

> Every user-defined word gets a stable 4-byte trampoline (a single
> ARM64 `B` instruction). All callers jump to the trampoline, which
> jumps to the actual code. When a word is redefined, only the
> trampoline's target is patched — every caller instantly sees the
> new behavior.

The VSCode extension (`editors/vscode/fy-lang/`) sends `: word …
;` definitions over TCP; the runtime compiles and patches the
trampoline under mutex; next invocation runs new code.

Slab reuses this wholesale. The hot-patch TCP port moves into the
Slab process. VSCode still talks to one endpoint.
The builtin editor uses the same function path directly (no TCP
round-trip).

## What we extend

Three things:

### 1. File-watcher → hot-patch

Slab watches each loaded machine's `panel.fy`, `dsp.fy`, and
any `include`d files. On save, it:

1. Parses the changed file's top-level definitions.
2. For each definition, compiles and patches its trampoline (same
   path as TCP hot-patch).
3. Marks affected UI panels for redraw.

Users can also save via built-in editor; same path.

### 2. Stack-effect verification

fy's docs note:

> Stack-incompatible redefinitions may crash — if a word previously
> returned 1 value and you redefine it to return 3, callers
> compiled with the old stack effect will misbehave.

For a DAW with live audio, "may crash" is unacceptable. Extension:

- Every word records its stack effect on first compile.
- On hot-patch, the new definition is compiled, its stack effect
  computed, and compared to the prior.
- **Mismatch → patch is refused** with a structured error returned
  to the editor.

Stack effect computation is tractable for `dsp:` mode because the
language subset is small and nearly always has a static stack
effect. For full fy (panels, UI), the effect can be partially
inferred; when it can't, the patch is allowed but flagged. `dsp:`
mode has the stricter check because audio-thread code is where a
mismatch causes immediate audible destruction.

### 3. Inline site registry (ship mode)

`dsp:` mode default-inlines its callees for performance. Inlined
code is embedded in the caller's body, not reached via a
trampoline. Hot-patching an inlined word therefore doesn't affect
existing callers.

Two solutions, one config knob:

**Dev mode (default while editing).** Inlining is *disabled* for
`dsp:` calls. Every cross-word call is a `BL` through the
trampoline. Hot-patch works normally. Cost: ~5–15% slower inner
loops, acceptable for livecoding.

**Ship mode.** Inlining is enabled. The compiler maintains a per-word
"inlined-into" registry: when word `svf-lp` is inlined into words
A, B, C, the registry records `{svf-lp → [A, B, C]}`. On hot-patch
of `svf-lp`:

1. Patch `svf-lp`'s trampoline (for non-inlined callers).
2. For each word in the inlined-into set, re-emit the caller's body
   with the new `svf-lp` body inlined.
3. Atomically swap each re-emitted caller's trampoline.
4. Flush icache.

This introduces a brief compile pause (10–100ms depending on fan-out)
on each kernel edit in ship mode. Dev mode avoids this by paying the
runtime BL cost instead.

The mode is a runtime flag; users can toggle it in the project
settings.

## What can be hot-patched

| edit | hot-patch result |
|---|---|
| `:` word body change | Yes, trampoline patched. |
| `dsp:` word body change | Yes, with stack-effect verify. |
| New word added | Yes, registered fresh. |
| Word removed | Patch refused until callers updated (or allowed with stub that errors at call). |
| `::` constant change | Patched *by value*, but callers compiled with the old constant don't pick it up (fy inlines constants). Warned. |
| `macro:` change | Affects *future* compilations only. |
| `struct:` field added at end | Compatible. Existing params/voice instances keep layout, new field gets default. |
| `struct:` field reordered/removed | Breaking. Machine instances cold-reload from defaults. |
| `machine:` declaration change | Re-registers machine; existing instances migrated if compatible. |

## The guarantees under hot-patch

Three levels of promise:

1. **Audio never glitches from a refused patch.** If the patch is
   rejected (stack-effect, heap-access violation in `dsp:`, etc.),
   the machine continues running the old code unchanged. The editor
   shows the error.

2. **Audio may produce a one-block discontinuity on accepted
   patch.** A new filter topology might have different state
   initialization; the first block after patch can click. This is
   acceptable and documented. Users learn to patch during quiet
   moments or engineer crossfades into their kernels.

3. **Audio state is never corrupted across a patch.** The machine's
   persistent arena and voice states stay valid. Params stay in
   their current smoothed values. Only the code behind the
   trampoline changes.

## What can NOT be hot-patched

- **Changes to a machine's params struct layout.** The params
  struct is the ABI surface. Reordering fields means pointers into
  the struct from UI code point at wrong offsets. The host refuses
  and requires a machine reinstantiation (existing param values
  dropped to defaults unless the machine provides a migration word
  — see [08-services.md](08-services.md#preset-system)).
- **Changes to `voice-state` struct layout.** Same reasoning.
  Live notes are released; new notes get new-layout voice slabs.
- **Changes to manifest memory sizing** (`persistent-scratch`,
  `block-scratch`, `voice-count`). Requires reallocating arenas,
  which requires a cold reinstantiation.

All of these are *allowed* — they just do cold reload instead of
hot-patch. The editor flags them as "restart-required" changes.

## The editor experience

In Slab's built-in editor (or in VSCode with the fy extension):

1. Edit a `dsp:` word body.
2. Save the file.
3. A badge flashes at the top of the source view: green "patched"
   / red "refused: stack effect 2→3 changed, was 2→2" / yellow
   "patched with warnings".
4. For panel words: the panel redraws on the next frame.
5. For `dsp:` words: the next audio block runs new code.
6. A brief ripple animation on the affected machine's panel header
   indicates which instance(s) picked up the change.

Users can revert a patch with `⌘Z` (which re-sends the prior
source). Patch history is kept per file for the session.

## Multi-instance behavior

A machine loaded N times has N instances but one code image. A
hot-patch updates the code for all instances simultaneously. Each
instance keeps its own persistent state; the change is universal.

(This is different from "a preset change affects one instance" —
presets are values, code is structure.)

## Thread interaction recap

```
UI thread                       Audio thread
─────────                       ────────────
save file →                     (running previous code)
parse, compile →
acquire fy_mutex →
verify stack effect →
patch trampoline target →
flush icache →
release fy_mutex
                                (next block starts)
                                trampoline B jumps to new code →
                                (new code runs)
```

Worst case: ~a few microseconds of main-thread-blocked while the
patch is applied. The audio thread is never blocked by a patch —
it only ever reads trampoline targets, and the read-after-write
ordering is guaranteed by the icache flush + memory barrier.

## `struct:` layout versioning — how it plays with hot-reload

The params struct has a **layout hash** computed at compile time
(hash of field types + names + order). At machine load, the host
stores this hash alongside the machine instance. On hot-reload of
`params.struct`:

- New hash == old hash → layout unchanged, hot-patchable.
- New hash != old hash but only appends → host can extend existing
  instances in place (given headroom in persistent arena) and zero-
  init new fields.
- New hash != old hash and structural → cold reload; params go to
  defaults (or through migration word if provided).

The user gets a dialog on structural change: "Reload with defaults?
/ Migrate from old values? / Cancel."

## Livecoding discipline

Users get taught (via docs and by the product's affordances):

- Edit `dsp:` bodies freely; structure remains stable.
- When changing struct layouts or manifest fields, expect a cold
  reload.
- Test new filter topologies in "audition mode" (quiet playback)
  before relying on them in a live set.
- Version-control machines with git — the preset hash and manifest
  version let you roll back cleanly.

Hot-reload is a tool, not a guarantee of magical correctness. Good
livecoding affordances + a strict `dsp:` mode + stack-effect checks
buy you a very high ceiling before you hit a footgun, but they
don't eliminate them entirely. The product's job is to make the
common case (tweak a kernel, hear the change) feel frictionless,
and to make the footgun cases (layout changes) impossible rather
than dangerous.
