# Dva progona odnoj i toj zhe sverki --decode-check pri DVUH raskladkah grafa.
# MEMEX_LAYOUT_SEL menjaet tolko razmeshchenie buferov (kopija top-k naruzhu zakrepljaet
# tenzory i zapreshchaet gallocr pereispolzovat ih bufera). Arifmetika ta zhe, znachit
# vse chisla objazany sovpast do znaka. Esli net - kakoj-to uzel chitaet chuzhoj bufer.
param(
  [string]$Model = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
  [string]$Prompt = 'D:\MemeX\results\prompt_micro.txt',
  [string]$OutDir = 'D:\MemeX\results',
  [string]$Tag = '',
  [int]$Steps = 16,
  [string]$Probe = 'all'
)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$exe = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$argsCommon = @('-m', $Model, '-f', $Prompt, '--tokens', '32', '--decode-check', "$Steps", '-t', '8', '--no-repack')
if ($Probe -ne '') { $argsCommon += @('--probe', $Probe) }

foreach ($arm in @('without','with')) {
  if (-not (Take-Machine -Who "dbg-layout-$arm" -TimeoutMin 300)) {
    Write-Output "mashinu ne dali: $arm"
    exit 1
  }
  try {
    if ($arm -eq 'with') { $env:MEMEX_LAYOUT_SEL = '1' } else { Remove-Item Env:MEMEX_LAYOUT_SEL -ErrorAction SilentlyContinue }
    $log = Join-Path $OutDir "dbg_layout_$arm$Tag.log"
    Write-Output "=== progon $arm -> $log ==="
    & $exe @argsCommon *>&1 | Tee-Object -FilePath $log | Out-Null
    Write-Output "gotovo: $arm"
  } finally {
    Remove-Item Env:MEMEX_LAYOUT_SEL -ErrorAction SilentlyContinue
    Free-Machine
  }
}
Write-Output 'oba progona zaversheny'
