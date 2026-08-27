# The static output head on the card, measured against the same engine without it.
#
# ONE BINARY, TWO ARMS, ONE SESSION. The point of the A/B is that nothing differs between the
# arms except the flag: same exe, same model, same prompt, same length, interleaved rounds. The
# stored 12.97 tok/s baseline is deliberately NOT the comparator - another agent is hunting a
# 7.6% repack regression in this tree right now, so a number from yesterday describes a
# different binary.
#
# The arms:
#   cpu     llama-memex-static, everything on the CPU. This is llama-memex-fwd's behaviour
#           exactly: with --gpu-static absent, head_matmul() returns ggml_mul_mat(w.out, cur),
#           which is the line it replaced.
#   card    the same, with output.weight in video memory and the head computed there.
#
# WHAT THE CONTROL IS. Every run also drives llama_decode over the same tokens for the logit
# comparison, and llama_decode does not know the card exists. So ref_tok_s is a quantity that
# MUST NOT move between the arms, and if it does the machine moved rather than the arm - the
# same role prefill played when a 3.7x swing on a compute-bound phase proved that a bandwidth
# story was wrong. It is printed beside every arm rather than checked once at the start,
# because a gate tests a condition at an instant and a measurement occupies an interval.
#
# Rounds are interleaved (cpu, card, cpu, card, ...) rather than blocked (cpu x3 then card x3):
# a machine that drifts over ten minutes puts all of that drift into the difference when the
# arms are blocked, and splits it evenly when they are interleaved.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-static.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$LOG    = 'D:\MemeX\results\head_ab.log'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'

function Say($m)  { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

# Wait on state, not on a clock. Each run holds about 16 GB and frees it on exit; Windows zeroes
# freed pages in a background thread, so a fixed sleep starts the next replicate in competition
# with the reclaim of the last one. Two readings within 200 MB means it has finished. The cap is
# there because a wait that cannot end is worse than one that is too short.
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

# $proc, never $p: this project has twice lost replicates 2 and 3 of every arm to a local named
# after a single-letter script variable, because PowerShell does not distinguish case and the
# assignment then overwrote a path with a Process object.
function RunOnce($tag, [string[]]$extra, [int]$ngen, [int]$limitSec) {
    $hogs = Get-CpuHogs -MinPct 12
    if ($hogs) {
        Note ('  KONKURENTY pered progonom: ' +
              (($hogs | ForEach-Object { "$($_.Name)/$($_.Id) $([math]::Round($_.Pct,0))%" }) -join ', '))
    }
    $so = "D:\MemeX\results\_head_$tag.out"
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', '512', '-t', '8', '--gen', "$ngen") + $extra
    $proc = $null
    try {
        $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch {
        return @{ err = ('ne zapustilsja: ' + $_.Exception.Message) }
    }
    if ($null -eq $proc) { return @{ err = 'Start-Process nichego ne vernul' } }
    # Rule 55: touching .Handle before the wait is what makes the object keep the OS handle, and
    # without it .ExitCode comes back $null - which compares unequal to 0 and reports a failure
    # for a step that succeeded.
    $null = $proc.Handle
    $done = $proc.WaitForExit($limitSec * 1000)
    if (-not $done) {
        Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
        $null = Wait-Settled
        return @{ err = 'tajm-aut' }
    }
    $out = @()
    if (Test-Path $so) { $out += Get-Content $so }
    if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
    $res = @{ err = '' }
    $h = $out | Select-String -Pattern '^STATIC_AB ' | Select-Object -First 1
    if ($h -and $h.Line -match 'our_tok_s ([\d.]+) ref_tok_s ([\d.]+) gen_ms ([\d.]+) n_gen (\d+) head_ms ([\d.]+) static (\d)') {
        $res.gen  = [double]$Matches[1]
        $res.ref  = [double]$Matches[2]
        $res.head = [double]$Matches[5]
        $res.on   = [int]$Matches[6]
    }
    $f = $out | Select-String -Pattern 'USTROJSTVO OTKAZALO' | Select-Object -First 1
    if ($f) { $res.err = $f.Line.Trim() }
    if (-not $res.ContainsKey('gen') -and $res.err -eq '') {
        $bad = $out | Select-String -Pattern 'not supported|failed|abort|assert|--gpu-static:' |
               Select-Object -First 1
        $res.err = if ($bad) { $bad.Line.Trim() } else { "net stroki STATIC_AB (exit $($proc.ExitCode))" }
    }
    $null = Wait-Settled
    return $res
}

# A mean with the spread beside it, and a name rather than a number when there is not enough to
# average. One replicate has nothing to disagree with, so its 0.0% spread is the absence of the
# check and not evidence of a quiet machine. The floor on this machine is 4.2%.
function Summ($name, $vals) {
    $v = @($vals | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return ("  {0,-12} --" -f $name) }
    $mean = ($v | Measure-Object -Average).Average
    if ($v.Count -lt 2) { return ("  {0,-12} {1,7:N2} (1 povtor - ne rezultat)" -f $name, $mean) }
    $sp = 100.0 * (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $mean
    $flag = if ($sp -gt 4.2) { '!' } else { ' ' }
    return ("  {0,-12} {1,7:N2} ({2,4:N1}%{3}, n={4})" -f $name, $mean, $sp, $flag, $v.Count)
}

$reps     = if ($args.Count -gt 0) { [int]$args[0] } else { 3 }
$ngen     = if ($args.Count -gt 1) { [int]$args[1] } else { 192 }
$ownsLock = -not ($args -contains 'external')

("`n`n######## head A/B " + (Get-Date)) | Add-Content $LOG

if (-not (Test-Path -LiteralPath $EXE)) { Note "net binarnika: $EXE"; exit 1 }
if (-not (Test-Path -LiteralPath $PROMPT)) { Note "net promta: $PROMPT"; exit 1 }

# Rule 49: prove the binary runs before anything is measured with it. -1073741511 is a DLL/exe
# mismatch and -1073741515 is a DLL not found, and both happen before the program prints a single
# character, so no log pattern can tell them apart from "the model is slow".
& $EXE --help *> $null
$hc = $LASTEXITCODE
if ($null -eq $hc) { Note 'ExitCode pust - schitaem otkazom'; exit 1 }
if ($hc -ne 0) { Note "binarnik ne zapuskaetsja (exit $hc)"; exit 1 }

if ($ownsLock) {
    if (-not (Take-Machine -Who 'gpu-static' -TimeoutMin 120 -MinFreeGB 16)) {
        Note 'mashinu ne poluchili'; exit 1
    }
} else {
    Note 'blokirovka u vyzyvajushchego, sami ne berjom'
}
Note ('vladeem: ' + (Get-LockHolder))

$cpuGen = @(); $cpuRef = @()
$cardGen = @(); $cardRef = @(); $cardHead = @()
try {
    Say "A/B golovy: $reps raundov, --gen $ngen, prompt $PROMPT"
    for ($r = 1; $r -le $reps; $r++) {
        Say "raund $r / $reps"
        $a = RunOnce "cpu_$r" @() $ngen 900
        if ($a.err) { Note ("cpu  NE POSHLO: " + $a.err) }
        else {
            Note ("cpu  {0,7:N2} tok/s   etalon {1,6:N2}" -f $a.gen, $a.ref)
            $cpuGen += $a.gen; $cpuRef += $a.ref
        }
        $b = RunOnce "card_$r" @('--gpu-static') $ngen 900
        if ($b.err) { Note ("card NE POSHLO: " + $b.err) }
        else {
            Note ("card {0,7:N2} tok/s   etalon {1,6:N2}   golova {2:N3} ms/tokjen" -f
                  $b.gen, $b.ref, $b.head)
            $cardGen += $b.gen; $cardRef += $b.ref; $cardHead += $b.head
        }
    }

    Say 'itog'
    Note (Summ 'cpu  tok/s'  $cpuGen)
    Note (Summ 'card tok/s'  $cardGen)
    Note (Summ 'cpu  etalon' $cpuRef)
    Note (Summ 'card etalon' $cardRef)
    Note (Summ 'golova ms'   $cardHead)
    if ($cpuGen.Count -ge 2 -and $cardGen.Count -ge 2) {
        $mc = ($cpuGen  | Measure-Object -Average).Average
        $mg = ($cardGen | Measure-Object -Average).Average
        Note ("raznica: {0,+6:N2}% ({1:N2} -> {2:N2} tok/s), po vremeni tokjena {3:N2} -> {4:N2} ms" -f
              (100.0 * ($mg - $mc) / $mc), $mc, $mg, (1000.0 / $mc), (1000.0 / $mg))
        # The control. If the reference decoder's speed differs between the arms by more than the
        # noise floor, the machine moved and the difference above is not attributable to the flag.
        $rc = ($cpuRef  | Measure-Object -Average).Average
        $rg = ($cardRef | Measure-Object -Average).Average
        $drift = 100.0 * [math]::Abs($rg - $rc) / $rc
        Note ("kontrol (etalon, karty ne znaet): {0:N2} protiv {1:N2} tok/s, drejf {2:N1}%{3}" -f
              $rc, $rg, $drift, $(if ($drift -gt 4.2) { ' - MASHINA DVIGALAS, raznica vyshe ne pripisyvaetsja flagu' } else { '' }))
    } else {
        Note 'menshe dvuh povtorov v odnom iz plech - eto ne rezultat'
    }
} finally {
    if ($ownsLock) { Free-Machine }
    Note ('lock posle: ' + (Get-LockHolder))
}
