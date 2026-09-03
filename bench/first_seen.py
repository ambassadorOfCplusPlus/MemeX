# -*- coding: utf-8 -*-
"""Доля обращений к экспертам, которые появляются в документе ВПЕРВЫЕ, по окнам токенов.
Это нижняя граница промахов любого предсказателя по истории (частота, LRU, межслойный):
эксперта, которого ещё не видели, из истории не достать. Печатает также рост числа
различных экспертов на слой.  python bench/first_seen.py <след> [окно=100]"""
import sys, numpy as np
sys.path.insert(0, __import__('os').path.dirname(__file__))
from route_lab import load_trace
if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8', errors='replace')
tr, n_exp, fmt = load_trace(sys.argv[1]); win = int(sys.argv[2]) if len(sys.argv) > 2 else 100
T, L, U = tr.shape
seen = np.zeros((L, n_exp), bool); first = np.zeros(T, np.int64)
distinct = np.zeros((T, L), np.int32)
for t in range(T):
    for il in range(L):
        cur = tr[t, il]; cur = cur[(cur >= 0) & (cur < n_exp)]
        first[t] += (~seen[il, cur]).sum(); seen[il, cur] = True
    distinct[t] = seen.sum(axis=1)
print('след %s: %d токенов, %d слоёв, top-%d из %d' % (fmt, T, L, U, n_exp))
print('ПЕРВЫЕ ПОЯВЛЕНИЯ по окнам %d токенов: доля обращений и штук на токен (нижняя граница промахов по истории)' % win)
for a in range(0, T, win):
    b = min(T, a + win); f = first[a:b].sum(); n = (b - a) * L * U
    print('  токены %5d-%5d: %6.2f%%  %5.1f/токен  (SSD %5.1f мс, HDD %6.1f мс)' % (a, b, f / n * 100, f / (b - a), f / (b - a) * 3.616, f / (b - a) * 23.287))
print('различных экспертов на слой к концу: среднее %.0f, мин %d, макс %d из %d' % (distinct[-1].mean(), distinct[-1].min(), distinct[-1].max(), n_exp))
print('к токену 200: %.0f; к 500: %.0f; к 1000: %.0f' % (distinct[min(199, T-1)].mean(), distinct[min(499, T-1)].mean(), distinct[min(999, T-1)].mean()))
