# -*- coding: utf-8 -*-
"""Маршрутизатор f32 → q8_0: меняет ли это решения маршрутизации? Офлайн по дампу скрытых состояний.

Ревью (спека §3c): ffn_gate_inp хранится в f32, 4 МиБ на слой = 192 МиБ на токен (7,7 мс с шины
ОЗУ на CPU-пути; на карте при 67 ГБ/с ≈ 2,9 мс). В q8_0 — 1,06 МиБ на слой. Но маршрутизатор
решает, какие эксперты считать, поэтому квантовать его «самовольно» нельзя (HANDOFF §10.5).
Здесь считается, насколько совпадают множества top-10 при f32- и q8_0-маршрутизаторе на всех
токенах дампа, послойно, плюс совпадение весов после softmax (относительная разница).

q8_0 моделируется как в ggml: блоки по 32 вдоль n_embd, scale = max|x|/127, q = round(x/scale).

Запуск: python bench/router_q8_check.py <дамп> <след> <gguf>
"""
import sys, os
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from route_lab import load_trace  # noqa: E402
from hidden_lab import load_hidden, load_routers  # noqa: E402


def q8_0(W):
    """W [n_exp, n_embd] -> деквантованная копия после q8_0 по блокам 32."""
    n_exp, n_embd = W.shape
    blocks = W.reshape(n_exp, n_embd // 32, 32)
    amax = np.abs(blocks).max(axis=-1, keepdims=True)
    scale = amax / 127.0
    scale[scale == 0] = 1.0
    q = np.clip(np.round(blocks / scale), -127, 127)
    return (q * scale).reshape(n_exp, n_embd).astype(np.float32)


def main():
    hidden, trace_p, gguf = sys.argv[1:4]
    trace, n_exp, _ = load_trace(trace_p)
    H = load_hidden(hidden)
    n = min(H.shape[0], trace.shape[0]); H = H[:n]; trace = trace[:n]
    n_tok, n_layer, _ = H.shape
    W = load_routers(gguf, n_layer)
    n_used = trace.shape[2]
    print('дамп %d токенов x %d слоёв; top-%d из %d' % (n_tok, n_layer, n_used, n_exp))
    tot_same = 0; tot = 0; worst = (100.0, -1); wdiff_max = 0.0; sanity = 0
    per = []
    for il in range(n_layer):
        X = H[:, il, :]
        lf = X @ W[il].T
        lq = X @ q8_0(W[il]).T
        top_f = np.argsort(-lf, axis=1)[:, :n_used]
        top_q = np.argsort(-lq, axis=1)[:, :n_used]
        # проверка согласованности с реальным следом (f32 против движка)
        act = trace[:, il, :]
        sanity += np.mean([len(set(top_f[t]) & set(act[t])) for t in range(n_tok)]) / n_used
        same = np.mean([len(set(top_f[t]) & set(top_q[t])) for t in range(n_tok)]) / n_used * 100
        per.append(same); tot_same += same; tot += 1
        if same < worst[0]: worst = (same, il)
        # веса после softmax на выбранных f32-экспертах: относительная разница
        pf = np.exp(lf - lf.max(axis=1, keepdims=True)); pf /= pf.sum(axis=1, keepdims=True)
        pq = np.exp(lq - lq.max(axis=1, keepdims=True)); pq /= pq.sum(axis=1, keepdims=True)
        sel = np.take_along_axis(pf, top_f, axis=1); selq = np.take_along_axis(pq, top_f, axis=1)
        wdiff_max = max(wdiff_max, float(np.abs(selq - sel).max() / sel.max()))
    print('согласованность f32-маршрутизатора с реальным следом: %.2f%% (должно быть ~100)' % (sanity / n_layer * 100))
    print('совпадение множеств top-%d f32 против q8_0: среднее %.3f%%, худший слой %d: %.3f%%' % (n_used, tot_same / tot, worst[1], worst[0]))
    print('слои с совпадением < 99.9%%: %s' % [(il, round(p, 2)) for il, p in enumerate(per) if p < 99.9])
    print('макс. относительная разница веса эксперта после softmax: %.4f' % wdiff_max)
    print('обращений, меняющих эксперта: %.1f на токен из %d' % ((100 - tot_same / tot) / 100 * n_layer * n_used, n_layer * n_used))
    print('НЕ ИЗМЕРЕНО: влияние на итоговые токены (нужен --decode-check с перекантованной моделью); q8_0 смоделирован, а не взят из llama-quantize')


if __name__ == '__main__':
    main()
