#!/bin/bash
# Retry of ds4_bisect.sh: the first attempt ran into a GPU crash mid-sweep (all runs showed
# "VRAM: NE UZNANO" - Vulkan not detected - because the device had already failed before this
# script started, not because of the bisection code). GPU is back to CM_PROB_NONE now. Keep
# this run SHORT (3 tests only) to limit stress on a card with a crash history today.
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_BISECT2_2026-09-11.log"

echo "=== bisect2 start $(date '+%H:%M:%S') ===" > "$OUT"
run() {
  local tag="$1"; local mask="$2"; shift 2
  echo "--- $tag (MEMEX_DSV4_MASK=$mask) $(date '+%H:%M:%S') ---" >> "$OUT"
  MEMEX_DSV4_MASK="$mask" "$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref --no-repack --gen 12 \
    --gpu-static --gpu-static-attn 16 >> "$OUT" 2>&1
  echo "" >> "$OUT"
}

run "qkv only"   1
run "oproj only" 2
run "shexp only" 4

echo "=== bisect2 done $(date '+%H:%M:%S') ===" >> "$OUT"
