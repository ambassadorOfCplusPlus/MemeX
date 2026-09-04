#!/usr/bin/env python3
"""Zatravka schjotchikov chastoty dlja rezidentnogo hranilishcha (--expert-prior).

ZACHEM ONA NUZHNA, i eto ne dogadka, a izmerenie. Chastota po istorii dokumenta upiraetsja v
plato 98,6% popadanij pri LJUBOM bjudzhete (bench/route_lab.py, bench/first_seen.py): ostatok -
PERVYE POJAVLENIJA eksperta v dokumente, do kotoryh istorii dokumenta po opredeleniju net.
Chastoty s CHUZHIH tekstov eto plato probivajut:

    bjudzhet   tolko dokument      + zatravka
    256        98,39 / 89,30       98,79 / 93,06
    320        98,56 / 89,57       99,24 / 95,32
    410        98,61 / 89,63       99,67 / 98,01     (srednee / holodnyj start)

Vhod - nashi zhe sledy MEMEX_EXPERT_TRACE:

    zagolovok int32[4] = [n_tokens, n_layer, n_expert_used, n_expert]
    telo      n_tokens * n_layer * n_expert_used int32, poriadok [token][sloj][mesto]

Vyhod - fajl, kotoryj chitaet ExpertStore::load_prior:

    zagolovok int32[4] = [0x45585052 ('EXPR'), n_layer, n_expert, 1]
    telo      f32 [n_layer][n_expert]

MASHTAB VYHODA NAROSCHNO NAZVAN V TOKENAH. Schjotchik dokumenta pribavljaet rovno 1,0 za
obrashchenie, tak chto zatravka, normirovannaja na `--tokens-equiv T`, vesit stolko zhe,
skolko T tokenov dokumenta. Bez etoj normirovki ves zatravki zavisel by ot dliny
kalibrovochnyh sledov, i "zatravka iz trjoh tekstov" znachila by raznoe pri raznyh tekstah.
Kazhdyj sled vhodit s ODINAKOVYM vesom, a ne proporcionalno svoej dline - inache samyj dlinnyj
tekst korpusa zadaval by nabor v odinochku.

CHEGO ETOT SKRIPT NE DELAET: on ne smotrit na to, na chjom snjaty sledy. Esli podat sjuda sled
TOGO ZHE dokumenta, na kotorom potom merjaetsja popadanie, poluchitsja orakul, a ne zatravka -
i cifry budut krasivye i nedejstvitelnye. Imena vhodnyh fajlov pechatajutsja imenno poetomu.
"""

import argparse
import struct
import sys
from pathlib import Path

import numpy as np

MAGIC = 0x45585052  # 'EXPR' little-endian


def read_trace(path):
    raw = np.fromfile(path, dtype=np.int32)
    if raw.size < 4:
        raise SystemExit(f"{path}: fajl koroche zagolovka")
    n_tok, n_layer, n_used, n_expert = (int(x) for x in raw[:4])
    want = n_tok * n_layer * n_used
    body = raw[4:]
    if body.size != want:
        raise SystemExit(
            f"{path}: telo {body.size} chisel, a zagolovok obeshchaet {want} "
            f"({n_tok} x {n_layer} x {n_used}) - sled NEPOLON, ne beru"
        )
    ids = body.reshape(n_tok, n_layer, n_used)
    return ids, n_tok, n_layer, n_used, n_expert


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("traces", nargs="+", help="fajly sledov MEMEX_EXPERT_TRACE")
    ap.add_argument("-o", "--out", required=True, help="kuda pisat zatravku")
    ap.add_argument(
        "--tokens-equiv",
        type=float,
        default=300.0,
        help="skolkim tokenam dokumenta ravna zatravka po vesu (po umolchaniju 300)",
    )
    a = ap.parse_args()

    counts = None
    n_layer = n_expert = n_used = None
    per_trace = []
    for p in a.traces:
        ids, n_tok, nl, nu, ne = read_trace(p)
        if counts is None:
            n_layer, n_expert, n_used = nl, ne, nu
            counts = np.zeros((nl, ne), dtype=np.float64)
        elif (nl, ne, nu) != (n_layer, n_expert, n_used):
            raise SystemExit(
                f"{p}: geometrija {nl}x{ne} top-{nu} ne sovpadaet s {n_layer}x{n_expert} "
                f"top-{n_used} - eto sled DRUGOJ modeli"
            )
        c = np.zeros((n_layer, n_expert), dtype=np.float64)
        for il in range(n_layer):
            flat = ids[:, il, :].reshape(-1)
            flat = flat[(flat >= 0) & (flat < n_expert)]
            c[il] += np.bincount(flat, minlength=n_expert)
        # Ravnyj ves kazhdomu sledu: delim na ego sobstvennoe chislo obrashchenij na sloj.
        tot = c.sum(axis=1, keepdims=True)
        tot[tot == 0] = 1.0
        counts += c / tot
        per_trace.append((p, n_tok, int((c > 0).sum(axis=1).mean())))

    # Normirovka v "tokeny dokumenta": summa po sloju = tokens_equiv * n_used.
    scale = a.tokens_equiv * n_used / len(a.traces)
    prior = (counts * scale).astype(np.float32)

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("wb") as f:
        f.write(struct.pack("<4i", MAGIC, n_layer, n_expert, 1))
        prior.tofile(f)

    print(f"zatravka zapisana: {out} ({out.stat().st_size} bajt)")
    print(f"  geometrija: {n_layer} sloev x {n_expert} ekspertov, top-{n_used}")
    print(f"  ves zatravki: {a.tokens_equiv:.0f} tokenov dokumenta na sloj")
    print("  vhodnye sledy (kazhdyj s ODINAKOVYM vesom):")
    for p, n_tok, distinct in per_trace:
        print(f"    {p}: {n_tok} tokenov, razlichnyh ekspertov na sloj v srednem {distinct}")
    nz = (prior > 0).sum(axis=1)
    print(
        f"  nenulevyh schjotchikov na sloj: srednee {nz.mean():.0f}, "
        f"ot {nz.min()} do {nz.max()} iz {n_expert}"
    )
    print(
        "  CHEGO NE PROVERENO: chto eti sledy snjaty NE na tom tekste, na kotorom potom "
        "merjaetsja popadanie - imena vyshe dlja etogo i napechatany"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
