#!/usr/bin/env python3
"""
byte_budget.py -- compute bytes read per generated token for a set of GGUF models.

Pure-python GGUF header parser. Does NOT load weights: it parses the header and
tensor descriptors only (a few MB of I/O per file), so it is safe to run while
other jobs hold RAM.

Sizing follows ik_llama.cpp exactly:

    ggml_row_size(type, ne0) = row_meta_size[type] + type_size[type]*ne0/blck_size[type]
    ggml_nbytes(tensor)      = ggml_row_size(type, ne0) * (ne1*ne2*ne3)

(see ggml/src/ggml.c:4808 for ggml_row_size, and the type_traits table above it.)
The _KS/_KL family has row_meta_size > 0 -- a per-row scale -- which is why their
effective bits-per-weight depends on the row length ne0.  We therefore compute
sizes from row-size semantics and use the bpw table only as a cross-check.

Correctness check per file: sum of ggml_nbytes over all tensors, plus the aligned
header, must equal the file size on disk. If that identity fails, the type table
is wrong for some type present in the file and the numbers are not trustworthy.
"""

import os
import struct
import sys

# ---------------------------------------------------------------- ggml types

QK_K = 256
K_SCALE_SIZE = 12

# name -> (blck_size, type_size, row_meta_size)
# type_size values are sizeof(block_*) from ggml/src/ggml-common.h with QK_K=256.
# row_meta_size values are read verbatim from the type_traits table in ggml.c.
TRAITS = {
    "f32":    (1, 4, 0),
    "f16":    (1, 2, 0),
    "bf16":   (1, 2, 0),
    "f64":    (1, 8, 0),
    "i8":     (1, 1, 0),
    "i16":    (1, 2, 0),
    "i32":    (1, 4, 0),
    "i64":    (1, 8, 0),
    "q4_0":   (32, 18, 0),
    "q4_1":   (32, 20, 0),
    "q5_0":   (32, 22, 0),
    "q5_1":   (32, 24, 0),
    "q8_0":   (32, 34, 0),                                  # 2 + 32
    "q6_0":   (32, 26, 0),
    "mxfp4":  (32, 17, 0),                                  # 1 + 16
    "q2_K":   (QK_K, 84, 0),
    "q3_K":   (QK_K, 110, 0),
    "q4_K":   (QK_K, 4 + K_SCALE_SIZE + QK_K // 2, 0),      # 144
    "q5_K":   (QK_K, 4 + K_SCALE_SIZE + QK_K // 8 + QK_K // 2, 0),   # 176
    "q6_K":   (QK_K, QK_K // 2 + QK_K // 4 + QK_K // 16 + 2, 0),     # 210
    "q8_K":   (QK_K, 4 + QK_K + QK_K // 8, 0),
    "iq4_nl": (32, 18, 0),
    "iq4_xs": (QK_K, 2 + 2 + QK_K // 64 + QK_K // 2, 0),    # 136
    "iq2_k":  (QK_K, 2 + 2 + QK_K // 32 + QK_K // 4, 0),    # 76
    "iq3_k":  (QK_K, 2 + 2 + 2 + QK_K // 32 + QK_K // 4 + QK_K // 8, 0),  # 110
    "iq4_k":  (QK_K, 2 + 2 + QK_K // 64 + QK_K // 32 + QK_K // 2, 0),     # 144
    "iq5_k":  (QK_K, 2 + 2 + QK_K // 64 + QK_K // 32 + QK_K // 2 + QK_K // 8, 0),  # 176
    "iq6_k":  (QK_K, 2 + 2 + QK_K // 16 + QK_K // 2 + QK_K // 4, 0),      # 212
    # --- _KS / _KL family: per-row scale in row_meta_size
    "iq2_ks": (QK_K, 2 + QK_K // 64 + QK_K // 4, 2),                      # 70  + 2/row
    "iq3_ks": (QK_K, 2 + QK_K // 64 + QK_K // 4 + QK_K // 8, 2),          # 102 + 2/row
    "iq4_ks": (QK_K, QK_K // 32 + QK_K // 2, 4),                          # 136 + 4/row
    "iq5_ks": (QK_K, QK_K // 32 + QK_K // 2 + QK_K // 8, 4),              # 168 + 4/row
    "iq2_kl": (QK_K, 2 + QK_K // 64 + QK_K // 4 + QK_K // 16, 2),         # 86  + 2/row
    # --- the upstream i-quant family, needed to price models quantised by others (Coder-Next
    # ships as IQ3_XXS). Sizes taken from the struct definitions in ggml/src/ggml-common.h
    # rather than from memory, with IQ3S_N_SCALE = QK_K/64 = 4. All fields are naturally
    # aligned to two bytes, so there is no struct padding to account for.
    "iq1_s":   (QK_K, 2 + QK_K // 8 + 2 * (QK_K // 32), 0),                # 50  -> 1.5625 bpw
    "iq1_m":   (QK_K, QK_K // 8 + QK_K // 16 + QK_K // 32, 0),             # 56  -> 1.75
    "iq2_xxs": (QK_K, 2 + 2 * (QK_K // 8), 0),                             # 66  -> 2.0625
    "iq2_xs":  (QK_K, 2 + 2 * (QK_K // 8) + QK_K // 32, 0),                # 74  -> 2.3125
    "iq2_s":   (QK_K, 2 + QK_K // 4 + QK_K // 32 + QK_K // 32, 0),         # 82  -> 2.5625
    "iq3_xxs": (QK_K, 2 + 3 * QK_K // 8, 0),                               # 98  -> 3.0625
    "iq3_s":   (QK_K, 2 + QK_K // 4 + QK_K // 32 + QK_K // 8 + QK_K // 64, 0),  # 110 -> 3.4375
}

# ggml_type enum -> name, for the types ik_llama.cpp can emit (ggml/include/ggml.h)
TYPE_ID = {
    0: "f32", 1: "f16", 2: "q4_0", 3: "q4_1", 6: "q5_0", 7: "q5_1",
    8: "q8_0", 9: "q8_1", 10: "q2_K", 11: "q3_K", 12: "q4_K", 13: "q5_K",
    14: "q6_K", 15: "q8_K", 16: "iq2_xxs", 17: "iq2_xs", 18: "iq3_xxs",
    19: "iq1_s", 20: "iq4_nl", 21: "iq3_s", 22: "iq2_s", 23: "iq4_xs",
    24: "i8", 25: "i16", 26: "i32", 27: "i64", 28: "f64", 29: "iq1_m",
    30: "bf16", 39: "mxfp4",
    133: "q6_0", 137: "iq2_k", 138: "iq3_k", 139: "iq4_k", 140: "iq5_k",
    141: "iq6_k", 144: "iq4_ks", 145: "iq2_ks", 146: "iq4_kss",
    152: "iq5_ks", 153: "iq2_kt", 154: "iq3_kt", 155: "iq4_kt",
    156: "iq3_ks", 157: "iq2_kl", 158: "iq1_kt",
}


def row_size(tname, ne0):
    if tname not in TRAITS:
        raise KeyError("no traits for ggml type %r -- add it to TRAITS" % tname)
    blck, tsz, meta = TRAITS[tname]
    if ne0 % blck != 0:
        raise ValueError("ne0=%d not a multiple of blck_size=%d for %s" % (ne0, blck, tname))
    return meta + tsz * ne0 // blck


def nbytes(tname, ne):
    nrows = 1
    for d in ne[1:]:
        nrows *= d
    return row_size(tname, ne[0]) * nrows


# ---------------------------------------------------------------- GGUF parse

GGUF_MAGIC = 0x46554747  # 'GGUF' little-endian

(T_U8, T_I8, T_U16, T_I16, T_U32, T_I32, T_F32, T_BOOL,
 T_STR, T_ARR, T_U64, T_I64, T_F64) = range(13)

_FIXED = {
    T_U8: ("<B", 1), T_I8: ("<b", 1), T_U16: ("<H", 2), T_I16: ("<h", 2),
    T_U32: ("<I", 4), T_I32: ("<i", 4), T_F32: ("<f", 4), T_BOOL: ("<?", 1),
    T_U64: ("<Q", 8), T_I64: ("<q", 8), T_F64: ("<d", 8),
}


class Reader(object):
    def __init__(self, fh):
        self.fh = fh

    def raw(self, n):
        b = self.fh.read(n)
        if len(b) != n:
            raise EOFError("short read")
        return b

    def fixed(self, vtype):
        fmt, n = _FIXED[vtype]
        return struct.unpack(fmt, self.raw(n))[0]

    def string(self):
        n = self.fixed(T_U64)
        return self.raw(n).decode("utf-8", "replace")

    def value(self, vtype):
        if vtype in _FIXED:
            return self.fixed(vtype)
        if vtype == T_STR:
            return self.string()
        if vtype == T_ARR:
            etype = self.fixed(T_U32)
            n = self.fixed(T_U64)
            if etype == T_STR:
                # avoid materialising 150k vocab strings; skip but keep length
                for _ in range(n):
                    self.fh.seek(self.fixed(T_U64), os.SEEK_CUR)
                return ("<%d strings>" % n, n)
            if etype == T_ARR:
                return [self.value(T_ARR) for _ in range(n)]
            fmt, sz = _FIXED[etype]
            if n > 4096:
                self.fh.seek(n * sz, os.SEEK_CUR)
                return ("<%d values>" % n, n)
            return list(struct.unpack("<" + fmt[1] * n, self.raw(n * sz)))
        raise ValueError("unknown gguf value type %d" % vtype)


def parse_gguf(path):
    """Return (kv dict, list of tensor dicts, data_offset, alignment)."""
    with open(path, "rb") as fh:
        r = Reader(fh)
        magic = r.fixed(T_U32)
        if magic != GGUF_MAGIC:
            raise ValueError("%s: not a GGUF file (magic 0x%08x)" % (path, magic))
        version = r.fixed(T_U32)
        if version != 3:
            print("  WARNING: gguf version %d (expected 3)" % version)
        n_tensors = r.fixed(T_U64)
        n_kv = r.fixed(T_U64)

        kv = {}
        for _ in range(n_kv):
            key = r.string()
            vtype = r.fixed(T_U32)
            kv[key] = r.value(vtype)

        tensors = []
        for _ in range(n_tensors):
            name = r.string()
            nd = r.fixed(T_U32)
            ne = [r.fixed(T_U64) for _ in range(nd)]
            while len(ne) < 4:
                ne.append(1)
            tid = r.fixed(T_U32)
            off = r.fixed(T_U64)
            tname = TYPE_ID.get(tid)
            if tname is None:
                raise KeyError("unknown ggml type id %d for tensor %s" % (tid, name))
            tensors.append({"name": name, "ne": ne, "type": tname, "offset": off,
                            "bytes": nbytes(tname, ne)})

        align = kv.get("general.alignment", 32)
        pos = fh.tell()
        data_offset = (pos + align - 1) // align * align

    return kv, tensors, data_offset, align


# ---------------------------------------------------------------- categories

def categorise(name):
    """Bucket a tensor by what it costs per generated token."""
    n = name
    if "_exps" in n:
        return "experts"
    if n.startswith("token_embd"):
        return "token_embd"
    if n == "output.weight" or n.startswith("output.") and "norm" not in n:
        return "output_head"
    if "attn" in n:
        return "attention"
    if "ffn_gate_inp" in n or "exp_probs_b" in n:
        return "router"
    if "ffn_" in n:
        return "ffn_dense"
    return "norms_other"


CATS = ["experts", "attention", "router", "ffn_dense", "output_head",
        "norms_other", "token_embd"]


def analyse(path, verbose=False):
    kv, tensors, data_offset, align = parse_gguf(path)

    fsize = os.path.getsize(path)
    total = sum(t["bytes"] for t in tensors)

    # exact identity check: header + padded tensor blob == file size
    last = max(tensors, key=lambda t: t["offset"])
    blob_end = last["offset"] + last["bytes"]
    predicted = data_offset + blob_end
    ok = abs(predicted - fsize) < align  # trailing pad only

    arch = kv.get("general.architecture", "?")
    pfx = arch
    n_exp = kv.get("%s.expert_count" % pfx)
    n_used = kv.get("%s.expert_used_count" % pfx)
    n_layer = kv.get("%s.block_count" % pfx)

    if n_exp is None or n_used is None:
        raise ValueError("%s: missing expert_count/expert_used_count in KV" % path)
    frac = float(n_used) / float(n_exp)

    per_cat_full = dict((c, 0) for c in CATS)
    per_type = {}
    for t in tensors:
        c = categorise(t["name"])
        per_cat_full[c] += t["bytes"]
        e = per_type.setdefault(t["type"], [0, 0])
        e[0] += 1
        e[1] += t["bytes"]

    # bytes read per generated token
    per_cat_tok = dict(per_cat_full)
    per_cat_tok["experts"] = per_cat_full["experts"] * frac
    # token_embd: one row of the embedding table per token
    embd_rows = [t for t in tensors if t["name"].startswith("token_embd")]
    if embd_rows:
        t = embd_rows[0]
        per_cat_tok["token_embd"] = float(row_size(t["type"], t["ne"][0]))
    bpt = sum(per_cat_tok.values())

    return {
        "path": path, "file_size": fsize, "tensor_total": total,
        "predicted": predicted, "size_ok": ok, "n_tensors": len(tensors),
        "arch": arch, "n_expert": n_exp, "n_expert_used": n_used,
        "n_layer": n_layer, "frac": frac,
        "full": per_cat_full, "tok": per_cat_tok, "bpt": bpt,
        "per_type": per_type, "tensors": tensors,
    }


def bpw_selfcheck():
    """Cross-check the derived row sizes against the validated bpw table."""
    table = [
        ("iq2_ks", 2.1953, 2.2083), ("iq3_ks", 3.1953, 3.2083),
        ("iq4_xs", 4.2500, 4.2500), ("iq4_ks", 4.2656, 4.2917),
        ("q4_K",   4.5000, 4.5000), ("iq5_ks", 5.2656, 5.2917),
        ("q5_K",   5.5000, 5.5000), ("q6_K",   6.5625, 6.5625),
        ("q8_0",   8.5000, 8.5000), ("f16",   16.0000, 16.0000),
    ]
    print("bpw cross-check (derived from ggml_row_size vs validated table)")
    print("  %-8s %-18s %-18s" % ("type", "ne0=2048", "ne0=768"))
    bad = 0
    for tname, e2048, e768 in table:
        d2048 = row_size(tname, 2048) * 8.0 / 2048
        d768 = row_size(tname, 768) * 8.0 / 768
        f1 = "OK" if abs(d2048 - e2048) < 5e-4 else "MISMATCH"
        f2 = "OK" if abs(d768 - e768) < 5e-4 else "MISMATCH"
        if f1 != "OK" or f2 != "OK":
            bad += 1
        print("  %-8s %8.4f exp %7.4f %s   %8.4f exp %7.4f %s"
              % (tname, d2048, e2048, f1, d768, e768, f2))
    print("  -> %s\n" % ("all types agree" if bad == 0 else "%d MISMATCHES" % bad))
    return bad == 0


GB = 1024.0 ** 3
MB = 1024.0 ** 2


def main(paths):
    print("=" * 100)
    print("PART 1 -- bytes read per generated token, from the GGUF headers")
    print("=" * 100)
    print()
    bpw_selfcheck()

    results = []
    for p in paths:
        if not os.path.exists(p):
            print("SKIP %s -- file does not exist (this is a MISSING measurement, not zero)" % p)
            continue
        try:
            results.append(analyse(p))
        except Exception as exc:
            print("FAIL %s -- %s: %s" % (p, type(exc).__name__, exc))

    if not results:
        print("no models analysed")
        return 1

    print("-" * 100)
    print("file-size identity check (header + tensor blob == bytes on disk)")
    print("-" * 100)
    print("%-46s %14s %14s %8s %7s" % ("model", "on disk", "predicted", "delta", "ok"))
    for r in results:
        print("%-46s %14d %14d %8d %7s"
              % (os.path.basename(r["path"]), r["file_size"], r["predicted"],
                 r["predicted"] - r["file_size"], "yes" if r["size_ok"] else "NO"))
    print()

    print("-" * 100)
    print("model geometry")
    print("-" * 100)
    for r in results:
        print("%-46s arch=%s layers=%s experts=%s used=%s (%.4f) tensors=%d"
              % (os.path.basename(r["path"]), r["arch"], r["n_layer"],
                 r["n_expert"], r["n_expert_used"], r["frac"], r["n_tensors"]))
    print()

    print("-" * 100)
    print("resident weight size by category (MiB, full tensors)")
    print("-" * 100)
    hdr = "%-30s %10s" % ("model", "total")
    for c in CATS:
        hdr += " %11s" % c[:11]
    print(hdr)
    for r in results:
        line = "%-30s %10.1f" % (os.path.basename(r["path"])[:30],
                                 r["tensor_total"] / MB)
        for c in CATS:
            line += " %11.1f" % (r["full"][c] / MB)
        print(line)
    print()

    print("-" * 100)
    print("BYTES READ PER GENERATED TOKEN (MiB)  [experts weighted %s]"
          % "/".join(str(results[0][k]) for k in ("n_expert_used", "n_expert")))
    print("-" * 100)
    hdr = "%-30s %9s %10s %10s" % ("model", "file GB", "B/tok GB", "B/tok MiB")
    for c in CATS:
        hdr += " %11s" % c[:11]
    print(hdr)
    for r in results:
        line = "%-30s %9.2f %10.4f %10.1f" % (
            os.path.basename(r["path"])[:30], r["file_size"] / GB,
            r["bpt"] / GB, r["bpt"] / MB)
        for c in CATS:
            line += " %11.2f" % (r["tok"][c] / MB)
        print(line)
    print()

    print("-" * 100)
    print("per-token share by category (%)")
    print("-" * 100)
    hdr = "%-30s" % "model"
    for c in CATS:
        hdr += " %11s" % c[:11]
    print(hdr)
    for r in results:
        line = "%-30s" % os.path.basename(r["path"])[:30]
        for c in CATS:
            line += " %10.1f%%" % (100.0 * r["tok"][c] / r["bpt"])
        print(line)
    print()

    print("-" * 100)
    print("quant type mix per model (MiB of full tensors)")
    print("-" * 100)
    for r in results:
        parts = sorted(r["per_type"].items(), key=lambda kv: -kv[1][1])
        s = ", ".join("%s:%.0fMiB(%d)" % (t, v[1] / MB, v[0]) for t, v in parts)
        print("%-30s %s" % (os.path.basename(r["path"])[:30], s))
    print()

    print("-" * 100)
    print("KV-cache traffic (NOT a weight read; depends on position, not on the quant)")
    print("-" * 100)
    r = results[0]
    kv, _, _, _ = parse_gguf(r["path"])
    p = r["arch"]
    n_kv_head = kv.get("%s.attention.head_count_kv" % p)
    k_len = kv.get("%s.attention.key_length" % p)
    v_len = kv.get("%s.attention.value_length" % p)
    n_layer = r["n_layer"]
    if None not in (n_kv_head, k_len, v_len):
        per_pos = n_layer * n_kv_head * (k_len + v_len) * 2  # f16 K and V
        print("  n_layer=%d n_head_kv=%d k_len=%d v_len=%d, cache type f16"
              % (n_layer, n_kv_head, k_len, v_len))
        print("  KV bytes re-read per token per context position: %d B (%.1f KiB)"
              % (per_pos, per_pos / 1024.0))
        for npos in (20, 148, 276, 2048):
            b = per_pos * npos
            print("    at n_past=%-5d %8.2f MiB/token  = %5.2f ms at 24.8 GB/s  (%4.1f%% of mx1 budget)"
                  % (npos, b / MB, b / 24.8e9 * 1000, 100.0 * b / results[1]["bpt"]))
        print("  For -n 256 from a ~20-token prompt the mean n_past is ~148, so ~%.1f MiB"
              % (per_pos * 148 / MB))
        print("  ~= %.2f ms/token at 24.8 GB/s. This is IDENTICAL for all seven models"
              % (per_pos * 148 / 24.8e9 * 1000))
        print("  (same architecture), so it lands in the fitted INTERCEPT even though it")
        print("  is genuinely memory traffic. Subtract it before calling the intercept 'compute'.")
    else:
        print("  MISSING: attention head_count_kv/key_length/value_length not in KV --")
        print("  KV-cache traffic not estimated (this is unknown, not zero).")
    print()

    print("-" * 100)
    print("csv for the fit (model,bytes_per_token)")
    print("-" * 100)
    for r in results:
        print("%s,%d" % (os.path.basename(r["path"]), int(round(r["bpt"]))))
    return 0


if __name__ == "__main__":
    argv = sys.argv[1:]
    if not argv:
        argv = [
            r"D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf",
            r"D:\Qwen3-Coder-30B-A3B-mx1.gguf",
            r"D:\Qwen3-Coder-30B-A3B-mx2.gguf",
            r"D:\Qwen3-Coder-30B-A3B-mx3.gguf",
            r"D:\Qwen3-Coder-30B-A3B-mx4.gguf",
            r"D:\Qwen3-Coder-30B-A3B-mx5.gguf",
            r"D:\Qwen3-Coder-30B-A3B-mx6.gguf",
        ]
    sys.exit(main(argv))
