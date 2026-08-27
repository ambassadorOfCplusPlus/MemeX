"""Read the RSET_SEG traces off the adaptation runs and answer one question:

    after the domain switch, does the hit rate come back, and in how many tokens?

Why a separate reader instead of trusting the PowerShell summary: the 32-token segments are
noisy (the code half alone varies 30-54% at capacity 12), and a recovery criterion applied to
single noisy segments will fire on a lucky one. This re-bins to a coarser width before judging,
prints the whole series so the shape is visible rather than summarised, and states the plateau
and the floor it is measured against.

The 9.4% line matters: capacity is 12 of 128, so a set with no information at all scores 9.4%.
A trough near it means the code-built set is worth nothing on Russian, which is the premise the
switch test was built on.
"""
import re
import sys
import glob
import os

BIN = int(sys.argv[1]) if len(sys.argv) > 1 else 96
SWITCH = int(sys.argv[2]) if len(sys.argv) > 2 else 1044
RES = 'D:/MemeX/results'

pat = re.compile(
    r'RSET_SEG phase warm tok (\d+) hits ([\d.]+) promo (\d+) evict (\d+) refresh (\d+)')


def series(path):
    out = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for ln in f:
            m = pat.search(ln)
            if m:
                out.append((int(m.group(1)), float(m.group(2)), int(m.group(3))))
    return out


def rebin(s, width):
    """Weighted re-bin. Every segment holds the same number of picks, so a plain mean over the
    segments falling in a bin is the pick-weighted hit rate of that bin."""
    if not s:
        return []
    step = s[1][0] - s[0][0] if len(s) > 1 else width
    per = max(1, width // step)
    out = []
    for i in range(0, len(s) - per + 1, per):
        chunk = s[i:i + per]
        out.append((chunk[-1][0],
                    sum(c[1] for c in chunk) / len(chunk),
                    sum(c[2] for c in chunk)))
    return out


def report(tag, s):
    b = rebin(s, BIN)
    if len(b) < 4:
        print(f'{tag:8s} otrezkov malo ({len(b)})')
        return
    pre = [x for x in b if x[0] <= SWITCH]
    post = [x for x in b if x[0] > SWITCH]
    if len(pre) < 2 or len(post) < 2:
        print(f'{tag:8s} pre {len(pre)} post {len(post)} - malo')
        return
    # Plateau: the second half of the pre-switch region, so the empty-window warm-up is out.
    plat = pre[len(pre) // 2:]
    plateau = sum(x[1] for x in plat) / len(plat)
    trough = min(x[1] for x in post)
    tr_at = [x[0] for x in post if x[1] == trough][0]
    need = 0.90 * plateau
    rec = None
    for k in range(len(post) - 1):
        if post[k][1] >= need and post[k + 1][1] >= need:
            rec = post[k][0]
            break
    # Steady state after the switch: the last third of the post region.
    tail = post[2 * len(post) // 3:]
    after = sum(x[1] for x in tail) / len(tail)
    print(f'{tag:8s} plato {plateau:5.1f}%  proval {trough:5.1f}% (na {tr_at})  '
          f'hvost {after:5.1f}%  vosstanovlenie '
          + (f'{rec - SWITCH} tokenov' if rec else 'NE dostignuto (90% ot plato)'))
    print('         ' + ' '.join(f'{x[1]:.0f}' for x in b))
    print('         ' + ' '.join(f'{x[0]}' for x in b))


print(f'bin {BIN} tokenov, perekljuchenie na {SWITCH}, sluchajnyj pol 9.4% (12 iz 128)')
for tag in ['p3', 'p16', 'p32', 'p64', 'never']:
    p = os.path.join(RES, f'_adapt_{tag}.out')
    if not os.path.exists(p):
        print(f'{tag:8s} net fajla')
        continue
    report(tag, series(p))
p = os.path.join(RES, '_adapt_codeonly.out')
if os.path.exists(p):
    s = rebin(series(p), BIN)
    print('\ncodeonly (odin domen, kontrol na "kolebanija ot teksta, a ne ot politiki"):')
    print('         ' + ' '.join(f'{x[1]:.0f}' for x in s))
