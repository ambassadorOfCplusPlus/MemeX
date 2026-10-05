#!/bin/bash
# Each of qkv/oproj/shexp works ALONE (bisect2: all three gave "is Paris..."). Only the full
# combination (mask=7) is broken. Test mask=3 (qkv+oproj, no shexp) to see if TWO crossings
# together is already enough to break it, or if it takes all three.
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_BISECT3_2026-09-11.log"

echo "=== bisect3 start $(date '+%H:%M:%S') ===" > "$OUT"
run() {
  local tag="$1"; local mask="$2"; shift 2
  echo "--- $tag (MEMEX_DSV4_MASK=$mask) $(date '+%H:%M:%S') ---" >> "$OUT"
  MEMEX_DSV4_MASK="$mask" "$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref --no-repack --gen 12 \
    --gpu-static --gpu-static-attn 16 >> "$OUT" 2>&1
  echo "" >> "$OUT"
}

run "qkv+oproj (no shexp)" 3

echo "=== bisect3 done $(date '+%H:%M:%S') ===" >> "$OUT"
