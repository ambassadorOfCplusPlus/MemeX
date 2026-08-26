"""Self-speculative decoding for MoE: the model drafts for itself with top-1 routing.

Why this can be a large win on weak hardware. At batch 1 the cost per token is
dominated by *reading* the active expert weights once. Two facts combine:

  * a draft pass that keeps only the single best expert per layer reads ~1/k of
    the bytes (k = normal top-k), and those experts are the most popular ones,
    so they are the ones already resident in VRAM;
  * verifying d drafted tokens in ONE forward pass reads each needed expert once
    for all d tokens, instead of once per token. Because routing is temporally
    sticky, the union of d tokens' experts is far smaller than d times one.

So the speedup is not about compute, it is about amortising weight traffic. The
open question this script answers: how often does top-1 routing predict the same
token as full top-k routing? That acceptance rate decides everything.

The measurement is exact, not simulated: the same weights are used for both
passes, only the router's top-k is changed.
"""
import argparse
import os
import time

import torch

try:
    from .compat import load_model, load_tokenizer
except ImportError:
    from compat import load_model, load_tokenizer


def find_router_modules(model):
    """Locate MoE routers/gates in any architecture by looking for the modules
    whose output width equals the expert count."""
    n_exp = None
    for key in ("num_experts", "num_local_experts", "n_routed_experts",
                "num_experts_per_tok"):
        v = getattr(model.config, key, None)
        if v and key != "num_experts_per_tok":
            n_exp = v
            break
    hits = []
    for name, mod in model.named_modules():
        if isinstance(mod, torch.nn.Linear) and n_exp and mod.out_features == n_exp:
            hits.append((name, mod))
    return n_exp, hits


class TopKLimiter:
    """Force the router to behave as if only `keep` experts were selected.

    Implemented by hooking the router's output and pushing all but the top
    `keep` logits to -inf, so whatever downstream top-k / softmax the model uses
    ends up concentrating on those experts. Model code is untouched.
    """

    def __init__(self, routers, keep):
        self.keep = keep
        self.handles = [m.register_forward_hook(self._hook) for _, m in routers]

    def _hook(self, module, inputs, output):
        if self.keep is None:
            return output
        logits = output
        k = min(self.keep, logits.shape[-1])
        thresh = logits.topk(k, dim=-1).values[..., -1:]
        return logits.masked_fill(logits < thresh, float("-inf"))

    def remove(self):
        for h in self.handles:
            h.remove()


@torch.no_grad()
def greedy_ids(model, ids, steps, limiter_keep=None, routers=None):
    """Greedy continuation, optionally with the router limited to top-`keep`."""
    lim = TopKLimiter(routers, limiter_keep) if limiter_keep else None
    try:
        out = model(ids, use_cache=True)
        cache = out.past_key_values
        nxt = out.logits[0, -1].argmax().reshape(1, 1)
        got = [int(nxt)]
        for _ in range(steps - 1):
            out = model(nxt, past_key_values=cache, use_cache=True)
            cache = out.past_key_values
            nxt = out.logits[0, -1].argmax().reshape(1, 1)
            got.append(int(nxt))
        return got
    finally:
        if lim:
            lim.remove()


@torch.no_grad()
def measure_acceptance(model, tokenizer, prompts, routers, draft_keep=1,
                       draft_len=4, rounds=8):
    """Run the real speculative loop and count accepted drafts.

    Per round: draft `draft_len` tokens with top-`draft_keep` routing, then
    verify them in a single full-routing forward pass. A draft is accepted while
    it matches the full model's greedy choice — exactly the standard
    accept-reject rule, so quality is identical to plain greedy decoding.
    """
    stats = {"drafted": 0, "accepted": 0, "rounds": 0, "draft_s": 0.0,
             "verify_s": 0.0}
    for prompt in prompts:
        ids = tokenizer(prompt, return_tensors="pt").input_ids
        for _ in range(rounds):
            t0 = time.time()
            draft = greedy_ids(model, ids, draft_len, draft_keep, routers)
            stats["draft_s"] += time.time() - t0

            # one verification pass over prompt + drafted tokens
            t0 = time.time()
            cand = torch.cat([ids, torch.tensor(draft).reshape(1, -1)], dim=1)
            logits = model(cand, use_cache=False).logits[0]
            stats["verify_s"] += time.time() - t0

            # position i predicts token i+1; compare against the drafts
            start = ids.shape[1] - 1
            accepted = 0
            for i, tok in enumerate(draft):
                if int(logits[start + i].argmax()) == tok:
                    accepted += 1
                else:
                    break
            # the model's own token at the first mismatch is always correct
            correction = int(logits[start + accepted].argmax())
            stats["drafted"] += len(draft)
            stats["accepted"] += accepted
            stats["rounds"] += 1
            keep = draft[:accepted] + [correction]
            ids = torch.cat([ids, torch.tensor(keep).reshape(1, -1)], dim=1)
    return stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--draft-keep", type=int, nargs="+", default=[1, 2],
                    help="experts per layer during drafting")
    ap.add_argument("--draft-len", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=6)
    ap.add_argument("--threads", type=int, default=4)
    args = ap.parse_args()

    torch.set_num_threads(args.threads)
    tok = load_tokenizer(args.model)
    model = load_model(args.model, device="cpu")
    n_exp, routers = find_router_modules(model)
    topk = getattr(model.config, "num_experts_per_tok", None)
    print(f"экспертов на слой: {n_exp}, штатный top-k: {topk}, "
          f"найдено роутеров: {len(routers)}")
    if not routers:
        raise SystemExit("роутеры не найдены — модель не MoE или иная раскладка")

    prompts = [
        "The warehouse report shows that the total number of laptops in stock is",
        "def compute_average(values):\n    if not values:\n        return 0\n    ",
        "Краткий вывод по отчёту о складских остатках:",
    ]
    for keep in args.draft_keep:
        s = measure_acceptance(model, tok, prompts, routers, draft_keep=keep,
                               draft_len=args.draft_len, rounds=args.rounds)
        acc = s["accepted"] / max(s["drafted"], 1)
        per_round = s["accepted"] / max(s["rounds"], 1)
        # bytes saved: drafting reads keep/topk of the experts; verification
        # reads the union once for (per_round + 1) tokens
        ratio = (keep / topk) if topk else 1.0
        print(f"\ntop-{keep} черновик, длина {args.draft_len}:")
        print(f"  принято {s['accepted']}/{s['drafted']} = {acc:.3f} "
              f"({per_round:.2f} токена за раунд + 1 бесплатный)")
        print(f"  чтение черновика от полного: {ratio:.2f}x")
        print(f"  время: черновик {s['draft_s']:.1f} с, проверка "
              f"{s['verify_s']:.1f} с")
        print(f"  токенов за раунд: {per_round + 1:.2f} против 1 у обычного декода")


if __name__ == "__main__":
    main()
