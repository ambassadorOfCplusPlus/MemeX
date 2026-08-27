# A/B puti cherez kartu: tri plecha v ODNOJ sessii, povtory vperemezhku, porjadok plech
# menjaetsja po raundam.
#
# POCHEMU IMENNO TAK, i eto ne oformlenie.
#
# Porog shuma 4.2% - VNUTRISESSIONNYJ. Odin neizmennyj binarnik za sutki dal 11.99 / 13.38 /
# 12.95 / 12.21, to est razmah 11.6% mezhdu sessijami pri chistyh razbrosah vnutri kazhdoj.
# Poetomu sravnivat mezhdu dnjami nelzja voobshche, a vnutri dnja - tolko plechi, snjatye
# vperemezhku. Odin polden byl potrachen na "regressiju 7.6%", kotoraja okazalas raznicej
# mezhdu dvumja sostojanijami mashiny.
#
# Porjadok plech menjaetsja po chjotnosti raunda: esli mashina medlenno progrevaetsja ili
# medlenno zagrjaznjaetsja, fiksirovannyj porjadok otdajot pervomu plechu sistematicheskoe
# preimushchestvo, i eto neotlichimo ot rezultata.
#
# etalon (ref_tok_s) - KONTROL. llama_decode ne znaet o karte vovse, poetomu esli on
# dvizhetsja mezhdu plechami, dvigalas mashina, a ne plecho.
param(
    [int]    $Reps   = 3,
    [int]    $Ngen   = 192,
    [int]    $Tokens = 512,
    [int]    $Threads = 8,
    [int]    $Resident = 0,      # 0 - jomkost vybiraetsja po svobodnoj videopamjati
    [switch] $NoExperts,         # tolko dva plecha: cpu i statika
    [switch] $ExpAlone,          # dobavit plecho "eksperty bez statiki" - razdeljaet rychagi
    [switch] $External           # zamok u vyzyvajushchego
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$SNAP   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-ab-snapshot.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\static_ab.log'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

# Zhdjom SOSTOJANIJA, a ne chasov. Kazhdyj progon derzhit okolo 16 GB i otdajot ih na vyhode,
# a Windows zanuljaet osvobozhdjonnye stranicy fonovym potokom - fiksirovannyj son startuet
# sledujushchij povtor v konkurencii s uborkoj za predydushchim. Pjatnadcati sekund odnazhdy ne
# hvatilo i eto dalo razbrosy 8-28% pri poroge 4.2%.
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

# $proc, nikogda $p: dvazhdy proekt terjal povtory 2 i 3 kazhdogo plecha iz-za lokalnoj
# peremennoj, nazvannoj kak odnobukvennaja skriptovaja - PowerShell ne razlichaet registr.
function RunOnce($tag, [string[]]$extra, [int]$limitSec) {
    $hogs = Get-CpuHogs -MinPct 12
    if ($hogs) {
        Note ('KONKURENTY pered progonom: ' +
              (($hogs | ForEach-Object { "$($_.Name)/$($_.Id) $([math]::Round($_.Pct,0))%" }) -join ', '))
    }
    $so = "D:\MemeX\results\_sab_$tag.out"
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$Threads",
           '--gen', "$Ngen", '--no-repack') + $extra
    $proc = $null
    try {
        $proc = Start-Process -FilePath $SNAP -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { return @{ err = ('ne zapustilsja: ' + $_.Exception.Message) } }
    if ($null -eq $proc) { return @{ err = 'Start-Process nichego ne vernul' } }
    # Pravilo 55: bez chtenija .Handle ExitCode prihodit PUSTYM, a pustoe sravnivaetsja s nulem
    # kak neravnoe - i uspeshnyj shag otchityvaetsja kak upavshij.
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
    if ($h -and $h.Line -match 'our_tok_s ([\d.]+) ref_tok_s ([\d.]+) gen_ms ([\d.]+) n_gen (\d+) head_ms ([\d.]+) static (\d)') {
        $res.gen = [double]$Matches[1]
        $res.ref = [double]$Matches[2]
        $res.head = [double]$Matches[5]
    }
    $l = $out | Select-String -Pattern 'na tokjen ([\d.]+) ms; zaborov' | Select-Object -First 1
    if ($l -and $l.Line -match 'na tokjen ([\d.]+) ms') { $res.layer = [double]$Matches[1] }
    $c = $out | Select-String -Pattern 'попаданий ([\d.]+)%' | Select-Object -Last 1
    if ($c -and $c.Line -match 'попаданий ([\d.]+)%') { $res.hit = [double]$Matches[1] }
    $f = $out | Select-String -Pattern 'USTROJSTVO OTKAZALO|OTKAZALO|поток устройства упал' | Select-Object -First 1
    if ($f) { $res.err = $f.Line.Trim() }
    if (-not $res.ContainsKey('gen') -and $res.err -eq '') {
        $bad = $out | Select-String -Pattern 'not supported|failed|abort|assert|--gpu-static|--gpu-experts' |
               Select-Object -First 1
        $res.err = if ($bad) { $bad.Line.Trim() } else { "net stroki STATIC_AB (exit $($proc.ExitCode))" }
    }
    $null = Wait-Settled
    return $res
}

# Srednee s razbrosom rjadom, i IMJA vmesto chisla, kogda usrednjat nechego. Odin povtor ne
# imeet s chem raznoglasit, poetomu ego 0.0% - eto otsutstvie proverki, a ne tihaja mashina.
function Summ($name, $vals) {
    $v = @($vals | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return ("{0,-16} --" -f $name) }
    $mean = ($v | Measure-Object -Average).Average
    if ($v.Count -lt 2) { return ("{0,-16} {1,7:N2} (1 povtor - NE REZULTAT)" -f $name, $mean) }
    $sp = 100.0 * (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $mean
    $flag = if ($sp -gt 4.2) { ' RAZBROS VYSHE PORoga' } else { '' }
    return ("{0,-16} {1,7:N2} (razbros {2,4:N1}%, n={3}){4}" -f $name, $mean, $sp, $v.Count, $flag)
}

("`n`n######## static A/B " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8

if (-not (Test-Path -LiteralPath $EXE))    { Note "net binarnika: $EXE"; exit 1 }
if (-not (Test-Path -LiteralPath $PROMPT)) { Note "net promta: $PROMPT"; exit 1 }

# Snimok binarnika pod svoim imenem. Sborka, nachavshajasja poseredine A/B, inache podmenit
# plecho mezhdu povtorami - i raznica mezhdu plechami stanet raznicej mezhdu binarnikami.
Copy-Item -LiteralPath $EXE -Destination $SNAP -Force
# Pravilo 49: dokazat zapuskaemost DO sbora dannyh. -1073741511 - nesootvetstvie DLL i exe,
# -1073741515 - DLL ne najdena, i oba proishodjat do pervogo napechatannogo simvola.
$null = & $SNAP --version *> $null
$hc = $LASTEXITCODE
if ($null -eq $hc -or $hc -ne 0) { Note "snimok binarnika ne zapuskaetsja (exit $hc)"; exit 1 }

$arms = @(
    @{ t = 'cpu';    e = @() },
    @{ t = 'stat';   e = @('--gpu-static-layers') }
)
if (-not $NoExperts) {
    $arms += @{ t = 'stat_exp'; e = @('--gpu-static-layers', '--gpu-experts', '--resident', "$Resident") }
}
# Chetvjortoe plecho razdeljaet dva rychaga, kotorye inache smesheny v odnom chisle. Bez
# statiki na karte u ekspertov BOLSHE videopamjati (846 MiB osvobozhdajutsja, to est plus
# okolo sedmi ekspertov na sloj), tak chto eto ne "ta zhe shema minus statika" - eto drugaja
# raskladka, i imenno poetomu ejo nado izmerit, a ne vychest.
if ($ExpAlone) {
    $arms += @{ t = 'exp'; e = @('--gpu-experts', '--resident', "$Resident") }
}

# Zamok berjotsja NA RAUND, a ne na vsjo A/B. Vtoroj proekt delit etu mashinu pod tem zhe
# zamkom, i ego progony uzhe tri raza padali po tajm-autu iz-za nashih neotpuskaemyh blokov;
# dogovor - ne bolshe 20 minut podrjad i ne menshe 5 minut pauzy. Raund iz trjoh plech
# ukladyvaetsja v 20, i pri etom vsja tablica ostajotsja ODNOJ sessiej: sravnimost mezhdu
# plechami derzhitsja na tom, chto oni snjaty vperemezhku, a ne na tom, chto zamok ne otpuskali.
$ownsLock = -not $External

$acc = @{}
foreach ($arm in $arms) { $acc[$arm.t] = @{ gen = @(); ref = @(); head = @(); layer = @(); hit = @() } }

try {
    Say ("A/B: raundov $Reps, plech " + $arms.Count + ", --gen $Ngen, --tokens $Tokens, prompt $PROMPT")
    for ($r = 1; $r -le $Reps; $r++) {
        if ($ownsLock) {
            if ($r -gt 1) { Note 'pauza 5 minut - mashina svobodna dlja sosednego proekta'; Start-Sleep -Seconds 300 }
            if (-not (Take-Machine -Who 'static-ab' -TimeoutMin 120 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; break }
            Note ('vladeem: ' + (Get-LockHolder))
        }
        # Porjadok plech perevorachivaetsja kazhdyj vtoroj raund.
        $order = if ($r % 2 -eq 1) { $arms } else { $arms[($arms.Count-1)..0] }
        Say ("raund $r / $Reps, porjadok: " + (($order | ForEach-Object { $_.t }) -join ' -> '))
        foreach ($arm in $order) {
            $res = RunOnce ("$($arm.t)_$r") $arm.e 1200
            if ($res.err) { Note ("$($arm.t) NE POSHLO: " + $res.err); continue }
            $line = "{0,-9} {1,7:N2} tok/s   etalon {2,6:N2}" -f $arm.t, $res.gen, $res.ref
            if ($res.ContainsKey('head'))  { $line += ("   golova {0:N3} ms" -f $res.head) }
            if ($res.ContainsKey('layer')) { $line += ("   sloi {0:N2} ms/tok" -f $res.layer) }
            if ($res.ContainsKey('hit'))   { $line += ("   popadanij {0:N1}%" -f $res.hit) }
            Note $line
            $acc[$arm.t].gen += $res.gen
            $acc[$arm.t].ref += $res.ref
            if ($res.ContainsKey('head'))  { $acc[$arm.t].head  += $res.head }
            if ($res.ContainsKey('layer')) { $acc[$arm.t].layer += $res.layer }
            if ($res.ContainsKey('hit'))   { $acc[$arm.t].hit   += $res.hit }
        }
        if ($ownsLock) { Free-Machine; Note 'zamok otpushchen do sledujushchego raunda' }
    }

    Say 'itog'
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) tok/s") $acc[$arm.t].gen) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) etalon") $acc[$arm.t].ref) }
    foreach ($arm in $arms) {
        if ($acc[$arm.t].layer.Count -gt 0) { Note (Summ ("$($arm.t) sloi ms") $acc[$arm.t].layer) }
        if ($acc[$arm.t].hit.Count -gt 0)   { Note (Summ ("$($arm.t) popadanij") $acc[$arm.t].hit) }
    }
    $base = @($acc['cpu'].gen)
    if ($base.Count -ge 2) {
        $mb = ($base | Measure-Object -Average).Average
        foreach ($arm in $arms) {
            if ($arm.t -eq 'cpu') { continue }
            $v = @($acc[$arm.t].gen)
            if ($v.Count -lt 2) { Note ("$($arm.t): menshe dvuh povtorov - ne rezultat"); continue }
            $mv = ($v | Measure-Object -Average).Average
            Note ("{0,-9} protiv cpu: {1,+7:N2}%  ({2:N2} -> {3:N2} tok/s, {4:N2} -> {5:N2} ms/tokjen)" -f
                  $arm.t, (100.0 * ($mv - $mb) / $mb), $mb, $mv, (1000.0/$mb), (1000.0/$mv))
        }
        # Kontrol. Etalon ne znaet o karte, poetomu ego dvizhenie mezhdu plechami - eto
        # dvizhenie mashiny, a ne plecha, i togda vsja tablica nedejstvitelna.
        $refs = @()
        foreach ($arm in $arms) { if ($acc[$arm.t].ref.Count -gt 0) { $refs += ($acc[$arm.t].ref | Measure-Object -Average).Average } }
        if ($refs.Count -ge 2) {
            $rs = 100.0 * (($refs | Measure-Object -Maximum).Maximum - ($refs | Measure-Object -Minimum).Minimum) /
                  (($refs | Measure-Object -Average).Average)
            Note ("KONTROL: etalon mezhdu plechami rashoditsja na {0:N1}%{1}" -f $rs,
                  $(if ($rs -gt 4.2) { ' - MASHINA DVIGALAS, tablica nedejstvitelna' } else { ' - v predelah shuma' }))
        }
    } else {
        Note 'plecho cpu dalo menshe dvuh povtorov - sravnivat ne s chem'
    }
} finally {
    # Idempotentno: Free-Machine na neuderzhivaemom zamke - pustaja operacija, a ostavlennyj
    # zamok posle padenija skripta stoil ocheredi dvazhdy.
    if ($ownsLock) { Free-Machine; Note 'mashina osvobozhdena' }
}
