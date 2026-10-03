# Contributing to Slab

Start with [CLAUDE.md](CLAUDE.md) and [docs/README.md](docs/README.md):
the design docs are the plan, and code follows them.

## Before your first pull request

Sign the [Contributor License Agreement](CLA.md). The CLA bot asks you
on your first pull request. Slab is GPL-3.0-or-later (see
[COPYING.md](COPYING.md)); the CLA lets the project keep that and still
ship builds where the GPL alone wouldn't allow it.

## What can go in

- **Code** (the frame, kernels, machines): your own work, or code under
  a GPL-3.0-compatible license, named in [NOTICE](NOTICE).
- **Factory presets, sounds and demos**: CC0. Your own work, or CC0
  sources such as VCSL. Never commercial libraries, hardware ROMs, sounds
  ripped from records or games, or AI-generated audio whose service
  forbids redistributing it as sounds (ElevenLabs Sound Effects, for
  one).
- **Songs**: your own compositions. Name the license in the file.

Sharing machines, presets, packs and projects with other Slab users
goes through publishing (docs/25 §Publishing), not this repository;
the licenses each kind of item may use are listed there.

## Commits

`area: short imperative summary`, one logical change per commit, and
the doc section a commit implements in its summary. See CLAUDE.md
§Commit style.
