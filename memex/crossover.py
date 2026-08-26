# Kogda nasha shema luchshe vygruzki celyh sloev, i gde porog.
#
# Two ways to use a card that cannot hold the model:
#
#   WHOLE LAYERS (-ngl N). The card owns layers 0..N-1 entirely and must hold ALL their experts,
#   because any of the 128 may be routed to. One handoff per token, at the boundary. Dispatch cost
#   is N x 43 nodes: every node of those layers runs on the card.
#
#   OURS. The card owns the static half of EVERY layer - attention, head, router - plus as many
#   popular experts as fit. The CPU owns the rest of the experts. A rendezvous per layer, and
#   roughly 15 card-side nodes per layer.
#
# The measured terms, all of them:
#   24.8 GB/s host, 131 GB/s device
#   27.24 us marginal cost of one graph node   <- measured this run, and it is the term that decides
#   17.4 us submit+fence
#   ~177 us host-side rendezvous (worker thread wakeup, mutex, condvar - NOT the submit)
#
# The dispatch number is what makes this question sharp. At 5 us per node ours would win almost
# everywhere. At 27 us the two schemes trade: whole layers touch fewer layers so they launch fewer
# kernels, ours touches every layer so it launches more - but ours covers the static half, which is
# 47% of the traffic and needs no experts resident at all.

HOST, DEV = 24.8, 131.0
NODE_US, SUBMIT_US, RV_US = 27.24, 17.4, 177.0
NODES_LAYER_ALL = 43      # counted from build_step in memex-fwd.cpp
NODES_LAYER_OURS = 15     # attention + head/router + the card's expert slice
MB = 1.0

# Qwen3-Coder-30B-A3B mx1, measured off the file
L, NEXP, USED = 48, 128, 8
ATT_L   = 510.4 / L       # attention weights per layer
EXP_MB  = 2.39            # one expert
HEAD    = 243.4 + 48.0    # output head + router, read once per token
KV_TOK  = 96.0 / 1024.0   # MB per occupied context token

HITS = [(0,0.0),(8,.542),(12,.671),(16,.762),(24,.870),(32,.918),(48,.953),(64,.964),(128,1.0)]
def hit(c):
    for (a,ha),(b,hb) in zip(HITS, HITS[1:]):
        if c <= b: return ha + (hb-ha)*(c-a)/max(1e-9,(b-a))
    return 1.0

def cpu_only(ctx):
    b = 510.4 + HEAD + L*USED*EXP_MB + KV_TOK*ctx
    return b/1024.0/HOST*1000.0

def whole_layers(vram, ctx):
    """-ngl N. Each offloaded layer needs all its experts plus its KV."""
    per_layer = ATT_L + NEXP*EXP_MB + KV_TOK*ctx/L
    n = min(L, int(vram / per_layer))
    if n <= 0: return None
    dev_b = n*(ATT_L + USED*EXP_MB + KV_TOK*ctx/L)
    host_b = (L-n)*(ATT_L + USED*EXP_MB + KV_TOK*ctx/L) + HEAD
    t = dev_b/1024.0/DEV*1000.0 + host_b/1024.0/HOST*1000.0
    t += n*NODES_LAYER_ALL*NODE_US/1000.0
    t += RV_US/1000.0                      # one handoff at the boundary
    return t, n

def ours(vram, ctx):
    """Static everywhere + as many popular experts as fit."""
    fixed = 510.4 + HEAD + KV_TOK*ctx
    if vram < fixed: return None
    left = vram - fixed
    c = min(NEXP, (left/EXP_MB)/L)
    hr = hit(c)
    dev_b = 510.4 + HEAD + KV_TOK*ctx + L*USED*EXP_MB*hr
    host_b = L*USED*EXP_MB*(1-hr)
    # attention is serial with the MoE; the two expert halves overlap
    t_att = (510.4 + KV_TOK*ctx)/1024.0/DEV*1000.0
    t_moe = max(L*USED*EXP_MB*hr/1024.0/DEV, host_b/1024.0/HOST)*1000.0
    t = t_att + t_moe + HEAD/1024.0/DEV*1000.0
    t += L*NODES_LAYER_OURS*NODE_US/1000.0
    t += L*RV_US/1000.0
    return t, c, hr

for ctx in (2048, 16384):
    print(f"\n=== kontekst {ctx}, baza na CPU {cpu_only(ctx):.1f} ms = {1000/cpu_only(ctx):.1f} tok/s")
    print(f"  {'VRAM':>6} {'celye sloi':>22} {'nashe':>26}   luchshe")
    for vram in (1000, 2000, 3000, 3980, 6000, 8000, 12000, 16000, 24000):
        w = whole_layers(vram, ctx); o = ours(vram, ctx)
        ws = f"{1000/w[0]:5.1f} tok/s ({w[1]} sloev)" if w else "      ne vlezaet"
        os_ = f"{1000/o[0]:5.1f} tok/s ({o[1]:.0f}/sloj, {100*o[2]:.0f}%)" if o else "        ne vlezaet"
        if w and o:   best = "nashe" if o[0] < w[0] else "celye sloi"
        elif o:       best = "nashe"
        elif w:       best = "celye sloi"
        else:         best = "-"
        print(f"  {vram:5} MB {ws:>22} {os_:>26}   {best}")

# Where exactly do they cross, as a share of the model held in VRAM?
full = 510.4 + HEAD + L*NEXP*EXP_MB
print(f"\nves modeli celikom {full/1024:.1f} GB")
for ctx in (2048, 16384):
    prev = None
    for v in range(200, 30000, 25):
        w, o = whole_layers(v, ctx), ours(v, ctx)
        cur = (o is not None and (w is None or o[0] < w[0]))
        if prev is not None and cur != prev:
            print(f"  ctx {ctx:5}: perelom pri {v} MB VRAM = {100.0*v/full:.1f}% modeli"
                  f"  -> dalshe luchshe {'nashe' if cur else 'celye sloi'}")
        prev = cur
