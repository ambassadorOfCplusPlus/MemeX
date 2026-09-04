# MemeX Kaggle: сбор датасета предсказателя экспертов (R1)

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
  (Add-ons -> Secrets) с токеном на чтение `ambassadorOfCplusPlus/memex-engine`.

## Проверенное окружение (2026-09-04, аккаунт ratmirgfxc)
- Kaggle API/kernels — доступ есть.
- GPU НЕ выдаётся (`torch.cuda.is_available()==False`, нет nvcc) — нужна верификация.
- Интернет в кернеле НЕ работает (`curl` к HF даёт 000) — нужна верификация.
- Модель UD-IQ3_XXS = 28.5 ГБ, влезает в `/kaggle/tmp` (сотни ГБ), не в `/kaggle/working` (21 ГБ).

## Запуск
    kaggle kernels push -p .
    kaggle kernels status ratmirgfxc/memex-dataset-r1
    kaggle kernels output ratmirgfxc/memex-dataset-r1 -p D:\MemeX\results
