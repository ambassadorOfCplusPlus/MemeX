# -*- coding: utf-8 -*-
"""Simuljator politik REZIDENTNOSTI ekspertov po sledu marshrutizacii (oflajn, bez dvizhka).

Vopros: skolko popadanij dajot pul iz S slotov na sloj pri raznyh politikah vytesnenija, i gde
POTOLOK (Belady - orakul, znaet budushchee). Eto reshaet, skolko sil vkladyvat v rezidentnost
(vybor zhertvy) protiv predzagruzki (chtenie zaranee): esli Belady lish na 2-3% vyshe recency,
rezidentnost ischerpana i vyigrysh tolko v perekrytii chtenij so schjotom.

Politiki (vsjo - odin pul S slotov na sloj, kak C+Z v ExpertStore):
  fifo     - kolco (kak pick_victim segodnja dlja zapasnyh, bez zashchity want)
  lru      - vytesnjaetsja davnee vsego ISPOLZOVANNYJ
  lfu      - vytesnjaetsja s naimenshej NAKOPLENNOJ chastotoj (decay 1.0)
  decayL   - lfu s zatuhaniem score *= L za token (L=0.9 => ~10 tokenov pamjati)
  store    - kak ExpertStore SEGODNJA: C=want po decay-score s refresh raz v period (s SINHRONNYM
             dochityvaniem otsutstvujushchih want - schitaem otdelno kak 'refresh reads'), Z zapasnyh
             po kolcu FIFO
  lazy     - to zhe, no refresh NE chitaet: want lish zashchishchaet; zhertva sredi ne-want - po
             naimenshemu decay-score (predlagaemaja politika)
  belady   - orakul: vytesnjaetsja tot, kto ponadobitsja pozzhe vseh (verhnjaja granica)

Vhod: libo damp --prefetch-calib (MXPC: sel po sloju i tokenu), libo MXRD route-dump (sel), libo
sled MEMEX_EXPERT_TRACE. Hash-sloi (0..hash-1) uchityvajutsja otdelno (ih chitaet --prefetch-hash
tochno), po umolchaniju v itog NE vhodjat - kak v dvizhke, gde predskazatel ih ne kasaetsja.

Zapusk: py bench/pred_residency_sim.py FILE [--slots 54,64,70,80] [--decay 0.9] [--period 16]
"""
import argparse, io, struct, sys
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')


def load_any(path):
    """-> sel [n_tok, n_layer, n_used] int (-1 pad), n_expert, hash_layers"""
    raw = io.open(path, 'rb').read()
    magic = struct.unpack('<i', raw[:4])[0]
    if magic == 0x43505850:   # MXPC calib
        _, ver, n_layer, n_expert, n_used, k = struct.unpack('<iiiiii', raw[:24])
        rec = np.dtype([('tgt', '<i4'), ('tok', '<i4'), ('r0', '<f2', (n_expert,)), ('sel', '<i2', (n_used,))])
        r = np.frombuffer(raw[24:len(raw) - (len(raw) - 24) % rec.itemsize], dtype=rec)
        toks = np.unique(r['tok']); tmap = {t: i for i, t in enumerate(toks)}
        sel = -np.ones((len(toks), n_layer, n_used), np.int64)
        for x in r:
            sel[tmap[x['tok']], x['tgt']] = x['sel']
        return sel, n_expert, 3 if n_layer == 43 else 0
    if magic == 0x4452584D:   # MXRD route-dump
        _, ver, n_layer, n_embd, n_used, n_expert, hashl, _z = struct.unpack('<iiiiiiii', raw[:32])
        rec = np.dtype([('il', '<i4'), ('tok', '<i4'), ('x', '<f2', (n_embd,)), ('sel', '<i2', (n_used,))])
        body = raw[32:]; n = len(body) // rec.itemsize
        r = np.frombuffer(body[:n * rec.itemsize], dtype=rec)
        per = [np.where(r['il'] == il)[0] for il in range(n_layer)]
        T = min(len(p) for p in per)
        sel = -np.ones((T, n_layer, n_used), np.int64)
        for il in range(n_layer):
            sel[:, il] = r['sel'][per[il][:T]]
        return sel, n_expert, hashl
    # MEMEX_EXPERT_TRACE
    n_tok, n_layer, n_used, n_expert = struct.unpack('<iiii', raw[:16])
    sel = np.frombuffer(raw, dtype='<i4', offset=16, count=n_tok * n_layer * n_used).reshape(n_tok, n_layer, n_used).astype(np.int64)
    return sel, n_expert, 0


def sim_layer(seq, n_expert, S, policy, decay=0.9, period=16, C=None, warm=0):
    """seq: [T, n_used] vybory sloja. Vozvrashchaet (hits, picks, refresh_reads).
    Pervye `warm` tokenov - progrev (schitajutsja, no ne v metrike), kak zatravka prefillom."""
    T, U = seq.shape
    slots = {}                  # expert -> True (rezident)
    score = np.zeros(n_expert)  # decay-score / lfu
    last = np.full(n_expert, -1)
    fifo = []
    want = set()
    hits = picks = rreads = 0
    # Belady: sledujushchee ispolzovanie
    if policy == 'belady':
        nxt = np.full((T, n_expert), T + 1, np.int64)
        fut = np.full(n_expert, T + 1, np.int64)
        for t in range(T - 1, -1, -1):
            nxt[t] = fut
            for e in seq[t]:
                if e >= 0: fut[e] = t
    for t in range(T):
        es = [int(e) for e in seq[t] if e >= 0]
        cur = set(es)
        for e in es:
            if t >= warm: picks += 1
            if e in slots:
                if t >= warm: hits += 1
            else:
                if len(slots) >= S:
                    # vybor zhertvy
                    cand = [x for x in slots if x not in cur]
                    if policy in ('store', 'lazy'):
                        cand2 = [x for x in cand if x not in want]
                        if cand2: cand = cand2
                    if policy == 'fifo' or policy == 'store':
                        v = next(x for x in fifo if x in cand); fifo.remove(v)
                    elif policy == 'lru':
                        v = min(cand, key=lambda x: last[x])
                    elif policy in ('lfu', 'decay', 'lazy'):
                        v = min(cand, key=lambda x: (score[x], last[x]))
                    elif policy == 'belady':
                        v = max(cand, key=lambda x: nxt[t][x])
                    else:
                        raise SystemExit('politika ' + policy)
                    del slots[v]
                slots[e] = True
                if policy in ('fifo', 'store'): fifo.append(e)
            score[e] += 1.0
            last[e] = t
        if policy in ('decay', 'store', 'lazy') and decay < 1.0:
            score *= decay
        if policy in ('store', 'lazy') and C and (t + 1) % period == 0:
            top = np.argsort(-score, kind='stable')[:C]
            want = set(int(x) for x in top)
            if policy == 'store':
                # sinhronnoe dochityvanie otsutstvujushchih want v sloty ne-want (kak refresh())
                need = [x for x in want if x not in slots]
                free = [x for x in slots if x not in want]
                for x, v in zip(need, free):
                    del slots[v]; slots[x] = True
                    if v in fifo: fifo.remove(v)
                    fifo.append(x)
                    if t >= warm: rreads += 1
    return hits, picks, rreads


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('trace')
    ap.add_argument('--slots', default='54,64,70,80')
    ap.add_argument('--decay', type=float, default=0.9)
    ap.add_argument('--period', type=int, default=16)
    ap.add_argument('--spares', type=int, default=16, help='Z dlja politik store/lazy: C = S - Z')
    ap.add_argument('--warm', type=int, default=0, help='pervye N tokenov - progrev, ne v metrike')
    ap.add_argument('--policies', default='fifo,lru,lfu,decay,store,lazy,belady')
    ap.add_argument('--include-hash', action='store_true')
    a = ap.parse_args()
    sel, n_expert, hashl = load_any(a.trace)
    T, n_layer, U = sel.shape
    layers = list(range(0 if a.include_hash else hashl, n_layer))
    print('sled %s: %d tokenov x %d sloev x top-%d iz %d; hash-sloev %d (%s); progrev %d tokenov' %
          (a.trace, T, n_layer, U, n_expert, hashl, 'vkljucheny' if a.include_hash else 'iskljucheny', a.warm))
    pols = a.policies.split(',')
    print('\n%-6s ' % 'S' + ' '.join('%14s' % p for p in pols) + '   (popadanija %; store: +refresh-chtenij/token)')
    for S in [int(x) for x in a.slots.split(',')]:
        row = []
        for p in pols:
            h = n = rr = 0
            for il in layers:
                hh, nn, r = sim_layer(sel[:, il], n_expert, S, p, a.decay, a.period, C=max(1, S - a.spares), warm=a.warm)
                h += hh; n += nn; rr += r
            s = '%6.2f%%' % (100.0 * h / max(n, 1))
            if p == 'store':
                s += ' +%.1f' % (rr / max(T - a.warm, 1))
            row.append('%14s' % s)
        print('%-6d ' % S + ' '.join(row))
    print('\nCHTO NE IZMERENO: stoimost chtenij (vse promahi schitajutsja ravnymi), predzagruzka (zdes tolko\n'
          '  KTO lezhit v slotah), perenos na drugoj tekst; sled korotkij => holodnyj start vesit mnogo.\n'
          '  belady = potolok LJUBOJ politiki bez predskazanija budushchego teksta.')


if __name__ == '__main__':
    main()
