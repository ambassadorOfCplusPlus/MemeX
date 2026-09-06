# Готовый к применению набор патчей горячего пути декода (6 сентября 2026)

Найдено агентом-анализатором (только чтение). Все патчи **byte-identical по построению** — токены
не меняются. НЕ применены ночью намеренно: выигрыш «только джиттер, <0,1%», не стоит
несупервизируемой ночной пересборки. Применять днём одной сборкой + `bench/regress_tokens.ps1`
(должно остаться 16/16 на всех трёх архитектурах).

## Вывод по потокам (ЗАМЕРЕНО, не патч — это самый крупный рычаг, и он оказался мал)
Свип `-t` на 35B CPU (прогрето): 4→6,56  5→6,46  6→6,85  8→6,70 tok/s — разброс ~6%, шум.
`-t 3`=0,83 — выброс холодного кэша. Шина ОЗУ насыщается уже 4 потоками, 8 не штрафуют.
Номинально лучший **-t 6**. Гипотеза «меньше потоков сильно быстрее» НЕ подтвердилась на 35B
(было измерено давно на другой модели/конфиге). Второй свип (mx1/gemma4) — см. STATE.
Действие: в бенч-лесенках использовать -t 6 (мелкий выигрыш), НЕ код.

## Патч 2: вынести векторы плана из set_step (gpu_static.cpp:2058, раз в токен, все карт-архитектуры)
```
-    std::vector<int> plan_lo(lg_.size(), 0), plan_len(lg_.size(), n_kv);
+    static thread_local std::vector<int> plan_lo, plan_len;
+    plan_lo.assign(lg_.size(), 0);
+    plan_len.assign(lg_.size(), n_kv);
```
Убирает 2 malloc/free на токен. set_step однопоточный, thread_local безопасен, оба вектора
полностью перезаписываются каждый вызов.

## Патч 3a: sync_slots (gpu_experts.cpp:1131-1132, раз в токен при смене резидентности)
```
-    std::vector<int> freelist;
-    freelist.reserve(std::size_t(cap));
+    static thread_local std::vector<int> freelist;
+    freelist.clear();
+    freelist.reserve(std::size_t(cap));
```
(reserve на выросшем векторе — no-op; freelist.clear() на строке 1140 не трогать.)

## Патч 3b: refresh (expert_store.cpp:886-888, раз в period токенов)
```
-    std::vector<int> ord(std::size_t(cfg_.n_expert));
-    std::vector<int> need;
-    std::vector<int> free_slots;
+    static thread_local std::vector<int> ord, need, free_slots;
+    ord.resize(std::size_t(cfg_.n_expert));
+    need.clear();
+    free_slots.clear();
```
(need/free_slots чистятся по-слойно на 899/909, ord перезаписывается std::iota на 891 — вынос
поведение сохраняет.)

## Патч 3c (мелкий, опционально): set_graph_inputs (memex-fwd.cpp:1370, только qwen3next)
`std::vector<int32_t> z(nt,0)` для seq_ids каждый токен → тот же static thread_local + assign.

## Дед-код (только чистота, ноль перфа) — удалять в гигиеническую сборку
- gpu_static: step_mask_sent_ (hpp:657), LayerGraph::mapped/mapped_probed (hpp:531-532),
  GpuStaticStats::layer_readback_mapped (hpp:305), d_pad_/kv_pad_ (hpp:558/600).
- gpu_experts: out_mapped_/out_mapped_probed_ (hpp:503-504), readback_mapped() (hpp:280),
  st_.readback_mapped (hpp:154), (void)had; (cpp:812).
Проверено ревью как write-only/never-incremented. Удаление безопасно под пересборку + decode-check.

## НЕ трогать (агент проверил)
- 48 submit/токен (gpu_static:2496, gpu_experts:1682) = ~8,5 мс/токен накладных — САМЫЙ крупный
  теоретический рычаг, но СТРУКТУРНО заблокирован: MoE слоя L считает CPU между блоками карты,
  одним графом не собрать (STATE «Квин 25,6»). Fold-readback уже свёл 2 round-trip/слой в 1.
- Промежуточные host→host копии (gpu_static:547/2550, gpu_experts:1720/1800) = ~40-60 мкс/токен
  (<0,1%), каждая оправдана скоростью pinned-буфера. Не трогать.
- Предсказатель O(E²) в do_prefetch (expert_store.cpp:1257) — output-invariant, можно капнуть до
  top-B кандидатов, но нужен профиль сначала; только Coder-Next с --prefetch.
