# Changelog

What changed in each Slab release, newest first. Each release's notes on
GitHub are its section here (`tools/release.sh` copies them), so add to
**Unreleased** as you go: what a user can now do or will notice, not how.

## Unreleased

### Warp

- **Warp an audio clip** (right-click → *Warp*, or WARP in the audio clip
  editor): it locks to the beat and follows the tempo, tempo changes and
  ramps included. TAPE mode plays it like a tape: speed and pitch move
  together.
- **⌘-drag a clip's edge to stretch it**; a plain drag still trims.
- Unwarped clips no longer drag past the end of their audio, and the
  waveform no longer stretches across silence.
- Stereo audio clips draw both channels, left over right, in the
  arrangement and the audio clip editor.
- Audio clips play through a band-limited resampler: cleaner rate
  changes, no aliasing when sped up.
- **BEATS mode** for drums and loops (MODE in the audio clip editor):
  the audio is cut at its hits, each played at its own speed from where
  it lands on the grid, so hits stay sharp at any tempo. PRESERVE cuts at
  the hits or every 1/16, 1/8, 1/4; GAP fills a stretched slice with
  silence or its looped tail; DECAY shortens each slice.
- **MIX mode** keeps the pitch for anything (full mixes, pads, vocals):
  a phase vocoder locked to the spectrum's peaks, resetting on hits,
  holding the stereo image. Warping a clip now picks BEATS for short
  loops full of hits and MIX for everything else.
- **VOICE mode** for vocals, bass and leads (one note at a time): grains
  matched to each other, so no phasing; GRAIN sets their length.
- **SMEAR mode**: Paulstretch-style extreme stretching into texture, with
  a SIZE for how much it smears; renders the same every time.
- **Warp markers** in the audio clip editor: drag a marker and the audio
  around it stretches; ⌘-drag slides the audio under it; drag a hit
  straight onto the beat. Double-click the strip to add one; right-click
  for *Warp straight from here* and more.
- **Tempo detection**: a loop's tempo and downbeat from its hits. Short
  files (30 s or less) are warped onto it as they're imported, so they
  play in the song's tempo right away; *Warp* uses it too. SEG BPM in the
  editor: drag it, double-click to detect, ×2 / ÷2 from the right-click
  menu.
- **Quantize hits to grid** for audio: a live take's hits pulled onto
  the edit grid.
- **Warped audio plays the groove**: swing a drum loop with the song's
  or the track's groove, like the notes.
- **Extract groove** from an audio clip's hits: a drummer's feel for
  your MIDI tracks.
- **Follow its beats**: a take that drifts gets a marker on every bar,
  so it stays on the grid.
- **Song follows this clip**: the song's tempo map from a warped take, so
  a performance played without a click sets the tempo for everything.
- **TRANSPOSE and FINE** in every mode but TAPE: pitch apart from time.
- Slab finds the hits in every audio file, shown as ticks in the audio
  clip editor.
- slabkit: `track.audio(..., warp=bpm)` and `fit_beats=`, `mode="beats"`
  with `preserve=`, `gap=`, `decay=`, `mode="mix"`, `"voice"` with
  `grain=`, `"smear"` with `size=`, `transpose=`, `fine=`.

## 0.0.7 — 2026-10-05

### Time: tempo, sections, groove

- **Tempo changes.** Right-click the ruler: *Tempo change here*, *Ramp to
  next tempo*, *Remove tempo change*; drag a change's value on the ruler.
  Steps and linear ramps, exact to the sample; editing the tempo while
  playing keeps the playhead on its beat. The BPM field sets the tempo
  where the playhead is.
- **Sections and locators.** A lane above the ruler: sections (INTRO,
  VERSE, …) back to back, locators (named flags) and the song's END.
  Double-click to add a section, drag to move, right-click for the rest;
  ⌘← / ⌘→ jump between them. A section's dialog sets its name, color,
  tempo, meter and groove, written into the maps at its start. Sections
  sit on bars; with ⌥, anywhere on the grid (a pickup).
- **Arranging by section.** *Duplicate section*, *Move section
  earlier/later*, *Delete section and its content*: clips, automation,
  tempo and meter changes and locators move with it, cut cleanly at its
  edges.
- **Groove.** Swing and feel applied as notes play, never written into
  them: MPC swings, triplets, samba, laid back, loose, and grooves that
  follow the meter's groups (aksak). The song's groove (ruler menu), a
  section's, or a track's own with AMOUNT and SHIFT (piano roll header).
  *Extract groove* from a clip, *Commit groove* into the notes. Replaces
  the piano roll's SWING.
- **Polymeter and polytempo.** A track can have its own meter and a tempo
  ratio (3:2, 4:3, 5:4, …) from its right-click menu; its clips run in
  its own beats.

### Bounce, freeze, export

- **Bounce** a selection of clips to a new track, after the instrument,
  the effects, the fader or with its sends; the originals mute and can be
  thawed back, and a bounce shows STALE when what it was made from
  changed.
- **Freeze** a track (right-click its name): its audio plays instead of
  its machines to save CPU; *Unfreeze*, *Freeze again*, *Flatten to
  audio*. FROZEN / STALE on its header.
- **The Export sheet** (⌘R): presets (MASTER, STREAMING, CD, STEMS FOR
  MIXING, SECTIONS, LOOP, PREVIEW, BROADCAST, ARCHIVE, and your own),
  tabs for tracks, format, level and files. Stems from one render, chosen
  per track; WAV, AIFF, FLAC (Slab's own encoder), ALAC, AAC; 44.1–96
  kHz; mono or stereo; dither; normalize to a loudness or peak with a
  report card; name templates with folders; title/artist/album/year tags
  in every format; a file per section; WAV cue points from sections and
  locators, and loop tempo for apps that sync loops.
- **Clip mute.**
- Command line: `--stems`, `--sections`, `--normalize`, `--rate`,
  `--mono`, `--flac-level`, tags and more (`docs/19`).

### slabkit

- `song.tempo()`, `section(groove=)`, `Song(groove=)`, `track.groove()`,
  `track.time()`; songs write their sections and END.

## 0.0.6 — 2026-10-04

- An About card, the version on the splash, a loading card while a
  project opens.
- A README for everyone; #slab on The Fixpoint Discord.

## 0.0.5 — 2026-10-04

- Factory sounds of Slab's own: FM-86 keys, e-pianos, leads and basses,
  43 Unfairlight voices, and the VCSL basics for the sampler (FLAC).
- The sampler loads FLAC.
- Four demo songs as projects, on Slab's own presets.
- Licensing: GPL-3.0-or-later with the Slab Machine Exception; factory
  content CC0. fy, the machine language, ships in the source tree.
- Earlier releases (0.0.1–0.0.4) were withdrawn.
