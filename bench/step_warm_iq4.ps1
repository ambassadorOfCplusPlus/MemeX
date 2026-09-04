# GLAVNYJ ZAMER: IQ4_XS (eksperty 33,4 GiB, ne vlezajut v OZU), gguf na D: (HDD).
# Tri rezhima --gen podrjad (ustanovivsheesja):
#   (a) bez warm-urovnja  - promahi s HDD-gguf (~23 ms)
#   (b) warm na SSD C:     - promahi s tjoplogo fajla (~2,7 ms)
#   (c) warm + predzagruzka R1 (r1_corr_multi, dva poroga + hdd-lead)
# LLAMA_MMAP_PREFETCH=0. Model gruzitsja zanovo kazhdyj raz (eto neizbezhno).
param(
    [string] $Model   = 'D:\Qwen3-Coder-Next-UD-IQ4_XS.gguf',
    [string] $Prompt  = 'D:\MemeX\results\prompt_micro.txt',
    [string] $Corr    = 'D:\MemeX\results\r1_corr_multi.bin',
    [string] $Prior   = 'D:\MemeX\results\expert_prior_coder_next.bin',
    [string] $WarmDir = 'C:\memex_warm',
    [double] $WarmCap = 3.0,
    [int]    $Cap     = 330,
    [int]    $Gen     = 64,
    [int]    $Tokens  = 32,
    [string] $Arms    = 'a,b,c',
    [string] $OutDir  = 'D:\MemeX\results\step_warm_iq4'
)
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Path $OutDir -Force -EA SilentlyContinue | Out-Null

function Run([string]$name, [string[]]$extra) {
    $log = Join-Path $OutDir ("gen_{0}.log" -f $name)
    $a = @('-m',$Model,'-f',$Prompt,'--tokens',"$Tokens",'--gen',"$Gen",
           '-t','8','--no-repack','--no-ref','--gpu-static','--gpu-static-layers',
           '--expert-store',"$Cap",'--expert-prior',$Prior) + $extra
    $env:LLAMA_MMAP_PREFETCH='0'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $sw.Stop()
    $txt = Get-Content -LiteralPath $log -Raw
    $est = [regex]::Match($txt,'ESTORE_AB ([^\r\n]*)')
    $lv  = [regex]::Match($txt,'ESTORE_LEVEL ([^\r\n]*)')
    $pf  = [regex]::Match($txt,'PREFETCH_AB ([^\r\n]*)')
    $cap = [regex]::Match($txt,'C = (\d+) iz (\d+)')
    $warm= [regex]::Match($txt,'TRI UROVNJA: OZU (\d+) rezidentnyh/sloj \+ SSD tjoplyj fajl (\d+) ekspertov/sloj \(([0-9.]+) GiB, postrojka ([0-9.]+) ms')
    # ms/token: ishchem "ustanovivsheesja" ili srednee po gen. Beriom stroku gen tajminga.
    $mspt = [regex]::Match($txt,'([0-9.]+) ms/token vsego')
    $tps  = [regex]::Matches($txt,'([0-9.]+) tok/s')
    Write-Host ("=== {0} === (wall {1:N0}s)" -f $name,$sw.Elapsed.TotalSeconds)
    if ($cap.Success)  { Write-Host ("  C = {0}/{1}" -f $cap.Groups[1].Value,$cap.Groups[2].Value) }
    if ($warm.Success) { Write-Host ("  warm: OZU {0}/sloj + SSD {1}/sloj = {2} GiB (postrojka {3} ms)" -f `
                          $warm.Groups[1].Value,$warm.Groups[2].Value,$warm.Groups[3].Value,$warm.Groups[4].Value) }
    if ($mspt.Success) { Write-Host ("  {0} ms/token vsego" -f $mspt.Groups[1].Value) }
    if ($est.Success)  { Write-Host ("  ESTORE_AB "  + $est.Groups[1].Value) }
    if ($lv.Success)   { Write-Host ("  ESTORE_LEVEL " + $lv.Groups[1].Value) }
    if ($pf.Success)   { Write-Host ("  PREFETCH_AB " + $pf.Groups[1].Value) }
    $c = (Get-PSDrive C).Free/1GB
    Write-Host ("  C: free posle = {0:N2} GiB" -f $c)
}

if (-not (Take-Machine -Who 'warm-iq4' -TimeoutMin 300)) { Write-Host 'ne vzjal mashinu'; exit 1 }
try {
    $armList = $Arms -split ','
    if ($armList -contains 'a') { Run 'a_no_warm'      @() }
    if ($armList -contains 'b') { Run 'b_warm_ssd'     @('--warm-dir',$WarmDir,'--warm-cap',"$WarmCap") }
    if ($armList -contains 'c') { Run 'c_warm_pref'    @('--warm-dir',$WarmDir,'--warm-cap',"$WarmCap",
                                     '--expert-prefetch',$Corr,'--prefetch-budget','12',
                                     '--conf-hi','0.5','--conf-lo','1.0','--hdd-lead','4') }
} finally { Free-Machine }
