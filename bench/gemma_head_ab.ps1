# Gemma 4: the head on the card against the head on the host.
#
# WHY. With attention, routers and KV already on the card, three things still cross host RAM
# every token, and the head is the largest of them:
#
#   golova (token_embd, 262144 x 2816, Q8_0)   784 MB -> 31,6 ms   28% tokena
#   eksperty (30 x 8 x 3 x 2816 x 704)         803 MB -> 32,4 ms   29%
#   plotnaja polovina FFN (30 x 3 x 2816x2112) 301 MB -> 12,1 ms   11%
#
# From video memory at 131 GB/s the same 784 MB cost about 6 ms, so the head should be worth
# roughly 25 ms of a 112 ms token. Predicted here BEFORE the run: 9,10 -> about 11,7 tok/s.
# If it comes back under 10,2 the arithmetic is wrong somewhere and the number matters more
# than the prediction.
#
# WHY IT WAS NOT ON THE CARD ALREADY. `sc.head = false` was hardcoded for gemma4 with the note
# "its builder does not call the card head anyway" - true, and self-fulfilling: the builder did
# not call it because this line said not to upload it. gemma4's tail is fnorm -> mul_mat ->
# softcap and the substitution replaces ONLY the mul_mat: the norm runs before it and the
# softcap after, on the host, untouched. The refusal was wider than its reason - the third time
# that same pattern has hidden a whole lever in this project (--gen and --gpu-static-layers were
# the other two).
#
# VRAM: layers occupy 1292 MiB of a 3227 MiB budget; the head adds 748, leaving ~1190 - which is
# also roughly what a gemma4 expert cache would want later. Both fit, but not by much, so the
# occupancy is printed per arm rather than assumed.
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
$LOG    = 'D:\MemeX\results\gemma_head_ab.log'
$OUT    = 'D:\MemeX\results'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

foreach ($f in @($EXE, $MODEL, $PROMPT)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "NET FAJLA: $f"; exit 4 }
}

function RunOnce {
    param([string]$Tag, [string[]]$Extra, [int]$LimitSec)
    $log = Join-Path $OUT "_ghd_$Tag.out"
    $err = "$log.err"
    # --ref-fa is not optional for gemma4: with flash attention off the fork's own gemma4 V cache
    # is stored flat while gemma4 hands that code a 3-D V, so THE REFERENCE is wrong, not us.
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '--gen', "$Ngen",
           '-t', "$Threads", '--no-repack', '--ref-fa', '--gpu-static-layers') + $Extra
    $cmdline = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" } }) -join ' '
    $proc = Start-Process -FilePath $EXE -ArgumentList $cmdline -NoNewWindow -PassThru `
                          -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitSec * 1000)) { try { $proc.Kill($true) } catch { }; return @{ err = 'tajm-aut' } }
    $res = @{ err = '' }
    $code = $proc.ExitCode
    if ($null -eq $code) { $code = -2 }
    # exit 2 = "it ran and the numbers disagree" - a result, and for a SPEED arm an acceptable
    # one. Anything else means the run did not happen.
    if ($code -ne 0 -and $code -ne 2) { $res.err = "kod vyhoda $code"; return $res }
    $res.code = $code
    $txt = Get-Content -LiteralPath $log -EA SilentlyContinue
    # Rule 68: the arm has to say which arm it is. The head prints its own size in video memory,
    # and "0.0 MiB" is the host arm saying so in its own words.
    $h = $txt | Select-String -Pattern 'output.weight\s+(\S+),\s+([\d.,]+) MiB v videopamjati' | Select-Object -First 1
    if ($h -and $h.Line -match '([\d.,]+) MiB v videopamjati') { $res.head_mib = [double](($Matches[1]) -replace ',', '.') }
    $w = $txt | Select-String -Pattern 'graf dekoda: sloi schitaet (KARTA|processor)' | Select-Object -First 1
    if ($w -and $w.Line -match 'graf dekoda: sloi schitaet (KARTA|processor)') { $res.who = $Matches[1] }
    $g = $txt | Select-String -Pattern 'our_tok_s ([\d.]+)' | Select-Object -First 1
    if ($g -and $g.Line -match 'our_tok_s ([\d.]+)') { $res.gen = [double]$Matches[1] }
    $v = $txt | Select-String -Pattern 'kucha 0\s+DEVICE_LOCAL.*zanjato\s+([\d.,]+)' | Select-Object -Last 1
    if ($v -and $v.Line -match 'zanjato\s+([\d.,]+)') { $res.vram = [double](($Matches[1]) -replace ',', '.') }
    return $res
}

# want_head: how many MiB the head is expected to occupy. 0 means the host arm.
$arms = @(
    @{ t = 'golova_na_karte'; x = @();                      head = $true  },
    @{ t = 'golova_na_hoste'; x = @('--gpu-static-nohead'); head = $false }
)
$acc = @{}; foreach ($arm in $arms) { $acc[$arm.t] = @() }

("`n`n######## golova gemma4 " + (Get-Date)) | Add-Content $LOG
Say 'PREDSKAZANIE (do progona): golova na karte snimaet okolo 25 ms iz 112, to est 9,10 -> okolo 11,7 tok/s. Nizhe 10,2 - arifmetika gde-to nevernaja.'

for ($r = 1; $r -le $Reps; $r++) {
    Say "berjom mashinu pod raund $r"
    if (-not (Take-Machine -Who 'gemma_head' -TimeoutMin 180)) { Note 'mashinu ne poluchili'; exit 3 }
    try {
        foreach ($arm in $arms) {
            $res = RunOnce "$($arm.t)_$r" $arm.x 1800
            if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
            # The arm must be what was asked for, and the engine's own head line says it.
            $got_head = ($res.ContainsKey('head_mib') -and $res.head_mib -gt 1.0)
            if ($got_head -ne $arm.head) {
                Note ("raund ${r} $($arm.t): golova v videopamjati $($res.head_mib) MiB - eto ne to plecho, VYBROSHENO")
                continue
            }
            if (-not $res.ContainsKey('gen')) { Note ("raund ${r} $($arm.t): tok/s ne prochitan - vybrosheno"); continue }
            $acc[$arm.t] += $res.gen
            Note ("raund {0} {1,-16} golova {2,7:N1} MiB  kucha0 {3,7:N1} MiB  tok/s {4,6:N2}{5}" -f
                  $r, $arm.t, $(if ($res.head_mib) { $res.head_mib } else { 0 }),
                  $(if ($res.vram) { $res.vram } else { 0 }), $res.gen,
                  $(if ($res.code -eq 2) { '   (RASHOZHDENIE: skorost godna, tochnost net)' } else { '' }))
        }
    } finally { Free-Machine; Say "mashina osvobozhdena posle raunda $r" }
}

Say 'ITOG'
$m = @{}
foreach ($arm in $arms) {
    $a = @($acc[$arm.t] | Where-Object { $null -ne $_ })
    if ($a.Count -eq 0) { Note ("{0,-16} NE IZMERENO" -f $arm.t); continue }
    $avg = ($a | Measure-Object -Average).Average
    $m[$arm.t] = $avg
    if ($a.Count -lt 2) { Note ("{0,-16} {1,6:N2} tok/s (odin progon - NE REZULTAT)" -f $arm.t, $avg); continue }
    $sp = (($a | Measure-Object -Maximum).Maximum - ($a | Measure-Object -Minimum).Minimum) / $avg
    Note ("{0,-16} {1,6:N2} tok/s (razbros {2,5:P1}, n={3})" -f $arm.t, $avg, $sp, $a.Count)
}
if ($m.ContainsKey('golova_na_karte') -and $m.ContainsKey('golova_na_hoste')) {
    $d = 100.0 * ($m['golova_na_karte'] - $m['golova_na_hoste']) / $m['golova_na_hoste']
    Note ("golova na karte protiv hosta: {0:N2} -> {1:N2} tok/s, {2:N1}%" -f
          $m['golova_na_hoste'], $m['golova_na_karte'], $d)
}
