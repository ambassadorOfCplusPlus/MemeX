"""Write the per-layer resident expert set that cache-conditional routing needs.

The idea being tested: when the router's top-k choices are nearly equal in weight,
prefer the experts already held in fast memory. It is worth testing here because the
router of this model is flat - the eighth chosen expert carries 7.6% of the routing
mass against 22.7% for the first - so substituting a neighbour costs almost nothing.
Offline that traded 1% of routing mass for eleven points of hit rate (67.3% -> 79.1%).

Offline mass is a proxy, though. To measure the real cost the runtime has to apply the
bonus and perplexity has to be compared, and for that the graph needs to know which
experts count as resident. This writes that set, taken from a recorded trace, in a flat
binary the fork reads once at load:

    int32 n_layers, int32 n_experts
    then n_layers rows of n_experts float32, 1.0 for resident, 0.0 otherwise
"""
import argparse
import io
import struct
from collections import Counter


def read_ids(path):
    """(layer -> list of per-token id lists), ignoring weight and prob records."""
    by_layer = {}
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                break
            tag, n_used, n_tok = struct.unpack("<iii", hdr)
            n = n_used * n_tok
            raw = f.read(4 * n)
            if len(raw) < 4 * n:
                break
            if tag < 0:
                continue                  # weights or the full distribution
            vals = struct.unpack(f"<{n}i", raw)
            rows = [list(vals[i * n_used:(i + 1) * n_used]) for i in range(n_tok)]
            by_layer.setdefault(tag, []).extend(rows)
    return by_layer


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", default=r"D:\MemeX\results\tr_code.bin")
    ap.add_argument("--experts", type=int, default=128)
    ap.add_argument("--layers", type=int, default=48)
    ap.add_argument("--per-layer", type=int, default=32,
                    help="сколько экспертов слоя считать резидентными")
    ap.add_argument("--out", default=r"D:\MemeX\blob\resident.bin")
    args = ap.parse_args()

    by_layer = read_ids(args.trace)
    if not by_layer:
        raise SystemExit("в трассе нет записей с номерами экспертов")
    # The last layer computes its FFN for one token only, so it holds almost no
    # evidence; give it the same treatment as any layer with too little data - fall
    # back to the model-wide ranking rather than a set built from one row.
    full = max(len(v) for v in by_layer.values())
    global_pop = Counter()
    for rows in by_layer.values():
        for r in rows:
            global_pop.update(r)

    with io.open(args.out, "wb") as f:
        f.write(struct.pack("<ii", args.layers, args.experts))
        resident_total = 0
        for layer in range(args.layers):
            rows = by_layer.get(layer, [])
            pop = Counter()
            if len(rows) >= full // 2:
                for r in rows:
                    pop.update(r)
            else:
                pop = global_pop
            chosen = {e for e, _ in pop.most_common(args.per_layer)}
            resident_total += len(chosen)
            row = [1.0 if e in chosen else 0.0 for e in range(args.experts)]
            f.write(struct.pack(f"<{args.experts}f", *row))
    print(f"записано: {args.out}")
    print(f"слоёв {args.layers}, экспертов {args.experts}, "
          f"резидентных {resident_total} ({100.0 * resident_total / (args.layers * args.experts):.1f}%)")


if __name__ == "__main__":
    main()
