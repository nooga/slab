# Changelog

What changed in each Slab release, newest first. Each release's notes on
GitHub are its section here (`tools/release.sh` copies them), so add to
**Unreleased** as you go: what a user can now do or will notice, not how.

## Unreleased

### Audio into notes

- **Audio to notes**: right-click an audio clip and its sung, hummed,
  whistled or played line comes out as notes on a new Cream track under
  it, with a lead sound, or a bass when the line sits under C3. The notes
  land on the song's beats, follow the clip's warp, and are corrected
  for a take that isn't tuned to A440. The clip is muted.
- **Hum to notes**: right-click a track's arm button to switch it from
  **R** to **N**, and a take recorded there turns into notes as soon as
  you stop.
- **Tune**: put a voice in key. Press **TUNE** in the audio clip editor,
  or choose *Tune* from a clip's right-click menu. The key comes from
  the take itself; change it, pick a scale, set **SPEED** (0 for the
  hard effect, slower for gentle correction) and **HUMAN** (keep the
  singer's vibrato). The waveform shows the sung and the tuned pitch.
  The voice keeps its own character because its formants stay put. It
  works on warped and unwarped clips, and in slabkit as
  `audio(…, tune="A", scale="minor")`.
- **Chords to notes**: right-click an audio clip to hear its chords
  back on a pad. Chords, sevenths and the key are found beat by beat,
  even from a full band with drums, and land as a pattern on a new Juno
  track. The clip is named after them ("C Am F G7"), and its Tune key
  is set to the song's.
- **Drums to a kit**: right-click a drum loop, take or stem and it
  becomes a sampler kit and a pattern. Its hits are sorted into kick,
  snare, hats, toms and percussion on General MIDI keys, and the cleanest
  hit of each becomes its pad. Each hit is judged by what it adds over
  what was already sounding, so bleed under it doesn't fool it. On a
  whole song, Explode runs it on the separated drums: about 87% of hits
  were named right on rendered songs.
- **Split into stems**: take a song apart into drums, bass, other and
  vocals, each on its own track under the clip and playing in its place.
  It uses HTDemucs, a neural network, running on your Mac through
  CoreML: a three-minute song takes about 15 s. It needs the **Extract**
  pack (Browser, Packs), which downloads and sets up the model once.
- **Explode…**: one sheet for all of it. Pick stems, drums, bass,
  chords and melody, and a song comes back as stems, a drum kit with its
  pattern, the bassline and melody as notes, and the chords on a pad.
- **Extract** and **Tempo from clip** submenus: an audio clip's
  right-click gathers Audio to notes, Chords to notes, Drums to a kit,
  Slice to a sampler track, Split into stems and Explode under
  *Extract*.
- **Song tempo to clip** and **Section tempo to clip** set the whole
  song, or the clip's section, to the tempo the clip was played in. The
  tempo comes from a warped clip's markers, or is detected from an
  unwarped clip's hits. *Song follows the clip's changes* joins them
  under *Tempo from clip*.

### Fixes

- **Hits under a loud bass** are found on the hit, not up to 16 ms
  off. That makes warp markers, BEATS slices and grooves from such
  takes sit tighter.
- **Slice to sampler on a track at its own tempo ratio** (3:2 and the
  like): the new pattern is as long as the clip, and the slices cover all
  of it, the last one included.
- **Song follows clip on a track at its own tempo ratio**: the tempo
  changes cover the whole clip, and the song's own tempo comes back where
  the clip ends.

## 0.0.8 — 2026-10-05

### Warp: audio on the beat

- **Warp an audio clip** (right-click → *Warp*, or WARP in the audio clip
  editor): it locks to the beat and follows the tempo, tempo changes and
  ramps included. Short loops (30 s or less) arrive warped when imported,
  at the tempo Slab hears in them, so they play in the song's tempo right
  away.
- **⌘-drag a clip's edge to stretch it**; a plain drag still trims.
- **Five ways to stretch** (MODE in the audio clip editor):
  - **TAPE**: like a tape, speed and pitch move together.
  - **BEATS**, for drums and loops: cut at the hits, each played at its
    own speed from where it lands, so hits stay sharp at any tempo.
    PRESERVE cuts at the hits or every 1/16, 1/8, 1/4; GAP fills a
    stretched slice with silence or its looped tail; DECAY shortens each
    slice.
  - **MIX**, for anything (full mixes, pads, chords): a phase vocoder that
    keeps the pitch, resets on hits and holds the stereo image.
  - **VOICE**, for vocals, bass and leads: matched grains, no phasing;
    GRAIN sets their length.
  - **SMEAR**: Paulstretch-style extreme stretching into texture; SIZE
    sets how much.
  Warping picks BEATS for short loops full of hits and MIX for the rest.
- **TRANSPOSE and FINE** in every mode but TAPE: pitch apart from time.

### Editing warped audio

- **Hits**: Slab finds them in every audio file, shown as ticks in the
  audio clip editor.
- **Warp markers**: drag a marker and the audio around it stretches;
  ⌘-drag slides the audio under it; drag a hit straight onto the beat.
  Double-click the strip to add one; right-click for *Warp straight from
  here* and more.
- **SEG BPM** in the editor: drag it, double-click to detect the tempo;
  *Tempo ×2 / ÷2* from the right-click menu.
- **Quantize hits to grid**: a live take's hits pulled onto the grid.
- **Follow its beats**: a take that drifts gets a marker on every bar, so
  it stays on the grid.

### Audio and the song's time

- **Warped audio plays the groove**: swing a drum loop with the song's or
  the track's groove, like the notes.
- **Extract groove** from an audio clip's hits: a drummer's feel for your
  MIDI tracks.
- **Song follows this clip**: the song's tempo map from a warped take, so
  a performance played without a click sets the tempo for everything.
- **Slice to a sampler track**: a loop cut at its hits onto sampler pads
  from C1 up, with a pattern playing them where they played; rearrange
  the break as notes.

### Audio clips

- Stereo clips draw both channels, left over right.
- Clips play through a band-limited resampler: cleaner rate changes, no
  aliasing when sped up.
- Unwarped clips no longer drag past the end of their audio, and the
  waveform no longer stretches across silence.

### slabkit

- `track.audio(..., warp=bpm)` or `fit_beats=`, with `mode="tape"`,
  `"beats"` (`preserve=`, `gap=`, `decay=`), `"mix"`, `"voice"`
  (`grain=`) or `"smear"` (`size=`), and `transpose=`, `fine=`.

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
