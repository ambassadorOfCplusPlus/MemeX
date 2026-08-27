# BJUDZHET PODKACHEK VNIZ: 8 (baza) -> 4 -> 2 -> zamorozhennyj nabor.
#
# OTKUDA VOPROS, i on ne iz teorii. Dva nezavisimyh izmenenija podrjad sdelali RABOTU KARTY
# bystree, a TOKJEN medlennee:
#
#     paketirovanie podkachek   sloj 29.63 -> 27.36 ms (-7.7%)   tok/s 15.242 -> 14.918 (-2.1%)
#     snjatie barjerov          sloj 29.69 -> 26.71    (-10.0%)  tok/s 15.15  -> 14.78  (-2.4%)
#
# Odno napravlenie, blizkaja velichina, razbrosy pod procentom. Eto mehanizm, a ne shum.
#
# KANDIDAT: karta i processor deljat POLOSU OPERATIVNOJ PAMJATI, i processornaja polovina
# ekspertov ejo-to i upiraetsja v polosu. Podkachka chitaet ozu (mmap fajla, potom zakreplennyj
# promezhutochnyj bufer, potom PCIe), i processornaja polovina chitaet ozu. Vsjo, chto delaet
# obrashchenija karty k ozu bolee agressivnymi - paket vmesto rovnogo potoka, snjatye barjery -
# otnimaet polosu u processornoj poloviny, a ona na kriticheskom puti.
#
# Otsjuda i pereosmyslenie nashih +25%: my schitali, chto delo v tom, chto karta BYSTRAJA. Esli
# gipoteza verna, delo v tom, chto ona UBIRAET chtenija iz ozu - a trafik podkachek vozvrashchaet
# ih obratno.
#
# PROVERKA KONTRINTUITIVNAJA I IMENNO POETOMU CENNAJA: umenshit bjudzhet podkachek. Menshe
# podkachek - menshe otnjatoj polosy, no i huzhe popadanija. Esli mehanizm est, tokjen stanet
# BYSTREE, a popadanija HUZHE - i nichem drugim v etoj sheme takoe ne objasnjaetsja.
#
# PREDSKAZANIE, ZAPISANNOE DO PROGONA. Baza (izmereno, tri raunda, razbrosy pod procentom):
# bjudzhet 8 nikogda ne svjazyval (0 obnovlenij iz 3072), popadanij 71.6%, podkachek 6.9 na
# tokjen, podkachki zanimajut potok karty 8.96 mc/tokjen, polovina CPU 15.84, tok/s 15.24.
#
#     plecho     podkachek/tok   popadanija   promo_ms/tok   tok/s
#     budget8        6.9           71.6%         8.96        15.24   (baza)
#     budget4        ~4.5          69-71%        5.5-6.5      15.3-15.6
#     budget2        ~2.4          65-69%        3.0-3.5      15.4-15.9
#     frozen         0.0           55-65%        0.0          15.6-16.3
#
# To est: esli gipoteza polosy verna, tok/s rastjot monotonno vniz po bjudzhetu, i frozen -
# samoe bystroe plecho. Esli gipoteza neverna, tok/s libo ne dvinetsja (togda podkachki ne
# stojat processoru nichego, i vsja vetka polosy zakryta), libo UPADJOT vmeste s popadanijami
# (togda rabotaet ta shema, kotoruju my i predpolagali s samogo nachala).
#
# Esli frozen okazhetsja samym bystrym - eto krupnyj i neprijatnyj vyvod o vsej konstrukcii
# rezidentnogo nabora, i imenno poetomu on merjaetsja, a ne obsuzhdaetsja.
#
# CHITAT NADO POPADANIJA I tok/s VMESTE. Interesnyj rezultat - eto dve velichiny, dvizhushchiesja
# v PROTIVOPOLOZHNYE storony; kazhdaja po otdelnosti tut nichego ne govorit.
#
# Napisano latinicej: PowerShell zdes chitaet fajl bez metki kak ANSI.
param(
    [int]    $Reps    = 2,
    [int]    $Ngen    = 192,
    [int]    $Tokens  = 512,
    [int]    $Threads = 8,
    [switch] $External
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$SNAP   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-budget-snap.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\budget_sweep_ab.log'

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
    $so = "D:\MemeX\results\_bsab_$tag.out"
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
        if ($ln -match 'join_wait_tok ([\d.]+)')     { $res.wait = [double]$Matches[1] }
        if ($ln -match ' job_tok ([\d.]+)')          { $res.job = [double]$Matches[1] }
        if ($ln -match ' cpu_tok ([\d.]+)')          { $res.cpu = [double]$Matches[1] }
        if ($ln -match ' budget (-?\d+) frozen (\d+) hits ([\d.]+)') {
            $res.budget = [int]$Matches[1]
            $res.frozen = [int]$Matches[2]
            $res.hits   = [double]$Matches[3]
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
    if ($v.Count -eq 0) { return ("{0,-24} --" -f $name) }
    $mean = ($v | Measure-Object -Average).Average
    if ($v.Count -lt 2) { return ("{0,-24} {1,8:N3} (1 povtor - NE REZULTAT)" -f $name, $mean) }
    $sp = 100.0 * (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $mean
    $flag = if ($sp -gt 4.2) { ' RAZBROS VYSHE POROGA' } else { '' }
    return ("{0,-24} {1,8:N3} (razbros {2,4:N1}%, n={3}){4}" -f $name, $mean, $sp, $v.Count, $flag)
}

("`n`n######## budget sweep " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8
if (-not (Test-Path -LiteralPath $EXE)) { Note "net binarnika: $EXE"; exit 1 }
Copy-Item -LiteralPath $EXE -Destination $SNAP -Force
$null = & $SNAP --version *> $null
if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) { Note "snimok ne zapuskaetsja"; exit 1 }

$arms = @(
    @{ t = 'budget8'; a = @('--resident-budget','8'); b = 8;  f = 0 },
    @{ t = 'budget2'; a = @('--resident-budget','2'); b = 2;  f = 0 },
    @{ t = 'frozen';  a = @('--resident-freeze');     b = 8;  f = 1 }
)
$acc = @{}
foreach ($arm in $arms) {
    $acc[$arm.t] = @{ gen=@(); ref=@(); layer=@(); promo_tok=@(); promo_ms=@();
                      hits=@(); wait=@(); job=@(); cpu=@() }
}

if (-not $External) {
    Say 'berjom mashinu pod svip bjudzheta'
    if (-not (Take-Machine -Who 'budget-sweep' -TimeoutMin 90)) { Note 'mashinu ne poluchili'; exit 1 }
}
try {
    Say ("svip bjudzheta podkachek: raundov $Reps, --gen $Ngen, --tokens $Tokens, t=$Threads")
    for ($r = 1; $r -le $Reps; $r++) {
        if ($r -eq 1) {
            Say 'progrev na vybros'
            $w = RunOnce 'warm' @('--resident-budget','8') 900
            if ($w.err -ne '') { Note ('progrev NE POSHJOL: ' + $w.err) }
            else               { Note ('progrev: {0:N2} tok/s - VYBROSHENO' -f $w.gen) }
        }
        # Kontrbalans: chjotnyj raund v obratnom porjadke.
        $order = if ($r % 2 -eq 1) { $arms } else { $arms[($arms.Count-1)..0] }
        foreach ($arm in $order) {
            $res = RunOnce "$($arm.t)_$r" $arm.a 900
            if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
            # Pravilo 68: plecho bez podtverzhdennoj nastrojki - ne plecho.
            if (-not $res.ContainsKey('budget')) {
                Note ("raund ${r} $($arm.t): STROKI PROMO_AB NET - nastrojka ne podtverzhdena, vybrosheno")
                continue
            }
            if ($res.budget -ne $arm.b -or $res.frozen -ne $arm.f) {
                Note ("raund ${r} $($arm.t): v otchjote budget $($res.budget) frozen $($res.frozen), prosili $($arm.b)/$($arm.f) - vybrosheno")
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
            foreach ($k in @('gen','ref','layer','promo_tok','promo_ms','hits','wait','job','cpu')) {
                if ($res.ContainsKey($k)) { $acc[$arm.t].$k += $res.$k }
            }
            Note ("raund {0} {1,-8} podkachek/tok {2,5:N2}  popadanij {3,5:N1}%  promo_ms/tok {4,5:N2}  CPU/tok {5,6:N2}  zhdjom {6,5:N2}  sloj {7,5:N2}  tok/s {8,6:N2}  match {9}/{10}  bajty {11}/{12}" -f
                  $r, $arm.t, $res.promo_tok, $res.hits, $res.promo_ms, $res.cpu,
                  $res.wait, $res.layer, $res.gen, $res.match, $res.of, $res.vbad, $res.vslots)
        }
    }
    Say 'ITOG po plecham'
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) podkachek/tok") $acc[$arm.t].promo_tok) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) popadanij %")   $acc[$arm.t].hits) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) promo_ms/tok")  $acc[$arm.t].promo_ms) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) CPU/tok")       $acc[$arm.t].cpu) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) zhdjom/tok")    $acc[$arm.t].wait) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) karta/tok")     $acc[$arm.t].job) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) sloj ms")       $acc[$arm.t].layer) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) tok/s")         $acc[$arm.t].gen) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) etalon")        $acc[$arm.t].ref) }

    Say 'POPADANIJA I SKOROST VMESTE - eto i est otvet'
    foreach ($arm in $arms) {
        $hh = @($acc[$arm.t].hits | Where-Object { $null -ne $_ })
        $gg = @($acc[$arm.t].gen  | Where-Object { $null -ne $_ })
        $pp = @($acc[$arm.t].promo_tok | Where-Object { $null -ne $_ })
        if ($hh.Count -lt 2 -or $gg.Count -lt 2) { Note ("{0,-8} menshe dvuh povtorov - NE REZULTAT" -f $arm.t); continue }
        Note ("{0,-8} podkachek/tok {1,5:N2}   popadanij {2,5:N1}%   tok/s {3,6:N3}" -f
              $arm.t, ($pp | Measure-Object -Average).Average,
              ($hh | Measure-Object -Average).Average, ($gg | Measure-Object -Average).Average)
    }
    $g8 = @($acc['budget8'].gen | Where-Object { $null -ne $_ })
    $gf = @($acc['frozen'].gen  | Where-Object { $null -ne $_ })
    if ($g8.Count -ge 2 -and $gf.Count -ge 2) {
        $m8 = ($g8 | Measure-Object -Average).Average
        $mf = ($gf | Measure-Object -Average).Average
        Note ('budget8 -> frozen: tok/s {0:N3} -> {1:N3} = {2:+0.0;-0.0}%  {3}' -f $m8, $mf,
              (100.0*($mf-$m8)/$m8),
              $(if ($mf -gt $m8) { 'GIPOTEZA POLOSY PODTVERZHDAETSJA: nol podkachek BYSTREE' }
                else { 'gipoteza polosy NE podtverzhdaetsja: podkachki sebja opravdyvajut' }))
    }
} finally {
    if (-not $External) { Free-Machine; Say 'mashina osvobozhdena' }
}
