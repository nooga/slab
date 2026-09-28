"""slabkit — write Slab songs as Python.

    from slabkit import *
    song = Song("Night Drive", bpm=104, key="A minor")
    ...
    song.save("songs/night_drive.slab")
    song.render()          # headless bounce + mix report

See docs/19-project-format.md (the file format), docs/20-machine-reference.md
(every machine's params and presets) and docs/21-production-guide.md (how
to write and mix a song with them).
"""
from .theory import Key, Chord, note, note_name, SCALES
from .rhythm import steps, euclid
from .machines import machines, machine, presets, preset
from .song import Song, Section, Track, Bus, Clip, fx
from .analyze import analyze_wav

__all__ = [
    "Song", "Section", "Track", "Clip", "fx",
    "Key", "Chord", "note", "note_name", "SCALES",
    "steps", "euclid",
    "machines", "machine", "presets", "preset",
    "analyze_wav",
]
