# 27 — Bounce and export

Two ways audio leaves the live graph:

- **Bounce** turns a selection of clips into an audio clip on a new
  track, inside the project.
- **Export** writes the project, or part of it, to files outside it:
  a mix, stems, sections, in WAV, AIFF, FLAC, ALAC or AAC.

Both run the offline renderer (`Engine.renderOffline`), so what they
write is what playback sounds like, bit-exact at any `--threads`
(docs/07 §Parallel rendering).

**Status:** 2026-10-04, branch `feat/bounce-export`. Built: clip mute,
stereo audio clips, the engine's capture and ring-out stop, Bounce
selection, Export (mix and one-pass stems, project/loop/selection, WAV
and AIFF at 16/24/32f with dither, FLAC, the command line). Each section
below says what of it is still design.

## Bounce selection

Select clips (on one track or many, note or audio clips) and choose
**Bounce** (arrangement right-click menu, `cmd+B`). A small dialog
asks three things, then renders with the same progress bar as Render
Audio.

### Range

From the earliest selected clip's start to the latest one's end, plus
a tail. The tail is **AUTO** by default: the render keeps going until
the output stays below −80 dBFS for 0.5 s, up to 30 s. A fixed tail in
seconds is the alternative. The new clip starts at the range's start,
and its length is whatever was rendered, so a reverb's decay is part
of the clip.

### What plays

Only the selected clips. Every other clip, on any track, is silent
for the render, including other clips on the selected tracks, so an
earlier clip's reverb tail can't leak in. Track automation and the
selected clips' own lanes play as usual. Machines are reset and
chased at the range's start, as an export does.

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
−80 dBFS. `sources` makes the render hear only those tracks: every
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

**File > Export Audio…** (`cmd+R`) replaced Render Audio. One dialog
with the options below, then a save panel that names the mix; the last
settings are kept for the session.

### What

- **MIX**: the master, as Render Audio wrote it.
- **STEMS**: one file per **TRACKS** (tracks that play: audible, with a
  clip that isn't muted), **BUSES** (audible buses) or **ALL**, at the
  **FX** tap (after the inserts) or **FADER** (default, after volume and
  pan). A track's stem is its own signal: before its group bus, its
  sends' returns and the master chain. A return or group is a stem of
  its own with BUSES.
- **BOTH** writes the mix and the stems from the same pass.

Stems come from **one render pass**: the engine's capture (§How it
renders) copies each stem's tap while the mix renders, so 24 stems
cost about one mix render plus the writes. `src/exporter.zig` does a
whole export and is shared by the dialog's worker thread and the
command line. Every file of an export has the same length, so they
line up from zero in any DAW; each stem is read from its own latency
on (PDC).

They go in a folder beside the mix, `<name> stems/`, named
`<name>-<nn>-<track>` where `<name>` is the save panel's.

Not built yet: stems through the master chain (MASTER FX), which needs
a render per stem.

### Range

PROJECT (beat 0 to the last playing clip's end), LOOP or SELECTION
(the selected clips' span; everything plays). The transport **stops**
at the range's end (`Engine.offline_stop`): no note starts past it and
audio clips fall silent there, the notes sounding are released, and the
tail is what rings out. AUTO stops once the master and every stem have
stayed below −80 dBFS for 0.5 s, up to 30 s; a fixed tail renders
exactly that long.

**SECTIONS** (one file per stretch between locator markers) waits for
locator markers (docs/07 §Markers), which aren't built.

**LOOP-WRAP**, for LOOP and SECTIONS (not built): the tail is rendered,
then added back onto the start of the file, and the file is cut to the
range's exact length. Played in a loop it continues seamlessly, with a
reverb carrying over into bar 1. That's what a sample pack loop or a
game music loop needs, and DAWs leave it to manual editing.

### Format

Built:

| Format | Bits |
|---|---|
| WAV | 16, 24 (default), 32f |
| AIFF | 16, 24, 32f (AIFF-C `fl32`) |
| FLAC | 16, 24 (level 5) |

`src/export.zig`. PCM is clamped to full scale, float written as is.
**Dither**: TPDF at ±1 LSB for 16-bit, on by default, seeded so an
export is reproducible; off for 24-bit and float.

Planned:

| Format | Bits | Notes |
|---|---|---|
| ALAC | 16, 24 | AudioToolbox (`ExtAudioFile`), in `.m4a` |
| AAC | 128–320 kb/s | AudioToolbox, in `.m4a`; default 256 |

MP3 isn't planned: AAC covers lossy delivery and MP3 encoding would
mean vendoring LAME.

**Sample rate** (planned): 44.1, 48 (default), 88.2, 96 kHz. The engine
runs at 48 kHz (`audio.SAMPLE_RATE`), so other rates are produced by an
offline, high-quality resampler (polyphase windowed sinc, ≥ 120 dB
stopband) on the rendered buffer. Rendering natively at the target rate
would need every machine to be rate-independent, which isn't verified.

**Channels** (planned): STEREO, or MONO (L+R at −3 dB) for a mono stem.

### Normalize and the loudness report

Planned. **NORMALIZE**: OFF (default), PEAK (to a dBFS ceiling), or
LOUDNESS (to an integrated LUFS target, −14 by default, with a true-peak
ceiling of −1 dBTP). LOUDNESS applies one gain to the whole file. If the
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

Planned: an editable name template (`export.fillName` already fills
`{project}`, `{nn}`, `{track}` and `{section}`). WAV and AIFF get the
project's locator markers as cue points, and the tempo and meter in an
`acid` chunk when the tempo is constant. FLAC and M4A get title,
artist and BPM tags. Every format gets a `slab` comment with the
version and a hash of the project, so a file can be traced back to the
exact render.

### Command line

```
slab song.slab --render out.wav                  # 24-bit, 3 s tail, as before
slab song.slab --render out.aif --bits 16        # AIFF, dithered
slab song.slab --render out.flac                 # FLAC, 24-bit, level 5
slab song.slab --render out.wav --stems stems/   # the mix and stems, one render
slab song.slab --stems stems/ --stem-kind all --tap fx --tail auto
```

The format comes from the extension. slabkit's `render(stems=True)`
calls `--stems` once instead of writing a project per track.

## FLAC encoder

`src/flac.zig`: an encoder of our own, no libFLAC. **Built.**

- Fixed blocksize, 4096 frames (a short last frame); 16 or 24 bits; 1
  or 2 channels; any rate (the common ones coded in the frame header).
- **Stereo decorrelation**: independent, left/side, right/side and
  mid/side are all encoded per frame, and the smallest kept.
- **Subframes**: CONSTANT (silence costs a few bytes), VERBATIM as the
  fallback, FIXED orders 0–4, and LPC up to order 12, from Levinson-
  Durbin on a Welch-windowed autocorrelation, coefficients quantized
  with error feedback at 15 bits (13 past 17-bit samples, so 64-bit
  free decoders stay exact). A residual that wouldn't fit 32 bits
  rejects its predictor.
- **Residual**: partitioned Rice coding (RICE2 when a parameter passes
  14), partition order chosen per subframe, the parameter per partition
  from the exact cost around the mean's log2.
- STREAMINFO with the MD5 of the samples and the real min/max frame
  sizes, CRC-8 headers and CRC-16 frames, a VORBIS_COMMENT with the
  vendor. No SEEKTABLE yet.

The level picks how hard it searches, as `flac -0..-8` does: 0–2 FIXED
only (partition order up to 3–5), 3–6 LPC at one order (6, 8, 8, 12),
7–8 every LPC order up to 12; 5 is the default. Frames are encoded on
up to 8 threads and joined in order; the output is the same bytes.

FLAC holds 16 or 24 bits, so a 32-bit float export asks it for 24.

Verified: every test signal (silence, full-scale noise, a sine sweep,
a DC offset; 16 and 24-bit; levels 0, 5, 8; a short last frame; mono)
round-trips bit-exact through miniaudio's decoder (dr_flac), and the
reference `flac -t` passes the files. On two rendered songs, level 5
came out 0.2 % and 1.6 % smaller than `flac -5`, within 0.3 % of
`flac -8`, and decodes to exactly the 24-bit WAV export's samples.

## Phasing

1. **Clip mute** (built).
2. **Bounce selection** (built).
3. **Export dialog and one-pass stems** (built; SECTIONS waits for
   locator markers, an editable name template and MASTER FX stems are
   open).
4. **FLAC encoder** (built; no level choice in the dialog yet), then
   ALAC and AAC through AudioToolbox.
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
