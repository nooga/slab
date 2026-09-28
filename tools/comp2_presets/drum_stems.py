"""The drum group's input per song: the drum tracks soloed together, post
fader (their own inserts on), no master chain."""
import json, subprocess, sys, os, copy
binary, outdir = sys.argv[1], sys.argv[2]
DRUMS = {"glass_horizon": ["KIT", "SNARE", "KICK"], "paper_boulevard": ["KIT", "HATS"],
         "voltage_riot": ["KICK", "CLAP", "HATS", "PERC", "ROLL"]}
os.makedirs(outdir, exist_ok=True)
for song, names in DRUMS.items():
    p = json.load(open(f"songs/{song}.slab"))
    for u in p["tracks"]:
        u["solo"] = u["name"] in names; u["mute"] = False
        if u["name"] in names: u["output"] = None; u["sends"] = []
    p["master"]["effects"] = []; p["master"]["volume"] = 1.0
    path = f"{outdir}/{song}.DRUMS.slab"
    json.dump(p, open(path, "w"))
    subprocess.run([binary, path, "--render", path[:-5] + ".wav"], capture_output=True, start_new_session=True)
    print(path)
