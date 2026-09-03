# Poslojnye zondy qwen3next pri etalone na processore: gde imenno rashoditsja prefill.
param(
  [string]$Model = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
  [string]$Prompt = 'D:\MemeX\results\prompt_micro.txt',
  [string]$Out = 'D:\MemeX\results\dbg_probe_next_refcpu.log',
  [string]$Extra = ''
)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$exe = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
if (-not (Take-Machine -Who 'dbg-probe-next' -TimeoutMin 300)) { Write-Output 'mashinu ne dali'; exit 1 }
try {
  $argv = @('-m', $Model, '-f', $Prompt, '--tokens', '32', '--decode-check', '16', '--probe', 'all', '-t', '8', '--no-repack')
  if ($Extra -ne '') { $argv += $Extra.Split(' ') }
  & $exe @argv *>&1 | Tee-Object -FilePath $Out | Out-Null
  Write-Output ("gotovo: " + $Out)
} finally { Free-Machine }
