# -*- coding: utf-8 -*-
"""Предсказатель экспертов по СКРЫТОМУ СОСТОЯНИЮ - офлайн-оценка по дампу.

Идея пользователя: микромодель, которой на вход идёт скрытое состояние, а на выходе -
вероятности экспертов на ближайшую перспективу. Здесь она проверяется без движка и без
карты, по дампу скрытых состояний и следу маршрутизации.

Что именно предсказывается. В момент, когда слой l токена t уже посчитал вход своего
маршрутизатора x_l (это выход ffn_norm), нужно назвать эксперты слоёв l+1..l+k того же
токена - чтобы их успели прочитать. Три способа, по нарастанию стоимости:

  R0  «свой маршрутизатор»: router_{l+k} · x_l. Ноль новых весов: маршрутизаторы уже лежат на
      карте, это один матвектор [2048x512]. Работает, если остаточный поток меняется от слоя к
      слою медленно. Проверка k=0 обязана дать ~100% - иначе дамп и след не согласованы.
  R1  «подправленный маршрутизатор»: линейная поправка поверх R0, обученная гребневой
      регрессией на первой половине документа, проверенная на второй.
  R2  «свой линейный слой»: W_{l,k} x_l -> логиты слоя l+k, обучен гребневой регрессией на
      точные логиты слоя l+k (они известны: router_{l+k} · x_{l+k}). Полный ранг 2048x512 -
      4 МиБ f32 на пару (l,k), в движок пойдёт только в низком ранге; здесь это ПОТОЛОК.

Метрики те же, что в route_lab.py: среднее, холодный старт (первые N токенов - здесь у
скрытого состояния нет истории, так что холодный старт должен быть равен среднему), худший
слой. Бюджеты предзагрузки: 10..64 экспертов на слой.

Формат дампа (MEMEX_HIDDEN_TRACE, пишет движок): заголовок int32[4] = n_tokens, n_layer,
n_embd, dtype (1 = f16, 0 = f32); тело [token][layer][n_embd] - выход ffn_norm, то есть вход
маршрутизатора. Порядок токенов тот же, что в следе MEMEX_EXPERT_TRACE.

Честность: скрипт печатает, что НЕ измерено. Для проверки водопровода есть --selftest:
случайные маршрутизаторы и медленно дрейфующий поток, k=0 обязан дать 100%.

Запуск: python bench/hidden_lab.py <дамп> <след> <модель.gguf> [--ks 1,2,4] [--budgets 10,16,24,32,48,64]
"""
import argparse, io, struct, sys, os
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from route_lab import load_trace  # noqa: E402


def load_hidden(path):
    raw = io.open(path, 'rb').read()
    n_tok, n_layer, n_embd, dt = struct.unpack('<iiii', raw[:16])
    dtype = np.float16 if dt == 1 else np.float32
    body = np.frombuffer(raw, dtype=dtype, offset=16)
    need = n_tok * n_layer * n_embd
    if body.size != need:
        raise SystemExit('дамп: тело %d элементов, заголовок обещает %d - ДАМП НЕДЕЙСТВИТЕЛЕН'
                         % (body.size, need))
    return body.reshape(n_tok, n_layer, n_embd).astype(np.float32)


def load_routers(gguf_path, n_layer):
    sys.path.insert(0, r'D:\MemeX\src\ik_llama.cpp\gguf-py')
    from gguf import GGUFReader
    r = GGUFReader(gguf_path)
    by = {t.name: t for t in r.tensors}
    W = []
    for il in range(n_layer):
        t = by['blk.%d.ffn_gate_inp.weight' % il]
        if t.tensor_type.name != 'F32':
            raise SystemExit('маршрутизатор слоя %d не F32 (%s) - деквантизация не реализована'
                             % (il, t.tensor_type.name))
        # gguf хранит [n_expert, n_embd] строками (ne0 = n_embd быстрее всего)
        W.append(np.asarray(t.data, dtype=np.float32).reshape(-1, int(t.shape[0])))
    return np.stack(W)   # [n_layer, n_expert, n_embd]


def topk_sets(logits, k):
    return np.argpartition(-logits, k - 1, axis=-1)[..., :k]


def hits_all_budgets(score, actual, budgets):
    """score [T, E], actual [T, k] -> попадания на каждый бюджет [nb]"""
    order = np.argsort(-score, axis=-1, kind='stable')
    pos = np.empty_like(order)
    T, E = score.shape
    pos[np.arange(T)[:, None], order] = np.arange(E)[None, :]
    p = np.take_along_axis(pos, actual, axis=-1)          # [T, k]
    return np.array([(p < B).sum() for B in budgets])


def ridge(X, Y, lam):
    """W = argmin ||XW - Y||^2 + lam||W||^2, X [T, d] (со столбцом 1), Y [T, m]"""
    A = X.T @ X + lam * np.eye(X.shape[1], dtype=np.float64)
    return np.linalg.solve(A, X.T @ Y)


def evaluate(H, trace, W, ks, budgets, cold_n, lam=10.0):
    n_tok, n_layer, n_embd = H.shape
    n_used = trace.shape[2]
    n_exp = W.shape[1]
    half = n_tok // 2
    ways = ['R0 свой маршрутизатор', 'R1 подправленный', 'R2 свой линейный (потолок)']
    res = {}
    for k in [0] + ks:
        acc = {w: {'hit': np.zeros(len(budgets)), 'tot': 0, 'cold': np.zeros(len(budgets)),
                   'coldtot': 0, 'per': []} for w in ways}
        for l in range(n_layer - k):
            tgt = l + k
            actual = trace[:, tgt, :]
            ok = (actual >= 0).all(axis=1)
            X = H[:, l, :]                               # [T, d]
            logit0 = X @ W[tgt].T                        # R0: [T, E]
            true_logit = H[:, tgt, :] @ W[tgt].T         # точные логиты цели
            # обучение на первой половине, проверка на второй
            tr = np.arange(n_tok) < half
            te = ~tr & ok
            Xb = np.concatenate([X, np.ones((n_tok, 1), np.float32)], axis=1).astype(np.float64)
            L0b = np.concatenate([logit0, np.ones((n_tok, 1), np.float32)], axis=1).astype(np.float64)
            scores = {ways[0]: logit0}
            if k > 0:
                W1 = ridge(L0b[tr & ok], true_logit[tr & ok].astype(np.float64), lam)
                scores[ways[1]] = (L0b @ W1).astype(np.float32)
                W2 = ridge(Xb[tr & ok], true_logit[tr & ok].astype(np.float64), lam)
                scores[ways[2]] = (Xb @ W2).astype(np.float32)
            for w, sc in scores.items():
                # k=0 и R0 меряются на всём следе (нет обучения); обученные - на второй половине
                mask = ok if w == ways[0] else te
                h = hits_all_budgets(sc[mask], actual[mask], budgets)
                acc[w]['hit'] += h; acc[w]['tot'] += mask.sum() * n_used
                acc[w]['per'].append(h / max(mask.sum() * n_used, 1) * 100)
                cm = mask & (np.arange(n_tok) < cold_n)
                if cm.any():
                    acc[w]['cold'] += hits_all_budgets(sc[cm], actual[cm], budgets)
                    acc[w]['coldtot'] += cm.sum() * n_used
        for w in ways:
            if acc[w]['tot'] == 0: continue
            per = np.array(acc[w]['per'])                 # [layers, nb]
            res[(k, w)] = (acc[w]['hit'] / acc[w]['tot'] * 100,
                           acc[w]['cold'] / max(acc[w]['coldtot'], 1) * 100,
                           per.min(axis=0))
    return res, ways


def print_table(res, ways, ks, budgets, n_used):
    print('\nПРЕДЗАГРУЗКА ПО СКРЫТОМУ СОСТОЯНИЮ: доля попаданий, %% (сред/холод/худш.слой); '
          'top-%d = идеал' % n_used)
    print('  %-30s' % 'k / способ' + ''.join('%22d' % B for B in budgets))
    for k in [0] + ks:
        for w in ways:
            if (k, w) not in res: continue
            m, c, worst = res[(k, w)]
            line = '  k=%d %-26s' % (k, w)
            for j in range(len(budgets)):
                # обученные способы проверяются на второй половине, где холодного старта нет
                cold = '%6.2f' % c[j] if w == ways[0] else '   н/д'
                line += '   %6.2f/%s/%6.2f' % (m[j], cold, worst[j])
            print(line)
    if (0, ways[0]) in res:
        m0 = res[(0, ways[0])][0][0]
        if m0 < 99.0:
            print('  <<< ПРОВЕРКА k=0 НЕ ПРОЙДЕНА: %.2f%% вместо ~100 - дамп и след не согласованы '
                  '(порядок токенов, слой, нормировка). Остальные строки НЕДЕЙСТВИТЕЛЬНЫ.' % m0)
        else:
            print('  проверка k=0: %.2f%% - дамп и след согласованы' % m0)


def selftest(ks, budgets):
    rng = np.random.default_rng(1)
    T, L, D, E, K = 400, 12, 64, 96, 8
    W = rng.normal(size=(L, E, D)).astype(np.float32)
    H = np.empty((T, L, D), np.float32)
    x = rng.normal(size=(T, D)).astype(np.float32)
    for l in range(L):
        x = x + 0.15 * rng.normal(size=(T, D)).astype(np.float32)
        H[:, l, :] = x
    trace = np.empty((T, L, K), np.int32)
    for l in range(L):
        trace[:, l, :] = topk_sets(H[:, l, :] @ W[l].T, K)
    res, ways = evaluate(H, trace, W, ks, [b for b in budgets if b < E], 100)
    print_table(res, ways, ks, [b for b in budgets if b < E], K)
    print('\nэто САМОПРОВЕРКА на случайных данных: цифры ничего не говорят о модели')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('hidden', nargs='?')
    ap.add_argument('trace', nargs='?')
    ap.add_argument('gguf', nargs='?')
    ap.add_argument('--ks', default='1,2,4')
    ap.add_argument('--budgets', default='10,16,24,32,48,64')
    ap.add_argument('--cold', type=int, default=200)
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    ks = [int(x) for x in a.ks.split(',')]
    budgets = [int(x) for x in a.budgets.split(',')]
    if a.selftest:
        return selftest(ks, budgets)
    if not (a.hidden and a.trace and a.gguf):
        raise SystemExit('нужны дамп, след и gguf (или --selftest)')
    trace, n_exp, fmt = load_trace(a.trace)
    H = load_hidden(a.hidden)
    n_tok, n_layer, n_embd = H.shape
    print('дамп: %d токенов x %d слоёв x %d; след: %s, %d экспертов' % (n_tok, n_layer, n_embd, fmt, n_exp))
    if trace.shape[0] != n_tok or trace.shape[1] != n_layer:
        n = min(trace.shape[0], n_tok)
        print('  длины не совпадают (след %d, дамп %d) - берётся общий префикс %d токенов; '
              'если они с разных прогонов, результат НЕДЕЙСТВИТЕЛЕН' % (trace.shape[0], n_tok, n))
        trace = trace[:n]; H = H[:n]
    W = load_routers(a.gguf, n_layer)
    res, ways = evaluate(H, trace, W, ks, budgets, a.cold)
    print_table(res, ways, ks, budgets, trace.shape[2])
    print('\nЧЕГО НЕ ИЗМЕРЕНО:')
    print('  - стоимость предсказателя в движке (R0 = один матвектор [2048x512] на пару слоёв)')
    print('  - R1/R2 обучены на первой половине ЭТОГО документа; перенос на другой текст не измерен')
    print('  - дамп снят на нашем промте, а не на собственном продолжении модели')


if __name__ == '__main__':
    main()
