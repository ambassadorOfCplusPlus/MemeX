#!/bin/bash
# Oflajn-analiz posle sbora dampov (bench/predres_collect.sh): chastotnye krivye domenov, presety,
# peresechenie domenov, shkala shtrafa. Chitaet ~1.5 GB dampy - zapuskat cherez with_lock.
PY=D:/Python311/python.exe
B=C:/Users/User11/Desktop/MemeX/bench
OUT=D:/MemeX/results/predres
LOG=$OUT/analyze.log
GIB=${GIB:-17}
{
echo "##### ANALYZE $(date +%H:%M:%S) bjudzhet ${GIB} GiB"
for d in code wp docs gen; do
  [ -f $OUT/dump_$d.bin ] || { echo "net dampa $d"; continue; }
  echo "--- krivaja: $d"
  $PY $B/pred_presets.py curve --dump $OUT/dump_$d.bin --name $d --gib $GIB --ks 8,16,24,32,48,56,64,80,96,128,160,192,224,256
done
echo "--- krivaja: prose = wp+docs"
$PY $B/pred_presets.py curve --dump $OUT/dump_wp.bin --dump $OUT/dump_docs.bin --name prose --gib $GIB --ks 8,16,32,48,56,64,96,128,192,256
echo "--- presety (polnyj rang, bez ni razu ne vybrannyh)"
$PY $B/pred_presets.py build --dump $OUT/dump_code.bin --k 256 --out $OUT/preset_code.bin --name code
$PY $B/pred_presets.py build --dump $OUT/dump_wp.bin --dump $OUT/dump_docs.bin --k 256 --out $OUT/preset_prose.bin --name prose
$PY $B/pred_presets.py build --dump $OUT/dump_code.bin --k 56 --out $OUT/preset_code_top56.bin --name code_top56
echo "--- peresechenie domenov i pokrytie chuzhogo korpusa"
$PY $B/pred_presets.py overlap --preset $OUT/preset_code.bin --preset $OUT/preset_prose.bin --dump $OUT/dump_code.bin --dump $OUT/dump_gen.bin
$PY $B/pred_presets.py overlap --preset $OUT/preset_code_top56.bin --preset $OUT/preset_prose.bin --dump $OUT/dump_code.bin --dump $OUT/dump_gen.bin
echo "--- shkala shtrafa (zazor 6-go/7-go, oflajn-sim) na dekode gen i na kode"
$PY $B/pred_presets.py penalty --dump $OUT/dump_gen.bin --preset $OUT/preset_code_top56.bin --lams 0,0.02,0.05,0.1,0.2,0.5,1,1e9
echo "##### ANALYZE DONE $(date +%H:%M:%S)"
} >> $LOG 2>&1
