# Sverka "do/posle" po logam --decode-check i --gen 8.
#
# Zachem otdelnyj skript, a ne diff. Vo-pervyh, v logah est vremena i adresa, kotorye
# menjajutsja ot progona k progonu, i pobajtovyj diff na nih shumit. Vo-vtoryh, dvizhok
# pechataet kirillicu, a konsol etoj mashiny nesjot cp866: v log popadaet ustojchivo
# isporchennyj tekst. Poetomu kazhdaja stroka snachala ochishchaetsja do ASCII, i sverjajutsja
# rovno te kanaly, kotorye OBJAZANY sovpast, esli graf tot zhe: nomer shaga, pozicija, L2
# protiv etalona, identifikator tokena i ego tekst.
#
# Vyvod tolko ASCII - po toj zhe prichine.
import io
import re
import sys

# "  0 (   32): L2  5.7092%   3950 ' token'" posle ochistki ot kirillicy
STEP = re.compile(r"^\s*(\d+)\s*\(\s*(\d+)\):\s*L2\s*([0-9.]+)%\s*(\d+)\s*'(.*?)'")
# Stroka generacii/skorosti: chislo pered "tok/s"
TPS = re.compile(r'our_tok_s\s+([0-9.]+)')


def ascii_only(line):
    return ''.join(c if ord(c) < 128 else ' ' for c in line)


def read(path):
    try:
        return io.open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return ''


def steps(text):
    out = []
    for line in text.split('\n'):
        m = STEP.match(ascii_only(line))
        if m:
            out.append((int(m.group(1)), int(m.group(2)), m.group(3),
                        int(m.group(4)), m.group(5)))
    return out


def gen_ids(text):
    # Glavnaja stroka progona --gen: identifikatory sgenerirovannyh tokenov. Ona i est
    # otvet modeli; vsjo ostalnoe v logfajle - diagnostika.
    for line in text.split('\n'):
        a = ascii_only(line).strip()
        m = re.match(r'^id:\s*((?:\d+\s+)*\d+)$', a)
        if m:
            return [int(x) for x in m.group(1).split()]
    return None


def body(text):
    # Vsjo, chto ne soderzhit chisel vremeni, razmerov i adresov. Ostajotsja to, chto ot
    # progona k progonu objazano byt odinakovym.
    #
    # NE 's\b' i ne golyj 'ms': pervoe lovit ljuboe slovo na -s i vybrasyvaet imenno stroku
    # so SGENERIROVANNYM TEKSTOM ('determines', 'experts'), vtoroe - ljuboe slovo s 'ms'
    # vnutri. Edinicy nazyvajutsja celymi slovami.
    drop = re.compile(r'(\bms\b|\bsek\b|tok/s|GB/s|MB/s|0x[0-9a-f]{4,}|[0-9]+[.,][0-9]+)')
    keep = []
    for line in text.split('\n'):
        a = ascii_only(line).rstrip()
        if not a.strip():
            continue
        if a.lstrip().startswith('#'):
            continue
        if drop.search(a):
            continue
        keep.append(' '.join(a.split()))
    return keep


def cmp_check(tag, a_path, b_path):
    a, b = read(a_path), read(b_path)
    if not a or not b:
        print('%-10s NET LOGA (%s / %s)' % (tag, bool(a), bool(b)))
        return False
    sa, sb = steps(a), steps(b)
    ok = True
    if not sa or not sb:
        print('%-10s shagov ne najdeno (do %d, posle %d) - NE SVERENO' % (tag, len(sa), len(sb)))
        return False
    if len(sa) != len(sb):
        print('%-10s RAZNOE CHISLO SHAGOV: do %d, posle %d' % (tag, len(sa), len(sb)))
        ok = False
    for i in range(min(len(sa), len(sb))):
        if sa[i] != sb[i]:
            print('%-10s shag %d RASHODITSJA:' % (tag, sa[i][0]))
            print('   do    : poz %d L2 %s tok %d %r' % sa[i][1:])
            print('   posle : poz %d L2 %s tok %d %r' % sb[i][1:])
            ok = False
    if ok:
        print('%-10s %d shagov: pozicii, L2 i tokeny sovpadajut do znaka; posl. tok %d %r'
              % (tag, len(sa), sa[-1][3], sa[-1][4]))
    return ok


def cmp_gen(tag, a_path, b_path):
    a, b = read(a_path), read(b_path)
    if not a or not b:
        print('%-10s NET LOGA GENERACII' % tag)
        return False
    ba, bb = body(a), body(b)
    ta = TPS.findall(ascii_only(a))
    tb = TPS.findall(ascii_only(b))
    ia, ib = gen_ids(a), gen_ids(b)
    ok = True
    if ia is None or ib is None:
        print('%-10s stroka id sgenerirovannyh tokenov NE NAJDENA (do %s, posle %s) - '
              'NE SVERENO' % (tag, ia is not None, ib is not None))
        ok = False
    elif ia != ib:
        print('%-10s TOKENY GENERACII RASHODJATSJA:\n   do    : %s\n   posle : %s'
              % (tag, ia, ib))
        ok = False
    else:
        print('%-10s tokeny generacii sovpadajut: %s' % (tag, ia))
    if ba == bb:
        print('%-10s generacija: %d strok bez chisel vremeni sovpadajut; tok/s do %s, posle %s'
              % (tag, len(ba), ta, tb))
        return ok
    print('%-10s GENERACIJA RASHODITSJA:' % tag)
    n = 0
    for i in range(max(len(ba), len(bb))):
        x = ba[i] if i < len(ba) else '<net stroki>'
        y = bb[i] if i < len(bb) else '<net stroki>'
        if x != y:
            n += 1
            if n <= 30:
                print('   do    : %s' % x)
                print('   posle : %s' % y)
    print('   vsego rashozhdenij strok: %d; tok/s do %s, posle %s' % (n, ta, tb))
    return False


if __name__ == '__main__':
    keys = sys.argv[1:] or ['mx1', 'gemma4', 'next']
    base = 'D:\\MemeX\\results\\step2_'
    allok = True
    for k in keys:
        allok &= cmp_check(k, base + 'before_' + k + '.log', base + 'after_' + k + '.log')
        allok &= cmp_gen(k + '/gen', base + 'before_' + k + '_gen.log',
                         base + 'after_' + k + '_gen.log')
    print('ITOG: %s' % ('vsjo sovpalo' if allok else 'EST RASHOZHDENIJA - CHITAT VYSHE'))
