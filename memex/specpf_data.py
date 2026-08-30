"""Read a moe-trace file into the (router input at layer L, expert ids at layer L+1) pairs
that SpecPrefetch needs, and cache them as an .npz.

Two things about the trace format that cost time to find and must not be rediscovered:

  * The activation is written TWICE per batch per layer. `moe-trace.cpp` matches the node by
    name prefix, and `ggml_cast` hands its output the same name, so the f32 copy matches too.
    The two records are bit-identical (checked: max |a-b| = 0). Keep the first of each pair.

  * Records arrive interleaved act(l), ids(l), act(l), act(l+1), ids(l+1), ... so a reader that
    assumes "all of layer 0, then all of layer 1" is wrong. Group by tag, keep file order.

The layer tags are the ones moe-trace.cpp documents: >=0 ids, -(l+1) chosen weights,
-(l+1)-10000 full distribution, -(l+1)-20000 the MoE block input activation.
"""
import io, os, struct
import numpy as np

D_MODEL = 2048

def _records(path):
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                return
            tag, nu, nt = struct.unpack("<iii", hdr)
            if nu < 0 or nt < 0 or 4 * nu * nt > 2_000_000_000:
                raise SystemExit(f"{path}: bitaja zapis tag={tag} nu={nu} nt={nt}")
            n = 4 * nu * nt
            raw = f.read(n)
            if len(raw) < n:
                return                       # truncated tail: stop, do not guess
            yield tag, nu, nt, raw

def read_pairs(path, n_expert_used=8, d_model=D_MODEL, n_expert=128):
    """-> (X, IDS, P): X[l] is [T, d_model], IDS[l] is [T, k], P[l] is [T, n_expert] or absent.

    P is the frozen router's own distribution at that layer - the teacher the paper's KL loss is
    written against. It is kept only when the trace was taken with MOE_TRACE_PROBS, and it costs
    128 floats per token per layer against the activation's 2048, so keeping it is nearly free and
    not keeping it means re-running the model to ask a question the same run already answered.
    """
    acts, ids, probs = {}, {}, {}
    seen_act, seen_p = {}, {}                # name-prefix matching writes some nodes twice
    for tag, nu, nt, raw in _records(path):
        if nt == 0:
            continue                         # empty final chunk; not an error
        if tag >= 0 and nu == n_expert_used:
            ids.setdefault(tag, []).append(np.frombuffer(raw, dtype=np.int32).reshape(nt, nu))
        elif -30001 < tag <= -20001 and nu == d_model:
            l = -tag - 20001
            k = seen_act.get(l, 0)
            seen_act[l] = k + 1
            if k % 2 == 0:                   # first of each identical pair
                acts.setdefault(l, []).append(np.frombuffer(raw, dtype=np.float32).reshape(nt, nu))
        elif -20001 < tag <= -10001 and nu == n_expert:
            l = -tag - 10001
            k = seen_p.get(l, 0)
            seen_p[l] = k + 1
            if k % 2 == 0:
                probs.setdefault(l, []).append(np.frombuffer(raw, dtype=np.float32).reshape(nt, nu))
    layers = sorted(set(acts) & set(ids))
    if not layers:
        raise SystemExit(f"{path}: net par (aktivacija, vybory)")
    X = {l: np.concatenate(acts[l], axis=0) for l in layers}
    I = {l: np.concatenate(ids[l], axis=0) for l in layers}
    # llama.cpp evaluates the last layer's FFN only for the token that produces the logits
    # (METHODS rule 7). That layer arrives with one row and, taken as the minimum, silences all
    # 48. Short layers are dropped by name; the rest keep their full length.
    full = max(max(x.shape[0] for x in X.values()), max(i.shape[0] for i in I.values()))
    short = [l for l in layers if min(X[l].shape[0], I[l].shape[0]) < full // 2]
    if short:
        print(f"  {os.path.basename(path)}: otbrosheny nepolnye sloi {short}")
        layers = [l for l in layers if l not in short]
    T = min(min(X[l].shape[0] for l in layers), min(I[l].shape[0] for l in layers))
    X = {l: X[l][:T] for l in layers}
    I = {l: I[l][:T] for l in layers}
    P = {l: np.concatenate(probs[l], axis=0)[:T] for l in layers if l in probs}
    if P and min(v.shape[0] for v in P.values()) < T:
        P = {}                               # a partial teacher is worse than none: refuse it
    return X, I, P

def cache(path, out, **kw):
    X, I, P = read_pairs(path, **kw)
    layers = sorted(X)
    arrs = dict(layers=np.array(layers, dtype=np.int32),
                X=np.stack([X[l] for l in layers]).astype(np.float16),
                I=np.stack([I[l] for l in layers]).astype(np.int16))
    if len(P) == len(layers):
        arrs["P"] = np.stack([P[l] for l in layers]).astype(np.float16)
    np.savez(out, **arrs)
    print(f"  {os.path.basename(path)} -> {os.path.basename(out)}: "
          f"{len(layers)} sloev, {X[layers[0]].shape[0]} tokenov"
          + (", s raspredelenijami marshrutizatora" if "P" in arrs else ", bez raspredelenij"))
    return out

def load(npz):
    z = np.load(npz)
    return z["layers"], z["X"], z["I"]

def load_probs(npz):
    """The frozen router's own distribution, or None if this trace did not record it."""
    z = np.load(npz)
    return z["P"] if "P" in z.files else None

if __name__ == "__main__":
    import sys
    cache(sys.argv[1], sys.argv[2])
