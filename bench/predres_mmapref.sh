#!/bin/bash
# Etalon skorosti BEZ stora (plain mmap) na tom zhe promte/dline, chto i svip - pod zamkom (with_lock).
BIN='D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt/bin/Release/llama-memex-fwd.exe'
DS='C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf'
OUT=D:/MemeX/results/predres; export LLAMA_MMAP_PREFETCH=0
echo "=== mmap_ref: bez stora, tot zhe promt $(date +%H:%M:%S) ===" >> $OUT/sweep.log
"$BIN" -m "$DS" -f $OUT/prompt_prose_short.txt --tokens 64 --gen 128 -t 8 -c 256 --no-repack --no-ref --mmap-touch-hash > $OUT/sweep_mmap_ref.log 2>&1
echo "exit $?" >> $OUT/sweep.log
tr -d '\000' < $OUT/sweep_mmap_ref.log | grep -aE 'скорость генерации|MMAP-TOUCH|OTKAZ' | head -3 >> $OUT/sweep.log
tr -d '\000' < $OUT/sweep_mmap_ref.log | grep -aE '^наш   :' | head -1 | cut -c1-400 >> $OUT/sweep.log
echo "=== mmap_ref DONE $(date +%H:%M:%S) ===" >> $OUT/sweep.log
