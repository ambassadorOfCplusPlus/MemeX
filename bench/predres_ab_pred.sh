#!/bin/bash
# A/B predskazatelja (MXPR) na tom zhe promte, chto svip: stor bez preseta (0.41 tok/s) vs + --expert-predictor
# (piny + async chtenija) i + lazy-refresh/victim 1. Pod zamkom (with_lock). Otvet dolzhen byt IDENTICHEN (predskazatel ne menjaet vybor).
BIN='D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt/bin/Release/llama-memex-fwd.exe'
DS='C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf'
OUT=D:/MemeX/results/predres; export LLAMA_MMAP_PREFETCH=0
PRED=$OUT/ds4_pred.bin
[ -f $PRED ] || { echo "=== ab_pred: net $PRED (obuchenie ne zavershilos) ===" >> $OUT/sweep.log; exit 1; }
BASE="-t 8 -c 256 --no-repack --no-ref --expert-store-auto --expert-store-reserve 10000 --expert-store-decay 0.9 --expert-store-miss-batch --prefetch-hash"
run() { local name=$1; shift
  echo "=== $name: $* $(date +%H:%M:%S) ===" >> $OUT/sweep.log
  "$BIN" -m "$DS" -f $OUT/prompt_prose_short.txt --tokens 64 --gen 128 $BASE "$@" > $OUT/sweep_$name.log 2>&1
  echo "exit $?" >> $OUT/sweep.log
  tr -d '\000' < $OUT/sweep_$name.log | grep -aE 'raschjot:|PREDSKAZATEL|popadanij|PREDIKTIVN|pin|predskaz|predzagruzheno|скорость генерации|OTKAZ' | head -14 | cut -c1-260 >> $OUT/sweep.log
  tr -d '\000' < $OUT/sweep_$name.log | grep -aE '^наш   :' | head -1 | cut -c1-400 >> $OUT/sweep.log
  echo "=== $name DONE $(date +%H:%M:%S) ===" >> $OUT/sweep.log; }
run pred            --expert-predictor $PRED --expert-store-spares 32
run pred_lazy_lru   --expert-predictor $PRED --expert-store-spares 32 --expert-store-lazy-refresh --expert-store-victim 1
run pred_pins_only  --expert-predictor $PRED --expert-store-spares 32 --predictor-no-issue
