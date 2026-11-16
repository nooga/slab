#!/usr/bin/env python3
"""Create unnormalized, randomized listening montages from fixed fresh examples."""
import json
from pathlib import Path
import random
import wave
from ablations import BASE,VARIANTS,guard


def main():
    guard();out=BASE/'listening';out.mkdir(exist_ok=False)
    rows=json.loads((BASE/'rows.json').read_text())
    test=[r for r in rows if r['split']=='test'][:3]
    rng=random.Random(20261103)
    key={};guide=['# Listening comparisons','','No listening ratings have been collected. All excerpts retain their rendered gain.',
                 'Each montage starts with the target, then candidates A–E separated by 0.75 seconds of silence.',
                 'Candidate order is randomized independently for each example. It includes unchanged current audio and all four models.',
                 'Rate closeness to the target, especially attack, brightness, beating, envelope and echo. The mapping is in blind-key.json.','']
    for row in test:
        candidates=[('unchanged',Path(row['folder'])/'current.wav')]+[(v,BASE/v/'renders'/f'{row["seed"]}-correction.wav') for v in VARIANTS]
        rng.shuffle(candidates)
        segments=[('reference',Path(row['folder'])/'target.wav')]+[(chr(65+i),p) for i,(_,p) in enumerate(candidates)]
        key[str(row['seed'])]={chr(65+i):v for i,(v,_) in enumerate(candidates)}
        montage=out/f'{row["seed"]}-blind.wav'
        cursor=0;timestamps=[]
        with wave.open(str(montage),'wb') as dest:
            dest.setparams((2,2,48000,0,'NONE','not compressed'))
            for label,path in segments:
                with wave.open(str(path),'rb') as source:
                    assert source.getnchannels()==2 and source.getsampwidth()==2 and source.getframerate()==48000
                    frames=source.readframes(source.getnframes())
                timestamps.append(f'{label}: {cursor/48000:.2f}s')
                dest.writeframes(frames);cursor+=len(frames)//4
                dest.writeframes(bytes(36000*4));cursor+=36000
        guide.extend([f'## Example {row["seed"]}', '',f'[Play montage]({montage})','',', '.join(timestamps),''])
    (out/'blind-key.json').write_text(json.dumps(key,indent=2))
    (out/'README.md').write_text('\n'.join(guide))
    (out/'ratings.csv').write_text('example,candidate,closeness_1_to_5,notes\n'+''.join(f'{r["seed"]},{chr(65+i)},,\n' for r in test for i in range(5)))
    print(out)


if __name__=='__main__':main()
