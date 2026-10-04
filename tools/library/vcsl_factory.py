#!/usr/bin/env python3
"""vcsl_factory.py - build the VCSL instruments that ship with slab.

A few basics from the Versilian Community Sample Library (CC0) ship as
factory samples so they play without the 6 GB pack: two pianos, the FM
piano, a harpsichord, mallets, an ocarina and three drum kits.  The rest
of VCSL stays a download (packs/vcsl.pack.json).

This reads the SFZs that vcsl.py made in the library (run it first, with
--only for these instruments), converts every sample to 16-bit mono FLAC
at 44.1 kHz, whole, into machines/sampler/assets/vcsl/<name>/, writes
<name>.sfz beside them, and a sampler preset per instrument into
machines/sampler/presets/vcsl/.  Unfairlight's presets point at the same
SFZs; it makes its voice RAM from them when it loads.  Needs sox.

  tools/library/vcsl_factory.py
"""

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vcsl  # noqa: E402

SLAB = vcsl.SLAB
ASSETS = os.path.join(SLAB, "machines/sampler/assets/vcsl")
PRESETS = os.path.join(SLAB, "machines/sampler/presets/vcsl")

# the library SFZ -> the factory name
FACTORY = {
    "vcsl-keys/upright-piano-yamaha": "upright-piano",
    "vcsl-keys/grand-piano-kawai": "grand-piano",
    "vcsl-keys/fm-piano": "fm-piano",
    "vcsl-keys/harpsichord-french": "harpsichord",
    "vcsl-mallets/marimba": "marimba",
    "vcsl-mallets/kalimba-kenya": "kalimba",
    "vcsl-winds/ocarina-typical-sus": "ocarina",
    "vcsl-kits/acoustic-kit": "acoustic-kit",
    "vcsl-kits/studio-kit": "studio-kit",
    "vcsl-kits/latin-kit": "latin-kit",
}


def convert(src, dst):
    subprocess.run(["sox", src, "-b", "16", "-c", "1", "-r", "44100", dst], check=True)


def build(lib, src_name, name):
    sfz = os.path.join(lib, src_name + ".sfz")
    out = os.path.join(ASSETS, name)
    os.makedirs(out, exist_ok=True)
    lines, files = [], {}
    for line in open(sfz):
        line = line.rstrip("\n")
        m = re.search(r"sample=(.+)$", line)
        if not m:
            lines.append(line)
            continue
        src = os.path.normpath(os.path.join(os.path.dirname(sfz), m.group(1)))
        if src not in files:
            files[src] = f"{len(files) + 1:03d}-{os.path.basename(src)[:-4].replace(' ', '_')}.flac"
            dst = os.path.join(out, files[src])
            if not os.path.exists(dst):
                convert(src, dst)
        lines.append(line[: m.start()] + f"sample={name}/{files[src]}")
    lines.insert(2, "// shipped with slab as 16-bit mono FLAC at 44.1 kHz (tools/library/vcsl_factory.py)")
    with open(os.path.join(ASSETS, name + ".sfz"), "w") as f:
        f.write("\n".join(lines) + "\n")
    # the pack's preset for this SFZ, pointed at the factory copy
    pre = json.load(open(os.path.join(lib, "presets/sampler", src_name + ".preset")))
    pre["assets"] = {"smp": f"factory:machines/sampler/assets/vcsl/{name}.sfz"}
    with open(os.path.join(PRESETS, name + ".preset"), "w") as f:
        json.dump(pre, f)
        f.write("\n")
    size = sum(os.path.getsize(os.path.join(out, f)) for f in os.listdir(out))
    print(f"{name}: {len(files)} samples, {size / 1e6:.1f} MB", flush=True)
    return size


def main():
    lib = os.path.join(vcsl.library_root(), "vcsl")
    os.makedirs(PRESETS, exist_ok=True)
    total = sum(build(lib, s, n) for s, n in FACTORY.items())
    print(f"total {total / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
