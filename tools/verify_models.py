"""Verify local GGUF files against the SHA256 that HuggingFace stores for them.

Why this exists: a download can finish with exactly the right byte count and still
be wrong. That happened here — a 17 GB model matched the expected size to the byte
and produced pure garbage, and only the hash showed why. Every subsequent hour of
tuning would have been spent on a broken file.

Matches local files to repo files by basename, so it works for any model pulled
from any of the usual GGUF repos.
"""
import argparse
import hashlib
import json
import os
import sys

from huggingface_hub import HfApi

REPOS = [
    "unsloth/gemma-4-26b-a4b-it-GGUF",
    "unsloth/Qwen3-Coder-Next-GGUF",
    "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
    "unsloth/Qwen3.6-35B-A3B-GGUF",
    "unsloth/Qwen3-30B-A3B-GGUF",
]


def hf_hashes(repos):
    api = HfApi()
    table = {}
    for repo in repos:
        try:
            info = api.model_info(repo, files_metadata=True)
        except Exception as e:
            print(f"  репозиторий {repo}: {type(e).__name__}", flush=True)
            continue
        for s in info.siblings:
            if not s.rfilename.endswith(".gguf"):
                continue
            lfs = s.lfs
            sha = None
            if lfs is not None:
                sha = getattr(lfs, "sha256", None) or (
                    lfs.get("sha256") if isinstance(lfs, dict) else None)
            table[os.path.basename(s.rfilename)] = {
                "repo": repo, "size": s.size, "sha256": sha}
    return table


def sha256_of(path, block=1 << 24):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(block)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+", help="локальные .gguf")
    ap.add_argument("--out", default=r"D:\MemeX\results\model_integrity.json")
    args = ap.parse_args()

    print("забираю эталонные хеши с HuggingFace...", flush=True)
    table = hf_hashes(REPOS)
    print(f"известно файлов: {len(table)}\n", flush=True)

    rows = []
    for path in args.files:
        name = os.path.basename(path)
        if not os.path.exists(path):
            print(f"{name}: нет файла")
            continue
        size = os.path.getsize(path)
        ref = table.get(name)
        if not ref:
            print(f"{name}: эталон не найден в известных репозиториях "
                  f"({size/1e9:.2f} GB) — проверить нечем")
            rows.append({"file": name, "verdict": "нет эталона", "size": size})
            continue
        if ref["size"] and size != ref["size"]:
            print(f"{name}: НЕДОКАЧАН — {size/1e9:.2f} из {ref['size']/1e9:.2f} GB")
            rows.append({"file": name, "verdict": "недокачан", "size": size,
                         "expected_size": ref["size"], "repo": ref["repo"]})
            continue
        print(f"{name}: размер совпал, считаю хеш ({size/1e9:.1f} GB)...", flush=True)
        got = sha256_of(path)
        ok = (got == ref["sha256"]) if ref["sha256"] else None
        verdict = "целый" if ok else ("БИТЫЙ" if ok is False else "хеша нет в HF")
        print(f"  -> {verdict}")
        rows.append({"file": name, "verdict": verdict, "sha256": got,
                     "expected": ref["sha256"], "repo": ref["repo"]})

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=1, ensure_ascii=False)
    bad = [r for r in rows if r["verdict"] in ("БИТЫЙ", "недокачан")]
    print(f"\nитог: проверено {len(rows)}, требуют перекачки {len(bad)}")
    for r in bad:
        print(f"  {r['file']} ({r['verdict']}) из {r.get('repo','?')}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
