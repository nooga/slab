"""Pitches, keys, chords, progressions and voice leading.

MIDI pitch numbers throughout; C4 = 60 (middle C), A4 = 69.
"""
import re

NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
_PC = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

SCALES = {
    "major": [0, 2, 4, 5, 7, 9, 11],
    "minor": [0, 2, 3, 5, 7, 8, 10],          # natural minor / aeolian
    "harmonic minor": [0, 2, 3, 5, 7, 8, 11],
    "melodic minor": [0, 2, 3, 5, 7, 9, 11],
    "dorian": [0, 2, 3, 5, 7, 9, 10],
    "phrygian": [0, 1, 3, 5, 7, 8, 10],
    "lydian": [0, 2, 4, 6, 7, 9, 11],
    "mixolydian": [0, 2, 4, 5, 7, 9, 10],
    "aeolian": [0, 2, 3, 5, 7, 8, 10],
    "locrian": [0, 1, 3, 5, 6, 8, 10],
    "major pentatonic": [0, 2, 4, 7, 9],
    "minor pentatonic": [0, 3, 5, 7, 10],
    "blues": [0, 3, 5, 6, 7, 10],
}

# chord-symbol suffix → intervals above the root
QUALITIES = {
    "": [0, 4, 7], "maj": [0, 4, 7], "m": [0, 3, 7], "min": [0, 3, 7],
    "dim": [0, 3, 6], "°": [0, 3, 6], "aug": [0, 4, 8], "+": [0, 4, 8],
    "5": [0, 7], "sus2": [0, 2, 7], "sus4": [0, 5, 7], "sus": [0, 5, 7],
    "6": [0, 4, 7, 9], "m6": [0, 3, 7, 9],
    "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10],
    "mmaj7": [0, 3, 7, 11], "m7b5": [0, 3, 6, 10], "ø": [0, 3, 6, 10], "ø7": [0, 3, 6, 10],
    "dim7": [0, 3, 6, 9], "°7": [0, 3, 6, 9], "7sus4": [0, 5, 7, 10],
    "add9": [0, 4, 7, 14], "madd9": [0, 3, 7, 14],
    "9": [0, 4, 7, 10, 14], "maj9": [0, 4, 7, 11, 14], "m9": [0, 3, 7, 10, 14],
    "11": [0, 4, 7, 10, 14, 17], "m11": [0, 3, 7, 10, 14, 17],
}


def pitch_class(name):
    m = re.fullmatch(r"([A-Ga-g])([#b]*)", name)
    if not m:
        raise ValueError(f"not a note name: {name!r}")
    return (_PC[m.group(1).upper()] + m.group(2).count("#") - m.group(2).count("b")) % 12


def note(n):
    """"C4" → 60, "F#2" → 42, "Bb3" → 58; ints pass through."""
    if isinstance(n, int):
        return n
    m = re.fullmatch(r"([A-Ga-g][#b]*)(-?\d+)", n.strip())
    if not m:
        raise ValueError(f"not a note: {n!r} (want e.g. C4, F#2, Bb3)")
    letter = m.group(1)
    semis = _PC[letter[0].upper()] + letter.count("#") - letter.count("b")
    return 12 * (int(m.group(2)) + 1) + semis


def note_name(p):
    return f"{NAMES[p % 12]}{p // 12 - 1}"


class Chord:
    """A chord as a root pitch class, intervals and an optional slash bass."""

    def __init__(self, root, intervals, name=None, bass=None):
        self.root = root % 12
        self.intervals = list(intervals)
        self.bass = None if bass is None else bass % 12
        self.name = name or NAMES[self.root]

    def __repr__(self):
        return f"Chord({self.name})"

    @classmethod
    def parse(cls, sym):
        """"Am", "F#m7b5", "Cmaj7/E", "G7sus4", "Dsus2"."""
        m = re.fullmatch(r"([A-G][#b]?)([^/]*)(?:/([A-G][#b]?))?", sym.strip())
        if not m or m.group(2) not in QUALITIES:
            raise ValueError(f"can't parse chord {sym!r}; qualities: {', '.join(q or 'maj' for q in QUALITIES)}")
        bass = pitch_class(m.group(3)) if m.group(3) else None
        return cls(pitch_class(m.group(1)), QUALITIES[m.group(2)], sym.strip(), bass)

    @property
    def tones(self):
        """Pitch classes, root first."""
        return [(self.root + i) % 12 for i in self.intervals]

    def pitches(self, octave=4, inversion=0):
        """Close position from the root at `octave`, then inverted."""
        base = 12 * (octave + 1) + self.root
        ps = [base + i for i in self.intervals]
        for _ in range(inversion % len(ps)):
            ps = ps[1:] + [ps[0] + 12]
        return ps

    def root_pitch(self, octave=2):
        """The bass note (slash bass if any) in `octave`."""
        return 12 * (octave + 1) + (self.root if self.bass is None else self.bass)

    def tone(self, index, octave=4):
        """Chord tone by index, wrapping into higher octaves: 0 root, 1
        third, 2 fifth, 3 seventh (or the root an octave up on a triad)."""
        n = len(self.intervals)
        return 12 * (octave + 1) + self.root + self.intervals[index % n] + 12 * (index // n)

    def voicing(self, near=60, voices=4, spread=False):
        """A voicing of `voices` notes whose centre sits near `near`: an
        inversion of the close chord, doubled upward from its bottom note
        when voices > chord size. spread=True opens it (drop-2) for pads."""
        n = len(self.intervals)
        best = None
        for inv in range(n):
            ps = [i + (12 if k < inv else 0) for k, i in enumerate(self.intervals)]
            ps = sorted(ps)[:voices]
            while len(ps) < voices:
                ps.append(ps[len(ps) - n] + 12)
            if spread and len(ps) >= 4:
                ps = sorted(ps[:-2] + [ps[-2] - 12] + ps[-1:])
            centre = (ps[0] + ps[-1]) / 2
            shift = round((near - self.root - centre) / 12) * 12
            ps = [self.root + p + shift for p in ps]
            score = abs((ps[0] + ps[-1]) / 2 - near)
            if best is None or score < best[0]:
                best = (score, ps)
        return best[1]

    def transpose(self, semis):
        return Chord(self.root + semis, self.intervals, NAMES[(self.root + semis) % 12] +
                     self.name.lstrip("ABCDEFG#b").split("/")[0],
                     None if self.bass is None else self.bass + semis)


def voice_lead(chords, near=60, voices=4, spread=False):
    """Voicings for a progression that move as little as possible: each
    chord takes the inversion closest to the previous voicing (not
    drifting more than a fifth from `near`)."""
    out = []
    prev = None
    for ch in chords:
        cands = []
        for c in range(near - 7, near + 8):
            cands.append(ch.voicing(c, voices, spread))
        if prev is None:
            pick = ch.voicing(near, voices, spread)
        else:
            pick = min(cands, key=lambda v: sum(abs(a - b) for a, b in zip(sorted(v), sorted(prev)))
                       + 0.25 * abs((v[0] + v[-1]) / 2 - near))
        out.append(pick)
        prev = pick
    return out


_ROMAN = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7}


class Key:
    """A tonic and a scale: Key("A minor"), Key("F# dorian"), Key("Eb")."""

    def __init__(self, spec="C major"):
        parts = spec.split(None, 1)
        self.tonic = pitch_class(parts[0])
        self.mode = parts[1].lower() if len(parts) > 1 else "major"
        if self.mode not in SCALES:
            raise ValueError(f"unknown scale {self.mode!r}; have {', '.join(SCALES)}")
        self.steps = SCALES[self.mode]
        self.name = f"{NAMES[self.tonic]} {self.mode}"

    def __repr__(self):
        return f"Key({self.name})"

    def degree(self, d, octave=4):
        """Scale degree d (1-based; 8 = tonic up an octave, 0/-1 go below)
        as a pitch, with degree 1 in `octave`."""
        n = len(self.steps)
        i = d - 1
        return 12 * (octave + 1) + self.tonic + self.steps[i % n] + 12 * (i // n)

    def scale(self, octave=4, octaves=1):
        return [self.degree(d, octave) for d in range(1, len(self.steps) * octaves + 2)]

    def contains(self, pitch):
        return (pitch - self.tonic) % 12 in self.steps

    def snap(self, pitch):
        """The nearest in-key pitch (ties go down)."""
        for d in (0, -1, 1, -2, 2):
            if self.contains(pitch + d):
                return pitch + d
        return pitch

    def diatonic(self, degree, sevenths=False):
        """The chord built on a scale degree by stacking scale thirds."""
        n = len(self.steps)
        if n != 7:
            raise ValueError("diatonic chords need a 7-note scale")
        idx = [degree - 1 + 2 * k for k in range(4 if sevenths else 3)]
        ps = [self.steps[i % 7] + 12 * (i // 7) for i in idx]
        root = ps[0]
        intervals = [p - root for p in ps]
        q = {(0, 4, 7): "", (0, 3, 7): "m", (0, 3, 6): "dim", (0, 4, 8): "aug",
             (0, 4, 7, 11): "maj7", (0, 4, 7, 10): "7", (0, 3, 7, 10): "m7",
             (0, 3, 6, 10): "m7b5", (0, 3, 6, 9): "dim7", (0, 3, 7, 11): "mmaj7"}.get(tuple(intervals), "?")
        return Chord(self.tonic + root, intervals, NAMES[(self.tonic + root) % 12] + q)

    def roman(self, sym):
        """"vi", "IV", "V7", "bVII", "iiø7", "Imaj7", "IV/V"-style slash
        (bass as a degree: "I/3"). Case gives the quality: upper major,
        lower minor; ° dim, + aug; suffixes as in chord symbols."""
        m = re.fullmatch(r"([b#]?)(VII|VI|V|IV|III|II|I|vii|vi|v|iv|iii|ii|i)([^/]*)(?:/(\d))?", sym.strip())
        if not m:
            raise ValueError(f"can't parse roman numeral {sym!r}")
        acc, num, suffix, bass_deg = m.groups()
        deg = _ROMAN[num.upper()]
        # Numerals count degrees of this key's own scale: VI in A minor is F.
        root = self.degree(deg, -1) % 12 + acc.count("#") - acc.count("b")
        lower = num.islower()
        if suffix in ("°", "dim"):
            q = "dim"
        elif suffix in ("°7", "dim7"):
            q = "dim7"
        elif suffix in ("ø", "ø7", "m7b5"):
            q = "m7b5"
        elif lower:
            q = {"": "m", "7": "m7", "9": "m9", "6": "m6", "11": "m11", "add9": "madd9", "maj7": "mmaj7"}.get(suffix, suffix)
        else:
            q = suffix
        if q not in QUALITIES:
            raise ValueError(f"unknown chord quality in {sym!r}")
        bass = self.degree(int(bass_deg), -1) if bass_deg else None
        return Chord(root, QUALITIES[q], NAMES[root % 12] + q, bass)

    def chord(self, tok):
        try:
            return Chord.parse(tok)
        except ValueError:
            return self.roman(tok)

    def progression(self, text):
        """"i VI III VII" (roman) or "Am F C G" (symbols), space-separated;
        '|' is ignored so bars can be marked. Durations are dropped; see
        timed()."""
        return [c for c, _ in self.timed(text)]

    def timed(self, text):
        """[(Chord, beats or None)] from "Dmaj7:4 Bm7 A7sus4:2 A7:2" —
        a :beats suffix sets that chord's length, None means the default."""
        out = []
        for tok in text.replace("|", " ").split():
            sym, _, beats = tok.partition(":")
            out.append((self.chord(sym), float(beats) if beats else None))
        return out
