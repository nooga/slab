"""Racks (docs/42): lanes of chains under eight macros, as Python.

    amp = rack("Bass rig")
    di = amp.lane("DI", "bass", preset="p-bass", fx=[fx("comp2", "bass-leveler")])
    cab = amp.lane("AMP", "bass", preset="p-bass", fx=[fx("amp2", "bass-vintage-15")])
    blend = amp.macro(1, "BLEND", 0.5)
    amp.map(blend, di, "level", min=-40, max=0, formula="clamp(2 - 2*x, 0, 1)")
    amp.map(blend, cab, "level", min=-40, max=0, formula="clamp(2*x, 0, 1)")
    amp.map(amp.macro(2, "GROWL", 0.4), cab, "amp-gain", insert=1, min=0.15, max=0.85)
    song.track("Bass", amp)

An effect rack is `rack(kind="effect")`, put in fx=[…] like any insert;
its lanes have no instrument (`lane("DRY")`, `lane("WET", fx=[…])`).
A saved rig loads with `rack(preset="bass-di-amp")`, or as a track's
machine and preset: `song.track("Bass", "rack", "bass-di-amp")`.
"""
import copy
import json

from .machines import SlabError, machine, preset as load_preset, preset_assets, preset_name, _preset_files

MAX_LANES = 16
MAX_MACROS = 8
MAX_DEPTH = 3
# What a preset file holds besides the rack's own state.
PRESET_KEYS = ("slab", "schema", "machine", "note", "params")


class Lane:
    def __init__(self, rack, name, machine_id, preset, params, fx, keys, vel, chain, transpose, level, pan, poly, mute):
        self.rack = rack
        self.name = name
        self.machine_id = machine_id
        self.preset = preset
        self.params = params or {}
        self.fx = list(fx)
        self.keys, self.vel, self.chain = keys, vel, chain
        self.transpose, self.level, self.pan, self.poly, self.mute = transpose, level, pan, poly, mute

    @property
    def number(self):
        """The lane's place, from 1: what maps and automation paths name."""
        return self.rack.lanes.index(self) + 1

    def _machine(self, slot):
        """The machine at slot 0 (the instrument) or the n-th insert, as
        (machine, rack or None)."""
        if slot == 0:
            if self.machine_id is None:
                raise SlabError(f"rack {self.rack.name} lane {self.name}: an effect rack's lane has no instrument")
            if isinstance(self.machine_id, Rack):
                return machine(self.machine_id.machine_id), self.machine_id
            return machine(self.machine_id), None
        if not 1 <= slot <= len(self.fx):
            raise SlabError(f"rack {self.rack.name} lane {self.name}: insert {slot}, but the lane has {len(self.fx)}")
        f = self.fx[slot - 1]
        return machine(f.machine_id), f.rack

    def build(self, where, depth):
        out = {"name": self.name}
        if self.rack.kind == "instrument":
            out["instrument"] = _machine_json(self.machine_id, self.preset, self.params, f"{where} lane {self.name}", depth)
        out["effects"] = [f.build(f"{where} lane {self.name} fx {i}", depth=depth + 1) for i, f in enumerate(self.fx)]
        for key, rng, hi in (("", self.keys, 127), ("v", self.vel, 127), ("c", self.chain, 127)):
            if rng is not None:
                lo_, hi_ = rng
                if not 0 <= lo_ <= hi_ <= hi:
                    raise SlabError(f"{where} lane {self.name}: zone {rng} must be lo ≤ hi within 0..127")
                out[key + "lo"], out[key + "hi"] = lo_, hi_
        for key, v in (("transpose", self.transpose), ("level", self.level), ("pan", self.pan), ("poly", self.poly)):
            if v:
                out[key] = v
        if self.mute:
            out["mute"] = True
        return out


class Macro:
    def __init__(self, number, name, value):
        self.number, self.name, self.value = number, name, value


class Rack:
    """An instrument rack (kind="instrument", a track's machine) or an
    effect rack (kind="effect", an insert)."""

    def __init__(self, name="Rack", kind="instrument", chain=0, collapsed=False):
        if kind not in ("instrument", "effect"):
            raise SlabError(f"rack {name}: kind is 'instrument' or 'effect', not {kind!r}")
        self.name = name
        self.kind = kind
        self.lanes = []
        self.macros = [Macro(i + 1, "", 0.0) for i in range(MAX_MACROS)]
        self.chain = chain
        self.collapsed = collapsed
        self.maps = []
        # A rig loaded from a preset keeps its saved state as is.
        self._state = None
        self.preset = None

    @property
    def machine_id(self):
        return "rack" if self.kind == "instrument" else "fxrack"

    def lane(self, name, machine_id=None, preset=None, params=None, fx=(), keys=None, vel=None, chain=None,
             transpose=0, level=0.0, pan=0.0, poly=0, mute=False):
        """A lane: an instrument (another rack works too) and its inserts.
        keys/vel/chain are (lo, hi) zones 0..127 — notes, velocities, and
        the CHAIN value that play this lane. level is dB, transpose
        semitones, poly the lane's voice cap (0 = the machine's)."""
        self._own()
        if len(self.lanes) >= MAX_LANES:
            raise SlabError(f"rack {self.name}: max {MAX_LANES} lanes")
        if self.kind == "instrument" and machine_id is None:
            raise SlabError(f"rack {self.name} lane {name}: an instrument rack's lane needs an instrument")
        if self.kind == "effect" and machine_id is not None:
            raise SlabError(f"rack {self.name} lane {name}: an effect rack's lanes are inserts only (fx=[…])")
        if machine_id is not None and not isinstance(machine_id, Rack) and machine(machine_id).kind != "instrument":
            raise SlabError(f"rack {self.name} lane {name}: {machine_id} is an effect; put it in fx=[…]")
        if isinstance(machine_id, Rack) and machine_id.kind != "instrument":
            raise SlabError(f"rack {self.name} lane {name}: an effect rack goes in fx=[…]")
        l = Lane(self, name, machine_id, preset, params, fx, keys, vel, chain, transpose, level, pan, poly, mute)
        self.lanes.append(l)
        return l

    def macro(self, number, name=None, value=None):
        """Macro 1..8: name it, set its value (0..1); returns it for map()."""
        if not 1 <= number <= MAX_MACROS:
            raise SlabError(f"rack {self.name}: macros are 1..{MAX_MACROS}, not {number}")
        self._own()
        m = self.macros[number - 1]
        if name is not None:
            m.name = name
        if value is not None:
            if not 0 <= value <= 1:
                raise SlabError(f"rack {self.name}: macro {number} value {value} is outside [0, 1]")
            m.value = value
        return m

    def map(self, macro, lane, target, insert=0, min=0.0, max=1.0, formula=None):
        """Macro → target. target is "level" (dB), "pan", or a control of
        the lane's instrument (insert=0) or n-th insert ("amp-gain"; the
        machine prefix may be left off). min/max are in the control's units;
        formula shapes x (the macro, 0..1) first: "clamp(2*x, 0, 1)"."""
        self._own()
        number = macro.number if isinstance(macro, Macro) else macro
        if not 1 <= number <= MAX_MACROS:
            raise SlabError(f"rack {self.name}: macros are 1..{MAX_MACROS}, not {number}")
        if lane not in self.lanes:
            raise SlabError(f"rack {self.name}: map to a lane of this rack")
        out = {"macro": number, "lane": lane.number}
        if target in ("level", "pan"):
            out["target"] = target
        else:
            m, _ = lane._machine(insert)
            pid = m.resolve(target)
            p = m.params[pid]
            where = f"rack {self.name} map {pid}"
            p.coerce(min, where), p.coerce(max, where)
            if insert:
                out["insert"] = insert
            out["control"] = pid
        out["min"], out["max"] = min, max
        if formula:
            out["formula"] = formula
        self.maps.append((lane, out))
        return self

    def _own(self):
        if self._state is not None:
            raise SlabError(f"rack {self.name} is the preset {self.preset!r}; build a new rack() to edit lanes")

    @property
    def params(self):
        """The rack's controls as a project stores them."""
        state = self._state
        macros = state.get("macros", []) if state else [{"value": m.value} for m in self.macros]
        out = {f"rk-m{i + 1}": m.get("value", 0) for i, m in enumerate(macros[:MAX_MACROS])}
        out["rk-chain"] = state.get("chain", 0) if state else self.chain
        return out

    def build(self, where="rack", depth=1):
        if depth > MAX_DEPTH:
            raise SlabError(f"{where}: racks nest {MAX_DEPTH} deep at most")
        if self._state is not None:
            return copy.deepcopy(self._state)
        if not self.lanes:
            raise SlabError(f"{where}: rack {self.name} has no lanes")
        maps = []
        for lane, m in self.maps:
            maps.append({**m, "lane": lane.number})
        return {
            "rack": 2, "kind": self.kind,
            "lanes": [l.build(where, depth) for l in self.lanes],
            "macros": [{"name": m.name, "value": m.value} for m in self.macros],
            "chain": self.chain, "maps": maps,
            **({"collapsed": True} if self.collapsed else {}),
        }

    # Automation paths (docs/42 §Automation): "1.2:amp-gain" is lane 1's
    # second insert; "1.0:..." the lane's instrument; "1.1/2.0:..." goes
    # one rack deeper.
    def resolve_path(self, steps, pid, where):
        """The machine and param id at a path, walked through the saved
        state, so a rig loaded from a preset resolves too."""
        state = self.build(where)
        for depth, (lane_n, slot) in enumerate(steps):
            lanes = state.get("lanes", [])
            if not 1 <= lane_n <= len(lanes):
                raise SlabError(f"{where}: lane {lane_n}, but the rack has {len(lanes)}")
            lane = lanes[lane_n - 1]
            if slot == 0:
                if "instrument" not in lane:
                    raise SlabError(f"{where}: an effect rack's lane has no instrument (place 0)")
                entry = lane["instrument"]
            else:
                fxs = lane.get("effects", [])
                if not 1 <= slot <= len(fxs):
                    raise SlabError(f"{where}: insert {slot}, but lane {lane_n} has {len(fxs)}")
                entry = fxs[slot - 1]
            if depth < len(steps) - 1:
                if "state" not in entry:
                    raise SlabError(f"{where}: lane {lane_n} place {slot} is {entry['machine']}, not a rack")
                state = entry["state"]
        m = machine(entry["machine"])
        return m, m.resolve(pid)


def rack(name="Rack", kind="instrument", preset=None, chain=0, collapsed=False):
    """A new rack, or a saved rig with preset= (from machines/rack/presets
    or machines/fxrack/presets)."""
    r = Rack(name, kind, chain, collapsed)
    if preset:
        r._state = rack_preset_state(r.machine_id, preset)
        r.preset = preset_name(r.machine_id, preset)
        r.kind = r._state.get("kind", kind)
    return r


def rack_preset_state(mid, name):
    with open(_preset_files(mid)[preset_name(mid, name)]) as f:
        data = json.load(f)
    return {k: v for k, v in data.items() if k not in PRESET_KEYS}


def _machine_json(machine_id, preset, params, where, depth):
    """A lane's instrument as the rack saves it."""
    if isinstance(machine_id, Rack):
        return {"machine": machine_id.machine_id, "params": machine_id.params, "state": machine_id.build(where, depth + 1)}
    m = machine(machine_id)
    if m.native:
        r = rack(kind=m.kind, preset=preset) if preset else None
        if r is None:
            raise SlabError(f"{where}: a {m.id} needs a Rack object or a preset")
        return _machine_json(r, None, None, where, depth)
    values = dict(load_preset(m.id, preset)) if preset else {}
    values.update(m.params_from(params or {}, where))
    out = {"machine": m.id, "params": values}
    if preset:
        out["preset"] = preset_name(m.id, preset)
        assets = preset_assets(m.id, preset)
        if assets:
            out["assets"] = assets
    return out
