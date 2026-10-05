# Build the wt_ds4gpu chain AND run the N=18 verification WITHIN ONE lock hold - other agents
# delete/rebuild DLLs whenever the lock is free, so a build in one lock and a run in the next races
# a missing-DLL load failure. Robust launch retry (DLL writes settle a beat after link). Latinica.
param(
    [string] $Src  = 'D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu',
    [string] $Dir  = 'D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt',
    [int]    $Jobs = 8,
    [int]    $LockMin = 300,
    [switch] $Clean
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
function Say($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
if (-not (Take-Machine -Who 'ds4_build_verify' -TimeoutMin $LockMin)) { Say 'NE POLUCHIL MASHINU'; exit 3 }
try {
    $t0 = Get-Date
    if ($Clean) {
        Say "CLEAN rebuild ggml -> llama -> llama-memex-fwd"
        & cmake --build $Dir --target ggml llama llama-memex-fwd --config Release -j $Jobs --clean-first 2>&1 |
            Where-Object { $_ -match 'error C|Error|LNK|fatal' } | Select-Object -Last 40
    } else {
        Say "rebuild ggml -> llama -> llama-memex-fwd"
        & cmake --build $Dir --target ggml llama llama-memex-fwd --config Release -j $Jobs 2>&1 |
            Where-Object { $_ -match 'error C|Error|LNK|fatal' } | Select-Object -Last 40
    }
    $rc = $LASTEXITCODE
    Say ("sborka kod {0} za {1:N0} s" -f $rc, ((Get-Date) - $t0).TotalSeconds)
    if ($rc -ne 0) { Say 'SBORKA NE UDALAS'; exit 2 }

    $exe = Join-Path $Dir 'bin/Release/llama-memex-fwd.exe'
    $loaded = $false
    for ($i = 1; $i -le 8; $i++) {
        Start-Sleep -Seconds 2
        $null = & $exe --version 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) { $loaded = $true; Say "exe zagruzhaetsja (popytka $i)"; break }
        Say ("popytka {0}: --version kod {1}" -f $i, $code)
    }
    if (-not $loaded) { Say 'EXE NE ZAGRUZHAETSJA posle 8 popytok - DLL problema'; exit 4 }

    Say 'zapuskaju N=18 verifikaciju (bash)'
    & 'C:/Program Files/Git/bin/bash.exe' 'C:/Users/User11/Desktop/MemeX/bench/ds4_verify.sh'
    Say ("verify bash kod {0}" -f $LASTEXITCODE)
} finally { Free-Machine; Say 'zamok otpushchen' }
