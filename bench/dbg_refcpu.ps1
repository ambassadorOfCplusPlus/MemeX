# Kontrol posle pravki: etalon bolshe ne otdajot uzly na Vulkan.
#
#   fix_nosel  - qwen3next, novyj default (etalon celikom na CPU)
#   fix_sel    - to zhe pri DRUGOJ raskladke buferov (MEMEX_LAYOUT_SEL)
#   old_refoff - staroe povedenie (--ref-offload), dolzhno vosproizvesti 8,7740 / 10,5839
#   mx1        - qwen3moe, ne dolzhno stat huzhe
#   gemma4     - gemma4, ne dolzhno stat huzhe
param(
  [string]$OutDir = 'D:\MemeX\results',
  [string]$Prompt = 'D:\MemeX\results\prompt_micro.txt',
  [int]$Steps = 16
)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$exe  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$next = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
$mx1  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$g4   = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'

$arms = @(
  @{ name='fix_nosel';  model=$next; sel=$false; extra=@() },
  @{ name='fix_sel';    model=$next; sel=$true;  extra=@() },
  @{ name='old_refoff'; model=$next; sel=$false; extra=@('--ref-offload') },
  @{ name='mx1';        model=$mx1;  sel=$false; extra=@() },
  @{ name='gemma4';     model=$g4;   sel=$false; extra=@() }
)

foreach ($a in $arms) {
  if (-not (Test-Path -LiteralPath $a.model)) { Write-Output ("net modeli: " + $a.model); continue }
  if (-not (Take-Machine -Who ("dbg-refcpu-" + $a.name) -TimeoutMin 300)) {
    Write-Output ("mashinu ne dali: " + $a.name); exit 1
  }
  try {
    Remove-Item Env:MEMEX_LAYOUT_SEL -ErrorAction SilentlyContinue
    if ($a.sel) { $env:MEMEX_LAYOUT_SEL = '1' }
    $log = Join-Path $OutDir ("dbg_refcpu_" + $a.name + ".log")
    Write-Output ("=== " + $a.name + " -> " + $log + " ===")
    $argv = @('-m', $a.model, '-f', $Prompt, '--tokens', '32', '--decode-check', "$Steps", '-t', '8', '--no-repack') + $a.extra
    & $exe @argv *>&1 | Tee-Object -FilePath $log | Out-Null
    foreach ($pat in @('etalon posazhen', 'ref-offload', 'graph splits', 'MEMEX_LAYOUT_SEL')) {
      $h = Select-String -Path $log -Pattern $pat -SimpleMatch | Select-Object -First 1
      if ($h) { Write-Output ("  " + $h.Line) }
    }
    $tail = Get-Content -LiteralPath $log | Select-String -Pattern 'L2:|L2 |itog|top' | Select-Object -Last 6
    foreach ($t in $tail) { Write-Output ("  " + $t.Line) }
  } finally {
    Remove-Item Env:MEMEX_LAYOUT_SEL -ErrorAction SilentlyContinue
    Free-Machine
  }
}
Write-Output 'kontrol zavershjon'
