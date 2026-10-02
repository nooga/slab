# 25 — Storage: projects, the library, sharing

Where slab keeps what it ships and what users make, how a project names
the files it uses, how a project stays whole when it moves to another
computer, and how anything a user makes becomes something others can
open. **Status: design.** Built: the shared table cache (§Load time).
Code, as it lands: `src/storage.zig` (roots and references),
`src/document.zig` (the project package), `src/wavetable_cache.zig`.

This supersedes the path rules in [19-project-format.md](19-project-format.md)
(paths relative to the working directory, `song.tables/` beside the
project) once phase 2 lands; docs/19 then points here.

Prior art: Ableton's User Library and Collect All and Save, Logic's
project packages, Bitwig's package manager, Git's content addressing.

## Goals

1. Slab ships instruments, presets, wavetables, clips and example
   projects. Users never edit these, and a new slab version never
   changes the sound of an old song.
2. Each user has a home folder for their own projects, presets,
   wavetables, clips, samples and machines.
3. A project is portable. Zip it, send it, and it opens on another
   slab with everything it uses.
4. Anything made inside a project (a preset, a table, a clip, an edited
   machine) can be saved to the home folder and reused.
5. Anything can be published to an online repository and opened from
   inside slab, with no manual downloads. Publishing is: select the
   thing, click Publish.

The one rule behind all five: **every file is identified by its
content** (a SHA-256 hash). Paths say where to look first; the hash says
whether what's there is the right file.

## Roots

A reference is a string with a root prefix. Slab resolves it against
these roots:

| Root | Where | Holds | Writable |
|---|---|---|---|
| `project:` | inside the open project's package | what the project made or collected | yes |
| `user:` | the home folder, `~/Music/Slab/` (`$SLAB_HOME`) | the user's own things | yes |
| `factory:` | the app bundle, `Slab.app/Contents/Resources/factory/`; in a dev build, the repo root (`$SLAB_FACTORY`) | what slab ships | no |
| `lib:` | `~/Music/Slab/Library/` (`$SLAB_LIBRARY`) | large sample packs fetched separately | by pack tools |
| `slab:` | the online repository, cached in `~/Music/Slab/Cache/` | published items | no |

In a project file, a path with no prefix is relative to the project
package: `tables/bass.wav` means `project:tables/bass.wav`. Absolute
paths still load, but saving collects them (§Collect on save), so a
saved project never depends on one.

Machine ids (`"machine": "juno2"`) resolve in order **project → user →
factory**. A project that carries its own edited `juno2` plays that
one. Every other project keeps the factory machine.

## The home folder

```
~/Music/Slab/
  Projects/      Song.slab packages
  Presets/       <machine id>/<bank>/<name>.preset
  Wavetables/    .wav, Serum-compatible, 2048-sample frames
  Clips/         .slabclip
  Samples/       the user's own samples, kits, keymaps (.wav, .sfz, folders)
  Machines/      <id>/<id>.fy, with presets/ and assets/ like machines/ in the repo
  Library/       lib: packs (VCSL, the drum machines, …), one folder each
  Cache/         slab: downloads and anything slab can rebuild
```

Slab creates the folder on first launch. `$SLAB_HOME` moves all of it,
and `$SLAB_LIBRARY` moves only `Library/`, as it does today.

The home folder sits in `~/Music` rather than `~/Documents` because
that is where macOS audio apps keep their content, and Time Machine and
iCloud users expect to find it there.

**Settings are not content.** They live in
`~/Library/Application Support/Slab/settings.json`: the audio device,
UI zoom, recent projects, a moved home folder, and the collect policy.
They are never shared or published.

## The project package

A project is a folder that Finder shows as a single file:

```
Song.slab/
  project.json    the document (docs/19's format, plus "assets")
  tables/         wavetables edited in the project
  samples/        samples and keymaps the project collected
  recordings/     audio input takes
  presets/        <machine id>/<name>.preset saved in the project
  machines/       <id>/: machine sources edited for this project
  clips/          .slabclip files the project saved or collected
```

- **Zipping the folder is the export.** Nothing else is needed.
- **Finder treats it as one file** because the app's Info.plist
  declares `.slab` as a document package (`com.apple.package`).
  Double-clicking it opens slab.
- **It stays diffable:** `project.json` is plain JSON, so git and
  slabkit work on it as they do now.
- **A bare `.slab` JSON file still opens.** slabkit writes these, and
  so do the songs in `songs/`. Its relative paths are relative to its
  folder. Saving it from the app writes a package.
- **This replaces two earlier layouts:**
  - `song.tables/`, the folder the wavetable editor writes today, becomes
    the package's `tables/`.
  - `recordings/` in the working directory (`src/recorder.zig`) becomes
    the package's `recordings/`.

### The asset table

`project.json` gets a top-level `assets` object listing every file the
project uses. Each key is the reference exactly as tracks and clips
write it:

```json
"assets": {
  "tables/growl.wav": {"sha256": "a3f9…", "origin": "user:Wavetables/growl.wav"},
  "factory:machines/concoction/assets/kick.wav": {"sha256": "7c01…"},
  "samples/vcsl/marimba/marimba.sfz": {"sha256": "e912…", "origin": "lib:vcsl/Marimba/marimba.sfz",
    "files": {"samples/vcsl/marimba/m-c4.wav": "41bd…"}}
}
```

- **References keep their form.** Tracks, clips and presets write
  references exactly as they do now (`"wt-a": "tables/growl.wav"`), so
  the JSON stays readable and slabkit's job doesn't change.
- **`origin`** is where a collected file came from. Slab can then show
  "from your library" and offer to update the copy.
- **`files`** lists the files an asset pulls in with it: an SFZ's
  samples, a folder kit's WAVs, a machine's sources.
- **The table is rebuilt on every save**, from what the tracks
  reference at that moment. Nothing goes stale.

### Collect on save

Saving makes the project complete:

| Reference | On save |
|---|---|
| `project:` | kept |
| `user:`, `slab:`, an absolute path | **copied into the package**, rewritten to the copy, `origin` kept |
| `lib:` | **only the files the project uses** are copied: the SFZ and the samples its regions name, not the pack |
| `factory:` | kept as a reference, pinned by its hash |

- **Copies are skipped when a file with the same hash is already in
  the package.** A second save copies nothing new.
- **Saving leaves collected files in place when nothing references
  them any more.** **Clean Up** removes them.
- **Collecting is the default.** The settings can turn off collecting
  for `lib:` (projects stay small, and only open where that pack is
  installed). They can't turn it off for `user:`, because a project
  that points into someone's home folder never works for anyone else.
- **Save stays fast:** hashing and copying happen only for references
  that changed since the last save.

This is a project-save step and only that. `document.serialize` also
makes undo snapshots, so it never touches files (the same reason the
wavetable editor's tables are written in `saveProject`, docs/15).

### Load

For each asset, slab resolves the reference and checks it:

1. The file is there and its hash matches: use it.
2. The file is missing or differs, and an `origin` is given: look for
   a copy with that hash in the package. The project carries its copy,
   so this is the normal case for a project that was moved.
3. A `factory:` file has changed (it shouldn't, see below): look it up
   by hash in the factory's retired files.
4. Nothing matches: the asset loads empty, as a missing file does now
   (docs/19 §Where loading fails silently), and slab lists what's
   missing in the status bar and the project's info.

Hashing is cheap next to decoding, but slab also keeps a hash cache in
`Cache/hashes` keyed by path, size and modification time, so a large
sample is hashed once.

### Factory files never change

What slab ships is append-only. A factory file that a new version
changes keeps its old content in
`Resources/factory/.retired/<sha256>`, so a pinned reference still finds
it. Slab may then offer "a newer version of this table ships with slab"
without changing the song on its own.

Factory presets are params, not files, and a project already saves
every param value (docs/19 §Preset: "`params` stay authoritative").
Changing a factory preset changes only what the preset menu shows, never
an existing song.

## Items

Everything a user can save, reuse or share is an **item** of one kind:

| Kind | File | Notes |
|---|---|---|
| project | `Song.slab/` | the largest item |
| preset | `.preset` | docs/19's JSON. Racks are presets with `parts` |
| wavetable | `.wav` | with the `clm ` chunk (docs/15 §Wavetable editor) |
| sample | `.wav`, `.sfz` plus its files, or a folder kit | |
| clip | `.slabclip` | one clip in docs/19's clip JSON: a note clip, or an audio clip plus its audio |
| machine | `<id>/` | the same layout as `machines/<id>/` |

**Metadata.** Every item can carry name, author, note, tags and
license:
- **JSON formats** (project, preset, clip) hold them in a `meta`
  object.
- **Formats with no room** (WAV, SFZ, folders) hold them in a sidecar
  file, `<file>.meta.json`, which only exists once something has been
  set.

**Dependencies** use the asset table from §The asset table. A preset
that names a wavetable, or a clip that names its audio, lists that file
with its hash, so the item travels with what it needs.

### Save to Library

Anything in a project can be saved to the home folder with **Save to
Library**:
- **From where:** a preset from the panel's preset menu, a table from
  the wavetable editor, a clip from the arrangement, a machine from the
  code view.
- **What it does:** copies the item, and its project-only dependencies,
  into `user:`.
- **The project's own references don't change:** the project keeps its
  copy, and the `origin` becomes the new library file.

Preset menus list factory and user presets together: user presets come
from `user:Presets/<machine>/`, in a bank of their own. Saving a preset
from the panel defaults to the project's `presets/`, with a "Save to
Library" option. A preset made for one song stays with the song unless
the user says otherwise.

### Licenses

Not everything can be redistributed. The CMI disks, and any
commercial pack, are for the user alone.

- **Library packs say so:** a pack declares
  `"redistributable": false` in its `pack.json`.
- **Items inherit it:** anything collected from such a pack carries
  the flag in its asset entry.
- **Collecting still works:** the project is for the user's own use.
- **Publishing doesn't:** Publish refuses those files and says which
  ones. The user can publish the project without them, and recipients
  see them as missing.

## The browser

One browser panel lists items by kind, with four sources:

| Source | Lists |
|---|---|
| Project | what the open project carries |
| User | the home folder |
| Factory | what slab ships |
| Online | the repository: search, then open or drag in |

Dragging an item onto a track works the same from every source. An
online item is downloaded into `Cache/` and checked against its hash
first. Opening an online project downloads it and opens it as an
untitled copy. Saving writes it to `user:Projects/`.

## Publishing

A published item is a **manifest plus content-addressed files**:

```json
{"kind": "preset", "name": "Growl Bass", "author": "@nooga", "version": 3,
 "license": "CC-BY-4.0", "note": "…", "tags": ["bass", "wavetable"],
 "files": {"growl-bass.preset": "9ab2…", "tables/growl.wav": "a3f9…"}}
```

- **Publish:** select an item (in the browser, a preset menu, the
  wavetable editor, or File → Publish Project), check the dialog, and
  click Publish.
  - **The dialog** shows the name, note, tags, license, what's
    included and anything refused for its license.
  - **What it does:** collects dependencies as a project save does,
    hashes everything, and uploads the manifest plus only the files
    the repository doesn't already have.
- **Addresses:** `slab:@author/name` is the newest version, and
  `slab:@author/name@3` pins one. Projects that use a published item
  collect it like a `user:` file, with `slab:` as the `origin`. So they
  open offline and don't break when the author publishes version 4.
- **Storage is by hash:** a hundred projects using the same factory
  kick store it once. Factory files are never uploaded; a hash that
  matches a factory file is sent as the `factory:` reference.
- **The cache** keeps files by hash in `Cache/blobs/<sha256>` and
  manifests in `Cache/items/`. Anything in it can be deleted and
  downloaded again.

The repository itself (accounts, search, the server API) is a separate
design. This doc only fixes what slab sends and receives, so that
local projects and libraries can be built now without changing their
format when the online part lands.

## Load time

Measured on 2026-10-02 with debug builds and `--render` (load = total
time − render time):

| Song | Load before | Load after the table cache |
|---|---|---|
| `pml_basses` (23 Concoctions) | 20.9 s | 7.7 s |
| `voltage_riot`, `paper_boulevard` | ~4.5 s | unchanged |

**Wavetables (fixed).** Every Concoction built its own copy of every
table it declares, at 12 FFTs a frame. For `pml_basses` that was 46
builds of the same few files, about 120 MB of duplicate tables.

`src/wavetable_cache.zig` now keeps one read-only table per content and
counts its users:
- **Keyed by** a hash of the decoded samples, the frame size and the
  normalize flag.
- **Shared by** every instance that loads the same file.
- **Freed by** the last instance to let go.
- **Edited tables** are copied first: the editor rebuilds a shared
  table as the instance's own before its first change lands
  (`syncTableDoc`).

The render is bit-identical.

**fy compilation (open).** The rest of every load compiles each
instance's machine source in its own host. Most of that time goes to
clearing the instruction cache once per linked word (`Image.link`,
`registerGeneratedWord`) instead of once per compile. Two steps:
1. **One flush per compile.** This is a change in fy.
2. **Compile once per machine type** and give each instance its own
   state, as the test builds' shared hosts already do
   (`test_hosts`). This first needs a check of what livecoding expects:
   a shared host means that editing the source changes every instance
   of that machine type at once.

**FFT (open).** The table build itself could use precomputed rotation
factors and an optimized build of `wavetable.zig` even in Debug. Since
the cache, this only matters for the first instance.

## Phases

1. **Shared table cache.** Built.
2. **Roots and references.** `src/storage.zig` resolves `project:`,
   `user:`, `factory:` and `lib:` (`lib:` moves here from
   `keymap.resolvePath`). Paths with no prefix become project-relative.
   Slab creates the home folder and writes `settings.json`. slabkit
   writes `factory:` references for shipped assets.
3. **The project package.**
   - Save and load `Song.slab/`, with `tables/` and `recordings/` inside.
   - The asset table with hashes, and collect on save.
   - The fallback on load, and the missing-files list.
   - Clean Up.
   - Convert `songs/`.
4. **The user library.**
   - User presets in the preset menus.
   - Save to Library for presets, tables and clips.
   - `.slabclip`.
   - The browser with Project, User and Factory sources.
5. **Machines in projects and the home folder.** Machine ids resolve
   project → user → factory, and Save to Library works from the code
   view.
6. **Online.** Item manifests, the cache, Publish, and the browser's
   Online source, against the repository once it exists.
