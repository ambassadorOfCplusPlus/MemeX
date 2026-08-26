#!/bin/sh
# =============================================================================
# flag_sweep.sh --- замер флагов ik_llama.cpp для Qwen3-Coder-30B-A3B (qwen3moe)
#
# ЧТО ЗАМЕРЯЕТСЯ И ЗАЧЕМ
# ----------------------
# Конфигурация: только CPU (-ngl 0), Windows, flash attention выключен (-fa off),
# run-time repack (-rtr), 4 потока. Узкое место --- пропускная способность RAM
# (измерено: 1.83 ГБ чтения на токен при 24.8 ГБ/с). Значит выигрыш может дать
# только то, что уменьшает объём читаемой памяти или улучшает локальность чтения.
# Всё остальное --- шум.
#
# В скрипт включены ТОЛЬКО те флаги, которые по результатам аудита кода реально
# что-то делают в этой конфигурации. Флаги-пустышки (-mqkv, -rcache, -sas, -smgs,
# -ger, -mtp, -mtprot, -gap, -grt, -vq, -khad, -vhad, -wb) исключены --- причины
# перечислены в отчёте, а не здесь.
#
# СЕКЦИЯ 1 (-c 4096) --- по одному изменению относительно базовой строки:
#   base        базовая линия, все остальные арки сравниваются с ней
#   -muge       объединяет ffn_up_exps и ffn_gate_exps в один непрерывный тензор.
#               В этом файле оба тензора имеют тип IQ4_XS, поэтому слияние реально
#               произойдёт (при разных типах код молча отказывается сливать).
#               Fused-op up*silu(gate) и так включён по умолчанию; -muge меняет не
#               наличие фьюза, а то, что fused-ядро читает ОДИН буфер вместо двух.
#               Именно это и может помочь при упоре в память. Главный кандидат.
#   -amb N      порог (в МиБ!) на размер тензора K*Q, выше которого attention
#               считается по головам, а не одним большим matmul. Работает только
#               при -fa off, то есть ровно в нашем случае. Влияет на prompt eval,
#               на генерацию (1 токен) практически нет. -amb 0 = никогда не дробить.
#   -ub N       физический размер микробатча --- именно он, а не -b, задаёт
#               реальную нарезку в llama_decode. Влияет на prompt eval и на размер
#               compute-буфера.
#
# СЕКЦИЯ 2 (-c 16384) --- зонированный KV-кэш, ради чего флаг и существует:
#   Семантика проверена по коду: N в "-ctk-first TYPE,N" --- это число СЛОЁВ, а не
#   позиций в контексте. "first" = слои с малыми индексами, "last" = с большими.
#   Внутри слоя тип кэша один, поэтому никакого смешивания типов под одним softmax
#   нет. При -fa off квантованный V запрещён (жёсткое исключение), поэтому арок с
#   -ctv-first / -ctv-last здесь НЕТ --- они бы просто уронили запуск.
#   На 16384 f16-кэш K+V занимает ~1.6 ГиБ, что сравнимо с чтением веса на токен,
#   поэтому квантование K тут может дать реальный выигрыш.
#
# ВНИМАНИЕ: в машине 32 ГБ RAM. Модель mx1 (16.5 ГБ) + KV на 16384 (~1.6 ГБ) и
# -rtr (mmap отключается, всё грузится в RAM) --- запускать секцию 2 только когда
# посторонние процессы освободят память, иначе уйдёт в swap и цифры будут ложью.
# =============================================================================

set -u

BIN_DIR="/d/MemeX/src/ik_llama.cpp/build/bin/Release"
CLI="$BIN_DIR/llama-cli.exe"

WORK_DIR="${TMPDIR:-/tmp}/flag_sweep.$$"
mkdir -p "$WORK_DIR" || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Model selection. Prefer mx3, fall back to mx1.
#
# NOTE: existence alone is not enough. At the time this script was written,
# mx3.gguf existed (8.4 GB) but its header was all zero bytes -- not a valid
# GGUF. So we check the "GGUF" magic, not just the file. A file that exists but
# is not a GGUF is treated as absent.
# ---------------------------------------------------------------------------
is_gguf() {
    [ -f "$1" ] || return 1
    magic=$(head -c 4 "$1" | od -An -c | tr -d ' \n')
    [ "$magic" = "GGUF" ]
}

MODEL_WIN=""
if is_gguf "/d/Qwen3-Coder-30B-A3B-mx3.gguf"; then
    MODEL_WIN="D:\\\\Qwen3-Coder-30B-A3B-mx3.gguf"
    echo "model: mx3"
elif is_gguf "/d/Qwen3-Coder-30B-A3B-mx1.gguf"; then
    MODEL_WIN="D:\\\\Qwen3-Coder-30B-A3B-mx1.gguf"
    echo "model: mx1 (mx3 missing or not a valid GGUF)"
else
    echo "ни одна модель не найдена / не является валидным GGUF" >&2
    exit 1
fi

PROMPT="Write a Python function that merges two sorted lists."

# Long prompt file for the 16384-context section, so that prompt-eval is
# actually large enough to measure.
LONG_PROMPT="$WORK_DIR/long_prompt.txt"
i=0
while [ "$i" -lt 400 ]; do
    printf '%s\n' "The quick brown fox jumps over the lazy dog while the maintainer refactors the tokenizer, the scheduler, the allocator, and the quantization kernels of a large mixture of experts language model runtime." >> "$LONG_PROMPT"
    i=$((i + 1))
done

BASE_4K="-n 128 -c 4096 -t 4 -ngl 0 -fa off -rtr --seed 1 --no-display-prompt"
BASE_16K="-n 128 -c 16384 -t 4 -ngl 0 -fa off -rtr --seed 1 --no-display-prompt"

# ---------------------------------------------------------------------------
# Timing extraction.
#
# The timings line is printed by llama_print_timings(), so the real prefix is
# "llama_print_timings:", NOT "main:". Both are accepted here so the script
# keeps working if the prefix ever changes. Anything that fails to match must
# say so out loud -- a silently empty cell has produced a wrong conclusion in
# this project before.
# ---------------------------------------------------------------------------
NOTRUN="не запустилось"

# generation speed: the "eval time" line that is NOT "prompt eval time"
extract_tg() {
    v=$(grep -E '^[a-z_]+: +eval time' "$1" 2>/dev/null \
        | tail -n 1 \
        | sed -n 's/.*[ (]\([0-9][0-9.]*\) tokens per second.*/\1/p')
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$NOTRUN"
}

extract_pp() {
    v=$(grep -E '^[a-z_]+: +prompt eval time' "$1" 2>/dev/null \
        | tail -n 1 \
        | sed -n 's/.*[ (]\([0-9][0-9.]*\) tokens per second.*/\1/p')
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$NOTRUN"
}

RESULTS="$WORK_DIR/results.txt"
: > "$RESULTS"

# run_arm <label> <section> <extra args...>
# section is "4k" (report TG only) or "16k" (report PP and TG)
run_arm() {
    label=$1
    section=$2
    shift 2
    log="$WORK_DIR/$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '_').log"

    echo ">>> running: $label" >&2
    if [ "$section" = "16k" ]; then
        # shellcheck disable=SC2086
        "$CLI" -m "$MODEL_WIN" -f "$LONG_PROMPT" $BASE_16K "$@" > "$log" 2>&1
    else
        # shellcheck disable=SC2086
        "$CLI" -m "$MODEL_WIN" -p "$PROMPT" $BASE_4K "$@" > "$log" 2>&1
    fi

    tg=$(extract_tg "$log")
    pp=$(extract_pp "$log")
    printf '%s\t%s\t%s\t%s\n' "$section" "$label" "$pp" "$tg" >> "$RESULTS"

    if [ "$tg" = "$NOTRUN" ]; then
        echo "    $NOTRUN  (лог: $log)" >&2
        # Keep the log of a failed arm so the failure can actually be read.
        cp "$log" "./failed_$(basename "$log")" 2>/dev/null
    else
        echo "    pp=$pp tg=$tg" >&2
    fi
}

print_table() {
    section=$1
    header=$2
    echo ""
    echo "$header"
    printf '%-34s %14s %14s\n' "arm" "prompt tok/s" "gen tok/s"
    printf '%-34s %14s %14s\n' "----------------------------------" "--------------" "--------------"
    while IFS="$(printf '\t')" read -r sec label pp tg; do
        [ "$sec" = "$section" ] || continue
        printf '%-34s %14s %14s\n' "$label" "$pp" "$tg"
    done < "$RESULTS"
}

# ===========================================================================
# SECTION 1 -- one changed thing per arm, -c 4096
# ===========================================================================
run_arm "base"          4k
run_arm "-muge"         4k -muge
run_arm "-amb 0"        4k -amb 0
run_arm "-amb 128"      4k -amb 128
run_arm "-amb 512"      4k -amb 512
run_arm "-amb 1024"     4k -amb 1024
run_arm "-ub 128"       4k -ub 128
run_arm "-ub 256"       4k -ub 256
run_arm "-ub 1024"      4k -ub 1024

# ===========================================================================
# SECTION 2 -- zoned K-cache at -c 16384.
# K only: with -fa off a quantized V cache throws, so no -ctv arms exist here.
# 48 layers total, so N is bounded by 48.
# ===========================================================================
run_arm "16k base (f16 K/V)"        16k
run_arm "16k -ctk q8_0 (uniform)"   16k -ctk q8_0
run_arm "16k -ctk-first q8_0,24"    16k -ctk-first q8_0,24
run_arm "16k -ctk-last q8_0,24"     16k -ctk-last q8_0,24
run_arm "16k -ctk-last q8_0,40"     16k -ctk-last q8_0,40
run_arm "16k -ctk-first q6_0,24"    16k -ctk-first q6_0,24
# -amb matters most here: at 16384 the K*Q tensor crosses the default 256 MiB
# threshold during prompt processing, so this is where the flag has teeth.
run_arm "16k -amb 0"                16k -amb 0
run_arm "16k -amb 1024"             16k -amb 1024

print_table 4k  "=== SECTION 1: -c 4096, one flag changed per arm ==="
print_table 16k "=== SECTION 2: -c 16384, zoned K-cache (K only, -fa off) ==="
echo ""
