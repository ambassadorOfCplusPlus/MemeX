"""Resumable parallel downloader for large HuggingFace files.

Three things this handles that the obvious approach does not:

  * `hf_hub_download` stalls at zero bytes on this connection, while plain HTTP
    Range requests work — so everything is built on ranges;
  * a HEAD on an LFS path reports the size of the redirect, not of the file, which
    silently makes a huge download look finished. The total comes from
    Content-Range on a one-byte range request instead;
  * the CDN throttles *per connection*, so a single stream leaves most of the link
    unused. Blocks are fetched by several workers at once, each writing at its own
    offset, and completed blocks are recorded in a sidecar file so an interrupted
    transfer resumes exactly where it stopped.
"""
import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request


def total_size(url, timeout=60):
    req = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        cr = r.headers.get("Content-Range")          # "bytes 0-0/2670000000"
        if cr and "/" in cr:
            tail = cr.rsplit("/", 1)[1].strip()
            if tail.isdigit():
                return int(tail)
        n = r.headers.get("Content-Length")
        return int(n) if n and int(n) > 1 else None


class Progress:
    def __init__(self, total, done_bytes):
        self.total = total
        self.start_done = done_bytes
        self.done = done_bytes
        self.t0 = time.time()
        self.lock = threading.Lock()
        self.last = 0.0

    def add(self, n):
        with self.lock:
            self.done += n
            now = time.time()
            if now - self.last < 15:
                return
            self.last = now
            rate = (self.done - self.start_done) / max(now - self.t0, 1e-9) / 1e6
            left = (self.total - self.done) / (rate * 1e6) / 60 if rate > 0 else 0
            print(f"  {self.done/1e9:6.2f} / {self.total/1e9:.2f} GB  "
                  f"{100*self.done/self.total:5.1f}%  {rate:6.2f} MB/s  "
                  f"ETA {left:5.1f} мин", flush=True)


def worker(url, path, blocks, block_bytes, total, prog, lock, state, state_path,
           timeout, retries_max):
    while True:
        with lock:
            if not blocks:
                return
            idx = blocks.pop()
        start = idx * block_bytes
        end = min(start + block_bytes, total) - 1
        want = end - start + 1
        got = 0
        attempt = 0
        while got < want:
            req = urllib.request.Request(
                url, headers={"Range": f"bytes={start+got}-{end}"})
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    with open(path, "r+b") as f:
                        f.seek(start + got)
                        while True:
                            buf = r.read(1 << 20)
                            if not buf:
                                break
                            f.write(buf)
                            got += len(buf)
                            prog.add(len(buf))
                attempt = 0
            except Exception as e:
                attempt += 1
                if attempt > retries_max:
                    print(f"блок {idx} не дошёл: {type(e).__name__}", flush=True)
                    with lock:
                        blocks.append(idx)     # let another worker retry it
                    return
                time.sleep(min(2 + attempt, 20))
        with lock:
            state["done"].append(idx)
            with open(state_path, "w") as f:
                json.dump(state, f)


def intact_blocks(path, total, block_bytes, probe=1 << 20):
    """Which blocks of an existing file already hold real data.

    A download that was interrupted mid-flight leaves a file of the correct total
    length whose missing pieces are still the zeros it was preallocated with. Those
    pieces are recognisable: quantised tensor data never contains a megabyte of one
    repeated byte, so any probe that is entirely uniform belongs to a hole.

    A block counts as intact only when *every* probe inside it carries data, so a
    block that is half-written is refetched rather than trusted.
    """
    done = []
    with open(path, "rb") as f:
        n_blocks = (total + block_bytes - 1) // block_bytes
        for idx in range(n_blocks):
            start = idx * block_bytes
            end = min(start + block_bytes, total)
            ok = True
            pos = start
            while pos < end:
                f.seek(pos)
                buf = f.read(min(probe, end - pos))
                if not buf or len(set(buf)) == 1:
                    ok = False
                    break
                pos += len(buf)
            if ok:
                done.append(idx)
    return done


def download(url, path, block_mb=32, workers=6, timeout=120, retries_max=50,
             repair=False):
    total = total_size(url)
    if not total:
        print("не удалось узнать размер файла", flush=True)
        return False
    print(f"размер: {total/1e9:.2f} GB, потоков: {workers}", flush=True)

    block_bytes = block_mb << 20
    n_blocks = (total + block_bytes - 1) // block_bytes
    state_path = path + ".parts"
    state = {"total": total, "block_bytes": block_bytes, "done": []}
    if os.path.exists(state_path) and os.path.exists(path):
        try:
            old = json.load(open(state_path))
            if old.get("total") == total and old.get("block_bytes") == block_bytes:
                state = old
        except Exception:
            pass
    if not os.path.exists(path) or os.path.getsize(path) != total:
        with open(path, "wb") as f:            # preallocate so workers can seek
            f.truncate(total)

    if repair and not state["done"]:
        print("сканирую файл на дыры...", flush=True)
        state["done"] = intact_blocks(path, total, block_bytes)
        kept = len(state["done"]) * block_bytes
        print(f"целых блоков: {len(state['done'])} из {n_blocks} "
              f"({kept/1e9:.2f} GB уже есть, качать {(total-kept)/1e9:.2f} GB)",
              flush=True)
        with open(state_path, "w") as f:
            json.dump(state, f)

    done = set(state["done"])
    todo = [i for i in range(n_blocks) if i not in done]
    if not todo:
        print("уже скачано полностью", flush=True)
        os.path.exists(state_path) and os.remove(state_path)
        return True
    print(f"осталось блоков: {len(todo)} из {n_blocks}", flush=True)

    prog = Progress(total, len(done) * block_bytes)
    lock = threading.Lock()
    todo.reverse()                              # pop() takes the lowest index
    threads = [threading.Thread(target=worker,
                                args=(url, path, todo, block_bytes, total, prog,
                                      lock, state, state_path, timeout,
                                      retries_max), daemon=True)
               for _ in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    ok = len(set(state["done"])) == n_blocks
    if ok:
        print(f"\nготово: {total/1e9:.2f} GB за "
              f"{(time.time()-prog.t0)/60:.1f} мин", flush=True)
        os.path.exists(state_path) and os.remove(state_path)
    else:
        print(f"\nнедокачано блоков: {n_blocks - len(set(state['done']))} — "
              f"запусти снова, продолжит с этого места", flush=True)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--revision", default="main")
    ap.add_argument("--block-mb", type=int, default=32)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--repair", action="store_true",
                    help="докачать только дыры в уже существующем файле")
    args = ap.parse_args()

    url = (f"https://huggingface.co/{args.repo}/resolve/{args.revision}/"
           f"{args.file}")
    os.makedirs(args.out_dir, exist_ok=True)
    path = os.path.join(args.out_dir, os.path.basename(args.file))
    print(f"url : {url}\npath: {path}", flush=True)
    sys.exit(0 if download(url, path, args.block_mb, args.workers,
                          repair=args.repair) else 1)


if __name__ == "__main__":
    main()
