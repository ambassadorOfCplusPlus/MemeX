# smartstock local AI stack (2026-09-12)

Local AI-serving stack for the "smartstock" app on the fixed box:
**RX 6500 XT 4GB (Vulkan only) / i3-10100F 4c8t / 32GB RAM**, single user, no hardware upgrade coming.

Built on the fork `D:/MemeX/src/ik_llama.cpp`, binaries in `build-bt2022/bin/Release`.
Everything below was VERIFIED with a real request on this box. `llama-server` version `4938 (7348a440)`.

---

## 0. What had to be built

The fork's `build-bt2022` tree shipped only `llama-cli`, `llama-memex-fwd`, `llama-quantize` —
**`llama-server` was not built** (`LLAMA_BUILD_SERVER:BOOL=OFF` in the CMake cache). The server
source is fully present (`examples/server`, incl. `function_calls.hpp`, qwen3/kimi/deepseek tool
parsers, embeddings, and `mtmd` multimodal).

Fix (done): reconfigure with the flag ON, then build the chain (Vulkan already ON):
```
cmake -S D:/MemeX/src/ik_llama.cpp -B D:/MemeX/src/ik_llama.cpp/build-bt2022 -DLLAMA_BUILD_SERVER=ON
# then via the project's build script (takes the machine lock, verifies startability):
pwsh -File bench/build_safe.ps1 -Targets llama-server,llama-embedding
```
Result: `llama-server.exe` (8.0 MB) and `llama-embedding.exe` (1.9 MB) built and startable.
(Note: `build_safe.ps1` had one transient parallel-build failure mid-`ggml`; a plain
`cmake --build ... --target ggml --target llama --target llama-server --target llama-embedding`
succeeded. If it fails once, just re-run.)

Confirmed server capabilities: `/v1/chat/completions`, `/v1/embeddings`, JSON-schema/grammar
constraints, native tool-calling (needs `--jinja`), and `--mmproj` vision (mtmd.dll present).

---

## 1. THE KEY HARDWARE FINDING — run on CPU, not the GPU

The RX 6500 XT has a tiny host-visible VRAM heap (small-BAR, no Resizable-BAR), so the fork's
Vulkan backend logs `prosil host-visible, poluchil tolko device-local: zapis ... cherez submit s
ozhidaniem` and falls back to submit-with-wait for buffer writes. **Decode collapses even with all
layers offloaded.** Measured, qwen3-4b Q4_K_M, 160-tok generation after warmup:

| config                        | prompt tok/s | decode tok/s |
|-------------------------------|-------------:|-------------:|
| Vulkan, all 37/37 layers on GPU |         ~17 |     **2.68** |
| **CPU (`-ngl 0`)**              |         ~38 |     **7.72** |
| llama-3.2-3b Q4_K_M, CPU        |         ~10 |    **10.13** |

**=> The stack runs on CPU (`-ngl 0`). Adding GPU layers on this card is measurably slower.**
Do not "optimize" by offloading to VRAM here. (If ReBAR ever becomes available, re-measure; the
GPU path would then be worth revisiting. The project's own `memex-fwd` engine gets its 13-19 tok/s
figures through a different path, not `llama-server`.)

The "≤3.5GB fits VRAM whole" note still holds physically (3824 MiB free measured), but fit is not
the bottleneck — write bandwidth to VRAM is. VRAM is left for a possible future SmolVLM experiment.

---

## 2. Roles, models, and VERIFIED commands

All servers: bind `127.0.0.1`, CPU (`-ngl 0`). Port 8080 is taken by another local service on this
box — the stack uses **18080 (chat)** and **18081 (embeddings)**.

### (a) CHAT  — qwen3-4b  ✔ verified
`qwen3-4b-q4_k_m.gguf` is the primary chat model: good quality AND it doubles as the tool-calling
model (the fork only parses tool calls for models whose name contains `qwen3`). Use `/no_think` in
the prompt to skip the thinking block for latency.
```
llama-server.exe -m D:/smartstock/models/qwen3-4b-q4_k_m.gguf -a qwen3-4b \
  -ngl 0 -c 4096 --host 127.0.0.1 --port 18080 --jinja
```
Verified request/response:
```
POST /v1/chat/completions  {"model":"qwen3-4b","messages":[{"role":"user",
  "content":"In one short sentence, what is a stock keeping unit (SKU)? /no_think"}],"max_tokens":80}
-> "A stock keeping unit (SKU) is a unique identifier used to track individual items in a retail
    or manufacturing environment."   (7.7 tok/s decode)
```
Faster alternative if you don't need tools on the same port: **llama-3.2-3b** (10.1 tok/s) or
phi-4-mini. Keep qwen3-4b for the tool endpoint.

### (b) EMBEDDINGS — bge-m3  ✔ verified
```
llama-server.exe -m D:/smartstock/models/bge-m3-q8.gguf -a bge-m3 \
  --embedding -ngl 0 -c 512 --host 127.0.0.1 --port 18081
```
Verified:
```
POST /v1/embeddings  {"model":"bge-m3","input":"Wireless bluetooth headphones, over-ear, noise cancelling"}
-> data[0].embedding, length = 1024  (real float vector, e.g. -0.0377, 0.0148, -0.0547, ...)
```
`multilingual-e5-small-Q8_0.gguf` (384-dim) is the lighter fallback for the same role.

### (c) FUNCTION-CALLING — qwen3-4b + `--jinja`  ✔ verified
The server rejects a `tools` param without `--jinja` (`"tools param requires --jinja flag"`).
With `--jinja` on a qwen3-named model, tool calls are parsed into the OpenAI `tool_calls` shape.
Same server as (a). Verified:
```
POST /v1/chat/completions  (model=qwen3-4b, one tool get_stock_level{sku,warehouse})
  user: "How many units of SKU RED-SHOE-42 are in the warehouse? Use the tool. /no_think"
-> finish_reason "tool_calls",
   tool_calls[0].function.name = "get_stock_level"
   tool_calls[0].function.arguments = {"sku":"RED-SHOE-42","warehouse":"default"}
```
Dedicated FC models on disk (`xLAM-2-3B-fc-r`, `Arch-Function-3B`, `hammer2.1-*`) are NOT
auto-parsed by the fork (name-gated to qwen3/kimi-k2/deepseek-r1). To use one anyway, constrain the
output with a request-level `json_schema`/`grammar` (model-agnostic) and parse it yourself. qwen3-4b
native tools is simpler and is what's wired in — prefer it.

---

## 3. Orchestration — run chat + embeddings together

Script: **`bench/smartstock_serve.ps1`** (starts both detached, waits for `/health`, writes PIDs to
`D:/smartstock/run/servers.pids`, logs to `D:/smartstock/run/srv_*.log`).
```
pwsh -File bench/smartstock_serve.ps1          # start chat(18080, --jinja) + embeddings(18081)
pwsh -File bench/smartstock_serve.ps1 -Stop    # stop both
pwsh -File bench/smartstock_serve.ps1 -UseLock # take the machine lock first (when agents share box)
```
VERIFIED both up at once: chat returned `STACK OK`, embeddings returned a 1024-dim vector, `-Stop`
killed both cleanly. RAM with both loaded on CPU is a few GB of 32GB — comfortable.
Defaults (CPU, ports, models) are params at the top of the script.

---

## 4. Follow-up: VLM (SmolVLM-256M)  — command ready, not yet verified

Vision is supported via `--mmproj` (mtmd). SmolVLM-256M is tiny (175MB model + 103MB mmproj) so it
can sit on its own port. Exact command:
```
llama-server.exe -m D:/smartstock/models/SmolVLM-256M-Instruct-Q8_0.gguf \
  --mmproj D:/smartstock/models/mmproj-SmolVLM-256M-Instruct-Q8_0.gguf \
  -a smolvlm -ngl 0 -c 4096 --host 127.0.0.1 --port 18082
```
Then POST `/v1/chat/completions` with a content array mixing text and an `image_url` whose `url` is a
`data:image/...;base64,<...>` string (the server requires base64-encoded, not remote URLs). Being
tiny, SmolVLM is a candidate to try on Vulkan (`-ngl 99`) too — measure both. Left as follow-up per
the task; use it for product-photo tagging / shelf-image checks in smartstock.

---

## Role summary

| role              | model (file)                        | port  | flags                     | verified |
|-------------------|-------------------------------------|-------|---------------------------|:--------:|
| chat              | qwen3-4b-q4_k_m.gguf                 | 18080 | `-ngl 0 --jinja`          | ✔ 7.7 t/s |
| chat (faster alt) | llama-3.2-3b-instruct-q4_k_m.gguf    | 18080 | `-ngl 0`                  | ✔ 10.1 t/s |
| embeddings        | bge-m3-q8.gguf                       | 18081 | `-ngl 0 --embedding`      | ✔ dim 1024 |
| function-calling  | qwen3-4b (same as chat)             | 18080 | `-ngl 0 --jinja` + `tools`| ✔ tool_call |
| vision (later)    | SmolVLM-256M + mmproj               | 18082 | `-ngl 0 --mmproj ...`     | cmd ready |

Binaries: `D:/MemeX/src/ik_llama.cpp/build-bt2022/bin/Release/llama-server.exe` (also
`llama-embedding.exe` as a standalone embeddings CLI fallback).
