#!/usr/bin/env python3
"""
fit_bandwidth.py -- Part 3: fit ms_per_token = a + b * bytes_per_token.

  slope  b  -> effective bandwidth = 1 / b   (GB/s if bytes are in GB)
  interp a  -> fixed per-token cost that is NOT memory traffic (ms)

Reads the measured CSV written by bench/bw_fit.ps1 and the byte budget computed
by byte_budget.py (imported, so the two can never drift apart).
"""

import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import byte_budget as bb  # noqa: E402

CSV = r"C:\Users\User11\Desktop\MemeX\bench\bw_fit.csv"
GB = 1e9  # decimal GB, to match the "24.8 GB/s" reference figure


def ols(xs, ys):
    n = len(xs)
    if n < 2:
        return None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    if sxx == 0:
        return None
    b = sxy / sxx
    a = my - b * mx
    pred = [a + b * x for x in xs]
    sse = sum((y - p) ** 2 for y, p in zip(ys, pred))
    sst = sum((y - my) ** 2 for y in ys)
    r2 = 1.0 - sse / sst if sst > 0 else float("nan")
    # standard errors
    se = None
    if n > 2:
        s2 = sse / (n - 2)
        se_b = (s2 / sxx) ** 0.5
        se_a = (s2 * (1.0 / n + mx * mx / sxx)) ** 0.5
        se = (se_a, se_b)
    return a, b, r2, pred, se


def load_measured():
    if not os.path.exists(CSV):
        print("MISSING: %s -- Part 2 never produced measurements. This is a\n"
              "missing measurement, not a zero; no fit is possible." % CSV)
        return []
    rows = []
    with open(CSV, newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            rows.append(r)
    return rows


def report():
    rows = load_measured()
    if not rows:
        return 1

    # --- byte budgets, recomputed from the files
    budget = {}
    expert_full = {}
    nonexpert = {}
    for p in [
        r"D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf",
        r"D:\Qwen3-Coder-30B-A3B-mx1.gguf",
        r"D:\Qwen3-Coder-30B-A3B-mx2.gguf",
        r"D:\Qwen3-Coder-30B-A3B-mx3.gguf",
        r"D:\Qwen3-Coder-30B-A3B-mx4.gguf",
        r"D:\Qwen3-Coder-30B-A3B-mx5.gguf",
        r"D:\Qwen3-Coder-30B-A3B-mx6.gguf",
    ]:
        if not os.path.exists(p):
            continue
        r = bb.analyse(p)
        k = os.path.basename(p)
        budget[k] = r["bpt"]
        expert_full[k] = r["full"]["experts"]
        nonexpert[k] = r["bpt"] - r["tok"]["experts"]

    ok = [r for r in rows if r["status"] == "OK"]
    bad = [r for r in rows if r["status"] != "OK"]

    print("=" * 100)
    print("MEASURED ms/token (status != OK is a MISSING measurement, not a zero)")
    print("=" * 100)
    print("%-34s %-8s %4s %6s %6s %10s %9s" %
          ("model", "tag", "thr", "rep", "extra", "ms/tok", "tok/s"))
    for r in rows:
        st = "" if r["status"] == "OK" else ("   <-- " + r["status"])
        print("%-34s %-8s %4s %6s %6s %10s %9s%s" %
              (r["model"][:34], r["tag"], r["threads"], r["rep"], r["extra"] or "-",
               r["ms_per_tok"] or "-", r["tok_per_s"] or "-", st))
    print()
    for r in bad:
        print("NOT MEASURED: %s t=%s %s -- %s" %
              (r["model"], r["threads"], r["extra"], r["status"]))
    if bad:
        print()

    # ------------------------------------------------- ARM A: cross-model fit
    print("=" * 100)
    print("ARM A -- cross-model fit at t=4")
    print("=" * 100)
    sweep = [r for r in ok if r["tag"] == "sweep"]
    by_model = {}
    for r in sweep:
        by_model.setdefault(r["model"], []).append(float(r["ms_per_tok"]))

    xs, ys, names = [], [], []
    print("%-34s %10s %10s %10s %10s" %
          ("model", "GB/tok", "rep1 ms", "rep2 ms", "mean ms"))
    for m in sorted(by_model, key=lambda k: budget.get(k, 0)):
        if m not in budget:
            print("%-34s  no byte budget -- skipped" % m[:34])
            continue
        v = by_model[m]
        mean = sum(v) / len(v)
        print("%-34s %10.4f %10.2f %10s %10.2f" %
              (m[:34], budget[m] / GB, v[0],
               ("%.2f" % v[1]) if len(v) > 1 else "-", mean))
        xs.append(budget[m] / GB)
        ys.append(mean)
        names.append(m)
    print()

    spread = (max(xs) - min(xs)) / min(xs) * 100 if xs else 0
    print("lever arm: bytes/token spans %.3f..%.3f GB (%.0f%% of the smallest)"
          % (min(xs), max(xs), spread) if xs else "no points")
    if xs and spread < 40:
        print("WARNING: with this little spread in x the intercept is poorly")
        print("         conditioned. Treat 'a' as an estimate with wide error bars.")
    print()

    fit = ols(xs, ys)
    if fit:
        a, b, r2, pred, se = fit
        print("fit: ms/token = %.3f + %.4f * GB/token" % (a, b))
        print("  slope    %.4f ms per GB  ->  effective bandwidth %.2f GB/s" % (b, 1000.0 / b))
        print("  intercept %.3f ms/token of fixed, non-bandwidth cost" % a)
        print("  R^2      %.5f   (n=%d)" % (r2, len(xs)))
        if se:
            print("  std err: intercept +/- %.3f ms, slope +/- %.4f (-> %.2f..%.2f GB/s)"
                  % (se[0], se[1], 1000.0 / (b + se[1]), 1000.0 / (b - se[1])))
        print()
        print("  residuals (measured - fitted):")
        for n, x, y, p in zip(names, xs, ys, pred):
            print("    %-34s %8.4f GB %8.2f ms  fit %8.2f  resid %+7.2f ms (%+5.1f%%)"
                  % (n[:34], x, y, p, y - p, 100.0 * (y - p) / y))
        print()
        for n, x, y in zip(names, xs, ys):
            print("  implied per-model bandwidth if 100%% memory-bound: %-30s %.2f GB/s"
                  % (n[:30], x / (y / 1000.0)))
    print()

    # ------------------------------------------------- ARM C: expert override
    print("=" * 100)
    print("ARM C -- active-expert override on one file (orthogonal lever)")
    print("=" * 100)
    exp = [r for r in ok if r["tag"] == "experts"]
    if not exp:
        print("not measured")
    else:
        m = exp[0]["model"]
        xs2, ys2 = [], []
        print("%-6s %10s %10s" % ("k_exp", "GB/tok", "ms/tok"))
        for r in sorted(exp, key=lambda r: int(r["extra"].lstrip("_e"))):
            k = int(r["extra"].lstrip("_e"))
            bpt = nonexpert[m] + expert_full[m] * k / 128.0
            print("%-6d %10.4f %10.2f" % (k, bpt / GB, float(r["ms_per_tok"])))
            xs2.append(bpt / GB)
            ys2.append(float(r["ms_per_tok"]))
        f2 = ols(xs2, ys2)
        if f2:
            a2, b2, r22, _, _ = f2
            print()
            print("fit: ms/token = %.3f + %.4f * GB/token" % (a2, b2))
            print("  slope -> %.2f GB/s effective bandwidth" % (1000.0 / b2))
            print("  intercept %.3f ms/token   R^2 %.5f" % (a2, r22))
            print("  (same weights, same attention/head traffic: this isolates the")
            print("   expert-read term and is immune to per-model quant differences)")
    print()

    # ------------------------------------------------- ARM B: thread scaling
    print("=" * 100)
    print("ARM B -- thread scaling on mx1 (independent check on the intercept)")
    print("=" * 100)
    thr = [r for r in ok if r["tag"] == "threads"]
    if not thr:
        print("not measured")
    else:
        thr.sort(key=lambda r: int(r["threads"]))
        base = None
        print("%6s %10s %10s %10s %10s" % ("thr", "ms/tok", "tok/s", "speedup", "GB/s impl"))
        m = thr[0]["model"]
        gbt = budget.get(m, 0) / GB
        for r in thr:
            ms = float(r["ms_per_tok"])
            if base is None:
                base = ms
            print("%6s %10.2f %10.2f %10.3f %10.2f" %
                  (r["threads"], ms, float(r["tok_per_s"]), base / ms, gbt / (ms / 1000.0)))
        print()
        d = dict((int(r["threads"]), float(r["ms_per_tok"])) for r in thr)
        if 2 in d and 4 in d:
            g = (d[2] - d[4]) / d[2] * 100.0
            print("  gain from 2 -> 4 threads: %.1f%%" % g)
            print("  If generation were saturating DRAM at t=2 this would be ~0%.")
            print("  It is not: %.1f%% of the t=2 time was still thread-scalable." % g)
        if 4 in d and 8 in d:
            print("  gain from 4 -> 8 threads: %.1f%% (8 threads = SMT/oversubscribed)"
                  % ((d[4] - d[8]) / d[4] * 100.0))
    print()

    # --------------------------------------- do the two methods agree?
    print("=" * 100)
    print("CONSISTENCY: do the arms agree, and is either physically possible?")
    print("=" * 100)
    print("A fitted slope can never imply a bandwidth ABOVE the machine's real")
    print("streaming bandwidth (24.8 GB/s measured). A slope that does is wrong,")
    print("and it inflates the intercept it is paired with by exactly as much.")
    print()
    if fit:
        print("  ARM A slope -> %.2f GB/s  %s" %
              (1000.0 / b, "UNPHYSICAL (> 24.8)" if 1000.0 / b > 24.8 else "plausible"))
        print("        intercept %.2f +/- %.2f ms" % (a, se[0] if se else float('nan')))
    if exp and f2:
        print("  ARM C slope -> %.2f GB/s  %s" %
              (1000.0 / b2, "UNPHYSICAL (> 24.8)" if 1000.0 / b2 > 24.8 else "plausible"))
        print("        intercept %.2f ms" % a2)
    print()
    if thr:
        d = dict((int(r["threads"]), float(r["ms_per_tok"])) for r in thr)
        m = thr[0]["model"]
        gbt = budget.get(m, 0) / GB
        print("  Arm B is the referee. If a fixed non-memory cost of I ms were real,")
        print("  the memory part at each thread count would be (t - I) ms, implying:")
        for I, lbl in ((a if fit else 0.0, "Arm A intercept"), (a2 if (exp and f2) else 0.0, "Arm C intercept")):
            row = []
            for t in sorted(d):
                rem = d[t] - I
                row.append("t=%d:%.1f" % (t, gbt / (rem / 1000.0)) if rem > 0 else "t=%d:inf" % t)
            worst = max(gbt / ((d[t] - I) / 1000.0) for t in sorted(d) if d[t] - I > 0)
            print("    I=%5.2f ms (%s): %s GB/s -> peak %.1f %s"
                  % (I, lbl, " ".join(row), worst,
                     "IMPOSSIBLE" if worst > 24.8 else "OK"))
        print()
        print("  Any intercept large enough to push the implied bandwidth past")
        print("  24.8 GB/s is refuted by the hardware, regardless of its R^2.")
    print()

    # ------------------------------------------------- headline
    print("=" * 100)
    print("HEADLINE")
    print("=" * 100)
    mx1 = "Qwen3-Coder-30B-A3B-mx1.gguf"
    if mx1 in by_model and mx1 in budget:
        ms = sum(by_model[mx1]) / len(by_model[mx1])
        gbt = budget[mx1] / GB
        print("mx1: %.4f GB/token, %.2f ms/token measured" % (gbt, ms))
        print("     implied bandwidth if 100%% memory-bound: %.2f GB/s" % (gbt / (ms / 1000.0)))
        for bw in (24.8,):
            t_mem = gbt / bw * 1000.0
            print("     at %.1f GB/s the memory traffic alone costs %.2f ms = %.0f%% of the time"
                  % (bw, t_mem, 100.0 * t_mem / ms))
            print("     -> non-memory residue %.2f ms (%.0f%%)" % (ms - t_mem, 100.0 * (ms - t_mem) / ms))
            print("     -> ceiling if ALL non-memory cost were removed: %.2f tok/s" % (1000.0 / t_mem))
        print("     bytes/token needed for 20 tok/s at %.1f GB/s: %.3f GB" % (24.8, 24.8 * 0.050))
    return 0


if __name__ == "__main__":
    sys.exit(report())
