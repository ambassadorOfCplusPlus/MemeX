# Waits for the GPU retry to finish, then hands the machine to the main queue and the downloads.
#
# Chained rather than run in parallel because the GPU retry is the highest-value measurement
# open right now - it decides whether the whole card direction was closed on a misdiagnosis -
# and because two 15 GB models in 32 GB is how a previous night's numbers were destroyed.
#
# Detection is by process, not by log content: gpu_retry.ps1 writes its own log and a crash
# would leave the last line looking like progress. A pwsh whose command line names the script
# is the only signal that cannot lie about whether it is still running.

$ErrorActionPreference = 'Continue'
$LOG = 'D:\MemeX\results\chain.log'
$BENCH = 'C:\Users\User11\Desktop\MemeX\bench'

function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }

function Running($needle) {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $PID) { continue }
        if ($p.CommandLine -and $p.CommandLine -like "*$needle*") { return $true }
    }
    return $false
}

Note 'zhdu okonchanija gpu_retry'
$deadline = (Get-Date).AddHours(6)
while ((Get-Date) -lt $deadline) {
    if (-not (Running 'gpu_retry.ps1')) { break }
    Start-Sleep -Seconds 60
}
if (Running 'gpu_retry.ps1') {
    Note 'gpu_retry idjot bolshe 6 chasov - zapuskaju ochered vsjo ravno, ona sama zhdjot tishiny'
} else {
    Note 'gpu_retry zavershjon'
}

Note 'zapuskaju ochered i zagruzki'
Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile','-NonInteractive','-File',"$BENCH\master.ps1" `
    -RedirectStandardOutput 'D:\MemeX\results\master_out.log' `
    -RedirectStandardError  'D:\MemeX\results\master_err.log' -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 10
Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile','-NonInteractive','-File',"$BENCH\dl_chain.ps1" `
    -RedirectStandardOutput 'D:\MemeX\results\dl_chain_out.log' `
    -RedirectStandardError  'D:\MemeX\results\dl_chain_err.log' -WindowStyle Hidden | Out-Null
Note 'peredano'
