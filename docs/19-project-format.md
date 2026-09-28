# 19 — Project and preset format

How a `.slab` project and a `.preset` file are laid out, and how the host
interprets each field when it loads them. Code: `src/document.zig`
(project save/load, also the undo snapshot format), `src/presets.zig`,
`src/describe.zig`. Every machine's params: [20-machine-reference.md](20-machine-reference.md).
How to write music with it: [21-production-guide.md](21-production-guide.md)
and `tools/slabkit`.

## Command line

| Command | Does |
|---|---|
| `slab song.slab` | open a project |
| `slab song.slab --render out.wav` | bounce headless (no window, no device) to 24-bit stereo 48 kHz WAV and print peak/RMS. Renders from beat 0 to the last clip's end plus a 3 s tail. |
| `slab --describe out.json` | dump every builtin machine's params, switch options and drum note labels from the live manifests |

The render runs the same engine as playback, including the master
soft-clip, so what it writes is what you'd hear.

## Preset

`machines/<id>/presets/<name>.preset`, or `presets/<bank>/<name>.preset`
for a bank (the panel shows banks as submenus):

```json
{"schema": 1, "machine": "juno2", "note": "Bittersweet minor loop pad",
 "params": {"jn-cutoff": 950, "jn-res": 0.1, "jn-pwmod": 1}}
```

- `params` maps param id → value. Values are **real units** (Hz,
  seconds, dB, semitones, a 0–1 level), never 0–1 knob positions, so
  retuning a knob's range doesn't move saved sounds.
- Switches store the **option index** (0-based), not the option's
  value. `jn-pwmod: 1` is `LFO` in `MAN/LFO/ENV`.
- Values are clamped into the param's range on apply. Unknown ids are
  ignored. Params the preset leaves out keep their current value, which
  is the manifest default on a fresh instance.
- `machine` and `note` are metadata; the loader ignores them.

A track's `instrument.params` and an effect's `params` in a project use
exactly the same map.

A **Rack** preset (`machines/rack/presets/`) holds parts instead of
params, each part a machine with its settings in that machine's own
form:

```json
{"schema": 1, "machine": "rack", "note": "CMI tour / gabriel2 / FISHINET",
 "parts": [{"machine": "unfairlight", "name": "VOC1", "lo": 0, "hi": 40,
            "vlo": 1, "vhi": 127, "transpose": 12, "level": 0, "pan": 0,
            "poly": 2, "mute": false,
            "params": {"cmi-filter": 144, "cmi-atk": 0.47},
            "assets": {"voice": "lib:cmi/tour/gabriel2/VOC1.vc"},
            "zones": {}}]}
```

- A note goes to every part whose key range (`lo`–`hi`) and velocity
  range (`vlo`–`vhi`, 1–127) hold it, `transpose` semitones away, so
  splits and layers are ranges that don't or do overlap.
- `poly` caps a part's notes at once (0 = the machine's own voices): at
  the cap its oldest note is released first.
- `level` is dB (−60..+12), `pan` −1..1 (a balance).
- `params`, `assets` and `zones` are what the part's machine would take
  as a track's instrument. Parts naming an unknown machine are dropped;
  racks don't nest.

## Project

JSON. Top level:

```json
{
  "schema": 1,
  "transport": {"bpm": 106.0, "loop": {"on": false, "start": 0.0, "end": 296.0}},
  "meter": [{"bar": 0, "num": 4, "den": 4}],
  "tracks": [ … ],
  "master": {"volume": 1.0, "pan": 0.0, "effects": [ … ]}
}
```

| Field | Meaning |
|---|---|
| `transport.bpm` | tempo; one tempo per song (no tempo map yet) |
| `transport.loop` | loop region in **beats**; `on` sets whether playback loops. The render ignores it. |
| `meter` | meter map: `{bar, num, den}` points. The first point is forced to bar 0. Missing = 4/4. It changes the bar grid and what machines get as `bar`/`beat_in_bar`; note times are always in beats. |
| `tracks` | at most 16 |
| `master` | the master bus: `volume` (linear gain, default 1.0), `pan` (a balance control, not a pan law), `effects` |

### Track

```json
{
  "name": "BASS", "color": [64, 206, 174],
  "volume": 0.66, "pan": 0.0, "mute": false, "solo": false,
  "instrument": {"machine": "cream", "params": {"cr-cutoff": 900}},
  "effects": [{"machine": "comp2", "params": {"comp-thresh": -14}, "preset": "drum-bus", "bypass": false}],
  "clips": [ … ]
}
```

| Field | Meaning |
|---|---|
| `volume` | linear gain after the insert chain, 0 to 1.25 (default 0.8). 0.5 ≈ −6 dB. |
| `pan` | −1 to 1, equal-power: centre is −3 dB per side, hard left/right is unity on one side |
| `mute` / `solo` | any soloed track mutes all unsoloed ones |
| `instrument.machine` | machine **id**: the folder name under `machines/` (`juno2`, not "Ju-Know"). Display names change; ids don't. |
| `instrument.assets` | files the machine has loaded, by asset name. Only the sampler has one: `{"smp": "path"}`, where the path is a `.wav`, an `.sfz` or a folder of WAVs (relative to the working directory, or absolute). A path under the sample library is written `lib:<path>`, relative to `$SLAB_LIBRARY` (default `~/Music/Slab/Library`), so projects and shipped presets find library samples on any machine. Missing: the machine keeps its bundled sample. |
| `instrument.zones` | the sampler's per-zone edits, by zone name (the sample's file stem): `{"clap": {"level": -6, "tune": 0, "decay": 0, "tone": 0, "cut": 0}}`. level in dB, tune in semitones, decay in seconds to −60 dB (0 = off), tone in octaves of filter offset, cut the choke: 0 the pack's (`group`/`off_by`), 1 none, n+1 choke group n (the zone joins it and is cut by it). Zones sharing a name (an SFZ label, a sample's layers and round robins) take the same edits. Only edited zones are written; names that don't match the loaded keymap are ignored. `"reverse": true` plays the sound backwards (a reversed copy of its samples, loop mirrored). A **copy** is a sound of its own, `"snare 2": {"copy": "snare", "key": 39, …}`: every zone of the named one-key sound on `key`, pitched as the original, with its own edits (sampler and Unfairlight kits). |
| `instrument.preset` / effect `preset` | the preset the settings started from, by its full name (`rom1a/dx-bass`), for the panel's label. `params` stay authoritative: loading marks the preset current without applying it. Missing or unknown = no label ("init"). |
| `instrument.state` | settings a machine keeps beyond flat params: a Rack's `{"parts": […]}`, the same form as its presets. |
| `effects` | insert chain, run in order, stereo. `bypass: true` passes audio through untouched. `key` (an index into `tracks`) sidechains the effect's detector from that track's pre-fader signal ([23-routing.md](23-routing.md)). |
| `kind` | `"bus"` for a bus (a group or a return: no instrument, no clips; its input is what's routed to it). Missing = an audio track. |
| `folded` | On a bus: `true` hides a group's members in the arrangement and mixer. UI state only; missing = unfolded. |
| `output` | index into `tracks` of the bus the post-fader signal goes to. Missing = the master. |
| `sends` | `[{"to": 10, "level": 0.5, "pre": false}]`: copies into buses, `level` linear gain 0–2 (1 = 0 dB), `pre` true taps before the fader. |
| `automation` | track automation lanes, see below. Optional. |
| `show_automation` | `true` shows the lanes under the track in the arrangement. |

Signal flow per track: instrument (a bus: its routed input) → audio
clips summed in → effects in order → volume → pan → its output (the
master or a bus) and its sends → master effects → master volume and
balance → **master soft-clip** → output. Routing that isn't a bus, is
duplicated or closes a loop is dropped on load with a warning
([23-routing.md](23-routing.md) §Semantics).

The master soft-clip is linear up to ±0.7 (−3.1 dBFS) and bends
smoothly toward ±1.0 above that (`src/engine.zig`, `masterSoftClip`).
Nothing clips hard, but anything peaking above −3.1 dBFS is being
saturated. A limiter on the master with its ceiling at −3.2 dB keeps
the output clean.

### Automation

A track's `automation` is a list of lanes ([22-automation.md](22-automation.md)):

```json
"automation": [
  {"target": "inst:jn-cutoff", "points": [[0, 200, "curve", -0.5], [16, 6000], [24, 800]]},
  {"target": "volume", "points": [[24, 0.7], [32, 0.0]]},
  {"target": "fx0:delay-mix", "points": [[0, 0, "hold"], [16, 0.5]]}
]
```

- `target`: `volume` (linear gain, 0–1.25), `pan` (−1..1),
  `inst:<param id>`, or `fx<N>:<param id>` with `N` the effect's
  0-based position in `effects`.
- A point is `[beat, value]` or `[beat, value, shape, tension]`. Beats
  are song beats. Values are real units like `params` (switches: the
  option index). `shape` is `linear` (default), `curve` or `hold`, and
  shapes the segment to the next point; `tension` (−1..1, default 0)
  bends a `curve`, + = most of the change early.
- Points at the same beat make an instant jump. Before the first point
  the lane holds the first value, after the last the last.
- Interpolation runs in knob space, so a `linear` segment on an
  exponential knob sweeps evenly in pitch, as a drag does.
- Switch and integer lanes step (`hold`) whatever shape is written.
- One lane per target; a later duplicate, an unknown target or param id,
  and an `fx` index past the chain are dropped. Values are clamped.

### Clips

A **note clip**:

```json
{"type": "note", "name": "chorus", "start": 96.0, "len": 32.0,
 "notes": [{"pitch": 38, "start": 0.0, "len": 0.375, "vel": 112}]}
```

- `start` and `len` are in beats on the song timeline.
- Note `start` is in beats **from the clip's start**, not the song's.
  A note plays at `clip.start + note.start`. Only notes inside
  `[0, len)` play.
- `pitch` is MIDI (C4 = 60) and `vel` is 1–127.
- `expr` (optional): per-note expression, one point list per
  dimension, at most 8 points each, beats from the note's start, point
  shapes as in automation. After the note ends each holds its last
  value.
  - `pitch`: semitones from `pitch` (±48): `{"pitch": [[0, 0], [1, 0],
    [3.5, -7, "curve", -0.4]]}`. Every pitched machine plays it.
  - `gain`: dB (−48..+12, rest 0); the sampler and Unfairlight play it.
  - `pressure`, `slide`: 0..1 (rest 0.5 and 0); carried to machines,
    none uses them yet.
- `automation` (optional): clip lanes, the same form as a track's but
  with beats from the clip's start. While the clip plays they override
  the track's lane for the same target; where clips overlap, the one
  that starts later wins. Points past the clip's end are kept but
  don't play.
- At most 64 clips and 2048 notes per track.
- Clips on one track may overlap, and both play.

An **audio clip**:

```json
{"type": "audio", "name": "vox", "start": 16.0, "len": 8.0, "source": "recordings/take1.wav",
 "gain": 1.0, "start_sec": 0.0, "dur_sec": 7.5, "fade_in": 0.01, "fade_out": 0.2}
```

`source` is a WAV path (relative to the working directory, or
absolute). `start_sec` is where in the file playback begins, `dur_sec`
is how much plays, and the fades are in seconds. `"reversed": true`
plays that window from its end back to its start; the fades and the
gain stay in clip time (a fade-in still fades the clip's first
moments). A missing file keeps the clip, which then plays silent.

## How the machines interpret notes

- **Poly machines** (`voices` > 1 in the dump: juno2, fm86, rhodes,
  sampler) take the oldest released voice for a new note, and steal the
  oldest held one when all voices are busy.
- **Mono machines** (ms20, cream) play one note. A note that starts
  while another is held is **legato**: it moves the pitch (gliding if
  the glide/portamento param is up) without retriggering the envelopes.
  Releasing it falls back to the newest still-held note. To retrigger,
  leave a gap. To slide, overlap the notes slightly. Chords on a mono
  machine play one note.
- **Drum machines** (`note_pitch` in the dump; drum2) map pitch to a
  voice. drum2 uses the pitch class, so any octave works: C kick,
  D snare, D# clap, F# closed hat, A tom, A# open hat (canonically
  36, 38, 39, 42, 45, 46). The open and closed hats share a voice, so
  one chokes the other. Velocity feeds the kit's ACCENT param.
- The **sampler** plays its keymap, `instrument.assets.smp`, or the
  bundled pluck without one. The keymap comes from one of three sources:
  - **a WAV:** one zone over the whole keyboard. Its root and loop come
    from the file's `smpl` chunk; without one, ROOT (`smp-root`, a MIDI
    note) sets the root.
  - **an SFZ file:** regions with `sample`, `key`/`lokey`/`hikey`,
    `pitch_keycenter`, `lovel`/`hivel`, `tune`, `transpose`, `volume`,
    `pan`, `loop_mode`, `loop_start`/`loop_end`, `group`/`off_by`,
    `seq_length`/`seq_position` (round robin, counted per key),
    `region_label`/`group_label` (the zone's name) and `<control>
    default_path`. `trigger=release` regions play at note-off, in the
    same voice as the note, from a second playhead beside the body's
    release: same key, velocity and round robin, pitched with the note,
    `rt_decay` dB quieter per second held, unfiltered. Other triggers
    and generators are skipped.
  - **a Fairlight `.VC` voice:** its 16,384-byte 8-bit RAM (at 0x1500)
    and its segment loop, as one zone of rate 0: the Unfairlight plays
    it at RATE, the sampler as 24 kHz. Its Page 7 (NAME.CO) isn't read
    here: tools/library/cmi.py folds it into the voice's preset.
  - **a folder:** if the file names contain notes (`Piano_C4.wav`,
    `A#3`, C4 = 60), each sample covers the keys half way to its
    neighbours, and several files at one root split the velocity range.
    If none do, the folder is a drum kit: one one-shot per key, placed
    by General MIDI keywords (kick 36, snare 38, clap 39, closed hat 42,
    open hat 46, …) and then on free keys from 36. The hats share a
    choke group.

  Up to 256 zones. Stereo files are folded to mono. One-shot zones
  ignore note-off. A kit's keys are named after its zones in the piano
  roll; a preset that carries `assets` can carry `zones` too.

## Where loading fails silently

The loader is lenient on purpose (a livecoded machine that fails to
compile must not take the project down), so mistakes don't raise
errors:

| Mistake | Result |
|---|---|
| unknown machine id | the track loads with a silent instrument; an unknown effect is dropped |
| misspelled param id | ignored |
| value out of range | clamped |
| switch given its option *value* instead of its index | clamped to an index, so the wrong option plays |
| note outside the clip | never plays |
| more than 16 tracks | the load fails |

`tools/slabkit` checks all of these against `slab --describe` before
writing a file.

## Not in the format yet

Tempo changes, sends and returns, sidechain, and the meter
map's accent groups.
