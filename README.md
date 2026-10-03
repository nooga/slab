# Slab

**Slab Audio Workstation — SAW.**

An eclectic, livecodable DAW. Zig owns the frame (transport, mixer,
timeline, piano roll, automation, UI widget library, audio I/O, final
mix). [fy](../fy) owns every machine inside the frame — synths, effects,
note transformers, custom panels. Edit a machine's source while it
plays and the next audio block runs the new code.

Brutalist grey, 1px bevels, serious tool.

- Domain: [slab.audio](https://slab.audio) *(to be registered)*
- Platform: macOS on Apple Silicon only (fy's JIT is aarch64-specific)
- License: open source *(license TBD)*

## Status

Working prototype. The Zig host now has audio I/O, transport,
arrangement clips, piano-roll editing, a compact immediate-mode UI,
fy-authored machines, per-track machine instantiation, and basic loop
playback. It is still early and intentionally rough: save/load and
undo/redo exist for the arrangement document, but fy panel parameter
state is not serialized yet; loop wrapping is not sample-accurate, and
livecoding propagation to per-track fy instances is not complete.

Start at [docs/README.md](docs/README.md), especially the current
status in [docs/10-roadmap.md](docs/10-roadmap.md) and session notes in
[docs/sessions/](docs/sessions/).

## Layout

```
build.zig, build.zig.zon     zig build system
src/                         zig host: audio, transport, UI, engine
machines/                    fy machine sources and shared fy helpers
docs/                        design docs and session notes
vendor/                      miniaudio + icon font assets
```

## Building

```sh
zig build              # build
zig build run          # build and run Slab
zig build test         # run unit tests
```

### The app

```sh
tools/package_app.sh          # zig-out/Slab.app
tools/package_app.sh --dmg    # and zig-out/Slab-<version>.dmg
tools/package_app.sh --zip    # and zig-out/Slab.zip
tools/release.sh              # GitHub release v<build.zig.zon version>
```

A ReleaseFast build bundled with the factory files (machines, kernels,
packs, demos), raylib in `Contents/Frameworks`, and the icon from
`tools/app/icon.png` (drawn by `tools/app/make_icon.py`). Ad-hoc signed
with the JIT entitlements in `tools/app/entitlements.plist`, so it opens
on this Mac; a downloaded copy has to be allowed once under System
Settings > Privacy & Security > Open Anyway (no Developer ID or
notarization yet). Installing with curl skips that, since curl doesn't
quarantine what it downloads:

```sh
curl -fsSL https://github.com/nooga/slab/releases/latest/download/install.sh | bash
```

### Zig version

Needs **zig >= 0.16** (see `build.zig.zon`). Earlier 0.15.x on macOS 26
fails to link its own build runner against libSystem because of
missing libc stubs for that OS.

## Not in scope (yet)

Plenty. See [docs/10-roadmap.md](docs/10-roadmap.md) for what we're
building first vs. what we're explicitly deferring.
