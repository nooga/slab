"""Normalize a machine's preset levels to a loudness target, measured on the bench.

Loudness = the loudest 400 ms RMS window of the `held` case (single C3), so
plucks and pads compare fairly. Rewrites each preset's level control.

    python3 tools/bench/normalize_presets.py juno2 jn-level -18
"""
import json, glob, re, subprocess, sys, wave
import numpy as np

machine, level_id, target = sys.argv[1], sys.argv[2], float(sys.argv[3])

def loud(preset=None, level=None):
    cmd = ['zig', 'build', 'bench', '--', machine, '--case=held', '--no-sheets']
    if preset: cmd.append('--preset=' + preset)
    if level is not None: cmd += ['-p', '%s=%g' % (level_id, level)]
    subprocess.run(cmd, capture_output=True, text=True, check=True)
    w = wave.open('scratch/bench/%s/held.wav' % machine)
    a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.uint8).reshape(-1, 3)
    x = (a[:, 0].astype(np.int32) | (a[:, 1].astype(np.int32) << 8) | (a[:, 2].astype(np.int32) << 16))
    x = np.where(x >= 1 << 23, x - (1 << 24), x)[::2] / float(1 << 23)
    win = int(0.4 * 48000); hop = 2400
    best = max(np.sqrt(np.mean(x[i:i + win] ** 2)) for i in range(0, len(x) - win, hop))
    return 20 * np.log10(best * np.sqrt(2) + 1e-12)   # sine-referenced dBFS

for f in sorted(glob.glob('machines/%s/presets/**/*.preset' % machine, recursive=True)):
    d = json.load(open(f)); name = f.split('/presets/')[1][:-7]
    lv = d['params'].get(level_id)
    if lv is None: print('skip (no level)', name); continue
    before = loud(name)
    new = min(1.0, lv * 10 ** ((target - before) / 20))
    d['params'][level_id] = round(new, 3); json.dump(d, open(f, 'w'))
    print('%-28s level %.3f -> %.3f  loud %6.1f -> %6.1f dB' % (name, lv, new, before, loud(name)))
print('default loud', round(loud(), 1))
