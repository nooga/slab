# 00 — Vision

## What this is

A DAW that looks and feels like a serious production tool — tracks,
mixer, piano roll, automation lanes, signal routing, transport — where
**every machine inside the frame is a livecodable source file**. You
pop the face off an oscillator, a compressor, a panel, and you see the
code that makes it. You edit the code, hit a key, and the running
audio immediately plays the new version.

The frame is Zig. The machines are [fy](../fy/).

## What "machine" means

A machine is a single unit of functionality — a synth, a drum kit,
an effect, a note transformer, a generative sequencer, a meter, a
custom visualiser. Every machine is:

- a source directory on disk
- a manifest declaring params, I/O, polyphony, memory needs
- a panel (fy words that draw its UI and handle its events)
- a DSP word (fy that processes one audio block per call)
- optional assets (wavetables, samples, IRs)

That's the whole extensibility surface. No C++ plugin SDK, no Rack-style
headers, no separate build. Author in the DAW itself or in VSCode with
fy's existing hot-patch bridge.

## Why this could be good

Three reasons. Anything less and it's just another DAW.

**1. Liveness without ceiling.**
Max/MSP, Reaktor, gen~, SuperCollider all have livecoding. They all
have ceilings — either the DSP quality caps out (gen~ is good but not
Serum), or the UI is locked (Reaktor panels are not Live panels), or
the language can't express what commercial synths do (too abstract,
too slow, too niche). If fy's `dsp:` mode can compile to the same
ARM64+NEON a hand-tuned C kernel would produce, and the host gives
machines the same services commercial plugins get (voice management,
oversampling, param smoothing, latency compensation), then a fy machine
can in principle sound as good as a commercial one *and* be editable
while it plays. That's a new thing.

**2. One language, bottom to top.**
The kernel library and the user's machines are the same language, same
runtime, same hot-patch model. A user who wants a weird resonant notch
filter with a cubic nonlinearity in the feedback path writes a 20-line
`dsp:` word and it's there. Users who read that word's source see the
same kind of code the built-in kernels are written in. The gap between
"product user" and "product contributor" is a keyboard.

**3. Brutalism as license.**
1px-bevel CDE/Win95 framing is a design stance. It says: the frame is
utilitarian; interestingness lives inside the panels. Machine authors
are then free to make their panels look however weird they want — a
brutalist frame absorbs all of it. The whole ecosystem coheres
visually even when twenty different people wrote twenty different
panels.

## What "really good" looks like

The quality bar is not "interesting toy" — it's:

- **TAL-U-NO-LX / Juno / SH-101 / Pro-One** — analog synths with
  antialiased oscillators, ZDF filters, proper envelopes, chorus/BBD
- **DX7** — 6-operator FM with exact envelope curves and feedback
- **Synth1 / JP-8000** — supersaw, unison, ladder filters
- **Serum-class wavetable** — mipmap'd wavetables, warp modes, big
  mod matrix
- **TR-808** — bridged-T kick, noise+BPF snare, metallic ring cymbals
- **FabFilter-class effects** — multi-band comp, linear-phase EQ,
  spectral manipulation, saturation, stereo tools

Every one of these is buildable from a small set of well-factored
kernels plus machine-specific glue. The architecture has to deliver
those kernels with the right ergonomics. See
[05-kernels.md](05-kernels.md).

## Non-goals

- Plugin hosting (VST/AU/AAX). Never, probably.
- Cross-platform. macOS on Apple Silicon only — that's a hard
  constraint from fy's JIT (`MAP_JIT`, `pthread_jit_write_protect_np`).
- Video. fuvid exists for that.
- Replacing Ableton. Matching Ableton's feature matrix is not the
  goal; matching its "feels like a serious instrument" quality is.
- Being easy to learn in 10 minutes. It's a livecoding DAW. There's a
  learning curve. The payoff is the ceiling.

## Decisions already made

- Host: Zig (same language as fy, can embed fy directly)
- Extension language: fy, with a `dsp:` sub-mode for audio-thread code
- Rendering: immediate-mode (probably raylib, reusing what fy already binds)
- Graph model: Live-style (tracks → sends → master) for v1; node-graph later
- Aesthetic: brutalist, 1px bevels, CDE/Workbench/NeXT neighborhood
- Memory: host-owned arenas, machines never touch fy's GC heap on audio
- Hot-patch: trampoline-based (fy already has it); extend to machines
