#!/bin/bash
# Bisect which of the three --gpu-static-attn crossings (qkv=1, oproj=2, shexp=4) produces
# wrong output. N=16, --no-repack, gen16, same config as the reproducibly-broken runs.
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_BISECT_2026-09-11.log"

echo "=== bisect start $(date '+%H:%M:%S') ===" > "$OUT"
run() {
  local tag="$1"; local mask="$2"; shift 2
  echo "--- $tag (MEMEX_DSV4_MASK=$mask) $(date '+%H:%M:%S') ---" >> "$OUT"
  MEMEX_DSV4_MASK="$mask" "$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref --no-repack --gen 16 \
    --gpu-static --gpu-static-attn 16 >> "$OUT" 2>&1
  echo "" >> "$OUT"
}

run "qkv only"           1
run "oproj only"         2
run "shexp only"         4
run "qkv+oproj (no shexp)" 3
run "all three (reconfirm broken)" 7

echo "=== bisect done $(date '+%H:%M:%S') ===" >> "$OUT"
