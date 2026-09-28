#!/usr/bin/env python3
"""drums.py - classic drum machine kits for the sampler, from Reverb's
free "Drum Machines: The Complete Collection".

Bring the collection yourself (free with a Reverb account,
https://reverb.com/item/15980096-reverb-drum-machines-the-complete-collection)
and unpack it into $SLAB_LIBRARY/drum-machines/_sources/ (default
~/Music/Slab/Library). Slab ships none of it. Then

  tools/library/drums.py            write every machine's kits
  tools/library/drums.py --list     what each machine has, nothing written

For each machine with one-shots (loop-only packs are skipped):

  kit      every sound on its General MIDI key (kick 36, snare 38, hats
           42/44/46 choking each other, toms 41-50 low to high by pitch,
           crash 49, ride 51, cowbell 56, congas 62-64, ...), the best
           "middle" variant of each; Soft/Mid/Hard/Loud and Accent takes of
           one sound become its velocity layers; other variants go on keys
           84 and up
  kicks, snares, toms, ...
           for a sound with four or more variants (the 808's and 909's tone
           and decay grids): every variant, one a key from 36

SFZ files land in lib:drum-machines/kits/<machine>/, sampler presets in
machines/sampler/presets/drums/<machine>/ (gitignored). A kit's level is
set so its loudest main sound peaks at -6 dBFS; the balance inside a kit
is the machine's own. Levels are cached in drum-machines/analysis.json.
"""

import argparse
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vcsl  # noqa: E402  (its WAV reader, preset writer and sampler defaults)

import numpy as np  # noqa: E402

TARGET_PEAK_DB = -6.0
EXTRA_KEYS = list(range(84, 128))
TOM_KEYS = [41, 43, 45, 47, 48, 50]
HAT_ROLES = ("chh", "ohh")

# role, pattern; a name's role is the pattern matching earliest in it
# ("Kick-Hat" is a kick), the longer match on a tie ("Hat Open" is open)
ROLES = [
    ("ohh", r"\bohh?\b|hats? open|hi ?hat open|open hat"),
    ("chh", r"\bchh?\b|hats? clos\w*|hat close|hi ?hats?\d*|\bhh\d*\b|hats? (?:med|accent)\w*|\bhats?\b"),
    ("clap", r"clap\w*|\bhc\b|\bsnap\b"),
    ("rim", r"rim ?shot\w*|\brim\w*|side ?stick|^stick\b|\brs\b"),
    ("kick", r"kick\w*|\bbd\b|bass ?drum"),
    ("snare", r"snare\w*|\bsn\b|\bsd\b|rapid snare"),
    ("tom", r"\btom\w*|\b[lmh]t\b"),
    ("crash", r"crash\w*|cymbal\w*|\bcc\b|\bcy\b"),
    ("ride", r"ride\w*|\brc\b"),
    ("cowbell", r"cow ?bell\w*"),
    ("tamb", r"tamb\w*"),
    ("cabasa", r"cabasa\w*"),
    ("shaker", r"shak\w*|maraca\w*"),
    ("clave", r"clav\w*"),
    ("block", r"\w*block\w*"),
    ("conga", r"conga\w*"),
    ("bongo", r"bongo\w*"),
    ("timbale", r"timbale\w*"),
    ("guiro", r"guiro\w*"),
    ("quijada", r"quijada"),
]
SKIP = re.compile(r"loop|pattern|groove|\bbeat\b|\bfill\b", re.I)
GM = {"kick": [36, 35], "snare": [38, 40], "rim": [37], "clap": [39], "chh": [42, 44], "ohh": [46],
      "crash": [49, 57, 52, 55], "ride": [51, 59, 53], "tamb": [54], "cabasa": [69], "shaker": [70],
      "clave": [75], "block": [76, 77], "timbale": [65, 66], "guiro": [73, 74], "quijada": [58]}
# drums pitched in positions: where each position goes
POSITIONS = {"conga": {"hi": 63, "mid": 62, "low": 64}, "bongo": {"hi": 60, "mid": 60, "low": 61},
             "cowbell": {"hi": 56, "mid": 56, "low": None}}
POS_WORDS = {"low": "low", "lo": "low", "lt": "low", "mid": "mid", "med": "mid", "mt": "mid",
             "hi": "hi", "high": "hi", "ht": "hi"}
LEVELS = {"soft": 0, "mid": 1, "med": 1, "hard": 2, "loud": 2}
ROLE_TITLE = {"kick": "kicks", "snare": "snares", "rim": "rims", "clap": "claps", "chh": "closed-hats",
              "ohh": "open-hats", "tom": "toms", "crash": "cymbals", "ride": "rides", "cowbell": "cowbells",
              "tamb": "tambourines", "conga": "congas", "shaker": "shakers", "perc": "percussion"}


def library_root():
    return vcsl.library_root()


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def machine_name(pack):
    return re.sub(r"^Reverb |\s*Sample Pack$", "", pack).strip()


def sound_name(fname):
    stem = os.path.splitext(fname)[0]
    name = stem.split("_", 1)[1] if "_" in stem else stem
    return re.sub(r"[\s.]+$", "", name.replace("_", " ").strip())


def role_of(name):
    low = name.lower()
    best = None
    for role, pat in ROLES:
        m = re.search(pat, low)
        if m and (best is None or (m.start(), -(m.end() - m.start())) < best[0]):
            best = ((m.start(), -(m.end() - m.start())), role)
    return best[1] if best else "perc"


def level_split(name):
    """(the sound without its level, level rank): Accent tops the layers,
    a trailing Soft/Mid/Hard/Loud ranks under it. "Cowbell Accent2" is the
    accent of "Cowbell2"."""
    words = name.split()
    rank = 1
    out = []
    for i, w in enumerate(words):
        wl = w.lower()
        m = re.fullmatch(r"accent(\d*)", wl)
        if m:
            rank = 3
            if m.group(1) and out:
                out[-1] += m.group(1)
            continue
        out.append(w)
    # a hat's "Med" is how far it's open, not how hard it was hit
    if len(out) > 1 and out[-1].lower() in LEVELS and rank != 3 and role_of(" ".join(out)) not in HAT_ROLES:
        rank = LEVELS[out[-1].lower()]
        out = out[:-1]
    return " ".join(out), rank


def position_of(name):
    for w in re.split(r"[\s.\-]+", name.lower())[1:] + re.split(r"[\s.\-]+", name.lower())[:1]:
        if w in POS_WORDS:
            return POS_WORDS[w]
    return None


def middleness(name):
    """Higher for the variant a kit should lead with: middle settings,
    unmodded, the first of a numbered set."""
    low = name.lower()
    mids = len(re.findall(r"\b(?:mid|med)\b", low))
    num = re.search(r"(\d+)\s*$", low)
    n = int(num.group(1)) if num else 1
    # a rhythm box's combined hits ("Kick Hat") yield to the plain sound
    combo = len(re.findall(r"\b(?:hat|cymbal|cowbell|bongo|perc|click|shaker|ohh)\b", low.split(" ", 1)[1] if " " in low else ""))
    return mids * 2 - (5 if "mod" in low else 0) - (1 if n > 1 else 0) - 3 * combo - n * 0.01 - len(low) * 0.001


class Sound:
    """One sound: its velocity layers, [(rank, path)] soft to loud."""

    def __init__(self, name, role):
        self.name, self.role, self.layers = name, role, []
        self.peak = 0.0
        self.centroid = 0.0

    def label(self):
        return slug(self.name)


def scan(pack_dir):
    sounds = {}
    for dp, ds, fs in os.walk(pack_dir):
        ds.sort()
        for f in sorted(fs):
            if not f.lower().endswith(".wav"):
                continue
            name = sound_name(f)
            if SKIP.search(name):
                continue
            base, rank = level_split(name)
            key = base.lower()
            s = sounds.get(key)
            if s is None:
                s = sounds[key] = Sound(base, role_of(base))
            s.layers.append((rank, os.path.join(dp, f)))
    for s in sounds.values():
        s.layers.sort()
    return list(sounds.values())


def analyse(sounds, cache):
    for s in sounds:
        for _, p in s.layers:
            st = os.stat(p)
            k = f"{p}|{st.st_size}|{int(st.st_mtime)}"
            if k not in cache:
                x, sr = vcsl.read_wav(p)
                head = x[:int(sr * 0.25)]
                spec = np.abs(np.fft.rfft(head * np.hanning(len(head)))) if len(head) > 16 else np.zeros(2)
                f = np.fft.rfftfreq(len(head), 1 / sr) if len(head) > 16 else np.zeros(2)
                cen = float((spec * f).sum() / spec.sum()) if spec.sum() > 0 else 0.0
                cache[k] = {"peak": float(np.abs(x).max()) if len(x) else 0.0, "centroid": cen}
            a = cache[k]
            s.peak = max(s.peak, a["peak"])
            s.centroid = s.centroid or a["centroid"]


def place(sounds):
    """{key: Sound} for the kit, and the leftovers in order."""
    keys, used = {}, set()
    by_role = {}
    for s in sounds:
        by_role.setdefault(s.role, []).append(s)
    for role, lst in by_role.items():
        lst.sort(key=lambda s: -middleness(s.name))
        if role == "guiro":  # GM: short guiro 73, long 74
            lst.sort(key=lambda s: "long" in s.name.lower())
    rest = []

    def put(k, s):
        if k is not None and k not in used:
            keys[k] = s
            used.add(k)
            return True
        return False

    for role, lst in by_role.items():
        if role in POSITIONS:
            taken = set()
            for s in lst:
                pos = position_of(s.name) or "mid"
                if pos not in taken and put(POSITIONS[role][pos], s):
                    taken.add(pos)
                else:
                    rest.append(s)
        elif role == "tom":
            # one tom per position (Low/Mid/Hi) or per numbered tom, ordered
            # by pitch (the attack's spectral centroid) onto the tom keys
            heads, seen = [], set()
            for s in lst:
                pos = position_of(s.name)
                num = re.search(r"tom\s*(\d+)", s.name.lower())
                ident = pos or (num.group(1) if num else s.name)
                if ident in seen:
                    rest.append(s)
                    continue
                seen.add(ident)
                heads.append(s)
            if len(heads) > len(TOM_KEYS):
                heads.sort(key=lambda s: s.centroid)
                pick = [heads[round(i * (len(heads) - 1) / (len(TOM_KEYS) - 1))] for i in range(len(TOM_KEYS))]
                rest += [s for s in heads if s not in pick]
                heads = pick
            order = {"low": 0, "mid": 1, "hi": 2}
            if all(position_of(s.name) for s in heads):
                heads.sort(key=lambda s: order[position_of(s.name)])
            else:
                heads.sort(key=lambda s: s.centroid)
            spread = {1: [45], 2: [43, 47], 3: [41, 45, 48], 4: [41, 43, 45, 48], 5: [41, 43, 45, 47, 48]}
            for k, s in zip(spread.get(len(heads), TOM_KEYS), heads):
                put(k, s)
        elif role in GM:
            slots = list(GM[role])
            for s in lst:
                while slots and slots[0] in used:
                    slots.pop(0)
                if slots and put(slots.pop(0), s):
                    continue
                rest.append(s)
        else:
            rest += lst
    # no closed hat (the 808 pack): the shortest open hat stands in
    if 42 not in used:
        short = [x for x in rest if x.role == "ohh" and re.search(r"\b(?:min|short)\b", x.name.lower())]
        if short:
            rest.remove(short[0])
            put(42, short[0])
    extra = [k for k in EXTRA_KEYS if k not in used]
    dropped = []
    for s in sorted(rest, key=lambda s: (s.role, s.name.lower())):
        if extra:
            put(extra.pop(0), s)
        else:
            dropped.append(s)
    return keys, dropped


def regions(keys, gain_db, sfz_dir):
    lines = []
    for k in sorted(keys):
        s = keys[k]
        n = len(s.layers)
        hat = " group=1 off_by=1" if s.role in HAT_ROLES else ""
        for li, (_, p) in enumerate(s.layers):
            lovel, hivel = (128 * li) // n, (128 * (li + 1)) // n - 1
            rel = os.path.relpath(p, sfz_dir)
            lines.append(f"<region> key={k} pitch_keycenter={k} lovel={lovel} hivel={hivel} "
                         f"volume={gain_db:g} loop_mode=one_shot{hat} region_label={s.label()} sample={rel}")
    return lines


def gain_for(sounds):
    pk = max((s.peak for s in sounds), default=0)
    return round(TARGET_PEAK_DB - 20 * math.log10(pk), 1) if pk > 0 else 0.0


def write_kit(path, title, keys, gain_db):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    head = [f"// {title}", "// Reverb Drum Machines (bring your own) - generated by tools/library/drums.py", ""]
    with open(path, "w") as f:
        f.write("\n".join(head + regions(keys, gain_db, os.path.dirname(path))) + "\n")


def preset_params(layered):
    p = dict(vcsl.BASE)
    p.update({"smp-atk": 0.001, "smp-rel": 0.3, "smp-vel": 0.5 if layered else 0.8})
    return p


def build(machine, sounds, root, write=True):
    """Write the machine's kit and palettes; returns [(name, count)]."""
    ms = slug(machine)
    kdir = os.path.join(root, "kits", ms)
    keys, dropped = place(sounds)
    out = []
    gain = gain_for(list(keys.values()))
    if write:
        write_kit(os.path.join(kdir, "kit.sfz"), f"{machine} kit on GM keys", keys, gain)
        layered = any(len(s.layers) > 1 for s in keys.values())
        vcsl.write_preset(os.path.join("drums", ms), "kit", f"{machine}: kit on GM keys",
                          f"lib:drum-machines/kits/{ms}/kit.sfz", preset_params(layered))
    out.append(("kit", len(keys), len(dropped)))
    by_role = {}
    for s in sounds:
        by_role.setdefault(s.role, []).append(s)
    for role, lst in sorted(by_role.items()):
        if len(lst) < 4:
            continue
        lst.sort(key=lambda s: s.name.lower())
        pal = {36 + i: s for i, s in enumerate(lst[:92])}
        name = ROLE_TITLE.get(role, role + "s")
        if write:
            write_kit(os.path.join(kdir, name + ".sfz"), f"{machine}: every {name[:-1]}, one a key from C2", pal,
                      gain_for(lst))
            vcsl.write_preset(os.path.join("drums", ms), name, f"{machine}: every {name[:-1]} from C2",
                              f"lib:drum-machines/kits/{ms}/{name}.sfz",
                              preset_params(any(len(s.layers) > 1 for s in lst)))
        out.append((name, len(pal), 0))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="show each machine's kit, write nothing")
    args = ap.parse_args()
    root = os.path.join(library_root(), "drum-machines")
    src = os.path.join(root, "_sources")
    if not os.path.isdir(src):
        sys.exit(f"no {src}: unpack Reverb's Drum Machines collection there (see --help)")
    cache_path = os.path.join(root, "analysis.json")
    cache = json.load(open(cache_path)) if os.path.exists(cache_path) else {}
    if not args.list:
        import shutil
        shutil.rmtree(os.path.join(vcsl.PRESETS, "drums"), ignore_errors=True)
        shutil.rmtree(os.path.join(root, "kits"), ignore_errors=True)
    kits = 0
    for pack in sorted(os.listdir(src)):
        pdir = os.path.join(src, pack)
        if not os.path.isdir(pdir):
            continue
        sounds = scan(pdir)
        machine = machine_name(pack)
        if not sounds:
            print(f"{machine}: loops only, skipped")
            continue
        analyse(sounds, cache)
        if args.list:
            keys, dropped = place(sounds)
            print(f"{machine}:")
            for k in sorted(keys):
                s = keys[k]
                print(f"  {k:3d} {vcsl.note_name(k):4s} {s.role:8s} {s.name}" + (f"  [{len(s.layers)} layers]" if len(s.layers) > 1 else ""))
            if dropped:
                print(f"  ({len(dropped)} more only in the palettes)")
            continue
        made = build(machine, sounds, root)
        kits += len(made)
        print(f"{machine}: " + ", ".join(f"{n} ({c})" for n, c, _ in made))
    with open(cache_path, "w") as f:
        json.dump(cache, f)
    if not args.list:
        print(f"{kits} kits in {os.path.join(root, 'kits')}, presets in machines/sampler/presets/drums/")


if __name__ == "__main__":
    main()
