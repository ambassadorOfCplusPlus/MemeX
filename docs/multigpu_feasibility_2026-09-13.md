# Multi-GPU feasibility — verdict (2026-09-13)

## TL;DR
The custom fast path (our speed moat) is **intrinsically single-GPU** and cannot be made
multi-GPU without destroying the very thing that makes it fast. Multi-GPU / CUDA for
**production** is already available through the **stock `ggml_backend_sched` path** that the
fork inherits (used by `llama-cli` / `llama-server`); the `memex-fwd` fast path simply opts
out of it. Recommendation: do **not** force multi-GPU into the fast path; for multi-GPU /
server targets use the inherited stock offload. The only "real" generalization worth a look
later is routing the custom optimizations through `ggml_backend_sched` — large, and
**unverifiable on the single-GPU dev box**.

## Why the moat is single-device (evidence)
There is no `memex::FullGpu` class. The fast path = **`GpuStatic`** (head + attn/router/dense
+ KV; `gpu_static.hpp:319`) + **`GpuExperts`** (resident MoE; `gpu_experts.hpp:235`), spliced
as `ggml_map_custom` nodes into a **CPU** main graph (`mp.n_gpu_layers=0`,
`memex-fwd.cpp:5604/6794`; `ggml_backend_cpu_init` `:5638/7697`).

- **Device 0 hardcoded**: `ggml_backend_vk_init(0)` (`gpu_static.cpp:349`, `gpu_experts.cpp:740`);
  buffer types from device 0 (`:351`, `:742`). Backend/buft are **scalar** members, no device
  list/array (`gpu_static.hpp:548-549`, `gpu_experts.hpp:388-389`). `vkEnumeratePhysicalDevices`
  is used only for diagnostics and always reduced to `devs[0]`.
- **Single-submit crossing is the moat, and it is one-device**: `ggml_backend_graph_compute(be_, gf)`
  per graph (`gpu_static.cpp:528/899/2493`, `gpu_experts.cpp:1679`) with `GGML_VK_SUBMIT_DIVISOR=1`
  (`memex-fwd.cpp:6590-6598`) collapsing each whole layer graph into **one queue submit on one
  device**. Splitting a graph across devices reintroduces exactly the per-op host↔device crossings
  the design exists to eliminate.
- **Everything typed to the one device**: weights (`gpu_static.cpp:235/1161`, `gpu_experts.cpp:487`),
  KV + delta-state (`gpu_static.cpp:1149-1161/1140`), pinned readback buffers
  (`gpu_static.cpp:544/2465`, `gpu_experts.cpp:1708`). Capacity = single-VRAM fit
  (`gpu_experts.cpp:753-834`; `hw_caps` `choose_strategy` gates on the single largest heap). Both
  modules deliberately share **one** cached `vk_device` (one command pool / queue / staging buffer).
- **Latent multi-GPU bug**: `hw_caps.cpp:133-153` selects a *discrete* GPU for measurement, but
  `ggml_backend_vk_init(0)` always takes ordinal 0 — on a 2-GPU box the caps can describe a
  different physical device than the fast path actually runs on.

## Verdict
The single-device assumption is **load-bearing, not incidental**. Multi-GPU inside the fast path =
give up the moat.

## Production answer (multi-hardware scope)
The fork **retains the full stock multi-device + CUDA scheduler** (`ggml_backend_sched`) used by
`llama-cli` / `llama-server`: `tensor-split` / `-ngl` / `main-gpu` / `split-mode` already do
multi-GPU and CUDA. So "multi-GPU support" for production means **shipping/enabling the stock path**
on those targets; our fast path is a weak-single-GPU specialization that is simply not engaged in
that config.

## Options
1. **(recommended, low risk)** Treat multi-GPU / CUDA as the stock path's job. Verify the stock
   offload builds and runs in our fork on a CUDA / multi-GPU target (cannot be verified on the dev
   box). Keep our custom flags single-GPU-only and guarded.
2. **(large, later)** Generalize the custom optimizations to compose with `ggml_backend_sched` so
   head/experts can live across devices — the roadmap "CUDA / multi-card via backend-sched" item.
   Per-token cross-device crossings would likely erase the moat for **split** models, **but
   replication** (whole model resident per GPU, parallel batches/requests) could scale **throughput**
   without splitting a single token — the right multi-GPU story for a server (throughput), distinct
   from single-stream latency.
3. **Scaffold-only untested multi-GPU in the fast path** — NOT recommended (unverifiable here, and
   architecturally fights the moat).

## Validation
Unverifiable on the single-GPU dev box except stock device enumeration. Any multi-GPU speed claim
needs real 2-GPU hardware and must carry the usual anti-cheat proof (coherent output + regression).
