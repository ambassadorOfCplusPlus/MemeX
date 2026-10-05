# -*- coding: utf-8 -*-
"""Obuchenie PREDSKAZATELJA EKSPERTOV po route-dump dvizhka (MEMEX_ROUTE_DUMP, format MXRD).

Chto predskazyvaetsja. V moment, kogda sloj l tokena t poschital vhod svoego marshrutizatora x_l,
nazvat top-k ekspertov sloev l+1..l+D TOGO ZHE tokena (D - glubina, sloi = vremja: ~14-23 ms na
sloj, chtenie eksperta s SSD ~16 ms => nuzhno D>=2 fory). Hash-sloi (0..hash-1) ne predskazyvajutsja
(tam marshrut po id tokena, ego chitaet --prefetch-hash tochno) i ne sluzhat istochnikom.

Priznaki - BESPLATNYE v grafe: r_tgt = W_tgt x_l (router celevogo sloja na tekushchem sostojanii,
256) i r_l = W_l x_l (sobstvennye logity sloja, 256). Golova na paru (l, d):
    z = r_tgt + W2 relu(W1 [r_tgt; r_l; 1] + b1) + b2      (H skrytyh; H=0 => linejnaja popravka)
Obuchenie - sigmoid-BCE po ekspertam (cel: mnozhestvo top-k), Adam, polnyj batch. Sigmoid nuzhen
NAROCHNO: dvizhok ne beret top-B, a chitaet tolko ekspertov s p >= tau - kalibrovannaja verojatnost
dajot upravljaemuju TOCHNOST predzagruzki (proval prezhnego R1: 13% tochnosti, polosa SSD v pustuju).

Sravnivaemye sposoby (vsjo na KONTROLE - drugie dokumenty/tokeny, chem obuchenie):
    R0      tozhdestvo: r_tgt kak est (chto delal identity-R1)
    lin     r_tgt + linejnaja popravka ot [r_tgt; r_l]  (H=0)
    mlp     H=256 (osnovnoj kandidat)
    xlin    polnyj rang x_l -> 256 (POTOLOK linejnogo po x, 1M parametrov na paru; v dvizhok ne idjot)
Metriki: recall@6 (dolja fakticheskih top-6 v predskazannyh top-6), recall@B dlja B=8,10,16, i
krivaja tochnost/otzyv po porogu p>=tau (imenno ona nuzhna dvizhku).

Vyhod: fajl predskazatelja MXPR (chitaet ExpertStore::load_predictor):
    int32[8] = {0x5250584D 'MXPR', 1, n_layer, n_expert, H, D, min_layer(hash), n_in(=2*n_expert)}
    f32 tau_pin[D], f32 tau_issue[D]  (porogi po glubine, podobrany zdes pod celevuju tochnost)
    dlja l in [0,n_layer) dlja d in [1..D]: int32 present; esli present:
        f16 W1[H][n_in], f16 b1[H], f16 W2[n_expert][H], f16 b2[n_expert]
Vesa pered ocenkoj okrugljajutsja v f16 - kak ih uvidit dvizhok.

Zapusk:
  py bench/pred_train.py fit --dump A.bin --dump B.bin --eval-dump C.bin --out ds4_pred.bin --depth 4 --hidden 256
  py bench/pred_train.py inspect --dump A.bin
"""
import argparse, io, os, struct, sys, time
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

MAGIC_RD = 0x4452584D
MAGIC_RT = 0x5452584D
MAGIC_PR = 0x5250584D


# ------------------------------------------------------------------ vvod
def load_dump(path):
    raw = np.fromfile(path, dtype=np.uint8)
    hd = raw[:32].view('<i4')
    if hd[0] != MAGIC_RD or hd[1] != 1:
        raise SystemExit('%s: ne route-dump MXRD v1' % path)
    n_layer, n_embd, n_used, n_expert, hashl = int(hd[2]), int(hd[3]), int(hd[4]), int(hd[5]), int(hd[6])
    rec = np.dtype([('il', '<i4'), ('tok', '<i4'), ('x', '<f2', (n_embd,)), ('sel', '<i2', (n_used,))])
    body = raw[32:]
    n = body.size // rec.itemsize
    if n * rec.itemsize != body.size:
        print('  %s: hvost %d bajt otbroshen (progon prervan)' % (path, body.size - n * rec.itemsize))
    r = body[:n * rec.itemsize].view(rec)
    per = [np.where(r['il'] == il)[0] for il in range(n_layer)]
    T = min(len(p) for p in per)
    if T == 0:
        raise SystemExit('%s: est sloj bez zapisej' % path)
    # [T, n_layer, ...]: dlja kazhdogo sloja porjadok zapisej = porjadok tokenov (sm. RouteDump)
    X = np.empty((T, n_layer, n_embd), np.float16)
    S = np.empty((T, n_layer, n_used), np.int64)
    tok = np.empty(T, np.int64)
    for il in range(n_layer):
        idx = per[il][:T]
        X[:, il] = r['x'][idx]
        S[:, il] = r['sel'][idx]
        if il == 0: tok[:] = r['tok'][idx]
    return dict(X=X, S=S, tok=tok, n_layer=n_layer, n_embd=n_embd, n_used=n_used, n_expert=n_expert, hashl=hashl, path=path)


def load_routers(path, n_layer, n_embd, n_expert):
    with io.open(path, 'rb') as f:
        hd = struct.unpack('<iiii', f.read(16))
        if hd[0] != MAGIC_RT or hd[1:] != (n_layer, n_embd, n_expert):
            raise SystemExit('%s: routery ne toj geometrii %s' % (path, hd))
        W = [None] * n_layer; B = [None] * n_layer
        for il in range(n_layer):
            has = struct.unpack('<i', f.read(4))[0]
            if has:
                raw = f.read(4 * n_expert * n_embd)
                if len(raw) < 4 * n_expert * n_embd:
                    print('  %s: sloj %d: router obrezan (%d bajt) - sloj bez routera' % (path, il, len(raw)))
                    break
                W[il] = np.frombuffer(raw, dtype='<f4').reshape(n_expert, n_embd).copy()
            hb = f.read(4)
            hasb = struct.unpack('<i', hb)[0] if len(hb) == 4 else 0
            if hasb:
                raw = f.read(4 * n_expert)
                if len(raw) < 4 * n_expert:
                    # HVOST FAJLA OBREZAN (nabljudalos: sloj 42, 166 iz 256 floatov - nedopisannyj bufer pri vyhode).
                    # Nedostajushchee = 0 (bias tolko smeshchaet top-k, dlja poslednego sloja kak celi eto melochi) - i VSLUH.
                    print('  %s: sloj %d: bias obrezan (%d iz %d floatov) - dopolnen nuljami' % (path, il, len(raw) // 4, n_expert))
                    raw = raw + b'\x00' * (4 * n_expert - len(raw))
                B[il] = np.frombuffer(raw, dtype='<f4').copy()
    return W, B


# ------------------------------------------------------------------ metriki
def topk_recall(score, sel, B):
    """dolja fakticheskih vyborov (sel, -1 pad) v top-B po score. score [N,E]."""
    N, E = score.shape
    B = min(B, E)
    part = np.argpartition(-score, B - 1, axis=1)[:, :B]
    hit = np.zeros(N, np.int64); tot = np.zeros(N, np.int64)
    for j in range(sel.shape[1]):
        s = sel[:, j]; v = s >= 0
        m = (part == s[:, None]).any(1) & v
        hit += m; tot += v
    return hit.sum() / max(tot.sum(), 1)


def pr_curve(prob, sel, taus):
    """dlja kazhdogo tau: (predskazano/sample, tochnost, otzyv)."""
    N, E = prob.shape
    Y = np.zeros((N, E), bool)
    for j in range(sel.shape[1]):
        s = sel[:, j]; v = s >= 0
        Y[np.where(v)[0], s[v]] = True
    out = []
    for tau in taus:
        P = prob >= tau
        tp = (P & Y).sum(); npred = P.sum(); npos = Y.sum()
        out.append((npred / N, tp / max(npred, 1), tp / max(npos, 1)))
    return out


# ------------------------------------------------------------------ model
def sigmoid(z):
    return 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))


def fit_head(F, Y, base, H, steps, lr, wd, seed=0, val=None, verbose=False):
    """F [N,n_in] priznaki (s edinicej), Y [N,E] 0/1, base [N,E] (r_tgt, ostatochnaja svjaz).
    Vozvrashchaet (W1,b1,W2,b2) ili (None,None,W2,b2) pri H==0 (togda W2 - [n_in,E])."""
    rng = np.random.default_rng(seed)
    N, nin = F.shape; E = Y.shape[1]
    pos_w = 1.0   # bez perevzveshivanija: kalibrovannaja p nuzhna kak est
    if H > 0:
        W1 = (rng.standard_normal((nin, H)) * np.sqrt(2.0 / nin)).astype(np.float32); b1 = np.zeros(H, np.float32)
        W2 = np.zeros((H, E), np.float32); b2 = np.zeros(E, np.float32)
        params = [W1, b1, W2, b2]
    else:
        W2 = np.zeros((nin, E), np.float32); b2 = np.zeros(E, np.float32)
        params = [W2, b2]
    m = [np.zeros_like(p) for p in params]; v = [np.zeros_like(p) for p in params]
    b1a, b2a, eps = 0.9, 0.999, 1e-8
    bs = min(N, 2048)
    t = 0
    for step in range(1, steps + 1):
        idx = rng.choice(N, bs, replace=False) if bs < N else np.arange(N)
        f = F[idx]; y = Y[idx]; bz = base[idx]
        if H > 0:
            a = f @ W1 + b1; h = np.maximum(a, 0.0)
            z = bz + h @ W2 + b2
        else:
            z = bz + f @ W2 + b2
        p = sigmoid(z)
        g = (p - y) / len(idx)
        if H > 0:
            gW2 = h.T @ g; gb2 = g.sum(0)
            gh = g @ W2.T; gh[a <= 0] = 0
            gW1 = f.T @ gh; gb1 = gh.sum(0)
            grads = [gW1 + wd * W1, gb1, gW2 + wd * W2, gb2]
        else:
            grads = [f.T @ g + wd * W2, g.sum(0)]
        t += 1
        for i, (pp, gg) in enumerate(zip(params, grads)):
            m[i] = b1a * m[i] + (1 - b1a) * gg
            v[i] = b2a * v[i] + (1 - b2a) * gg * gg
            pp -= lr * (m[i] / (1 - b1a ** t)) / (np.sqrt(v[i] / (1 - b2a ** t)) + eps)
        if verbose and (step % 100 == 0 or step == steps):
            loss = -(y * np.log(p + 1e-7) + (1 - y) * np.log(1 - p + 1e-7)).mean()
            print('    step %d bce %.4f' % (step, loss))
    if H > 0:
        return W1, b1, W2, b2
    return None, None, W2, b2


def head_forward(head, F, base, f16=True):
    W1, b1, W2, b2 = head
    if f16:
        cast = lambda a: None if a is None else a.astype(np.float16).astype(np.float32)
        W1, b1, W2, b2 = cast(W1), cast(b1), cast(W2), cast(b2)
    if W1 is not None:
        h = np.maximum(F @ W1 + b1, 0.0)
        return base + h @ W2 + b2
    return base + F @ W2 + b2


def features(X, W_l, W_tgt, mode):
    """X [N,n_embd] f32 -> (F, base). mode: 'r' -> [r_tgt; r_l; 1], base r_tgt; 'x' -> [x;1], base r_tgt."""
    r_t = X @ W_tgt.T
    if mode == 'x':
        F = np.concatenate([X, np.ones((len(X), 1), np.float32)], 1)
    else:
        r_l = X @ W_l.T
        F = np.concatenate([r_t, r_l, np.ones((len(X), 1), np.float32)], 1)
    return F.astype(np.float32), r_t.astype(np.float32)


def khot(sel, E):
    Y = np.zeros((len(sel), E), np.float32)
    for j in range(sel.shape[1]):
        s = sel[:, j]; v = s >= 0
        Y[np.where(v)[0], s[v]] = 1.0
    return Y


# ------------------------------------------------------------------ komandy
def cmd_inspect(a):
    for p in a.dump:
        d = load_dump(p)
        print('%s: %d tokenov x %d sloev, n_embd %d, top-%d iz %d, hash %d; tok[:8]=%s' %
              (p, d['X'].shape[0], d['n_layer'], d['n_embd'], d['n_used'], d['n_expert'], d['hashl'], d['tok'][:8].tolist()))
        S = d['S']
        for il in [d['hashl'], d['n_layer'] // 2, d['n_layer'] - 1]:
            u = np.unique(S[:, il][S[:, il] >= 0])
            print('  sloj %d: razlichnyh ekspertov %d iz %d' % (il, len(u), d['n_expert']))


def write_pred(path, heads, n_layer, E, H, D, min_layer, n_in, tau_pin, tau_issue):
    with io.open(path, 'wb') as f:
        f.write(struct.pack('<8i', MAGIC_PR, 1, n_layer, E, H, D, min_layer, n_in))
        f.write(np.asarray(tau_pin, '<f4').tobytes()); f.write(np.asarray(tau_issue, '<f4').tobytes())
        npres = 0
        for l in range(n_layer):
            for d in range(1, D + 1):
                hd = heads.get((l, d))
                if hd is None:
                    f.write(struct.pack('<i', 0)); continue
                W1, b1, W2, b2 = hd
                f.write(struct.pack('<i', 1)); npres += 1
                if H > 0:
                    f.write(np.ascontiguousarray(W1.T, '<f2').tobytes())   # [H][n_in]
                    f.write(np.asarray(b1, '<f2').tobytes())
                    f.write(np.ascontiguousarray(W2.T, '<f2').tobytes())   # [E][H]
                else:
                    f.write(np.ascontiguousarray(W2.T, '<f2').tobytes())   # [E][n_in]
                f.write(np.asarray(b2, '<f2').tobytes())
    print('zapisano %s: %d golov, %.1f MB' % (path, npres, os.path.getsize(path) / 1e6))


def cmd_fit(a):
    t_all = time.time()
    dumps = [load_dump(p) for p in a.dump]
    evals = [load_dump(p) for p in a.eval_dump]
    d0 = dumps[0]
    n_layer, E, U, hashl, n_embd = d0['n_layer'], d0['n_expert'], d0['n_used'], d0['hashl'], d0['n_embd']
    rpath = a.routers or (a.dump[0] + '.routers')
    Wr, Br = load_routers(rpath, n_layer, n_embd, E)
    D = a.depth
    print('dampov %d (+%d kontrolnyh), sloev %d, ekspertov %d, top-%d, hash %d, glubina 1..%d, H=%d, holdout %.0f%% po vremeni'
          % (len(dumps), len(evals), n_layer, E, U, hashl, D, a.hidden, a.holdout * 100))
    for d in dumps + evals:
        print('  %s: %d tokenov' % (d['path'], d['X'].shape[0]))

    # Sanity k=0: router sloja l na x_l dolzhen davat FAKTICHESKIJ top-k (s uchjotom bias vybora)
    # - proverka soglasovannosti dampa i routerov, kak k=0 v hidden_lab.
    d = dumps[0]; il = hashl + 1
    X0 = d['X'][:, il].astype(np.float32); r = X0 @ Wr[il].T
    sc = np.sqrt(np.log1p(np.exp(r))) + (Br[il] if Br[il] is not None else 0.0)
    print('SANITY d=0 sloj %d: recall@%d po sqrt_softplus(router x)+bias = %.2f%% (dolzhno byt ~100)' %
          (il, U, 100 * topk_recall(sc, d['S'][:, il], U)))

    modes = a.modes.split(',')
    budgets = [int(x) for x in a.budgets.split(',')]
    taus = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
    agg = {}      # (mode, d) -> dict metric -> [sum, n]
    heads = {}
    def acc(key, name, val, n):
        s = agg.setdefault(key, {}).setdefault(name, [0.0, 0])
        s[0] += val * n; s[1] += n

    layers = [l for l in range(hashl, n_layer) if Wr[l] is not None]
    for l in layers:
        for dd in range(1, D + 1):
            tgt = l + dd
            if tgt >= n_layer or Wr[tgt] is None: continue
            # obuchenie: vse dampy krome poslednih holdout% tokenov kazhdogo; kontrol: eti hvosty + eval-dampy
            Xtr, Str, Xte, Ste = [], [], [], []
            for dmp in dumps:
                T = dmp['X'].shape[0]; cut = int(T * (1 - a.holdout))
                Xtr.append(dmp['X'][:cut, l]); Str.append(dmp['S'][:cut, tgt])
                Xte.append(dmp['X'][cut:, l]); Ste.append(dmp['S'][cut:, tgt])
            for dmp in evals:
                Xte.append(dmp['X'][:, l]); Ste.append(dmp['S'][:, tgt])
            Xtr = np.concatenate(Xtr).astype(np.float32); Str = np.concatenate(Str)
            Xte = np.concatenate(Xte).astype(np.float32); Ste = np.concatenate(Ste)
            Ytr = khot(Str, E)
            line = '  l=%2d d=%d tgt=%2d Ntr=%5d Nte=%4d |' % (l, dd, tgt, len(Xtr), len(Xte))
            for mode in modes:
                if mode == 'R0':
                    _, bte = features(Xte, Wr[l], Wr[tgt], 'r')
                    z = bte
                    if Br[tgt] is not None:   # tot zhe vybor, chto v grafe: sqrt_softplus + bias
                        z = np.sqrt(np.log1p(np.exp(z))) + Br[tgt]
                    prob = None
                else:
                    fmode = 'x' if mode == 'xlin' else 'r'
                    H = 0 if mode in ('lin', 'xlin') else a.hidden
                    Ftr, btr = features(Xtr, Wr[l], Wr[tgt], fmode)
                    Fte, bte = features(Xte, Wr[l], Wr[tgt], fmode)
                    # normirovka priznakov (masshtab routera proizvolnyj): po obuchajushchej vyborke
                    mu = Ftr.mean(0); sd = Ftr.std(0) + 1e-3; mu[-1] = 0; sd[-1] = 1
                    Ftr = (Ftr - mu) / sd; Fte = (Fte - mu) / sd
                    # bazu tozhe privodim k shkale logitov: r_tgt centriruem po ekspertu
                    bmu = btr.mean(0)
                    head = fit_head(Ftr, Ytr, btr - bmu, H, a.steps, a.lr, a.wd, seed=l * 10 + dd)
                    z = head_forward(head, Fte, bte - bmu, f16=True)
                    prob = sigmoid(z)
                    if mode == a.export:
                        # vkladyvaem normirovku v vesa: F_norm = (F-mu)/sd => W1' = W1/sd, b1' = b1 - (mu/sd)W1
                        # vkladyvaem normirovku i stolbec edinic v vesa: F_norm = (F-mu)/sd, poslednij
                        # priznak = 1 (mu=0, sd=1) => ego stroka vesov uhodit v smeshchenie; dvizhok podajot
                        # feats = [r_tgt; r_l] (n_in = 2E) bez edinicy.
                        W1, b1, W2, b2 = head
                        if W1 is not None:
                            W1e = W1[:-1] / sd[:-1, None]; b1e = b1 + W1[-1] - (mu[:-1] / sd[:-1]) @ W1[:-1]
                            b2e = b2 - bmu
                            heads[(l, dd)] = (W1e.astype(np.float32), b1e.astype(np.float32), W2, b2e.astype(np.float32))
                        else:
                            W2e = W2[:-1] / sd[:-1, None]; b2e = b2 + W2[-1] - (mu[:-1] / sd[:-1]) @ W2[:-1] - bmu
                            heads[(l, dd)] = (None, None, W2e.astype(np.float32), b2e.astype(np.float32))
                n = (Ste >= 0).sum()
                for B in budgets:
                    acc((mode, dd), 'r@%d' % B, topk_recall(z, Ste, B), n)
                if prob is not None:
                    for tau, (npred, prec, rec) in zip(taus, pr_curve(prob, Ste, taus)):
                        acc((mode, dd), 'n@%.1f' % tau, npred, n); acc((mode, dd), 'p@%.1f' % tau, prec, n); acc((mode, dd), 'c@%.1f' % tau, rec, n)
                line += ' %s r@%d %.1f%%' % (mode, U, 100 * topk_recall(z, Ste, U))
            if a.verbose: print(line)
        if not a.verbose: print('  sloj %d gotov (%.0f s)' % (l, time.time() - t_all)); sys.stdout.flush()

    print('\nKONTROL (hvosty %.0f%% obuchajushchih dampov + eval-dampy; vesa f16). recall@B = dolja fakticheskih top-%d v top-B predskazanija:' % (a.holdout * 100, U))
    print('  %-5s %-3s ' % ('mode', 'd') + ' '.join('%9s' % ('r@%d' % B) for B in budgets))
    for mode in modes:
        for dd in range(1, D + 1):
            s = agg.get((mode, dd))
            if not s: continue
            print('  %-5s %-3d ' % (mode, dd) + ' '.join('%8.2f%%' % (100 * s['r@%d' % B][0] / s['r@%d' % B][1]) for B in budgets))
    print('\nPOROG p>=tau (chto chitaet dvizhok): predskazano/sloj, tochnost, otzyv - po glubine:')
    for mode in modes:
        if mode == 'R0': continue
        for dd in range(1, D + 1):
            s = agg.get((mode, dd))
            if not s: continue
            print('  %-5s d=%d ' % (mode, dd) + ' | '.join('tau %.1f: %4.1f pred, P %.0f%% R %.0f%%' % (
                tau, s['n@%.1f' % tau][0] / s['n@%.1f' % tau][1], 100 * s['p@%.1f' % tau][0] / s['p@%.1f' % tau][1],
                100 * s['c@%.1f' % tau][0] / s['c@%.1f' % tau][1]) for tau in taus))

    if a.out and heads:
        H = 0 if a.export in ('lin',) else a.hidden
        # porogi po glubine pod celevuju tochnost: pin (mjagche) i issue (strozhe)
        tau_pin, tau_issue = [], []
        for dd in range(1, D + 1):
            s = agg.get((a.export, dd), {})
            def pick(target):
                best = taus[-1]
                for tau in taus:
                    if s.get('p@%.1f' % tau) and s['p@%.1f' % tau][0] / s['p@%.1f' % tau][1] >= target:
                        return tau
                return best
            tau_pin.append(pick(a.prec_pin)); tau_issue.append(pick(a.prec_issue))
        print('porogi po glubine: pin %s (tochnost>=%.0f%%), issue %s (tochnost>=%.0f%%)' % (tau_pin, 100 * a.prec_pin, tau_issue, 100 * a.prec_issue))
        write_pred(a.out, heads, n_layer, E, H, D, hashl, 2 * E, tau_pin, tau_issue)
    print('vsego %.0f s' % (time.time() - t_all))
    print('\nCHTO NE IZMERENO: skorost v dvizhke (tok/s) i realnaja tochnost predzagruzki v boju (chast\n'
          '  predskazannyh uzhe rezidentna i ne chitaetsja) - tolko posle sborki i A/B.')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('inspect'); p.add_argument('--dump', action='append', required=True); p.set_defaults(fn=cmd_inspect)
    p = sp.add_parser('fit')
    p.add_argument('--dump', action='append', required=True, help='obuchajushchie route-dumpy (hvost kazhdogo - kontrol)')
    p.add_argument('--eval-dump', action='append', default=[], help='tolko kontrol (naprimer dekod-damp)')
    p.add_argument('--routers', default=None, help='fajl .routers (po umolchaniju <pervyj damp>.routers)')
    p.add_argument('--out', default=None)
    p.add_argument('--depth', type=int, default=4)
    p.add_argument('--hidden', type=int, default=256)
    p.add_argument('--steps', type=int, default=400)
    p.add_argument('--lr', type=float, default=3e-3)
    p.add_argument('--wd', type=float, default=1e-4)
    p.add_argument('--holdout', type=float, default=0.2)
    p.add_argument('--budgets', default='6,8,10,16')
    p.add_argument('--modes', default='R0,lin,mlp')
    p.add_argument('--export', default='mlp')
    p.add_argument('--prec-pin', type=float, default=0.5)
    p.add_argument('--prec-issue', type=float, default=0.7)
    p.add_argument('--verbose', action='store_true')
    p.set_defaults(fn=cmd_fit)
    a = ap.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
