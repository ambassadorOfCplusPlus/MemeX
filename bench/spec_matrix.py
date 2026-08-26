"""Measure the optimisations the first matrix missed: speculation and static
expert residency.

The first sweep established the base (best: everything on CPU, 6.3 tok/s) but its
speculation arms never ran - build b10470 removed `--draft-max` in favour of
`--spec-draft-n-max`, so those two configs died on argument parsing. Speculation is
the one lever that can pass the memory-bandwidth ceiling without touching
quantisation: the weights are read once per verify pass and several tokens come out
of it, so the bytes-per-token figure falls by the acceptance count.

This build also exposes speculation types that need no draft model at all (n-gram
families, which re-propose fragments already present in the context) plus EAGLE-3
and MTP heads. And `-ot` allows pinning chosen expert tensors to the GPU
permanently, which is the profitable form of expert residency here: the transfer
happens once at load instead of once per token, and a per-token transfer over PCIe
3.0 x4 was measured at 1.7 tok/s - worse than computing on the CPU.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from bench.speed_matrix import parse_speed, run                    # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--llama-dir", default=r"D:\MemeX\llama")
    ap.add_argument("--model", required=True)
    ap.add_argument("--draft", default=r"D:\smartstock\models\qwen3-0.6b-q4_k_m.gguf")
    ap.add_argument("--prompt", default="Напиши функцию на Python, которая считает "
                                        "скользящее среднее по списку чисел, с "
                                        "проверкой аргументов и парой примеров.")
    ap.add_argument("--n-predict", type=int, default=128)
    ap.add_argument("--ctx", type=int, default=4096)
    ap.add_argument("--timeout", type=int, default=1500)
    ap.add_argument("--only", default=None)
    ap.add_argument("--out", default=r"D:\MemeX\results\spec_matrix.json")
    args = ap.parse_args()

    cli = os.path.join(args.llama_dir, "llama-cli.exe")
    # the winning base from the first sweep: no GPU offload at all
    base = [cli, "-m", args.model, "-p", args.prompt, "-n", str(args.n_predict),
            "-c", str(args.ctx), "--no-warmup", "-st", "--temp", "0",
            "-ngl", "0", "-t", "4"]

    cfg = [("повтор базы (CPU, 4 потока)", [])]

    # 1. draft model of the same family
    if os.path.exists(args.draft):
        for n in (3, 5, 8):
            cfg.append((f"черновик 0.6B, глубина {n}",
                        ["--spec-type", "draft-simple", "-md", args.draft,
                         "--spec-draft-n-max", str(n)]))
        cfg.append(("черновик 0.6B, глубина 5, черновик на GPU",
                    ["--spec-type", "draft-simple", "-md", args.draft,
                     "--spec-draft-n-max", "5", "-ngld", "99"]))
    else:
        print(f"черновик не найден: {args.draft}")

    # 2. speculation that needs no draft model
    for t in ("ngram-cache", "ngram-simple", "ngram-mod", "ngram-map-k"):
        cfg.append((f"без черновика: {t}", ["--spec-type", t]))

    # 3. static expert residency: transfer once at load, not once per token
    cfg.append(("плотное на GPU, все эксперты в RAM (-ot)",
                ["-ngl", "99", "-ot", "exps=CPU"]))
    cfg.append(("эксперты первых 4 слоёв закреплены в VRAM",
                ["-ngl", "99", "-ot", r"blk\.[0-3]\.ffn_.*_exps=Vulkan0",
                 "-ot", "exps=CPU"]))
    cfg.append(("эксперты первых 8 слоёв закреплены в VRAM",
                ["-ngl", "99", "-ot", r"blk\.[0-7]\.ffn_.*_exps=Vulkan0",
                 "-ot", "exps=CPU"]))

    # 4. the two best levers together
    if os.path.exists(args.draft):
        cfg.append(("закреплённые эксперты + черновик",
                    ["-ngl", "99", "-ot", r"blk\.[0-7]\.ffn_.*_exps=Vulkan0",
                     "-ot", "exps=CPU", "--spec-type", "draft-simple",
                     "-md", args.draft, "--spec-draft-n-max", "5"]))
        cfg.append(("черновик + ngram-cache вместе",
                    ["--spec-type", "draft-simple,ngram-cache", "-md", args.draft,
                     "--spec-draft-n-max", "5"]))

    rows = []
    for name, extra in cfg:
        if args.only and args.only.lower() not in name.lower():
            continue
        out, wall, rc = run(base + extra, args.timeout)
        pp, gen = parse_speed(out)
        rows.append({"config": name, "prompt_tok_s": pp, "gen_tok_s": gen,
                     "wall_s": round(wall, 1), "rc": rc, "args": extra})
        if gen:
            print(f"{name:<46} генерация {gen:6.2f} ток/с, префилл {pp or 0:6.1f}",
                  flush=True)
        else:
            why = "таймаут" if rc == -9 else f"не запустилось (rc={rc})"
            print(f"{name:<46} {why}", flush=True)
            for line in [x for x in out.splitlines() if x.strip()][-3:]:
                print("     |", line[:150], flush=True)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=1, ensure_ascii=False)

    good = [r for r in rows if r["gen_tok_s"]]
    if good:
        best = max(good, key=lambda r: r["gen_tok_s"])
        b0 = next((r["gen_tok_s"] for r in rows if "повтор базы" in r["config"]
                   and r["gen_tok_s"]), None)
        print(f"\nлучшая: {best['config']} = {best['gen_tok_s']:.2f} ток/с")
        if b0:
            print(f"  против базы {b0:.2f} -> x{best['gen_tok_s'] / b0:.2f}")
        print(f"  флаги: {' '.join(best['args'])}")


if __name__ == "__main__":
    main()
