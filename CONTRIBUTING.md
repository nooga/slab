# Contributing to Slab

Start with [CLAUDE.md](CLAUDE.md) and [docs/README.md](docs/README.md):
the design docs are the plan, and code follows them.

## Before your first pull request

Sign the [Contributor License Agreement](CLA.md). The CLA bot asks you
on your first pull request, and you sign by posting the comment it
quotes. Slab is GPL-3.0-or-later (see [COPYING.md](COPYING.md)). The
CLA lets the Maintainer license Slab, your contributions included,
under other terms too, including terms that are not open source;
releases already made under the GPL stay available under it. You keep
your copyright.

## What can go in

- **Code** (the frame, kernels, machines): your own work, or code under
  a GPL-3.0-compatible license, named in [NOTICE](NOTICE).
- **Factory presets, sounds and demos**: CC0. Your own work, or CC0
  sources such as VCSL. Never commercial libraries, hardware ROMs, sounds
  ripped from records or games, or AI-generated audio whose service
  forbids redistributing it as sounds (ElevenLabs Sound Effects, for
  one). AI-made sounds are fine when the tool lets you own the output
  and redistribute it (the Unfairlight factory voices come from Stable
  Audio 3, run locally): name the tool, prompt and seed in the preset's
  note.
- **Songs**: your own compositions. Name the license in the file.

Sharing machines, presets, packs and projects with other Slab users
goes through publishing (docs/25 §Publishing), not this repository;
the licenses each kind of item may use are listed there.

## Commits

`area: short imperative summary`, one logical change per commit, and
the doc section a commit implements in its summary. See CLAUDE.md
§Commit style.
