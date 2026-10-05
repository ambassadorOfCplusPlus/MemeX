#!/bin/bash
# Decisive check: N=16 just degenerated to repeated <bos>, identically to the earlier coherent
# run (same flags, same exe, no rebuild). Rule out "my new dsv4 code specifically" vs "GPU/driver
# state degraded under repeated use" by testing the PRE-EXISTING head-only --gpu-static path
# (no --gpu-static-attn at all - untouched code from before this session's GPU work) and a pure
# CPU run, both right now, same process/driver state as the just-failed N=16 run.
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_DIAG3_2026-09-11.log"

echo "=== diag3 start $(date '+%H:%M:%S') ===" > "$OUT"
run() {
  local tag="$1"; shift
  echo "--- $tag $(date '+%H:%M:%S') ---" >> "$OUT"
  "$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref --no-repack --gen 16 "$@" >> "$OUT" 2>&1
  echo "" >> "$OUT"
}

run "head-only gpu-static (no attn, pre-existing path)" --gpu-static
run "pure CPU, no GPU at all"
run "N=16 re-reconfirm (third try)" --gpu-static --gpu-static-attn 16

echo "=== diag3 done $(date '+%H:%M:%S') ===" >> "$OUT"
