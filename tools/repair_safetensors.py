"""Repair a safetensors file by re-fetching only the tensors that are damaged.

The GGUF repair tool works by finding holes - regions of preallocated zeros that a
download never filled. This file had no holes at all, yet seven tensors held
non-finite values and the whole-file hash was wrong, so the damage is corrupted
bytes rather than missing ones. Nothing in the file layout reveals where.

What does reveal it is the data itself: a trained weight tensor never contains NaN
or Inf, so any tensor that does is damaged, and the safetensors header gives its
exact byte range. Re-fetching those ranges costs tens of megabytes instead of
gigabytes, and the whole-file hash then says whether that was all of it.
"""
import argparse
import hashlib
import io
import json
import os
import struct
import urllib.request

import torch
from safetensors import safe_open


def header(path):
    with io.open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        hdr = json.loads(f.read(n))
    return hdr, 8 + n


def damaged_tensors(path):
    bad = []
    with safe_open(path, framework="pt") as f:
        for key in f.keys():
            t = f.get_tensor(key)
            if not torch.isfinite(t.float()).all():
                bad.append(key)
    return bad


def fetch_range(url, start, end, path, timeout=180, retries=12):
    got = 0
    want = end - start + 1
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                url, headers={"Range": f"bytes={start + got}-{end}"})
            with urllib.request.urlopen(req, timeout=timeout) as r, \
                    io.open(path, "r+b") as f:
                f.seek(start + got)
                while True:
                    buf = r.read(1 << 20)
                    if not buf:
                        break
                    f.write(buf)
                    got += len(buf)
            if got >= want:
                return True
        except Exception as e:
            print(f"    попытка {attempt + 1}: {type(e).__name__}", flush=True)
    return False


def sha256_of(path):
    h = hashlib.sha256()
    with io.open(path, "rb") as f:
        while True:
            b = f.read(1 << 24)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--name", default="model.safetensors")
    ap.add_argument("--pad-mb", type=int, default=1)
    args = ap.parse_args()

    hdr, data_start = header(args.file)
    true_size = data_start + max(v["data_offsets"][1] for k, v in hdr.items()
                                if k != "__metadata__")
    size = os.path.getsize(args.file)
    if size != true_size:
        print(f"обрезаю лишний хвост: {size} -> {true_size} "
              f"({(size - true_size) / 1e6:.1f} МБ)")
        with io.open(args.file, "r+b") as f:
            f.truncate(true_size)

    print("ищу повреждённые тензоры...", flush=True)
    bad = damaged_tensors(args.file)
    print(f"нефинитных тензоров: {len(bad)}")
    if not bad:
        print("повреждённых тензоров не видно")
    url = f"https://huggingface.co/{args.repo}/resolve/main/{args.name}"
    pad = args.pad_mb << 20
    total = 0
    for i, key in enumerate(bad, 1):
        a, b = hdr[key]["data_offsets"]
        s = max(0, data_start + a - pad)
        e = min(true_size - 1, data_start + b - 1 + pad)
        total += e - s + 1
        print(f"  [{i}/{len(bad)}] {key}: {(e - s + 1) / 1e6:.1f} МБ", flush=True)
        if not fetch_range(url, s, e, args.file):
            raise SystemExit(f"не удалось докачать {key}")
    print(f"докачано {total / 1e6:.1f} МБ")

    still = damaged_tensors(args.file)
    print(f"нефинитных после ремонта: {len(still)}")
    print("считаю хеш...", flush=True)
    print("sha256:", sha256_of(args.file))


if __name__ == "__main__":
    main()
