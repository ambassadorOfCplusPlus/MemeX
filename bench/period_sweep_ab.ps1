# PERIOD OBNOVLENIJA NABORA: 3 (baza) -> 16 -> 32 -> 64 -> zamorozhennyj kak potolok.
#
# OTKUDA VOPROS. Svip bjudzheta zakonchilsja neozhidannym: zamorozhennyj nabor - samoe bystroe
# plecho, +10,5% k tokjenu (14,798 -> 16,347), a popadanija terjajut vsego 2,25 punkta
# (71,57 -> 69,32). Vyigrysh polnostju objasnjaetsja tem, chto podkachka DERZHIT POTOK KARTY,
# kotorogo processornaja polovina zhdjot na dzhojne: ZHDJOM 11,34 -> 7,39 (-3,95 ms) i sloj
# 29,72 -> 27,71 (-2,0 ms), a summa 5,95 ms pokryvaet 6,41 ms, na kotorye ukorotilsja tokjen.
# Gipoteza polosy OZU oproverglas na svojom sobstvennom stolbce: CPU/tok ne dvinulsja vovse
# (16,460 -> 16,421).
#
# I bjudzhet okazalsja NE tem rychagom: budget 2 protiv budget 8 dajot 6,72 podkachki na tokjen
# protiv 6,91, potomu chto bjudzhet dejstvuet POSLOJNO i POREFRESHNO, a LFU prosit menshe dvuh
# na sloj za obnovlenie. Rychag - PERIOD.
#
# Zamorozka naveki - eto zamer, a ne konstrukcija: nabor ustarel by na dlinnoj generacii i na
# smene temy. Ustojchivost izmerena i ona ploskaja po k (47,8% na k=1, 52,3% na k=20), znachit
# period 32-64 dolzhen zabrat bolshuju chast +10,5% i sohranit adaptaciju. Adaptacija
# proverjaetsja OTDELNYM skriptom (period_adapt.ps1) i skorost zdes bez nejo nichego ne reshaet.
#
# PREDSKAZANIE, ZAPISANNOE DO PROGONA.
#
# Iz chego ono sdelano. Obnovlenie proishodit raz v P tokenov; pri P=3 izmereno 6,906 podkachki
# na tokjen, to est 20,7 podkachki na obnovlenie na 48 sloev = 0,43 na sloj (bjudzhet 8 nikogda
# ne svjazyval). Esli udlinit period, drejf mezhdu obnovlenijami nakaplivaetsja, no NE linejno -
# ustojchivost ploskaja po k, i okno vsego 64 tokena. Zhdu, chto podkachek na obnovlenie
# vyrastet primerno vdvoe ot P=3 k P=64, to est podkachek NA TOKJEN padaet primerno kak 1/P
# s popravkoj 1,4 / 1,7 / 2,1.
#
# Cena tokjena: frozen otdal 6,41 ms, i eto cena vsej podkachki. Znachit ekonomija plecha
# = 6,41 * (1 - podkachek(P)/6,906).
#
#     plecho     podkachek/tok  popadanij   promo_ms/tok  zhdjom/tok  sloj ms   tok/s
#     period3        6,91        71,6%          8,99        11,34      29,72   14,80  (izmereno)
#     period16     1,6-2,1     71,0-71,4%     2,1-2,7      8,3-9,0   28,2-28,6  15,8-16,0
#     period32     0,9-1,3     70,6-71,1%     1,2-1,7      7,8-8,4   27,9-28,3  16,0-16,2
#     period64     0,5-0,9     70,0-70,8%     0,7-1,2      7,6-8,1   27,8-28,1  16,1-16,3
#     frozen         0,00        69,3%          0,00         7,39      27,71   16,35  (izmereno)
#
# PERELOM ZHDU MEZHDU 3 I 16: P=16 zabiraet ~70-75% ot +10,5%, P=32 ~85%, P=64 ~90%. To est
# rekomendacija, kotoruju ja ozhidaju uvidet, - P=32: pochti vsja skorost i tri perioda na
# vosstanovlenie posle smeny domena.
#
# CHTO OPROVERGAET PREDSKAZANIE, i chitat nado imenno eto, a ne tok/s:
#   * podkachek/tok NE padaet kak ~1/P (ostajotsja pochti 6,9) - togda podkachek na obnovlenie
#     rastjot linejno s periodom, period tozhe ne rychag, i vsja postanovka zadachi 1 mertva.
#     Eto glavnoe chislo v tablice, i u nego razbros 0,0%.
#   * tok/s pri P=64 VYSHE zamorozhennogo plecha - togda mehanizm ne "podkachka derzhit potok",
#     potomu chto nol podkachek objazan byt potolkom.
#   * tok/s ne monotonen po P pri razbrosah pod procentom - togda dvizhet chto-to tretje.
#
# ZAODNO ZAKRYVAETSJA ZADACHA 3. Plecho period3 - eto v tochnosti plecho budget8 iz predydushchego
# svipa (period 3, bjudzhet 8), poetomu ono sluzhit dvazhdy: kak baza svipa i kak proverka, chto
# novaja instrumentacija podkachki besplatna (promo_ms_tok objazan vernutsja 8,99, pravilo 69).
# I ono dajot razlozhenie 1,30 ms podkachki na chtenie / zapis kopii / submit s zaborom /
# ostatok - edinstvennyj chlen, nikogda ne merennyj.
#
# PREDSKAZANIE PO RAZLOZHENIJU, do progona. Chtenie - eto memcpy 2,51 MB iz otobrazhenija v
# zakreplennuju pamjat, to est 5,02 MB hostovogo trafika na ODNOM jadre, a 0,10 ms emu pripisali
# deleniem na SOVOKUPNUJU polosu mashiny 24,8 GB/s. Odno jadro takoj kopii dajot 5-7 GB/s:
#
#     chtenie        0,35-0,50 ms   (a ne 0,10, kotorye emu pripisany)
#     zapis kopii    0,02-0,10      (batch_set_tensor tolko zapisyvaet komandu)
#     submit+zabor   0,70-0,85      (vnutri nego i idjot sama DMA po PCIe)
#     OSTATOK        okolo nulja
#     -------------------------------------------
#     vsego          1,30 (izmereno)
#
# Esli chtenie okazhetsja <= 0,15 ms, to dyra ne v njom, i sledujushchij podozrevaemyj nazvan
# zaranee: eto ochered i bloki v worker_loop VNE upload(), kotorye vhodjat v ms_promote i ne
# vhodjat ni v odin iz trjoh zondov - imenno ih i pokazhet stroka OSTATOK.
#
# Napisano latinicej: PowerShell zdes chitaet fajl bez metki kak ANSI.
param(
    [int]    $Reps    = 2,
    [int]    $Ngen    = 192,
    [int]    $Tokens  = 512,
    [int]    $Threads = 8,
    [int]    $RestMin = 5,
    [switch] $External
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$SNAP   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-period-snap.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\period_sweep_ab.log'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

# Pauza po SOSTOJANIJU, ne po vremeni (pravilo 51).
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
function RunOnce($tag, [string[]]$extra, [int]$limitSec) {
    $hogs = Get-CpuHogs -MinPct 12
    if ($hogs) {
        Note ('KONKURENTY pered progonom: ' +
              (($hogs | ForEach-Object { "$($_.Name)/$($_.Id) $([math]::Round($_.Pct,0))%" }) -join ', '))
    }
    $so = "D:\MemeX\results\_psab_$tag.out"
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$Threads",
           '--gen', "$Ngen", '--no-repack', '--gpu-static-layers', '--gpu-experts',
           '--resident', '0') + $extra
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
    $p2 = $out | Select-String -Pattern '^PROMO_AB ' | Select-Object -First 1
    if ($p2) {
        $ln = $p2.Line
        if ($ln -match 'match (\d+) of (\d+)')       { $res.match = [int]$Matches[1]; $res.of = [int]$Matches[2] }
        if ($ln -match ' promo (\d+) batches (\d+)') { $res.promo = [int]$Matches[1]; $res.batches = [int]$Matches[2] }
        if ($ln -match 'promo_ms_tok ([\d.]+)')      { $res.promo_ms = [double]$Matches[1] }
        if ($ln -match 'ms_per_promo ([\d.]+)')      { $res.per_promo = [double]$Matches[1] }
        if ($ln -match 'join_wait_tok ([\d.]+)')     { $res.wait = [double]$Matches[1] }
        if ($ln -match ' job_tok ([\d.]+)')          { $res.job = [double]$Matches[1] }
        if ($ln -match ' cpu_tok ([\d.]+)')          { $res.cpu = [double]$Matches[1] }
        if ($ln -match ' budget (-?\d+) frozen (\d+) hits ([\d.]+)') {
            $res.budget = [int]$Matches[1]
            $res.frozen = [int]$Matches[2]
            $res.hits   = [double]$Matches[3]
        }
        if ($ln -match ' period (-?\d+) capacity (\d+)') {
            $res.period = [int]$Matches[1]; $res.cap = [int]$Matches[2]
        }
        if ($ln -match ' rd_promo ([\d.]+) rec_promo ([\d.]+) fe_promo ([\d.]+) rest_promo (-?[\d.]+) rd_gbs ([\d.]+)') {
            $res.rd    = [double]$Matches[1]
            $res.rec   = [double]$Matches[2]
            $res.fe    = [double]$Matches[3]
            $res.rest  = [double]$Matches[4]
            $res.rdgbs = [double]$Matches[5]
        }
    }
    $v = $out | Select-String -Pattern '^VERIFY_AB ' | Select-Object -First 1
    if ($v -and $v.Line -match 'slots (\d+) bad (\d+)') {
        $res.vslots = [int]$Matches[1]; $res.vbad = [int]$Matches[2]
    }
    if ($res.ContainsKey('promo') -and $Ngen -gt 0) { $res.promo_tok = $res.promo / $Ngen }
    if (-not $res.ContainsKey('gen') -and $res.err -eq '') {
        $bad = $out | Select-String -Pattern 'not supported|failed|abort|assert|OTKAZALO' |
               Select-Object -First 1
        $res.err = if ($bad) { $bad.Line.Trim() } else { "net stroki STATIC_AB (exit $($proc.ExitCode))" }
    }
    $null = Wait-Settled
    return $res
}

# Pravilo 44: odin povtor ne imeet razbrosa, i ob etom nado skazat slovami.
function Summ($name, $vals) {
    $v = @($vals | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return ("{0,-26} --" -f $name) }
    $mean = ($v | Measure-Object -Average).Average
    if ($v.Count -lt 2) { return ("{0,-26} {1,8:N3} (1 povtor - NE REZULTAT)" -f $name, $mean) }
    if ($mean -eq 0) { return ("{0,-26} {1,8:N3} (n={2})" -f $name, $mean, $v.Count) }
    $sp = 100.0 * (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $mean
    $flag = if ($sp -gt 4.2) { ' RAZBROS VYSHE POROGA' } else { '' }
    return ("{0,-26} {1,8:N3} (razbros {2,4:N1}%, n={3}){4}" -f $name, $mean, $sp, $v.Count, $flag)
}

("`n`n######## period sweep " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8
if (-not (Test-Path -LiteralPath $EXE)) { Note "net binarnika: $EXE"; exit 1 }
Copy-Item -LiteralPath $EXE -Destination $SNAP -Force
$null = & $SNAP --version *> $null
if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) { Note "snimok ne zapuskaetsja"; exit 1 }

$arms = @(
    @{ t = 'period3';  a = @('--resident-period','3');  p = 3;      f = 0 },
    @{ t = 'period16'; a = @('--resident-period','16'); p = 16;     f = 0 },
    @{ t = 'period32'; a = @('--resident-period','32'); p = 32;     f = 0 },
    @{ t = 'period64'; a = @('--resident-period','64'); p = 64;     f = 0 },
    @{ t = 'frozen';   a = @('--resident-freeze');      p = 3;      f = 1 }
)
$acc = @{}
foreach ($arm in $arms) {
    $acc[$arm.t] = @{ gen=@(); ref=@(); layer=@(); promo_tok=@(); promo_ms=@(); per_promo=@();
                      hits=@(); wait=@(); job=@(); cpu=@(); rd=@(); rec=@(); fe=@(); rest=@();
                      rdgbs=@() }
}

# Blok ne dolshe 20 minut, potom mashina otdajotsja minimum na 5: na etoj mashine vtoroj
# proekt pod tem zhe zamkom. Poetomu raund - eto blok, i zamok berjotsja i otdajotsja vokrug
# KAZHDOGO raunda, a ne vokrug vsego svipa. Vperemezhku i s kontrbalansom eto ne meshaet:
# vnutri raunda vse pjat plech idut podrjad, chjotnyj raund - v obratnom porjadke.
try {
    for ($r = 1; $r -le $Reps; $r++) {
        if (-not $External) {
            Say "berjom mashinu pod raund $r"
            if (-not (Take-Machine -Who "period-sweep-r$r" -TimeoutMin 120)) {
                Note 'mashinu ne poluchili'; exit 1
            }
        }
        try {
            if ($r -eq 1) {
                Say 'progrev na vybros'
                $w = RunOnce 'warm' @('--resident-period','3') 900
                if ($w.err -ne '') { Note ('progrev NE POSHJOL: ' + $w.err) }
                else               { Note ('progrev: {0:N2} tok/s - VYBROSHENO' -f $w.gen) }
            }
            $order = if ($r % 2 -eq 1) { $arms } else { $arms[($arms.Count-1)..0] }
            foreach ($arm in $order) {
                $res = RunOnce "$($arm.t)_$r" $arm.a 900
                if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
                # Pravilo 68: plecho bez podtverzhdennoj nastrojki - ne plecho.
                if (-not $res.ContainsKey('period')) {
                    Note ("raund ${r} $($arm.t): STROKI PROMO_AB NET ili net polja period - vybrosheno")
                    continue
                }
                if ($res.period -ne $arm.p -or $res.frozen -ne $arm.f) {
                    Note ("raund ${r} $($arm.t): v otchjote period $($res.period) frozen $($res.frozen), prosili $($arm.p)/$($arm.f) - vybrosheno")
                    continue
                }
                # Korrektnost do skorosti, oba priznaka.
                if ($res.ContainsKey('match') -and $res.match -lt $res.of) {
                    Note ("raund ${r} $($arm.t): SOVPALO $($res.match) iz $($res.of) - plecho NEVERNOE, cifry vybrosheny")
                    continue
                }
                if ($res.ContainsKey('vbad') -and $res.vbad -gt 0) {
                    Note ("raund ${r} $($arm.t): VIDEOPAMJAT RASHODITSJA s modelju v $($res.vbad) slotah iz $($res.vslots) - vybrosheno")
                    continue
                }
                foreach ($k in @('gen','ref','layer','promo_tok','promo_ms','per_promo','hits',
                                 'wait','job','cpu','rd','rec','fe','rest','rdgbs')) {
                    if ($res.ContainsKey($k)) { $acc[$arm.t].$k += $res.$k }
                }
                Note ("raund {0} {1,-9} podkachek/tok {2,5:N2}  popadanij {3,5:N1}%  promo_ms/tok {4,5:N2}  CPU/tok {5,6:N2}  zhdjom {6,5:N2}  sloj {7,5:N2}  tok/s {8,6:N2}  match {9}/{10}  bajty {11}/{12}" -f
                      $r, $arm.t, $res.promo_tok, $res.hits, $res.promo_ms, $res.cpu,
                      $res.wait, $res.layer, $res.gen, $res.match, $res.of, $res.vbad, $res.vslots)
                if ($res.ContainsKey('rd')) {
                    Note ("        podkachka {0:N3} ms = chtenie {1:N3} ({2:N2} GB/s) + zapis {3:N3} + submit/zabor {4:N3} + ostatok {5:N3}" -f
                          $res.per_promo, $res.rd, $res.rdgbs, $res.rec, $res.fe, $res.rest)
                }
            }
        } finally {
            if (-not $External) { Free-Machine; Say "mashina osvobozhdena posle raunda $r" }
        }
        if ($r -lt $Reps -and -not $External) {
            Say "pauza $RestMin min - vtoroj proekt pod tem zhe zamkom"
            Start-Sleep -Seconds ($RestMin * 60)
        }
    }

    Say 'ITOG po plecham'
    foreach ($k in @(@('promo_tok','podkachek/tok'), @('hits','popadanij %'),
                     @('promo_ms','promo_ms/tok'), @('cpu','CPU/tok'), @('wait','zhdjom/tok'),
                     @('job','karta/tok'), @('layer','sloj ms'), @('gen','tok/s'),
                     @('ref','etalon'))) {
        foreach ($arm in $arms) { Note (Summ ("$($arm.t) $($k[1])") $acc[$arm.t].($k[0])) }
    }

    Say 'ZADACHA 3: iz chego sostoit podkachka (ms na podkachku)'
    foreach ($arm in $arms) {
        if ($arm.f -eq 1) { continue }
        foreach ($k in @(@('per_promo','vsego'), @('rd','chtenie'), @('rdgbs','chtenie GB/s'),
                         @('rec','zapis kopii'), @('fe','submit+zabor'), @('rest','OSTATOK'))) {
            Note (Summ ("$($arm.t) $($k[1])") $acc[$arm.t].($k[0]))
        }
    }

    Say 'POPADANIJA I SKOROST VMESTE - eto i est otvet'
    $base = $null; $ceil = $null
    foreach ($arm in $arms) {
        $hh = @($acc[$arm.t].hits | Where-Object { $null -ne $_ })
        $gg = @($acc[$arm.t].gen  | Where-Object { $null -ne $_ })
        $pp = @($acc[$arm.t].promo_tok | Where-Object { $null -ne $_ })
        if ($hh.Count -lt 2 -or $gg.Count -lt 2) { Note ("{0,-9} menshe dvuh povtorov - NE REZULTAT" -f $arm.t); continue }
        $mg = ($gg | Measure-Object -Average).Average
        Note ("{0,-9} podkachek/tok {1,5:N2}   popadanij {2,5:N1}%   tok/s {3,6:N3}" -f
              $arm.t, ($pp | Measure-Object -Average).Average,
              ($hh | Measure-Object -Average).Average, $mg)
        if ($arm.t -eq 'period3') { $base = $mg }
        if ($arm.t -eq 'frozen')  { $ceil = $mg }
    }
    if ($null -ne $base -and $null -ne $ceil -and $ceil -gt $base) {
        Say 'DOLJA POTOLKA, kotoruju zabiraet kazhdyj period'
        foreach ($arm in $arms) {
            $gg = @($acc[$arm.t].gen | Where-Object { $null -ne $_ })
            if ($gg.Count -lt 2) { continue }
            $mg = ($gg | Measure-Object -Average).Average
            Note ("{0,-9} tok/s {1,6:N3} = {2,5:N1}% ot potolka zamorozki" -f
                  $arm.t, $mg, 100.0 * ($mg - $base) / ($ceil - $base))
        }
    }
} finally {
    if ($script:MEMEX_HELD -and -not $External) { Free-Machine }
}
