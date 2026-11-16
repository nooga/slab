# Tonewheel Organ and Rotary Speaker (implemented, 2026-11-11)

Two machines made for each other: `organ`, an instrument, and `rotary`,
an effect. `songs/organ_demo.py` plays one through the other.

## Tonewheel Organ (`machines/organ`, `kernels/06-voices/organ.fy`)

The model is the electromechanical organ: 91 wheels on a shaft that
never stops, each inducing a sine in its pickup, and keys that only
connect wheels to the output.

- **The wheels are shared.** They live in the machine's shared region
  (docs/04 §Shared state) and run once a sample, a semitone apart from
  C1 (32.7 Hz) to F#7 (5.9 kHz), from random start phases. Two keys that
  reach the same wheel get the same phase, so a chord is one waveform.
  The shared word's period is 1: a voice reads the wheels' outputs each
  sample.
- **A voice is a key's nine contacts**, one per drawbar: 16', 5 1/3',
  8', 4', 2 2/3', 2', 1 3/5', 1 1/3', 1' (wheels −12, +7, 0, +12, +19,
  +24, +28, +31, +36 from the key). A contact that asks for a wheel past
  either end gets the one an octave in (fold-back). 16 keys at once.
- **Drawbars** run 0 to 8 in 3 dB steps and are continuous, so they can
  be automated.
- **Velocity is travel, not level.** The nine contacts close one after
  another, over 10 ms at a soft touch and 1 ms at a hard one. Each makes
  at whatever point its wheel has reached; that is the key click. CLICK
  sets how fast one contact makes (4 ms to 0.16 ms).
- **PERC** is a decaying note of the key's 2nd or 3rd harmonic, FAST
  (0.2 s) or SLOW (0.7 s), NORM or SOFT. It fires only when a key goes
  down with none held, and all held keys share the one decay.
- **VIBRATO** is a scanner: a short delay read at a point swept at
  6.9 Hz. V1 to V3 are depths (±0.15, 0.3, 0.5 ms); C1 to C3 mix the
  same with the straight signal.
- **LEAK** is every wheel faintly, while a key is down. **DRIVE** is a
  preamp stage, bypassed at 0. The output is mono.

Left out: the manuals' own fold-back of 16' in the bottom octave (the
bottom twelve wheels are reachable instead), the lowest wheels' complex
waveform, the 1' drawbar muting with percussion on, and pedals.

## Rotary Speaker (`machines/rotary`, `kernels/07-effects/rotary.fy`)

A valve amp, a crossover at 800 Hz, a treble horn and a bass drum that
turn, and two microphones. The input is summed to mono; the stereo is
the microphones.

- **Each rotor is a delay line read at a moving point** (Doppler, up to
  ±0.55 ms for the horn and ±0.22 ms for the drum at DEPTH 1), with
  level and a low-pass that follow the angle: loud and bright facing the
  microphone, quiet and dull facing away. The horn also has a second,
  later read for the cabinet wall behind it, which bends the other way.
- **The microphones** sit SPREAD apart (up to half a turn). MIC is their
  distance: close is deep tremolo, far is more wall.
- **SPEED** is STOP, SLOW (0.8 Hz) or FAST (6.8 Hz); the SLOW and FAST
  rates have their own knobs. The horn reaches a new speed with a time
  constant near 1 s, the drum near 5 s, the drum turns the other way and
  13% slower. INERTIA scales both times. Fresh state starts at speed.
- **DRIVE** is the amp ahead of the crossover; BALANCE is horn against
  drum.

Automate SPEED with held points (`"fx0:speed"`, values 0, 1, 2).

## Cost

ReleaseFast, 48 kHz: the organ is 153 ns/sample with a four-note chord
(the wheels are most of it, and don't grow with polyphony); the rotary
is 107 ns/sample.
