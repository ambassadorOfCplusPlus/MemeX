# -*- coding: utf-8 -*-
"""Obuchaemyj R1 dlja predzagruzki ekspertov - iz KALIBROVOCHNOGO DAMPA DVIZHKA (--prefetch-calib).

Chem otlichaetsja ot train_r1.py: tam vhod - damp skrytyh sostojanij prefilla (MEMEX_HIDDEN_TRACE,
tolko qwen35/qwen3next) + marshrutizatory iz gguf, cel - TOCHNYE logity sloja tgt. Zdes vhod - rovno
te pary, kotorye vidit sam dvizhok na DEKODE: r0 = router_tgt * x_{tgt-K} (snjat v do_prefetch, do
popravki i do recency) i FAKTICHESKIJ top-k sloja tgt (snjat v do_map). Rabotaet dlja ljuboj
arhitektury so storom (qwen3next/Coder-Next i deepseek4), ne trebuet gguf, uchit i smeshchenie
(u deepseek4 vybor idjot po sqrt_softplus(logit)+exp_probs_b - tozhdestvennyj R1 etogo ne znaet).

Format dampa (pishet ExpertStore, sm. expert_store.hpp ExpertStoreConfig::pref_calib):
  zagolovok int32[6] = {0x43505850 'MXPC', 1, n_layer, n_expert, n_used, K}
  zapisi fiksirovannoj dliny: int32 tgt, int32 token, f16 r0[n_expert], int16 sel[n_used] (-1 = pad)

Obuchenie (po sloju tgt): sc = [r0 ; 1] . Wc, Wc [n_expert+1][n_expert].
  ce    (po umolchaniju): softmax-kross-entropija na mnozhestvo vybrannyh (k-hot/k), L2 K TOZHDESTVU
        (mu*||Wc - [I;0]||^2): pri malom chisle par Wc ostajotsja ~tozhdestvom (bezopasno), pri bolshom
        - uchit popravku i smeshchenie. Shkala logitov sohranjaetsja => γ-recency iz dvizhka primenim.
  ridge (bystryj zakrytyj vid): Wc = (X'X + mu I)^-1 (X' tau*Yind + mu W0) - regressija na indikator
        vybora, tozhe zaankorena na tozhdestve. Grubee ce po shkale, no bez iteracij.

Chestnost: split PO VREMENI vnutri kazhdogo dampa (poslednie --holdout tokenov - kontrol), otchjot
tolko po kontrolju; vesa pered ocenkoj okrugljajutsja v f16, kak ih uvidit dvizhok. Pechataetsja:
pokrytie top-B (dolja fakticheskih vyborov v top-B) i "ispolzovano/predskazano" (= pokrytie*k/B -
rovno metrika PREFETCH_AB pri polnoj nerezidentnosti) dlja tozhdestva, obuchennogo, recency i
obuchennogo+γ*recency (γ sweep - podskazka dlja --prefetch-recency-w; recency simuliruetsja kak
L.score dvizhka: +1 za vybor, *λ za token, START S NULJA - bez zatravki/prefilla, sm. ogovorku).
Gorizont 1..H tokenov vperjod: kakuju dolju vyborov tokena t+h nakryvaet top-B recency v moment t.
Dolja PERVYH POJAVLENIJ (ekspert ne vstrechalsja na etom sloe ranshe v dampe) - potolok togo, chto
recency ne dostanet nikogda; R1 dostajot ih tolko cherez signal marshrutizatora.

Vyhod: r1_corr_kK.bin v formate load_prefetch: int32[4] = {n_layer, n_expert+1, n_expert, K},
telo f16 [n_layer][n_expert+1][n_expert]; sloi bez par (tgt < K, hash-sloi deepseek4, malo dannyh)
- tozhdestvo.

Zapusk:
  python bench/fit_prefetch_calib.py identity --n-layer 48 --n-expert 512 --k 4 --out r1_id_k4.bin
  python bench/fit_prefetch_calib.py inspect --calib calib.bin
  python bench/fit_prefetch_calib.py fit --calib calib_a.bin --calib calib_b.bin --out r1_corr_k4.bin
"""
import argparse, io, os, struct, sys
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

MAGIC = 0x43505850


# ------------------------------------------------------------------ vvod/vyvod
def load_calib(path):
    raw = io.open(path, 'rb').read()
    if len(raw) < 24:
        raise SystemExit('%s: koroche zagolovka' % path)
    magic, ver, n_layer, n_expert, n_used, k = struct.unpack('<iiiiii', raw[:24])
    if magic != MAGIC or ver != 1:
        raise SystemExit('%s: ne fajl kalibrovki MXPC v1 (magic %08x, ver %d)' % (path, magic & 0xffffffff, ver))
    rec = np.dtype([('tgt', '<i4'), ('tok', '<i4'), ('r0', '<f2', (n_expert,)), ('sel', '<i2', (n_used,))])
    body = raw[24:]
    n = len(body) // rec.itemsize
    if n * rec.itemsize != len(body):
        print('  %s: hvost %d bajt otbroshen (progon prervan posredine zapisi)' % (path, len(body) - n * rec.itemsize))
    recs = np.frombuffer(body, dtype=rec, count=n)
    return dict(n_layer=n_layer, n_expert=n_expert, n_used=n_used, k=k, recs=recs, path=path)


def write_r1(path, corr, k):
    n_layer, n_in, n_out = corr.shape
    with io.open(path, 'wb') as f:
        f.write(struct.pack('<iiii', n_layer, n_in, n_out, k))
        f.write(corr.astype('<f2').tobytes())
    print('zapisano %s: %d bajt = 16 + %d*%d*%d*2, K=%d' % (path, os.path.getsize(path), n_layer, n_in, n_out, k))


def identity_corr(n_layer, n_expert):
    corr = np.zeros((n_layer, n_expert + 1, n_expert), dtype=np.float32)
    corr[:, :n_expert, :] = np.eye(n_expert, dtype=np.float32)[None]
    return corr


# ------------------------------------------------------------------ metriki
def coverage(score, sel, budgets):
    """score [N,E], sel [N,U] (-1 pad) -> massiv [len(budgets)]: dolja vyborov v top-B."""
    N, E = score.shape
    order = np.argsort(-score, axis=1, kind='stable')
    rank = np.empty_like(order)
    rank[np.arange(N)[:, None], order] = np.arange(E)[None, :]
    valid = sel >= 0
    r = np.take_along_axis(rank, np.where(valid, sel, 0), axis=1)
    tot = valid.sum()
    return np.array([(r[valid] < B).sum() / max(tot, 1) for B in budgets])


def simulate_recency(tokens, sels, n_expert, lam):
    """Recency L.score dvizhka dlja odnogo sloja: vozvrashchaet [N,E] score V MOMENT predskazanija
    (posle vseh tokenov < t), + dlja kazhdoj zapisi flag 'pervoe pojavlenie' po vyboram.
    tokens/sels otsortirovany po tokenu, po odnoj zapisi na token."""
    N = len(tokens)
    out = np.zeros((N, n_expert), dtype=np.float32)
    first = np.zeros(sels.shape, dtype=bool)
    s = np.zeros(n_expert, dtype=np.float32)
    seen = np.zeros(n_expert, dtype=bool)
    prev_tok = None
    for i in range(N):
        if prev_tok is not None:
            gap = int(tokens[i] - prev_tok)
            if gap > 0 and lam < 1.0:
                s *= lam ** gap
        out[i] = s
        e = sels[i][sels[i] >= 0]
        first[i, sels[i] >= 0] = ~seen[e]
        seen[e] = True
        np.add.at(s, e, 1.0)
        prev_tok = tokens[i]
    return out, first


# ------------------------------------------------------------------ obuchenie
def fit_ce(X, sel, W0, mu, steps, lr):
    """Softmax-CE na mnozhestvo vybrannyh, Adam, polnyj batch, L2 k W0. X [N,E+1] f32, sel [N,U]."""
    N, D = X.shape
    E = W0.shape[1]
    Y = np.zeros((N, E), dtype=np.float32)
    valid = sel >= 0
    rows = np.repeat(np.arange(N), valid.sum(1))
    np.add.at(Y, (rows, sel[valid]), 1.0)
    Y /= np.maximum(Y.sum(1, keepdims=True), 1.0)
    W = W0.copy()
    m = np.zeros_like(W); v = np.zeros_like(W)
    b1, b2, eps = 0.9, 0.999, 1e-8
    Xt = X.T.copy()
    for t in range(1, steps + 1):
        Z = X @ W
        Z -= Z.max(1, keepdims=True)
        P = np.exp(Z); P /= P.sum(1, keepdims=True)
        G = Xt @ (P - Y) / N + mu * (W - W0)
        m = b1 * m + (1 - b1) * G
        v = b2 * v + (1 - b2) * G * G
        W -= lr * (m / (1 - b1 ** t)) / (np.sqrt(v / (1 - b2 ** t)) + eps)
    return W


def fit_ridge(X, sel, W0, mu, tau):
    N, D = X.shape
    E = W0.shape[1]
    Y = np.zeros((N, E), dtype=np.float64)
    valid = sel >= 0
    rows = np.repeat(np.arange(N), valid.sum(1))
    Y[rows, sel[valid]] = tau
    Xd = X.astype(np.float64)
    A = Xd.T @ Xd + mu * np.eye(D)
    B = Xd.T @ Y + mu * W0.astype(np.float64)
    return np.linalg.solve(A, B).astype(np.float32)


# ------------------------------------------------------------------ komandy
def cmd_identity(a):
    write_r1(a.out, identity_corr(a.n_layer, a.n_expert), a.k)
    print('tozhdestvennyj R1 (R1 = R0): godjotsja dlja kalibrovochnogo progona i kak bazlajn "naive"')


def cmd_inspect(a):
    for p in a.calib:
        d = load_calib(p)
        r = d['recs']
        print('%s: n_layer %d, n_expert %d, n_used %d, K %d, zapisej %d' % (p, d['n_layer'], d['n_expert'], d['n_used'], d['k'], len(r)))
        if len(r) == 0:
            continue
        toks = np.unique(r['tok'])
        print('  tokenov %d (%d..%d), sloev s zapisjami %d: %s' % (len(toks), toks.min(), toks.max(), len(np.unique(r['tgt'])),
              ','.join(str(x) for x in np.unique(r['tgt']))))
        budgets = [int(x) for x in a.budgets.split(',')]
        cov = coverage(r['r0'].astype(np.float32), r['sel'].astype(np.int64), budgets)
        print('  tozhdestvo (R1=R0) pokrytie top-B po VSEM zapisjam: ' + ', '.join('B=%d %.1f%%' % (B, c * 100) for B, c in zip(budgets, cov)))


def cmd_fit(a):
    dumps = [load_calib(p) for p in a.calib]
    d0 = dumps[0]
    for d in dumps[1:]:
        if (d['n_layer'], d['n_expert'], d['n_used'], d['k']) != (d0['n_layer'], d0['n_expert'], d0['n_used'], d0['k']):
            raise SystemExit('dampy raznoj geometrii/K: %s vs %s' % (d['path'], d0['path']))
    n_layer, E, U, K = d0['n_layer'], d0['n_expert'], d0['n_used'], d0['k']
    budgets = [int(x) for x in a.budgets.split(',')]
    gammas = [float(x) for x in a.gammas.split(',')]
    if a.main_budget not in budgets:
        budgets.append(a.main_budget); budgets.sort()
    bi = budgets.index(a.main_budget)
    print('K=%d, sloev %d, ekspertov %d, top-k %d, dampov %d, metod %s, mu %.3g, holdout %.0f%%, recency λ=%.3f' %
          (K, n_layer, E, U, len(dumps), a.method, a.mu, a.holdout * 100, a.decay))

    # split po vremeni vnutri kazhdogo dampa
    parts = []
    for di, d in enumerate(dumps):
        r = d['recs']
        if len(r) == 0:
            continue
        toks = np.unique(r['tok'])
        cut = toks[int(len(toks) * (1.0 - a.holdout))] if len(toks) > 1 else toks[0] + 1
        parts.append((di, r, cut))
        print('  %s: %d tokenov, kontrol s tokena %d (%d tokenov)' % (d['path'], len(toks), cut, (toks >= cut).sum()))

    corr = identity_corr(n_layer, E)
    W0 = corr[0].copy()
    agg = {}   # imja -> summa pokrytij po budgets (vzveshenno chislom vyborov)
    agg_n = 0
    horizon = np.zeros(a.horizon); horizon_n = np.zeros(a.horizon)
    first_n = 0; first_tot = 0
    print('\n  %-5s %6s %6s | %-16s %-16s %-16s | %s' % ('sloj', 'N_tr', 'N_te', 'tozhd B=%d' % a.main_budget,
          'obuch B=%d' % a.main_budget, 'recency B=%d' % a.main_budget, 'luchshee obuch+γ (γ)'))
    layers_fit = 0
    for tgt in range(n_layer):
        Xtr, Str, Xte, Ste, Rte, Fte, Hte = [], [], [], [], [], [], []
        for di, r, cut in parts:
            rl = r[r['tgt'] == tgt]
            if len(rl) == 0:
                continue
            rl = rl[np.argsort(rl['tok'], kind='stable')]
            r0 = rl['r0'].astype(np.float32); sel = rl['sel'].astype(np.int64); tok = rl['tok']
            rec, first = simulate_recency(tok, sel, E, a.decay)
            tr = tok < cut; te = ~tr
            Xtr.append(r0[tr]); Str.append(sel[tr])
            Xte.append(r0[te]); Ste.append(sel[te]); Rte.append(rec[te]); Fte.append(first[te])
            # gorizont: recency v moment t protiv vyborov t+h (v predelah etogo dampa, kontrol)
            idx = np.where(te)[0]
            for h in range(1, a.horizon + 1):
                ok = idx + h < len(rl)
                if ok.any():
                    Hte.append((h, coverage(rec[idx[ok]], sel[idx[ok] + h], [a.main_budget])[0], (sel[idx[ok] + h] >= 0).sum()))
        if not Xtr:
            continue
        Xtr = np.concatenate(Xtr); Str = np.concatenate(Str)
        Xte = np.concatenate(Xte); Ste = np.concatenate(Ste); Rte = np.concatenate(Rte); Fte = np.concatenate(Fte)
        if len(Xtr) < a.min_samples:
            print('  %-5d %6d %6d | malo par (< %d) - ostavleno tozhdestvo' % (tgt, len(Xtr), len(Xte), a.min_samples))
            continue
        Xb = np.concatenate([Xtr, np.ones((len(Xtr), 1), np.float32)], axis=1)
        if a.method == 'ce':
            W = fit_ce(Xb, Str, W0, a.mu, a.steps, a.lr)
        else:
            tau = a.tau if a.tau > 0 else float(np.std(Xtr)) * 4.0
            W = fit_ridge(Xb, Str, W0, a.mu, tau)
        corr[tgt] = W
        layers_fit += 1
        if len(Xte) == 0:
            print('  %-5d %6d %6d | net kontrolja' % (tgt, len(Xtr), 0))
            continue
        W16 = W.astype(np.float16).astype(np.float32)
        Xbte = np.concatenate([Xte, np.ones((len(Xte), 1), np.float32)], axis=1)
        sc_id = Xte
        sc_tr = Xbte @ W16
        res = {'tozhdestvo': coverage(sc_id, Ste, budgets), 'obuchennyj': coverage(sc_tr, Ste, budgets),
               'recency': coverage(Rte, Ste, budgets)}
        for g in gammas:
            res['obuch+%.3gγ' % g] = coverage(sc_tr + g * Rte, Ste, budgets)
            res['tozhd+%.3gγ' % g] = coverage(sc_id + g * Rte, Ste, budgets)
        nsel = (Ste >= 0).sum()
        for k_, v in res.items():
            agg[k_] = agg.get(k_, 0.0) + v * nsel
        agg_n += nsel
        for h, c, n in Hte:
            horizon[h - 1] += c * n; horizon_n[h - 1] += n
        first_n += (Fte & (Ste >= 0)).sum(); first_tot += nsel
        best = max(((g, res['obuch+%.3gγ' % g][bi]) for g in gammas), key=lambda x: x[1])
        print('  %-5d %6d %6d | %6.1f%%           %6.1f%%           %6.1f%%           | %6.1f%% (γ=%.3g)' %
              (tgt, len(Xtr), len(Xte), res['tozhdestvo'][bi] * 100, res['obuchennyj'][bi] * 100,
               res['recency'][bi] * 100, best[1] * 100, best[0]))

    if agg_n == 0:
        raise SystemExit('ni odnoj kontrolnoj pary - umenshite --min-samples ili soberite bolshe tokenov')
    print('\nKONTROL (poslednie %.0f%% tokenov kazhdogo dampa, vesa f16), pokrytie top-B / ispolzovano-predskazano:' % (a.holdout * 100))
    print('  %-16s ' % 'sposob' + ' '.join('%16s' % ('B=%d' % B) for B in budgets))
    order = ['tozhdestvo', 'obuchennyj', 'recency'] + ['tozhd+%.3gγ' % g for g in gammas] + ['obuch+%.3gγ' % g for g in gammas]
    for k_ in order:
        v = agg[k_] / agg_n
        print('  %-16s ' % k_ + ' '.join('%7.1f%% / %5.2f' % (c * 100, c * U / B) for c, B in zip(v, budgets)))
    print('  (ispolzovano/predskazano = pokrytie*k/B: pri polnoj nerezidentnosti eto used/predicted iz PREFETCH_AB;\n'
          '   v boju chast top-B uzhe rezidentna i ne chitaetsja, tak chto realnyj issued nizhe)')
    print('\nPERVYE POJAVLENIJA v kontrole: %.1f%% vyborov - ekspert ne vstrechalsja na etom sloe ranshe v dampe\n'
          '  (recency ih ne dostajot v principe; R1 - tolko cherez marshrutizator)' % (100.0 * first_n / max(first_tot, 1)))
    print('GORIZONT (tolko recency λ=%.3f, B=%d): dolja vyborov tokena t+h, nakrytyh recency v moment t:' % (a.decay, a.main_budget))
    print('  ' + '  '.join('h=%d %.1f%%' % (h + 1, 100.0 * horizon[h] / max(horizon_n[h], 1)) for h in range(a.horizon)))
    print('  => esli h=1..4 blizki drug k drugu, gorjachij nabor stabilen i γ*recency v do_prefetch = deshjovyj\n'
          '     mnogotokennyj gorizont bez smeny formata [n_expert+1][n_expert] (priznakov tam net, sm. shapku)')
    print('\nOGOVORKI: recency simulirovana s nulja (v dvizhke L.score = zatravka --expert-prior + prefill + dekod,\n'
          '  poetomu bojevaja recency polnee); kontrol - tot zhe tekst, chto obuchenie (drugie tokeny), perenos na\n'
          '  chuzhoj tekst = dat --calib s odnogo promta i proverjat na drugom (sm. --eval-calib); sloev obucheno %d iz %d.' % (layers_fit, n_layer))

    if a.eval_calib:
        ev = [load_calib(p) for p in a.eval_calib]
        c16 = corr.astype(np.float16).astype(np.float32)
        tot = {}; n_tot = 0
        for d in ev:
            r = d['recs']
            for tgt in np.unique(r['tgt']):
                rl = r[r['tgt'] == tgt]
                r0 = rl['r0'].astype(np.float32); sel = rl['sel'].astype(np.int64)
                Xb = np.concatenate([r0, np.ones((len(r0), 1), np.float32)], axis=1)
                ns = (sel >= 0).sum(); n_tot += ns
                tot['tozhdestvo'] = tot.get('tozhdestvo', 0) + coverage(r0, sel, budgets) * ns
                tot['obuchennyj'] = tot.get('obuchennyj', 0) + coverage(Xb @ c16[tgt], sel, budgets) * ns
        print('\nPERENOS na chuzhie dampy (%s), pokrytie top-B:' % ', '.join(a.eval_calib))
        for k_, v in tot.items():
            print('  %-12s ' % k_ + ' '.join('B=%d %.1f%%' % (B, c / n_tot * 100) for c, B in zip(v, budgets)))

    write_r1(a.out, corr, K)
    print('ISPOLZOVANIE: --expert-prefetch %s --prefetch-budget B [--prefetch-recency-w γ --expert-store-decay %.3f]\n'
          'NE IZMERENO: skorost v dvizhke (tok/s), used/issued v boju - tolko posle sborki i progona s etim fajlom.' % (a.out, a.decay))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('identity'); p.add_argument('--n-layer', type=int, required=True); p.add_argument('--n-expert', type=int, required=True)
    p.add_argument('--k', type=int, required=True); p.add_argument('--out', required=True); p.set_defaults(fn=cmd_identity)
    p = sp.add_parser('inspect'); p.add_argument('--calib', action='append', required=True); p.add_argument('--budgets', default='8,10,16,32')
    p.set_defaults(fn=cmd_inspect)
    p = sp.add_parser('fit')
    p.add_argument('--calib', action='append', required=True, help='damp(y) --prefetch-calib (povtorjaemyj)')
    p.add_argument('--eval-calib', action='append', default=[], help='chuzhie dampy tolko dlja proverki perenosa')
    p.add_argument('--out', required=True)
    p.add_argument('--method', choices=['ce', 'ridge'], default='ce')
    p.add_argument('--mu', type=float, default=1.0, help='L2 k tozhdestvu (bolshe = ostorozhnee)')
    p.add_argument('--steps', type=int, default=300); p.add_argument('--lr', type=float, default=0.02)
    p.add_argument('--tau', type=float, default=0.0, help='ridge: shkala indikatora (0 = 4*std(r0))')
    p.add_argument('--holdout', type=float, default=0.25)
    p.add_argument('--min-samples', type=int, default=64)
    p.add_argument('--budgets', default='8,10,12,16')
    p.add_argument('--main-budget', type=int, default=10)
    p.add_argument('--decay', type=float, default=0.9, help='λ recency dlja simuljacii (= --expert-store-decay)')
    p.add_argument('--gammas', default='0,0.5,1,2,4', help='γ sweep (= --prefetch-recency-w)')
    p.add_argument('--horizon', type=int, default=4)
    p.set_defaults(fn=cmd_fit)
    a = ap.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
