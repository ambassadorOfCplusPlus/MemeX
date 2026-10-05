# Heavy-hitter / bounded KV cache — design (2026-09-13)

User's idea: keep attention **sinks** (first N tokens, full) + a **recent window** (last W, full) + a
dynamic set of **heavy-hitter** tokens (high attention mass) at full fidelity, **evict the rest**.
This is the H2O / Scissorhands / SnapKV family. It is **lossy** → strictly opt-in (default OFF),
quality-measured. It helps ONLY long-context (>=8k) on **dense-KV** archs (gemma4, qwen3moe, small
dense); NOT deepseek (MLA already compresses KV) and NOT short contexts (KV tiny).

## What we already have (build on, don't duplicate)
- **SWA ring-cache** (`examples/memex-fwd/gpu_static.cpp:965-1014`, env `MEMEX_SWA_RING`, default ON):
  for sliding-window layers the KV cache is a **ring** of size `GGML_PAD(max_swa + layer_width + 64, 32)`;
  once it wraps, the oldest position is overwritten. This is eviction **by recency**, and only for SWA
  layers (gemma4 has ~25/35 sliding layers; the ~1/6 GLOBAL layers still keep full KV).
- **Attention sinks** (`ggml_soft_max_add_sinks` / gpt-oss) — first tokens kept.
So sinks + recency-eviction already exist for SWA layers. Heavy-hitter is: **evict by importance
instead of by age, and target the GLOBAL-attention layers whose KV grows unbounded with context.**

## The decisive constraint: attention scores are INVISIBLE under flash-attention
gemma4 attention is `ggml_flash_attn_ext` with `GGML_ASSERT(cparams.flash_attn)` (build_gemma4.cpp:171,361).
Flash-attention **fuses QK^T -> softmax -> xV in one kernel and never materializes the softmax weight
matrix** — that is its whole point (O(n) memory). The heavy-hitter importance signal *is* those softmax
weights (per-query distribution over KV). So under flash-attn the signal does not exist as a tensor.

Consequences:
- **H2O (accumulate attention mass every decode token) is impractical here.** It needs the per-token
  score distribution on every step → an unfused attention pass (or a per-token n_head x n_kv readback)
  each token → destroys decode speed and fights exactly the fused single-crossing the engine is built on.
- **SnapKV (select once, at end of prefill) is the viable design.** The prompt is processed in one
  prefill; run ONE **unfused** attention pass there (the `!flash_attn` branch already exists,
  build_gemma4.cpp:39, and is the CPU/reference path) to obtain per-KV attention mass over the last
  ~W_obs prompt queries, select the KV to keep, drop the rest, then **decode with flash-attn over the
  bounded cache**. The expensive unfused step happens once, not per token.

## Proposed design (SnapKV-style, GLOBAL layers only)
Per global-attention layer, budget `B = N_sink + H_heavy + W_recent`:
1. **Prefill selection.** At end of prompt prefill, for each global layer compute an importance score
   per KV position = summed softmax weight over the last `W_obs` (e.g. 32) prompt query rows
   (SnapKV's "observation window"; optional 1-D pooling over positions to keep local clusters intact).
   Source of the scores = the unfused attention pass. Do NOT touch SWA layers (their ring already bounds KV).
2. **Compaction.** Keep positions = first `N_sink` (sinks) ∪ top-`H_heavy` by score (excluding sinks and
   the recent window) ∪ last `W_recent` (recent). Physically compact the global-layer K/V buffers to those
   `B` slots and record a slot→original-position map (needed for RoPE position ids at decode).
3. **Decode.** Append new tokens into the bounded global cache (evict lowest-score non-sink, non-recent
   slot when full — cheap, no new scores needed since decode reuses the prefill ranking + recency). SWA
   layers unchanged (ring). Attention stays flash-attn over `B` positions.

State to add: per-global-layer score array + slot→pos map + the compacted K/V (fits in the existing
single-device buffers, since B << n_kv at long ctx). Positions feed RoPE and the KQ mask as today.

## Correctness & measurement (mandatory)
- **Default OFF = bit-identical.** New flags default to no-op (full KV, flash-attn unchanged); the token
  regression and every `--decode-check` must stay 16/16 with the feature off.
- **Quality when ON.** Measure on a fixed long text: (a) perplexity vs full-KV at 8k and 16k; (b) our
  argmax-divergence (`--decode-check` style) vs a full-KV reference over N generated tokens. Target e.g.
  `< 2%` first-flip rate at budget `B = n_kv/4`. Sweep B to find the near-lossless knee (SnapKV reports
  ~50-75% KV cut near-lossless on many tasks; verify on OUR models, don't assume).
- **Flags (all default OFF):** `--kv-budget N` (0=off), `--kv-sinks N` (e.g. 4), `--kv-recent W`
  (e.g. 512), `--kv-obs W_obs` (32). Gate to global-attention layers; refuse loudly on archs where the
  unfused pass is unavailable.

## Effort & honest verdict
- **Effort:** moderate, ~300-500 lines — the unfused prefill score pass (reuse the `!flash_attn` branch),
  per-global-layer selection + compaction + slot→pos map, decode-time bounded append, flags + measurement
  harness. Contained to the attention/KV path of the global layers; SWA ring untouched.
- **Where it helps:** ONLY >=8k context on global-attention dense-KV layers — lets long context fit in
  4 GB VRAM and cuts per-token attention cost. gemma4 benefits modestly (mostly SWA already bounded, only
  ~1/6 layers global); **qwen3moe benefits most** (all-global attention → KV grows unbounded). deepseek:
  no (MLA). Short ctx: no.
- **Recommendation:** **do it as a gated R&D item, but AFTER the Option-B correct features** — it is lossy,
  helps only a regime (>=8k) that is not the main use case on this box, and needs a real quality sweep to
  justify a budget. The SnapKV (prefill-time) variant is the ONLY sane one here; do NOT attempt H2O's
  per-decode score accumulation (it fights flash-attn and the single-crossing moat). If the user has a
  concrete long-context need (e.g. large-doc RAG in smartstock), promote it; otherwise it stays queued.

Next concrete step if pursued: prototype the unfused prefill score pass for qwen3moe (all-global, biggest
win), select+compact at B=n_kv/4, measure perplexity + decode-divergence at 8k/16k vs full-KV. Gate OFF.
