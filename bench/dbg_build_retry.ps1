# Sborka s povtorami: v dereve parallelno pravjatsja gpu_static.hpp/cpp chuzhim agentom,
# i ejo promezhutochnoe sostojanie ne kompiliruetsja. Zhdjom i povtorjaem, nichego ne chinim.
param([int]$Tries = 12, [int]$WaitSec = 120)
for ($i = 1; $i -le $Tries; $i++) {
  Write-Output ("popytka " + $i)
  $out = pwsh -File C:\Users\User11\Desktop\MemeX\bench\build_safe.ps1 -Targets llama-memex-fwd -Dir D:\MemeX\src\ik_llama.cpp\build-vk -Jobs 4 -LockMin 300 2>&1
  $rc = $LASTEXITCODE
  $out | Select-Object -Last 3 | ForEach-Object { Write-Output ("  " + $_) }
  if ($rc -eq 0) { Write-Output 'sborka godna'; exit 0 }
  Start-Sleep -Seconds $WaitSec
}
Write-Output 'ne sobralos za vse popytki'
exit 1
