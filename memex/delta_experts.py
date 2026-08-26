"""Shared base + low-rank delta factorisation of MoE experts (plan §2.3, idea).

Hypothesis: experts inside one MoE layer start from the same initialisation and
learn related functions, so each expert weight can be written as

    W_i  ~=  B  +  U_i V_i        (B shared by the whole layer, U_i V_i rank-r)

If that holds at a small rank, the paging engine only ever moves the delta: the
base sits in VRAM permanently and one cache slot holds many more experts. This
tool measures whether it holds, on real expert tensors, and what it would buy.

Error metric is relative Frobenius norm per expert, plus the baseline error of
the shared base alone (rank 0) so the gain from the delta is visible. A useful
control is "rank-r SVD of W_i itself" (no shared base): if the shared base does
not beat that at equal budget, the idea adds nothing.
"""
import argparse
import glob
import json
import os
import re

import numpy as np


def load_expert_tensors(paths, pattern, max_experts=None):
    """Collect tensors whose names match `pattern` from safetensors files.
    Returns {group_key: [(name, matrix)]} grouped by everything except the
    expert index, so each group is one (layer, projection) family."""
    from safetensors import safe_open

    groups = {}
    rx = re.compile(pattern)
    for path in paths:
        with safe_open(path, framework="np") as f:
            for name in f.keys():
                m = rx.search(name)
                if not m:
                    continue
                key = rx.sub("<E>", name)
                arr = f.get_tensor(name)
                if arr.ndim != 2:
                    continue
                groups.setdefault(key, []).append((name, arr.astype(np.float32)))
    if max_experts:
        for k in groups:
            groups[k] = groups[k][:max_experts]
    return groups


def fetch_hf_tensors(repo, filename, pattern, max_experts=32, max_groups=3,
                     revision="main"):
    """Fetch only the expert tensors we need, via HTTP range requests.

    A safetensors file starts with an 8-byte little-endian header length, then a
    JSON header giving every tensor's dtype, shape and byte range. So a few tens
    of megabytes of real expert weights can be pulled out of a multi-gigabyte
    shard without downloading the shard — which matters on a slow link.
    """
    import urllib.request

    url = f"https://huggingface.co/{repo}/resolve/{revision}/{filename}"

    def get_range(start, end):
        req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()

    n = int.from_bytes(get_range(0, 7), "little")
    header = json.loads(get_range(8, 8 + n - 1).decode("utf-8"))
    print(f"header: {len(header)} tensors, {n/1e3:.0f} KB")

    rx = re.compile(pattern)
    dtype_map = {"F32": np.float32, "F16": np.float16, "BF16": np.uint16}

    def read_tensor(meta):
        dt = meta["dtype"]
        if dt not in dtype_map:
            return None
        lo, hi = meta["data_offsets"]
        raw = get_range(8 + n + lo, 8 + n + hi - 1)
        arr = np.frombuffer(raw, dtype=dtype_map[dt]).reshape(meta["shape"])
        if dt == "BF16":
            arr = (arr.astype(np.uint32) << 16).view(np.float32)  # top half of f32
        return arr.astype(np.float32), len(raw)

    # Two layouts in the wild: one tensor per expert (Mixtral, Qwen, DeepSeek),
    # or all experts of a layer fused into a 3-D [E, rows, cols] tensor (Granite).
    fused, per_expert = [], {}
    for name, meta in header.items():
        if name == "__metadata__" or not rx.search(name):
            continue
        shape = meta.get("shape", [])
        if len(shape) == 3:
            fused.append((name, meta))
        elif len(shape) == 2:
            per_expert.setdefault(rx.sub("<E>", name), []).append((name, meta))

    out, fetched = {}, 0
    for name, meta in sorted(fused)[:max_groups]:
        got = read_tensor(meta)
        if not got:
            continue
        arr, nbytes = got
        fetched += nbytes
        mats = [(f"{name}[{i}]", arr[i]) for i in range(min(arr.shape[0], max_experts))]
        out[name] = mats
        print(f"  {name}: {len(mats)} experts {mats[0][1].shape} (fused)")

    for key in sorted(per_expert)[: max(0, max_groups - len(out))]:
        items = sorted(per_expert[key],
                       key=lambda kv: kv[1]["data_offsets"][0])[:max_experts]
        mats = []
        for name, meta in items:
            got = read_tensor(meta)
            if not got:
                continue
            arr, nbytes = got
            fetched += nbytes
            mats.append((name, arr))
        if mats:
            out[key] = mats
            print(f"  {key}: {len(mats)} experts {mats[0][1].shape}")
    print(f"fetched {fetched/1e6:.1f} MB of real weights")
    return out


def synthetic_group(n_experts=32, rows=512, cols=256, true_rank=16, seed=0):
    """Correlated experts: a common base plus genuine low-rank differences, so
    the tool can be validated where the answer is known."""
    rng = np.random.default_rng(seed)
    base = rng.normal(0, 1.0, size=(rows, cols)).astype(np.float32)
    out = []
    for i in range(n_experts):
        u = rng.normal(0, 0.3, size=(rows, true_rank)).astype(np.float32)
        v = rng.normal(0, 0.3, size=(true_rank, cols)).astype(np.float32)
        out.append((f"synthetic.expert.{i}", base + u @ v))
    return {"synthetic.expert.<E>": out}


def factorize_all(mats, ranks):
    """One SVD per expert answers every rank at once.

    For a truncated SVD, ||X - X_r||_F^2 = sum of the dropped squared singular
    values, so a single decomposition of the residual (and of the raw matrix, for
    the control) gives the error curve over all ranks — 2 SVDs per expert instead
    of 2 per expert per rank.
    """
    stack = np.stack(mats)
    base = stack.mean(axis=0)
    tail_res, tail_raw, norms = [], [], []
    for w in mats:
        nrm = float(np.linalg.norm(w)) + 1e-12
        norms.append(nrm)
        r = w - base
        s_res = np.linalg.svd(r, compute_uv=False)
        s_raw = np.linalg.svd(w, compute_uv=False)
        # reverse-cumulative energy: tail[k] = sum_{i>=k} s_i^2
        tail_res.append(np.concatenate([np.cumsum((s_res ** 2)[::-1])[::-1], [0.0]]))
        tail_raw.append(np.concatenate([np.cumsum((s_raw ** 2)[::-1])[::-1], [0.0]]))
    out = {}
    for rank in ranks:
        ed, eb, ep = [], [], []
        for i in range(len(mats)):
            k = min(rank, len(tail_res[i]) - 1)
            ed.append(float(np.sqrt(tail_res[i][k])) / norms[i])
            eb.append(float(np.sqrt(tail_res[i][0])) / norms[i])
            ep.append(float(np.sqrt(tail_raw[i][k])) / norms[i])
        out[rank] = (float(np.mean(ed)), float(np.mean(eb)), float(np.mean(ep)))
    return out


def cross_expert_pca(mats, ks, bytes_per_param, coeff_bytes=4):
    """Do the experts of one layer live in a shared low-dimensional subspace?

    Treats each expert as a point in R^(rows*cols) and asks how well K principal
    directions span them. If they do, an expert is described by K coefficients —
    so paging transfers K numbers instead of a weight matrix, and the K shared
    basis matrices are loaded once and amortised over all experts. This is a
    different question from per-matrix low rank (which real experts fail).

    Computed through the E x E Gram matrix, so cost is set by the number of
    experts, not by matrix size.
    """
    E = len(mats)
    X = np.stack([m.reshape(-1) for m in mats]).astype(np.float32)
    total_sq = float((X ** 2).sum())
    mean = X.mean(axis=0)
    Xc = X - mean
    gram = Xc @ Xc.T
    evals = np.linalg.eigvalsh(gram)[::-1].clip(min=0.0)
    centred_sq = float(evals.sum())
    rows, cols = mats[0].shape
    out = {}
    for k in ks:
        kk = min(k, E)
        residual = max(0.0, centred_sq - float(evals[:kk].sum()))
        err = float(np.sqrt(residual / max(total_sq, 1e-12)))
        # per-expert cost: K coefficients + amortised share of basis and mean
        basis_amortised = (kk + 1) * rows * cols * bytes_per_param / E
        per_expert = kk * coeff_bytes + basis_amortised
        out[k] = (err, per_expert)
    return out, centred_sq, total_sq


def _kmeans(train, k, iters, rng):
    cb = train[rng.choice(len(train), size=min(k, len(train)), replace=False)].copy()
    step = 20000
    for _ in range(iters):
        assign = np.empty(len(train), dtype=np.int32)
        for s in range(0, len(train), step):
            blk = train[s:s + step]
            dist = (blk ** 2).sum(1)[:, None] - 2 * blk @ cb.T + (cb ** 2).sum(1)
            assign[s:s + step] = dist.argmin(1)
        for j in range(len(cb)):
            sel = train[assign == j]
            if len(sel):
                cb[j] = sel.mean(0)
    return cb


def _quantize(vecs, cb):
    """Return the codebook approximation of every vector, chunked."""
    out = np.empty_like(vecs)
    step = 20000
    for s in range(0, len(vecs), step):
        blk = vecs[s:s + step]
        dist = (blk ** 2).sum(1)[:, None] - 2 * blk @ cb.T + (cb ** 2).sum(1)
        out[s:s + step] = cb[dist.argmin(1)]
    return out


def vq_error(mats, dim=8, k=256, stages=1, per_row_scale=True, iters=12,
             sample=200_000, seed=0):
    """Additive vector quantisation with a codebook shared across all experts.

    Two ingredients carried over from the published 2-bit methods:
      * per-row scale normalisation — otherwise the codebook spends its capacity
        on magnitude differences instead of shape;
      * additive stages — each stage quantises what the previous one missed, so
        the bit budget grows linearly while error falls geometrically. This is
        what makes AQLM-class methods usable at 2 bits where plain k-means is not.

    Bits per weight = stages * log2(k) / dim (scales are ~0.01 bit/weight).
    """
    rng = np.random.default_rng(seed)
    blocks = []
    for m in mats:
        v = m.reshape(-1, dim).astype(np.float32)
        blocks.append(v)
    vecs = np.concatenate(blocks, axis=0)
    scales = None
    if per_row_scale:
        scales = np.sqrt((vecs ** 2).mean(axis=1, keepdims=True)) + 1e-8
        vecs = vecs / scales

    idx = rng.choice(len(vecs), size=min(sample, len(vecs)), replace=False)
    eval_idx = rng.choice(len(vecs), size=min(sample, len(vecs)), replace=False)
    train, ev = vecs[idx], vecs[eval_idx]

    approx = np.zeros_like(ev)
    residual_train = train.copy()
    for _ in range(max(1, stages)):
        cb = _kmeans(residual_train, k, iters, rng)
        residual_train = residual_train - _quantize(residual_train, cb)
        approx = approx + _quantize(ev - approx, cb)

    if per_row_scale:
        s = scales[eval_idx]
        num = float((((ev - approx) * s) ** 2).sum())
        den = float(((ev * s) ** 2).sum())
    else:
        num = float(((ev - approx) ** 2).sum())
        den = float((ev ** 2).sum())
    rel = float(np.sqrt(num / max(den, 1e-12)))
    bits = max(1, stages) * np.log2(k) / dim
    return rel, bits


def shared_codebook_error(mats, dim=8, k=256, iters=12, sample=200_000, seed=0):
    """The hypothesis that survives the geometry argument: experts may be mutually
    orthogonal as matrices while still being built from a shared vocabulary of
    small weight patterns.

    Slices every expert into `dim`-wide vectors, learns ONE codebook of k entries
    across all experts (k-means on a subsample), then quantises everything to
    codebook indices. Cost per weight = log2(k)/dim bits plus an amortised
    codebook. This is the mechanism behind AQLM/QuIP#-style 2-bit methods, and
    unlike a shared base it does not require the experts to be similar.
    """
    rng = np.random.default_rng(seed)
    vecs = np.concatenate([m.reshape(-1, dim) for m in mats], axis=0)
    idx = rng.choice(len(vecs), size=min(sample, len(vecs)), replace=False)
    train = vecs[idx]
    # k-means++ style seeding is overkill here; random distinct rows converge fine
    cb = train[rng.choice(len(train), size=k, replace=False)].copy()
    for _ in range(iters):
        d = ((train[:, None, :] - cb[None, :, :]) ** 2).sum(-1) if False else None
        # chunked assignment to keep memory bounded
        assign = np.empty(len(train), dtype=np.int32)
        step = 20000
        for s in range(0, len(train), step):
            blk = train[s:s + step]
            dist = (blk ** 2).sum(1)[:, None] - 2 * blk @ cb.T + (cb ** 2).sum(1)
            assign[s:s + step] = dist.argmin(1)
        for j in range(k):
            sel = train[assign == j]
            if len(sel):
                cb[j] = sel.mean(0)
    # evaluate on a fresh sample of all vectors
    eval_idx = rng.choice(len(vecs), size=min(sample, len(vecs)), replace=False)
    ev = vecs[eval_idx]
    err_sq = 0.0
    step = 20000
    for s in range(0, len(ev), step):
        blk = ev[s:s + step]
        dist = (blk ** 2).sum(1)[:, None] - 2 * blk @ cb.T + (cb ** 2).sum(1)
        q = cb[dist.argmin(1)]
        err_sq += float(((blk - q) ** 2).sum())
    rel = float(np.sqrt(err_sq / max((ev ** 2).sum(), 1e-12)))
    bits_per_weight = np.log2(k) / dim
    return rel, bits_per_weight


def base_rescale_error(mats):
    """Simplest 'algorithm that turns the average into the target': keep one
    shared base and send only a per-row scale (rows numbers per expert).
    Closed form: the optimal scale for row r is <w_r, b_r> / ||b_r||^2."""
    base = np.stack(mats).mean(axis=0)
    denom = (base ** 2).sum(axis=1) + 1e-12
    errs = []
    for w in mats:
        scale = (w * base).sum(axis=1) / denom
        approx = base * scale[:, None]
        errs.append(float(np.linalg.norm(w - approx) / (np.linalg.norm(w) + 1e-12)))
    return float(np.mean(errs))


def paged_bytes(rows, cols, rank, bytes_per_param):
    full = rows * cols * bytes_per_param
    delta = (rows + cols) * rank * bytes_per_param
    return full, delta


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--safetensors", nargs="*", default=None,
                    help="files or globs holding expert weights")
    ap.add_argument("--pattern", default=r"experts\.(\d+)\.",
                    help="regex matching the expert index in tensor names")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--hf-repo", default=None,
                    help="fetch expert tensors from this HF repo by range request")
    ap.add_argument("--hf-file", default="model.safetensors")
    ap.add_argument("--ranks", type=int, nargs="+", default=[0, 4, 8, 16, 32, 64])
    ap.add_argument("--max-experts", type=int, default=32)
    ap.add_argument("--max-groups", type=int, default=3)
    ap.add_argument("--bytes-per-param", type=float, default=0.56)
    ap.add_argument("--json-out", default=None)
    ap.add_argument("--codebook", nargs="*", default=None,
                    help="VQ tests as dim:entries[:stages], e.g. 8:256:2 4:256")
    ap.add_argument("--vq-ablate", action="store_true",
                    help="also run each VQ config without per-row scales")
    args = ap.parse_args()
    if args.codebook is not None:
        args.codebook = [tuple(int(x) for x in spec.split(":"))
                         for spec in (args.codebook or ["8:256", "4:256", "2:256"])]

    if args.hf_repo:
        groups = fetch_hf_tensors(args.hf_repo, args.hf_file, args.pattern,
                                  max_experts=args.max_experts,
                                  max_groups=args.max_groups)
        if not groups:
            raise SystemExit("no matching expert tensors in that file")
    elif args.synthetic or not args.safetensors:
        groups = synthetic_group(n_experts=args.max_experts)
        print("using synthetic experts (known answer: true rank 16)")
    else:
        paths = []
        for p in args.safetensors:
            paths.extend(glob.glob(p))
        if not paths:
            raise SystemExit("no safetensors files matched")
        groups = load_expert_tensors(paths, args.pattern, args.max_experts)
        if not groups:
            raise SystemExit("pattern matched no 2-D tensors")

    report = []
    for gi, (key, items) in enumerate(sorted(groups.items())):
        if gi >= args.max_groups:
            break
        mats = [m for _, m in items]
        rows, cols = mats[0].shape
        print(f"\n== {key}  ({len(mats)} experts, {rows}x{cols}) ==")
        print(f"{'rank':>5} {'base+delta err':>15} {'base only':>10} "
              f"{'plain SVD':>10} {'paged bytes':>12} {'vs full':>8}")
        full_b, _ = paged_bytes(rows, cols, 0, args.bytes_per_param)
        curves = factorize_all(mats, args.ranks)
        for r in args.ranks:
            ed, eb, ep = curves[r]
            _, delta_b = paged_bytes(rows, cols, r, args.bytes_per_param)
            shown = full_b if r == 0 else delta_b
            print(f"{r:>5} {ed:>15.4f} {eb:>10.4f} {ep:>10.4f} "
                  f"{shown/1e6:>11.2f}M {shown/full_b:>7.2f}x")
            report.append({"group": key, "rank": r, "err_base_delta": ed,
                           "err_base_only": eb, "err_plain_svd": ep,
                           "paged_bytes": shown, "full_bytes": full_b})

        # The other hypothesis: experts as coefficients over a shared basis.
        pca, centred_sq, total_sq = cross_expert_pca(
            mats, args.ranks, args.bytes_per_param)
        print(f"\n  cross-expert subspace ({len(mats)} experts; centred energy "
              f"{centred_sq/total_sq:.3f} of total):")
        print(f"  {'K':>4} {'error':>8} {'bytes/expert':>13} {'vs full':>8}")
        for k in args.ranks:
            err, per = pca[k]
            print(f"  {k:>4} {err:>8.4f} {per/1e6:>12.3f}M {per/full_b:>7.3f}x")
            report.append({"group": key, "pca_k": k, "err_pca": err,
                           "bytes_per_expert": per, "full_bytes": full_b})
        rescale = base_rescale_error(mats)
        print(f"  base + per-row rescale ({rows} numbers/expert): error {rescale:.4f}")
        report.append({"group": key, "err_base_rescale": rescale})

        if args.codebook:
            print("\n  shared codebook across all experts (additive VQ):")
            print(f"  {'dim':>4} {'entries':>8} {'stages':>7} {'scales':>7} "
                  f"{'error':>8} {'bits/w':>7} {'vs 16-bit':>10}")
            for spec in args.codebook:
                dim, k, stages = (spec + (1,))[:3] if len(spec) < 3 else spec
                for scaled in ((False, True) if args.vq_ablate else (True,)):
                    err, bpw = vq_error(mats, dim=dim, k=k, stages=stages,
                                        per_row_scale=scaled)
                    print(f"  {dim:>4} {k:>8} {stages:>7} "
                          f"{'yes' if scaled else 'no':>7} {err:>8.4f} "
                          f"{bpw:>7.2f} {bpw/16:>9.3f}x")
                    report.append({"group": key, "cb_dim": dim, "cb_entries": k,
                                   "stages": stages, "per_row_scale": scaled,
                                   "err_codebook": err, "bits_per_weight": bpw})
    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(report, f, indent=1)


if __name__ == "__main__":
    main()
