"""Scaled needle-in-a-haystack benchmark: donor full cache vs MemeX two-tier cache.

The needle is planted in the zone that gets compressed (beyond the exact window),
so this directly stress-tests the rank-r tail. Conditions:
  - full     : donor, untouched cache (upper bound)
  - rank-R   : tail projected to rank R
  - rank-R+nb: same plus training-free notebook (H2O attention-mass, exact KV)
  - zero     : tail zeroed (StreamingLLM-like lower bound)
"""
import argparse
import gc
import json
import os
import random
import sys
import time

import torch
from transformers import AutoTokenizer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from memex.compat import load_model, load_tokenizer
from memex.projected_cache import (causal_h2o_notebook, compress_cache,
                                   generate_with_cache,
                                   prefill_with_notebook_probe,
                                   prefill_with_salience_notebook,
                                   query_aware_restore, restore_midzone,
                                   snapshot_midzone)

FILLER = (
    "The old lighthouse keeper wrote careful notes about the weather every "
    "morning. Ships passed the rocky shore and the gulls circled above the "
    "waves while the wind carried salt across the cliffs. In the village the "
    "baker lit his ovens before dawn and the streets slowly filled with the "
    "smell of fresh bread. "
)


def build_case(tokenizer, total_tokens, depth_frac, passkey, distractors=0,
               rng=None):
    needle = f" Remember this: the secret passkey is {passkey}. Keep it safe. "
    question = "\nQuestion: What is the secret passkey? Answer: The secret passkey is"
    filler_ids = tokenizer(FILLER, add_special_tokens=False).input_ids
    reps = total_tokens // len(filler_ids) + 2
    hay = (filler_ids * reps)[:total_tokens]
    needle_ids = tokenizer(needle, add_special_tokens=False).input_ids
    q_ids = tokenizer(question, add_special_tokens=False).input_ids
    pos = int(len(hay) * depth_frac)
    ids = hay[:pos] + needle_ids + hay[pos:]
    rng = rng or random.Random(42)
    for _ in range(distractors):
        fake = (f" Note: the backup code is {rng.randint(10000, 99999)} and the "
                f"locker number is {rng.randint(100, 999)}. ")
        fids = tokenizer(fake, add_special_tokens=False).input_ids
        at = rng.randint(0, len(ids) - 1)
        ids = ids[:at] + fids + ids[at:]
    return torch.tensor(ids + q_ids).unsqueeze(0)


@torch.no_grad()
def run(args):
    torch.set_num_threads(args.threads)
    tokenizer = load_tokenizer(args.model)
    model = load_model(args.model, device=args.device, attn="eager")

    basis = torch.load(os.path.join(args.results, "kv_basis.pt"), weights_only=True)
    basis_k = [b.to(args.device) for b in basis["k"]]
    basis_v = [b.to(args.device) for b in basis["v"]]

    head = None
    head_path = os.path.join(args.futattn, "salience_head.pt")
    if os.path.exists(head_path):
        head = torch.load(head_path, weights_only=True)
        # A head trained on another model's hidden width cannot be applied here.
        want = model.config.hidden_size + 1
        got = head["W"].shape[0] if torch.is_tensor(head.get("W")) else None
        if got != want:
            print(f"[head] пропущена: обучена под hidden+1={got}, "
                  f"у этой модели {want} — политика 'pred' отключена", flush=True)
            head = None
        else:
            head = {k: (v.to(args.device) if torch.is_tensor(v) else v)
                    for k, v in head.items()}

    # (name, rank, notebook policy, zero_tail)
    # h2o-oracle peeks at the question (upper-bound reference only);
    # h2o-causal and pred are honest write-time policies.
    conditions = [("full", None, None, False)]
    for r in args.ranks:
        conditions.append((f"rank{r}", r, None, False))
        conditions.append((f"rank{r}+h2oC", r, "h2o_causal", False))
        if head is not None:
            conditions.append((f"rank{r}+pred", r, "pred", False))
        conditions.append((f"rank{r}+topk", r, "topk", False))
        if head is not None:
            conditions.append((f"rank{r}+pred+topk", r, "pred_topk", False))
        conditions.append((f"rank{r}+h2oORC", r, "h2o_oracle", False))
    conditions.append(("zero", 0, None, True))

    random.seed(0)
    cases = []
    for depth in args.depths:
        for _ in range(args.per_depth):
            cases.append((depth, str(random.randint(10000, 99999))))
    case_rng = random.Random(7)

    # incremental, resumable log: one JSON object per (case, condition)
    log_path = os.path.join(args.results, "needle_log.jsonl")
    done = set()
    if os.path.exists(log_path):
        with open(log_path) as f:
            for line in f:
                try:
                    r = json.loads(line)
                    done.add((r["case"], r["cond"]))
                except json.JSONDecodeError:
                    pass
        print(f"[resume] {len(done)} results already logged", flush=True)

    for ci, (depth, passkey) in enumerate(cases):
        pending = [c for c in conditions if (ci, c[0]) not in done]
        if not pending:
            continue
        ids = build_case(tokenizer, args.haystack, depth, passkey,
                         distractors=args.distractors,
                         rng=case_rng).to(args.device)
        need = {c[2] for c in pending}
        nb_pred = nb_causal = None
        if "pred" in need and head is not None:
            nb_pred, _ = prefill_with_salience_notebook(
                model, ids, budget=args.notebook, head=head, sinks=args.sinks,
                window=args.window, keep_cache=False)
            gc.collect()
        if "h2o_causal" in need:
            nb_causal = causal_h2o_notebook(model, ids, budget=args.notebook,
                                            sinks=args.sinks, window=args.window)
            gc.collect()
        nb_h2o, pkv = prefill_with_notebook_probe(
            model, ids, budget=args.notebook, sinks=args.sinks,
            window=args.window, probe_len=args.probe_len)
        gc.collect()
        snap = snapshot_midzone(pkv, args.sinks, args.window)
        for name, rank, nb_policy, zero in pending:
            nb = {"h2o_oracle": nb_h2o, "pred": nb_pred,
                  "h2o_causal": nb_causal}.get(nb_policy)
            if nb_policy == "pred_topk":
                # half the notebook so the total exactness budget matches others
                nb = [t[: args.notebook // 2] for t in nb_pred]
            t0 = time.time()
            restore_midzone(pkv, snap, args.sinks, args.window)
            if rank is not None:
                compress_cache(pkv, basis_k, basis_v, rank, args.window,
                               sinks=args.sinks, notebook_idx=nb,
                               zero_tail=zero)
            if nb_policy in ("topk", "pred_topk"):
                # equal exactness budget: split it when a notebook is also used
                budget = args.notebook if nb_policy == "topk" else args.notebook // 2
                pkv, _ = query_aware_restore(
                    model, ids, pkv, snap, budget, sinks=args.sinks,
                    window=args.window, probe_len=args.topk_probe)
            ans = generate_with_cache(model, tokenizer, ids, pkv,
                                      max_new_tokens=8)
            ok = bool(passkey in ans)
            rec = {"case": ci, "depth": depth, "cond": name, "ok": ok,
                   "answer": ans.strip()[:40]}
            with open(log_path, "a") as f:
                f.write(json.dumps(rec) + "\n")
            print(f"[case {ci} d={depth}] {name:>14}: "
                  f"{'OK ' if ok else 'FAIL'} ({time.time()-t0:.0f}s) -> {ans.strip()[:30]!r}",
                  flush=True)
            gc.collect()
        del pkv, snap, nb_h2o, nb_pred, nb_causal
        gc.collect()

    # summarize whatever is logged
    tally, seen_cases = {}, set()
    with open(log_path) as f:
        for line in f:
            r = json.loads(line)
            tally.setdefault(r["cond"], []).append(r["ok"])
            seen_cases.add(r["case"])
    print(f"\n=== Needle accuracy ({len(seen_cases)} cases) ===")
    for name, *_ in conditions:
        v = tally.get(name, [])
        if v:
            print(f"{name:>14}: {sum(v)}/{len(v)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=r"D:\MemeX\models\Qwen3-0.6B")
    ap.add_argument("--results", default=r"D:\MemeX\results")
    ap.add_argument("--haystack", type=int, default=3000)
    ap.add_argument("--window", type=int, default=512)
    ap.add_argument("--sinks", type=int, default=4)
    ap.add_argument("--notebook", type=int, default=64)
    ap.add_argument("--ranks", type=int, nargs="+", default=[64, 256])
    ap.add_argument("--depths", type=float, nargs="+", default=[0.2, 0.5])
    ap.add_argument("--per-depth", type=int, default=2)
    ap.add_argument("--distractors", type=int, default=0)
    ap.add_argument("--futattn", default=r"D:\MemeX\data\future_attn")
    ap.add_argument("--probe-len", type=int, default=64)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--topk-probe", type=int, default=32)
    run(ap.parse_args())


if __name__ == "__main__":
    main()
