#!/bin/sh
# Our own loop against the fork's, same model file, same conditions.
#
# This is the number the whole "grow our engine instead of porting into the fork" decision
# rests on, and it was never measured - memex-fwd was only ever checked for correctness
# (24 of 24 tokens identical), never for speed. Correct and fast are different claims.
#
# Expect our side to be behind at first, for three known reasons rather than mysterious ones:
# we do not repack weights at load time the way -rtr does (that alone was +17% on the fork),
# we rebuild the decode graph every step because the cache write offset is baked in at build
# time, and there is no warmup pass. All three are fixable; the point of measuring is to learn
# what they actually cost before deciding to pay for them.
set -u
BIN=/d/MemeX/src/ik_llama.cpp/build/bin/Release
M=D:\Qwen3-Coder-30B-A3B-mx3.gguf
[ -f /d/Qwen3-Coder-30B-A3B-mx3.gguf ] || M=D:\Qwen3-Coder-30B-A3B-mx1.gguf
P="Write a Python function that merges two sorted lists."

printf 'модель: %s\n\n' "$M"

printf 'форк, llama-cli:\n'
"$BIN/llama-cli.exe" -m "$M" -p "$P" -n 64 -c 2048 -t 4 -ngl 0 -fa off -rtr \
    --seed 1 --no-display-prompt 2>&1 | grep -a "^main:  *eval time"
printf 'форк, без -rtr (честная база для нас, мы тоже не перепаковываем):\n'
"$BIN/llama-cli.exe" -m "$M" -p "$P" -n 64 -c 2048 -t 4 -ngl 0 -fa off \
    --seed 1 --no-display-prompt 2>&1 | grep -a "^main:  *eval time"

printf '\nнаш цикл, memex-fwd:\n'
"$BIN/memex-fwd.exe" -m "$M" -p "$P" --gen 64 -t 4 2>&1 | tail -20
