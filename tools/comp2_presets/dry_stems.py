"""Render the signal each comp2 sees: a track's chain up to its comp2 at
unity fader, no sends, no master chain; plus the full mix after the master
eq (what the master comp sees)."""
import json, subprocess, sys, os, copy
from concurrent.futures import ThreadPoolExecutor
binary, outdir = sys.argv[1], sys.argv[2]
songs = {"glass_horizon": ["CR-78", "KIT", "SNARE", "KICK", "BASS", "VOICE", "PAD", "CHOIR"],
         "paper_boulevard": ["KIT", "BASS", "PAD", "E.PIANO"],
         "voltage_riot": ["BASS", "CLAP", "KICK"]}
os.makedirs(outdir, exist_ok=True)
jobs = []
for song, names in songs.items():
    d = json.load(open(f"songs/{song}.slab"))
    for i, t in enumerate(d["tracks"]):
        if t["name"] not in names: continue
        p = copy.deepcopy(d)
        for j, u in enumerate(p["tracks"]):
            u["solo"] = (j == i); u["mute"] = False
        tt = p["tracks"][i]
        fx = tt.get("effects", [])
        k = next((n for n, e in enumerate(fx) if e["machine"] == "comp2"), len(fx))
        tt["effects"] = fx[:k]
        tt["volume"] = 1.0; tt["pan"] = 0.0; tt["sends"] = []; tt.pop("automation", None)
        tt["output"] = None
        p["master"]["effects"] = []; p["master"]["volume"] = 1.0
        jobs.append((f"{song}.{t['name']}", p))
    p = copy.deepcopy(d)
    p["master"]["effects"] = [e for e in p["master"]["effects"] if e["machine"] == "eq2"]
    p["master"]["volume"] = 1.0
    jobs.append((f"{song}.MIX", p))
def run(job):
    name, proj = job
    path = os.path.join(outdir, name.replace(" ", "_").replace("+", "p") + ".slab")
    json.dump(proj, open(path, "w"))
    subprocess.run([binary, path, "--render", path[:-5] + ".wav"], capture_output=True, start_new_session=True)
    return name
with ThreadPoolExecutor(6) as ex:
    print(list(ex.map(run, jobs)))
