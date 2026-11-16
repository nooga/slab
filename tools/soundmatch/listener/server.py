#!/usr/bin/env python3
"""Loopback-only blind listening app. Python standard library; no build step."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time
from urllib.parse import urlsplit

ROOT=Path(__file__).resolve().parents[3]
UI=Path(__file__).parent
LOCK=threading.Lock()


def build_trials(manifest=None):
    if manifest is not None:
        trials=[];audio={}
        for trial in manifest["trials"]:
            urls={}
            for label in ["reference","A","B"]:
                path=Path(trial["sources"][label])
                if not path.is_file():raise FileNotFoundError(path)
                token=hashlib.sha256(f'{manifest["experiment"]}:{trial["id"]}:{label}'.encode()).hexdigest()[:24]
                audio[token]=path;urls[label]=f"/audio/{token}"
            trials.append({"id":trial["id"],"audio":urls})
        return trials,audio
    base=ROOT/'scratch/soundmatch-auraloss'
    records=json.loads((base/'refinement.json').read_text())
    key=json.loads((base/'listening/blind-key.json').read_text())
    rows={r['seed']:r for r in json.loads((ROOT/'scratch/soundmatch-diverse-5k/feature-rows.json').read_text())}
    trials=[]; audio={}
    for record in records:
        if record['start']!='model-5000':continue
        trial_id=str(record['seed'])
        sources={'reference':Path(rows[record['seed']]['folder'])/'target.wav',
                 **{label:Path(record['initial'] if name=='before' else record['wav']) for label,name in key[trial_id].items()}}
        urls={}
        for label,path in sources.items():
            if not path.is_file():raise FileNotFoundError(path)
            token=hashlib.sha256(f'auraloss-v1:{trial_id}:{label}'.encode()).hexdigest()[:24]
            audio[token]=path;urls[label]=f'/audio/{token}'
        trials.append({'id':trial_id,'audio':urls})
    return trials,audio


class Server(ThreadingHTTPServer):
    daemon_threads=True
    def __init__(self,port,state_dir,manifest_path=None):
        manifest=json.loads(manifest_path.read_text()) if manifest_path else None
        self.experiment=manifest["experiment"] if manifest else "auraloss-v1"
        self.title=manifest["title"] if manifest else "Auraloss refinement"
        self.trials,self.audio=build_trials(manifest)
        self.ids={t['id'] for t in self.trials}
        state_dir.mkdir(parents=True,exist_ok=True)
        self.state_file=state_dir/'labels.json'
        self.labels=json.loads(self.state_file.read_text()) if self.state_file.exists() else {}
        super().__init__(('127.0.0.1',port),Handler)
    def save(self):
        tmp=self.state_file.with_suffix('.tmp')
        with tmp.open('w') as f:
            json.dump(self.labels,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        tmp.replace(self.state_file)


class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def send(self,status,data,kind='application/json'):
        if kind=='application/json':data=json.dumps(data).encode()
        self.send_response(status);self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(data)
    def trusted(self):
        return self.headers.get('Host') in {f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}'}
    def do_GET(self):
        if not self.trusted():return self.send(403,{'error':'Local access only.'})
        path=urlsplit(self.path).path
        if path=='/api/session':
            with LOCK:self.send(200,{'title':self.server.title,'trials':self.server.trials,'labels':self.server.labels})
        elif path=='/api/export':
            with LOCK:self.send(200,{'experiment':self.server.experiment,'labels':self.server.labels})
        elif path in ['/','/app.js','/style.css']:
            filename={'/':'index.html','/app.js':'app.js','/style.css':'style.css'}[path]
            self.send(200,(UI/filename).read_bytes(),{'/':'text/html; charset=utf-8','/app.js':'text/javascript','/style.css':'text/css'}[path])
        elif path.startswith('/audio/') and path[7:] in self.server.audio:
            self.send(200,self.server.audio[path[7:]].read_bytes(),'audio/wav')
        else:self.send(404,{'error':'Not found.'})
    def do_POST(self):
        origin=self.headers.get('Origin')
        if not self.trusted() or origin not in [None,f'http://{self.headers.get("Host")}']:
            return self.send(403,{'error':'Local access only.'})
        if self.path!='/api/label':return self.send(404,{'error':'Not found.'})
        try:
            size=int(self.headers.get('Content-Length','0'))
            if not 0<size<4096:raise ValueError()
            data=json.loads(self.rfile.read(size));trial_id=data['id'];choice=data['choice']
            if trial_id not in self.server.ids or choice not in ['A','B','tie','skip',None]:raise ValueError()
            with LOCK:
                old=dict(self.server.labels)
                if choice is None:self.server.labels.pop(trial_id,None)
                else:self.server.labels[trial_id]={'choice':choice,'updated_at':time.time(),'heard':sorted(set(data.get('heard',[]))&{'reference','A','B'})}
                try:self.server.save()
                except OSError:
                    self.server.labels=old;raise
                self.send(200,{'labels':self.server.labels})
        except (ValueError,KeyError,TypeError):self.send(400,{'error':'Invalid label.'})
        except OSError:self.send(500,{'error':'Could not save to disk. Please retry.'})


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--port',type=int,default=8765)
    p.add_argument('--state-dir',type=Path,default=ROOT/'scratch/soundmatch-auraloss/listening/web-labels')
    p.add_argument('--manifest',type=Path)
    args=p.parse_args()
    if args.manifest and args.state_dir==ROOT/'scratch/soundmatch-auraloss/listening/web-labels':args.state_dir=args.manifest.parent/'web-labels'
    server=Server(args.port,args.state_dir,args.manifest)
    print(f'Listening app: http://127.0.0.1:{server.server_port}',flush=True)
    print(f'Labels: {server.state_file}',flush=True)
    server.serve_forever()

if __name__=='__main__':main()
