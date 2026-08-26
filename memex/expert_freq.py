"""How unevenly are the 128 experts of each layer actually selected across tokens?

This is a different question from the one `lexi_plan.py` answered, and confusing the two cost me
a wrong conclusion. That script measured how routing mass is distributed *within* one token's
top-k - and found it flat, uniformly across all 48 layers. This one measures how often each
expert is chosen *across* tokens, which is the skew that matters for spending bits.

Why it matters, stated as the arithmetic rather than the intuition. For expert i with selection
frequency f, per-use error e and size s:

    bytes read per token  =  sum(f_i * s_i)     <- frequency weighted
    file size             =  sum(s_i)           <- NOT frequency weighted
    output error          ~  sum(f_i * e_i)     <- frequency weighted

Upgrading one expert changes error by f*de and per-token bytes by f*ds, so f cancels and the
per-token-byte budget cannot be improved by *choosing* which experts to upgrade. But it changes
file size by ds alone, so under a file-size budget frequency is exactly the right criterion.

The consequence, which is what this script quantifies: giving more bits to frequent experts is a
file-size win and a speed-neutral non-win, whereas taking bits away from rare experts is a
file-size win at almost no cost in either speed or quality - because bytes they are never asked
for are never read.

Indirect evidence that the skew is real, before measuring anything: llama-imatrix drops a
layer's expert tensor if any one of its 128 experts was never exercised, and it dropped 9 of 48
layers even over roughly 200k tokens - where the average expert should have been hit about 12k
times.
"""
import argparse
import io
import struct

import numpy as np


def read_probs(path, n_expert, max_rows_per_layer):
    """Full router distributions per layer: {layer: [n_rows, n_expert]}.

    The trace tags the pre-selection distribution as -(layer+1)-10000; rows are tokens.
    """
    out = {}
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                break
            tag, nu, nt = struct.unpack("<iii", hdr)
            n = nu * nt
            raw = f.read(4 * n)
            if len(raw) < 4 * n:
                break
            if tag > -10001 or nu != n_expert:
                continue
            layer = -tag - 10001
            cur = out.setdefault(layer, [])
            if sum(x.shape[0] for x in cur) < max_rows_per_layer:
                cur.append(np.frombuffer(raw, dtype=np.float32).reshape(-1, n_expert))
    return {k: np.concatenate(v, axis=0) for k, v in out.items() if v}


def counts_for(p, n_used):
    """How many times each expert lands in the top-n_used, over all rows."""
    idx = np.argpartition(-p, n_used - 1, axis=1)[:, :n_used]
    return np.bincount(idx.ravel(), minlength=p.shape[1]).astype(np.float64)


def plan_cost(freq, bits):
    """Per-token bytes and file size for a bit assignment, both relative to all-4-bit.

    freq is normalised so it sums to n_used: it is the expected number of times each expert is
    read per token. Size is taken as proportional to the bit width, which is close enough for
    ranking - the real IQ types carry a little metadata per row on top.
    """
    rel = bits / 4.0
    per_token = float((freq * rel).sum() / freq.sum())
    file_size = float(rel.mean())
    return per_token, file_size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", default=r"D:\MemeX\results\tr_p_code.bin")
    ap.add_argument("--experts", type=int, default=128)
    ap.add_argument("--used", type=int, default=8)
    ap.add_argument("--rows", type=int, default=20000)
    args = ap.parse_args()

    probs = read_probs(args.trace, args.experts, args.rows)
    if not probs:
        raise SystemExit("в трассе нет распределений роутера — снимай с MOE_TRACE_PROBS=1")
    layers = sorted(probs)
    rows = {l: probs[l].shape[0] for l in layers}
    print(f"слоёв: {len(layers)}, строк на слой: {min(rows.values())}–{max(rows.values())}")

    cnt = {l: counts_for(probs[l], args.used) for l in layers}

    # The headline numbers: how concentrated is selection, and is anyone never chosen at all.
    print("\nперекос выбора по слоям (доля выборов, которую забирают N самых частых):")
    print("слой   строк  никогда   top-16   top-32   top-64   макс/сред")
    agg_never = 0
    for l in layers:
        c = cnt[l]
        tot = c.sum()
        srt = np.sort(c)[::-1]
        never = int((c == 0).sum())
        agg_never += never
        print(f"{l:4d} {rows[l]:7d} {never:8d} "
              f"{srt[:16].sum() / tot:8.3f} {srt[:32].sum() / tot:8.3f} "
              f"{srt[:64].sum() / tot:8.3f} {srt[0] / c.mean():9.2f}")
    print(f"\nэкспертов, ни разу не выбранных, всего по модели: {agg_never} "
          f"из {len(layers) * args.experts}")

    # A rarely-selected expert is not the same thing as an unused one, and the difference is the
    # whole risk here: routing depends on the input, so an expert that is dead on this text may
    # be essential on another. Report the tail by threshold rather than by a hard zero.
    print("\nхвост: сколько экспертов забирают меньше доли X от равномерной (1/128 каждый):")
    for thr in (0.5, 0.25, 0.1, 0.02):
        tail = []
        for l in layers:
            c = cnt[l]
            share = c / c.sum() * args.experts / args.used * (args.used / args.experts)
            uniform = c.sum() / args.experts
            tail.append(int((c < thr * uniform).sum()))
        print(f"  < {thr:4.2f} от равномерной: в среднем {np.mean(tail):5.1f} "
              f"из {args.experts} на слой (мин {min(tail)}, макс {max(tail)})")

    # Two plans against the same baseline, so the trade is visible rather than argued.
    print("\nдва плана, всё относительно «все эксперты в 4 битах»:")
    for name, builder in (
        ("однородно 5 бит",
         lambda c: np.full(args.experts, 5.0)),
        ("твоя схема: 20 по 6, 60 по 5, 48 по 4",
         lambda c: np.where(np.argsort(np.argsort(-c)) < 20, 6.0,
                            np.where(np.argsort(np.argsort(-c)) < 80, 5.0, 4.0))),
        ("отнять у редких: нижние 48 в 2 бита",
         lambda c: np.where(np.argsort(np.argsort(-c)) < 80, 4.0, 2.0)),
        ("отнять у редких: нижние 32 в 3 бита",
         lambda c: np.where(np.argsort(np.argsort(-c)) < 96, 4.0, 3.0)),
    ):
        pts, fss = [], []
        for l in layers:
            c = cnt[l]
            freq = c / c.sum() * args.used
            pt, fs = plan_cost(freq, builder(c))
            pts.append(pt)
            fss.append(fs)
        print(f"  {name:38s} байт/токен {np.mean(pts):6.3f}   файл {np.mean(fss):6.3f}")


if __name__ == "__main__":
    main()
