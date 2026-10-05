# -*- coding: utf-8 -*-
"""DOMENNYE PRESETY marshrutizatora + oflajn-krivaja MJAGKOGO SHTRAFA (ideja polzovatelja).

Preset domena = na kazhdyj routed-sloj top-K ekspertov po chastote vyborov na domennom korpuse
(route-dump MXRD ili sled MXPC/MEMEX_EXPERT_TRACE). Hash-sloi (0..hash-1) v preset ne vhodjat:
tam marshrut po id tokena, shtrafovat nechego.

Fajl preseta MXPS (chitaet dvizhok, --preset): int32[4] = {0x5350584D 'MXPS', n_layer, n_expert, K};
po sloju: int32 n_kept, int32 ids[n_kept] (0 dlja hash-sloev).

MJAGKIJ SHTRAF (--route-penalty L v dvizhke): pered top-k iz OCENKI VYBORA (u deepseek4 eto
sqrt_softplus(logit) + exp_probs_b - imenno ejo vidit ggml_top_k, a ne syroj logit) vychitaetsja L
u ekspertov vne preseta. L=0 - bit-v-bit. Zdes ta zhe operacija schitaetsja OFLAJN po dampu
(x_l i routery est): dlja setki L - dolja vyborov, kotorye smenilis, i pokrytie vyborov presetom.
Eto priblizhenie pervogo porjadka (izmenjonnyj vybor na sloe l ne menjaet x_{l+1} v dampe) -
nastojashchuju krivuju (tok/s, promahi, sovpadenie vyvoda) dajot tolko dvizhok. Zato setka L
vybiraetsja po shkale REALNYH zazorov mezhdu 6-m i 7-m ekspertom, a ne naugad.

Zapusk:
  py bench/pred_presets.py build --dump dump_code.bin --k 64 --out preset_code.bin [--name coding]
  py bench/pred_presets.py overlap --preset a.bin --preset b.bin
  py bench/pred_presets.py penalty --dump dump_code.bin --preset preset_code.bin --preset preset_prose.bin --lams 0,0.1,0.25,0.5,1,2,1e9
"""
import argparse, io, os, struct, sys
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pred_residency_sim import load_any          # noqa: E402  (sel iz MXRD/MXPC/trace)
from pred_train import load_dump, load_routers  # noqa: E402

MAGIC_PS = 0x5350584D


def write_preset(path, kept, n_layer, n_expert, K):
    with io.open(path, 'wb') as f:
        f.write(struct.pack('<4i', MAGIC_PS, n_layer, n_expert, K))
        for il in range(n_layer):
            ids = np.asarray(kept[il], '<i4')
            f.write(struct.pack('<i', len(ids))); f.write(ids.tobytes())
    print('zapisano %s: %d sloev, K=%d, %d bajt' % (path, n_layer, K, os.path.getsize(path)))


def read_preset(path):
    with io.open(path, 'rb') as f:
        magic, n_layer, n_expert, K = struct.unpack('<4i', f.read(16))
        if magic != MAGIC_PS: raise SystemExit('%s: ne preset MXPS' % path)
        kept = []
        for il in range(n_layer):
            n = struct.unpack('<i', f.read(4))[0]
            kept.append(np.frombuffer(f.read(4 * n), dtype='<i4').copy())
    return kept, n_layer, n_expert, K


def cmd_build(a):
    sels = []; n_expert = None; hashl = 0
    for p in a.dump:
        sel, E, h = load_any(p); sels.append(sel); n_expert = E; hashl = max(hashl, h)
    sel = np.concatenate(sels)
    T, n_layer, U = sel.shape
    if a.hash is not None: hashl = a.hash
    kept = []
    cover = []
    for il in range(n_layer):
        if il < hashl: kept.append(np.zeros(0, np.int64)); continue
        s = sel[:, il][sel[:, il] >= 0]
        cnt = np.bincount(s, minlength=n_expert)
        top = np.argsort(-cnt, kind='stable')[:a.k]
        top = top[cnt[top] > 0]          # ni razu ne vybrannye v domene - vne preseta (na nih lam_off)
        # PORJADOK V FAJLE = RANG PO CHASTOTE (dvizhok berjot verhnie C spiska rezidentno) - ne sortirovat po id
        kept.append(top)
        cover.append(cnt[top].sum() / max(cnt.sum(), 1))
    print('%s: %d tokenov, %d sloev (hash %d), top-%d na sloj; pokrytie vyborov SVOEGO korpusa: srednee %.1f%%, min %.1f%%, max %.1f%%' %
          (a.name or ','.join(a.dump), T, n_layer, hashl, a.k, 100 * np.mean(cover), 100 * np.min(cover), 100 * np.max(cover)))
    write_preset(a.out, kept, n_layer, n_expert, a.k)


def cmd_curve(a):
    """CHASTOTNAJA KRIVAJA domena: kakuju dolju vyborov pokryvajut top-K ekspertov sloja (K = 8..E),
    srednee/min po routed-slojam. Otvet na vopros 'koncentriruetsja li domen dostatochno tugo'."""
    sels = []; n_expert = None; hashl = 0
    for p in a.dump:
        sel, E, h = load_any(p); sels.append(sel); n_expert = E; hashl = max(hashl, h)
    sel = np.concatenate(sels)
    T, n_layer, U = sel.shape
    Ks = [int(k) for k in a.ks.split(',')] if a.ks else [8, 16, 24, 32, 48, 64, 96, 128, 160, 192, 224]
    Ks = [k for k in Ks if k <= n_expert]
    cov = np.zeros((n_layer, len(Ks)))
    n_used_experts = np.zeros(n_layer, int)
    for il in range(hashl, n_layer):
        s = sel[:, il][sel[:, il] >= 0]
        cnt = np.bincount(s, minlength=n_expert)
        srt = np.sort(cnt)[::-1]
        cum = np.cumsum(srt) / max(cnt.sum(), 1)
        n_used_experts[il] = (cnt > 0).sum()
        for j, k in enumerate(Ks): cov[il, j] = cum[k - 1]
    rows = cov[hashl:]
    print('%s: %d tokenov, %d routed-sloev, E=%d, top-%d; ekspertov, vstretivshihsja hot raz: srednee %.0f, max %d' %
          (a.name or ','.join(os.path.basename(p) for p in a.dump), T, n_layer - hashl, n_expert, U,
           n_used_experts[hashl:].mean(), n_used_experts[hashl:].max()))
    print('  %-6s %10s %10s %10s' % ('top-K', 'pokr.sred', 'pokr.min', 'pokr.max'))
    for j, k in enumerate(Ks):
        print('  %-6d %9.1f%% %9.1f%% %9.1f%%' % (k, 100 * rows[:, j].mean(), 100 * rows[:, j].min(), 100 * rows[:, j].max()))
    if a.gib:
        # skolko ekspertov na sloj vlezaet v bjudzhet (bajt na eksperta zadan) i kakoe eto pokrytie
        per = a.bytes_per_expert
        C = int(a.gib * 1073741824 / (per * (n_layer - hashl)))
        C = min(C, n_expert)
        cum_all = []
        for il in range(hashl, n_layer):
            s = sel[:, il][sel[:, il] >= 0]; cnt = np.bincount(s, minlength=n_expert)
            srt = np.sort(cnt)[::-1]; cum_all.append(srt[:C].sum() / max(cnt.sum(), 1))
        print('  bjudzhet %.1f GiB pri %.1f MiB/ekspert => C=%d na routed-sloj: pokrytie srednee %.1f%%, min %.1f%%' %
              (a.gib, per / 1048576, C, 100 * np.mean(cum_all), 100 * np.min(cum_all)))


def cmd_overlap(a):
    ps = [read_preset(p) for p in a.preset]
    names = [os.path.basename(p) for p in a.preset]
    n_layer = ps[0][1]
    print('peresechenie presetov po slojam (Jaccard, %):')
    for i in range(len(ps)):
        for j in range(i + 1, len(ps)):
            jac = []
            for il in range(n_layer):
                A = set(ps[i][0][il].tolist()); B = set(ps[j][0][il].tolist())
                if not A or not B: continue
                jac.append(len(A & B) / len(A | B))
            print('  %s vs %s: srednee %.1f%%, min %.1f%%, max %.1f%%' % (names[i], names[j], 100 * np.mean(jac), 100 * np.min(jac), 100 * np.max(jac)))
    # pokrytie chuzhogo korpusa presetom
    for p in a.dump:
        sel, E, h = load_any(p)
        for (kept, nl, ne, K), nm in zip(ps, names):
            cov = []
            for il in range(h, nl):
                s = sel[:, il][sel[:, il] >= 0]
                cov.append(np.isin(s, kept[il]).mean())
            print('  preset %s pokryvaet vybory %s: %.1f%% (min po slojam %.1f%%)' % (nm, os.path.basename(p), 100 * np.mean(cov), 100 * np.min(cov)))


def cmd_penalty(a):
    d = load_dump(a.dump)
    n_layer, E, U, hashl, n_embd = d['n_layer'], d['n_expert'], d['n_used'], d['hashl'], d['n_embd']
    Wr, Br = load_routers(a.routers or (a.dump + '.routers'), n_layer, n_embd, E)
    lams = [float(x) for x in a.lams.split(',')]
    presets = [(os.path.basename(p), read_preset(p)[0]) for p in a.preset]
    T = d['X'].shape[0]
    layers = [il for il in range(hashl, n_layer) if Wr[il] is not None]
    # ocenka vybora, kak v grafe
    gaps = []
    scores = {}
    for il in layers:
        X = d['X'][:, il].astype(np.float32)
        r = X @ Wr[il].T
        sc = np.sqrt(np.log1p(np.exp(r))) + (Br[il] if Br[il] is not None else 0.0)
        scores[il] = sc
        srt = -np.sort(-sc, axis=1)
        gaps.append(srt[:, U - 1] - srt[:, U])
    gaps = np.concatenate(gaps)
    print('%s: %d tokenov, %d routed-sloev. Zazor mezhdu %d-m i %d-m ekspertom po ocenke vybora: '
          'mediana %.3f, p10 %.3f, p90 %.3f (shkala dlja L)' % (a.dump, T, len(layers), U, U + 1, np.median(gaps), np.percentile(gaps, 10), np.percentile(gaps, 90)))
    # sanity: top-6 po ocenke == fakticheskij vybor
    ok = 0; tot = 0
    for il in layers:
        top = np.argsort(-scores[il], axis=1)[:, :U]
        S = d['S'][:, il]
        for j in range(U):
            ok += (top == S[:, j][:, None]).any(1).sum(); tot += len(S)
    print('SANITY: fakticheskij top-%d vosstanovlen po ocenke na %.2f%% (dolzhno ~100)' % (U, 100 * ok / tot))
    print('\n%-14s %-8s %10s %10s %10s' % ('preset', 'L', 'smenilos%', 'pokryto%', 'vne_pres/tok'))
    for nm, kept in presets:
        masks = {}
        for il in layers:
            m = np.ones(E, bool); m[kept[il]] = False; masks[il] = m   # True = vne preseta
        for lam in lams:
            changed = 0; covered = 0; tot = 0; out_per_tok = 0
            for il in layers:
                sc = scores[il]
                base = np.argsort(-sc, axis=1)[:, :U]
                pen = sc - lam * masks[il][None, :]
                new = np.argsort(-pen, axis=1)[:, :U]
                bs = np.sort(base, axis=1); ns = np.sort(new, axis=1)
                # skolko vyborov tokena smenilos: |base \ new|
                for t in range(T):
                    diff = np.setdiff1d(bs[t], ns[t], assume_unique=True).size
                    changed += diff
                    outp = masks[il][ns[t]].sum()
                    out_per_tok += outp
                    covered += U - outp
                    tot += U
            print('%-14s %-8g %9.2f%% %9.1f%% %10.2f' % (nm, lam, 100 * changed / tot, 100 * covered / tot, out_per_tok / T))
    print('\nCHTO NE IZMERENO: rasprostranenie izmenjonnogo vybora na sledujushchie sloi/tokeny (x v dampe ot L=0),\n'
          '  kachestvo teksta, tok/s - eto tolko dvizhok (sweep --route-penalty).')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('build'); p.add_argument('--dump', action='append', required=True); p.add_argument('--k', type=int, default=64)
    p.add_argument('--out', required=True); p.add_argument('--name', default=None); p.add_argument('--hash', type=int, default=None); p.set_defaults(fn=cmd_build)
    p = sp.add_parser('curve'); p.add_argument('--dump', action='append', required=True); p.add_argument('--name', default=None)
    p.add_argument('--ks', default=None); p.add_argument('--gib', type=float, default=0.0)
    p.add_argument('--bytes-per-expert', type=float, default=7.2 * 1048576); p.set_defaults(fn=cmd_curve)
    p = sp.add_parser('overlap'); p.add_argument('--preset', action='append', required=True); p.add_argument('--dump', action='append', default=[]); p.set_defaults(fn=cmd_overlap)
    p = sp.add_parser('penalty'); p.add_argument('--dump', required=True); p.add_argument('--routers', default=None)
    p.add_argument('--preset', action='append', required=True); p.add_argument('--lams', default='0,0.05,0.1,0.25,0.5,1,2,1e9'); p.set_defaults(fn=cmd_penalty)
    a = ap.parse_args(); a.fn(a)


if __name__ == '__main__':
    main()
