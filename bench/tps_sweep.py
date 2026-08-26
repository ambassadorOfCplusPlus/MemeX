"""Measure real end-to-end generation speed across engine configurations.

Everything measured in this project so far has been per-component: expert dispatch, zoned
attention, precision moves. Those numbers are sound but they do not add up to a speed,
because what limits a token is whichever component is slowest at that moment. This runs the
whole engine and reads the tokens per second off it.

Two prompts, because the answer differs. The short one is ordinary generation. The long one
asks the model to rewrite code it was just given, which is the case where n-gram speculation
works - the output repeats the input, so a draft can be taken from the context for free. A
sweep on the short prompt alone would report that speculation does nothing.

Configurations are cumulative where that makes sense, so the table reads as a ladder rather
than a set of unrelated points.
"""
import argparse
import io
import os
import re
import statistics
import subprocess
import sys
import time

# The Vulkan tree, not the plain one. The plain build reports "not compiled with GPU offload
# support" and then silently ignores -ngl, which made an earlier sweep read as though moving
# attention onto the card changed nothing at all.
BIN = r"D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-cli.exe"
MODEL = r"D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf"

SHORT = "Write a Python function that merges two sorted lists."

# Long prompt: the model is handed code and asked to return it changed. The output shares
# most of its n-grams with the input, which is exactly when a context-derived draft pays.
LONG = """Here is a C++ function:

static bool intact_blocks(const char* path, size_t total, size_t block_bytes) {
    FILE* f = fopen(path, "rb");
    if (!f) return false;
    std::vector<char> probe(1 << 20);
    for (size_t off = 0; off < total; off += block_bytes) {
        fseek(f, (long)off, SEEK_SET);
        size_t got = fread(probe.data(), 1, probe.size(), f);
        if (got == 0) { fclose(f); return false; }
    }
    fclose(f);
    return true;
}

Rewrite this function so that it reports which blocks are missing instead of returning a
single boolean, keeps the same probing strategy, and handles a short final block. Output the
full function."""

# Fused MoE and graph reuse are already on by default in this fork - the flags exist only
# to switch them off (-no-fmoe, -no-gr) - so they appear here as checks that they help,
# not as additions.
GPU = ["-ngl", "99", "-ot", "exps=CPU", "-fa", "off"]
KV8 = ["-ctk", "q8_0", "-ctv", "q8_0"]
NGRAM = ["--spec-type", "ngram-mod:n_max=16,n_min=2,ngram_size_n=8"]

CONFIGS = [
    ("CPU, база", ["-ngl", "0", "-fa", "off"]),
    ("внимание на GPU, эксперты на CPU", GPU),
    ("то же без слитого MoE", GPU + ["-no-fmoe"]),
    ("то же без переиспользования графа", GPU + ["-no-gr"]),
    ("+ KV в q8_0", GPU + KV8),
    ("+ спекуляция на n-граммах", GPU + KV8 + NGRAM),
    ("+ 6 экспертов вместо 8", GPU + KV8 + NGRAM + ["-ser", "6,1.0"]),
    ("+ 4 эксперта вместо 8", GPU + KV8 + NGRAM + ["-ser", "4,1.0"]),
]

EVAL = re.compile(r"eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens")


def run(flags, prompt, n_gen, threads, ctx, reps):
    """Median tokens per second over `reps` runs, or None if the run failed."""
    out = []
    for _ in range(reps):
        cmd = [BIN, "-m", MODEL, "-p", prompt, "-n", str(n_gen), "-c", str(ctx),
               "-t", str(threads), "--seed", "1", "--no-display-prompt"] + flags
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800,
                               encoding="utf-8", errors="replace")
        except subprocess.TimeoutExpired:
            return None, "таймаут"
        text = (r.stdout or "") + (r.stderr or "")
        # The generation line is the second "eval time"; the first is the prompt.
        hits = EVAL.findall(text)
        if len(hits) < 2:
            return None, "нет строки eval time"
        ms, toks = float(hits[-1][0]), int(hits[-1][1])
        if ms <= 0 or toks <= 0:
            return None, "нулевое время"
        out.append(1000.0 * toks / ms)
    return statistics.median(out), None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", type=int, default=128)
    ap.add_argument("--ctx", type=int, default=8192)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--out", default=r"D:\MemeX\results\tps_sweep.txt")
    args = ap.parse_args()

    lines = []

    def say(s):
        print(s)
        lines.append(s)

    say(f"модель: {os.path.basename(MODEL)}")
    say(f"{args.tokens} токенов, контекст {args.ctx}, {args.threads} потока, "
        f"медиана из {args.reps}")
    say("")
    say(f"{'конфигурация':<38} {'короткий':>10} {'код':>10}")
    for name, flags in CONFIGS:
        row = []
        for prompt in (SHORT, LONG):
            tps, err = run(flags, prompt, args.tokens, args.threads, args.ctx, args.reps)
            row.append(f"{tps:10.2f}" if tps else f"{'—':>10}")
            if err:
                say(f"  ({name}: {err})")
        say(f"{name:<38} {row[0]} {row[1]}")

    io.open(args.out, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print(f"\nзаписано: {args.out}")


if __name__ == "__main__":
    main()
