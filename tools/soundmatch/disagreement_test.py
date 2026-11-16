#!/usr/bin/env python3
"""Prepare balanced blind metric disagreements from existing renders, without labels."""
import hashlib
import itertools
import json
from pathlib import Path
import random

ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'scratch/soundmatch-diverse-5k'
OUT=ROOT/'scratch/soundmatch-comparator-test'


def main():
    renders=json.loads((BASE/'renders.json').read_text())
    scores=json.loads((ROOT/'scratch/soundmatch-auraloss/scores.json').read_text())
    candidates=[]
    for row in scores:
        if row['severity']=='identity' or row['seed'] in [20305215,20305315,20305415,20305515]:continue
        rr=[r for r in renders if r['seed']==row['seed'] and r['kind']=='correction']
        old={r['model']:r['after'] for r in rr};old['unchanged']=rr[0]['before']
        paths={r['model']:r['wav'] for r in rr};paths['unchanged']=str(Path(rr[0]['source'])/'current.wav')
        for a,b in itertools.combinations(old,2):
            da=old[a]-old[b];db=row['scores'][a]-row['scores'][b]
            if da*db>=0 or min(abs(da),abs(db))<=1e-6:continue
            strength=min(abs(da)/max(old[a],old[b],1e-9),abs(db)/max(row['scores'][a],row['scores'][b],1e-9))
            candidates.append(dict(seed=row['seed'],group=row['group'],severity=row['severity'],strength=strength,
                models=[a,b],spectral={a:old[a],b:old[b]},auraloss={a:row['scores'][a],b:row['scores'][b]},paths={a:paths[a],b:paths[b]},reference=str(Path(rr[0]['source'])/'target.wav')))
    selected=[]
    for group in ['familiar','patch','phrase','joint']:
        used=set()
        for candidate in sorted([c for c in candidates if c['group']==group],key=lambda c:(-c['strength'],c['seed'],c['models'])):
            if candidate['seed'] in used:continue
            selected.append(candidate);used.add(candidate['seed'])
            if len(used)==3:break
        assert len(used)==3
    rng=random.Random(20261103);rng.shuffle(selected)
    sides=['A']*6+['B']*6;rng.shuffle(sides)
    trials=[];keys={}
    for i,(c,side) in enumerate(zip(selected,sides),1):
        tid=f'pair-{i:02d}';other='B' if side=='A' else 'A'
        preferred=min(c['auraloss'],key=c['auraloss'].get);alternative=next(m for m in c['models'] if m!=preferred)
        assert min(c['spectral'],key=c['spectral'].get)==alternative
        trials.append(dict(id=tid,sources={'reference':c['reference'],side:c['paths'][preferred],other:c['paths'][alternative]}))
        keys[tid]=dict(**c,assignment={side:preferred,other:alternative},auraloss_choice=side,spectral_choice=other)
    OUT.mkdir(exist_ok=False)
    (OUT/'manifest.json').write_text(json.dumps(dict(experiment='comparator-disagreement-v1',title='Comparator disagreements',trials=trials),indent=2))
    (OUT/'blind-key.json').write_text(json.dumps(keys,indent=2))
    (OUT/'protocol.json').write_text(json.dumps(dict(candidate_pairs=len(candidates),candidate_seeds=len({c['seed'] for c in candidates}),selection='Three strongest rank reversals per family, distinct seeds, strength=min(relative gap in either metric). Excludes identity and four prior montage seeds. No listening labels used.',balance='Auraloss prefers A six times and B six times; trial order shuffled with seed 20261103.',analysis='Count agreement with each metric on decisive labels; report ties and skips separately. Exact binomial uncertainty on decisive labels. Selection is conditional on disagreement, not population-wide accuracy. One listener; any tuning requires fresh evaluation.',source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()),indent=2))
    print(f'Prepared {len(trials)} trials from {len(candidates)} disagreements in {len({c["seed"] for c in candidates})} examples. No new audio rendered.')

if __name__=='__main__':main()
