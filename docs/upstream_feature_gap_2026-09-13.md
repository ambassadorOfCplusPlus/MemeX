# Upstream feature-gap survey — MemeX fork vs llama.cpp / ik_llama.cpp / ktransformers

Date: 2026-09-13
Scope: **read-only survey, no code changes, no builds.** Goal: find capabilities in upstream llama.cpp / ik_llama.cpp and in ktransformers that our fork LACKS, categorized by the **hardware tier** each one benefits (production now targets more than the user's weak box).

## Hardware tiers

- **T1 — weak AMD/Vulkan + weak CPU** (the user's box): RX 6500 XT 4 GB, **RDNA2, Vulkan-only** (no CUDA/ROCm, no cooperative-matrix WMMA); i3-10100F 4c/8t Comet Lake (AVX2, **no AVX-512/AMX**); 32 GB; SSD+HDD. Small dense ≤4B fully on card; big MoE with experts on CPU/SSD.
- **T2 — mid consumer GPU**: e.g. RTX 3060/4070 (CUDA) or RDNA3 8–16 GB (Vulkan + WMMA/coopmat). Model fits mostly/entirely in VRAM.
- **T3 — server NVIDIA**: A100/H100/L40S, CUDA + tensor cores. Marlin/CUDA-graph/FlashInfer/ktransformers GPU kernels are **first-class here**, not skipped.
- **T4 — CPU-heavy / big-RAM**: Sapphire/Emerald Rapids (**AMX**), dual-socket **NUMA**, 256 GB+. Big MoE mostly in RAM, attention on a modest GPU (the ktransformers sweet spot).

CUDA-only and AMX-only items are IN scope but tagged so they are only compiled on their target.

---

## 1. What the fork ALREADY has (verified by grep in D:\MemeX\src\ik_llama.cpp)

Custom MemeX path `examples/memex-fwd/` (bespoke single-arch, own-graph engine; never calls `llama_decode`; CLI/batch only, **no server**):
- Full-GPU static path: `gpu_static.*` — `--gpu-static`, `--gpu-static-layers/-dense/-width/-verify/-reserve` (this is the "`--gpu-full`" path; there is no literal `--gpu-full` flag).
- GPU expert dispatch: `gpu_experts.*` — `--gpu-experts[-check/-reserve]`.
- SSD/RAM expert offload: `expert_store.*` — `--expert-store[-auto/-repack/-reserve]`; resident RAM store `resident_set.*`.
- **Expert prefetch already present**: `--expert-prefetch`, `--prefetch-budget`, `--prefetch-sync`, `--hdd-lead` (R1-correction-file driven).
- **Speculative already present in the real decode path**: `--model-draft`, `--draft-max`, `--draft-check` (dense qwen3 draft), plus draft KV types `-ctkd/-ctvd`.
- Zoned KV cache: `--zoned`, `--sinks`, `--window`. Chat template applied (`--chat/--system`); **no tool/function-call parsing inside memex-fwd** (fork-wide `common/chat-*` auto-parser infra exists, but the custom path doesn't use it).

Inherited / kept current from llama.cpp — all **PRESENT** (so NOT gaps):
- Samplers: min-p, top-n-sigma, XTC, DRY, mirostat 1&2, typical-p, TFS_Z, dynatemp.
- Grammar: GBNF (`src/llama-grammar.*`) + json-schema-to-grammar + LLGuidance + PEG chat auto-parser.
- Server (`examples/server/`): `/completion`, `/embedding`, `/v1/embeddings`, `/infill`, `/slots` (+save/restore/erase), `/lora-adapters` (hot-swap), `/props`, `/metrics`, `/v1/chat/completions`, `/v1/responses`; function calling (`function_calls.hpp`, `deepseek_r1_tools.hpp`).
- KV-quant: `-ctk/-ctv` (+ fork extras `-ctk-first/-last`, draft variants).
- Context: context-shift (default on), self-extend `-gan/-gaw`, RoPE `--rope-scaling` + full YaRN.
- LoRA hot-load: `--lora[-scaled]`, `--lora-init-without-apply`, runtime `/lora-adapters`.
- State: `--prompt-cache[-all/-ro]`, save-load-state, server `--slot-save-path`.
- Arch registry (`src/llama-arch.*`) incl. **MLA** (`-mla`), and the fork archs: DEEPSEEK4/2, OPENAI_MOE (gptoss), PHI3, QWEN3MOE/QWEN35MOE/QWEN3NEXT, GEMMA/2/3/4(+MTP), GLM4_MOE, DFLASH, etc.
- Backends: **RPC** (`--rpc`), **Vulkan** (`ggml-vulkan.cpp` + coopmat1 FA shader `flash_attn_cm1.comp`), **CUDA graphs** (`ggml-cuda/graph.cuh`), **FlashAttention-CUDA** (full `fattn-*` incl mma-f16 for Ampere+), **tensor-split / multi-GPU** (`--split-mode`, `tensor_split`), **basic NUMA** (`--numa`), **continuous batching** (`--parallel`, `-np`, `cont_batching`).
- ik_llama CPU strength we already inherit: iqk AVX2 GEMM + IQ-K quants + fused-MoE — ahead of mainline for CPU-side MoE.

Net: the fork is close to upstream parity plus ik extras. Genuine gaps are few and concentrated in (a) two CUDA/AMX server kernels, (b) rerank/router server ergonomics, (c) deeper predictive-prefetch than the current `--hdd-lead`.

---

## 2. Port candidates — categorized by tier

Benefit is per-tier (H/M/L; "—" = not applicable / no benefit on that tier). Effort S/M/L. "Build" = special build target needed.

| # | Candidate | Source | What it does | T1 weak-AMD | T2 mid-GPU | T3 srv-NVIDIA | T4 CPU/RAM | Effort | Default-safe | Build |
|---|-----------|--------|--------------|:--:|:--:|:--:|:--:|:--:|:--:|--|
| P1 | **kt-style locality-aware expert prefetch + prefill semantic preload** (beyond current `--hdd-lead`) | ktransformers | predict next-layer/next-token experts, overlap SSD/RAM load with compute; at prefill preload only domain-relevant experts | **H** | L | — | **H** | M–L | opt-in→default | any |
| P2 | **AMX expert GEMM kernels** | ktransformers / llamafile | tile-based bf16/int8 matmul for expert FFN on AMX CPUs | — | — | M (host) | **H** | L | auto by cpuid | AMX CPU |
| P3 | **Marlin / Machete quantized GEMM (CUDA)** | llama.cpp/vLLM lineage | high-throughput 4-bit tensor-core GEMM; big decode/prefill speedup on Ampere+ | — | M (NVIDIA) | **H** | — | L | auto on CUDA | CUDA |
| P4 | **Vulkan coopmat2 path** (`flash_attn_cm2` + coopmat2 matmul) | llama.cpp | cooperative-matrix kernels for RDNA3/NVIDIA Vulkan; big GPU-matmul win | — (RDNA2 lacks WMMA) | **H** (RDNA3/NV) | L | — | M | auto by device caps | Vulkan |
| P5 | **/v1/rerank endpoint** | llama.cpp | cross-encoder rerank over existing embedding path; unlocks RAG serving | **M** | M | M | M | S | default-safe | any |
| P6 | **Model router / swap server** (`--models` + LRU eviction) | llama.cpp | serve several models from one process, evict LRU; switch small-dense ↔ MoE without restart | M | M | **H** (multi-tenant) | M | M | opt-in | any |
| P7 | **NUMA-aware expert placement** (beyond `--numa` distribute) | ktransformers | pin experts + threads per socket, local-alloc, avoid cross-QPI expert reads | — | — | M | **H** | M | opt-in | dual-socket |
| P8 | **FlashInfer-style paged/batched attention** | FlashInfer | paged-KV + batched-prefill attention for high concurrency | — | L | **H** (serving) | — | L | opt-in | CUDA |
| P9 | **Tool/function-call parsing inside memex-fwd** | llama.cpp (fork infra) | wire the existing `common/chat-*` auto-parser into the custom decode path | M | M | M | M | M | opt-in | any |
| P10 | **CUDA-graph coverage for MoE/expert graph** (extend beyond current dense use) | llama.cpp | capture expert-dispatch subgraph to cut launch overhead at low batch | — | M (NVIDIA) | **M** | — | M | opt-in | CUDA |
| P11 | **Selective expert *unload* / residency eviction policy** (LRU on ExpertStore) | ktransformers idea | bound RAM by evicting cold experts; complements P1 | **M** | L | — | M | S–M | opt-in | any |

Present-already, no action: samplers, grammar/JSON-schema, KV-quant, embeddings/infill/slots, LoRA hot-load, prompt-cache/state, context-shift/self-extend/YaRN, MLA, RPC, Vulkan coopmat1 FA, CUDA graphs (dense), FlashAttention-CUDA, tensor-split/multi-GPU, basic NUMA, continuous batching, **speculative decoding (incl. memex-fwd draft)**, **basic expert prefetch**.

---

## 3. ktransformers portable-vs-kernel verdict

| kt idea | Portability | Verdict |
|---------|-------------|---------|
| Locality-aware prefetch (decode) + semantic preload (prefill) | backend-agnostic | **Adopt (P1)** — top portable idea; benefits T1 and T4 most. |
| Compute-in-place experts (no expert movement to GPU) | already our design | Already how `expert_store` works — keep. |
| AMX expert kernels | AMX CPUs only | **Adopt for T4 (P2)**; irrelevant on T1's Comet Lake. |
| NUMA-aware placement | dual-socket only | **Adopt for T4 (P7)**. |
| GPU MoE kernels / CUDA-graph fusion | CUDA only | Fold into P3/P10 for T3; not portable to T1/T2-AMD. |
| Hot-experts-in-VRAM residency | needs VRAM headroom | T2/T3 only; on T1's 4 GB there is no room after static+KV. |

---

## 4. Per-tier top picks

**T1 — weak AMD/Vulkan + weak CPU (user's box):**
1. **P1 kt-style predictive expert prefetch** — the SSD/HDD expert-load latency is the dominant cost; deeper prediction than `--hdd-lead` is the single biggest lever here.
2. **P5 /v1/rerank** — cheap (reuses embeddings), small reranker fits the 4 GB card, unlocks RAG. Good quick win.
3. **P11 ExpertStore LRU eviction** — bounds the 32 GB RAM ceiling so bigger MoEs stay stable; pairs with P1.

**T2 — mid consumer GPU:**
1. **P4 Vulkan coopmat2** — large matmul/FA speedup on RDNA3 / NVIDIA-Vulkan; currently only coopmat1 present.
2. **P3 Marlin/Machete** (NVIDIA members of this tier) — 4-bit tensor-core GEMM throughput.
3. **P6 model router** — switch models without a reload on a single card.

**T3 — server NVIDIA:**
1. **P3 Marlin/Machete quant GEMM** — highest raw throughput gain; genuine absence today.
2. **P8 FlashInfer paged/batched attention** — concurrency + long-context serving.
3. **P6 model router + P10 MoE CUDA-graph** — multi-tenant serving ergonomics + launch-overhead cut.

**T4 — CPU-heavy / big-RAM (ktransformers sweet spot):**
1. **P2 AMX expert kernels** — the defining kt speedup for big-MoE-in-RAM; large win on Sapphire/Emerald Rapids.
2. **P7 NUMA-aware expert placement** — avoids cross-socket expert reads that otherwise halve throughput.
3. **P1 predictive prefetch** — same locality win, RAM-tier instead of SSD-tier.

---

## 5. Overall first-three (cross-tier, best benefit ÷ effort)

1. **P1 — kt-style predictive expert prefetch** (S/M–L, helps T1 **and** T4, default-safe once tuned): attacks the expert-load bottleneck that defines both the user's box and the big-RAM server tier; scaffolding (`--expert-prefetch`, `--hdd-lead`) already exists, so this is completion, not greenfield.
2. **P5 — /v1/rerank endpoint** (S, all tiers, default-safe): only real server gap that's cheap; reuses the embeddings path and gives RAG serving everywhere.
3. **P3 — Marlin/Machete quant GEMM** (L, T3, CUDA-build-gated): the one high-value *kernel* absence for the new production NVIDIA target; biggest throughput unlock where CUDA is available.

---
_Investigation only. No source modified, no build, no downloads. Presence/absence verified by direct grep of `D:\MemeX\src\ik_llama.cpp` plus a code-inventory subagent, 2026-09-13._
