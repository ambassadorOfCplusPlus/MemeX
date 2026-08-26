"""Repair a partially corrupt model file by re-fetching only the damaged ranges.

Why this works. A multi-connection downloader preallocates the file to its full
length and then fills it piece by piece. If a piece never lands, the file still
has exactly the right size — it just has a hole of zeros where that piece
belongs. That is precisely what happened here: byte-for-byte correct length, wrong
SHA256, and a model that loaded and emitted garbage.

So the repair is: scan locally for holes (free, no network), re-download only
those byte ranges, then verify the whole-file hash against the one HuggingFace
stores. A 17 GB model with a few missing pieces costs a few hundred megabytes to
fix instead of a full re-download.

If no holes are found, the damage is not a hole (swapped or truncated pieces), and
the tool says so instead of pretending — then a full re-download is the only
honest option.
"""
import argparse
import hashlib
import json
import os
import sys
import urllib.request

from huggingface_hub import HfApi


def expected_meta(repo, filename):
    api = HfApi()
    info = api.model_info(repo, files_metadata=True)
    for s in info.siblings:
        if os.path.basename(s.rfilename) == os.path.basename(filename):
            lfs = s.lfs
            sha = None
            if lfs is not None:
                sha = getattr(lfs, "sha256", None) or (
                    lfs.get("sha256") if isinstance(lfs, dict) else None)
            return s.rfilename, s.size, sha
    return None, None, None


def find_holes(path, probe=1 << 20, min_hole=1 << 20):
    """Return byte ranges that look unwritten.

    A quantised tensor never contains megabytes of identical bytes, so a long run
    of a single value (zeros from preallocation, or 0xFF from some tools) marks a
    piece that never arrived. Scanning is done in 1 MB probes and merged into
    ranges, which is fast enough to sweep tens of gigabytes off disk.
    """
    size = os.path.getsize(path)
    holes = []
    start = None
    with open(path, "rb") as f:
        pos = 0
        while pos < size:
            f.seek(pos)
            buf = f.read(probe)
            if not buf:
                break
            blank = buf.count(buf[0:1] * len(buf)) == 1 or len(set(buf)) == 1
            if blank:
                if start is None:
                    start = pos
            else:
                if start is not None:
                    if pos - start >= min_hole:
                        holes.append((start, pos - 1))
                    start = None
            pos += len(buf)
    if start is not None and size - start >= min_hole:
        holes.append((start, size - 1))
    return size, holes


def fetch_range(url, start, end, path, timeout=180, retries=20):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
            with urllib.request.urlopen(req, timeout=timeout) as r, \
                    open(path, "r+b") as f:
                f.seek(start)
                got = 0
                while True:
                    buf = r.read(1 << 20)
                    if not buf:
                        break
                    f.write(buf)
                    got += len(buf)
            if got == end - start + 1:
                return True
            start += got            # partial range: continue from where it stopped
        except Exception as e:
            print(f"    попытка {attempt+1}: {type(e).__name__}", flush=True)
    return False


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
    ap.add_argument("--file", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--pad-mb", type=int, default=4,
                    help="сколько МБ добрать по краям каждой дыры")
    ap.add_argument("--scan-only", action="store_true")
    ap.add_argument("--skip-hash", action="store_true")
    args = ap.parse_args()

    rfile, exp_size, exp_sha = expected_meta(args.repo, args.file)
    if not rfile:
        sys.exit("файл не найден в репозитории")
    size = os.path.getsize(args.file)
    print(f"локально {size/1e9:.2f} GB, по HF {exp_size/1e9:.2f} GB")
    if exp_size and size != exp_size:
        print("размеры расходятся — это недокачка, а не дыры; нужна докачка целиком")
    print("сканирую на дыры...", flush=True)
    size, holes = find_holes(args.file)
    total_hole = sum(e - s + 1 for s, e in holes)
    print(f"найдено участков: {len(holes)}, суммарно {total_hole/1e6:.1f} МБ "
          f"({100*total_hole/size:.3f}% файла)")
    for s, e in holes[:12]:
        print(f"  {s/1e9:8.3f} – {e/1e9:8.3f} GB  ({(e-s+1)/1e6:.1f} МБ)")
    if len(holes) > 12:
        print(f"  ... и ещё {len(holes)-12}")

    if args.scan_only:
        return
    if not holes:
        print("дыр нет — повреждение иного рода, точечный ремонт не поможет")
        sys.exit(2)

    url = f"https://huggingface.co/{args.repo}/resolve/main/{rfile}"
    pad = args.pad_mb << 20
    print(f"\nдокачиваю {len(holes)} участков...", flush=True)
    for i, (s, e) in enumerate(holes, 1):
        s2, e2 = max(0, s - pad), min(size - 1, e + pad)
        print(f"  [{i}/{len(holes)}] {(e2-s2+1)/1e6:.1f} МБ", flush=True)
        if not fetch_range(url, s2, e2, args.file):
            sys.exit(f"не удалось докачать участок {s2}-{e2}")

    if args.skip_hash:
        print("готово (хеш не проверялся по просьбе)")
        return
    print("\nсчитаю итоговый хеш...", flush=True)
    got = sha256_of(args.file)
    print(f"локально: {got}\nэталон  : {exp_sha}")
    if exp_sha and got == exp_sha:
        print("ВЕРДИКТ: файл восстановлен полностью")
    else:
        print("ВЕРДИКТ: хеш всё ещё не совпадает — остались другие повреждения")
        sys.exit(3)


if __name__ == "__main__":
    main()
