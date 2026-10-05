#!/bin/bash
OUT=D:/MemeX/results/predres; B=C:/Users/User11/Desktop/MemeX/bench; LOG=$OUT/pipeline.log
PS='powershell -NoProfile -ExecutionPolicy Bypass -File'
echo "##### TRAIN+AB+REGRESS $(date +%H:%M:%S)" >> $LOG
if [ ! -f $OUT/ds4_pred.bin ]; then
  echo "--- train $(date +%H:%M:%S)" >> $LOG;   $PS $B/with_lock.ps1 -Who predres-train -Script $B/predres_train.sh -TimeoutMin 600 >> $LOG 2>&1
fi
echo "--- ab_pred $(date +%H:%M:%S)" >> $LOG; $PS $B/with_lock.ps1 -Who predres-ab-pred -Script $B/predres_ab_pred.sh -TimeoutMin 600 >> $LOG 2>&1
echo "--- regress $(date +%H:%M:%S)" >> $LOG
pwsh -NoProfile -ExecutionPolicy Bypass -File $B/regress_tokens.ps1 -Exe D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt/bin/Release/llama-memex-fwd.exe -TimeoutMin 600 >> $LOG 2>&1
echo "##### TRAIN+AB+REGRESS DONE $(date +%H:%M:%S)" >> $LOG
