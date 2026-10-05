#!/bin/bash
# Orkestrator (detached, sam BEZ zamka): zhdjot sborku build8 -> sbor dampov -> analiz -> sweep -> regressija.
# Kazhdaja faza berjot mashinnyj zamok cherez with_lock.ps1 / regress_tokens.ps1 sami.
OUT=D:/MemeX/results/predres; B=C:/Users/User11/Desktop/MemeX/bench
PS='powershell -NoProfile -ExecutionPolicy Bypass -File'
WL() { $PS $B/with_lock.ps1 -Who "$1" -Script "$2" -TimeoutMin 240; }
LOG=$OUT/pipeline.log
echo "##### PIPELINE $(date +%H:%M:%S)" >> $LOG
EXE='D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt/bin/Release/llama-memex-fwd.exe'
ensure_exe() {  # exe dolzhen ZAPUSKATSJA (DLL rjadom propadali - 0xC0000135); inache peresborka pod zamkom
  "$EXE" --help > /dev/null 2>&1 && return 0
  echo "exe ne zapuskaetsja ($?) - peresborka $(date +%H:%M:%S)" >> $LOG
  $PS $B/build_wt_predres.ps1 -LockMin 60 > $OUT/build_auto.log 2>&1
  grep -aE "^\[" $OUT/build_auto.log >> $LOG
  "$EXE" --help > /dev/null 2>&1 || { echo "exe vsjo eshchjo ne zapuskaetsja - STOP" >> $LOG; exit 2; }
}
ensure_exe
[ -n "$SKIP_COLLECT" ] || { echo "--- collect $(date +%H:%M:%S)" >> $LOG;  WL predres-collect $B/predres_collect.sh >> $LOG 2>&1; }
[ -n "$SKIP_COLLECT" ] || { ensure_exe; echo "--- analyze $(date +%H:%M:%S)" >> $LOG;  WL predres-analyze $B/predres_analyze.sh >> $LOG 2>&1; }
ensure_exe; echo "--- sweep $(date +%H:%M:%S)" >> $LOG
export PRESET=$OUT/preset_prose.bin LAMS="0 0.02 0.05 0.1 0.3" LOFF=0 RESERVE=10000 NTOK=64 NGEN=128 PROMPT=$OUT/prompt_prose_short.txt
WL predres-sweep $B/predres_sweep.sh >> $LOG 2>&1
echo "--- regress $(date +%H:%M:%S)" >> $LOG
$PS $B/regress_tokens.ps1 -Exe D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt/bin/Release/llama-memex-fwd.exe >> $LOG 2>&1
echo "--- train $(date +%H:%M:%S)" >> $LOG; WL predres-train $B/predres_train.sh >> $LOG 2>&1
echo "##### PIPELINE DONE $(date +%H:%M:%S)" >> $LOG
