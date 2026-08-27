# Rastjot li raznica so vremenem u plecha s kartoj bystree, chem u plecha bez nejo.
#
# ETO EDINSTVENNYJ VOPROS, i on ne o velichine, a o naklone. Rjad l_out-0..47 uzhe okazalsja
# POSTROCHNO odinakovym s flagom i bez nego, potomu chto prefill mnogotokennyj i idjot na
# hoste v oboih sluchajah. Znachit rost 0.0489% -> 0.9954% po sloju prinadlezhit CPU-putju
# dvizhka i suschestvoval do karty. Ostajotsja rjad dekoda - i tam u karty est svoj
# zakonnyj mehanizm nakoplenija, kotoryj nado izmerit, a ne ugadat:
#
#   KV-kesh na karte pishetsja ejo zhe povorotom i ejo zhe proekcijami, to est kazhdyj shag
#   kladjot v kesh K i V, otlichajushchiesja ot hostovyh na okruglenie. Eti otlichija OSTAJUTSJA
#   v keshe i perechityvajutsja na kazhdom sledujushchem shage. Vopros: nakoplenie nasyshchaetsja
#   ili rastjot bez granicy. Pervoe - svojstvo ljuboj realizacii na drugih jadrah, vtoroe -
#   oshibka.
#
# Kontrol - plecho bez flaga v tom zhe zapuske. Ono tozhe rashoditsja s llama_decode, potomu
# chto sravnivaetsja nash graf s chuzhim; vazhen naklon RAZNICY mezhdu plechami.
param(
    [string]$Model  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf',
    [int]   $Tokens = 12,
    [int]   $Steps  = 32,
    [int]   $Threads = 8,
    [int]   $LimitMin = 20
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$LOG = 'D:\MemeX\results\static_layers_drift.log'
$PFILE = 'D:\MemeX\results\prompt_short.txt'

function Say($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)
    Write-Host $line
    Add-Content -LiteralPath $LOG -Value $line -Encoding UTF8
}

$null = & $EXE --version 2>&1
if ($LASTEXITCODE -ne 0) { Say ("exe ne zapuskaetsja, kod " + $LASTEXITCODE); exit 1 }

function RunOnce($tag, [string[]]$extra) {
    $so = "D:\MemeX\results\_sldrift_$tag.out"
    $a = @('-m', $Model, '-f', $PFILE, '--tokens', "$Tokens", '-t', "$Threads",
           '--decode-check', "$Steps", '--no-repack') + $extra
    $proc = $null
    try {
        $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { Say ("ne zapustilsja: " + $_.Exception.Message); return $null }
    if ($null -eq $proc) { Say 'Start-Process nichego ne vernul'; return $null }
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) {
        Say "$tag ne uspel - ubivaju"; try { $proc.Kill() } catch {}; return $null
    }
    Say "$tag zakonchil, kod $($proc.ExitCode)"
    return $so
}

function Series($path) {
    $out = @()
    Get-Content -LiteralPath $path -Encoding UTF8 |
        Select-String -Pattern 'шаг +(\d+) \(позиция +\d+\): L2 +([0-9.]+)%' |
        ForEach-Object {
            $m = [regex]::Match($_.Line, 'шаг +(\d+) \(позиция +\d+\): L2 +([0-9.]+)%')
            if ($m.Success) { $out += [pscustomobject]@{ i = [int]$m.Groups[1].Value; l2 = [double]$m.Groups[2].Value } }
        }
    return $out
}

Say 'berjom mashinu pod zamer drejfa'
if (-not (Take-Machine -Who 'static-layers-drift' -TimeoutMin 60)) { Say 'mashinu ne poluchili'; exit 1 }
try {
    $oc = RunOnce 'cpu'  @()
    $ok = RunOnce 'card' @('--gpu-static-layers')
    if (-not $oc -or -not $ok) { exit 1 }
    $sc = Series $oc
    $sk = Series $ok
    Say ("shagov: cpu " + $sc.Count + ", karta " + $sk.Count)
    Say '  shag |   cpu L2 |  karta L2 | otnoshenie'
    for ($i = 0; $i -lt [math]::Min($sc.Count, $sk.Count); $i++) {
        $r = if ($sc[$i].l2 -gt 0) { $sk[$i].l2 / $sc[$i].l2 } else { -1 }
        Say ("  {0,4} | {1,8:F4} | {2,9:F4} | {3,6:F2}" -f $sc[$i].i, $sc[$i].l2, $sk[$i].l2, $r)
    }
    # Naklon po pervoj i vtoroj polovine rjada. Esli u karty vtoraja polovina rastjot
    # otnositelno svoej pervoj silnee, chem u cpu - nakoplenie u nas. Esli odinakovo -
    # nakoplenie prinadlezhit sravneniju s chuzhim grafom, a ne karte.
    function Halves($s) {
        $n = $s.Count; if ($n -lt 4) { return @(-1, -1) }
        $h = [int]($n / 2)
        $a = ($s[0..($h-1)] | Measure-Object -Property l2 -Average).Average
        $b = ($s[$h..($n-1)] | Measure-Object -Property l2 -Average).Average
        return @($a, $b)
    }
    $hc = Halves $sc; $hk = Halves $sk
    Say ("srednee L2: cpu   pervaja polovina {0:F4}%, vtoraja {1:F4}%, otnoshenie {2:F2}" -f $hc[0], $hc[1], ($hc[1]/$hc[0]))
    Say ("srednee L2: karta pervaja polovina {0:F4}%, vtoraja {1:F4}%, otnoshenie {2:F2}" -f $hk[0], $hk[1], ($hk[1]/$hk[0]))
    Say '  esli oba otnoshenija blizki - nakoplenija u karty net sverh togo, chto est u hosta'
} finally {
    Free-Machine
    Say 'mashina osvobozhdena'
}
