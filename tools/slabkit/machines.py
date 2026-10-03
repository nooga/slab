"""The machine database: param ids, ranges and presets.

Param data comes from the live manifests via `slab --describe`, cached at
zig-out/machines.json and refreshed whenever the slab binary is newer than
the cache (so a knob added in fy shows up here after `zig build`).
"""
import difflib
import json
import os
import subprocess
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SLAB = os.path.join(ROOT, "zig-out", "bin", "slab")
CACHE = os.path.join(ROOT, "zig-out", "machines.json")
MACHINES_DIR = os.path.join(ROOT, "machines")

_db = None


class SlabError(Exception):
    pass


class Param:
    def __init__(self, d):
        self.id = d["id"]
        self.module = d["module"]
        self.label = d["label"]
        self.type = d["type"]          # float | switch | int
        self.min = d["min"]
        self.max = d["max"]
        self.default = d["default"]
        self.curve = d["curve"]
        self.options = [o["label"] for o in d.get("options", [])]

    def coerce(self, value, where):
        """Turn a user value into what the project stores. Switches take an
        index or an option label ("SAW", "1/8."); out-of-range numbers are
        an error rather than a silent clamp."""
        if self.type == "switch":
            if isinstance(value, bool):
                value = int(value)
            if isinstance(value, str):
                labels = [o.upper() for o in self.options]
                if value.upper() not in labels:
                    raise SlabError(f"{where}: {self.id} has options {self.options}, not {value!r}")
                return labels.index(value.upper())
            if value != int(value) or not 0 <= value < len(self.options):
                raise SlabError(f"{where}: {self.id} is a switch {self.options}; use an index 0..{len(self.options) - 1} or a label")
            return int(value)
        if isinstance(value, str):
            raise SlabError(f"{where}: {self.id} takes a number, got {value!r}")
        if not self.min - 1e-9 <= value <= self.max + 1e-9:
            raise SlabError(f"{where}: {self.id}={value} is outside [{self.min:g}, {self.max:g}]")
        return int(round(value)) if self.type == "int" else value

    def describe(self):
        if self.type == "switch":
            return f"{self.id}: {' / '.join(f'{i}={o}' for i, o in enumerate(self.options))} (default {self.default:g})"
        return f"{self.id}: {self.min:g}..{self.max:g} (default {self.default:g}, {self.curve})"


class Machine:
    def __init__(self, d):
        self.id = d["id"]
        self.name = d["name"]
        self.kind = d["kind"]          # instrument | effect
        self.voices = d["voices"]
        self.note_pitch = d["note_pitch"]
        # The detector takes a sidechain key: fx(..., key=track) (docs/23).
        self.sidechain = d.get("sidechain", False)
        self.note_labels = {n["label"].lower(): n["pitch"] for n in d["note_labels"]}
        self.params = {p["id"]: Param(p) for p in d["params"]}
        # Most machines prefix every id ("jn-cutoff", "comp-thresh"); knowing
        # the prefix lets callers write cutoff=… instead of jn_cutoff=….
        heads = Counter(pid.split("-")[0] for pid in self.params if "-" in pid)
        head, n = heads.most_common(1)[0] if heads else ("", 0)
        self.prefix = head + "-" if n >= 0.75 * len(self.params) else ""

    @property
    def mono(self):
        return self.voices == 1

    def resolve(self, key):
        """Map a kwarg-style name to a param id: exact id, underscores as
        dashes, or the machine prefix added ("thresh" → "comp-thresh")."""
        for cand in (key, key.replace("_", "-"), self.prefix + key.replace("_", "-")):
            if cand in self.params:
                return cand
        close = difflib.get_close_matches(key.replace("_", "-"), list(self.params), n=3)
        hint = f" — did you mean {', '.join(close)}?" if close else ""
        raise SlabError(f"{self.id} has no param {key!r}{hint}")

    def params_from(self, values, where):
        out = {}
        for k, v in values.items():
            pid = self.resolve(k)
            out[pid] = self.params[pid].coerce(v, where)
        return out

    def presets(self):
        return presets(self.id)

    def help(self):
        lines = [f"{self.id} — {self.name} ({self.kind}, {'mono' if self.mono else f'{self.voices} voices'})"]
        if self.note_labels:
            lines.append("  notes: " + ", ".join(f"{k}={v}" for k, v in self.note_labels.items()))
        module = None
        for p in self.params.values():
            if p.module != module:
                module = p.module
                lines.append(f"  [{module}]")
            lines.append("    " + p.describe())
        lines.append("  presets: " + ", ".join(self.presets()))
        return "\n".join(lines)


def _load():
    global _db
    if _db is not None:
        return _db
    stale = not os.path.exists(CACHE) or (
        os.path.exists(SLAB) and os.path.getmtime(SLAB) > os.path.getmtime(CACHE))
    if stale:
        if not os.path.exists(SLAB):
            raise SlabError(f"{SLAB} not found — run `zig build` first")
        subprocess.run([SLAB, "--describe", CACHE], check=True, cwd=ROOT,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    with open(CACHE) as f:
        _db = {m["id"]: Machine(m) for m in json.load(f)["machines"]}
    return _db


def machines():
    return _load()


def machine(mid):
    db = _load()
    if mid not in db:
        close = difflib.get_close_matches(mid, list(db), n=3)
        raise SlabError(f"no machine {mid!r}; have {', '.join(db)}" + (f" (did you mean {close[0]}?)" if close else ""))
    return db[mid]


def _preset_dirs(mid):
    """Where a machine's presets live: the factory's folder, then each
    installed pack's <library>/<pack>/presets/<mid> (docs/25 §Pack presets)."""
    dirs = [os.path.join(MACHINES_DIR, mid, "presets")]
    lib = library_dir()
    if os.path.isdir(lib):
        for pack in sorted(os.listdir(lib)):
            d = os.path.join(lib, pack, "presets", mid)
            if os.path.isdir(d):
                dirs.append(d)
    return dirs


def _preset_files(mid):
    """{name: file} for every preset of a machine, bank presets as "bank/name"."""
    out = {}
    for base in _preset_dirs(mid):
        for dirpath, _, files in os.walk(base):
            for f in files:
                if f.endswith(".preset"):
                    path = os.path.join(dirpath, f)
                    out.setdefault(os.path.relpath(path, base)[: -len(".preset")], path)
    return out


def presets(mid):
    """Preset names for a machine, bank presets as "bank/name"."""
    return sorted(_preset_files(mid), key=lambda n: (n.count("/"), n))


def preset_name(mid, name):
    """The preset's full name as the host lists it ("slab/glass-lead")."""
    names = presets(mid)
    hits = [n for n in names if n == name] or [n for n in names if n.split("/")[-1] == name]
    if len(hits) != 1:
        if hits:
            raise SlabError(f"{mid} preset {name!r} is ambiguous: {', '.join(hits)}")
        close = difflib.get_close_matches(name, names, n=4)
        raise SlabError(f"{mid} has no preset {name!r}" + (f"; close: {', '.join(close)}" if close else ""))
    return hits[0]


def _preset_file(mid, name):
    with open(_preset_files(mid)[preset_name(mid, name)]) as f:
        return json.load(f)


def preset(mid, name):
    """A preset's params, keyed by param id. `name` may omit the bank when
    it is unique ("glass-lead" finds "slab/glass-lead")."""
    return dict(_preset_file(mid, name)["params"])


def preset_assets(mid, name):
    """The files a preset loads ({"smp": "lib:…/kit.sfz"}), or {}."""
    return dict(_preset_file(mid, name).get("assets") or {})


# ── roots and references (docs/25 §Roots; src/storage.zig) ─────────────

def home_dir():
    """The home folder: $SLAB_HOME, else ~/Music/Slab."""
    return (os.environ.get("SLAB_HOME") or os.path.expanduser("~/Music/Slab")).rstrip("/")


def library_dir():
    """Sample packs: $SLAB_LIBRARY, else <home>/Library."""
    return (os.environ.get("SLAB_LIBRARY") or os.path.join(home_dir(), "Library")).rstrip("/")


def factory_dir():
    """What slab ships: $SLAB_FACTORY, else the repo (slab renders from it)."""
    return os.path.abspath(os.environ.get("SLAB_FACTORY") or ROOT)


def _roots(project_dir):
    # Ties go to the earlier root, as in storage.zig.
    roots = [("lib:", library_dir()), ("factory:", factory_dir()), ("user:", home_dir())]
    if project_dir:
        roots.append(("project:", os.path.abspath(project_dir)))
    return roots


def resolve(path, project_dir=None):
    """A reference ("lib:…", "factory:…", "user:…", "project:…", or a path
    relative to the project's folder) as an absolute file path."""
    for pre, root in _roots(project_dir) + [("project:", os.path.abspath(project_dir or "."))]:
        if path.startswith(pre):
            return os.path.normpath(os.path.join(root, path[len(pre):].lstrip("/")))
    return os.path.normpath(os.path.join(os.path.abspath(project_dir or "."), path))


def ref(path, project_dir=None):
    """How a project names a file: under the root that holds it most
    closely, relative to `project_dir` when that's it, else absolute.
    References pass through."""
    if any(path.startswith(p) for p in ("lib:", "factory:", "user:", "project:")):
        return path
    # Song scripts name shipped files relative to the repo, where slab runs.
    full = os.path.normpath(os.path.join(factory_dir(), path))
    best = None
    for pre, root in _roots(project_dir):
        if full.startswith(root + "/") and (best is None or len(root) > len(best[1])):
            best = (pre, root)
    if best is None:
        return full
    rest = full[len(best[1]) + 1:]
    return rest if best[0] == "project:" else best[0] + rest


def library_path(path):
    """A reference or a repo-relative path as a file path."""
    return resolve(path, factory_dir())
