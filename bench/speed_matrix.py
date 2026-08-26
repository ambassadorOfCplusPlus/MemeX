"""Measure real tokens/second for every optimisation available without new code.

Speed is compared, not guessed: llama.cpp reports its own timings and we parse
them. This exists because the project already hit one case where a change that
reduced cache misses made generation slower — only measurement separates real
multipliers from plausible ones.

Levers covered, and why each matters on a 4 GB / PCIe x4 card:
  * where MoE experts live — moving a cold expert across x4 costs more than
    recomputing it on the CPU, so experts usually belong in RAM;
  * KV cache precision — the KV cache competes with the expert cache for the same
    ~2.3 GB of usable VRAM, so shrinking it buys expert residency;
  * batch sizes — the defaults are tuned for pure-GPU inference and are too small
    for hybrid CPU+GPU MoE;
  * speculative decoding — amortises weight reads over several accepted tokens,
    which is the dominant cost at batch 1;
  * threads — 4 physical cores, so oversubscription usually hurts.
"""
import argparse
import json
import os
import re
import subprocess
import time


def run(cmd, timeout):
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           errors="ignore")
        return p.stdout + p.stderr, time.time() - t0, p.returncode
    except subprocess.TimeoutExpired:
        return "TIMEOUT", time.time() - t0, -9


def parse_speed(out):
    """New CLI prints '[ Prompt: 21.3 t/s | Generation: 8.1 t/s ]'; older builds
    print 'eval time ... tokens per second'. Accept both."""
    m = re.search(r"Prompt:\s*([\d.]+)\s*t/s\s*\|\s*Generation:\s*([\d.]+)\s*t/s", out)
    if m:
        return float(m.group(1)), float(m.group(2))
    pp = gen = None
    for line in out.splitlines():
        m = re.search(r"eval time.*?([\d.]+)\s*tokens per second", line)
        if m:
            if "prompt eval" in line:
                pp = float(m.group(1))
            else:
                gen = float(m.group(1))
    return pp, gen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--llama-dir", default=r"D:\MemeX\llama")
    ap.add_argument("--model", required=True)
    ap.add_argument("--draft", default=None)
    ap.add_argument("--prompt", default="Опиши в двух предложениях, почему разреженная "
                                        "активация экспертов ускоряет генерацию.")
    ap.add_argument("--n-predict", type=int, default=64)
    ap.add_argument("--ctx", type=int, default=4096)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--only", default=None, help="подстрока: запустить лишь часть")
    ap.add_argument("--out", default=r"D:\MemeX\results\speed_matrix.json")
    args = ap.parse_args()

    cli = os.path.join(args.llama_dir, "llama-cli.exe")
    base = [cli, "-m", args.model, "-p", args.prompt, "-n", str(args.n_predict),
            "-c", str(args.ctx), "--no-warmup", "-st", "--temp", "0"]

    cfg = []
    # 1. где живут эксперты
    cfg.append(("база: эксперты в RAM, плотное на GPU, 4 потока",
                ["-ngl", "99", "-ncmoe", "999", "-t", "4"]))
    cfg.append(("часть экспертов на GPU (ncmoe=40)",
                ["-ngl", "99", "-ncmoe", "40", "-t", "4"]))
    cfg.append(("часть экспертов на GPU (ncmoe=20)",
                ["-ngl", "99", "-ncmoe", "20", "-t", "4"]))
    cfg.append(("всё на CPU, GPU не используется",
                ["-ngl", "0", "-t", "4"]))
    # 2. потоки
    cfg.append(("8 потоков (гипертрединг)",
                ["-ngl", "99", "-ncmoe", "999", "-t", "8"]))
    cfg.append(("3 потока (оставить ядро системе)",
                ["-ngl", "99", "-ncmoe", "999", "-t", "3"]))
    # 3. KV-кэш: освобождает VRAM под экспертов
    cfg.append(("+ KV в q8_0",
                ["-ngl", "99", "-ncmoe", "999", "-t", "4",
                 "-ctk", "q8_0", "-ctv", "q8_0"]))
    cfg.append(("+ KV в q4_0",
                ["-ngl", "99", "-ncmoe", "999", "-t", "4",
                 "-ctk", "q4_0", "-ctv", "q4_0"]))
    cfg.append(("+ flash attention",
                ["-ngl", "99", "-ncmoe", "999", "-t", "4", "-fa", "on"]))
    # 4. батчи: дефолты рассчитаны на чистый GPU и малы для CPU+GPU
    for b, ub in ((1024, 256), (2048, 512)):
        cfg.append((f"+ батчи b={b}, ub={ub}",
                    ["-ngl", "99", "-ncmoe", "999", "-t", "4",
                     "-b", str(b), "-ub", str(ub)]))
    # 5. загрузка целиком в RAM вместо mmap
    cfg.append(("+ без mmap (грузить в RAM целиком)",
                ["-ngl", "99", "-ncmoe", "999", "-t", "4", "--no-mmap"]))
    # 6. спекуляция: черновик того же семейства
    if args.draft and os.path.exists(args.draft):
        for nd in (4, 8):
            cfg.append((f"+ спекуляция черновиком, глубина {nd}",
                        ["-ngl", "99", "-ncmoe", "999", "-t", "4",
                         "-ctk", "q8_0", "-ctv", "q8_0",
                         "-md", args.draft, "--draft-max", str(nd), "-ngld", "99"]))

    rows = []
    for name, extra in cfg:
        if args.only and args.only.lower() not in name.lower():
            continue
        out, wall, rc = run(base + extra, args.timeout)
        pp, gen = parse_speed(out)
        rows.append({"config": name, "prompt_tok_s": pp, "gen_tok_s": gen,
                     "wall_s": round(wall, 1), "rc": rc, "args": extra})
        if gen:
            print(f"{name:<44} генерация {gen:6.2f} ток/с, префилл {pp or 0:6.1f}",
                  flush=True)
        else:
            why = "таймаут" if rc == -9 else f"не запустилось (rc={rc})"
            print(f"{name:<44} {why}", flush=True)
            for l in [x for x in out.splitlines() if x.strip()][-2:]:
                print("     |", l[:140], flush=True)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=1, ensure_ascii=False)
    good = [r for r in rows if r["gen_tok_s"]]
    if good:
        best = max(good, key=lambda r: r["gen_tok_s"])
        worst = min(good, key=lambda r: r["gen_tok_s"])
        print(f"\nлучшая конфигурация: {best['config']}")
        print(f"  {best['gen_tok_s']:.2f} ток/с против {worst['gen_tok_s']:.2f} "
              f"у худшей - разброс x{best['gen_tok_s']/worst['gen_tok_s']:.2f}")
        print(f"  флаги: {' '.join(best['args'])}")


if __name__ == "__main__":
    main()
