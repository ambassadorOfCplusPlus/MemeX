# POTOLOK DESHJOVYH PREDSKAZATELEJ EKSPERTOV, po sledu marshrutizacii.
#
# ZACHEM. Krivaja pokrytija otvechaet "skolko ekspertov derzhat, chtoby popadat". Zdes drugoj
# vopros: KAKIE imenno derzhat, esli ih vybiraet ne chastota, a predskazatel. Vsjo schitaetsja
# oflajn po sledu, poetomu sravnenie desjatka sposobov stoit sekundy i ne trebuet ni peresborki,
# ni zanjatija mashiny.
#
# CHESTNOST. Skript sam pechataet, chego on NE merit:
#   - sled snjat na NASHEM promte, a ne na sobstvennom prodolzhenii modeli (populjacii raznye);
#   - stoimost samogo predskazatelja ne uchitivaetsja voobshche - eto POTOLOK, a ne vygoda;
#   - kazhdyj sposob smotrit tolko na to, chto uzhe proshlo: nikakogo zagljadyvanija vperjod.
import array, collections, io, os, sys

path = sys.argv[1] if len(sys.argv) > 1 else r'D:\MemeX\results\route_trace.bin'
if not os.path.exists(path):
    print('sleda net: %s' % path)
    print('  snjat ego: MEMEX_EXPERT_TRACE=<fajl> vmeste s MEMEX_EXPERT_COVERAGE=1')
    raise SystemExit(2)

raw = io.open(path, 'rb').read()
hdr = array.array('i'); hdr.frombytes(raw[:16])
n_tok, n_layer, n_used, n_exp = hdr[0], hdr[1], hdr[2], hdr[3]
body = array.array('i'); body.frombytes(raw[16:16 + 4 * n_tok * n_layer * n_used])
print('sled: %d tokenov x %d sloev x %d mest, iz %d ekspertov' % (n_tok, n_layer, n_used, n_exp))
if len(body) != n_tok * n_layer * n_used:
    print('  dlina tela ne shoditsja s zagolovkom - SLED NEDEJSTVITELEN')
    raise SystemExit(2)

def sel(t, il):
    o = (t * n_layer + il) * n_used
    return [e for e in body[o:o + n_used] if 0 <= e < n_exp]

# Kurs obmena, izmerennyj: ekspert pri IQ3_XXS ~1,03 MiB; sluchajnoe chtenie s SSD 3,616 ms,
# s zhjostkogo diska 23,287 ms. Odin promah = odno takoe chtenie.
MISS_SSD_MS = 3.616
PER_TOKEN_READS = n_layer * n_used

BUDGETS = [32, 64, 96, 128, 192, 256]

def run(name, make_pred):
    # make_pred(hist_per_layer) -> mnozhestvo id, kotorye budut REZIDENTNY na sledujushchij token
    out = {}
    for B in BUDGETS:
        hit = tot = 0
        state = [make_pred(B) for _ in range(n_layer)]
        for t in range(n_tok):
            for il in range(n_layer):
                cur = sel(t, il)
                if not cur: continue
                if t > 0:
                    keep = state[il].predict()
                    for e in cur:
                        tot += 1
                        if e in keep: hit += 1
                state[il].observe(cur)
        out[B] = (hit / tot * 100.0) if tot else float('nan')
    return name, out

class Freq:
    "chastota po vsej istorii - to zhe, chto merila krivaja pokrytija"
    def __init__(s, B): s.B=B; s.c=collections.Counter()
    def observe(s, cur): s.c.update(cur)
    def predict(s): return set(e for e,_ in s.c.most_common(s.B))

class Persist:
    "tolko to, chto vybral predydushchij token; ostatok bjudzheta - chastotoj"
    def __init__(s, B): s.B=B; s.last=[]; s.c=collections.Counter()
    def observe(s, cur): s.last=list(cur); s.c.update(cur)
    def predict(s):
        k=set(s.last)
        for e,_ in s.c.most_common():
            if len(k)>=s.B: break
            k.add(e)
        return k

class Window:
    "objedinenie poslednih W tokenov, ostatok - chastotoj"
    W = 16
    def __init__(s, B): s.B=B; s.q=collections.deque(maxlen=s.W); s.c=collections.Counter()
    def observe(s, cur): s.q.append(list(cur)); s.c.update(cur)
    def predict(s):
        k=set()
        for step in reversed(s.q):
            for e in step:
                if len(k)<s.B: k.add(e)
        for e,_ in s.c.most_common():
            if len(k)>=s.B: break
            k.add(e)
        return k

class Recent:
    "chistyj LRU po obrashchenijam"
    def __init__(s, B): s.B=B; s.o=collections.OrderedDict()
    def observe(s, cur):
        for e in cur:
            s.o.pop(e, None); s.o[e]=1
        while len(s.o)>s.B: s.o.popitem(last=False)
    def predict(s): return set(s.o.keys())

rows = [run('chastota (baza)', Freq), run('uporstvo+chastota', Persist),
        run('okno 16+chastota', Window), run('LRU', Recent)]

print('\nDOLJA POPADANIJ na SLEDUJUSHCHIJ token, %% (chem bolshe, tem menshe chtenij s diska)')
print('  sposob              ' + ''.join('%8d' % B for B in BUDGETS))
best = {B: max(r[1][B] for r in rows) for B in BUDGETS}
for name, out in rows:
    line = '  %-20s' % name
    for B in BUDGETS:
        mark = '*' if abs(out[B]-best[B]) < 1e-9 else ' '
        line += '%7.2f%s' % (out[B], mark)
    print(line)

base = dict(rows)['chastota (baza)']
print('\nCHTO DAJOT LUCHSHIJ SPOSOB PROTIV CHASTOTY (v mс na token, chtenija s SSD)')
for B in BUDGETS:
    d = best[B] - base[B]
    ms = d / 100.0 * PER_TOKEN_READS * MISS_SSD_MS
    print('  bjudzhet %3d iz %d: +%5.2f punkta  ->  %7.1f ms na token' % (B, n_exp, d, ms))

print('\nCHEGO ZDES NE IZMERENO:')
print('  - sled snjat na NASHEM promte, a ne na sobstvennom prodolzhenii modeli (rule 87)')
print('  - cena samogo predskazatelja NE uchtena: eto potolok sposoba, a ne vygoda dvizhka')
print('  - promah schitaetsja po cene SSD (3,616 ms izmereno); na zhjostkom diske ona 23,287')
print('  - ni odin sposob zdes ne obuchaemyj: eto BAZA, kotoruju obuchaemyj objazan pobit')
