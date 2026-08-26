"""Is there exploitable activation sparsity in the MoE block, and is it *structured*?

Why this measurement is worth taking. Every other byte reduction in this project works on
the weights: fewer bits per weight, or fewer weights read because the router did not pick
that expert. Activation sparsity is different in kind - it removes work from a matmul whose
weights are already as small as they will get. In `down( silu(gate(x)) * up(x) )`:

  * an intermediate entry j that is ~0 means row j of `down` need not be read, and
    column j of `up` and of `gate` need not be computed;
  * an *input* entry i that is ~0 means row i of `up` and row i of `gate` need not be read.

Both are byte reductions on the critical path, and for a Qwen3-30B-A3B expert they are not
the same size: gate and up are [2048, 768] each and down is [768, 2048], so input-side
sparsity can reach 2/3 of an expert's bytes and intermediate-side sparsity the remaining 1/3
plus the compute for the other two.

The catch, and the reason this script spends most of its output on question 2 rather than
question 1: a fraction of near-zero entries is worthless on its own. A GEMV kernel skips
memory in contiguous chunks. Dropping one scattered entry saves nothing - the cache line was
fetched anyway, and the branch to test it costs more than the multiply it avoided. So the
number that decides whether any kernel gets written is not "what fraction of entries are
small" but "what fraction of *aligned blocks of 32/64/128 consecutive entries* are entirely
small". Those two numbers can differ by an order of magnitude, and only the second one buys
anything.

WHAT THIS SCRIPT CAN AND CANNOT MEASURE - read this before quoting any number from it.

`tr_act.bin` was produced by moe-trace.cpp with MOE_TRACE_ACT set. That flag matches the node
named `ffn_inp_normed`, which is the RMS-normalised hidden state *entering* the MoE block:
shape [n_embd=2048, n_tokens]. It is the FFN INPUT, not the FFN intermediate. The intermediate
`silu(gate(x)) * up(x)` is the node `ffn_moe_gate_par` in
src/llama-build-context.cpp (shape [n_ff_exp=768, n_expert_used=8, n_tokens]) and it is not
captured in any trace currently on disk. This script therefore answers all four questions for
the input side and says nothing about the intermediate side. The literature figure of ~17% is
an intermediate-side number and is NOT confirmed or refuted here.

To get the intermediate, change the `is_a` predicate in moe-trace.cpp to match
"ffn_moe_gate_par" (17 chars). The existing record writer already handles it: n_used = ne[0]
= 768 and n_tok = ne[1]*ne[2] = 8 * n_tokens, so each record is 8 rows per token, one per
selected expert, in top-k order - the same order as the `ffn_moe_topk` ids already in the file.

Error metric. For the input side the exact quantity is the error in the expert output after
gate/up/silu/down, which is not computable from x alone. This script reports the relative L2
error of the truncated *input vector*, ||x - x_masked|| / ||x||. That is a proxy, and a
sharper-than-reality one: gate/up are near-orthogonal random-ish projections, so input error
propagates roughly linearly, but the SiLU gate is nonlinear and the router weights rescale
the result. Read every error column as "the perturbation injected", not "the damage done".
"""
import argparse
import io
import math
import struct

import numpy as np

# tag layout from moe-trace.cpp: >=0 ids, -(l+1) weights, -(l+1)-10000 probs,
# -(l+1)-20000 the MoE block input activation, -(l+1)-30000 K, -(l+1)-40000 V
ACT_TAG_BASE = 20001
ACT_TAG_LO = -30001  # exclusive lower bound


def scan_records(path):
    """One pass over the headers only: [(tag, nu, nt, data_offset)]. No payload read."""
    out = []
    with io.open(path, "rb") as f:
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                break
            tag, nu, nt = struct.unpack("<iii", hdr)
            if nu < 0 or nt < 0:
                raise SystemExit(f"битый заголовок: tag={tag} nu={nu} nt={nt}")
            out.append((tag, nu, nt, f.tell()))
            f.seek(4 * nu * nt, io.SEEK_CUR)
    return out


def load_layer(path, recs, dim):
    """Rows of the activation for one layer, with the tracer's duplicate records removed.

    The graph fires cb() twice on this node per layer per batch, so the file holds each
    matrix twice in a row. Keeping both would double every count and make the
    across-token stability numbers look better than they are, because half the "tokens"
    would be exact copies of the other half.
    """
    parts = []
    with io.open(path, "rb") as f:
        for tag, nu, nt, off in recs:
            if nu != dim or nt < 1:
                continue
            f.seek(off)
            raw = f.read(4 * nu * nt)
            if len(raw) < 4 * nu * nt:
                raise SystemExit(f"трасса обрезана на смещении {off}")
            x = np.frombuffer(raw, dtype=np.float32).reshape(nt, nu)
            if parts and parts[-1].shape == x.shape and np.array_equal(parts[-1], x):
                continue  # exact duplicate of the previous record
            parts.append(x)
    if not parts:
        return None
    return np.concatenate(parts, axis=0).astype(np.float32)


def verify(path, dim, n_ff_exp):
    """Print what is actually in the file before anything is computed on it.

    An earlier analysis in this project was ruined by a tracer that matched the wrong
    tensor by name prefix, so the shapes and the tag bands get printed, not assumed.
    """
    recs = scan_records(path)
    bands = {}
    for tag, nu, nt, _ in recs:
        if tag >= 0:
            b = "ids (выбранные эксперты)"
        elif tag > -10001:
            b = "веса роутера"
        elif tag > -20001:
            b = "полное распределение роутера"
        elif tag > ACT_TAG_LO:
            b = "активация (узел MOE_TRACE_ACT_NAME)"
        elif tag > -40001:
            b = "K"
        else:
            b = "V"
        key = (b, nu)
        cur = bands.setdefault(key, [0, 0])
        cur[0] += 1
        cur[1] += nt
    print("что реально лежит в файле (полоса тега, nu) -> записей, строк:")
    for (b, nu), (nrec, nrow) in sorted(bands.items(), key=lambda kv: -kv[1][1]):
        print(f"  {b:32s} nu={nu:5d}   записей {nrec:5d}   строк {nrow:8d}")

    act = [r for r in recs if ACT_TAG_LO < r[0] <= -ACT_TAG_BASE]
    if not act:
        raise SystemExit("в трассе нет записей активации — снимай с MOE_TRACE_ACT=1")
    dims = sorted({r[1] for r in act})
    print(f"\nразмерность активации: {dims}")
    if dims != [dim]:
        raise SystemExit(f"ожидал nu={dim}, а в файле {dims}")
    print(f"  n_embd            = {dim}")
    print(f"  n_ff_exp          = {n_ff_exp}")
    if dim != n_ff_exp:
        print("  ВНИМАНИЕ: nu совпадает с n_embd, а НЕ с n_ff_exp.")
        print("  Это ВХОД блока MoE (ffn_inp_normed), а не промежуточный вектор")
        print("  silu(gate(x))*up(x) (это узел ffn_moe_gate_par, ширина n_ff_exp).")
        print("  Всё ниже — про разреженность ВХОДА. Про промежуточный вектор здесь нет данных.")

    by_layer = {}
    for r in act:
        by_layer.setdefault(-r[0] - ACT_TAG_BASE, []).append(r)
    return by_layer


def describe(x, name):
    """Basic statistics, so it is visible whether these look like post-SiLU products."""
    a = np.abs(x)
    rms = float(np.sqrt((x.astype(np.float64) ** 2).mean()))
    med = float(np.median(a))
    print(f"  {name}: строк {x.shape[0]:5d}  сред {x.mean():+.4f}  ско {x.std():.4f}  "
          f"|x|сред {a.mean():.4f}  медиана|x| {med:.4f}  макс|x| {a.max():8.3f}  "
          f"ровно нулей {(x == 0).mean():.3g}  медиана/скo {med / (rms + 1e-30):.3f}")


def sweep_thresholds(x, thresholds):
    """Per-entry drop: kill |x_j| < t * rms(row). Returns (frac_dropped, rel_L2_err) per t."""
    xd = x.astype(np.float32)
    e = xd * xd
    row_ms = e.mean(axis=1, keepdims=True)               # mean square per token
    row_energy = e.sum(axis=1, keepdims=True)
    scale = np.sqrt(row_ms)                              # rms of the row
    out = []
    for t in thresholds:
        m = np.abs(xd) < (t * scale)                     # True = dropped
        frac = float(m.mean())
        lost = np.where(m, e, 0.0).sum(axis=1, keepdims=True)
        rel = np.sqrt(lost / np.maximum(row_energy, 1e-30))
        out.append((frac, float(rel.mean()), float(rel.max())))
    return out


def block_all_below(x, thresholds, block):
    """Fraction of aligned blocks of `block` consecutive entries entirely below threshold.

    This is the implementable quantity: a kernel skips a whole cache-line-aligned run or
    it skips nothing. Blocks that do not divide the dimension are dropped from the count
    rather than padded, so the fraction is not inflated by a short tail block.
    """
    n = x.shape[1] // block * block
    xd = np.abs(x[:, :n].astype(np.float32)).reshape(x.shape[0], -1, block)
    e = (x.astype(np.float32) ** 2)
    row_ms = e.mean(axis=1, keepdims=True)
    scale = np.sqrt(row_ms)[:, :, None]
    peak = xd.max(axis=2)                                # a block dies only if its max dies
    out = []
    for t in thresholds:
        out.append(float((peak < t * scale[:, 0, :]).mean()))
    return out


def dead_block_profile(x, thr, block):
    """Per-token count of fully-dead blocks, plus the worst offender.

    Reporting only the mean fraction of dead blocks hides the shape of the distribution,
    and here the shape is the whole story: if a handful of tokens account for every dead
    block, the average is describing an outlier, not a property a kernel can rely on.
    """
    n = x.shape[1] // block * block
    xd = x.astype(np.float32)
    scale = np.sqrt((xd * xd).mean(axis=1, keepdims=True))
    peak = np.abs(xd[:, :n]).reshape(x.shape[0], -1, block).max(axis=2)
    dead = peak < thr * scale
    per_tok = dead.sum(axis=1)
    nb = dead.shape[1]
    worst = int(per_tok.argmax())
    row = np.abs(xd[worst])
    srt = np.sort(row)
    return {
        "blocks": nb,
        "share_tokens": float((per_tok > 0).mean()),
        "mean": float(per_tok.mean()),
        "median": float(np.median(per_tok)),
        "p99": float(np.percentile(per_tok, 99)),
        "max": int(per_tok.max()),
        "worst_tok": worst,
        "worst_dim": int(row.argmax()),
        "worst_ratio": float(srt[-1] / max(srt[-2], 1e-30)),
    }


def greedy_block_budget(x, block, budgets):
    """The kernel-realistic version: drop the smallest-norm blocks until error hits budget.

    Thresholding single entries is the wrong policy for a block kernel - it asks every
    entry of a block to be small. The right policy ranks blocks by their L2 norm and
    drops from the bottom while the accumulated relative error stays inside the budget.
    This is an upper bound on what any block mask of this size can achieve per token.
    """
    n = x.shape[1] // block * block
    e = (x[:, :n].astype(np.float64) ** 2).reshape(x.shape[0], -1, block)
    be = e.sum(axis=2)                                   # energy per block
    tot = be.sum(axis=1, keepdims=True)
    srt = np.sort(be, axis=1)
    cum = np.cumsum(srt, axis=1) / np.maximum(tot, 1e-300)
    nb = be.shape[1]
    out = []
    for eps in budgets:
        # how many blocks can be dropped before relative L2 error exceeds eps
        k = (cum <= eps * eps).sum(axis=1)
        out.append(float(k.mean()) / nb)
    return out


def stability(x, thr, block):
    """Does the small-entry set move from token to token, or is it the same set every time?

    A static pattern can be baked into the weight layout once, at zero runtime cost. A
    per-token pattern needs a mask computed and branched on for every token, which is its
    own overhead and can easily exceed the memory it saves.
    """
    xd = x.astype(np.float32)
    scale = np.sqrt((xd * xd).mean(axis=1, keepdims=True))
    m = np.abs(xd) < thr * scale                         # [tokens, dim]
    p = m.mean(axis=0)                                   # per-dim probability of being small
    res = {
        "frac_dropped": float(m.mean()),
        "always": float((p > 0.99).mean()),
        "usually": float((p > 0.90).mean()),
        "often": float((p > 0.50).mean()),
        "never": float((p < 0.01).mean()),
    }
    # pairwise Jaccard between token masks, on a bounded random sample of pairs
    rng = np.random.default_rng(0)
    nt = m.shape[0]
    npair = min(2000, nt * (nt - 1) // 2)
    i = rng.integers(0, nt, npair)
    j = rng.integers(0, nt, npair)
    ok = i != j
    i, j = i[ok], j[ok]
    inter = np.logical_and(m[i], m[j]).sum(axis=1).astype(np.float64)
    union = np.logical_or(m[i], m[j]).sum(axis=1).astype(np.float64)
    res["jaccard"] = float((inter / np.maximum(union, 1)).mean())
    # the static-mask question at block granularity
    n = x.shape[1] // block * block
    peak = np.abs(xd[:, :n]).reshape(nt, -1, block).max(axis=2)
    bm = peak < thr * scale
    bp = bm.mean(axis=0)
    res["block_any"] = float((bp > 0.0).mean())
    res["block_static"] = float((bp > 0.99).mean())
    return res


def main():
    ap = argparse.ArgumentParser(
        description="разреженность активаций блока MoE: сколько, насколько блочно, насколько устойчиво")
    ap.add_argument("--trace", default=r"D:\MemeX\results\tr_act.bin")
    ap.add_argument("--dim", type=int, default=2048, help="ожидаемая ширина активации")
    ap.add_argument("--n-ff-exp", type=int, default=768, help="ширина промежуточного вектора эксперта")
    ap.add_argument("--blocks", default="32,64,128")
    ap.add_argument("--thresholds", default="0.02,0.05,0.10,0.15,0.20,0.30,0.50")
    ap.add_argument("--budgets", default="0.01,0.02,0.05,0.10")
    ap.add_argument("--stab-thr", type=float, default=0.20,
                    help="порог (в единицах rms строки) для таблицы устойчивости")
    ap.add_argument("--max-rows", type=int, default=4096, help="строк на слой максимум")
    ap.add_argument("--layers", default="", help="через запятую; пусто = все")
    # The BOS token carries one massive activation (peak/second ~ 400x) which inflates the
    # row rms and makes every other entry look dead. How many *rows* that token occupies
    # depends on the captured node: 1 for the MoE input, n_expert_used for the intermediate
    # (one row per selected expert). It has to be told, not guessed.
    ap.add_argument("--bos-rows", type=int, default=1,
                    help="строк, занимаемых токеном BOS (1 для входа, n_expert_used для промежуточного)")
    ap.add_argument("--exclude-bos", action="store_true",
                    help="выкинуть строки BOS из ВСЕГО анализа, а не только из последней таблицы")
    args = ap.parse_args()

    blocks = [int(v) for v in args.blocks.split(",") if v]
    thrs = [float(v) for v in args.thresholds.split(",") if v]
    budgets = [float(v) for v in args.budgets.split(",") if v]

    print(f"файл: {args.trace}")
    by_layer = verify(args.trace, args.dim, args.n_ff_exp)

    want = sorted(int(v) for v in args.layers.split(",") if v) or sorted(by_layer)
    data = {}
    thin = []
    for l in want:
        if l not in by_layer:
            continue
        x = load_layer(args.trace, by_layer[l], args.dim)
        if x is not None and args.exclude_bos and args.bos_rows > 0:
            x = x[args.bos_rows:]
        if x is None or x.shape[0] < 2:
            thin.append((l, 0 if x is None else x.shape[0]))
            continue
        if x.shape[0] > args.max_rows:
            x = x[:args.max_rows]
        data[l] = x
    if not data:
        raise SystemExit("ни одного слоя с данными — это отказ измерения, а не нулевой результат")
    rows = {l: v.shape[0] for l, v in data.items()}
    print(f"\nслоёв с данными: {len(data)} ({min(data)}..{max(data)}), "
          f"строк на слой: {min(rows.values())}–{max(rows.values())}")
    if thin:
        print(f"слои без пригодных данных (строк < 2): {thin}")
        print("  (последний слой граф обрезает до выходных токенов, поэтому там 0–1 строка)")

    print("\nсырые статистики — проверка, что это не то, что мы думали:")
    probe = [min(data), sorted(data)[len(data) // 2], max(data)]
    for l in probe:
        describe(data[l], f"слой {l:2d}")
    print("  для справки: у произведения silu(gate)*up медиана|x|/ско обычно << 0.3")
    print("  и распределение резко несимметрично; у почти гауссова входа она 0.40-0.60.")
    if args.dim == args.n_ff_exp:
        print("  nu == n_ff_exp: это должен быть ПРОМЕЖУТОЧНЫЙ вектор. Если медиана/ско выше 0.4")
        print("  и среднее около нуля — снят не тот узел, числа ниже читать нельзя.")

    groups = [("ранние 0-15", [l for l in data if l <= 15]),
              ("средние 16-31", [l for l in data if 16 <= l <= 31]),
              ("поздние 32+", [l for l in data if l >= 32])]

    # --- 1. how much can be dropped, and at what injected error
    print("\n=== 1. поэлементный отброс: |x_j| < t*rms(строки) ===")
    print("порог t   доля отброшенных   гаусс-эталон   отн. L2 ошибка (сред / макс по токену)")
    agg = {t: [] for t in thrs}
    for l, x in data.items():
        for t, (fr, em, ex) in zip(thrs, sweep_thresholds(x, thrs)):
            agg[t].append((fr, em, ex))
    for t in thrs:
        a = np.array(agg[t])
        # what a plain dense N(0,1) vector would give: no sparsity at all, just the mass a
        # symmetric unimodal distribution always has near zero. If the measured column
        # matches this one, there is literally nothing to exploit.
        gauss = math.erf(t / math.sqrt(2.0))
        print(f"  {t:5.2f}   {a[:, 0].mean():14.4f}   {gauss:12.4f}   "
              f"{a[:, 1].mean():10.4f} / {a[:, 2].max():.4f}")
    print("  (ошибка считается по самому вектору x — это прокси; истинная величина —")
    print("   ошибка после gate/up/silu/down, её из одного x не получить)")

    print("\nто же по группам слоёв (доля отброшенных):")
    hdr = "  группа           " + "".join(f"  t={t:<6.2f}" for t in thrs)
    print(hdr)
    for name, ls in groups:
        if not ls:
            continue
        vals = [np.mean([agg[t][i][0] for i, l in enumerate(data) if l in ls]) for t in thrs]
        print(f"  {name:16s}" + "".join(f"  {v:8.4f}" for v in vals))

    # --- 2. is it structured
    print("\n=== 2. структурность: доля блоков, ЦЕЛИКОМ ниже порога ===")
    print("этот столбец решает, реализуемо ли вообще: ядро пропускает блок, а не элемент")
    for b in blocks:
        print(f"\n  блок {b} элементов ({args.dim // b} блоков на строку):")
        print("    порог t   доля целых блоков   доля элементов   отношение")
        for t in thrs:
            bf = np.mean([block_all_below(x, [t], b)[0] for x in data.values()])
            ef = np.mean([a[0] for a in agg[t]])
            print(f"    {t:5.2f}   {bf:17.6f}   {ef:14.4f}   {bf / max(ef, 1e-12):9.4f}")

    # Averages over blocks can be carried entirely by one freak token, so look at the
    # distribution over tokens before believing any nonzero block fraction above.
    print(f"\n  распределение мёртвых блоков по токенам (порог t={args.stab_thr}):")
    print("    блок   токенов с >=1 мёртвым   мёртвых блоков/токен: сред / медиана / p99 / макс")
    for b in blocks:
        pr = [dead_block_profile(x, args.stab_thr, b) for x in data.values()]
        nb = pr[0]["blocks"]
        print(f"    {b:4d}   {np.mean([p['share_tokens'] for p in pr]):20.5f}   "
              f"{np.mean([p['mean'] for p in pr]):6.3f} / {np.mean([p['median'] for p in pr]):7.3f} / "
              f"{np.mean([p['p99'] for p in pr]):5.2f} / {np.mean([p['max'] for p in pr]):5.1f}"
              f"   (из {nb} блоков)")
    b0 = blocks[0]
    print(f"    худший токен по слоям (блок {b0}) — где именно живёт вся «разреженность»:")
    for l in probe:
        p = dead_block_profile(data[l], args.stab_thr, b0)
        print(f"      слой {l:2d}: токен {p['worst_tok']:4d}, мёртвых блоков {p['max']:3d}/{p['blocks']}, "
              f"пик в измерении {p['worst_dim']:4d}, пик/второй = {p['worst_ratio']:8.1f}")
    print("    пик/второй в сотни раз — это massive activation служебного токена (BOS),")
    print("    из-за которого rms строки задран и «мёртвым» кажется весь остальной вектор.")

    print("\n  верхняя граница для блочной маски: жадно выбрасываем блоки с наименьшей нормой,")
    print("  пока накопленная относительная L2 ошибка не превысит бюджет (пер-токен, оракул):")
    print("    блок  " + "".join(f"  eps={e:<6.0%}" for e in budgets))
    for b in blocks:
        vals = [np.mean([greedy_block_budget(x, b, budgets)[i] for x in data.values()])
                for i in range(len(budgets))]
        print(f"    {b:4d}  " + "".join(f"  {v:9.4f}" for v in vals))
    nb_ = args.bos_rows if not args.exclude_bos else 0
    print(f"  то же без токена BOS (первые {nb_} строк), т.е. по обычным токенам:")
    print("    блок  " + "".join(f"  eps={e:<6.0%}" for e in budgets))
    for b in blocks:
        vals = [np.mean([greedy_block_budget(x[nb_:], b, budgets)[i] for x in data.values()])
                for i in range(len(budgets))]
        print(f"    {b:4d}  " + "".join(f"  {v:9.4f}" for v in vals))

    # --- 3. stability across tokens
    print(f"\n=== 3. устойчивость маски по токенам (порог t={args.stab_thr}) ===")
    b0 = blocks[0]
    print(f"слой   отбр.   всегда   >90%   >50%   никогда   Jaccard   блок{b0}:хоть раз / всегда")
    st = {}
    for l in sorted(data):
        s = stability(data[l], args.stab_thr, b0)
        st[l] = s
        print(f"{l:4d} {s['frac_dropped']:7.4f} {s['always']:8.4f} {s['usually']:6.4f} "
              f"{s['often']:6.4f} {s['never']:9.4f} {s['jaccard']:9.4f} "
              f"{s['block_any']:12.5f} / {s['block_static']:.5f}")
    print("  «всегда» = доля измерений, малых у >99% токенов -> их можно вырезать статически.")
    print("  Jaccard = совпадение масок двух случайных токенов; 1.0 = маска не двигается.")

    # --- 4. per-layer view of the headline numbers
    print("\n=== 4. по слоям: доля отброшенных элементов и доля целых блоков ===")
    tmid = thrs[len(thrs) // 2]
    print(f"(порог t={tmid})")
    print("слой   элементы   " + "   ".join(f"блок{b:<4d}" for b in blocks) + "     ско")
    for i, l in enumerate(sorted(data)):
        x = data[l]
        ef = agg[tmid][list(data).index(l)][0]
        bs = [block_all_below(x, [tmid], b)[0] for b in blocks]
        print(f"{l:4d} {ef:10.4f}   " + "   ".join(f"{v:8.5f}" for v in bs) +
              f"   {x.std():7.4f}")
    print("\nсводка по группам (порог t=%.2f):" % tmid)
    print("  группа            элементы   " + "   ".join(f"блок{b:<4d}" for b in blocks))
    for name, ls in groups:
        if not ls:
            continue
        ef = np.mean([agg[tmid][list(data).index(l)][0] for l in ls])
        bs = [np.mean([block_all_below(data[l], [tmid], b)[0] for l in ls]) for b in blocks]
        print(f"  {name:16s} {ef:10.4f}   " + "   ".join(f"{v:8.5f}" for v in bs))

    if args.dim != args.n_ff_exp:
        print("\nнапоминание: измерен ВХОД блока MoE (ffn_inp_normed, ширина n_embd).")
        print("промежуточный вектор silu(gate(x))*up(x) — узел ffn_moe_gate_par, ширина n_ff_exp —")
        print("в этой трассе отсутствует; литературные ~17% относятся именно к нему.")
    else:
        print("\nнапоминание: ширина nu == n_ff_exp, т.е. это ПРОМЕЖУТОЧНЫЙ вектор")
        print("silu(gate(x))*up(x) (узел ffn_moe_gate_par). Одна строка = один (токен, эксперт),")
        print("порядок строк совпадает с порядком top-k в ffn_moe_topk той же трассы.")
        print(f"строки BOS: {args.bos_rows}, исключены из всего анализа: {args.exclude_bos}")


if __name__ == "__main__":
    main()
