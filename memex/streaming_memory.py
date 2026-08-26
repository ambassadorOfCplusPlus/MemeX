"""Streaming MemeX memory with the elastic notebook ("evict-or-expand").

The one-shot benchmarks fill the notebook once, so the policy that makes MemeX
distinctive never gets exercised. Here the context arrives in chunks, exactly as
it does in a real session, and the notebook must decide continuously:

  * a token leaving the exact window is either promoted to the notebook (kept at
    full rank) or projected into the low-rank tail;
  * when the notebook is full, the least important slot is DEMOTED to the tail
    rather than deleted — nothing is ever lost irrecoverably, which is the known
    failure mode of H2O/SnapKV-style eviction;
  * if every slot is above the importance threshold, the notebook ASKS FOR MORE
    room instead of throwing a useful fact away, up to a hardware cap.

Importance is not static: a slot that keeps receiving attention grows, and one
that stops decays, so the notebook tracks what the session actually needs.
"""
import argparse
import json
import os
import sys
import time

import torch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from memex.compat import load_model, load_tokenizer
from memex.projected_cache import get_layer_kv, project_rows


class ElasticNotebook:
    """Per-layer set of exact slots with importance-driven eviction/expansion."""

    def __init__(self, n_layers, capacity, cap_max, threshold=0.35, decay=0.9,
                 grow_by=16, mode="elastic"):
        self.n_layers = n_layers
        # Elasticity is for RELEASING memory, not for acquiring it. Starting
        # starved and growing under pressure loses early-arriving facts before
        # the notebook has room — measured: a needle at 35% depth was demoted
        # while capacity was still small. So start at the cap and shrink only
        # when the hardware asks for the memory back.
        if mode == "elastic":
            capacity = cap_max
        self.capacity = [capacity] * n_layers
        self.cap_max = cap_max
        self.threshold = threshold
        self.decay = decay
        self.grow_by = grow_by
        self.mode = mode                     # elastic | fixed
        self.slots = [dict() for _ in range(n_layers)]  # pos -> importance
        self.stats = {"promoted": 0, "demoted": 0, "expansions": 0,
                      "refused_evictions": 0, "shrinks": 0}

    def decay_all(self):
        for layer in self.slots:
            for pos in list(layer):
                layer[pos] *= self.decay

    def touch(self, layer_idx, pos, mass):
        """A read of this slot raises its importance."""
        if pos in self.slots[layer_idx]:
            self.slots[layer_idx][pos] += float(mass)

    def offer(self, layer_idx, pos, importance):
        """Try to keep token `pos` exact. Returns the position demoted to the
        compressed tail (or None). This is the evict-or-expand decision."""
        slots = self.slots[layer_idx]
        if pos in slots:
            slots[pos] = max(slots[pos], float(importance))
            return None
        if len(slots) < self.capacity[layer_idx]:
            slots[pos] = float(importance)
            self.stats["promoted"] += 1
            return None

        weakest = min(slots, key=slots.get)
        # Scale-free threshold: importance is raw attention mass, whose magnitude
        # depends on layer, head count and chunk size, so an absolute cut-off is
        # meaningless. Compare against the notebook's own mean instead.
        mean_imp = sum(slots.values()) / max(len(slots), 1)
        weak_enough = slots[weakest] < self.threshold * mean_imp
        if weak_enough:
            del slots[weakest]                      # demoted, not deleted:
            slots[pos] = float(importance)          # the caller compresses it
            self.stats["promoted"] += 1
            self.stats["demoted"] += 1
            return weakest

        # Everything currently held is still important.
        if self.mode == "elastic" and self.capacity[layer_idx] < self.cap_max:
            self.capacity[layer_idx] = min(self.cap_max,
                                           self.capacity[layer_idx] + self.grow_by)
            slots[pos] = float(importance)
            self.stats["promoted"] += 1
            self.stats["expansions"] += 1
            return None

        # Fixed budget (or cap reached): the new candidate loses.
        self.stats["refused_evictions"] += 1
        return pos

    def shrink(self, layer_idx, to_capacity, policy="importance"):
        """Give memory back: reduce this layer's capacity and demote the losers.

        Returns the positions that must move to the compressed tail. The policy
        argument exists so the value of importance-ranked release can be measured
        against the naive alternatives instead of assumed.
        """
        slots = self.slots[layer_idx]
        self.capacity[layer_idx] = to_capacity
        drop = max(0, len(slots) - to_capacity)
        if drop == 0:
            return []
        if policy == "importance":
            order = sorted(slots, key=slots.get)            # weakest first
        elif policy == "oldest":
            order = sorted(slots)                           # lowest position
        else:
            order = sorted(slots, reverse=True)             # newest first
        victims = order[:drop]
        for p in victims:
            del slots[p]
        self.stats["demoted"] += len(victims)
        self.stats["shrinks"] += 1
        return victims

    def exact_positions(self, layer_idx):
        return torch.tensor(sorted(self.slots[layer_idx]), dtype=torch.long)

    def mean_capacity(self):
        return sum(self.capacity) / len(self.capacity)

    def mean_used(self):
        return sum(len(s) for s in self.slots) / len(self.slots)


class MasterCopy:
    """Full-rank K/V of everything that left the exact window — the RAM tier.

    Compression happens in the cache the model reads from (the fast tier), but the
    original rows are kept here, so a token demoted to low rank is not lost: at
    query time the retrieval step can restore the ones this particular question
    needs. Without this the architecture's "warm on access" is impossible, and
    demotion becomes as irreversible as H2O-style eviction.
    """

    def __init__(self, n_layers):
        self.rows = [dict() for _ in range(n_layers)]  # pos -> (k_row, v_row)

    def put(self, layer_idx, pos, k_row, v_row):
        # Kept on the host: this is the RAM tier, and it must not compete with
        # the cache for accelerator memory.
        if pos not in self.rows[layer_idx]:
            self.rows[layer_idx][pos] = (k_row.detach().to("cpu", copy=True),
                                         v_row.detach().to("cpu", copy=True))

    def restore(self, layer_idx, pos, k_tensor, v_tensor):
        got = self.rows[layer_idx].get(pos)
        if got is None:
            return False
        k_row, v_row = got
        k_tensor[0, :, pos, :] = k_row.to(k_tensor.device, k_tensor.dtype)
        v_tensor[0, :, pos, :] = v_row.to(v_tensor.device, v_tensor.dtype)
        return True

    def bytes(self):
        n = 0
        for layer in self.rows:
            for k_row, v_row in layer.values():
                n += k_row.numel() * k_row.element_size()
                n += v_row.numel() * v_row.element_size()
        return n


@torch.no_grad()
def query_retrieval(model, ids, cache, master, budget, sinks, window,
                    probe_len=32):
    """Restore the top-`budget` tail positions this query actually needs.

    Scores come from re-running the last `probe_len` prompt tokens against the
    already-compressed cache: low-rank latents are good enough to rank, and the
    winners are then brought back to full rank from the master copy.
    """
    T = ids.shape[1]
    if hasattr(cache, "crop"):
        cache.crop(T - probe_len)
    out = model(ids[:, T - probe_len:], past_key_values=cache, use_cache=True,
                output_attentions=True)
    cache = out.past_key_values
    lo, hi = sinks, T - window
    restored = 0
    for li, att in enumerate(out.attentions):
        if hi <= lo:
            break
        score = att[0].sum(dim=(0, 1))[lo:hi]
        k = min(budget, score.numel())
        if k <= 0:
            continue
        top = torch.topk(score, k).indices + lo
        k_t, v_t = get_layer_kv(cache, li)
        for p in top.tolist():
            restored += master.restore(li, p, k_t, v_t)
    del out
    return cache, restored


@torch.no_grad()
def stream_context(model, ids, basis_k, basis_v, rank, window, sinks,
                   notebook, chunk=256, pressure_at=None, pressure_to=8,
                   pressure_policy="importance", master=None):
    """Feed the context in chunks, maintaining window + notebook + tail.

    Returns the cache. Importance of a candidate token is the attention mass it
    received from the chunk that just ran — available for free, and causal: the
    question has not been seen yet.
    """
    n_layers = model.config.num_hidden_layers
    cache = None
    total = ids.shape[1]
    pos = 0
    while pos < total:
        piece = ids[:, pos:pos + chunk]
        out = model(piece, past_key_values=cache, use_cache=True,
                    output_attentions=True)
        cache = out.past_key_values
        seen = pos + piece.shape[1]

        # candidates: tokens that just fell out of the exact window
        lo = sinks
        hi = seen - window
        if hi > lo:
            for li in range(n_layers):
                att = out.attentions[li][0]           # [heads, q_chunk, seen]
                mass = att.sum(dim=(0, 1))            # per key position
                # refresh importance of slots that were read again
                for p in list(notebook.slots[li]):
                    if p < mass.shape[0]:
                        notebook.touch(li, p, mass[p])
                k, v = get_layer_kv(cache, li)
                fresh = range(max(lo, hi - piece.shape[1]), hi)
                for p in fresh:
                    if master is not None:
                        master.put(li, p, k[0, :, p, :], v[0, :, p, :])
                    demoted = notebook.offer(li, p, float(mass[p]))
                    if demoted is None:
                        continue
                    # `demoted` is a position that must live in the tail now
                    for tensor, bas in ((k, basis_k[li]), (v, basis_v[li])):
                        row = tensor[0, :, demoted, :].reshape(1, -1)
                        tensor[0, :, demoted, :] = project_rows(
                            row, bas, rank).reshape(tensor.shape[1],
                                                    tensor.shape[3])
        del out
        notebook.decay_all()
        pos += piece.shape[1]

        # Simulated hardware pressure: the KV cache grew, VRAM shrank, another
        # process appeared — the notebook must hand slots back mid-session. This
        # is where the choice of *what* to release is decided.
        if pressure_at is not None and pos >= pressure_at and not notebook.stats["shrinks"]:
            k_all = [get_layer_kv(cache, li) for li in range(n_layers)]
            for li in range(n_layers):
                victims = notebook.shrink(li, pressure_to, pressure_policy)
                k, v = k_all[li]
                for p in victims:
                    for tensor, bas in ((k, basis_k[li]), (v, basis_v[li])):
                        row = tensor[0, :, p, :].reshape(1, -1)
                        tensor[0, :, p, :] = project_rows(row, bas, rank).reshape(
                            tensor.shape[1], tensor.shape[3])
    return cache


@torch.no_grad()
def answer(model, tokenizer, ids, cache, max_new=8):
    cur = cache
    if hasattr(cur, "crop"):
        cur.crop(ids.shape[1] - 1)
    out = model(ids[:, -1:], past_key_values=cur, use_cache=True)
    cur = out.past_key_values
    nxt = out.logits[0, -1].argmax().reshape(1, 1)
    got = [int(nxt)]
    for _ in range(max_new - 1):
        out = model(nxt, past_key_values=cur, use_cache=True)
        cur = out.past_key_values
        nxt = out.logits[0, -1].argmax().reshape(1, 1)
        got.append(int(nxt))
    return tokenizer.decode(got)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=r"D:\MemeX\models\Qwen3-0.6B")
    ap.add_argument("--results", default=r"D:\MemeX\results")
    ap.add_argument("--haystack", type=int, default=2000)
    ap.add_argument("--window", type=int, default=256)
    ap.add_argument("--sinks", type=int, default=4)
    ap.add_argument("--rank", type=int, default=128)
    ap.add_argument("--chunk", type=int, default=256)
    ap.add_argument("--start-slots", type=int, default=16)
    ap.add_argument("--cap-max", type=int, default=96)
    ap.add_argument("--threshold", type=float, default=0.35)
    ap.add_argument("--cases", type=int, default=4)
    ap.add_argument("--pressure-at", type=int, default=None,
                    help="token position where the notebook must give slots back")
    ap.add_argument("--pressure-to", type=int, default=8,
                    help="capacity after the shrink")
    ap.add_argument("--retrieve", type=int, default=0,
                    help="positions restored from the master copy at query time "
                         "(0 = notebook only, no read-time retrieval)")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    torch.set_num_threads(args.threads)
    tokenizer = load_tokenizer(args.model)
    model = load_model(args.model, device=args.device, attn="eager")
    basis = torch.load(os.path.join(args.results, "kv_basis.pt"),
                       weights_only=True)
    basis_k = [b.to(args.device) for b in basis["k"]]
    basis_v = [b.to(args.device) for b in basis["v"]]

    sys.path.insert(0, os.path.join(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))), "bench"))
    from needle import build_case
    import random

    results = []
    # The shrink-policy arms are meaningless without a shrink event, and silently
    # producing four identical runs is worse than failing: default the pressure
    # point to mid-context instead of None.
    if args.pressure_at is None:
        args.pressure_at = args.haystack // 2
        print(f"[стенд] давление не задано -> ставлю на {args.pressure_at} токенов, "
              f"иначе ветки политик совпадут", flush=True)
    # All arms see the SAME cases (own RNG per arm, same seed) and the same final
    # slot budget, so the only difference is which facts the policy keeps.
    arms = (
        ("no-pressure (потолок всё время)", args.cap_max, None, "importance"),
        ("сжатие по важности", args.cap_max, args.pressure_at, "importance"),
        ("сжатие: сброс старых", args.cap_max, args.pressure_at, "oldest"),
        ("сжатие: сброс новых", args.cap_max, args.pressure_at, "newest"),
        ("маленький с начала", args.pressure_to, None, "importance"),
    )
    for mode, start, press_at, press_pol in arms:
        rng = random.Random(11)
        hits = 0
        caps = []
        for ci in range(args.cases):
            passkey = str(rng.randint(10000, 99999))
            ids = build_case(tokenizer, args.haystack, 0.35, passkey,
                             distractors=6, rng=rng).to(args.device)
            nb = ElasticNotebook(model.config.num_hidden_layers, start, start,
                                 threshold=args.threshold, mode="fixed")
            t0 = time.time()
            master = MasterCopy(model.config.num_hidden_layers) if args.retrieve else None
            cache = stream_context(model, ids, basis_k, basis_v, args.rank,
                                   args.window, args.sinks, nb, chunk=args.chunk,
                                   pressure_at=press_at,
                                   pressure_to=args.pressure_to,
                                   pressure_policy=press_pol, master=master)
            restored = 0
            if master is not None:
                cache, restored = query_retrieval(
                    model, ids, cache, master, args.retrieve, args.sinks,
                    args.window)
            ans = answer(model, tokenizer, ids, cache)
            ok = passkey in ans
            hits += ok
            caps.append(nb.mean_capacity())
            mb = master.bytes() / 1e6 if master else 0.0
            print(f"[{mode} {ci}] {'OK ' if ok else 'FAIL'} "
                  f"слотов {nb.mean_capacity():.0f}, понижений {nb.stats['demoted']}, "
                  f"восстановлено {restored}, мастер-копия {mb:.0f} МБ, "
                  f"{time.time()-t0:.0f} с -> {ans.strip()[:22]!r}", flush=True)
            results.append({"mode": mode, "case": ci, "ok": bool(ok),
                            "mean_capacity": nb.mean_capacity(),
                            **nb.stats})
        print(f"== {mode}: {hits}/{args.cases}, средний бюджет "
              f"{sum(caps)/len(caps):.1f} слотов ==\n", flush=True)

    with open(os.path.join(args.results, "elastic_notebook.json"), "w") as f:
        json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
