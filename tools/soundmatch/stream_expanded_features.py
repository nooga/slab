#!/usr/bin/env python3
"""Extract completed pairs while expanded_data generates later pairs."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import time
import numpy as np
from expanded_data import BASE,TOTAL_COUNT,PROFILE,guard,GIB
from ablations import multires


def main():
    guard(reserve=5*GIB);path=BASE/'features.npy'
    if path.exists():raise RuntimeError('Feature cache exists')
    run=json.loads((BASE/'run.json').read_text());assert run['count']==TOTAL_COUNT and run['profile']==PROFILE
    seedbase={'legacy26':20400000,'ranges':20500000,'oscillator':20600000}[PROFILE]
    data=np.lib.format.open_memmap(path,mode='w+',dtype='float32',shape=(TOTAL_COUNT,2,6,128,128));started=time.perf_counter()
    def work(i):
        folder=BASE/str(seedbase+i);label=folder/'labels.json';deadline=time.monotonic()+2400
        while True:
            try:row=json.loads(label.read_text());break
            except (FileNotFoundError,json.JSONDecodeError):
                if time.monotonic()>deadline:raise TimeoutError(label)
                time.sleep(1)
        assert row['seed']==seedbase+i and row['index']==i
        a=multires(folder/'target.wav');b=multires(folder/'current.wav') if row['changed'] else a.copy()
        return np.stack([a,b])
    with ThreadPoolExecutor(max_workers=2) as pool:
        for i,value in enumerate(pool.map(work,range(TOTAL_COUNT))):
            assert np.isfinite(value).all();data[i]=value
            if (i+1)%400==0 or i+1==TOTAL_COUNT:
                guard();data.flush();print(f'stream features {i+1}/{TOTAL_COUNT}',flush=True)
    data.flush();metadata=dict(seconds_including_wait=time.perf_counter()-started,shape=list(data.shape),bytes=path.stat().st_size,source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (BASE/'features-ready.json').write_text(json.dumps(metadata,indent=2));print('Features ready',flush=True)

if __name__=='__main__':main()
