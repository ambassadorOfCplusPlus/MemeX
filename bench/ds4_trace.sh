#!/bin/bash
# DIAGNOSTIC (MEMEX_DSV4_TRACE): per-crossing input/output checksums + NaN/zero counts + immediate
# [DSV4_FAIL] prints. Distinguishes "exception -> zeros -> BOS" from "silent corrupt readback", and
# shows whether an EARLIER crossing's own output changes when a LATER crossing is also on.
# N=16 (clean groups), gen 8, no expert store - same config as ds4_bisect.sh.
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_TRACE_2026-09-11.log"

echo "=== trace start $(date '+%H:%M:%S') ===" > "$OUT"
run() {
  local tag="$1"; local mask="$2"; shift 2
  echo "" >> "$OUT"
  echo "############ $tag (MEMEX_DSV4_MASK=$mask) $(date '+%H:%M:%S') ############" >> "$OUT"
  MEMEX_DSV4_TRACE=1 MEMEX_DSV4_MASK="$mask" "$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref \
    --no-repack --gen 8 --gpu-static --gpu-static-attn 16 >> "$OUT" 2>&1
}

run "qkv only"              1
run "oproj only"            2
run "shexp only"            4
run "qkv+oproj (broken?)"   3
run "all three"             7

echo "" >> "$OUT"
echo "=== trace done $(date '+%H:%M:%S') ===" >> "$OUT"
