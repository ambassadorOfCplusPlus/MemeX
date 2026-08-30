"""Feasibility, before any training run: is there a linear map from layer L's router input to
layer L+1's expert demand, and does the paper's SHARED output head survive our model?

Both questions are answered with ridge regression rather than SGD on purpose. A ridge solution is
the r -> full-rank limit of z = B A x, so it is an UPPER BOUND on what any rank-r adapter of the
same shape can reach. If the bound fails there is nothing to train; if it holds, the rank sweep is
about cost, not about whether the idea works.

Metric: R@M, the share of the 8 experts the native router actually picks at layer L+1 that are
inside the predictor's top-M. Same quantity the paper reports.
"""
import argparse
import numpy as np
from specpf_data import load

def topM_recall(score, true_ids, M):
    """score [T,E], true_ids [T,k] -> mean share of true ids inside top-M of score."""
    idx = np.argpartition(-score, M - 1, axis=1)[:, :M]
    hit = 0
    for t in range(score.shape[0]):
        hit += np.intersect1d(idx[t], true_ids[t]).size
    return hit / (score.shape[0] * true_ids.shape[1])

def multihot(ids, E):
    Y = np.zeros((ids.shape[0], E), dtype=np.float32)
    np.put_along_axis(Y, ids.astype(np.int64), 1.0, axis=1)
    return Y

def ridge(Xtr, Ytr, lam):
    d = Xtr.shape[1]
    A = Xtr.T @ Xtr
    A[np.diag_indices(d)] += lam
    return np.linalg.solve(A, Xtr.T @ Ytr)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--npz", default=r"D:/MemeX/results/specpf/act_unknown.npz")
    ap.add_argument("--n-expert", type=int, default=128)
    ap.add_argument("--lam", type=float, nargs="+", default=[1e2, 1e3, 1e4])
    ap.add_argument("--train-frac", type=float, default=0.7)
    ap.add_argument("--gap", type=int, default=32)
    a = ap.parse_args()

    layers, X, I = load(a.npz)
    L, T, D = X.shape
    E = a.n_expert
    ntr = int(T * a.train_frac)
    tr = slice(0, ntr)
    te = slice(ntr + a.gap, T)               # a gap so the test tokens are not the train tokens' neighbours
    print(f"sloev {L}, tokenov {T}, D={D}, train {ntr}, test {T - ntr - a.gap}")

    # transitions l -> l+1, both present
    trans = [(i, i + 1) for i in range(L - 1) if layers[i + 1] == layers[i] + 1]
    print(f"perehodov L->L+1: {len(trans)}")

    Ms = (8, 12, 16, 24)
    def report(name, scores_te, ids_te):
        row = [topM_recall(np.concatenate(scores_te), np.concatenate(ids_te), M) for M in Ms]
        print("  {:28s}".format(name) + "".join(f" R@{M}={100*v:6.2f}%" for M, v in zip(Ms, row)))
        return row

    # ---------------- baselines
    freq_s, freq_i, oracle_s, prev_s = [], [], [], []
    for i, j in trans:
        ids_te = I[j][te].astype(np.int64)
        cnt = np.bincount(I[j][tr].ravel().astype(np.int64), minlength=E).astype(np.float32)
        freq_s.append(np.repeat(cnt[None, :], ids_te.shape[0], axis=0))
        freq_i.append(ids_te)
        # oracle: the true selection scored 1, everything else 0 -> R@M = 1 for M>=8
        o = multihot(ids_te, E)
        oracle_s.append(o)
        # previous token, same layer: what the engine's cheapest reactive signal knows
        pv = np.zeros((ids_te.shape[0], E), dtype=np.float32)
        prev = I[j][ntr + a.gap - 1: T - 1].astype(np.int64)
        np.put_along_axis(pv, prev, 1.0, axis=1)
        prev_s.append(pv)
    print("\nbazovye linii (te zhe otlozhennye tokeny)")
    report("chastota na train", freq_s, freq_i)
    report("proshlyj tokjen, tot zhe sloj", prev_s, freq_i)
    report("orakul", oracle_s, freq_i)

    # ---------------- ridge, per layer and shared
    Xtr_all, Ytr_all = [], []
    for i, j in trans:
        x = X[i][tr].astype(np.float32)
        Xtr_all.append(np.hstack([x, np.ones((x.shape[0], 1), np.float32)]))
        Ytr_all.append(multihot(I[j][tr].astype(np.int64), E))

    for lam in a.lam:
        print(f"\nridge lam={lam:g}")
        # per-layer
        sc, idsl, sc_tr, ids_tr = [], [], [], []
        for k, (i, j) in enumerate(trans):
            W = ridge(Xtr_all[k], Ytr_all[k], lam)
            xte = X[i][te].astype(np.float32)
            sc.append(np.hstack([xte, np.ones((xte.shape[0], 1), np.float32)]) @ W)
            idsl.append(I[j][te].astype(np.int64))
            sc_tr.append(Xtr_all[k] @ W)
            ids_tr.append(I[j][tr].astype(np.int64))
        report("poslojnyj linejnyj (test)", sc, idsl)
        report("poslojnyj linejnyj (train)", sc_tr, ids_tr)

        # shared across layers, exactly the paper's shape at full rank
        Xs = np.concatenate(Xtr_all); Ys = np.concatenate(Ytr_all)
        Ws = ridge(Xs, Ys, lam * len(trans))
        sc = []
        for i, j in trans:
            xte = X[i][te].astype(np.float32)
            sc.append(np.hstack([xte, np.ones((xte.shape[0], 1), np.float32)]) @ Ws)
        report("OBSHCHIJ linejnyj (test)", sc, idsl)

if __name__ == "__main__":
    main()
