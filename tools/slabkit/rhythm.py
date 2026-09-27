"""Step patterns.

A step string is one character per step: "x...x...x...x..." is four on
the floor at 16ths. Spaces and '|' are ignored, so bars can be marked:
"x..x ..x. | x..x .x..". Characters:

    X  accent        x  hit        o  ghost (soft)
    .  rest          -  tie: extend the previous hit by a step

Melodic patterns (Clip.bass) add their own characters on top; see there.
"""

VEL = {"X": 122, "x": 100, "o": 58}


def clean(pattern):
    return pattern.replace(" ", "").replace("|", "").replace("\n", "")


def steps(pattern, step=0.25):
    """(beat, char, length_in_beats) for every non-rest step; ties fold
    into the preceding hit's length."""
    p = clean(pattern)
    out = []
    for i, ch in enumerate(p):
        if ch == ".":
            continue
        if ch == "-":
            if out:
                b, c, n = out[-1]
                out[-1] = (b, c, n + step)
            continue
        out.append((i * step, ch, step))
    return out


def length(pattern, step=0.25):
    return len(clean(pattern)) * step


def euclid(hits, n, rotate=0, char="x"):
    """Spread `hits` onsets as evenly as possible over `n` steps
    (Bjorklund): euclid(3, 8) = "x..x..x.", the tresillo; (5, 8) the
    cinquillo; (5, 16) a bossa-ish hat."""
    pat = [char if (i * hits) % n < hits else "." for i in range(n)]
    # the modular form starts on a hit; rotate so the pattern can be offset
    r = rotate % n
    return "".join(pat[-r:] + pat[:-r]) if r else "".join(pat)
