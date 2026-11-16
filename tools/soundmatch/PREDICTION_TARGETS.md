# Prediction targets: ranges profile

Configured, not trained: 29 controls = 23 continuous + 6 categorical.
Every control has an edit gate; closed gates keep its current value.
Continuous controls predict normalized corrections. Categories predict a legal
option, not a fractional switch position. Known notes/routing remain inputs.

| Control | Type | Physical prediction range / options |
|---|---|---|
| Oscillator 1 waveform | Category | Triangle, saw, square, wide pulse, narrow pulse |
| Oscillator 2 waveform | Category | Triangle, saw, square, wide pulse, narrow pulse |
| Oscillator 1 range | Category | 32′, 16′, 8′, 4′, 2′ |
| Oscillator 2 range | Category | 32′, 16′, 8′, 4′, 2′ |
| Oscillator 3 range | Category | 32′, 16′, 8′, 4′, 2′ |
| Oscillator 1 level | Continuous | 0.2–1 |
| Oscillator 2 level | Continuous | 0–1 |
| Oscillator 3 level | Continuous | 0–0.7 |
| Oscillator 2 detune | Continuous | −0.15–+0.15 |
| Filter cutoff | Continuous, logarithmic | 200–5,000 Hz |
| Filter resonance (emphasis) | Continuous | 0.05–0.65 |
| Filter envelope amount (contour) | Continuous | 0.2–3 |
| Filter attack | Continuous, logarithmic | 0.001–1 s |
| Filter decay | Continuous, logarithmic | 0.05–0.8 s |
| Filter sustain | Continuous | 0–1 |
| Filter release | Continuous, logarithmic | 0.02–1 s |
| Amp attack | Continuous, logarithmic | 0.001–0.8 s |
| Amp decay | Continuous, logarithmic | 0.03–1.5 s |
| Amp sustain | Continuous | 0.1–1 |
| Amp release | Continuous, logarithmic | 0.03–0.4 s |
| LFO rate | Continuous, logarithmic | 0.15–12 Hz |
| LFO waveform | Category | Triangle, square, saw, sample-and-hold |
| LFO pitch amount | Continuous | 0–0.3 |
| LFO filter amount | Continuous | 0–0.5 |
| Drive | Continuous | 0.1–0.65 |
| Delay mix | Continuous | 0.03–0.3 |
| Delay feedback | Continuous | 0.1–0.45 |
| Compressor threshold | Continuous | −30–−12 dB |
| Cutoff automation sweep | Continuous, logarithmic | 0.6–1.8 × starting cutoff at beat 8 |

Oscillator 3's sub/free-oscillator mode is still a fixed known setting.
Its range switch is relevant in free-oscillator mode; the sub-octave switch
remains fixed. Oscillator 3 waveform/detune, oscillator sync, filter mode,
noise, glide, oscillator pitch envelope, and other unlisted machine controls
remain fixed known settings. Range switches have been removed from that
fixed context for the new profile. Notes, timing, velocities and chain
topology are not prediction targets. No training has run with the added ranges.
