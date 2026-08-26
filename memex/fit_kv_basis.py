"""Fit the compressed-tail basis to the model's own keys and values, and export it.

The zoned cache measures its byte savings correctly with any basis, which is exactly the
trap: a random projection reads the same 0.85 GB per token as a fitted one while
destroying what the context held. So the number that decides whether the tail is usable
is not the traffic - it is how much of a key or value survives the round trip through the
basis, and that can only be answered with vectors the model actually produced.

Method: take the K and V rows captured by the tracer, form their covariance, and keep the
leading `rank` eigenvectors. That is the projection minimising reconstruction error in
the least-squares sense, and since it is orthonormal the up-projection is the transpose -
which is what lets attention be computed inside the compressed space without ever
decompressing.

Exports a flat file the C++ side reads:
    int32 rank, int32 d_kv, then rank*d_kv float16 for W_down, then the same for W_up.
"""
import argparse
import io
import struct

import numpy as np


def read_kv(path, layer, d_kv, want_values):
    """Rows of K (or V) for one layer, as [n_positions, d_kv] float32.

    Only records whose unit width is exactly d_kv are kept, and that filter is doing real
    work rather than tidying. The graph names several nodes `Kcur` - the raw view out of
    the fused QKV matmul, the result of k_norm, and the result of RoPE - so a tracer
    matching on the name records the layer's keys four times: once at the width used here,
    once as the same numbers reshaped to [head_dim, n_head_kv, tokens], and twice for the
    pre-norm tensor whose rows are 40x longer.

    Accepting all of them was a measurement error, not merely waste. Covariance weights a
    vector by the square of its norm, so the pre-norm copy carried ~1600x the energy and
    the fit was effectively performed on it: the resulting basis reported 13.11% error on
    the mixture while leaving 40.66% on the keys the cache actually stores. Requiring the
    d_kv width keeps one record per pass - the post-norm keys, matching V one for one.
    """
    tag = -layer - (40001 if want_values else 30001)
    rows = []
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                break
            t, nu, nt = struct.unpack("<iii", hdr)
            n = nu * nt
            raw = f.read(4 * n)
            if len(raw) < 4 * n:
                break
            if t != tag or nu != d_kv:
                continue
            a = np.frombuffer(raw, dtype=np.float32)
            if a.size % d_kv:
                continue
            rows.append(a.reshape(-1, d_kv))
    return np.concatenate(rows, axis=0) if rows else None


def fit(x, rank):
    """Leading eigenvectors of the covariance, plus the error they leave behind."""
    x = x.astype(np.float64)
    # Centre nothing: attention consumes the raw vectors, so the basis has to explain
    # them as they are, not as deviations from a mean the runtime never subtracts.
    cov = (x.T @ x) / float(x.shape[0])
    evals, evecs = np.linalg.eigh(cov)
    order = np.argsort(evals)[::-1]
    w = evecs[:, order[:rank]].T                      # [rank, d_kv], orthonormal rows
    recon = (x @ w.T) @ w
    num = np.linalg.norm(recon - x)
    den = np.linalg.norm(x)
    kept = float(evals[order[:rank]].sum() / max(evals.sum(), 1e-30))
    return w.astype(np.float32), float(num / den) if den > 0 else 0.0, kept


def main():
    ap = argparse.ArgumentParser()
    # Repeatable, and that is the finding rather than a convenience. A basis fitted on
    # English fiction leaves 9.14% on its own keys and 29.95% on C++; on values, 21.41%
    # against 76.61%. So a single-domain basis stops meaning anything the moment the
    # context changes subject. A basis fitted on a mixture costs almost nothing against a
    # domain-specific one - 15.72% on code against 14.13% - so mixing is not a compromise.
    ap.add_argument("--trace", action="append", default=None,
                    help="трасса для подгонки; можно указать несколько")
    # Held out, never fitted on. Reported separately because fitting and measuring on the
    # same vectors answers a question nobody asked.
    ap.add_argument("--eval-trace", action="append", default=None)
    ap.add_argument("--layer", type=int, default=20)
    ap.add_argument("--d-kv", type=int, default=512)
    ap.add_argument("--rank", type=int, default=128)
    ap.add_argument("--out", default=r"D:\MemeX\blob\kv_basis_l20.bin")
    args = ap.parse_args()

    traces = args.trace or ["D:/MemeX/results/tr_kv2.bin"]
    ks, vs = [], []
    for t in traces:
        kk = read_kv(t, args.layer, args.d_kv, want_values=False)
        vv = read_kv(t, args.layer, args.d_kv, want_values=True)
        if kk is None or vv is None:
            raise SystemExit(f"в {t} нет K или V для слоя {args.layer} —"
                             " сними с MOE_TRACE_KV=1")
        print(f"  {t}: K {kk.shape}, V {vv.shape}")
        ks.append(kk)
        vs.append(vv)
    k = np.concatenate(ks, axis=0)
    v = np.concatenate(vs, axis=0)
    print(f"слой {args.layer}: подгонка на K {k.shape}, V {v.shape}")

    wk, err_k, kept_k = fit(k, args.rank)
    wv, err_v, kept_v = fit(v, args.rank)
    print(f"\nранг {args.rank} из {args.d_kv}:")
    print(f"  K: ошибка восстановления {100*err_k:5.2f}%, "
          f"сохранено дисперсии {100*kept_k:5.2f}%")
    print(f"  V: ошибка восстановления {100*err_v:5.2f}%, "
          f"сохранено дисперсии {100*kept_v:5.2f}%")

    for t in (args.eval_trace or []):
        ek = read_kv(t, args.layer, args.d_kv, want_values=False)
        ev = read_kv(t, args.layer, args.d_kv, want_values=True)
        if ek is None or ev is None:
            print(f"  отложенная {t}: нет данных для слоя {args.layer}")
            continue
        def held(w, x):
            x = x.astype(np.float64)
            return float(np.linalg.norm((x @ w.T) @ w - x) / np.linalg.norm(x))
        print(f"  отложенная {t}: K {100*held(wk, ek):5.2f}%, V {100*held(wv, ev):5.2f}%")

    # For comparison, what a random basis of the same size would cost - the arm the C++
    # bench has been using, and the reason its quality number was meaningless.
    rng = np.random.default_rng(0)
    rnd = rng.normal(size=(args.rank, args.d_kv)).astype(np.float32)
    rnd /= np.linalg.norm(rnd, axis=1, keepdims=True)
    rk = (k @ rnd.T) @ rnd
    print(f"  случайный базис того же ранга: ошибка "
          f"{100*np.linalg.norm(rk - k)/np.linalg.norm(k):5.2f}%")

    # A single basis is stored per file: K and V get their own, since their covariances
    # differ and sharing one would waste rank on whichever is harder.
    with io.open(args.out, "wb") as f:
        f.write(struct.pack("<ii", args.rank, args.d_kv))
        f.write(wk.astype(np.float16).tobytes())
        f.write(wk.astype(np.float16).tobytes())        # W_up = W_down for orthonormal
        f.write(wv.astype(np.float16).tobytes())
        f.write(wv.astype(np.float16).tobytes())
    print(f"\nзаписано: {args.out}")
    print("порядок: rank, d_kv, затем W_down(K), W_up(K), W_down(V), W_up(V) в fp16")


if __name__ == "__main__":
    main()
