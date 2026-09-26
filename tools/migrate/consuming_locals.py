#!/usr/bin/env python3
"""One-shot migration to consuming `| … |` locals (docs/17 step 4, pass 1).

Input: a report written by the fy compiler's temporary FY_DSP_MIGRATE
instrumentation, built under the OLD non-consuming locals. Each `cleanup`
line names a drop/nip/drop2 token (file + byte offset) whose only job was to
remove a bound local from the stack. Under consuming locals those tokens
must go. Also expands the removed grouped-load form `Struct@: f1 f2 ;` into
explicit `state Struct.f1@` / `params Struct.f2@` accessors.

usage: consuming_locals.py REPORT.tsv
"""
import os, re, sys
from collections import defaultdict

report = sys.argv[1]
dels = defaultdict(set)
for line in open(report):
    f = line.rstrip('\n').split('\t')
    if len(f) < 7 or f[0] != 'cleanup' or f[6] != '':
        continue
    if not f[1]:
        continue
    dels[os.path.realpath(f[1])].add((int(f[2]), f[4]))

def grouped(src):
    # `Ms20VoiceState@: age ;` -> `state Ms20VoiceState.age@`
    def rep(m):
        struct, fields = m.group(1), m.group(2).split()
        local = 'params' if struct.endswith('Params') else 'state'
        return '  '.join(f'{local} {struct}.{fl}@' for fl in fields)
    return re.sub(r'\b(\w+)@:\s+([^;]*?)\s*;', rep, src)

total = 0
for path, items in sorted(dels.items()):
    src = open(path, 'rb').read()  # report offsets are bytes
    buf = bytearray(src)
    for pos, tok in sorted(items, reverse=True):
        t = tok.encode()
        if src[pos:pos + len(t)] != t:
            sys.exit(f'{path}:{pos}: expected {tok!r}, found {src[pos:pos+len(t)]!r}')
        for i in range(pos, pos + len(t)):
            buf[i] = 0
        total += 1
    out = buf.decode()
    lines = []
    for ln in out.split('\n'):
        if '\0' in ln:
            ln = re.sub(r'[ \t]*\0+', '', ln).rstrip()
            if not ln.strip():
                continue
        lines.append(ln)
    out = grouped('\n'.join(lines))
    open(path, 'w').write(out)
print(f'removed {total} cleanup tokens in {len(dels)} files')

# files with grouped loads but no deletions
for root in ('kernels', 'machines'):
    for dp, _, fs in os.walk(root):
        for fn in fs:
            if fn.endswith('.fy'):
                p = os.path.realpath(os.path.join(dp, fn))
                if p in dels:
                    continue
                s = open(p).read()
                g = grouped(s)
                if g != s:
                    open(p, 'w').write(g)
