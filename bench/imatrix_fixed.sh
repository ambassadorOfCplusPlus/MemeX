#!/bin/sh
# Second attempt at the importance matrix, with both faults from the first one fixed.
#
# Fault 1: the fused up-gate op reports statistics under src[0]'s name only, and gate lives in
# src[1], so ffn_gate_exps collected nothing at all - no amount of text would have helped.
# Hence -no-fmoe -no-fug.
#
# Fault 2: save_imatrix deliberately drops any tensor where some expert was never exercised
# ("some of the experts end up not being exercised by the provided training data"). At 32
# chunks each layer had a few of its 128 experts never selected, so 44 of 48 layers were
# thrown away. The data file was never the problem - it holds about 1.1M tokens and we were
# reading 16k of it. 400 chunks gives roughly 12k activations per expert on average, which
# leaves room for the rarely routed ones.
#
# Waits for the running campaign to finish first: on four cores two of these at once would put
# noise into the campaign's timings, which is the whole reason it was written as one script.
set -u
BIN=/d/MemeX/src/ik_llama.cpp/build/bin/Release

quiet=0
while [ $quiet -lt 10 ]; do
    if tasklist //FI "IMAGENAME eq llama-quantize.exe" //FI "STATUS eq running" 2>/dev/null | grep -qi llama ||
       tasklist //FI "IMAGENAME eq llama-cli.exe" //FI "STATUS eq running" 2>/dev/null | grep -qi llama ||
       tasklist //FI "IMAGENAME eq llama-perplexity.exe" //FI "STATUS eq running" 2>/dev/null | grep -qi llama; then
        quiet=0
    else
        quiet=$((quiet + 1))
    fi
    sleep 30
done
echo "процессор свободен, считаю матрицу"

"$BIN/llama-imatrix.exe" -m "D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf" \
    -f "D:\MemeX\data\calibration.txt" -o "D:\MemeX\results\imatrix2.dat" \
    --chunks 400 -c 512 -t 4 -ngl 0 -fa off -rtr -no-fmoe -no-fug 2>&1 |
    tail -25

# The check that the first run needed and did not get: how many layers actually have expert
# data. Anything short of 48 for each of the three expert tensors means the calibration is
# still too thin and the quantisation would silently fall back to uncalibrated for the rest.
python - <<'PY'
import re, struct, collections
c = collections.Counter()
with open(r'D:\MemeX\results\imatrix2.dat', 'rb') as f:
    n = struct.unpack('<i', f.read(4))[0]
    for _ in range(n):
        ln = struct.unpack('<i', f.read(4))[0]
        name = f.read(ln).decode('utf-8', 'replace')
        ncall, nval = struct.unpack('<ii', f.read(8))
        f.read(4 * nval)
        c[re.sub(r'blk\.\d+\.', 'blk.N.', name)] += 1
print('покрытие матрицы:')
for k in ('blk.N.ffn_up_exps.weight', 'blk.N.ffn_gate_exps.weight',
          'blk.N.ffn_down_exps.weight', 'blk.N.attn_q.weight', 'output.weight'):
    print(f'  {k:32s} {c.get(k, 0)} / 48')
PY
