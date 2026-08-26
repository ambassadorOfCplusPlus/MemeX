# The reference table for the 30B, measured once, cleanly, under the machine lock.
#
# Why this needs doing before anything else on this model. Every conclusion about the 30B is a
# comparison against a baseline, and the baseline currently has two values: 13.38 tok/s and
# 14.04, taken at different times under unknown company. That is a 5% disagreement, and 5% is
# exactly the size of the wins and losses being argued about - the GPU expert path has to beat
# this number, and the quality-band candidate has to be compared against it. A reference with a
# 5% ambiguity cannot settle either question.
#
# So: every arm three times, one owner of the machine, nothing else running. The lock is used
# rather than a free-memory check because four different resource checks each caught the previous
# collision and missed the next - most recently two processes of 7 and 15 GB both passing an
# 18 GB gate honestly, which put 26% of spread into the speculation depth arms.
#
# What is being fixed here, stated plainly: the numbers this table replaces were not wrong
# measurements, they were measurements of an unknown machine state.

$ErrorActionPreference = 'Continue'
. 'C:\Users\User11\Desktop\MemeX\bench\lock.ps1'

$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\ref30b.log'
$P   = 'D:\MemeX\results\prompt_short.txt'
$TEXT = 'D:\MemeX\data\calibration.txt'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

function Speed($label, $model, [string[]]$extra) {
    if (-not (Test-Path -LiteralPath $model)) { Note ("{0,-30} net fajla" -f $label); return }
    $vals = @()
    for ($r = 1; $r -le 3; $r++) {
        # A separate output path per replicate. This was first written believing a shared file was
        # what killed replicates 2 and 3; it was not - the cause was the $P/$p collision noted
        # below, and spec_study.ps1 shares one file across three replicates quite happily. Kept
        # anyway because distinct files make a failed replicate diagnosable after the fact.
        $so = 'D:\MemeX\results\_ref' + "_$r.out"
        $a = @('-m', $model, '-f', $P, '-n', '256', '-c', '2048', '-t', '8', '-ngl', '0',
               '-fa', 'off', '--seed', '1', '--no-display-prompt') + $extra
        $proc = Start-Process -FilePath "$BIN\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        if (-not $proc.WaitForExit(600 * 1000)) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; continue }
        $out = @(); if (Test-Path $so) { $out += Get-Content $so }; if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
        $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($h -and $h.Line -match '([\d.]+) tokens per second') { $vals += [double]$Matches[1] }
        Start-Sleep -Seconds 15
    }
    if ($vals.Count -eq 0) { Note ("{0,-30} ne izmerilos" -f $label); return }
    # A lone replicate has nothing to disagree with, so its 0.0% spread is not evidence of a quiet
    # machine - it is the absence of the check. Named rather than reported.
    if ($vals.Count -lt 2) {
        Note ("{0,-30} {1,6:N2} tok/s  <<< tolko 1 povtor - ne rezultat" -f $label, $vals[0])
        return
    }
    $mean = ($vals | Measure-Object -Average).Average
    $spread = 100.0*(($vals|Measure-Object -Maximum).Maximum - ($vals|Measure-Object -Minimum).Minimum)/$mean
    # A spread above the 4.2% noise floor means the arm is not usable as a reference, so say it
    # rather than letting a mean stand in for three disagreeing numbers.
    $flag = if ($spread -gt 4.2) { '  <<< razbros vyshe shuma, ne opornoe' } else { '' }
    Note ("{0,-30} {1:N2} tok/s (razbros {2:N1}%, {3}){4}" -f $label, $mean, $spread,
          (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'), $flag)
}

function Ppl($label, $model) {
    if (-not (Test-Path -LiteralPath $model)) { Note ("{0,-30} net fajla" -f $label); return }
    $out = & "$BIN\llama-perplexity.exe" -m $model -f $TEXT -c 512 --chunks 16 -t 8 -ngl 0 -fa off -rtr 2>&1
    $h = $out | Select-String -Pattern 'Final estimate' | Select-Object -First 1
    if ($h -and $h.Line -match '= ([\d.]+) \+/-') {
        $v = [double]$Matches[1]
        Note ("{0,-30} ppl {1}  ({2:+0.00;-0.00}% ot 2.1121)" -f $label, $v, (100.0*($v-2.1121)/2.1121))
    } else { Note ("{0,-30} ppl ne poschitalas" -f $label) }
    Start-Sleep -Seconds 15
}

("`n`n######## reference 30B " + (Get-Date)) | Add-Content $LOG
Say 'berjom mashinu'
if (-not (Take-Machine -Who 'ref30b' -TimeoutMin 480 -MinFreeGB 18)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))

try {
    $MX1  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
    $MX9  = 'D:\Qwen3-Coder-30B-A3B-mx9.gguf'
    $MX10 = 'D:\Qwen3-Coder-30B-A3B-mx10-xs.gguf'
    $Q6   = 'D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf'

    Say 'skorost, 3 povtora, t=8, s perepakovkoj'
    Speed 'mx1  (4 bita, IQ4_KS)'  $MX1  @('-rtr')
    Speed 'mx9  (5 bit)'           $MX9  @('-rtr')
    Speed 'mx10 (4 bita, IQ4_XS)'  $MX10 @('-rtr')
    # Q6 cannot be repacked - 24.5 GB does not fit resident - so it is measured as it can run.
    Speed 'Q6_K (mmap, bez rtr)'   $Q6   @()

    Say 'to zhe bez perepakovki - eto ta baza, s kotoroj startuet put cherez kartu'
    Speed 'mx10 bez rtr'           $MX10 @()
    Speed 'mx1  bez rtr'           $MX1  @()

    Say 'kachestvo, tot zhe tekst i te zhe nastrojki'
    Ppl 'mx1'  $MX1
    Ppl 'mx9'  $MX9
    Ppl 'mx10' $MX10

    Say 'itog'
    Note 'mx1 - to, chto put cherez kartu objazan pobit s perepakovkoj;'
    Note 'mx10 bez rtr - to, s chego on faktichesky startuet, poka razvjazka ne sdelana.'
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
