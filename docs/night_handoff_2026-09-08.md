# Ночной хендофф 8→9 сент 2026 (утренние задачи)

## Что идёт ночью (автономно)
- **deepseek4 full-warm cap-58 + identity-предсказатель** — строит ~62 ГБ warm на SSD (C:/ds4warm),
  потом декод 16 токенов. Лог: `bench/DS4_FULLWARM_2026-09-08.log` (+ raw `_raw_`).
  Цель: покрытие ~89% модели на SSD+RAM → HDD-промахи вниз → ожидание ×5-10 (с ~0.1 к ~1-2 ток/с).
- **overnight_finish.sh** (`bench/`, PID см. лог) — ждёт конца deepseek → мерит fit-модели в ПИКОВЫХ
  конфигах → пишет `bench/OVERNIGHT_TABLE_2026-09-08.log` → усыпляет ПК (дедлайн-гарды epoch, сон ≤~04:30).
  `_no_sleep` удалён (авто-сон включён по выбору юзера). Создать `bench/_no_sleep` чтобы отменить сон.

## ✅ Сделано и провалидировано (build 20:29 + регрессия 16/16 + аудит-агент 0 находок)
- **qwen3moe `ggml_moe_up_gate` фьюз** (build_step + prefill build()) — bit-exact, регрессия 16/16.
- **gpt-oss head-split** (gpu_static.cpp alloc_head_split, concat dim0) + включён на карту (can_gstat/allowlist).
- **deepseek4 identity R1-предсказатель** (`tmp/ds4_r1_identity.bin`, ген `tmp/gen_r1_identity.py`).
  Нулевой R1 был СЛОМАН (все sc=0 → префетч [0..B-1]); identity = top-B приближённого роутера.

## 🔑 КОРРЕКТНЫЙ ПИК qwen3moe (исправление «поверхностного» замера)
Мой замер `--zoned` дал 10.04 = чистый CPU-тир (--zoned НЕ офлайн-флаг, на ctx=512 ~0).
**Пик 19.8 = полный офлайн на карту:**
```
--no-repack --no-ref --gpu-static-layers --gpu-experts --resident 0 --resident-period 32
--tokens 512 --gen 192 -t 8 -f prompt_2000.txt   (2 прогона, первый отбросить)
```
build-bt2022 — Vulkan-сборка (работает). При `--gpu-experts` эксперты на КАРТЕ, up_gate фьюз (CPU-путь)
пик не двигает — фьюз ускоряет CPU-тир (~в пределах шума). Это в overnight_finish.sh.

## 📋 Утренние задачи (по приоритету)
1. **Прочитать `bench/OVERNIGHT_TABLE_2026-09-08.log`** — финальная таблица fit-моделей + deepseek4 hit-rate.
2. **gemma4 SWA-narrowing** — интегрировать из воркри `D:/MemeX/src/ik_llama.cpp/.claude/wt_swa`
   (ветка `agent/gemma4-swa-narrow`, `git diff` в воркри, +91/−21, ОДИН файл memex-fwd.cpp).
   Bit-точно (self-review чист). Нужно: build → **регрессия 16/16 gemma4** → замер @8k ctx (там +15-22%).
   ⚠️ Реальные строки в HEAD: build_gemma4_step:2721, aim_kv_reads:1265 (не dirty-tree номера).
3. **gpt-oss MXFP4_R8** — headline (5.7→9-12 ожидание). Runtime `-rtr` блокирован: token_embd 1104МиБ>1024
   идёт на Vulkan_Host (загрузчик, llama.cpp:4322 buft_input=host). Путь: ОФЛАЙН R8-GGUF —
   собрать `llama-quantize` (build_safe -Targets llama-quantize) → `llama-quantize gpt-oss-20b.gguf
   gpt-oss-20b-r8.gguf MXFP4_R8` → запуск с mmap (эксперты R8, token_embd на mmap/CPU).
   R8 = чистый 8-строчный интерливинг (0 потери точности, iqk_quantize.cpp:5350).
4. **deepseek4 динамич warm-промоушен** (агент finding): warm СТАТИЧЕН (prime:775). Счётчик в do_map:746
   → повторные HDD-промахи промотить HDD→SSD (~8.5× на повтор). Ответ-сохраняющий.

## Прочие находки агентов (docs/optimization_agents_2026-09-08.md)
- gemma4 q8_0 K-кеш (−47% K, argmax-safe, под флаг); min_experts/thresh (−12%/эксперт, проверить прод).
- deepseek4 MLA подтверждён оптимальным; HDD seek-bound (число промахов>байты).
