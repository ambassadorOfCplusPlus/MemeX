# A/B: pre-patch upstream 8337e4c against our memex fork, same model, same flags, interleaved.
#
# The 14.04 baseline was taken by spec_study.ps1 on 26.08 at 18:06 with the binary in
# build\bin\Release, and that binary logged "main: build = 1 (8337e4c)" - pure upstream. The same
# directory was overwritten by our build at 21:02. So the comparison the regression claim rests on
# is between two binaries that no longer coexist. This script rebuilds the reference and runs both
# in one session, interleaved, because the same post-patch binary has already produced 11.99, 12.95
# and 13.38 tok/s on this arm in three different sessions - a spread wider than the 7.6% being
# attributed to the patches.
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$LOG  = 'D:\MemeX\results\repack_hunt.log'
$NEW  = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release\llama-cli.exe'
$OLD  = 'D:\MemeX\src\ik_upstream\build\bin\Release\llama-cli.exe'
$P    = 'D:\MemeX\results\prompt_short.txt'
$M    = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }

# Pauza po sostojaniju pamjati, ne po chasam (pravilo 51).
function Settle {
    param([int]$MaxSec = 180, [int]$TolMB = 200)
    $prev = -1; $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        Start-Sleep -Seconds 5
        $free = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
        if ($prev -ge 0 -and [math]::Abs($free - $prev) -le $TolMB) { return $free }
        $prev = $free
    }
    return $prev
}

function RunOne($exe, [string[]]$extra, $tag) {
    $so = "D:\MemeX\results\_hunt_$tag.out"
    $a = @('-m', $M, '-f', $P, '-n', '256', '-c', '2048', '-t', '8', '-ngl', '0',
           '-fa', 'off', '--seed', '1', '--no-display-prompt') + $extra
    $proc = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    $ok = $proc.WaitForExit(900 * 1000)
    if (-not $ok) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; $null = Settle; return $null }
    $out = @()
    if (Test-Path $so)       { $out += Get-Content $so -EA SilentlyContinue }
    if (Test-Path "$so.err") { $out += Get-Content "$so.err" -EA SilentlyContinue }
    $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    $v = $null
    if ($h -and $h.Line -match '([\d.]+) tokens per second') { $v = [double]$Matches[1] }
    $null = Settle
    return $v
}

("`n`n######## repack-hunt: A/B 8337e4c protiv memex " + (Get-Date)) | Add-Content $LOG
if (-not (Test-Path $OLD)) { Note "net referensnogo binarnika $OLD"; exit 1 }
if (-not (Take-Machine -Who 'repack-hunt' -TimeoutMin 180 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    $arms = @(
        @{ n='upstream 8337e4c, rtr'; x=$OLD; e=@('-rtr'); t='u_rtr' },
        @{ n='memex, rtr';            x=$NEW; e=@('-rtr'); t='m_rtr' },
        @{ n='upstream 8337e4c, mmap';x=$OLD; e=@();       t='u_mm'  },
        @{ n='memex, mmap';           x=$NEW; e=@();       t='m_mm'  })
    $res = @{}; foreach ($a in $arms) { $res[$a.n] = @() }

    Say 'progrev - odna zagruzka, kotoraja ne schitaetsja'
    $null = RunOne $NEW @('-rtr') 'warm'
    Note 'progrev sdelan'

    Say 'chetyre plecha, tri raunda vperemezhku'
    for ($round = 1; $round -le 3; $round++) {
        $order = if ($round % 2 -eq 1) { $arms } else { $arms[($arms.Count-1)..0] }
        foreach ($a in $order) {
            $v = RunOne $a.x $a.e ($a.t + "_$round")
            if ($v) { $res[$a.n] += $v } else { Note ("{0}: raund {1} bez chisla" -f $a.n, $round) }
        }
        Note ("raund {0} projden" -f $round)
    }

    Say 'itog'
    $mean = @{}
    foreach ($a in $arms) {
        $vals = $res[$a.n]
        if ($vals.Count -lt 2) { Note ("{0,-28} {1} povtorov - ne rezultat" -f $a.n, $vals.Count); continue }
        $m = ($vals | Measure-Object -Average).Average
        $mean[$a.n] = $m
        $spread = 100.0*(($vals|Measure-Object -Maximum).Maximum - ($vals|Measure-Object -Minimum).Minimum)/$m
        $flag = if ($spread -gt 4.2) { '  <<< vyshe shuma' } else { '' }
        Note ("{0,-28} {1,6:N2} tok/s (razbros {2:N1}%, {3}){4}" -f $a.n, $m, $spread,
              (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'), $flag)
    }
    Say 'chto iz etogo sleduet'
    if ($mean.ContainsKey('upstream 8337e4c, rtr') -and $mean.ContainsKey('memex, rtr')) {
        $d = 100.0*($mean['memex, rtr'] - $mean['upstream 8337e4c, rtr'])/$mean['upstream 8337e4c, rtr']
        Note ('nashi patchi na rtr: {0:N1}% (polozhitelno = my bystree)' -f $d)
    }
    foreach ($k in @('upstream 8337e4c','memex')) {
        if ($mean.ContainsKey("$k, rtr") -and $mean.ContainsKey("$k, mmap")) {
            $d = 100.0*($mean["$k, rtr"] - $mean["$k, mmap"])/$mean["$k, mmap"]
            Note ('{0}: perepakovka daet {1:N1}%' -f $k, $d)
        }
    }
    Say 'dreif mashiny po raundam'
    for ($round = 1; $round -le 3; $round++) {
        $rv = @(); foreach ($a in $arms) { if ($res[$a.n].Count -ge $round) { $rv += $res[$a.n][$round-1] } }
        if ($rv.Count) { Note ("raund {0}: srednee po plecham {1:N2} tok/s" -f $round, (($rv | Measure-Object -Average).Average)) }
    }
} finally { Free-Machine; Note 'mashina osvobozhdena' }
