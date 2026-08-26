#!/bin/sh
# The whole remaining cheap list, in one pass, in order of value per minute of work.
#
# Written as one script because every step needs the processor to itself: on four cores two of
# these at once put 13% of noise into the numbers, and this project has already chased that
# noise once. Each step prints its own result and failures do not stop the rest.
#
# Order is deliberate:
#   1. requantise with an importance matrix - the gating question, because "four bits cost
#      7.9% perplexity" was measured against a base that *was* calibrated while the candidate
#      was not, and if that explains it then everything downstream replans;
#   2. a cheaper draft - best value for effort left: speculation already accepts 48% of drafts
#      but the draft eats 30% of the time, and it is 379 MB requantised in a minute;
#   3. flags nobody measured;
#   4. quantised KV at long context - most of our zoned-cache win is reachable this way,
#      without rewriting the cache;
#   5. prefill on the card - every "the card is useless" measurement was taken on decoding,
#      which is matrix-by-vector and bound by bandwidth and launch count. Prefill is
#      matrix-by-matrix and bound by arithmetic, which is the card's own ground.
set -u

BIN=/d/MemeX/src/ik_llama.cpp/build/bin/Release
VK=/d/MemeX/src/ik_llama.cpp/build-vk/bin/Release
Q6=D:\\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf
MX1=D:\\Qwen3-Coder-30B-A3B-mx1.gguf
MX3=D:\\Qwen3-Coder-30B-A3B-mx3.gguf
DRAFT=D:\\smartstock\\models\\qwen3-0.6b-q4_k_m.gguf
DRAFT3=D:\\qwen3-0.6b-iq3.gguf
IMAT=D:\\MemeX\\results\\imatrix-q3c30b.dat
TEXT=D:\\MemeX\\data\\calibration.txt
PROMPT="Write a Python function that merges two sorted lists and explain each step."

say() { printf '\n===== %s\n' "$1"; }

speed() {   # speed <label> <model> <extra args...>
    label=$1; model=$2; shift 2
    line=$("$BIN/llama-cli.exe" -m "$model" -p "$PROMPT" -n 128 -c 4096 -t 4 -ngl 0 \
           -fa off -rtr --seed 1 --no-display-prompt "$@" 2>&1 |
           grep -a "^main:        eval time" | head -1)
    printf '  %-40s %s\n' "$label" "${line:-не запустилось}"
}

ppl() {     # ppl <label> <model>
    line=$("$BIN/llama-perplexity.exe" -m "$2" -f "$TEXT" -c 512 --chunks 16 -t 4 \
           -ngl 0 -fa off -rtr 2>&1 | grep -a "Final estimate" | head -1)
    printf '  %-40s %s\n' "$1" "${line:-не посчиталось}"
}

say "1. переквантование с матрицей важности"
if [ -f "$(printf %s "$IMAT" | tr '\\' '/')" ] || true; then
    "$BIN/llama-quantize.exe" --allow-requantize --imatrix "$IMAT" \
        --custom-q 'ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq4_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks,output.weight=iq4_ks' \
        "$Q6" "$MX3" q6_k 4 > /d/MemeX/results/quant3.log 2>&1
    printf '  готово, размер: %s\n' "$(ls -l --block-size=M /d/Qwen3-Coder-30B-A3B-mx3.gguf 2>/dev/null | awk '{print $5}')"
fi
ppl "mx3 (с матрицей)" "$MX3"
speed "mx3" "$MX3"
ppl "mx1 (без матрицы, для сверки)" "$MX1"

say "2. черновик подешевле"
"$BIN/llama-quantize.exe" --allow-requantize "$DRAFT" "$DRAFT3" iq3_s 4 \
    > /d/MemeX/results/quant_draft.log 2>&1
printf '  черновик IQ3: %s МБ (был 379)\n' \
    "$(ls -l --block-size=M /d/qwen3-0.6b-iq3.gguf 2>/dev/null | awk '{print $5}')"
speed "mx3, без спекуляции" "$MX3"
speed "mx3 + черновик Q4, n_max=3" "$MX3" -md "$DRAFT" --spec-type draft:n_max=3
speed "mx3 + черновик IQ3, n_max=3" "$MX3" -md "$DRAFT3" --spec-type draft:n_max=3
speed "mx3 + черновик IQ3, n_max=4" "$MX3" -md "$DRAFT3" --spec-type draft:n_max=4

say "3. флаги, которые не мерили"
speed "без mmap" "$MX3" --no-mmap
speed "с mlock" "$MX3" --mlock

say "4. квантованный кэш на длинном контексте"
# Quantised values need flash attention in this fork - without it the run died with a stack
# overrun earlier. Both arms are measured with -fa on so the comparison is about the cache.
for cfg in "f16:-fa on" "q8_0:-fa on -ctk q8_0 -ctv q8_0" "q8_0+адамар:-fa on -ctk q8_0 -ctv q8_0 -khad"; do
    lbl=${cfg%%:*}; args=${cfg#*:}
    line=$("$BIN/llama-cli.exe" -m "$MX3" -f /d/MemeX/results/prompt_code.txt -n 64 \
           -c 16384 -t 4 -ngl 0 -rtr --seed 1 --no-display-prompt $args 2>&1 |
           grep -aE "^main:( *prompt)? *eval time" | head -2 | tr '\n' ' ')
    printf '  %-40s %s\n' "кэш $lbl" "${line:-не запустилось}"
done

say "5. префилл на карте"
# Prefill is where the card ought to earn its keep: matrix-by-matrix work, bound by arithmetic
# rather than by bandwidth or launch count. Reported separately from generation because the
# two are limited by different things and mixing them hid this for a whole session.
for n in 0 8 16; do
    line=$("$VK/llama-cli.exe" -m "$MX3" -f /d/MemeX/results/prompt_code.txt -n 8 \
           -c 8192 -t 4 -ngl $n -fa off --seed 1 --no-display-prompt 2>&1 |
           grep -a "^main: prompt eval time" | head -1)
    printf '  %-40s %s\n' "ngl=$n" "${line:-не запустилось}"
done
