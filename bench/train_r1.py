# -*- coding: utf-8 -*-
"""Обучение и экспорт поправок R1 для предзагрузки экспертов (шаг 5).

R1: логиты слоя l+k ≈ [router_{l+k} · x_l ; 1] · Wc_{l+k}, где Wc — матрица [513×512], обученная
гребневой регрессией на точные логиты слоя l+k. По результатам hidden_lab.py на Coder Next при
бюджете 16 и k=1 даёт 96,8 % (худший слой 90,4 %), при k=4 — 90,2 % (83,7 %).

Экспорт для движка (файл читается в C++ одним fread):
  заголовок int32[4] = {n_layer, n_in (=n_expert+1), n_out (=n_expert), k}
  тело f16 [n_layer][n_in][n_out]; для целевых слоёв tgt < k матрица нулевая с единичной
  диагональю на первых n_out строках (то есть тождество: R1 = R0), чтобы движок не ветвился.

Честность: обучение на первой половине документа; печатается контроль на второй половине для
бюджетов 10/16/32 (тот же метод, что в hidden_lab.py), и предупреждение, что перенос на другие
тексты не измерен — для боевого файла надо обучать на нескольких дампах (--hidden/--trace можно
повторять, они конкатенируются).

Запуск: python bench/train_r1.py --hidden h.bin --trace t.bin --gguf model.gguf --k 4 --out r1_k4.bin
"""
import argparse, io, struct, sys, os
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from route_lab import load_trace  # noqa: E402
from hidden_lab import load_hidden, load_routers, ridge, hits_all_budgets  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--hidden', action='append', required=True)
    ap.add_argument('--trace', action='append', required=True)
    ap.add_argument('--gguf', required=True)
    ap.add_argument('--k', type=int, default=4)
    ap.add_argument('--lam', type=float, default=10.0)
    ap.add_argument('--out', required=True)
    ap.add_argument('--budgets', default='10,16,32')
    a = ap.parse_args()
    if len(a.hidden) != len(a.trace):
        raise SystemExit('число дампов и следов должно совпадать (пары)')
    Hs, Ts = [], []
    for h, t in zip(a.hidden, a.trace):
        H = load_hidden(h); T, n_exp, _ = load_trace(t)
        n = min(H.shape[0], T.shape[0]); Hs.append(H[:n]); Ts.append(T[:n])
        print('пара: %s + %s, %d токенов' % (h, t, n))
    H = np.concatenate(Hs); trace = np.concatenate(Ts)
    n_tok, n_layer, n_embd = H.shape
    W = load_routers(a.gguf, n_layer)
    n_out = W.shape[1]; n_in = n_out + 1
    k = a.k
    budgets = [int(x) for x in a.budgets.split(',')]
    half = n_tok // 2
    tr = np.arange(n_tok) < half; te = ~tr
    corr = np.zeros((n_layer, n_in, n_out), dtype=np.float32)
    for tgt in range(n_layer):
        if tgt < k:
            corr[tgt, :n_out, :] = np.eye(n_out, dtype=np.float32)
            continue
        l = tgt - k
        logit0 = H[:, l, :] @ W[tgt].T
        true_logit = H[:, tgt, :] @ W[tgt].T
        L0b = np.concatenate([logit0, np.ones((n_tok, 1), np.float32)], axis=1).astype(np.float64)
        Wc = ridge(L0b[tr], true_logit[tr].astype(np.float64), a.lam)
        corr[tgt] = Wc.astype(np.float32)
    # контроль на второй половине (f16-округлённые веса, как их увидит движок)
    corr16 = corr.astype(np.float16).astype(np.float32)
    hit = np.zeros(len(budgets)); tot = 0; worst = np.full(len(budgets), 100.0)
    for tgt in range(k, n_layer):
        l = tgt - k
        L0b = np.concatenate([H[te, l, :] @ W[tgt].T, np.ones((te.sum(), 1), np.float32)], axis=1)
        sc = L0b @ corr16[tgt]
        actual = trace[te, tgt, :]
        h = hits_all_budgets(sc, actual, budgets)
        hit += h; tot += actual.size
        worst = np.minimum(worst, h / actual.size * 100)
    print('контроль R1 (f16) на второй половине, k=%d: ' % k +
          ', '.join('B=%d %.2f%% (худш. слой %.2f%%)' % (B, hit[i] / tot * 100, worst[i]) for i, B in enumerate(budgets)))
    with io.open(a.out, 'wb') as f:
        f.write(struct.pack('<iiii', n_layer, n_in, n_out, k))
        f.write(corr.astype('<f2').tobytes())
    sz = os.path.getsize(a.out)
    print('записано %s: %d байт = 16 + %d*%d*%d*2' % (a.out, sz, n_layer, n_in, n_out))
    print('НЕ ИЗМЕРЕНО: перенос на другие тексты (обучено на %d документе(ах)); стоимость в движке' % len(Hs))


if __name__ == '__main__':
    main()
