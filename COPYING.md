# Copying Slab

Slab is free software. This file says which license covers which part
of this repository and of the app built from it. Third-party notices
are in [NOTICE](NOTICE).

Copyright (C) 2026 Marcin Gasperowicz and the Slab contributors.

## What is under which license

| Part | License |
|---|---|
| Everything not listed below: the frame (`src/`), the kernels (`kernels/`), the machines' code (`machines/*/*.fy`, `machines/lib/`), tools, docs, tests | [GPL-3.0-or-later](LICENSE), with the [Slab Machine Exception](#slab-machine-exception) |
| Factory presets: `machines/*/presets/` | [CC0-1.0](LICENSES/CC0-1.0.txt) |
| Factory sounds and tables: `machines/*/assets/` | [CC0-1.0](LICENSES/CC0-1.0.txt) |
| Demo projects: `demos/` | [CC0-1.0](LICENSES/CC0-1.0.txt) |
| Songs: `songs/` (the compositions, their scripts and projects) | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/), Marcin Gasperowicz |
| The Slab name, the wordmark (`slab.png`), the app icon (`tools/app/icon.png`), the splash (`splash.png`) | Not licensed. See [The name and the look](#the-name-and-the-look) |
| `vendor/` and code ported from elsewhere | Their own licenses. See [NOTICE](NOTICE) |

CC0 means the factory presets and sounds are in the public domain:
use them in any music, released anywhere, sold or free, with no credit
owed. Music you make with Slab is yours. No license here reaches it.

## Slab Machine Exception

Additional permission under GNU GPL version 3 section 7.

Slab loads **machines**, **presets**, **projects** and **packs** that
people write and share: fy source files that declare a machine and its
kernels, preset and project files, and collections of them with their
samples and tables. These use Slab's machine interface: the words,
structures and kernels defined in `machines/lib/` and `kernels/`, which
a machine includes and calls.

As a special exception, the copyright holders of Slab give you
permission to write, combine and distribute machines, presets, projects
and packs that use Slab's machine interface under terms of your choice,
without those works becoming subject to the GPL because they include,
call or are loaded by Slab's machine interface.

This permission does not cover:

- Slab itself, or modified versions of it.
- Copies or modified versions of Slab's own source files, including the
  files in `machines/lib/`, `kernels/` and the factory machines. A
  machine that copies a factory kernel's code into itself, rather than
  including the unmodified file, carries that code under the GPL.

You may remove this additional permission from your copy of any part of
Slab, as section 7 of the GPL allows. When you distribute a modified
version of Slab, you may extend this exception to your version, but you
are not obliged to.

## The name and the look

The GPL and CC0 grant rights to the code and the content. They grant no
rights to the name "Slab", the wordmark, the app icon or the splash
image, which identify the official builds. A fork must use its own name
and look. Saying that a machine, preset or pack is "for Slab" is fine.

## Source for the app

Each release of the app is built from a tag in this repository
(`tools/release.sh`), together with the fy runtime at the commit named in
the release notes (https://github.com/nooga/fy, MIT). Those two
repositories at those commits are the complete corresponding source.

## Contributing

Contributions are accepted under the [Contributor License Agreement](CLA.md).
See [CONTRIBUTING.md](CONTRIBUTING.md).
