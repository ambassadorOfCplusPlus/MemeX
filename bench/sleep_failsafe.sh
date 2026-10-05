#!/usr/bin/env bash
# JESTKIJ FAILSAFE SNA: usypit PK v ~04:45 (esli net _no_sleep i PK eshchjo ne spit),
# na sluchaj esli aktivnaja orkestracija sessii zavisla/umerla. Epoch-dedlajn ot starta.
# Osnovnoj put sna - aktivnaja sessija posle vsej raboty; eto tolko strahovka.
NOSLEEP='C:/Users/User11/Desktop/MemeX/bench/_no_sleep'
LOG='C:/Users/User11/Desktop/MemeX/bench/_sleep_failsafe.log'
START=$(date +%s)
DEADLINE=$((START + 7*3600 + 1800))   # ~04:45 pri starte ~21:45
echo "FAILSAFE start $(date '+%H:%M %d-%m'), dedlajn $(date -d @$DEADLINE '+%H:%M' 2>/dev/null || echo +7.5h)" > "$LOG"
while [ $(date +%s) -lt $DEADLINE ]; do
  sleep 120
  [ -f "$NOSLEEP" ] && { echo "otmena: _no_sleep $(date '+%H:%M')" >> "$LOG"; exit 0; }
done
if [ -f "$NOSLEEP" ]; then echo "dedlajn, no _no_sleep - ne splju" >> "$LOG"; exit 0; fi
echo "FAILSAFE DEDLAJN $(date '+%H:%M:%S') - usyplju PK" >> "$LOG"
taskkill //F //IM llama-memex-fwd.exe 2>/dev/null
sleep 3
powershell -NoProfile -Command "rundll32.exe powrprof.dll,SetSuspendState 0,1,0" 2>/dev/null
