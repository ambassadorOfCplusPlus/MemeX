"""Generate a self-contained Kaggle notebook (project code embedded as base64)
and the kernel metadata, so the whole MemeX GPU run can be pushed with
`kaggle kernels push` — no dataset wiring, no UI clicks.
"""
import argparse
import base64
import json
import os

CODE_CELL = '''import base64, zipfile, io, os, torch
print("GPU:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")
ZIP_B64 = "{zip_b64}"
os.makedirs("/kaggle/working/MemeX", exist_ok=True)
with zipfile.ZipFile(io.BytesIO(base64.b64decode(ZIP_B64))) as z:
    z.extractall("/kaggle/working/MemeX")
os.chdir("/kaggle/working/MemeX")
os.makedirs("/kaggle/working/out", exist_ok=True)
os.makedirs("/kaggle/working/data", exist_ok=True)
print(sorted(os.listdir(".")))'''

SETUP_CELL = '''!pip install -q -U transformers huggingface_hub
from huggingface_hub import snapshot_download
snapshot_download("Qwen/Qwen3-0.6B", local_dir="/kaggle/working/Qwen3-0.6B")

import urllib.request
text = ""
for u in ["https://www.gutenberg.org/files/2600/2600-0.txt",
          "https://www.gutenberg.org/files/1342/1342-0.txt",
          "https://www.gutenberg.org/files/84/84-0.txt"]:
    try:
        text += urllib.request.urlopen(u, timeout=90).read().decode("utf-8", "ignore")
    except Exception as e:
        print("skip", u, e)
open("/kaggle/working/data/calibration.txt", "w", encoding="utf-8").write(text)
print("fiction chars:", len(text))
!python memex/make_corpus.py --fiction /kaggle/working/data/calibration.txt \\
  --out /kaggle/working/data/corpus_mixed.txt --synth-chars 4000000 --fiction-chars 4000000'''

TRANSPLANT_CELL = '''!python memex/transplant.py --model /kaggle/working/Qwen3-0.6B \\
  --text /kaggle/working/data/corpus_mixed.txt --out /kaggle/working/out \\
  --max-tokens {calib_tokens} --chunk-len 4096 --device cuda'''

SALIENCE_CELL = '''!python memex/future_attention.py --model /kaggle/working/Qwen3-0.6B \\
  --text /kaggle/working/data/corpus_mixed.txt --out /kaggle/working/out/future_attn \\
  --max-tokens {futattn_tokens} --device cuda
!python memex/salience_probe.py --data /kaggle/working/out/future_attn --holdout 4'''

NEEDLE_CELL = '''!python bench/needle.py --model /kaggle/working/Qwen3-0.6B \\
  --results /kaggle/working/out --futattn /kaggle/working/out/future_attn \\
  --haystack {haystack} --window {window} --sinks 4 --notebook {notebook} \\
  --ranks {ranks} --depths 0.1 0.4 0.7 0.9 --per-depth {per_depth} \\
  --distractors {distractors} --probe-len 128 --topk-probe 64 --device cuda'''

SUMMARY_CELL = '''import json, collections, shutil
tally = collections.defaultdict(list)
for line in open("/kaggle/working/out/needle_log.jsonl"):
    r = json.loads(line)
    tally[r["cond"]].append(r["ok"])
print("=== needle accuracy ===")
for cond, v in sorted(tally.items()):
    print(f"{cond:>20}: {sum(v)}/{len(v)}  ({sum(v)/len(v):.2f})")
# keep artifacts small enough to download via `kaggle kernels output`
shutil.rmtree("/kaggle/working/Qwen3-0.6B", ignore_errors=True)
shutil.rmtree("/kaggle/working/out/future_attn", ignore_errors=True)
shutil.rmtree("/kaggle/working/data", ignore_errors=True)'''


def cell(src):
    return {"cell_type": "code", "execution_count": None, "metadata": {},
            "outputs": [], "source": src.splitlines(keepends=True)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default=r"D:\MemeX\memex_code.zip")
    ap.add_argument("--out-dir", default=r"D:\MemeX\kaggle_push")
    ap.add_argument("--user", required=True)
    ap.add_argument("--slug", default="memex-gpu")
    ap.add_argument("--calib-tokens", type=int, default=1_000_000)
    ap.add_argument("--futattn-tokens", type=int, default=400_000)
    ap.add_argument("--haystack", type=int, default=16000)
    ap.add_argument("--window", type=int, default=1024)
    ap.add_argument("--notebook", type=int, default=128)
    ap.add_argument("--ranks", default="64 128")
    ap.add_argument("--per-depth", type=int, default=4)
    ap.add_argument("--distractors", type=int, default=16)
    args = ap.parse_args()

    with open(args.zip, "rb") as f:
        zip_b64 = base64.b64encode(f.read()).decode()

    nb = {
        "cells": [
            cell(CODE_CELL.format(zip_b64=zip_b64)),
            cell(SETUP_CELL),
            cell(TRANSPLANT_CELL.format(calib_tokens=args.calib_tokens)),
            cell(SALIENCE_CELL.format(futattn_tokens=args.futattn_tokens)),
            cell(NEEDLE_CELL.format(haystack=args.haystack, window=args.window,
                                    notebook=args.notebook, ranks=args.ranks,
                                    per_depth=args.per_depth,
                                    distractors=args.distractors)),
            cell(SUMMARY_CELL),
        ],
        "metadata": {"kernelspec": {"display_name": "Python 3",
                                    "language": "python", "name": "python3"},
                     "language_info": {"name": "python"}},
        "nbformat": 4, "nbformat_minor": 5,
    }

    os.makedirs(args.out_dir, exist_ok=True)
    nb_name = "memex-gpu.ipynb"
    with open(os.path.join(args.out_dir, nb_name), "w", encoding="utf-8") as f:
        json.dump(nb, f)
    meta = {
        "id": f"{args.user}/{args.slug}",
        "title": "MemeX GPU",
        "code_file": nb_name,
        "language": "python",
        "kernel_type": "notebook",
        "is_private": True,
        "enable_gpu": True,
        "enable_tpu": False,
        "enable_internet": True,
        "dataset_sources": [],
        "competition_sources": [],
        "kernel_sources": [],
        "model_sources": [],
    }
    with open(os.path.join(args.out_dir, "kernel-metadata.json"), "w") as f:
        json.dump(meta, f, indent=1)
    kb = len(zip_b64) / 1024
    print(f"wrote {args.out_dir}: {nb_name} (embedded code {kb:.0f} KB base64), "
          f"kernel-metadata.json -> {meta['id']}")


if __name__ == "__main__":
    main()
