# mx1 (qwen3moe): staroe povedenie etalona protiv novogo.
param([string]$OutDir = 'D:\MemeX\results')
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$exe = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$m   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$p   = 'D:\MemeX\results\prompt_micro.txt'
foreach ($a in @(@{n='mx1_old'; e=@('--ref-offload')})) {
  if (-not (Take-Machine -Who ('dbg-' + $a.n) -TimeoutMin 300)) { Write-Output 'net mashiny'; exit 1 }
  try {
    $log = Join-Path $OutDir ('dbg_' + $a.n + '.log')
    Write-Output ('=== ' + $a.n + ' ===')
    $argv = @('-m', $m, '-f', $p, '--tokens', '32', '--decode-check', '16', '-t', '8', '--no-repack') + $a.e
    & $exe @argv *>&1 | Tee-Object -FilePath $log | Out-Null
    $t = Get-Content -LiteralPath $log | Select-String -Pattern 'itog|L2:' | Select-Object -Last 3
    foreach ($x in $t) { Write-Output ('  ' + $x.Line) }
  } finally { Free-Machine }
}
Write-Output 'gotovo'
