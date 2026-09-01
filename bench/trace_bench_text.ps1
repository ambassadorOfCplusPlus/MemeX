# Trace the expert selections on the BENCHMARK'S OWN stream, so the offline replay and the
# engine finally measure the same thing.
#
# Why this exists. The engine reports 71.3% hits at capacity 12. Two independent offline
# replays - a fresh transcription of resident_set.cpp and our own vram_residency.py, agreeing
# with each other to 0.04 points - report 46.6% at the same capacity. The gap is not the policy:
# a CLAIRVOYANT fixed set of 12 per layer reaches only 46-57% on our trace corpora, so no policy
# whatever could produce 71.3% there. It is the text. fold_ab.ps1 prompts from prompt_2000.txt,
# which is the Project Gutenberg header and the opening of War and Peace - type/token 0.228
# against 0.403-0.685 for the corpora the traces were collected on.
#
# Corroborated from the other side of the policy: the engine does 1.68 promotions per token, the
# replay 4.26. Same fact, different measurement.
#
# So: run the tracer over prompt_2000.txt with the benchmark's own shape - 512 tokens of prefill
# in ONE batch, then 192 generated - and hand the replay a stream it can compare against 71.3%.
#
# The two phases separate themselves in the trace: the prefill batch carries n_tok = 512, the
# generated tokens arrive as 192 records with n_tok = 1. No phase marker is needed.
#
# -no-fmoe / -no-fug are not optional: the fused MoE path elides the node the trace callback
# matches on. Copied from specpf_trace2.ps1 rather than rediscovered.
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$BIN    = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG    = 'D:\MemeX\results\hobbit\trace_bench.log'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$OUT    = 'D:\MemeX\results\hobbit\tr_bench_wp.bin'
$NPZ    = 'D:\MemeX\results\hobbit\ap_bench_wp.npz'

New-Item -ItemType Directory -Force -Path 'D:\MemeX\results\hobbit' | Out-Null
function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) | Tee-Object -FilePath $LOG -Append }

$exe = Join-Path $BIN 'llama-moe-trace.exe'
foreach ($f in @($exe, $MODEL, $PROMPT)) {
    if (-not (Test-Path -LiteralPath $f)) { Note "NET FAJLA: $f"; exit 1 }
}
# Runnability, not existence: -1073741515 / -1073741511 mean a broken build tree and read like
# an empty result rather than a failure.
& $exe --version *> "$env:TEMP\trace_bench_ver.txt"
if ($LASTEXITCODE -lt 0) { Note "binarnik ne zapuskaetsja, kod $LASTEXITCODE"; exit 1 }

if (-not (Take-Machine -Who 'trace_bench' -TimeoutMin 600 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    if (Test-Path $OUT) { Remove-Item $OUT -Force -EA SilentlyContinue }
    $env:MOE_TRACE_OUT   = $OUT
    $env:MOE_TRACE_PROBS = '1'
    # No MOE_TRACE_ACT: the replay consumes only the top-k ids, and the activations are what
    # made the earlier traces half a gigabyte each.
    Note 'zapis trassy: ves promt odnim dekodom - eto TEKST bencha, a ne ego potok'
    & $exe -m $MODEL -f $PROMPT -c 4096 -b 4096 -ub 4096 -t 8 -ngl 0 -fa off `
           -no-fmoe -no-fug --seed 1 *> 'D:\MemeX\results\hobbit\run_bench_wp.log'
    Remove-Item Env:MOE_TRACE_OUT, Env:MOE_TRACE_PROBS -EA SilentlyContinue

    # Size, not presence. A file that exists and is empty is the failure mode this project keeps
    # reading as success.
    if (-not ((Test-Path $OUT) -and ((Get-Item $OUT).Length -gt 1MB))) {
        Note 'trassa ne zapisalas'
        Get-Content 'D:\MemeX\results\hobbit\run_bench_wp.log' -Tail 12 -EA SilentlyContinue |
            ForEach-Object { Note ('    ' + $_) }
        exit 2
    }
    Note ("trassa: {0:N1} MB" -f ((Get-Item $OUT).Length/1MB))
    & python 'C:/Users/User11/Desktop/MemeX/memex/specpf_data.py' $OUT $NPZ 2>&1 |
        ForEach-Object { Note ('    ' + $_) }
    if ((Test-Path $NPZ) -and ((Get-Item $NPZ).Length -gt 1MB)) {
        Note ("gotovo: {0}, {1:N1} MB" -f $NPZ, ((Get-Item $NPZ).Length/1MB))
    } else {
        Note 'konvertacija ne dala npz - syraja trassa ostavlena na meste'
    }
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
