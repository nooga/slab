# 33 — Composing with Slab

Build a small musical idea, listen to it, then expand it into a song.
This walkthrough uses Slab's native machines and Python `slabkit` to
make an eight-bar sketch with extended chords, an octave bass, an arp,
GEQ and a shared delay. The resulting `.slab` package opens in the normal
arrangement and piano roll for editing.

For deeper arrangement and mixing advice see
[21-production-guide.md](21-production-guide.md). For gestures and
shortcuts see [12-ux-interaction-spec.md](12-ux-interaction-spec.md);
for Python methods see [slabkit](../tools/slabkit/README.md).

## Start with a musical brief

Choose tempo, mood, length and a few distinct roles before choosing
presets. For example: 118 BPM, F-sharp minor, a restrained nocturnal
instrumental; steady kick, octave bass, changing chord colors, short arp
and occasional answering phrases. A reference can suggest pacing and
texture without supplying the notes.

Start with eight bars at the intended full-section energy. Make the
bass and drums work together before adding a lead. Decide which part is
the foreground: in an instrumental that might be the arp or a chord
rhythm. Adding more notes is only one way to increase energy; filter
movement, articulation, register and silence can do the same job.

## Discover the instruments before programming

From a source checkout on an Apple Silicon Mac with Zig 0.16:

```sh
zig build -Doptimize=ReleaseFast
PYTHONPATH=tools python3 - <<'PY'
from slabkit import machine, presets
print(machine("profit5").help())
print(machine("geq8").help())
print(presets("juno2"))
PY
```

The catalog reads the live manifests through `zig-out/bin/slab`. Rebuild
after updating the checkout so the executable and cached catalog match.
Machine IDs are directory names: `profit5`, `cream`, `juno2`, `geq8`.
[20-machine-reference.md](20-machine-reference.md) lists controls and presets.

Parameters use real units: Hz, seconds, dB or the range printed by the
machine. In slabkit, switches accept labels such as `t1="LC12"`; raw
project JSON stores option indices. An attack of `0.01` seconds is 10 ms,
while a control explicitly labeled in milliseconds takes milliseconds.
Check each instrument rather than transferring numbers blindly.

## Make an eight bar sketch

Save this as `scratch/composing_start.py` after creating `scratch/`.
Run every command below from the repository root. This example writes
only `scratch/composing_start.slab`; it does not replace an existing song.

```python
from slabkit import Song, fx

song = Song("Composing Start", bpm=118, key="F# minor", groove_seed=1984)
section = song.section("SKETCH", 8)
drums = song.track("DRUMS", "drum2", "tough-night-kit", volume=0.55)
bass = song.track("BASS", "cream", "synthwave-bass", volume=0.55,
                  params=dict(cutoff=700, a_rel=0.06))

# Each GEQ band has its own type, frequency, gain, Q and enable switch.
# All changes here are gentle starting points, to be adjusted in context.
keys = song.track("CHORDS", "juno2", "lush-pad", volume=0.30,
    params=dict(atk=0.18, rel=0.5, cutoff=1600),
    fx=[fx("geq8", "flat", t1="LC12", f1=180,
           t3="BELL", f3=450, b3=-2, q3=0.8, out=0)])
arp = song.track("ARP", "profit5", "pluck-keys", volume=0.40,
    params=dict(cutoff=1500, a_dec=0.18, a_sus=0.04, a_rel=0.07),
    fx=[fx("geq8", "flat", t1="LC12", f1=220)])
echo = song.bus("ECHO", fx=[fx("delay2", sync="SYNC", div="1/8.",
    mode="PING", fb=0.25, lowcut=400, damp=4000, mix=1)])
arp.send(echo, -14)  # dB; this is a copy, the dry arp still reaches master

# Each pair lasts two bars: F#m9, E6/9, Dmaj9, C#7sus4 then C#7b9.
# Bass roots are separate from the upper voicings.
roots = [42, 40, 38, 37]
voicings = [[57, 61, 64, 68], [56, 61, 66, 68],
            [54, 57, 61, 64], [54, 56, 59, 61]]
bc, kc, ac = bass.clip(section), keys.clip(section), arp.clip(section)
for i, (root, upper) in enumerate(zip(roots, voicings)):
    start = i * 8
    kc.chord(upper, start, 7.5 if i < 3 else 3.8, 80)
    if i == 3:
        kc.chord([53, 56, 59, 62], start + 4, 3.5, 80)
    for step in range(16):
        bc.note(root + (12 if step % 2 else 0), start + step * 0.5,
                0.32, 100 if step % 2 == 0 else 88)
    for step in range(32):
        tones = [53, 56, 59, 62] if i == 3 and step >= 16 else upper
        pitch = tones[[0, 2, 1, 3][step % 4]] + 12
        ac.note(pitch, start + step * 0.25, 0.14,
                95 if step % 8 in (0, 3, 6) else 73)

drums.clip(section).drums({"kick": "x...x...x...x...",
    "snare": "....x.......x...", "ch": "xoxoxoxoxoxoxoxo"}, bars=8)
ac.ramp("cutoff", 0, section.length, 900, 2400, tension=-0.3)
song.master(fx=[fx("limiter2", gain=0, ceil=-2)])
song.save("scratch/composing_start.slab")
```

```sh
PYTHONPATH=tools python3 scratch/composing_start.py
zig-out/bin/slab scratch/composing_start.slab
```

This is a sketch, not a mastered preset. Listen at a comfortable fixed
volume. Try shortening the bass gate, removing every second arp accent,
or dropping the pad for two bars. Change one thing per audition so you
can tell which move improved the groove.

Slab uses MIDI C4 = 60. The example's note starts are in beats relative
to each clip. A section's start is on the song timeline; don't add it to
notes inside that section's clip. Mono instruments retrigger with gaps
and play legato when notes overlap. Long releases and host unison consume
voices: allow enough polyphony for the chord and its overlapping tail.

## Choose and use EQ

| Tool | Use it for |
|---|---|
| `eq2` | A compact high-pass, low/high shelves and two bells for broad shaping |
| `geq8` | Eight flexible bands, selectable slopes, notches, adaptive Q, output spectrum and output trim |

GEQ is already a native effect. Its band types are `LC48`, `LC12`,
`LSHLF`, `BELL`, `NOTCH`, `HSHLF`, `HC12`, `HC48`. Each band can be
switched off with `on1="OFF"` through `on8="OFF"`. `adapt="ON"`
narrows bell Q as the boost or cut increases. `out` is −12..+12 dB.
The `flat` preset leaves all eight bands enabled but with a flat response;
our sketch turns the first band into a low cut and shapes one bell.

Use the spectrum to locate energy, then listen to decide whether it is
a problem. First try a fader, octave or shorter envelope when two parts
mask each other. If a cut helps, compare at similar loudness using GEQ's
output trim. A steeper cut removes more energy near its cutoff; it is
not automatically clearer. Avoid high-passing every part to a recipe.

For gain changes beyond the fader's range, inspect the instrument's
output control and GEQ trim before adding another processor. Some
instrument level controls affect drive, so check the signal path.
Ratio-1 compression with makeup gain is another option when more gain
is needed, but it should be a deliberate gain stage.

## Build an arrangement from the sketch

Make sections with different jobs: introduce the rhythm, establish the
full groove, open the harmony, remove the drums, rebuild, then return
with one meaningful change. As a starting form, try 8 + 16 + 16 + 8 +
8 + 16 + 8 bars. At constant 118 BPM in 4/4, those 80 bars last about
2:43 before the tail. Count phrase lengths and leave room for transitions.

Use `clip.copy(next_section)` for a variation, then edit its notes or
velocity. `clip.ramp()` moves with the copied clip; `track.ramp()` uses
song beats and suits long transitions across sections. A clip lane
overrides a track lane for the same target while playing. Per-note
`clip.bend()` takes offsets from each note's start. See
[22-automation.md](22-automation.md) for precedence and expression.

Keep a few common chord tones and move other voices by small steps.
Extended chords can live above a simple root bass. Let short arps and
long pads occupy different registers or different moments. Sparse calls
and responses often leave more character than a continuous lead line.

There are **32 tracks including buses**, with **64 note clips and 2,048
notes per track**. Eight bars of straight sixteenth notes use 128 notes;
128 bars use the whole 2,048-note budget before any extra layer. More
clips on that same track do not raise the note limit. Split long parts
across tracks or thin the writing before reaching it.

## Route depth and movement

`track.output = bus` routes the main signal through a group;
`track.send(bus, -12)` adds a parallel copy. Set a shared reverb or delay
to fully wet. Filter its return so low end and bright repeats do not
obscure the dry parts. An insert at a lower wet mix is useful when only
one sound needs the effect. Routing cycles are refused.

For kick-driven ducking, put `fx("comp2", key=kick, thresh=-24,
ratio=3, atk=0.003, rel=0.12)` on the bass or pad, where `kick` is a
separate track in the song. Adjust threshold to the actual key level.
For a gated snare return, use `verb2` in GATED mode on a bus with
`key=snare`: sending toms into it does not make them open the snare's
gate. [23-routing.md](23-routing.md) explains taps and solo behavior.

Shape sounds before widening everything. Keep the bass foundation
stable in mono; try modest unison or chorus on upper parts. Add
saturation with output compensation so louder is not mistaken for
better. Listen both in context and briefly soloed for unwanted noise,
clicks, harsh resonance or tails obscuring the next phrase.

## Render and listen

For a persistent mix and stems from the same pass:

```sh
zig-out/bin/slab scratch/composing_start.slab \
  --render scratch/composing_start.wav \
  --stems scratch/composing_start-stems \
  --stem-kind tracks --tap fader --tail 4 --bits 24
```

`--stem-kind tracks` selects audio tracks; `buses` selects buses; `all`
includes both. At the fader tap, audio track stems include their inserts,
volume and pan, but not downstream group/master processing or separate
return buses. With `all`, don't sum a group bus and its member stems as
if they were independent: you would double-count those members.

`Song.render(stems=True)` is convenient for a mix report but currently
renders the mix and temporary stems in separate passes and deletes the
stems afterward. Use the CLI above when delivering files. Export options,
including ranges and tails, are in [27-bounce-export.md](27-bounce-export.md).

Check the beginning, a dense section, a transition and the ending.
Listen quietly, in mono and on another playback system. Compare exports
at similar loudness. LUFS, crest factor, spectrum and correlation help
find problems; they cannot certify musicality or sound quality. An
assistant that cannot audition should report that limitation.

`limiter2` limits sample peaks. Its ceiling is not a guaranteed true-peak
ceiling. Measure the exported WAV, leave enough headroom for its actual
inter-sample peaks, and check encoded deliveries separately. A lower
ceiling is preferable to assuming that a clean sample meter proves there
are no reconstructed overs. Set loudness for the music, not a universal
LUFS target.

## Keep the project editable

Keep the script, project package, custom presets and exports together.
Regenerating with `Song.save()` rewrites `project.json`; save UI edits to
a separate project before running the generator again. Transfer those
changes into the script if you want it to remain authoritative.

A generated package can still reference external samples. Use the app's
collect-on-save workflow and check the package on reopening before
sharing it; Python `save()` is not an asset collector. Storage roots and
project-relative files are described in [25-storage.md](25-storage.md).

You can also start from audio in the current beta: record or import a
phrase, then use an audio clip's **Extract** menu for notes, chords or a
drum kit, and correct the result by ear. Stem separation and Explode's
separation step require the Extract pack; the note/chord/drum analyzers
are native. See [30-extract.md](30-extract.md) for their scope and limits.
