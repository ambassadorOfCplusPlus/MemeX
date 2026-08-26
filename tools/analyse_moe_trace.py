"""Turn a routing trace into the numbers that decide two engine changes.

The trace holds, for every layer and every token, which experts the router chose.
Three questions get answered from it, and each one is a go/no-go for work that
would otherwise be done on faith:

  * how concentrated expert use is - the ceiling on any caching scheme, including
    pinning hot experts in fast memory;
  * how the union of chosen experts grows across k consecutive tokens - this is the
    reason speculative decoding behaves differently on a mixture-of-experts model
    than on a dense one. A dense model reads its weights once per verify pass, so k
    accepted tokens cost one read. A MoE model reads whatever the k tokens jointly
    demand, so if the union grows linearly there is no weight-traffic saving at all
    and the measured speed-up comes only from attention and dense layers;
  * what forcing one shared expert set per batch would save - the difference
    between the union and the per-token count is exactly the prize.

Byte counts default to Qwen3-30B-A3B at Q6_K, the model actually being measured.
"""
import argparse
import io
import json
import os
import struct
from collections import Counter


def read_trace(path):
    """Yield (layer, ids) where ids is a list of per-token expert lists."""
    out = []
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                break
            layer, n_used, n_tokens = struct.unpack("<iii", hdr)
            n = n_used * n_tokens
            raw = f.read(4 * n)
            if len(raw) < 4 * n:
                break
            vals = struct.unpack(f"<{n}i", raw)
            # ggml keeps ne[0] as the fastest axis, so each token's ids are
            # contiguous and the block reshapes to [n_tokens, n_used]
            per_token = [list(vals[i * n_used : (i + 1) * n_used])
                         for i in range(n_tokens)]
            out.append((layer, per_token))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", default=r"D:\MemeX\results\moe_trace.bin")
    ap.add_argument("--windows", type=int, nargs="+", default=[2, 3, 4, 5, 8, 16])
    ap.add_argument("--layers", type=int, default=48)
    ap.add_argument("--experts", type=int, default=128)
    ap.add_argument("--hidden", type=int, default=2048)
    ap.add_argument("--ff-exp", type=int, default=768)
    ap.add_argument("--bytes-per-param", type=float, default=0.82,
                    help="Q6_K ~ 6.56 бита на параметр")
    ap.add_argument("--vram-gb", type=float, default=2.3)
    ap.add_argument("--ram-gbs", type=float, default=17.0,
                    help="измеренная эффективная полоса RAM")
    ap.add_argument("--out", default=r"D:\MemeX\results\moe_trace_stats.json")
    args = ap.parse_args()

    if not os.path.exists(args.trace):
        raise SystemExit(f"нет трассы: {args.trace}")
    blocks = read_trace(args.trace)
    if not blocks:
        raise SystemExit("трасса пуста")

    by_layer = {}
    for layer, per_token in blocks:
        if layer < 0:
            continue          # a node whose name carried no layer suffix
        by_layer.setdefault(layer, []).extend(per_token)
    # The final layer computes its FFN for the last token only - llama.cpp prunes
    # the rest because only that row feeds the logits - so it carries a single row
    # and would otherwise drag the common token count down to one.
    full = max(len(v) for v in by_layer.values())
    dropped = [k for k, v in by_layer.items() if len(v) < full // 2]
    for k in dropped:
        del by_layer[k]
    layers = sorted(by_layer)
    n_tokens = min(len(v) for v in by_layer.values())
    top_k = len(by_layer[layers[0]][0])
    print(f"слоёв в трассе: {len(layers)}, токенов: {n_tokens}, top-{top_k}"
          + (f" (пропущены слои с укороченным выходом: {dropped})" if dropped else ""))

    # 1) concentration
    pop = Counter()
    for lay in layers:
        for row in by_layer[lay][:n_tokens]:
            for e in row:
                pop[(lay, e)] += 1
    total = sum(pop.values())
    ranked = sorted(pop.values(), reverse=True)
    coverage = {}
    for frac in (0.02, 0.05, 0.10, 0.20, 0.30, 0.50):
        n = max(1, int(len(ranked) * frac))
        coverage[f"top_{int(frac * 100)}pct"] = round(sum(ranked[:n]) / total, 4)
    # what a uniform router would give, as the reference point
    uniform = {k: round(float(k.split("_")[1].rstrip("pct")) / 100, 4)
               for k in coverage}

    # 2) union growth across consecutive tokens
    union = {}
    for k in args.windows:
        sizes = []
        for lay in layers:
            rows = by_layer[lay][:n_tokens]
            for i in range(0, len(rows) - k + 1, k):
                s = set()
                for r in rows[i : i + k]:
                    s.update(r)
                sizes.append(len(s))
        if not sizes:
            continue
        u = sum(sizes) / len(sizes)
        union[str(k)] = {"union": round(u, 2),
                         "per_token": round(u / k, 2),
                         "saving_vs_single": round(top_k / (u / k), 3),
                         "if_shared_set": round(u / top_k, 3)}

    # 3) adjacent-token overlap
    jac = []
    for lay in layers:
        rows = [set(r) for r in by_layer[lay][:n_tokens]]
        if len(rows) > 1:
            jac.append(sum(len(a & b) / len(a | b)
                           for a, b in zip(rows[:-1], rows[1:])) / (len(rows) - 1))
    overlap = round(sum(jac) / len(jac), 4) if jac else 0.0

    # 4) traffic model
    exp_params = 3 * args.hidden * args.ff_exp
    exp_bytes = exp_params * args.bytes_per_param
    per_token_gb = args.layers * top_k * exp_bytes / 1e9
    ceiling = args.ram_gbs / per_token_gb
    slots = args.layers * args.experts
    fit = int(args.vram_gb * 1e9 / exp_bytes)
    order = [k for k, _ in sorted(pop.items(), key=lambda kv: -kv[1])]
    served = sum(pop[k] for k in order[:fit]) / total

    res = {"tokens": n_tokens, "layers": len(layers), "top_k": top_k,
           "coverage": coverage, "coverage_if_uniform": uniform,
           "union_growth": union, "adjacent_overlap": overlap,
           "expert_mb": round(exp_bytes / 1e6, 2),
           "read_per_token_gb": round(per_token_gb, 3),
           "bandwidth_ceiling_tok_s": round(ceiling, 2),
           "expert_slots": slots, "slots_in_vram": fit,
           "vram_hit_share": round(served, 4)}
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with io.open(args.out, "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, ensure_ascii=False)

    print("\n=== насколько неравномерно используются эксперты ===")
    for k in coverage:
        print(f"  {k:9} обслуживают {100 * coverage[k]:5.1f}% обращений "
              f"(при равномерном роутере было бы {100 * uniform[k]:.0f}%)")
    print(f"  сходство наборов у соседних токенов: {100 * overlap:.1f}%")

    print("\n=== объединение экспертов по нескольким токенам ===")
    print(f"  на один токен читается {top_k} экспертов")
    for k, v in union.items():
        print(f"  окно {k:>2}: объединение {v['union']:6.2f} "
              f"({v['per_token']:5.2f} на токен, экономия x{v['saving_vs_single']:.2f}); "
              f"общий набор дал бы x{v['if_shared_set']:.2f} меньше чтений")

    print("\n=== трафик ===")
    print(f"  эксперт: {exp_bytes / 1e6:.2f} МБ; на токен {per_token_gb:.3f} ГБ")
    print(f"  потолок при {args.ram_gbs:.0f} ГБ/с: {ceiling:.2f} ток/с")
    print(f"  в VRAM влезает {fit} из {slots} слотов -> "
          f"{100 * served:.1f}% обращений")
    print(f"\nзаписано: {args.out}")


if __name__ == "__main__":
    main()
