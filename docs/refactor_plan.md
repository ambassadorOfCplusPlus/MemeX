# План разбиения движка MemeX (memex-fwd) в дерево модулей

Чистый анализ на бумаге. Код не менялся, ничего не собиралось, модель не запускалась, замок не
трогался. Источники (только чтение):
`D:\MemeX\src\ik_llama.cpp\examples\memex-fwd\` — `memex-fwd.cpp` (10465 строк), `gpu_static.*`
(2782/674), `gpu_experts.*` (2680/573), `resident_set.*` (437/330), `expert_store.*` (770/247),
`CMakeLists.txt`; хвост `STATE.md`; спека
`docs/superpowers/specs/2026-09-03-coder-next-static-gpu-tiering-design.md`.

Замечание о спеке: раздела «Фаза 2 / вынос в `libmemex`» в спеке **нет**. Спека описывает пять
шагов Coder Next; шаг 2 («Реестр архитектур» — `ArchModel` + `build_any`) уже реализован (см.
коммиты) и является фундаментом этого разбиения. Настоящий план — заявленный пользователем вынос
механизмов в библиотеку, отдельно от спеки.

---

## 1. Карта текущего memex-fwd.cpp

Файл монолитен, но внутренне уже разбит на именованные блоки. Ниже — диапазоны строк, размер и
зависимости. Всё, кроме двух `namespace memex { class … }` вперёдобъявлений, живёт в анонимном
`namespace { … }` (открыт на строке 182).

| # | Блок | Строки | ~строк | Зависит от |
|---|------|--------|--------|-----------|
| A | Прозаический заголовок + `#include` (ggml, llama, resident_set.hpp, expert_store.hpp, gpu_experts.hpp; gpu_static.hpp косвенно) | 1–131 | 130 | внешние заголовки |
| B | Вперёдобъявления `ZonedKvCache`, `namespace memex` классов; утилиты `ms_since`, `gb`, `type_is_interleaved` | 132–421 | 290 | ggml |
| C | **Геометрия слоя**: `LayerKind` (ATTN/ATTN_SWA/DELTA_NET), `LayerGeom`, `HParams` (rope, sections, delta_state_elems, n_delta_layers) | 238–395 | 160 | ggml |
| D | **Чтение гиперпараметров из GGUF**: `key_u32/arr_u32/f32`, `read_hparams` (495), `print_present_tensors`, `pad32` | 422–705 | 284 | gguf, HParams |
| E | ggml-хелперы графа: `norm`, `fnorm`, `report_first_nonfinite`, `head_matmul`, `need` | 706–826 | 120 | ggml |
| F | **Веса по архитектурам**: `Weights` (797), `DenseWeights` (860), `Gemma4Weights` (911), `Qwen35Weights` (950) | 797–1156 | 360 | ggml, HParams |
| G | **Загрузчики (collect)**: `collect` qwen3moe (827), `collect_dense` (880), `collect_gemma4` (997, правит HParams), `collect_qwen35` (1089) | 818–1156 | 340 | llama_model, F |
| H | Граф: `Graph` (1157), `set_graph_inputs` (1379), `build` первичный (1435) | 1157–1592 | 435 | ggml-alloc, C, F |
| I | **KV-кэш**: `Cache` (1593), `KvBytes` | 1593–1687 | 95 | H |
| J | **DeltaState** — переносимое состояние гейтированной дельта-сети (72 МиБ, пишется на месте каждый токен) | 1646–1765 | 120 | C |
| K | **Зонный KV**: `ZonedOpt`, `ZonedKV`, `print_kv_zoning`, `seed_zoned`, `verify_seed`, `mirror_zoned_row`, `zoned_begin_step` | 1766–2176 | 410 | memex::ZonedCache (внешн., под `MEMEX_FWD_ZONED`) |
| L1 | **Построитель qwen3moe**: `build_step` (внимание rope_multi + MoE-FFN инлайн) | 2177–2623 | 447 | H, F, ResidentSet, GpuExperts, GpuStatic, ZonedKV |
| L2 | **Построитель dense** (черновик): `build_dense_step` | 2624–2778 | 155 | H, DenseWeights |
| L3 | **Построитель gemma4**: `build_gemma4_step` (две геометрии внимания, SWA) | 2779–3316 | 538 | H, Gemma4Weights |
| L4 | **Хелперы qwen35**: `qwen35_moe_routed` (3317), `qwen35_ffn` (3368), `qwen35_delta_layer` (3413, ssm_conv + delta_net) | 3317–3577 | 260 | ggml, DeltaState |
| L5 | **Построитель qwen35moe/qwen3next**: `build_qwen35_step` (гибрид: внимание каждый 4-й слой, дельта-сеть между) | 3578–3920 | 343 | L4, DeltaState, ExpertStore, GpuStatic |
| M | **Реестр**: `BuildOpts` (3921), `ArchModel` (3969), `arch_qwen3moe/gemma4/qwen35/qwen3_dense` (4002–4047), `build_any` (4048) — единственная точка диспетчеризации, через неё идут все 9 мест | 3921–4155 | 235 | L1–L5, F |
| N | `Generator` — обёртка init/prefill/build_decode для замерного цикла | 4156–4433 | 278 | M, H, I, J |
| O | **Зонды**: `Probe`, `probe_cb`, `report` (сверка тензоров ours/ref) | 4434–4619 | 186 | ggml callback |
| P | **Семплер**: `Sampling`, `Sampler` (argmax и пр.) | 4620–4801 | 182 | — |
| Q | Опции модулей + печать отчётов: `Budget`, `ResidentOpt`, `ExpertStoreOpt`, `GpuStaticOpt`, `GpuExpertOpt`, `ResidentReport`; `expert_bytes_one`, `print_store_report`, `print_resident`, `print_budget` | 4802–5336 | 535 | resident_set, expert_store, gpu_* |
| R | Чат: `ChatMsg`, `apply_chat` (шаблон) | 5337–5410 | 74 | llama chat |
| S | Сравнение логитов + семпл-хелперы: `LogitCmp`, `top2_gap`, `argmax_of` | 5386–5493 | 108 | — |
| T | **Замерный прогон**: `GenStats` (5494), `generate` (5542) — основной цикл генерации со спекуляцией | 5494–5823 | 330 | N, P, Draft |
| U | **Черновик/спекуляция**: `draft_selftest` (5824), `Draft` (5964), `load_draft` (5971), `common_prefix` (6047) | 5824–6052 | 228 | llama, M |
| V | `run_chat` — интерактивный чат отдельной веткой | 6053–6221 | 169 | N, P, R |
| **W** | **main** — весь харнесс | **6222–10465** | **4244** | всё выше |

### Разбор main (W) — крупнейший источник спагетти

| Подблок | Строки | Что делает |
|---|---|---|
| W1 Объявления опций/состояния (много прозы) | 6222–6316 | десятки локальных переменных-флагов |
| W2 **Разбор argv** — цепочка `else if (!strcmp(a, "--…"))` | 6317–6612 | ~90 флагов (см. §4) |
| W3 Валидация и взаимоисключения (`selftest`, `--zoned`+`--chat`, `--resident`+спекуляция и т.д.) | 6613–6798 | ~30 проверок с отказом вслух |
| W4 Загрузка модели, детект архитектуры, `read_hparams`/`collect_*`, сборка `ArchModel` | 6799–7293 | `llama_model_load_from_file` (7215), collect (7360–7362), arch_* (7383–7385) |
| W5 Настройка зонда (`--probe`) | 7294–7316 | |
| W6 Эталонный контекст (`want_ref`, llama_decode) | 7317–7437 | |
| W7 Настройка `gpu_static` | 7438–7672 | |
| W8 Настройка `expert_store` / резидентности | 7673–7930 | |
| W9 Прогон зонда «all» | 7931–8002 | |
| W10 **`--decode-check N`** — сверка токенов против эталона | 8003–8214 | |
| W11 **`--gen N`** — замерный харнесс, подветки: gpu_experts (8246), резидентность/split (8381), зонная рука (9436), split-рука (9690), join (10278) | 8215–10465 | самая тяжёлая часть |

**Ключевое наблюдение по зависимостям.** Внимание и MoE-FFN **не** вынесены в общие функции — они
инлайнены внутри каждого построителя (L1, L3, L5). Общие только: `norm/fnorm/head_matmul` (E) и
хелперы qwen35 (L4). Это повышает риск при попытке «вынести attention/moe в отдельный файл» —
там придётся факторизовать инлайн-код, а не переместить готовую функцию.

---

## 2. Предлагаемое дерево `libmemex/`

Правило: **харнесс замеров не входит в библиотеку**. Библиотека = «построить граф и выполнить
токен»; всё, что печатает отчёты, разбирает argv, делает свипы и сверки — в `harness/`.

```
libmemex/
  include/memex/            (публичные заголовки)
    hparams.hpp             C   геометрия слоя, HParams, LayerKind/LayerGeom
    weights.hpp             F   Weights/DenseWeights/Gemma4Weights/Qwen35Weights
    model_registry.hpp      M   ArchModel, BuildOpts, arch_* фабрики, build_any (публ. интерфейс)
    graph.hpp               H   Graph, set_graph_inputs
    cache.hpp               I,J Cache, KvBytes, DeltaState
    config.hpp              —   struct Config (см. §4) — заменяет десятки getenv
    sampler.hpp             P,S Sampling/Sampler, argmax_of, top2_gap
  src/
    hparams.cpp             C,D чтение GGUF (read_hparams, key_*), pad32
    weights.cpp             F,G collect / collect_dense / collect_gemma4 / collect_qwen35
    ggml_util.cpp           E   norm, fnorm, head_matmul, need, report_first_nonfinite
    graph.cpp               H   Graph, set_graph_inputs, build
    cache.cpp               I,J Cache, DeltaState
    model_registry.cpp      M   ArchModel/build_any (диспетчер + отказ вслух)
    builders/
      qwen3moe.cpp          L1  build_step
      dense.cpp             L2  build_dense_step
      gemma4.cpp            L3  build_gemma4_step
      qwen35.cpp            L4,L5 qwen35_*_helpers + build_qwen35_step
    deltanet.cpp            L4  qwen35_delta_layer + ssm-обвязка (внутреннее)
    attention.cpp           —   (цель) общий attention-хелпер, факторизованный из L1/L3/L5
    moe.cpp                 —   (цель) общий MoE-FFN-хелпер, факторизованный из L1/L5
    zoned.cpp               K   ZonedKV-обвязка (под MEMEX_FWD_ZONED)
    gpu_static.cpp          (перенос как есть)
    gpu_experts.cpp         (перенос как есть)
    resident_set.cpp        (перенос как есть)
    expert_store.cpp        (перенос как есть)
    predictor.cpp           —   (шаг 5) r1_corr / router-предзагрузчик — пока не существует

harness/                    (исполняемый llama-memex-fwd, НЕ библиотека)
  main.cpp                  W1 argv/диспетчер режимов
  cli.cpp                   W2 разбор флагов -> Config
  validate.cpp             W3 взаимоисключения
  modes/
    decode_check.cpp        W10
    gen.cpp                 W11 (+ подветки gpu_experts/resident/zoned/split)
    probe.cpp               W5,W9,O
    chat.cpp                V   run_chat
  generator.cpp             N,T Generator, generate, GenStats
  draft.cpp                 U   Draft, load_draft, draft_selftest
  reports.cpp               Q   print_budget/resident/store + опции-структуры
```

**Публичный интерфейс библиотеки** (что видит харнесс): `HParams`, `Weights*`, `ArchModel` +
`build_any`, `Graph`, `Cache`/`DeltaState`, `Config`, `Sampler`, `read_hparams`, `collect_*`.
**Внутреннее** (не в публичных заголовках): все `builders/*`, `deltanet`, `attention`, `moe`,
хелперы ggml — доступны только через `build_any`. `gpu_static`/`gpu_experts`/`resident_set`/
`expert_store` уже имеют свои `.hpp` и остаются публичными для харнесса.

`attention.cpp`/`moe.cpp`/`predictor.cpp` помечены целью: attention/moe требуют факторизации
инлайна (риск, см. §5), predictor — шаг 5, ещё не написан.

---

## 3. Порядок миграции (каждый шаг компилируется и сверяется)

Инвариант проверки после каждого шага: `--decode-check 16` на трёх моделях (qwen3moe mx1,
gemma4, qwen3next) даёт **те же токены**; плюс `--gen 8` на mx1 не медленнее (19,7 ток/с ±
разброс). Это тот же контроль, что в шаге 2 спеки.

| Шаг | Что выносим | Риск | Проверка | ЧЧ |
|---|---|---|---|---|
| 0 | Создать дерево `libmemex/`, CMake-цель-библиотеку `memex` рядом с exe; `gpu_static/gpu_experts/resident_set/expert_store` **уже** отдельные файлы — просто перевесить в цель библиотеки, `memex-fwd.cpp` линкуется с ней. Ноль перемещений кода. | мин | сборка + `--decode-check 16` ×3 | 2–4 |
| 1 | Вынести E (ggml_util) и P/S (sampler) — они без внешних зависимостей и почти ни от чего | мин | то же + `--gen 8` | 2–3 |
| 2 | Вынести C+D (hparams) и F+G (weights/collect) — чистые данные и чтение GGUF | низк | `--decode-check 16` (загрузка не изменилась → те же токены) | 4–6 |
| 3 | Вынести H+I+J (graph/cache/deltanet-state) | средн | сверка; следить за общими буферами (§5) | 4–6 |
| 4 | Вынести M (реестр) + builders/ по файлу на построитель (L1–L5). Порядок узлов графа обязан совпасть побайтно | **выс** | `--gpu-static-verify` (побайтно) + зонд слоя против `Qcur_roped-3` + `--decode-check 16` ×3 | 8–12 |
| 5 | Вынести K (zoned) и Q (reports) в harness | низк | `--zoned-check`, `--decode-check 16` | 3–4 |
| 6 | Вынести N/T/U (generator/generate/draft) в harness | средн | `--gen 8`, `--draft-check` | 4–6 |
| 7 | Ввести `struct Config`, перевести argv-разбор (W2) и getenv (§4) в неё; harness/cli.cpp | средн | все флаги дают прежнее поведение; сверка списком §4 | 6–10 |
| 8 | **Последним** — расщепить main (W1/W3/W10/W11/V) на modes/. Самое объёмное, но после шага 4 механически | средн | полный прогон всех режимов | 8–12 |
| 9 | (Цель, необязательно) факторизовать attention.cpp/moe.cpp из инлайна L1/L3/L5 | **выс** | побайтная сверка на каждой арх; можно отложить | 8–16 |

Первым — то, что уже обособлено (шаг 0: gpu_static/expert_store/resident_set). Последним —
main/харнесс (шаг 8). Attention/moe-факторизация (шаг 9) вынесена в конец как необязательная:
она единственная переписывает логику, а не границы.

**Итого оценка**: ~43–63 ЧЧ на шаги 0–8 (границы модулей), +8–16 ЧЧ на необязательный шаг 9.

---

## 4. Переменные окружения → `Config` или отладочный флаг

Найдено `grep -o 'MEMEX_[A-Z_]*'`: 25 уникальных MEMEX_-переменных + внешние (`GGML_VK_*`,
`LLAMA_MMAP_PREFETCH`). Плотность: gpu_static.cpp 18 getenv, memex-fwd.cpp 22, gpu_experts.cpp 5.

**Компиляционные дефайны (НЕ трогать, остаются в CMake):**
`MEMEX_FWD_GPU_EXPERTS`, `MEMEX_FWD_ZONED`, `MEMEX_FWD_VULKAN` — это `target_compile_definitions`,
не runtime env.

**→ в `struct Config`** (влияют на поведение/граф, должны быть воспроизводимыми полями, а лучше и
CLI-флагами):

| Переменная | Роль | Файл |
|---|---|---|
| `MEMEX_STATIC_TRUNC` | усечение статики на карте | gpu_static |
| `MEMEX_LAYOUT_SEL` | форс раскладки selection | memex-fwd:4134 |
| `MEMEX_FUSED_NORM` | путь слитой нормы | gpu_static |
| `MEMEX_SWA_RING`, `MEMEX_SWA_NARROW` | геометрия SWA-окна | gpu_static |
| `MEMEX_SPLIT_OUT` | расщепление выходной головы | gpu_static |
| `MEMEX_PROMO_DRAIN`, `MEMEX_PROMO_YIELD`, `MEMEX_PROMO_ASYNC` | политика промоушена экспертов | gpu_experts/memex-fwd |
| `MEMEX_FOLD_READBACK` | путь свёртки/зачитки предсказателя | gpu_static |
| `MEMEX_MTP_OVERLAP` | перекрытие MTP | memex-fwd:8957 |
| `MEMEX_SPEC_WIDTH`, `MEMEX_SPEC_ALLLOG`, `MEMEX_SPEC_SEQ` | ширина/режим спекуляции | memex-fwd:9266+ |
| `MEMEX_CARD_LO`, `MEMEX_CARD_HI` | границы свипа слоёв на карте | memex-fwd:3676 |

**→ остаются отладочными флагами (getenv, диагностика/трассы/абляции — не воспроизводятся, не в
Config):**

| Переменная | Роль |
|---|---|
| `MEMEX_EXPERT_TRACE` | путь файла следа маршрутизации |
| `MEMEX_HIDDEN_TRACE` | путь дампа скрытых состояний |
| `MEMEX_EXPERT_DUMP` | дамп выбора экспертов |
| `MEMEX_EXPERT_COVERAGE` | тумблер измерения покрытия |
| `MEMEX_NO_SOFTMAX`, `MEMEX_NO_ROPE` | абляции (выключить операцию для диагностики) |

Пограничные: `MEMEX_NO_SOFTMAX/NO_ROPE` — абляции, но меняют граф; предлагаю оставить отладочными
с явной печатью «граф изменён абляцией», чтобы не спутать с боевым прогоном. Внешние
`GGML_VK_SUBMIT_DIVISOR/TAIL` (memex-fwd:6782) и `LLAMA_MMAP_PREFETCH` (7200) — чужие, не наши,
оставить как есть.

Итог: ~15 переменных в `Config`, ~5 отладочных, 3 компиляционных дефайна, 3 чужих.

---

## 5. Риски: где расщепление даст «работает, но неверно»

1. **Порядок узлов графа (высший риск).** Построители (L1/L3/L5) эмитят узлы в строго
   определённом порядке; `--gpu-static-verify` и зонды сверяют тензоры по именам вроде
   `Qcur_roped-3`. Перенос построителя в отдельный файл не должен переставить ни одного
   `ggml_*`-вызова. **Ловля**: побайтная сверка (`--gpu-static-verify`) + зонд одного слоя +
   `--decode-check 16` даёт токен-в-токен. Любой сдвиг проявится немедленно.

2. **DeltaState (ловушка 7.5, уже задокументирована в коде).** Состояние дельта-сети (J)
   продвигается и пишется на месте каждый токен; отмотать нечем. Один экземпляр на прогон —
   два экземпляра означали бы, что шаг читает не то, что записал предыдущий. При выносе cache.cpp
   нельзя допустить копию/повторную инициализацию. `ArchModel.can_repeat=false` для qwen35 — это
   защита; её надо сохранить дословно. **Ловля**: `--gen` на qwen3next (не медленнее и те же
   токены); повторный прогон одного графа (`repeat_runs`) на qwen35 обязан по-прежнему **отказывать
   вслух**, а не молча портить состояние.

3. **Общие буферы `Graph`/`Cache`.** `Graph` держит входные тензоры (positions, seq_ids, sel_ids,
   hid_outs), которые заполняет `set_graph_inputs` и читают резидентный набор, трасса и покрытие.
   Флаги `want_sel`/`want_hid`/`keep_dbg`/`keep_probes` в `BuildOpts` управляют тем, строится ли
   узел вообще. При расщеплении легко «всегда строить» ради простоты — это те самые 48 лишних
   закреплённых узлов на токен, которые реестр как раз убрал. **Ловля**: сравнить число узлов
   графа (движок печатает диспатчи) до/после; `--gen 8` скорость.

4. **`build_any` как единственная точка отказа.** Девять мест харнесса зовут `build_any`; отказ
   вслух с именем точки (`BuildOpts.where`) — это то, что ловит «новая архитектура попала в чужой
   построитель». При расщеплении main на modes/ каждое из девяти мест должно сохранить своё имя
   точки. **Ловля**: прогнать неподдержанную комбинацию (напр. `--zoned` на gemma4) и убедиться,
   что печатается отказ, а не тихий граф.

5. **gemma4: `collect_gemma4` правит `HParams`.** В отличие от прочих collect, `collect_gemma4`
   принимает `HParams*` и меняет его (full_attention_interval, две геометрии). При выносе
   weights.cpp порядок «read_hparams → collect_gemma4 (доправляет) → arch» обязан сохраниться.
   **Ловля**: `--decode-check 16` на gemma4.

6. **Условная компиляция.** `zoned` (под `MEMEX_FWD_ZONED`), `gpu_static/gpu_experts` (под
   `GGML_VULKAN`) — сборка без Vulkan/без MemeX-дерева обязана и дальше конфигурироваться и
   отказывать вслух на флаге. **Ловля**: сконфигурировать обе ветки (build и build-vk).

---

## Чего НЕ вошло в анализ

- **Внутренности `gpu_static.cpp`/`gpu_experts.cpp` (5462 строки вместе)**: считаю их уже
  обособленными файлами и переношу как есть. Их собственные 23 getenv расклассифицированы в §4,
  но карта их внутренних блоков не строилась.
- **`resident_set.cpp`/`expert_store.cpp` внутренне** — то же, перенос как есть.
- **Замер трудозатрат — грубая оценка** по объёму строк и числу точек вызова, не по факту.
- **Attention/MoE-факторизация (шаг 9)** намечена, но конкретные границы общих функций не
  спроектированы: инлайн в L1/L3/L5 различается (rope_multi у qwen3moe, две геометрии + SWA у
  gemma4, гибрид у qwen35), и вынести их в один хелпер без изменения логики — отдельная задача.
- **`predictor` (шаг 5)** — файла ещё нет; в дереве это заглушка под будущий `r1_corr`.
- **Тесты**: план опирается на существующие `--decode-check`/`--gpu-static-verify`/зонды; новые
  юнит-тесты модулей не проектировались.
- **Сборочные скрипты** (`build_and_verify.ps1`, `arch_verify_run.ps1` и пр.) и их правки под
  новое дерево не рассматривались.
- Каталоги `C:\Users\User11\Desktop\zadacha` и `C:\Users\User11\Desktop\MemeX\bench` не трогались.
