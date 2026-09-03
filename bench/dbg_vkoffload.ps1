# Otkuda berjotsja L2 8-10% u qwen3next na --decode-check.
#
# Gipoteza: eto ne nash graf, a ETALON. llama_decode sozdajotsja s n_gpu_layers 0, no
# planirovshchik vsjo ravno otdajot Vulkan ljuboj uzel s ne[1] >= 32
# (ggml_backend_vk_offload_op, min_batch_size 32), i na promte rovno v 32 tokena tuda
# uezzhaet ves prefill - s nakopleniem v f16. Nash put chisto processornyj v f32.
#
# Chetyre plecha:
#   nosel  - baza, 32 tokena
#   sel    - ta zhe baza pri DRUGOJ raskladke buferov (MEMEX_LAYOUT_SEL)
#   t31    - 31 token: nizhe poroga vygruzki, etalon dolzhen ostatsja na CPU
#   novk   - 32 tokena, no Vulkan spryatan ot processa celikom
param(
  [string]$Model = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
  [string]$Prompt = 'D:\MemeX\results\prompt_micro.txt',
  [string]$OutDir = 'D:\MemeX\results',
  [int]$Steps = 16
)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$exe = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'

$arms = @(
  @{ name='nosel'; tokens=32; sel=$false; novk=$false },
  @{ name='sel';   tokens=32; sel=$true;  novk=$false },
  @{ name='t31';   tokens=31; sel=$false; novk=$false },
  @{ name='novk';  tokens=32; sel=$false; novk=$true  }
)

foreach ($a in $arms) {
  if (-not (Take-Machine -Who ("dbg-vk-" + $a.name) -TimeoutMin 300)) {
    Write-Output ("mashinu ne dali: " + $a.name); exit 1
  }
  try {
    Remove-Item Env:MEMEX_LAYOUT_SEL -ErrorAction SilentlyContinue
    Remove-Item Env:GGML_VK_VISIBLE_DEVICES -ErrorAction SilentlyContinue
    if ($a.sel)  { $env:MEMEX_LAYOUT_SEL = '1' }
    if ($a.novk) { $env:GGML_VK_VISIBLE_DEVICES = ' ' }
    $log = Join-Path $OutDir ("dbg_vk_" + $a.name + ".log")
    Write-Output ("=== " + $a.name + " -> " + $log + " ===")
    & $exe -m $Model -f $Prompt --tokens $a.tokens --decode-check $Steps -t 8 --no-repack *>&1 |
      Tee-Object -FilePath $log | Out-Null
    $keep = Select-String -Path $log -Pattern 'MEMEX_LAYOUT_SEL|Vulkan0 compute|graph splits|prefill cherez|itog:|otnositelnaja' -SimpleMatch:$false
    foreach ($k in $keep) { Write-Output ("  " + $k.Line) }
  } finally {
    Remove-Item Env:MEMEX_LAYOUT_SEL -ErrorAction SilentlyContinue
    Remove-Item Env:GGML_VK_VISIBLE_DEVICES -ErrorAction SilentlyContinue
    Free-Machine
  }
}
Write-Output 'vse plechi zaversheny'
