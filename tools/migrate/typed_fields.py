#!/usr/bin/env python3
"""One-shot migration to typed locals + dotted fields (docs/17 step 4, pass 2).

Per `dsp:` word:
  - a frame local used as `L Struct.f@` / `L Struct.f-p` with one struct
    becomes `L:Struct` in its frame, and
      L Struct.f@          -> L.f
      L Struct.f-p f@64    -> L.f
      L Struct.f-p f!64    -> -> L.f
      L Struct.f-p         -> L.f&
  - `( a b -- c )` right after the name plus a leading `| a b |` frame with
    the same input count merge into `| a b -- c |` (frame names win).

usage: typed_fields.py FILE...
"""
import re, sys

TOK = re.compile(r'\S+')

def tokens(src, start, end):
    """(start, end, text) of tokens in src[start:end], skipping ( comments )."""
    out, i, depth = [], start, 0
    while i < end:
        c = src[i]
        if c.isspace():
            i += 1
            continue
        m = TOK.match(src, i)
        t = m.group(0)
        if depth == 0 and t == '(' or depth == 0 and t.startswith('(') and t != '(':
            # comment opener: `(` token (fy comments start with a lone paren)
            if t == '(':
                depth = 1
                i = m.end()
                continue
        if depth > 0:
            # scan char-wise for the matching close paren
            while i < end and depth > 0:
                if src[i] == '(':
                    depth += 1
                elif src[i] == ')':
                    depth -= 1
                i += 1
            continue
        out.append((m.start(), m.end(), t))
        i = m.end()
    return out

ACC = re.compile(r'^([A-Z][A-Za-z0-9]*)\.([a-z0-9][a-z0-9-]*?)(@|-p)$')

def migrate_word(src, s, e, name_end):
    """Return list of (start, end, replacement) edits for one word body."""
    edits = []
    toks = tokens(src, name_end, e)
    # paren declaration right after the name
    decl = None
    j = name_end
    while j < e and src[j].isspace():
        j += 1
    if j < e and src[j] == '(':
        depth, k = 0, j
        while k < e:
            if src[k] == '(':
                depth += 1
            elif src[k] == ')':
                depth -= 1
                if depth == 0:
                    break
            k += 1
        inner = src[j + 1:k].split()
        if '--' in inner and all(':' not in t and '|' not in t for t in inner):
            d = inner.index('--')
            decl = (j, k + 1, inner[:d], inner[d + 1:])
    # frames
    frames = []  # (open_idx, close_idx, names)
    i = 0
    while i < len(toks):
        if toks[i][2] == '|':
            k = i + 1
            while k < len(toks) and toks[k][2] != '|':
                k += 1
            names = [t[2] for t in toks[i + 1:k]]
            frames.append((i, k, names))
            i = k + 1
            continue
        i += 1
    allnames = [n for f in frames for n in f[2] if n != '--']
    # struct per local
    use = {}
    for i in range(len(toks) - 1):
        L, nxt = toks[i][2], toks[i + 1][2]
        m = ACC.match(nxt)
        if m and L in allnames:
            use.setdefault(L, set()).add(m.group(1))
    typed = {L: next(iter(ss)) for L, ss in use.items()
             if len(ss) == 1 and allnames.count(L) == 1}
    # accessor rewrites
    i = 0
    while i < len(toks) - 1:
        L = toks[i][2]
        m = ACC.match(toks[i + 1][2])
        if L in typed and m and m.group(1) == typed[L]:
            f, kind = m.group(2), m.group(3)
            after = toks[i + 2][2] if i + 2 < len(toks) else None
            if kind == '@':
                edits.append((toks[i][0], toks[i + 1][1], f'{L}.{f}'))
                i += 2
                continue
            if after == 'f!64':
                edits.append((toks[i][0], toks[i + 2][1], f'-> {L}.{f}'))
                i += 3
                continue
            if after == 'f@64':
                edits.append((toks[i][0], toks[i + 2][1], f'{L}.{f}'))
                i += 3
                continue
            edits.append((toks[i][0], toks[i + 1][1], f'{L}.{f}&'))
            i += 2
            continue
        i += 1
    # frame rewrites (types, and the declaration merge for the leading frame)
    for fi, (o, c, names) in enumerate(frames):
        leading = fi == 0 and o == 0
        new = [f'{n}:{typed[n]}' if n in typed else n for n in names]
        merged = False
        if leading and decl and '--' not in names and len(decl[2]) == len(names):
            new = new + ['--'] + decl[3]
            merged = True
        if new != names:
            edits.append((toks[o][1], toks[c][0], ' ' + ' '.join(new) + ' '))
        if merged:
            ds, de = decl[0], decl[1]
            # drop the declaration and the whitespace before it
            while ds > 0 and src[ds - 1] in ' \t':
                ds -= 1
            edits.append((ds, de, ''))
    return edits

def migrate(path):
    src = open(path).read()
    edits = []
    for m in re.finditer(r'(?m)^dsp: (\S+)', src):
        s = m.start()
        # word ends at the first `;` token (outside comments) after the name
        toks = tokens(src, m.end(), len(src))
        end = next((t[1] for t in toks if t[2] == ';'), None)
        if end is None:
            continue
        edits += migrate_word(src, s, end, m.end())
    for a, b, r in sorted(edits, key=lambda x: x[0], reverse=True):
        src = src[:a] + r + src[b:]
    open(path, 'w').write(src)
    return len(edits)

n = sum(migrate(p) for p in sys.argv[1:])
print(f'{n} edits')
