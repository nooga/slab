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

Pre-code. Design documents only. Start at [docs/README.md](docs/README.md).

## Layout

```
build.zig, build.zig.zon     zig build system
src/                         zig host (stub)
docs/                        design docs — read these first
```

## Building

```sh
zig build              # build
zig build run          # build and run the stub
zig build test         # run unit tests
```

### Zig version

Needs **zig >= 0.16** (see `build.zig.zon`). Earlier 0.15.x on macOS 26
fails to link its own build runner against libSystem because of
missing libc stubs for that OS.

## Not in scope (yet)

Plenty. See [docs/10-roadmap.md](docs/10-roadmap.md) for what we're
building first vs. what we're explicitly deferring.
