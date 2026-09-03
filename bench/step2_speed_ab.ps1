# A/B skorosti "do reestra / posle reestra" na mx1, plechi CHEREDUJUTSJA.
#
# Pochemu chereduem, a ne meryaem podryad: stranichnyj kesh ubivaet odinochnoe sravnenie.
# Ta zhe komanda na etoj mashine davala snachala 2,9661 tok/s, potom 6,0122 - vdvoe, potomu
# chto vtoroj progon chital iz kesha, nagretogo pervym. Poetomu tri kruga "staryj, novyj",
# i razbros pechataetsja RJADOM so srednim: bez nego raznica v procent nichego ne znachit.
#
# Staryj binarnik zhivjot so svoimi DLL v otdelnoj papke - imenno so svoimi, potomu chto
# sosednij agent pravit ggml-vulkan, i staryj exe s novoj ggml.dll eto ne "do", a tretje
# plecho, o kotorom nikto ne prosil.
param(
    [string]$OldBin = 'D:\MemeX\results\step2_before_bin\llama-memex-fwd.exe',
    [string]$NewBin = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe',
    [string]$Model  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf',
    [int]$Rounds = 3,
    [int]$LockMin = 300,
    [string]$Out = 'D:\MemeX\results\step2_speed_ab.log'
)

$ErrorActionPreference = 'Continue'
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1

function Get-Tps {
    param([string]$Bin)
    # STATIC_AB - sobstvennaja ASCII-stroka dvizhka: our_tok_s <chislo>. Berjotsja ona, a ne
    # vremja obolochki: v obolochku vhodit zagruzka modeli, a sravnivaem my generaciju.
    $txt = & $Bin -m $Model -f D:\MemeX\results\prompt_micro.txt --tokens 32 `
                  --gen 8 -t 8 --no-repack --no-ref 2>&1 | Out-String
    $m = [regex]::Match($txt, 'our_tok_s\s+([0-9.]+)')
    if (-not $m.Success) { return $null }
    return [double]$m.Groups[1].Value
}

foreach ($b in @($OldBin, $NewBin)) {
    if (-not (Test-Path -LiteralPath $b)) { Write-Host "NET BINARNIKA: $b"; exit 2 }
}
if (-not (Take-Machine -Who 'step2-ab' -TimeoutMin $LockMin)) {
    Write-Host 'MASHINU NE POLUCHIL - NE IZMERENO'
    exit 3
}
$old = @(); $new = @()
try {
    for ($r = 1; $r -le $Rounds; $r++) {
        $a = Get-Tps -Bin $OldBin
        $b = Get-Tps -Bin $NewBin
        if ($null -eq $a -or $null -eq $b) {
            Write-Host "krug ${r}: stroka our_tok_s ne najdena - NE IZMERENO"
            continue
        }
        $old += $a; $new += $b
        Write-Host ("krug {0}: do {1:F4} tok/s, posle {2:F4} tok/s" -f $r, $a, $b)
    }
} finally {
    Free-Machine
}

function Stat($v) {
    if ($v.Count -eq 0) { return $null }
    $mean = ($v | Measure-Object -Average).Average
    $min = ($v | Measure-Object -Minimum).Minimum
    $max = ($v | Measure-Object -Maximum).Maximum
    $spread = if ($mean -gt 0) { 100.0 * ($max - $min) / $mean } else { 0 }
    return [pscustomobject]@{ Mean = $mean; Min = $min; Max = $max; Spread = $spread }
}
$so = Stat $old; $sn = Stat $new
$lines = @()
$lines += "A/B reestra arhitektur, mx1, --gen 8 --no-ref, plechi cheredujutsja, $Rounds kruga"
$lines += ("  do    : " + ($old -join ', '))
$lines += ("  posle : " + ($new -join ', '))
if ($so -and $sn) {
    $lines += ("  do    srednee {0:F4} tok/s, razbros {1:F1}%" -f $so.Mean, $so.Spread)
    $lines += ("  posle srednee {0:F4} tok/s, razbros {1:F1}%" -f $sn.Mean, $sn.Spread)
    $delta = 100.0 * ($sn.Mean - $so.Mean) / $so.Mean
    $lines += ("  raznica srednih {0:F2}% pri razbrose {1:F1}% / {2:F1}%" -f $delta, $so.Spread, $sn.Spread)
    if ([math]::Abs($delta) -le [math]::Max($so.Spread, $sn.Spread)) {
        $lines += "  VYVOD: raznica VNUTRI razbrosa - uskorenija/zamedlenija NE POKAZANO"
    } else {
        $lines += "  VYVOD: raznica BOLSHE razbrosa - trebuet otdelnogo razbora"
    }
} else {
    $lines += '  NE IZMERENO'
}
$lines | ForEach-Object { Write-Host $_ }
$lines | Set-Content -LiteralPath $Out -Encoding utf8
