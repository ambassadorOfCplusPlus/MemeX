# A/B DVUH BINARNIKOV: vosmiuzlovoj hvost MoE protiv odnogo ggml_mul_multi_add.
#
# Plecho zdes - EXE, a ne flag, potomu chto razlichie na urovne postroenija grafa i flagom ne
# vykljuchaetsja. Snimok "base" snjat s dereva DO pravki i proveren na zapuskaemost;
# arifmetika dvuh binarnikov uzhe svjorena i sovpala do poslednej cifry (98 strok po slojam,
# prefilnye logity 2.6495% / 0.40612, shest shagov dekoda), poetomu zdes izmerjaetsja TOLKO
# skorost, i ljuboe rashozhdenie v tokenah bylo by oshibkoj osnastki, a ne rezultatom.
#
# ---------------------------------------------------------------------------------------
# PREDSKAZANIE, ZAPISANNOE DO PROGONA (pravilo proekta: snachala chislo, potom zamer)
#
# Zadanie stavilo etot rychag kak "29 uzlov -> 8 daet okolo 7.4 ms, 15.0 -> 16.5-17". Ja
# predskazyvaju SUSHCHESTVENNO MENSHE, i vot pochemu - dva raznyh bjudzheta uzlov byli slozheny
# v odin:
#
#   * 29 uzlov - eto graf sloja NA KARTE (gpu_static.cpp). Iz nih tolko 19 dispatchi:
#     ggml_vk_is_empty propuskaet RESHAPE i VIEW, a ih v grafe desjat. Izmereno, predskazanie
#     19/10 sovpalo tochno.
#   * Hvost MoE - eto uzly HOSTA v build_step. V te 29 oni ne popadajut vovse, i cena u nih
#     drugaja: ne 7.2 us dispatcha, a barjer pula potokov na uzel.
#
# Rezhetsja 7 nastojashchih uzlov i 8 vidov na sloj, to est 336 nastojashchih uzlov na tokjen.
# Cena hostovogo uzla pri n_tokens=1 - eto pochti celikom sinhronizacija vosmi potokov nad
# 8-64 KB dannyh; ocenka 0.5-5 us. Otsjuda:
#
#     stat_exp:  tokjen 66.6 ms (15.02 tok/s)  ->  ekonomija 0.17-1.7 ms  ->  15.05-15.4 tok/s
#                to est ot +0.3% do +2.5%, i skoree vsego NIZHE poroga shuma 4.2%
#     cpu:       tokjen 83.5 ms (11.98 tok/s)  ->  ta zhe ekonomija        ->  12.00-12.23
#
# ESLI VYJDET VYSHE 16 - moja model ceny hostovogo uzla nevernaja vtroe, i eto nado skazat
# chislom, a ne perepisat predskazanie zadnim chislom.
#
# Poetomu glavnyj rezultat etoj pravki - NE skorost, a to, chto slitoe napisanie sovpadaet s
# tem, chto realno vypolnjaet llama_decode (fused_mmad po umolchaniju true), i to, chto hvost
# MoE vpervye voobshche s chem-to sverjaetsja.
# ---------------------------------------------------------------------------------------
#
# Porjadok plech menjaetsja po chjotnosti raunda, povtory vperemezhku, srednee po raundu
# pechataetsja - drejf mashiny dolzhen byt viden, a ne razmazan po plecham (pravilo 56:
# porog 4.2% VNUTRISESSIONNYJ, mezhdu sessijami razmah 11.6%).
param(
    [int]    $Reps   = 3,
    [int]    $Ngen   = 192,
    [int]    $Tokens = 512,
    [int]    $Threads = 8,
    [int]    $Resident = 0,
    [string] $Mode   = 'stat_exp',   # stat_exp | cpu
    [switch] $External
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$NEW   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$BASE  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd-base.exe'
$SNEW  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-mfab-new.exe'
$SBASE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-mfab-base.exe'
$MODEL = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG   = 'D:\MemeX\results\moe_fuse_ab.log'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

# Zhdjom SOSTOJANIJA, a ne chasov: progon otdajot 16 GB, i Windows zanuljaet ih fonovym
# potokom. Fiksirovannyj son odnazhdy dal razbrosy 8-28% pri poroge 4.2%.
function Wait-Settled([int]$capSec = 180, [int]$deltaMB = 200) {
    $prev = -1.0
    $deadline = (Get-Date).AddSeconds($capSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB
        if ($prev -ge 0 -and [math]::Abs($free - $prev) -lt $deltaMB) { return $free }
        $prev = $free
    }
    return $prev
}

# $proc, nikogda $p (pravilo 45: PowerShell ne razlichaet registr, a $P - eto put k promptu).
function RunOnce($exe, $tag, [string[]]$extra, [int]$limitSec) {
    $hogs = Get-CpuHogs -MinPct 12
    if ($hogs) {
        Note ('KONKURENTY pered progonom: ' +
              (($hogs | ForEach-Object { "$($_.Name)/$($_.Id) $([math]::Round($_.Pct,0))%" }) -join ', '))
    }
    $so = "D:\MemeX\results\_mfab_$tag.out"
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$Threads",
           '--gen', "$Ngen", '--no-repack') + $extra
    $proc = $null
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { return @{ err = ('ne zapustilsja: ' + $_.Exception.Message) } }
    if ($null -eq $proc) { return @{ err = 'Start-Process nichego ne vernul' } }
    # Pravilo 60: bez chtenija .Handle ExitCode prihodit PUSTYM, a pustoe ne est nol.
    $null = $proc.Handle
    if (-not $proc.WaitForExit($limitSec * 1000)) {
        Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
        $null = Wait-Settled
        return @{ err = 'tajm-aut' }
    }
    $out = @()
    if (Test-Path $so) { $out += Get-Content -LiteralPath $so -Encoding UTF8 }
    if (Test-Path "$so.err") { $out += Get-Content -LiteralPath "$so.err" -Encoding UTF8 }
    $res = @{ err = '' }
    $h = $out | Select-String -Pattern '^STATIC_AB ' | Select-Object -First 1
    if ($h -and $h.Line -match 'our_tok_s ([\d.]+) ref_tok_s ([\d.]+)') {
        $res.gen = [double]$Matches[1]
        $res.ref = [double]$Matches[2]
    }
    $l = $out | Select-String -Pattern 'na tokjen ([\d.]+) ms; zaborov' | Select-Object -First 1
    if ($l -and $l.Line -match 'na tokjen ([\d.]+) ms') { $res.layer = [double]$Matches[1] }
    $f = $out | Select-String -Pattern 'USTROJSTVO OTKAZALO|OTKAZALO' | Select-Object -First 1
    if ($f) { $res.err = $f.Line.Trim() }
    if (-not $res.ContainsKey('gen') -and $res.err -eq '') {
        $bad = $out | Select-String -Pattern 'not supported|failed|abort|assert|nelzja' |
               Select-Object -First 1
        $res.err = if ($bad) { $bad.Line.Trim() } else { "net stroki STATIC_AB (exit $($proc.ExitCode))" }
    }
    $null = Wait-Settled
    return $res
}

function Summ($name, $vals) {
    $v = @($vals | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return ("{0,-18} --" -f $name) }
    $mean = ($v | Measure-Object -Average).Average
    # Pravilo 44: odnomu povtoru ne s chem raznoglasit, i ego 0.0% - eto otsutstvie proverki.
    if ($v.Count -lt 2) { return ("{0,-18} {1,7:N2} (1 povtor - NE REZULTAT)" -f $name, $mean) }
    $sp = 100.0 * (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $mean
    $flag = if ($sp -gt 4.2) { ' RAZBROS VYSHE POROGA' } else { '' }
    return ("{0,-18} {1,7:N2} (razbros {2,4:N1}%, n={3}){4}" -f $name, $mean, $sp, $v.Count, $flag)
}

("`n`n######## moe_fuse A/B " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8

foreach ($f in @($NEW, $BASE, $PROMPT)) {
    if (-not (Test-Path -LiteralPath $f)) { Note "net fajla: $f"; exit 1 }
}
# Snimki oboih plech pod svoimi imenami: sborka, nachavshajasja poseredine A/B, inache
# podmenit plecho mezhdu povtorami, i raznica plech stanet raznicej binarnikov.
Copy-Item -LiteralPath $NEW  -Destination $SNEW  -Force
Copy-Item -LiteralPath $BASE -Destination $SBASE -Force
foreach ($f in @($SNEW, $SBASE)) {
    $null = & $f --version *> $null
    $hc = $LASTEXITCODE
    # Pravilo 49: zapuskaemost dokazyvaetsja do sbora dannyh. -1073741511 nesootvetstvie DLL
    # i exe, -1073741515 DLL ne najdena; oba proishodjat do pervogo napechatannogo simvola.
    if ($null -eq $hc -or $hc -ne 0) { Note "snimok ne zapuskaetsja: $f (exit $hc)"; exit 1 }
}

$extra = if ($Mode -eq 'cpu') { @() } else { @('--gpu-static-layers', '--gpu-experts', '--resident', "$Resident") }
$arms = @(
    @{ t = 'base'; x = $SBASE },
    @{ t = 'new';  x = $SNEW }
)
$acc = @{}
foreach ($arm in $arms) { $acc[$arm.t] = @{ gen = @(); ref = @(); layer = @() } }

if (-not $External) {
    Say 'berjom mashinu pod A/B'
    if (-not (Take-Machine -Who 'moe-fuse-ab' -TimeoutMin 90)) { Note 'mashinu ne poluchili'; exit 1 }
}
try {
    Say ("A/B hvosta MoE: rezhim $Mode, raundov $Reps, --gen $Ngen, --tokens $Tokens, t=$Threads")
    for ($r = 1; $r -le $Reps; $r++) {
        # Progrev na vybros. Pervaja zagruzka 15 GB s diska i pervoe zapolnenie stranichnogo
        # kesha dostajutsja celikom pervomu plechu pervogo raunda, i perestanovka porjadka
        # etogo NE lechit: ona lechit sistematicheskij naklon, a ne odnokratnyj vybros v
        # nachale. Bez nejo pervyj progon etogo skripta dal raund 1 = 14.04 protiv raunda
        # 2 = 15.28, i vsja raznica plech okazalas raznicej raundov.
        if ($r -eq 1) {
            Say 'progrev: odna zagruzka na vybros, chisla iz nejo ne idut nikuda'
            $w = RunOnce $SBASE 'warm' $extra 900
            if ($w.err -ne '') { Note ('progrev NE POSHJOL: ' + $w.err) }
            else               { Note ('progrev: {0:N2} tok/s - VYBROSHENO' -f $w.gen) }
        }
        $order = if ($r % 2 -eq 1) { $arms } else { $arms[($arms.Count-1)..0] }
        $thisRound = @()
        foreach ($arm in $order) {
            $res = RunOnce $arm.x "$($arm.t)_$r" $extra 900
            if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
            $acc[$arm.t].gen += $res.gen
            $acc[$arm.t].ref += $res.ref
            if ($res.ContainsKey('layer')) { $acc[$arm.t].layer += $res.layer }
            $thisRound += $res.gen
            Note ("raund {0} {1,-5} {2,6:N2} tok/s (etalon {3,5:N2})" -f $r, $arm.t, $res.gen, $res.ref)
        }
        if ($thisRound.Count -eq $arms.Count) {
            $rm = ($thisRound | Measure-Object -Average).Average
            Note ('raund {0}: srednee po plecham {1:N2} tok/s' -f $r, $rm)
        } else {
            Note ("raund ${r}: plech proshlo $($thisRound.Count) iz $($arms.Count) - srednee ne schitaetsja")
        }
    }
    Say 'ITOG'
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) tok/s") $acc[$arm.t].gen) }
    # etalon - KONTROL: llama_decode ne znaet ni o karte, ni o nashem grafe, poetomu esli on
    # dvizhetsja mezhdu plechami, dvigalas mashina.
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) etalon") $acc[$arm.t].ref) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) sloj ms") $acc[$arm.t].layer) }
    if ($acc['base'].gen.Count -ge 2 -and $acc['new'].gen.Count -ge 2) {
        $b = ($acc['base'].gen | Measure-Object -Average).Average
        $n = ($acc['new'].gen  | Measure-Object -Average).Average
        Note ('new protiv base: {0:N2} protiv {1:N2} = {2:+0.0;-0.0}%' -f $n, $b, (100.0*($n-$b)/$b))
    }
} finally {
    if (-not $External) { Free-Machine; Say 'mashina osvobozhdena' }
}
