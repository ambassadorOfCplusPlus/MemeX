# Rebuild the FULL ggml->llama->exe chain for build-wt (the 22:19 build left a stale ggml.dll vs a
# fresh llama.dll -> STATUS_ENTRYPOINT_NOT_FOUND at load), verify the exe actually LOADS, and only
# then run the dsv4 mask-sweep trace. One machine-lock acquisition for all of it. Latinica namerenno.
param(
    [string] $Dir  = 'D:/MemeX/src/ik_llama.cpp/.claude/wt_ds4gpu/build-wt',
    [int]    $Jobs = 8,
    [int]    $LockMin = 300
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
function Say($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
if (-not (Take-Machine -Who 'ds4_rebuild_trace' -TimeoutMin $LockMin)) { Say 'NE POLUCHIL MASHINU'; exit 3 }
try {
    Say "rebuild ggml -> llama -> llama-memex-fwd v $Dir"
    $t0 = Get-Date
    & cmake --build $Dir --target ggml llama llama-memex-fwd --config Release -j $Jobs 2>&1 |
        Where-Object { $_ -match 'error|Error|-> D:|memex-fwd|gpu_static|ggml\.vcxproj|llama\.vcxproj' } | Select-Object -Last 60
    $rc = $LASTEXITCODE
    Say ("sborka kod {0} za {1:N0} s" -f $rc, ((Get-Date) - $t0).TotalSeconds)
    if ($rc -ne 0) { Say 'SBORKA NE UDALAS'; exit 2 }

    $exe = Join-Path $Dir 'bin/Release/llama-memex-fwd.exe'
    Start-Sleep -Milliseconds 500
    $probe = & $exe --version 2>&1
    Say ("zapuskaemost --version: kod {0}" -f $LASTEXITCODE)
    if ($LASTEXITCODE -eq -1073741511 -or $LASTEXITCODE -eq -1073741515) {
        Say "EXE NE ZAGRUZHAETSJA (kod $LASTEXITCODE) - DLL rassoglasovany, nuzhen --clean-first"; exit 4
    }
    Say 'exe zagruzhaetsja - zapuskaju trace'
    & 'C:/Program Files/Git/bin/bash.exe' 'C:/Users/User11/Desktop/MemeX/bench/ds4_trace.sh'
    Say ("trace bash kod {0}" -f $LASTEXITCODE)
} finally { Free-Machine; Say 'zamok otpushchen' }
