#!/usr/bin/env python3
"""Report expanded pilot without conflating parameter and audio accuracy."""
import json
from pathlib import Path
from expanded_data import PROFILE,BASE,ROOT,KEYS,CATS,TRAIN_COUNT


def main():
    train=json.loads((BASE/'model/training.json').read_text());audio=json.loads((BASE/'evaluation/summary.json').read_text());gen=json.loads((BASE/'generation.json').read_text());metric=train['metrics']['test']['all']
    lines=['# Focused oscillator results' if PROFILE=='oscillator' else '# Expanded Cream pilot results','',f'{len(KEYS)} continuous controls and {len(CATS)} categorical controls. {TRAIN_COUNT:,} train / 200 validation / 200 test pairs. Single training seed; known MIDI and routing. No refinement search.','',
        f'Generation: {gen["seconds"]:.1f}s. Training: {train["seconds"]:.1f}s on {train["device"]}; {train["parameter_count"]:,} weights. Selected update {train["best_step"]}/{train["steps"]}.','',
        '| Test group (altered pairs only) | Count | Initial spectral ↓ | Model spectral ↓ | Initial auraloss ↓ | Model auraloss ↓ | Improved / unchanged / worsened (spectral) |',
        '|---|---:|---:|---:|---:|---:|---:|']
    for name in ['all','familiar','patch','phrase','joint']+(['sparse','dense'] if PROFILE=='oscillator' else ['new-only','combined']):
        a=audio[name];lines.append(f'| {name} | {a["count"]} | {a["before"]:.4f} | {a["after"]:.4f} | {a["auraloss_before"]:.4f} | {a["auraloss_after"]:.4f} | {a["improved"]} / {a["count"]-a["improved"]-a["worsened"]} / {a["worsened"]} |')
    lines+=['',f'Identity render changes: {audio["identity_changed"]}/40. Matching-audio probes edited: {metric["identity_probe_pairs_edited"]}/200.','',
        f'Continuous normalized parameter MSE: {metric["baseline_continuous_mse"]:.5f} → {metric["continuous_mse"]:.5f}.',f'Category accuracy on all test categories: {metric["baseline_category_accuracy"]:.1%} → {metric["category_accuracy"]:.1%}. Changed-category accuracy: {metric["changed_category_accuracy"]:.1%}.','',
        '## Per-control diagnostics','','| Control | Initial error | Model error |','|---|---:|---:|']
    rows={r['seed']:r for r in json.loads((BASE/'rows.json').read_text())};pred=[r for r in json.loads((BASE/'model/predictions.json').read_text()) if r['split']=='test'];control={}
    for k in KEYS+CATS:
        def error(r,state):return float(state[k]!=r['target'][k]) if k in CATS else (state[k]-r['target'][k])**2
        before=sum(error(rows[p['seed']],rows[p['seed']]['current']) for p in pred)/len(pred)
        after=sum(error(rows[p['seed']],p['predicted']) for p in pred)/len(pred)
        control[k]=dict(before=before,after=after,measure='misclassification rate' if k in CATS else 'normalized MSE')
        lines.append(f'| {k} | {before:.5f} | {after:.5f} |')
    (BASE/'evaluation/per-control.json').write_text(json.dumps(control,indent=2))
    diagnostic_path=BASE/'model/generalization.json'
    if diagnostic_path.exists():
        diagnostics=json.loads(diagnostic_path.read_text())
        lines+=['','## Generalization of the selected checkpoint','','| Split | Continuous MSE | Changed-category accuracy |','|---|---:|---:|']
        for split in ['train','validation','test']:
            d=diagnostics[split]
            lines.append(f'| {split} | {d["continuous_mse"]:.5f} | {d["changed_category_accuracy"]:.1%} |')
        lines+=['','| Categorical control | Changed test cases | Recovery accuracy |','|---|---:|---:|']
        for key,d in diagnostics['test']['per_category'].items():
            lines.append(f'| {key} | {d["changed_count"]} | {d["changed_accuracy"]:.1%} |')
    lines+=['','Continuous rows use MSE; categorical rows use misclassification rate. These are different units and should not be averaged together.','',
        'The harder data distribution prevents a clean numerical comparison with the previous 12-control experiment. Wider control coverage and supervised parameter improvement do not establish perceptual improvement. The categorical objective and validation weighting are first-pilot choices.','',
        f'Eight balanced blind comparisons (model versus unchanged) are in `manifest.json`; sources chosen before considering scores. Protocol: [{"OSCILLATOR_5K.md" if PROFILE=="oscillator" else "EXPANDED.md"}]({"OSCILLATOR_5K.md" if PROFILE=="oscillator" else "EXPANDED.md"}). Artifacts: `{BASE.relative_to(ROOT)}`.']
    labels_path=BASE/'web-labels/labels.json'
    if labels_path.exists():
        labels=json.loads(labels_path.read_text());key=json.loads((BASE/'blind-key.json').read_text())
        renders={r['seed']:r for r in json.loads((BASE/'evaluation/results.json').read_text())}
        counts=dict(model=0,unchanged=0,tie=0,skip=0);agreement=dict(spectral=0,auraloss=0);trials=[]
        for tid,k in key.items():
            if tid not in labels:continue
            choice=labels[tid]['choice'];winner=k['assignment'].get(choice,choice);counts[winner]+=1;r=renders[k['seed']]
            trial=dict(id=tid,seed=k['seed'],group=k['group'],mode=k['mode'],human=winner)
            for metric,prefix in [('spectral',''),('auraloss','auraloss_')]:
                before,after=r[prefix+'before'],r[prefix+'after']
                preferred='tie' if abs(before-after)<=1e-9 else 'model' if after<before else 'unchanged'
                trial[metric]=preferred
                if winner in ('model','unchanged') and preferred==winner:agreement[metric]+=1
            trials.append(trial)
        decisive=counts['model']+counts['unchanged']
        (BASE/'evaluation/listening.json').write_text(json.dumps(dict(counts=counts,decisive=decisive,agreement=agreement,trials=trials),indent=2)+'\n')
        lines+=['','## Blind listening', '',f'Model preferred: {counts["model"]}; unchanged preferred: {counts["unchanged"]}; ties: {counts["tie"]}; skipped: {counts["skip"]}.',f'Agreement on the {decisive} decisive choices: spectral {agreement["spectral"]}/{decisive}; auraloss {agreement["auraloss"]}/{decisive}. Metric preferences use raw error direction; human ties are excluded from these agreement counts.','', '| Trial | Group | Changes | Human | Spectral | Auraloss |','|---|---|---|---|---|---|']
        for t in trials:lines.append(f'| {t["id"]} | {t["group"]} | {t["mode"]} | {t["human"]} | {t["spectral"]} | {t["auraloss"]} |')
        lines+=['','One listener and eight selected comparisons are insufficient to establish a reliable advantage or calibrate a perceptual comparator. These labels are evaluation evidence, not training data.']
    (ROOT/({'legacy26':'tools/soundmatch/EXPANDED_RESULTS.md','ranges':'tools/soundmatch/EXPANDED_RANGES_RESULTS.md','oscillator':'tools/soundmatch/OSCILLATOR_5K_RESULTS.md'}[PROFILE])).write_text('\n'.join(lines)+'\n');print('\n'.join(lines[:18]))

if __name__=='__main__':main()
