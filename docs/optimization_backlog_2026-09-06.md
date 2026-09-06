# Бэклог оптимизаций — новые приёмы 2025-26 (агент-разведка, 6 сент)

Ранжировано по (выигрыш на НАШЕМ железе: i3 4c/8t, 32 ГБ DDR4-2400 24,8 ГБ/с, RX6500XT 4 ГБ Vulkan
256 МБ BAR) × выполнимость. Всё атакует байты-читаемые-на-токен — наш реальный предел.

## Tier 1 — наибольшая ценность

### 1. REAP — обрезка экспертов (СТРАТЕГИЧЕСКИЙ ключ к DeepSeek)
Router-weighted Expert Activation Pruning: скорит экспертов по gate×activation-norm, удаляет
низкоценные НАВСЕГДА. Почти без потерь на 25%, юзабельно на 50% (код/генерация, 20B-1T).
Даёт стандартную меньшую модель → квантуем нашим пайплайном. Линейно сокращает пул экспертов →
больше резидентно в ОЗУ, меньше стриминга с диска. **Для DeepSeek: обрезанный вариант может ВЛЕЗТЬ
в ОЗУ и дать 5-8 tok/s вместо <1.** На HF есть готовые ...-REAP-XXB.
- https://arxiv.org/abs/2510.13999 · https://github.com/CerebrasResearch/reap
- https://docs.vllm.ai/projects/llm-compressor/en/latest/examples/reap_expert_pruning/

### 2. Смешанная точность экспертов (HOBBIT / DynaExq)
Горячие эксперты в норм-кванте, холодные в 2-бит; на cache-miss грузить НИЗКОБИТНУЮ копию вместо
стойла на полной. HOBBIT: до 9,93× декода vs SOTA-офлоадинг. DynaExq: онлайн бюджет бит по EMA-
hotness + гистерезис, неблокирующие swap. Ложится на наш частотный счётчик + R1 + 3-tier store —
добавить вторую (2-бит) версию эксперта и miss-путь к ней.
- https://arxiv.org/pdf/2411.01433 (HOBBIT) · https://arxiv.org/html/2511.15015 (DynaExq)

### 3. Быстрые IQK-кванты ik_llama (drop-in, мы уже на форке)
IQ4_KS, IQ2_KS, IQ4_K_R4 (row-interleaved) — выделенные быстрые CPU GEMV/GEMM (150-350% PP).
Меньше bpw = меньше байт/токен. ОСТОРОЖНО с trellis _KT (IQ2_KT ~2.125 bpw лучше по perplexity, НО
декод ~5× тяжелее — слабый 4-ядерный i3 может не переварить; мерить llama-sweep-bench, не предполагать).
- https://github.com/ikawrakow/ik_llama.cpp · QTIP https://arxiv.org/abs/2406.11235

## Tier 2 — дешевле, но реальные
### 4. Симметричный q8_0 KV-кэш → fused Flash-Attention на AMD
Асимметричный KV (q4_0/f16) ОТКЛЮЧАЕТ fused FA на AMD; симметричный q8_0/q8_0 держит его, режет KV
буфер ~47% без потери качества. Освобождённый VRAM → больше статики или больше SWA-ring.
- https://github.com/ggml-org/llama.cpp/discussions/22411

### 5. Офлоад экспертов на ПРЕФИЛЛЕ большими батчами
-b 4096 -ub 4096, offload-batch-size: на префилле GEMM экспертов на GPU бьёт CPU GEMV выше пары
сотен токенов. Помогает префиллу, не декоду (ограничено 256 МБ BAR).

## Отброшено (хайп для нашего железа)
- FP4/MXFP4/NVFP4 — нет FP4-железа на RX6500XT, только память, без edge над IQ4.
- coopmat/coopmat2 — RDNA2 без WMMA, это NVIDIA-only; для AMD только ACO + GEMV-тюнинг.
- EAGLE-3/спекулятивка — MoE-верификация активирует ЛИШНИЕ эксперты = чтения на узком месте;
  net-negative пока эксперты не станут резидентными (т.е. после REAP+mixed-precision).
- PowerInfer neuron-sparsity — дублирует наш expert-level hot/cold tiering, не стоит ретулинга.

## Порядок: REAP → mixed-precision cold-experts (на R1) → IQK-кванты → симметричный q8_0 KV.
Все бьют байты/токен — реальный предел машины. Deprioritize FP4/coopmat/спекуляцию.
