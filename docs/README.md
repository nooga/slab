# Slab documentation

**Slab Audio Workstation (SAW)** — livecodable DAW with a Zig frame
and fy-scripted machines. These pages cover composing, current formats
and features, and the architectural plans behind them.

**Start composing:** [33-composing.md](33-composing.md) walks from a
musical brief through a runnable sketch, GEQ, routing, automation and export.
[21-production-guide.md](21-production-guide.md) covers arrangement and mixing
in more depth; [slabkit](../tools/slabkit/README.md) is the Python API cheat sheet.

**Current releases:** [CHANGELOG.md](../CHANGELOG.md). The working beta has
32 tracks including buses, shared sends, sidechains, clip automation,
per-note expression and headless mix/stem export. For current machine
controls use [20-machine-reference.md](20-machine-reference.md) or
`slab --describe`; limits and serialization are in docs/19 and the source.

**Design history:** [17-direction.md](17-direction.md), the dated milestones
in [10-roadmap.md](10-roadmap.md), and [sessions](sessions/) record plans
and earlier results. They are not a complete inventory of today's features.
[34-production-wishlist.md](34-production-wishlist.md) collects production
improvements with existing capabilities and acceptance criteria.

For architecture, read the numbered foundations in order. Later feature
documents contain both implementation notes and proposals; check their
status and the source before assuming a feature is absent or complete.

1. [00-vision.md](00-vision.md) — what this product is and why it
   could be good
2. [01-architecture.md](01-architecture.md) — Zig host / fy machines,
   process model, embedding fy
3. [02-machines.md](02-machines.md) — the machine as the extensibility
   unit; manifest, lifecycle, versioning
4. [03-memory-model.md](03-memory-model.md) — arenas, double-buffered
   params, the no-GC-on-audio invariant
5. [04-block-contract.md](04-block-contract.md) — the `ctx` struct
   passed to every machine's `process`; note events; port model
6. [05-kernels.md](05-kernels.md) — `dsp:` mode, NEON assembler
   extension, combinator-based authoring, compile-time fusion
7. [06-ui-widgets.md](06-ui-widgets.md) — UI system: pixel grid, Tamzen
   type, materials, OLED/VFD displays, control catalogue, tiered sizing,
   the `Ui` core, pop-the-face gesture
8. [07-transport.md](07-transport.md) — audio-clock-authoritative
   transport, block scheduling, graph model, plugin delay
   compensation
9. [08-services.md](08-services.md) — polyphonic voice pool,
   oversampler wrapper, param smoother, modulation matrix, preset
   system
10. [09-hot-reload.md](09-hot-reload.md) — livecoding model,
    stack-effect checks, dev vs ship compile strategies
11. [10-roadmap.md](10-roadmap.md) — MVP slice, milestones, explicit
    non-goals
12. [11-fy-integration-plan.md](11-fy-integration-plan.md) — staged
    plan for embedding Fy and moving audio words into the host
13. [12-ux-interaction-spec.md](12-ux-interaction-spec.md) — frame UI
    behavior, zoom rules, keybinds, and tooltips
14. [13-dsp-workbench.md](13-dsp-workbench.md) — current refocus:
    `dsp:` compiler work, layered kernels, offline render/plot/metric
    harness, and test ratchet
15. [14-ms20-machine.md](14-ms20-machine.md) — the MS-20 voice: analog
    VCOs, dual filters, MG/EGs, kernels, and the register/fusion strategy
16. [15-machine-panels.md](15-machine-panels.md) — declarative beveled
    machine panels: strips, controls, auto title bar, custom-draw hatch
17. [16-drum-machine.md](16-drum-machine.md) — the drum machine: x0x-family
    voices with modifiable character, drum kernels, slot triggering,
    vertical strip panel, drum1 decommission plan
18. [17-direction.md](17-direction.md) — **active plan**: fy `dsp:`
    language, one ctx ABI, workbench v2, machine DSL, routing, and the
    road to the warm sound
19. [18-fy-dsp-language.md](18-fy-dsp-language.md) — the `dsp:` language
    as implemented: consuming and typed locals, dotted fields, memory
    order, composition, spilling, word set
20. [19-project-format.md](19-project-format.md) — `.slab` project and
    `.preset` files, how the loader interprets them, `--render` and
    `--describe`
21. [20-machine-reference.md](20-machine-reference.md) — every machine's
    params, ranges, switch options and presets (generated)
22. [21-production-guide.md](21-production-guide.md) — writing and
    mixing a song: research, form, harmony, groove, sound choice,
    channel setup, compression, master, the stem report; `tools/slabkit`
23. [22-automation.md](22-automation.md) — track lanes, clip lanes and
    per-note expression on one curve type; automated controls, editing
    gestures, engine and format
24. [23-routing.md](23-routing.md) — groups, returns, sends, sidechain
    keys, mixer and delay compensation
25. [24-compressors.md](24-compressors.md) — dynamics design and implemented
    compressor families
26. [25-storage.md](25-storage.md) — where things live: factory, the
    home folder, project packages, references by content, collect on
    save, Save to Library, publishing; load time
27. [26-tape.md](26-tape.md) — tape2: cassette and VHS audio, the WEAR
    macro, and the shared transport kernels (wow, dropouts, hum,
    hysteresis, compand)
28. [27-bounce-export.md](27-bounce-export.md) — bounce a selection to
    a new track (taps, clip mute, thawable recipes) and export: stems
    in one pass, sections, FLAC/ALAC/AAC, dither, loudness report
29. [28-time.md](28-time.md) — how a beat becomes a sample: the tempo
    map, locators and sections, groove, polymeter and polytempo, freeze
30. [29-warp.md](29-warp.md) — audio on the beat axis: warp markers,
    TAPE/BEATS/VOICE/MIX/SMEAR stretching, transients, tempo detection
31. [30-extract.md](30-extract.md) — audio into music: hum to notes,
    chords, drums to a kit, stems, sound matching, tune
32. [31-editing.md](31-editing.md) — one way to edit across the
    arrangement, piano roll, audio editor and lanes: shared view and
    gestures, one command table, time selection, note editing,
    multi-clip editing
33. [32-accessibility.md](32-accessibility.md) — the UI as a tree:
    nodes from every control, a VoiceOver bridge, keyboard operation,
    `--ax-dump` for tests and agents
34. [33-composing.md](33-composing.md) — practical composing walkthrough
35. [34-production-wishlist.md](34-production-wishlist.md) — production
    improvements, evidence and acceptance criteria

## Terminology crib sheet

| term | meaning |
|---|---|
| **host** | the Zig program; owns transport, mixer, windowing, audio I/O |
| **machine** | a fy-authored unit: manifest + panel + dsp + params |
| **panel** | a machine's UI surface; fy words that draw and handle events |
| **kernel** | a reusable `dsp:` word: a filter, oscillator, shaper, etc. |
| **`dsp:` mode** | restricted fy compile mode: no heap allocation, NEON available, audio-thread-safe |
| **block** | N audio samples processed in one go; typically 64–256 |
| **ctx** | the context struct passed to every machine each block |
| **arena** | a preallocated memory region with bump-pointer or slab semantics |
| **voice pool** | host service that matches note-on/off to voice slots |
| **PDC** | plugin delay compensation — per-chain latency alignment |
| **params struct** | the machine's control-facing state; double-buffered |
| **hot-patch** | redefine a word at runtime via fy's trampoline indirection |
| **DSP workbench** | offline runner that renders Fy kernels/machines and emits WAVs, plots, metrics, perf reports, and disassembly |
| **test ratchet** | bounded regression system for sound, compiler quality, and performance metrics |
