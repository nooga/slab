import json, re, subprocess, sys, os
from concurrent.futures import ThreadPoolExecutor
S = os.environ.get("S", "scratch/comp2-presets")
DRY = f"{S}/dry"
MATERIAL = {
    "bass-leveler": ["glass_horizon.BASS", "paper_boulevard.BASS", "voltage_riot.BASS"],
    "vocal-leveler": ["glass_horizon.VOICE"],
    "dialog-leveler": ["glass_horizon.VOICE"],
    "smooth-pad-comp": ["glass_horizon.PAD", "paper_boulevard.PAD", "glass_horizon.CHOIR", "paper_boulevard.E.PIANO"],
    "dry-drum-punch": ["glass_horizon.CR-78", "glass_horizon.KICK", "paper_boulevard.KIT", "voltage_riot.KICK"],
    "drum-smash": ["glass_horizon.KIT", "glass_horizon.SNARE", "paper_boulevard.KIT"],
    "rude-clap": ["voltage_riot.CLAP", "glass_horizon.SNARE"],
    "pump": ["voltage_riot.MIX", "paper_boulevard.MIX"],
    "audible-pump": ["voltage_riot.MIX", "paper_boulevard.MIX"],
    "bus-glue": ["glass_horizon.MIX", "paper_boulevard.MIX", "voltage_riot.MIX"],
    "gentle-bus-glue": ["glass_horizon.MIX", "paper_boulevard.MIX", "voltage_riot.MIX"],
    "gentle-glue": ["glass_horizon.MIX", "paper_boulevard.MIX", "voltage_riot.MIX"],
    "soft-master-glue": ["glass_horizon.MIX", "paper_boulevard.MIX", "voltage_riot.MIX"],
    "drum-bus": ["glass_horizon.DRUMS", "paper_boulevard.DRUMS", "voltage_riot.DRUMS"],
}
BENCH = None

def bench_bin():
    global BENCH
    if BENCH is None:
        out = subprocess.run(["zig", "build", "bench", "--", "--help"], capture_output=True, text=True)
        # find the built binary in the cache: newest 'bench' executable
        import glob
        cands = sorted(glob.glob(".zig-cache/o/*/bench"), key=os.path.getmtime)
        BENCH = cands[-1]
    return BENCH

def metrics(params, stem, preset=None):
    args = [bench_bin(), "machines/comp2", "--no-sheets", f"--input={DRY}/{stem}.wav", f"--out={S}/tb/{stem}-{os.getpid()}-{abs(hash(json.dumps(params,sort_keys=True)))}"]
    if preset: args.append(f"--preset={preset}")
    for k, v in params.items(): args += ["-p", f"comp-{k}={v}"]
    r = subprocess.run(args, capture_output=True, text=True)
    m = re.search(r"metrics: (.*)", r.stderr + r.stdout)
    if not m: raise SystemExit(r.stderr[-2000:])
    return {k: float(v) for k, v in (kv.split("=") for kv in m.group(1).split())}

def avg(params, stems, preset=None):
    with ThreadPoolExecutor(len(stems)) as ex:
        ms = list(ex.map(lambda s: metrics(params, s, preset), stems))
    return {k: sum(m[k] for m in ms) / len(ms) for k in ms[0]}, ms

def show(name, m):
    return (f"{name:18} g50 {m['g50']:6.2f} g10 {m['g10']:6.2f} g01 {m['g01']:6.2f} pump {m['pump']:4.2f} | "
            f"crest {m['crest_in']:5.2f}->{m['crest_out']:5.2f} spread {m['spread_in']:4.2f}->{m['spread_out']:4.2f} "
            f"t/b {m['tb_in']:5.2f}->{m['tb_out']:5.2f} | lvl {m['out_rms']-m['in_rms']:+5.2f}")

if __name__ == "__main__" and sys.argv[1] == "before":
    for p, stems in MATERIAL.items():
        m, _ = avg({}, stems, preset=p)
        print(show(p, m))
