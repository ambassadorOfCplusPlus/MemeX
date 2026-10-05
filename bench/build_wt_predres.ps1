# Sborka vetki agent/pred-residency v SVOJOM kataloge sborki (build-wt vnutri worktree), pod
# mashinnym zamkom. Konfiguracija - kopija build-bt2022 (VS 17 2022 x64, Vulkan cherez vcpkg,
# glslc iz Android NDK, IQK, bez curl/testov), chtoby exe byl sravnim s osnovnym bit-v-bit po
# kompiljatoru i flagam. Posle sborki - proverka zapuskaemosti (--version), kak v build_safe.ps1.
# Latinica namerenno (PowerShell chitaet fajl bez metki kak ANSI).
param(
    [string] $Src   = 'D:/MemeX/src/ik_llama.cpp/.claude/wt_predres',
    [string] $Dir   = 'D:/MemeX/src/ik_llama.cpp/.claude/wt_predres/build-wt',
    [int]    $Jobs  = 6,
    [int]    $LockMin = 480,
    [string] $Extra = '',     # dopolnitelnaja komanda pod tem zhe zamkom (naprimer simuljator)
    [switch] $Force           # vzjat svobodnyj zamok, ne gljadja na chuzhuju CPU-nagruzku (TOLKO dlja sborki:
                              # sborka - ne zamer, chuzhoj odnopotochnyj python ejo ne portit; Test-ForeignLoad
                              # inache livlochit ochered, sm. memory lock-discipline)
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
function Say($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

if ($Force) {
    $deadline = (Get-Date).AddMinutes($LockMin); $got = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-LockAlive) { Start-Sleep -Seconds 30; continue }
        try {
            $fs = [IO.File]::Open($script:MEMEX_LOCK, 'Create', 'Write', 'None')
            $bytes = [Text.Encoding]::UTF8.GetBytes("$PID|build_wt_predres(force)|" + (Get-Date -Format 'HH:mm:ss'))
            $fs.Write($bytes, 0, $bytes.Length); $fs.Close(); $script:MEMEX_HELD = $true; $got = $true; break
        } catch { Start-Sleep -Seconds 15 }
    }
    if (-not $got) { Say 'NE POLUCHIL MASHINU (force)'; exit 3 }
    Say 'zamok vzjat FORCE (chuzhaja CPU-nagruzka ignoriruetsja - eto sborka, ne zamer)'
} elseif (-not (Take-Machine -Who 'build_wt_predres' -TimeoutMin $LockMin)) { Say 'NE POLUCHIL MASHINU'; exit 3 }
try {
    # Konfiguracija KAZHDYJ raz (deshevo pri gotovom keshe): glslc iz Android NDK, na kotoryj smotrel
    # build-bt2022, s mashiny udaljon (generator shejderov padal "Failed to create process" i pisal
    # PUSTYE tablicy) - berjom glslc iz vcpkg i peredajom javno, chtoby kesh obnovilsja.
    Say "konfiguracija $Dir"
    & cmake -S $Src -B $Dir -G 'Visual Studio 17 2022' -A x64 -T host=x64 `
        -DBUILD_SHARED_LIBS=ON -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON `
        -DGGML_IQK_MUL_MAT=ON -DGGML_IQK_FLASH_ATTENTION=ON -DGGML_IQK_FA_ALL_QUANTS=ON `
        -DGGML_SCHED_MAX_COPIES=1 -DGGML_OPENMP=ON -DGGML_CCACHE=OFF -DLLAMA_CURL=OFF `
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=ON `
        -DVulkan_INCLUDE_DIR=C:/vcpkg/installed/x64-windows/include `
        -DVulkan_LIBRARY=C:/vcpkg/installed/x64-windows/lib/vulkan-1.lib `
        -DVulkan_GLSLC_EXECUTABLE=C:/vcpkg/installed/x64-windows/tools/shaderc/glslc.exe 2>&1 | Select-Object -Last 4
    if ($LASTEXITCODE -ne 0) { Say "KONFIGURACIJA NE UDALAS ($LASTEXITCODE)"; exit 2 }
    # Generator shejderov Vulkan pishet .spv v $Dir/ggml/src/vulkan-shaders.spv i NE sozdajot katalog sam:
    # bez nego glslc padaet na kazhdom shejdere, a generator molcha pishet PUSTYE tablicy (hpp 330 bajt)
    # i sborka ggml valitsja na C2065. Sozdajom katalog i vybrasyvaem pustye fajly, chtoby komanda pereshla.
    $spv = Join-Path $Dir 'ggml/src/vulkan-shaders.spv'
    if (-not (Test-Path $spv)) { New-Item -ItemType Directory -Force $spv | Out-Null; Say "sozdan $spv" }
    $hpp = Join-Path $Dir 'ggml/src/ggml-vulkan-shaders.hpp'
    if ((Test-Path $hpp) -and (Get-Item $hpp).Length -lt 10000) {
        Remove-Item -Force $hpp, (Join-Path $Dir 'ggml/src/ggml-vulkan-shaders.cpp') -ErrorAction SilentlyContinue
        Say 'udaleny pustye sgenerirovannye fajly shejderov'
    }
    Say "sborka llama-memex-fwd (-j$Jobs)"
    $t0 = Get-Date
    & cmake --build $Dir --target llama-memex-fwd --config Release -j $Jobs 2>&1 |
        Where-Object { $_ -match 'error|Error|-> D:|memex-fwd|expert_store|glslc|spv' } | Select-Object -Last 60
    $rc = $LASTEXITCODE
    Say ("sborka zavershena kod {0} za {1:N0} s" -f $rc, ((Get-Date) - $t0).TotalSeconds)
    $exe = Join-Path $Dir 'bin/Release/llama-memex-fwd.exe'
    if (Test-Path $exe) {
        $null = & $exe --version 2>&1
        Say ("zapuskaemost: kod {0}; exe {1} ({2:N1} MB, {3})" -f $LASTEXITCODE, $exe, ((Get-Item $exe).Length / 1MB), (Get-Item $exe).LastWriteTime)
    } else { Say "EXE NET: $exe" }
    if ($Extra) { Say "extra: $Extra"; Invoke-Expression $Extra }
} finally { Free-Machine }
