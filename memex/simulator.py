"""MemeX MoE expert-cache simulator (causal, no lookahead in policies).

Models the three-echelon design: VRAM slot cache <- RAM (inclusive, holds all
warm experts) <- disk. Weights are read-only, so eviction is free (slot drop);
only loads cost time. Two control loops:
  fast : cross-layer gate prefetch (Fate-style), configurable accuracy
  slow : every X tokens, EMA popularity re-ranking pins top experts in VRAM

Policies: lru, lfu, lfru (freq / (age+1)), belady (non-causal oracle, upper
bound only — reported separately, never compared as achievable).

Cost model (defaults ≈ user's PC): PCIe 3.0 x4 ≈ 3.5 GB/s, expert 1.8 MB Q4,
CPU GEMM per expert per token ≈ configurable; GPU compute ≈ free vs transfers.
Trace: synthetic Zipf popularity + Markov temporal stickiness, or a real trace
JSON (list of per-token, per-layer expert lists).
"""
import argparse
import heapq
import json
import random
from collections import defaultdict


def synth_trace(tokens=2000, layers=24, experts=512, topk=10, zipf=1.0,
                sticky=0.35, seed=0):
    """Zipf-popular experts with per-token Markov stickiness (repeat prob)."""
    rng = random.Random(seed)
    weights = [1.0 / (i + 1) ** zipf for i in range(experts)]
    # per-layer independent popularity permutation (layers differ in hot sets)
    perms = [rng.sample(range(experts), experts) for _ in range(layers)]
    prev = [None] * layers
    trace = []
    for _ in range(tokens):
        tok = []
        for li in range(layers):
            chosen = set()
            if prev[li]:
                for e in prev[li]:
                    if rng.random() < sticky:
                        chosen.add(e)
            while len(chosen) < topk:
                r = rng.choices(range(experts), weights=weights)[0]
                chosen.add(perms[li][r])
            sel = sorted(chosen)[:topk]
            prev[li] = sel
            tok.append(sel)
        trace.append(tok)
    return trace


class SlotCache:
    """Fixed-size slot cache with pluggable eviction policy."""

    def __init__(self, slots, policy, pinned=None):
        self.slots = slots
        self.policy = policy
        self.data = {}          # expert -> last_access
        self.freq = defaultdict(int)
        self.clock = 0
        self.pinned = set(pinned or [])

    def contains(self, e):
        return e in self.data

    def touch(self, e):
        self.clock += 1
        self.freq[e] += 1
        self.data[e] = self.clock

    def insert(self, e, future=None):
        if e in self.data:
            self.touch(e)
            return None
        victim = None
        if len(self.data) >= self.slots:
            victim = self._pick_victim(future)
            if victim is None:
                return "no-slot"       # everything pinned; caller computes on CPU
            del self.data[victim]
        self.touch(e)
        return victim

    def _pick_victim(self, future):
        cands = [x for x in self.data if x not in self.pinned]
        if not cands:
            return None
        if self.policy == "lru":
            return min(cands, key=lambda x: self.data[x])
        if self.policy == "lfu":
            return min(cands, key=lambda x: self.freq[x])
        if self.policy == "lfru":
            return min(cands, key=lambda x: self.freq[x] / (self.clock - self.data[x] + 1))
        if self.policy == "belady":
            nxt = {x: future.get(x, float("inf")) for x in cands}
            return max(cands, key=lambda x: nxt[x])
        raise ValueError(self.policy)


def simulate(trace, layers, vram_slots_per_layer, policy="lfru",
             prefetch_acc=0.97, rerank_every=64, ema=0.02,
             pcie_gbps=3.5, expert_mb=1.8, cpu_ms_per_expert=1.2,
             gpu_ms_per_expert=0.08, layer_ms=0.4, pin_frac=0.5):
    """Returns dict of metrics. Time model per layer: compute overlaps with the
    prefetch of the next layer's predicted experts; mispredicted/missed experts
    either stall for PCIe or run on CPU, whichever is cheaper."""
    rng = random.Random(1)
    xfer_ms = expert_mb / (pcie_gbps * 1024) * 1000.0

    caches = [SlotCache(vram_slots_per_layer, policy) for _ in range(layers)]
    popularity = [defaultdict(float) for _ in range(layers)]

    # belady oracle needs future positions
    future = None
    fptr = None
    if policy == "belady":
        future = [defaultdict(list) for _ in range(layers)]
        for ti, tok in enumerate(trace):
            for li, sel in enumerate(tok):
                for e in sel:
                    future[li][e].append(ti)
        fptr = [defaultdict(int) for _ in range(layers)]

    def fut_view(li, cache):
        """Next unconsumed use for each cached expert (belady only). Occurrences
        are consumed in consume() at actual use time, so an expert still needed
        later in the current token shows next-use == now and stays protected."""
        if future is None:
            return None
        view = {}
        for x in cache.data:
            lst = future[li][x]
            p = fptr[li][x]
            view[x] = lst[p] if p < len(lst) else float("inf")
        return view

    def consume(li, ti, e):
        if future is None:
            return
        lst = future[li][e]
        p = fptr[li][e]
        while p < len(lst) and lst[p] <= ti:
            p += 1
        fptr[li][e] = p

    hits = misses = cpu_runs = 0
    stall_ms = total_ms = 0.0
    for ti, tok in enumerate(trace):
        for li, sel in enumerate(tok):
            cache = caches[li]
            for e in sel:
                popularity[li][e] = popularity[li][e] * (1 - ema) + ema
            # fast loop: prefetch predicted experts during previous layer compute
            predicted = [e for e in sel if rng.random() < prefetch_acc]
            hidden_budget = layer_ms  # transfer time hidden under prior compute
            for e in predicted:
                if not cache.contains(e):
                    r = cache.insert(e, fut_view(li, cache))
                    if r != "no-slot":
                        cost = max(0.0, xfer_ms - hidden_budget)
                        hidden_budget = max(0.0, hidden_budget - xfer_ms)
                        stall_ms += cost
                else:
                    cache.touch(e)
            layer_time = layer_ms
            for e in sel:
                if cache.contains(e):
                    hits += 1
                    cache.touch(e)
                    layer_time += gpu_ms_per_expert
                else:
                    misses += 1
                    # unpredicted miss: CPU compute vs synchronous transfer
                    if cpu_ms_per_expert <= xfer_ms + gpu_ms_per_expert:
                        cpu_runs += 1
                        layer_time += cpu_ms_per_expert
                    else:
                        cache.insert(e, fut_view(li, cache))
                        layer_time += xfer_ms + gpu_ms_per_expert
                        stall_ms += xfer_ms
                consume(li, ti, e)
            total_ms += layer_time
        # slow loop: re-pin the EMA-top experts every X tokens
        if rerank_every and (ti + 1) % rerank_every == 0:
            for li in range(layers):
                top = sorted(popularity[li], key=popularity[li].get, reverse=True)
                caches[li].pinned = set(top[: int(vram_slots_per_layer * pin_frac)])

    accesses = hits + misses
    return {
        "policy": policy, "vram_slots": vram_slots_per_layer,
        "prefetch_acc": prefetch_acc, "rerank_every": rerank_every,
        "hit_rate": round(hits / accesses, 4),
        "cpu_run_frac": round(cpu_runs / accesses, 4),
        "stall_ms_per_tok": round(stall_ms / len(trace), 3),
        "ms_per_tok": round(total_ms / len(trace), 2),
        "tok_per_s": round(1000.0 * len(trace) / total_ms, 2),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", type=int, default=1500)
    ap.add_argument("--layers", type=int, default=24)
    ap.add_argument("--experts", type=int, default=512)
    ap.add_argument("--topk", type=int, default=10)
    ap.add_argument("--slots", type=int, nargs="+", default=[32, 64, 128])
    ap.add_argument("--policies", nargs="+",
                    default=["lru", "lfu", "lfru", "belady"])
    ap.add_argument("--rerank", type=int, nargs="+", default=[0, 16, 64, 256])
    ap.add_argument("--sticky", type=float, default=0.35)
    ap.add_argument("--prefetch", type=float, default=0.97)
    ap.add_argument("--trace-json", default=None,
                    help="real trace: JSON [[ [experts per layer], ...], ...]")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.trace_json:
        with open(args.trace_json) as f:
            trace = json.load(f)
        args.layers = len(trace[0])
    else:
        trace = synth_trace(args.tokens, args.layers, args.experts,
                            args.topk, sticky=args.sticky)

    rows = []
    print(f"{'policy':>8} {'slots':>5} {'rerankX':>7} {'hit':>7} {'cpu%':>6} "
          f"{'stall':>7} {'tok/s':>7}")
    for slots in args.slots:
        for pol in args.policies:
            for rr in (args.rerank if pol != "belady" else [0]):
                m = simulate(trace, args.layers, slots, policy=pol,
                             prefetch_acc=args.prefetch, rerank_every=rr)
                rows.append(m)
                print(f"{pol:>8} {slots:>5} {rr:>7} {m['hit_rate']:>7} "
                      f"{m['cpu_run_frac']:>6} {m['stall_ms_per_tok']:>7} "
                      f"{m['tok_per_s']:>7}")
    if args.out:
        with open(args.out, "w") as f:
            json.dump(rows, f, indent=1)


if __name__ == "__main__":
    main()
