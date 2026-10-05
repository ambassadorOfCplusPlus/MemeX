# Sborka vetki consolidation v SVOJOM kataloge sborki (build-wt vnutri worktree wt_consol), pod
# mashinnym zamkom. Kopija konfiguracii build_wt_chat.ps1 (VS 17 2022 x64, Vulkan cherez
# vcpkg, glslc iz vcpkg, IQK, bez curl/testov). Latinica namerenno (PowerShell chitaet fajl
# bez metki kak ANSI).
param(
    [string] $Src   = 'D:/MemeX/src/ik_llama.cpp/.claude/wt_consol',
    [string] $Dir   = 'D:/MemeX/src/ik_llama.cpp/.claude/wt_consol/build-wt',
    [int]    $Jobs  = 8,
    [int]    $LockMin = 240
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
function Say($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

if (-not (Take-Machine -Who 'build_wt_consol' -TimeoutMin $LockMin)) { Say 'NE POLUCHIL MASHINU'; exit 3 }
try {
    Say "konfiguracija $Dir"
    & cmake -S $Src -B $Dir -G 'Visual Studio 17 2022' -A x64 -T host=x64 `
        -DBUILD_SHARED_LIBS=ON -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON `
        -DGGML_IQK_MUL_MAT=ON -DGGML_IQK_FLASH_ATTENTION=ON -DGGML_IQK_FA_ALL_QUANTS=ON `
        -DGGML_SCHED_MAX_COPIES=1 -DGGML_OPENMP=ON -DGGML_CCACHE=OFF -DLLAMA_CURL=OFF `
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=ON `
        -DVulkan_INCLUDE_DIR=C:/vcpkg/installed/x64-windows/include `
        -DVulkan_LIBRARY=C:/vcpkg/installed/x64-windows/lib/vulkan-1.lib `
        -DVulkan_GLSLC_EXECUTABLE=C:/vcpkg/installed/x64-windows/tools/shaderc/glslc.exe 2>&1 | Select-Object -Last 10
    if ($LASTEXITCODE -ne 0) { Say "KONFIGURACIJA NE UDALAS ($LASTEXITCODE)"; exit 2 }
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
        Tee-Object -FilePath (Join-Path $Dir 'build_last.log') |
        Where-Object { $_ -match 'error|Error|warning C|-> D:|memex-fwd' } | Select-Object -Last 200
    $rc = $LASTEXITCODE
    Say ("sborka zavershena kod {0} za {1:N0} s" -f $rc, ((Get-Date) - $t0).TotalSeconds)
    $exe = Join-Path $Dir 'bin/Release/llama-memex-fwd.exe'
    if (Test-Path $exe) {
        $null = & $exe --version 2>&1
        Say ("zapuskaemost: kod {0}; exe {1} ({2:N1} MB, {3})" -f $LASTEXITCODE, $exe, ((Get-Item $exe).Length / 1MB), (Get-Item $exe).LastWriteTime)
    } else { Say "EXE NET: $exe" }
} finally { Free-Machine }
