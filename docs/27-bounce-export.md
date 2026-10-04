# 27 — Bounce and export

Two ways audio leaves the live graph:

- **Bounce** turns a selection of clips into an audio clip on a new
  track, inside the project.
- **Export** writes the project, or part of it, to files outside it:
  a mix, stems, sections, in WAV, AIFF, FLAC, ALAC or AAC.

Both run the offline renderer `Render Audio` uses today
(`Engine.renderOffline`), so what they write is what playback sounds
like, bit-exact at any `--threads` (docs/07 §Parallel rendering).
**Status:** 2026-10-04, branch `feat/bounce-export`. Built: clip mute,
stereo audio clips, the engine's capture, Bounce selection. The rest is
design: Render Audio still renders a project or loop range with a tail to
24-bit stereo WAV, and stems exist only in slabkit, which re-renders the
project once per soloed track.

## Bounce selection

Select clips (on one track or many, note or audio clips) and choose
**Bounce** (arrangement right-click menu, `cmd+B`). A small dialog
asks three things, then renders with the same progress bar as Render
Audio.

### Range

From the earliest selected clip's start to the latest one's end, plus
a tail. The tail is **AUTO** by default: the render keeps going until
the output stays below −90 dBFS for 0.5 s, up to 30 s. A fixed tail in
seconds is the alternative. The new clip starts at the range's start,
and its length is whatever was rendered, so a reverb's decay is part
of the clip.

### What plays

Only the selected clips. Every other clip, on any track, is silent
for the render, including other clips on the selected tracks, so an
earlier clip's reverb tail can't leak in. Track automation and the
selected clips' own lanes play as usual. Machines are reset and
chased at the range's start, as Render Audio does now.

The engine gets a **render mask**: a per-clip bit the offline pass
consults instead of the clip list's normal triggering. Live playback
never sets it.

### Tap

Where the signal is taken, per source track:

| Tap | Where | Engine tap |
|---|---|---|
| **INSTR** | the instrument or audio clips, no inserts | `input` |
| **FX** (default) | after the inserts, before volume and pan | `pre` |
| **FADER** | after volume, pan and their automation | `post` |
| **+SENDS** | FADER plus what the track's sends return: the buses its sends reach, rendered with only this track feeding them | `post` + bus outputs |

This replaces a "dry/wet" control. Dry and wet are tap points, and
the tap also says whether the fader and the space are printed.
**+SENDS** is the one that "prints the reverb". Its bus outputs are
taken after the bus's inserts and fader, so a reverb return and a
drum group both come out as heard. The master chain is never included
in a bounce, because a bounce is going back into the mix that the
master processes.

### Together or each

With clips on more than one track:

- **TOGETHER**: one clip on one new track, the sum of the taps.
- **EACH**: one new track per source track, each clip at the range's
  start so they stay aligned.

### The new track and the originals

The new track is an audio track inserted below the lowest source
track, named `<source> bounce` (`Bounce N` when TOGETHER spans several
tracks), in its first source's color. Its output is where its sources'
outputs go when they all agree (a group stays a group), else the
master. When the tap printed the fader (FADER, +SENDS), its fader is at
0 dB and its pan at center. When it didn't (INSTR, FX) and the clip has
one source, it stands in for that source: it copies its fader, pan and
sends, so the bounce sits in the mix where the source did. Volume and
pan automation isn't copied; FADER prints it.

The file is a 32-bit float stereo WAV, so a bounce that peaks above
0 dBFS before the master isn't clipped. It goes to the package's
`audio/` as `<source>-bounce.wav` (`bounce.wav` for several sources;
`-2`, `-3`… when taken), or to `Cache/recordings/` while the project is
unsaved, as takes do (docs/25 §The project package). Audio clips play
stereo sources in stereo (`wav.loadStereo`; imports used to fold to
mono).

The originals are **muted**: they stay where they were, drawn dimmed,
and don't play, so the song doesn't play the part twice (the bounce and
its source on top of each other). Unmute them to compare, or delete
them once you're happy with the bounce. The whole bounce is one undo
step. The dialog also offers **KEEP** (the originals stay audible, for
a layer you want doubled) and **DELETE**.

**Clip mute**: a `muted` flag on `Clip`, persisted as `"muted": true`,
skipped by the engine (`Track.publishSnapshot`) and drawn without its
track color. `0` or the clip menu toggles it on the selection. It's
useful on its own, for trying a part with and without a clip.

### How it renders

`Engine.capture` (`Capture` in src/engine.zig): before `renderOffline`, the
caller names a tap per track and gives each its buffers. Each node
copies its tap as it renders (its own buffers only, so the parallel
render is untouched) and notes where its signal last rose above
−90 dBFS. `sources` makes the render hear only those tracks: every
other track is muted (still rendering when it keys something, so a
bass ducked by the kick still pumps), buses keep their own mute, solos
are ignored. The source tracks publish only their selected clips while
it runs (`Track.play_selected`). With a hold, the render stops once
every tap has been quiet that long past the range; each tap is read
from its own latency on, so PDC lines the parts up.

EACH with +SENDS takes one pass per source, since a return must hear
one source at a time; everything else is one pass.

### Provenance: a bounce you can thaw

A bounced clip keeps a **recipe**:

```json
{"type": "audio", "name": "pad bounce", "source": "audio/bounce-003.wav", "...": "...",
 "recipe": {"clips": [[4, 2], [4, 3]], "tap": "fx", "mode": "together", "tail": "auto",
            "hash": "9f2c41e0b7a3d815"}}
```

`clips` are `[track, clip]` pairs naming the muted originals (rewritten
when tracks or clips are reordered, dropped when an original is
deleted). `hash` covers everything the render depended on: the
originals' notes, audio and lanes, each source track's machine source
text (after includes), params, inserts and their params, automation in
the range, the tempo map over it, the sends' buses for +SENDS, and the
Slab version.

Slab renders deterministically, so a recipe whose hash still matches
would reproduce the clip exactly. When it doesn't match, because a
kernel was edited, a knob moved, or a note changed, the clip shows a
**stale** corner and its menu offers:

- **Re-bounce**: render the recipe again into the same clip.
- **Thaw**: unmute the originals and delete the bounce, back to where
  you started.

DAWs treat a bounce as a fork. Here it's a cache of a render you can
always redo, which is what makes bouncing safe in a livecoding DAW,
where the source keeps changing under it. The hash is computed when
the project is saved and on edits to the tracks involved, on the main
thread, never on the audio thread.

## Export

**File > Export…** (`cmd+shift+E`) replaces Render Audio. It's one
dialog with the options below. The last settings are kept per project.

### What

- **MIX**: the master, as Render Audio writes it now.
- **STEMS**: one file per track, with a choice of **TRACKS**, **BUSES**
  or both, and of tap: FX, FADER (default), or FADER through the
  master chain ("MASTER FX"), for a mastering engineer or a remix pack
  that should sound like the record. Muted tracks are skipped. A track
  that only feeds a bus still gets its own stem.
- **MIX + STEMS** writes both from the same pass.

Stems come from **one render pass**. The engine already computes every
track's taps each block, so the offline pass copies the requested taps
out alongside the master instead of re-rendering per track. Exporting
24 stems costs about one mix render plus the writes, not 24 renders.
slabkit's stem report moves onto this path.

### Range

PROJECT (beat 0 to the last clip's end), LOOP, SELECTION (as in
Bounce, without the mask: everything plays), or **SECTIONS**: one file
per stretch between consecutive locator markers (docs/07 §Markers),
named after the marker. A tail (AUTO or seconds) applies to each file.

**LOOP-WRAP**, for LOOP and SECTIONS: the tail is rendered, then added
back onto the start of the file, and the file is cut to the range's
exact length. Played in a loop it continues seamlessly, with a reverb
carrying over into bar 1. That's what a sample pack loop or a game
music loop needs, and DAWs leave it to manual editing.

### Format

| Format | Bits | Notes |
|---|---|---|
| WAV | 16, 24, 32f | default 24 |
| AIFF | 16, 24, 32f | |
| FLAC | 16, 24 | our encoder, below; level 0–8, default 5 |
| ALAC | 16, 24 | AudioToolbox (`ExtAudioFile`), in `.m4a` |
| AAC | 128–320 kb/s | AudioToolbox, in `.m4a`; default 256 |

MP3 isn't planned: AAC covers lossy delivery and MP3 encoding would
mean vendoring LAME.

**Sample rate**: 44.1, 48 (default), 88.2, 96 kHz. The engine runs at
48 kHz (`audio.SAMPLE_RATE`), so other rates are produced by an
offline, high-quality resampler (polyphase windowed sinc, ≥ 120 dB
stopband) on the rendered buffer. Rendering natively at the target rate
would need every machine to be rate-independent, which isn't verified.
If it is one day, 96 kHz exports become free oversampling, but the
resampler doesn't wait on that.

**Dither**: TPDF at ±1 LSB, on by default whenever the output is
16-bit, off for 24-bit and float. One seed per export, so exports stay
reproducible.

**Channels**: STEREO, or MONO (L+R at −3 dB) for a mono stem.

### Normalize and the loudness report

**NORMALIZE**: OFF (default), PEAK (to a dBFS ceiling), or LOUDNESS
(to an integrated LUFS target, −14 by default, with a true-peak ceiling
of −1 dBTP). LOUDNESS applies one gain to the whole file. If the
ceiling would be exceeded, the gain is lowered instead of limiting.
The master chain is where limiting belongs. Stems take the mix's gain,
so their balance is preserved.

The meter is ITU-R BS.1770-4 in Zig (`src/loudness.zig`): K-weighting,
400 ms gated blocks, LRA from 3 s blocks, true peak from 4×
oversampling. slabkit's Python version (`tools/slabkit/analyze.py`) is
the reference it's tested against.

After every export, the dialog shows a **report card**: integrated
LUFS, LRA, true peak and the gain applied for the mix, and for stems
each one's integrated loudness relative to the loudest. That's the
stem report from docs/21 §Mixing by numbers, now in the app.

### Names and metadata

Files are named by a template, default `{project}` for the mix and
`{project}-{nn}-{track}` for stems (`{section}` for SECTIONS). They
go into a folder picked once. A name that already exists asks before
overwriting, once for the whole export.

WAV and AIFF get the project's locator markers as cue points, and the
tempo and meter in an `acid` chunk when the tempo is constant. FLAC
and M4A get title, artist and BPM tags. Every format gets a `slab`
comment with the version and a hash of the project, so a file can be
traced back to the exact render.

### Command line

`--render` grows the same options, so slabkit and scripts get them:

```
slab song.slab --render out.flac --bits 24 --rate 44100
slab song.slab --render stems/ --stems tracks --tap fader
slab song.slab --render loops/ --sections --loop-wrap
slab song.slab --render out.wav --normalize -14
```

The format comes from the extension. A directory means one file per
stem or section. The report card is printed as today's peak/RMS line
is. slabkit's `render(stems=True)` calls `--stems` once instead of
writing a project per track.

## FLAC encoder

`src/flac.zig`: an encoder of our own, no libFLAC. It covers the subset
a renderer needs:

- Fixed blocksize, 4096 frames; 16 or 24 bits; 1 or 2 channels; any
  of the export rates.
- **Stereo decorrelation**: try independent, left/side, right/side and
  mid/side per frame, and keep the smallest.
- **Subframes**: CONSTANT (silence costs a few bytes), VERBATIM as the
  fallback, FIXED orders 0–4, and LPC orders up to 12 (levels 6–8 up
  to 32 coefficients), with Levinson-Durbin on a windowed
  autocorrelation and quantized coefficients at 15-bit precision.
- **Residual**: partitioned Rice coding, partition order chosen per
  subframe, Rice parameter per partition.
- STREAMINFO with the MD5 of the unencoded audio, frame and subframe
  CRC-8/CRC-16, a VORBIS_COMMENT block for the tags, a SEEKTABLE.

The level picks how hard to search (LPC on or off, max order, partition
orders tried), the same idea as `flac -0..-8`. Encoding runs on the
render pool's workers, a frame per job, since frames are independent.

It's verified against miniaudio's FLAC decoder, which Slab already
links: every test file round-trips bit-exact, and sizes are compared
to `flac -5` on the same input (target: within 3 %). Inputs: silence,
full-scale noise, a sine sweep, a rendered song, a 24-bit file with
a DC offset.

## Phasing

1. **Clip mute** (built).
2. **Bounce selection** (built).
3. **Export dialog and one-pass stems**: MIX/STEMS, ranges incl.
   SECTIONS, WAV/AIFF at 16/24/32f, dither, naming. `--render` options.
   slabkit moves to `--stems`.
4. **FLAC encoder**, then ALAC and AAC through AudioToolbox.
5. **Loudness**: `loudness.zig`, NORMALIZE, the report card.
6. **Resampler** for 44.1/88.2/96 kHz.
7. **Provenance**: recipe, hash, stale, Re-bounce, Thaw.
8. **LOOP-WRAP** and metadata (cue points, `acid`, tags).

Later, not designed here:

- **Variations**: bounce a selection N times with different seeds for
  the machines that use randomness, into N clips or a sampler's round
  robin.
- **Bounce to sampler**: the selection becomes a sampler instrument,
  sliced at its notes or as one chromatic sample.
- **Freeze**: a whole track rendered to replace its instrument and
  inserts for CPU, built on the same recipe and render mask.
- **Resample input**: record the master or another track live, as a
  track's input (docs/07 §Recording, Deferred).
- **Recipes without the audio**: since a fresh recipe reproduces its
  clip exactly, a shared package could leave bounce files out and
  re-render on open. That only works if the recipient has the same
  machines and Slab version, so it waits until packages carry that.
