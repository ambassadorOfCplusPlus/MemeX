# Kontrol gemma4: bylo li ejo rashozhdenie DO pravki. Odno plecho staroe (--ref-offload),
# odno novoe, i to zhe s --ref-fa - u gemmy bez nego neveren sam etalon (V-kesh
# transponirovan, sm. kommentarij v memex-fwd.cpp).
param([string]$OutDir = 'D:\MemeX\results')
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$exe = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$g4  = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'
$p   = 'D:\MemeX\results\prompt_micro.txt'
$arms = @(
  @{ name='g4_old'; extra=@('--ref-offload') },
  @{ name='g4_fa';  extra=@('--ref-fa') },
  @{ name='g4_old_fa'; extra=@('--ref-offload','--ref-fa') }
)
foreach ($a in $arms) {
  if (-not (Take-Machine -Who ('dbg-g4-' + $a.name) -TimeoutMin 300)) { Write-Output 'net mashiny'; exit 1 }
  try {
    $log = Join-Path $OutDir ('dbg_' + $a.name + '.log')
    Write-Output ('=== ' + $a.name + ' ===')
    $argv = @('-m', $g4, '-f', $p, '--tokens', '32', '--decode-check', '16', '-t', '8', '--no-repack') + $a.extra
    & $exe @argv *>&1 | Tee-Object -FilePath $log | Out-Null
    $t = Get-Content -LiteralPath $log | Select-String -Pattern 'itog|L2:' | Select-Object -Last 3
    foreach ($x in $t) { Write-Output ('  ' + $x.Line) }
  } finally { Free-Machine }
}
Write-Output 'gotovo'
