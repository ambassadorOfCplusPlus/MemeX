# TRJOHUROVNEVOE HRANILISHCHE (ideja polzovatelja): sverka - trjohurovnevaja raskladka i
# predzagruzka s dvumja porogami NE menjajut otvet. Kriterij: TE ZHE tokeny, chto golden
# qwen3next, i ESTORE_VERIFY bez plohih slotov. Model IQ3_XXS s C: (SSD), tjoplyj fajl na D:
# (dlja sverki disk urovnja ne vazhen - vazhno, chto bajty te zhe). LLAMA_MMAP_PREFETCH=0.
param(
    [string] $Model  = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
    [string] $Prompt = 'D:\MemeX\results\prompt_micro.txt',
    [string] $Corr   = 'D:\MemeX\results\r1_corr_multi.bin',
    [string] $Prior  = 'D:\MemeX\results\expert_prior_coder_next.bin',
    [string] $WarmDir= 'D:\memex_warm_vf',
    [string] $OutDir = 'D:\MemeX\results\step_warm'
)
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Path $OutDir -Force -EA SilentlyContinue | Out-Null
$golden = (Get-Content 'C:/Users/User11/Desktop/MemeX/bench/golden_decode.json' -Raw | ConvertFrom-Json).qwen3next -join ','

function Run([string]$name, [string[]]$extra) {
    $log = Join-Path $OutDir ("dc_{0}.log" -f $name)
    $a = @('-m',$Model,'-f',$Prompt,'--tokens','32','--decode-check','16',
           '-t','8','--no-repack','--gpu-static','--gpu-static-layers') + $extra
    $env:LLAMA_MMAP_PREFETCH='0'
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $txt = Get-Content -LiteralPath $log -Raw
    $m  = [regex]::Match($txt,'DECODE_CHECK agree (\d+) steps (\d+) worst_l2 ([0-9.]+) worst_step (-?\d+) ids([^\r\n]*)')
    $vr = [regex]::Match($txt,'ESTORE_VERIFY slots (\d+) bad (\d+)')
    $lv = [regex]::Match($txt,'ESTORE_LEVEL ([^\r\n]*)')
    $ok = [regex]::Match($txt,'OTKAZ|OTKAZAN')
    if (-not $m.Success) { Write-Host ("  {0}: NET DECODE_CHECK (OTKAZ? {1})" -f $name,$ok.Success); return }
    $ids = ($m.Groups[5].Value.Trim() -replace '\s+',',')
    $same = ($ids -eq $golden)
    Write-Host ("  {0}: {1}/{2} agree, worstL2 {3:N4}%  golden_match={4}{5}" -f `
        $name,$m.Groups[1].Value,$m.Groups[2].Value,[double]$m.Groups[3].Value,$same,
        $(if($vr.Success){"  VERIFY slots $($vr.Groups[1].Value) bad $($vr.Groups[2].Value)"}else{''}))
    if ($lv.Success) { Write-Host ("      LEVEL " + $lv.Groups[1].Value) }
    if (-not $same) { Write-Host ("      ids= $ids"); Write-Host ("      gold=$golden") }
}

if (-not (Take-Machine -Who 'warm-verify' -TimeoutMin 300)) { Write-Host 'ne vzjal mashinu'; exit 1 }
try {
    Write-Host "golden qwen3next = $golden"
    Run 'baseline_store'   @('--expert-store','128','--expert-prior',$Prior)
    Run 'warm_only'        @('--expert-store','128','--expert-prior',$Prior,'--warm-dir',$WarmDir,'--warm-cap','2')
    Run 'warm_prefetch'    @('--expert-store','128','--expert-prior',$Prior,'--warm-dir',$WarmDir,'--warm-cap','2','--expert-prefetch',$Corr,'--prefetch-budget','12')
    Run 'warm_pref_thresh' @('--expert-store','128','--expert-prior',$Prior,'--warm-dir',$WarmDir,'--warm-cap','2','--expert-prefetch',$Corr,'--prefetch-budget','12','--conf-hi','0.5','--conf-lo','1.0','--hdd-lead','3')
} finally { Free-Machine }
