"""One-shot migration of machine entry words to the ctx ABI (docs/04 §Kernel ABI).

Kept in tools/ for the record; not meant to be re-run.
"""
import re, glob, sys

files = sorted(set(glob.glob('kernels/**/*.fy', recursive=True) + glob.glob('machines/**/*.fy', recursive=True)))
texts = {f: open(f).read() for f in files}

# entry words by hook, from manifests
hooks = {}
for f, s in texts.items():
    for m in re.finditer(r'"([a-z0-9-]+)" +(render|note-on|note-off|prepare|block-prepare|derive)!', s):
        if m.group(1) not in ('render-word', 'prepare-word'):
            hooks[m.group(1)] = m.group(2)

DET_STAGES = {'comp-detect', 'gate-detect', 'lim-gain'}
CTX_STAGES = {'v-jn-dco'}

def add_drops(body, n):
    """Append n drops to the word's final drop line (or add one)."""
    if n == 0:
        return body
    extra = ' '.join(['drop2'] * (n // 2) + (['drop'] if n % 2 else []))
    lines = body.rstrip('\n').split('\n')
    for i in range(len(lines) - 1, -1, -1):
        toks = lines[i].split()
        if toks and all(t in ('drop', 'drop2') for t in toks):
            lines[i] = lines[i] + ' ' + extra
            return '\n'.join(lines) + '\n'
    return '\n'.join(lines) + '\n  ' + extra + '\n'

def frame_of(body):
    m = re.search(r'\|([^|]*)\|', body)
    return (m, m.group(1).split()) if m else (None, [])

log = []

def rewrite_word(name, body, comp):
    hook = hooks.get(name)
    m, args = frame_of(body)
    head, rest = body[:m.start()], body[m.end():]
    if hook == 'render' and comp:
        new = '| io ctx state params |'
        def fix_call(cm):
            toks = cm.group(1).split()
            callee = cm.group(2)
            toks = ['io' if t in ('out', 'in') else t for t in toks]
            if callee in DET_STAGES:
                toks = ['io'] + toks
            if callee in CTX_STAGES:
                toks = ['ctx'] + toks
            return '  ' + ' '.join(toks) + ' call: ' + callee
        rest = re.sub(r'^[ \t]*(.*?)[ \t]*call: ([a-z0-9-]+)', fix_call, rest, flags=re.M)
        return head + new + rest
    if hook == 'render':
        # plain render: out stays arg0 (now the io pointer), input moves into io
        if len(args) == 4:
            inname = args[3]
            rest = re.sub(r'\b%s f@64' % re.escape(inname), 'out Io.in-l@', rest)
            return head + '| out ctx state params |' + rest
        return add_drops(head + '| out ctx state params |' + rest, 1)
    if hook == 'note-on':
        return add_drops(head + '| ctx state params |\n  ctx Ctx.hz@ ctx Ctx.vel@ | %s %s |' % (args[2], args[3]) + rest, 1)
    if hook == 'note-off':
        return add_drops(head + '| ctx state params |' + rest, 1)
    if hook == 'prepare':
        return add_drops(head + '| ctx state params |\n  ctx Ctx.sr@ | %s |' % args[2] + rest, 1)
    if hook == 'block-prepare':
        return add_drops(head + '| ctx state params |\n  ctx Ctx.sr@ | %s |' % args[1] + rest, 2)
    if hook == 'derive':
        if comp:
            return head + '| ctx state params |' + rest
        return add_drops(head + '| ctx state params |\n  ctx Ctx.data-p p@64 | %s |' % args[1] + rest, 2)
    return None

def rewrite_stage(name, body):
    out = body
    if name in DET_STAGES:
        m, args = frame_of(out)
        out = out[:m.start()] + '| io state params |' + out[m.end():]
        # det pointer + index + indexed read + index bump -> one io read
        out = re.sub(r'  state [A-Za-z]+\.det-p p@64 \| det \|\n  state [A-Za-z]+\.idx@ \| i \|\n  det i f@i', '  io Io.det@', out)
        out = re.sub(r'\n  i 1\.0 f\+ state [A-Za-z]+\.idx-p f!64', '', out)
        # bindings: io state params (3) vs state params det i (4): one fewer
        lines = out.rstrip('\n').split('\n')
        for i in range(len(lines) - 1, -1, -1):
            toks = lines[i].split()
            if toks and all(t in ('drop', 'drop2') for t in toks):
                # remove one drop
                if toks[-1] == 'drop':
                    toks = toks[:-1]
                else:
                    toks[-1] = 'drop'
                lines[i] = '  ' + ' '.join(toks) if toks else None
                break
        out = '\n'.join(l for l in lines if l is not None) + '\n'
    if name in CTX_STAGES:
        m, args = frame_of(out)
        out = out[:m.start()] + '| ctx state params |' + out[m.end():]
        out = out.replace('state JunoState.voice-idx@', 'ctx Ctx.chan@')
        out = add_drops(out, 1)
    # stages that read the effect input through `in`
    m, args = frame_of(out)
    if m is None:
        return out
    if 'in' in args and re.search(r'\bin f@64', out) and hooks.get(name) != 'render':
        out = re.sub(r'\bin f@64', 'in Io.in-l@', out)
    return out

word_re = re.compile(r'^dsp: ([a-z0-9-]+)(.*?)^;', re.S | re.M)
for f in files:
    s = texts[f]
    def sub(m):
        name, body = m.group(1), m.group(2)
        comp = 'call:' in body
        if name in hooks:
            nb = rewrite_word(name, body, comp)
        else:
            nb = rewrite_stage(name, body)
        if nb is None or nb == body:
            return m.group(0)
        log.append((f, name))
        return 'dsp: ' + name + nb + ';'
    ns = word_re.sub(sub, s)
    # special reads that now come from ctx
    ns = ns.replace('state ChorusState.chan@', 'ctx Ctx.chan@')
    ns = ns.replace('state VerbState.chan@', 'ctx Ctx.chan@')
    ns = ns.replace('params DelayParams.tempo-bpm@', 'ctx Ctx.tempo@')
    if ns != s:
        texts[f] = ns
        open(f, 'w').write(ns)
for f, n in log:
    print(f, n)
