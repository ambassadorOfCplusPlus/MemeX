# Oflajn-ocenka predskazatelja po skrytomu sostojaniju. Pod zamkom: skript derzhit v pamjati
# damp (373 MB f16 -> 1,5 GB f32) i schitaet grebnevuju regressiju na 48 sloev.
param(
  [string]$OutDir = 'D:\MemeX\results',
  [string]$Model  = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
  [string]$Ks     = '1,2,4'
)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
if (-not (Take-Machine -Who 'dbg-hidden-lab' -TimeoutMin 300)) { Write-Output 'net mashiny'; exit 1 }
try {
  $out = Join-Path $OutDir 'hidden_lab_coder_next.txt'
  python C:\Users\User11\Desktop\MemeX\bench\hidden_lab.py `
    (Join-Path $OutDir 'hidden_trace.bin') (Join-Path $OutDir 'route_trace_h.bin') $Model `
    --ks $Ks *> $out
  Write-Output ('vyvod: ' + $out)
  Get-Content -LiteralPath $out | Select-Object -Last 30 | ForEach-Object { Write-Output $_ }
} finally { Free-Machine }
