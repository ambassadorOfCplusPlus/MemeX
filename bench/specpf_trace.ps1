# Collect the (router input at layer L, expert ids/probs at layer L+1) dataset the learned
# predictor needs - across code, English prose and Russian, because a set fitted on one domain
# is measured to be worthless on another (METHODS 33: a code-derived set takes 24.1% of Russian
# picks against 25.0% for a random one).
#
# Nothing here is new data collection for its own sake. tr_act.bin already holds 1110 tokens of
# exactly this pair and it is what proved the idea works; it is one domain and it overfits
# (train R@16 99.9% against test 82.2%). This run buys tokens and domains, not a new quantity.
#
# -no-fmoe / -no-fug are not optional: the fused MoE path elides the ffn_moe_probs node the
# callback matches on. MOE_TRACE_ACT captures ffn_inp_normed, which lives outside the fused op
# and would survive either way, but the two must come from ONE run to be aligned.
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\specpf\collect.log'
$MODEL = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'

function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) | Tee-Object -FilePath $LOG -Append }

("`n`n######## sbor trass dlja predskazatelja " + (Get-Date)) | Add-Content $LOG
$exe = Join-Path $BIN 'llama-moe-trace.exe'
if (-not (Test-Path $exe)) { Note "net binarnika: $exe"; exit 1 }
# METHODS 49: proverjaem zapuskaemost, a ne nalichie fajla. Kody -1073741511 / -1073741515
# oznachajut slomannoe derevo sborki i vygljadjat kak pustoj rezultat.
& $exe --version *> "$env:TEMP\specpf_ver.txt"
if ($LASTEXITCODE -lt 0) { Note "binarnik ne zapuskaetsja, kod $LASTEXITCODE"; exit 1 }
Note "binarnik zapuskaetsja (kod $LASTEXITCODE)"

if (-not (Take-Machine -Who 'specpf_trace' -TimeoutMin 600 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    foreach ($dom in @('code','en','ru')) {
        $prompt = "D:\MemeX\results\specpf\prompt_$dom.txt"
        $out    = "D:\MemeX\results\specpf\tr_ap_$dom.bin"
        $npz    = "D:\MemeX\results\specpf\ap_$dom.npz"
        if (Test-Path $npz) { Note "$dom - npz uzhe est, propuskaem"; continue }
        if (Test-Path $out) { Remove-Item $out -Force -EA SilentlyContinue }
        $env:MOE_TRACE_OUT   = $out
        $env:MOE_TRACE_ACT   = '1'
        $env:MOE_TRACE_PROBS = '1'
        Note "$dom : zapis trassy"
        & $exe -m $MODEL -f $prompt -c 8192 -b 8192 -ub 8192 -t 8 -ngl 0 -fa off `
               -no-fmoe -no-fug --seed 1 *> "D:\MemeX\results\specpf\run_$dom.log"
        Remove-Item Env:MOE_TRACE_OUT, Env:MOE_TRACE_ACT, Env:MOE_TRACE_PROBS -EA SilentlyContinue
        # Nalichie fajla ne est zapis (METHODS: proverjalos sushchestvovanie tam, gde nuzhna
        # byla prigodnost). Sudim po razmeru, i tolko potom konvertiruem.
        if (-not ((Test-Path $out) -and ((Get-Item $out).Length -gt 100MB))) {
            Note "$dom : trassa ne zapisalas"
            Get-Content "D:\MemeX\results\specpf\run_$dom.log" -Tail 8 -EA SilentlyContinue | ForEach-Object { Note ('    ' + $_) }
            continue
        }
        Note ("$dom : {0:N1} MB, konvertacija" -f ((Get-Item $out).Length/1MB))
        & python 'C:/Users/User11/Desktop/MemeX/memex/specpf_data.py' $out $npz 2>&1 | ForEach-Object { Note ('    ' + $_) }
        if ((Test-Path $npz) -and ((Get-Item $npz).Length -gt 10MB)) {
            Remove-Item $out -Force -EA SilentlyContinue      # syroj f32 v dva raza izbytochen
            Note ("$dom : gotovo, npz {0:N1} MB" -f ((Get-Item $npz).Length/1MB))
        } else { Note "$dom : konvertacija ne dala npz" }
    }
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
