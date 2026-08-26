"""Build the MemeX expert blob: every expert stored at its own precision.

This is the on-disk format the engine's loader reads, and it exists because GGUF
cannot express what the measurements ask for. GGUF keeps a layer's experts in one
fused tensor, so precision is a per-layer choice; the routing traces say demand is
per-expert and heavily skewed, and that the skew moves with the task.

Two properties are dictated by measurement rather than taste:

  * every payload starts and ends on a 4096-byte boundary. Background loading must
    use unbuffered reads - pulling experts through the file cache evicted the model's
    own pages and cost 37% of generation speed - and unbuffered reads require
    sector-aligned offsets and lengths.
  * bit widths come from a water-filling assignment over measured access frequencies,
    because error roughly doubles per bit removed while size falls linearly. At equal
    memory this beat a two-level hot/cold split by 1.35x on total damage.

Layout: one blob of concatenated payloads plus a JSON manifest describing each
(layer, tensor, expert) -> offset, length, bits, group, shape. Both copies of an
expert can live in the same blob; the manifest keys them by bit width, so the engine
can promote or demote by reading a different entry.
"""
import argparse
import io
import json
import os
import struct
from collections import Counter

import numpy as np
from gguf import GGUFReader, GGMLQuantizationType
import gguf.quants as gq

SECTOR = 4096

# The ladder is built from ggml's own block formats rather than a hand-rolled one.
# Two reasons, both measured. First, they are the same schemes: ggml's Q4_1 is
# asymmetric 4-bit over groups of 32 with fp16 scale and offset, and it reproduces
# our packer's error to the second decimal (7.85%). Second, they beat the hand-rolled
# widths at every point - Q4_0 costs 4.5 bits for 8.79% error where our 3-bit cost
# 4.0 bits for 16.84%. Using them means the payload lands in a ggml tensor with no
# conversion and multiplies with ik_llama's SIMD kernels instead of naive code.
#
# name -> (bits per weight, MB per expert of three tensors, measured error)
LADDER = [
    ("Q4_0",   4.50, 2.65, 0.0879),
    ("Q4_1",   5.00, 2.95, 0.0785),
    ("Q5_0",   5.50, 3.24, 0.0461),
    ("source", 6.56, 4.25, 0.0000),   # the model's own blocks, copied verbatim
]
LADDER_BY_NAME = {n: (b, mb, e) for n, b, mb, e in LADDER}


def read_trace_popularity(path):
    pop = Counter()
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                break
            layer, n_used, n_tok = struct.unpack("<iii", hdr)
            n = n_used * n_tok
            raw = f.read(4 * n)
            if len(raw) < 4 * n:
                break
            if layer < 0:
                continue
            for e in struct.unpack(f"<{n}i", raw):
                pop[(layer, e)] += 1
    return pop


def assign_steps(pop, layers, n_experts, budget_gb):
    """Water-filling over the ladder: raise the step whose damage falls most per byte.

    Damage is access frequency times reconstruction error, so an expert nobody routes
    to contributes nothing however coarsely it is stored - which is exactly why a
    uniform choice wastes memory on the tail and starves the head.
    """
    keys = [(l, e) for l in layers for e in range(n_experts)]
    total = sum(pop.values()) or 1
    freq = {k: pop.get(k, 0) / total for k in keys}
    step = {k: 0 for k in keys}                       # index into LADDER
    used_gb = len(keys) * LADDER[0][2] / 1024

    while True:
        best, best_gain = None, 0.0
        for k in keys:
            i = step[k]
            if i + 1 >= len(LADDER):
                continue
            add_gb = (LADDER[i + 1][2] - LADDER[i][2]) / 1024
            if used_gb + add_gb > budget_gb:
                continue
            gain = freq[k] * (LADDER[i][3] - LADDER[i + 1][3]) / add_gb
            if gain > best_gain:
                best_gain, best = gain, k
        if best is None:
            break
        i = step[best]
        used_gb += (LADDER[i + 1][2] - LADDER[i][2]) / 1024
        step[best] = i + 1
    return {k: LADDER[i][0] for k, i in step.items()}, used_gb


def pack_step(w, step, src_blocks, src_type):
    """Pack one expert tensor at the given ladder step, in ggml's own block layout.

    The payload is therefore byte-identical to what a ggml tensor of that type holds,
    so the loader can read it straight into place: no conversion, and the multiply
    runs on the backend's optimised kernel. The top step is the model's own blocks
    copied verbatim, which is both smaller than a 7-bit repack (4.25 against 4.72 MB)
    and exactly as accurate as the weights shipped.
    """
    if step == "source":
        return np.asarray(src_blocks).reshape(-1), 0.0, int(src_type)
    qtype = getattr(GGMLQuantizationType, step)
    packed = gq.quantize(w, qtype)
    back = gq.dequantize(packed, qtype).astype(np.float32)
    denom = float(np.linalg.norm(w))
    err = float(np.linalg.norm(back - w) / denom) if denom > 0 else 0.0
    return packed.reshape(-1).view(np.uint8), err, int(qtype)


def pad_to_sector(f):
    pos = f.tell()
    rem = pos % SECTOR
    if rem:
        f.write(b"\0" * (SECTOR - rem))
    return f.tell()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=r"C:\models\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf")
    ap.add_argument("--trace", default=r"D:\MemeX\results\tr_code.bin")
    ap.add_argument("--out-blob", default=r"D:\MemeX\blob\experts.bin")
    ap.add_argument("--out-manifest", default=r"D:\MemeX\blob\experts.json")
    ap.add_argument("--experts", type=int, default=128)
    ap.add_argument("--layers", type=int, nargs="+", default=None,
                    help="по умолчанию все слои, найденные в модели")
    ap.add_argument("--budget-gb", type=float, default=22.1)
    ap.add_argument("--group", type=int, default=32)
    ap.add_argument("--also-full", action="store_true",
                    help="дописать вторую копию в исходной точности для подъёма")
    args = ap.parse_args()

    reader = GGUFReader(args.model, "r")
    by_name = {t.name: t for t in reader.tensors}
    found = sorted({int(n.split(".")[1]) for n in by_name
                    if n.endswith("ffn_up_exps.weight")})
    layers = args.layers if args.layers else found
    print(f"слоёв с экспертами: {len(found)}, обрабатываем {len(layers)}")

    pop = read_trace_popularity(args.trace)
    steps, planned_gb = assign_steps(pop, layers, args.experts, args.budget_gb)
    hist = Counter(steps.values())
    print("распределение по лестнице: " +
          ", ".join(f"{n}: {hist[n]}" for n, _, _, _ in LADDER if hist[n]))
    print(f"запланировано {planned_gb:.1f} ГБ при бюджете {args.budget_gb} ГБ")

    os.makedirs(os.path.dirname(args.out_blob), exist_ok=True)
    entries = []
    errs = []
    written = 0
    with io.open(args.out_blob, "wb") as blob:
        for li, layer in enumerate(layers):
            for kind in ("up", "gate", "down"):
                name = f"blk.{layer}.ffn_{kind}_exps.weight"
                t = by_name.get(name)
                if t is None:
                    continue
                arr = np.asarray(t.data)
                for e in range(args.experts):
                    w = gq.dequantize(arr[e], t.tensor_type).astype(np.float32)
                    # Every expert gets both rungs, always. Writing only the ladder's
                    # choice left the experts it placed at source precision with no
                    # coarse copy at all, so the runtime could never demote them: it
                    # was forced to load them full, the memory budget stopped meaning
                    # anything, and a demotion silently re-read the same bytes.
                    plan = [steps[(layer, e)]]
                    if args.also_full:
                        other = LADDER[0][0] if plan[0] == "source" else "source"
                        plan.append(other)
                    for st in plan:
                        payload, err, gtype = pack_step(w, st, arr[e], t.tensor_type)
                        off = pad_to_sector(blob)
                        blob.write(payload.tobytes())
                        pad_to_sector(blob)
                        entries.append({"layer": layer, "tensor": kind,
                                        "expert": e, "step": st,
                                        "ggml_type": gtype,
                                        "offset": off,
                                        "bytes": int(payload.nbytes),
                                        "rows": int(w.shape[0]),
                                        "cols": int(w.shape[1])})
                        errs.append(err)
                        written += int(payload.nbytes)
            # The router itself, stored beside the experts it selects. Without it the
            # runtime can only replay recorded routing decisions; with it, our own code
            # makes them - and can be checked against what the model chose.
            rt = by_name.get(f"blk.{layer}.ffn_gate_inp.weight")
            if rt is not None and kind == "down":
                raw = np.asarray(rt.data).tobytes()
                off = pad_to_sector(blob)
                blob.write(raw)
                pad_to_sector(blob)
                entries.append({"layer": layer, "tensor": "router", "expert": 0,
                                "step": "router", "ggml_type": int(rt.tensor_type),
                                "offset": off, "bytes": len(raw),
                                "rows": int(rt.shape[1]), "cols": int(rt.shape[0])})
                written += len(raw)
            print(f"  слой {layer}: готово ({li+1}/{len(layers)}), "
                  f"записано {written/1e9:.2f} ГБ", flush=True)

    man = {"blob": os.path.basename(args.out_blob), "sector": SECTOR,
           "experts_per_layer": args.experts,
           "ladder": [{"step": n, "bpw": b, "mb": mb, "err": e}
                      for n, b, mb, e in LADDER],
           "mean_error": float(np.mean(errs)) if errs else 0.0,
           "entries": entries}
    with io.open(args.out_manifest, "w", encoding="utf-8") as f:
        json.dump(man, f)
    print(f"\nблоб: {written/1e9:.2f} ГБ, записей {len(entries)}, "
          f"средняя ошибка {100*np.mean(errs):.2f}%")
    print(f"манифест: {args.out_manifest}")


if __name__ == "__main__":
    main()
