#!/usr/bin/env python3
"""Decode saved comparator labels without modifying them."""
import json
import math
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'scratch/soundmatch-comparator-test'


def interval(k,n):
    if not n:return [0.,1.]
    def invert(fn,target,increasing):
        lo,hi=0.,1.
        for _ in range(80):
            mid=(lo+hi)/2
            if (fn(mid)<target)==increasing:lo=mid
            else:hi=mid
        return (lo+hi)/2
    lower=0. if k==0 else invert(lambda p:sum(math.comb(n,i)*p**i*(1-p)**(n-i) for i in range(k,n+1)),.025,True)
    upper=1. if k==n else invert(lambda p:sum(math.comb(n,i)*p**i*(1-p)**(n-i) for i in range(k+1)),.025,False)
    return [lower,upper]


def main():
    labels=json.loads((BASE/'web-labels/labels.json').read_text());key=json.loads((BASE/'blind-key.json').read_text())
    counts=dict(auraloss=0,spectral=0,tie=0,skip=0,unanswered=0);rows=[]
    for tid,item in key.items():
        choice=labels.get(tid,{}).get('choice','unanswered')
        outcome=('auraloss' if choice==item['auraloss_choice'] else 'spectral') if choice in ['A','B'] else choice
        counts[outcome]+=1
        rows.append(dict(id=tid,seed=item['seed'],group=item['group'],choice=choice,outcome=outcome))
    n=counts['auraloss']+counts['spectral'];k=counts['auraloss'];ci=interval(k,n)
    result=dict(counts=counts,decisive=n,auraloss_agreement=k/n if n else None,exact_binomial_ci95=ci,rows=rows,
        limitation='Single listener; strongest disagreements selected, not a random population sample. Binomial interval is descriptive and assumes independent trials. No universal accuracy or reliable winner established.')
    (BASE/'feedback-summary.json').write_text(json.dumps(result,indent=2)+'\n')
    lines=['# Comparator listening results','','Twelve blind comparisons were chosen where the two metrics rank candidates oppositely. Three distinct examples per family; balanced A/B placement. Existing montage examples were excluded. See `disagreement_test.py` and the experiment protocol.','',
        f'- Auraloss agrees with the listener: {counts["auraloss"]}.',f'- Original spectral convergence agrees: {counts["spectral"]}.',f'- Ties: {counts["tie"]}; skips: {counts["skip"]}; unanswered: {counts["unanswered"]}.','',
        f'Auraloss agrees on {k}/{n} decisive labels. Exact binomial 95% interval: {ci[0]:.1%}–{ci[1]:.1%}, conditional on these selected disagreements and assuming independent trials. This does not establish a better comparator.','',
        '| Test family | Auraloss | Original spectral | Tie |','|---|---:|---:|---:|']
    for g in ['familiar','patch','phrase','joint']:
        lines.append(f'| {g} | '+' | '.join(str(sum(r['group']==g and r['outcome']==o for r in rows)) for o in ['auraloss','spectral','tie'])+' |')
    lines+=['','Each subgroup has only three examples; subgroup differences are hypotheses, not established effects. Both metrics are useful proxies, and neither is validated as a replacement for listening. A lower optimized loss is not itself evidence of perceptual improvement.','',
        'Keep both scores during experiments; agreement can prioritize candidates, but is not proof of perceptual correctness. Retain periodic blind checks, particularly under new instruments, chains or mixtures. These labels may inform development; a comparator tuned on them must be evaluated on fresh examples.','',
        'Raw labels: `scratch/soundmatch-comparator-test/web-labels/labels.json`. Decoded results: `scratch/soundmatch-comparator-test/feedback-summary.json`.']
    (ROOT/'tools/soundmatch/COMPARATOR_RESULTS.md').write_text('\n'.join(lines)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
