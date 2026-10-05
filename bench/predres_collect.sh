#!/bin/bash
# Sbor obuchajushchih dannyh predskazatelja (MEMEX_ROUTE_DUMP) na deepseek4 (SSD-kopija na C:).
# Tri progona, plain mmap (bez stora): prefill realnogo teksta kuskami po 1024 (kazhdyj kusok
# chitaet vseh ekspertov odin raz => deshevle dekoda) + dekod 160 tokenov sobstvennogo teksta.
# Zapuskat cherez bench/with_lock.ps1 (zamok berjot obertka).
BIN='D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt/bin/Release/llama-memex-fwd.exe'
DS='C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf'
OUT=D:/MemeX/results/predres
export LLAMA_MMAP_PREFETCH=0
run() {  # name file tokens gen
  local name=$1 file=$2 ntok=$3 ngen=$4
  if [ -f $OUT/dump_$name.bin ] && [ $(stat -c %s $OUT/dump_$name.bin) -gt 200000000 ]; then
    echo "=== $name: damp uzhe est ($(stat -c %s $OUT/dump_$name.bin) bajt) - propusk $(date +%H:%M:%S) ===" >> $OUT/collect.log; return; fi
  echo "=== $name: $file tokens $ntok gen $ngen $(date +%H:%M:%S) ===" >> $OUT/collect.log
  MEMEX_ROUTE_DUMP=$OUT/dump_$name.bin "$BIN" -m "$DS" -f "$file" --tokens $ntok --gen $ngen -t 8 -c $((ntok+ngen+64)) \
    --prefill-chunk 1024 --no-repack --no-ref > $OUT/run_$name.log 2>&1
  tr -d '\000' < $OUT/run_$name.log | grep -aE 'ROUTE|prefill kuskami|наш   :|STATIC_AB|OTKAZ|ошибка|error|токенов в промпте' | head -20 >> $OUT/collect.log
  ls -la $OUT/dump_$name.bin >> $OUT/collect.log
  echo "=== $name DONE $(date +%H:%M:%S) ===" >> $OUT/collect.log
}
if [ ! -f $OUT/dump_smoke.bin ]; then
# SMOKE: 16 tokenov + 2 gen s dampom, proverka formata MXRD pythonom - inache ne zhech 1h15 vpustuju
echo "=== SMOKE $(date +%H:%M:%S) ===" >> $OUT/collect.log
MEMEX_ROUTE_DUMP=$OUT/dump_smoke.bin "$BIN" -m "$DS" -p "The quick brown fox jumps over the lazy dog near the river bank." --tokens 16 --gen 2 -t 8 -c 128 --no-repack --no-ref > $OUT/run_smoke.log 2>&1
echo "smoke exit $?" >> $OUT/collect.log
tr -d '\000' < $OUT/run_smoke.log | grep -aE 'ROUTE|наш   :|OTKAZ|ошибка|error' | head -8 >> $OUT/collect.log
if ! D:/Python311/python.exe -c "import sys; sys.path.insert(0,'C:/Users/User11/Desktop/MemeX/bench'); from pred_train import load_dump; d=load_dump('$OUT/dump_smoke.bin'); print('smoke dump OK: X',d['X'].shape,'S',d['S'].shape,'hashl',d['hashl'])" >> $OUT/collect.log 2>&1; then
  echo "=== SMOKE FAILED, STOP $(date +%H:%M:%S) ===" >> $OUT/collect.log; exit 5
fi
fi
run wp    D:/MemeX/results/prompt_18k.txt        4096 160
run docs  D:/MemeX/results/long_prompt_varied.txt 4096 160
# kod (domen "coding" dlja presetov): ishodnik ggml.c
run code  D:/MemeX/src/ik_llama.cpp/ggml/src/ggml.c 2048 120
# dekod-kontrol: sobstvennyj tekst modeli na raznorodnom promte (kak prezhnjaja kalibrovka)
if [ -f $OUT/dump_gen.bin ] && [ $(stat -c %s $OUT/dump_gen.bin) -gt 50000000 ]; then echo "=== gen: damp est - propusk ===" >> $OUT/collect.log; else
echo "=== gen: $(date +%H:%M:%S) ===" >> $OUT/collect.log
MEMEX_ROUTE_DUMP=$OUT/dump_gen.bin "$BIN" -m "$DS" -p "Explain quantum computing, then write Python code for a web server, then describe the history of Rome, then solve a math problem: what is the integral of x squared." --tokens 40 --gen 220 -t 8 -c 320 --no-repack --no-ref > $OUT/run_gen.log 2>&1
tr -d '\000' < $OUT/run_gen.log | grep -aE 'ROUTE|наш   :|STATIC_AB|OTKAZ' | head -10 >> $OUT/collect.log
ls -la $OUT/dump_gen.bin >> $OUT/collect.log
fi
echo "=== ALL DONE $(date +%H:%M:%S) ===" >> $OUT/collect.log
