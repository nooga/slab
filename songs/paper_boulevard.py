"""Paper Boulevard — late-80s sophisti-pop (Johnny Hates Jazz, Curiosity
Killed the Cat, Living in a Box territory). Original material.

106 BPM, D major, up a tone to E for the last chorus. Gated snare into a
plate, DX e-piano on the offbeats, Juno pad, brass stabs, a syncopated
Moog-ish bass, and a synth lead singing the vocal line.

    PYTHONPATH=tools python3 songs/paper_boulevard.py
    zig-out/bin/slab songs/paper_boulevard.slab
"""
from slabkit import Song, fx

song = Song("Paper Boulevard", bpm=106, key="D major")

# ── form ───────────────────────────────────────────────────────────────
intro = song.section("intro", 8)
verse1 = song.section("verse1", 8)
pre1 = song.section("pre1", 4)
chorus1 = song.section("chorus1", 8)
verse2 = song.section("verse2", 8)
pre2 = song.section("pre2", 4)
chorus2 = song.section("chorus2", 8)
bridge = song.section("bridge", 8)
chorus3 = song.section("chorus3", 8)   # up a tone
outro = song.section("outro", 8)       # up a tone
end = song.section("end", 2)

VERSE = "Dmaj7 Bm7 Gmaj7 A7sus4:2 A7:2"
PRE = "Em7 F#m7 Gmaj7 A7sus4"
CHORUS = "Gmaj7 A F#m7 Bm7 Em7 A Dmaj7 A7sus4:2 A7:2"
BRIDGE = "Bbmaj7 C Am7 Dm7 Gm7 C Fmaj7 A7sus4:2 A7:2"
UP = 2  # the last-chorus key change, in semitones
LIFT = (chorus3, outro, end)

# ── melodies (the "vocal") ─────────────────────────────────────────────
VERSE_MEL = """
r:.5 A4:.5 F#4 A4 B4:1 A4 | F#4:1.5 E4:.5 D4:1 r | r:.5 B4:.5 B4 C#5 D5:1 B4 | A4:1.5 G4:.5 E4:1 r
r:.5 A4:.5 F#4 A4 D5:1 C#5 | B4:1.5 A4:.5 F#4:1 r | r:.5 G4:.5 G4 A4 B4:.75 A4 G4:.5 | A4:3 r:1
"""
PRE_MEL = """
r:.5 E4:.5 G4 B4 B4:1 A4 | r:.5 F#4:.5 A4 C#5 C#5:1 B4 | r:.5 G4:.5 B4 D5 E5:1 D5 | E5:2 F#5:1 E5
"""
HOOK_A = "F#5:1.5 E5:.5 D5:1 E5 | E5:1.5 C#5:.5 A4:2 | r:.5 A4:.5 C#5 E5 E5:1 D5 | D5:1.5 C#5:.5 B4:2"
HOOK_B = "r:.5 B4:.5 D5 E5 G5:1 F#5 | E5:1.5 D5:.5 C#5:1 E5 | F#5:1.5 E5:.5 D5:2 | r:1 A4:.5 B4 C#5 D5 E5:1"
HOOK = HOOK_A + " | " + HOOK_B
BRIDGE_MEL = """
D5:2 C5:1 A4 | G4:3 r:1 | E5:2 D5:1 C5 | A4:3 r:1
Bb4:2 A4:1 G4 | E4:2 G4 | A4:2 C5:1 E5 | E5:2 C#5
"""

# ── tracks ─────────────────────────────────────────────────────────────
kit = song.track("KIT", "drum2", "gated-snare-kit", volume=1.0, params=dict(
    kick_decay=0.3, snare_decay=0.26, snare_tone=2600, master_drive=1.25), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=32, p1_hz=420, p1_db=-2.5, p1_q=1.0, hs_hz=7000, hs_db=2),
    fx("comp2", "dry-drum-punch"),
    # the 80s snare: a bright plate, short enough to stay out of the vocal
    fx("verb2", "bright-plate", decay=0.7, predelay=0.012, mix=0.2, damp=7000),
])
hats = song.track("HATS", "drum2", "crisp-hat-kit", volume=1.0, pan=0.22,
                   params=dict(hat_level=1.5, master_level=1.0), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=500, hs_hz=9000, hs_db=-2),
    fx("verb2", "small-room", mix=0.12),
])
bass = song.track("BASS", "cream", "outstanding-funk-bass", volume=1.25, params=dict(
    cutoff=900, contour=2.6, glide=0.0, age=0.25, level=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=34, p1_hz=250, p1_db=-2, p1_q=1.2),
    fx("comp2", "bass-leveler"),
])
ep = song.track("E.PIANO", "fm86", "e-piano-1", volume=0.43, pan=-0.25, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=180, p2_hz=2800, p2_db=1.5),
    fx("chorus2", "wide-keys"),
    fx("verb2", "medium-plate", mix=0.18),
])
pad = song.track("PAD", "juno2", "wide-sunny-pad", volume=0.2, params=dict(level=0.5, age=0.4), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=260, p1_hz=500, p1_db=-3, hs_hz=8000, hs_db=-3),
    fx("chorus2", "juno-ii"),
    fx("verb2", "big-plate-hall", mix=0.3),
])
brass = song.track("BRASS", "juno2", "bright-brass-stab", volume=0.42, pan=0.18, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=220),
    fx("verb2", "medium-plate", mix=0.22),
])
bells = song.track("VIBES", "fm86", "vibe-1", volume=0.27, pan=0.35, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=400),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.3, damp=4000, mix=0.22),
])
lead = song.track("LEAD", "cream", "cream-lead", volume=0.35, params=dict(
    cutoff=1500, glide=0.035, age=0.5, emphasis=0.2), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=200, p2_hz=3000, p2_db=1.5),
    fx("delay2", sync="SYNC", div="1/4", fb=0.28, damp=3500, mix=0.18),
    fx("verb2", "plate", mix=0.22),
])

# ── drums ──────────────────────────────────────────────────────────────
GROOVE = {"kick": "x.....x...x.....", "snare": "....x.......x..."}
CHORUS_GROOVE = {"kick": "x.....x.x.....x.", "snare": "....x..o....x..."}
HALF = {"kick": "x.........x.....", "snare": "........x......."}
FILL = {"kick": "x.......", "snare": "....x.x.xoxoXxXX"}  # 1 bar, crescendo


def drum_section(sec, groove, fill=True, hats_pat="xoxoxoxoxoxoxoxo", open_hat=True, soft=False):
    c = kit.clip(sec)
    c.drums(groove, bars=sec.bars - (1 if fill else 0))
    if fill:
        c.drums({"kick": "x...............", "snare": "....x.x.xoxoXxXX", "tom": "........x.x.x..."},
                at=(sec.bars - 1) * 4, bars=1)
    if soft:  # verses play under the choruses: drum2's accent follows velocity
        c.velocities(lambda n: n["vel"] * 0.82)
    c.humanize(time=0.004, vel=5)
    h = hats.clip(sec)
    h.drums({"ch": hats_pat})
    if open_hat:
        h.drums({"oh": "..............x."})
        h.notes = [n for n in h.notes if not (n["pitch"] == 42 and n["start"] % 4 == 3.5)]
    h.swing(0.54).humanize(time=0.003, vel=8)


# the intro's drums enter after 4 bars with a fill
c = kit.clip(intro, at_bar=3, bars=5)
c.drums({"snare": "....x.x.xoxoXxXX", "tom": "........x.x.x..."}, bars=1)
c.drums(GROOVE, at=4, bars=4)
hats.clip(intro, at_bar=4).drums({"ch": "x.x.x.x.x.x.x.x."}).swing(0.54)
drum_section(verse1, GROOVE, open_hat=False, soft=True)
drum_section(pre1, GROOVE)
drum_section(chorus1, CHORUS_GROOVE)
drum_section(verse2, GROOVE, soft=True)
drum_section(pre2, GROOVE)
drum_section(chorus2, CHORUS_GROOVE, fill=False)
drum_section(bridge, HALF, hats_pat="x.x.x.x.x.x.x.x.", open_hat=False)
drum_section(chorus3, CHORUS_GROOVE)
drum_section(outro, CHORUS_GROOVE, fill=False)
kit.clip(end).drums({"kick": "x", "snare": "X"}, bars=1)
hats.clip(end).drums({"oh": "X"}, bars=1)
# the outro drums fade over its 8 bars
for clip in (kit.clips[-2], hats.clips[-2]):
    clip.velocities(lambda n: n["vel"] * (1 - 0.45 * n["start"] / 32))

# ── bass ───────────────────────────────────────────────────────────────
V_BASS = "x-..x.x.x-..o.x."
C_BASS = "x.xo..x.x.xo.5x."
for sec, prog, pat in [(verse1, VERSE, V_BASS), (pre1, PRE, V_BASS), (chorus1, CHORUS, C_BASS),
                       (verse2, VERSE, V_BASS), (pre2, PRE, V_BASS), (chorus2, CHORUS, C_BASS),
                       (bridge, BRIDGE, "x-------..x.o.x."), (chorus3, CHORUS, C_BASS), (outro, CHORUS, C_BASS)]:
    b = bass.clip(sec).bass(prog, pat, vel=88 if pat is V_BASS else 104)
    if sec in LIFT:
        b.transpose(UP)
    b.humanize(time=0.003, vel=6)
bass.clip(intro, at_bar=4).bass(CHORUS[CHORUS.index("Em7"):], "x-------x-..o...", vel=96)
bass.clip(end, bars=1).note("E1", 0, 3.5, 112)

# ── keys, pad, brass, vibes ────────────────────────────────────────────
EP_V = "..x..x....x..x.."        # offbeat comping
EP_C = "x..x..x...x..x.."
for sec, prog, pat in [(intro, CHORUS, EP_C), (verse1, VERSE, EP_V), (pre1, PRE, EP_V), (chorus1, CHORUS, EP_C),
                       (verse2, VERSE, EP_V), (pre2, PRE, EP_V), (chorus2, CHORUS, EP_C),
                       (bridge, BRIDGE, None), (chorus3, CHORUS, EP_C), (outro, CHORUS, EP_C)]:
    e = ep.clip(sec).chords(prog, pat, near=64, voices=4, vel=74 if pat is EP_V else 88, gate=0.9)
    if sec in LIFT:
        e.transpose(UP)
    e.humanize(time=0.004, vel=6)
ep.clip(end).chords("Dmaj7", near=64, gate=0.98).transpose(UP)

for sec, prog in [(intro, CHORUS), (pre1, PRE), (chorus1, CHORUS), (verse2, VERSE), (pre2, PRE),
                  (chorus2, CHORUS), (bridge, BRIDGE), (chorus3, CHORUS), (outro, CHORUS)]:
    p = pad.clip(sec).chords(prog, near=60, voices=4, spread=True, vel=70 if sec is verse2 else 80)
    if sec in LIFT:
        p.transpose(UP)
pad.clip(end).chords("Dmaj7", near=60, spread=True, vel=80).transpose(UP)

STABS = "......x.x......."
for sec in (chorus1, chorus2, chorus3):
    s = brass.clip(sec).chords(CHORUS, STABS, near=67, voices=4, vel=100, gate=0.45)
    if sec in LIFT:
        s.transpose(UP)
# brass pickup into each chorus
for sec in (pre1, pre2):
    brass.clip(sec, at_bar=3, bars=1).chords("A7sus4", "x.x.x.x.x-x-x---", near=67, vel=96, gate=0.5)
brass.clip(end, bars=1).chords("Dmaj7", "x", near=67, vel=110, gate=0.9).transpose(UP)

for sec in (chorus1, chorus2, chorus3, outro):
    v = bells.clip(sec).arp(CHORUS, [0, 2, 3, 1, 2, 4], rate=0.5, octave=5, vel=74, gate=0.6)
    if sec in LIFT:
        v.transpose(UP)

# ── lead ───────────────────────────────────────────────────────────────
lead.clip(intro, at_bar=4).melody(HOOK_B, vel=96)
for sec in (verse1, verse2):
    lead.clip(sec).melody(VERSE_MEL, vel=100)
for sec in (pre1, pre2):
    lead.clip(sec).melody(PRE_MEL, vel=104)
for sec in (chorus1, chorus2, chorus3, outro):
    m = lead.clip(sec).melody(HOOK, vel=108)
    if sec in LIFT:
        m.transpose(UP)
lead.clip(bridge).melody(BRIDGE_MEL, vel=98)
lead.clip(end, bars=1).melody("F#5:3.5", vel=100).transpose(UP)

# ── master ─────────────────────────────────────────────────────────────
song.master(fx=[
    fx("eq2", hpf_on="ON", hpf_hz=25, hs_hz=10000, hs_db=1.5),
    fx("comp2", "gentle-bus-glue"),
    fx("limiter2", gain=4.5, ceil=-3.2),
])

if __name__ == "__main__":
    import sys
    if "--render" in sys.argv:
        song.render(stems="--stems" in sys.argv)
    else:
        song.save()
