"""Sweat Geometry — modern peak-time techno, written to the ten rules
from Oscar (Underdog)'s "The ten rules (explained)". Original material.

130 BPM, A minor. How each rule lands:

 1 the pulse        four-on-the-floor kick tuned to A1, open hats on the
                    upbeat: head down on the kick, up on the hat
 2 syncopation      clap on 2 and 4, dub stabs on the 3-3-4-3 grid the
                    kick and hats leave empty, a rim between them
 3 playful kicks    the breakdown's kick breaks off the grid while
                    closed hats carry the pulse
 4 go hard          the whole kit is one 909 box through a VALVE stage, an
                    SSL bus and a parallel FET smash
 5 fill the lows    a rumble return (kick into a long dark verb, valve,
                    low-passed, ducked by the kick) plus a rolling
                    Profit-5 bass between the kicks. The DJ trick: the
                    whole mix high-passes up in each build and drops back
                    on the one
 6 add a 909        drum2 909-punch everywhere, processed as a group
 7 polymeter        the acid line is 7 steps long, the rim 10, the tom
                    6: they drift against the bar and meet again
 8 full / empty     the breakdown opens reverbs, delays and a pad, then
                    empties to a bell and the acid's echo
 9 articulate       every build ends in a beat of silence and the drop
                    returns to kick and clap first
10 dance / light    bells, zaps and delay throws: ear candy that stays
                    light over the weight

    PYTHONPATH=tools python3 songs/sweat_geometry.py --render --stems
    zig-out/bin/slab songs/sweat_geometry.slab
"""
from slabkit import Song, fx

song = Song("Sweat Geometry", bpm=130, key="A minor")

# ── form: 144 bars, 4:26 ───────────────────────────────────────────────
intro = song.section("intro", 16)
groove = song.section("groove", 16)
build1 = song.section("build1", 8)
drop1 = song.section("drop1", 32)
brk = song.section("break", 24)
drop2 = song.section("drop2", 32)
outro = song.section("outro", 16)

BAR = song.bar_beats
DROPS = (drop1, drop2)
KICK_SECTIONS = (intro, groove, build1, drop1, drop2, outro)

# ── buses ──────────────────────────────────────────────────────────────
# Everything goes through MIX so a build can high-pass the whole record
# (rule 5's DJ trick). fx0 is the automated filter.
mix = song.bus("MIX", fx=[fx("eq2", hpf_on="ON", hpf_hz=20)])
# Rule 6: the kit speaks as one box. VALVE colours it all, bus2 glues,
# a FET smash underneath fattens the tails between hits.
drums = song.bus("909", volume=1.0, output=mix, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=28, p1_hz=320, p1_db=-2.5, p1_q=1.0),
    fx("sat2", "valve-crunch", drive=10, mix=0.55),
    fx("bus2", "drum-bus", thresh=-20, makeup=3.0, color=0.35),
    fx("char2", "fet-smash", mix=0.3),
])
# shared spaces: one hall, one dub delay (their volumes ride in the break)
space = song.bus("SPACE", output=mix, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=300, hs_hz=7000, hs_db=-4),
    fx("verb2", "big-hall", mix=1.0, predelay=0.03, damp=4000),
])
dub = song.bus("DUB", output=mix, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=350),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.5, damp=2600, mix=1.0),
    fx("verb2", "medium-plate", mix=0.25),
])

# ── drums ──────────────────────────────────────────────────────────────
kick = song.track("KICK", "drum2", "909-punch", volume=1.0, output=drums, params=dict(
    # A1 body with the sweep and drive reaching 80–120 Hz, where it's felt
    kick_tune=55, kick_sweep=11, kick_bend=0.045, kick_decay=0.34, kick_click=0.45,
    kick_drive=4.5, kick_level=1.0, master_drive=1.4), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=30, ls_hz=90, ls_db=1.5, p1_hz=280, p1_db=-4, p1_q=1.2, p2_hz=3800, p2_db=2),
])
# Rule 5: the rumble. The kick feeds a long, dark verb; valve grit gives it
# harmonics, the EQ keeps only the lows, and the kick ducks it hard so it
# swells in the gaps: low end that moves between the pulses.
rumble = song.bus("RUMBLE", volume=0.6, output=mix, fx=[
    fx("verb2", mix=1.0, decay=17.26, damp=1200, tone=1500, predelay=0.012, mod=4),
    fx("sat2", "valve-bass", drive=16, mix=0.8),
    fx("eq2", hpf_on="ON", hpf_hz=38, p1_hz=420, p1_db=-6, p1_q=0.7, hs_hz=1500, hs_db=-18),
    fx("comp2", key=kick, thresh=-34, ratio=10, knee=4, atk=0.0008, rel=0.16),
])
kick.send(rumble, -4)

# The real 909 (Reverb's TR-909 pack) for everything above the kick:
# clap, hats, ride, crash. The kick stays synthetic so it can sit on A1.
TR909 = "drums/roland-tr-909/kit"
CH, CH_SHORT, OH, CLP, RIM, CRASH, RIDE = 42, 84, 46, 39, 37, 49, 51
clap = song.track("CLAP", "sampler", TR909, volume=0.62, output=drums, params=dict(level=0.9), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=200, p1_hz=500, p1_db=-2, p2_hz=2400, p2_db=2),
    fx("comp2", ratio=1, thresh=0, makeup=18),   # the pack sits ~-19 dBFS
    fx("comp2", "rude-clap"),
    fx("verb2", "short-plate-room", mix=0.2),
])
clap.send(space, -20)
# ticking, not hissing: the short-decay hat, the top shelved off above 9 kHz
hats = song.track("HATS", "sampler", TR909, volume=0.42, pan=0.16, output=drums, params=dict(level=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=550, hs_hz=9000, hs_db=-5),
    fx("comp2", ratio=1, thresh=0, makeup=12),
])
ohat = song.track("OPEN HAT", "sampler", TR909, volume=0.40, pan=-0.12, output=drums, params=dict(level=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=500, hs_hz=9000, hs_db=-5),
    fx("comp2", ratio=1, thresh=0, makeup=11),
    fx("verb2", "small-room", mix=0.12),
])
ride = song.track("RIDE", "sampler", TR909, volume=0.3, pan=0.35, output=drums, params=dict(level=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=700, hs_hz=10000, hs_db=-4),
    fx("comp2", ratio=1, thresh=0, makeup=9),
])
# polymeter percussion: a rim (snare lane, tuned up, very short) on 10
# steps and a high tom on 6, through a little SP-1200 grit and the dub delay
perc = song.track("PERC", "drum2", "synthetic-tom-kit", volume=0.48, pan=0.3, output=drums, params=dict(
    tom_tune=210, tom_sweep=2.0, tom_decay=0.12, tom_drive=3.0,
    snare_tune=380, snare_decay=0.06, snare_sdec=0.04, snare_snap=1.0, snare_tone=3400), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=180, hs_hz=9000, hs_db=-4),
    fx("era", "sp1200", mix=0.5),
])
perc.send(dub, -14)
roll = song.track("ROLL", "drum2", "909-punch", volume=0.28, output=drums, params=dict(
    snare_decay=0.14, snare_tone=2800, snare_snap=0.9, snare_level=1.0), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=220),
    fx("verb2", "big-plate-hall", mix=0.25),
])
# the drop's downbeat: a long low boom and a crash into the hall
impact = song.track("IMPACT", "drum2", "808-boom", volume=0.5, output=mix, params=dict(
    kick_tune=44, kick_decay=1.6, kick_sweep=14, kick_drive=3.0, hat_ohdec=1.6, hat_tone=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=30, hs_hz=9000, hs_db=-4),
    fx("comp2", key=kick, thresh=-24, ratio=4, atk=0.001, rel=0.2),
])
impact.send(space, -8)

# ── bass ───────────────────────────────────────────────────────────────
# The rolling bass sits in the three 16ths between kicks. Profit-5's
# heat and feedback give it grit; the sub is kept lean, the 800 Hz growl
# pushed so it reads on small speakers too.
bass = song.track("BASS", "profit5", "heavy-bass", volume=1.25, output=mix, params=dict(
    cutoff=520, res=0.28, env=0.5, f_dec=0.16, f_sus=0.1, a_dec=0.2, a_sus=0.55, a_rel=0.05,
    heat=0.7, fbk=0.3, drive=0.7, vel=0.5, level=0.7), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=36, ls_hz=70, ls_db=-2, p1_hz=240, p1_db=-2, p2_hz=850, p2_db=3, p2_q=1.0),
    fx("comp2", "bass-leveler"),
    fx("sat2", "valve-bass", drive=10, mix=0.5),
    fx("comp2", key=kick, thresh=-30, ratio=5, knee=6, atk=0.001, rel=0.09),
])

# ── acid (rules 6 + 7) ─────────────────────────────────────────────────
# SM-24 through FUZZ and the dub delay. The line is 7 steps long, so it
# circles the bar: accents land somewhere new every time round.
acid = song.track("ACID", "ms20", "acid-bass", volume=0.41, pan=0.05, output=mix, params=dict(
    cutoff=300, resonance=1.6, env_amount=4.0, drive=1.6, filter_decay=0.22), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=150, p1_hz=400, p1_db=-2, p2_hz=1600, p2_db=1.5, hs_hz=7000, hs_db=-3),
    fx("sat2", drive=12, mode="FUZZ", tone=5000, mix=0.3),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.38, damp=3000, mix=0.14),
])
acid.send(space, -18)
# drop 2's second voice: the same idea on 5 steps an octave up, screaming
acid2 = song.track("ACID HI", "ms20", "acid-bass", volume=0.24, pan=-0.3, output=mix, params=dict(
    cutoff=900, resonance=1.8, env_amount=4.5, drive=3.0), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=300, hs_hz=7000, hs_db=-4),
    fx("delay2", sync="SYNC", div="1/16", fb=0.4, damp=3800, mix=0.2),
])
acid2.send(dub, -12)

# ── chords, pad ────────────────────────────────────────────────────────
# dub-techno stabs: a short Profit-5 pluck, filter opened by automation,
# thrown into the delay
stab = song.track("STAB", "profit5", "pluck-keys", volume=1.25, pan=-0.18, output=mix, params=dict(
    cutoff=700, res=0.3, env=0.55, f_dec=0.2, a_dec=0.35, a_rel=0.15, fine_b=0.1, age=0.5, level=0.95), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=240, p1_hz=450, p1_db=-3),
    fx("chorus2", "juno-i"),
    fx("comp2", key=kick, thresh=-28, ratio=4, atk=0.001, rel=0.12),
])
stab.send(dub, -6)
stab.send(space, -12)
pad = song.track("PAD", "profit5", "ob-pad", volume=0.36, output=mix, params=dict(cutoff=900), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=260, p1_hz=500, p1_db=-3, hs_hz=8000, hs_db=-3),
    fx("chorus2", "juno-ii"),
    fx("comp2", key=kick, thresh=-26, ratio=4, atk=0.002, rel=0.2),
    fx("verb2", "big-plate-hall", mix=0.35),
])

# ── ear candy ──────────────────────────────────────────────────────────
# Poly-mod bells, one each side: the high sparkle comes from these, not hats
bell_l = song.track("BELL L", "profit5", "poly-mod-bell", volume=0.22, pan=-0.75, params=dict(a_dec=1.3, a_rel=0.6, f_dec=0.9, f_rel=0.6), output=mix, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=500, hs_hz=9000, hs_db=-2),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.45, damp=4500, mix=0.3),
])
bell_r = song.track("BELL R", "profit5", "poly-mod-bell", volume=0.27, pan=0.75, params=dict(a_dec=1.3, a_rel=0.6, f_dec=0.9, f_rel=0.6), output=mix, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=500, hs_hz=9000, hs_db=-2),
    fx("delay2", sync="SYNC", div="1/4", fb=0.4, damp=4500, mix=0.3),
])
bell_l.send(space, -10)
bell_r.send(space, -10)
# laser zaps: an SM-24 blip with the envelope bending the pitch down
zap = song.track("ZAP", "ms20", "aggressive-fill-lead", volume=0.3, pan=0.45, output=mix, params=dict(
    eg_pitch=0.8, amp_decay=0.08, amp_sustain=0.0, amp_release=0.05, filter_decay=0.08,
    cutoff=2500, resonance=1.2), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=400, hs_hz=9000, hs_db=-3),
])
zap.send(dub, -4)

# ── CMI: warped washes and industrial hits ─────────────────────────────
# The Tibetan chant loop, clocked down to 11 kHz: an octave-ish lower,
# grainy, the loop seam turned into a slow pulse. Long attack, drowned in
# the cathedral: a reverb wash, not a pad you hear as notes.
wash = song.track("WASH", "unfairlight", "cmi-classic/choral/tibet", volume=0.22, output=mix, params=dict(
    rate=11000, atk=2.5, damp=4.0, filter=120, vib_depth=0.15, vib_rate=0.3, vol=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=220, p1_hz=600, p1_db=-3, hs_hz=7000, hs_db=-3),
    fx("chorus2", "slow-woozy-mod"),
    fx("comp2", key=kick, thresh=-30, ratio=4, atk=0.002, rel=0.25),
    fx("verb2", "cathedral", mix=0.55),
])
# a choir "ahh" held and looped, warped slow, for the breakdown's top
choir = song.track("CHOIR", "unfairlight", "cmi-classic/choral/ahh1", volume=0.05, pan=0.2, output=mix, params=dict(
    rate=16000, loop="ON", loop_start=40, loop_end=118, atk=1.8, damp=5.0, vib_depth=0.2, vib_rate=4.5, vol=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=300, hs_hz=8000, hs_db=-3),
    fx("chorus2", "string-ensemble"),
    fx("verb2", "long-melancholy-verb", mix=0.5),
])
choir.send(dub, -12)
# factory loop, tuned down and filtered: machinery under drop 2
factory = song.track("FACTORY", "unfairlight", "cmi-iix/34-construction/factry01", volume=0.85, pan=-0.2, output=mix, params=dict(
    rate=14000, atk=0.8, damp=2.0, vol=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=350, p2_hz=2500, p2_db=2, hs_hz=8000, hs_db=-4),
    fx("comp2", key=kick, thresh=-32, ratio=6, atk=0.001, rel=0.14),
    fx("delay2", sync="SYNC", div="1/4", fb=0.3, damp=3000, mix=0.2),
])
# steel door slammed and pitched up: an industrial hit on an 11-step cycle
metal = song.track("METAL", "unfairlight", "cmi-iix/41-misc-fx-2/steeldor", volume=0.23, pan=0.4, output=drums, params=dict(
    rate=28000, damp=0.25, vol=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=400, hs_hz=9000, hs_db=-4),
])
metal.send(dub, -10)
metal.send(space, -14)
# the big slams: the jail door into the hall at the breakdown and drop 2
slam = song.track("SLAM", "unfairlight", "cmi-iix/41-misc-fx-2/jaildoor", volume=0.22, output=mix, params=dict(
    rate=18000, damp=3.0, vol=0.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=90, hs_hz=8000, hs_db=-3),
    fx("verb2", "cathedral", mix=0.45),
])
# Mog Passenger drone: two saws a hair apart at A1, ladder nearly shut,
# the LFO breathing on the cutoff. It holds the lows while the break's
# kick plays around the grid (rules 3 + 5).
drone = song.track("DRONE", "cream", "growl", volume=0.35, output=mix, params=dict(
    range1="16", range2="16", detune2=-0.12, lvl3=0.4, drive=0.7, cutoff=180, emphasis=0.35, contour=0.6,
    a_atk=1.2, a_sus=1.0, a_rel=1.5, f_atk=1.5, f_dec=4.0, f_sus=0.6,
    lfo_rate=0.12, lfo_wave="TRI", lfo_cut=0.8, age=0.5, level=0.55), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=32, ls_hz=70, ls_db=-2, p2_hz=800, p2_db=2),
    fx("comp2", key=kick, thresh=-30, ratio=6, atk=0.001, rel=0.15),
])

# ── risers ─────────────────────────────────────────────────────────────
# white noise through the SM-24's filter; the cutoff rides up each build
noise = song.track("NOISE", "ms20", "rising-filter-fx", volume=0.11, output=mix, params=dict(
    saw_level=0.0, pulse_level=0.0, noise_level=1.0, env_amount=0.0, cutoff=300, resonance=0.9,
    hpf_cutoff=300, amp_attack=0.5, amp_sustain=1.0, amp_release=1.5, level=0.6), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=400, hs_hz=10000, hs_db=-3),
])
noise.send(space, -6)
# a synced Profit-5 note bending up an octave through the build
lift = song.track("LIFT", "profit5", "sync-lead", volume=0.24, pan=0.1, output=mix, params=dict(
    a_atk=1.5, a_rel=0.6, cutoff=1800), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=300, hs_hz=8000, hs_db=-3),
])
lift.send(space, -6)

# ── patterns ───────────────────────────────────────────────────────────
FOUR = "x...x...x...x..."
OFFBEAT = "..x...x...x...x."
HATS16 = "xoxoXoxoxoxoXoxo"
CLAP = "....x.......x..."
ROLLING = ".xxx.xxx.xxx.xxx"
ROLL_TURN = ".xxx.xxx.xxx.xob"           # the 4th bar turns over
STABS = "...x..x...x..x.."                 # 3-3-4-3: the gaps the kick leaves
RIM10 = "..x..x.x.."                       # 10 steps: meets the bar every 5 bars
TOM6 = "x....."                            # 6 steps: a dotted-8th cycle across the bar
# 7 steps; accents and slides make it (the 303 idiom)
ACID7 = "A2 . A3! A2 C3~ E3 G2"
ACID7B = "A2 A3! . C3~ D3 A2! G3"
ACID5 = "A3! . C4~ E4 G3"
BASS_PROG = "Am Am Am Am F F G G"
STAB_PROG = "Am9 Am9 Am9 Am9 Fmaj7 Fmaj7 G6 G6"


def kicks(sec, bars=None, at_bar=0, pattern=FOUR, vel=None):
    return kick.clip(sec, at_bar=at_bar, bars=bars or sec.bars - at_bar).drums({"kick": pattern}, vel=vel)


def pull(clip, beats=1):
    """Silence the last `beats` of a clip: the breath before the drop."""
    clip.notes = [n for n in clip.notes if n["start"] < clip.length - beats - 1e-9]
    return clip


def build(sec, bars=8):
    """The last `bars` of `sec`: a snare roll 8ths → 16ths → 32nds, the
    noise sweep, the lift bending up an octave, and the whole mix
    high-passing up to 220 Hz (rule 5's DJ trick), all into a beat of
    silence. The filter snaps back on the drop's one."""
    first = sec.bars - bars
    t0 = sec.start + first * BAR
    t1 = sec.start + sec.length
    r = roll.clip(sec, at_bar=first, bars=bars)
    half = bars // 2
    r.drums({"snare": "x...x...x...x.x."}, bars=half)
    r.drums({"snare": "x.x.x.x.x.x.x.x."}, at=half * BAR, bars=bars - half - 2)
    r.drums({"snare": "xxxxxxxxxxxxxxxx"}, at=(bars - 2) * BAR, bars=1)
    r.drums({"snare": "xxxxxxxxxxxxxxxx"}, at=(bars - 1) * BAR, bars=1, step=0.125)
    pull(r)
    total = bars * BAR
    r.velocities(lambda n: 38 + 89 * (n["start"] / total) ** 1.4)
    nz = noise.clip(sec, at_bar=first, bars=bars)
    nz.note(69, 0, total - 1, 100)
    noise.ramp("cutoff", t0, t1 - 1, 300, 9000, tension=-0.5)
    noise.automate("cutoff", (t1 + 8, 300))
    lf = lift.clip(sec, at_bar=first, bars=bars)
    lf.note(57, 0, total - 1, 90)
    lf.bend([(0, 0), (total - 1, 12, "curve", -0.4)])
    # the DJ trick: the lows leave for the last four bars, return on the one
    mix.automate("fx0:hpf_hz", (t1 - 4 * BAR, 20, "curve", -0.5), (t1 - 1, 220, "hold"), (t1, 20))


def drop_hit(sec):
    c = impact.clip(sec, bars=2)
    c.note(36, 0, 1.0, 127)
    c.note(46, 0, 1.0, 110)


def bells(track, sec, at_bar, bars, line, vel=86):
    """A sparse bell phrase every 4 bars: short figures, lots of rest."""
    track.clip(sec, at_bar=at_bar, bars=bars).melody(line, vel=vel).repeat(4 * BAR)


BELL_A = "r:2.75 E6:.25 A6:.5 r:.5 | r:3 G6:.25 E6:.25 D6:.5 | r:4 | r:1.5 C7:.25 A6:1 r:1.25"
BELL_B = "r:1 A5:.25 r:.75 E6:.25 r:1.75 | r:4 | r:2.5 C6:.25 D6:.25 E6:1 | r:4"


def zaps(sec, at_bar, bars, pattern="...............x|..........x.....|...............x|......x.x......."):
    zap.clip(sec, at_bar=at_bar, bars=bars).drums({72: pattern})


# ── intro: the pulse, then the rumble under it (rules 1, 5) ────────────
kicks(intro, bars=15)
kick.clip(intro, at_bar=15, bars=1, name="intro turn").drums({"kick": "x...x...x...x.x."})
ohat.clip(intro, at_bar=4).drums({OH: OFFBEAT}).humanize(time=0.002, vel=4)
perc.clip(intro, at_bar=8).drums({"tom": TOM6, "snare": RIM10}, vel={"x": 88})
# the acid peeks in, filter nearly shut
acid.clip(intro, at_bar=12).seq(ACID7, vel=80, accent=110)
stab.clip(intro, at_bar=8).chords("Am9", "...x............|................", near=62, vel=80, gate=0.3)
bells(bell_r, intro, 8, 8, BELL_B, vel=70)

# ── groove: clap, 16ths, the rolling bass (rule 2) ─────────────────────
kicks(groove)
clap.clip(groove).drums({CLP: CLAP})
hats.clip(groove).drums({CH: HATS16}).swing(0.53).humanize(time=0.002, vel=6)
ohat.clip(groove).drums({OH: OFFBEAT}).humanize(time=0.002, vel=4)
perc.clip(groove).drums({"tom": TOM6, "snare": RIM10})
bass.clip(groove).bass("Am", ROLLING, octave=1, vel=104, gate=0.6)
acid.clip(groove).seq(ACID7, vel=86, accent=116)
stab.clip(groove, at_bar=8).chords(STAB_PROG, STABS, near=62, voices=3, vel=86, gate=0.3)
zaps(groove, 12, 4)

# ── build 1 ────────────────────────────────────────────────────────────
pull(kicks(build1, bars=7))
kick.clip(build1, at_bar=7, bars=1, name="build turn").drums({"kick": "x...x...x.x.x..."})
clap.clip(build1, bars=7).drums({CLP: CLAP})
hats.clip(build1).drums({CH: HATS16}).swing(0.53).humanize(time=0.002, vel=6)
pull(ohat.clip(build1).drums({OH: OFFBEAT}))
pull(bass.clip(build1, bars=6).bass("Am", ROLLING, octave=1, vel=104, gate=0.6), 0)
pull(acid.clip(build1).seq(ACID7B, vel=92, accent=122))
pull(stab.clip(build1).chords("Am9", STABS, near=62, voices=3, vel=88, gate=0.3))
build(build1)

# ── drops (rules 4, 5, 6: everything, hard) ────────────────────────────
for sec in DROPS:
    drop_hit(sec)
    kicks(sec)
    clap.clip(sec).drums({CLP: CLAP})
    hats.clip(sec).drums({CH: HATS16}).swing(0.53).humanize(time=0.002, vel=6)
    ohat.clip(sec).drums({OH: OFFBEAT}).humanize(time=0.002, vel=4)
    perc.clip(sec).drums({"tom": TOM6, "snare": RIM10})
    bass.clip(sec).bass(BASS_PROG, ROLL_TURN, octave=1, vel=108, gate=0.62)
    acid.clip(sec).seq(ACID7 if sec is drop1 else ACID7B, vel=94, accent=124)
    stab.clip(sec).chords(STAB_PROG, STABS, near=62, voices=3, vel=94, gate=0.3)
    bells(bell_l, sec, 8, 8, BELL_A)
    bells(bell_r, sec, 16, 16, BELL_B)
    zaps(sec, 4, 4)
    zaps(sec, 24, 4)
    # an 8-bar turn: the snare roll into bar 17 keeps the drop moving
    roll.clip(sec, at_bar=15, bars=1).drums({"snare": "........x.x.xxxx"}).velocities(lambda n: 60 + 40 * n["start"] / 4)

# drop 2 is the peak: the high acid on 5 steps, a denser top
acid2.clip(drop2, at_bar=8, bars=24).seq(ACID5, vel=96, accent=124)
bells(bell_l, drop2, 24, 8, BELL_A, vel=92)

# ── break (rules 3, 8): open up, empty out, tease ──────────────────────
# bars 0–8: pad, a bell, the acid's echo; nothing on the pulse
pad.clip(brk, bars=16).chords("Am9:8 Fmaj7:8 G6:8 Am9:8", near=60, spread=True, vel=76)
bells(bell_l, brk, 0, 8, BELL_A, vel=76)
bells(bell_r, brk, 4, 12, BELL_B, vel=72)
acid.clip(brk, bars=8).seq(ACID7, vel=78, accent=104)
stab.clip(brk, at_bar=4, bars=4).chords("Fmaj7", "...x............", near=62, vel=76, gate=0.3)
# bars 8–16: a playful kick off the grid; closed hats hold the pulse
kick.clip(brk, at_bar=8, bars=8, name="playful").drums(
    {"kick": "x.....x...x.....|x.....x..x..x..."}, vel={"x": 104})
hats.clip(brk, at_bar=8, bars=8).drums({CH: "..x...x...x...x."}).humanize(time=0.002, vel=5)
perc.clip(brk, at_bar=10, bars=6).drums({"tom": TOM6, "snare": RIM10}, vel={"x": 80})
acid.clip(brk, at_bar=8, bars=16).seq(ACID7B, vel=86, accent=118)
# bars 16–24: the long build back
bass.clip(brk, at_bar=16, bars=6).bass("Am", ROLLING, octave=1, vel=98, gate=0.55)
pad.clip(brk, at_bar=16, bars=8).chords("Am9", near=60, spread=True, vel=70)
pull(kick.clip(brk, at_bar=20, bars=4, name="return").drums({"kick": FOUR}))
hats.clip(brk, at_bar=16, bars=8).drums({CH: HATS16}).swing(0.53)
build(brk)

# ── outro: back to the pulse and the syncopation (rule 9) ──────────────
kicks(outro)
clap.clip(outro, bars=12).drums({CLP: CLAP})
hats.clip(outro, bars=8).drums({CH: HATS16}).swing(0.53).humanize(time=0.002, vel=6)
ohat.clip(outro, bars=12).drums({OH: OFFBEAT})
perc.clip(outro).drums({"tom": TOM6, "snare": RIM10})
bass.clip(outro, bars=8).bass("Am", ROLLING, octave=1, vel=100, gate=0.58)
acid.clip(outro, bars=12).seq(ACID7, vel=86, accent=114)
bells(bell_r, outro, 4, 8, BELL_B, vel=66)
for c in (kick.clips[-1], perc.clips[-1]):
    c.velocities(lambda n, c=c: n["vel"] * (1 - 0.35 * n["start"] / c.length))

# ── CMI layers, ride, drone ────────────────────────────────────────────
A1, A2, E3, A3 = 33, 45, 52, 57
wash.clip(intro, at_bar=4, bars=12).chord([A2, E3], 0, 12 * BAR - 1, 84)
wash.clip(brk, bars=24).chord([A2, E3, A3], 0, 24 * BAR - 2, 90)
wash.clip(outro, at_bar=8, bars=8).chord([A2, E3], 0, 8 * BAR, 76)
choir.clip(brk, bars=16).chords("Am9:8 Fmaj7:8 G6:8 Am9:8", near=67, voices=3, vel=80)
choir.clip(drop2, at_bar=24, bars=8).chords("Am9:16 Fmaj7:8 G6:8", near=69, voices=3, vel=70)
factory.clip(brk, at_bar=8, bars=8).note(A2, 0, 8 * BAR - 0.5, 80)
factory.clip(drop2, bars=32).note(A2, 0, 32 * BAR - 0.5, 90)
metal.clip(drop1, at_bar=16, bars=16).drums({60: "X.........."}, vel={"X": 100})
metal.clip(drop2, bars=32).drums({60: "X....x....."}, vel={"X": 108, "x": 72})
for sec, at in ((brk, 0), (drop2, 0)):
    slam.clip(sec, at_bar=at, bars=2).note(60, 0, 3, 110)
drone.clip(brk, bars=22).note(A1, 0, 22 * BAR - 1, 96)
# crash on each drop's one, the ride 8ths lifting the second half of each drop
for sec in DROPS:
    ride.clip(sec, bars=1, name="crash").note(CRASH, 0, 1.0, 118)
    ride.clip(sec, at_bar=16, bars=16).drums({RIDE: "x.o.x.o.x.o.x.o."}).humanize(time=0.002, vel=5)

# ── automation: the filters do the arranging ───────────────────────────
S = lambda sec, bar=0: sec.start + bar * BAR  # noqa: E731
# acid: shut in the intro, opening across the groove, wide in the build,
# breathing within each drop, dark then opening again in the break
acid.automate("cutoff",
              (S(intro, 12), 200), (S(groove), 260, "curve", -0.4), (S(build1), 900, "curve", -0.3),
              (S(drop1) - 1, 2200), (S(drop1), 700, "curve", -0.3), (S(drop1, 16), 1800, "curve", 0.3),
              (S(drop1, 24), 900, "curve", -0.4), (S(brk) - 0.5, 2600),
              (S(brk), 400, "curve", -0.5), (S(brk, 16), 1200, "curve", -0.4), (S(drop2) - 1, 3200),
              (S(drop2), 900, "curve", -0.3), (S(drop2, 16), 2600, "curve", 0.3), (S(drop2, 28), 3400),
              (S(outro), 1400, "curve", 0.4), (S(outro, 12), 250))
acid.automate("resonance", (S(intro), 1.4), (S(drop1), 1.5, "curve", -0.3), (S(drop2, 16), 1.85), (S(outro), 1.5))
# delay throws: the acid's echo blooms at phrase ends and in the break
acid.automate("fx2:mix", (S(intro), 0.12), (S(drop1, 7, ) + 2, 0.12), (S(drop1, 8), 0.45), (S(drop1, 8) + 2, 0.12),
              (S(drop1, 23) + 2, 0.12), (S(drop1, 24), 0.45), (S(drop1, 24) + 2, 0.12),
              (S(brk), 0.4), (S(brk, 16), 0.2), (S(drop2), 0.12), (S(drop2, 15) + 2, 0.12), (S(drop2, 16), 0.5),
              (S(drop2, 16) + 2, 0.12), (S(outro, 8), 0.12), (S(outro, 12), 0.5))
acid2.ramp("cutoff", S(drop2, 8), S(drop2, 28), 700, 3000, tension=-0.3)
# stabs: dark in the groove, open in the drops, a slow sweep up across drop 2
stab.automate("cutoff", (S(intro), 500), (S(groove, 8), 450, "curve", -0.4), (S(build1) + 30, 1400),
              (S(drop1), 900, "curve", -0.3), (S(drop1, 32), 1800), (S(drop2), 800, "curve", -0.4), (S(drop2, 32), 2800))
bass.automate("cutoff", (S(groove), 360, "curve", -0.3), (S(drop1), 560), (S(drop1, 32), 620),
              (S(brk, 16), 300, "curve", -0.4), (S(drop2), 600), (S(drop2, 32), 700), (S(outro, 8), 420))
pad.ramp("cutoff", S(brk), S(brk, 16), 500, 2600, tension=-0.3)
# rule 8: the spaces open in the break and close for the drop
space.automate("volume", (S(intro), 0.7), (S(brk) - 2, 0.7), (S(brk), 1.1), (S(brk, 16), 1.0), (S(brk, 24) - 1, 1.25), (S(drop2), 0.7))
dub.automate("volume", (S(intro), 0.8), (S(brk) - 2, 0.8), (S(brk), 1.15), (S(brk, 16), 0.9), (S(drop2), 0.8))
rumble.automate("volume", (S(intro), 0.7), (S(groove), 0.9), (S(drop2), 1.0), (S(outro, 8), 1.0), (S(outro, 16), 0.6))

# ── mix rides ──────────────────────────────────────────────────────────
bass.ride({groove: (-5, 0)})
clap.ride({drop2: 1})
# the break is the quiet one: the whole mix sits back, the build brings it up
mix.ride({brk: (-5, -2), build1: -1.5})

# ── master: loud and dense, under the knee ─────────────────────────────
song.master(fx=[
    fx("eq2", hpf_on="ON", hpf_hz=24, hs_hz=12000, hs_db=1.0),
    fx("multi2", "master-balance", mlo_thresh=-20, mlo_gain=-1.0, mmid_gain=2.0, mhi_gain=1.5),
    fx("limiter2", gain=10.0, ceil=-1.0),
])

if __name__ == "__main__":
    import sys
    if "--render" in sys.argv:
        song.render(stems="--stems" in sys.argv)
    else:
        song.save()
