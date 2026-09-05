# IQ4_XS DO POLA: trjohurovnevoe hranilishche s POLNYM tjoplym urovnem na SSD C:.
# --expert-store-auto (avto-C), --warm-cap bolshe vsego overflow (~9 GiB) => vsjo nerezidentnoe
# na SSD (2,7 ms), HDD okolo nulja. Bez predzagruzki (arm b) i s predzagruzkoj (arm c).
# Zatem arm dc: --decode-check 16 s polnym tjoplym urovnem - sverka tokenov protiv golden.
# CREATE_ALWAYS: tjoplyj fajl stroitsja ZANOVO kazhdyj arm (~1400 s na 9 GiB). LLAMA_MMAP_PREFETCH=0.
param(
    [string] $Model   = 'D:\Qwen3-Coder-Next-UD-IQ4_XS.gguf',
    [string] $Prompt  = 'D:\MemeX\results\prompt_micro.txt',
    [string] $Corr    = 'D:\MemeX\results\r1_corr_multi.bin',
    [string] $Prior   = 'D:\MemeX\results\expert_prior_coder_next.bin',
    [string] $WarmDir = 'C:\memex_warm',
    [double] $WarmCap = 12.0,
    [int]    $Gen     = 64,
    [int]    $Tokens  = 32,
    [string] $Arms    = 'a,b,c,dc',
    [string] $OutDir  = 'D:\MemeX\results\iq4_floor'
)
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Path $OutDir -Force -EA SilentlyContinue | Out-Null
$env:LLAMA_MMAP_PREFETCH = '0'
$golden = (Get-Content 'C:/Users/User11/Desktop/MemeX/bench/golden_decode.json' -Raw | ConvertFrom-Json).qwen3next -join ','

$base = @('-m',$Model,'-f',$Prompt,'--tokens',"$Tokens",
          '-t','8','--no-repack','--no-ref','--gpu-static','--gpu-static-layers',
          '--expert-store-auto','--expert-prior',$Prior)

function RunGen([string]$name, [string[]]$extra) {
    $log = Join-Path $OutDir ("gen_{0}.log" -f $name)
    $a = $base + @('--gen',"$Gen") + $extra
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $sw.Stop()
    $txt = Get-Content -LiteralPath $log -Raw
    $cap = [regex]::Match($txt,'C = (\d+) iz (\d+)')
    $ab  = [regex]::Match($txt,'ESTORE_AB C (\d+) spares \d+ period \d+ repack \d+ tokens \d+ hits ([0-9.]+) miss_per_tok ([0-9.]+) ms_sync_per_tok ([0-9.]+) fills (\d+)')
    $lv  = [regex]::Match($txt,'ESTORE_LEVEL warm (\d+) warm_w (\d+) warm_gib ([0-9.]+) tokens \d+ sync_ssd_pt ([0-9.]+) sync_hdd_pt ([0-9.]+) bytes_ssd_gib ([0-9.]+) bytes_hdd_gib ([0-9.]+) async_ssd (\d+) async_hdd (\d+)')
    $mspt= [regex]::Match($txt,'dolja fazy: ([0-9.]+) ms/token')
    # fallback measured budget line: unit token has a '/', unlike "NNN МиБ -> " memory lines
    if (-not $mspt.Success) { $mspt = [regex]::Match($txt,'([0-9.]+) [^ ]*/[^ ]* -> ') }
    $warm= [regex]::Match($txt,'TRI UROVNJA: OZU (\d+) rezidentnyh/sloj \+ SSD tjoplyj fajl (\d+) ekspertov/sloj \(([0-9.]+) GiB, postrojka ([0-9.]+) ms')
    $ms = if ($mspt.Success) { [double]$mspt.Groups[1].Value } else { [double]::NaN }
    Write-Host ("=== {0} === (wall {1:N0}s)" -f $name,$sw.Elapsed.TotalSeconds)
    if ($cap.Success)  { Write-Host ("  C = {0}/{1} rezidentnyh" -f $cap.Groups[1].Value,$cap.Groups[2].Value) }
    if ($warm.Success) { Write-Host ("  warm build: OZU {0}/sloj + SSD {1} ekspertov/sloj = {2} GiB (postrojka {3} ms = {4:N0} s)" -f `
                          $warm.Groups[1].Value,$warm.Groups[2].Value,$warm.Groups[3].Value,$warm.Groups[4].Value,([double]$warm.Groups[4].Value/1000.0)) }
    if (-not [double]::IsNaN($ms)) { Write-Host ("  {0:N1} ms/token  ({1:N2} tok/s)" -f $ms,(1000.0/$ms)) }
    if ($ab.Success)   { Write-Host ("  hits {0:P2}  miss/tok {1}  ms_sync/tok {2}  fills {3}" -f `
                          [double]$ab.Groups[2].Value,$ab.Groups[3].Value,$ab.Groups[4].Value,$ab.Groups[5].Value) }
    if ($lv.Success)   {
        Write-Host ("  LEVEL: warm_gib {0}  sync SSD {1}/tok  sync HDD {2}/tok  bytes SSD {3} GiB / HDD {4} GiB  async(ssd/hdd) {5}/{6}" -f `
            $lv.Groups[3].Value,$lv.Groups[4].Value,$lv.Groups[5].Value,$lv.Groups[6].Value,$lv.Groups[7].Value,$lv.Groups[8].Value,$lv.Groups[9].Value)
        $hddpt = [double]$lv.Groups[5].Value
        Write-Host ("  HDD promahov okolo nulja? {0} (HDD {1}/token)" -f ($(if($hddpt -lt 0.5){'DA'}else{'NET'})),$lv.Groups[5].Value)
    }
    $c = (Get-PSDrive C).Free/1GB
    Write-Host ("  C: free posle = {0:N2} GiB" -f $c)
}

function RunDecodeCheck([string]$name, [string[]]$extra) {
    $log = Join-Path $OutDir ("dc_{0}.log" -f $name)
    $a = $base + @('--decode-check','16') + $extra
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $txt = Get-Content -LiteralPath $log -Raw
    $m  = [regex]::Match($txt,'DECODE_CHECK agree (\d+) steps (\d+) worst_l2 ([0-9.]+) worst_step (-?\d+) ids([^\r\n]*)')
    $vr = [regex]::Match($txt,'ESTORE_VERIFY slots (\d+) bad (\d+)')
    $lv = [regex]::Match($txt,'ESTORE_LEVEL warm (\d+) warm_w (\d+) warm_gib ([0-9.]+)')
    Write-Host ("=== DECODE_CHECK {0} ===" -f $name)
    if (-not $m.Success) { Write-Host "  NET DECODE_CHECK (sm. log)"; return }
    $ids = ($m.Groups[5].Value.Trim() -replace '\s+',',')
    $same = ($ids -eq $golden)
    Write-Host ("  agree {0}/{1}, worstL2 {2}%  golden_match={3}{4}" -f `
        $m.Groups[1].Value,$m.Groups[2].Value,$m.Groups[3].Value,$same,
        $(if($vr.Success){"  VERIFY slots $($vr.Groups[1].Value) bad $($vr.Groups[2].Value)"}else{''}))
    if ($lv.Success) { Write-Host ("  warm_gib {0}" -f $lv.Groups[3].Value) }
    if (-not $same) { Write-Host ("  ids = $ids"); Write-Host ("  gold= $golden") }
}

if (-not (Take-Machine -Who 'iq4-floor' -TimeoutMin 300)) { Write-Host 'ne vzjal mashinu'; exit 1 }
try {
    Write-Host ("golden qwen3next = {0}" -f $golden)
    $armList = $Arms -split ','
    if ($armList -contains 'a')  { RunGen 'a_no_warm'   @() }
    if ($armList -contains 'b')  { RunGen 'b_warm_full' @('--warm-dir',$WarmDir,'--warm-cap',"$WarmCap") }
    if ($armList -contains 'c')  { RunGen 'c_warm_pref' @('--warm-dir',$WarmDir,'--warm-cap',"$WarmCap",
                                     '--expert-prefetch',$Corr,'--prefetch-budget','12',
                                     '--conf-hi','0.5','--conf-lo','1.0','--hdd-lead','4') }
    if ($armList -contains 'dc') { RunDecodeCheck 'warm_full' @('--warm-dir',$WarmDir,'--warm-cap',"$WarmCap") }
} finally { Free-Machine }
