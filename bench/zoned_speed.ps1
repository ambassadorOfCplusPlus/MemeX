# The zoned KV cache: byte saving is measured, speed is not. This closes that gap.
#
# What is already known. The engine reports the saving from its own accounting, and it matches
# the standalone module's synthetic measurement: 1.69x at 2048 context, 1.78x at 4096, 1.86x at
# 16384, approaching Q8_0's 1.88x ceiling as the fixed exact zones shrink as a share. Token
# agreement with zoning on is 16 of 16.
#
# Why speed still has to be measured separately, and what to expect. KV is only part of the byte
# budget, so the speed gain is much smaller than the KV saving:
#
#   at  2048:  dense 841 + experts 963 + KV 201 = 2005 MB  ->  zoned 1923 MB  ->  +4%
#   at 16384:  dense 841 + experts 963 + KV 1611 = 3415 MB ->  zoned 2672 MB  ->  +28%
#
# So the honest claim is "this pays at long context and does almost nothing at short", and these
# arms are chosen to show exactly that curve rather than one flattering point. Bytes have
# converted to speed almost one-for-one everywhere else in this project (R^2 = 0.998 on the
# expert-count sweep), so a large miss against these predictions is itself the finding.

$ErrorActionPreference = 'Continue'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$E   = "$BIN\llama-memex-fwd.exe"
$LOG = 'D:\MemeX\results\zoned_speed.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$LONG = 'D:\MemeX\results\prompt_long.txt'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }
function Busy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'llama-moe-trace','memex-test','llama-memex-fwd','memex-qerr')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function WaitQuiet { $q = 0; while ($q -lt 6) { if (Busy) { $q = 0 } else { $q++ }; Start-Sleep -Seconds 30 } }

# Three replicates because four runs of one configuration measured a 4.2% coefficient of
# variation here: a single run cannot tell a 4% win from nothing, and the short-context arms are
# expected to land exactly in that band.
function Arm($label, [string[]]$extra, $limitSec) {
    if ((FreeGB) -lt 18) { Note ("{0,-34} OTKAZ: svobodno {1:N1} GB" -f $label, (FreeGB)); return }
    $vals = @()
    for ($r = 1; $r -le 3; $r++) {
        $so = 'D:\MemeX\results\_zoned_arm.out'
        $a = @('-m', $M, '-f', $LONG, '--tokens', '1400', '--gen', '64', '-t', '8', '--no-ref') + $extra
        $p = Start-Process -FilePath $E -ArgumentList $a -WindowStyle Hidden -PassThru `
                 -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        if (-not $p.WaitForExit($limitSec * 1000)) {
            Stop-Process -Id $p.Id -Force -EA SilentlyContinue
            Note ("      povtor {0}: TAJM-AUT" -f $r); continue
        }
        $out = @()
        if (Test-Path $so)       { $out += Get-Content $so -EA SilentlyContinue }
        if (Test-Path "$so.err") { $out += Get-Content "$so.err" -EA SilentlyContinue }
        $h = $out | Select-String -Pattern 'скорость генерации' | Select-Object -First 1
        if ($h -and $h.Line -match 'наш ([\d.]+)') { $vals += [double]$Matches[1] }
        elseif ($h -and $h.Line -match '([\d.]+) ток/с') { $vals += [double]$Matches[1] }
        else {
            # A run that produced no rate must say why; a silent miss reads as a zero.
            $out | Select-String -Pattern 'отвергнут|не открылся|ошибк|error|assert' |
                Select-Object -First 2 | ForEach-Object { Note ("      " + $_.Line.Trim()) }
        }
        Start-Sleep -Seconds 15
    }
    if ($vals.Count -eq 0) { Note ("{0,-34} ne izmerilos" -f $label); return }
    $mean = ($vals | Measure-Object -Average).Average
    $spread = if ($vals.Count -gt 1) {
        100.0 * (($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum) / $mean
    } else { 0 }
    Note ("{0,-34} {1:N2} tok/s  (razbros {2:N1}%, {3})" -f $label, $mean, $spread,
          (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'))
}

("`n`n######## zoned speed " + (Get-Date)) | Add-Content $LOG
Say 'gotovlju dlinnyj prompt'
# The engine truncates the prompt to --tokens, so the file only has to be long enough; built by
# repeating real source text rather than synthetic filler, because attention over repeated
# gibberish is not the attention pattern the zones are designed for.
if (-not (Test-Path $LONG)) {
    $src = @()
    foreach ($f in @('D:\MemeX\src\ik_llama.cpp\src\llama-quantize.cpp',
                     'D:\MemeX\src\ik_llama.cpp\common\speculative.cpp')) {
        if (Test-Path $f) { $src += (Get-Content $f -TotalCount 900) }
    }
    Set-Content -Path $LONG -Value ($src -join "`n") -Encoding utf8
}
Note ("prompt: {0:N0} KB" -f ((Get-Item $LONG).Length/1KB))

Say 'waiting for the machine'
WaitQuiet

# Short context first: the prediction is that zoning does nothing here, and an arm that shows a
# gain would mean the accounting is wrong somewhere.
Say 'kontekst 2048 - ozhidaetsja pochti nichego (+4%)'
Arm 'c=2048, tochnyj'  @('-c','2048','-rtr')                                  600
Arm 'c=2048, zonnyj'   @('-c','2048','-rtr','--zoned','--window','256')       600

Say 'kontekst 8192'
Arm 'c=8192, tochnyj'  @('-c','8192','-rtr')                                  900
Arm 'c=8192, zonnyj'   @('-c','8192','-rtr','--zoned','--window','256')       900

Say 'kontekst 16384 - zdes prijom i dolzhen platit (+28%)'
Arm 'c=16384, tochnyj' @('-c','16384','-rtr')                                 1200
Arm 'c=16384, zonnyj'  @('-c','16384','-rtr','--zoned','--window','256')      1200
# A tighter window compresses more of the tail: more saving, more error. The trade should be
# visible rather than assumed.
Arm 'c=16384, okno 64' @('-c','16384','-rtr','--zoned','--window','64')       1200
# f16 tail is the control: same zone machinery, no compression. If it matches the exact arm, the
# zoning code costs nothing by itself and the whole difference is the Q8_0 tail.
Arm 'c=16384, hvost f16' @('-c','16384','-rtr','--zoned','--window','256','--tail-form','f16') 1200

Say 'done'
