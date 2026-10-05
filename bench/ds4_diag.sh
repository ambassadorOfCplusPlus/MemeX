#!/bin/bash
# Diagnostic: DS4_STACK_2026-09-11.log showed degenerate output ("is<bos><bos>...") in ALL
# arms, including the baseline --gpu-static-attn 18 (which previously gave coherent "is Paris.
# The capital of England is London..." at --gen 16). Two things changed vs that known-good run:
# --no-repack (added) and --gen 48 (vs 16). Isolate which one (or the combination) causes it.
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_DIAG_2026-09-11.log"

echo "=== diag start $(date '+%H:%M:%S') ===" > "$OUT"
run() {
  local tag="$1"; shift
  echo "--- $tag $(date '+%H:%M:%S') ---" >> "$OUT"
  "$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref "$@" >> "$OUT" 2>&1
  echo "" >> "$OUT"
}

# A: attn18, repack DEFAULT (as in the known-good run), gen 16 - reproduce the good baseline.
run "A: attn18 default-repack gen16" --gpu-static --gpu-static-attn 18 --gen 16
# B: attn18, repack DEFAULT, gen 48 - isolate gen-length effect alone.
run "B: attn18 default-repack gen48" --gpu-static --gpu-static-attn 18 --gen 48
# C: attn18, --no-repack, gen 16 - isolate no-repack effect alone.
run "C: attn18 no-repack gen16" --gpu-static --gpu-static-attn 18 --no-repack --gen 16
# D: NO gpu-static-attn at all (pure CPU), no-repack, gen 48 - is it gpu-static-attn's fault at all?
run "D: CPU-only no-repack gen48" --no-repack --gen 48

echo "=== diag done $(date '+%H:%M:%S') ===" >> "$OUT"
