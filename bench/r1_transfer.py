# -*- coding: utf-8 -*-
"""Перенос R1 между текстами: обучить на N-1 текстах, проверить на отложенном (leave-one-out).

Это то, ради чего был Kaggle, только локально. Отвечает на вопрос: обобщается ли поправка R1
(скрытое состояние -> эксперты слоя l+k) с одних текстов на другой, ранее не виденный? Если да -
предсказатель годен как боевой файл r1_corr.bin; если перенос плохой - нужен ещё более широкий
корпус, но это уже измеримо, а не гадание.

Вход: пары дампов из bench/collect_dataset.ps1 (D:\MemeX\results\dataset\<text>.hidden.bin +
<text>.trace.bin). Для каждого текста: обучить R1 на ВСЕХ ОСТАЛЬНЫХ, проверить на нём.
Сравнить с R1, обученным на самом тексте (потолок) и с R0 (без обучения).

Запуск: python bench/r1_transfer.py <gguf> [--k 4] [--budgets 10,16,32] [--dir <папка дампов>]
"""
import argparse, glob, os, sys
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from route_lab import load_trace  # noqa: E402
from hidden_lab import load_hidden, load_routers, ridge, hits_all_budgets  # noqa: E402


def fit_r1(H_list, T_list, W, k, lam=10.0):
    """Обучить поправки R1 [n_layer][513][512] на объединении текстов H_list/T_list."""
    n_layer = W.shape[0]; n_out = W.shape[1]
    corr = [None] * n_layer
    for tgt in range(k, n_layer):
        l = tgt - k
        X = np.concatenate([H[:, l, :] for H in H_list])
        Y = np.concatenate([H[:, tgt, :] @ W[tgt].T for H in H_list])
        L0 = np.concatenate([X @ W[tgt].T, np.ones((X.shape[0], 1), np.float32)], 1).astype(np.float64)
        corr[tgt] = ridge(L0, Y.astype(np.float64), lam).astype(np.float32)
    return corr


def score_on(H, trace, W, corr, k, budgets):
    """Доля попаданий R1 (corr) на тексте H/trace: [nb] среднее и худший слой."""
    n_layer = W.shape[0]
    hit = np.zeros(len(budgets)); tot = 0; worst = np.full(len(budgets), 100.0)
    for tgt in range(k, n_layer):
        if corr[tgt] is None: continue
        l = tgt - k
        L0 = np.concatenate([H[:, l, :] @ W[tgt].T, np.ones((H.shape[0], 1), np.float32)], 1)
        sc = (L0 @ corr[tgt]).astype(np.float32)
        act = trace[:, tgt, :]; act = act[(act >= 0).all(1)]
        sc = sc[(trace[:, tgt, :] >= 0).all(1)]
        if act.size == 0: continue
        h = hits_all_budgets(sc, act, budgets)
        hit += h; tot += act.size
        worst = np.minimum(worst, h / act.size * 100)
    m = hit / max(tot, 1) * 100
    return m, worst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('gguf')
    ap.add_argument('--k', type=int, default=4)
    ap.add_argument('--budgets', default='10,16,32')
    ap.add_argument('--dir', default=r'D:\MemeX\results\dataset')
    a = ap.parse_args()
    budgets = [int(x) for x in a.budgets.split(',')]
    pairs = []
    for hid in sorted(glob.glob(os.path.join(a.dir, '*.hidden.bin'))):
        name = os.path.basename(hid)[:-len('.hidden.bin')]
        tr = os.path.join(a.dir, name + '.trace.bin')
        if not os.path.exists(tr): continue
        H = load_hidden(hid); T, n_exp, _ = load_trace(tr)
        n = min(H.shape[0], T.shape[0])
        pairs.append((name, H[:n], T[:n]))
    if len(pairs) < 2:
        raise SystemExit('нужно >=2 текстов с дампами в %s (запусти bench/collect_dataset.ps1)' % a.dir)
    n_layer = pairs[0][1].shape[1]
    W = load_routers(a.gguf, n_layer)
    print('тексты: ' + ', '.join('%s(%d)' % (n, H.shape[0]) for n, H, T in pairs))
    print('leave-one-out перенос R1, k=%d, бюджеты %s (среднее %% / худший слой %%)\n' % (a.k, budgets))
    print('  %-14s %-24s %-24s %-24s' % ('отложен', 'R1 на ЧУЖИХ (перенос)', 'R1 на СЕБЕ (потолок)', 'R0 (без обуч.)'))
    agg = {'transfer': np.zeros(len(budgets)), 'self': np.zeros(len(budgets)), 'r0': np.zeros(len(budgets))}
    for i, (name, Hh, Th) in enumerate(pairs):
        rest_H = [p[1] for j, p in enumerate(pairs) if j != i]
        rest_T = [p[2] for j, p in enumerate(pairs) if j != i]
        corr_tr = fit_r1(rest_H, rest_T, W, a.k)
        corr_self = fit_r1([Hh], [Th], W, a.k)
        # R0 = единичная поправка (только логиты маршрутизатора l+k на x_l)
        corr_r0 = [None] * n_layer
        for tgt in range(a.k, n_layer):
            e = np.zeros((W.shape[1] + 1, W.shape[1]), np.float32); e[:W.shape[1], :] = np.eye(W.shape[1], dtype=np.float32)
            corr_r0[tgt] = e
        mt, wt = score_on(Hh, Th, W, corr_tr, a.k, budgets)
        ms, ws = score_on(Hh, Th, W, corr_self, a.k, budgets)
        m0, w0 = score_on(Hh, Th, W, corr_r0, a.k, budgets)
        agg['transfer'] += mt; agg['self'] += ms; agg['r0'] += m0
        f = lambda m, w: '/'.join('%.0f' % m[j] for j in range(len(budgets)))
        print('  %-14s %-24s %-24s %-24s' % (name,
              '/'.join('%.1f' % x for x in mt), '/'.join('%.1f' % x for x in ms), '/'.join('%.1f' % x for x in m0)))
    n = len(pairs)
    print('\nСРЕДНЕЕ (бюджеты %s):' % budgets)
    for j, B in enumerate(budgets):
        print('  B=%2d: перенос %.1f%%  потолок(на себе) %.1f%%  R0 %.1f%%  штраф переноса %+.1f' %
              (B, agg['transfer'][j]/n, agg['self'][j]/n, agg['r0'][j]/n, (agg['transfer'][j]-agg['self'][j])/n))
    print('\nВЫВОД: если "перенос" близок к "на себе" - R1 обобщается, боевой файл годен на этом корпусе.')
    print('Если штраф переноса большой - нужен ещё шире корпус (добавь текстов в collect_dataset.ps1).')
    print('НЕ ИЗМЕРЕНО: дампы сняты на префилле наших текстов; стоимость R1 в движке (в spec).')


if __name__ == '__main__':
    main()
