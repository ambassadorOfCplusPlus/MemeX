# Waits for the overnight pipeline to finish, writes a morning report, then suspends the machine.
#
# The guard that matters: sleeping the PC is irreversible for the night, so this does NOT sleep
# merely because nothing is running. A crashed pipeline and a finished pipeline look identical
# from the outside - both are quiet - and sleeping on the first would waste the whole night. So
# the pipeline must either report 'done' in its log, or fail twice after being relaunched.
#
# ASCII only and no fork: the sh version of the pipeline died on Cygwin fork exhaustion with
# several agents running, and a previous .ps1 in this project failed to parse as UTF-8 without
# BOM under PS 5.

$ErrorActionPreference = 'Continue'

$LOG      = 'D:\MemeX\results\night.log'
$PIPELINE = 'C:\Users\User11\Desktop\MemeX\bench\night.ps1'
$REPORT   = 'D:\MemeX\results\MORNING.md'
$WLOG     = 'D:\MemeX\results\watchdog.log'
$CAMPAIGN = 'C:\Users\User11\AppData\Local\Temp\claude\C--Users-User11-Desktop-MemeX\92fae5ff-a063-4f06-8f6a-e20dd30bc20c\tasks\brovgu91k.output'

function Log($m) {
    "[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m | Add-Content -Path $WLOG
}

function PipelineRunning {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.CommandLine -and $p.CommandLine -like '*night.ps1*') { return $true }
    }
    return $false
}

function WorkRunning {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'memex-fwd','memex-qerr','memex-hyb')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function PipelineDone {
    if (-not (Test-Path $LOG)) { return $false }
    return [bool](Select-String -Path $LOG -Pattern '=====\s+done' -Quiet -ErrorAction SilentlyContinue)
}

Log 'watchdog started'

$restarts = 0
while ($true) {
    if (PipelineDone) { Log 'pipeline reported done'; break }

    if (-not (PipelineRunning)) {
        # Quiet for a while and no pipeline process: either it crashed or it never started.
        # Give it two more chances before accepting that the night is over, because losing the
        # night to a silent crash costs far more than a redundant relaunch.
        if (-not (WorkRunning)) {
            if ($restarts -lt 2) {
                $restarts++
                Log "pipeline gone without 'done' - relaunch attempt $restarts"
                Start-Process -FilePath 'pwsh' `
                    -ArgumentList '-NoProfile','-NonInteractive','-File',$PIPELINE `
                    -RedirectStandardOutput 'D:\MemeX\results\night_stdout.log' `
                    -RedirectStandardError  'D:\MemeX\results\night_stderr.log' `
                    -WindowStyle Hidden | Out-Null
                Start-Sleep -Seconds 120
            } else {
                Log 'pipeline failed twice - giving up and going to sleep'
                break
            }
        }
    }
    Start-Sleep -Seconds 60
}

# Do not suspend while anything is still writing a 17 GB file.
Log 'waiting for the last processes to exit'
$quiet = 0
while ($quiet -lt 5) {
    if (WorkRunning -or (PipelineRunning)) { $quiet = 0 } else { $quiet++ }
    Start-Sleep -Seconds 60
}

# ------------------------------------------------------------------ morning report
$lines = @()
$lines += "# Otchet za noch ({0})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')
$lines += ''
$lines += 'Vse cifry - iz D:\MemeX\results\night.log. Reference: Q6_K_XL ppl 2.1236, budzhet +2%.'
$lines += ''
$lines += '## Nochnoj konvejer'
$lines += ''
$lines += '```'
if (Test-Path $LOG) {
    $lines += (Get-Content $LOG | Select-String -Pattern '=====|ppl |tok/s|/ 48|size:|tensors with|model:|prefill' |
               ForEach-Object { $_.Line })
} else {
    $lines += 'night.log otsutstvuet'
}
$lines += '```'
$lines += ''
$lines += '## Kampanija (chernovik, flagi, KV, prefill)'
$lines += ''
$lines += '```'
if (Test-Path $CAMPAIGN) {
    $lines += (Get-Content $CAMPAIGN | Select-String -Pattern '=====|tokens per second|Final estimate|MB|gotovo|matrica' |
               ForEach-Object { $_.Line })
} else {
    $lines += 'vyvod kampanii nedostupen'
}
$lines += '```'
$lines += ''
$lines += '## Fajly modelej'
$lines += ''
$lines += '```'
$lines += (Get-ChildItem 'D:\*.gguf' -ErrorAction SilentlyContinue |
           Sort-Object Name |
           ForEach-Object { "{0,-52} {1,7:N2} GB" -f $_.Name, ($_.Length / 1GB) })
$lines += '```'
$lines += ''
$lines += '## Svobodnoe mesto'
$lines += ''
$lines += '```'
$lines += (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -in @('C','D') } |
           ForEach-Object { "{0}: svobodno {1:N1} GB" -f $_.Name, ($_.Free / 1GB) })
$lines += '```'

Set-Content -Path $REPORT -Value $lines -Encoding utf8
Log "report written to $REPORT"

# ------------------------------------------------------------------ suspend
Log 'suspending'
Start-Sleep -Seconds 5
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    # Suspend, not Hibernate; do not force, do not disable wake events.
    [System.Windows.Forms.Application]::SetSuspendState(
        [System.Windows.Forms.PowerState]::Suspend, $false, $false) | Out-Null
    Log 'SetSuspendState returned'
} catch {
    Log "WinForms path failed: $_ - falling back to rundll32"
    & rundll32.exe powrprof.dll,SetSuspendState 0,1,0
}
