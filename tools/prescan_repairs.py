"""Pre-compute the intact-block map for files that need repair.

Scanning a 30 GB file off a spinning disk takes minutes, and the downloader would
otherwise do it again when the repair actually starts. Writing the map into the
same `.parts` sidecar the downloader already understands means the scan happens
once: `fetch_big.py --repair` finds the sidecar and goes straight to fetching.
"""
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from memex.fetch_big import intact_blocks, total_size          # noqa: E402

TARGETS = [
    (r"D:\Qwen3-Coder-Next-UD-IQ3_XXS.gguf", "unsloth/Qwen3-Coder-Next-GGUF"),
    (r"D:\Qwen3.6-35B-A3B-UD-Q6_K.gguf", "unsloth/Qwen3.6-35B-A3B-GGUF"),
    (r"D:\Qwen3-Coder-Next-Q4_K_S.gguf", "unsloth/Qwen3-Coder-Next-GGUF"),
]
BLOCK = 32 << 20

def main():
    plan = []
    for path, repo in TARGETS:
        if not os.path.exists(path):
            print(f"{os.path.basename(path)}: нет файла")
            continue
        total = os.path.getsize(path)
        print(f"{os.path.basename(path)}: сканирую {total/1e9:.1f} GB...", flush=True)
        done = intact_blocks(path, total, BLOCK)
        n_blocks = (total + BLOCK - 1) // BLOCK
        kept = len(done) * BLOCK
        need = total - kept
        state = {"total": total, "block_bytes": BLOCK, "done": done}
        with io.open(path + ".parts", "w") as f:
            json.dump(state, f)
        print(f"  целых {len(done)}/{n_blocks} блоков — есть {kept/1e9:.2f} GB, "
              f"качать {need/1e9:.2f} GB ({100*need/total:.1f}%)", flush=True)
        plan.append({"file": os.path.basename(path), "repo": repo,
                     "have_gb": round(kept/1e9, 2), "need_gb": round(need/1e9, 2)})
    print("\nитого докачать: "
          f"{sum(p['need_gb'] for p in plan):.2f} GB "
          f"вместо {sum(p['have_gb']+p['need_gb'] for p in plan):.2f} GB заново")
    out = r"D:\MemeX\results\repair_plan.json"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with io.open(out, "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=1, ensure_ascii=False)

if __name__ == "__main__":
    main()
