"""Model-agnostic MoE tiering manifest.

Goal: plug ANY open MoE checkpoint into the MemeX expert-paging engine without
per-model code. Everything needed is derivable from the checkpoint's weight
index (`model.safetensors.index.json`) plus `config.json` — no weights are
downloaded, so a 600 GB model can be planned from a few hundred KB of metadata.

What it produces:
  * which tensors are per-expert (pageable, read-only) vs always-resident
    (embeddings, attention, norms, dense MLPs, shared experts, router gates)
  * bytes per expert and per layer, at a chosen quantisation
  * a VRAM / RAM / disk plan for given hardware limits: how many expert slots
    fit in VRAM, how much of the expert pool stays warm in RAM, what spills to
    disk, and the expected cold-miss rate under a Zipf popularity assumption
  * per-token traffic estimate -> a bandwidth-bound speed ceiling

Expert tensors are recognised by name patterns shared across the open MoE
families (Mixtral, Qwen3-MoE/Next, DeepSeek V2/V3/V4, GLM, OLMoE, Granite,
MiniMax, Phi-MoE), so new checkpoints usually need no changes at all.
"""
import argparse
import json
import os
import re
import urllib.request

# (regex, expert-index group) — expert weight names across open MoE families
EXPERT_PATTERNS = [
    re.compile(r"\.experts\.(\d+)\."),          # Mixtral, Qwen3-MoE, DeepSeek, GLM, OLMoE
    re.compile(r"\.expert_(\d+)\."),            # some Granite/Phi variants
    re.compile(r"\.mlp\.(\d+)\.(?:w1|w2|w3)"),  # older Megablocks-style dumps
]
# always resident regardless of size: routing needs them before any expert runs
RESIDENT_HINTS = re.compile(
    r"(embed|lm_head|norm|rotary|router|gate\.weight|gate_proj\.bias|"
    r"shared_expert|shared_experts|correction_bias|e_score)")
LAYER_RE = re.compile(r"layers?\.(\d+)\.")

BYTES_PER_PARAM = {"fp16": 2.0, "bf16": 2.0, "fp8": 1.0, "int8": 1.0,
                   "q6": 0.82, "q5": 0.68, "q4": 0.56, "mxfp4": 0.55,
                   "q3": 0.44, "q2": 0.33,
                   # shared-codebook vector quantisation, measured in
                   # delta_experts.py on real experts (relative error in
                   # parentheses): row scales add ~0.01 bit/weight.
                   "vq4": 0.51,   # dim 2, 256 entries, per-row scales (0.013)
                   "vq2": 0.26,   # dim 4, 256 entries, per-row scales (0.237)
                   "vq1": 0.13}   # dim 8, 256 entries, per-row scales (0.560)


def fetch_index(model_id, local_dir=None):
    """Return (index dict or None, config dict). Works from a local folder or
    straight from the Hub over HTTPS (metadata only)."""
    def read_local(name):
        p = os.path.join(local_dir, name)
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        return None

    def read_hub(name):
        url = f"https://huggingface.co/{model_id}/resolve/main/{name}"
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return json.loads(r.read().decode())
        except Exception:
            return None

    reader = read_local if local_dir else read_hub
    config = reader("config.json") or {}
    index = reader("model.safetensors.index.json")
    return index, config


def numel_from_shape(shape):
    n = 1
    for d in shape:
        n *= d
    return n


def analyse(index, config):
    """Split the checkpoint into pageable expert tensors and resident tensors.

    Parameter counts come from the index's per-tensor byte sizes when present;
    otherwise from config-derived shapes. Both are optional in the wild, so we
    fall back to counting tensors per expert and using config dims.
    """
    weight_map = index.get("weight_map", {}) if index else {}
    meta_total = (index or {}).get("metadata", {}).get("total_size")

    experts = {}          # (layer, expert) -> [tensor names]
    resident = []
    for name in weight_map:
        if RESIDENT_HINTS.search(name):
            resident.append(name)
            continue
        hit = None
        for pat in EXPERT_PATTERNS:
            m = pat.search(name)
            if m:
                hit = int(m.group(1))
                break
        if hit is None:
            resident.append(name)
            continue
        lm = LAYER_RE.search(name)
        layer = int(lm.group(1)) if lm else -1
        experts.setdefault((layer, hit), []).append(name)

    n_layers = config.get("num_hidden_layers") or (
        max((l for l, _ in experts), default=-1) + 1)
    hidden = config.get("hidden_size")
    inter = (config.get("moe_intermediate_size")
             or config.get("expert_intermediate_size")
             or config.get("intermediate_size"))
    n_experts = (config.get("num_experts")
                 or config.get("n_routed_experts")
                 or config.get("num_local_experts")
                 or (max((e for _, e in experts), default=-1) + 1))
    top_k = (config.get("num_experts_per_tok")
             or config.get("moe_topk")
             or config.get("num_experts_per_token") or 0)

    # params in one expert: gate+up+down projections of an SwiGLU MLP
    tensors_per_expert = max((len(v) for v in experts.values()), default=3)
    params_per_expert = None
    if hidden and inter:
        params_per_expert = (3 if tensors_per_expert >= 3 else 2) * hidden * inter

    # Everything that is NOT a routed expert is shared by all of them —
    # attention, norms, embeddings, the router itself, the always-active shared
    # expert, and (in hybrids) the linear-attention layers. It never pages, so it
    # has to fit in VRAM before a single expert slot exists.
    dtype = str(config.get("torch_dtype") or config.get("dtype") or "bfloat16")
    published_bpp = 1.0 if "8" in dtype and "float8" in dtype.replace("_", "") else 2.0
    total_params = None
    resident_params = None
    if meta_total:
        total_params = meta_total / published_bpp
        if params_per_expert:
            expert_params = params_per_expert * len(experts)
            resident_params = max(0.0, total_params - expert_params)

    return {
        "total_params": total_params, "resident_params": resident_params,
        "published_bytes_per_param": published_bpp,
        "n_layers": n_layers, "hidden": hidden, "expert_inter": inter,
        "n_experts": n_experts, "top_k": top_k,
        "moe_layers": len({l for l, _ in experts}),
        "experts_found": len(experts),
        "tensors_per_expert": tensors_per_expert,
        "params_per_expert": params_per_expert,
        "resident_tensors": len(resident),
        "total_size_bytes": meta_total,
        "is_moe": bool(experts),
    }


def plan(info, quant="q4", vram_gb=4.0, ram_gb=32.0, reserve_vram_gb=1.4,
         reserve_ram_gb=4.0, zipf=1.0, pcie_gbps=3.5, disk_gbps=0.15,
         ram_gbps=40.0, delta_rank=0):
    """Tiering plan + bandwidth-bound speed ceiling for given hardware.

    delta_rank > 0 models the shared-base + low-rank-delta variant: the layer's
    common base stays resident and only (rows+cols)*rank per projection is paged,
    so a slot holds far more experts. Validate the quality side with
    memex/delta_experts.py before trusting the speed side.
    """
    bpp = BYTES_PER_PARAM[quant]
    ppe = info["params_per_expert"]
    if not ppe:
        return None
    if delta_rank > 0 and info["hidden"] and info["expert_inter"]:
        h, i = info["hidden"], info["expert_inter"]
        tensors = 3 if info["tensors_per_expert"] >= 3 else 2
        ppe = tensors * (h + i) * delta_rank
    expert_mb = ppe * bpp / 1e6
    total_experts = info["moe_layers"] * info["n_experts"]
    pool_gb = total_experts * expert_mb / 1000

    vram_slots_total = max(0, int((vram_gb - reserve_vram_gb) * 1000 / expert_mb))
    ram_slots_total = max(0, int((ram_gb - reserve_ram_gb) * 1000 / expert_mb))
    per_layer_slots = vram_slots_total // max(info["moe_layers"], 1)

    resident_frac = min(1.0, (vram_slots_total + ram_slots_total) / total_experts)
    # Zipf(1) popularity: fraction of activations served by the most popular
    # `resident_frac` of experts ~ ln(1+r*N)/ln(1+N)
    import math
    n = total_experts
    if zipf <= 0.01:
        # Uniform popularity: residency buys coverage one-for-one. This is the
        # pessimistic case, and MoE load-balancing losses actively push real
        # models toward it, so it is not a straw man.
        covered = resident_frac
    else:
        # Zipf(s): share of total mass held by the top `resident_frac` of items.
        k = max(1, int(resident_frac * n))
        harmonic = lambda m: sum(1.0 / (i ** zipf) for i in range(1, m + 1)) \
            if m <= 4096 else (math.log(m) + 0.5772) if zipf == 1.0 else \
            (m ** (1 - zipf) - 1) / (1 - zipf) + 1
        covered = min(1.0, harmonic(k) / harmonic(n))
    cold_frac = max(0.0, 1 - covered)

    # per-token traffic: active experts that must be fetched from RAM or disk
    active = info["top_k"] * info["moe_layers"]
    vram_frac = min(1.0, vram_slots_total / n) if n else 1.0
    from_vram = active * min(1.0, math.log1p(vram_frac * n) / math.log1p(n) if n else 1)
    from_disk = active * cold_frac
    from_ram = max(0.0, active - from_vram - from_disk)
    ms = (from_ram * expert_mb / (ram_gbps * 1000) * 1000
          + from_disk * expert_mb / (disk_gbps * 1000) * 1000)
    return {
        "quant": quant, "expert_mb": round(expert_mb, 2),
        "experts_total": total_experts, "pool_gb": round(pool_gb, 1),
        "vram_slots": vram_slots_total, "vram_slots_per_layer": per_layer_slots,
        "ram_slots": ram_slots_total,
        "resident_frac": round(resident_frac, 3),
        "activations_covered": round(covered, 3),
        "cold_miss_frac": round(cold_frac, 3),
        "active_experts_per_token": active,
        "fetch_per_token": {"vram_hit": round(from_vram, 1),
                            "from_ram": round(from_ram, 1),
                            "from_disk": round(from_disk, 1)},
        "weight_ms_per_token": round(ms, 1),
        "ceiling_tok_s": round(1000 / ms, 2) if ms > 0 else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model", help="HF repo id, or local dir with --local")
    ap.add_argument("--local", default=None, help="local checkpoint dir")
    ap.add_argument("--quant", default="q4", choices=sorted(BYTES_PER_PARAM))
    ap.add_argument("--vram-gb", type=float, default=4.0)
    ap.add_argument("--ram-gb", type=float, default=32.0)
    ap.add_argument("--disk-gbps", type=float, default=0.15,
                    help="0.15 = HDD, 3.5 = SATA SSD, 7 = NVMe")
    ap.add_argument("--zipf", type=float, default=1.0,
                    help="expert popularity skew: 1.0 = strongly skewed, "
                         "0.0 = uniform. MoE load-balancing losses push real "
                         "models toward uniform, which is the pessimistic case")
    ap.add_argument("--json-out", default=None)
    ap.add_argument("--resident-quant", default=None, choices=sorted(BYTES_PER_PARAM),
                    help="precision for the always-resident part (default: same "
                         "as --quant); measured sensitivity says this is where "
                         "extra bits are worth spending")
    ap.add_argument("--delta-rank", type=int, default=0,
                    help="model experts as shared base + rank-r delta")
    args = ap.parse_args()

    index, config = fetch_index(args.model, args.local)
    if index is None and not config:
        raise SystemExit("could not read config.json / index (offline? wrong id?)")
    info = analyse(index, config)
    print(f"== {args.model} ==")
    print(f"architecture   : {config.get('model_type', '?')}, "
          f"{info['n_layers']} layers, hidden {info['hidden']}")
    if not info["is_moe"]:
        print("no expert tensors found -> dense model, nothing to page")
        return
    print(f"MoE            : {info['n_experts']} experts x {info['moe_layers']} "
          f"MoE layers, top-{info['top_k']} per token")
    print(f"expert shape   : {info['tensors_per_expert']} tensors, "
          f"{info['params_per_expert'] and info['params_per_expert']/1e6:.1f}M params each")
    if info["total_size_bytes"]:
        print(f"checkpoint     : {info['total_size_bytes']/1e9:.0f} GB as published")
    p = plan(info, quant=args.quant, vram_gb=args.vram_gb, ram_gb=args.ram_gb,
             disk_gbps=args.disk_gbps, delta_rank=args.delta_rank,
             zipf=args.zipf)
    if not p:
        print("could not size experts (config lacks dims)")
        return
    print(f"\n-- plan @ {args.quant}, VRAM {args.vram_gb} GB, RAM {args.ram_gb} GB, "
          f"disk {args.disk_gbps} GB/s --")
    if info.get("resident_params"):
        rp = info["resident_params"]
        # The shared part is ~3% of the model but carries the routing decision,
        # so it can be kept at a higher precision almost for free.
        res_quant = args.resident_quant or args.quant
        res_gb = rp * BYTES_PER_PARAM[res_quant] / 1e9
        if res_quant != args.quant:
            print(f"resident quant : {res_quant} (experts stay at {args.quant})")
        left = args.vram_gb - res_gb
        print(f"always resident: {rp/1e9:.1f}B params = {res_gb:.2f} GB at "
              f"{res_quant} (attention, norms, embeddings, router, shared expert"
              f"{', linear layers' if info['moe_layers'] < info['n_layers'] else ''})"
              f" -> {left:.2f} GB left in VRAM for expert slots"
              f"{' — DOES NOT FIT' if left < 0 else ''}")
    print(f"expert size    : {p['expert_mb']} MB  (pool {p['pool_gb']} GB, "
          f"{p['experts_total']} experts)")
    print(f"VRAM slots     : {p['vram_slots']} ({p['vram_slots_per_layer']}/layer)")
    print(f"RAM slots      : {p['ram_slots']}")
    print(f"resident share : {p['resident_frac']*100:.1f}% of experts -> "
          f"{p['activations_covered']*100:.1f}% of activations (Zipf-1)")
    print(f"cold misses    : {p['cold_miss_frac']*100:.1f}% of activations hit disk")
    f = p["fetch_per_token"]
    print(f"per token      : {p['active_experts_per_token']} expert calls "
          f"(vram {f['vram_hit']}, ram {f['from_ram']}, disk {f['from_disk']})")
    print(f"weight traffic : {p['weight_ms_per_token']} ms/token -> "
          f"ceiling ~{p['ceiling_tok_s']} tok/s")
    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump({"info": info, "plan": p}, fh, indent=1)


if __name__ == "__main__":
    main()
