# phi3 full-GPU offload — implementation blueprint

Status: **blueprint** (multi-day change, needs build + regression 16/16 + VRAM tuning after the
machine frees). Author agent: phi3-full-gpu. Base engine: `examples/memex-fwd/` on branch
`agent/phi3-full-gpu`.

---

## 0. The problem in one paragraph

phi3-mini (2.4 GB Q4) runs **CPU-only** in our engine at ~12.4 tok/s. Stock llama.cpp with
`-ngl 99` puts the whole 2.4 GB in the 4 GB VRAM and reaches ~30–40 tok/s on the same RX 6500 XT
(Vulkan). Our engine only offloads the **head** for phi3 (`head_matmul` -> `GpuStatic::head`); the
32 dense transformer layers stay on CPU, reading 2.4 GB from system RAM every token. The 3x gap is
exactly the bytes-per-token difference: CPU reads the whole model over the ~25 GB/s memory bus,
the GPU reads it over 131 GB/s VRAM once it is resident.

---

## 1. How the engine computes today (the surface we change)

- Weights are loaded through the public fork API: `llama_model_load_from_file` (memex-fwd.cpp:6417,
  6565), i.e. **host tensors, mmap-backed, on the CPU**. `collect_phi3` (memex-fwd.cpp:913) just
  grabs pointers to them.
- Every graph is built onto **one backend buffer type**, always the CPU one:
  `buft = ggml_backend_cpu_buffer_type()` (memex-fwd.cpp:6455, 8589), then computed with
  `ggml_backend_graph_compute(be, gf)` where `be = ggml_backend_cpu_init()`. There are ~10 such
  compute sites in the decode/verify/zoned/resident loops (memex-fwd.cpp:5095, 5146, 5194, 6486,
  8681, 9407, 10086, 10162, 10282, 10295, 10515, 10620, 10783).
- `build_phi3_step` (memex-fwd.cpp:2916) builds the graph out of **plain ggml ops only**:
  `get_rows, mul_mat, rms_norm (fnorm), rope_multi, view/cont/permute/reshape, cpy, soft_max_ext,
  silu, mul, add`. Every one of these has a Vulkan kernel in this tree (ggml-vulkan.cpp: 81 hits
  for RMS_NORM/ROPE/vk_init alone; mul_mat/soft_max/silu/cpy/get_rows all present). **There is no
  custom fused op** — the fused QKV and fused gate|up are done with `ggml_view_2d`+`ggml_cont`,
  which are ordinary ops. This is the single most important fact for feasibility: the phi3 graph is
  already 100% Vulkan-expressible, unchanged.
- `GpuStatic` (gpu_static.hpp/.cpp) is a **side-channel offload**: it holds chosen weights resident
  in Vulkan buffers and splices device results into the CPU graph through `ggml_map_custom` nodes
  (`head()` -> `head_op`/`do_head`/`block`; `layer()` -> `layer_op`/`do_layer`). Each such node is
  one **host<->device rendezvous** (~177 us fixed, measured; see gpu_static.hpp:24–35). The head is
  1 rendezvous per token; the layer path is **1 rendezvous per layer per token**.
- Vulkan is compiled in only under `MEMEX_FWD_GPU_EXPERTS` (the `build-vk` tree). The
  single-Vulkan-buffer ceiling is `suballocation_block_size` = **1024 MiB** default
  (ggml-vulkan.cpp:3443), capped by `max_memory_allocation_size` (:3445).

---

## 2. Feasibility verdict

**Yes — phi3-mini can realistically reach ~30 tok/s through our engine, and the right path is to run
the WHOLE phi3 graph on the Vulkan backend with weights + KV resident in VRAM. This is Option B
below. Extending `gpu_static`'s layer path (Option A) is the WRONG shape for a model that fits.**

### Why extending gpu_static (the layer path) is wrong here

`GpuStatic::layer()` was built for **non-fitting MoE** (Qwen3-30B-A3B): it keeps the residual stream
on the host and returns `[ffn_inp, ffn-normed hidden, router logits]` so the host can run the expert
dispatch and the residual add (gpu_static.hpp:379–400). Two disqualifying consequences for phi3:

1. **It keeps the FFN on the host.** For a dense phi3 there is no router; the FFN *is* the work
   (fused `ffn_up` [3072->16384] + `ffn_down` [8192->3072] — the biggest matmuls per layer). The
   layer abstraction deliberately leaves those on CPU. That is the exact 2.4 GB/token we are trying
   to get off the memory bus. Moving only attention leaves >half the traffic on CPU.
2. **1 rendezvous per layer.** 32 layers x 177 us = **5.66 ms/token of host coordination floor**
   (~176 tok/s ceiling) *before* any upload/readback, and the calls are synchronous with no overlap
   (the Vulkan backend implements none of ggml's async iface — gpu_static.hpp:43–51). For the 30B
   MoE this still wins (weights do not fit at all); for a fitting dense model it is pure overhead
   versus keeping the residual on the device.

The whole-graph path pays **1 rendezvous per token** (upload token ids+positions+mask, run all 32
layers on device, read back logits). That is what `-ngl 99` does and why stock is 3x faster.

### Why plain Vulkan-backend compute, not ggml_backend_sched

`ggml_backend_sched` (present, ggml-backend.cpp) is the general tool that assigns each op to a
backend and inserts cross-backend copies. It is the correct tool **when some ops fall back to CPU**.
phi3 has **zero** such ops — every op has a Vulkan kernel — so we do not need the scheduler's op
partitioning at all. We need only:

- weights resident on the device (sched does *not* do this for you; a weight is a leaf input and
  sched would copy it to the compute backend **every** graph unless it already lives in a device
  buffer — that is the whole reason llama.cpp allocates weights into the GPU buffer at load time),
- the graph allocated on the Vulkan buffer type,
- `ggml_backend_graph_compute(be_vk, gf)`.

So the scheduler buys nothing over a direct `be_vk` compute for phi3, and it adds a second way for
the weight-residency question to go wrong. **Recommendation: direct Vulkan-backend compute.** Keep
`ggml_backend_sched` in reserve as the generalization for a future arch that has a Vulkan-missing op
(e.g. delta-net/SSM_CONV — Vulkan has none of those, gpu_static.hpp comments confirm), where sched's
CPU fallback is the *point*. For phi3 it is not.

### VRAM budget (the one real constraint — needs tuning + measurement)

- Weights ~2.4 GB (Q4). Largest single tensor is the fused `ffn_up` (~25 MiB Q4) and `token_embd`/
  `output` (~64 MiB) — **all far under the 1024 MiB per-buffer ceiling**, so no head-style row-split
  is needed; allocate per-layer buffers (~40 MiB each) like `gpu_static`'s `ctxs_l_/bufs_l_`.
- KV is the tight part. phi3-mini is **MHA (n_head_kv = 32, head_dim 96, n_layer 32)**:
  `2 * n_layer * n_head_kv * head_dim * 2 B ≈ 0.75 MiB/token` (F16). At 2048 ctx = 1.5 GB; at 4096 =
  3.0 GB. So **weights 2.4 + KV 1.5 + graph scratch ≈ 4.0 GB at ctx 2048** — fits a 4 GB card only
  with a modest context. Levers if it does not fit at the target ctx: cap n_ctx (~2048), F16 stays
  but consider the existing SWA/ring machinery is N/A (phi3 is full attention), or Q8/Q4 KV. This is
  the item that **must be measured** — do not assume the default 4k ctx fits.
- Note the BAR trap (gpu_static.hpp:66–82): any device buffer that is **<= 256 MiB** may be typed
  onto the 256 MiB BAR heap and then read at 3.1 GB/s while still reporting device-local. Per-layer
  weight buffers at ~40 MiB are under 256 MiB and are therefore **at risk**. Two clean options,
  both proven in `gpu_static`: (a) group several layers per buffer so each buffer clears 256 MiB, or
  (b) pad each buffer past 256 MiB (`d_pad_`/`kv_pad_` pattern). Grouping is preferred (no dead
  VRAM). The KV buffer(s) must likewise clear 256 MiB or share a >256 MiB buffer with weights, as
  `gpu_static` already does for its layer path (gpu_static.hpp:621–626).

---

## 3. Implementation plan (Option B)

The change reuses `build_phi3_step` **verbatim for graph topology** — only the tensors' backend
changes. New machinery is confined to (a) a weight-residency helper, (b) a KV allocation on the VK
buffer type, (c) choosing `be_vk`/`buft_vk` at the phi3 decode sites. Gate everything behind a new
flag `--gpu-full` (phi3 only for v1) so the CPU path stays bit-exact and available.

### 3.1 New module: `Phi3Gpu` (a resident full-model, one class)

Add `phi3_gpu.hpp/.cpp` (or fold into `gpu_static.cpp` next to the existing VK plumbing to reuse
`ggml_backend_vk_init(0)` device caching and the BAR/verify helpers). Responsibilities:

```
class Phi3Gpu {
  bool init(const HParams& h, const Phi3Weights& host_w, int n_kv_max, std::string* err);
  // Allocates VK backend + buffer type. Uploads every phi3 weight to device buffers,
  // grouped so each buffer clears 256 MiB (BAR) and none exceeds 1024 MiB. Allocates
  // device KV (F16) in a buffer that also clears 256 MiB. Produces device_weights():
  // a Phi3Weights whose tensors are the DEVICE copies, same field names/shapes.
  const Phi3Weights& device_weights() const;   // fed to build_phi3_step instead of host w
  Cache&             device_kv();               // K/V tensors on the VK buffer type
  ggml_backend_t     backend() const;           // be_vk, for ggml_backend_graph_compute
  ggml_backend_buffer_type_t buft() const;      // buft_vk, for the graph arena
  bool verify(std::string* err) const;          // optional byte-compare vs host tensors
};
```

Upload path is exactly `GpuStatic::alloc_head`/`alloc_layers`: create a ggml context sized for the
group, `ggml_backend_alloc_ctx_tensors_from_buft(ctx, buft_vk)`, then
`ggml_backend_tensor_set(dst, host->data, 0, ggml_nbytes)` per tensor. The `_R*` repack guard from
`GpuStatic::init` (gpu_static.hpp:326–331) applies verbatim: refuse an interleaved weight by name
rather than discover a wrong answer. The engine already defaults repack to experts-only, so phi3
dense weights are plain-quantised and uploadable directly (no GGUF re-read).

### 3.2 Graph: reuse build_phi3_step unchanged

`build_phi3_step(g, buft_vk, h, phi3gpu.device_weights(), phi3gpu.device_kv(), ...)`. Because it
allocates the graph arena on `buft` and references whatever weight/KV tensors it is handed, passing
the VK buffer type + device weights + device KV makes the **entire** graph live on the device. No
line of `build_phi3_step` changes. (The one thing to check at build time: `Cache::init` must accept
`buft_vk` — it already takes a `buft` argument, memex-fwd.cpp:6459.)

### 3.3 Compute: `be_vk` at the phi3 decode sites

At the phi3 decode/prefill sites, compute with `phi3gpu.backend()` instead of the CPU `be`. Inputs
(`g.tokens/positions/mask`) are set with `ggml_backend_tensor_set` exactly as today (they land in
the graph arena, now VK; the writes take the host-visible/BAR memcpy path). Logits are read with
`ggml_backend_tensor_get(g.logits, ...)` — one readback per token. Cleanest integration: thread an
optional `ggml_backend_t compute_be` through the phi3 decode path (default = CPU `be`), set to
`phi3gpu.backend()` when `--gpu-full` is on. This localizes the change to the phi3 branch and leaves
all other archs on CPU.

### 3.4 Flag + refusal wiring (mirror the existing gpu-static guards)

- New `--gpu-full` (name TBD; keep distinct from `--gpu-static`). v1: **phi3 only**; every other
  arch refuses by name at the same spot the gpu-static list refuses (memex-fwd.cpp:8106), with the
  same loud-refusal discipline the file insists on.
- `--gpu-full` and `--gpu-static`/`--gpu-experts` are **mutually exclusive** for v1: two VK contexts
  sharing one cached `vk_device` is the exact hazard documented at memex-fwd.cpp:7316–7333. Refuse
  the combination up front.
- Under `#ifndef MEMEX_FWD_GPU_EXPERTS`, refuse `--gpu-full` with the same "built without Vulkan"
  message as memex-fwd.cpp:7303–7309.

### 3.5 Bit-exactness posture

Full-GPU is **not** bit-exact vs CPU f32 decode (device matmul order differs — same reason the
gpu-static head is validated by row-comparison, not bit-equality). So `--gpu-full` is the
**flag-gated alternative** the task allows, not a silent replacement. Regression 16/16 for phi3 must
be run **CPU path unchanged** (proves no regression to the default) **and** `--gpu-full` compared
against CPU logits row-wise within tolerance (the `verify()` hook + a `--gpu-full-check` mirroring
`--gpu-experts-check`). The token-level 16/16 check should still pass on `--gpu-full` because greedy
argmax over near-identical logits is stable; if a token differs, that is the signal to inspect, not
to relax the check.

---

## 4. Concrete task list (for the build-enabled session)

1. `phi3_gpu.hpp/.cpp` (or a `gpu_static.cpp` section): VK backend init, grouped weight upload
   (BAR-clear, <=1024 MiB/buffer), device KV alloc, `device_weights()`, `verify()`.
2. Thread an optional `compute_be`/`compute_buft` through the phi3 decode + prefill path; default
   CPU, `--gpu-full` -> VK.
3. `build_phi3_step` call sites: pass `buft_vk` + device weights + device KV when `--gpu-full`.
4. Flag parse + refusals (arch != phi3; combo with gpu-static/experts; no-Vulkan build).
5. `--gpu-full-check`: row-compare device logits vs CPU for the first token.
6. **Build in `build-vk` (GGML_VULKAN=ON).** Then:
   - regression **16/16 phi3 CPU** (default path unregressed),
   - regression **16/16 phi3 `--gpu-full`** (+ `--gpu-full-check` row tolerance),
   - **measure tok/s** at ctx 2048 and record peak config per the benchmark peak-config rule.
7. VRAM tuning: confirm weights+KV+scratch fit at the target ctx; if not, cap ctx / quantise KV.

## 5. Expected result

One rendezvous/token, 2.4 GB read from 131 GB/s VRAM instead of ~25 GB/s RAM. That is the same
arithmetic that gives stock ~30–40 tok/s; we should land in the same band (>=30 tok/s), closing the
3x gap. If we land short, the first suspects are (a) a weight buffer that slipped under 256 MiB into
the BAR window (check the placement report), and (b) KV not resident / read back per layer.

---

## 6. Note on the worktree base

`agent/phi3-full-gpu` branches from `7348a440`, which **predates the phi3 port** — the phi3 code
(`build_phi3_step`, `Phi3Weights`, `collect_phi3`, `arch_phi3_model`, the gpu-static phi3 head
allowance) lives only in the **uncommitted working tree** of the `memex` checkout (5 files,
+1328 lines, `git diff --stat HEAD`). Before any code lands on this branch, that phi3 work must be
committed (or the branch rebased onto a commit that contains it). This blueprint depends on that
base; it does not itself require it, which is why it is committed here first.
