# Re-runs the speculation study alone, after the machine is genuinely free.
#
# The first attempt produced nothing: every arm was refused because free memory was 15.2-16.0 GB
# against an 18 GB gate. The gate was right - mx1 with repacking needs about 16 GB resident plus
# the cache, so 15.5 GB free would have thrashed - but the scheduling was mine and it was wrong:
# the speculation study had just acquired the machine when I manually launched a second
# measurement outside the queue, and its perplexity pass took 14 GB.
#
# So this waits for BOTH conditions before starting: no model process running, and no other
# bench script alive. Checking only for model processes is what let the collision happen - a
# sibling script sitting in its own wait loop is invisible that way, and starts the moment this
# one does.

$ErrorActionPreference = 'Continue'
$LOG = 'D:\MemeX\results\rerun_spec.log'
$BENCH = 'C:\Users\User11\Desktop\MemeX\bench'

function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

function ModelBusy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'llama-moe-trace','memex-test','llama-memex-test','llama-memex-fwd',
                     'memex-qerr','llama-memex-kv')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
# Any sibling orchestrator counts, including one merely waiting: two waiters see the same silence
# and start together, which is exactly how a night's numbers were lost once already.
function SiblingBusy {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $PID) { continue }
        if ($p.CommandLine -and $p.CommandLine -match '-File\s+\S*bench' -and
            $p.CommandLine -notlike '*rerun_spec.ps1*') { return $true }
    }
    return $false
}

Note 'zhdu: ni odnoj modeli i ni odnogo drugogo skripta'
$quiet = 0
$deadline = (Get-Date).AddHours(8)
while ((Get-Date) -lt $deadline) {
    if ((ModelBusy) -or (SiblingBusy)) { $quiet = 0 } else { $quiet++ }
    if ($quiet -ge 8) { break }          # four consecutive quiet minutes
    Start-Sleep -Seconds 30
}
if ((ModelBusy) -or (SiblingBusy)) {
    Note 'tak i ne osvobodilos za 8 chasov - vyhozhu, nichego ne izmeriv'
    exit 1
}
Note ("svobodno: RAM {0:N1} GB" -f (FreeGB))
if ((FreeGB) -lt 18) {
    Note 'pamjati vsjo ravno menshe 18 GB - zamer byl by musorom, vyhozhu'
    exit 1
}

Note 'zapuskaju izuchenie spekuljacii'
& pwsh -NoProfile -NonInteractive -File "$BENCH\spec_study.ps1" 2>&1 | Out-Null
Note 'gotovo'
