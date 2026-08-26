# Two sources of prediction the resident set does not use, both testable without distributions.
#
# The gap being aimed at: at 16 experts per layer, frequency-over-window gets 76.2% of requests and
# an oracle that can see the next four tokens gets 91.0%. Fifteen points are not in capacity and not
# in the workload being unpredictable - they are in the predictor.
#
# SOURCE 1 - CO-OCCURRENCE. Frequency counts each expert alone. But experts are chosen eight at a
# time, and if some travel together then seeing one is evidence for the others. A frequency table
# cannot express that; a pairwise table can. Tested as: given this token's already-known choices at
# a layer, how well do the co-occurrence partners predict the NEXT token's choices at that layer.
#
# SOURCE 2 - THE PREVIOUS LAYER, WITHIN THE SAME TOKEN. This one is different in kind and worth more
# if it works. Every other predictor here forecasts across tokens, so the earliest it can act is one
# token ahead. But layer L's routing happens strictly before layer L+1's, inside the same forward
# pass - so if L predicts L+1, the prefetch can start mid-token, with 47 layers of runway on this
# model instead of one token. That converts a prediction problem into a scheduling one.
#
# The oracle is carried through everything as the bound. Without it a comparison cannot separate
# "our predictor is weak" from "this workload has no more signal in it".

import argparse, io, struct
import numpy as np

def read_sel(path, n_used, max_rows):
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

ap = argparse.ArgumentParser()
ap.add_argument("--trace", default=r"D:/MemeX/results/moe_trace.bin")
ap.add_argument("--n-expert", type=int, default=128)
ap.add_argument("--n-used", type=int, default=8)
a = ap.parse_args()

sel = read_sel(a.trace, a.n_used, 4000)
full = max(p.shape[0] for p in sel.values())
sel = {l: p for l, p in sel.items() if p.shape[0] >= full // 2}
layers = sorted(sel)
T = min(p.shape[0] for p in sel.values())
E = a.n_expert
print(f"trassa: {len(layers)} sloev, {T} tokenov, top-{a.n_used} iz {E}")

# ---------- 1. co-occurrence: do experts travel in groups?
print("\n1. Sovmestnaja vstrechaemost: naskolko vybor odnogo predskazyvaet ostalnyh")
lift = []
for l in layers:
    s = sel[l][:T]
    cnt = np.bincount(s.ravel(), minlength=E).astype(np.float64)
    p_solo = cnt / max(1.0, cnt.sum() / a.n_used)      # P(expert used in a token)
    co = np.zeros((E, E))
    for row in s:
        for i in row:
            co[i, row] += 1
    np.fill_diagonal(co, 0)
    with np.errstate(divide='ignore', invalid='ignore'):
        # P(j | i) against P(j): >1 means they travel together
        pj_given_i = co / np.maximum(cnt[:, None], 1)
        ratio = pj_given_i / np.maximum(p_solo[None, :], 1e-9)
    m = np.isfinite(ratio) & (co > 20)
    if m.any(): lift.append(np.median(ratio[m]))
print(f"   mediannoe otnoshenie P(j|i) k P(j): {np.mean(lift):.2f}"
      f"  (1.00 = nezavisimy, vyshe = hodjat gruppami)")

# ---------- 2. the previous layer, within the same token
print("\n2. Predydushchij sloj predskazyvaet sledujushchij VNUTRI odnogo tokena")
print("   (sluchajnyj uroven = 8/128 = 6.2%; sravnenie - tot zhe sloj na proshlom tokene)")
same_tok, prev_tok = [], []
for i in range(1, len(layers)):
    a_, b_ = sel[layers[i-1]][:T], sel[layers[i]][:T]
    for t in range(0, T, 5):
        same_tok.append(len(np.intersect1d(a_[t], b_[t])) / a.n_used)
        if t: prev_tok.append(len(np.intersect1d(b_[t-1], b_[t])) / a.n_used)
print(f"   sloj L-1 tot zhe tokjen : {100*np.mean(same_tok):5.1f}%")
print(f"   tot zhe sloj, proshlyj  : {100*np.mean(prev_tok):5.1f}%")

# ---------- 3. do the two combine, and how far are they from the bound?
print("\n3. Politiki pri emkosti C na sloj, okno 32, obnovlenie kazhdye 4 tokena")
print(f"   {'C':>4} {'chastota':>10} {'+ sovmestnost':>15} {'orakul':>9}")
W, PER = 32, 4
for C in (8, 12, 16, 24, 32):
    res = {"freq": [], "cooc": [], "oracle": []}
    for l in layers:
        s = sel[l][:T]
        co = np.zeros((E, E))
        for row in s[:W]:
            for i in row: co[i, row] += 1
        for name in res:
            cur, hit, tot = set(), 0, 0
            for t in range(W, T):
                if (t - W) % PER == 0:
                    cnt = np.bincount(s[t-W:t].ravel(), minlength=E).astype(np.float64)
                    if name == "freq":
                        cur = set(np.argsort(-cnt)[:C].tolist())
                    elif name == "cooc":
                        # Frequency, plus the partners of what this token just used: an expert that
                        # rides with a currently-active one is evidence a count cannot carry.
                        boost = co[s[t-1]].sum(axis=0)
                        score = cnt / max(1.0, cnt.max()) + 0.5 * boost / max(1.0, boost.max())
                        cur = set(np.argsort(-score)[:C].tolist())
                    else:
                        cur = set(np.argsort(-np.bincount(s[t:t+PER].ravel(), minlength=E))[:C].tolist())
                for e in s[t]:
                    tot += 1
                    if e in cur: hit += 1
                if t >= W:
                    for i in s[t]: co[i, s[t]] += 1
            res[name].append(hit / max(1, tot))
    print(f"   {C:>4} {100*np.mean(res['freq']):>9.1f}% {100*np.mean(res['cooc']):>14.1f}%"
          f" {100*np.mean(res['oracle']):>8.1f}%")
