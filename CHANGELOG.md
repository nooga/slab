# Changelog

What changed in each Slab release, newest first. Each release's notes on
GitHub are its section here (`tools/release.sh` copies them), so add to
**Unreleased** as you go: what a user can now do or will notice, not how.

## Unreleased

### Warp

- **Warp an audio clip** (right-click → *Warp*, or WARP in the audio clip
  editor): it locks to the beat and follows the tempo, tempo changes and
  ramps included. TAPE mode for now: speed and pitch move together.
- **⌘-drag a clip's edge to stretch it**; a plain drag still trims.
- Unwarped clips no longer drag past the end of their audio, and the
  waveform no longer stretches across silence.
- Audio clips play through a band-limited resampler: cleaner rate
  changes, no aliasing when sped up.
- slabkit: `track.audio(..., warp=bpm)` and `fit_beats=`.

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
