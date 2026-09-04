# MemeX Kaggle: сбор датасета предсказателя экспертов (R1)

## ЖДЁТ ПОЛЬЗОВАТЕЛЯ (два блокера уровня аккаунта, снять может только он)
1. Верифицировать аккаунт Kaggle по телефону -> это включает GPU T4 и интернет в кернелах.
   Без этого ноутбук не соберёт форк и не скачает модель (проверено: GPU не выдаётся, curl к HF = 000).
2. Дать Kaggle доступ к приватному форку memex-engine: сделать репо публичным ЛИБО
   добавить в Kaggle секрет GITHUB_PAT с read-доступом (решение пользователя, не сделано за него).

Когда оба сняты: `kaggle kernels push -p .` и rerun `ratmirgfxc/memex-dataset-r1`,
затем `kaggle kernels output ratmirgfxc/memex-dataset-r1 -p D:\MemeX\results`.

Путь А (наш форк memex-engine + CUDA). Ноутбук `memex_dataset_kaggle.ipynb`:
клонирует ветку `memex`, собирает `llama-memex-fwd` с `-DGGML_CUDA=ON`
(с CPU-only фолбэком), качает `Qwen3-Coder-Next-UD-IQ3_XXS.gguf` (28.5 ГБ) в
`/kaggle/tmp`, снимает `MEMEX_HIDDEN_TRACE`+`MEMEX_EXPERT_TRACE` на 6 промтах
(своё продолжение, `--gen 2`), обучает R1 (`train_r1.py`) на всех текстах,
печатает таблицу переноса между текстами и сохраняет `r1_corr_multi.bin`.

## Предусловия аккаунта Kaggle (иначе не работает)
- Аккаунт верифицирован по телефону: без этого Kaggle не даёт ни GPU (T4), ни интернет.
- Accelerator: GPU T4 x2; Internet: On.
- Приватный форк: сделать публичным ЛИБО добавить секрет `GITHUB_PAT`
  (Add-ons -> Secrets) с токеном на чтение `ambassadorOfCplusPlus/memex-engine-public`.

## Проверенное окружение (2026-09-04, аккаунт ratmirgfxc)
- Kaggle API/kernels — доступ есть.
- GPU НЕ выдаётся (`torch.cuda.is_available()==False`, нет nvcc) — нужна верификация.
- Интернет в кернеле НЕ работает (`curl` к HF даёт 000) — нужна верификация.
- Модель UD-IQ3_XXS = 28.5 ГБ, влезает в `/kaggle/tmp` (сотни ГБ), не в `/kaggle/working` (21 ГБ).

## Запуск
    kaggle kernels push -p .
    kaggle kernels status ratmirgfxc/memex-dataset-r1
    kaggle kernels output ratmirgfxc/memex-dataset-r1 -p D:\MemeX\results
