"""Future-attention dataset collector (research flagship, plan §2.8).

For every token t in a chunk, records the total attention mass it receives
from FUTURE queries (q > t), aggregated over layers and heads — the free
supervision signal for training a write-policy predictor ("will this token
be needed later?"). Also stores the final hidden state per token (predictor
input candidate) and token ids.

Forward-only, eager attention, CPU. Shards saved to D:\\MemeX\\data\\future_attn.
"""
import argparse
import faulthandler
import os
import time

faulthandler.enable()

import torch
from transformers import AutoTokenizer

try:
    from .compat import load_model
except ImportError:
    from compat import load_model


@torch.no_grad()
def collect(model, tokenizer, text, out_dir, max_tokens=100_000, chunk_len=1024,
            shard_chunks=8):
    os.makedirs(out_dir, exist_ok=True)
    import gc
    ids = tokenizer(text, return_tensors="pt").input_ids[0][:max_tokens]
    n_chunks = len(ids) // chunk_len
    # resume: progress file records the last fully sharded chunk index
    prog_path = os.path.join(out_dir, "progress.txt")
    start_chunk = 0
    if os.path.exists(prog_path):
        with open(prog_path) as f:
            start_chunk = int(f.read().strip() or 0)
    existing = [f for f in os.listdir(out_dir) if f.startswith("shard_")]
    shard, shard_id, done = [], len(existing), 0
    if start_chunk:
        print(f"[futatt] resuming from chunk {start_chunk}", flush=True)
    t0 = time.time()
    for ci in range(start_chunk, n_chunks):
        chunk = ids[ci * chunk_len : (ci + 1) * chunk_len].unsqueeze(0).to(
            next(model.parameters()).device)
        out = model(chunk, output_attentions=True, output_hidden_states=True,
                    use_cache=False)
        T = chunk.shape[1]
        # future mass: attention received from future queries. "far" excludes
        # local neighbourhood (q <= t+local): inside the exact window the token
        # needs no notebook, so only distant demand matters for write policy.
        local = 128
        dev = chunk.device
        mass_all = torch.zeros(T, device=dev)
        mass_far = torch.zeros(T, device=dev)
        for att in out.attentions:                      # [1, h, T(q), T(k)]
            a = att[0].sum(0)                           # sum over heads
            # causal attention lives in the LOWER triangle (q >= k); a key k is
            # attended by queries q > k, i.e. row - col >= 1 -> tril(-1).
            mass_all += torch.tril(a, diagonal=-1).sum(0)
            mass_far += torch.tril(a, diagonal=-(1 + local)).sum(0)
        assert mass_all.sum() > 0, "labels are all zero - check triangle side"
        denom_all = torch.arange(T - 1, -1, -1, device=dev).clamp(min=1).float()
        denom_far = (denom_all - local).clamp(min=1)
        shard.append({
            "ids": chunk[0].to(torch.int32).cpu(),
            "future_mass": (mass_all / denom_all).to(torch.float16).cpu(),
            "future_mass_far": (mass_far / denom_far).to(torch.float16).cpu(),
            "hidden": out.hidden_states[-1][0].to(torch.float16).cpu(),
        })
        del out
        gc.collect()
        done += T
        if (ci + 1) % shard_chunks == 0 or ci == n_chunks - 1:
            torch.save(shard, os.path.join(out_dir, f"shard_{shard_id:04d}.pt"))
            shard, shard_id = [], shard_id + 1
            with open(prog_path, "w") as f:
                f.write(str(ci + 1))
        rate = done / max(time.time() - t0, 1e-9)
        print(f"[futatt] chunk {ci + 1}/{n_chunks}, tokens={done}, {rate:.0f} tok/s",
              flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=r"D:\MemeX\models\Qwen3-0.6B")
    ap.add_argument("--text", default=r"D:\MemeX\data\calibration.txt")
    ap.add_argument("--out", default=r"D:\MemeX\data\future_attn")
    ap.add_argument("--max-tokens", type=int, default=100_000)
    ap.add_argument("--chunk-len", type=int, default=1024)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--threads", type=int, default=4)
    args = ap.parse_args()

    torch.set_num_threads(args.threads)
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = load_model(args.model, device=args.device, attn="eager")
    with open(args.text, encoding="utf-8", errors="ignore") as f:
        text = f.read()
    collect(model, tokenizer, text, args.out,
            max_tokens=args.max_tokens, chunk_len=args.chunk_len)


if __name__ == "__main__":
    main()
