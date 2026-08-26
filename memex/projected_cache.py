"""MemeX two-tier KV cache, correctness-first CPU implementation.

Takes a filled HF cache and rewrites it in place:
  [sinks | notebook (exact, important) | compressed tail (rank-r projection) | exact window]

Compression = projection of flattened (kv_heads*head_dim) K/V rows onto the
top-r principal subspace computed by transplant.py. Attention math afterwards
is the donor's own (we hand it the reconstructed cache), so any quality drop
is attributable purely to the rank-r approximation — the phase-0 hypothesis test.

Notebook v0 is training-free (H2O-style): tokens that accumulated the most
attention mass during prefill keep their exact full-rank KV.
"""
import torch

from .transplant import get_layer_kv


def project_rows(x, basis, rank):
    """Rank-r reconstruction of rows of x [T, D] using orthonormal basis [D, D]."""
    u = basis[:, :rank].to(x.dtype)
    return (x @ u) @ u.T


@torch.no_grad()
def compress_cache(pkv, basis_k, basis_v, rank, window, sinks=4,
                   notebook_idx=None, zero_tail=False):
    """Rewrite the cache in place. notebook_idx: per-layer LongTensor of absolute
    positions to keep exact. zero_tail=True ablation = StreamingLLM-like drop."""
    n_layers = len(basis_k)
    stats = {"tail_tokens": 0, "kept_exact": 0}
    for li in range(n_layers):
        k, v = get_layer_kv(pkv, li)
        T = k.shape[2]
        lo, hi = sinks, T - window
        if hi <= lo:
            continue
        keep = torch.zeros(T, dtype=torch.bool, device=k.device)
        if notebook_idx is not None and len(notebook_idx[li]) > 0:
            keep[notebook_idx[li].to(k.device)] = True
        idx = torch.arange(lo, hi, device=k.device)
        idx = idx[~keep[idx]]
        if idx.numel() == 0:
            continue
        for tensor, basis in ((k, basis_k[li]), (v, basis_v[li])):
            rows = tensor[0, :, idx, :].transpose(0, 1).reshape(idx.numel(), -1)
            new = torch.zeros_like(rows) if zero_tail else project_rows(rows, basis, rank)
            h, d = tensor.shape[1], tensor.shape[3]
            tensor[0, :, idx, :] = new.reshape(idx.numel(), h, d).transpose(0, 1)
        stats["tail_tokens"] += int(idx.numel())
        stats["kept_exact"] += int(keep[lo:hi].sum())
    return stats


@torch.no_grad()
def prefill_with_salience_notebook(model, input_ids, budget, head, sinks=4,
                                   window=512, keep_cache=True):
    """Notebook selected by the learned future-salience predictor (plan §2.8).

    One plain prefill (no attention matrices needed): score every mid-zone
    token by the ridge head applied to its hidden state, keep the top `budget`.
    Returns (per-layer notebook idx — identical across layers, cache).
    """
    out = model(input_ids, use_cache=keep_cache, output_hidden_states=True)
    pkv = out.past_key_values if keep_cache else None
    h = out.hidden_states[-1][0].float()
    del out
    T = input_ids.shape[1]
    lo, hi = sinks, T - window
    hn = (h - head["mu"]) / head["sd"]
    scores = torch.cat([hn, torch.ones(len(hn), 1)], dim=1) @ head["W"]
    n_layers = model.config.num_hidden_layers
    zone = scores[lo:hi]
    if zone.numel() == 0 or budget == 0:
        return [torch.empty(0, dtype=torch.long)] * n_layers, pkv
    top = torch.topk(zone, min(budget, zone.numel())).indices + lo
    return [top] * n_layers, pkv


@torch.no_grad()
def query_aware_restore(model, ids, pkv, snap, budget, sinks=4, window=512,
                       probe_len=32):
    """Query-time top-k retrieval from the compressed tail (Quest/DSA-style).

    The compressed cache still supports *approximate* scoring: re-running the
    last `probe_len` prompt tokens against it shows which tail positions the
    current query cares about. Those positions are then restored to full rank
    from the master copy (`snap`, i.e. RAM), so the tokens that matter are exact
    while everything else stays low-rank. Unlike a write-time notebook this sees
    the actual query — which is legitimate, because at read time the query
    exists.

    Returns (cache, positions restored per layer).
    """
    T = snap[0][2]
    if hasattr(pkv, "crop"):
        pkv.crop(T - probe_len)
    out = model(ids[:, T - probe_len :], past_key_values=pkv, use_cache=True,
                output_attentions=True)
    pkv = out.past_key_values
    lo, hi = sinks, T - window
    restored = 0
    for li, att in enumerate(out.attentions):        # [1, heads, probe, T]
        score = att[0].sum(dim=(0, 1))[lo:hi]
        if score.numel() == 0 or budget == 0:
            continue
        top = torch.topk(score, min(budget, score.numel())).indices
        k, v = get_layer_kv(pkv, li)
        k_ref, v_ref, _ = snap[li]
        k[:, :, top + lo, :] = k_ref[:, :, top, :].to(k.dtype)
        v[:, :, top + lo, :] = v_ref[:, :, top, :].to(v.dtype)
        restored = max(restored, int(top.numel()))
    del out
    return pkv, restored


@torch.no_grad()
def snapshot_midzone(pkv, sinks, window):
    """Clone only the compressible zone of every layer (one copy per case),
    so conditions can be evaluated by restore-then-compress instead of
    deep-copying the whole cache each time."""
    snap = []
    li = 0
    while True:
        try:
            k, v = get_layer_kv(pkv, li)
        except (IndexError, AttributeError):
            break
        T = k.shape[2]
        lo, hi = sinks, T - window
        snap.append((k[:, :, lo:hi, :].clone(), v[:, :, lo:hi, :].clone(), T))
        li += 1
    return snap


@torch.no_grad()
def restore_midzone(pkv, snap, sinks, window):
    """Undo compression and drop any tokens appended by a previous generation."""
    if hasattr(pkv, "crop"):
        pkv.crop(snap[0][2])
    for li, (k_ref, v_ref, T) in enumerate(snap):
        k, v = get_layer_kv(pkv, li)
        lo, hi = sinks, T - window
        k[:, :, lo:hi, :] = k_ref
        v[:, :, lo:hi, :] = v_ref


@torch.no_grad()
def causal_h2o_notebook(model, input_ids, budget, sinks=4, window=512,
                        local=128):
    """Honest (causal) H2O: score a token only by attention it received from the
    `local` tokens that followed it — information available at the moment it
    leaves the exact window, with NO access to the later question.

    Computed on independent sliding windows of 2*local tokens (cheap: attention
    matrices stay [heads, local, 2*local]), then aggregated over layers/heads.
    """
    T = input_ids.shape[1]
    scores = torch.zeros(T)
    for start in range(0, T, local):
        q_lo, q_hi = start, min(start + local, T)
        w_lo = max(0, q_lo - local)
        if q_hi <= q_lo:
            break
        seg = input_ids[:, w_lo:q_hi]
        out = model(seg, output_attentions=True, use_cache=False)
        off = q_lo - w_lo
        for att in out.attentions:                     # [1, h, S, S]
            a = att[0].sum(0)                          # [S(q), S(k)]
            recv = torch.tril(a[off:], diagonal=off - 1).sum(0)
            scores[w_lo:q_hi] += recv
        del out
    lo, hi = sinks, T - window
    n_layers = model.config.num_hidden_layers
    zone = scores[lo:hi]
    if zone.numel() == 0 or budget == 0:
        return [torch.empty(0, dtype=torch.long)] * n_layers
    top = torch.topk(zone, min(budget, zone.numel())).indices + lo
    return [top] * n_layers


@torch.no_grad()
def prefill_with_notebook_probe(model, input_ids, budget, sinks=4, window=512,
                                probe_len=256):
    """Single prefill that also yields H2O-style importance. Prefills all but
    the last probe_len tokens, then forwards the probe chunk with attentions on
    (memory stays [heads, probe, T] per layer, not [heads, T, T]).

    Returns (notebook_idx per layer, full prefilled cache)."""
    T = input_ids.shape[1]
    split = max(T - probe_len, 1)
    out1 = model(input_ids[:, :split], use_cache=True)
    pkv = out1.past_key_values
    del out1
    out2 = model(input_ids[:, split:], past_key_values=pkv, use_cache=True,
                 output_attentions=True)
    pkv = out2.past_key_values          # now contains all T tokens
    lo, hi = sinks, T - window
    result = []
    for att in out2.attentions:          # [1, heads, probe, T]
        mass = att[0].sum(dim=(0, 1))    # [T]
        zone = mass[lo:hi]
        if zone.numel() == 0 or budget == 0:
            result.append(torch.empty(0, dtype=torch.long))
            continue
        top = torch.topk(zone, min(budget, zone.numel())).indices + lo
        result.append(top)
    del out2
    return result, pkv


@torch.no_grad()
def eval_perplexity_with_cache(model, ids, pkv, start):
    """Teacher-forced NLL of ids[start:] continuing from a (possibly compressed)
    cache that already contains ids[:start]."""
    nll, count = 0.0, 0
    cur = pkv
    for pos in range(start, ids.shape[1] - 1):
        out = model(ids[:, pos : pos + 1], past_key_values=cur, use_cache=True)
        cur = out.past_key_values
        logp = torch.log_softmax(out.logits[0, -1].float(), dim=-1)
        nll -= float(logp[ids[0, pos + 1]])
        count += 1
    return nll / max(count, 1)


@torch.no_grad()
def generate_with_cache(model, tokenizer, ids, pkv, max_new_tokens=12):
    """Greedy generation continuing from a prefilled (possibly compressed) cache.

    The cache is cropped to T-1 so the final prompt token is re-run against it
    (rather than appended twice), which keeps the first prediction exact.
    """
    cur = pkv
    if hasattr(cur, "crop"):
        cur.crop(ids.shape[1] - 1)
    out = model(ids[:, -1:], past_key_values=cur, use_cache=True)
    cur = out.past_key_values
    next_id = out.logits[0, -1].argmax().reshape(1, 1)
    generated = [int(next_id)]
    for _ in range(max_new_tokens - 1):
        out = model(next_id, past_key_values=cur, use_cache=True)
        cur = out.past_key_values
        next_id = out.logits[0, -1].argmax().reshape(1, 1)
        generated.append(int(next_id))
        if generated[-1] == tokenizer.eos_token_id:
            break
    return tokenizer.decode(generated)
