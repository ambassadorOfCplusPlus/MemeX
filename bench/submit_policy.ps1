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

# Wait on state, not on a clock.
#
# A fixed sleep between replicates was the harness's assumption that fifteen seconds is enough for
# the machine to become idle again. It is not. Each of these runs holds about 15 GB and frees it on
# exit, and Windows zeroes freed pages in a background thread - so the next replicate starts while
# the system is still working through the last one's leavings, and gets fewer cores than it asked
# for. The evidence is in the prefill column of the run that held the lock before this one:
# 116.80 ms/token on one replicate and 31.71 on the next, of an unchanged arm. Prefill is
# compute-bound; a 3.7x swing there is not bandwidth, not cache and not thermals, it is the process
# not getting the cores.
#
# So: poll free memory until it stops rising. Two readings within 200 MB means the reclaim has
# finished. The cap is there because a wait that cannot end is worse than a wait that is too short -
# thirteen hours were lost to one in this project - and because on a machine that is genuinely busy
# with something else, the lock, not this loop, is the thing that should be complaining.
function Wait-Settled([int]$capSec = 180, [int]$deltaMB = 200) {
    $prev = -1.0
    $deadline = (Get-Date).AddSeconds($capSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB   # KiB -> MiB
        if ($prev -ge 0 -and [math]::Abs($free - $prev) -lt $deltaMB) { return $free }
        $prev = $free
    }
    return $prev
}

function Say($m)  { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

# One llama-cli run under one setting of the switches. Prefill and generation both come out of the
# same process, so an arm costs one model load rather than two.
function RunOnce($tag, $divisor, $tail, $limitSec) {
    # Who else is on the machine, sampled at the moment this arm starts.
    #
    # This is here because the evening's 15-35 percent drift turned out to be an agent on an
    # unrelated project compiling, and neither the harness nor the lock saw it: the guard was a list
    # of the compiler names WE use, and a different toolchain is not on that list. Two diagnoses
    # were argued from that absence and both were wrong. Get-CpuHogs asks how much of the machine a
    # process is eating rather than what it is called, so it cannot be fooled the same way - and
    # logging it per run means the next anomalous arm arrives with the evidence attached instead of
    # with a story fitted to it afterwards.
    $hogs = Get-CpuHogs -MinPct 12
    if ($hogs) {
        Note ('  KONKURENTY pered progonom: ' + (($hogs | ForEach-Object { "$($_.Name)/$($_.Id) $([math]::Round($_.Pct,0))%" }) -join ', '))
    }
    $so = "D:\MemeX\results\_sp_$tag.out"
    $env:GGML_VK_SUBMIT_DIVISOR = "$divisor"
    $env:GGML_VK_SUBMIT_TAIL    = "$tail"
    # The direct measurement. tok/s on this configuration is mostly the CPU's expert share, and the
    # machine has been moving 15-25 percent this evening for reasons nobody has found; an effect
    # worth a few percent of a token cannot be read off it. Submits per graph and milliseconds
    # inside graph_compute are what the policy actually changes, and neither depends on how fast
    # the CPU ran its half.
    $env:GGML_VK_SUBMIT_STATS   = '1'
    $a = @('-m', $M, '-f', $P, '-n', '128', '-c', '4096', '-t', '8',
           '-fa', 'off', '--seed', '1', '--no-display-prompt',
           '-ngl', '99', '-ot', 'exps=CPU')
    $p = Start-Process -FilePath "$VK\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    $done = $p.WaitForExit($limitSec * 1000)
    Remove-Item Env:\GGML_VK_SUBMIT_DIVISOR, Env:\GGML_VK_SUBMIT_TAIL, Env:\GGML_VK_SUBMIT_STATS -EA SilentlyContinue
    if (-not $done) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue; return @{ err = 'tajm-aut' } }
    $out = @(); if (Test-Path $so) { $out += Get-Content $so }
    if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
    $res = @{ err = '' }
    $hg = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    if ($hg -and $hg.Line -match '([\d.]+) tokens per second') { $res.gen = [double]$Matches[1] }
    $hp = $out | Select-String -Pattern 'prompt eval time' | Select-Object -First 1
    if ($hp -and $hp.Line -match '([\d.]+) tokens per second') { $res.pre = [double]$Matches[1] }
    $hs = $out | Select-String -Pattern 'ggml_vulkan submit stats' | Select-Object -First 1
    if ($hs -and $hs.Line -match 'grafov (\d+), uzlov (\d+) \(([\d.]+) na graf\), submitov (\d+) \(([\d.]+) na graf, ([\d.]+) na uzel\), v graph_compute ([\d.]+) ms') {
        $res.graphs    = [double]$Matches[1]
        $res.nodesper  = [double]$Matches[3]
        $res.subper    = [double]$Matches[5]
        $res.vkms      = [double]$Matches[7]
    }
    if (-not $res.ContainsKey('gen')) {
        $bad = $out | Select-String -Pattern 'not supported|failed|error|abort|assert' | Select-Object -First 1
        if ($bad) { $res.err = $bad.Line.Trim() }
    }
    # $null = : a bare call would emit its return value into RunOnce's output stream and
    # the caller would receive an array instead of the result hashtable.
    $null = Wait-Settled
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

# Drop the divisor-8 arm on demand, rather than a replicate.
#
# The two are not interchangeable when the lock arrives late. An arm without at least two replicates
# reports a 0.0% spread, which is the absence of the noise check rather than a quiet machine, so
# cutting rounds to fit five arms into the time left produces five numbers none of which is a
# result. Cutting an arm keeps the check intact on the ones that remain. B is the one to cut because
# it is the interior point of the divisor scale: A is upstream, C and D are the ends, E is the
# separate tail question. Losing B costs shape, not the comparison.
$dropB8 = ($args -contains 'no8')
if ($ownsLock) {
    if (-not (Take-Machine -Who 'submit-policy' -TimeoutMin 120 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
} else {
    Note 'blokirovka u vyzyvajushchego, sami ne berjom'
}
Note ('vladeem: ' + (Get-LockHolder))
try {
    $arms = @(
        @{ tag = 'A40'; label = 'A. divisor 40 (upstream)'; div = 40; tail = 1 },
        @{ tag = 'C1';  label = 'C. divisor 1';             div = 1;  tail = 1 },
        @{ tag = 'D0';  label = 'D. divisor 0, bajty off';  div = 0;  tail = 1 },
        @{ tag = 'E0T'; label = 'E. divisor 0, bez tail';   div = 0;  tail = 0 }
    )
    if (-not $dropB8) {
        $arms = @($arms[0]) + @(@{ tag = 'B8'; label = 'B. divisor 8'; div = 8; tail = 1 }) + @($arms[1..($arms.Count-1)])
    }
    foreach ($arm in $arms) { $arm.gen = @(); $arm.pre = @(); $arm.subper = @(); $arm.vkms = @(); $arm.nodesper = @() }

    # Per-round means across all arms. Every round contains every arm exactly once, so these are
    # directly comparable to each other and the only thing that separates them is when they ran.
    # If they disagree, the machine drifted during the sweep and the arm means are standing on a
    # moving floor - which is a thing to report, not a thing to average away.
    $roundGen = @(); $roundPre = @()

    Say "svip politiki otpravki, raundov: $reps, plech: $($arms.Count)"
    Note 'znak vosklicanija posle razbrosa = vyshe shumovogo poroga 4.2 procenta'

    # One load thrown away before anything is counted. The run holding the lock ahead of this one
    # reported 5.61 / 5.71 / 7.37 across three replicates of one unchanging arm - the third load
    # 31 percent faster than the first - and 10.22 / 10.06 / 10.85 on another. Replicate three
    # being the fast one in two arms out of three is not thermal drift, which would go the other
    # way; it is the model arriving in the page cache. Counterbalancing does not fix that, because
    # it is a trend across rounds rather than a position within one. Discarding the first load does.
    Say 'progrev: odna zagruzka modeli vholostuju, rezultat vybrasyvaetsja'
    $null = RunOnce 'warm' 40 1 900

    for ($r = 1; $r -le $reps; $r++) {
        # Counterbalanced order: odd rounds forward, even rounds reversed. Interleaving already
        # stops a slow drift from being charged to one arm, but with a fixed order a drift WITHIN
        # a round still lands on arm position - the arm that always runs last always runs on the
        # warmest machine. Reversing alternate rounds cancels that to first order, and costs
        # nothing but a line. Given the 25% unexplained movement on this machine this evening,
        # paying nothing for a defence against it is an easy trade.
        $order = if ($r % 2 -eq 1) { $arms } else { $arms[($arms.Count - 1)..0] }
        Say ("raund {0} iz {1}, porjadok: {2}" -f $r, $reps, (($order | ForEach-Object { $_.tag }) -join ' '))
        $gs = @(); $ps = @()
        foreach ($arm in $order) {
            $t0 = Get-Date
            $res = RunOnce "$($arm.tag)_$r" $arm.div $arm.tail 900
            if ($res.ContainsKey('gen')) { $arm.gen += $res.gen; $gs += $res.gen }
            if ($res.ContainsKey('pre')) { $arm.pre += $res.pre; $ps += $res.pre }
            if ($res.ContainsKey('subper')) { $arm.subper += $res.subper; $arm.vkms += $res.vkms; $arm.nodesper += $res.nodesper }
            if (-not $res.ContainsKey('gen')) {
                Note ("{0,-30} raund {1}: NE POSHLO {2}" -f $arm.label, $r, $res.err)
            } else {
                $pv = 0.0
                if ($res.ContainsKey('pre')) { $pv = $res.pre }
                $sp = 0.0; $vk = 0.0
                if ($res.ContainsKey('subper')) { $sp = $res.subper; $vk = $res.vkms }
                Note ("{0,-30} raund {1} [{2}]: prefill {3,7:N2}  gen {4,6:N2}  submitov/graf {5,5:N2}  vk {6,8:N1} ms" -f
                      $arm.label, $r, $t0.ToString('HH:mm'), $pv, $res.gen, $sp, $vk)
            }
        }
        if ($gs.Count -gt 0) { $roundGen += ($gs | Measure-Object -Average).Average }
        if ($ps.Count -gt 0) { $roundPre += ($ps | Measure-Object -Average).Average }
    }

    Say 'itog po plecham (sravnenie vnutri svipa, ne s izmerenijami drugih dnej)'
    foreach ($arm in $arms) {
        Note (("{0,-30}" -f $arm.label) + (Summ 'prefill' $arm.pre) + (Summ 'gen' $arm.gen))
    }

    # The direct half. Same work in every arm - same prompt, same 128 tokens - so the number of
    # submits and the time spent inside graph_compute are comparable across arms without any
    # assumption about what the CPU side was doing.
    Say 'prjamoe izmerenie: chto imenno menjaet politika'
    foreach ($arm in $arms) {
        Note (("{0,-30}" -f $arm.label) + (Summ 'submitov/graf' $arm.subper) +
              (Summ 'vk ms za progon' $arm.vkms) + (Summ 'uzlov/graf' $arm.nodesper))
    }

    # The drift check. Each round holds the same five arms, so a difference between rounds is
    # time and nothing else.
    Say 'drejf: srednee po vsem plecham v kazhdom raunde'
    Note (("{0,-30}" -f 'raundy po porjadku') + (Summ 'prefill' $roundPre) + (Summ 'gen' $roundGen))
    if ($roundGen.Count -ge 2) {
        $rm = ($roundGen | Measure-Object -Average).Average
        $rs = 100.0*(($roundGen|Measure-Object -Maximum).Maximum - ($roundGen|Measure-Object -Minimum).Minimum)/$rm
        Note (('po raundam: ' + (($roundGen | ForEach-Object { $_.ToString('N2') }) -join ' -> ')))
        if ($rs -gt 4.2) {
            Note ("DREJF {0:N1} procenta mezhdu raundami - vyshe poroga 4.2. Mashina dvigalas vo" -f $rs)
            Note 'vremja svipa, znachit absoljutnye chisla plech stojat na plyvushchem polu.'
            Note 'Sravnenie mezhdu plechami vyzhivaet (kazhdyj raund soderzhit vse plechi),'
            Note 'sravnenie s ljubym izmereniem drugogo dnja - net.'
        } else {
            Note ("{0:N1} procenta mezhdu raundami - v predelah shuma, mashina stojala rovno." -f $rs)
            Note 'Eto samo po sebe rezultat: ranshe segodnja te zhe plechi hodili na 15-35 procentov,'
            Note 'i edinstvennoe chto izmenilos - chuzhaja sborka na sosednem proekte ostanovlena.'
        }
    }
} finally {
    if ($ownsLock) { Free-Machine; Note 'mashina osvobozhdena' }
}
