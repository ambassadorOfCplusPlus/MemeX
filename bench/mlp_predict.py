# -*- coding: utf-8 -*-
"""Бьёт ли НЕЙРОСЕТЬ простую поправку R1 на дампе скрытых состояний? Проверка перед Kaggle.

R1 (hidden_lab.py) = линейная поправка поверх маршрутизатора: [router_{l+k}·x_l ; 1] · Wc.
Здесь: MLP x_l (2048) -> hidden (H, tanh) -> логиты слоя l+k (512), обучение Adam на первой
половине документа, проверка на второй (тот же сплит, что у R1). Всё на numpy, GPU не нужен:
данных один документ, и вопрос — есть ли вообще нелинейная структура, или большая ёмкость
переобучается, как это было с полноранговым R2.

Если MLP НЕ бьёт R1 на второй половине — значит на одном документе Kaggle бесполезен, сначала
нужен бОльший датасет (много дампов, собираются локально под замком). Если бьёт — Kaggle оправдан.

Запуск: python bench/mlp_predict.py <дамп> <след> <gguf> [--k 4] [--hidden 128] [--layers 6]
"""
import argparse, sys, os
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from route_lab import load_trace  # noqa: E402
from hidden_lab import load_hidden, load_routers, ridge, hits_all_budgets  # noqa: E402


def train_mlp(X, Y, Xte, H, epochs=200, lr=1e-3, l2=1e-4, seed=0):
    """Один скрытый слой tanh, Adam, ранняя остановка по обучающей MSE. Возврат: предсказание на Xte."""
    rng = np.random.default_rng(seed)
    d_in, d_out = X.shape[1], Y.shape[1]
    # нормировка входа
    mu = X.mean(0); sd = X.std(0) + 1e-6
    Xn = (X - mu) / sd; Xten = (Xte - mu) / sd
    W1 = rng.normal(0, 1 / np.sqrt(d_in), (d_in, H)).astype(np.float32); b1 = np.zeros(H, np.float32)
    W2 = rng.normal(0, 1 / np.sqrt(H), (H, d_out)).astype(np.float32); b2 = np.zeros(d_out, np.float32)
    params = [W1, b1, W2, b2]
    m = [np.zeros_like(p) for p in params]; v = [np.zeros_like(p) for p in params]
    b1a, b2a = 0.9, 0.999
    n = X.shape[0]; bs = 512
    t = 0
    for ep in range(epochs):
        idx = rng.permutation(n)
        for s in range(0, n, bs):
            bi = idx[s:s + bs]
            xb, yb = Xn[bi], Y[bi]
            z1 = xb @ W1 + b1; a1 = np.tanh(z1)
            out = a1 @ W2 + b2
            g = (out - yb) / len(bi)
            gW2 = a1.T @ g + l2 * W2; gb2 = g.sum(0)
            ga1 = g @ W2.T; gz1 = ga1 * (1 - a1 ** 2)
            gW1 = xb.T @ gz1 + l2 * W1; gb1 = gz1.sum(0)
            grads = [gW1, gb1, gW2, gb2]
            t += 1
            for i, (p, gr) in enumerate(zip(params, grads)):
                m[i] = b1a * m[i] + (1 - b1a) * gr
                v[i] = b2a * v[i] + (1 - b2a) * gr * gr
                mh = m[i] / (1 - b1a ** t); vh = v[i] / (1 - b2a ** t)
                p -= lr * mh / (np.sqrt(vh) + 1e-8)
    a1 = np.tanh(Xten @ W1 + b1)
    return a1 @ W2 + b2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('hidden'); ap.add_argument('trace'); ap.add_argument('gguf')
    ap.add_argument('--k', type=int, default=4)
    ap.add_argument('--hid', type=int, default=128)
    ap.add_argument('--layers', type=int, default=6, help='сколько слоёв-целей прогнать (0 = все)')
    ap.add_argument('--budgets', default='10,16,32')
    ap.add_argument('--epochs', type=int, default=150)
    a = ap.parse_args()
    trace, n_exp, _ = load_trace(a.trace)
    H = load_hidden(a.hidden)
    n = min(H.shape[0], trace.shape[0]); H = H[:n]; trace = trace[:n]
    n_tok, n_layer, _ = H.shape
    W = load_routers(a.gguf, n_layer)
    budgets = [int(x) for x in a.budgets.split(',')]
    half = n_tok // 2
    tr = np.arange(n_tok) < half; te = ~tr
    k = a.k
    tgts = list(range(k, n_layer))
    if a.layers > 0:
        step = max(1, len(tgts) // a.layers); tgts = tgts[::step][:a.layers]
    print('дамп %d токенов x %d слоёв, k=%d, hidden=%d, целей %d, обучение %d эпох (numpy, CPU)'
          % (n_tok, n_layer, k, a.hid, len(tgts), a.epochs))
    print('  %-6s %-22s %-22s %-22s' % ('слой', 'R1 (линейн.)', 'MLP', 'разница MLP-R1'))
    agg = {B: [0.0, 0.0] for B in budgets}
    for tgt in tgts:
        l = tgt - k
        Xtr = H[tr, l, :]; Xte = H[te, l, :]
        true_tr = H[tr, tgt, :] @ W[tgt].T
        actual_te = trace[te, tgt, :]
        tot = actual_te.size
        # R1
        L0tr = np.concatenate([Xtr @ W[tgt].T, np.ones((tr.sum(), 1), np.float32)], 1).astype(np.float64)
        Wc = ridge(L0tr, true_tr.astype(np.float64), 10.0)
        L0te = np.concatenate([Xte @ W[tgt].T, np.ones((te.sum(), 1), np.float32)], 1)
        r1 = (L0te @ Wc).astype(np.float32)
        # MLP
        ml = train_mlp(Xtr, true_tr.astype(np.float32), Xte, a.hid, epochs=a.epochs)
        hr1 = hits_all_budgets(r1, actual_te, budgets) / tot * 100
        hml = hits_all_budgets(ml, actual_te, budgets) / tot * 100
        for i, B in enumerate(budgets): agg[B][0] += hr1[i]; agg[B][1] += hml[i]
        sr1 = '/'.join('%.1f' % x for x in hr1); sml = '/'.join('%.1f' % x for x in hml)
        sd = '/'.join('%+.1f' % (hml[i] - hr1[i]) for i in range(len(budgets)))
        print('  %-6d %-22s %-22s %-22s' % (tgt, sr1, sml, sd)); sys.stdout.flush()
    nL = len(tgts)
    print('\nСРЕДНЕЕ по %d слоям (бюджеты %s):' % (nL, budgets))
    for B in budgets:
        print('  B=%2d: R1 %.2f%%  MLP %.2f%%  разница %+.2f' % (B, agg[B][0] / nL, agg[B][1] / nL, (agg[B][1] - agg[B][0]) / nL))
    print('\nВЫВОД: если разница около нуля или отрицательна - на одном документе нелинейность НЕ помогает,')
    print('Kaggle без бОльшего датасета бесполезен. Если MLP стабильно выше R1 - собрать больше дампов и учить на GPU.')
    print('НЕ ИЗМЕРЕНО: перенос на другой текст; k следующего токена; больше данных сняло бы переобучение MLP.')


if __name__ == '__main__':
    main()
