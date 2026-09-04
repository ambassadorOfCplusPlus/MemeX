# Карта встраивания механизмов MemeX в штатный `llama-server` форка

Дата: 2026-09-04. Первый проверяемый шаг продуктизации: сборка штатного сервера форка + база на mx1
через нативный `-ot` + точная карта кода для пяти наших механизмов. Все пути абсолютные, дерево
`D:\MemeX\src\ik_llama.cpp\`. Номера строк сняты с текущего дерева (git HEAD 9c408f6) и проверены
чтением, а не только grep'ом. Файлы харнесса (`examples/memex-fwd/*`) не трогались.

## 0. Что сделано и подтверждено кодом

- **Сервер собран.** Цель `llama-server` уже присутствует в cmake-решении форка
  (`examples/server/CMakeLists.txt:1` → `set(TARGET llama-server)`); `build-vk` сконфигурирован с
  `GGML_VULKAN:BOOL=ON`, `LLAMA_BUILD_EXAMPLES:BOOL=ON`. Собрано через
  `bench/build_safe.ps1 -Targets llama-server -Dir D:\MemeX\src\ik_llama.cpp\build-vk`, бинарь
  `build-vk/bin/Release/llama-server.exe` (~8 МБ), проверка запускаемости пройдена. Отдельного
  флага cmake включать не потребовалось.
- **Продуктовая обвязка на месте** (подтверждено): OpenAI `/v1/chat/completions`
  (`server.cpp:2136-2137`), нативный `/completion` (`2133`), Anthropic `/v1/messages` (`2140`),
  SSE-стрим через `res.set_chunked_content_provider("text/event-stream", ...)` (`server.cpp:1265`).
- **Заготовки ядра на месте** (подтверждено чтением):
  - `memex_cc` — резидентный бонус к выбору экспертов, `llama-build-context.cpp:1487-1560`,
    применение `llama-build-context.cpp:1645-1648`;
  - отложенная загрузка экспертов: `llama_expert_tensor_index` (`llama-expert-io.h:15`),
    `build_expert_tensor_index` (`llama-model-loader.cpp:624`), диапазоны файлов
    (`llama-model-loader.cpp:663`); путь `--defer-experts` **только Linux** (комментарий
    `llama-mmap.cpp:65`);
  - `cparams.prefetch_experts` — НЕ пустышка, а рабочий флаг `--prefetch-experts`
    (`common/common.cpp:2196`), проброшенный в CPU-бэкенд
    (`llama.cpp:6165` → `ggml_backend_cpu_set_moe_expert_prefetch`, реализация
    `ggml/src/ggml-backend.cpp:999`, движок `ggml_backend_prefetch_init`,
    `ggml/src/ggml-backend.cpp:1243`). Но это **безусловный read-ahead всех экспертов** (Linux madvise),
    без входа «какие эксперты предсказаны». Именно этого входа не хватает для R1 — см. §5.

## 0.5. База на mx1 через штатный сервер (замер под замком, 2026-09-04)

Запуск: `llama-server -m D:/Qwen3-Coder-30B-A3B-mx1.gguf -ngl 99 -ot exps=CPU -fa off -c 4096
-t 8 --no-warmup --port 8099`. Статика → GPU-бэкенд, эксперты (`blk.N.ffn_*_exps`) → CPU. Health
через 45 с. Каждое число — из ответа сервера / его лога таймингов.

| Проверка | Результат |
|---|---|
| Декод (`/completion` timings, prompt «reverse a string») | **10,85 ток/с** (64 ток, 5898,8 мс) |
| Декод, другой промпт | **11,35 ток/с** (62 ток) |
| Prefill | ~13,2 ток/с |
| Лог сервера (короткий запрос) | eval 12,64 ток/с, prompt 23,53 ток/с |
| SSE-стрим (`/v1/chat/completions`, stream:true) | **работает** — 16 data-чанков + `[DONE]` |
| OpenAI-совместимость (non-stream) | работает («Hello!», usage.completion_tokens=3) |
| Семплер, temp=1.2, seed 1 vs 2 | **разный текст** (True) — семплер живой |
| Детерминизм, temp=0, два прогона | одинаково (True) |

**Вывод развилки (фаза 1 плана продуктизации).** Штатный сервер с нативным `-ot exps=CPU` даёт
**~10,9-11,4 ток/с** на mx1 — это воспроизводит «штатный fork с -ot ~10,7» из плана, но **вдвое ниже
нашего ручного пути ~19 ток/с**. Значит на этой карте (RX 6500 XT, ловушка BAR-окна 256 МиБ) ручная
раскладка `GpuStatic` **несущая**, а не избыточная: нативный GPU-путь ядра не достаёт нашей скорости.
Это подтверждает целесообразность встраивания механизмов, а не только опоры на `-ot`. База зафиксирована.

## 1. Путь построения графа в ядре (общий скелет)

`llama_decode` → `llama_decode_internal` (цикл по ubatch) → `llama_build_graph`
(`llama-build-context.cpp:2820-...`) → `switch(arch)`:
- `LLM_ARCH_QWEN3MOE` → `build_qwen3moe()` (`llama-build-context.cpp:2961`, тело —
  `src/graphs/build_qwen3.cpp:106`);
- `LLM_ARCH_QWEN35MOE` (qwen3next / Coder Next) → `build_qwen35moe()`
  (`llama-build-context.cpp:2973`, тело — `src/graphs/build_qwen35.cpp:6`).

Оба билдера — один и тот же скелет на слой: **внимание → MoE-FFN → residual**, финал — общая голова.
Общие хелперы (в них и встраиваемся, один раз на все архитектуры):
- внимание: `llm_build_context::build_std_attention` (`llama-build-context.cpp:3222`) — Q/K/V,
  RoPE, запись KV в `kv_self.k_l[il]/v_l[il]`, KQV;
- MoE-FFN: `llm_build_context::llm_build_std_moe_ffn` (`llama-build-context.cpp:1856`) →
  `llm_build_context::llm_build_moe_ffn` (`llama-build-context.cpp:1562`);
- голова: `llm_build_context::build_output` (`llama-build-context.cpp:2669` и перегрузка с нормой
  `2674`), финальный matmul в неразделённой ветке — `llama-build-context.cpp:2732`
  (`llm_build_lora_mm(lctx, ctx, output, cur)`).

qwen35moe-цикл слоёв: `src/graphs/build_qwen35.cpp:38-66` — внимание/дельта
(`build_std_attention` 43 / `delta.build_layer_attn_linear` 41), затем `llm_build_std_moe_ffn`
(48), голова `build_output` (67). qwen3moe-цикл: `src/graphs/build_qwen3.cpp:21-56`.

## 2. Карта пяти механизмов (точка кода, тип хука, честность)

### (а) Голова на карте — `gpu_static::head`
- **Точка**: `llm_build_context::build_output`, неразделённая ветка, финальный
  `llm_build_lora_mm(lctx, ctx, output, cur)` — **`llama-build-context.cpp:2732`**. Прямой аналог
  харнессового `head_matmul` под условием `gstat->head_on()` (memex-fwd.cpp:790).
- **Тип хука**: подмена одной ноды. `gstat->head(c, cur)` возвращает тензор той же формы `[n_vocab,
  n_tokens]` и типа, ниже по графу ничего не меняется.
- **Честность**: **чисто, но со швом sched.** Узел исполняется как CPU-`map_custom` (n_tasks=1),
  внутри синхронно дёргающий Vulkan. В ядре граф идёт через `ggml_backend_sched`, поэтому нашу
  ноду надо **прибить к CPU-бэкенду** в sched (иначе sched попробует её оффлоадить). Хук —
  опция (cparam/поле в `llm_build_context`), не патч логики. Единственный на все архитектуры, т.к.
  голова у всех идёт через `build_output`.

### (б) Статика слоя на карте (внимание + роутер + KV) — `gpu_static::layer`
- **Точка**: подмена вызова блока внимания. Для qwen3next — `build_std_attention(...)`
  **`src/graphs/build_qwen35.cpp:43`** (и дельта-ветка `delta.build_layer_attn_linear`,
  `build_qwen35.cpp:41`); общий хелпер — `build_std_attention` (`llama-build-context.cpp:3222`),
  внутри которого запись KV `kv_self.k_l[il]` (`llama-build-context.cpp:3265+`). Плюс хостовая
  оркестрация `set_step`/`upload_kv`/`upload_delta` в `update_slots` сервера.
- **Тип хука**: **патч-логика средней инвазивности** (не просто опция). Замена целого блока
  внимания на `gstat->layer()` + перенос пооктокенного клея в цикл слотов.
- **Честность**: **опция с жёсткими условиями.** Работает только при ширине декода 1 (или
  `layer_width`) И **одной активной последовательности** — карта держит один KV-буфер (`upload_kv`
  грузит один кэш на промпт). Мультислот требует отката на CPU-граф (см. §3, риск ширины).

### (в) Хранилище экспертов в ОЗУ — `ExpertStore` (на месте `mul_mat_id`)
- **Точка**: узел перевода `id→slot` между top-k и сбором экспертов в `llm_build_moe_ffn`:
  сразу после `cb(selected_experts, "ffn_moe_topk", il)` (**`llama-build-context.cpp:1681`**) и до
  трёх `llm_build_lora_mm_id(up/gate/down, selected_experts)`
  (**`llama-build-context.cpp:1764/1767/1802`**). Т.е. `sel = es->slots_node(c, il, selected_experts, gf)`.
- **Альтернатива (рекомендация плана)**: переиспользовать ядрёные `defer_experts` +
  `expert_tensor_index` (`llama-model-loader.cpp:624`) вместо собственного чтения по файловым
  смещениям — снимает известный дефект двойной памяти.
- **Честность**: **полу-чисто.** В ядре уже есть индекс файловых диапазонов экспертов и путь
  `drop_mmap_expert_pages`, но **только Linux** (`llama-mmap.cpp:65`), а цель — Windows: портируемость
  отложенного пути — отдельная подзадача (`VirtualUnlock`/`DiscardVirtualMemory`).

### (г) Кольцевой / зонный KV — `ZonedKvCache`
- **Точка**: аллокация KV-буферов слоёв — `llama_kv_cache_init`, `cache.k_l.push_back(...)`
  (**`llama.cpp:1428-1429`**, разделённый вариант 1520-1586); в ядре уже есть оконная логика SWA
  (`is_compacted`, `size_swa`, `head_swa` — `llama-build-context.cpp:72-73`,
  `llama.cpp:1786-1790`). Наш кольцевой буфер идёт **ПОД** штатным `llama_kv_cache`, не вместо него.
- **Тип хука**: опция размера/геометрии буфера на оконных слоях + per-slot позиции.
- **Честность**: **отдельная работа**, не конфликтует с семантикой KV сервера, но с мультислотом —
  та же проблема одного устройства, что у (б).

### (д) Предсказатель экспертов R1 (шаг 5) — через `prefetch_experts`
- **Точка входа данных**: дамп входа роутера (в харнессе `hid_outs`/`want_hid`,
  memex-fwd.cpp:1254/3849). В ядре скрытое состояние доступно в `llm_build_moe_ffn` до роутера
  (`cur`, `llama-build-context.cpp:1562+`).
- **Точка выхода**: `cparams.prefetch_experts` (`llama-cparams.h:42`), флаг `--prefetch-experts`
  (`common/common.cpp:2196`), движок `ggml_backend_prefetch_init` (`ggml-backend.cpp:1243`).
- **Честность**: **пока НЕ в C++, и хук неполный.** Существующий `prefetch_experts` — безусловный
  read-ahead всех экспертов (Linux), у него **нет входа «список предсказанных экспертов»**.
  R1-предсказатель сейчас живёт только в оффлайне (`bench/train_r1.py`, `route_lab.py`). Встраивание
  = новый код: снять скрытое состояние в процессе + сделать `prefetch_experts` селективным по
  предсказанию. Точка подключения есть, но самого селективного пути — нет.

## 3. Главный риск: ширина декода (мультислот против карты)

**Подтверждено кодом.** Наш карточный путь требует `ne[1]==1` (gpu_static.hpp:148-156; включение
в графе харнесса жёстко `n_tokens==1`, memex-fwd.cpp:2263/3663). Сервер же **батчит РАЗНЫЕ
последовательности в один decode**:
- на генерации каждый активный слот добавляет один токен со СВОИМ seq_id:
  `common_batch_add(batch, slot.sampled, ..., { slot.id }, true)` — **`server-context.cpp:3563`**
  (спекулятивный черновик 3589, промпт 4148);
- декод режет общий батч по `n_batch`: `process_batch_tokens` (**`server-context.cpp:4647`**),
  `batch_view` c `n_tokens = min(n_batch, batch.n_tokens - i)` (**4653-4664**) → `server_decode`
  → `llama_decode`. При K активных слотах `batch_view.n_tokens = K > 1`, и это **K независимых
  последовательностей**, а не одна задача ширины K.

**Две ортогональные ширины:**
1. **Ширина по запросам** (батч разных seq в один decode) — это делает сервер. Наш путь карты
   держит ОДИН KV/перенос­имое состояние → неявно одна последовательность. С этим карта **несовместима**.
2. **Ширина внутри одной последовательности** (MTP / верификация спекуляции) — это `layer_width`
   карты, её карта умеет (~18 ток/с, bench/spec_width.ps1).

**Развязка (рекомендация — вариант A):** гейт по одиночному слоту. Включать путь карты только когда
активна ровно одна последовательность (`--parallel 1`, или динамически — занят один слот); на батче
из нескольких слотов откатываться на штатный CPU/GPU-граф ядра. Корректность бесплатна (это текущий
инвариант харнесса). У сервера уже есть прецедент форса одиночного слота:
`server_speculative_requires_single_slot` (**`server-context.cpp:79`**, применение 220). Карта
смыкается со спекулятивным путём для случая (2), мультипользовательский поток обслуживается штатным
графом. Варианты B (пер-слотовая итерация, N диспатчей/токен) и C (Vulkan-графы ширины N) —
дороже и для случая (1) бесперспективны.

**Доп. фактор:** в `llm_build_moe_ffn` уже есть ветка `memex_shared_experts_enabled() && n_tokens>1`
(**`llama-build-context.cpp:1653`**): при ширине>1 — ОДИН общий top-k на батч. Любой наш
предсказатель/резидентность на ширине>1 должен читать тот же выбор, иначе разойдётся с ядром.

## 4. Архитектурный шов sched (общий для а/б/г)

Харнесс НЕ использует `ggml_backend_sched` (свой `ggml_gallocr`, ручной счёт). Ядро сервера считает
через `ggml_backend_sched_graph_compute`. Наши `map_custom`-ноды (n_tasks=1, синхронный Vulkan
внутри) должны при встраивании **остаться на CPU-бэкенде sched**, иначе sched попробует их
оффлоадить. Весь тонкий контроль вокруг 256-МиБ BAR-окна карты остаётся ручным. Выполнимо, но шов
надо держать явным. Плюс ограничение процесса: `GpuStatic` и `GpuExperts` не делят один `vk_device`
(gpu_static.hpp:60-64) — в сервере это значит «либо статика-слой, либо резидентные эксперты», выбор —
параметр запуска.

## 5. Итог по чистоте встраивания

| Механизм | Точка | Тип | Чисто? |
|---|---|---|---|
| (а) Голова | `llama-build-context.cpp:2732` | подмена ноды (опция+sched) | чисто |
| (б) Слой | `build_qwen35.cpp:43` / `llama-build-context.cpp:3222` | патч-логика + оркестрация | опция, только 1 слот |
| (в) ExpertStore | `llama-build-context.cpp:1681→1764` | вставка ноды id→slot | полу-чисто (Linux-порт) |
| (г) Кольцевой KV | `llama.cpp:1428` | опция геометрии буфера | отдельная работа |
| (д) R1-префетч | вход `moe_ffn` `:1562`, выход `cparams.prefetch_experts` | новый код + селективный вход | не в C++, хук неполный |

## 5.5. POC: механизм подключается в штатный сервер только опциями (замер под замком)

Доказательство, что наш механизм ВООБЩЕ подключается к серверному пути **без единой правки кода** —
через уже вкомпилированный в ядро `memex_cc` (cache-conditional routing = смещение выбора экспертов к
резидентным, наш ResidentSet-бонус). Управляется только env: `MEMEX_CACHE_BONUS`, `MEMEX_RESIDENT_FILE`
(бинарь-маска: `int32 n_layers, int32 n_experts, float[n_layers*n_experts]`). Два прогона штатного
`llama-server` (mx1, тот же `-ot exps=CPU`), greedy `temp=0`, промпт «The capital of France is»:

| Прогон | Выход | Баннер MemeX |
|---|---|---|
| A baseline (без env) | «Paris. The capital of Belgium is Brussels...» (корректно) | нет |
| B `MEMEX_CACHE_BONUS=5.0`, маска 64/128 резидентных | «France is France is France is...» (вырожденно) | **`MemeX: бонус резидентным 5.000, маска 48 x 128`** |

- Баннер печатается при init графа (`llama_init_from_model`, graph nodes=2021 — включая map_custom1-ноду
  бонуса из `llama-build-context.cpp:1646`), т.е. наша нода реально вошла в серверный граф.
- **greedy A ≠ B = True**: бонус сместил маршрутизацию к резидентной половине экспертов и изменил
  декод. Вырождение при bonus=5.0 — не баг POC, а прямое свидетельство, что смещение действует
  (экстремальный бонус жёстко фиксирует выбор на половине экспертов).

**Вывод POC:** механизм из семьи MemeX (резидентное смещение) подключается к штатному `llama-server`
как чистая опция, без правки запрещённых файлов, и наблюдаемо влияет на декод. Это подтверждает
контракт «механизм = опция»: остальные четыре (голова/слой/ExpertStore/R1) требуют аналогичных
типизированных хуков, но уже с правкой ядра/выносом libmemex (см. §6), т.к. их точек-заглушек в ядре,
управляемых env, пока нет.

## 6. Что требует правки харнесса (отдано в очередь)

Файлы `examples/memex-fwd/*` не трогались (правят два других агента). Для чистого встраивания в
сервер потребуется (в очередь ПОСЛЕ выноса libmemex):
- вынести `gpu_static`/`gpu_experts`/`resident_set`/`expert_store` в `libmemex` (уже библиотечной
  формы — свои `.hpp`, зависят только от ggml). Это отвязывает механизмы от харнесса.
- добавить типизированный `memex_hooks` в `llm_build_context` (зеркало `BuildOpts` харнесса,
  memex-fwd.cpp:3921) и пробросить в `build_output` / `llm_build_moe_ffn` / билдер слоя.
- перенести пооктокенную оркестрацию (`set_step`/`upload_kv`/`upload_delta`/`observe`/`end_token`)
  из цикла генерации харнесса в `update_slots` сервера.
