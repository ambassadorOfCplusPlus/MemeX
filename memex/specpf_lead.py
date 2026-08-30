"""How far ahead does the hidden state predict, and does the paper's shared head survive here?

Three questions in one pass, because they share the same fit and the model load is the expensive
part of everything else in this project:

  1. LEAD. SpecPrefetch predicts one layer ahead, which on this machine is ~1.3 ms - exactly one
     promotion. If layer j-2 or j-4 predicts j nearly as well, the lead time doubles or quadruples
     and hiding the transfer stops being tight. This is the difference between a prefetch that has
     to be perfect and one that has slack.

  2. SHAPE. The paper shares BOTH A and B across layers. Our own trace says an expert index means a
     different thing in every layer, so the three shapes are fitted side by side:
       obshchij      one 2048->128 map for every transition   (the paper, at full rank)
       obshchij A    a shared r-dim projection, per-layer head (what a rank-r fit would give)
       poslojnyj     an independent map per transition        (the upper bound)

  3. DOMAIN. A predictor fitted on code and scored on Russian, against the measured fact that a
     code-derived expert SET takes 24.1% of Russian picks versus 25.0% for a random one. If the
     predictor transfers where the set does not, that is its own argument.

Everything is ridge, i.e. the r -> full-rank limit, so a negative answer cannot be blamed on the
optimiser and a positive one is an upper bound rather than a claim.
"""
import argparse
import numpy as np
from specpf_data import load
from specpf_feas import multihot, ridge, topM_recall


def fit_layerwise(X, I, tgt, lead, ntr, E, lam):
    """W[k] maps layer (j-lead) input to layer j expert scores, fitted on the first ntr tokens."""
    Ws = []
    for j in tgt:
        x = X[j - lead][:ntr].astype(np.float32)
        Xtr = np.hstack([x, np.ones((ntr, 1), np.float32)])
        Ws.append(ridge(Xtr, multihot(I[j][:ntr].astype(np.int64), E), lam))
    return Ws


def score(X, tgt, lead, Ws, sl):
    out = []
    for k, j in enumerate(tgt):
        x = X[j - lead][sl].astype(np.float32)
        out.append(np.hstack([x, np.ones((x.shape[0], 1), np.float32)]) @ Ws[k])
    return out


def recalls(sc, ids, Ms=(8, 12, 16, 24)):
    s = np.concatenate(sc)
    i = np.concatenate(ids)
    return [100 * topM_recall(s, i, M) for M in Ms]


def line(name, r, Ms=(8, 12, 16, 24)):
    print("  %-30s" % name + "".join(" R@%d=%6.2f%%" % (M, v) for M, v in zip(Ms, r)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--npz", default=r"D:/MemeX/results/specpf/ap_code.npz")
    ap.add_argument("--cross", nargs="*", default=[],
                    help="npz files fitted-elsewhere, scored here: domain transfer")
    ap.add_argument("--n-expert", type=int, default=128)
    ap.add_argument("--lam", type=float, default=1000.0)
    ap.add_argument("--train-frac", type=float, default=0.7)
    ap.add_argument("--gap", type=int, default=64)
    ap.add_argument("--leads", type=int, nargs="+", default=[1, 2, 4, 8])
    ap.add_argument("--ranks", type=int, nargs="+", default=[16, 32, 64, 128])
    a = ap.parse_args()

    E = a.n_expert
    layers, X, I = load(a.npz)
    L, T, D = X.shape
    ntr = int(T * a.train_frac)
    te = slice(ntr + a.gap, T)
    print("%s: sloev %d, tokenov %d, train %d, test %d" % (a.npz, L, T, ntr, T - ntr - a.gap))

    print("\n1. Zapas po vremeni: skolko sloev vperjod skrytoe sostojanie eshchjo predskazyvaet")
    print("   (odin sloj ~1.3 ms, rovno cena odnoj podkachki)")
    for lead in a.leads:
        tgt = [j for j in range(lead, L) if layers[j] == layers[j - lead] + lead]
        if not tgt:
            continue
        Ws = fit_layerwise(X, I, tgt, lead, ntr, E, a.lam)
        ids = [I[j][te].astype(np.int64) for j in tgt]
        line("zapas %d sloev (%d perehodov)" % (lead, len(tgt)),
             recalls(score(X, tgt, lead, Ws, te), ids))

    lead = 1
    tgt = [j for j in range(1, L) if layers[j] == layers[j - 1] + 1]
    ids = [I[j][te].astype(np.int64) for j in tgt]
    idst = [I[j][:ntr].astype(np.int64) for j in tgt]

    print("\n2. Forma adaptera: obshchij protiv poslojnogo (vsjo - ridge, to est predel po rangu)")
    # Accumulated, never concatenated: the pooled design matrix is 46 x ntr x 2049 floats, which
    # is most of a gigabyte on a machine that may be holding a 15 GB model for the next trace.
    Wl = fit_layerwise(X, I, tgt, 1, ntr, E, a.lam)
    line("poslojnyj (test)", recalls(score(X, tgt, 1, Wl, te), ids))
    line("poslojnyj (train)",
         recalls([np.hstack([X[j - 1][:ntr].astype(np.float32), np.ones((ntr, 1), np.float32)])
                  @ Wl[k] for k, j in enumerate(tgt)], idst))

    G = np.zeros((D + 1, D + 1), np.float64)
    H = np.zeros((D + 1, E), np.float64)
    Cov = np.zeros((D, D), np.float64)
    mu = np.zeros(D, np.float64)
    for j in tgt:
        x = np.hstack([X[j - 1][:ntr].astype(np.float32), np.ones((ntr, 1), np.float32)])
        G += x.T @ x
        H += x.T @ multihot(I[j][:ntr].astype(np.int64), E)
        mu += X[j - 1][:ntr].astype(np.float32).sum(axis=0)
    mu /= ntr * len(tgt)
    muf = mu.astype(np.float32)
    for j in tgt:
        xc = X[j - 1][:ntr].astype(np.float32) - muf
        Cov += xc.T @ xc
    G[np.diag_indices(D + 1)] += a.lam * len(tgt)
    Ws = np.linalg.solve(G, H).astype(np.float32)
    line("OBSHCHIJ A i B (test)",
         recalls([np.hstack([X[j - 1][te].astype(np.float32),
                             np.ones((T - ntr - a.gap, 1), np.float32)]) @ Ws for j in tgt], ids))

    # shared A, per-layer B: A is the top-r principal directions of the pooled router inputs, which
    # is what a shared rank-r bottleneck can carry; B is then fitted per layer inside it.
    w, V = np.linalg.eigh(Cov / (ntr * len(tgt)))
    order = np.argsort(-w)
    for r in a.ranks:
        A = V[:, order[:r]].astype(np.float32)
        Wr = []
        for j in tgt:
            z = (X[j - 1][:ntr].astype(np.float32) - muf) @ A
            Wr.append(ridge(np.hstack([z, np.ones((ntr, 1), np.float32)]),
                            multihot(I[j][:ntr].astype(np.int64), E), a.lam * 1e-3))
        sc = []
        for k, j in enumerate(tgt):
            z = (X[j - 1][te].astype(np.float32) - muf) @ A
            sc.append(np.hstack([z, np.ones((z.shape[0], 1), np.float32)]) @ Wr[k])
        line("obshchij A r=%d, poslojnyj B" % r, recalls(sc, ids))

    print("\n3. Perenos mezhdu domenami: podgonka zdes, ocenka tam")
    for other in a.cross:
        lo, Xo, Io = load(other)
        To = Xo.shape[1]
        tgo = [j for j in range(1, len(lo)) if lo[j] == lo[j - 1] + 1]
        if tgo != tgt:
            print("   %s: drugoj nabor sloev, propuskaem" % other)
            continue
        so = slice(0, To)
        idso = [Io[j].astype(np.int64) for j in tgo]
        line("na %s, poslojnyj" % other.split("/")[-1], recalls(score(Xo, tgo, 1, Wl, so), idso))

        # frequency fitted here, scored there - the control the set-based measurement used
        fr = []
        for k, j in enumerate(tgo):
            c = np.bincount(I[j][:ntr].astype(np.int64).ravel(), minlength=E).astype(np.float32)
            fr.append(np.repeat(c[None, :], To, axis=0))
        line("na %s, chastota otsjuda" % other.split("/")[-1], recalls(fr, idso))


if __name__ == "__main__":
    main()
