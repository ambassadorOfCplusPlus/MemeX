# Tri proverki, kotorye bez progona ostalis by utverzhdenijami.
#
#  1. OTKAZ VSLUH. gemma4 + --min-experts: stroitel gemma4 takogo parametra ne prinimaet
#     vovse, i do reestra flag tiho nichego ne delal. Dolzhna pojavitsja stroka
#     "tochka prefill: arhitektura gemma4 ne podderzhivaet min_experts/porog ... OTKAZ".
#  2. SLED PO SVOEMU FLAGU. qwen3next + tolko MEMEX_EXPERT_TRACE (bez MEMEX_MTP_OVERLAP i
#     bez MEMEX_EXPERT_COVERAGE): fajl sleda dolzhen pojavitsja. Do pravki blok zapisi lezhal
#     vnutri vetki MTP i ne vypolnjalsja vovse.
#  3. CHESTNOE "NE IZMERENO". qwen3moe + MEMEX_EXPERT_TRACE bez --resident: kopiju
#     marshrutizacii u etoj arhitektury stroit rwarm, to est rezidentnyj nabor, i bez nego
#     grafa s nej net. Ranshe eto byl tihij propusk; teper dolzhna byt stroka o tom, chto
#     marshrutizacija zaproshena, a graf ejo ne otdal.
param([int]$LockMin = 300)

$ErrorActionPreference = 'Continue'
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1

$bin  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$g4   = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'
$next = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
$mx1  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$trace = 'D:\MemeX\results\step2_trace_probe.bin'

if (-not (Take-Machine -Who 'step2-refusals' -TimeoutMin $LockMin)) {
    Write-Host 'MASHINU NE POLUCHIL - NE IZMERENO'
    exit 3
}
try {
    Write-Host '=== 1. gemma4 + --min-experts 4 : zhdjom OTKAZ s imenem tochki'
    & $bin -m $g4 -f D:\MemeX\results\prompt_micro.txt --tokens 32 --gen 2 -t 8 `
           --no-repack --no-ref --min-experts 4 *>&1 |
        Tee-Object -FilePath 'D:\MemeX\results\step2_refuse_gemma4.log' | Out-Null

    Write-Host '=== 2. qwen3next + tolko MEMEX_EXPERT_TRACE : zhdjom fajl sleda'
    if (Test-Path -LiteralPath $trace) { Remove-Item -LiteralPath $trace -Force }
    $env:MEMEX_EXPERT_TRACE = $trace
    Remove-Item Env:MEMEX_EXPERT_COVERAGE -ErrorAction SilentlyContinue
    Remove-Item Env:MEMEX_MTP_OVERLAP -ErrorAction SilentlyContinue
    & $bin -m $next -f D:\MemeX\results\prompt_micro.txt --tokens 32 --gen 2 -t 8 `
           --no-repack --no-ref *>&1 |
        Tee-Object -FilePath 'D:\MemeX\results\step2_trace_next.log' | Out-Null

    Write-Host '=== 3. qwen3moe + MEMEX_EXPERT_TRACE bez --resident : zhdjom chestnoe NE IZMERENO'
    & $bin -m $mx1 -f D:\MemeX\results\prompt_micro.txt --tokens 32 --gen 2 -t 8 `
           --no-repack --no-ref *>&1 |
        Tee-Object -FilePath 'D:\MemeX\results\step2_trace_mx1.log' | Out-Null
    Remove-Item Env:MEMEX_EXPERT_TRACE -ErrorAction SilentlyContinue
} finally {
    Free-Machine
}
if (Test-Path -LiteralPath $trace) {
    Write-Host ('fajl sleda: ' + (Get-Item -LiteralPath $trace).Length + ' bajt')
} else {
    Write-Host 'FAJL SLEDA NE POJAVILSJA'
}
Write-Host 'GOTOVO'
