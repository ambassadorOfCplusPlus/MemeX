# §2 no-copy baseline: Coder-Next IQ4_XS, chistyj mmap BEZ --expert-store, statika na karte.
# Odna kopija ekspertov = page-cache mmap, privatnogo bufera net. Zapuskat kogda disk svoboden.
# NB: binar pishet sluzhebnoe v stderr - NE ispolzuem $ErrorActionPreference=Stop + pipe (padaet).
param([int]$gen = 64, [int]$tokens = 32)
$bin   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$model = 'D:\Qwen3-Coder-Next-UD-IQ4_XS.gguf'
$env:LLAMA_MMAP_PREFETCH = '0'   # inache loader prefetchnet ves 41 GB s HDD
$args = @('-m',$model,'--tokens',$tokens,'--gen',$gen,'-t','8','--no-repack','--gpu-static','--gpu-static-layers')
$dir = Split-Path (Get-Item $PSCommandPath).FullName
function Run($tag) {
  $o = "$env:TEMP\_nocopy_$tag.out"
  Write-Host "=== $tag $(Get-Date -Format HH:mm:ss) ==="
  $p = Start-Process -FilePath $bin -ArgumentList $args -RedirectStandardOutput $o -RedirectStandardError "$o.err" -PassThru -NoNewWindow
  $p | Wait-Process -Timeout 900 -EA SilentlyContinue
  if (-not $p.HasExited) { Stop-Process $p -Force -EA SilentlyContinue; Write-Host "  TAJMAUT 900s" }
  $line = (Get-Content $o -EA SilentlyContinue | Select-String 'STATIC_AB').Line
  if ($line) { Write-Host "  $line" } else { Write-Host "  (net STATIC_AB); hvost:"; Get-Content $o -Tail 4 -EA SilentlyContinue | ForEach-Object { Write-Host "    $_" } }
}
Run 'PROGREV'
Run 'STEADY1'
Run 'STEADY2'
Write-Host 'NOCOPY_BASELINE_DONE'
