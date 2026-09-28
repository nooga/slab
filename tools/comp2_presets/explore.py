import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import design
from tune import show
name = sys.argv[1]
base = design.D[name]
for spec in sys.argv[2:]:
    d = dict(base, p=dict(base["p"], **json.loads(spec)))
    for k in ("key", "gr", "lvl"):
        if k in d["p"]: d[k] = d["p"].pop(k)
    p, m = design.solve(name, d)
    print(f"{spec:52}", show("", m)[19:], {k: p[k] for k in ("thresh", "makeup")}, flush=True)
