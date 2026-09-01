"""HOBBIT (arXiv 2411.01433) cross-layer router reuse, measured on our model and our traces.

The claim under test: consecutive MoE layers see almost the same gate input (cosine > 0.99,
because of the residual stream), so evaluating layer L+1's router on layer L's gate input
recovers layer L+1's expert selection early - 96% top-k accuracy one layer ahead, ~90% two and
three ahead, no training, no architectural change.

This is not the learned predictor this project already refuted. There is no fitted model here:
the router weights are the model's own f32 `blk.N.ffn_gate_inp.weight`, read out of the GGUF and
applied to a recorded activation. The refutation of the learned predictor does not reach it.

Why the answer matters in this project's units: a promotion costs 1.306 ms, of which 0.949 ms is
a synchronous fence wait. One hit-rate point is worth 0.368 ms/token, so a promotion must buy
3.55 points to break even. Knowing layer L+1's selection while layer L still runs lets the upload
start a full layer early and the fence overlap real work - effective cost toward 0.357 ms and
break-even toward 0.97 points. That is the only reason to ask.

Format traps handled upstream in specpf_data.py and restated here so they are not rediscovered:
every activation is written twice (name-prefix matching plus ggml_cast), and layer 47 arrives
with a single token so a min across layers zeroes all 48. The cached .npz already has both dealt
with - it carries 47 layers.

Held-out discipline: the router projection needs no training, but the frequency baseline does,
so the two are compared on the same tokens. Frequency tables come from runs 0 and 1 of a domain;
everything is scored on run 2, which is a different prompt.
"""
import argparse, io, json, os, struct, sys
import numpy as np

GGUF = r"D:\Qwen3-Coder-30B-A3B-mx1.gguf"
SPECPF = r"D:\MemeX\results\specpf"
OUT = r"D:\MemeX\results\hobbit"
TOPK = 8
N_EXPERT = 128
D_MODEL = 2048


# ---------------------------------------------------------------- gguf router readout
def read_routers(path, n_layer_max=64):
    """-> {layer: W[n_expert, d_model] float32}, read straight out of the file.

    Header parsing is traffic.py's, extended with the one thing it does not need and this does:
    where the tensor data actually starts. GGUF stores per-tensor offsets relative to the end of
    the header, aligned up to general.alignment (32 unless the file says otherwise).
    """
    f = io.open(path, "rb")
    if f.read(4) != b"GGUF":
        raise SystemExit(f"{path}: ne GGUF")
    struct.unpack("<I", f.read(4))
    nt, = struct.unpack("<Q", f.read(8))
    nk, = struct.unpack("<Q", f.read(8))

    def rs():
        n, = struct.unpack("<Q", f.read(8))
        return f.read(n).decode("utf-8", "replace")

    S = {0: "<b", 1: "<B", 2: "<h", 3: "<H", 4: "<i", 5: "<I", 6: "<f", 7: "<?",
         10: "<q", 11: "<Q", 12: "<d"}

    def rv(t):
        if t == 8:
            return rs()
        if t == 9:
            et, = struct.unpack("<I", f.read(4))
            n, = struct.unpack("<Q", f.read(8))
            return [rv(et) for _ in range(n)]
        fmt = S[t]
        return struct.unpack(fmt, f.read(struct.calcsize(fmt)))[0]

    kv = {}
    for _ in range(nk):
        k = rs()
        t, = struct.unpack("<I", f.read(4))
        kv[k] = rv(t)
    tensors = {}
    for _ in range(nt):
        nm = rs()
        nd, = struct.unpack("<I", f.read(4))
        dims = [struct.unpack("<Q", f.read(8))[0] for _ in range(nd)]
        tt, = struct.unpack("<I", f.read(4))
        off, = struct.unpack("<Q", f.read(8))
        tensors[nm] = (dims, tt, off)
    align = kv.get("general.alignment", 32)
    data_start = f.tell()
    if data_start % align:
        data_start += align - data_start % align

    W = {}
    for l in range(n_layer_max):
        nm = "blk.%d.ffn_gate_inp.weight" % l
        if nm not in tensors:
            continue
        dims, tt, off = tensors[nm]
        if tt != 0:
            # f32 is what the router is in every Qwen3-MoE GGUF seen here. Anything else means
            # there is no dequant path in this file, and a wrong router produces a plausible
            # number rather than an error.
            raise SystemExit("%s: tip %d, a ne f32 - dekvantovat zdes nechem" % (nm, tt))
        if list(dims) != [D_MODEL, N_EXPERT]:
            raise SystemExit("%s: forma %s, ozhidalos [%d, %d]" % (nm, dims, D_MODEL, N_EXPERT))
        f.seek(data_start + off)
        raw = f.read(4 * D_MODEL * N_EXPERT)
        # GGUF dims are ne0-fastest: [d_model, n_expert] is n_expert rows of d_model floats,
        # i.e. row e is the expert-e weight vector. logits = X @ W.T.
        W[l] = np.frombuffer(raw, dtype=np.float32).reshape(N_EXPERT, D_MODEL).copy()
    f.close()
    if not W:
        raise SystemExit("%s: ne najden ni odin blk.N.ffn_gate_inp.weight" % path)
    return W


# ---------------------------------------------------------------- measures
def topk_ids(logits, k=TOPK):
    return np.argpartition(-logits, k - 1, axis=-1)[:, :k]


def overlap(pred, true, k=TOPK):
    """Mean |pred cap true| / k over tokens. Both [T, k] arrays of expert ids."""
    T = pred.shape[0]
    m = np.zeros((T, N_EXPERT), dtype=bool)
    m[np.arange(T)[:, None], pred] = True
    return m[np.arange(T)[:, None], true].sum(axis=1) / float(k)


def cos_rows(A, B):
    a = A / (np.linalg.norm(A, axis=1, keepdims=True) + 1e-12)
    b = B / (np.linalg.norm(B, axis=1, keepdims=True) + 1e-12)
    return (a * b).sum(axis=1)


def counts_from(npz_paths, n_layer):
    c = np.zeros((n_layer, N_EXPERT), dtype=np.int64)
    for p in npz_paths:
        z = np.load(p)
        layers, I = z["layers"], z["I"]
        for li, l in enumerate(layers):
            if l >= n_layer:
                continue
            np.add.at(c[l], I[li].reshape(-1).astype(np.int64), 1)
        del z
    return c


# ---------------------------------------------------------------- one domain
def run_domain(dom, W, verbose=True):
    ev = os.path.join(SPECPF, "ap_%s2.npz" % dom)
    tr = [os.path.join(SPECPF, "ap_%s.npz" % dom), os.path.join(SPECPF, "ap_%s1.npz" % dom)]
    z = np.load(ev)
    layers = z["layers"].astype(int)
    X, I = z["X"], z["I"].astype(np.int64)
    n_layer = int(layers.max()) + 1
    T = X.shape[1]
    pos = {int(l): i for i, l in enumerate(layers)}
    if verbose:
        print("\n=== %s: ocenka na %s, %d tokenov, %d sloev; chastota s %s"
              % (dom, os.path.basename(ev), T, len(layers),
                 ", ".join(os.path.basename(p) for p in tr)))

    freq = counts_from(tr, n_layer)
    freq_top = np.argsort(-freq, axis=1)[:, :TOPK]          # static table, train tokens only

    res = {"domain": dom, "eval_file": os.path.basename(ev), "tokens": int(T),
           "layers": [int(l) for l in layers], "per_layer": {}, "mean": {}}

    for d in (0, 1, 2, 3):
        ov, cs, fq, pv = [], [], [], []
        per = []
        for l in layers:
            lt = int(l) + d
            if lt not in pos or lt not in W:
                continue
            xs = X[pos[int(l)]].astype(np.float32)          # gate input at L
            true = I[pos[lt]]                               # true selection at L+d
            pred = topk_ids(xs @ W[lt].T)
            o = overlap(pred, true)
            c = cos_rows(xs, X[pos[lt]].astype(np.float32))
            fbase = overlap(np.repeat(freq_top[lt][None, :], T, axis=0), true)
            # same layer, previous token: what a promotion policy already has for free
            prevo = overlap(I[pos[lt]][:-1], true[1:])
            per.append({"L": int(l), "target": lt,
                        "overlap": float(o.mean()), "cos": float(c.mean()),
                        "freq": float(fbase.mean()), "prev_tok": float(prevo.mean())})
            ov.append(o.mean()); cs.append(c.mean())
            fq.append(fbase.mean()); pv.append(prevo.mean())
        if d == 1:
            # Two controls, both demanded by how the learned-predictor line was judged.
            #
            # Shuffle: the SAME router at L+1 driven by the gate input of a DIFFERENT token.
            # This is the router's own marginal - whatever a fixed-ish input direction would
            # select regardless of which token is being routed. If the honest score sits near
            # this, the "cross-layer" story is decoration on a popularity prior.
            #
            # Capacity sweep: overlap is recall at capacity k, so widening the prefetch is the
            # obvious lever and has to be priced against frequency at the same k.
            rng = np.random.default_rng(0)
            perm = rng.permutation(T)
            sh, rk, rkf = [], {}, {}
            for l in layers:
                lt = int(l) + 1
                if lt not in pos or lt not in W:
                    continue
                xs = X[pos[int(l)]].astype(np.float32)
                true = I[pos[lt]]
                lg = xs @ W[lt].T
                sh.append(overlap(topk_ids(lg[perm]), true).mean())
                order = np.argsort(-lg, axis=1)
                forder = np.argsort(-freq[lt])
                for k in (8, 12, 16, 24, 32):
                    rk.setdefault(k, []).append(overlap(order[:, :k], true, k=TOPK).mean())
                    rkf.setdefault(k, []).append(
                        overlap(np.repeat(forder[None, :k], T, axis=0), true, k=TOPK).mean())
            res["shuffle_d1"] = float(np.mean(sh))
            res["recall_at_k_d1"] = dict((str(k), float(np.mean(v))) for k, v in rk.items())
            res["recall_at_k_freq_d1"] = dict((str(k), float(np.mean(v))) for k, v in rkf.items())
            if verbose:
                print("  kontrol peremeshivaniem (d=1): %.2f%%" % (res["shuffle_d1"] * 100))
                print("  R@k pri d=1:  " + "   ".join(
                    "k=%d %.1f%% (chast. %.1f%%)" % (k, res["recall_at_k_d1"][str(k)] * 100,
                                                     res["recall_at_k_freq_d1"][str(k)] * 100)
                    for k in (8, 12, 16, 24, 32)))
        res["per_layer"][str(d)] = per
        res["mean"][str(d)] = {
            "overlap": float(np.mean(ov)), "cos": float(np.mean(cs)),
            "freq": float(np.mean(fq)), "prev_tok": float(np.mean(pv)),
            "n_pairs": len(ov)}
        if verbose:
            m = res["mean"][str(d)]
            tag = "  (proverka: dolzhno byt 100.00)" if d == 0 else ""
            print("  d=%d: perekrytie %6.2f%%   cos %.4f   chastota %6.2f%%   pred.tokjen %6.2f%%%s"
                  % (d, m["overlap"] * 100, m["cos"], m["freq"] * 100, m["prev_tok"] * 100, tag))
    del z, X, I
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--domains", default="code,en,ru")
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    print("chitaju marshrutizatory iz %s" % GGUF)
    W = read_routers(GGUF)
    print("  %d sloev, f32 [%d, %d]" % (len(W), N_EXPERT, D_MODEL))

    all_res = [run_domain(d, W) for d in a.domains.split(",")]

    agg = {}
    for d in ("0", "1", "2", "3"):
        agg[d] = dict((k, float(np.mean([r["mean"][d][k] for r in all_res])))
                      for k in ("overlap", "cos", "freq", "prev_tok"))
    out = {"model": os.path.basename(GGUF), "topk": TOPK, "n_expert": N_EXPERT,
           "random_floor": TOPK / float(N_EXPERT), "domains": all_res, "overall": agg}
    with io.open(os.path.join(a.out, "hobbit_crosslayer.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)

    lines = []
    P = lines.append
    P("HOBBIT cross-layer router reuse, %s, top-%d iz %d" % (os.path.basename(GGUF), TOPK, N_EXPERT))
    P("sluchajnyj pol = %.2f%%   otlozhennye tokeny (progon 2 kazhdogo domena)" % (100.0 * TOPK / N_EXPERT))
    P("")
    P("obshchee (srednee po trjom domenam):")
    P("  d   perekrytie   cos(X_L, X_L+d)   chastota C=8   pred.tokjen   HOBBIT zajavljaet")
    claim = {"0": "-", "1": "96%", "2": "~90%", "3": "~90%"}
    for d in ("0", "1", "2", "3"):
        g = agg[d]
        P("  %s   %9.2f%%   %15.4f   %11.2f%%   %9.2f%%   %6s"
          % (d, g["overlap"] * 100, g["cos"], g["freq"] * 100, g["prev_tok"] * 100, claim[d]))
    P("")
    for r in all_res:
        P("%s (%d tokenov, %s):" % (r["domain"], r["tokens"], r["eval_file"]))
        for d in ("0", "1", "2", "3"):
            m = r["mean"][d]
            P("  d=%s  perekrytie %6.2f%%  cos %.4f  chastota %6.2f%%  pred.tokjen %6.2f%%  par %d"
              % (d, m["overlap"] * 100, m["cos"], m["freq"] * 100, m["prev_tok"] * 100, m["n_pairs"]))
        P("")
    P("kontrol peremeshivaniem pri d=1 (tot zhe marshrutizator L+1, vhod ot DRUGOGO tokena):")
    for r in all_res:
        P("  %-5s %6.2f%%   (chestnyj %6.2f%%, chastota %6.2f%%)"
          % (r["domain"], r["shuffle_d1"] * 100, r["mean"]["1"]["overlap"] * 100,
             r["mean"]["1"]["freq"] * 100))
    P("  srednee %.2f%%" % (100 * np.mean([r["shuffle_d1"] for r in all_res])))
    P("")
    P("R@k pri d=1, srednee po domenam (dolja istinnoj vosmjorki vnutri k podkachannyh):")
    P("     k    proekcija   chastota")
    for k in ("8", "12", "16", "24", "32"):
        P("  %4s   %8.2f%%   %7.2f%%"
          % (k, 100 * np.mean([r["recall_at_k_d1"][k] for r in all_res]),
             100 * np.mean([r["recall_at_k_freq_d1"][k] for r in all_res])))
    P("")
    P("poslojno, d=1, srednee po domenam:")
    P("   L   perekrytie   cos    chastota")
    n = min(len(r["per_layer"]["1"]) for r in all_res)
    for i in range(n):
        L = all_res[0]["per_layer"]["1"][i]["L"]
        o = np.mean([r["per_layer"]["1"][i]["overlap"] for r in all_res])
        c = np.mean([r["per_layer"]["1"][i]["cos"] for r in all_res])
        fq = np.mean([r["per_layer"]["1"][i]["freq"] for r in all_res])
        P("  %2d   %8.2f%%   %.4f   %7.2f%%" % (L, o * 100, c, fq * 100))
    txt = "\n".join(lines)
    with io.open(os.path.join(a.out, "hobbit_crosslayer.txt"), "w", encoding="utf-8") as f:
        f.write(txt + "\n")
    print("\n" + txt)


if __name__ == "__main__":
    main()
