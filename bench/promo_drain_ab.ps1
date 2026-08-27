# DRENAZH OCHEREDI PODKACHEK: MEMEX_PROMO_DRAIN=1 protiv =8.
#
# CHTO MERJAETSJA. worker_loop (gpu_experts.cpp) bral iz ocheredi ODNU podkachku za prohod i
# oboračival ejo v batch_begin / upload / batch_end, a batch_end zhdjot zabor. Schjotchik nazval
# eto pryamo: 1902 podkachki, 1902 paketa - razmer paketa vsegda edinica. Teper za prohod
# berjotsja do promo_drain_ podkachek i vse oni uhodjat pod odin submit i odin zabor.
#
# CHTO CHITAT, i eto glavnoe reshenie ob osnastke. Chitat nado promo_ms_tok (podkachki na potoke
# karty, mc/tokjen) i per_batch (podkachek na paket) - imenno na nih priem dejstvuet naprjamuju, i
# u nih razbros pod procentom. tok/s neset vsju ostalnuju izmenchivost i idjot vtorym.
#
# PREDSKAZANIE, ZAPISANNOE DO PROGONA (STATE.md, razdel o podkachkah):
#
#     per_batch          1.00  ->  6-8
#     promo_ms_tok      13.04  ->  5.5-6.5   <- eto predskazanie iz zadanija
#     ostatok dzhojna    6.29  ->  2-3
#     tokjen             66.0  ->  60-62 ms, to est 16.1-16.5 tok/s
#
# VAZHNAJA POPRAVKA K BAZE, najdennaja do progona. 13.04 mc/tokjen bylo poluchno deleniem VSEGO
# ms_promote na n_gen, vkljuchaja pervičnuju zalivku videopamjati (576 ekspertov, 1.44 GB, 789 mc),
# kotoruju ni odin sgenerirovannyj tokjen ne platil. Na generacii eto 8.96 mc/tokjen, i cena odnoj
# podkachki 1.30 mc, a ne 1.89 (13.04 / 6.9 delilo total s zalivkoj na rate bez nejo). Znamenatel
# ispravlen v dvizhke, i plecho drain=1 zdes merit ispravlennuju bazu, a ne staruju cifru.
#
# KORREKTNOST DO SKOROSTI. Plecho snjatija barjerov dalo sloj na 10% bystree i 0 iz 192 vernyh
# tokenov - to est skorost iz nevernogo plecha molcha vrjot. Poetomu iz PROMO_AB chitaetsja
# "match N of M", i plecho, u kotorogo match < M, v itog ne idjot vovse.
#
# Napisano latinicej: PowerShell na etoj mashine chitaet fajly bez metki kak ANSI, i kirillica v
# skripte lomaet razbor. Poetomu dvizhok pechataet ASCII-stroku PROMO_AB - vsjo ostalnoe v otchjote
# kirillicej, i obrazec po nemu zdes nesti nelzja.
param(
    [int]    $Reps    = 3,
    [int]    $Ngen    = 192,
    [int]    $Tokens  = 512,
    [int]    $Threads = 8,
    [switch] $External
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$SNAP   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-drain-snap.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\promo_drain_ab.log'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

# Pauza po SOSTOJANIJU, ne po vremeni (pravilo 51): predyduschij progon osvobozhdaet 16 GB, i
# Windows obnuljaet eti stranicy fonovym potokom. Pjatnadcati sekund na eto ne hvataet.
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
function RunOnce($tag, [string]$drain, [int]$limitSec) {
    $hogs = Get-CpuHogs -MinPct 12
    if ($hogs) {
        Note ('KONKURENTY pered progonom: ' +
              (($hogs | ForEach-Object { "$($_.Name)/$($_.Id) $([math]::Round($_.Pct,0))%" }) -join ', '))
    }
    $so = "D:\MemeX\results\_pdab_$tag.out"
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$Threads",
           '--gen', "$Ngen", '--no-repack', '--gpu-static-layers', '--gpu-experts',
           '--resident', '0')
    $env:MEMEX_PROMO_DRAIN = $drain
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
    # PROMO_AB: i nastrojka, i velichiny, i korrektnost - odnoj strokoj.
    $p2 = $out | Select-String -Pattern '^PROMO_AB ' | Select-Object -First 1
    if ($p2) {
        $ln = $p2.Line
        if ($ln -match 'drain (\d+) ring (\d+) pinned (\d+)') {
            $res.drain  = [int]$Matches[1]
            $res.ring   = [int]$Matches[2]
            $res.pinned = [int]$Matches[3]
        }
        if ($ln -match 'match (\d+) of (\d+)')       { $res.match = [int]$Matches[1]; $res.of = [int]$Matches[2] }
        if ($ln -match ' promo (\d+) batches (\d+)') { $res.promo = [int]$Matches[1]; $res.batches = [int]$Matches[2] }
        if ($ln -match 'per_batch ([\d.]+)')         { $res.per_batch = [double]$Matches[1] }
        if ($ln -match 'promo_ms_tok ([\d.]+)')      { $res.promo_ms = [double]$Matches[1] }
        if ($ln -match 'ms_per_promo ([\d.]+)')      { $res.ms_promo = [double]$Matches[1] }
        if ($ln -match ' gbs ([\d.]+)')              { $res.gbs = [double]$Matches[1] }
        if ($ln -match 'join_wait_tok ([\d.]+)')     { $res.wait = [double]$Matches[1] }
        if ($ln -match ' job_tok ([\d.]+)')          { $res.job = [double]$Matches[1] }
        if ($ln -match ' cpu_tok ([\d.]+)')          { $res.cpu = [double]$Matches[1] }
        if ($ln -match 'fill_ms ([\d.]+)')           { $res.fill = [double]$Matches[1] }
    }
    if (-not $res.ContainsKey('gen') -and $res.err -eq '') {
        $bad = $out | Select-String -Pattern 'not supported|failed|abort|assert|OTKAZALO' |
               Select-Object -First 1
        $res.err = if ($bad) { $bad.Line.Trim() } else { "net stroki STATIC_AB (exit $($proc.ExitCode))" }
    }
    $null = Wait-Settled
    return $res
}

# Pravilo 44: odin povtor ne imeet razbrosa, i ob etom nado skazat slovami, a ne pechatat 0.0%.
function Summ($name, $vals) {
    $v = @($vals | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return ("{0,-22} --" -f $name) }
    $mean = ($v | Measure-Object -Average).Average
    if ($v.Count -lt 2) { return ("{0,-22} {1,8:N3} (1 povtor - NE REZULTAT)" -f $name, $mean) }
    $sp = 100.0 * (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $mean
    $flag = if ($sp -gt 4.2) { ' RAZBROS VYSHE POROGA' } else { '' }
    return ("{0,-22} {1,8:N3} (razbros {2,4:N1}%, n={3}){4}" -f $name, $mean, $sp, $v.Count, $flag)
}

function Delta($name, $a, $b, $pred) {
    $x = @($a | Where-Object { $null -ne $_ }); $y = @($b | Where-Object { $null -ne $_ })
    if ($x.Count -lt 2 -or $y.Count -lt 2) { return ("{0}: menshe dvuh povtorov - NE REZULTAT" -f $name) }
    $m1 = ($x | Measure-Object -Average).Average
    $m2 = ($y | Measure-Object -Average).Average
    return ("{0}: {1:N3} -> {2:N3} = {3:+0.0;-0.0}%   {4}" -f $name, $m1, $m2, (100.0*($m2-$m1)/$m1), $pred)
}

("`n`n######## promo drain A/B " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8
if (-not (Test-Path -LiteralPath $EXE)) { Note "net binarnika: $EXE"; exit 1 }
# Snimok, chtoby parallelnaja sborka ne podmenila binarnik posredi serii.
Copy-Item -LiteralPath $EXE -Destination $SNAP -Force
$null = & $SNAP --version *> $null
if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) { Note "snimok ne zapuskaetsja"; exit 1 }

$arms = @(
    @{ t = 'drain1'; v = '1' },
    @{ t = 'drain8'; v = '8' }
)
$acc = @{}
foreach ($arm in $arms) {
    $acc[$arm.t] = @{ gen=@(); ref=@(); layer=@(); per_batch=@(); promo_ms=@();
                      ms_promo=@(); gbs=@(); wait=@(); job=@(); cpu=@() }
}

if (-not $External) {
    Say 'berjom mashinu pod A/B drenazha'
    if (-not (Take-Machine -Who 'promo-drain-ab' -TimeoutMin 90)) { Note 'mashinu ne poluchili'; exit 1 }
}
try {
    Say ("drenazh ocheredi podkachek: raundov $Reps, --gen $Ngen, --tokens $Tokens, t=$Threads")
    for ($r = 1; $r -le $Reps; $r++) {
        if ($r -eq 1) {
            Say 'progrev na vybros'
            $w = RunOnce 'warm' '8' 900
            if ($w.err -ne '') { Note ('progrev NE POSHJOL: ' + $w.err) }
            else               { Note ('progrev: {0:N2} tok/s - VYBROSHENO' -f $w.gen) }
        }
        # Kontrbalans: chjotnyj raund idjot v obratnom porjadke.
        $order = if ($r % 2 -eq 1) { $arms } else { $arms[($arms.Count-1)..0] }
        foreach ($arm in $order) {
            $res = RunOnce "$($arm.t)_$r" $arm.v 900
            if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
            # Pravilo 68: plecho bez podtverzhdennoj nastrojki ne plecho.
            if (-not $res.ContainsKey('drain')) {
                Note ("raund ${r} $($arm.t): STROKI PROMO_AB NET - nastrojka ne podtverzhdena, plecho vybrosheno")
                continue
            }
            if ($res.drain -ne [int]$arm.v) {
                Note ("raund ${r} $($arm.t): drain v otchjote $($res.drain), a prosili $($arm.v) - plecho vybrosheno")
                continue
            }
            # Korrektnost do skorosti. Nevernoe plecho vrjot v ljubuju storonu.
            if ($res.ContainsKey('match') -and $res.match -lt $res.of) {
                Note ("raund ${r} $($arm.t): SOVPALO $($res.match) iz $($res.of) TOKENOV - plecho NEVERNOE, cifry vybrosheny")
                continue
            }
            foreach ($k in @('gen','ref','layer','per_batch','promo_ms','ms_promo','gbs','wait','job','cpu')) {
                if ($res.ContainsKey($k)) { $acc[$arm.t].$k += $res.$k }
            }
            Note ("raund {0} {1,-7} promo_ms/tok {2,6:N2}  na paket {3,5:N2}  mc/podkachku {4,5:N2}  {5,5:N2} GB/s  zhdjom {6,5:N2}  tok/s {7,6:N2}  match {8}/{9}  (kolco {10}, pinned {11}, zalivka {12:N0} mc)" -f
                  $r, $arm.t, $res.promo_ms, $res.per_batch, $res.ms_promo, $res.gbs,
                  $res.wait, $res.gen, $res.match, $res.of, $res.ring, $res.pinned, $res.fill)
        }
    }
    Say 'ITOG po plecham'
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) promo_ms/tok") $acc[$arm.t].promo_ms) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) na paket")     $acc[$arm.t].per_batch) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) mc/podkachku") $acc[$arm.t].ms_promo) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) GB/s")         $acc[$arm.t].gbs) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) zhdjom/tok")   $acc[$arm.t].wait) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) karta/tok")    $acc[$arm.t].job) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) CPU/tok")      $acc[$arm.t].cpu) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) tok/s")        $acc[$arm.t].gen) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) sloj ms")      $acc[$arm.t].layer) }
    foreach ($arm in $arms) { Note (Summ ("$($arm.t) etalon")       $acc[$arm.t].ref) }

    Say 'PREDSKAZANIE PROTIV ZAMERA'
    Note (Delta 'na paket    ' $acc['drain1'].per_batch $acc['drain8'].per_batch '(predskazano 1.0 -> 6-8)')
    Note (Delta 'promo_ms/tok' $acc['drain1'].promo_ms  $acc['drain8'].promo_ms  '(predskazano do 5.5-6.5 mc)')
    Note (Delta 'zhdjom/tok  ' $acc['drain1'].wait      $acc['drain8'].wait      '(predskazano ostatok 6.3 -> 2-3)')
    Note (Delta 'tok/s       ' $acc['drain1'].gen       $acc['drain8'].gen       '(predskazano 15.15 -> 16.1-16.5)')
} finally {
    Remove-Item Env:MEMEX_PROMO_DRAIN -EA SilentlyContinue
    if (-not $External) { Free-Machine; Say 'mashina osvobozhdena' }
}
