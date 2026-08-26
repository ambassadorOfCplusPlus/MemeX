"""Build the Kaggle kernel that runs the memory experiments on a free T4.

Design constraints that shaped this:
  * no internet in the kernel (Kaggle enables it only after phone verification),
    so the donor model comes from a private Kaggle dataset and the corpus is
    generated synthetically inside the kernel;
  * the project code is embedded as base64, so there is nothing to clone;
  * the run order is cheap-to-expensive: calibrate, then a fast one-shot sweep to
    locate the setting where compression actually breaks the task, and only then
    the expensive streaming policy comparison at that setting. Doing this in the
    other order is what wasted hours on CPU.
"""
import argparse
import base64
import json
import os

CELLS = []


def cell(src):
    CELLS.append({"cell_type": "code", "execution_count": None, "metadata": {},
                  "outputs": [], "source": src.splitlines(keepends=True)})


def build(zip_b64, args):
    cell(f'''import base64, zipfile, io, os, glob, torch
print("GPU:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")
ZIP_B64 = "{zip_b64}"
os.makedirs("/kaggle/working/MemeX", exist_ok=True)
with zipfile.ZipFile(io.BytesIO(base64.b64decode(ZIP_B64))) as z:
    z.extractall("/kaggle/working/MemeX")
os.chdir("/kaggle/working/MemeX")
os.makedirs("/kaggle/working/out", exist_ok=True)
# Diagnose the environment instead of guessing: the previous run failed with an
# empty /kaggle/input and no accelerator, and both are invisible from outside.
print("--- /kaggle/input ---")
for root, dirs, files in os.walk("/kaggle/input"):
    depth = root.count("/") - 2
    if depth <= 2:
        print(" " * depth, root, "->", files[:6], "(+%d)" % max(0, len(files) - 6))
hits = glob.glob("/kaggle/input/**/config.json", recursive=True)
if not hits:  # a dataset uploaded with --dir-mode zip arrives as an archive
    for z in glob.glob("/kaggle/input/**/*.zip", recursive=True):
        print("распаковываю", z)
        with zipfile.ZipFile(z) as zf:
            zf.extractall("/kaggle/working/model")
    hits = glob.glob("/kaggle/working/model/**/config.json", recursive=True)
MODEL = os.path.dirname(hits[0]) if hits else None
print("модель:", MODEL)
if MODEL:
    print(sorted(os.listdir(MODEL))[:8])
else:
    raise SystemExit("датасет с моделью не примонтирован — дальше идти незачем")''')

    cell('''# синтетический корпус: факт заявлен рано, вопрос приходит через сотни токенов
!python memex/make_corpus.py --fiction /nonexistent \\
  --out /kaggle/working/corpus.txt --synth-chars 3000000''')

    cell(f'''# стадия B: базис сжатия хвоста (минуты на T4)
!python memex/transplant.py --model {{MODEL}} --text /kaggle/working/corpus.txt \\
  --out /kaggle/working/out --max-tokens {args.calib_tokens} --chunk-len 4096 --device cuda''')

    cell(f'''# ДЕШЁВО: найти настройку, где сжатие само по себе ломает задачу.
# Информативна та точка, где "без блокнота" почти всегда падает,
# а "с оракулом" почти всегда проходит.
!python bench/needle.py --model {{MODEL}} --results /kaggle/working/out \\
  --futattn /kaggle/working/out --haystack {args.haystack} --window {args.window} \\
  --ranks 32 64 128 --depths 0.2 0.5 0.8 --per-depth 2 --distractors 8 \\
  --notebook 64 --probe-len 128 --topk-probe 64 --device cuda''')

    cell(f'''# ДОРОГО: потоковое сравнение политик в найденной точке.
# Все ветки видят одни и те же кейсы и один и тот же итоговый бюджет слотов,
# поэтому различие только в том, ЧТО политика решает сохранить.
for rank in [{args.stream_ranks}]:
    print("=" * 70, "rank", rank, flush=True)
    !python memex/streaming_memory.py --model {{MODEL}} --results /kaggle/working/out \\
      --haystack {args.haystack} --window {args.window} --chunk 512 --rank $rank \\
      --cases {args.cases} --cap-max 48 --pressure-at {args.haystack // 2} \\
      --pressure-to 8 --retrieve 48 --device cuda''')

    cell('''import json, collections, os
p = "/kaggle/working/out/needle_log.jsonl"
if os.path.exists(p):
    t = collections.defaultdict(list)
    for line in open(p):
        r = json.loads(line)
        t[r["cond"]].append(r["ok"])
    print("=== одношаговый бенч ===")
    for c, v in sorted(t.items()):
        print(f"{c:>18}: {sum(v)}/{len(v)}")
p2 = "/kaggle/working/out/elastic_notebook.json"
if os.path.exists(p2):
    rows = json.load(open(p2))
    agg = collections.defaultdict(list)
    for r in rows:
        agg[r["mode"]].append(r["ok"])
    print("\\n=== потоковые политики ===")
    for m, v in agg.items():
        print(f"{m:>34}: {sum(v)}/{len(v)}")''')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default=r"D:\MemeX\memex_code.zip")
    ap.add_argument("--out-dir", default=r"D:\MemeX\kaggle_stream")
    ap.add_argument("--user", required=True)
    ap.add_argument("--slug", default="memex-memory-gpu")
    ap.add_argument("--dataset", required=True,
                    help="kaggle dataset holding the donor model")
    ap.add_argument("--calib-tokens", type=int, default=300_000)
    ap.add_argument("--haystack", type=int, default=6000)
    ap.add_argument("--window", type=int, default=384)
    ap.add_argument("--cases", type=int, default=4)
    ap.add_argument("--stream-ranks", default="32, 64")
    args = ap.parse_args()

    with open(args.zip, "rb") as f:
        zip_b64 = base64.b64encode(f.read()).decode()
    build(zip_b64, args)

    os.makedirs(args.out_dir, exist_ok=True)
    nb = {"cells": CELLS,
          "metadata": {"kernelspec": {"display_name": "Python 3",
                                      "language": "python", "name": "python3"},
                       "language_info": {"name": "python"}},
          "nbformat": 4, "nbformat_minor": 5}
    name = f"{args.slug}.ipynb"
    with open(os.path.join(args.out_dir, name), "w", encoding="utf-8") as f:
        json.dump(nb, f)
    meta = {"id": f"{args.user}/{args.slug}", "title": "MemeX memory GPU",
            "code_file": name, "language": "python", "kernel_type": "notebook",
            "is_private": True, "enable_gpu": True, "enable_tpu": False,
            "enable_internet": False,
            "dataset_sources": [args.dataset], "competition_sources": [],
            "kernel_sources": [], "model_sources": []}
    with open(os.path.join(args.out_dir, "kernel-metadata.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print(f"готово: {args.out_dir} ({len(zip_b64)/1024:.0f} КБ кода в base64), "
          f"ядро {meta['id']}, датасет {args.dataset}, интернет выключен")


if __name__ == "__main__":
    main()
