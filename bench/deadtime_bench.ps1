# Benchmarki MJORTVOGO VREMENI: zapuskajutsja hukom Claude Code (StopFailure/rate_limit), kogda
# sessija upjorlas v limit i reshenij prinimat nekomu. Vsjo, chto zdes est, ne trebuet reshenij:
# gotovye A/B, rezultat v fajl, potom koordinator prochitaet. Kazhdyj punkt idempotenten: esli
# ego fajl rezultata uzhe est - propuskaetsja (huk mozhet srabotat neskolko raz).
# Vsjo pod mashinnym zamkom, odnim processom. Latinica: PowerShell chitaet fajl bez metki kak ANSI.
#   pwsh -File C:\Users\User11\Desktop\MemeX\bench\deadtime_bench.ps1 [-DryRun]
param([switch]$DryRun, [int]$TimeoutMin = 240)
$R = 'D:\MemeX\results'
$LOG = "$R\deadtime_log.txt"
function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Out-File $LOG -Append -Encoding utf8 }
if ($DryRun -or $env:DEADTIME_DRYRUN -eq '1') { Note "DRYRUN: huk srabotal, nichego ne zapuskaju"; exit 0 }

# Odin ekzempljar: vtoroj zapusk poka idjot pervyj - vyhod.
$mtx = New-Object System.Threading.Mutex($false, 'Global\MemeX_deadtime_bench')
if (-not $mtx.WaitOne(0)) { Note "uzhe idjot drugoj ekzempljar - vyhod"; exit 0 }

. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$BIN = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
$MX1 = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_micro.txt'

function OurTok($file) {
    $l = Select-String -Path $file -Pattern 'our_tok_s\s+([\d.]+)' | Select-Object -Last 1
    if ($l) { return [double]$l.Matches[0].Groups[1].Value }
    return $null
}

Note "start (TimeoutMin $TimeoutMin)"
if (-not (Take-Machine -Who 'deadtime' -TimeoutMin $TimeoutMin)) { Note "NE POLUCHIL MASHINU"; exit 3 }
try {
    # 1. Svip potokov na CPU-puti mx1: -t 4 / 6 / 8, plechi chereduyutsja, 3 kruga.
    $out1 = "$R\deadtime_threads_mx1.txt"
    if (-not (Test-Path $out1)) {
        Note "punkt 1: svip potokov"
        $res = @{ 4 = @(); 6 = @(); 8 = @() }
        for ($r = 1; $r -le 3; $r++) {
            foreach ($t in 4, 6, 8) {
                $so = "$R\_deadtime_t${t}_$r.out"
                & "$BIN\llama-memex-fwd.exe" -m $MX1 -f $PROMPT --tokens 32 --gen 32 -t $t --no-repack --no-ref *> $so
                $v = OurTok $so
                "krug $r  -t $t : $v tok/s" | Out-File $out1 -Append -Encoding utf8
                if ($v) { $res[$t] += $v }
            }
        }
        foreach ($t in 4, 6, 8) {
            $a = $res[$t]
            if ($a.Count -ge 2) {
                $m = ($a | Measure-Object -Average).Average; $mx = ($a | Measure-Object -Maximum).Maximum; $mn = ($a | Measure-Object -Minimum).Minimum
                ("-t {0}: {1}  srednee {2:N2}  razbros {3:N1}%" -f $t, ($a -join ' / '), $m, (($mx - $mn) / $m * 100)) | Out-File $out1 -Append -Encoding utf8
            }
        }
        "NE IZMERENO: Coder Next (ne vlezaet v OZU bez statiki na karte); karta ne uchastvovala" | Out-File $out1 -Append -Encoding utf8
        Note "punkt 1 gotov"
    } else { Note "punkt 1 uzhe est - propusk" }

    # 2. Chestnyj A/B protiv shtatnogo forka (-ngl 99 -ot exps=CPU), nash - statika+rezidentnye eksperty.
    $out2 = "$R\deadtime_fair_fork.txt"
    if (-not (Test-Path $out2)) {
        Note "punkt 2: fork A/B"
        $ours = @(); $fork = @()
        for ($r = 1; $r -le 3; $r++) {
            $so = "$R\_deadtime_ours_$r.out"
            & "$BIN\llama-memex-fwd.exe" -m $MX1 -f $PROMPT --tokens 32 --gen 32 -t 8 --no-repack --no-ref --gpu-static-layers --gpu-experts --resident 0 --resident-period 3 *> $so
            $v = OurTok $so
            "krug $r  NASH : $v tok/s" | Out-File $out2 -Append -Encoding utf8
            if ($v) { $ours += $v }
            $sf = "$R\_deadtime_fork_$r.out"
            & "$BIN\llama-cli.exe" -m $MX1 -f $PROMPT -n 32 -c 2048 -t 8 -ngl 99 -ot "exps=CPU" -fa off --no-warmup *> $sf
            $l2 = Select-String -Path $sf -Pattern 'eval time.*tokens per second' | Where-Object { $_.Line -notmatch 'prompt eval' } | Select-Object -Last 1
            $w = $null; if ($l2 -and $l2.Line -match '([\d.]+)\s*tokens per second') { $w = [double]$Matches[1] }
            "krug $r  FORK : $w tok/s" | Out-File $out2 -Append -Encoding utf8
            if ($w) { $fork += $w }
        }
        foreach ($pair in @(@('NASH', $ours), @('FORK', $fork))) {
            $a = $pair[1]
            if ($a.Count -ge 2) {
                $m = ($a | Measure-Object -Average).Average; $mx = ($a | Measure-Object -Maximum).Maximum; $mn = ($a | Measure-Object -Minimum).Minimum
                ("{0}: {1}  srednee {2:N2}  razbros {3:N1}%" -f $pair[0], ($a -join ' / '), $m, (($mx - $mn) / $m * 100)) | Out-File $out2 -Append -Encoding utf8
            }
        }
        "NE IZMERENO: sovpadenie tokenov mezhdu plechami; fork s -rtr; nash s luchshej konfiguraciej rezidentnosti (flagi vzjaty iz period32_ab.ps1)" | Out-File $out2 -Append -Encoding utf8
        Note "punkt 2 gotov"
    } else { Note "punkt 2 uzhe est - propusk" }
    Note "vsjo gotovo"
} finally { Free-Machine; $mtx.ReleaseMutex() | Out-Null }
