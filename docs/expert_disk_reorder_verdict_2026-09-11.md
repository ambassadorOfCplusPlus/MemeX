# Disk-reorder ekspertov DeepSeek-V4-Flash: Faza 1 verdikt (NE delat Fazu 2)

Worktree: `D:/MemeX/src/ik_llama.cpp/.claude/wt_reorder` (branch `agent/expert-disk-reorder`,
baseline commit `e8e6c4f0` = snapshok tekushchego working-tree memex-fwd s ds4-opt +
phi3-full-gpu, chtoby ne poterjat). Kod NE menjalsja - analiz tolko chtenie GGUF-zagolovkov,
calib-dampa i probы diska.

## 1. Tekushchij on-disk layout (podtverzhdeno cherez ruchnoj GGUF-parser)

Kazhdyj sloj hranit **odin sliyanyj tenzor na proekciju** na vse 256 ekspertov:
`blk.N.ffn_{gate,up,down}_exps.weight` s formoj `[.., .., 256]`. Vnutri odnoj proekcii
eksperty UZHE smezhny (blok eksperta e = baza + e*slab_size, slab_size = razmer/256).
NO tri proekcii odnogo sloja lezhat v SOVSEM raznyh mestah fajla:

```
blk.0.ffn_down_exps   @ 708 090 176      (3 211 264 B/ekspert, IQ3_XXS)
blk.0.ffn_gate_exps   @ 1 537 055 040    (+829 MB ot down)
blk.0.ffn_up_exps     @ 2 101 686 592    (+565 MB ot gate)
```
7.19 MiB/ekspert summarno (3.06 MiB down + 2.06+2.06 MiB gate/up) - sovpadaet s
zajavlennoj cifroj v zadanii i s docs/deepseek4_ssd_ceiling_2026-09-09.md.

`ExpertStore::read_misses` (expert_store.cpp:387-449) uzhe chitaet vse `3*n_used` kuska
odnim paketom OVERLAPPED ReadFile (n_used=6 => QD=18 v poljote), t.e. dvizhok uzhe
ne serializuet promahi.

## 2. Co-aktivacija (real'nyj damp `bench/ds4_calib_k2.bin`, 200 tokenov x 40 sloёv, 8000 zapisej)

Schitali, skolko SMEZHNYH probegov (runs) trebuet top-6 vybor odnogo sloja/tokena v
TEKUSHCHEM ID-porjadke vs posle zhadnoj co-aktivacionnoj klasterizacii (per-layer greedy
chain po chastote sovmestnyh vyborov):

```
sredn. runs/(sloj,token), iz do 6 vozmozhnyh:
  TEKUSHCHIJ ID-porjadok:        5.88   (98% - eto uzhe otdel'nyj probeg, praktichno NOL' lokalnosti)
  posle co-akt. klasterizacii:   3.94   => 1.49x menshe probegov na ODNU proekciju
  + sliyanie gate+up+down v odin blok na eksperta: eshchjo 3x (segodnja kazhdyj promah -
    eto VSEGDA 3 razdelennyh chtenija, dazhe dlja 1 eksperta)
  ITOGO potencial: do ~4.5x menshe SEEKOV (ne bajt) pri fuzii+pereukladke
```

## 3. NO: real'nyj disk NE shtrafuet sluchajnye chtenija na etom razmere - poэtomu vyigrysh
##    ot p.2 pochti nulevoj

Motivirujushchaja cifra v zadanii (0.167 GB/s / 43.9 ms na sluchajnoe 7 MiB chtenie protiv
0.358 GB/s posledovatel'no, t.e. ~2.1x shtraf) **NE podtverdilas'** - proverili TREMJA
nezavisimymi sposobami:

| metod | razmer | QD | rezul'tat |
|---|---|---|---|
| Python `os.read` (bufer. kesh OS) | 7 MiB | 1..32 | 361-439 MB/s |
| Win32 `FILE_FLAG_NO_BUFFERING` (TOCHNO put' dvizhka, kesh OS obojdjon) | 7 MiB | 1..32 | 356-454 MB/s, 14-20 ms/chtenie |
| `dd iflag=direct`, vnutrennee vremja peredachi (bez shell-obvjazki) | 7 MiB | 1 (posledovatel'no) | 414-461 MB/s, 16-17 ms |

Vse tri shodjatsja k **~0.36-0.46 GB/s dlja SLUCHAJNOGO 7 MiB chtenija** - t.e. STATISTIChESKI
NE OTLIchAETSJA ot izmerennoj posledovatel'noj polosy 0.358 GB/s (SSD_PROBE_2026-09-10.log,
odin bolshoj holodnyj dd na 38 GiB). **Net shtrafa za sluchajnyj dostup na etom razmere bloka
na etom nakopitele.**

Nezavisimoe podtverzhdenie: `docs/deepseek4_ssd_ceiling_2026-09-09.md:33` (napisano DO
etogo zadanija, drugim agentom) uzhe schital "promah = 7.19 MiB / 0.46 GB/s = 15.6 ms" -
TOChNO tot zhe porjadok cifr, chto my izmerili sejchas nezavisimo.

**Otkuda vzjalas' cifra 43.9 ms**: vosproizvel original'nuju metodiku (bash-cikl `dd
iflag=direct` s $RANDOM na kazhduju iteraciju) - poluchil wall-clock 58-69 ms/iteracija,
no VNUTRENNEE vremja peredachi (iz stderr samogo dd) - vsego 16-17 ms. Raznica (~42-53 ms) -
eto NAKLADNYE RASHODY na spawn processa/shell v bash-cikle, NE vremja diska. Original'nyj
`SSD_PROBE_2026-09-10.log` skoree vsego izmeril tu zhe artefaktnuju velichinu (ego stroka
"RANDOM: ... bytes in  s =  GB/s" slomana - peremennye vremeni/GB-s ne podstavilis',
t.e. real'noe chislo iz nego voobshche ne izvlekalos').

## VERDIKT: Faza 2 (offline repack + --expert-reorder) NE delat'

Prichina: net real'nogo fizicheskogo shtrafa za sluchajnyj dostup na razmere bloka
2-7 MiB na etom SSD => perekladka ekspertov (hot' po co-aktivacii, hot' prostoe sliyanie
gate+up+down v odin blok) snizit KOLIchESTVO seekov v 3-4.5 raza, no seek na etom
nakopitele stoit ~nol' sverh peredachi bajt - t.e. ozhidaemoe uskorenie na REAL'NOM
zheleze ~1.0x (v predelah shuma izmerenij), NE 2-4x. Riskovat' celostnostju 77-90 GB
modeli (kopirovanie/repack, tesnoe mesto na C:) radi izmerimo nulevogo effekta - ne
opravdano.

Chto MOZHET eshchjo dat' real'nyj effekt (ne eto zadanie, no zametka na budushchee):
- esli v BOJU (pod nagruzkoj GPU-compute + parallel'nye agenty na toj zhe mashine) real'naja
  dostignutaja polosa nizhe izmerennoj zdes' (kontencija, ne lokal'nost') - eto drugoj
  vopros (planirovanie I/O pod nagruzkoj), ne reshaetsja pereukladkoj bajt na diske.
- hash-sloi (40-42) marshrutizirujut deterministicheski po token_id - dlja nih FIZIchESKI
  vozmozhna ideal'naja posledovatel'naja pereukladka, no bez shtrafa za random eto NE dast
  izmerimogo uskorenija segodnja.

## Artefakty
- `bench/QD_PROBE_2026-09-10.log`, `bench/QD_PROBE_NOCACHE_2026-09-10.log`,
  `bench/DD_RECHECK_2026-09-10.log` - probы diska (etot progon).
- Analiz layout/co-aktivacii - odnorazovye skripty v scratchpad sessii (ne v repo,
  legko vosproizvodimy iz opisanija vyshe pri neobhodimosti).
