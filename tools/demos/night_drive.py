"""Generate demos/night_drive.slab — a 32-bar synthwave demo for Slab.

104 BPM, A minor, Am–F–C–G. Tracks: drum2, Cream Mono bass, Juno pad,
Juno arp, Cream Mono lead; per-track effects and a master bus.
Run: python3 tools/demos/night_drive.py  (then: zig-out/bin/slab demos/night_drive.slab)
"""
import json
import os

BPM = 104
BARS = 32
BEATS = BARS * 4
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def preset(machine, name):
    with open(os.path.join(ROOT, "machines", machine, "presets", name + ".preset")) as f:
        return json.load(f)["params"]


def fx(machine, **params):
    return {"machine": machine, "params": {k.replace("_", "-"): v for k, v in params.items()}, "bypass": False}


# Am F C G — roots, pad voicings, arp tones
CHORDS = [
    dict(root=33, pad=[57, 60, 64, 69], arp=[69, 72, 76, 81]),   # Am
    dict(root=29, pad=[53, 57, 60, 65], arp=[65, 69, 72, 77]),   # F
    dict(root=36, pad=[55, 60, 64, 67], arp=[67, 72, 76, 79]),   # C
    dict(root=31, pad=[55, 59, 62, 67], arp=[67, 71, 74, 79]),   # G
]


def chord(bar):
    return CHORDS[bar % 4]


def note(pitch, start, length, vel):
    return {"pitch": pitch, "start": round(start, 4), "len": round(length, 4), "vel": vel}


def pad_notes():
    out = []
    for bar in range(BARS):
        for p in chord(bar)["pad"]:
            out.append(note(p, bar * 4, 3.95, 78))
    return out


def arp_notes():
    out = []
    order = [0, 1, 2, 3, 2, 1, 2, 3]  # up, back, up: rolls into the next beat
    for bar in range(4, BARS):
        tones = chord(bar)["arp"]
        for step in range(16):
            vel = 96 if step % 4 == 0 else (80 if step % 2 == 0 else 68)
            out.append(note(tones[order[step % 8]], bar * 4 + step * 0.25, 0.2, vel))
    return out


def bass_notes():
    out = []
    for bar in range(8, BARS):
        if bar >= 30:  # the drop
            break
        r = chord(bar)["root"]
        pattern = [r, r, r + 12, r, r, r + 12, r, r + 12]
        for i, p in enumerate(pattern):
            vel = 118 if i == 0 else (104 if i % 2 == 0 else 92)
            out.append(note(p, bar * 4 + i * 0.5, 0.38, vel))
    return out


KICK, SNARE, CLAP, CH, TOM, OH = 36, 38, 39, 42, 45, 46


def drum_notes():
    out = []
    for bar in range(8, BARS):
        if bar >= 30:
            break
        b = bar * 4
        chorus = bar >= 16
        fill = bar % 8 == 7
        for beat in range(4):
            # kick on every beat in the chorus, 1 and 3 in the verse
            if chorus or beat % 2 == 0:
                out.append(note(KICK, b + beat, 0.2, 120 if beat == 0 else 108))
            if beat % 2 == 1 and not (fill and beat == 3):
                out.append(note(SNARE, b + beat, 0.2, 116))
                if chorus:
                    out.append(note(CLAP, b + beat, 0.2, 100))
        # hats: 16ths, accented 8ths; open hat on the offbeats in the chorus
        for s in range(16):
            t = b + s * 0.25
            if fill and s >= 12:
                continue
            if chorus and s % 4 == 2:
                out.append(note(OH, t, 0.2, 84))
            else:
                out.append(note(CH, t, 0.1, 92 if s % 2 == 0 else 62))
        if fill:  # tom run into the next section
            for i, s in enumerate(range(12, 16)):
                out.append(note(TOM, b + s * 0.25, 0.2, 90 + i * 8))
            out.append(note(SNARE, b + 3.75, 0.2, 124))
    # the last hit lands on the downbeat of the drop
    out.append(note(KICK, 30 * 4, 0.2, 124))
    out.append(note(CLAP, 30 * 4, 0.2, 110))
    return out


# the hook, two 4-bar phrases over Am F C G; (pitch, length) per bar
PHRASE_A = [
    [(76, 1.5), (74, 0.5), (72, 1.0), (74, 1.0)],
    [(72, 1.5), (69, 0.5), (69, 2.0)],
    [(67, 1.0), (72, 1.0), (76, 1.5), (79, 0.5)],
    [(74, 1.5), (71, 0.5), (74, 2.0)],
]
PHRASE_B = [
    [(81, 1.5), (79, 0.5), (76, 2.0)],
    [(77, 1.0), (76, 1.0), (72, 2.0)],
    [(76, 1.0), (79, 1.0), (84, 1.5), (83, 0.5)],
    [(79, 1.0), (76, 3.0)],
]


def lead_notes():
    out = []
    for section in (16, 24):
        for i, phrase in enumerate((PHRASE_A, PHRASE_B)):
            for j, bar_notes in enumerate(phrase):
                t = (section + i * 4 + j) * 4
                for p, length in bar_notes:
                    # legato: each note runs into the next for the glide
                    out.append(note(p, t, length * 0.98, 104))
                    t += length
    return out


def track(name, color, machine, params, clips, volume, poly=1, effects=(), pan=0.0):
    return {
        "name": name, "color": color, "volume": volume, "pan": pan, "mute": False, "solo": False,
        "poly": poly, "instrument": {"machine": machine, "params": params},
        "effects": list(effects), "clips": clips,
    }


def clip(name, notes):
    return [{"type": "note", "name": name, "start": 0.0, "len": float(BEATS), "notes": notes}]


drums_params = {
    "kick-tune": 52, "kick-sweep": 8, "kick-decay": 0.42, "kick-drive": 2.4, "kick-level": 0.8,
    "snare-tune": 190, "snare-decay": 0.22, "snare-snap": 0.85, "snare-tone": 2200,
    "clap-decay": 0.35, "hat-level": 1.0, "hat-tone": 1.25, "hat-chdec": 0.05, "hat-ohdec": 0.35,
    "tom-tune": 120, "tom-decay": 0.35, "master-drive": 1.3,
}

bass = preset("cream", "synthwave-bass")
bass.update({"cr-contour": 3.4, "cr-level": 0.45, "cr-age": 0.3})

lead = preset("cream", "cream-lead")
lead.update({"cr-glide": 0.07, "cr-level": 0.46, "cr-age": 0.5, "cr-cutoff": 1100})

pad = preset("juno2", "lush-pad")
pad.update({"jn-age": 0.5, "jn-level": 0.42, "jn-cutoff": 1400})

arp = preset("juno2", "pluck-keys")
arp.update({"jn-cutoff": 3400, "jn-level": 0.5, "jn-age": 0.4})

project = {
    "schema": 1,
    "transport": {"bpm": float(BPM), "loop": {"on": True, "start": 0.0, "end": float(BEATS)}},
    "tracks": [
        track("DRUMS", [230, 90, 120], "drum2", drums_params, clip("Drive Beat", drum_notes()), 0.78, effects=[
            fx("comp2", comp_thresh=-16, comp_ratio=3.5, comp_atk=0.008, comp_rel=0.12, comp_makeup=3),
            fx("sat2", sat_drive=5, sat_mode=1, sat_tone=14000, sat_mix=0.6),
            fx("verb2", verb_predelay=0.01, verb_decay=0.62, verb_damp=6000, verb_mix=0.14),
        ]),
        track("BASS", [64, 206, 174], "cream", bass, clip("Pulse Bass", bass_notes()), 0.72, effects=[
            fx("comp2", comp_thresh=-14, comp_ratio=3, comp_atk=0.004, comp_rel=0.09, comp_makeup=2),
        ]),
        # the pad and arp step out of the bass's way: highpassed above its
        # harmonics, the pad's low-mids dipped where the bass growls
        track("PAD", [150, 110, 230], "juno2", pad, clip("Night Pad", pad_notes()), 0.52, poly=8, effects=[
            fx("eq2", eq_hpf_on=1, eq_hpf_hz=240, eq_p1_hz=450, eq_p1_db=-3, eq_p1_q=0.8),
            fx("chorus2", chorus_mode=0, chorus_mix=0.55),
            fx("verb2", verb_decay=0.88, verb_predelay=0.03, verb_mix=0.34, verb_damp=4500),
        ]),
        track("ARP", [250, 190, 80], "juno2", arp, clip("Glass Arp", arp_notes()), 0.5, poly=8, pan=0.15, effects=[
            fx("eq2", eq_hpf_on=1, eq_hpf_hz=320),
            fx("delay2", delay_sync=1, delay_div=3, delay_fb=0.42, delay_damp=3800, delay_mix=0.3),
            fx("chorus2", chorus_mode=1, chorus_mix=0.4),
        ]),
        track("LEAD", [90, 170, 250], "cream", lead, clip("Hook", lead_notes()), 0.62, effects=[
            fx("delay2", delay_sync=1, delay_div=4, delay_fb=0.35, delay_damp=4200, delay_mix=0.24),
            fx("verb2", verb_decay=0.82, verb_mix=0.26, verb_predelay=0.04),
        ]),
    ],
    "master": {"volume": 1.0, "effects": [
        fx("eq2", eq_hpf_on=1, eq_hpf_hz=28, eq_ls_hz=70, eq_ls_db=-1.5, eq_p1_hz=320, eq_p1_db=-1.5, eq_hs_hz=7000, eq_hs_db=3.5),
        fx("comp2", comp_thresh=-12, comp_ratio=2, comp_atk=0.012, comp_rel=0.25, comp_knee=8, comp_makeup=2),
        fx("limiter2", lim_gain=4, lim_ceil=-3.2, lim_rel=0.15),
    ]},
}

out = os.path.join(ROOT, "demos", "night_drive.slab")
with open(out, "w") as f:
    json.dump(project, f, indent=1)
print(out, sum(len(t["clips"][0]["notes"]) for t in project["tracks"]), "notes")
