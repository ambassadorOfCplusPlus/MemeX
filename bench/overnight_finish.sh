#!/usr/bin/env bash
# OVERNIGHT: dozhdatsja konca deepseek4 -> zamerit fit-modeli v PIKOVYH konfigah ->
# tablica -> uspit PK. Dedlajny v EPOCH ot starta (bez perehoda cherez polnoch). Avtonomno.
BIN='/d/MemeX/src/ik_llama.cpp/build-bt2022/bin/Release/llama-memex-fwd.exe'
PROM='D:/MemeX/results/prompt_2000.txt'
TBL='C:/Users/User11/Desktop/MemeX/bench/OVERNIGHT_TABLE_2026-09-08.log'
NOSLEEP='C:/Users/User11/Desktop/MemeX/bench/_no_sleep'
TMP='C:/Users/User11/.claude/jobs/a547d6bd/tmp'
START=$(date +%s)
DL_WAIT=$((START + 6*3600))       # do ~03:30 zhdjom deepseek, potom bez fit-zamerov k snu
DL_MEASURE=$((START + 7*3600))    # posle ~04:30 novyj zamer ne nachinaem
ts(){ date '+%H:%M:%S'; }
say(){ echo "[$(ts)] $*" >> "$TBL"; }

echo "=== OVERNIGHT FINISH start $(date '+%H:%M %d-%m') (START epoch $START) ===" > "$TBL"

# --- 1. Zhdjom konca deepseek4 (no ne dolshe DL_WAIT) ---
say "zhdu zavershenija deepseek4 (warm-build)..."
while tasklist 2>/dev/null | grep -qi 'llama-memex-fwd.exe'; do
  [ $(date +%s) -ge $DL_WAIT ] && { say "6ch ozhidanija - deepseek eshchjo idjot, k snu bez fit-zamerov"; break; }
  sleep 60
done
if ! tasklist 2>/dev/null | grep -qi 'llama-memex-fwd.exe'; then
  say "deepseek4 zavershilsja $(ts). Rezultat:"
  grep -aiE 'STATIC_AB our|popadanij|promah|nash *:|Paris|warm|DONE|dolja fazy' 'C:/Users/User11/Desktop/MemeX/bench/DS4_FULLWARM_2026-09-08.log' 2>/dev/null | tail -14 >> "$TBL"
fi

# --- 2. Zamer: progrev(vybros) + do 2 zamerov, luchshij. Gard po vremeni (epoch). ---
measure(){
  local label="$1"; local model="$2"; shift 2; local flags="$@"
  [ $(date +%s) -ge $DL_MEASURE ] && { say "  dedlajn - propusk $label"; return; }
  say "----- $label :: $(basename $model) :: [$flags]"
  if [ ! -f "$model" ]; then say "  NET MODELI - propusk"; return; fi
  local best=""
  for i in 0 1 2; do
    [ $(date +%s) -ge $DL_MEASURE ] && break
    local gen=192; [ $i -eq 0 ] && gen=24
    timeout 1200 "$BIN" -m "$model" -f "$PROM" --tokens 512 --gen $gen -t 8 $flags > "$TMP/_on_${label}.log" 2>&1
    local tok=$(tr -d '\000' < "$TMP/_on_${label}.log" | grep -aE '^STATIC_AB ' | head -1 | sed -nE 's/.*our_tok_s ([0-9.]+).*/\1/p')
    local err=$(tr -d '\000' < "$TMP/_on_${label}.log" | grep -aiE 'Failed to alloc|OTKAZ|too large|not supported|abort|bad_alloc' | head -1)
    if [ $i -eq 0 ]; then say "  progrev: ${tok:-FAIL} tok/s (vybros) ${err:+ERR:$err}"; else
      say "  rep $i: ${tok:-FAIL} tok/s ${err:+ERR:$err}"; [ -n "$tok" ] && best="$best $tok"
    fi
  done
  if [ -n "$best" ]; then say "  >>> ITOG $label: $(echo $best | tr ' ' '\n' | sort -rn | head -1) tok/s (iz [$best])"
  else say "  >>> ITOG $label: NET DANNYH"; fi
}

say ""
say "### ZAMERY FIT-MODELEJ (pikovye konfigi) ###"
measure qwen3moe_peak 'D:/Qwen3-Coder-30B-A3B-mx1.gguf' --no-repack --no-ref --gpu-static-layers --gpu-experts --resident 0 --resident-period 32
measure gptoss_head 'D:/gpt-oss-20b.gguf' --no-repack --gpu-static
measure gemma4_peak 'D:/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf' --no-repack --no-ref --gpu-static --gpu-static-dense --gpu-static-layers
measure phi3_peak 'D:/phi3mini-q4.gguf' --repack-only=all
measure gptoss_base 'D:/gpt-oss-20b.gguf' --no-repack

say ""
say "=== OVERNIGHT FINISH done $(ts) ==="

# --- 3. Son PK ---
if [ -f "$NOSLEEP" ]; then
  say "SON OTMENJON (_no_sleep) - PK ostajotsja vkljuchjon"
else
  say "usyplju PK cherez 60 sek (sozdaj bench/_no_sleep chtoby otmenit)..."
  sleep 60
  if [ -f "$NOSLEEP" ]; then say "otmena v poslednij moment"; else
    say "SON $(ts)."
    taskkill //F //IM llama-memex-fwd.exe 2>/dev/null
    sleep 3
    powershell -NoProfile -Command "rundll32.exe powrprof.dll,SetSuspendState 0,1,0" 2>/dev/null
  fi
fi
