"""Songs, sections, tracks and clips → a .slab project.

The model mirrors the file (docs/19): a song has tracks; a track has an
instrument, an insert chain and clips; a clip holds notes timed from the
clip's own start. On top of that, a song has *sections* — named runs of
bars laid end to end — and clips are normally placed on a section, so
the arrangement reads like the song form.
"""
import json
import math
import os
import random
import re
import subprocess
import wave
import zlib

from . import rhythm
from .machines import ROOT, SLAB, SlabError, library_path, machine, ref as file_ref, preset as load_preset, preset_assets, preset_name
from .theory import Chord, Key, note, voice_lead

MAX_TRACKS = 32  # buses count (docs/23)
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
    def __init__(self, machine_id, preset=None, bypass=False, key=None, **params):
        self.machine_id = machine_id
        self.preset = preset
        self.bypass = bypass
        # A track (or bus) whose pre-fader signal drives the detector.
        self.key = key
        self.params = params

    def build(self, where, index=None):
        m = machine(self.machine_id)
        if m.kind != "effect":
            raise SlabError(f"{where}: {self.machine_id} is an instrument, not an effect")
        values = dict(load_preset(m.id, self.preset)) if self.preset else {}
        values.update(m.params_from(self.params, where))
        out = {"machine": m.id, "params": values, "bypass": self.bypass}
        if self.preset:
            out["preset"] = preset_name(m.id, self.preset)
        if self.key is not None:
            if not m.sidechain:
                raise SlabError(f"{where}: {m.id} takes no sidechain key (comp2, gate2 and verb2 do)")
            if index is None or id(self.key) not in index:
                raise SlabError(f"{where}: key {self.key!r} isn't a track in this song")
            out["key"] = index[id(self.key)]
        return out


def fx(machine_id, preset=None, bypass=False, key=None, **params):
    """An insert effect: fx("comp2", "drum-smash", thresh=-20). Params may
    drop the machine prefix and use underscores (thresh → comp-thresh);
    switches take an index or a label (div="1/8."). key=track sidechains a
    comp2/gate2/verb2 detector from that track (docs/23)."""
    return FX(machine_id, preset, bypass, key, **params)


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
            if b > self.span + 1e-9:
                self.song.warn(f"{where}: point at beat {b:g} is past the clip's end ({self.span:g}) and won't play")
        return self

    def ramp(self, target, frm, to, v0, v1, tension=0.0):
        """One sweep in clip beats, added to the clip's lane."""
        return self.automate(target, (frm, v0, "curve" if tension else "linear", tension), (to, v1))

    # ── note expression (docs/22) ────────────────────────────────────

    def _pick(self, which):
        if which is None:
            return list(self.notes)
        if callable(which):
            return [n for n in self.notes if which(n)]
        pitches = {note(w) for w in (which if isinstance(which, (list, tuple, set)) else [which])}
        return [n for n in self.notes if n["pitch"] in pitches]

    EXPR_RANGES = {"pitch": (-48, 48), "pressure": (0, 1), "slide": (0, 1), "gain": (-48, 12)}

    def bend(self, points, notes=None, dim="pitch"):
        """Per-note expression: points are (beat from the note's start,
        value[, shape[, tension]]), at most 8. dim "pitch" (semitones,
        ±48, the default), "pressure" / "slide" (0..1) or "gain" (dB,
        -48..12). `notes` picks which: None = all, a pitch or list of
        pitches, or a function of the note dict. Pitch plays on every
        pitched machine; gain on the sampler and Unfairlight."""
        where = f"clip {self.track.name}/{self.name} {dim}"
        if dim not in self.EXPR_RANGES:
            raise SlabError(f"{where}: dim is one of {', '.join(self.EXPR_RANGES)}")
        lo, hi = self.EXPR_RANGES[dim]
        lanes = {}
        _add_points(lanes, ("e", lambda v: v, False), where, points)
        pts = lanes["e"]
        if len(pts) > 8:
            raise SlabError(f"{where}: {len(pts)} points (a note holds at most 8)")
        for _, v, _, _ in pts:
            if not lo <= v <= hi:
                raise SlabError(f"{where}: {v} is outside [{lo}, {hi}]")
        for n in self._pick(notes):
            n.setdefault("expr", {})[dim] = list(pts)
        return self

    def converge(self, to, start, end, tension=-0.3, notes=None):
        """Every note sounding over [start, end) (clip beats) bends onto
        pitch `to` by `end`, holding its own pitch until `start` — a chord
        folding onto one note. Negative tension = slow start."""
        target = note(to)
        where = f"clip {self.track.name}/{self.name} converge"
        if end <= start:
            raise SlabError(f"{where}: end {end} is not after start {start}")
        hit = 0
        for n in self._pick(notes):
            n0, n1 = n["start"], n["start"] + n["len"]
            if n1 <= start or n0 >= end:
                continue
            semis = target - n["pitch"]
            if not -48 <= semis <= 48:
                raise SlabError(f"{where}: {n['pitch']} -> {target} is more than 48 semitones")
            s0 = max(start - n0, 0.0)
            n.setdefault("expr", {})["pitch"] = [(s0, 0.0, "curve" if tension else "linear", tension), (end - n0, float(semis), "linear", 0.0)]
            hit += 1
        if hit == 0:
            self.song.warn(f"{where}: no note sounds over beats {start:g}..{end:g}")
        return self

    @property
    def bar(self):
        """Beats in a bar of the track's meter (its own, or the song's)."""
        return self.track.bar_beats

    @property
    def span(self):
        """The clip's length in its track's own beats: with a tempo ratio
        p:q (Track.time) they run p/q as fast as the song's, so a clip
        `length` song beats long holds length·p/q of them (docs/28)."""
        return self.length * self.track.rate

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
        span = (bars * self.bar) if bars else self.span - at
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
        span = (bars * self.bar) if bars else self.span - at
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
        while t < self.span - 1e-9:
            ch, beats = prog[i % len(prog)]
            ln = beats or bpc
            yield ch, t, min(ln, self.span - t)
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
        while k < self.span - 1e-9:
            for n in base:
                if n["start"] + k < self.span - 1e-9:
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
        # crc32, not hash(): str hashes are salted per process, which made
        # every regeneration of a song rewrite its whole .slab.
        if seed is None:
            seed = zlib.crc32(f"{self.track.name}/{self.name}".encode())
        rng = random.Random(seed)
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
        c.notes = [{**n, **({"expr": {k: list(v) for k, v in n["expr"].items()}} if n.get("expr") else {})} for n in self.notes]
        c.lanes = {k: list(v) for k, v in self.lanes.items()}
        return c

    def to_json(self):
        notes = sorted(self.notes, key=lambda n: (n["start"], n["pitch"]))
        return {"type": "note", "name": self.name, "start": round(self.start, 6), "len": round(self.length, 6),
                "notes": [{"pitch": n["pitch"], "start": round(n["start"], 5), "len": round(max(n["len"], 0.01), 5),
                           "vel": n["vel"],
                           **({"expr": {d: [[b, v] if sh == "linear" and te == 0 else [b, v, sh, te]
                                            for b, v, sh, te in pts]
                                        for d, pts in n["expr"].items()}} if n.get("expr") else {})}
                          for n in notes],
                **({"automation": _lanes_json(self.lanes)} if self.lanes else {})}


def _wav_seconds(path):
    try:
        with wave.open(path, "rb") as w:
            return w.getnframes() / float(w.getframerate())
    except (wave.Error, EOFError, OSError):
        return None


class AudioClip:
    """A WAV placed on a track and mixed in directly (docs/19 audio clips).
    It plays the source window [start_sec, start_sec + dur_sec) at native
    rate; reverse=True plays that window end to start. Fades are seconds,
    in clip time. Warped (docs/29), the source is laid on beats at
    `warp_bpm` and the clip follows the tempo, in `mode`."""

    notes = ()
    lanes = {}

    def __init__(self, track, path, start, start_sec, dur_sec, gain, fade_in, fade_out, reverse, name,
                 warp_bpm=None, mode="tape", total=None, beats=None):
        self.beats = beats or {}
        self.warp_bpm = warp_bpm
        self.mode = mode
        self.total = total
        self.track = track
        self.path = os.path.abspath(path)
        self.start = start
        self.start_sec = start_sec
        self.dur_sec = dur_sec
        self.gain = gain
        self.fade_in = fade_in
        self.fade_out = fade_out
        self.reverse = reverse
        self.name = name

    @property
    def length(self):
        if self.warp_bpm:
            return self.dur_sec * self.warp_bpm / 60
        song = self.track.song
        return song.beat_at(song.seconds_at(self.start) + self.dur_sec) - self.start

    def to_json(self):
        return {"type": "audio", "name": self.name, "start": round(self.start, 6), "len": round(self.length, 6),
                "gain": self.gain, "start_sec": self.start_sec, "dur_sec": self.dur_sec,
                "fade_in": self.fade_in, "fade_out": self.fade_out,
                **({"reversed": True} if self.reverse else {}),
                **({"warp": self._warp_json()} if self.warp_bpm else {}),
                **({"tune": self.tune} if getattr(self, "tune", None) else {}), "source": self.path}

    def _warp_json(self):
        bps = self.warp_bpm / 60
        total = max(self.total or 0, self.start_sec + self.dur_sec)
        head = total - (self.start_sec + self.dur_sec) if self.reverse else self.start_sec
        return {"mode": self.mode, "offset": round(head * bps, 9), **self.beats,
                "markers": [[0, 0], [round(total, 9), round(total * bps, 9)]]}


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
                 fx=(), color=None, mute=False, samples=None, output=None, unison=None, assets=None):
        self.song = song
        # Host unison (docs/08 §Unison): dict(count=, voices=, detune= cents, spread=, blend=).
        self.unison = dict(unison) if unison else None
        self.name = name
        # Routing (docs/23): a Bus for the post-fader signal (None = master),
        # and sends as (bus, linear level, pre).
        self.output = output
        self.sends = []
        self.machine = machine(machine_id)
        if self.machine.kind != "instrument":
            raise SlabError(f"track {name}: {machine_id} is an effect; put it in fx=[…]")
        self.preset = preset_name(machine_id, preset) if preset else None
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
        # Files the instrument loads: the preset's (a kit, a CMI voice), or samples=.
        self.assets = preset_assets(machine_id, preset) if preset else {}
        # Per-sound edits by zone name, and copies/reversals (zone()).
        self.zones = {}
        if samples is not None:
            if self.machine.id != "sampler":
                raise SlabError(f"track {name}: samples= is for the sampler, not {self.machine.id}")
            if not os.path.exists(library_path(samples)):
                song.warn(f"track {name}: samples {samples!r} not found; the track keeps the bundled pluck")
            self.assets["smp"] = samples
        # Files to load by asset name, e.g. a wavetable: assets={"wt-a": "machines/concoction/assets/skill.wav"}.
        if assets:
            self.assets.update(assets)
        for aname, apath in self.assets.items():
            if samples is None and not os.path.exists(library_path(apath)):
                song.warn(f"track {name}: preset {preset!r} loads {apath!r}, which isn't here (fetch the library?)")

    def __repr__(self):
        return f"Track({self.name}: {self.machine.id}, {len(self.clips)} clips)"

    def time(self, meter=None, ratio=None):
        """The track's own time (docs/28 §Polymeter and polytempo):
        meter=(5, 4) counts its bars in 5/4 (its machines' bar position,
        clip.bar); ratio=(3, 2) runs its beats 3/2 as fast as the song's
        from each clip's start, so its clips hold 3/2 as many of them
        (write their notes in its own beats; clip.span is how many)."""
        if meter is not None:
            if not (1 <= meter[0] <= 32 and meter[1] in (1, 2, 4, 8, 16, 32)):
                raise SlabError(f"track {self.name}: meter {meter}?")
            self.meter = tuple(meter)
        if ratio is not None:
            if not (1 <= ratio[0] <= 16 and 1 <= ratio[1] <= 16):
                raise SlabError(f"track {self.name}: ratio {ratio} must be p:q with 1..16")
            self.ratio = tuple(ratio)
        return self

    @property
    def rate(self):
        r = getattr(self, "ratio", None)
        return r[0] / r[1] if r else 1.0

    @property
    def bar_beats(self):
        m = getattr(self, "meter", None)
        return m[0] * 4 / m[1] if m else self.song.bar_beats

    def _time_json(self):
        out = {}
        if getattr(self, "meter", None):
            out["meter"] = list(self.meter)
        if getattr(self, "ratio", None) and self.ratio[0] != self.ratio[1]:
            out["ratio"] = list(self.ratio)
        return {"time": out} if out else {}

    def groove(self, name=None, amount=1.0, shift_ms=0.0):
        """How this track plays its notes (docs/28 §Groove): a groove by
        name ("MPC 58 1/16", "SAMBA 1/16", "AKSAK"…), "NONE" to play
        straight, or None to follow the song and its sections; amount
        0..1 of it; shift_ms −50..50 pushes (−) or drags (+) the track."""
        self.groove_json = {"name": name or "", "amount": float(amount), "shift_ms": float(shift_ms)}
        return self

    def set(self, **params):
        """Tweak instrument params after the preset: set(cutoff=900)."""
        self.params.update(self.machine.params_from(params, f"track {self.name}"))
        return self

    def send(self, bus, db=0.0, pre=False):
        """Send a copy into `bus` at `db` (-inf..+6), post-fader unless pre."""
        if not isinstance(bus, Bus):
            raise SlabError(f"track {self.name}: send target {bus!r} is not a bus")
        if bus is self:
            raise SlabError(f"track {self.name}: a bus can't send to itself")
        if any(b is bus for b, _, _ in self.sends):
            raise SlabError(f"track {self.name}: already sends to {bus.name}")
        if db > 6:
            raise SlabError(f"track {self.name}: send level {db} dB is above +6")
        self.sends.append((bus, 0.0 if db == float("-inf") else 10 ** (db / 20), pre))
        return self

    def _routing_json(self, index):
        out = {}
        if self.output is not None:
            if not isinstance(self.output, Bus):
                raise SlabError(f"track {self.name}: output {self.output!r} is not a bus")
            out["output"] = index[id(self.output)]
        if self.sends:
            out["sends"] = [{"to": index[id(b)], "level": lvl, "pre": pre} for b, lvl, pre in self.sends]
        return out

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

    def ride(self, rides, glide=1.0):
        """A mix ride on the volume lane: {section: dB}, or {section: (dB0, dB1)}
        for a move across the section. Unlisted sections sit at the fader;
        changes glide over `glide` beats into each section. Call after the
        fader is final (the lane is in fader units)."""
        v = self.volume
        pts = []
        prev = None
        for sec in self.song.sections:
            r = rides.get(sec, 0.0)
            d0, d1 = r if isinstance(r, tuple) else (r, r)
            a, b = min(1.25, v * 10 ** (d0 / 20)), min(1.25, v * 10 ** (d1 / 20))
            if prev is None:
                pts.append((sec.start, a))
            elif abs(prev - a) > 1e-9:
                pts.append((max(0.0, sec.start - glide), prev))
                pts.append((sec.start, a))
            if abs(a - b) > 1e-9:
                pts.append((sec.start + sec.length, b))
            prev = b
        pts.append((self.song.sections[-1].start + self.song.sections[-1].length, prev))
        # drop points that repeat the time of the one before
        clean = []
        for t, val in pts:
            if clean and abs(clean[-1][0] - t) < 1e-9:
                clean[-1] = (t, val)
            else:
                clean.append((t, val))
        return self.automate("volume", *clean)

    def audio(self, path, section=None, at_bar=0, at_beat=None, start_sec=0.0, dur_sec=None,
              gain=1.0, fade_in=0.0, fade_out=0.0, reverse=False, name=None,
              warp=None, fit_beats=None, mode="tape", preserve="hits", gap="cut", decay=100,
              transpose=0, fine=0, grain=40, size=0.7, tune=None, scale="chromatic", speed=20,
              humanize=0):
        """Place a WAV: at a section's start plus `at_bar` bars, or at
        `at_beat`. dur_sec defaults to the rest of the file. reverse=True
        plays it backwards (a swell into the downbeat: end it on the bar).
        warp=bpm locks it to the beat at the tempo it was played in, so it
        follows the song's (docs/29); fit_beats=n stretches the window to n
        beats instead. mode: "tape" (speed and pitch together) or "beats"
        (cut at the hits, each at its own speed: drums), with preserve=
        "hits" | "1/16" | "1/8" | "1/4", gap="cut" | "loop" and decay=1..100
        (% of each slice that sounds), "mix" (keeps pitch, for anything),
        "voice" (one note at a time, grain= 10..80 ms) or "smear" (extreme
        stretch into texture, size= 0.3 | 0.7 | 1.4 | 2.7 s windows).
        transpose= semitones and fine= cents move the pitch apart from time
        (not in "tape"). tune="A" puts a voice in that key (docs/30 §Tune):
        scale= "chromatic", "major", "minor", "harmonic", "dorian",
        "mixolydian", "penta_major", "penta_minor" or "blues", speed= ms a
        correction takes (0: the hard effect), humanize= 0..100 (% of vibrato
        and slides kept)."""
        where = f"track {self.name} audio {path}"
        if not os.path.exists(path):
            raise SlabError(f"{where}: file not found")
        total = _wav_seconds(path)
        if dur_sec is None:
            if total is None:
                raise SlabError(f"{where}: can't read its length; pass dur_sec=")
            dur_sec = total - start_sec
        if dur_sec <= 0:
            raise SlabError(f"{where}: nothing to play (start_sec {start_sec} past the end)")
        bb = self.song.bar_beats
        start = at_beat if at_beat is not None else (section.start if section else 0) + at_bar * bb
        if mode not in ("tape", "beats", "mix", "voice", "smear"):
            raise SlabError(f"{where}: mode {mode!r}: tape, beats, mix, voice or smear")
        if not 10 <= grain <= 80:
            raise SlabError(f"{where}: grain {grain} ms must be 10..80")
        sizes = {0.3: 0, 0.7: 1, 1.4: 2, 2.7: 3}
        if size not in sizes:
            raise SlabError(f"{where}: size {size} s: one of 0.3, 0.7, 1.4, 2.7")
        if not -48 <= transpose <= 48 or not -50 <= fine <= 50:
            raise SlabError(f"{where}: transpose -48..48 semitones, fine -50..50 cents")
        if (transpose or fine) and mode == "tape":
            raise SlabError(f"{where}: transpose/fine need mode=\"beats\" or \"mix\" (tape's pitch is its speed)")
        preserves = {"hits": "hits", "1/16": "d16", "1/8": "d8", "1/4": "d4"}
        if preserve not in preserves:
            raise SlabError(f"{where}: preserve {preserve!r}: one of {', '.join(preserves)}")
        if gap not in ("cut", "loop"):
            raise SlabError(f"{where}: gap {gap!r}: \"cut\" or \"loop\"")
        if not 1 <= decay <= 100:
            raise SlabError(f"{where}: decay {decay} must be 1..100")
        beats = {"preserve": preserves[preserve], "gap": gap, "decay": int(decay)} if mode == "beats" else {}
        if transpose or fine:
            beats.update(transpose=int(transpose), fine=int(fine))
        if mode == "voice":
            beats["grain"] = int(grain)
        if mode == "smear":
            beats["size"] = sizes[size]
        if mode != "tape" and warp is None and fit_beats is None:
            raise SlabError(f"{where}: mode={mode!r} needs warp= or fit_beats=")
        if warp is True:
            raise SlabError(f"{where}: tempo detection isn't built yet; pass warp=<bpm> or fit_beats=")
        if fit_beats is not None:
            if fit_beats <= 0:
                raise SlabError(f"{where}: fit_beats must be positive")
            warp = fit_beats * 60 / dur_sec
        if warp is not None and not 20 <= warp <= 999:
            raise SlabError(f"{where}: warp={warp} bpm is out of range")
        tuned = None
        if tune is not None:
            keys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            flats = {"Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#"}
            key = flats.get(tune, tune)
            if key not in keys:
                raise SlabError(f"{where}: tune {tune!r}: a key, C..B (sharps or flats)")
            scales = ("chromatic", "major", "minor", "harmonic", "dorian", "mixolydian", "penta_major", "penta_minor", "blues")
            if scale not in scales:
                raise SlabError(f"{where}: scale {scale!r}: one of {', '.join(scales)}")
            if not 0 <= speed <= 400 or not 0 <= humanize <= 100:
                raise SlabError(f"{where}: speed 0..400 ms, humanize 0..100")
            if reverse:
                raise SlabError(f"{where}: a reversed clip can't be tuned")
            tuned = {"key": key, "scale": scale, "speed": int(speed), "humanize": int(humanize)}
        c = AudioClip(self, path, start, start_sec, dur_sec, gain, fade_in, fade_out, reverse,
                      name or os.path.splitext(os.path.basename(path))[0], warp, mode, total, beats)
        c.tune = tuned
        self.clips.append(c)
        return c

    def _sampler_only(self, what):
        if self.machine.id not in ("sampler", "unfairlight"):
            raise SlabError(f"track {self.name}: {what} is for the sampler or Unfairlight, not {self.machine.id}")

    def zone(self, name, level=None, tune=None, decay=None, tone=None, reverse=None):
        """Edit one sound of the sampler's keymap by name: level dB, tune
        semitones, decay seconds (0 off), tone octaves; reverse=True plays
        it backwards."""
        self._sampler_only("zone()")
        z = self.zones.setdefault(name, {})
        for k, v in (("level", level), ("tune", tune), ("decay", decay), ("tone", tone)):
            if v is not None:
                z[k] = float(v)
        if reverse is not None:
            if reverse:
                z["reverse"] = True
            else:
                z.pop("reverse", None)
        return self

    def duplicate_zone(self, name, key, as_name=None, reverse=False, **edits):
        """Copy a kit sound onto another key (a note name or number), as
        its own sound: duplicate_zone("snare", "D#2", reverse=True). Returns
        the copy's name ("snare 2" unless as_name)."""
        self._sampler_only("duplicate_zone()")
        copy = as_name or f"{name} 2"
        n = 3
        while as_name is None and copy in self.zones:
            copy = f"{name} {n}"
            n += 1
        k = note(key)
        if not 0 <= k <= 127:
            raise SlabError(f"track {self.name}: key {key!r} out of MIDI range")
        base = {kk: v for kk, v in self.zones.get(name, {}).items() if kk in ("level", "tune", "decay", "tone")}
        self.zones[copy] = {**base, "copy": name, "key": k}
        self.zone(copy, reverse=reverse, **edits)
        return copy

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

    def build(self, index=None):
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
                if n["start"] >= c.span - 1e-9 or n["start"] < 0:
                    self.song.warn(f"{where}/{c.name}: note at beat {n['start']:g} is outside the clip (0..{c.span:g}) and won't play")
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
                           **({"preset": self.preset} if self.preset else {}),
                           **({"assets": self.assets} if self.assets else {}),
                           **({"unison": self.unison} if self.unison else {}),
                           **({"zones": self.zones} if self.zones else {})},
            "effects": [f.build(f"{where} fx {i}", index) for i, f in enumerate(self.fx)],
            "clips": [c.to_json() for c in sorted(self.clips, key=lambda c: c.start)],
            **({"automation": _lanes_json(self.lanes)} if self.lanes else {}),
            **({"groove": self.groove_json} if getattr(self, "groove_json", None) else {}),
            **self._time_json(),
            **self._routing_json(index or {}),
        }


class Bus(Track):
    """A bus (docs/23): no instrument or clips; its input is what outputs
    and sends route to it. A group when tracks output to it, a return when
    they send to it. Volume and pan and fx automate as on a track."""

    def __init__(self, song, name, fx=(), volume=1.0, pan=0.0, color=None, mute=False, output=None, folded=False):
        self.song = song
        self.folded = folded
        self.name = name
        self.output = output
        self.sends = []
        self.machine = None
        self.params = {}
        self.volume = volume
        self.pan = pan
        self.fx = list(fx)
        self.color = color or PALETTE[len(song.tracks) % len(PALETTE)]
        self.mute = mute
        self.clips = []
        self.lanes = {}
        self.samples = None
        self.assets = {}
        self.zones = {}

    def __repr__(self):
        return f"Bus({self.name})"

    def _no(self, what):
        raise SlabError(f"bus {self.name}: a bus has no {what}")

    def set(self, **params):
        self._no("instrument")

    def clip(self, *a, **k):
        self._no("clips")

    def audio(self, *a, **k):
        self._no("clips")

    def _auto_target(self, target):
        if target not in ("volume", "pan") and not re.fullmatch(r"fx\d+:.+", target):
            self._no(f"instrument param {target!r} to automate")
        return super()._auto_target(target)

    def build(self, index=None):
        return {
            "name": self.name, "kind": "bus", "color": self.color, "volume": self.volume, "pan": self.pan,
            "mute": self.mute, "solo": False, "instrument": None,
            "effects": [f.build(f"bus {self.name} fx {i}", index) for i, f in enumerate(self.fx)],
            "clips": [],
            **({"automation": _lanes_json(self.lanes)} if self.lanes else {}),
            **({"folded": True} if self.folded else {}),
            **self._routing_json(index or {}),
        }


class Song:
    def __init__(self, title, bpm=120, key="C major", meter=(4, 4), loop=False, groups=None, groove=None, groove_seed=None):
        """meter=(7, 8), groups=(2, 2, 3): the grouping sets the metronome's
        and the grid's accents (docs/07 §meter-map); None is the default
        (7/8 -> 2+2+3, 9/8 -> 3+3+3, /4 meters downbeat only).
        groove="MPC 58 1/16": the song's groove, which tracks follow unless
        they pick their own (Track.groove); groove_seed fixes its random
        timing (docs/28 §Groove)."""
        self.groove = groove
        self.groove_seed = groove_seed
        if groups is not None:
            groups = tuple(int(g) for g in groups)
            if sum(groups) != meter[0] or min(groups) < 1 or len(groups) > 16:
                raise SlabError(f"groups {groups} must be 1..16 positive parts summing to {meter[0]}")
        self.groups = groups
        self.title = title
        self.bpm = bpm
        self.key = Key(key) if isinstance(key, str) else key
        self.meter = meter
        self.loop = loop
        self.sections = []
        self.tempos = []  # (beat, bpm, ramp) after the start, sorted
        self.ramp = False
        self.tracks = []
        self.master_volume = 1.0
        self.master_subsonic = False
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

    def tempo(self, bar, bpm, ramp=False):
        """A tempo change at the start of `bar` (0-based; 0 sets the
        song's tempo). ramp=True glides linearly from here to the next
        change (docs/28 §Tempo map)."""
        if bar == 0:
            self.bpm, self.ramp = bpm, ramp
            return self
        beat = bar * self.bar_beats
        self.tempos = sorted([t for t in self.tempos if t[0] != beat] + [(beat, bpm, ramp)])
        return self

    def _points(self):
        return [(0.0, float(self.bpm), self.ramp)] + [(float(b), float(t), r) for b, t, r in self.tempos]

    def _seg_seconds(self, pts, i, beat):
        b0, t0, ramp = pts[i]
        db = beat - b0
        k = (pts[i + 1][1] - t0) / (pts[i + 1][0] - b0) if ramp and i + 1 < len(pts) else 0.0
        if abs(k) < 1e-9:
            return db * 60.0 / t0
        return 60.0 / k * math.log((t0 + k * db) / t0)

    def seconds_at(self, beat):
        """Seconds from the start to `beat`, through the tempo changes."""
        pts = self._points()
        if beat <= 0:
            return beat * 60.0 / pts[0][1]
        t = 0.0
        for i in range(len(pts)):
            end = pts[i + 1][0] if i + 1 < len(pts) else math.inf
            if beat <= end:
                return t + self._seg_seconds(pts, i, beat)
            t += self._seg_seconds(pts, i, end)

    def beat_at(self, secs):
        """The beat `secs` seconds in (bisection over seconds_at)."""
        lo, hi = -1.0, 1.0
        while self.seconds_at(hi) < secs:
            hi *= 2
        for _ in range(80):
            mid = (lo + hi) / 2
            if self.seconds_at(mid) < secs:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2

    def section(self, name, bars, groove=None):
        """Append a section of `bars` bars after the last one. groove= a
        groove's name (or "NONE") for the tracks that follow the song,
        from here until a section sets another."""
        s = Section(self, name, self.bars, bars)
        s.groove = groove
        self.sections.append(s)
        return s

    def track(self, name, machine_id, preset=None, params=None, volume=0.8, pan=0.0, fx=(), color=None, mute=False,
              samples=None, output=None, unison=None, assets=None):
        if len(self.tracks) >= MAX_TRACKS:
            raise SlabError(f"max {MAX_TRACKS} tracks (buses count)")
        t = Track(self, name, machine_id, preset, params, volume, pan, fx, color, mute, samples, output, unison, assets)
        self.tracks.append(t)
        return t

    def bus(self, name, fx=(), volume=1.0, pan=0.0, color=None, mute=False, output=None, folded=False):
        """A bus (docs/23): route tracks into it with output=bus (a group,
        drawn above its members; folded=True hides them in the app) or
        track.send(bus, db) (a return). Counts against MAX_TRACKS."""
        if len(self.tracks) >= MAX_TRACKS:
            raise SlabError(f"max {MAX_TRACKS} tracks (buses count)")
        b = Bus(self, name, fx, volume, pan, color, mute, output, folded)
        self.tracks.append(b)
        return b

    def _check_routing(self):
        """Refuse a loop through outputs, sends and keys (the app would drop it)."""
        succ = {id(t): [x for x in [t.output] + [b for b, _, _ in t.sends] if x is not None] for t in self.tracks}
        for t in self.tracks:
            for f in t.fx:
                if f.key is not None and id(f.key) in succ:
                    succ[id(f.key)].append(t)
        state = {}

        def visit(t, path):
            state[id(t)] = 1
            for n in succ[id(t)]:
                if state.get(id(n)) == 1:
                    raise SlabError("routing loop: " + " -> ".join(x.name for x in path + [t, n]))
                if not state.get(id(n)):
                    visit(n, path + [t])
            state[id(t)] = 2

        for t in self.tracks:
            for n in succ[id(t)]:
                if all(n is not x for x in self.tracks):
                    raise SlabError(f"track {t.name}: routes to {n.name}, which isn't in this song")
            if not state.get(id(t)):
                visit(t, [])

    def master(self, volume=1.0, fx=(), pan=0.0, subsonic=False):
        """subsonic=True: the master's 24 dB/oct highpass at 30 Hz, before its fx."""
        self.master_volume = volume
        self.master_pan = pan
        self.master_subsonic = subsonic
        self.master_fx = list(fx)
        return self

    def build(self):
        self.warnings = []
        self._check_routing()
        index = {id(t): i for i, t in enumerate(self.tracks)}
        end = max([self.bars * self.bar_beats] + [c.start + c.length for t in self.tracks for c in t.clips])
        num, den = self.meter
        return {
            "slab": "project",
            "schema": 1,
            "transport": dict({"bpm": float(self.bpm), "loop": {"on": self.loop, "start": 0.0, "end": float(end)}},
                              **({"tempo": [dict({"beat": b, "bpm": float(t)}, **({"ramp": True} if r else {}))
                                            for b, t, r in self.tempos]} if self.tempos else {}),
                              **({"ramp": True} if self.ramp and self.tempos else {})),
            "meter": [dict({"bar": 0, "num": num, "den": den}, **({"groups": list(self.groups)} if self.groups else {}))],
            # Sections run back to back and END closes the last (docs/28).
            "sections": [dict({"beat": float(sec.start), "name": sec.name, "color": (4 + i) % 12},
                              **({"groove": sec.groove} if getattr(sec, "groove", None) else {}))
                         for i, sec in enumerate(self.sections)],
            **({"groove": dict({"song": self.groove or "NONE"},
                               **({"seed": int(self.groove_seed)} if self.groove_seed is not None else {}))}
               if self.groove or self.groove_seed is not None else {}),
            "end": float(end),
            "tracks": [t.build(index) for t in self.tracks],
            "master": {"volume": self.master_volume, "pan": self.master_pan, "subsonic": self.master_subsonic,
                       "effects": [f.build(f"master fx {i}") for i, f in enumerate(self.master_fx)]},
        }

    def default_path(self):
        slug = re.sub(r"[^a-z0-9]+", "_", self.title.lower()).strip("_") or "song"
        return os.path.join(ROOT, "songs", slug + ".slab")

    def save(self, path=None, quiet=False):
        """Write the project package (docs/25): `path` is the Song.slab
        folder, the document its project.json. A bare .slab file there is
        replaced by the package."""
        path = os.path.abspath(path or self.default_path())
        project = _with_refs(self.build(), path)
        if os.path.isfile(path):
            os.remove(path)
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "project.json"), "w") as f:
            json.dump(project, f, indent=1)
        if not quiet:
            n = sum(len(c.get("notes", ())) for t in project["tracks"] for c in t["clips"])
            secs = self.seconds_at(self.bars * self.bar_beats)
            print(f"saved {os.path.relpath(path)}: {len(project['tracks'])} tracks, {n} notes, "
                  f"{self.bars} bars, {int(secs // 60)}:{int(secs % 60):02d}")
            for w in self.warnings:
                print("  warning:", w)
        self._path = path
        return path

    def render(self, wav=None, stems=False, report=True):
        """Save, bounce headless with `slab --render`, and analyze. With
        stems=True every track that plays is also exported as a stem (its
        post-fader signal: its own inserts, no send returns, no master
        chain) to show how loud each part sits. It saves where the last
        save() did, else to songs/."""
        from .analyze import analyze_wav, print_report
        path = self.save(getattr(self, "_path", None), quiet=not report)
        wav = wav or os.path.splitext(path)[0] + ".wav"
        _bounce(path, wav)
        secs = [(s.name, self.seconds_at(s.start), self.seconds_at(s.end)) for s in self.sections]
        mix = analyze_wav(wav, secs)
        stem_stats = []
        if stems:
            # One render: each track's post-fader signal, captured while
            # the mix plays (docs/27 §Export), so no master chain and no
            # send returns.
            import glob, shutil, tempfile
            d = tempfile.mkdtemp(prefix="slab-stems-")
            try:
                _bounce(path, None, ["--stems", d, "--stem-kind", "tracks", "--tap", "fader"])
                for f in sorted(glob.glob(os.path.join(d, "*.wav"))):
                    name = re.sub(r"^.*?-\d\d-", "", os.path.splitext(os.path.basename(f))[0])
                    stem_stats.append((name, analyze_wav(f, secs)))
            finally:
                shutil.rmtree(d, ignore_errors=True)
        if report:
            print_report(wav, mix, stem_stats)
        return mix, stem_stats


def _with_refs(node, project_dir):
    """The project with every file written as a reference (docs/25 §Roots):
    asset maps, a rack's parts' assets, audio clip sources."""
    if isinstance(node, list):
        return [_with_refs(x, project_dir) for x in node]
    if not isinstance(node, dict):
        return node
    out = {}
    for k, v in node.items():
        if k == "assets" and isinstance(v, dict):
            out[k] = {a: file_ref(p, project_dir) if isinstance(p, str) else p for a, p in v.items()}
        elif k == "source" and isinstance(v, str) and node.get("type") == "audio":
            out[k] = file_ref(v, project_dir)
        else:
            out[k] = _with_refs(v, project_dir)
    return out


def _bounce(project, wav, extra=()):
    if not os.path.exists(SLAB):
        raise SlabError(f"{SLAB} not found — run `zig build` first")
    # Own session: the headless render has been seen to take its caller's
    # process group down with it on exit.
    args = [SLAB, project] + (["--render", wav] if wav else []) + list(extra)
    r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                       start_new_session=True)
    if r.returncode != 0:
        raise SlabError(f"render failed:\n{r.stderr[-2000:]}")
