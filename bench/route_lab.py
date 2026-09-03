# -*- coding: utf-8 -*-
"""Лаборатория предсказателей экспертов по следу маршрутизации.

Отвечает на вопрос шага 5 плана: КАКИЕ эксперты держать/подгружать на следующий токен и
следующий слой, если их выбирает не частота, а предсказатель. Всё считается офлайн по следу,
поэтому десяток способов сравнивается за секунды, без пересборки и без замка машины.

Отличия от bench/route_predict.py (база прошлого агента), которые тут добавлены намеренно:
  * ТРИ метрики, а не одна: среднее по всему следу; ХОЛОДНЫЙ СТАРТ (первые N токенов);
    ХУДШИЙ СЛОЙ. Промах случается в конкретном слое и в начале документа, а не «в среднем».
  * Предсказание ВНУТРИ токена: при счёте слоя l уже известны выборы слоёв 0..l-1 этого же
    токена. Способ «межслойный» учится на совместной встречаемости (слой l-k -> слой l) и
    предсказывает слой l на k слоёв вперёд - это ровно то окно, за которое надо успеть
    прочитать эксперта с SSD.
  * Затравка с ЧУЖОГО текста (prior): частоты другого следа как начальные счётчики, чтобы
    померить, спасает ли это холодный старт, и насколько (перенос между текстами 81%).
  * Два режима бюджета: РЕЗИДЕНТНОСТЬ (сколько держать в ОЗУ: 128..410 из 512) и
    ПРЕДЗАГРУЗКА (сколько читать заранее на слой: 10..64).

Честность. Скрипт печатает, чего он НЕ мерит:
  * след снят на нашем промте, а не на собственном продолжении модели;
  * стоимость самого предсказателя не учтена - это потолок способа, а не выигрыш движка;
  * скрытых состояний в следе нет, поэтому предсказатель по скрытому состоянию тут НЕ
    измерен - нужен отдельный дамп (см. --hidden, пока отказ вслух).

Форматы следа:
  новый (MEMEX_EXPERT_TRACE): заголовок int32[4] = n_tokens, n_layer, n_used, n_expert,
      тело [token][layer][slot];
  старый (moe_trace.bin от 30B): блоки [layer, n_used, n_tokens] + ids [token][slot].

Запуск:  python bench/route_lab.py <след> [--prior <другой след>] [--cold 200]
"""
import argparse, io, os, struct, sys, collections
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

MISS_SSD_MS = 3.616      # измерено bench/ssd_raw_reads.py, блок 1,67 МБ мимо кэша
MISS_HDD_MS = 23.287


# ----------------------------------------------------------------------------- загрузка
def load_trace(path):
    raw = io.open(path, 'rb').read()
    if len(raw) >= 16:
        n_tok, n_layer, n_used, n_exp = struct.unpack('<iiii', raw[:16])
        if (n_tok > 0 and 0 < n_layer <= 256 and 0 < n_used <= 32 and 0 < n_exp <= 4096
                and len(raw) == 16 + 4 * n_tok * n_layer * n_used):
            body = np.frombuffer(raw, dtype='<i4', offset=16)
            return body.reshape(n_tok, n_layer, n_used).copy(), n_exp, 'MEMEX_EXPERT_TRACE'
    # старый формат: блоки по слоям
    # старый формат: блоки [layer, n_used, n_tokens] идут подряд (префилл, затем по токену),
    # блоки одного слоя склеиваются; последний слой в префилле считает только последний токен
    # (эталон обрезает граф), поэтому слои с половиной длины отбрасываются вслух.
    layers = collections.defaultdict(list)
    off = 0
    while off + 12 <= len(raw):
        layer, n_used, n_tokens = struct.unpack('<iii', raw[off:off + 12]); off += 12
        n = n_used * n_tokens
        if off + 4 * n > len(raw):
            break
        ids = np.frombuffer(raw, dtype='<i4', offset=off, count=n).reshape(n_tokens, n_used)
        off += 4 * n
        if layer >= 0:
            layers[layer].append(ids)
    if not layers:
        raise SystemExit('след не разобран ни одним форматом: %s' % path)
    layers = {il: np.concatenate(v) for il, v in layers.items()}
    full = max(v.shape[0] for v in layers.values())
    short = sorted(il for il, v in layers.items() if v.shape[0] < full // 2)
    if short:
        print('  старый формат: слои %s имеют неполный след и ОТБРОШЕНЫ' % short)
        for il in short: del layers[il]
    n_layer = max(layers) + 1
    n_tok = min(v.shape[0] for v in layers.values())
    n_used = next(iter(layers.values())).shape[1]
    arr = np.full((n_tok, n_layer, n_used), -1, dtype=np.int32)
    for il, v in layers.items():
        arr[:, il, :] = v[:n_tok]
    n_exp = int(arr.max()) + 1
    return arr, n_exp, 'moe_trace (блоки по слоям)'


# ----------------------------------------------------------------------------- предсказатели
# Контракт: predictor(il) -> объект с
#   order(ctx)   -> np.ndarray id в порядке убывания приоритета (можно короче n_exp). Бюджет B
#                   означает «первые B из этого порядка», поэтому все бюджеты оцениваются за
#                   один вызов. ctx.same_token[l] - выборы слоёв < il текущего токена (уже
#                   известны), ctx.t - номер токена.
#   observe(cur, ctx) -> учесть фактический выбор слоя il на текущем токене
# Никакого заглядывания вперёд: order вызывается ДО observe того же слоя и токена.

class Ctx:
    __slots__ = ('t', 'same_token')
    def __init__(s): s.t = 0; s.same_token = {}


class Freq:
    "частота по всей истории слоя - база, которую надо побить"
    def __init__(s, n_exp, prior=None, prior_w=0.0):
        s.c = np.zeros(n_exp, dtype=np.float64)
        if prior is not None and prior_w > 0:
            s.c += prior_w * prior / max(prior.sum(), 1.0)
    def order(s, ctx):
        if not s.c.any(): return np.empty(0, dtype=np.int64)
        o = np.argsort(-s.c, kind='stable')
        return o[s.c[o] > 0]
    def observe(s, cur, ctx): np.add.at(s.c, cur, 1.0)


class FreqDecay(Freq):
    "частота с экспоненциальным забыванием: следит за темой, а не за всем документом"
    def __init__(s, n_exp, alpha, **kw):
        super().__init__(n_exp, **kw); s.alpha = alpha
    def observe(s, cur, ctx):
        s.c *= s.alpha
        np.add.at(s.c, cur, 1.0)


class WindowFreq(Freq):
    "объединение последних W токенов, остаток бюджета - частотой"
    def __init__(s, n_exp, W, **kw):
        super().__init__(n_exp, **kw); s.q = collections.deque(maxlen=W)
    def order(s, ctx):
        keep = []
        seen = set()
        for step in reversed(s.q):
            for e in step:
                if e not in seen:
                    seen.add(e); keep.append(e)
        if s.c.any():
            for e in np.argsort(-s.c, kind='stable'):
                if s.c[e] <= 0: break
                if e not in seen: seen.add(e); keep.append(int(e))
        return np.asarray(keep, dtype=np.int64)
    def observe(s, cur, ctx):
        s.q.append(list(cur)); super().observe(cur, ctx)


class LRU:
    def __init__(s, n_exp): s.o = collections.OrderedDict()
    def order(s, ctx): return np.asarray(list(s.o.keys())[::-1], dtype=np.int64)
    def observe(s, cur, ctx):
        for e in cur:
            s.o.pop(int(e), None); s.o[int(e)] = 1


class CrossLayer:
    """Межслойный: слой il предсказывается по выборам слоя il-k ТОГО ЖЕ токена.

    Таблица T[p, e] - сколько раз эксперт p на слое il-k и эксперт e на слое il встретились
    на одном токене. Оценка e = сумма T[p, e] по p из фактического выбора слоя il-k, плюс
    малая доля частоты как разрешение ничьих. Учится онлайн, причинно. Для первых k слоёв
    (нет слоя il-k в этом токене) берётся выбор слоя il на ПРЕДЫДУЩЕМ токене - то, что было
    бы известно движку в этот момент.
    """
    def __init__(s, n_exp, il, k, prior_T=None, prior_w=0.0, tie=0.01):
        s.il = il; s.k = k; s.n = n_exp; s.tie = tie
        s.T = np.zeros((n_exp, n_exp), dtype=np.float32)
        if prior_T is not None and prior_w > 0:
            s.T += prior_w * prior_T / max(prior_T.sum(), 1.0) * n_exp
        s.c = np.zeros(n_exp, dtype=np.float64)
        s.last_src = None      # выбор слоя-источника на этом токене (для observe)
        s.prev_cur = None      # свой выбор на предыдущем токене
    def _src(s, ctx):
        src_l = s.il - s.k
        if src_l >= 0 and src_l in ctx.same_token:
            return ctx.same_token[src_l], True
        return s.prev_cur, False
    def order(s, ctx):
        src, _ = s._src(ctx)
        score = s.c * s.tie
        if src is not None and len(src):
            score = score + s.T[np.asarray(src)].sum(axis=0)
        if not score.any(): return np.empty(0, dtype=np.int64)
        o = np.argsort(-score, kind='stable')
        return o[score[o] > 0]
    def observe(s, cur, ctx):
        src, same = s._src(ctx)
        if src is not None and len(src):
            s.T[np.ix_(np.asarray(src), np.asarray(cur))] += 1.0
        np.add.at(s.c, cur, 1.0)
        s.prev_cur = np.asarray(cur)


# ----------------------------------------------------------------------------- прогон
def run(trace, n_exp, make, budgets, cold_n):
    """Возвращает {B: (среднее, холодный старт, худший слой, доля по слоям)}.
    Один проход по следу на способ: порядок приоритета считается один раз, а попадание при
    бюджете B - это «позиция эксперта в порядке < B», поэтому все бюджеты сразу."""
    n_tok, n_layer, n_used = trace.shape
    budgets = np.asarray(budgets)
    nb = len(budgets)
    preds = [make(il) for il in range(n_layer)]
    hit = np.zeros((n_layer, nb), dtype=np.int64); tot = np.zeros(n_layer, dtype=np.int64)
    hit_cold = np.zeros(nb, dtype=np.int64); tot_cold = 0
    pos = np.empty(n_exp, dtype=np.int64)
    ctx = Ctx()
    for t in range(n_tok):
        ctx.t = t; ctx.same_token = {}
        for il in range(n_layer):
            cur = trace[t, il]
            cur = cur[(cur >= 0) & (cur < n_exp)]
            if len(cur) == 0: continue
            if t > 0:
                o = preds[il].order(ctx)
                pos.fill(n_exp)
                if len(o): pos[o] = np.arange(len(o))
                h = (pos[cur][:, None] < budgets[None, :]).sum(axis=0)
                hit[il] += h; tot[il] += len(cur)
                if t < cold_n:
                    hit_cold += h; tot_cold += len(cur)
            preds[il].observe(cur, ctx)
            ctx.same_token[il] = cur
    out = {}
    for j, B in enumerate(budgets):
        per = np.where(tot > 0, hit[:, j] / np.maximum(tot, 1) * 100.0, np.nan)
        out[int(B)] = (hit[:, j].sum() / max(tot.sum(), 1) * 100.0,
                       hit_cold[j] / max(tot_cold, 1) * 100.0,
                       np.nanmin(per) if np.isfinite(per).any() else float('nan'), per)
    return out


def prior_from(trace, n_exp):
    """Частоты по слоям и таблицы совместной встречаемости (k=1) с чужого текста."""
    n_tok, n_layer, n_used = trace.shape
    freq = np.zeros((n_layer, n_exp)); T1 = np.zeros((n_layer, n_exp, n_exp), dtype=np.float32)
    for il in range(n_layer):
        v = trace[:, il, :]; v = v[(v >= 0) & (v < n_exp)]
        np.add.at(freq[il], v, 1.0)
        if il >= 1:
            for t in range(n_tok):
                a = trace[t, il - 1]; b = trace[t, il]
                a = a[(a >= 0) & (a < n_exp)]; b = b[(b >= 0) & (b < n_exp)]
                T1[il][np.ix_(a, b)] += 1.0
    return freq, T1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace')
    ap.add_argument('--prior', action='append', help='след другого текста для затравки холодного старта (можно несколько раз, частоты суммируются)')
    ap.add_argument('--cold', type=int, default=200, help='длина холодного старта в токенах')
    ap.add_argument('--resident', default='128,192,256,320,384,410',
                    help='бюджеты резидентности (экспертов на слой в ОЗУ)')
    ap.add_argument('--prefetch', default='10,16,24,32,48,64',
                    help='бюджеты предзагрузки (экспертов на слой заранее)')
    ap.add_argument('--ks', default='1,2,4', help='на сколько слоёв вперёд предсказывать')
    ap.add_argument('--hidden', help='дамп скрытых состояний (пока не поддержан)')
    a = ap.parse_args()

    if a.hidden:
        print('ОТКАЗ: предсказатель по скрытому состоянию требует дампа, формат которого ещё '
              'не определён; этот канал НЕ ИЗМЕРЕН')
    trace, n_exp, fmt = load_trace(a.trace)
    n_tok, n_layer, n_used = trace.shape
    per_token = n_layer * n_used
    print('след: %s, формат %s' % (a.trace, fmt))
    print('  %d токенов x %d слоёв x %d мест, из %d экспертов; обращений на токен %d'
          % (n_tok, n_layer, n_used, n_exp, per_token))
    if n_tok * n_used / n_exp < 10:
        print('  ВНИМАНИЕ: %.1f обращений на эксперта на слой - выборка мала, выводы о дрейфе '
              'недействительны (урок HANDOFF_ROUTER §4)' % (n_tok * n_used / n_exp))

    prior_f = prior_T = None
    for pp in (a.prior or []):
        ptr, pexp, pfmt = load_trace(pp)
        if pexp != n_exp or ptr.shape[1] != n_layer:
            print('  prior %s: другая геометрия (%d слоёв, %d экспертов) - НЕ применён' % (pp, ptr.shape[1], pexp))
            continue
        f, T = prior_from(ptr, n_exp)
        prior_f = f if prior_f is None else prior_f + f
        prior_T = T if prior_T is None else prior_T + T
        print('  затравка с чужого текста: %s (%d токенов)' % (pp, ptr.shape[0]))

    resident = [int(x) for x in a.resident.split(',') if int(x) < n_exp]
    prefetch = [int(x) for x in a.prefetch.split(',') if int(x) < n_exp]
    ks = [int(x) for x in a.ks.split(',')]

    ways = [
        ('частота (база)',        lambda il: Freq(n_exp)),
        ('частота, забыв. 0.99',  lambda il: FreqDecay(n_exp, 0.99)),
        ('частота, забыв. 0.995', lambda il: FreqDecay(n_exp, 0.995)),
        ('окно 16 + частота',     lambda il: WindowFreq(n_exp, 16)),
        ('LRU',                   lambda il: LRU(n_exp)),
    ]
    for k in ks:
        ways.append(('межслойный k=%d' % k, (lambda k: lambda il: CrossLayer(n_exp, il, k))(k)))
    if prior_f is not None:
        for w in (50, 200):
            ways.append(('частота + затравка w=%d' % w,
                         (lambda w: lambda il: Freq(n_exp, prior=prior_f[il], prior_w=w))(w)))
        ways.append(('межслойный k=1 + затравка',
                     lambda il: CrossLayer(n_exp, il, 1, prior_T=prior_T[il], prior_w=200)))

    def table(title, budgets):
        print('\n%s' % title)
        print('  %-28s' % 'способ' + ''.join('%22d' % B for B in budgets))
        print('  %-28s' % '' + ''.join('%22s' % 'сред/холод/худш.слой' for B in budgets))
        rows = []
        for name, mk in ways:
            r = run(trace, n_exp, mk, budgets, a.cold)
            rows.append((name, r))
            line = '  %-28s' % name
            for B in budgets:
                m, c, w, _ = r[B]
                line += '   %6.2f/%6.2f/%6.2f' % (m, c, w)
            print(line); sys.stdout.flush()
        return rows

    rows_r = table('РЕЗИДЕНТНОСТЬ: доля попаданий на следующий токен, %% (бюджет = экспертов '
                   'на слой в ОЗУ; холодный старт = первые %d токенов)' % a.cold, resident)
    base = dict(rows_r)['частота (база)']
    print('\nЦЕНА ПРОМАХОВ БАЗЫ (частота) в мс на токен, среднее / холодный старт:')
    for B in resident:
        m, c, w, _ = base[B]
        print('  бюджет %3d/%d: SSD %6.1f / %6.1f мс   HDD %6.1f / %6.1f мс'
              % (B, n_exp, (100 - m) / 100 * per_token * MISS_SSD_MS,
                 (100 - c) / 100 * per_token * MISS_SSD_MS,
                 (100 - m) / 100 * per_token * MISS_HDD_MS,
                 (100 - c) / 100 * per_token * MISS_HDD_MS))
    print('\nЛУЧШИЙ СПОСОБ ПРОТИВ ЧАСТОТЫ, пункты покрытия -> мс на токен с SSD (среднее; холодный старт):')
    for B in resident:
        bm = max(rows_r, key=lambda r: r[1][B][0]); bc = max(rows_r, key=lambda r: r[1][B][1])
        dm = bm[1][B][0] - base[B][0]; dc = bc[1][B][1] - base[B][1]
        print('  бюджет %3d: %-26s %+6.2f п. -> %6.1f мс ; холод: %-26s %+6.2f п. -> %6.1f мс'
              % (B, bm[0], dm, dm / 100 * per_token * MISS_SSD_MS,
                 bc[0], dc, dc / 100 * per_token * MISS_SSD_MS))

    table('ПРЕДЗАГРУЗКА: доля попаданий при чтении B экспертов на слой заранее, %% '
          '(это точность самого предсказания; top-%d = идеал)' % n_used, prefetch)

    print('\nЧЕГО ЗДЕСЬ НЕ ИЗМЕРЕНО:')
    print('  - след снят на нашем промте, а не на собственном продолжении модели')
    print('  - цена самого предсказателя не учтена: потолок способа, а не выигрыш движка')
    print('  - скрытые состояния: канала нет, предсказатель по ним НЕ измерен')
    print('  - межслойный способ предсказывает слой il по слою il-k того же токена; для первых '
          'k слоёв - по своему выбору на предыдущем токене')
    if prior_f is None:
        print('  - затравка с чужого текста: не задан --prior, холодный старт с затравкой НЕ измерен')


if __name__ == '__main__':
    main()
