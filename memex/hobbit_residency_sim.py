"""Does next-layer router projection pay, once it has to evict?

The previous step measured that layer L's gate input through layer L+1's router recovers 83.94%
of layer L+1's true top-8. That is an accuracy, and this project has already learned once that an
accuracy is not a decision: the learned predictor was 80.2% R@16 against 42.4% for frequency and
still lost in 89 of 97 operating points, because it was never priced at equal promotions.

So this replays the engine's OWN residency policy - transcribed from
`ik_llama.cpp/examples/memex-fwd/resident_set.cpp`, not reinvented - and asks what changes when a
prefetch is added. Three arms:

  1. instrument check: reproduce the engine's measured hit rate before believing anything else;
  2. prefetch arm: at layer L, project layer L+1, prefetch predicted experts that are not
     resident, EVICTING the LFU victim for each one. Net hit rate is the number;
  3. global versus per-layer residency at the same total slot count, which is independent of the
     prefetch and free in promotions.

The policy details that matter and were taken from the C++ rather than assumed:

  * hits are accounted in observe() BEFORE the window is updated and BEFORE the refresh, so a
    token is served from a set chosen without seeing it;
  * refresh runs once per token in end_token(), not once per layer, and only when
    tokens % period == 0;
  * the LFU ranking is over the sliding window's counts, ties broken on the LOWER expert id
    (reproducibility - the C++ says so explicitly);
  * cap = min(capacity, distinct): the set is never padded with count-zero experts, because that
    would charge a promotion for each and inflate promotions/token;
  * unclipped, `resident = want` EXACTLY, including the case where that only evicts. The C++
    comment says keeping the surplus would be a free hit-rate improvement and is deliberately not
    taken, so taking it here would be measuring a different policy;
  * clipped by budget: promote the best `budget`, evict the same number of the least-used members
    of resident \\ want.

Prefetch timing. This is a WITHIN-token prefetch. At layer L of token t we predict layer L+1 of
the SAME token, so a correct prefetch is used a few hundred microseconds later. The loop below is
therefore per layer and not vectorised across layers: prefetching into L+1 has to happen after
layer L is accounted and before layer L+1 is.
"""
import argparse, io, json, os, sys
import numpy as np

from hobbit_crosslayer import read_routers, SPECPF, OUT, TOPK, N_EXPERT

# Exchange rate. Every one of these is a measured number from this project, not a model.
MS_PER_HIT_POINT = 0.368    # one hit-rate point, per token
MS_PROMO_SERIAL = 1.306     # a promotion as the engine does it today
MS_PROMO_OVERLAP = 0.357    # the floor if the 0.949 ms submit+fence genuinely hides
TOKEN_MS = 61.2             # the token this is all measured against


def load_domain(dom, run="2"):
    z = np.load(os.path.join(SPECPF, "ap_%s%s.npz" % (dom, run)))
    return z["layers"].astype(int), z["X"], z["I"].astype(np.int64)


def predicted_ranking(layers, X, W, kmax=32):
    """top-`kmax` experts of layer L+1 predicted from layer L's gate input, per token.

    -> P[l, t, kmax] int8, where index l corresponds to layers[l] and the prediction is for
    layers[l]+1. The last layer has no successor and is left at -1.
    """
    nL, T, _ = X.shape
    P = np.full((nL, T, kmax), -1, dtype=np.int8)
    pos = dict((int(l), i) for i, l in enumerate(layers))
    for i, l in enumerate(layers):
        lt = int(l) + 1
        if lt not in pos or lt not in W:
            continue
        lg = X[i].astype(np.float32) @ W[lt].T
        P[i] = np.argsort(-lg, axis=1)[:, :kmax].astype(np.int8)
    return P


class PerLayerLFU:
    """The engine's ResidentSet, per layer, transcribed."""

    def __init__(self, n_layer, capacity, window=64, period=32, budget=8, n_used=TOPK):
        self.nL, self.cap, self.period, self.budget = n_layer, capacity, period, budget
        self.W = window * n_used
        self.res = np.zeros((n_layer, N_EXPERT), dtype=bool)
        self.cnt = np.zeros((n_layer, N_EXPERT), dtype=np.int32)
        self.ring = np.full((n_layer, self.W), -1, dtype=np.int16)
        self.head = 0
        self.fill = 0
        self.n_used = n_used
        self.tokens = 0
        self.promotions = 0
        self.prefetches = 0
        self.evictions = 0

    def push(self, ids):
        """ids: [n_layer, n_used]. Ring is shared-shape across layers because every layer sees
        exactly n_used picks per token, so head/fill are scalars."""
        rows = np.arange(self.nL)[:, None]
        sl = slice(self.head, self.head + self.n_used)
        if self.fill == self.W:
            old = self.ring[:, sl].astype(np.int64)
            self.cnt[rows, old] -= 1
        else:
            self.fill += self.n_used
        self.ring[:, sl] = ids.astype(np.int16)
        self.cnt[rows, ids] += 1
        self.head = (self.head + self.n_used) % self.W

    def refresh(self):
        # (-count, id) ordering: a stable sort on -count leaves ascending id inside a tie.
        order = np.argsort(-self.cnt, axis=1, kind="stable")
        distinct = (self.cnt > 0).sum(axis=1)
        for l in range(self.nL):
            capl = min(self.cap, int(distinct[l]))
            if capl <= 0:
                continue
            want = order[l, :capl]
            wb = np.zeros(N_EXPERT, dtype=bool)
            wb[want] = True
            res = self.res[l]
            promote = want[~res[want]]
            if self.budget > 0 and promote.size > self.budget:
                promote = promote[:self.budget]
                cand = np.flatnonzero(res & ~wb)
                if cand.size:
                    vo = cand[np.argsort(self.cnt[l, cand], kind="stable")]
                    victims = vo[:promote.size]
                    res[victims] = False
                    self.evictions += victims.size
                res[promote] = True
            else:
                gone = int((res & ~wb).sum())
                self.evictions += gone
                self.res[l] = wb
            self.promotions += int(promote.size)

    def end_token(self):
        self.tokens += 1
        if self.tokens % self.period == 0:
            self.refresh()

    def prefetch(self, layer, cands, cap):
        """Bring up to `cap` predicted-but-absent experts into `layer`, each evicting the
        least-used resident. Returns how many were brought in."""
        res = self.res[layer]
        n = 0
        for e in cands:
            if n >= cap:
                break
            e = int(e)
            if e < 0 or res[e]:
                continue
            live = np.flatnonzero(res)
            if live.size >= self.cap:
                # LFU victim by window count, ties on lower id (stable sort over ascending ids).
                v = live[np.argsort(self.cnt[layer, live], kind="stable")[0]]
                res[v] = False
                self.evictions += 1
            res[e] = True
            n += 1
        self.prefetches += n
        return n


def run(layers, I, P=None, capacity=12, window=64, period=32, budget=8,
        cap_per_layer=0, k=8, warmup=200):
    """One replay. cap_per_layer = 0 is the untouched engine policy."""
    nL, T, _ = I.shape
    S = PerLayerLFU(nL, capacity, window, period, budget)
    hits = tot = 0
    hits_w = tot_w = 0
    for t in range(T):
        ids = I[:, t, :]
        for l in range(nL):
            row = ids[l]
            h = int(S.res[l, row].sum())
            hits += h
            tot += TOPK
            if t >= warmup:
                hits_w += h
                tot_w += TOPK
            if cap_per_layer and P is not None and l + 1 < nL:
                S.prefetch(l + 1, P[l, t, :k], cap_per_layer)
        S.push(ids)
        S.end_token()
    return {"hit": hits / float(tot), "hit_warm": hits_w / float(max(tot_w, 1)),
            "promotions": S.promotions, "prefetches": S.prefetches,
            "promo_per_tok": (S.promotions + S.prefetches) / float(T),
            "refresh_promo_per_tok": S.promotions / float(T),
            "prefetch_per_tok": S.prefetches / float(T),
            "evictions": S.evictions, "tokens": T}


class GlobalLFU:
    """The same policy with one pool over all layers instead of a fixed slice per layer.

    Legitimate because every layer receives exactly n_used picks per token, so window counts are
    directly comparable across layers and a global ranking equalises the MARGINAL count - which
    is the water-filling allocation, and therefore the one that maximises total hits at a fixed
    slot count.
    """

    def __init__(self, n_layer, total, window=64, period=32, budget=8, n_used=TOPK):
        self.nL, self.total, self.period, self.budget = n_layer, total, period, budget
        self.W = window * n_used
        self.res = np.zeros(n_layer * N_EXPERT, dtype=bool)
        self.cnt = np.zeros(n_layer * N_EXPERT, dtype=np.int32)
        self.ring = np.full((n_layer, self.W), -1, dtype=np.int16)
        self.head = 0
        self.fill = 0
        self.n_used = n_used
        self.base = (np.arange(n_layer) * N_EXPERT)[:, None]
        self.tokens = 0
        self.promotions = 0
        self.evictions = 0

    def push(self, ids):
        g = (self.base + ids).ravel()
        sl = slice(self.head, self.head + self.n_used)
        if self.fill == self.W:
            old = (self.base + self.ring[:, sl].astype(np.int64)).ravel()
            np.subtract.at(self.cnt, old, 1)
        else:
            self.fill += self.n_used
        self.ring[:, sl] = ids.astype(np.int16)
        np.add.at(self.cnt, g, 1)
        self.head = (self.head + self.n_used) % self.W

    def refresh(self):
        distinct = int((self.cnt > 0).sum())
        capl = min(self.total, distinct)
        if capl <= 0:
            return
        order = np.argsort(-self.cnt, kind="stable")
        want = order[:capl]
        wb = np.zeros_like(self.res)
        wb[want] = True
        promote = want[~self.res[want]]
        bud = self.budget * self.nL
        if bud > 0 and promote.size > bud:
            promote = promote[:bud]
            cand = np.flatnonzero(self.res & ~wb)
            if cand.size:
                vo = cand[np.argsort(self.cnt[cand], kind="stable")]
                victims = vo[:promote.size]
                self.res[victims] = False
                self.evictions += victims.size
            self.res[promote] = True
        else:
            self.evictions += int((self.res & ~wb).sum())
            self.res = wb
        self.promotions += int(promote.size)

    def end_token(self):
        self.tokens += 1
        if self.tokens % self.period == 0:
            self.refresh()


def run_global(I, total, window=64, period=32, budget=8, warmup=200):
    nL, T, _ = I.shape
    S = GlobalLFU(nL, total, window, period, budget)
    hits = tot = hits_w = tot_w = 0
    base = (np.arange(nL) * N_EXPERT)[:, None]
    for t in range(T):
        ids = I[:, t, :]
        h = int(S.res[(base + ids).ravel()].sum())
        hits += h
        tot += nL * TOPK
        if t >= warmup:
            hits_w += h
            tot_w += nL * TOPK
        S.push(ids)
        S.end_token()
    return {"hit": hits / float(tot), "hit_warm": hits_w / float(max(tot_w, 1)),
            "promotions": S.promotions, "promo_per_tok": S.promotions / float(T),
            "evictions": S.evictions, "tokens": T}


def price(dhit_points, dpromo_per_tok):
    """-> (ms/token at the overlapped rate, ms/token serialized). Negative is a win."""
    gain = dhit_points * MS_PER_HIT_POINT
    return (gain - dpromo_per_tok * MS_PROMO_OVERLAP,
            gain - dpromo_per_tok * MS_PROMO_SERIAL)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--domains", default="code,en,ru")
    ap.add_argument("--capacity", type=int, default=12)
    ap.add_argument("--warmup", type=int, default=200)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    doms = a.domains.split(",")
    W = read_routers(r"D:\Qwen3-Coder-30B-A3B-mx1.gguf")
    L = []
    P_ = L.append

    data = {}
    for d in doms:
        layers, X, I = load_domain(d)
        Pr = predicted_ranking(layers, X, W)
        del X
        data[d] = (layers, I, Pr)
        print("  %s: %d sloev, %d tokenov, predskazanija gotovy" % (d, I.shape[0], I.shape[1]))

    res = {"config": {"window": 64, "period": 32, "budget": 8, "warmup": a.warmup}}

    # ---------------------------------------------------------------- arm 1: instrument check
    P_("ARM 1 - PROVERKA INSTRUMENTA")
    P_("politika dvizhka (resident_set.cpp), okno 64, period 32, bjudzhet 8, LFU")
    P_("celevoe chislo iz zadanija: 71.3%% popadanij pri C=12")
    P_("")
    P_("  C    popadanij (posle progreva)               promotions/tok")
    P_("        code      en        ru      srednee")
    sweep = {}
    for C in (8, 12, 16, 20, 24, 29):
        r = dict((d, run(data[d][0], data[d][1], capacity=C, warmup=a.warmup)) for d in doms)
        m = np.mean([r[d]["hit_warm"] for d in doms])
        pt = np.mean([r[d]["promo_per_tok"] for d in doms])
        sweep[C] = {"per_domain": r, "mean_hit_warm": float(m), "promo_per_tok": float(pt)}
        P_("  %2d   %6.2f%%  %6.2f%%  %6.2f%%   %6.2f%%      %6.2f"
           % (C, 100 * r["code"]["hit_warm"], 100 * r["en"]["hit_warm"],
              100 * r["ru"]["hit_warm"], 100 * m, pt))
    res["capacity_sweep"] = sweep
    P_("")

    # The capacity that reproduces the engine's number is the one every later arm must use.
    # resident_set.hpp names 29 as the design point ("29 resident experts per layer ... gives a
    # 67-80% hit rate depending on the text"), and the sweep lands there, not at 12.
    CAPS = [29, 12]
    res["arms"] = {}
    for C in CAPS:
        base = dict((d, run(data[d][0], data[d][1], capacity=C, warmup=a.warmup)) for d in doms)
        bh = np.mean([base[d]["hit_warm"] for d in doms])
        bp = np.mean([base[d]["promo_per_tok"] for d in doms])
        arm = {"baseline": {"hit_warm": float(bh), "promo_per_tok": float(bp)}}

        P_("=" * 78)
        P_("ARM 2 - PODKACHKA PO PROEKCII, C=%d" % C)
        P_("bazovaja linija: %.2f%% popadanij, %.2f podkachek/tok" % (100 * bh, bp))
        P_("")
        P_("k-svip pri cap=1 (odna podkachka na sloj - edinstvennyj realnyj sluchaj):")
        P_("   k    popadanij   delta    podkachek/tok    ms/tok (0.357)   ms/tok (1.306)")
        ks = {}
        for k in (8, 12, 16, 24, 32):
            r = dict((d, run(data[d][0], data[d][1], data[d][2], capacity=C,
                             cap_per_layer=1, k=k, warmup=a.warmup)) for d in doms)
            h = np.mean([r[d]["hit_warm"] for d in doms])
            pt = np.mean([r[d]["promo_per_tok"] for d in doms])
            dh = 100 * (h - bh)
            ov, se = price(dh, pt - bp)
            ks[k] = {"hit_warm": float(h), "dhit_points": float(dh),
                     "promo_per_tok": float(pt), "ms_overlap": float(ov), "ms_serial": float(se),
                     "per_domain": r}
            P_("  %2d    %7.2f%%  %+7.2f   %10.2f      %+9.2f       %+9.2f"
               % (k, 100 * h, dh, pt, ov, se))
        arm["k_sweep_cap1"] = ks
        best_k = max(ks, key=lambda kk: ks[kk]["dhit_points"])
        P_("  luchshij po CHISTYM popadanijam: k=%d (%+.2f punkta)"
           % (best_k, ks[best_k]["dhit_points"]))
        P_("")
        P_("cap-svip pri k=%d (cap>1 pokazan kak forma krivoj, ne kak variant):" % best_k)
        P_("  cap   popadanij   delta    podkachek/tok    ms/tok (0.357)   ms/tok (1.306)")
        cs = {}
        for cp in (1, 2, 3):
            r = dict((d, run(data[d][0], data[d][1], data[d][2], capacity=C,
                             cap_per_layer=cp, k=best_k, warmup=a.warmup)) for d in doms)
            h = np.mean([r[d]["hit_warm"] for d in doms])
            pt = np.mean([r[d]["promo_per_tok"] for d in doms])
            dh = 100 * (h - bh)
            ov, se = price(dh, pt - bp)
            cs[cp] = {"hit_warm": float(h), "dhit_points": float(dh),
                      "promo_per_tok": float(pt), "ms_overlap": float(ov),
                      "ms_serial": float(se), "per_domain": r}
            P_("  %2d    %7.2f%%  %+7.2f   %10.2f      %+9.2f       %+9.2f"
               % (cp, 100 * h, dh, pt, ov, se))
        arm["cap_sweep"] = cs
        arm["best_k"] = best_k
        P_("")

        P_("ARM 3 - GLOBALNYJ NABOR PROTIV POSLOJNOGO, C=%d (vsego %d slotov)"
           % (C, C * data[doms[0]][1].shape[0]))
        tot = C * data[doms[0]][1].shape[0]
        g = dict((d, run_global(data[d][1], tot, warmup=a.warmup)) for d in doms)
        gh = np.mean([g[d]["hit_warm"] for d in doms])
        gp = np.mean([g[d]["promo_per_tok"] for d in doms])
        ov, se = price(100 * (gh - bh), gp - bp)
        P_("  poslojno  %6.2f%%   %5.2f podkachek/tok" % (100 * bh, bp))
        P_("  globalno  %6.2f%%   %5.2f podkachek/tok   delta %+.2f punkta   %+.2f ms/tok"
           % (100 * gh, gp, 100 * (gh - bh), ov))
        for d in doms:
            P_("     %-5s poslojno %6.2f%%  globalno %6.2f%%  delta %+.2f"
               % (d, 100 * base[d]["hit_warm"], 100 * g[d]["hit_warm"],
                  100 * (g[d]["hit_warm"] - base[d]["hit_warm"])))
        arm["global"] = {"hit_warm": float(gh), "promo_per_tok": float(gp),
                         "dhit_points": float(100 * (gh - bh)), "ms_overlap": float(ov),
                         "per_domain": g}
        P_("")
        res["arms"][str(C)] = arm

    print("\n".join(L))
    with io.open(os.path.join(a.out, "residency_sim.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    with io.open(os.path.join(a.out, "residency_sim.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1)
    return res


if __name__ == "__main__":
    main()
