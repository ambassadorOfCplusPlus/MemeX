# -*- coding: utf-8 -*-
"""Симуляция всей схемы уровней экспертов по следу и дампу: сколько чтений с SSD остаётся.

Схема (шаги 4–5 плана):
  * РЕЗИДЕНТНОСТЬ: на каждом слое в ОЗУ держится C экспертов из 512 — верхние по частоте
    (затравка с чужих текстов + частота документа), набор обновляется раз в `period` токенов.
  * ПРЕДЗАГРУЗКА: когда посчитан вход маршрутизатора слоя l (x_l), предсказатель R1
    (маршрутизатор слоя l+k на x_l плюс линейная поправка, обученная на первой половине)
    называет B экспертов слоя l+k; те из них, что не резидентны, читаются с SSD заранее.
  * Промах = эксперт нужен, а он ни резидентен, ни предзагружен → синхронное чтение (3,6 мс).
    Предзагруженный и использованный → асинхронное чтение, скрыто, если полоса SSD позволяет.
    Предзагруженный и не использованный → впустую потраченная полоса.

Для честности всё оценивается на ВТОРОЙ половине документа (R1 обучен на первой), плюс
отдельно первые 200 токенов для базовой резидентности (там R1 не участвует в обучении, но
применяется — это честно: поправка обучена на первой половине, куда входят и они; поэтому
колонка «холод» для схемы с R1 помечена как ОПТИМИСТИЧНАЯ).

Полоса SSD измерена: ~380 экспертов/с; при T мс на токен доступно T*0.38 чтений. Печатаем
и проверяем.

Запуск: python bench/system_sim.py <дамп> <след> <gguf> --prior a.bin --prior b.bin
        [--cap 320,410] [--budget 16,32] [--k 4] [--period 16] [--token-ms 70]
"""
import argparse, sys, os
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from route_lab import load_trace, prior_from  # noqa: E402
from hidden_lab import load_hidden, load_routers, ridge  # noqa: E402

MISS_SSD_MS = 3.4
SSD_READS_PER_S = 280.0


def train_r1(H, W, k, half, ok_mask):
    """Поправки R1 для всех пар (l, l+k): список матриц [513, 512] или None."""
    n_tok, n_layer, _ = H.shape
    corr = [None] * n_layer
    for l in range(n_layer - k):
        tgt = l + k
        logit0 = H[:, l, :] @ W[tgt].T
        true_logit = H[:, tgt, :] @ W[tgt].T
        L0b = np.concatenate([logit0, np.ones((n_tok, 1), np.float32)], axis=1).astype(np.float64)
        tr = (np.arange(n_tok) < half) & ok_mask
        corr[tgt] = (ridge(L0b[tr], true_logit[tr].astype(np.float64), 10.0), l)
    return corr


def simulate(trace, H, W, prior_f, cap, budget, k, period, cold_n, corr, token_ms):
    n_tok, n_layer, n_used = trace.shape
    n_exp = W.shape[1]
    half = n_tok // 2
    counts = np.zeros((n_layer, n_exp))
    if prior_f is not None:
        for il in range(n_layer):
            counts[il] += 50.0 * prior_f[il] / max(prior_f[il].sum(), 1.0)
    resident = [np.zeros(n_exp, bool) for _ in range(n_layer)]
    def refresh():
        for il in range(n_layer):
            top = np.argpartition(-counts[il], cap - 1)[:cap]
            resident[il][:] = False; resident[il][top] = True
    refresh()
    stats = {'sync': 0, 'async_used': 0, 'wasted': 0, 'acc': 0, 'tokens': 0,
             'sync_cold': 0, 'tokens_cold': 0, 'sync_2nd': 0, 'tokens_2nd': 0,
             'worst_layer_sync': np.zeros(n_layer)}
    for t in range(n_tok):
        if t > 0 and t % period == 0: refresh()
        prefetched = [None] * n_layer
        for il in range(n_layer):
            cur = trace[t, il]; cur = cur[(cur >= 0) & (cur < n_exp)]
            if len(cur) == 0: continue
            # предзагрузка для слоя il+k по состоянию слоя il
            tgt = il + k
            if tgt < n_layer and corr[tgt] is not None and budget > 0:
                Wc, src = corr[tgt]
                x = H[t, il, :]
                l0 = np.concatenate([x @ W[tgt].T, [1.0]]).astype(np.float64)
                score = l0 @ Wc
                top = np.argpartition(-score, budget - 1)[:budget]
                pf = top[~resident[tgt][top]]
                prefetched[tgt] = set(int(e) for e in pf)
            # учёт текущего слоя
            if t > 0:
                res = resident[il]
                pf = prefetched[il] if prefetched[il] is not None else set()
                hit_res = res[cur]
                miss = cur[~hit_res]
                used_pf = sum(1 for e in miss if int(e) in pf)
                sync = len(miss) - used_pf
                stats['sync'] += sync; stats['async_used'] += used_pf
                stats['wasted'] += len(pf) - used_pf
                stats['acc'] += len(cur)
                stats['worst_layer_sync'][il] += sync
                if t < cold_n: stats['sync_cold'] += sync
                if t >= half: stats['sync_2nd'] += sync
            np.add.at(counts[il], cur, 1.0)
        if t > 0:
            stats['tokens'] += 1
            if t < cold_n: stats['tokens_cold'] += 1
            if t >= half: stats['tokens_2nd'] += 1
    T = max(stats['tokens'], 1)
    reads_per_tok = (stats['sync'] + stats['async_used'] + stats['wasted']) / T
    return {
        'sync/tok': stats['sync'] / T,
        'sync/tok cold': stats['sync_cold'] / max(stats['tokens_cold'], 1),
        'sync/tok 2nd': stats['sync_2nd'] / max(stats['tokens_2nd'], 1),
        'async/tok': stats['async_used'] / T,
        'wasted/tok': stats['wasted'] / T,
        'reads/tok': reads_per_tok,
        'ssd budget/tok': SSD_READS_PER_S * token_ms / 1000.0,
        'worst layer sync/tok': stats['worst_layer_sync'].max() / T,
        'sync ms 2nd': stats['sync_2nd'] / max(stats['tokens_2nd'], 1) * MISS_SSD_MS,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('hidden'); ap.add_argument('trace'); ap.add_argument('gguf')
    ap.add_argument('--prior', action='append')
    ap.add_argument('--cap', default='320,410')
    ap.add_argument('--budget', default='0,16,32')
    ap.add_argument('--k', type=int, default=4)
    ap.add_argument('--period', type=int, default=16)
    ap.add_argument('--cold', type=int, default=200)
    ap.add_argument('--token-ms', type=float, default=70.0)
    a = ap.parse_args()
    trace, n_exp, fmt = load_trace(a.trace)
    H = load_hidden(a.hidden)
    n = min(trace.shape[0], H.shape[0]); trace = trace[:n]; H = H[:n]
    n_tok, n_layer, _ = H.shape
    W = load_routers(a.gguf, n_layer)
    prior_f = None
    for pp in (a.prior or []):
        ptr, pexp, _ = load_trace(pp)
        if pexp == n_exp and ptr.shape[1] == n_layer:
            f, _T = prior_from(ptr, n_exp)
            prior_f = f if prior_f is None else prior_f + f
            print('затравка: %s (%d токенов)' % (pp, ptr.shape[0]))
    ok = (trace >= 0).all(axis=(1, 2))
    half = n_tok // 2
    print('след %d токенов x %d слоёв, k=%d, period=%d, token_ms=%.0f, полоса SSD %.0f чтений/с'
          % (n_tok, n_layer, a.k, a.period, a.token_ms, SSD_READS_PER_S))
    corr = train_r1(H, W, a.k, half, ok)
    print('\n%-8s %-7s | %-10s %-10s %-10s | %-9s %-9s %-9s %-11s | %-12s %s' % (
        'C/512', 'B', 'sync/tok', 'холод', '2-я пол.', 'async', 'впустую', 'чтений', 'бюджет SSD', 'худш.слой', 'мс синхр. (2-я пол.)'))
    for cap in [int(x) for x in a.cap.split(',')]:
        for B in [int(x) for x in a.budget.split(',')]:
            r = simulate(trace, H, W, prior_f, cap, B, a.k, a.period, a.cold, corr, a.token_ms)
            flag = '' if r['reads/tok'] <= r['ssd budget/tok'] else '  <<< ПОЛОСА SSD ПРЕВЫШЕНА'
            print('%-8d %-7d | %-10.2f %-10.2f %-10.2f | %-9.2f %-9.2f %-9.2f %-11.1f | %-12.3f %6.1f%s' % (
                cap, B, r['sync/tok'], r['sync/tok cold'], r['sync/tok 2nd'], r['async/tok'], r['wasted/tok'],
                r['reads/tok'], r['ssd budget/tok'], r['worst layer sync/tok'], r['sync ms 2nd'], flag))
    print('\nЧТО НЕ ИЗМЕРЕНО: колонка «холод» при B>0 ОПТИМИСТИЧНА (R1 обучен на первой половине, куда входят'
          ' первые 200 токенов); стоимость предсказателя и задержка чтения не моделируются (предзагрузка за'
          ' k=%d слоёв считается успевающей); перенос R1 на другой текст; сгенерированные токены.' % a.k)


if __name__ == '__main__':
    main()
