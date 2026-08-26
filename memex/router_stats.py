"""Measure what MoE routing actually does, because three separate optimisations
all depend on the same unmeasured numbers.

  * pinning hot experts in VRAM pays off only in proportion to how concentrated
    expert usage is - if usage were uniform, a cache holding 8% of the experts
    would serve 8% of the reads and change nothing;
  * computing several tokens with one shared expert set pays off only if the union
    of experts over k consecutive tokens is much smaller than k times the per-token
    count - that ratio is the ceiling on the saving, and it is a property of the
    model, not of the implementation;
  * quantising rarely-used experts changes the footprint, but per-token traffic is
    driven by which experts are *activated*; those are different quantities, and
    conflating them predicts a speed-up that never arrives.

So: hook the routers, record every decision, and report all three.
"""
import argparse
import io
import json
import os
from collections import Counter, defaultdict

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer


def attach_router_hooks(model, n_experts, store):
    """Capture router logits wherever they are produced.

    Router plumbing differs per architecture (Granite returns sorted index
    tensors, Qwen returns logits, OLMoE differs again), so instead of matching
    names this matches the shape contract: a Linear whose output width equals the
    expert count is a router in every implementation seen so far.
    """
    handles, found = [], []
    for name, mod in model.named_modules():
        if isinstance(mod, torch.nn.Linear) and mod.out_features == n_experts:
            def hook(_m, _i, out, layer=name):
                logits = out.detach().reshape(-1, n_experts).float()
                store[layer].append(logits.cpu())
            handles.append(mod.register_forward_hook(hook))
            found.append(name)
    return handles, found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=r"D:\MemeX\models\granite-moe")
    ap.add_argument("--text", default=r"D:\MemeX\data\corpus_mixed.txt")
    ap.add_argument("--tokens", type=int, default=8192)
    ap.add_argument("--chunk", type=int, default=512)
    ap.add_argument("--windows", type=int, nargs="+", default=[2, 4, 8, 16])
    ap.add_argument("--vram-gb", type=float, default=2.3,
                    help="сколько VRAM реально доступно под экспертов")
    ap.add_argument("--out", default=r"D:\MemeX\results\router_stats.json")
    args = ap.parse_args()

    cfg = json.load(io.open(os.path.join(args.model, "config.json"),
                            encoding="utf-8"))
    n_exp = cfg.get("num_local_experts") or cfg.get("num_experts")
    top_k = cfg.get("num_experts_per_tok")
    n_layers = cfg["num_hidden_layers"]
    print(f"модель: {n_layers} слоёв, {n_exp} экспертов, top-{top_k}")

    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(
        args.model, torch_dtype=torch.float32).eval()

    if os.path.exists(args.text):
        text = io.open(args.text, encoding="utf-8", errors="ignore").read()
    else:
        print("корпуса нет - беру встроенный текст")
        text = ("The access code for the north gate is 4821. " * 200 +
                "Somebody was whistling in the corridor, badly. " * 200) * 4
    ids = tok(text, return_tensors="pt").input_ids[0][: args.tokens]
    print(f"токенов: {len(ids)}")

    store = defaultdict(list)
    handles, found = attach_router_hooks(model, n_exp, store)
    print(f"перехвачено роутеров: {len(found)}")
    if not found:
        raise SystemExit("роутеры не найдены - архитектура не распознана")

    with torch.no_grad():
        for s in range(0, len(ids) - 1, args.chunk):
            model(ids[s : s + args.chunk].unsqueeze(0))
    for h in handles:
        h.remove()

    layers = sorted(store)
    picks = {}                       # layer -> LongTensor[tokens, top_k]
    for lay in layers:
        picks[lay] = torch.cat(store[lay], 0).topk(top_k, dim=-1).indices

    # 1) how concentrated expert use is
    pop = Counter()
    for lay in layers:
        for e, n in Counter(picks[lay].reshape(-1).tolist()).items():
            pop[(lay, e)] += n
    total_reads = sum(pop.values())
    ranked = sorted(pop.values(), reverse=True)
    coverage = {}
    for frac in (0.05, 0.10, 0.20, 0.30, 0.50):
        n = max(1, int(len(ranked) * frac))
        coverage[f"top_{int(frac * 100)}pct_experts"] = round(
            sum(ranked[:n]) / total_reads, 4)

    # 2) union growth - the ceiling on sharing one expert set across k tokens
    union = {}
    for k in args.windows:
        per_layer = []
        for lay in layers:
            p = picks[lay]
            n_win = p.shape[0] // k
            if n_win == 0:
                continue
            sizes = [len(set(p[i * k : (i + 1) * k].reshape(-1).tolist()))
                     for i in range(n_win)]
            per_layer.append(sum(sizes) / len(sizes))
        if not per_layer:
            continue
        u = sum(per_layer) / len(per_layer)
        union[str(k)] = {"union_size": round(u, 2),
                         "reads_per_token": round(u / k, 2),
                         "vs_topk": round(top_k / (u / k), 3)}

    # 3) how stable routing is between neighbouring tokens
    jac = []
    for lay in layers:
        p = picks[lay]
        rows = [set(r.tolist()) for r in p]
        if len(rows) < 2:
            continue
        jac.append(sum(len(a & b) / len(a | b)
                       for a, b in zip(rows[:-1], rows[1:])) / (len(rows) - 1))
    overlap = round(sum(jac) / len(jac), 4) if jac else 0.0

    # 4) footprint versus traffic - the distinction that decides what
    #    compressing cold experts actually buys
    exp_params = 3 * cfg["hidden_size"] * cfg["intermediate_size"]
    n_slots = n_layers * n_exp
    B_Q6, B_Q4 = 0.82, 0.56
    full_gb = n_slots * exp_params * B_Q6 / 1e9
    fit_q6 = int(args.vram_gb * 1e9 / (exp_params * B_Q6))
    order = [k for k, _ in sorted(pop.items(), key=lambda kv: -kv[1])]
    served = sum(pop[k] for k in order[:fit_q6]) / total_reads
    mixed_gb = (fit_q6 * exp_params * B_Q6 +
                (n_slots - fit_q6) * exp_params * B_Q4) / 1e9
    # with cold experts at 4 bits the same VRAM holds more of them, so the
    # comparison worth reporting is how much more of the traffic it covers
    fit_mixed = min(n_slots, int(args.vram_gb * 1e9 / (exp_params * B_Q4)))
    served_mixed = sum(pop[k] for k in order[:fit_mixed]) / total_reads

    res = {"model": os.path.basename(args.model), "layers": n_layers,
           "experts": n_exp, "top_k": top_k, "tokens": int(len(ids)),
           "coverage": coverage, "union_growth": union,
           "adjacent_overlap": overlap,
           "expert_slots": n_slots,
           "slots_fitting_vram_q6": fit_q6,
           "share_of_reads_served": round(served, 4),
           "slots_fitting_vram_q4": fit_mixed,
           "share_of_reads_served_q4": round(served_mixed, 4),
           "expert_pool_gb_q6": round(full_gb, 2),
           "expert_pool_gb_hot_q6_cold_q4": round(mixed_gb, 2)}

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with io.open(args.out, "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, ensure_ascii=False)

    print("\n=== концентрация использования ===")
    for k, v in coverage.items():
        print(f"  {k:22} обслуживают {100 * v:5.1f}% обращений")
    print(f"  сходство наборов у соседних токенов: {100 * overlap:.1f}%")
    print("\n=== несколько токенов одним набором ===")
    for k, v in union.items():
        print(f"  окно {k:>2}: объединение {v['union_size']:5.2f} экспертов, "
              f"чтений на токен {v['reads_per_token']:4.2f} вместо {top_k} "
              f"(выигрыш x{v['vs_topk']:.2f})")
    print("\n=== VRAM и сжатие холодных ===")
    print(f"  пул экспертов в Q6: {full_gb:.2f} GB, слотов {n_slots}")
    print(f"  в {args.vram_gb} GB VRAM влезает {fit_q6} слотов -> "
          f"{100 * served:.1f}% обращений")
    print(f"  если те же слоты хранить в 4 битах: влезает {fit_mixed} -> "
          f"{100 * served_mixed:.1f}% обращений")
    print(f"  пул целиком при холодных в 4 битах: {mixed_gb:.2f} GB "
          f"(было {full_gb:.2f})")
    print(f"\nзаписано: {args.out}")


if __name__ == "__main__":
    main()
