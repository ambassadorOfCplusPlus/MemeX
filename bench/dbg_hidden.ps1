# Damp skrytyh sostojanij dlja predskazatelja ekspertov.
#
#   check  - BEZ peremennoj: --decode-check 16 na qwen3next objazan dat te zhe cifry, chto do
#            pravki (6,8449 / 9,1129 / 15 iz 16). Esli net - graf izmenilsja tam, gde ne dolzhen.
#   dump   - sled i damp ODNIM progonom: poriadok tokenov u nih objazan sovpast, i imenno eto
#            proverjaet k=0 v hidden_lab.py.
param(
  [string]$OutDir = 'D:\MemeX\results',
  [string]$Model  = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
  [switch]$SkipCheck
)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$exe = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'

if (-not $SkipCheck) {
  if (-not (Take-Machine -Who 'dbg-hidden-check' -TimeoutMin 300)) { Write-Output 'net mashiny'; exit 1 }
  try {
    Remove-Item Env:MEMEX_HIDDEN_TRACE -ErrorAction SilentlyContinue
    Remove-Item Env:MEMEX_EXPERT_TRACE -ErrorAction SilentlyContinue
    $log = Join-Path $OutDir 'dbg_hidden_check.log'
    Write-Output '=== check: bez peremennoj, --decode-check 16 ==='
    & $exe -m $Model -f 'D:\MemeX\results\prompt_micro.txt' --tokens 32 --decode-check 16 -t 8 --no-repack *>&1 |
      Tee-Object -FilePath $log | Out-Null
    $t = Get-Content -LiteralPath $log | Select-String -Pattern 'L2:|itog' | Select-Object -Last 3
    foreach ($x in $t) { Write-Output ('  ' + $x.Line) }
  } finally { Free-Machine }
}

if (-not (Take-Machine -Who 'dbg-hidden-dump' -TimeoutMin 300)) { Write-Output 'net mashiny'; exit 1 }
try {
  $env:MEMEX_EXPERT_TRACE = Join-Path $OutDir 'route_trace_h.bin'
  $env:MEMEX_HIDDEN_TRACE = Join-Path $OutDir 'hidden_trace.bin'
  $log = Join-Path $OutDir 'dbg_hidden_dump.log'
  Write-Output '=== dump: sled i damp odnim progonom ==='
  & $exe -m $Model -f 'D:\MemeX\results\prompt_2000.txt' --tokens 1900 --gen 2 -t 8 `
        --no-repack --no-ref --prefill-chunk 128 *>&1 |
    Tee-Object -FilePath $log | Out-Null
  foreach ($pat in @('MEMEX_HIDDEN_TRACE','damp skrytogo','sled marshrutizacii','tokenov v promte','NE ZAPISAN')) {
    $h = Select-String -Path $log -Pattern $pat -SimpleMatch
    foreach ($x in $h) { Write-Output ('  ' + $x.Line) }
  }
} finally {
  Remove-Item Env:MEMEX_EXPERT_TRACE -ErrorAction SilentlyContinue
  Remove-Item Env:MEMEX_HIDDEN_TRACE -ErrorAction SilentlyContinue
  Free-Machine
}
Write-Output 'gotovo'
