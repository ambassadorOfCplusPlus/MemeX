# Gemma 4: the DENSE feed-forward half on the card, against the same run without it.
#
# WHY IT SHOULD PAY. gemma4 runs a dense feed-forward on every token beside the routed one:
# 3 x 2816 x 2112 per layer at q8_0, thirty layers, 569 MB read from host RAM EVERY token -
# 22.9 ms of an 86.6 ms token. Unlike an expert it is read whether or not any router picks it,
# which makes it the most predictable traffic in the model and the best MiB-for-MiB resident:
#
#     golova        748 MiB -> 31,6 ms of CPU read saved = 0,042 ms/MiB
#     plotnaja FFN  542 MiB -> 22,9 ms                    = 0,042 ms/MiB
#     eksperty C=7  748 MiB -> 12,3 ms (38,6% popadanij)  = 0,016 ms/MiB
#
# WHY THIS IS AN A/B AND NOT TWO RUNS. The first attempt measured one arm each and got 13,36
# against 7,58 - and the same control had given 10,51 and 11,54 on earlier identical runs. A
# spread of 52% on an unchanged configuration cannot measure a 15% effect. Worse, the two
# controls that differed ONLY in whether the (unused) reference context was allocated came out
# 7,58 and 11,54, with the one holding an extra 1265 MiB the FASTER of the two - which is not a
# mechanism, it is noise wearing a mechanism's clothes.
#
# So: both arms inside one lock acquisition, alternating, several rounds, spread reported. A
# single number from this configuration is not a result and the summary says so when n < 2.
param(
    [int]    $Reps    = 3,
    [int]    $Tokens  = 256,
    [int]    $Ngen    = 64,
    [int]    $Threads = 8,
    [string] $Prompt  = 'D:\MemeX\results\prompt_2000.txt'
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'
$LOG   = 'D:\MemeX\results\gemma_dense_ab.log'
$OUT   = 'D:\MemeX\results'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

foreach ($f in @($EXE, $MODEL, $Prompt)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "NET FAJLA: $f"; exit 4 }
}

function RunOnce {
    param([string]$Tag, [string[]]$Extra, [int]$LimitSec)
    $log = Join-Path $OUT "_gd_$Tag.out"
    $err = "$log.err"
    $a = @('-m', $MODEL, '-f', $Prompt, '--tokens', "$Tokens", '--gen', "$Ngen",
           '-t', "$Threads", '--no-repack', '--no-ref') + $Extra
    $cmdline = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" } }) -join ' '
    $proc = Start-Process -FilePath $EXE -ArgumentList $cmdline -NoNewWindow -PassThru `
                          -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitSec * 1000)) { try { $proc.Kill($true) } catch { }; return @{ err = 'tajm-aut' } }
    $res = @{ err = '' }
    $code = $proc.ExitCode
    if ($null -eq $code) { $code = -2 }
    if ($code -ne 0 -and $code -ne 2) { $res.err = "kod vyhoda $code"; return $res }
    $txt = Get-Content -LiteralPath $log -EA SilentlyContinue
    $g = $txt | Select-String -Pattern 'our_tok_s ([\d.]+)' | Select-Object -First 1
    if ($g -and $g.Line -match 'our_tok_s ([\d.]+)') { $res.gen = [double]$Matches[1] }
    # Rule 68: the arm says which arm it is. The card prints how many MiB it holds, and the two
    # arms differ by the dense half's 542 MiB - a fact from the engine, not from the flags.
    $v = $txt | Select-String -Pattern 'vsego ([\d.,]+) MiB v videopamjati' | Select-Object -First 1
    if ($v -and $v.Line -match 'vsego ([\d.,]+) MiB') { $res.vram = [double](($Matches[1]) -replace ',', '.') }
    $l = $txt | Select-String -Pattern 'na tokjen ([\d.,]+) ms' | Select-Object -First 1
    if ($l -and $l.Line -match 'na tokjen ([\d.,]+) ms') { $res.layer = [double](($Matches[1]) -replace ',', '.') }
    return $res
}

$arms = @(
    @{ t = 'dense_na_karte'; x = @('--gpu-static-dense')  },
    @{ t = 'dense_na_cpu';   x = @('--gpu-static-layers') }
)
$acc = @{}
foreach ($arm in $arms) { $acc[$arm.t] = @{ gen = @(); vram = @(); layer = @() } }

("`n`n######## plotnaja FFN na karte " + (Get-Date)) | Add-Content $LOG
Say 'PREDSKAZANIE (do progona): plotnaja polovina snimaet ~22,9 ms hostovogo chtenija i dobavljaet ~4,3 ms chtenija iz videopamjati, to est 86,6 -> ~68 ms, okolo 14,5 tok/s. Karta pri etom dolzhna derzhat na 542 MiB bolshe.'

for ($r = 1; $r -le $Reps; $r++) {
    Say "berjom mashinu pod raund $r"
    if (-not (Take-Machine -Who 'gemma_dense' -TimeoutMin 240)) { Note 'mashinu ne poluchili'; exit 3 }
    try {
        # Alternating order between rounds, so a drift in the machine cannot land on one arm.
        $order = if ($r % 2 -eq 1) { $arms } else { $arms[1], $arms[0] }
        foreach ($arm in $order) {
            $res = RunOnce "$($arm.t)_$r" $arm.x 1800
            if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
            if (-not $res.ContainsKey('gen')) { Note ("raund ${r} $($arm.t): tok/s ne prochitan - vybrosheno"); continue }
            $acc[$arm.t].gen   += $res.gen
            if ($res.ContainsKey('vram'))  { $acc[$arm.t].vram  += $res.vram }
            if ($res.ContainsKey('layer')) { $acc[$arm.t].layer += $res.layer }
            Note ("raund {0} {1,-15} tok/s {2,6:N2}   na karte {3,7:N1} MiB   sloj {4,6:N2} ms" -f
                  $r, $arm.t, $res.gen,
                  $(if ($res.vram)  { $res.vram }  else { 0 }),
                  $(if ($res.layer) { $res.layer } else { 0 }))
        }
    } finally { Free-Machine; Say "mashina osvobozhdena posle raunda $r" }
}

Say 'ITOG'
function Summ($name, $v, $unit) {
    $a = @($v | Where-Object { $null -ne $_ })
    if ($a.Count -eq 0) { return ("{0,-24} NE IZMERENO" -f $name) }
    $m = ($a | Measure-Object -Average).Average
    if ($a.Count -lt 2) { return ("{0,-24} {1,7:N2} $unit (odin progon - NE REZULTAT)" -f $name, $m) }
    $sp = (($a | Measure-Object -Maximum).Maximum - ($a | Measure-Object -Minimum).Minimum) / $m
    return ("{0,-24} {1,7:N2} $unit (razbros {2,5:P1}, n={3})" -f $name, $m, $sp, $a.Count)
}
$m = @{}
foreach ($arm in $arms) {
    Note (Summ "$($arm.t) tok/s"    $acc[$arm.t].gen   '')
    Note (Summ "$($arm.t) na karte" $acc[$arm.t].vram  'MiB')
    Note (Summ "$($arm.t) sloj"     $acc[$arm.t].layer 'ms')
    $a = @($acc[$arm.t].gen | Where-Object { $null -ne $_ })
    if ($a.Count -ge 2) { $m[$arm.t] = ($a | Measure-Object -Average).Average }
}
if ($m.Count -eq 2) {
    $d = 100.0 * ($m['dense_na_karte'] - $m['dense_na_cpu']) / $m['dense_na_cpu']
    Note ("plotnaja FFN na karte protiv processora: {0:N2} -> {1:N2} tok/s, {2:N1}%" -f
          $m['dense_na_cpu'], $m['dense_na_karte'], $d)
    # The spread has to be smaller than the effect or the comparison says nothing. Said here
    # rather than left for the reader, because the first attempt at this measurement had a 52%
    # spread on an unchanged configuration and looked like a result.
    $sa = @($acc['dense_na_karte'].gen); $sb = @($acc['dense_na_cpu'].gen)
    $wa = (($sa | Measure-Object -Maximum).Maximum - ($sa | Measure-Object -Minimum).Minimum) / $m['dense_na_karte']
    $wb = (($sb | Measure-Object -Maximum).Maximum - ($sb | Measure-Object -Minimum).Minimum) / $m['dense_na_cpu']
    $worst = [Math]::Max($wa, $wb)
    if ([Math]::Abs($d) -lt 100.0 * $worst) {
        Note ("RAZBROS {0:P1} BOLSHE EFFEKTA {1:N1}% - eto NE REZULTAT, nuzhno bolshe povtorov" -f $worst, $d)
    } else {
        Note ("razbros {0:P1} menshe effekta {1:N1}% - sravnenie godno" -f $worst, $d)
    }
} else { Note 'menshe dvuh povtorov hotja by v odnom pleche - NE REZULTAT' }
