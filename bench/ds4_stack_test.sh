#!/bin/bash
# Stack test: --gpu-static-attn 18 (statika na karte) + --expert-store <C> (rezidentnye eksperty
# v OZU, osvobozhdennoj perenosom statiki na kartu). Beat 1.41 tok/s (chistyj --gpu-static-attn 18,
# mmap) ili net - eksperty vsjo ravno idut s SSD, tak chto rezidentnost dolzhna pomoch tolko esli
# hватает mesta na zametnuju dolju 256/sloj.
set -u
EXE="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt/bin/Release/llama-memex-fwd.exe"
MODEL="C:/DeepSeek-V4-Flash/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf"
PROMPT="D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/prompt_france.txt"
OUT="C:/Users/User11/Desktop/MemeX/bench/DS4_STACK_2026-09-11.log"

echo "=== stack test start $(date '+%H:%M:%S') ===" > "$OUT"

run() {
  local tag="$1"; shift
  echo "--- $tag $(date '+%H:%M:%S') ---" >> "$OUT"
  "$EXE" -m "$MODEL" -f "$PROMPT" --gen 48 -t 8 --no-ref "$@" >> "$OUT" 2>&1
  echo "" >> "$OUT"
}

# --no-repack: bez nego repack-only=experts po umolchaniju perepakovyvaet pochti vsjo IQ2/IQ3
# soderzhimoe fajla, dvizhok reshaet, chto mmap bolshe ne imeet smysla, otkljuchaet ego i pytaetsja
# derzhat ~90 GB v privatnoj OZU - garantirovannyj OOM na 32 GB. Vse predыdushchie uspeshnye zamery
# (DS4_GPUSTATIC_ATTN, DS4_ATTN_SWEEP) eto izbegali; etot progon povtorjaet to zhe uslovie javno.
run "baseline gpu-static-attn 18, mmap (no store)" --gpu-static --gpu-static-attn 18 --no-repack

run "stack: attn18 + expert-store 48"  --gpu-static --gpu-static-attn 18 --no-repack --expert-store 48
run "stack: attn18 + expert-store 96"  --gpu-static --gpu-static-attn 18 --no-repack --expert-store 96
run "stack: attn18 + expert-store-auto" --gpu-static --gpu-static-attn 18 --no-repack --expert-store-auto

echo "=== stack test done $(date '+%H:%M:%S') ===" >> "$OUT"
