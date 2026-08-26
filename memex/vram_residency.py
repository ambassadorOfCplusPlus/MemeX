"""Simulate a live VRAM-resident expert set on real router traces.

The design being tested: keep a subset of experts resident in video memory, let the GPU compute
those while the CPU computes the rest in parallel, and refresh the resident set every few tokens
from observed usage - promoting experts that are being selected, evicting ones that are not.

Why this is worth simulating rather than arguing about. The whole win is proportional to the
hit rate: bytes read from RAM per token fall by exactly the fraction of expert selections the
resident set covers, and generation on this machine is 100% memory-bound, so bytes convert to
speed almost one for one. A hit rate of 35% and one of 15% are the difference between a design
worth weeks of Vulkan work and one that is not.

This is a DIFFERENT mechanism from the frequency-derived bit ladder that was closed earlier, and
the difference is the reason it deserves its own measurement. That one froze a set of "rare"
experts from a calibration run, and it died on distribution shift: the set derived from code
carried no information on Russian (24.1% of selections against 25.0% for a random set). Here the
set is refreshed online from what is actually being selected, so a change of language or domain
is something the policy follows rather than something that breaks it. The simulation therefore
reports the hit rate on each trace separately AND on a trace switched mid-stream, because the
adaptation is the claim under test.

Capacity comes from the hardware: about 3.8 GB of usable video memory, minus the KV cache
(roughly 200 MB at 2k context, 1.6 GB at 16k), leaves ~3.6 GB. One expert in the four-bit model
is about 2.5 MB, so roughly 1400 of 6144 experts fit - about 29 per layer out of 128.
"""
import argparse
import collections
import io
import struct

import numpy as np


def read_probs(path, n_expert, max_rows):
    """Router distributions per layer: {layer: [n_rows, n_expert]}, in trace order."""
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
            if sum(x.shape[0] for x in cur) < max_rows:
                cur.append(np.frombuffer(raw, dtype=np.float32).reshape(-1, n_expert))
    return {k: np.concatenate(v, axis=0) for k, v in out.items() if v}


def selections(p, n_used):
    """Per-row top-k expert ids, in trace order. Rows are tokens."""
    idx = np.argpartition(-p, n_used - 1, axis=1)[:, :n_used]
    return idx


def simulate(sel, capacity, period, window, policy, budget=0):
    """Walk the token stream, refreshing the resident set every `period` tokens.

    Returns (hit_rate, promotions, warmup_hit_rate_first_100).

    The resident set is chosen from a sliding window of recent selections, which is what an
    engine can actually observe - it cannot see the future, and using the whole trace to pick
    the set would measure an oracle rather than the design.
    """
    n_rows, n_used = sel.shape
    resident = set()
    recent = collections.deque(maxlen=window * n_used)
    hits = 0
    total = 0
    promotions = 0
    early_hits = 0
    early_total = 0

    for t in range(n_rows):
        row = sel[t]
        # Account BEFORE updating, so the hit rate reflects a set chosen without seeing this token.
        for e in row:
            total += 1
            if e in resident:
                hits += 1
            if t < 100:
                early_total += 1
                if e in resident:
                    early_hits += 1
        recent.extend(int(e) for e in row)

        if (t + 1) % period == 0 and recent:
            if policy == "lfu":
                counts = collections.Counter(recent)
                want = {e for e, _ in counts.most_common(capacity)}
            else:  # lru: most recently touched distinct experts
                want = set()
                for e in reversed(recent):
                    want.add(e)
                    if len(want) >= capacity:
                        break

            # A promotion is a 2.5 MB transfer over a 3.94 GB/s link, so the churn is a real
            # cost and not bookkeeping. Unbounded LRU wanted up to 208 MB per token - more than
            # the link physically carries in one token's time - which is why it has to be capped
            # rather than merely preferred against. With a budget, promote the experts the window
            # ranks highest and let the rest wait for the next refresh; the set converges a
            # little slower and the link stays inside its budget.
            new = want - resident
            if budget > 0 and len(new) > budget:
                if policy == "lfu":
                    counts = collections.Counter(recent)
                    order = sorted(new, key=lambda e: -counts[e])
                else:
                    seen, order = set(), []
                    for e in reversed(recent):
                        if e in new and e not in seen:
                            seen.add(e)
                            order.append(e)
                new = set(order[:budget])
                # Evict only as many as we promote, choosing the ones the window likes least.
                counts = collections.Counter(recent)
                victims = sorted(resident - want, key=lambda e: counts[e])[:len(new)]
                resident = (resident - set(victims)) | new
            else:
                resident = want
            promotions += len(new)

    return (hits / total if total else 0.0,
            promotions,
            early_hits / early_total if early_total else 0.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--traces", nargs="+", default=[
        r"D:\MemeX\results\tr_p_code.bin",
        r"D:\MemeX\results\tr_p_ru.bin",
        r"D:\MemeX\results\tr_p_en.bin",
    ])
    ap.add_argument("--experts", type=int, default=128)
    ap.add_argument("--used", type=int, default=8)
    ap.add_argument("--capacity", type=int, default=29, help="резидентных экспертов на слой")
    ap.add_argument("--period", type=int, default=3, help="обновлять набор каждые N токенов")
    ap.add_argument("--window", type=int, default=64, help="окно наблюдения в токенах")
    ap.add_argument("--rows", type=int, default=6000)
    ap.add_argument("--budget", type=int, default=0,
                    help="максимум подкачек за одно обновление (0 = без ограничения)")
    args = ap.parse_args()

    # Bytes per expert and the resulting speed, so the hit rate lands as tokens per second
    # rather than as an abstract fraction.
    EXPERT_MIB = 918.0          # experts read per token, mx1, measured
    OTHER_MIB = 801.0 + 48.0    # attention + head + router, read every token regardless
    BW_CPU = 24.8               # GB/s, measured
    BW_GPU = 37.1               # GB/s, measured
    base_ms = (EXPERT_MIB + OTHER_MIB) / 1024.0 / BW_CPU * 1000.0

    print(f"ёмкость {args.capacity} из {args.experts} экспертов на слой "
          f"({100.0 * args.capacity / args.experts:.0f}%), "
          f"обновление каждые {args.period} токенов, окно {args.window}")
    print(f"база без карты: {base_ms:.1f} мс/токен = {1000.0 / base_ms:.2f} ток/с\n")

    for path in args.traces:
        try:
            probs = read_probs(path, args.experts, args.rows)
        except OSError as e:
            print(f"{path}: не открылось — {e}")
            continue
        if not probs:
            print(f"{path}: нет распределений роутера")
            continue
        layers = sorted(probs)
        # Layer 47 has one row per ubatch in every trace we have - the graph prunes the last
        # layer to the tokens whose logits are needed - so it cannot be simulated.
        layers = [l for l in layers if probs[l].shape[0] > 100]

        for policy in ("lfu", "lru"):
            rates, proms, earlies = [], [], []
            for l in layers:
                sel = selections(probs[l], args.used)
                r, p, e = simulate(sel, args.capacity, args.period, args.window, policy, args.budget)
                rates.append(r); proms.append(p); earlies.append(e)
            hit = float(np.mean(rates))
            # Hits are served from video memory at its own bandwidth, in parallel with the CPU.
            # The CPU path is what remains, and it is the critical path as long as the GPU keeps
            # up - which the per-layer arithmetic says it does with roughly twice the margin.
            cpu_mib = EXPERT_MIB * (1.0 - hit) + OTHER_MIB
            gpu_mib = EXPERT_MIB * hit
            cpu_ms = cpu_mib / 1024.0 / BW_CPU * 1000.0
            gpu_ms = gpu_mib / 1024.0 / BW_GPU * 1000.0
            tok_ms = max(cpu_ms, gpu_ms)
            name = path.split("\\")[-1]
            print(f"{name:22s} {policy}: попаданий {hit:6.1%} "
                  f"(первые 100 токенов {float(np.mean(earlies)):5.1%}), "
                  f"подкачек {float(np.mean(proms)):6.0f} на слой")
            print(f"{'':22s}      CPU {cpu_ms:5.1f} мс, GPU {gpu_ms:4.1f} мс -> "
                  f"{1000.0 / tok_ms:5.2f} ток/с "
                  f"({100.0 * (base_ms / tok_ms - 1.0):+.0f}%)")
        print()

    # The claim that separates this from the closed static version: a set trained on one
    # distribution should recover after the input switches to another. Concatenating two traces
    # and reporting the hit rate right after the seam is the direct test of that.
    if len(args.traces) >= 2:
        print("проверка приспособления: код, затем русский, склеенные подряд")
        a = read_probs(args.traces[0], args.experts, args.rows)
        b = read_probs(args.traces[1], args.experts, args.rows)
        common = [l for l in sorted(set(a) & set(b)) if a[l].shape[0] > 100 and b[l].shape[0] > 100]
        for horizon in (10, 30, 100, 300):
            after = []
            for l in common:
                sa = selections(a[l], args.used)
                sb = selections(b[l], args.used)
                joined = np.concatenate([sa, sb], axis=0)
                seam = sa.shape[0]
                # Warm the policy on the first part, then measure only the window after the seam.
                r_all, _, _ = simulate(joined[:seam + horizon], args.capacity, args.period,
                                       args.window, "lfu", args.budget)
                r_pre, _, _ = simulate(sa, args.capacity, args.period, args.window, "lfu", args.budget)
                # Hits inside the horizon, backed out from the two cumulative rates.
                n_pre = seam * args.used
                n_all = (seam + horizon) * args.used
                h = (r_all * n_all - r_pre * n_pre) / max(1, n_all - n_pre)
                after.append(h)
            print(f"  через {horizon:4d} токенов после смены: попаданий {float(np.mean(after)):6.1%}")


if __name__ == "__main__":
    main()
