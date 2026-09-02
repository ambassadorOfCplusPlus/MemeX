# Skolko stoit prochitat ODNOGO eksperta s diska, kogda model ne vlezaet v OZU.
#
# ZACHEM. Dlja modelej, kotorye vlezajut, kurs izvesten: 1 punkt popadanij = 0,368 ms/token, i
# vsjo upiraetsja v polosu OZU (24,8 GB/s, izmereno). Dlja modeli, kotoraja NE vlezaet, chast
# ekspertov kazhdyj token chitaetsja s diska, i togda kurs sovsem drugoj - a bez nego nelzja ni
# sprojektirovat predskazatel ekspertov, ni skazat, na skolko tokenov vperjod nado smotret.
#
# CHTO MERITSJA. Sluchajnye chtenija bloka razmerom v odnogo eksperta iz BOLSHOGO fajla. Fajl
# dolzhen byt zametno bolshe OZU, inache izmerjaetsja stranichnyj kesh, a ne disk: 41,5 GB pri
# 32 GB pamjati - eto chestno, a 29,3 GB - uzhe net.
#
# Blok schitaetsja iz geometrii modeli, a ne beryotsja krugloj cifroj:
#   qwen3next: n_embd 2048, ekspert ffn 512, tri matricy (up, gate, down) na eksperta
#   3 * 2048 * 512 = 3,146 M parametrov; pri IQ4_XS okolo 4,25 bita = ~1,67 MB na eksperta
#
# CHESTNOST. Pervyj prohod po fajlu progrevaet kesh, poetomu smeshchenija berutsja sluchajno po
# vsemu fajlu i pervye neskolko chtenij vybrasyvajutsja. Esli izmerennaja polosa vyjdet blizkoj
# k polose OZU - eto priznak, chto merilsja kesh, i skript govorit ob etom sam.
import os, sys, time, random

PATH = sys.argv[1] if len(sys.argv) > 1 else r'D:\Qwen3-Coder-Next-UD-IQ4_XS.gguf'
BLOCK = int(sys.argv[2]) if len(sys.argv) > 2 else 1670000   # bajt na eksperta
N = int(sys.argv[3]) if len(sys.argv) > 3 else 200

size = os.path.getsize(PATH)
print('fajl %s, %.1f GB, blok %.2f MB, chtenij %d' % (os.path.basename(PATH), size / 1e9,
                                                      BLOCK / 1e6, N))
random.seed(20260902)
f = open(PATH, 'rb', buffering=0)
times = []
for i in range(N + 8):
    off = random.randrange(0, max(1, size - BLOCK))
    t0 = time.perf_counter()
    f.seek(off)
    got = f.read(BLOCK)
    dt = time.perf_counter() - t0
    if len(got) != BLOCK:
        print('nedochitano na smeshchenii', off, '- NE IZMERENO')
        raise SystemExit(2)
    if i >= 8:                      # pervye vosem vybrosheny: progrev
        times.append(dt)
f.close()

times.sort()
n = len(times)
med = times[n // 2]
p90 = times[int(n * 0.9)]
mn = times[0]
mx = times[-1]
gbs = BLOCK / med / 1e9
print('  mediana %7.3f ms   p90 %7.3f ms   min %7.3f ms   max %7.3f ms' %
      (med * 1e3, p90 * 1e3, mn * 1e3, mx * 1e3))
print('  polosa po mediane: %.2f GB/s' % gbs)
if gbs > 8.0:
    print('  <<< VNIMANIE: %.1f GB/s slishkom bystro dlja diska - merilsja stranichnyj kesh, '
          'a ne disk. Voz'"'"'mite fajl bolshe OZU.' % gbs)
else:
    # Skolko eto na token, esli dolja promahov mimo OZU raznaja.
    print('  cena na token pri 320 ekspertah na token (40 sloev x top-8):')
    for miss in (0.05, 0.10, 0.20, 0.35, 0.50):
        print('     promahov %3.0f%%  ->  %6.1f ms na token' % (miss * 100,
                                                                320 * miss * med * 1e3))
