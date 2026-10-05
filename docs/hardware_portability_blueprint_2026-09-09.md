# Блюпринт портируемости железа memex-fwd (9 сент) — CUDA/мульти-карта/разные CPU

Агент-разведка по реальному исходнику `D:\MemeX\src\ik_llama.cpp`. Все номера строк реальны.

## Ключевой вывод: арх-форварды портируемы ПОЧТИ ДАРОМ
- Все 5 build_*_step — чистые ggml-ops, аллоцируются через параметризованный buft
  (`ggml_gallocr_new(buft)` + `alloc_ctx_tensors_from_buft`), НО исполняются на ЖЁСТКО прописанном
  CPU-бэкенде: `memex-fwd.cpp:6449, 8587` = `ggml_backend_cpu_init()`; 15 сайтов
  `ggml_backend_graph_compute(be, gf)` (single-backend). **Ни одного `ggml_backend_sched_*` в движке.**
- Форк ggml УЖЕ содержит **полный CUDA-бэкенд** (`ggml/src/ggml-cuda/`), но `GGML_CUDA` = OFF
  (`ggml/CMakeLists.txt:117`). Полный `ggml_backend_sched` API есть (+ форк-расширения:
  `set_only_active_experts`, `set_split_mode_graph`, `set_op_offload` — ggml-backend.h:214-217).
- Значит: арх-форварды пойдут на CUDA/Metal/Vulkan, как только buft+be укажут на тот бэкенд.

## Vulkan-заперто (только кастомный offload, ~300KB)
- `gpu_static.cpp` + `gpu_experts.cpp` (компилятся под GGML_VULKAN). Захардкожено `ggml_backend_vk_init(0)`
  (gpu_static:464, gpu_experts:740). Форк-only async-хелперы: `ggml_backend_vk_batch_*` (батч-заливка),
  `ggml_backend_vk_arm_readback` (folded readback) — у CUDA их НЕТ, но у CUDA есть родные
  set_tensor_async/streams/events (проще, чем Vulkan).

## КОРОНА: CPU/GPU overlap-планировщик (наш моат, +46%)
- `memex-fwd.cpp:115-128`, `gpu_experts.hpp:31/376`. Хост-поток владеет бэкендом, считает резидентную
  половину слоя ПОКА CPU считает не-резидентную, джойн на слой. Замерено 13.41 vs 9.16 sequential.
- **НЕ выразимо через ggml_backend_sched** (Vulkan async-примитивы = NULL). Это отдельный слой.

## ПУТЬ (два тира)
- **Tier A (эта неделя, дёшево):** арх-форварды → `ggml_backend_sched({CUDA,CPU})`. CUDA/Metal/мульти-GPU
  почти без кода (ops уже ggml). Правки: buft/be-селектор (6449/8587), общий buft, 15 compute-сайтов →
  `ggml_backend_sched_graph_compute`.
- **Tier B (позже, крупнее):** кастомный overlap-offload — НЕ пихать в sched (потеряем +46%). Портировать
  на CUDA через тонкий backend-seam над ~6 Vulkan-точками + 2 async-хелпера (на CUDA проще).

## Фазы
- **Фаза 0 (часы):** включить GGML_CUDA, build-cuda дерево. Без правок исходника.
- **Фаза 1 (~2-4 дня):** backend-селектор вместо CPU-хардкода; арх-граф через sched({CUDA,CPU});
  веса на GPU buft (стандартный -ngl путь llama.cpp, адаптировать). Offload OFF — фаза самодостаточна.
- **Фаза 2 (~1-2 нед):** backend-seam-vtable над Vulkan-точками offload + CUDA-реализация.
- **Фаза 3:** мульти-GPU (массив бэкендов в sched_new + per-layer placement), CPU-варианты (ggml уже; но
  host-код Windows-специфичен: GlobalMemoryStatusEx memex-fwd.cpp:218, _ftelli64 — нужна портируемость).

## ВАЖНО для нашего железа: у пользователя AMD, НЕ NVIDIA
- CUDA-путь НЕ проверить на этой машине (нет NVIDIA GPU) — только компиляция (Фаза 0). Runtime-валидация
  требует NVIDIA. НО Фаза 1 (sched) полезна и на AMD Vulkan: даст стандартный -ngl (зрелость стока) +
  задел под мульти-карту. Риск: конфликт с кастомным overlap — держать overlap отдельным слоем (Tier B).

## Риски
- Резидентность весов/VRAM: наивный full-offload Фазы 1 предполагает влезание в VRAM; для nonfit нужен
  split (Фаза 2). Сначала Фаза 1 для ВЛЕЗАЮЩИХ (доказать корректность+скорость), CPU-путь для nonfit.
- Покрытие типов/ops: CUDA vs Vulkan разные квант/ops (iqk, MXFP4, sinks). Проверять per-arch
  `ggml_backend_supports_op` ДО заявления поддержки — главный риск тихо-неверного вывода.
- Argmax-регрессия при смене бэкенда — гонять через --zoned-check/argmax-гейты.

**Итог:** арх-форварды — почти даром через sched; Vulkan-замок только в 300KB offload, чей overlap-моат
намеренно вне sched. Неделя-1 = Фаза 0+1 (sched с CUDA). Сохранено под [[hardware-support-roadmap-2026-09-09]].
