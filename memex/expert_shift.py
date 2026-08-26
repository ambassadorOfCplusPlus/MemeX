"""Does the set of rarely-used experts survive a change of input distribution?

`expert_freq.py` measured the skew of expert selection on one text and concluded that taking
bits away from the rare tail is nearly free. That conclusion has a hole in it: routing is a
function of the input. An expert that is nearly dead on C++ may be load-bearing on Russian
prose, and a perplexity check run on code would never show it.

So this script does not re-measure the skew. It measures whether the *identity* of the tail is
stable. Three numbers, in increasing order of how much the decision rests on them:

  1. Spearman rank correlation of per-expert selection counts between two texts. Says whether
     the router's ordering of its experts is a property of the router or of the input.
  2. Jaccard overlap of the "bottom 32 by count" sets. Says whether the specific experts we
     would starve are the same ones.
  3. The one that decides it: freeze the bottom-k set chosen on the reference (code) trace, then
     ask what fraction of all selections on a *different* text lands inside that frozen set.
     That fraction is, to first order, the share of expert reads served at the starved bit
     width - i.e. the exposure. On the text it was fitted to it is ~3%. If it stays near 3%
     elsewhere the plan is safe; if it reaches double digits it is not.

Layers with too few rows to mean anything are dropped rather than averaged in: the last layer of
the graph is only evaluated for the tokens whose logits are needed, so it yields ~1 row per
ubatch, and an "unused expert" measured from 3 tokens is noise wearing a result's clothes.
"""
import argparse
import itertools
import os

import numpy as np

from expert_freq import counts_for, read_probs


def rankdata(a):
    """Average-tie ranks, so an all-zero tail does not get an arbitrary ordering."""
    order = np.argsort(a, kind="mergesort")
    ranks = np.empty(len(a), dtype=np.float64)
    sorted_a = a[order]
    i = 0
    while i < len(a):
        j = i
        while j + 1 < len(a) and sorted_a[j + 1] == sorted_a[i]:
            j += 1
        ranks[order[i:j + 1]] = 0.5 * (i + j) + 1.0
        i = j + 1
    return ranks


def spearman(x, y):
    rx, ry = rankdata(x), rankdata(y)
    rx = rx - rx.mean()
    ry = ry - ry.mean()
    den = np.sqrt((rx * rx).sum() * (ry * ry).sum())
    return float((rx * ry).sum() / den) if den > 0 else float("nan")


def bottom_set(counts, k):
    """The k least-selected experts. Ties resolved by index, so the set is reproducible."""
    order = np.lexsort((np.arange(len(counts)), counts))
    return set(int(i) for i in order[:k])


def jaccard(a, b):
    u = len(a | b)
    return len(a & b) / u if u else float("nan")


def half_counts(probs, used):
    """Counts from the first and second half of a trace's rows.

    This is the noise floor the cross-text numbers have to be read against. The reference trace
    is only 1110 rows deep, so the average expert is hit ~69 times and two *identical*
    distributions sampled that thinly will not agree perfectly either. Without this control a
    Spearman of 0.8 between code and Russian is uninterpretable: it could be distribution shift
    or it could be the same shift-free router seen twice through a small sample.
    """
    n = probs.shape[0] // 2
    return counts_for(probs[:n], used), counts_for(probs[n:2 * n], used)


def load(path, n_expert, used, rows, min_rows, keep_probs=False):
    if not os.path.exists(path):
        raise SystemExit(f"нет файла трассы: {path}")
    probs = read_probs(path, n_expert, rows)
    if not probs:
        raise SystemExit(
            f"ПРОВАЛ: в {path} нет ни одной записи распределения роутера "
            f"(tag<=-10001, nu={n_expert}). Это не ноль, это сломанная трасса — "
            f"снимать надо с MOE_TRACE_PROBS=1")
    cnt, nrow, thin, halves = {}, {}, [], {}
    for l, p in probs.items():
        nrow[l] = int(p.shape[0])
        if p.shape[0] < min_rows:
            thin.append(l)
            continue
        cnt[l] = counts_for(p, used)
        if keep_probs:
            halves[l] = half_counts(p, used)
    if not cnt:
        raise SystemExit(f"ПРОВАЛ: в {path} все слои тоньше {min_rows} строк")
    return cnt, nrow, sorted(thin), halves


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=r"D:\MemeX\results\tr_p_code.bin",
                    help="trace the bit plan would be fitted on")
    ap.add_argument("--ref-name", default="code(ref)")
    ap.add_argument("--other", action="append", default=[],
                    help="name=path, repeatable")
    ap.add_argument("--experts", type=int, default=128)
    ap.add_argument("--used", type=int, default=8)
    ap.add_argument("--rows", type=int, default=40000)
    ap.add_argument("--min-rows", type=int, default=200)
    ap.add_argument("--bottom", type=int, nargs="+", default=[32, 48])
    args = ap.parse_args()

    traces = [(args.ref_name, args.ref)]
    for spec in args.other:
        name, _, path = spec.partition("=")
        traces.append((name, path))

    cnt, nrow, thin, halves = {}, {}, {}, {}
    for name, path in traces:
        cnt[name], nrow[name], thin[name], halves[name] = load(
            path, args.experts, args.used, args.rows, args.min_rows, keep_probs=True)
        rr = nrow[name]
        kept = sorted(cnt[name])
        print(f"{name:12s} {os.path.basename(path):20s} "
              f"слоёв с данными {len(kept):3d}  строк/слой "
              f"{min(rr[l] for l in kept)}–{max(rr[l] for l in kept)}"
              + (f"  отброшено тонких слоёв: {thin[name]}" if thin[name] else ""))

    names = [n for n, _ in traces]
    layers = sorted(set.intersection(*[set(cnt[n]) for n in names]))
    print(f"\nобщих слоёв для сравнения: {len(layers)} ({layers[0]}..{layers[-1]})")

    pairs = list(itertools.combinations(names, 2))

    # The noise floor: the same text against itself, split in half. Anything the cross-text
    # comparison reports that is no worse than this is not distribution shift, it is sampling.
    print("\n[0] ШУМОВОЙ ПОЛ: половина трассы против своей же второй половины")
    hdr = f"{'трасса':12s} {'строк/полов':>11s} {'Spearman':>9s}"
    for k in args.bottom:
        hdr += f" {'Jacc-' + str(k):>9s}"
    for k in args.bottom:
        hdr += f" {'масса' + str(k) + '%':>10s}"
    print(hdr)
    for n in names:
        sps, jcs, mss = [], {k: [] for k in args.bottom}, {k: [] for k in args.bottom}
        for l in layers:
            a, b = halves[n][l]
            sps.append(spearman(a, b))
            for k in args.bottom:
                jcs[k].append(jaccard(bottom_set(a, k), bottom_set(b, k)))
                # set frozen on half A, priced on half B: the decision number's own noise floor
                idx = np.fromiter(bottom_set(a, k), dtype=np.int64, count=k)
                mss[k].append(float(b[idx].sum() / b.sum() * 100.0))
        row = f"{n:12s} {nrow[n][layers[0]] // 2:11d} {np.mean(sps):9.3f}"
        for k in args.bottom:
            row += f" {np.mean(jcs[k]):9.3f}"
        for k in args.bottom:
            row += f" {np.mean(mss[k]):10.2f}"
        print(row)

    print("\n[1] Spearman по слоям (корреляция частот выбора эксперта)")
    print("слой " + "".join(f"{a[:5]}/{b[:5]:>12s}"[-13:] for a, b in pairs))
    sp = {p: [] for p in pairs}
    for l in layers:
        row = f"{l:4d} "
        for p in pairs:
            v = spearman(cnt[p[0]][l], cnt[p[1]][l])
            sp[p].append(v)
            row += f"{v:13.3f}"
        print(row)
    print("сред " + "".join(f"{np.mean(sp[p]):13.3f}" for p in pairs))
    print("мин  " + "".join(f"{np.min(sp[p]):13.3f}" for p in pairs))

    for k in args.bottom:
        print(f"\n[2] Jaccard пересечения множеств «нижние {k} по частоте»")
        print("слой " + "".join(f"{a[:5]}/{b[:5]:>12s}"[-13:] for a, b in pairs))
        jc = {p: [] for p in pairs}
        for l in layers:
            row = f"{l:4d} "
            for p in pairs:
                v = jaccard(bottom_set(cnt[p[0]][l], k), bottom_set(cnt[p[1]][l], k))
                jc[p].append(v)
                row += f"{v:13.3f}"
            print(row)
        print("сред " + "".join(f"{np.mean(jc[p]):13.3f}" for p in pairs))
        print("мин  " + "".join(f"{np.min(jc[p]):13.3f}" for p in pairs))

    # The decision. Freeze the starve set on the reference trace, then price it elsewhere.
    for k in args.bottom:
        print(f"\n[3] РЕШАЮЩЕЕ ЧИСЛО, нижние {k} зафиксированы по {args.ref_name}: "
              f"доля выборов, попадающих в это множество (%)")
        head = "слой " + "".join(f"{n:>10s}" for n in names)
        print(head + "   |  худ.эксп.в top32")
        mass = {n: [] for n in names}
        promoted = []
        for l in layers:
            bs = bottom_set(cnt[args.ref_name][l], k)
            idx = np.fromiter(bs, dtype=np.int64, count=len(bs))
            row = f"{l:4d} "
            for n in names:
                c = cnt[n][l]
                v = float(c[idx].sum() / c.sum() * 100.0)
                mass[n].append(v)
                row += f"{v:10.2f}"
            # how many of the frozen-starved experts are in the top 32 of some other text
            worst = 0
            for n in names[1:]:
                c = cnt[n][l]
                top = set(int(i) for i in np.lexsort((np.arange(len(c)), -c))[:32])
                worst = max(worst, len(bs & top))
            promoted.append(worst)
            print(row + f"   |{worst:8d}")
        print("сред " + "".join(f"{np.mean(mass[n]):10.2f}" for n in names)
              + f"   |{np.mean(promoted):8.2f}")
        print("макс " + "".join(f"{np.max(mass[n]):10.2f}" for n in names)
              + f"   |{np.max(promoted):8d}")
        base = np.mean(mass[args.ref_name])
        for n in names[1:]:
            print(f"     {n}: {np.mean(mass[n]):.2f}% против {base:.2f}% на опоре "
                  f"→ рост x{np.mean(mass[n]) / base:.2f}")


if __name__ == "__main__":
    main()
