# A/B for the long-context cache-read fix, against the binary that has the old arithmetic.
#
# What was wrong: the K and V views took their extent from the allocation (-c), not from
# occupancy, and the mask merely zeroed the unoccupied part after the read. Output was correct;
# the bandwidth was spent anyway. At -c 16384 with 1408 positions occupied the engine moved
# 1610.6 MB of cache per token instead of 138.4 - 11.6x - and the byte-budget report inherited
# the same mistake, so the engine had been reporting the error back as if it were a fact.
#
# Predicted from the corrected budget, written down before measuring:
#   -c  2048   2.005 -> 1.942 GB/token   about +3%, i.e. inside the noise floor
#   -c  8192   2.612 -> 1.942            about +34%
#   -c 16384   3.414 -> 1.942            about +76%, so 3.13 -> roughly 5.5 tok/s
# The short arm is the control: it should show essentially nothing, and if it shows a large gain
# then something other than the fix is moving.
#
# Both binaries are built from identical source; the "before" one has aim_kv_reads forced to
# refuse, so it is the old arithmetic exactly and not an older checkout with other differences.

$ErrorActionPreference = 'Continue'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$NEW = "$BIN\llama-memex-fwd.exe"
$OLD = "$BIN\llama-memex-fwd-before.exe"
$LOG = 'D:\MemeX\results\kvread_ab.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$P   = 'D:\MemeX\results\prompt_long.txt'

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
function SiblingBusy {
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.ProcessId -eq $PID) { continue }
        $c = $p.CommandLine
        if (-not $c) { continue }
        if ($c -notmatch '-File\s+\S*bench') { continue }
        # Orchestrators never load a model themselves; they only wait for the child they started.
        # Treating one as a competitor deadlocks the child against its own parent.
        if ($c -match 'resume_all\.ps1|master\.ps1|chain\.ps1|rerun_spec\.ps1') { continue }
        return $true
    }
    return $false
}

# Three replicates: four runs of one configuration here measured a 4.2% coefficient of variation,
# so the -c 2048 arm's predicted +3% is below what a single run can resolve.
function Arm($label, $exe, $ctx) {
    if (-not (Test-Path $exe)) { Note ("{0,-30} net binarnika" -f $label); return }
    $vals = @()
    for ($r = 1; $r -le 3; $r++) {
        if ((FreeGB) -lt 18) { Note ("{0,-30} povtor {1}: OTKAZ, {2:N1} GB" -f $label, $r, (FreeGB)); continue }
        $so = 'D:\MemeX\results\_kvab.out'
        $p = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru `
                 -RedirectStandardOutput $so -RedirectStandardError "$so.err" `
                 -ArgumentList @('-m',$M,'-f',$P,'--tokens','1400','-c',"$ctx",'--gen','64',
                                 '-t','8','--no-ref','-rtr')
        if (-not $p.WaitForExit(1200 * 1000)) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue; Note ("{0,-30} povtor {1}: TAJM-AUT" -f $label, $r); continue }
        $out = @(); if (Test-Path $so) { $out += Get-Content $so }; if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
        $h = $out | Select-String -Pattern 'скорость генерации' | Select-Object -First 1
        if ($h -and $h.Line -match 'наш ([\d.]+)') { $vals += [double]$Matches[1] }
        # The budget line is the proof the fix is active in this binary, so capture it once.
        if ($r -eq 1) {
            $out | Select-String -Pattern 'занято .*читается|KV на .* позиций|итого' | Select-Object -First 3 |
                ForEach-Object { Note ("      " + $_.Line.Trim()) }
        }
        Start-Sleep -Seconds 20
    }
    if ($vals.Count -eq 0) { Note ("{0,-30} ne izmerilos" -f $label); return }
    $mean = ($vals | Measure-Object -Average).Average
    $spread = if ($vals.Count -gt 1) { 100.0*(($vals|Measure-Object -Maximum).Maximum - ($vals|Measure-Object -Minimum).Minimum)/$mean } else { 0 }
    Note ("{0,-30} {1:N2} tok/s (razbros {2:N1}%, {3})" -f $label, $mean, $spread,
          (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'))
}

("`n`n######## kv-read A/B " + (Get-Date)) | Add-Content $LOG
Say 'zhdu, poka mashina osvoboditsja polnostju'
$q = 0
$deadline = (Get-Date).AddHours(10)
while ((Get-Date) -lt $deadline) {
    if ((ModelBusy) -or (SiblingBusy) -or ((FreeGB) -lt 18)) { $q = 0 } else { $q++ }
    if ($q -ge 6) { break }
    Start-Sleep -Seconds 30
}
if ($q -lt 6) { Note 'ne dozhdalsja'; exit 1 }
Note ("start, svobodno {0:N1} GB" -f (FreeGB))

foreach ($ctx in @(2048, 8192, 16384)) {
    Say "kontekst $ctx"
    Arm "do pravki, c=$ctx"    $OLD $ctx
    Arm "posle pravki, c=$ctx" $NEW $ctx
}
Say 'done'

