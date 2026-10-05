#!/bin/bash
# SVIP "domennyj preset x shtraf po mestu" na deepseek4 (SSD-kopija C:), CPU-only rezhim (GPU otkljuchena).
# Kazhdaja tochka: odin i tot zhe promt (kod, NE iz obuchajushchih dampov), greedy dekod, stor s auto-C
# (maks rezidentnyh pod svobodnuju OZU minus RESERVE). Metriki iz loga: popadanija, promahi/token,
# tok/s, tekst vyvoda (sravnivaetsja s tochkoj L=0). Zapuskat cherez bench/with_lock.ps1.
#   PRESET=fajl.bin LAMS="0 0.05 0.15 0.5" LOFF="0" RESERVE=3000 NTOK=1024 NGEN=96 bash predres_sweep.sh
BIN='D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt/bin/Release/llama-memex-fwd.exe'
DS='C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf'
OUT=D:/MemeX/results/predres
PROMPT=${PROMPT:-D:/MemeX/src/ik_llama.cpp/ggml/src/ggml-quants.c}
NTOK=${NTOK:-1024}; NGEN=${NGEN:-96}; RESERVE=${RESERVE:-3000}
LAMS=${LAMS:-"0 0.05 0.15 0.5"}; LOFF=${LOFF:-0}
BASE="-t 8 -c $((NTOK+NGEN+64)) --no-repack --no-ref --expert-store-auto --expert-store-reserve $RESERVE --expert-store-decay 0.9 --expert-store-miss-batch --prefetch-hash"
export LLAMA_MMAP_PREFETCH=0
LOG=$OUT/sweep.log
run() {  # name extra-flags
  local name=$1; shift
  if [ -f $OUT/sweep_$name.log ] && tr -d '\000' < $OUT/sweep_$name.log | grep -aq "скорость генерации"; then
    echo "=== $name: uzhe izmereno - propusk $(date +%H:%M:%S) ===" >> $LOG; return; fi
  echo "=== $name: $* $(date +%H:%M:%S) ===" >> $LOG
  "$BIN" -m "$DS" -f "$PROMPT" --tokens $NTOK --gen $NGEN $BASE "$@" > $OUT/sweep_$name.log 2>&1
  echo "exit $?" >> $LOG
  tr -d '\000' < $OUT/sweep_$name.log | grep -aE 'raschjot:|PRESET:|SHTRAF PO MESTU|popadanij|sinhronnyj promah v srednem|PAKETNOE|скорость генерации|OTKAZ|ошибка|error' | head -14 >> $LOG
  tr -d '\000' < $OUT/sweep_$name.log | grep -aE '^наш   :' | head -1 | cut -c1-400 >> $LOG
  echo "=== $name DONE $(date +%H:%M:%S) ===" >> $LOG
}
echo "##### SWEEP start $(date +%H:%M:%S): preset=$PRESET lams=[$LAMS] loff=$LOFF reserve=$RESERVE prompt=$PROMPT tokens=$NTOK gen=$NGEN" >> $LOG
run base_nopreset
if [ -n "$PRESET" ]; then
  for L in $LAMS; do
    if [ "$LOFF" != "0" ] && [ "$L" != "0" ]; then
      run "preset_l${L}_off${LOFF}" --preset "$PRESET" --route-penalty-ssd $L --route-penalty-off $LOFF
    else
      run "preset_l${L}" --preset "$PRESET" --route-penalty-ssd $L
    fi
  done
fi
echo "##### SWEEP done $(date +%H:%M:%S)" >> $LOG
