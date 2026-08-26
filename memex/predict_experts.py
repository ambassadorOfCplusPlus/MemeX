# Is expert selection predictable a few tokens ahead, and is predicting better than reacting?
#
# The proposal: give every expert a probability of being used over the next 5-10 tokens, keep the
# most probable ones resident, and recompute periodically. The router already produces a
# distribution over the experts of a layer that sums to 1, so the ingredients exist - but that
# distribution describes the CURRENT token, and it is only available after that layer's attention
# has run. Predicting k tokens ahead needs something the router does not directly give: evidence
# that the distribution persists.
#
# So this measures persistence rather than assuming it, and then compares three policies at equal
# VRAM capacity:
#
#   reactive (LFU over a window)  - what the engine does today, counting past selections
#   predictive (mean probability) - the proposal: rank by the router's own probability mass,
#                                   averaged over the window, rather than by hard selection counts
#   oracle                        - the best any policy could do with that capacity, chosen with
#                                   knowledge of the future. Not achievable; it bounds the others.
#
# The oracle matters because without it a policy comparison cannot distinguish "our policy is bad"
# from "this workload is not predictable". If reactive is already near the oracle, a better
# predictor cannot buy much, and the effort belongs elsewhere.

import argparse, io, struct
import numpy as np

def read_sel(path, n_used, max_rows):
    """Per-layer top-k expert ids, in trace order: {layer: [n_tokens, n_used]}.

    The file stores the ids as int32 but the writer emitted them through a float32 buffer, so a
    naive float read yields denormals (id 106 arrives as 1.49e-43). They are read as int32, which
    is what they are. This trace carries selections only, not the router's full distribution - so a
    policy that ranks experts by probability mass cannot be evaluated from it, and recency-weighted
    frequency stands in for that idea instead.
    """
    out = {}
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12: break
            tag, nu, nt = struct.unpack("<iii", hdr)
            n = nu * nt
            raw = f.read(4 * n)
            if len(raw) < 4 * n: break
            if nu != n_used or tag < 0: continue
            cur = out.setdefault(tag, [])
            if sum(x.shape[0] for x in cur) < max_rows:
                cur.append(np.frombuffer(raw, dtype=np.int32).reshape(-1, n_used))
    return {k: np.concatenate(v, axis=0) for k, v in out.items() if v}

def read_probs(path, n_expert, max_rows):
    """Full router distributions per layer, when the trace carries them.

    The tool writes them under tag -(layer)-10001, and only when MOE_TRACE_PROBS was set. Their
    absence is why the strong form of the proposal could not be tested from the first trace: an
    expert's probability rank is the thing that predicts its entry into the top-8, and a trace of
    selections has thrown that away by construction.
    """
    out = {}
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12: break
            tag, nu, nt = struct.unpack("<iii", hdr)
            n = nu * nt
            raw = f.read(4 * n)
            if len(raw) < 4 * n: break
            if tag > -10001 or tag <= -20000 or nu != n_expert: continue
            layer = -tag - 10001
            cur = out.setdefault(layer, [])
            if sum(x.shape[0] for x in cur) < max_rows:
                cur.append(np.frombuffer(raw, dtype=np.float32).reshape(-1, n_expert))
    return {k: np.concatenate(v, axis=0) for k, v in out.items() if v}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", default=r"D:/MemeX/results/moe_trace.bin")
    ap.add_argument("--n-expert", type=int, default=128)
    ap.add_argument("--n-used", type=int, default=8)
    ap.add_argument("--max-rows", type=int, default=4000)
    a = ap.parse_args()

    prob_all = read_probs(a.trace, a.n_expert, a.max_rows)
    sel_all = read_sel(a.trace, a.n_used, a.max_rows)
    if prob_all:
        # When distributions are present, derive the selections from them rather than trusting two
        # independent records to be aligned - a mismatch between them would be silent and would
        # look like a policy result.
        sel_all = {l: np.argpartition(-p, a.n_used - 1, axis=1)[:, :a.n_used]
                   for l, p in prob_all.items()}
        print("trassa neset polnye raspredelenija - dostupen rang po masse")
    elif not sel_all:
        print("trassa pusta"); return
    else:
        print("v trasse tolko vybory - rang po masse ne proverit")
    # One layer in this trace carries a single row - a partial final chunk. Taking the minimum
    # length across layers let that one row set T for all 48 of them, and every statistic came back
    # as a nan or a zero. Short layers are dropped by name rather than allowed to silence the rest.
    full = max(p.shape[0] for p in sel_all.values())
    short = [l for l, p in sel_all.items() if p.shape[0] < full // 2]
    if short:
        print(f"otbrosheny nepolnye sloi: {short}")
    sel_all = {l: p for l, p in sel_all.items() if p.shape[0] >= full // 2}
    layers = sorted(sel_all)
    T = min(p.shape[0] for p in sel_all.values())
    print(f"trassa: {len(layers)} sloev, {T} tokenov, top-{a.n_used} iz {a.n_expert}")

    # ---- 1. persistence: do the experts chosen now reappear k tokens later?
    print("\n1. Ustojchivost vybora: dolja ekspertov tokena t+k, kotorye byli i v tokene t")
    print("   (sluchajnyj uroven = 8/128 = 6.25%)")
    for k in (1, 2, 3, 5, 10, 20):
        ov = []
        for l in layers:
            s = sel_all[l][:T]
            for t in range(0, T - k, 7):        # stride 7: independent samples, cheap
                ov.append(len(np.intersect1d(s[t], s[t + k])) / a.n_used)
        print(f"     k={k:3}: {100*np.mean(ov):5.1f}%")

    # ---- 2. window union: does a window of the recent past cover the near future?
    print("\n2. Okno proshlogo pokryvaet blizhajshee budushchee")
    print("   (dolja vyborov sledujushchih 10 tokenov, popavshih v objedinenie okna)")
    for W in (4, 8, 16, 32, 64):
        cov, sz = [], []
        for l in layers:
            s = sel_all[l][:T]
            for t in range(W, T - 10, 13):
                past = set(s[t - W:t].ravel().tolist())
                fut = s[t:t + 10].ravel()
                cov.append(np.mean([e in past for e in fut]))
                sz.append(len(past))
        print(f"     okno {W:3} tokenov: pokrytie {100*np.mean(cov):5.1f}%,"
              f" razmer objedinenija {np.mean(sz):5.1f} ekspertov iz {a.n_expert}")

    # ---- 3. three policies at equal capacity
    # Capacity is per layer, so a budget of C experts per layer costs C * n_layer uploads worth of
    # VRAM. The engine's real question is what hit rate a given VRAM size buys.
    print("\n3. Try politiki pri odinakovoj vmestimosti (na sloj), okno 32, obnovlenie kazhdye 4 tokena")
    names = ["lfu", "pred"] + (["mass"] if prob_all else []) + ["oracle"]
    hdr = f"   {'C':>4} {'LFU':>10} {'po nedavnosti':>15}"
    if prob_all: hdr += f" {'po masse':>11}"
    print(hdr + f" {'orakul':>10}")
    W, PER = 32, 4
    for C in (8, 12, 16, 24, 32, 48, 64):
        hits = {n: [] for n in names}
        for l in layers:
            s = sel_all[l][:T]
            pm = prob_all[l][:T] if prob_all else None
            for name in hits:
                res, hit, tot = set(), 0, 0
                for t in range(W, T):
                    if (t - W) % PER == 0:
                        if name == "lfu":
                            cnt = np.bincount(s[t - W:t].ravel(), minlength=a.n_expert)
                            res = set(np.argsort(-cnt)[:C].tolist())
                        elif name == "pred":
                            # The proposal, as far as this trace can express it: weight recent
                            # selections more than old ones, so the set tracks a drifting
                            # distribution instead of averaging over a window that may straddle a
                            # topic change. Ranking by the router's actual probability mass would
                            # be strictly more informative, but the trace does not carry it.
                            w = np.zeros(a.n_expert, dtype=np.float64)
                            for j in range(W):
                                decay = 0.90 ** (W - 1 - j)
                                np.add.at(w, s[t - W + j], decay)
                            res = set(np.argsort(-w)[:C].tolist())
                        elif name == "mass":
                            # The proposal in its strong form: rank by how much probability mass
                            # the router actually put on each expert over the window, which counts
                            # the near-misses that never crossed into the top-8.
                            res = set(np.argsort(-pm[t - W:t].mean(axis=0))[:C].tolist())
                        else:
                            # Chosen knowing the next PER tokens. Not achievable - it is the bound.
                            fut = s[t:t + PER].ravel()
                            cnt = np.bincount(fut, minlength=a.n_expert)
                            res = set(np.argsort(-cnt)[:C].tolist())
                    for e in s[t]:
                        tot += 1
                        if e in res: hit += 1
                hits[name].append(hit / max(1, tot))
        row = f"   {C:>4} {100*np.mean(hits['lfu']):>9.1f}% {100*np.mean(hits['pred']):>14.1f}%"
        if prob_all: row += f" {100*np.mean(hits['mass']):>10.1f}%"
        print(row + f" {100*np.mean(hits['oracle']):>9.1f}%")

main()
