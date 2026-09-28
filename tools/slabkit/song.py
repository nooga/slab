"""Songs, sections, tracks and clips → a .slab project.

The model mirrors the file (docs/19): a song has tracks; a track has an
instrument, an insert chain and clips; a clip holds notes timed from the
clip's own start. On top of that, a song has *sections* — named runs of
bars laid end to end — and clips are normally placed on a section, so
the arrangement reads like the song form.
"""
import json
import os
import random
import re
import subprocess

from . import rhythm
from .machines import ROOT, SLAB, SlabError, machine, preset as load_preset
from .theory import Chord, Key, note, voice_lead

MAX_TRACKS = 16
MAX_CLIPS = 64
MAX_NOTES = 2048

PALETTE = [
    [230, 90, 120], [64, 206, 174], [150, 110, 230], [250, 190, 80],
    [90, 170, 250], [240, 130, 70], [120, 200, 90], [210, 120, 200],
]

DRUM_ALIASES = {
    "bd": "kick", "bass": "kick", "sd": "snare", "cp": "clap",
    "hh": "ch", "hat": "ch", "chh": "ch", "closed": "ch",
    "ohh": "oh", "open": "oh", "lt": "tom", "mt": "tom", "ht": "tom",
}


class Section:
    def __init__(self, song, name, start_bar, bars):
        self.song = song
        self.name = name
        self.start_bar = start_bar
        self.bars = bars

    @property
    def start(self):
        return self.start_bar * self.song.bar_beats

    @property
    def length(self):
        return self.bars * self.song.bar_beats

    @property
    def end(self):
        return self.start + self.length

    def __repr__(self):
        return f"Section({self.name}, bars {self.start_bar}–{self.start_bar + self.bars})"


class FX:
    def __init__(self, machine_id, preset=None, bypass=False, **params):
        self.machine_id = machine_id
        self.preset = preset
        self.bypass = bypass
        self.params = params

    def build(self, where):
        m = machine(self.machine_id)
        if m.kind != "effect":
            raise SlabError(f"{where}: {self.machine_id} is an instrument, not an effect")
        values = dict(load_preset(m.id, self.preset)) if self.preset else {}
        values.update(m.params_from(self.params, where))
        return {"machine": m.id, "params": values, "bypass": self.bypass}


def fx(machine_id, preset=None, bypass=False, **params):
    """An insert effect: fx("comp2", "drum-smash", thresh=-20). Params may
    drop the machine prefix and use underscores (thresh → comp-thresh);
    switches take an index or a label (div="1/8.")."""
    return FX(machine_id, preset, bypass, **params)


class Clip:
    def __init__(self, track, name, start, length):
        self.track = track
        self.name = name
        self.start = start
        self.length = length
        self.notes = []
        # Clip automation (docs/22): beats from the clip's start.
        self.lanes = {}

    @property
    def song(self):
        return self.track.song

    def automate(self, target, *points):
        """A clip lane, like Track.automate but timed from the clip's start;
        it moves and copies with the clip and overrides the track's lane
        for the same target while the clip plays."""
        where = f"clip {self.track.name}/{self.name} automation {target}"
        _add_points(self.lanes, self.track._auto_target(target), where, points)
        for b, *_ in self.lanes[self.track._auto_target(target)[0]]:
            if b > self.length + 1e-9:
                self.song.warn(f"{where}: point at beat {b:g} is past the clip's end ({self.length:g}) and won't play")
        return self

    def ramp(self, target, frm, to, v0, v1, tension=0.0):
        """One sweep in clip beats, added to the clip's lane."""
        return self.automate(target, (frm, v0, "curve" if tension else "linear", tension), (to, v1))

    @property
    def bar(self):
        return self.song.bar_beats

    def __repr__(self):
        return f"Clip({self.track.name}/{self.name}, beat {self.start:g}+{self.length:g}, {len(self.notes)} notes)"

    # ── raw notes ────────────────────────────────────────────────────

    def note(self, pitch, at, length=0.25, vel=100):
        """One note; `at` and `length` in beats from the clip start."""
        self.notes.append({"pitch": note(pitch), "start": float(at), "len": float(length), "vel": int(vel)})
        return self

    def chord(self, pitches, at, length, vel=90, strum=0.0):
        """Notes together; strum > 0 staggers them upward by that many beats."""
        for i, p in enumerate(sorted(note(x) for x in pitches)):
            self.note(p, at + i * strum, length - i * strum, vel)
        return self

    # ── patterns ─────────────────────────────────────────────────────

    def melody(self, text, at=0.0, vel=100, gate=0.95):
        """Mini notation: "E5:1.5 D5:.5 C5:1 r:1". Each token is
        pitch:beats, `r` a rest; the length carries over when omitted
        ("A4:.5 G4 E4" = three eighths); @vel sets velocity ("C5:1@120");
        a trailing ~ ties into the next note (legato on mono synths).
        '|' is ignored."""
        t = float(at)
        length = 1.0
        for tok in text.replace("|", " ").split():
            m = re.fullmatch(r"([A-Ga-gr][#b]?-?\d*)(?::([\d.]+))?(?:@(\d+))?(~?)", tok)
            if not m:
                raise SlabError(f"bad melody token {tok!r} (want e.g. E5:1.5, r:.5, C5:1@110)")
            p, ln, v, tie = m.groups()
            if ln:
                length = float(ln)
            if p != "r":
                g = 1.02 if tie else gate
                self.note(p, t, length * g, int(v) if v else vel)
            t += length
        return self

    def seq(self, text, at=0.0, step=0.25, bars=None, vel=96, accent=124, gate=0.5):
        """A step sequencer line, one token per step, repeated to fill the
        clip (or `bars`): "F2 . F3! Ab2~ Gb2 - . C3". Tokens: a pitch
        plays a note; `.` rest; `-` extends the previous note a step;
        suffix `!` accents, `~` slides into the next note (overlaps it,
        so mono synths glide instead of retriggering). '|' is ignored.
        The 303 idiom: accents and slides make the line, not the notes."""
        toks = text.replace("|", " ").split()
        plen = len(toks) * step
        span = (bars * self.bar) if bars else self.length - at
        reps = max(1, int(round(span / plen)))
        parsed = []  # (step_index, pitch, steps_long, accent, slide)
        for i, tok in enumerate(toks):
            if tok == ".":
                continue
            if tok == "-":
                if parsed and parsed[-1][0] + parsed[-1][2] == i:
                    j, p, n, a, sl = parsed[-1]
                    parsed[-1] = (j, p, n + 1, a, sl)
                continue
            m = re.fullmatch(r"([A-Ga-g][#b]?-?\d+)([!~]*)", tok)
            if not m:
                raise SlabError(f"bad seq token {tok!r} (want e.g. F2, C3!, Ab2~, ., -)")
            parsed.append((i, note(m.group(1)), 1, "!" in m.group(2), "~" in m.group(2)))
        for r in range(reps):
            for i, p, n, a, sl in parsed:
                t = at + r * plen + i * step
                if t < at + span - 1e-9:
                    ln = n * step + (step * 0.1 if sl else -(1 - gate) * step)
                    self.note(p, t, ln, accent if a else vel)
        return self

    def drums(self, lanes, at=0.0, step=0.25, bars=None, length=0.1, vel=None):
        """Drum lanes as step strings, repeated to fill the clip (or
        `bars`): {"kick": "x...x...", "snare": "....x...", "ch": "x.x.x.x."}.
        Lane names come from the instrument's note labels (drum2: kick,
        snare, clap, ch, oh, tom), common aliases (bd, sd, hh…), or a MIDI
        pitch. X accent, x hit, o ghost; `vel` overrides the char map."""
        vmap = dict(rhythm.VEL, **(vel or {}))
        span = (bars * self.bar) if bars else self.length - at
        for lane, pat in lanes.items():
            pitch = self.track.drum_pitch(lane)
            plen = rhythm.length(pat, step)
            if plen <= 0:
                continue
            reps = max(1, int(round(span / plen)))
            for r in range(reps):
                for b, ch, _ in rhythm.steps(pat, step):
                    t = at + r * plen + b
                    if t < at + span - 1e-9:
                        self.note(pitch, t, length, vmap.get(ch, 100))
        return self

    def _spans(self, prog, beats_per_chord, at):
        """(chord, start, length) cycling the progression across the clip."""
        if isinstance(prog, str):
            prog = self.song.key.timed(prog)
        else:
            prog = [(c, None) if isinstance(c, Chord) else c for c in prog]
        bpc = beats_per_chord or self.bar
        t, i = at, 0
        while t < self.length - 1e-9:
            ch, beats = prog[i % len(prog)]
            ln = beats or bpc
            yield ch, t, min(ln, self.length - t)
            t += ln
            i += 1

    def chords(self, prog, rhythm_pattern=None, beats_per_chord=None, at=0.0, near=62,
               voices=4, spread=False, vel=84, gate=0.97, step=0.25, strum=0.0):
        """Voice-led chords over the whole clip, one chord per bar by
        default ("Dmaj7 Bm7:2 E7:2" sets per-chord beats; the progression
        cycles until the clip ends). With no rhythm they sustain; with a step string they hit
        on the pattern ("x..x..x." = 3-3-2 stabs), restarting each chord."""
        spans = list(self._spans(prog, beats_per_chord, at))
        voicings = voice_lead([c for c, _, _ in spans], near, voices, spread)
        for (ch, t, ln), v in zip(spans, voicings):
            if rhythm_pattern is None:
                self.chord(v, t, ln * gate, vel, strum)
                continue
            plen = rhythm.length(rhythm_pattern, step)
            k = 0.0
            while k < ln - 1e-9:
                for b, c, n in rhythm.steps(rhythm_pattern, step):
                    if k + b < ln - 1e-9:
                        hit_vel = rhythm.VEL.get(c, vel) * vel // 100
                        self.chord(v, t + k + b, min(n, ln - k - b) * gate, hit_vel, strum)
                k += plen
        return self

    def bass(self, prog, pattern="x.......", beats_per_chord=None, at=0.0, octave=2,
             vel=108, gate=0.85, step=0.25):
        """A bassline following the progression. Pattern characters:
        x/X root (X accented), o/O root an octave up, 3 third, 5 fifth,
        7 seventh (octave on triads), b the root a step below in key
        (approach note), - tie, . rest. Repeats within each chord."""
        key = self.song.key
        for ch, t, ln in self._spans(prog, beats_per_chord, at):
            root = ch.root_pitch(octave)
            plen = rhythm.length(pattern, step)
            k = 0.0
            while k < ln - 1e-9:
                for b, c, n in rhythm.steps(pattern, step):
                    if k + b >= ln - 1e-9:
                        continue
                    p = {"x": root, "X": root, "o": root + 12, "O": root + 12,
                         "3": ch.tone(1, octave), "5": ch.tone(2, octave),
                         "7": ch.tone(3, octave), "b": key.snap(root - 2)}.get(c)
                    if p is None:
                        raise SlabError(f"bass pattern char {c!r}: use x X o O 3 5 7 b - .")
                    v = min(127, vel + 14) if c.isupper() else vel
                    self.note(p, t + k + b, min(n, ln - k - b) * gate, v)
                k += plen
        return self

    def arp(self, prog, pattern="up", rate=0.25, beats_per_chord=None, at=0.0, octave=4,
            octaves=1, gate=0.7, vel=92, accent=16):
        """Arpeggiate each chord: pattern "up", "down", "updown", "random",
        or a list of chord-tone indices (0 root, 1 third, 2 fifth, 3 next
        root/7th, …; negative goes below). Accents the first of each beat."""
        rng = random.Random(len(self.notes))
        for ch, t, ln in self._spans(prog, beats_per_chord, at):
            n = len(ch.intervals) * octaves
            if pattern == "up":
                seq = list(range(n))
            elif pattern == "down":
                seq = list(range(n - 1, -1, -1))
            elif pattern == "updown":
                seq = list(range(n)) + list(range(n - 2, 0, -1))
            elif pattern == "random":
                seq = None
            else:
                seq = list(pattern)
            i = 0
            k = 0.0
            while k < ln - 1e-9:
                idx = rng.randrange(n) if seq is None else seq[i % len(seq)]
                on_beat = abs((t + k) - round(t + k)) < 1e-6
                self.note(ch.tone(idx, octave), t + k, rate * gate, min(127, vel + (accent if on_beat else 0)))
                k += rate
                i += 1
        return self

    # ── transforms ───────────────────────────────────────────────────

    def repeat(self, every):
        """Tile the notes in [0, every) beats across the whole clip —
        write a 1- or 2-bar figure, then repeat(4) or repeat(8)."""
        base = [n for n in self.notes if n["start"] < every - 1e-9]
        self.notes = list(base)
        k = every
        while k < self.length - 1e-9:
            for n in base:
                if n["start"] + k < self.length - 1e-9:
                    self.notes.append(dict(n, start=n["start"] + k))
            k += every
        return self

    def transpose(self, semis):
        for n in self.notes:
            n["pitch"] += semis
        return self

    def swing(self, amount=0.6, grid=0.25):
        """Delay every off-grid step: amount 0.5 is straight, 0.66 triplet
        swing. grid 0.25 swings 16ths, 0.5 swings 8ths."""
        pair = 2 * grid
        for n in self.notes:
            pos = n["start"] % pair
            if abs(pos - grid) < 1e-6:
                n["start"] += (amount - 0.5) * pair
        return self

    def humanize(self, time=0.006, vel=6, seed=None):
        """Small random timing (± beats) and velocity (±) offsets. Keep
        time tiny — 0.006 beats is ~3 ms at 120 BPM."""
        rng = random.Random(seed if seed is not None else hash((self.track.name, self.name)) & 0xffff)
        for n in self.notes:
            n["start"] = max(0.0, n["start"] + rng.uniform(-time, time))
            n["vel"] = max(1, min(127, n["vel"] + rng.randint(-vel, vel)))
        return self

    def velocities(self, fn):
        """Rewrite velocities with fn(note_dict) → int, e.g. a crescendo:
        clip.velocities(lambda n: 60 + int(60 * n["start"] / clip.length))."""
        for n in self.notes:
            n["vel"] = max(1, min(127, int(fn(n))))
        return self

    def copy(self, section=None, name=None, at_beat=None):
        """Duplicate onto another section (same notes)."""
        start = section.start if section else at_beat
        c = self.track._new_clip(name or (section.name if section else self.name), start,
                                 section.length if section else self.length)
        c.notes = [dict(n) for n in self.notes]
        c.lanes = {k: list(v) for k, v in self.lanes.items()}
        return c

    def to_json(self):
        notes = sorted(self.notes, key=lambda n: (n["start"], n["pitch"]))
        return {"type": "note", "name": self.name, "start": round(self.start, 6), "len": round(self.length, 6),
                "notes": [{"pitch": n["pitch"], "start": round(n["start"], 5), "len": round(max(n["len"], 0.01), 5),
                           "vel": n["vel"]} for n in notes],
                **({"automation": _lanes_json(self.lanes)} if self.lanes else {})}


def _add_points(lanes, resolved, where, points):
    """Validate (beat, value[, shape[, tension]]) points into lanes[name]."""
    name, check, stepped = resolved
    lane = lanes.setdefault(name, [])
    for p in points:
        if not 2 <= len(p) <= 4:
            raise SlabError(f"{where}: a point is (beat, value[, shape[, tension]]), got {p!r}")
        beat, value = p[0], check(p[1])
        shape = p[2] if len(p) > 2 else "linear"
        tension = p[3] if len(p) > 3 else 0.0
        if shape not in ("hold", "linear", "curve"):
            raise SlabError(f"{where}: shape {shape!r} is not hold/linear/curve")
        if stepped and shape != "hold":
            shape = "hold"
        if not -1 <= tension <= 1:
            raise SlabError(f"{where}: tension {tension} is outside [-1, 1]")
        if beat < 0:
            raise SlabError(f"{where}: beat {beat} is negative")
        lane.append((beat, value, shape, tension))
    lane.sort(key=lambda q: q[0])  # stable: same-beat points keep their order (a jump)


def _lanes_json(lanes):
    return [{"target": t, "points": [[b, v] if sh == "linear" and te == 0 else [b, v, sh, te]
                                     for b, v, sh, te in pts]}
            for t, pts in lanes.items()]


class Track:
    def __init__(self, song, name, machine_id, preset=None, params=None, volume=0.8, pan=0.0,
                 fx=(), color=None, mute=False, samples=None):
        self.song = song
        self.name = name
        self.machine = machine(machine_id)
        if self.machine.kind != "instrument":
            raise SlabError(f"track {name}: {machine_id} is an effect; put it in fx=[…]")
        self.params = dict(load_preset(machine_id, preset)) if preset else {}
        if params:
            self.set(**params)
        self.volume = volume
        self.pan = pan
        self.fx = list(fx)
        self.color = color or PALETTE[len(song.tracks) % len(PALETTE)]
        self.mute = mute
        self.clips = []
        # Automation lanes (docs/22): file target name -> [(beat, value, shape, tension)]
        self.lanes = {}
        # The sampler's keymap: a .wav, an .sfz, or a folder of WAVs.
        self.samples = samples
        if samples is not None:
            if self.machine.id != "sampler":
                raise SlabError(f"track {name}: samples= is for the sampler, not {self.machine.id}")
            if not os.path.exists(samples):
                song.warn(f"track {name}: samples {samples!r} not found; the track keeps the bundled pluck")

    def __repr__(self):
        return f"Track({self.name}: {self.machine.id}, {len(self.clips)} clips)"

    def set(self, **params):
        """Tweak instrument params after the preset: set(cutoff=900)."""
        self.params.update(self.machine.params_from(params, f"track {self.name}"))
        return self

    def _auto_target(self, target):
        """File target name and a value checker for an automation target:
        "volume", "pan", an instrument param ("cutoff"), or "fx<N>:<param>"."""
        where = f"track {self.name} automation"
        if target == "volume":
            def check(v):
                if not 0 <= v <= 1.25:
                    raise SlabError(f"{where}: volume {v} is outside [0, 1.25]")
                return v
            return "volume", check, False
        if target == "pan":
            def check(v):
                if not -1 <= v <= 1:
                    raise SlabError(f"{where}: pan {v} is outside [-1, 1]")
                return v
            return "pan", check, False
        m = re.fullmatch(r"fx(\d+):(.+)", target)
        if m:
            i = int(m.group(1))
            if i >= len(self.fx):
                raise SlabError(f"{where}: {target} names effect {i}, but the track has {len(self.fx)}")
            mach = machine(self.fx[i].machine_id)
            pid = mach.resolve(m.group(2))
            name = f"fx{i}:{pid}"
        else:
            mach = self.machine
            pid = mach.resolve(target)
            name = f"inst:{pid}"
        param = mach.params[pid]
        return name, (lambda v: param.coerce(v, where)), param.type != "float"

    def automate(self, target, *points):
        """An automation lane: automate("cutoff", (0, 400), (64, 4000, "curve", 0.5)).
        Points are (beat, value[, shape[, tension]]); values in the param's
        units (Hz, dB, 0..1), switches by index or label. Shapes: "linear"
        (default), "curve" (tension -1..1, + = fast start), "hold" (steps).
        The shape shapes the segment to the next point (docs/22)."""
        _add_points(self.lanes, self._auto_target(target), f"track {self.name} automation {target}", points)
        return self

    def ramp(self, target, frm, to, v0, v1, tension=0.0):
        """One sweep from v0 at beat `frm` to v1 at beat `to`, added to the
        lane. tension bends it (+ = fast start)."""
        return self.automate(target, (frm, v0, "curve" if tension else "linear", tension), (to, v1))

    def drum_pitch(self, lane):
        if isinstance(lane, int):
            return lane
        k = lane.lower()
        labels = self.machine.note_labels
        k = k if k in labels else DRUM_ALIASES.get(k, k)
        if k not in labels:
            raise SlabError(f"track {self.name}: no drum lane {lane!r}; have {', '.join(labels) or '(none: not a drum machine)'}")
        return labels[k]

    def _new_clip(self, name, start, length):
        c = Clip(self, name, start, length)
        self.clips.append(c)
        return c

    def clip(self, section=None, name=None, bars=None, at_bar=0):
        """A new clip on a section (the whole section, or `bars` of it
        starting `at_bar` bars in), or at an absolute bar when section is
        None."""
        bb = self.song.bar_beats
        if section is None:
            return self._new_clip(name or self.name, at_bar * bb, (bars or 4) * bb)
        n = bars if bars is not None else section.bars - at_bar
        return self._new_clip(name or section.name, section.start + at_bar * bb, n * bb)

    def build(self):
        where = f"track {self.name}"
        if len(self.clips) > MAX_CLIPS:
            raise SlabError(f"{where}: {len(self.clips)} clips (max {MAX_CLIPS})")
        count = sum(len(c.notes) for c in self.clips)
        if count > MAX_NOTES:
            raise SlabError(f"{where}: {count} notes (max {MAX_NOTES}) — split across tracks or thin the pattern")
        spans = sorted((c.start, c.start + c.length, c.name) for c in self.clips)
        for (a0, a1, an), (b0, b1, bn) in zip(spans, spans[1:]):
            if b0 < a1 - 1e-9:
                self.song.warn(f"{where}: clips {an!r} and {bn!r} overlap (both play)")
        for c in self.clips:
            for n in c.notes:
                if not 0 <= n["pitch"] <= 127:
                    raise SlabError(f"{where}/{c.name}: pitch {n['pitch']} out of MIDI range")
                if n["start"] >= c.length - 1e-9 or n["start"] < 0:
                    self.song.warn(f"{where}/{c.name}: note at beat {n['start']:g} is outside the clip (0..{c.length:g}) and won't play")
            if self.machine.mono and not self.machine.note_pitch:
                starts = {}
                for n in c.notes:
                    starts.setdefault(round(n["start"], 4), []).append(n)
                stacked = [t for t, ns in starts.items() if len(ns) > 1]
                if stacked:
                    self.song.warn(f"{where}/{c.name}: {self.machine.id} is mono but has chords at beats {stacked[:4]} — only one note sounds")
        return {
            "name": self.name, "color": self.color, "volume": self.volume, "pan": self.pan,
            "mute": self.mute, "solo": False,
            "instrument": {"machine": self.machine.id, "params": self.params,
                           **({"assets": {"smp": self.samples}} if self.samples else {})},
            "effects": [f.build(f"{where} fx {i}") for i, f in enumerate(self.fx)],
            "clips": [c.to_json() for c in sorted(self.clips, key=lambda c: c.start)],
            **({"automation": _lanes_json(self.lanes)} if self.lanes else {}),
        }


class Song:
    def __init__(self, title, bpm=120, key="C major", meter=(4, 4), loop=False):
        self.title = title
        self.bpm = bpm
        self.key = Key(key) if isinstance(key, str) else key
        self.meter = meter
        self.loop = loop
        self.sections = []
        self.tracks = []
        self.master_volume = 1.0
        self.master_pan = 0.0
        self.master_fx = []
        self.warnings = []

    @property
    def bar_beats(self):
        num, den = self.meter
        return num * 4 / den

    @property
    def bars(self):
        return sum(s.bars for s in self.sections)

    def warn(self, msg):
        if msg not in self.warnings:
            self.warnings.append(msg)

    def section(self, name, bars):
        """Append a section of `bars` bars after the last one."""
        s = Section(self, name, self.bars, bars)
        self.sections.append(s)
        return s

    def track(self, name, machine_id, preset=None, params=None, volume=0.8, pan=0.0, fx=(), color=None, mute=False,
              samples=None):
        if len(self.tracks) >= MAX_TRACKS:
            raise SlabError(f"max {MAX_TRACKS} tracks")
        t = Track(self, name, machine_id, preset, params, volume, pan, fx, color, mute, samples)
        self.tracks.append(t)
        return t

    def master(self, volume=1.0, fx=(), pan=0.0):
        self.master_volume = volume
        self.master_pan = pan
        self.master_fx = list(fx)
        return self

    def build(self):
        self.warnings = []
        end = max([self.bars * self.bar_beats] + [c.start + c.length for t in self.tracks for c in t.clips])
        num, den = self.meter
        return {
            "schema": 1,
            "transport": {"bpm": float(self.bpm), "loop": {"on": self.loop, "start": 0.0, "end": float(end)}},
            "meter": [{"bar": 0, "num": num, "den": den}],
            "tracks": [t.build() for t in self.tracks],
            "master": {"volume": self.master_volume, "pan": self.master_pan,
                       "effects": [f.build(f"master fx {i}") for i, f in enumerate(self.master_fx)]},
        }

    def default_path(self):
        slug = re.sub(r"[^a-z0-9]+", "_", self.title.lower()).strip("_") or "song"
        return os.path.join(ROOT, "songs", slug + ".slab")

    def save(self, path=None, quiet=False):
        path = path or self.default_path()
        project = self.build()
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w") as f:
            json.dump(project, f, indent=1)
        if not quiet:
            n = sum(len(c["notes"]) for t in project["tracks"] for c in t["clips"])
            secs = self.bars * self.bar_beats * 60 / self.bpm
            print(f"saved {os.path.relpath(path)}: {len(project['tracks'])} tracks, {n} notes, "
                  f"{self.bars} bars, {int(secs // 60)}:{int(secs % 60):02d}")
            for w in self.warnings:
                print("  warning:", w)
        self._path = path
        return path

    def render(self, wav=None, stems=False, report=True):
        """Save, bounce headless with `slab --render`, and analyze. With
        stems=True every track is also bounced alone (through its own
        inserts, no master chain) to show how loud each part sits."""
        from .analyze import analyze_wav, print_report
        path = self.save(quiet=not report)
        wav = wav or os.path.splitext(path)[0] + ".wav"
        _bounce(path, wav)
        secs = [(s.name, s.start * 60 / self.bpm, s.end * 60 / self.bpm) for s in self.sections]
        mix = analyze_wav(wav, secs)
        stem_stats = []
        if stems:
            base = self.build()
            tmp = os.path.splitext(path)[0] + ".stem.slab"
            twav = os.path.splitext(path)[0] + ".stem.wav"
            for i, t in enumerate(base["tracks"]):
                one = dict(base, tracks=[dict(t, mute=False, solo=False)],
                           master={"volume": 1.0, "pan": 0.0, "effects": []})
                with open(tmp, "w") as f:
                    json.dump(one, f)
                _bounce(tmp, twav)
                stem_stats.append((t["name"], analyze_wav(twav, secs)))
            os.remove(tmp)
            os.remove(twav)
        if report:
            print_report(wav, mix, stem_stats)
        return mix, stem_stats


def _bounce(project, wav):
    if not os.path.exists(SLAB):
        raise SlabError(f"{SLAB} not found — run `zig build` first")
    # Own session: the headless render has been seen to take its caller's
    # process group down with it on exit.
    r = subprocess.run([SLAB, project, "--render", wav], cwd=ROOT, capture_output=True, text=True,
                       start_new_session=True)
    if r.returncode != 0:
        raise SlabError(f"render failed:\n{r.stderr[-2000:]}")
