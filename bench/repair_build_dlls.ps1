# Put ggml.dll and llama.dll back in D:\MemeX\src\ik_llama.cpp\build\bin\Release, and prove the
# tree starts before handing the machine back.
#
# WHAT WAS ACTUALLY FOUND, because the diagnosis changes the remedy.
#
# The tree is not mysteriously missing two files; it is stopped mid-build. The evidence, all of
# it read off the tree before anything was rebuilt:
#
#   build/ggml/Release            gone entirely (ggml.lib, ggml.exp)
#   build/ggml/ggml.dir           gone entirely (every object file, and the tlog directory)
#   build/src/Release/llama.exp   27 Aug 08:54   - written by a link that started
#   build/src/Release/llama.lib   26 Aug 20:33   - NOT written by it
#   build/src/llama.dir/Release/llama.tlog/unsuccessfulbuild   present
#   build/bin/Release             ggml.dll and llama.dll absent; every .exe still there
#
# `unsuccessfulbuild` is the marker MSBuild leaves when a link does not complete, and a fresh
# .exp beside a stale .lib is the fingerprint of the same thing. So a build in this tree was
# cleaned and then interrupted before it relinked.
#
# That matters for the remedy. The reason `--clean-first` was needed the previous two times is
# that MSBuild decides freshness from the tlog directory rather than from whether the output
# exists, so an ordinary rebuild was a no-op. Here the tlog directory and every object file are
# ALREADY gone, so there is nothing left to be falsely fresh: a plain build has to recompile
# ggml from nothing whatever it thinks. `--clean-first` would additionally wipe llama, common
# and all forty examples and cost the machine another twenty minutes for no change in outcome.
#
# So: try the plain build first, and fall back to --clean-first only if the DLLs do not appear.
# That fallback is not optional politeness - it is what makes the cheap path safe to try.
#
# llama-memex-fwd is rebuilt too, and non-fatally. It belongs to another agent and may be
# mid-edit, so a compile error there must not be reported as a failed repair; but leaving a
# stale exe beside a fresh ggml.dll is exactly the -1073741511 mismatch this whole script
# exists to prevent, so it is attempted rather than skipped.

param(
    [int]$TimeoutMin = 120,
    [string]$BuildDir = 'D:/MemeX/src/ik_llama.cpp/build',
    [int]$Jobs = 8
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
. 'C:/Users/User11/Desktop/MemeX/bench/tree_check.ps1'

$BIN = Join-Path $BuildDir 'bin/Release'
$LOG = 'D:\MemeX\results\repair_build.log'

function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

("`n`n######## repair build DLLs " + (Get-Date)) | Add-Content $LOG

Note 'sostojanie DO remonta:'
$null = Test-TreeStartable -Dir $BIN -Exes @('llama-cli.exe')

if (-not (Take-Machine -Who 'gpu-static-repair' -TimeoutMin $TimeoutMin)) {
    Note 'mashinu ne poluchili'
    exit 3
}
Note ('vladeem: ' + (Get-LockHolder))

$code = 0
try {
    Push-Location $BuildDir
    Note '--- ggml + llama + llama-cli (bez --clean-first: tlog i obektov i tak net) ---'
    $t0 = Get-Date
    & cmake --build . --config Release --target ggml llama llama-cli -j $Jobs -- /nologo /v:m 2>&1 |
        Tee-Object -FilePath D:/MemeX/results/repair_build_msbuild.log
    $bc = $LASTEXITCODE
    Note ("cmake exit {0} za {1:N1} min" -f $bc, ((Get-Date) - $t0).TotalMinutes)
    Pop-Location

    $ok = Test-TreeStartable -Dir $BIN -Exes @('llama-cli.exe')
    if (-not $ok) {
        Note '--- ne pomoglo: povtorjaem s --clean-first, kak v proshlye dva raza ---'
        Push-Location $BuildDir
        $t1 = Get-Date
        & cmake --build . --config Release --target ggml -j $Jobs --clean-first -- /nologo /v:m 2>&1 |
            Tee-Object -FilePath D:/MemeX/results/repair_build_msbuild.log -Append
        & cmake --build . --config Release --target llama llama-cli -j $Jobs -- /nologo /v:m 2>&1 |
            Tee-Object -FilePath D:/MemeX/results/repair_build_msbuild.log -Append
        Note ("clean-first za {0:N1} min" -f ((Get-Date) - $t1).TotalMinutes)
        Pop-Location
        $ok = Test-TreeStartable -Dir $BIN -Exes @('llama-cli.exe')
    }
    if (-not $ok) { $code = 1 }

    # Non-fatal on purpose - see the header. A stale llama-memex-fwd.exe beside a fresh
    # ggml.dll is the -1073741511 mismatch, so it is attempted; but its source belongs to
    # somebody else and a compile error there is their news, not a failed repair.
    Note '--- llama-memex-fwd (nefatalno: ischodnik chuzhoj) ---'
    Push-Location $BuildDir
    & cmake --build . --config Release --target llama-memex-fwd -j $Jobs -- /nologo /v:m 2>&1 |
        Tee-Object -FilePath D:/MemeX/results/repair_build_msbuild.log -Append |
        Select-Object -Last 6 | ForEach-Object { Note $_ }
    $mc = $LASTEXITCODE
    Pop-Location
    Note "llama-memex-fwd exit $mc"

    Note 'sostojanie POSLE remonta:'
    $null = Test-TreeStartable -Dir $BIN -Exes @('llama-cli.exe', 'llama-memex-fwd.exe')
} finally {
    Free-Machine
    Note ('lock posle: ' + (Get-LockHolder))
}
exit $code
