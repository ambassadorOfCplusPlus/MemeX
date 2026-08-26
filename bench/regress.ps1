# Odna razvilka: regressija ili nesopostavimye argumenty.
#
# Chistaja baza mx1 - 14.04 tok/s pri razbrose 2.0% - byla snjata segodnja v 18:06 skriptom
# spec_study s argumentami -n 256 -c 2048 -t 8 -ngl 0 -fa off -rtr. Tablica trjoh modelej na tom zhe
# fajle daet 10.4-11.1 pri tihoj mashine, i eto na 25% nizhe. Dva objasnenija, i oni razlichajutsja
# odnim argumentom:
#
#   - argumenty ne te: tam -n 256, zdes -n 192. Korotkaja generacija bolshe vesa daet progrevu.
#   - regressija: nashi patchi k forku trogajut put perepakovki (repack_only, repack_exclude,
#     novyj padded_need s vyravnivaniem 64). Kosvennyj priznak est: perepakovka sejchas daet 10.87
#     protiv 10.38 bez nejo, to est pochti nichego, a dolzhna davat +34%.
#
# Poetomu progon idjot krest-nakrest: dva znachenija -n na odnom binarnike, s perepakovkoj i bez.
# Esli -n 256 vernjot 14 - regressii net, vinovaty argumenty. Esli oba dadut 11 - regressija est,
# i togda raznica rtr/mmap skazhet, gde imenno.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\regress.log'
$P   = 'D:\MemeX\results\prompt_short.txt'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

# Zhdat, poka pamjat ne ustoitsja, a ne fiksirovannye sekundy.
#
# Otkuda eto vzjalos. Tri povtora odnogo i togo zhe plecha dali 5.61 / 5.71 / 7.37 tok/s pri tihoj
# mashine. Uliku dala faza prefila, kotoraja upiraetsja v schjot, a ne v pamjat: 116.80 ms na tokjen
# v povtore 2 protiv 31.71 v povtore 3, to est v 3.7 raza. Takaja raznica na schjotnoj faze znachit
# tolko odno - processu ne dostalis jadra.
#
# Zanimala ih ne chuzhaja rabota, a sama sistema: predydushchij progon osvobodil 16 GB, i Windows
# obnuljaet eti stranicy fonovym potokom. Pjatnadcati sekund pauzy na 16 GB ne hvataet, i sledujushchij
# povtor startuet v konkurencii s uborkoj za predydushchim.
#
# Poetomu pauza mezhdu povtorami ne vremennaja, a po sostojaniju: zhdjom, poka svobodnaja pamjat
# perestanet rasti. Dva podrjad zamera v predelah 200 MB drug ot druga - znachit uborka zakonchilas.
function Settle {
    param([int]$MaxSec = 180, [int]$TolMB = 200)
    $prev = -1
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        Start-Sleep -Seconds 5
        $free = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)  # MB
        if ($prev -ge 0 -and [math]::Abs($free - $prev) -le $TolMB) { return $free }
        $prev = $free
    }
    return $prev
}

# Odin progon, a ne tri. Povtory gonjatsja snaruzhi vperemezhku po plecham.
#
# Pochemu ne blokami. Mashina dvigaetsja vo vremja svipa - tretij povtor odnogo i togo zhe plecha
# vyhodil na 31% bystree pervogo. Pri blochnoj shkeme ves etot dreif dostajotsja tomu plechu,
# kotoroe shlo pervym, i objavljaetsja effektom. Pri peremezhajushchejsja - kazhdyj raund soderzhit
# kazhdoe plecho rovno odin raz, tak chto dreif razdeljaetsja mezhdu nimi porovnu i sravnenie
# vyzhivaet, dazhe esli absoljutnye chisla plyvut.
function Arm1($label, $ngen, [string[]]$extra, $r) {
        $so = 'D:\MemeX\results\_rg' + "_$r.out"
        $a = @('-m', $M, '-f', $P, '-n', "$ngen", '-c', '2048', '-t', '8', '-ngl', '0',
               '-fa', 'off', '--seed', '1', '--no-display-prompt') + $extra
        $exe = Join-Path $BIN 'llama-cli.exe'
        $proc = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        if (-not $proc.WaitForExit(900 * 1000)) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; continue }
        $out = @(); if (Test-Path $so) { $out += Get-Content $so }; if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
        $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($h -and $h.Line -match '([\d.]+) tokens per second') { $vals += [double]$Matches[1] }
    $null = Settle
    if ($vals.Count -lt 1) { return $null }
    return $vals[0]
}

("`n`n######## regressija ili argumenty " + (Get-Date)) | Add-Content $LOG
if (-not (Take-Machine -Who 'regress' -TimeoutMin 300 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    $arms = @(
        @{ n='n=256, rtr  (kak baza 14.04)'; g=256; e=@('-rtr') },
        @{ n='n=192, rtr  (kak tablica)';    g=192; e=@('-rtr') },
        @{ n='n=256, mmap';                  g=256; e=@()       },
        @{ n='n=192, mmap';                  g=192; e=@()       })
    $res = @{}
    foreach ($a in $arms) { $res[$a.n] = @() }

    Say 'progrev - odna zagruzka, kotoraja ne schitaetsja'
    # The machine was measurably faster on the third load of the same file than on the first. One
    # discarded load pays for that once, instead of charging it to whichever arm ran first.
    $null = Arm1 'progrev' 32 @('-rtr') 0
    Note 'progrev sdelan'

    Say 'chetyre plecha, tri raunda vperemezhku'
    for ($round = 1; $round -le 3; $round++) {
        # Chereduem napravlenie: inache plecho, stojashchee poslednim, vsegda idjot na samoj
        # progretoj mashine.
        $order = if ($round % 2 -eq 1) { $arms } else { $arms[($arms.Count-1)..0] }
        foreach ($a in $order) {
            $v = Arm1 $a.n $a.g $a.e $round
            if ($v) { $res[$a.n] += $v }
        }
        Note ("raund {0} projden" -f $round)
    }

    Say 'itog'
    foreach ($a in $arms) {
        $vals = $res[$a.n]
        if ($vals.Count -lt 2) { Note ("{0,-28} menshe dvuh povtorov - ne rezultat" -f $a.n); continue }
        $mean = ($vals | Measure-Object -Average).Average
        $spread = 100.0*(($vals|Measure-Object -Maximum).Maximum - ($vals|Measure-Object -Minimum).Minimum)/$mean
        $flag = if ($spread -gt 4.2) { '  <<< vyshe shuma' } else { '' }
        Note ("{0,-28} {1,6:N2} tok/s (razbros {2:N1}%, {3}){4}" -f $a.n, $mean, $spread,
              (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'), $flag)
    }
    # Kazhdyj raund soderzhit kazhdoe plecho rovno odin raz, poetomu srednee po raundu otlichaetsja
    # tolko tem, KOGDA on shjol. Eto prjamoj zamer dreifa mashiny.
    Say 'dreif mashiny po raundam'
    for ($round = 1; $round -le 3; $round++) {
        $rv = @(); foreach ($a in $arms) { if ($res[$a.n].Count -ge $round) { $rv += $res[$a.n][$round-1] } }
        if ($rv.Count) { Note ("raund {0}: srednee po plecham {1:N2} tok/s" -f $round, (($rv | Measure-Object -Average).Average)) }
    }
    Say 'kak chitat'
    Note 'n=256 rtr okolo 14  -> regressii net, vinovat argument -n'
    Note 'vse okolo 10-11     -> regressija est; raznica rtr protiv mmap pokazhet, v perepakovke li ona'
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
