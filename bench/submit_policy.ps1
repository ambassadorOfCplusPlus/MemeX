# What the Vulkan submit policy is worth on a real model graph.
#
# WHY THIS IS RUN ON THE MODEL AND NOT ON A PROBE. The last measurement in this line established
# the lesson the hard way: a synthetic graph of chained adds contains no matmul, so
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
#                            ability of ggml_vk_wait_for_fence to sleep rather than spin.
#
# WHY THIS CONFIGURATION. -ngl 99 -ot exps=CPU is the card plan's boundary: attention, router, head
# and KV on the device, experts on the host. It matters here for a second reason - ggml_backend_sched
# cuts the graph at every backend change, so each Vulkan piece is roughly one layer's worth of
# nodes, which is exactly the small-graph regime where the upstream rule submits after nearly every
# matmul. If the whole model were on the device this would be one large graph and the rule would
# behave as upstream intended.
#
# BOTH PHASES, DELIBERATELY. Submitting rarely trades overlap away for submits. Generation runs one
# token at a time, so its matmuls are thin and the recording is a large share of the work; prefill
# runs a whole prompt at once, so its matmuls are fat and the overlap being given up is worth more.
# The two can easily want different constants, and a single number chosen on generation alone would
# be chosen on half the evidence. llama-cli reports both, so both are read from the same run.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$VK  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
$LOG = 'D:\MemeX\results\submit_policy.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$P   = 'D:\MemeX\results\prompt_2000.txt'

function Say($m)  { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

# One arm: set the switches, run llama-cli $reps times, return prefill and generation tok/s.
# Both numbers come out of the same process, so an arm costs one model load rather than two.
function Arm($label, $divisor, $tail, $reps, $limitSec) {
    $gen = @(); $pre = @(); $err = ''
    for ($r = 1; $r -le $reps; $r++) {
        $so = "D:\MemeX\results\_sp_$($label -replace '[^A-Za-z0-9]','')_$r.out"
        $env:GGML_VK_SUBMIT_DIVISOR = "$divisor"
        $env:GGML_VK_SUBMIT_TAIL    = "$tail"
        $a = @('-m', $M, '-f', $P, '-n', '128', '-c', '4096', '-t', '8',
               '-fa', 'off', '--seed', '1', '--no-display-prompt',
               '-ngl', '99', '-ot', 'exps=CPU')
        $p = Start-Process -FilePath "$VK\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden -PassThru `
                 -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        if (-not $p.WaitForExit($limitSec * 1000)) {
            Stop-Process -Id $p.Id -Force -EA SilentlyContinue; $err = 'tajm-aut'; continue
        }
        $out = @(); if (Test-Path $so) { $out += Get-Content $so }
        if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
        $hg = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($hg -and $hg.Line -match '([\d.]+) tokens per second') { $gen += [double]$Matches[1] }
        $hp = $out | Select-String -Pattern 'prompt eval time' | Select-Object -First 1
        if ($hp -and $hp.Line -match '([\d.]+) tokens per second') { $pre += [double]$Matches[1] }
        if (-not $hg) {
            $bad = $out | Select-String -Pattern 'not supported|failed|error|abort|assert' | Select-Object -First 1
            if ($bad) { $err = $bad.Line.Trim() }
        }
        Start-Sleep -Seconds 10
    }
    Remove-Item Env:\GGML_VK_SUBMIT_DIVISOR, Env:\GGML_VK_SUBMIT_TAIL -EA SilentlyContinue
    Report $label $pre $gen $err
    return
}

# A mean with the spread beside it, and a name rather than a number when there is not enough to
# average. One replicate has nothing to disagree with, so its 0.0% spread is the absence of the
# check, not evidence of a quiet machine. The floor on this machine is 4.2%.
function Report($label, $pre, $gen, $err) {
    if ($gen.Count -eq 0) { Note ("{0,-34} NE POSHLO: {1}" -f $label, $err); return }
    $line = "{0,-34}" -f $label
    foreach ($pair in @(@('prefill', $pre), @('gen', $gen))) {
        $name = $pair[0]; $v = @($pair[1])
        if ($v.Count -eq 0) { $line += ("  {0} --" -f $name); continue }
        $mean = ($v | Measure-Object -Average).Average
        if ($v.Count -lt 2) { $line += ("  {0} {1,7:N2} (1 povtor - ne rezultat)" -f $name, $mean); continue }
        $sp = 100.0*(($v|Measure-Object -Maximum).Maximum - ($v|Measure-Object -Minimum).Minimum)/$mean
        $flag = if ($sp -gt 4.2) { '!' } else { ' ' }
        $line += ("  {0} {1,7:N2} tok/s ({2,4:N1}%{3})" -f $name, $mean, $sp, $flag)
    }
    Note $line
}

("`n`n######## submit policy " + (Get-Date)) | Add-Content $LOG

# The second argument exists because the lock is held by whoever owns the machine, and that is not
# always this script. When a caller already holds it - a session that took it to compile, say -
# taking it again here would be this process waiting on its own owner, which is the parent/child
# deadlock lock.ps1's own header lists as one of the four collisions that cost this project a day.
$reps     = if ($args.Count -gt 0) { [int]$args[0] } else { 3 }
$ownsLock = -not ($args.Count -gt 1 -and $args[1] -eq 'external')
if ($ownsLock) {
    if (-not (Take-Machine -Who 'submit-policy' -TimeoutMin 120 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
} else {
    Note 'blokirovka u vyzyvajushchego, sami ne berjom'
}
Note ('vladeem: ' + (Get-LockHolder))
try {
    Say "razvedka i svip, povtorov na plecho: $reps"
    Note '! posle razbrosa = vyshe shumovogo poroga 4.2%'

    Arm 'A. 40  (upstream)'      40 1 $reps 900
    Arm 'B. 8'                    8 1 $reps 900
    Arm 'C. 1'                    1 1 $reps 900
    Arm 'D. 0   (bajtovoe pravilo off)' 0 1 $reps 900
    Arm 'E. 0 + bez tail'         0 0 $reps 900
} finally {
    if ($ownsLock) { Free-Machine; Note 'mashina osvobozhdena' }
}
