#!/bin/bash
# Posle svipa: etalon mmap -> obuchenie predskazatelja -> regressija (pwsh: skript ispolzuet ternarnik PS7).
OUT=D:/MemeX/results/predres; B=C:/Users/User11/Desktop/MemeX/bench; LOG=$OUT/pipeline.log
PS='powershell -NoProfile -ExecutionPolicy Bypass -File'
WL() { $PS $B/with_lock.ps1 -Who "$1" -Script "$2" -TimeoutMin 480; }
echo "##### FOLLOWUP $(date +%H:%M:%S)" >> $LOG
echo "--- mmap_ref $(date +%H:%M:%S)" >> $LOG; WL predres-mmapref $B/predres_mmapref.sh >> $LOG 2>&1
echo "--- train $(date +%H:%M:%S)" >> $LOG;    WL predres-train $B/predres_train.sh >> $LOG 2>&1
echo "--- regress $(date +%H:%M:%S)" >> $LOG
pwsh -NoProfile -ExecutionPolicy Bypass -File $B/regress_tokens.ps1 -Exe D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt/bin/Release/llama-memex-fwd.exe -TimeoutMin 480 >> $LOG 2>&1
echo "##### FOLLOWUP DONE $(date +%H:%M:%S)" >> $LOG
