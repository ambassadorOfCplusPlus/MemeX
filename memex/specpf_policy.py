"""The number that decides whether the engine work is worth doing: hit rate AGAINST promotions.

R@M on its own is not the answer. This project measured the exchange rate directly - churn bought
2.25 points of hit rate and cost 1.55 tok/s, and the zero-promotion arm was the fastest thing ever
measured here (16.35 against 14.80 tok/s). So a predictor is only worth wiring in if it picks
BETTER AT THE SAME PROMOTION BUDGET. Every policy below is therefore reported as a pair.

The predictor's scores come from a per-layer ridge fit on the training tokens only, using the
router input of layer L to score the experts of layer L+1 - the SpecPrefetch shape, at the full
rank limit, which upper-bounds any rank-r version of it.
"""
import argparse
import numpy as np
from specpf_data import load
from specpf_feas import multihot, ridge

def simulate(pick, C, ids, T0, T1, n_layer, E, warm=32):
    """pick(j, t, resident) -> new resident set (or None to keep). Returns (hit%, promo/token)."""
    res = [set() for _ in range(n_layer)]
    hits = tot = promo = 0
    for t in range(T0 - warm, T1):
        scoring = t >= T0
        for j in range(n_layer):
            new = pick(j, t, res[j])
            if new is not None:
                d = len(new - res[j])
                if scoring:
                    promo += d
                res[j] = new
            if scoring:
                cur = ids[j][t]
                tot += len(cur)
                hits += sum(1 for e in cur if e in res[j])
    return 100.0 * hits / max(1, tot), promo / max(1, T1 - T0)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--npz", default=r"D:/MemeX/results/specpf/act_unknown.npz")
    ap.add_argument("--n-expert", type=int, default=128)
    ap.add_argument("--lam", type=float, default=1000.0)
    ap.add_argument("--train-frac", type=float, default=0.7)
    ap.add_argument("--gap", type=int, default=64)
    ap.add_argument("--caps", type=int, nargs="+", default=[12, 16, 24])
    ap.add_argument("--periods", type=int, nargs="+", default=[1, 4, 16, 32, 64])
    a = ap.parse_args()

    layers, X, I = load(a.npz)
    L, T, D = X.shape
    E = a.n_expert
    ntr = int(T * a.train_frac)
    T0, T1 = ntr + a.gap, T
    # Layer 0 has no predecessor to predict from, so it is excluded from EVERY policy rather than
    # given to the baselines only - otherwise the comparison would be between different layer sets.
    tgt = [j for j in range(1, L) if layers[j] == layers[j - 1] + 1]
    print(f"sloev {L}, tokenov {T}; obuchenie 0..{ntr}, ocenka {T0}..{T1} ({T1-T0} tokenov)")
    print(f"ocenivaemyh sloev (u kazhdogo est predshestvennik): {len(tgt)}")

    # ---- predictor: per-layer ridge, trained on the training tokens only
    S = np.zeros((len(tgt), T, E), dtype=np.float32)
    for k, j in enumerate(tgt):
        x = X[j - 1][:ntr].astype(np.float32)
        Xtr = np.hstack([x, np.ones((ntr, 1), np.float32)])
        W = ridge(Xtr, multihot(I[j][:ntr].astype(np.int64), E), a.lam)
        xa = X[j - 1].astype(np.float32)
        S[k] = np.hstack([xa, np.ones((T, 1), np.float32)]) @ W
    ids = [I[j].astype(np.int64) for j in tgt]
    nL = len(tgt)

    print("\n{:>26} {:>4} {:>9} {:>14}".format("politika", "C", "popadanij", "podkachek/tok"))
    rows = []
    def run(name, C, fn, warm=32):
        h, p = simulate(fn, C, ids, T0, T1, nL, E, warm)
        print("{:>26} {:>4} {:>8.2f}% {:>14.2f}".format(name, C, h, p))
        rows.append((name, C, h, p))

    W = 32
    for C in a.caps:
        # frozen: one set built from the window just before evaluation starts, never touched
        def frozen(j, t, cur, C=C):
            if t != T0 - 32:
                return None
            cnt = np.bincount(ids[j][max(0, t - W):t].ravel(), minlength=E)
            return set(np.argsort(-cnt)[:C].tolist())
        run("zamorozhennyj LFU", C, frozen)

        for P in a.periods:
            def lfu(j, t, cur, C=C, P=P):
                if (t - (T0 - 32)) % P:
                    return None
                cnt = np.bincount(ids[j][max(0, t - W):t].ravel(), minlength=E)
                return set(np.argsort(-cnt)[:C].tolist())
            run(f"LFU okno32 period{P}", C, lfu)

            def rec(j, t, cur, C=C, P=P):
                if (t - (T0 - 32)) % P:
                    return None
                w = np.zeros(E)
                lo = max(0, t - W)
                for u in range(lo, t):
                    np.add.at(w, ids[j][u], 0.90 ** (t - 1 - u))
                return set(np.argsort(-w)[:C].tolist())
            run(f"po nedavnosti period{P}", C, rec)

            def pred(j, t, cur, C=C, P=P):
                if (t - (T0 - 32)) % P:
                    return None
                return set(np.argsort(-S[j][t])[:C].tolist())
            run(f"PREDSKAZATEL period{P}", C, pred)

            def orc(j, t, cur, C=C, P=P):
                if (t - (T0 - 32)) % P:
                    return None
                cnt = np.bincount(ids[j][t:t + P].ravel(), minlength=E)
                return set(np.argsort(-cnt)[:C].tolist())
            run(f"orakul period{P}", C, orc)

        # The form that matters: refresh every token but cap how many experts may move, so the
        # promotion budget is set directly instead of being whatever the period happens to give.
        for k in (1, 2, 4):
            def cap(j, t, cur, C=C, k=k):
                s = S[j][t]
                want = np.argsort(-s)[:C]
                miss = [e for e in want if e not in cur][:k]
                if not miss:
                    return None
                new = set(cur)
                if len(new) < C:
                    new |= set(int(e) for e in miss[:C - len(new)])
                    return new
                # evict the resident experts the predictor ranks lowest
                order = sorted(new, key=lambda e: s[e])
                for e in miss:
                    if order:
                        new.discard(order.pop(0))
                        new.add(int(e))
                return new
            run(f"PREDSKAZATEL <={k}/sloj/tok", C, cap)

        # And the same cap driven by frequency instead, so the cap itself is not what wins.
        for k in (1, 2, 4):
            def capf(j, t, cur, C=C, k=k):
                cnt = np.bincount(ids[j][max(0, t - W):t].ravel(), minlength=E).astype(np.float64)
                want = np.argsort(-cnt)[:C]
                miss = [e for e in want if e not in cur][:k]
                if not miss:
                    return None
                new = set(cur)
                if len(new) < C:
                    new |= set(int(e) for e in miss[:C - len(new)])
                    return new
                order = sorted(new, key=lambda e: cnt[e])
                for e in miss:
                    if order:
                        new.discard(order.pop(0))
                        new.add(int(e))
                return new
            run(f"LFU <={k}/sloj/tok", C, capf)
        print()
    return rows

main()
