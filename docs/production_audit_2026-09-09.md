# Продакшен-аудит memex-fwd (9 сент) — что готово, что подключить

Агент-аудит по реальному исходнику (memex-fwd.cpp 11241 строк + sampler/expert_store/gpu_static/hw_caps).

## ГЛАВНОЕ: продукт уже есть, но не подключён
- **`run_chat` (memex-fwd.cpp:6626)** — полный интерактивный чат: `apply_chat` (:6031) через
  `llama_chat_apply_template` + GGUF-фолбэк (read_chat_template :698), стриминг, KV prefix-reuse
  (common_prefix :6620), проверки контекста/токенизации. **НО НЕТ ВЫЗОВА** (grep + признания в коде
  :6657, :10955). Флаг `--chat` (:7126) ставит bool, читаемый только в отказах --zoned/--resident.
  => `--chat` молча гоняет бенчмарк на хардкод-промпте. Весь usable-путь = МЁРТВЫЙ КОД.
- **Сэмплер (sampler.hpp:33-199)** — temp/top-k/top-p/min-p/repeat penalty, mt19937_64, inverse-CDF.
  Подключён (:6155-6377), CLI (:7119-7125). Дефолт greedy (temp 0) для 16/16. НЕ ГЭП.

## ТОП-ЗАДАЧА ПРОДАКШЕНА: подключить --chat → run_chat (~0.5 дня)
Точный код (из аудита): после сбора весов `w` (~:8016) и создания бэкенда `be`/`buft` (:8587), перед
one-shot (:8591):
```cpp
if (chat) {
  if (!arch_q3) { printf("--chat poka tolko qwen3moe\n"); llama_free_model(model); return 1; }
  const int n_ctx_chat = n_ctx_req > 0 ? n_ctx_req : 4096;
  const int rc = run_chat(model, model_path, h, w, be, buft, n_ctx_chat, samp,
                          system_prompt, "", n_predict, min_experts, expert_thresh,
                          nullptr, 0, bandwidth_gbs, zopt);
  llama_free_model(model); return rc;
}
```
+ гейтить ref-контекст `if (want_ref && !chat)` (:7961) и `need_oneshot && !chat` (:8618).
Все входы в scope (samp:6872, system_prompt:6874, n_ctx_req:6875, n_predict:6903, bandwidth_gbs:6909).
КАВЕАТ: run_chat юзает простой Generator БЕЗ ExpertStore/gpu_static тиринга (:6657) — v1 чат корректен
но CPU-путь (медленнее harness). Подключение модулей+placement в run_chat — фолоуап (~1-2д).

## РЕАЛИЗОВАНО (агент, ветка agent/prod-hardening commit a0cb14fe, +18/−5, bit-exact)
Seed-коммит ae643fc7 = текущее uncommitted состояние (HEAD 7348a440 отстаёт на +1328 строк!).
- generate() диагностика → stderr (:6120,6125,6167,6223,6238) — чистый поток токенов.
- fflush(stdout) после токена (:6149) — стриминг не зависит от глобального _IONBF.
- load_prefetch гард двойного вызова (expert_store.cpp:1117) — иначе std::terminate на второй thread.
ИНТЕГРАЦИЯ: git show a0cb14fe → применить в рабочее дерево (диф против текущего состояния, ложится чисто).

## РОАДМАП продакшена (value÷effort)
Дёшево, эта неделя: 1) --chat→run_chat (0.5д, ТОП); 2) stderr/stdout LOG()-макрос на 550 printf
(машинные строки ESTORE_* оставить на stdout); 3) отказ без -m вместо хардкод-пути (0.25д);
4) gpu_static shutdown() на провале init_layers (:1042, освобождать VRAM).
Средне: 5) null-чеки ggml_new_tensor в gpu_static (6 сайтов :1289-1322); 6) чат с тир-модулями (1-2д).
Крупно (если сетевой продукт): 7) single-user HTTP (OpenAI /v1/chat/completions + SSE, cpp-httplib
уже в дереве) поверх generate()/run_chat, ~2-4д. Конкурентность — очередь (один KV-кеш + IO-потоки).

## ВЕРДИКТ
Минимум «production-ready для локального/single-user» — МАЛ и достижим за неделю: сложное уже есть
и качественное (сэмплер/шаблоны/стриминг/KV-reuse/graceful-errors/очистка ресурсов). Гэп — не
способность, а ДОСТИЖИМОСТЬ+гигиена. Пункты 1-3 + фиксы = usable локальный чат-ассистент.
Чего неделя НЕ даст: конкурентный сетевой сервер (2-4д поверх, сток llama-server несовместим —
наш движок не зовёт llama_decode).
