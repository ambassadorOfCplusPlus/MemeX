#!/bin/bash
# FINAL verification of the --gpu-static-attn coherence fix at the target N=18, default mask (7 =
# all three crossings on the card). Success = coherent "...Paris..." + ~1.4 tok/s + a "18/43 ...
# na karte" line, all together. A CPU baseline run is included as the coherence reference.
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_VERIFY_2026-09-12.log"

echo "=== verify start $(date '+%H:%M:%S') ===" > "$OUT"

echo "" >> "$OUT"
echo "############ CPU baseline (no GPU static), gen 16 ############" >> "$OUT"
"$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref --no-repack --gen 16 >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "############ FIX: --gpu-static-attn 18 (mask default 7, all three on card), gen 16 ############" >> "$OUT"
"$EXE" -m "$MODEL" -f "$PROMPT" -t 8 --no-ref --no-repack --gen 16 --gpu-static --gpu-static-attn 18 >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "=== verify done $(date '+%H:%M:%S') ===" >> "$OUT"
