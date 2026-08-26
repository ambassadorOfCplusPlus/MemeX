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

function Arm($label, $ngen, [string[]]$extra) {
    $vals = @()
    for ($r = 1; $r -le 3; $r++) {
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
        Start-Sleep -Seconds 15
    }
    if ($vals.Count -lt 2) { Note ("{0,-28} menshe dvuh povtorov - ne rezultat" -f $label); return }
    $mean = ($vals | Measure-Object -Average).Average
    $spread = 100.0*(($vals|Measure-Object -Maximum).Maximum - ($vals|Measure-Object -Minimum).Minimum)/$mean
    $flag = if ($spread -gt 4.2) { '  <<< vyshe shuma' } else { '' }
    Note ("{0,-28} {1,6:N2} tok/s (razbros {2:N1}%, {3}){4}" -f $label, $mean, $spread,
          (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'), $flag)
}

("`n`n######## regressija ili argumenty " + (Get-Date)) | Add-Content $LOG
if (-not (Take-Machine -Who 'regress' -TimeoutMin 300 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    Say 'tot zhe binarnik, dva znachenija -n, s perepakovkoj i bez'
    Arm 'n=256, rtr  (kak baza 14.04)' 256 @('-rtr')
    Arm 'n=192, rtr  (kak tablica)'    192 @('-rtr')
    Arm 'n=256, mmap'                  256 @()
    Arm 'n=192, mmap'                  192 @()
    Say 'kak chitat'
    Note 'n=256 rtr okolo 14  -> regressii net, vinovat argument -n'
    Note 'vse okolo 10-11     -> regressija est; raznica rtr protiv mmap pokazhet, v perepakovke li ona'
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
