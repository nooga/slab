# 25 — Storage: projects, the library, sharing

Where slab keeps what it ships and what users make, how a project names
the files it uses, how a project stays whole when it moves to another
computer, and how anything a user makes becomes something others can
open. **Status: design; phases 1–4 built**
(§Load time, §Roots, the project package in `src/package.zig`, project
and library presets, Save to Library for presets, tables and clips).
Code, as it lands: `src/storage.zig` (roots and references),
`src/document.zig` (the project package), `src/wavetable_cache.zig`.

docs/19 §File references describes the reference forms a project file
uses today. `song.tables/` beside the project stays until phase 3
(the package).

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
  Samples/       the user's own samples, kits, keymaps (.wav, .flac, .sfz, folders)
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
`~/Library/Application Support/Slab/settings.json` (`$SLAB_SETTINGS`).
They are never shared or published.
- **Today it holds** `home`, a moved home folder.
- **Planned:** the audio device, UI zoom, recent projects and the
  collect policy.
- **The app** writes the defaults on first launch, so the file is there
  to edit. A headless render only reads it.

## Packs

A **pack** is a set of samples too large to ship with slab, or not
slab's to ship. Examples:
- **Free:** VCSL, about 6 GB. A few basics from it ship with slab
  instead (two pianos, the FM piano, harpsichord, marimba, kalimba,
  ocarina and three kits, 76 MB of 16-bit mono FLAC in
  `machines/sampler/assets/vcsl/`, made by `tools/library/vcsl_factory.py`):
  the sampler's `vcsl/` bank, and Unfairlight's VCSL presets load the
  same SFZs.
- **Yours to own:** the Fairlight CMI disks, the Reverb drum machine
  collection, a commercial library.

A pack lives in `Library/<pack id>/`, with the layout its importer
expects, and shows up in slab as presets and kits like anything that
ships.

### The pack manifest

Slab knows a pack by its manifest, `<id>.pack.json`. Manifests ship
with slab in `factory:packs/` (`vcsl`, `drum-machines`, `cmi` and
`extract`, the stems model, docs/30 §Stems, read by src/packs.zig), and more can come from the online repository:

```json
{"id": "vcsl", "name": "Versilian Community Sample Library", "version": "2024.1",
 "license": "CC0-1.0", "redistributable": true, "size": 6100000000,
 "get": {"download": [{"url": "https://github.com/sgossner/VCSL/archive/<commit>.zip", "sha256": "…"}]},
 "index": {"url": "slab:@slab/vcsl-index@3", "sha256": "…"}}
```

```json
{"id": "cmi", "name": "Fairlight CMI disks", "redistributable": false,
 "get": {"supply": {"into": "_sources",
   "expect": [{"name": "IIx v1.4 library", "glob": "**/*.VC", "min": 100},
              {"name": "Series II WAV dumps", "glob": "**/*.wav"}],
   "help": "Copy your disk images, or the folders you have them in, here."}},
 "import": "cmi"}
```

- **`get`** says how the files arrive, in one of three ways:
  - `download`: URLs, each pinned by hash. A URL can be https, a git
    archive, or a `slab:` item. Mirrors are listed in order.
  - `supply`: the user brings the files. The manifest lists what
    slab should find, and where to put it.
  - `instructions`: text and a link, for packs bought elsewhere. After
    buying, the pack is a `supply` pack.
- **`index`** holds the files that make a pack playable:
  - **What's in it:** the generated SFZs, kits, presets and catalog,
    everything `tools/library/*.py` writes today.
  - **Where it comes from:** for a known collection, the index ships
    ready-made, keyed to the files' hashes. Installing then means only
    fetching or finding the samples, with nothing to run on the
    user's machine.
- **`import`** names a slab importer, built into the app (not Python),
  for files the index can't predict. Examples: a supply pack whose
  hashes don't match a known collection, or the user's own folder of
  disks. The importer writes the same index that a ready-made one
  would.

Besides these, a manifest has `about` (a line for its card), `link`
(the maker's page) and `size` (the download, in bytes). An expectation
can list more patterns in `also`, and `"any": true` makes the pack
ready when any one is met rather than all.

References in projects and presets never use URLs: they stay
`lib:<id>/…`. URLs appear only in pack manifests, so a project never
breaks because a server moved.

### Installing

The browser's Library page lists every pack slab knows of, one card
each, in one of these states:

| State | The card offers |
|---|---|
| Available (download) | **Download** with the size. Slab fetches, checks hashes, unpacks into `Library/<id>/`, and installs the index. Progress is on the card, and a cancelled or broken download resumes. |
| Needs your files (supply) | **Show Folder** (creates `Library/<id>/_sources/` and opens it in Finder), the `help` text, and a list of what slab expects and has found so far. Dropping a folder or a zip on the card copies it there. Once the expected files are found, slab imports on its own. |
| Instructions | the text and the link. The card then turns into "Needs your files". |
| Installed | the version, size on disk, **Reveal**, **Remove**, and **Update** when a newer index or version exists |

The layout under `Library/<id>/` is the one the pack's importer writes,
so a pack that is already set up by hand keeps working unchanged. The
CMI and drum-machine folders in the library now are exactly what their
`supply` pack expects: slab finds them and marks the packs installed.

What's built (the PACKS tab, src/packs.zig):
- **Installed** means `Library/<id>/presets/` exists, or `models/` for a
  pack of models (`extract`). A library folder no manifest names is
  listed as installed and the user's own.
- **Needs your files** looks for the expected files in `_sources/`
  every second and a half while the tab is open, and shows the count
  for each. Once they are found, **IMPORT** appears; slab doesn't start
  an import on its own.
- **Importing** still runs the pack's tool from `tools/library/`
  (`vcsl.py`, `drums.py`, `cmi.py --collection disks _sources`) with
  Python 3, as a child process. Its output goes to
  `Cache/packs/<id>.log`, and the card shows the last line, with CANCEL
  and LOG. **DOWNLOAD** on VCSL runs `vcsl.py`, which fetches the
  library at its pinned commit and resumes where it stopped. Slab's own
  downloader (the manifest's `download` URLs, checked by hash) and
  importers replace the tools later in this phase.
- **Installed** cards count the pack's presets and samples and offer
  REVEAL, REMOVE (a second click within three seconds moves the folder
  to the Trash) and IMPORT AGAIN.
- **Not yet:** dropping a folder or zip on a card, Update, and the size
  on disk.

### Pack presets

A pack's presets live in the pack, in
`Library/<id>/presets/<machine id>/…`. Each machine's preset menu adds
installed packs as banks, next to factory and user presets.

A pack's banks keep the names they had when they lived in the repo
(`vcsl-keys/…`, `drums/roland-cr-78/kit`, `cmi-iix/<disk>/<voice>`), so
projects and slabkit songs that name them still find them. A name the
factory doesn't have is looked for in each installed pack
(`presets.locate`), and slabkit's `presets()` reads the packs too.

This replaced the gitignored generated presets in the repo
(`machines/sampler/presets/vcsl-*`, `machines/unfairlight/presets/cmi-*`,
`machines/rack/presets/cmi-*`, …), which existed only on machines that
ran a script, and only inside a checkout. The tools in
`tools/library/` now write into the pack.

### Missing packs

A project's asset entry for a `lib:` file names its pack and version.
Collect on save copies only the files a project uses, so a moved project
normally plays anyway. When a file is missing, the track says which pack
to install, with a button that opens its card. It never just goes
silent.

A project that collected files from a pack that isn't redistributable
still plays on its owner's machines. Sending that project to someone
else is the user's call, but Publish refuses those files (§Licenses).

## The project package

A project is a folder that Finder shows as a single file:

```
Song.slab/
  project.json    the document (docs/19's format, plus "assets")
  tables/         wavetables edited in the project (the editor writes them)
  samples/        files collected for instruments: samples, keymaps, tables
  audio/          audio clips' files: takes recorded into the project, collected audio
  presets/        <machine id>/<name>.preset saved in the project (phase 4)
  machines/       <id>/: machine sources edited for this project (phase 6)
  clips/          .slabclip files the project saved or collected (phase 4)
```

- **Zipping the folder is the export.** Nothing else is needed.
- **Finder treats it as one file** once Slab.app is on the Mac
  (`tools/package_app.sh`): its Info.plist exports `.slab` as a document
  package (`com.nooga.slab.project`, conforming to `com.apple.package`),
  and double-clicking opens slab (`src/native_app.m`). Without the app
  Finder shows a folder, and the open panel accepts `.slab` folders.
- **It stays diffable:** `project.json` is plain JSON, so git and
  slabkit work on it as they do now.
- **A bare `.slab` JSON file still opens.** Its relative paths are
  relative to its folder. Saving it from the app makes it a package: the
  file moves inside as `project.json` first, so a failed save loses
  nothing. slabkit writes packages, and `songs/` and `demos/` are
  packages.
- **This replaces two earlier layouts:**
  - The wavetable editor writes to `tables/` in the package, not to
    `song.tables/` beside it. An old sidecar's tables are collected into
    `samples/` on the next save.
  - Takes are recorded into the package's `audio/`, or into
    `<home>/Cache/recordings/` while the project is unsaved (or a bare
    file), and collected from there. A take never overwrites an earlier
    one.
- **Saves are atomic:** `project.json` is written to
  `project.json.saving` and renamed into place.

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
  them any more.** **File → Clean Up Project Files** saves the project,
  then moves the files in `tables/`, `samples/` and `audio/` that its
  asset table doesn't name to the Trash.
- **Where copies go:**
  - A pack file keeps its pack path: `samples/vcsl/Marimba/…`.
  - A single file goes by its name: `samples/hit.wav`.
  - An SFZ or a folder kit goes in a folder of its own, with its layout
    kept: `samples/kit/kit.sfz` and `samples/kit/smp/a.wav`.
  - A different file under a name that's already taken goes beside it:
    `samples/2/hit.wav`.
- **Collecting is the default.** The settings can turn off collecting
  for `lib:` (`"collect_lib": false` in settings.json): projects stay
  small, and only open where that pack is installed. They can't turn it off for `user:`, because a project
  that points into someone's home folder never works for anyone else.
- **Save stays fast:** hashing and copying happen only for references
  that changed since the last save.

This is a project-save step and only that. `document.serialize` also
makes undo snapshots, so it never touches files (the same reason the
wavetable editor's tables are written in `saveProject`, docs/15).

### Load

Collecting rewrites each reference to the package's copy, so a moved
project finds its files without a fallback. Loading checks that each
referenced file exists:
- **Missing files** load empty, as before (docs/19 §Where loading fails
  silently).
- **The status bar** says how many are missing and names the first.
- **The log** lists them all.

Planned:
1. **Verify factory files by hash on load.** A `factory:` file whose
   hash differs would be looked up among the factory's retired files
   (§Factory files never change).
2. **Fall back to a copy elsewhere** with the same hash.
3. **A disk hash cache.** Hashes are cached for the session (by path,
   size and modification time) so a save hashes each file once; a disk
   cache in `Cache/hashes` would carry that across sessions.

### Undo across projects

Open and New Project are undoable: ⌘Z after opening B brings back A,
the project it replaced. A step that switches projects carries the
project it left (src/history.zig `pushSwitch`), its path and whether
it was chosen or untitled, so undoing it restores all of A, not only
its tracks:
- **The title and file tile** name A again.
- **⌘S** saves to A's path, or asks where for an untitled project.
- **References** resolve against A's folder (`storage.setProject`),
  set before the snapshot is applied.

Redo carries the project undo left, so ⇧⌘Z opens B again. Edits keep
their plain snapshots: history is linear, so an edit's step always
belongs to the project that's open when it's reached.

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

Preset menus list three sources together (`src/presets.zig`):
- **Factory presets:** by their own names and banks, read-only in the
  app.
- **The Project bank:** the open package's `presets/<machine>/`.
- **The User bank:** `user:Presets/<machine>/`.

Saving:
- **Save preset…** writes to the project's bank, so a sound made for one
  song stays with the song. A project that isn't saved yet has no
  package, so its presets go to the User bank instead, and the status
  line says so.
- **Save to Library…** writes to the User bank.
- **Rename** works only in the Project and User banks.
- **Save As** to another package copies `presets/` along.
- **A Project-bank preset** names the package's files relative to it.
- **A library preset** takes copies of the files only the project has,
  into `Wavetables/` or `Samples/`.

Built so far:
- **Presets:** above.
- **Wavetables:** the editor's LIBRARY button writes a copy to
  `user:Wavetables/<name>.wav`, never over another. The oscillator keeps
  the project's table.
- **Clips:** the arrangement's **Save to Library** writes each selected
  clip to `user:Clips/<name>.slabclip`, as
  `{"slab": "clip", "schema": 1, "clip": {…}}`. The clip is in docs/19's
  form at beat 0; an audio clip's package-only file is copied to
  `user:Samples/`. `document.insertClipFile` puts one on a track; the
  browser will call it.
- **Not yet:** machines (phase 6), and the browser.

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

The browser is the app's left column (BROWSE in the transport bar,
⌘⌥B; ⌘F searches). src/library.zig finds the items, src/ui/browser.zig
lists them; the gallery's BROWSER page is where its look was tried out.

| Kind | Project | User | Factory | Pack |
|---|---|---|---|---|
| preset | `presets/<id>/` | `Presets/<id>/` | `machines/<id>/presets` | `Library/<pack>/presets/<id>/` |
| wavetable | `tables/` | `Wavetables/` | machine assets with a `clm ` chunk | |
| clip | | `Clips/` | `clips/` | |
| sample | `audio/` | `Samples/`, a group per folder | | `Library/<pack>/`, a group per folder |
| song | | `Projects/` | `demos/`, `songs/` | |

- **Finding.** Search as you type: any letter while the browser has
  focus, or ⌘F. Every word must match the name, the folder or the kind.
  Source tabs and kind chips narrow it; the chips count what matches.
  ★ narrows to favorites, kept in `favorites.txt` beside settings.json.
- **Moving.** Folders fold (⌥-click folds all); ↑↓ ←→ ↩ Esc; click,
  ⇧-click and ⌘-click select.
- **Previewing.** A sample plays through the engine's preview voice
  (src/preview.zig), on ▶ or as it's selected while AUTO is on. The
  preview pane draws a sample's waveform, a table's frames or a clip's
  notes, with the item's reference (a click copies it).
- **Dropping.** Every drop is one Undo step:

  | Item | Lane | Header, or the machine bay | Below the tracks |
  |---|---|---|---|
  | preset | loads on the track | loads on the track | a new track with it |
  | wavetable | | the first oscillator plays it (an empty track gets Concoction) | |
  | clip, sample | at the beat under the pointer, one after another | at the track's end | a new track with them |
  | song | opens it (undoable, like Open: §Undo across projects) | | |

  An instrument preset replaces the track's machine when it is another;
  an effect preset joins the chain. ↩, a double-click or LOAD drops on
  the selected track.

Clips dragged from the arrangement onto the browser are saved to
`Clips/` (Save to Library) and stay where they were. Rows show an
item's own name; the path is in the tooltip and the preview's
reference.

The PACKS tab has a card for each pack (§Installing). ONLINE waits for
phase 7.

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

### Licenses for shared items

Every published item names its license as an SPDX id in its manifest,
and Publish refuses a license its kind doesn't allow. The rules keep
everything shared usable in anyone's music:

| Kind | License | Why |
|---|---|---|
| machine (fy code) | `GPL-3.0-or-later` | It's code: the best ones can become factory machines, and improvements stay open. The Slab Machine Exception (COPYING.md) means a machine's author could choose otherwise, but the repository takes GPL only. |
| preset | `CC0-1.0` | Settings: they flow into anyone's music and into the factory banks. |
| sample, table, pack | `CC0-1.0` (default) or `CC-BY-4.0` | Any release can use them. No NC, SA or ND: a non-commercial sample can't go on a record, and share-alike would reach the song. A CC-BY pack's credit line shows on its card, and exporting a project that uses one lists the credits it owes. |
| project | `CC-BY-4.0` (default), `CC-BY-SA-4.0`, `CC-BY-NC-4.0`, `CC-BY-NC-SA-4.0` or `CC0-1.0` | A song is its author's. They decide whether others may release remixes; anyone may open it and learn from it. |

- **The name and look are not licensed:** an item may say it is "for
  Slab" but not use the Slab name or logo as its own branding.
- **What can't be published at all:** files from a pack that isn't
  redistributable (§Licenses), hardware ROMs, commercial libraries, and
  AI-generated sounds whose service forbids redistributing them as
  sounds (ElevenLabs Sound Effects, among others).
- **AI-made sounds that may be shared** are those whose tool lets the
  maker own the output and redistribute it (Stable Audio 3 run locally,
  which made the Unfairlight factory voices, for one). The item's note
  names the tool, the prompt and the seed.

The repository itself (accounts, search, the server API) is a separate
design. This doc only fixes what slab sends and receives, so that
local projects and libraries can be built now without changing their
format when the online part lands.

## Formats

Every file slab writes says what it is and which version of its format
it uses.
- **JSON files** open with `"slab": "<kind>"` and `"schema": <n>`, in
  that order.
- **Binary files** carry a marker of their own.

| File | Tag | Schema | Since |
|---|---|---|---|
| `project.json`, a bare `.slab` | `"slab": "project"` | 1 | built |
| `settings.json` | `"slab": "settings"` | 1 | built |
| `.preset` | `"slab": "preset"` | 1 | built (shipped and generated presets tagged) |
| `.slabclip` | `"slab": "clip"` | 1 | built |
| `<id>.pack.json` | `"slab": "pack"` | 1 | built |
| `item.json` (published items) | `"slab": "item"` | 1 | phase 7 |
| editor wavetables (`.wav`) | the `clm ` chunk's `(slab levels kept)` | — | built |

Loaders:
- **A tag naming another kind:** the file is refused. A preset opened as
  a project fails to open; it doesn't load as an empty song.
- **No tag:** the file is taken as the kind it was opened as. This
  covers hand-written files and the examples in these docs.
- **A newer schema:** slab loads what it understands and says so: a
  project's status line reads "made by a newer slab".
- **An older schema:** a loader-side migration in one place per format
  brings it up to date. None exists yet, because every format is still
  at 1.
- **When to bump:** a schema goes up when a field changes meaning. A new
  optional field doesn't need a bump, since older loaders ignore what
  they don't know.
- **Pre-1.0:** we still change formats freely and rewrite the shipped
  files rather than carry migrations (AGENTS.md).

The asset table and a Rack's state are parts of a project or a preset
and carry no version of their own.

## Load time

Measured on 2026-10-02 with debug builds and `--render` (load = total
time − render time):

| Song | Before | Table cache | + fy flush range | + shared hosts |
|---|---|---|---|---|
| a bass study (23 Concoctions) | 20.9 s | 7.7 s | 6.2 s | 4.0 s |
| `voltage_riot` | ~4.5 s | ~4.5 s | 4.1 s | 2.3 s |

**Wavetables (fixed).** Every Concoction built its own copy of every
table it declares, at 12 FFTs a frame. For the bass study that was 46
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

**fy's instruction-cache flush (fixed in fy).** fy flushed the whole
image, from its start to the newest word, after every word it linked.
It also re-protected the whole 64 MB range each time. That made a
compile quadratic in the code already linked. Now:
- **Each link flushes only what it wrote,** and the image is mapped
  RWX once.
- **Fy.holdFlush / releaseFlush** defer flushes across a batch.
  Linking then only widens a pending range, and the release flushes it
  in one pass.
- **Code is never run stale:**
  - Anything fy runs while held flushes first: wrappers, `jit`,
    constants, macros.
  - A trampoline patch also flushes first, so new code is never
    reachable before it is flushed.
- **Slab holds flushes around each `compileFile`.** `--flush-each`
  turns this off.

The range fix did the work. Holding saves almost nothing on top of it
(3.8 s vs 4.0 s for the bass study with `--flush-each`, within the
noise). It stays because it costs nothing and helps on larger images.

**Shared machine hosts (built).** Every instance used to compile its
machine source in a host of its own. Now instances of one machine type
share one compiled host from `host_cache`
(`src/machines/fy_raw_machine.zig`):
- **What stays per instance:** each instance still has its own
  descriptor, state, params, buffers and callers.
- **The registry's manifest read** comes off the same host, so slab
  compiles each machine type once.
- **Hosts are kept after their last instance goes,** so reopening a
  project compiles nothing.
- **Livecoding still works:** a host is recompiled when any file it
  compiled changes on disk (the machine file, and everything it
  includes, from fy's `file_ns_map`). An edit then reaches the next
  instance. Instances made before the edit keep the old host until
  they go.
- **Concurrent rendering is safe:** a dsp body uses only the machine
  stack and its own slots, and the current-instance pointer is
  thread-local. Renders with the cache are bit-identical to renders
  without it, on the worker pool.
- **`--no-machine-cache`** compiles every instance on its own, as
  before.

**What's left** is compiling each machine type once, about 100 ms each
in Debug. A release build is several times faster.

**FFT (open).** The table build itself could use precomputed rotation
factors and an optimized build of `wavetable.zig` even in Debug. Since
the cache, this only matters for the first instance.

## Phases

1. **Load time.** The shared table cache, fy's batched flush and the
   shared machine hosts are built.
2. **Roots and references.** Built.
   - `src/storage.zig` resolves `project:`, `user:`, `factory:` and
     `lib:` (moved from `keymap.resolvePath`).
   - Paths with no prefix are project-relative, and in memory every
     file is its absolute path.
   - A project save writes the most specific root, and the
     project-relative form only for files in the project's folder.
   - Slab creates the home folder and writes `settings.json` (its
     `home` moves the home folder).
   - slabkit writes references (`ref`, `resolve` in `machines.py`),
     and `songs/` uses them.

3. **The project package.** Built.
   - `Song.slab/` with `tables/`, `samples/` and `audio/`, and bare
     files converted on save.
   - The asset table with hashes, collect on save, and the
     missing-files report.
   - Clean Up.
   - `songs/` and `demos/` converted, and slabkit writes packages.
   - Open: hash checks on load, the factory's retired files, and the
     disk hash cache (§Load).
4. **The user library.**
   - Project and User presets in the preset menus. Built.
   - Save to Library for presets, tables and clips. Built.
   - `.slabclip`. Built.
   - The browser with Project, User and Factory sources, sample
     audition and drops onto the arrangement and the machine bay. Built.
5. **Packs.**
   - Pack manifests in `factory:packs/`, and the Library page with
     download, supply and instructions. Built, with the Python tools as
     the importers (§Installing).
   - Pack presets in the preset menus, replacing the gitignored
     generated presets. Built.
   - Slab's own downloader: the manifest's URLs, hashes, resume.
   - Ready-made indexes for VCSL, the CMI disks and the drum machines.
   - Importers in slab.
6. **Machines in projects and the home folder.** Machine ids resolve
   project → user → factory, and Save to Library works from the code
   view.
7. **Online.** Item manifests, the cache, Publish, and the browser's
   Online source, against the repository once it exists.
