"""Hit rate as a function of promotions per token - the frontier, not single points.

A policy comparison at one operating point cannot answer this project's question, because the two
axes were measured to trade against each other: 2.25 points of hit rate bought by churn cost
1.55 tok/s, and the zero-promotion arm was the fastest ever measured here. So every policy is swept
over its own knob and the whole curve is reported; a predictor is worth wiring in only if its curve
lies ABOVE the frequency curve in the region the hardware can actually pay for (measured: the
engine does 0.95 promotions per token at period 64 and 6.91 at period 3).

Score families, all reduced to one thing - a [layer, token, expert] score matrix, from which the
policy takes the top C at its refresh instants:

  lfu      count of selections in a window of W tokens                (what the engine does)
  rec      the same, weighted by recency                              (measured best so far)
  pred     the learned predictor's instantaneous score at this token  (SpecPrefetch)
  predema  the predictor's score smoothed over tokens                 (sustained demand)
  mix      predictor + frequency, both normalised
  orakul   the next P tokens' true counts                             (the bound)
"""
import argparse
import numpy as np
from specpf_data import load
from specpf_feas import multihot, ridge


def win_counts(ids, T, E, W):
    """[T, E] count of each expert among tokens [t-W, t)."""
    oh = np.zeros((T, E), dtype=np.float32)
    np.put_along_axis(oh, ids, 1.0, axis=1)
    cum = np.vstack([np.zeros((1, E), np.float32), np.cumsum(oh, axis=0)])
    lo = np.maximum(np.arange(T) - W, 0)
    return cum[np.arange(T)] - cum[lo]


def rec_counts(ids, T, E, decay):
    oh = np.zeros((T, E), dtype=np.float32)
    np.put_along_axis(oh, ids, 1.0, axis=1)
    out = np.zeros((T, E), dtype=np.float32)
    acc = np.zeros(E, dtype=np.float32)
    for t in range(T):
        out[t] = acc                          # strictly past: token t is not yet known
        acc = acc * decay + oh[t]
    return out


def fut_counts(ids, T, E, P):
    oh = np.zeros((T, E), dtype=np.float32)
    np.put_along_axis(oh, ids, 1.0, axis=1)
    cum = np.vstack([np.zeros((1, E), np.float32), np.cumsum(oh, axis=0)])
    hi = np.minimum(np.arange(T) + P, T)
    return cum[hi] - cum[np.arange(T)]


def simulate(score, ids, C, P, kcap, T0, T1, warm=64):
    """score [L,T,E]; refresh every P tokens, moving at most kcap experts per layer per refresh."""
    L = score.shape[0]
    res = [np.zeros(0, dtype=np.int64) for _ in range(L)]
    hits = tot = promo = 0
    start = T0 - warm
    for t in range(start, T1):
        refresh = (t - start) % P == 0
        for j in range(L):
            if refresh:
                s = score[j, t]
                want = np.argpartition(-s, C - 1)[:C]
                cur = res[j]
                if cur.size == 0:
                    new = want
                else:
                    miss = want[~np.isin(want, cur)]
                    if miss.size:
                        if kcap is not None and miss.size > kcap:
                            miss = miss[np.argsort(-s[miss])[:kcap]]
                        keep = cur[np.isin(cur, want)]
                        drop = cur[~np.isin(cur, want)]
                        drop = drop[np.argsort(-s[drop])]      # give up the least wanted first
                        room = C - keep.size - miss.size
                        new = np.concatenate([keep, miss, drop[:max(0, room)]])
                    else:
                        new = cur
                if t >= T0:
                    promo += int(np.setdiff1d(new, cur).size)
                res[j] = new
            if t >= T0:
                cur = ids[j][t]
                tot += cur.size
                hits += int(np.isin(cur, res[j]).sum())
    return 100.0 * hits / max(1, tot), promo / max(1, T1 - T0)


def build(npz, lam, train_frac, n_expert):
    layers, X, I = load(npz)
    L, T, D = X.shape
    E = n_expert
    ntr = int(T * train_frac)
    tgt = [j for j in range(1, L) if layers[j] == layers[j - 1] + 1]
    nL = len(tgt)
    ids = [I[j].astype(np.int64) for j in tgt]
    Z = np.zeros((nL, T, E), dtype=np.float32)
    for k, j in enumerate(tgt):
        x = X[j - 1][:ntr].astype(np.float32)
        W = ridge(np.hstack([x, np.ones((ntr, 1), np.float32)]),
                  multihot(I[j][:ntr].astype(np.int64), E), lam)
        xa = X[j - 1].astype(np.float32)
        Z[k] = np.hstack([xa, np.ones((T, 1), np.float32)]) @ W
    return layers, T, ntr, tgt, ids, Z


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--npz", default=r"D:/MemeX/results/specpf/act_unknown.npz")
    ap.add_argument("--n-expert", type=int, default=128)
    ap.add_argument("--lam", type=float, default=1000.0)
    ap.add_argument("--train-frac", type=float, default=0.7)
    ap.add_argument("--gap", type=int, default=64)
    ap.add_argument("--caps", type=int, nargs="+", default=[12, 16, 24])
    a = ap.parse_args()

    E = a.n_expert
    layers, T, ntr, tgt, ids, Zs = build(a.npz, a.lam, a.train_frac, E)
    nL = len(tgt)
    T0, T1 = ntr + a.gap, T
    print("tokenov %d; obuchenie 0..%d, ocenka %d..%d (%d tokenov), sloev %d"
          % (T, ntr, T0, T1, T1 - T0, nL))

    sm = np.exp(Zs - Zs.max(axis=2, keepdims=True))
    sm /= sm.sum(axis=2, keepdims=True)

    fam = {}
    fam["lfu32"] = np.stack([win_counts(ids[j], T, E, 32) for j in range(nL)])
    fam["lfu64"] = np.stack([win_counts(ids[j], T, E, 64) for j in range(nL)])
    fam["lfu128"] = np.stack([win_counts(ids[j], T, E, 128) for j in range(nL)])
    fam["rec90"] = np.stack([rec_counts(ids[j], T, E, 0.90) for j in range(nL)])
    fam["rec97"] = np.stack([rec_counts(ids[j], T, E, 0.97) for j in range(nL)])
    fam["pred"] = Zs
    for d in (0.7, 0.9, 0.97):
        acc = np.zeros((nL, E), np.float32)
        out = np.zeros_like(sm)
        for t in range(T):
            acc = acc * d + sm[:, t]
            out[:, t] = acc
        fam["predema%d" % int(d * 100)] = out
    nrm = lambda A: A / np.maximum(A.max(axis=2, keepdims=True), 1e-9)
    fam["mix"] = nrm(fam["rec90"]) + nrm(fam["predema90"])
    for P in (4, 16, 32, 64):
        fam["orakul%d" % P] = np.stack([fut_counts(ids[j], T, E, P) for j in range(nL)])

    freq_fams = ["lfu32", "lfu64", "lfu128", "rec90", "rec97"]
    pred_fams = ["pred", "predema70", "predema90", "predema97", "mix"]
    periods = [1, 2, 4, 8, 16, 32, 64, 128, 1000]

    for C in a.caps:
        print("\n=== C = %d na sloj; podkachki - summa po %d slojam za tokjen ===" % (C, nL))
        pts = {}
        for name in freq_fams + pred_fams:
            pts[name] = []
            for P in periods:
                for kcap in (None, 1):
                    if P == 1000 and kcap is not None:
                        continue
                    h, pr = simulate(fam[name], ids, C, P, kcap, T0, T1)
                    pts[name].append((pr, h, P, kcap))
        pts["orakul"] = []
        for P in (4, 16, 32, 64):
            h, pr = simulate(fam["orakul%d" % P], ids, C, P, None, T0, T1)
            pts["orakul"].append((pr, h, P, None))

        print("%14s %8s %5s %10s %14s" % ("semejstvo", "period", "cap", "popadanij", "podkachek/tok"))
        for name in freq_fams + pred_fams + ["orakul"]:
            for pr, h, P, kcap in sorted(pts[name]):
                if pr > 80:
                    continue
                print("%14s %8s %5s %9.2f%% %14.2f"
                      % (name, "nikogda" if P == 1000 else P,
                         "-" if kcap is None else kcap, h, pr))

        base = sorted(set(sum((pts[f] for f in freq_fams), [])))
        bx = np.array([p[0] for p in base])
        by = np.array([p[1] for p in base])
        env_x, env_y, best = [], [], -1.0
        for xx, yy in zip(bx, by):
            if yy > best:
                best = yy
                env_x.append(xx)
                env_y.append(yy)
        print("  --- pri RAVNYH podkachkah, protiv verhnej ogibajushchej chastotnyh politik ---")
        for name in pred_fams:
            for pr, h, P, kcap in sorted(pts[name]):
                if pr > 60:
                    continue
                ref = float(np.interp(pr, env_x, env_y))
                print("    %10s period %-8s podkachek %6.2f  predskazatel %6.2f%%  chastota %6.2f%%  raznica %+6.2f"
                      % (name, "nikogda" if P == 1000 else P, pr, h, ref, h - ref))


main()
