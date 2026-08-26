"""How many experts each layer actually needs, from the router's own distribution.

We refuted the global version of this already: a single relative threshold has no free zone on
this model, because the fifth through eighth experts sit clustered around a third of the top
one, so a threshold either touches nobody or cuts half of them. Measured by the strictest test
available - 24 of 24 generated tokens identical at 0.30, 0 of 24 at 0.35.

But that was one threshold for all forty-eight layers, and layers are not alike. This asks the
per-layer question instead: how much of the routing mass does each layer put in its top-k, and
what would it cost to keep fewer experts *there*. Nothing here needs a run on the model - the
full distribution is already in the trace.

The cost model is deliberately crude and stated as such: dropping experts whose renormalised
weight sums to m perturbs the layer's output by something on the order of m, because the
output is a weighted sum and the dropped weight gets redistributed over the kept experts.
It is a proxy for ranking layers, not a prediction of perplexity - which is why the plan it
produces has to be measured afterwards rather than trusted.
"""
import argparse
import io
import struct

import numpy as np


def read_probs(path, n_expert, max_rows_per_layer=4000):
    """Full router distributions per layer: {layer: [n_rows, n_expert]}.

    The trace tags the pre-selection distribution as -(layer+1)-10000. Rows are tokens.
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
            a = np.frombuffer(raw, dtype=np.float32).reshape(-1, n_expert)
            cur = out.setdefault(layer, [])
            if sum(x.shape[0] for x in cur) < max_rows_per_layer:
                cur.append(a)
    return {k: np.concatenate(v, axis=0) for k, v in out.items() if v}


def mass_curve(p, n_used):
    """Average share of the top-`n_used` mass that the top-k carries, for k = 1..n_used."""
    srt = -np.sort(-p, axis=1)[:, :n_used]
    total = srt.sum(axis=1, keepdims=True)
    total[total == 0] = 1.0
    cum = np.cumsum(srt, axis=1) / total
    return cum.mean(axis=0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", default=r"D:\MemeX\results\tr_p_code.bin")
    ap.add_argument("--experts", type=int, default=128)
    ap.add_argument("--used", type=int, default=8)
    # Total routing mass we are willing to discard across the whole model, summed over layers.
    # Expressed per layer on average, because that is the number one can reason about.
    ap.add_argument("--budget", type=float, default=0.02)
    args = ap.parse_args()

    probs = read_probs(args.trace, args.experts)
    if not probs:
        raise SystemExit("в трассе нет распределений роутера — снимай с MOE_TRACE_PROBS=1")
    layers = sorted(probs)
    print(f"слоёв с распределениями: {len(layers)}, "
          f"строк на слой: {min(probs[l].shape[0] for l in layers)}–"
          f"{max(probs[l].shape[0] for l in layers)}")

    curves = {l: mass_curve(probs[l], args.used) for l in layers}

    print(f"\nдоля массы в top-k, по слоям (k = 1..{args.used}):")
    print("слой " + " ".join(f"{k + 1:>6}" for k in range(args.used)))
    for l in layers[:6] + layers[len(layers) // 2 - 1:len(layers) // 2 + 1] + layers[-4:]:
        row = " ".join(f"{curves[l][k]:6.3f}" for k in range(args.used))
        print(f"{l:4d} {row}")

    # Greedy water-filling: repeatedly drop one expert from whichever layer loses the least
    # mass by it, until the average loss reaches the budget. Same shape of decision as the bit
    # ladder, and for the same reason - the marginal cost differs across layers.
    k = {l: args.used for l in layers}
    lost = {l: 0.0 for l in layers}
    while True:
        best, best_cost = None, None
        for l in layers:
            if k[l] <= 1:
                continue
            # dropping to k-1 loses this much of the layer's mass
            cost = 1.0 - curves[l][k[l] - 2]
            if best_cost is None or cost < best_cost:
                best, best_cost = l, cost
        if best is None:
            break
        trial = sum(1.0 - curves[l][k[l] - 2 + (1 if l == best else 0)] for l in layers)
        # average over layers of the mass each one would lose
        avg = sum((1.0 - curves[l][k[l] - 1 - (1 if l == best else 0)]) if
                  (k[l] - (1 if l == best else 0)) < args.used else 0.0
                  for l in layers) / len(layers)
        if avg > args.budget:
            break
        k[best] -= 1
        lost[best] = 1.0 - curves[best][k[best] - 1]

    total_experts = sum(k.values())
    print(f"\nплан при бюджете {100 * args.budget:.1f}% средней потери массы:")
    print(f"  экспертов на токен: {total_experts} вместо {args.used * len(layers)} "
          f"({100.0 * total_experts / (args.used * len(layers)):.1f}%)")
    avg_lost = sum(lost.values()) / len(layers)
    print(f"  средняя потеря массы: {100 * avg_lost:.2f}%")
    counts = {}
    for l in layers:
        counts[k[l]] = counts.get(k[l], 0) + 1
    print("  распределение k по слоям: " +
          ", ".join(f"k={kk}: {cnt} слоёв" for kk, cnt in sorted(counts.items())))
    worst = sorted(layers, key=lambda l: -lost[l])[:5]
    print("  слои с наибольшей потерей: " +
          ", ".join(f"{l} ({100 * lost[l]:.2f}%, k={k[l]})" for l in worst))
    keep = [l for l in layers if k[l] == args.used]
    print(f"  слоёв, не тронутых вовсе: {len(keep)}")


if __name__ == "__main__":
    main()
