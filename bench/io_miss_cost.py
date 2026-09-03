# -*- coding: utf-8 -*-
"""Skolko stoit promah eksperta na SAMOM DELE: tri kanala, kotorye do sih por ne merilis.

Izmereno ranshe (bench/ssd_raw_reads.py): odno sluchajnoe chtenie 1,67 MB mimo kesha - SSD 3,6 ms,
HDD 23,3 ms. No dvizhok promahi platit ne tak:

  1. Cherez mmap. Segodnja eksperty otobrazheny fajlom, i promah - eto NE odno chtenie, a
     lavina stranichnyh otkazov po 4 KiB (s kakim-to uprezhdeniem Windows). Skolko eto stoit na
     dele - neizvestno, i eto cena, kotoruju dvizhok platit SEJCHAS.
  2. Odin ekspert - eto TRI kuska (gate, up, down) v raznyh mestah fajla, po 0,32-0,53 MiB, a
     ne odin blok 1,67 MB. Tri chtenija pomenshe - eto tri pozicionirovanija.
  3. Glubina ocheredi. Predzagruzchik vydajot neskolko chtenij srazu; SSD pri QD 4-8 dajot
     zametno bolshe, chem pri QD 1, HDD - pochti net. Bez etoj cifry nelzja skazat, skolko
     promahov na token mozhno sprjatat za vremja scheta.

Vsjo chitaetsja s FILE_FLAG_NO_BUFFERING | FILE_FLAG_OVERLAPPED, to est mimo stranichnogo kesha,
inache na fajle menshe OZU merilsja by kesh. Dlja mmap-kanala kesh sbrosit nelzja, poetomu on
meritsja na fajle BOLSHE OZU (model 41,5 GB na D:) i na smeshchenijah, kotorye ne trogalis.

Chestnost: skript pechataet, chto NE izmereno (naprimer, esli fajl vlezaet v OZU - kanal mmap
nedejstvitelen), i otkazyvaetsja, esli polosa vyshla vyshe 8 GB/s (znachit kesh uchastvoval).

Zapusk (pod zamkom mashiny!):
  python bench/io_miss_cost.py <fajl> [--sizes 0.32,0.38,1.03] [--qd 1,2,4,8,16] [--n 64] [--mmap]
Napisano latinicej: PowerShell na etoj mashine chitaet fajly bez metki kak ANSI.
"""
import argparse, ctypes, ctypes.wintypes as wt, mmap, os, random, sys, time

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

GENERIC_READ = 0x80000000
FILE_SHARE_READ = 0x00000001
OPEN_EXISTING = 3
FILE_FLAG_NO_BUFFERING = 0x20000000
FILE_FLAG_OVERLAPPED = 0x40000000
FILE_FLAG_RANDOM_ACCESS = 0x10000000
ERROR_IO_PENDING = 997
INFINITE = 0xFFFFFFFF
SECTOR = 4096

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.CreateFileW.restype = wt.HANDLE
k32.CreateEventW.restype = wt.HANDLE
k32.ReadFile.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD, ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
k32.GetOverlappedResult.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.POINTER(wt.DWORD), wt.BOOL]
k32.WaitForMultipleObjects.argtypes = [wt.DWORD, ctypes.POINTER(wt.HANDLE), wt.BOOL, wt.DWORD]


class OVERLAPPED(ctypes.Structure):
    _fields_ = [('Internal', ctypes.c_void_p), ('InternalHigh', ctypes.c_void_p),
                ('Offset', wt.DWORD), ('OffsetHigh', wt.DWORD), ('hEvent', wt.HANDLE)]


def aligned_buffer(n):
    raw = ctypes.create_string_buffer(n + SECTOR)
    addr = ctypes.addressof(raw)
    off = (SECTOR - (addr % SECTOR)) % SECTOR
    return raw, addr + off


def open_raw(path):
    h = k32.CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, None, OPEN_EXISTING,
                        FILE_FLAG_NO_BUFFERING | FILE_FLAG_OVERLAPPED | FILE_FLAG_RANDOM_ACCESS, None)
    if h == wt.HANDLE(-1).value:
        raise SystemExit('CreateFileW ne udalsja, kod %d - NE IZMERENO' % ctypes.get_last_error())
    return h


def run_qd(h, total, block, qd, n, rnd):
    """n chtenij bloka `block` s glubinoj ocheredi qd. Vozvrashchaet (latencies, wall)."""
    bufs = [aligned_buffer(block) for _ in range(qd)]
    evs = [k32.CreateEventW(None, True, False, None) for _ in range(qd)]
    ovs = [OVERLAPPED() for _ in range(qd)]
    nblocks = (total - block) // SECTOR
    issued = 0; done = 0
    t_issue = [0.0] * qd
    lat = []
    got = wt.DWORD(0)
    inflight = [False] * qd
    t_wall0 = time.perf_counter()
    while done < n:
        for i in range(qd):
            if not inflight[i] and issued < n:
                pos = rnd.randrange(0, nblocks) * SECTOR
                ovs[i] = OVERLAPPED()
                ovs[i].Offset = pos & 0xFFFFFFFF; ovs[i].OffsetHigh = pos >> 32; ovs[i].hEvent = evs[i]
                t_issue[i] = time.perf_counter()
                ok = k32.ReadFile(h, bufs[i][1], block, None, ctypes.byref(ovs[i]))
                if not ok and ctypes.get_last_error() != ERROR_IO_PENDING:
                    raise SystemExit('ReadFile kod %d - NE IZMERENO' % ctypes.get_last_error())
                inflight[i] = True; issued += 1
        # zhdjom ljuboj iz aktivnyh
        act = [i for i in range(qd) if inflight[i]]
        arr = (wt.HANDLE * len(act))(*[evs[i] for i in act])
        r = k32.WaitForMultipleObjects(len(act), arr, False, INFINITE)
        i = act[r]
        if not k32.GetOverlappedResult(h, ctypes.byref(ovs[i]), ctypes.byref(got), True) or got.value != block:
            raise SystemExit('GetOverlappedResult: prochitano %d iz %d - NE IZMERENO' % (got.value, block))
        lat.append(time.perf_counter() - t_issue[i])
        inflight[i] = False; done += 1
    wall = time.perf_counter() - t_wall0
    for e in evs: k32.CloseHandle(e)
    return lat, wall


def run_mmap(path, total, block, n, rnd):
    """Promah cherez mmap: kosnutsja kazhdoj stranicy sluchajnogo diapazona `block`."""
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_BINARY', 0))
    mm = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)
    lat = []
    nblocks = (total - block) // SECTOR
    sink = 0
    for _ in range(n):
        pos = rnd.randrange(0, nblocks) * SECTOR
        t0 = time.perf_counter()
        for off in range(pos, pos + block, SECTOR):
            sink += mm[off]
        lat.append(time.perf_counter() - t0)
    mm.close(); os.close(fd)
    return lat, sink


def stats(lat):
    s = sorted(lat); n = len(s)
    return s[n // 2] * 1e3, s[int(n * 0.9)] * 1e3, s[0] * 1e3, s[-1] * 1e3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('--sizes', default='0.32,0.38,1.03', help='razmery kuskov, MiB')
    ap.add_argument('--qd', default='1,2,4,8,16')
    ap.add_argument('--n', type=int, default=64, help='chtenij na tochku')
    ap.add_argument('--mmap', action='store_true', help='izmerit i kanal mmap (fajl dolzhen byt bolshe OZU)')
    ap.add_argument('--seed', type=int, default=20260903)
    a = ap.parse_args()

    total = os.path.getsize(a.path)
    ram = ctypes.c_ulonglong(0)
    k32.GetPhysicallyInstalledSystemMemory(ctypes.byref(ram))
    ram_b = ram.value * 1024
    print('fajl %s: %.2f GB; OZU %.1f GB' % (a.path, total / 1e9, ram_b / 1e9))
    rnd = random.Random(a.seed)
    h = open_raw(a.path)
    sizes = [int(round(float(x) * (1 << 20) / SECTOR)) * SECTOR for x in a.sizes.split(',')]
    qds = [int(x) for x in a.qd.split(',')]

    print('\nPRJAMOE CHTENIE MIMO KESHA (NO_BUFFERING, OVERLAPPED): zaderzhka odnogo chtenija i polosa')
    print('  %-9s %-4s %9s %9s %9s %9s   %10s %12s' % ('kusok', 'QD', 'mediana', 'p90', 'min', 'max', 'MB/s', 'chtenij/s'))
    suspicious = False
    for block in sizes:
        for qd in qds:
            lat, wall = run_qd(h, total, block, qd, a.n, rnd)
            med, p90, mn, mx = stats(lat)
            mbs = block * len(lat) / wall / 1e6
            rps = len(lat) / wall
            print('  %6.2f MiB %-4d %8.3f ms %8.3f ms %8.3f ms %8.3f ms   %10.1f %12.1f'
                  % (block / (1 << 20), qd, med, p90, mn, mx, mbs, rps))
            if mbs > 8000: suspicious = True
    k32.CloseHandle(h)
    if suspicious:
        print('  <<< VNIMANIE: polosa vyshe 8 GB/s - kesh uchastvoval, izmerenie NEDEJSTVITELNO')

    if a.mmap:
        if total < ram_b * 1.1:
            print('\nKANAL mmap NE IZMEREN: fajl (%.1f GB) ne bolshe OZU (%.1f GB) - stranichnyj kesh '
                  'ne otlichit promah ot popadanija' % (total / 1e9, ram_b / 1e9))
        else:
            print('\nPROMAH CHEREZ mmap (tak platit dvizhok SEJCHAS): kosnutsja kazhdoj 4K-stranicy diapazona')
            for block in sizes:
                lat, _ = run_mmap(a.path, total, block, a.n, rnd)
                med, p90, mn, mx = stats(lat)
                print('  %6.2f MiB: mediana %8.3f ms  p90 %8.3f  min %8.3f  max %8.3f   (%d stranic)'
                      % (block / (1 << 20), med, p90, mn, mx, block // SECTOR))
    else:
        print('\nKANAL mmap ne zaproshen (--mmap) - NE IZMEREN')

    print('\nCHEGO NE IZMERENO: chtenie POD nagruzkoj scheta (CPU zanjat vsemi potokami) - eto otdelnyj zamer '
          'iz dvizhka; vlijanie fragmentacii fajla; drugie razmery sektora.')


if __name__ == '__main__':
    main()
