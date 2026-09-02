# Skolko stoit sluchajnoe chtenie bloka razmerom v eksperta MIMO stranichnogo kesha.
#
# ZACHEM IMENNO TAK. Prostoe chtenie cherez open() na fajle men'she OZU merit kesh, a ne disk:
# na C: svobodno 20,5 GB pri 32 GB pamjati, tak chto fajl, kotoryj tuda vlezet, budet
# celikom v keshe posle pervogo prohoda. Poetomu fajl otkryvaetsja s FILE_FLAG_NO_BUFFERING -
# togda kesh ne uchastvuet voobshche, i razmer fajla perestajot imet znachenie.
#
# Cena flaga: smeshchenie i dlina objazany byt kratny razmeru sektora (4096). Blok eksperta
# 1,67 MB okrugljaetsja do 408 * 4096 = 1 671 168 bajt.
#
# CHESTNOST. Skript sam govorit, esli polosa vyshla vyshe 8 GB/s - takoe znachit, chto kesh
# vsjo-taki uchastvoval i izmerenie nedejstvitelno.
import ctypes, ctypes.wintypes as wt
import os, sys, time, random

GENERIC_READ = 0x80000000
FILE_SHARE_READ = 0x00000001
OPEN_EXISTING = 3
FILE_FLAG_NO_BUFFERING = 0x20000000
FILE_FLAG_RANDOM_ACCESS = 0x10000000
SECTOR = 4096
BLOCK = 408 * SECTOR            # 1 671 168 bajt - blok eksperta, vyrovnennyj po sektoru

path = sys.argv[1] if len(sys.argv) > 1 else r'C:\MemeX_ssd_probe.bin'
size_gb = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
N = int(sys.argv[3]) if len(sys.argv) > 3 else 200

# Fajl sozdajotsja, esli ego net. S NO_BUFFERING razmer ne vazhen dlja chestnosti, no on dolzhen
# byt zametno bolshe bloka, chtoby smeshchenija byli raznymi.
need = int(size_gb * (1 << 30))
if not os.path.exists(path) or os.path.getsize(path) < need:
    print('sozdaju probnyj fajl %.1f GB: %s' % (size_gb, path))
    chunk = os.urandom(1 << 20)
    with open(path, 'wb') as f:
        written = 0
        while written < need:
            f.write(chunk)
            written += len(chunk)
    print('  sozdan')

total = os.path.getsize(path)
k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.CreateFileW.restype = wt.HANDLE
h = k32.CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, None, OPEN_EXISTING,
                    FILE_FLAG_NO_BUFFERING | FILE_FLAG_RANDOM_ACCESS, None)
if h == wt.HANDLE(-1).value:
    print('CreateFileW ne udalsja, kod', ctypes.get_last_error(), '- NE IZMERENO')
    raise SystemExit(2)

buf = ctypes.create_string_buffer(BLOCK + SECTOR)
# Bufer tozhe dolzhen byt vyrovnen po sektoru pri NO_BUFFERING.
addr = ctypes.addressof(buf)
off = (SECTOR - (addr % SECTOR)) % SECTOR
view = (ctypes.c_char * BLOCK).from_buffer(buf, off)

random.seed(20260902)
got = wt.DWORD(0)
times = []
nblocks = (total - BLOCK) // SECTOR
for i in range(N + 8):
    pos = random.randrange(0, nblocks) * SECTOR
    lo = pos & 0xFFFFFFFF
    hi = pos >> 32
    t0 = time.perf_counter()
    k32.SetFilePointer(h, ctypes.c_long(lo), ctypes.byref(ctypes.c_long(hi)), 0)
    ok = k32.ReadFile(h, view, BLOCK, ctypes.byref(got), None)
    dt = time.perf_counter() - t0
    if not ok or got.value != BLOCK:
        print('ReadFile vernul %s, prochitano %d iz %d - NE IZMERENO'
              % (bool(ok), got.value, BLOCK))
        k32.CloseHandle(h)
        raise SystemExit(2)
    if i >= 8:
        times.append(dt)
k32.CloseHandle(h)

times.sort()
n = len(times)
med = times[n // 2]
gbs = BLOCK / med / 1e9
print('fajl %.1f GB, blok %.2f MB, chtenij %d, MIMO kesha (NO_BUFFERING)'
      % (total / 1e9, BLOCK / 1e6, n))
print('  mediana %7.3f ms   p90 %7.3f ms   min %7.3f ms   max %7.3f ms'
      % (med * 1e3, times[int(n * 0.9)] * 1e3, times[0] * 1e3, times[-1] * 1e3))
print('  polosa po mediane: %.2f GB/s' % gbs)
if gbs > 8.0:
    print('  <<< VNIMANIE: %.1f GB/s slishkom bystro - kesh vsjo-taki uchastvoval, '
          'izmerenie NEDEJSTVITELNO' % gbs)
else:
    print('  cena na token pri 480 ekspertah (48 sloev x top-10) i raznoj dole promahov:')
    for miss in (0.004, 0.015, 0.05, 0.10):
        print('     promahov %5.1f%%  ->  %6.1f ms na token' % (miss * 100, 480 * miss * med * 1e3))
