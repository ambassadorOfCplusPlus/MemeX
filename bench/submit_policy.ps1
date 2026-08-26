# What the Vulkan submit policy is worth on a real model graph.
#
# WHY THIS IS RUN ON THE MODEL AND NOT ON A PROBE. The measurement that produced this patch
# established the lesson the hard way: a synthetic graph of chained adds contains no matmul, so
# total_mat_mul_bytes is zero, so ggml's submit threshold is zero, so it submitted after every
# node - and the probe spent a day reporting the cost of a vkQueueSubmit under the name "the cost
# of a dispatch". The rule being tuned here reads the graph's contents. A graph that is not the
# real one is tuning a different rule.
#
# WHAT IS BEING SWEPT. ggml-vulkan.cpp now reads three switches (see the comment at the point of
# use there):
#
#   GGML_VK_SUBMIT_DIVISOR   threshold = total_mat_mul_bytes / divisor. Upstream 40. Smaller means
#                            rarer submits. 0 turns the byte rule off and leaves only the node cap,
#                            the almost_ready submit and the last node.
#   GGML_VK_SUBMIT_TAIL      0 removes the almost_ready submit at 80% of the graph, and with it the
#                            ability of ggml_vk_wait_for_fence to sleep rather than spin over the
#                            bulk of the wait. That is why it is swept separately and not folded
#                            into the divisor: it buys a submit and sells a sleeping CPU, and on a
#                            machine whose eight threads are also running the expert FFNs those are
#                            not the same currency.
#
# WHY THIS CONFIGURATION. -ngl 99 -ot exps=CPU is the card plan boundary: attention, router, head
# and KV on the device, experts on the host. It matters here for a second reason - ggml_backend_sched
# cuts the graph at every backend change, so each Vulkan piece is roughly one layer worth of nodes,
# which is exactly the small-graph regime where the upstream rule submits after nearly every matmul.
# If the whole model were on the device this would be one large graph and the rule would behave as
# upstream intended.
#
# BOTH PHASES, DELIBERATELY. Submitting rarely trades overlap away for submits. Generation runs one
# token at a time, so its matmuls are thin and recording is a large share of the work; prefill runs
# a whole prompt at once, so its matmuls are fat and the overlap given up is worth more. The two can
# want different constants, and a single number chosen on generation alone would be chosen on half
# the evidence. llama-cli reports both, so both come out of one run.
#
# REPLICATES ARE INTERLEAVED, NOT BLOCKED. Round one runs every arm once, then round two, then round
# three. The reason is on the machine right now: the run holding the lock ahead of this one reported
# 15.8% spread across three consecutive replicates of a single unchanging arm, four times the noise
# floor. Whatever drifts on that scale - thermals, page cache, a background service - lands on
# whichever arm happens to be running when it drifts. Blocked replicates would charge that drift to
# one arm and call it an effect. Interleaved, it lands on all of them.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$VK  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
$LOG = 'D:\MemeX\results\submit_policy.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$P   = 'D:\MemeX\results\prompt_2000.txt'

function Say($m)  { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

# One llama-cli run under one setting of the switches. Prefill and generation both come out of the
# same process, so an arm costs one model load rather than two.
function RunOnce($tag, $divisor, $tail, $limitSec) {
    $so = "D:\MemeX\results\_sp_$tag.out"
    $env:GGML_VK_SUBMIT_DIVISOR = "$divisor"
    $env:GGML_VK_SUBMIT_TAIL    = "$tail"
    $a = @('-m', $M, '-f', $P, '-n', '128', '-c', '4096', '-t', '8',
           '-fa', 'off', '--seed', '1', '--no-display-prompt',
           '-ngl', '99', '-ot', 'exps=CPU')
    $p = Start-Process -FilePath "$VK\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    $done = $p.WaitForExit($limitSec * 1000)
    Remove-Item Env:\GGML_VK_SUBMIT_DIVISOR, Env:\GGML_VK_SUBMIT_TAIL -EA SilentlyContinue
    if (-not $done) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue; return @{ err = 'tajm-aut' } }
    $out = @(); if (Test-Path $so) { $out += Get-Content $so }
    if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
    $res = @{ err = '' }
    $hg = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    if ($hg -and $hg.Line -match '([\d.]+) tokens per second') { $res.gen = [double]$Matches[1] }
    $hp = $out | Select-String -Pattern 'prompt eval time' | Select-Object -First 1
    if ($hp -and $hp.Line -match '([\d.]+) tokens per second') { $res.pre = [double]$Matches[1] }
    if (-not $res.ContainsKey('gen')) {
        $bad = $out | Select-String -Pattern 'not supported|failed|error|abort|assert' | Select-Object -First 1
        if ($bad) { $res.err = $bad.Line.Trim() }
    }
    Start-Sleep -Seconds 10
    return $res
}

# A mean with the spread beside it, and a name rather than a number when there is not enough to
# average. One replicate has nothing to disagree with, so its 0.0% spread is the absence of the
# check, not evidence of a quiet machine. The floor on this machine is 4.2%.
function Summ($name, $vals) {
    $v = @($vals | Where-Object { $_ -ne $null })
    if ($v.Count -eq 0) { return ("  {0} --" -f $name) }
    $mean = ($v | Measure-Object -Average).Average
    if ($v.Count -lt 2) { return ("  {0} {1,7:N2} (1 povtor - ne rezultat)" -f $name, $mean) }
    $sp = 100.0*(($v|Measure-Object -Maximum).Maximum - ($v|Measure-Object -Minimum).Minimum)/$mean
    $flag = if ($sp -gt 4.2) { '!' } else { ' ' }
    return ("  {0} {1,7:N2} tok/s ({2,4:N1}%{3})" -f $name, $mean, $sp, $flag)
}

("`n`n######## submit policy " + (Get-Date)) | Add-Content $LOG

# The second argument exists because the lock is held by whoever owns the machine, and that is not
# always this script. When a caller already holds it - a session that took it to compile, say -
# taking it again here would be this process waiting on its own owner, which is the parent/child
# deadlock the header of lock.ps1 lists as one of the four collisions that cost this project a day.
$reps     = if ($args.Count -gt 0) { [int]$args[0] } else { 3 }
$ownsLock = -not ($args.Count -gt 1 -and $args[1] -eq 'external')
if ($ownsLock) {
    if (-not (Take-Machine -Who 'submit-policy' -TimeoutMin 120 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
} else {
    Note 'blokirovka u vyzyvajushchego, sami ne berjom'
}
Note ('vladeem: ' + (Get-LockHolder))
try {
    $arms = @(
        @{ tag = 'A40'; label = 'A. divisor 40 (upstream)'; div = 40; tail = 1 },
        @{ tag = 'B8';  label = 'B. divisor 8';             div = 8;  tail = 1 },
        @{ tag = 'C1';  label = 'C. divisor 1';             div = 1;  tail = 1 },
        @{ tag = 'D0';  label = 'D. divisor 0, bajty off';  div = 0;  tail = 1 },
        @{ tag = 'E0T'; label = 'E. divisor 0, bez tail';   div = 0;  tail = 0 }
    )
    foreach ($arm in $arms) { $arm.gen = @(); $arm.pre = @() }

    Say "svip politiki otpravki, raundov: $reps, plech: $($arms.Count)"
    Note 'znak vosklicanija posle razbrosa = vyshe shumovogo poroga 4.2 procenta'

    for ($r = 1; $r -le $reps; $r++) {
        Say "raund $r iz $reps"
        foreach ($arm in $arms) {
            $res = RunOnce "$($arm.tag)_$r" $arm.div $arm.tail 900
            if ($res.ContainsKey('gen')) { $arm.gen += $res.gen }
            if ($res.ContainsKey('pre')) { $arm.pre += $res.pre }
            if (-not $res.ContainsKey('gen')) {
                Note ("{0,-30} raund {1}: NE POSHLO {2}" -f $arm.label, $r, $res.err)
            } else {
                $pv = 0.0
                if ($res.ContainsKey('pre')) { $pv = $res.pre }
                Note ("{0,-30} raund {1}: prefill {2,7:N2}  gen {3,6:N2}" -f $arm.label, $r, $pv, $res.gen)
            }
        }
    }

    Say 'itog'
    foreach ($arm in $arms) {
        Note (("{0,-30}" -f $arm.label) + (Summ 'prefill' $arm.pre) + (Summ 'gen' $arm.gen))
    }
} finally {
    if ($ownsLock) { Free-Machine; Note 'mashina osvobozhdena' }
}
