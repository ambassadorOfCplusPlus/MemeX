"""Predict the DEMAND OVER THE NEXT K TOKENS, not the next layer - and check it is not just LFU.

Why the target changes. The next-layer target is the right one for a just-in-time fetch, and the
break-even arithmetic kills just-in-time fetching outright: 47 promotions x 1.300 ms is 61.1 ms on
a 61.2 ms token, and a promoted expert needs 13.6 demands to pay back, i.e. ~39 tokens of residency
at C=16. So the resident set is not answering "who is needed next", it is answering "who will be
demanded over the next forty tokens". This trains that question directly. The labels change; the
input, the fit and the metric do not.

The target is deliberately the ORACLE'S OWN SCORE: the count of each expert's selections at layer j
over tokens t..t+K-1. The oracle policy in every table of this project is the top C of exactly that
vector, so a horizon predictor is a learned approximation of the oracle and lands on the same axis
as every other policy - which the next-layer recall number cannot do.

THE TRAP, AND THE CHECK THAT DECIDES IT. The union of experts over forty tokens is broad and
dominated by frequent experts, so a model fitted on it can degenerate into a frequency table and
post a high recall while carrying no information about the token in front of it. Two controls:

  shuffled  the same fitted map, scored on hidden states PERMUTED across token positions. Whatever
            recall survives that is what the model knows without looking at the input.
  constant  the map's own time-average, which is frequency by construction.

If shuffled is close to the real thing, the horizon predictor is LFU wearing a hat, and no policy
comparison built on it means anything.
"""
import argparse
import numpy as np
from specpf_data import load
from specpf_feas import ridge, topM_recall


def fut_counts(ids, T, E, K):
    """[T, E]: how often each expert is selected over tokens t .. t+K-1.

    Token t is included on purpose. The router input of layer j-1 at token t is produced before
    layer j of token t runs, so a set installed from it is in place in time - this is the same
    convention the oracle policy uses, and using a different one would put the two on different
    axes for no reason.
    """
    oh = np.zeros((T, E), dtype=np.float32)
    np.put_along_axis(oh, ids, 1.0, axis=1)
    cum = np.vstack([np.zeros((1, E), np.float32), np.cumsum(oh, axis=0)])
    hi = np.minimum(np.arange(T) + K, T)
    return cum[hi] - cum[np.arange(T)]


def horizon_scores(X, I, layers, K, ntr, E, lam, rng=None):
    """Per-layer ridge from layer j-1's input to layer j's demand over the next K tokens.

    Returns (scores, scores_on_shuffled_inputs, tgt).
    """
    L, T, D = X.shape
    tgt = [j for j in range(1, L) if layers[j] == layers[j - 1] + 1]
    S = np.zeros((len(tgt), T, E), dtype=np.float32)
    Sh = np.zeros_like(S)
    perm = np.arange(T) if rng is None else rng.permutation(T)
    for k, j in enumerate(tgt):
        ids = I[j].astype(np.int64)
        Y = fut_counts(ids, T, E, K)[:ntr]
        x = X[j - 1][:ntr].astype(np.float32)
        W = ridge(np.hstack([x, np.ones((ntr, 1), np.float32)]), Y, lam)
        xa = X[j - 1].astype(np.float32)
        Xa = np.hstack([xa, np.ones((T, 1), np.float32)])
        S[k] = Xa @ W
        Sh[k] = Xa[perm] @ W
    return S, Sh, tgt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--npz", default=r"D:/MemeX/results/specpf/ap_code.npz")
    ap.add_argument("--n-expert", type=int, default=128)
    ap.add_argument("--lam", type=float, default=1000.0)
    ap.add_argument("--train-frac", type=float, default=0.7)
    ap.add_argument("--gap", type=int, default=64)
    ap.add_argument("--caps", type=int, nargs="+", default=[12, 16, 24])
    ap.add_argument("--horizons", type=int, nargs="+", default=[1, 8, 16, 32, 64])
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()

    E = a.n_expert
    layers, X, I = load(a.npz)
    L, T, D = X.shape
    ntr = int(T * a.train_frac)
    T0 = ntr + a.gap
    te = slice(T0, T)
    rng = np.random.default_rng(a.seed)
    print("%s: tokenov %d, train %d, test %d" % (a.npz.split("/")[-1], T, ntr, T - T0))
    print("metrika: dolja ekspertov, dejstvitelno vybrannyh na tokene t, popavshih v top-C ocenki")
    print("(to est to zhe, chto merit politika pri obnovlenii kazhdyj tokjen)\n")

    tgt = [j for j in range(1, L) if layers[j] == layers[j - 1] + 1]
    ids_te = [I[j][te].astype(np.int64) for j in tgt]
    true_now = np.concatenate(ids_te)

    # frequency measured on the training tokens: the thing the shuffle control is looking for
    freq = []
    for j in tgt:
        c = np.bincount(I[j][:ntr].astype(np.int64).ravel(), minlength=E).astype(np.float32)
        freq.append(np.repeat(c[None, :], T - T0, axis=0))
    freq = np.concatenate(freq)

    print("%8s %6s %10s %10s %10s %10s" % ("gorizont", "C", "ocenka", "peremeshan", "chastota", "raznica"))
    for C in a.caps:
        r = 100 * topM_recall(freq, true_now, C)
        print("%8s %6d %9s %10s %9.2f%% %10s" % ("-", C, "-", "-", r, "-"))
    for K in a.horizons:
        S, Sh, _ = horizon_scores(X, I, layers, K, ntr, E, a.lam, rng)
        s = np.concatenate([S[k][te] for k in range(len(tgt))])
        sh = np.concatenate([Sh[k][te] for k in range(len(tgt))])
        for C in a.caps:
            v = 100 * topM_recall(s, true_now, C)
            vs = 100 * topM_recall(sh, true_now, C)
            vf = 100 * topM_recall(freq, true_now, C)
            print("%8d %6d %9.2f%% %9.2f%% %9.2f%% %+9.2f" % (K, C, v, vs, vf, v - vf))
        del S, Sh


if __name__ == "__main__":
    main()
