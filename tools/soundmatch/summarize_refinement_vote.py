#!/usr/bin/env python3
"""Summarize completed refinement comparison; no perceptual claims from losses."""
import json
from pathlib import Path
import numpy as np
from refinement_vote import OUT,ROOT,STRATEGIES


def main():
    rows=json.loads((OUT/'results.json').read_text());report=json.loads((OUT/'report.json').read_text())
    assert len(rows)==40
    lines=['# Refinement acceptance comparison','','Forty previously unauditioned test examples; 32 altered and eight identity. Same 5k predictions and 48 proposals per strategy. Both metrics are measured on all final outputs.','',
        '| Strategy | Spectral error ↓ | Auraloss ↓ | Spectral worsened / 32 | Auraloss worsened / 32 | Unchanged / 32 |','|---|---:|---:|---:|---:|---:|']
    first=report['summary']['spectral']['metrics']
    lines.append(f'| Initial 5k prediction | {first["spectral"]["before"]:.4f} | {first["auraloss"]["before"]:.4f} | — | — | — |')
    for name in STRATEGIES:
        s=report['summary'][name];m=s['metrics']
        lines.append(f'| {name} | {m["spectral"]["after"]:.4f} | {m["auraloss"]["after"]:.4f} | {m["spectral"]["worsened"]} | {m["auraloss"]["worsened"]} | {s["unchanged"]} |')
    lines+=['','Consensus cannot worsen either optimized metric by construction. This table does not establish perceptual superiority or compare training objectives. A model trained on these search results would need fresh evaluation.','', '| Family | Strategy | Spectral error ↓ | Auraloss ↓ |','|---|---|---:|---:|']
    for g in ['familiar','patch','phrase','joint']:
        rr=[r for r in rows if r['group']==g and r['severity']!='identity']
        for name in ['initial']+STRATEGIES:
            s=[r['initial']['scores'] if name=='initial' else r['final'][name]['scores'] for r in rr]
            lines.append(f'| {g} | {name} | {np.mean([x["spectral"] for x in s]):.4f} | {np.mean([x["auraloss"] for x in s]):.4f} |')
    lines+=['','Final parameter states identical to consensus: '+', '.join(f'{name}: {sum(r["final"][name]["state"]==r["final"]["consensus"]["state"] for r in rows)}/40' for name in ['spectral','auraloss'])+'.']
    manifest=json.loads((OUT/'manifest.json').read_text())
    lines+=['',f'Identity audio changes (out of eight): '+', '.join(f'{s}: {report["summary"][s]["identity_changed"]}' for s in STRATEGIES)+'.','',f'Elapsed: {report["seconds"]:.1f} seconds. Unique renders: {report["unique_renders"]}. Free disk: {report["free_gib"]:.2f} GiB.', '', f'Prepared {len(manifest["trials"])} blind listening comparisons of distinct strategy outputs. No ratings collected at report generation. Selection and reproducible commands: [REFINEMENT_VOTE.md](REFINEMENT_VOTE.md).','', 'Artifacts: `scratch/soundmatch-refinement-vote/`. Starting predictions, final states, both scores and per-round decisions are retained in `results.json`; `manifest.json` and `blind-key.json` define the listening study.']
    (ROOT/'tools/soundmatch/REFINEMENT_VOTE_RESULTS.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines[:12]))

if __name__=='__main__':main()
