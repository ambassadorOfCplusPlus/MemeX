# Build the pre-patch reference binary (upstream 8337e4c) so both arms exist side by side.
#
# Why a whole second binary and not an env switch inside ours. The switch was the plan, and it
# would have measured nothing: with plain -rtr and no filter, repack_filtered() is false, so
# use_mmap is set to false exactly as upstream did, and llm_load_tensors takes the same in-place
# repack loop. The new contiguous-buffer path is unreachable without --repack-only/--repack-exclude.
# A switch between two identical paths is not a measurement. A binary built from the commit the
# 14.04 baseline was measured on covers the WHOLE diff instead of the part we suspected.
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$LOG = 'D:\MemeX\results\repack_hunt.log'
$SRC = 'D:\MemeX\src\ik_upstream'
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }

("`n`n######## repack-hunt: sborka referensa 8337e4c " + (Get-Date)) | Add-Content $LOG
if (-not (Take-Machine -Who 'repack-hunt' -TimeoutMin 120)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    Say 'configure'
    & cmake -S $SRC -B "$SRC\build" -G 'Visual Studio 18 2026' `
        -DCMAKE_BUILD_TYPE=Release `
        -DGGML_AVX=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_AVX512=OFF `
        -DGGML_NATIVE=ON -DGGML_OPENMP=ON `
        -DGGML_IQK_MUL_MAT=ON -DGGML_IQK_FLASH_ATTENTION=ON -DGGML_IQK_FA_ALL_QUANTS=ON `
        -DGGML_EXPERT_CHUNKING=ON `
        -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_RPC=OFF -DGGML_CURL=OFF `
        -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_CURL=OFF `
        *> 'D:\MemeX\results\_hunt_cmake.log'
    Note ('configure exit ' + $LASTEXITCODE)
    Say 'build llama-cli'
    $t0 = Get-Date
    & cmake --build "$SRC\build" --config Release --target llama-cli -- /m:8 `
        *> 'D:\MemeX\results\_hunt_build.log'
    Note ('build exit ' + $LASTEXITCODE + (', {0:N1} min' -f ((Get-Date)-$t0).TotalMinutes))
    $exe = "$SRC\build\bin\Release\llama-cli.exe"
    if (Test-Path $exe) { Note ('est binarnik: ' + (Get-Item $exe).Length + ' bajt') }
    else { Note 'BINARNIKA NET' }
} finally { Free-Machine; Note 'mashina osvobozhdena' }
