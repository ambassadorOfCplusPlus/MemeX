#!/bin/sh
# Ночной конвейер. Один последовательный поток тяжёлой работы, чтобы процессор не простаивал
# и чтобы два прогона никогда не считались одновременно — на четырёх ядрах это даёт 13% шума,
# и мы за этим шумом однажды уже гонялись.
#
# Порядок задан ценностью ответа, а не удобством:
#   1. матрица важности заново — от неё зависит главный открытый вопрос;
#   2. mx4 — тот же профиль байт, что у mx3, но с полной калибровкой. Разница между mx1, mx3 и
#      mx4 изолирует именно калибровку: у mx1 её нет вовсе, у mx3 только внимание, у mx4 всё;
#   3. наш движок против форка — от этого зависит стратегия развития движка;
#   4. непроверенные флаги;
#   5. mx5 — лишний бит на самой чувствительной матрице экспертов, повтор сравнения mx1/mx2,
#      но уже в корректных условиях. В прошлый раз оно ничего не купило, и это был сигнал, что
#      дело не в распределении битов, а в калибровке. Теперь проверяем по-настоящему.
#
# Всё пишется на D:, потому что на C: свободно 1.3 ГБ.
set -u

BIN=/d/MemeX/src/ik_llama.cpp/build/bin/Release
LOG=/d/MemeX/results/night.log
Q6=D:\\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf
MX1=D:\\Qwen3-Coder-30B-A3B-mx1.gguf
MX3=D:\\Qwen3-Coder-30B-A3B-mx3.gguf
MX4=D:\\Qwen3-Coder-30B-A3B-mx4.gguf
MX5=D:\\Qwen3-Coder-30B-A3B-mx5.gguf
DRAFT3=D:\\qwen3-0.6b-iq3.gguf
DRAFT=D:\\smartstock\\models\\qwen3-0.6b-q4_k_m.gguf
IMAT=D:\\MemeX\\results\\imatrix2.dat
TEXT=D:\\MemeX\\data\\calibration.txt
PROMPT="Write a Python function that merges two sorted lists and explain each step."

# Byte profile shared by mx3 and mx4 so the only difference between them is calibration.
PROFILE='ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq4_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks,output.weight=iq4_ks'
# mx5 spends one extra bit on down_exps, the matrix that showed up as most sensitive.
PROFILE5='ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq5_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks,output.weight=iq4_ks'

say() { printf '\n[%s] ===== %s\n' "$(date +%H:%M)" "$1" | tee -a "$LOG"; }
note() { printf '  %s\n' "$1" | tee -a "$LOG"; }

busy() {
    for exe in llama-quantize.exe llama-cli.exe llama-perplexity.exe llama-imatrix.exe memex-fwd.exe; do
        tasklist //FI "IMAGENAME eq $exe" 2>/dev/null | grep -qi "${exe%%.*}" && return 0
    done
    return 1
}

# Five consecutive quiet minutes, so a short gap between two arms of the running campaign is
# not mistaken for the campaign being over.
wait_quiet() {
    q=0
    while [ $q -lt 10 ]; do
        if busy; then q=0; else q=$((q + 1)); fi
        sleep 30
    done
}

ppl() {  # ppl <label> <model>
    line=$("$BIN/llama-perplexity.exe" -m "$2" -f "$TEXT" -c 512 --chunks 16 -t 4 \
           -ngl 0 -fa off -rtr 2>&1 | grep -a "Final estimate" | head -1)
    note "$(printf '%-34s %s' "$1" "${line:-не посчиталось}")"
}

speed() {  # speed <label> <model> [extra args...]
    label=$1; model=$2; shift 2
    line=$("$BIN/llama-cli.exe" -m "$model" -p "$PROMPT" -n 128 -c 4096 -t 4 -ngl 0 \
           -fa off -rtr --seed 1 --no-display-prompt "$@" 2>&1 |
           grep -a "^main:  *eval time" | head -1)
    note "$(printf '%-34s %s' "$label" "${line:-не запустилось}")"
}

coverage() {  # how many of the 48 layers actually have expert data
    python - <<'PY' 2>/dev/null
import collections, re, struct
c = collections.Counter()
try:
    with open(r'D:\MemeX\results\imatrix2.dat', 'rb') as f:
        n = struct.unpack('<i', f.read(4))[0]
        for _ in range(n):
            ln = struct.unpack('<i', f.read(4))[0]
            name = f.read(ln).decode('utf-8', 'replace')
            ncall, nval = struct.unpack('<ii', f.read(8))
            f.read(4 * nval)
            c[re.sub(r'blk\.\d+\.', 'blk.N.', name)] += 1
except Exception as e:
    print('не прочиталась:', e); raise SystemExit
for k in ('blk.N.ffn_up_exps.weight', 'blk.N.ffn_gate_exps.weight',
          'blk.N.ffn_down_exps.weight', 'blk.N.attn_q.weight', 'output.weight'):
    print(f'{k:32s} {c.get(k, 0)} / 48')
PY
}

mkdir -p /d/MemeX/results
printf '\n\n######## ночной прогон, старт %s\n' "$(date)" >> "$LOG"

say "ждём, пока освободится процессор"
wait_quiet
note "свободен"

# ---------------------------------------------------------------- 1. матрица важности
say "матрица важности заново: 400 блоков, слияние up-gate выключено"
# -no-fmoe/-no-fug matter more than the chunk count: the fused op reports statistics under
# src[0]'s name only, so ffn_gate_exps collected nothing at all in the first attempt.
"$BIN/llama-imatrix.exe" -m "$Q6" -f "$TEXT" -o "$IMAT" \
    --chunks 400 -c 512 -t 4 -ngl 0 -fa off -rtr -no-fmoe -no-fug \
    > /d/MemeX/results/imatrix2.log 2>&1
note "покрытие:"; coverage | while read -r l; do note "  $l"; done

# -rtr repacks weights, and it is not certain the collection hooks behave identically for the
# repacked types. If the expert tensors came out empty, retry the slow, plain way rather than
# quantise against a matrix we do not trust.
got=$(coverage | awk '/ffn_gate_exps/ {print $2}')
if [ "${got:-0}" -lt 24 ]; then
    say "покрытие gate плохое (${got:-0}/48) — повтор без -rtr"
    "$BIN/llama-imatrix.exe" -m "$Q6" -f "$TEXT" -o "$IMAT" \
        --chunks 400 -c 512 -t 4 -ngl 0 -fa off -no-fmoe -no-fug \
        > /d/MemeX/results/imatrix2b.log 2>&1
    note "покрытие:"; coverage | while read -r l; do note "  $l"; done
fi

# ---------------------------------------------------------------- 2. mx4
say "mx4: профиль mx3, но с калиброванной матрицей"
"$BIN/llama-quantize.exe" --allow-requantize --imatrix "$IMAT" --custom-q "$PROFILE" \
    "$Q6" "$MX4" q6_k 4 > /d/MemeX/results/quant4.log 2>&1
note "размер: $(ls -l --block-size=M /d/Qwen3-Coder-30B-A3B-mx4.gguf 2>/dev/null | awk '{print $5}')"
note "тензоров без данных в матрице: $(grep -ac 'did not find weights' /d/MemeX/results/quant4.log)"

say "качество и скорость: mx1 (без калибровки) / mx3 (внимание) / mx4 (всё)"
# Reference is Q6_K_XL at 2.1236 on these exact settings; the budget is +2%.
ppl "mx4" "$MX4"
ppl "mx3" "$MX3"
ppl "mx1" "$MX1"
speed "mx4" "$MX4"
[ -f /d/qwen3-0.6b-iq3.gguf ] && speed "mx4 + черновик IQ3 n_max=3" "$MX4" -md "$DRAFT3" --spec-type draft:n_max=3
[ -f /d/qwen3-0.6b-iq3.gguf ] || speed "mx4 + черновик Q4 n_max=3" "$MX4" -md "$DRAFT" --spec-type draft:n_max=3

# ---------------------------------------------------------------- 3. наш движок против форка
say "наш цикл против форка"
sh /c/Users/User11/Desktop/MemeX/bench/own_vs_fork.sh 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------- 4. флаги
if [ -f /c/Users/User11/Desktop/MemeX/bench/flag_sweep.sh ]; then
    say "перебор непроверенных флагов"
    sh /c/Users/User11/Desktop/MemeX/bench/flag_sweep.sh 2>&1 | tee -a "$LOG"
else
    say "flag_sweep.sh ещё не готов — пропускаю"
fi

# ---------------------------------------------------------------- 5. mx5
say "mx5: лишний бит на down_exps, теперь при корректной калибровке"
"$BIN/llama-quantize.exe" --allow-requantize --imatrix "$IMAT" --custom-q "$PROFILE5" \
    "$Q6" "$MX5" q6_k 4 > /d/MemeX/results/quant5.log 2>&1
note "размер: $(ls -l --block-size=M /d/Qwen3-Coder-30B-A3B-mx5.gguf 2>/dev/null | awk '{print $5}')"
ppl "mx5" "$MX5"
speed "mx5" "$MX5"

say "конец"
printf '\nсводка в %s\n' "$LOG"
