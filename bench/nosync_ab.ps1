# POTOLOK BARJERA na nastojashchem grafe: GGML_VK_NO_SYNC=0 protiv =1.
#
# CHTO ZDES IZMERJAETSJA I CHEGO ZDES NE IZMERJAETSJA.
#
# S NO_SYNC=1 arifmetika NE verna - barjery snjaty vse, vkljuchaja te, chto derzhat nastojashchie
# zavisimosti. Poetomu eto ne plecho-kandidat, a POTOLOK: uslovnyj barjer ne mozhet obognat
# polnoe otsutstvie barjerov, znachit vsjo, chto zdes ne najdjotsja, iskat v uslovnoj versii
# nezachem. Tochnost pri njom smotret bessmyslenno i ejo zdes ne smotrjat.
#
# OTKUDA VZJALSJA VOPROS. Zond vksplit, izmerenie 1b, cepochka protiv veera na 32 uzlah:
#
#     NO_SYNC=0    cepochka 200.23 us   veer 199.72   otnoshenie 1.003x
#     NO_SYNC=1    cepochka 117.35 us   veer 115.23   otnoshenie 1.018x
#
# Dva vyvoda, i vtoroj vazhnee pervogo.
#
# Pervyj: otnoshenie ostalos 1.00 i bez barjerov. Znachit "nichego ne perekryvaetsja" - eto
# svojstvo USTROJSTVA, a ne barjera, i gipoteza zadanija ("barjer meshaet nezavisimym
# dispatcham idti vmeste") oprovergnuta. Snjatie barjera perekrytija ne otkryvaet.
#
# Vtoroj: pri etom absoljutnaja cena upala na 41%. (200.23 - 117.35) / 32 = **2.59 us na
# dispatch** - sam barjer, a ne to, chto on zapreshchaet. Eto 36% ot izmerennyh 7.2 us na
# dispatch. Barjer polnyj: vse stadii, vse dostupy, vkljuchaja transfer read/write, to est na
# AMD eto sbros i invalidacija L2 pered kazhdym dispatchem.
#
# PREDSKAZANIE, ZAPISANNOE DO PROGONA. V grafe sloja 19 dispatchej, znachit 19 x 2.59 = 49 us
# na peresechenie, 49 peresechenij na tokjen = 2.4 ms:
#
#     sloj ms na tokjen   29.65  ->  ~27.2   (-8.2%)
#     tok/s               15.20  ->  15.6-15.8  (+2..+4%)
#
# CHITAT NADO "sloj ms", A NE tok/s, i eto glavnoe reshenie ob osnastke zdes. Razbros tok/s
# 1.6-1.8% pri poroge 4.2%, a predskazannyj effekt 3% - to est na tok/s on nerazlichim v
# principe. Razbros "sloj ms" 0.9-1.0%, a predskazannyj effekt tam 8%. Velichinu nado brat tu,
# u kotoroj otnoshenie effekta k razbrosu bolshe, i eto ne ta, v kotoroj stavitsja cel.
#
# Esli "sloj ms" ne dvinetsja - barjery v nashem grafe stojat inache, chem v zonde, i cifru 2.59
# nelzja perenosit; togda eto nado skazat i ostanovitsja, a ne iskat tretju metriku.
param(
    [int]    $Reps   = 3,
    [int]    $Ngen   = 192,
    [int]    $Tokens = 512,
    [int]    $Threads = 8,
    [switch] $External
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$SNAP  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-nosync-snap.exe'
$MODEL = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG   = 'D:\MemeX\results\nosync_ab.log'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

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

# $proc, nikogda $p (pravilo 45).
function RunOnce($tag, [string]$nosync, [int]$limitSec) {
    $hogs = Get-CpuHogs -MinPct 12
    if ($hogs) {
        Note ('KONKURENTY pered progonom: ' +
              (($hogs | ForEach-Object { "$($_.Name)/$($_.Id) $([math]::Round($_.Pct,0))%" }) -join ', '))
    }
    $so = "D:\MemeX\results\_nsab_$tag.out"
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$Threads",
           '--gen', "$Ngen", '--no-repack', '--gpu-static-layers', '--gpu-experts',
           '--resident', '0')
    # Pravilo 68: ggml chitaet eti peremennye odin raz, pri sozdanii vk_device, i ustrojstvo
    # sozdajot zagruzchik modeli - to est ranshe ljubogo nashego koda. Stavit ih nado v
    # okruzhenii DOCHERNEGO processa do ego starta, chto Start-Process i delaet, unasleduja
    # tekushchee okruzhenie. GGML_VK_SUBMIT_STATS=1 pechataet, PRIMENILAS li nastrojka - bez
    # etogo neprimenivshajasja nastrojka neotlichima ot bespoleznoj.
    $env:GGML_VK_NO_SYNC = $nosync
    $env:GGML_VK_SUBMIT_STATS = '1'
    $proc = $null
    try {
        $proc = Start-Process -FilePath $SNAP -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { return @{ err = ('ne zapustilsja: ' + $_.Exception.Message) } }
    if ($null -eq $proc) { return @{ err = 'Start-Process nichego ne vernul' } }
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
    # Prinjalas li nastrojka. Bez etoj proverki plecho "ne pomoglo" nerazlichimo s plechom
    # "ne vkljuchilos", a eto dve protivopolozhnye novosti (pravilo 68).
    $b = $out | Select-String -Pattern 'barjery: vydano (\d+), propushcheno (\d+)' | Select-Object -First 1
    if ($b -and $b.Line -match 'vydano (\d+), propushcheno (\d+)') {
        $res.issued  = [double]$Matches[1]
        $res.skipped = [double]$Matches[2]
    }
    if (-not $res.ContainsKey('gen') -and $res.err -eq '') {
        $bad = $out | Select-String -Pattern 'not supported|failed|abort|assert|OTKAZALO' |
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
    if ($v.Count -lt 2) { return ("{0,-18} {1,7:N2} (1 povtor - NE REZULTAT)" -f $name, $mean) }
    $sp = 100.0 * (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $mean
    $flag = if ($sp -gt 4.2) { ' RAZBROS VYSHE POROGA' } else { '' }
    return ("{0,-18} {1,7:N2} (razbros {2,4:N1}%, n={3}){4}" -f $name, $mean, $sp, $v.Count, $flag)
}

("`n`n######## nosync A/B " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8
if (-not (Test-Path -LiteralPath $EXE)) { Note "net binarnika: $EXE"; exit 1 }
Copy-Item -LiteralPath $EXE -Destination $SNAP -Force
$null = & $SNAP --version *> $null
if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) { Note "snimok ne zapuskaetsja"; exit 1 }

$arms = @(
    @{ t = 'sync';   v = '0' },
    @{ t = 'nosync'; v = '1' }
)
$acc = @{}
foreach ($arm in $arms) { $acc[$arm.t] = @{ gen = @(); ref = @(); layer = @() } }

if (-not $External) {
    Say 'berjom mashinu pod A/B barjera'
    if (-not (Take-Machine -Who 'nosync-ab' -TimeoutMin 90)) { Note 'mashinu ne poluchili'; exit 1 }
}
try {
    Say ("potolok barjera: raundov $Reps, --gen $Ngen, --tokens $Tokens, t=$Threads")
    for ($r = 1; $r -le $Reps; $r++) {
        if ($r -eq 1) {
            Say 'progrev na vybros'
            $w = RunOnce 'warm' '0' 900
            if ($w.err -ne '') { Note ('progrev NE POSHJOL: ' + $w.err) }
            else               { Note ('progrev: {0:N2} tok/s - VYBROSHENO' -f $w.gen) }
        }
        $order = if ($r % 2 -eq 1) { $arms } else { $arms[($arms.Count-1)..0] }
        foreach ($arm in $order) {
            $res = RunOnce "$($arm.t)_$r" $arm.v 900
            if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
            $acc[$arm.t].gen += $res.gen
            $acc[$arm.t].ref += $res.ref
            if ($res.ContainsKey('layer')) { $acc[$arm.t].layer += $res.layer }
            $bar = if ($res.ContainsKey('issued')) {
                ("barjerov vydano {0:N0}, propushcheno {1:N0}" -f $res.issued, $res.skipped)
            } else { 'STROKI O BARJERAH NET - nastrojka ne podtverzhdena' }
            Note ("raund {0} {1,-7} {2,6:N2} tok/s (etalon {3,5:N2}, sloj {4,5:N2} ms) {5}" -f
                  $r, $arm.t, $res.gen, $res.ref, $res.layer, $bar)
        }
    }
    Say 'ITOG'
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) tok/s") $acc[$arm.t].gen) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) sloj ms") $acc[$arm.t].layer) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) etalon") $acc[$arm.t].ref) }
    if ($acc['sync'].layer.Count -ge 2 -and $acc['nosync'].layer.Count -ge 2) {
        $a1 = ($acc['sync'].layer   | Measure-Object -Average).Average
        $a2 = ($acc['nosync'].layer | Measure-Object -Average).Average
        Note ('sloj ms: {0:N2} -> {1:N2} = {2:+0.0;-0.0}%  (predskazano -8.2%)' -f $a1, $a2, (100.0*($a2-$a1)/$a1))
    }
    if ($acc['sync'].gen.Count -ge 2 -and $acc['nosync'].gen.Count -ge 2) {
        $g1 = ($acc['sync'].gen   | Measure-Object -Average).Average
        $g2 = ($acc['nosync'].gen | Measure-Object -Average).Average
        Note ('tok/s:   {0:N2} -> {1:N2} = {2:+0.0;-0.0}%  (predskazano +2..+4%)' -f $g1, $g2, (100.0*($g2-$g1)/$g1))
    }
} finally {
    Remove-Item Env:GGML_VK_NO_SYNC -EA SilentlyContinue
    Remove-Item Env:GGML_VK_SUBMIT_STATS -EA SilentlyContinue
    if (-not $External) { Free-Machine; Say 'mashina osvobozhdena' }
}
