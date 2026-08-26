# What the full scheme is worth: static on the card, as many popular experts as fit beside it, the
# rest on the CPU in parallel.
#
# Every term here is measured rather than assumed, and the ones that are not are named as such:
#
#   24.8 GB/s   host bandwidth, measured (1.804 GB / 72.7 ms on the 30B, matching to three digits)
#   131 GB/s    device bandwidth, measured on this card (peak 138)
#   177 us      one per-layer rendezvous, measured - latency-bound, independent of size
#   31 us       one kernel dispatch, measured
#   hit rates   from the router trace: C experts per layer resident gives these hits
#                 C=8 54%, C=12 67%, C=16 76%, C=24 87%, C=32 92%, C=48 95%, C=64 96%
#               interpolated in between, and capped at 96% because the trace never showed better
#
# The schedule is what turns bytes into time, and it is not a single sum. Attention must finish
# before the router runs, so the CPU is idle through it; the two halves of the MoE do overlap.
# Layers are strictly sequential, so nothing overlaps across them.

import sys
sys.path.insert(0, '.')
from traffic import read, TN, BLK
import os

HOST, DEV = 24.8, 131.0
RENDEZVOUS_US, DISPATCH_US = 177.0, 31.0
VRAM_MB = 3980.0
MB = 1024.0 ** 2

# Measured hit rate against experts resident per layer.
HITS = [(8, .542), (12, .671), (16, .762), (24, .870), (32, .918), (48, .953), (64, .964)]

def hit_rate(c, n_expert):
    if c <= 0: return 0.0
    if c >= n_expert: return 1.0
    if c <= HITS[0][0]:  return HITS[0][1] * c / HITS[0][0]
    for (a, ha), (b, hb) in zip(HITS, HITS[1:]):
        if c <= b: return ha + (hb - ha) * (c - a) / (b - a)
    return min(0.964 + (c - 64) * 0.0005, 0.99)

def plan(path, ctx):
    kv, ts = read(path)
    g = lambda s: next((v for k, v in kv.items() if k.endswith(s)), None)
    L = g('.block_count'); nexp = g('.expert_count') or 0; used = g('.expert_used_count') or 0
    hk_arr = g('.attention.head_count_kv'); hk = hk_arr[0] if isinstance(hk_arr, list) else hk_arr
    h = g('.attention.head_count'); h = h[0] if isinstance(h, list) else h
    ne = g('.embedding_length'); hd = g('.attention.key_length') or (ne // h if h else 0)
    hd_swa = g('.attention.key_length_swa') or hd
    swa_pat = g('.attention.sliding_window_pattern'); swa_win = g('.attention.sliding_window') or 0

    att = head = rout = other = exps = 0
    names = {nm for nm, *_ in ts}
    for nm, dims, tt, off, sz in ts:
        if sz < 0: continue
        if   'exps' in nm:                              exps += sz
        elif 'attn' in nm or 'ssm' in nm:               att += sz
        elif 'gate_inp' in nm:                          rout += sz
        elif nm.startswith('output.'):                  head += sz
        elif 'token_embd' in nm:                        pass
        else:                                           other += sz
    per_exp = exps / max(1, L * nexp)
    ex_traf = L * used * per_exp
    static  = att + head + rout + other

    kvb = 0
    for il in range(L or 0):
        if f'blk.{il}.attn_k.weight' not in names: continue
        heads = hk_arr[il] if isinstance(hk_arr, list) and il < len(hk_arr) else hk
        win = bool(swa_pat[il]) if isinstance(swa_pat, list) and il < len(swa_pat) else False
        d = hd_swa if win else hd
        span = min(ctx, swa_win) if (win and swa_win) else ctx
        kvb += 2 * heads * d * 2 * span

    base_ms = 1000.0 * (static + ex_traf + kvb) / MB / 1024 / HOST

    left_mb = VRAM_MB - (static + kvb) / MB
    if left_mb < 0:
        return dict(name=os.path.basename(path), fits=False, base=base_ms,
                    need=(static + kvb) / MB)
    n_res = int(left_mb * MB / max(1.0, per_exp))
    c = n_res / max(1, L)
    hr = hit_rate(c, nexp)

    # attention: card reads its weights and the whole cache; the CPU has nothing to do here,
    # because the router that picks the experts runs after attention.
    t_attn = 1000.0 * (att + kvb) / MB / 1024 / DEV
    # MoE: both sides at once, so the slower one sets the time.
    t_moe = max(1000.0 * (ex_traf * hr) / MB / 1024 / DEV,
                1000.0 * (ex_traf * (1 - hr)) / MB / 1024 / HOST)
    t_head = 1000.0 * (head + rout) / MB / 1024 / DEV
    t_rv = L * RENDEZVOUS_US / 1000.0
    # Dispatches are the term most likely to be underestimated: roughly ten per layer for
    # attention and three for the MoE, and at one token each is a separate small kernel.
    t_disp = L * 13 * DISPATCH_US / 1000.0
    total = t_attn + t_moe + t_head + t_rv + t_disp
    return dict(name=os.path.basename(path), fits=True, base=base_ms, total=total,
                n_res=n_res, c=c, hr=hr, t_attn=t_attn, t_moe=t_moe, t_head=t_head,
                t_rv=t_rv, t_disp=t_disp, left=left_mb, static=static/MB, kv=kvb/MB)

for path in sys.argv[1:]:
    print(f"\n=== {os.path.basename(path)}")
    for ctx in (2048, 16384):
        r = plan(path, ctx)
        if not r['fits']:
            print(f"  -c {ctx:6d}: statika+KV = {r['need']:.0f} MB > {VRAM_MB:.0f} MB - ne vlezaet celikom")
            continue
        print(f"  -c {ctx:6d}: na karte statika {r['static']:.0f} + KV {r['kv']:.0f} MB,"
              f" ostatok {r['left']:.0f} MB = {r['n_res']} ekspertov ({r['c']:.0f} na sloj,"
              f" popadanij {100*r['hr']:.0f}%)")
        print(f"           vnimanie {r['t_attn']:5.1f} + MoE {r['t_moe']:5.1f}"
              f" + golova {r['t_head']:4.1f} + randevu {r['t_rv']:4.1f}"
              f" + zapuski {r['t_disp']:4.1f} = {r['total']:5.1f} ms")
        print(f"           {1000/r['total']:5.1f} tok/s   protiv bazy {1000/r['base']:.1f}"
              f"  ({r['base']/r['total']:.1f}x)")
