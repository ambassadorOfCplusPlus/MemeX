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

def read_pairs(path, n_expert_used=8, d_model=D_MODEL):
    """-> (X, IDS): X[l] is [T, d_model] float32, IDS[l] is [T, k] int32, same T for all layers."""
    acts, ids = {}, {}
    seen_act = {}                            # (layer, nt) -> how many copies of this record seen
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
    return X, I

def cache(path, out, **kw):
    X, I = read_pairs(path, **kw)
    layers = sorted(X)
    np.savez(out,
             layers=np.array(layers, dtype=np.int32),
             X=np.stack([X[l] for l in layers]).astype(np.float16),
             I=np.stack([I[l] for l in layers]).astype(np.int16))
    print(f"  {os.path.basename(path)} -> {os.path.basename(out)}: "
          f"{len(layers)} sloev, {X[layers[0]].shape[0]} tokenov")
    return out

def load(npz):
    z = np.load(npz)
    return z["layers"], z["X"], z["I"]

if __name__ == "__main__":
    import sys
    cache(sys.argv[1], sys.argv[2])
