"""MemeX spectral transplant, stage B.

Collects post-RoPE K/V activations of a donor model on calibration text,
accumulates per-layer covariance matrices, and computes the principal
subspaces (W_down) used to compress the KV tail beyond the exact window.

Forward-only: no backprop anywhere. Runs on CPU.
"""
import argparse
import json
import os
import time

import torch
from transformers import AutoTokenizer

try:
    from .compat import load_model, load_tokenizer
except ImportError:
    from compat import load_model, load_tokenizer


def get_layer_kv(pkv, layer_idx):
    """Return (K, V) tensors [B, kv_heads, T, head_dim] from a HF cache object,
    tolerating API differences between transformers versions."""
    if hasattr(pkv, "key_cache"):
        return pkv.key_cache[layer_idx], pkv.value_cache[layer_idx]
    if hasattr(pkv, "layers"):
        lay = pkv.layers[layer_idx]
        return lay.keys, lay.values
    return pkv[layer_idx][0], pkv[layer_idx][1]


@torch.no_grad()
def collect_covariances(model, tokenizer, text, max_tokens=200_000,
                        chunk_len=2048, device="cpu"):
    """Accumulate per-layer covariance of flattened (kv_heads*head_dim) K and V
    activations, as stored in the cache (post-RoPE keys).

    Covariances accumulate in float32 on the compute device (ample precision for
    a principal-subspace estimate); the eigendecomposition runs in float64 on CPU.
    """
    model.eval()
    acc_dtype = torch.float64 if device == "cpu" else torch.float32
    n_layers = model.config.num_hidden_layers
    cov_k = [None] * n_layers
    cov_v = [None] * n_layers
    total = 0

    ids = tokenizer(text, return_tensors="pt").input_ids[0]
    ids = ids[: max_tokens]
    n_chunks = (len(ids) + chunk_len - 1) // chunk_len
    t0 = time.time()
    for ci in range(n_chunks):
        chunk = ids[ci * chunk_len : (ci + 1) * chunk_len]
        if len(chunk) < 32:
            continue
        out = model(chunk.unsqueeze(0).to(device), use_cache=True)
        pkv = out.past_key_values
        for li in range(n_layers):
            k, v = get_layer_kv(pkv, li)
            # [1, h, T, d] -> [T, h*d]
            kf = k[0].transpose(0, 1).reshape(k.shape[2], -1).to(acc_dtype)
            vf = v[0].transpose(0, 1).reshape(v.shape[2], -1).to(acc_dtype)
            ck = kf.T @ kf
            cv = vf.T @ vf
            cov_k[li] = ck if cov_k[li] is None else cov_k[li] + ck
            cov_v[li] = cv if cov_v[li] is None else cov_v[li] + cv
        total += len(chunk)
        del out, pkv
        rate = total / max(time.time() - t0, 1e-9)
        print(f"[calib] chunk {ci + 1}/{n_chunks}, tokens={total}, {rate:.0f} tok/s", flush=True)
    return cov_k, cov_v, total


def spectra_from_covariances(cov_k, cov_v, total_tokens):
    """Eigendecompose covariances. Returns per-layer eigvecs (descending) and
    a JSON-able report of energy captured at various ranks."""
    report = {"tokens": total_tokens, "layers": []}
    basis = {"k": [], "v": []}
    ranks = [16, 32, 64, 128, 192, 256, 384, 512]
    for li, (ck, cv) in enumerate(zip(cov_k, cov_v)):
        entry = {"layer": li}
        for name, cov in (("k", ck), ("v", cv)):
            cov = cov.double().cpu()
            evals, evecs = torch.linalg.eigh(cov / total_tokens)
            evals = torch.flip(evals, [0]).clamp(min=0)
            evecs = torch.flip(evecs, [1])
            energy = evals.cumsum(0) / evals.sum().clamp(min=1e-12)
            dim = evals.numel()
            entry[name + "_energy"] = {
                str(r): round(float(energy[min(r, dim) - 1]), 6) for r in ranks if r <= dim
            }
            basis[name].append(evecs.to(torch.float32))
        report["layers"].append(entry)
    return basis, report


def summarize(report):
    """Average energy across layers for each rank; the go/no-go signal."""
    ranks = sorted({r for lay in report["layers"] for r in lay["k_energy"]}, key=int)
    lines = ["rank | K energy (mean over layers) | V energy"]
    for r in ranks:
        ke = sum(l["k_energy"][r] for l in report["layers"]) / len(report["layers"])
        ve = sum(l["v_energy"][r] for l in report["layers"]) / len(report["layers"])
        lines.append(f"{r:>4} | {ke:.4f} | {ve:.4f}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=r"D:\MemeX\models\Qwen3-0.6B")
    ap.add_argument("--text", default=r"D:\MemeX\data\calibration.txt")
    ap.add_argument("--out", default=r"D:\MemeX\results")
    ap.add_argument("--max-tokens", type=int, default=200_000)
    ap.add_argument("--chunk-len", type=int, default=2048)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--threads", type=int, default=4)
    args = ap.parse_args()

    torch.set_num_threads(args.threads)
    print(f"[calib] loading {args.model} on {args.device}", flush=True)
    tokenizer = load_tokenizer(args.model)
    model = load_model(args.model, device=args.device)

    with open(args.text, encoding="utf-8", errors="ignore") as f:
        text = f.read()

    cov_k, cov_v, total = collect_covariances(
        model, tokenizer, text, max_tokens=args.max_tokens,
        chunk_len=args.chunk_len, device=args.device
    )
    basis, report = spectra_from_covariances(cov_k, cov_v, total)

    os.makedirs(args.out, exist_ok=True)
    torch.save(
        {"k": basis["k"], "v": basis["v"], "tokens": total},
        os.path.join(args.out, "kv_basis.pt"),
    )
    with open(os.path.join(args.out, "spectrum_report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print(summarize(report), flush=True)
    print(f"[calib] saved basis to {args.out}", flush=True)


if __name__ == "__main__":
    main()
