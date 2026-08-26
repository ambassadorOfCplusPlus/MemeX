# The draft model measured on its own, to find out where its 22.3 ms per pass goes.
#
# Why this is the decisive missing measurement. Inside speculation the 0.6B Q4 draft costs 22.3 ms
# per predicted token. Its file is 378 MB, which at the machine's 24.8 GB/s is 15.2 ms - so it is
# running at about 17 GB/s, 68% of the roofline. And the break-even arithmetic says speculation
# pays as soon as the draft costs under 18.3 ms:
#
#   marginal cost of one more verified position at the target   25.0 ms
#   one draft pass                                              22.3 ms
#   it yields                                                   0.609 accepted tokens
#   -> 77.8 ms per accepted token against a 71.2 ms baseline
#
# So a draft at full bandwidth (15.2 ms) would cross break-even by itself, with no change to
# acceptance. That makes "why is the draft at 68% of roofline" worth more than any parameter sweep.
#
# Two candidate causes, and they need different fixes:
#   - inherent: a 0.6B model has small layers, so per-layer thread synchronisation is a larger
#     share of its time; then fewer threads may be faster and the fix is -td.
#   - harness: the speculation loop adds per-call cost the standalone run does not have; then the
#     fix is in the loop, not the thread count.
# Running the draft standalone across thread counts separates them: if the standalone best matches
# 22.3 ms, the cost is inherent; if standalone is much faster, the harness is responsible.

$ErrorActionPreference = 'Continue'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\draft_alone.log'
$DR4 = 'D:\smartstock\models\qwen3-0.6b-q4_k_m.gguf'
$DR3 = 'D:\qwen3-0.6b-iq3.gguf'
$P   = 'D:\MemeX\results\prompt_short.txt'
$BW  = 24.8

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }
function ModelBusy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix','llama-moe-trace',
                     'memex-test','llama-memex-test','llama-memex-fwd','memex-qerr','llama-memex-kv')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# Two readings a minute apart. Requiring six consecutive readings never converged on a machine
# that was in fact free, because Windows' reported free memory fluctuates.
Say 'zhdu mashinu'
$q = 0
$deadline = (Get-Date).AddHours(8)
while ((Get-Date) -lt $deadline) {
    if ((ModelBusy) -or ((FreeGB) -lt 6)) { $q = 0 } else { $q++ }
    if ($q -ge 2) { break }
    Start-Sleep -Seconds 60
}
if ($q -lt 2) { Note 'ne dozhdalsja'; exit 1 }
Note ("start, svobodno {0:N1} GB" -f (FreeGB))

# The draft is 378 MB, so it fits several times over and needs no memory gate of its own.
function Arm($label, $model, $threads, [string[]]$extra) {
    if (-not (Test-Path $model)) { Note ("{0,-34} net fajla" -f $label); return }
    $mb = (Get-Item $model).Length / 1MB
    $vals = @()
    for ($r = 1; $r -le 3; $r++) {
        $so = 'D:\MemeX\results\_draft.out'
        $a = @('-m', $model, '-f', $P, '-n', '256', '-c', '2048', '-t', "$threads",
               '-ngl', '0', '-fa', 'off', '--seed', '1', '--no-display-prompt') + $extra
        $proc = Start-Process -FilePath "$BIN\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        if (-not $proc.WaitForExit(300 * 1000)) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; continue }
        $out = @(); if (Test-Path $so) { $out += Get-Content $so }; if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
        $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($h -and $h.Line -match '([\d.]+) tokens per second') { $vals += [double]$Matches[1] }
        Start-Sleep -Seconds 5
    }
    if ($vals.Count -eq 0) { Note ("{0,-34} ne izmerilos" -f $label); return }
    $mean = ($vals | Measure-Object -Average).Average
    $ms = 1000.0 / $mean
    $gbs = $mb / 1024.0 / ($ms / 1000.0)
    $spread = 100.0*(($vals|Measure-Object -Maximum).Maximum - ($vals|Measure-Object -Minimum).Minimum)/$mean
    Note ("{0,-34} {1,7:N2} tok/s = {2,5:N1} ms/tok = {3,5:N1} GB/s ({4,4:N0}% polki, razbros {5:N1}%)" -f `
          $label, $mean, $ms, $gbs, (100*$gbs/$BW), $spread)
}

Say 'chernovik 0.6B Q4 (378 MB) po chislu potokov'
# Inside speculation this same model costs 22.3 ms per pass. If none of these reaches that, the
# harness is adding the difference; if the best one lands near it, the cost is the model's own.
foreach ($t in 1, 2, 3, 4, 6, 8) { Arm "0.6B Q4, t=$t" $DR4 $t @() }
Say 'to zhe s perepakovkoj - ona bit-tochna, tak chto eto besplatno po kachestvu'
foreach ($t in 2, 4, 8) { Arm "0.6B Q4, t=$t, rtr" $DR4 $t @('-rtr') }
Say 'IQ3 (292 MB) - on terjal prijomku, no zdes vazhna tolko ego cena'
foreach ($t in 4, 8) { Arm "0.6B IQ3, t=$t, rtr" $DR3 $t @('-rtr') }

Note ''
Note 'dlja sravnenija: vnutri spekuljacii etot chernovik stoit 22.3 ms na prohod,'
Note 'a porog okupaemosti spekuljacii - 18.3 ms. Polka dlja 378 MB = 15.2 ms.'
Say 'done'
