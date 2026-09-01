# Gemma 4 generation speed WITH the card actually computing the layers - which has never been
# measured, because until today the decode graph never got the card.
#
# `build_gemma4_step` takes gstat as its last parameter and it defaults to nullptr; the decode
# graph build site passed nothing, so `card` was false on every layer of every step. Meanwhile
# place_layers had uploaded 1174.7 MiB, --gpu-static-verify had confirmed the bytes, and the
# loader printed "vnimanie, marshrutizatory i KV-kesh na karte: 30 sloev". Every gemma4 tok/s
# ever recorded with --gpu-static-layers - 5.94 among them - was a pure CPU number under a line
# saying the layers were on the card. The only caller that passed gstat was Generator::build_one,
# reached only under --decode-check, which is why the probe comparison exercised the card and
# the speed measurement did not.
#
# Two arms, one binary, one session. The engine now prints which one it is:
#   "graf dekoda: sloi schitaet KARTA"
#   "graf dekoda: sloi schitaet processor (karta zapolnena, no graf ejo ne zovjot)"
# and this script REFUSES an arm whose line does not match what was asked for (rule 68).
param(
    [int]    $Reps    = 2,
    [int]    $Tokens  = 256,
    [int]    $Ngen    = 64,
    [int]    $Threads = 8
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL  = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\gemma_speed_ab.log'
$OUT    = 'D:\MemeX\results'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

foreach ($f in @($EXE, $MODEL, $PROMPT)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "NET FAJLA: $f"; exit 4 }
}

function RunOnce {
    param([string]$Tag, [string[]]$Extra, [int]$LimitSec)
    $log = Join-Path $OUT "_gsp_$Tag.out"
    $err = "$log.err"
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '--gen', "$Ngen",
           '-t', "$Threads", '--no-repack') + $Extra
    $cmdline = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" } }) -join ' '
    $proc = Start-Process -FilePath $EXE -ArgumentList $cmdline -NoNewWindow -PassThru `
                          -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitSec * 1000)) { try { $proc.Kill($true) } catch { }; return @{ err = 'tajm-aut' } }
    $res = @{ err = '' }
    $code = $proc.ExitCode
    if ($null -eq $code) { $code = -2 }
    if ($code -ne 0) { $res.err = "kod vyhoda $code"; return $res }
    $txt = Get-Content -LiteralPath $log -EA SilentlyContinue
    $w = $txt | Select-String -Pattern 'graf dekoda: sloi schitaet (KARTA|processor)' | Select-Object -First 1
    if ($w -and $w.Line -match 'graf dekoda: sloi schitaet (KARTA|processor)') { $res.who = $Matches[1] }
    $g = $txt | Select-String -Pattern 'our_tok_s ([\d.]+)' | Select-Object -First 1
    if ($g -and $g.Line -match 'our_tok_s ([\d.]+)') { $res.gen = [double]$Matches[1] }
    if (-not $res.ContainsKey('gen')) {
        $g2 = $txt | Select-String -Pattern 'наш ([\d.,]+) ток/с|nash ([\d.,]+) tok/s' | Select-Object -First 1
        if ($g2) { Note ("    (tok/s ne najden v STATIC_AB; stroka: " + $g2.Line.Trim() + ")") }
    }
    return $res
}

$arms = @(
    @{ t = 'karta';     x = @('--gpu-static-layers'); want = 'KARTA' },
    @{ t = 'processor'; x = @();                      want = $null   }
)
$acc = @{}; foreach ($arm in $arms) { $acc[$arm.t] = @() }

("`n`n######## skorost gemma4 " + (Get-Date)) | Add-Content $LOG
for ($r = 1; $r -le $Reps; $r++) {
    Say "berjom mashinu pod raund $r"
    if (-not (Take-Machine -Who 'gemma_speed' -TimeoutMin 180)) { Note 'mashinu ne poluchili'; exit 3 }
    try {
        foreach ($arm in $arms) {
            $res = RunOnce "$($arm.t)_$r" $arm.x 1800
            if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
            # Rule 68: the arm must say which arm it is, and the script checks it.
            if ($arm.want -and $res.who -ne $arm.want) {
                Note ("raund ${r} $($arm.t): dvizhok skazal 'sloi schitaet $($res.who)', prosili '$($arm.want)' - VYBROSHENO")
                continue
            }
            if (-not $res.ContainsKey('gen')) { Note ("raund ${r} $($arm.t): tok/s ne prochitan - vybrosheno"); continue }
            $acc[$arm.t] += $res.gen
            Note ("raund {0} {1,-10} schitaet {2,-9} tok/s {3,6:N2}" -f $r, $arm.t, $(if ($res.who) { $res.who } else { '?' }), $res.gen)
        }
    } finally { Free-Machine; Say "mashina osvobozhdena posle raunda $r" }
}

Say 'ITOG'
foreach ($arm in $arms) {
    $a = @($acc[$arm.t] | Where-Object { $null -ne $_ })
    if ($a.Count -eq 0) { Note ("{0,-10} NE IZMERENO" -f $arm.t); continue }
    $m = ($a | Measure-Object -Average).Average
    if ($a.Count -lt 2) { Note ("{0,-10} {1,6:N2} tok/s (odin progon - NE REZULTAT)" -f $arm.t, $m); continue }
    $sp = (($a | Measure-Object -Maximum).Maximum - ($a | Measure-Object -Minimum).Minimum) / $m
    Note ("{0,-10} {1,6:N2} tok/s (razbros {2,5:P1}, n={3})" -f $arm.t, $m, $sp, $a.Count)
}
