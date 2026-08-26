# Generation numbers for the three models the user asked about, measured once, cleanly.
#
# The 30B still has no clean reference table: three attempts were contaminated - twice by a
# subagent compiling, once by an llama-quantize finishing a variant the new plan made pointless -
# and every arm was discarded rather than reported. The only trustworthy figure so far is the
# 14.04 tok/s baseline from the speculation study, at a 2.0% spread.
#
# Memory decides which arms are possible, so it is stated rather than discovered:
#   30B mx1     15.4 GB - repacks resident inside 31.9 GB, so -rtr is available and worth +34%
#   Gemma 26B   15.8 GB - same
#   35B Q6_K    27.3 GB - does not fit resident beside the OS, so it must stay on mmap, no -rtr
# Comparing a repacked model against an mmap'd one is not a comparison of the models, so each gets
# both arms where both are possible, and the 35B's single arm is labelled for what it is.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\three_models.log'
$P   = 'D:\MemeX\results\prompt_short.txt'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

# Zapuskaemost proverjaetsja do zamerov, a ne vyvoditsja iz ego rezultatov.
#
# Vsja tablica tolko chto vyshla pustoj: kazhdoe plecho otchitalos "NE POSHLO" s pustym
# soobshcheniem, a prichina byla v tom, chto v build/bin/Release lezhala ggml.dll razmerom 67 KB ot
# 26 ijunja vmesto nastojashchej na 31 MB - parallelnaja sborka ostavila nesoglasovannoe derevo.
# llama-cli padal s kodom -1073741511 (tochka vhoda ne najdena) do togo, kak chto-libo napechatat,
# poetomu ni odin iz shablonov oshibok ne sovpal.
#
# Eto uzhe vtoroj raz: odnazhdy ggml.dll prosto ischezla, CMake schital cel gotovoj, i noch byla
# poterjana na progony, padavshie bez soobshchenija. Otlichie "ne zapustilos" ot "ne izmerilos"
# dolzhno delatsja odnoj proverkoj v nachale, a ne razbором pustyh logov potom.
function Startable($exe) {
    if (-not (Test-Path -LiteralPath $exe)) { return "net fajla: $exe" }
    $null = & $exe --version 2>&1
    $c = $LASTEXITCODE
    if ($c -eq 0) { return $null }
    $why = switch ($c) {
        -1073741511 { 'tochka vhoda ne najdena - DLL ne sootvetstvuet exe, nuzhna peresborka' }
        -1073741515 { 'DLL ne najdena' }
        default     { "kod vyhoda $c" }
    }
    return "binarnik ne startuet ($why)"
}

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

function Arm($label, $model, [string[]]$extra, $limitSec) {
    if (-not (Test-Path -LiteralPath $model)) { Note ("{0,-34} net fajla" -f $label); return }
    $vals = @(); $why = ''
    for ($r = 1; $r -le 3; $r++) {
        # A separate output path per replicate. This was first written believing a shared file was
        # what killed replicates 2 and 3; it was not - the cause was the $P/$p collision noted
        # below, and spec_study.ps1 shares one file across three replicates quite happily. Kept
        # anyway because distinct files make a failed replicate diagnosable after the fact.
        $so = 'D:\MemeX\results\_tm' + "_$r.out"
        $a = @('-m', $model, '-f', $P, '-n', '192', '-c', '2048', '-t', '8', '-ngl', '0',
               '-fa', 'off', '--seed', '1', '--no-display-prompt') + $extra
            # The process handle is NOT called $p here, and that is not a style choice. PowerShell
    # variable names are case-insensitive, the prompt path lives in $P, and `$p = Start-Process`
    # inside this function makes every later read of $P return a Process object. Replicate 1
    # succeeds, replicates 2 and 3 are handed a Process where a filename belongs and die before
    # they start - which is why every arm this evening reported one surviving run as a flawless
    # 0.0% spread. This exact collision has already cost this project one sweep once.
        $proc = Start-Process -FilePath "$BIN\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden -PassThru `
                 -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        if (-not $proc.WaitForExit($limitSec * 1000)) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; $why='tajm-aut'; continue }
        $out = @(); if (Test-Path $so) { $out += Get-Content $so }; if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
        $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($h -and $h.Line -match '([\d.]+) tokens per second') { $vals += [double]$Matches[1] }
        else {
            $bad = $out | Select-String -Pattern 'unknown model|not supported|failed to|error loading|abort' | Select-Object -First 1
            if ($bad) { $why = $bad.Line.Trim() }
        }
        $null = Settle
    }
    if ($vals.Count -eq 0) { Note ("{0,-34} NE POSHLO: {1}" -f $label, $why); return }
    # One surviving replicate reports a 0.0% spread and looks like the cleanest arm in the table.
    # It is not a spread at all - there is nothing to disagree with. A single value cannot show
    # contamination, which is the only thing the spread was there to catch, so it is named for what
    # it is rather than printed as a result.
    if ($vals.Count -lt 2) {
        Note ("{0,-34} {1,6:N2} tok/s  <<< tolko 1 povtor iz 3 - ne rezultat ({2})" -f $label, $vals[0], $why)
        return
    }
    $mean = ($vals | Measure-Object -Average).Average
    $spread = 100.0*(($vals|Measure-Object -Maximum).Maximum - ($vals|Measure-Object -Minimum).Minimum)/$mean
    # Above the 4.2% noise floor the mean of three disagreeing numbers is not a result, and saying
    # so is the whole reason the earlier attempts were thrown away instead of reported.
    $flag = if ($spread -gt 4.2) { '  <<< razbros vyshe shuma, ne schitaetsja' } else { '' }
    Note ("{0,-34} {1,6:N2} tok/s (razbros {2:N1}%, {3}){4}" -f $label, $mean, $spread,
          (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'), $flag)
}

("`n`n######## tri modeli " + (Get-Date)) | Add-Content $LOG
$bad = Startable ("$BIN" + [char]92 + "llama-cli.exe")
if ($bad) { Note $bad; exit 1 }
if (-not (Take-Machine -Who 'three_models' -TimeoutMin 600 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    Say 'Qwen3-Coder-30B-A3B, 4 bita'
    Arm '30B mx1, rtr'      'D:\Qwen3-Coder-30B-A3B-mx1.gguf' @('-rtr') 900
    Arm '30B mx1, mmap'     'D:\Qwen3-Coder-30B-A3B-mx1.gguf' @()       900

    Say 'Gemma 4 26B-A4B, Q4_K_XL - nash dvizhok ejo poka ne gruzit, eto baza forka'
    Arm 'Gemma 26B, rtr'    'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf' @('-rtr') 900
    Arm 'Gemma 26B, mmap'   'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf' @()       900

    Say 'Qwen3.6 35B-A3B Q6_K - 27.3 GB, rezidentno ne vlezaet, tolko mmap'
    Arm '35B Q6_K, mmap'    'D:\Qwen3.6-35B-A3B-UD-Q6_K.gguf' @()        1200

    Say 'chego zhdat po bajtam'
    Note '30B:   1721 MB/tok -> 67.8 ms -> 14.7 tok/s potolok pri 24.8 GB/s'
    Note 'Gemma: 2586 MB/tok -> 101.8 ms -> 9.8 tok/s'
    Note '35B:   2843 MB/tok -> 111.9 ms -> 8.9 tok/s'
    Note 'esli zamer sil-no nizhe potolka - eto ne pamjat, a schjot ili zagruzka.'
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
