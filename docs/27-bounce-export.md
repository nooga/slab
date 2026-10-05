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
selection with thawable recipes, Export (the Export sheet with presets,
a per-track stem list, mix and one-pass stems, mono, project/loop/
selection, WAV and AIFF at 16/24/32f with dither, FLAC, ALAC, AAC,
loudness and normalize with a report, 44.1/48/88.2/96 kHz, name
templates, tags, settings saved with the project, the command line).
Each section below says what of it is still design.

## Bounce selection

Select clips (on one track or many, note or audio clips) and choose
**Bounce** (arrangement right-click menu, `cmd+B`). One page, in
sections (`src/ui/bounce_dialog.zig`):

- the title bar names the selection: "3 CLIPS ON 2 TRACKS · 15.9 S";
- **TAKE THE SIGNAL AFTER**: the chain drawn as four caps, INSTRUMENT →
  EFFECTS → FADER → + SENDS, the arrows the signal passes lit, a line
  under it saying what that tap is for (§Tap);
- **RESULT**: MAKE (ONE CLIP, or ONE CLIP PER TRACK when the selection
  spans two or more), ORIGINALS (MUTE, CAN THAW; KEEP PLAYING; DELETE),
  TAIL (AUTO, NONE, 1–30 S), CHANNELS (STEREO, MONO, or AUTO: mono when
  the two sides are the same, the default) and NAME, the new tracks'
  name template (`{track} bounce`; `{track}` is the source's name);
- the footer says what will happen: "2 NEW TRACKS UNDER THE SOURCES ·
  32-BIT FLOAT WAV IN THE PROJECT".

Enter bounces, Esc cancels (unless the name field is being edited).
Then it renders with the Export sheet's progress bar.

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

- **ONE CLIP** (together): one clip on one new track, the sum of the
  taps.
- **ONE CLIP PER TRACK** (each): one new track per source track, each
  clip at the range's start so they stay aligned.

### The new track and the originals

The new track is an audio track inserted below the lowest source
track, named by the NAME template, `{track} bounce` by default, where
`{track}` is its source's name (`Bounce N` when one clip spans several
tracks), in its first source's color. Its output is where its sources'
outputs go when they all agree (a group stays a group), else the
master. When the tap printed the fader (FADER, +SENDS), its fader is at
0 dB and its pan at center. When it didn't (INSTR, FX) and the clip has
one source, it stands in for that source: it copies its fader, pan and
sends, so the bounce sits in the mix where the source did. Volume and
pan automation isn't copied; FADER prints it.

The file is a 32-bit float WAV, so a bounce that peaks above 0 dBFS
before the master isn't clipped; stereo, or mono when CHANNELS asks
(AUTO: when its two sides are the same). A re-bounce uses AUTO. It goes to the package's
`audio/` as `<source>-bounce.wav` (`bounce.wav` for several sources;
`-2`, `-3`… when taken), or to `Cache/recordings/` while the project is
unsaved, as takes do (docs/25 §The project package). Audio clips play
stereo sources in stereo (`wav.loadStereo`; imports used to fold to
mono).

The originals are **muted**: they stay where they were, drawn dimmed,
and don't play, so the song doesn't play the part twice (the bounce and
its source on top of each other). Unmute them to compare, or delete
them once you're happy with the bounce. The whole bounce is one undo
step. The dialog also offers **KEEP PLAYING** (the originals stay
audible, for a layer you want doubled) and **DELETE**.

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

Every clip has a stable **id** (`Clip.uid`, saved as `"id"`): kept by
save, load and undo, fresh for a copy, a paste from a file or a split's
new half. A bounced clip keeps a **recipe** (`Clip.recipe`):

```json
{"type": "audio", "name": "pad-bounce.wav", "id": 41, "...": "...",
 "recipe": {"clips": [12, 13], "tap": 1, "tail": "auto", "hash": "9f2c41e0b7a3d815"}}
```

`clips` are the ids of the clips it was rendered from (at most 32; a
bounce of more keeps no recipe, nor does one whose originals were
deleted). `tap` is the bounce dialog's (0 INSTR, 1 FX, 2 FADER,
3 +SENDS), `tail` "auto" or seconds. `hash` is a fingerprint
(`src/recipe.zig`) of everything the render heard:

- each source track's instrument, its settings and state, its inserts
  and their settings, and its lanes; its fader and pan when the tap
  printed them, its sends with +SENDS (`document.appendRenderSettings`);
- the code each of those machines runs: an fy machine hashes the
  contents of its file and every file it included when it was compiled
  (`FyRawMachine.code_hash`), so a livecoded kernel edit counts;
- with +SENDS, the buses its sends reach, the same way;
- the source clips themselves, where they sit and what they hold (not
  whether they're muted or selected);
- the tempo, the tap and tail, and the Slab version.

Slab renders deterministically, so a recipe whose fingerprint still
matches would make the same clip. The UI thread re-checks every recipe
twice a second (`recipe.checkAll`); one that no longer matches draws a
yellow **stale** notch in its clip's corner, and the clip menu offers:

- **Re-bounce**: select its originals and render them again as they
  were bounced (muted originals play for it), into the same clip: a new
  file, the length it now has, a fresh fingerprint. One undo step.
- **Thaw**: unmute the originals and delete the bounce. One undo step.

DAWs treat a bounce as a fork. Here it's a cache of a render you can
always redo, which is what makes bouncing safe in a livecoding DAW,
where the source keeps changing under it.

## Export

**File > Export Audio…** (`cmd+R`) replaced Render Audio. It opens the
**Export sheet**; its settings are the project's (`"export"` in the
project file, `src/export_settings.zig`), so `cmd+R`, Enter repeats the
last export.

### The Export sheet

`src/ui/export_dialog.zig`, 640×460, a dialog in sections rather than a
wall of buttons:

- **Title bar**: the PRESET dropdown, what the preset is for, SAVE…
  (names the current settings as a preset of your own) and, on one of
  your own, X to delete it. Editing anything makes it CUSTOM until the
  settings match a preset again.
- **Tabs** (`ctl.tabs`, `cmd+1`…`4`): TRACKS, FORMAT, LEVEL, FILES &
  TAGS. **RANGE** (PROJECT, LOOP, SELECTION) and **TAIL** (AUTO, WRAP,
  1–30 S) sit beside them, on every tab.
- **Footer**: what the export will be, "11 FILES · WAV 24/48 · AS MIXED
  · 3:12 + TAIL · ABOUT 270 MB", or in red why it can't run (no loop
  set, nothing selected, nothing to write); EXPORT and CANCEL.

**TRACKS** is the list of what's written. Its first row is the **MIX**
(on/off, CHANNELS), the second **STEMS** (on/off, and the defaults
every track follows: SIGNAL INSTR, FX or FADER, and CHANNELS), then a
row per track and bus: an on/off LED, its color and name, its kind
(TRACK, GROUP, RETURN, BUS), its SIGNAL and CHANNELS (DEFAULT shows the
default it follows, dimmed; picking a value overrides it for that track
only) and the file it will write. Each track's choices are saved on the
track (`"stem"`). By default every track that plays (audible, with a
clip that isn't muted) writes a stem and buses don't; the LED overrides
that per track, and SELECT ALL, NONE, TRACKS, BUSES or DEFAULT sets the
whole list. The list scrolls.

**FORMAT**: FORMAT (WAV, AIFF, FLAC, ALAC, AAC, each with a line on
what it's for), DEPTH or BITRATE, SAMPLE RATE, and for FLAC its
COMPRESSION level, 0–8; DITHER (only for 16-bit) and a size estimate.

**LEVEL**: NORMALIZE the mix (OFF, TO A PEAK, TO A LOUDNESS), its
TARGET (named: −9 club, −14 streaming, −16 Apple, −23 broadcast) and
CEILING; the stems' GAIN (§Normalize); and the last export's numbers.

**FILES & TAGS**: the FOLDER (a template too; `~` is home; CHOOSE…
opens a folder panel), the MIX NAME and STEM NAME templates (§Names
and metadata), IF IT EXISTS (ADD A NUMBER, REPLACE IT), SHOW IN FINDER,
where the first file will land, and the TAGS: title (the project's name
when empty), artist, album, year.

While it renders the sheet shows the progress; then the **report**
(§Normalize and the loudness report), with SHOW FILES and DONE.

**Presets** (`export_settings.BUILTIN`): MASTER (WAV 24/48, as mixed),
STREAMING (FLAC at −14 LUFS), CD (WAV 16/44.1, dithered), STEMS FOR
MIXING (the mix and stems, channels AUTO), LOOP (the loop, wrapped),
PREVIEW (AAC 256 at −14 LUFS, dated), BROADCAST (−23 LUFS), ARCHIVE
(FLAC level 8, mix and stems). A preset holds what's written, the
range and tail, the format, the level and the name templates, not the
folder, the tags or the tracks' choices. Yours are kept in
`export-presets.json` beside settings.json, for every project.

### What

- **MIX**: the master, as Render Audio wrote it; STEREO, MONO or AUTO.
- **STEMS**: a file per chosen track or bus, at its SIGNAL: **INSTR**
  (the instrument and audio clips, before the inserts), **FX** (after
  the inserts) or **FADER** (after volume and pan). A track's stem is
  its own signal: before its group bus, its sends' returns and the
  master chain. A group or return is a stem of its own.
- **Channels**: STEREO, MONO ((L + R) / 2) or AUTO (mono only when the
  two sides are the same, within −100 dBFS: a mono source panned
  center, a kick or a bass), per file.

Stems come from **one render pass**: the engine's capture (§How it
renders) copies each stem's tap while the mix renders, so 24 stems
cost about one mix render plus the writes. `src/exporter.zig` does a
whole export and is shared by the dialog's worker thread and the
command line. Every file of an export has the same length, so they
line up from zero in any DAW; each stem is read from its own latency
on (PDC).

Not built yet: stems through the master chain (MASTER FX), which needs
a render per stem.

### Range

PROJECT (beat 0 to END, else to the last playing clip's end), LOOP,
SELECTION (the selected clips' span; everything plays) or SECTIONS. The transport **stops**
at the range's end (`Engine.offline_stop`): no note starts past it and
audio clips fall silent there, the notes sounding are released, and the
tail is what rings out. AUTO stops once the master and every stem have
stayed below −80 dBFS for 0.5 s, up to 30 s; a fixed tail renders
exactly that long.

**SECTIONS** renders from the first section to the last one's end and
writes every output (the mix, each stem) as a file per section
([docs/28](28-time.md#export-by-section)).

**LOOP-WRAP** (TAIL WRAP; built):
everything rendered past the range's end is folded back onto its start,
round and round, and every file is exactly the range long. Played in a
loop it continues seamlessly, with a reverb carrying over into bar 1;
a resampled loop is resampled circularly so its seam stays clean. On a
rendered loop it cut the jump across the seam tenfold. The fold is a sum
after the master chain, so the start can peak past its limiter's
ceiling. That's what a sample pack loop or a game music loop needs, and
DAWs leave it to manual editing.

### Format

Built:

| Format | Bits |
|---|---|
| WAV | 16, 24 (default), 32f |
| AIFF | 16, 24, 32f (AIFF-C `fl32`) |
| FLAC | 16, 24 (level 0–8, 5 default) |
| ALAC | 16, 24, in `.m4a` |
| AAC | 128, 192, 256 (default), 320 kb/s, in `.m4a` |

`src/export.zig`. PCM is clamped to full scale, float written as is.
**Dither**: TPDF at ±1 LSB for 16-bit, on by default, seeded so an
export is reproducible; off for 24-bit and float.

ALAC and AAC are Apple's encoders through AudioToolbox's `ExtAudioFile`
(`src/native_audio.c`). ALAC is fed our quantized integers in the top
bits of 32, so it decodes to exactly the WAV export's samples (checked
with `afconvert`).

MP3 isn't planned: AAC covers lossy delivery and MP3 encoding would
mean vendoring LAME.

**Sample rate**: 44.1, 48 (default), 88.2 or 96 kHz. The engine runs
at 48 kHz (`audio.SAMPLE_RATE`), so other rates go through an offline
resampler (`src/resample.zig`): polyphase windowed sinc at the exact
rational ratio, Kaiser β 12.3 (about 120 dB of stopband), passband to
20 kHz going down and to 21.6 kHz going up, centered so timing holds.
Loudness is measured on the resampled file. Rendering natively at the
target rate would need every machine to be rate-independent, which
isn't verified.

**Channels**: STEREO, MONO or AUTO, per file (§What). Every format
writes mono.

### Normalize and the loudness report

**NORMALIZE**: OFF (default, as mixed), TO A PEAK (the mix's true peak
to −0.1, −1 or −3 dBTP) or TO A LOUDNESS (its integrated loudness to
−9, −14, −16 or −23 LUFS, lowered if that would push the true peak past
the CEILING, −1, −2 or −0.3 dBTP). It is one gain for the whole file,
never limiting: the master chain is where limiting belongs. The stems'
GAIN is SAME AS THE MIX (default: their balance is kept and they still
sum to the written mix) or AS MIXED; a stems-only export isn't
normalized.

The meter is `src/loudness.zig`: ITU-R BS.1770-4 K-weighting (shelf and
RLB highpass, derived for any rate), integrated loudness from 400 ms
blocks at 75 % overlap gated at −70 LUFS and 10 LU under, LRA per EBU
Tech 3342 (3 s blocks at 10 Hz, gated at −70 and 20 LU under, 10th to
95th percentile), true peak from a 4× oversampled copy (a 48-tap
Blackman-windowed sinc). On three rendered songs its integrated
loudness is within 0.05 LU of slabkit's (`tools/slabkit/analyze.py`).

After an export the sheet turns into a **report**: the files and their
length; for a mix, a strip of large readouts, its integrated loudness,
LRA, true peak (red past −1 dBTP) and the gain applied; and each stem's
loudness as a bar against the loudest stem (full at 0 LU, empty at −30)
with its LU under it, the stem report from docs/21 §Mixing by numbers.
LEVEL keeps the last export's numbers. `--render` prints the mix's.

### Names and metadata

**Names** are templates (`export.fillName`): `{project}`, `{track}`,
`{nn}` (the stem's number, two digits), `{date}` (YYYY-MM-DD) and
`{bpm}`. A `/` in a template makes a folder, so the default stem name,
`{project} stems/{nn} {track}`, puts the stems in a folder beside the
mix; in a field's value it, `:` and control characters become `-`, and
a template can't climb out of the folder (`..`) or start at the root.
The FOLDER is a template as well, `~/Music/Slab/Exports/{project}` by
default. IF IT EXISTS: ADD A NUMBER ("Song 2.wav", the default) or
REPLACE IT; two files of one export never share a name.

**Tags**: title (the project's name unless set; `<title> - <track>` for
a stem), artist, album, year, the tempo, and a comment, `Slab
<version>, project <hash>`, the hash of the project as it was rendered,
so a file traces back to its render.

- WAV: LIST/INFO (INAM, IART, IPRD, ICRD, ICMT, ISFT) and an `id3 `
  chunk, after the data.
- AIFF: NAME, AUTH, ANNO and an `ID3 ` chunk.
- FLAC: Vorbis comments (TITLE, ARTIST, ALBUM, DATE, COMMENT, BPM).
- M4A: iTunes atoms (©nam, ©ART, ©alb, ©day, ©cmt, ©too, tmpo).
  AudioToolbox won't write them into an .m4a, so `export.tagM4a` adds
  them to the file's `moov/udta/meta/ilst` afterwards, in the `free`
  room AudioToolbox leaves before the audio: nothing moves.

The ID3 frames are v2.3 Latin-1; other characters become `?`.

A WAV also carries **cue points**, the section starts and locators that
fall in it, named (`cue ` and LIST/`adtl` labels), and, when it is a
loop or a section whose tempo holds still, an **`acid` chunk** (a
stretchable loop, its length in the meter's units, the meter and the
tempo) for the apps that sync loops (docs/28 §Export by section).

### Command line

```
slab song.slab --render out.wav                  # 24-bit, 3 s tail, as before
slab song.slab --render out.aif --bits 16        # AIFF, dithered
slab song.slab --render out.flac                 # FLAC, 24-bit, level 5
slab song.slab --render cd.wav --rate 44100 --bits 16
slab song.slab --render loop.wav --range 16:32 --loop-wrap --tail auto
slab song.slab --render out.m4a --kbps 320       # AAC; --alac for Apple Lossless
slab song.slab --render out.wav --stems stems/   # the mix and stems, one render
slab song.slab --stems stems/ --stem-kind all --tap fx --tail auto
slab song.slab --render out.wav --normalize -14  # or peak:-1
slab song.slab --render out.flac --flac-level 8 --artist nooga --album Slabs --year 2026
slab song.slab --render demo.m4a --mono           # the mix summed to mono
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
3. **Export dialog and one-pass stems** (built; SECTIONS per docs/28;
   MASTER FX stems are open).
4. **FLAC encoder**, **ALAC and AAC** (built).
5. **Loudness**: `loudness.zig`, NORMALIZE, the report card (built).
6. **Resampler** for 44.1/88.2/96 kHz (built).
7. **Provenance**: recipe, hash, stale, Re-bounce, Thaw (built).
8. **LOOP-WRAP** and tags, cue points and `acid` (built).
9. **The Export sheet** (presets, tabs, the stem list, templates, tags,
   mono, saved settings) and the sectioned Bounce dialog (built).

Later, not designed here:

- **Variations**: bounce a selection N times with different seeds for
  the machines that use randomness, into N clips or a sampler's round
  robin.
- **Bounce to sampler**: the selection becomes a sampler instrument,
  sliced at its notes or as one chromatic sample.
- **Freeze** (built, [docs/28](28-time.md#freeze)): a whole track
  rendered to replace its instrument and inserts for CPU, on Bounce's
  job and FX tap.
- **Resample input**: record the master or another track live, as a
  track's input (docs/07 §Recording, Deferred).
- **Recipes without the audio**: since a fresh recipe reproduces its
  clip exactly, a shared package could leave bounce files out and
  re-render on open. That only works if the recipient has the same
  machines and Slab version, so it waits until packages carry that.
