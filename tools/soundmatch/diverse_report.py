#!/usr/bin/env python3
"""Learning-curve metrics and fixed-example blind listening materials."""
import json
from pathlib import Path
import random
import shutil
import wave
import numpy as np
from diverse_data import BASE,ROOT,GIB,guard

MODELS=['previous-model','model-1000','model-2000','model-5000']
GROUPS=['familiar','patch','phrase','joint']


def report():
    renders=json.loads((BASE/'renders.json').read_text())
    result={};rng=np.random.default_rng(2026)
    for name in MODELS:
        train=json.loads((BASE/name/'training.json').read_text())
        result[name]=dict(training=train,audio={})
        for group in ['all']+GROUPS:
            rr=[r for r in renders if r['model']==name and r['kind']=='correction' and (group=='all' or r['group']==group)]
            changed=[r for r in rr if r['severity']!='identity'];identity=[r for r in rr if r['severity']=='identity']
            before=np.array([r['before'] for r in changed]);after=np.array([r['after'] for r in changed]);delta=after-before
            ci=np.quantile(delta[rng.integers(0,len(delta),(5000,len(delta)))].mean(1),[.025,.975])
            result[name]['audio'][group]=dict(count=len(rr),changed_count=len(changed),identity_count=len(identity),
                before_mean=float(before.mean()),after_mean=float(after.mean()),relative_change_percent=float(100*(after.mean()/before.mean()-1)),
                improved=int((after<before-1e-6).sum()),unchanged=int((np.abs(after-before)<=1e-6).sum()),worsened=int((after>before+1e-6).sum()),
                identity_audio_changed=sum(r['after']>1e-6 for r in identity),difference_ci95=ci.tolist())
        result[name]['severity']={}
        for severity in ['subtle','medium','large']:
            rr=[r for r in renders if r['model']==name and r['kind']=='correction' and r['severity']==severity]
            result[name]['severity'][severity]=dict(n=len(rr),before=float(np.mean([r['before'] for r in rr])),after=float(np.mean([r['after'] for r in rr])))
    paired={}
    for a,b in [('model-1000','model-2000'),('model-2000','model-5000')]:
        aa={r['seed']:r['after'] for r in renders if r['model']==a and r['kind']=='correction' and r['severity']!='identity'}
        bb={r['seed']:r['after'] for r in renders if r['model']==b and r['kind']=='correction' and r['severity']!='identity'}
        d=np.array([bb[k]-aa[k] for k in sorted(aa)])
        ci=np.quantile(d[rng.integers(0,len(d),(5000,len(d)))].mean(1),[.025,.975])
        paired[f'{b}-minus-{a}']=dict(mean=float(d.mean()),ci95=ci.tolist())
    summary=dict(models=result,paired=paired,free_gib=shutil.disk_usage(ROOT).free/GIB)
    (BASE/'comparison.json').write_text(json.dumps(summary,indent=2))
    lines=['# Diverse 5k results — 2026-11-03','',
        '5,000 training pairs, 200 validation pairs and 400 test pairs. The three new models use nested training subsets, identical architecture/loss and 60 expected passes per example. Larger sets therefore receive more optimization steps. All runs use one training seed.','',
        '| Model | Updates | Selected update | Training seconds | Test parameter MSE (400 pairs) | Spectral error (128 changed pairs) ↓ | Improved / unchanged / worsened |',
        '|---|---:|---:|---:|---:|---:|---:|']
    baseline=result['model-5000']['audio']['all']['before_mean']
    lines.append(f'| No correction | — | — | — | {result["model-5000"]["training"]["metrics"]["test"]["all"]["baseline_mse"]:.6f} | {baseline:.4f} | — |')
    for name,r in result.items():
        t=r['training'];m=t['metrics']['test']['all'];a=r['audio']['all']
        lines.append(f'| {name} | {t.get("steps","—")} | {t.get("best_step","—")} | {round(t["seconds"],1) if "seconds" in t else "—"} | {m["mse"]:.6f} | {a["after_mean"]:.4f} | {a["improved"]} / {a["unchanged"]} / {a["worsened"]} |')
    lines+=['','Audio evaluation uses the first 40 examples per test group (160 pairs): 128 altered sounds plus 32 exact matches. Exact matches are excluded from the spectral-error means above and checked separately. This avoids crediting abstention on already-correct audio as an improvement. Parameter metrics cover all 400 test pairs.','',
        '| Family test | No correction | Prior model | 1k | 2k | 5k |','|---|---:|---:|---:|---:|---:|']
    for g in GROUPS:
        values=[result[n]['audio'][g]['after_mean'] for n in MODELS]
        lines.append(f'| {g} | {result["model-5000"]["audio"][g]["before_mean"]:.4f} | '+' | '.join(f'{v:.4f}' for v in values)+' |')
    lines+=['','Familiar = new examples from training families; patch = held-out Growl; phrase = held-out octave-answer family; joint = both. Validation used different held-out families. Known fixed settings are supplied to new models but unavailable to the old architecture. The prior-model comparison changes distribution, data, context and training, and is not an isolated architectural ablation.','',
        '| Model | Actual identity audio changed / 32 | Matching-audio probes with >5% edit / 400 | Correct-control drift |','|---|---:|---:|---:|']
    for name,r in result.items():
        m=r['training']['metrics']['test']['all'];a=r['audio']['all']
        lines.append(f'| {name} | {a["identity_audio_changed"]} | {m["identity_probes_over_005"]} | {m["correct_control_drift"]:.5f} |')
    lines+=['','## Severity','', '| Model | Subtle error | Medium error | Large error |','|---|---:|---:|---:|']
    lines.append('| No correction | '+' | '.join(f'{result["model-5000"]["severity"][s]["before"]:.4f}' for s in ['subtle','medium','large'])+' |')
    for name,r in result.items():lines.append(f'| {name} | '+' | '.join(f'{r["severity"][s]["after"]:.4f}' for s in ['subtle','medium','large'])+' |')
    lines+=['','## Paired uncertainty','']
    for k,v in paired.items():lines.append(f'- {k}: mean spectral difference {v["mean"]:.5f}; paired example-bootstrap 95% interval [{v["ci95"][0]:.5f}, {v["ci95"][1]:.5f}]. Negative favors the larger set.')
    lines+=['','These intervals resample examples, not training seeds. They do not establish reproducibility across training runs. Spectral metrics are not human listening ratings. Large denotes parameter change size, not a verified perceptual difference. No hand-edited weights, oracle masks, frozen detune, or audio-loss training.','',
        'The prior single-preset model is evaluated unchanged. The three new checkpoints are trained from scratch. Gates remain at 0.5; final test data does not choose checkpoints or thresholds.','',
        'Listening materials are prepared from the first large-mismatch example in each family-test group, chosen without reference to model scores. Target first, then five randomized candidates (unchanged, prior model, 1k, 2k, 5k). No new listening ratings have been collected.','',
        f'Disk remaining at report time: {summary["free_gib"]:.2f} GiB. Full protocol: [DIVERSE_5K.md](DIVERSE_5K.md).', '',
        'Artifacts: `scratch/soundmatch-diverse-5k/`, including `comparison.json`, `model-*/checkpoint.pt`, `model-*/predictions.json`, `renders.json` and `listening/`.']
    (ROOT/'tools/soundmatch/DIVERSE_5K_RESULTS.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines[:12]))


def listening():
    guard();out=BASE/'listening';out.mkdir(exist_ok=False)
    rows=json.loads((BASE/'feature-rows.json').read_text());rng=random.Random(20300000);key={}
    guide=['# Diverse listening comparisons','','Target first; A–E follow at 5.25-second intervals. Same rendered gain; no separate loudness matching. Each candidate is 4.5 seconds followed by 0.75 seconds silence.','',
        'Rate closeness to the reference. Candidate identities are in blind-key.json. No listening ratings have been collected.','']
    for group in GROUPS:
        row=next(r for r in rows if r['split']=='test' and r['group']==group and r['severity']=='large')
        candidates=[('unchanged',Path(row['folder'])/'current.wav')]+[(name,BASE/name/'renders'/f'{row["seed"]}-correction.wav') for name in MODELS]
        rng.shuffle(candidates);key[group]={chr(65+i):name for i,(name,_) in enumerate(candidates)}
        paths=[Path(row['folder'])/'target.wav']+[p for _,p in candidates]
        wav=out/f'{group}-{row["seed"]}-blind.wav'
        with wave.open(str(wav),'wb') as dest:
            dest.setparams((2,2,48000,0,'NONE','not compressed'))
            for p in paths:
                with wave.open(str(p),'rb') as source:
                    assert source.getframerate()==48000 and source.getnchannels()==2 and source.getsampwidth()==2
                    dest.writeframes(source.readframes(source.getnframes()))
                dest.writeframes(bytes(36000*4))
        guide.extend([f'## {group} — {row["seed"]}', '',f'[Play]({wav})',''])
    (out/'blind-key.json').write_text(json.dumps(key,indent=2));(out/'README.md').write_text('\n'.join(guide))
    (out/'ratings.csv').write_text('group,candidate,closeness_1_to_5,notes\n'+''.join(f'{g},{chr(65+i)},,\n' for g in GROUPS for i in range(5)))
    print(out)


if __name__=='__main__':
    report();listening()
