# Correctness before any timing, and against the reference rather than against plausibility.
#
# A card path that produces fluent text is not evidence. This project already had a
# float-reassociation bug that gave 3-6% relative L2 on the logits while every generated token
# still matched, so "the tokens are the same" is a weaker statement than it sounds and the L2 is
# the number that has to be read.
#
# Four checks, in increasing cost:
#
#   1. --gpu-static-selftest   no model. A synthetic Q6_K head of the real width, uploaded
#                              through the same path, then the same matmul on the CPU backend
#                              and on the device, row by row, plus a byte compare of everything
#                              that reached video memory. This is the only check that can see a
#                              wrong upload offset or a lost row block.
#   2. cpu parity              the engine's own prefill logit comparison against llama_decode,
#                              with the head on the CPU. The baseline L2: whatever the card arm
#                              scores has to be read against THIS, not against zero.
#   3. card parity             the same run with --gpu-static-verify. Same prompt, same tokens.
#   4. --decode-check          per-step comparison down the generation path, which is the path
#                              the timing A/B measures.
#
# Rule 47: none of these is corrupted by a busy machine - their output is a value, not a
# duration - so this script takes the lock for the RESOURCES (16 GB and the card) and not for
# quiet, and it can run while other work holds the cores.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-static.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$LOG    = 'D:\MemeX\results\head_verify.log'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'

function Say($m)  { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | ForEach-Object { Write-Host $_; Add-Content -LiteralPath $LOG -Value $_ -Encoding UTF8 } }
function Note($m) { ("  " + $m) | ForEach-Object { Write-Host $_; Add-Content -LiteralPath $LOG -Value $_ -Encoding UTF8 } }

function RunStep($tag, [string[]]$a, [int]$limitSec) {
    $so = "D:\MemeX\results\_hv_$tag.out"
    $proc = $null
    try {
        $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { Note ('ne zapustilsja: ' + $_.Exception.Message); return $null }
    if ($null -eq $proc) { Note 'Start-Process nichego ne vernul'; return $null }
    $null = $proc.Handle          # rule 55: without this .ExitCode is $null
    if (-not $proc.WaitForExit($limitSec * 1000)) {
        Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
        Note "tajm-aut posle $limitSec s"
        return $null
    }
    $code = $proc.ExitCode
    if ($null -eq $code) { Note 'ExitCode pust - schitaem otkazom'; return $null }
    Note "exit $code -> $so"
    $out = @()
    if (Test-Path $so) { $out += Get-Content $so }
    if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
    return $out
}

$tokens = if ($args.Count -gt 0) { [int]$args[0] } else { 64 }
$dcheck = if ($args.Count -gt 1) { [int]$args[1] } else { 8 }
$ownsLock = -not ($args -contains 'external')

("`n`n######## head verify " + (Get-Date)) | Add-Content $LOG
if (-not (Test-Path -LiteralPath $EXE)) { Note "net binarnika: $EXE"; exit 1 }

& $EXE --help *> $null
$hc = $LASTEXITCODE
if ($null -eq $hc) { Note 'ExitCode pust - schitaem otkazom'; exit 1 }
if ($hc -ne 0) { Note "binarnik ne zapuskaetsja (exit $hc)"; exit 1 }

if ($ownsLock) {
    if (-not (Take-Machine -Who 'gpu-static' -TimeoutMin 120 -MinFreeGB 16)) {
        Note 'mashinu ne poluchili'; exit 1
    }
} else { Note 'blokirovka u vyzyvajushchego, sami ne berjom' }
Note ('vladeem: ' + (Get-LockHolder))

$code = 0
try {
    Say '1. samoproverka modulja, bez modeli'
    $o = RunStep 'selftest' @('--gpu-static-selftest', '-t', '8') 600
    if ($null -eq $o) { $code = 1 }
    else {
        $o | Where-Object { $_ -match 'shirina|rashozhdenij|bufer:|ustrojstvo:|odna stroka|samoproverka|OBJAZAN|dolzhen lech|golovy v videopamjati' } |
            ForEach-Object { Note $_ }
        if (-not ($o -match 'samoproverka proshla')) { Note 'SAMOPROVERKA NE PROSHLA'; $code = 1 }
    }

    foreach ($arm in @('cpu', 'card')) {
        Say "2. paritet logitov protiv llama_decode: golova na $arm"
        $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$tokens", '-t', '8',
               '--probe', 'all', '--decode-check', "$dcheck")
        if ($arm -eq 'card') { $a += '--gpu-static-verify' }
        $o = RunStep "parity_$arm" $a 1500
        if ($null -eq $o) { Note 'plecho ne proshlo'; $code = 1; continue }
        # The lines that carry the answer. Kept as a filter rather than a full dump because a
        # --probe all run is ninety thousand lines and the two that matter are the logit L2 and
        # the argmax agreement.
        $o | Where-Object {
                $_ -match 'result_norm|logit|L2|argmax|arg-?max|\u0430\u0440\u0433\u043c\u0430\u043a\u0441|\u043b\u043e\u0433\u0438\u0442|\u0441\u043e\u0432\u043f\u0430|\u0440\u0430\u0441\u0445\u043e\u0436' -or
                $_ -match 'STATIC_AB|golova|golovy|bufer:|USTROJSTVO|provereno|OBJAZAN'
            } | Select-Object -First 60 | ForEach-Object { Note $_ }
    }
} finally {
    if ($ownsLock) { Free-Machine }
    Note ('lock posle: ' + (Get-LockHolder))
}
exit $code
