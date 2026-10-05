#!/bin/bash
# Bisect the --gpu-static-attn coherence bug found at N=18 (arm C of ds4_diag.sh): N=16 was
# coherent, N=18 degenerated to a repeated <bos> token. N=18 = 4 full groups of 4 layers +
# one tail group of 2 (padded past the BAR ceiling); N=16 = 4 clean full groups, no tail.
# Test N=17 (odd, forces a tail group of 1) and N=20 (a clean 5th full group, no tail) to see
# whether the bug tracks "any N past 16" or specifically "a short/padded tail group".
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_DIAG2_2026-09-11.log"

echo "=== diag2 start $(date '+%H:%M:%S') ===" > "$OUT"
run() {
  local tag="$1"; shift
  echo "--- $tag $(date '+%H:%M:%S') ---" >> "$OUT"
  "$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref --no-repack --gen 16 "$@" >> "$OUT" 2>&1
  echo "" >> "$OUT"
}

run "N=17 (tail group of 1)"   --gpu-static --gpu-static-attn 17
run "N=20 (clean 5 groups)"    --gpu-static --gpu-static-attn 20
run "N=16 reconfirm (clean 4 groups)" --gpu-static --gpu-static-attn 16

echo "=== diag2 done $(date '+%H:%M:%S') ===" >> "$OUT"
