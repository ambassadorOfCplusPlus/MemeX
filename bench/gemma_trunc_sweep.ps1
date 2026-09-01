# Where do the 0.796 ms of a gemma4 attention crossing actually go?
#
# THE QUESTION, and it is now the largest open item in the token. A layer's card graph is 21
# dispatches: four big matmuls (q, k, v, o) moving ~39 MB, and seventeen small ones (norms,
# ropes, cache writes, kq, softmax, kqv). The dense half - measured on this same card an hour
# ago - moves 19 MB in 0.149 ms, i.e. **127 GB/s**, so the big matmuls should cost about
# 39/127 = 0.307 ms. The crossing measures 0.796. That leaves **0.489 ms per layer, 14.7 ms per
# token, in operations that move almost no bytes.**
#
# MEMEX_STATIC_TRUNC builds the layer graph only up to stage N. The output is then wrong on
# purpose: device time does not depend on the values (rule 73), so the INCREMENT from stage N to
# N+1 is the true cost of the nodes between them, including their barrier and any submit they
# trigger. Per-node timestamps were tried and refuted (rule 80): execution is serial, so a small
# node's span swallows the drain of the big node before it, and the logger duly named ROPE the
# most expensive op in attention while removing it changed nothing.
#
#   1 input norm       2 +q,k,v proj    3 +q,k norms and ropes   4 +KV writes
#   5 +kq              6 +softmax       7 +kqv                   8 +o_proj and residual
#   0 full graph
#
# Read the RESULT as increments, never as absolutes: stage 5 alone means nothing, stage 5 minus
# stage 4 is the cost of kq.
param(
    [int]    $Tokens  = 256,
    [int]    $Ngen    = 16,
    [int]    $Threads = 8,
    [string] $Prompt  = 'D:\MemeX\results\prompt_2000.txt'
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'
$LOG   = 'D:\MemeX\results\gemma_trunc_sweep.log'
$OUT   = 'D:\MemeX\results'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

foreach ($f in @($EXE, $MODEL, $Prompt)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "NET FAJLA: $f"; exit 4 }
}

$names = @{
  1 = 'norma vhoda';        2 = '+ q,k,v proekcii';  3 = '+ normy i rope';
  4 = '+ zapis KV';         5 = '+ kq';              6 = '+ softmax';
  7 = '+ kqv';              8 = '+ o_proj i ostatok'; 0 = 'polnyj graf'
}

("`n`n######## razvjortka stadij sloja " + (Get-Date)) | Add-Content $LOG
Say 'Chitat PRIRASHCHENIJA, ne absoljutnye znachenija. Bez plotnoj poloviny (--gpu-static-layers), chtoby merit tolko vnimanie.'

$res = @{}
if (-not (Take-Machine -Who 'trunc_sweep' -TimeoutMin 240)) { Note 'mashinu ne poluchili'; exit 3 }
try {
    foreach ($st in @(1,2,3,4,5,6,7,8,0)) {
        $log = Join-Path $OUT "_tr_$st.out"
        $env:MEMEX_STATIC_TRUNC = "$st"
        $a = @('-m', $MODEL, '-f', $Prompt, '--tokens', "$Tokens", '--gen', "$Ngen",
               '-t', "$Threads", '--no-repack', '--no-ref', '--gpu-static-layers')
        $cmdline = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" } }) -join ' '
        $proc = Start-Process -FilePath $EXE -ArgumentList $cmdline -NoNewWindow -PassThru `
                              -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        $null = $proc.Handle
        if (-not $proc.WaitForExit(1800 * 1000)) { try { $proc.Kill($true) } catch { }; Note "stadija ${st}: tajm-aut"; continue }
        Remove-Item Env:MEMEX_STATIC_TRUNC -EA SilentlyContinue
        # Rule 68: the arm has to say which arm it is, and the engine prints the stage it built.
        $txt = Get-Content -LiteralPath "$log.err" -EA SilentlyContinue
        $s = $txt | Select-String -Pattern 'STATIC_TRUNC (\d+) uzlov (\d+)' | Select-Object -First 1
        $said = -1; $nodes = -1
        if ($s -and $s.Line -match 'STATIC_TRUNC (\d+) uzlov (\d+)') { $said = [int]$Matches[1]; $nodes = [int]$Matches[2] }
        if ($said -ne $st) { Note ("stadija ${st}: dvizhok skazal STATIC_TRUNC $said - VYBROSHENO"); continue }
        $o = Get-Content -LiteralPath $log -EA SilentlyContinue
        $l = $o | Select-String -Pattern 'na tokjen ([\d.,]+) ms' | Select-Object -First 1
        if (-not $l) { Note "stadija ${st}: net stroki 'na tokjen' - vybrosheno"; continue }
        $ms = [double](($l.Line -replace '.*na tokjen ([\d.,]+) ms.*','$1') -replace ',', '.')
        $res[$st] = $ms
        Note ("stadija {0} {1,-22} uzlov {2,3}   sloi na token {3,7:N2} ms" -f $st, $names[$st], $nodes, $ms)
    }
} finally { Free-Machine; Say 'mashina osvobozhdena' }

Say 'PRIRASHCHENIJA - eto i est cena kazhdoj stadii'
$prev = 0.0
foreach ($st in @(1,2,3,4,5,6,7,8,0)) {
    if (-not $res.ContainsKey($st)) { Note ("{0,-24} NE IZMERENO" -f $names[$st]); continue }
    $d = $res[$st] - $prev
    Note ("{0,-24} vsego {1,7:N2} ms   PRIRASHCHENIE {2,7:N2} ms" -f $names[$st], $res[$st], $d)
    $prev = $res[$st]
}
if ($res.ContainsKey(0) -and $res.ContainsKey(8)) {
    Note ("hvost posle o_proj (vklyuchaja normy gemma4, marshrutizator): {0:N2} ms" -f ($res[0] - $res[8]))
}
