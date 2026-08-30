"""The last place value could hide: does prediction beat observation when observations are scarce?

The break-even arithmetic says a promoted expert has to stay resident for tens of tokens, so the
only affordable schedule is the one already measured as fastest - build the set once, then freeze.
That makes the question about the set's BIRTH, not its maintenance: at the moment the set is first
chosen, is the learned predictor a better source than the handful of routing decisions observed so
far?

Measured as a race with a matched budget. After k tokens of a document, build a set of C experts
per layer two ways - by counting what those k tokens actually routed to, and by scoring them with
the predictor - then freeze both and read the hit rate over the next 192 tokens, which is the
generation length every speed arm in this project uses. The predictor is fitted on a DIFFERENT
domain, because that is the case where observation is worst and prediction has its best chance.
"""
import argparse
import numpy as np
from specpf_data import load
from specpf_feas import multihot, ridge


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fit", default=r"D:/MemeX/results/specpf/ap_code.npz")
    ap.add_argument("--test", nargs="+", default=[r"D:/MemeX/results/specpf/ap_ru.npz",
                                                  r"D:/MemeX/results/specpf/ap_en.npz"])
    ap.add_argument("--n-expert", type=int, default=128)
    ap.add_argument("--lam", type=float, default=1000.0)
    ap.add_argument("--caps", type=int, nargs="+", default=[12, 16, 24])
    ap.add_argument("--ks", type=int, nargs="+", default=[1, 2, 4, 8, 16, 32, 64, 128])
    ap.add_argument("--horizon", type=int, default=192)
    a = ap.parse_args()

    E = a.n_expert
    lf, Xf, If = load(a.fit)
    tgt = [j for j in range(1, len(lf)) if lf[j] == lf[j - 1] + 1]
    ntr = Xf.shape[1]
    W = []
    for j in tgt:
        x = Xf[j - 1][:ntr].astype(np.float32)
        W.append(ridge(np.hstack([x, np.ones((ntr, 1), np.float32)]),
                       multihot(If[j][:ntr].astype(np.int64), E), a.lam))
    print("predskazatel podognan na %s, %d tokenov, %d perehodov"
          % (a.fit.split("/")[-1], ntr, len(tgt)))

    for path in a.test:
        lo, Xo, Io = load(path)
        tgo = [j for j in range(1, len(lo)) if lo[j] == lo[j - 1] + 1]
        assert tgo == tgt
        T = Xo.shape[1]
        S = np.stack([np.hstack([Xo[j - 1].astype(np.float32),
                                 np.ones((T, 1), np.float32)]) @ W[k]
                      for k, j in enumerate(tgo)])
        ids = [Io[j].astype(np.int64) for j in tgo]
        print("\n=== %s, %d tokenov; nabor stroitsja po pervym k i zamorazhivaetsja ==="
              % (path.split("/")[-1], T))
        print("   podkachek na tokjen posle rozhdenija nabora: NOL v oboih plechah")
        for C in a.caps:
            print("   C=%d  %6s %14s %14s %14s" % (C, "k", "nabljudenie", "predskazanie", "raznica"))
            for k in a.ks:
                hb = hp = tot = 0
                for lay in range(len(tgo)):
                    cnt = np.bincount(ids[lay][:k].ravel(), minlength=E)
                    obs = set(np.argsort(-cnt)[:C].tolist())
                    prd = set(np.argsort(-S[lay][:k].mean(axis=0))[:C].tolist())
                    fut = ids[lay][k:k + a.horizon]
                    tot += fut.size
                    hb += sum(1 for e in fut.ravel() if e in obs)
                    hp += sum(1 for e in fut.ravel() if e in prd)
                print("        %6d %13.2f%% %13.2f%% %+13.2f"
                      % (k, 100 * hb / tot, 100 * hp / tot, 100 * (hp - hb) / tot))


if __name__ == "__main__":
    main()
