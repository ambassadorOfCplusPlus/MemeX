"""Assemble three held-out texts for the routing-shift measurement.

The question the traces have to answer is whether the set of rarely-selected experts is a
property of the router or a property of the input. That only gets a clean answer if the three
texts are genuinely different material and none of them is the text the reference code trace was
taken on. So: this project's own Russian documentation, the fork's English documentation, and
fork source files that are not the ones `results/prompt_code.txt` was cut from.

Sizes are capped in bytes rather than tokens because the tracer decodes the whole prompt in one
llama_decode call, so the prompt has to fit in n_ctx. The cap is chosen to land each arm under
~20k tokens at the worst plausible bytes-per-token ratio (Cyrillic is the dense case).
"""
import argparse
import io
import os

RU_SOURCES = [
    r"C:\Users\User11\Desktop\MemeX\METHODS.md",
    r"C:\Users\User11\Desktop\MemeX\RESEARCH_DIGEST.md",
    r"C:\Users\User11\Desktop\MemeX\ARCHITECTURE.md",
    r"C:\Users\User11\Desktop\MemeX\ARCHITECTURE_PLAN.md",
    r"C:\Users\User11\Desktop\MemeX\TODO_MORNING.md",
    r"C:\Users\User11\Desktop\MemeX\README.md",
]

FORK = r"D:\MemeX\src\ik_llama.cpp"

EN_SOURCES = [
    os.path.join(FORK, "README.md"),
    os.path.join(FORK, "docs", "build.md"),
    os.path.join(FORK, "docs", "parameters.md"),
    os.path.join(FORK, "docs", "speculative.md"),
    os.path.join(FORK, "docs", "function-calling.md"),
    os.path.join(FORK, "CONTRIBUTING.md"),
    os.path.join(FORK, "LICENSE"),
]

# Deliberately not llama-build-context.* — that is what results/prompt_code.txt was cut from,
# i.e. the calibration side of this comparison. These are unrelated parts of the same tree.
CODE_SOURCES = [
    os.path.join(FORK, "src", "llama-sampling.cpp"),
    os.path.join(FORK, "src", "llama-vocab.cpp"),
    os.path.join(FORK, "src", "llama-grammar.cpp"),
    os.path.join(FORK, "src", "llama-mmap.cpp"),
    os.path.join(FORK, "src", "llama-arch.h"),
    os.path.join(FORK, "src", "llama-quantize.cpp"),
]


def read_text(path):
    with io.open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def build(sources, cap_bytes, out_path):
    """Round-robin over the sources so a single long file cannot dominate the arm."""
    chunks = [read_text(p) for p in sources]
    step = 4000  # characters taken per source per pass
    parts = []
    total = 0
    pos = [0] * len(chunks)
    used = [0] * len(chunks)
    while total < cap_bytes:
        moved = False
        for i, c in enumerate(chunks):
            if pos[i] >= len(c):
                continue
            piece = c[pos[i]:pos[i] + step]
            pos[i] += step
            enc = piece.encode("utf-8")
            if total + len(enc) > cap_bytes:
                # trim at a character boundary, never inside a UTF-8 sequence
                room = cap_bytes - total
                while len(enc) > room:
                    piece = piece[:-16]
                    enc = piece.encode("utf-8")
                if not piece:
                    total = cap_bytes
                    moved = True
                    break
            parts.append(piece)
            used[i] += len(enc)
            total += len(enc)
            moved = True
            if total >= cap_bytes:
                break
        if not moved:
            break
    text = "".join(parts)
    with io.open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    size = os.path.getsize(out_path)
    print(f"{out_path}: {size} bytes ({size / 1024:.1f} KB), {len(text)} chars")
    for p, u in zip(sources, used):
        if u:
            print(f"    {u:8d} B  {os.path.basename(p)}")
    return size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=r"D:\MemeX\data")
    ap.add_argument("--cap-ru", type=int, default=40000)
    ap.add_argument("--cap-en", type=int, default=62000)
    ap.add_argument("--cap-code", type=int, default=52000)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    build(RU_SOURCES, args.cap_ru, os.path.join(args.outdir, "shift_ru_tech.txt"))
    build(EN_SOURCES, args.cap_en, os.path.join(args.outdir, "shift_en_docs.txt"))
    build(CODE_SOURCES, args.cap_code, os.path.join(args.outdir, "shift_code_heldout.txt"))


if __name__ == "__main__":
    main()
