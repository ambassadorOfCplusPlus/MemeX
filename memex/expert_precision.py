"""Assign a precision to each expert individually, by how much it is actually used.

This is the one optimisation llama.cpp cannot express. Its GGUF keeps all experts of
a layer in one fused tensor, so a quantisation type applies to the whole layer - all
128 experts at once. But the routing trace shows use is wildly uneven: the hottest
10% of expert slots serve 56% of all routing decisions, and which experts are hot
depends on the task (code and prose overlap by 2.2%). A per-layer choice therefore
either wastes precision on experts that are never touched, or damages the few that
carry the work.

Inside the fused tensor each expert's data is contiguous - the expert index is the
slowest-varying dimension - so a single expert can be sliced out, dequantised and
re-quantised on its own. That is what this does, which is also what gives the MemeX
blob format its per-expert precision.

What the numbers here are, and are not: footprint is exact, and the error reported
per expert is the true relative reconstruction error of that expert's weights. That
is not the same as end-to-end quality, which needs a run of the modified runtime -
so this measures the cost of compression, not yet its consequence.
"""
import argparse
import io
import json
import os
import struct
from collections import Counter

import numpy as np
from gguf import GGUFReader
import gguf.quants as gq


def read_trace_popularity(path, n_experts):
    """(layer, expert) -> how many times the router chose it."""
    pop = Counter()
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                break
            layer, n_used, n_tok = struct.unpack("<iii", hdr)
            n = n_used * n_tok
            raw = f.read(4 * n)
            if len(raw) < 4 * n:
                break
            if layer < 0:
                continue
            for e in struct.unpack(f"<{n}i", raw):
                pop[(layer, e)] += 1
    return pop


def expert_slices(tensor, n_experts):
    """One packed block per expert, ready to hand to the dequantiser.

    The reader already presents a fused expert tensor as (n_expert, n_rows,
    row_bytes) - the expert index is the slowest dimension - so slicing an expert
    out is free, and each slice keeps the row layout the dequantiser expects.
    """
    arr = np.asarray(tensor.data)
    if arr.ndim != 3 or arr.shape[0] != n_experts:
        return None
    return arr


def pack_kbit(w, bits, group=32):
    """Quantise to `bits` with one scale per group of weights along each row.

    The gguf package can only pack a few legacy types (Q4_0, Q4_1, Q5_0, Q8_0), and
    the engine does not need GGUF compatibility for its own blob - it needs to know
    what a given bit width costs. This is the same scheme those types use: absmax
    per group, symmetric levels, one fp16 scale per group. Cost per weight is
    bits + 16/group bits, so at 4 bits and groups of 32 it is 4.5 bits.
    """
    flat = w.reshape(-1, group).astype(np.float32)
    scale = np.abs(flat).max(axis=1, keepdims=True)
    levels = (1 << (bits - 1)) - 1          # symmetric, e.g. 7 for 4 bits
    scale = np.where(scale == 0, 1.0, scale)
    q = np.rint(flat / scale * levels).clip(-levels, levels)
    back = (q / levels) * scale
    bytes_total = int(np.ceil(w.size * bits / 8) + flat.shape[0] * 2)
    denom = float(np.linalg.norm(flat))
    err = float(np.linalg.norm(back - flat) / denom) if denom > 0 else 0.0
    return bytes_total, err


def requantize(raw, qtype, bits, group=32):
    """Dequantise one expert, then measure what `bits` would cost it."""
    deq = gq.dequantize(raw, qtype).astype(np.float32)
    return pack_kbit(deq, bits, group)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=r"C:\models\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf")
    ap.add_argument("--trace", default=r"D:\MemeX\results\tr_code.bin")
    ap.add_argument("--experts", type=int, default=128)
    ap.add_argument("--cold-share", type=float, default=0.7,
                    help="какую долю экспертов слоя считать холодной")
    ap.add_argument("--cold-bits", type=int, default=4,
                    help="битность холодных экспертов")
    ap.add_argument("--group", type=int, default=32,
                    help="сколько весов на один масштаб")
    ap.add_argument("--layers", type=int, nargs="+", default=[4, 20, 40],
                    help="на каких слоях мерить ошибку (полный проход слишком долгий)")
    ap.add_argument("--sample-experts", type=int, default=6)
    ap.add_argument("--out", default=r"D:\MemeX\results\expert_precision.json")
    args = ap.parse_args()

    pop = read_trace_popularity(args.trace, args.experts)
    if not pop:
        raise SystemExit("трасса пуста — сначала сними её llama-moe-trace")
    print(f"трасса: {len(pop)} использованных слотов, "
          f"{sum(pop.values())} обращений")

    reader = GGUFReader(args.model, "r")
    by_name = {t.name: t for t in reader.tensors}

    rows = []
    tot_before = tot_after = 0
    for layer in args.layers:
        # up/gate/down are stored as three fused tensors per layer
        names = [f"blk.{layer}.ffn_{k}_exps.weight" for k in ("up", "gate", "down")]
        for name in names:
            t = by_name.get(name)
            if t is None:
                print(f"нет тензора {name}")
                continue
            view = expert_slices(t, args.experts)
            if view is None:
                print(f"{name}: не делится на {args.experts} экспертов")
                continue
            shape = None   # the reader's layout already carries it
            n_hot = int(args.experts * (1.0 - args.cold_share))
            order = sorted(range(args.experts),
                           key=lambda e: -pop.get((layer, e), 0))
            hot = set(order[:n_hot])
            cold = [e for e in order[n_hot:]]

            per_expert_before = int(view[0].nbytes)
            tot_before += per_expert_before * args.experts

            # measure the error of a sample of cold experts and of hot ones, so the
            # comparison is not between different experts
            sample_cold = cold[: args.sample_experts]
            sample_hot = order[: args.sample_experts]
            errs_cold, errs_hot, after_cold = [], [], None
            for e in sample_cold:
                nb, err = requantize(view[e], t.tensor_type, args.cold_bits,
                                     args.group)
                errs_cold.append(err)
                after_cold = nb
            for e in sample_hot:
                nb, err = requantize(view[e], t.tensor_type, args.cold_bits,
                                     args.group)
                errs_hot.append(err)
            if after_cold is None:
                continue
            tot_after += per_expert_before * n_hot + after_cold * len(cold)
            rows.append({
                "tensor": name, "layer": layer,
                "bytes_per_expert_before": per_expert_before,
                "bytes_per_expert_after_cold": after_cold,
                "err_cold_mean": float(np.mean(errs_cold)),
                "err_hot_mean": float(np.mean(errs_hot)),
                "uses_hot_total": sum(pop.get((layer, e), 0) for e in hot),
                "uses_cold_total": sum(pop.get((layer, e), 0) for e in cold),
            })
            print(f"{name}: эксперт {per_expert_before/1e6:.2f} МБ -> "
                  f"{after_cold/1e6:.2f} МБ у холодных; ошибка "
                  f"холодных {np.mean(errs_cold)*100:.2f}%, "
                  f"горячих {np.mean(errs_hot)*100:.2f}%", flush=True)

    if not rows:
        raise SystemExit("ни один тензор не обработан")
    share_cold_uses = (sum(r["uses_cold_total"] for r in rows) /
                       max(1, sum(r["uses_cold_total"] + r["uses_hot_total"]
                                  for r in rows)))
    res = {"cold_share": args.cold_share, "cold_bits": args.cold_bits,
           "rows": rows,
           "footprint_ratio": tot_after / tot_before if tot_before else 0.0,
           "cold_share_of_uses": share_cold_uses}
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with io.open(args.out, "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, ensure_ascii=False)

    print(f"\nхолодными объявлено {100*args.cold_share:.0f}% экспертов, "
          f"на них приходится {100*share_cold_uses:.1f}% обращений")
    print(f"объём экспертов: {100*tot_after/tot_before:.1f}% от исходного "
          f"(экономия {100*(1-tot_after/tot_before):.1f}%)")
    print("трафик на токен меняется примерно на "
          f"{100*share_cold_uses*(1 - rows[0]['bytes_per_expert_after_cold']/rows[0]['bytes_per_expert_before']):.1f}% "
          "— именно потому, что холодные читаются редко")
    print(f"записано: {args.out}")


if __name__ == "__main__":
    main()
