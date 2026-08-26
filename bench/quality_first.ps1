# Quality-first configuration: what speed can we get WITHOUT paying any perplexity?
#
# The priority changed. Every mx candidate is out of budget - mx1 costs +7.9% and the four
# calibrated ones +9.6 to +10.7% - so the base returns to the original Q6_K at 2.1236, and the
# only admissible speedups are the ones that are bit-exact or distribution-exact:
#
#   repacking      - rewrites the weight layout, same bits, zero quality cost
#   graph reuse    - same arithmetic, zero cost
#   speculation    - provably preserves the target distribution, zero cost
#   -muge, -ub, threads, LTO - layout and scheduling only
#   prefill on the card - same arithmetic on another device
#
# The open question this script exists to answer: Q6_K is 24.5 GB and repacking forces mmap off
# (llama-model-loader.cpp:588), making the whole model resident private memory. On 32 GB that
# may simply not fit alongside the KV cache. If it does not, then the single largest quality-free
# speedup is unavailable on the quality-first base - and shrinking the file (bit ladder on rarely
# used experts) stops being decoration and becomes the precondition for it.
#
# So every arm reports free RAM before it runs, and an arm that cannot fit says so instead of
# quietly returning a thrashed number. Last night's whole speed table was lost to exactly that.

$ErrorActionPreference = 'Continue'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$VK  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
$LOG = 'D:\MemeX\results\quality_first.log'
$Q6  = 'D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf'
$MX1 = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$DR4 = 'D:\smartstock\models\qwen3-0.6b-q4_k_m.gguf'
$DR3 = 'D:\qwen3-0.6b-iq3.gguf'
$TEXT = 'D:\MemeX\data\calibration.txt'
$LONG = 'D:\MemeX\results\prompt_code.txt'
$PROMPT = 'Write a Python function that merges two sorted lists and explain each step.'
$REF = 2.1236

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

function Busy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'llama-moe-trace','memex-fwd','memex-test','llama-memex-fwd','llama-memex-test')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function WaitQuiet { $q = 0; while ($q -lt 6) { if (Busy) { $q = 0 } else { $q++ }; Start-Sleep -Seconds 30 } }

# needGB is the resident footprint we expect. Refusing to run is a result; a thrashed number is
# not - it looks like a measurement and is worse than a gap.
function Speed($label, $model, [string[]]$extra, $needGB) {
    if (-not (Test-Path $model)) { Note ("{0,-34} net fajla" -f $label); return }
    $free = FreeGB
    if ($free -lt $needGB) {
        Note ("{0,-34} OTKAZ: svobodno {1:N1} GB, nuzhno ~{2} GB" -f $label, $free, $needGB); return
    }
    $a = @('-m', $model, '-p', $PROMPT, '-n', '128', '-c', '4096', '-t', '4',
           '-ngl', '0', '-fa', 'off', '--seed', '1', '--no-display-prompt') + $extra
    $out = & "$BIN\llama-cli.exe" @a 2>&1
    $hit = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    if ($hit -and $hit.Line -match '([\d.]+) tokens per second') {
        Note ("{0,-34} {1} tok/s   (svobodno bylo {2:N1} GB)" -f $label, $Matches[1], $free)
    } else {
        Note ("{0,-34} ne zapustilos" -f $label)
        $out | Select-String -Pattern 'error|failed|alloc' | Select-Object -Last 2 |
            ForEach-Object { Note ("      " + $_.Line.Trim()) }
    }
    [System.GC]::Collect(); Start-Sleep -Seconds 25
}

function Ppl($label, $model, [string[]]$extra) {
    if (-not (Test-Path $model)) { Note ("{0,-34} net fajla" -f $label); return }
    $a = @('-m', $model, '-f', $TEXT, '-c', '512', '--chunks', '16', '-t', '4',
           '-ngl', '0', '-fa', 'off') + $extra
    $out = & "$BIN\llama-perplexity.exe" @a 2>&1
    $hit = $out | Select-String -Pattern 'Final estimate' | Select-Object -First 1
    if ($hit -and $hit.Line -match '= ([\d.]+) \+/-') {
        $v = [double]$Matches[1]
        $d = 100.0 * ($v - $REF) / $REF
        Note ("{0,-34} ppl {1}  ({2:+0.00;-0.00}%)" -f $label, $v, $d)
    } else { Note ("{0,-34} ne poschitalos" -f $label) }
    Start-Sleep -Seconds 20
}

("`n`n######## quality-first " + (Get-Date)) | Add-Content $LOG
Say 'waiting for the machine'
WaitQuiet
Note ("free RAM: {0:N1} GB" -f (FreeGB))
Note ("Q6_K on disk: {0:N1} GB" -f ((Get-Item $Q6).Length / 1GB))

# --------------------------------------------------------------- 1. does repacking even fit?
# The decisive question. Q6_K is 24.5 GB and -rtr makes it fully resident.
Say 'Q6_K: does repacking fit in memory at all'
Speed 'Q6_K, no rtr (mmap on)'  $Q6 @()        8
Speed 'Q6_K, with rtr'          $Q6 @('-rtr') 26

# --------------------------------------------------------------- 2. quality-free speedups on Q6
Say 'quality-free speedups on the Q6_K base'
Speed 'Q6_K + muge'             $Q6 @('-muge')                    8
Speed 'Q6_K + ub 128'           $Q6 @('-ub','128')                8
Speed 'Q6_K + ub 1024'          $Q6 @('-ub','1024')               8
Speed 'Q6_K, threads 3'         $Q6 @('-t','3')                   8
Speed 'Q6_K, threads 8'         $Q6 @('-t','8')                   8
Speed 'Q6_K + draft Q4 nmax3'   $Q6 @('-md',$DR4,'--spec-type','draft:n_max=3')  10
if (Test-Path $DR3) {
    Speed 'Q6_K + draft IQ3 nmax3' $Q6 @('-md',$DR3,'--spec-type','draft:n_max=3') 10
    Speed 'Q6_K + draft IQ3 nmax4' $Q6 @('-md',$DR3,'--spec-type','draft:n_max=4') 10
}
Speed 'Q6_K + muge + draft IQ3'  $Q6 @('-muge','-md',$DR3,'--spec-type','draft:n_max=3') 10

# --------------------------------------------------------------- 3. confirm the base perplexity
# Re-measuring the reference in the same session as everything else: the number 2.1236 comes
# from an earlier session, and a baseline measured elsewhere is exactly how this project once
# manufactured a fake "cost of four bits".
Say 'base perplexity, re-measured here'
Ppl 'Q6_K' $Q6 @()
Ppl 'mx1 (for contrast, +7.9% expected)' $MX1 @('-rtr')

# --------------------------------------------------------------- 4. prefill on the card
# Quality-free: same arithmetic, different device. Reported separately from generation because
# the two are limited by different things, and mixing them hid this for a whole session. Last
# night gave ngl 0/8/16 -> 2.37/3.17/3.59 tok/s, but under memory contention, so it is unusable
# except as a hint that the direction is right.
Say 'prefill on the card, clean'
if ((Test-Path "$VK\llama-cli.exe") -and (Test-Path $LONG)) {
    foreach ($n in @(0, 8, 16, 24)) {
        $free = FreeGB
        if ($free -lt 26) { Note ("ngl=$n OTKAZ: svobodno {0:N1} GB" -f $free); continue }
        $a = @('-m', $Q6, '-f', $LONG, '-n', '8', '-c', '8192', '-t', '4',
               '-ngl', "$n", '-fa', 'off', '--seed', '1', '--no-display-prompt')
        $out = & "$VK\llama-cli.exe" @a 2>&1
        $pp = $out | Select-String -Pattern '^(main|llama_print_timings): prompt eval time' | Select-Object -First 1
        if ($pp -and $pp.Line -match '([\d.]+) tokens per second') {
            Note ("{0,-34} prefill {1} tok/s" -f "ngl=$n", $Matches[1])
        } else {
            Note ("{0,-34} ne zapustilos" -f "ngl=$n")
            $out | Select-String -Pattern 'error|alloc|Vulkan' | Select-Object -Last 2 |
                ForEach-Object { Note ("      " + $_.Line.Trim()) }
        }
        Start-Sleep -Seconds 20
    }
} else { Note 'net build-vk ili dlinnogo prompta' }

# --------------------------------------------------------------- 5. our engine on the Q6 base
Say 'our engine on the quality-first base'
$ours = Join-Path $BIN 'llama-memex-fwd.exe'
if (Test-Path $ours) {
    foreach ($arm in @(@('ours, Q6_K', @()), @('ours, Q6_K + repack', @('-rtr')))) {
        $need = if ($arm[1].Count -gt 0) { 26 } else { 8 }
        $free = FreeGB
        if ($free -lt $need) { Note ("{0,-34} OTKAZ: svobodno {1:N1} GB" -f $arm[0], $free); continue }
        $out = & $ours (@('-m', $Q6, '-p', 'Write a Python function that merges two sorted lists.',
                          '--gen', '64', '-t', '4') + $arm[1]) 2>&1
        Note ("{0}:" -f $arm[0])
        $out | Select-String -Pattern 'ток/с|tok/s|скорость' | Select-Object -Last 2 |
            ForEach-Object { Note ("    " + $_.Line.Trim()) }
        Start-Sleep -Seconds 25
    }
} else { Note 'net llama-memex-fwd.exe' }

# --------------------------------------------------------------- 6. the two untested middles
# A little quality loss is acceptable, just not four-bit experts. Two points in that band were
# never measured, both missed because every earlier candidate ALSO put the output head into
# four bits - and the importance matrix has zero coverage for output.weight, so the head was
# quantised blind. The head is 14% of the byte budget, and mx1 (head kept at Q6) scored 2.2918
# while every candidate with a four-bit head landed at 2.33-2.35. So the head is confounding
# everything and both candidates here leave it alone.
#
#   mx7 - experts at four bits, head untouched, calibrated: the honest cost of four-bit experts
#   mx8 - experts at FIVE bits, head untouched, calibrated: the point nobody tried
#
# Expectation, stated before measuring so it can be wrong: e(4 bits) is 0.074 per the direct
# measurement, and if error roughly halves per added bit then five bits should cost a third to a
# half of what four bits cost. If +7.9% is the four-bit price, five bits ought to land near
# +2-3% - inside the acceptable band - for about 8-9% fewer bytes per token than Q6.
$IMAT = 'D:\MemeX\results\imatrix2.dat'
$MX7  = 'D:\Qwen3-Coder-30B-A3B-mx7.gguf'
$MX8  = 'D:\Qwen3-Coder-30B-A3B-mx8.gguf'
$P7 = 'ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq4_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks'
$P8 = 'ffn_up_exps=iq5_ks,ffn_gate_exps=iq5_ks,ffn_down_exps=iq5_ks,attn_q.weight=iq5_ks,attn_output.weight=iq5_ks'

foreach ($cand in @(@('mx8 (5 bit, head untouched)', $MX8, $P8),
                    @('mx7 (4 bit, head untouched)', $MX7, $P7))) {
    Say ("building " + $cand[0])
    if (-not (Test-Path $cand[1])) {
        & "$BIN\llama-quantize.exe" --allow-requantize --imatrix $IMAT --custom-q $cand[2] `
            $Q6 $cand[1] q6_k 4 *> ("D:\MemeX\results\quant_" + (Split-Path $cand[1] -Leaf) + ".log")
    }
    if (Test-Path $cand[1]) {
        Note ("size: {0:N2} GB" -f ((Get-Item $cand[1]).Length / 1GB))
        # Confirm the head really was left alone rather than trusting the profile string.
        $hl = Select-String -Path ("D:\MemeX\results\quant_" + (Split-Path $cand[1] -Leaf) + ".log") `
                  -Pattern 'output\.weight' -EA SilentlyContinue | Select-Object -First 1
        if ($hl) { Note ("  head: " + $hl.Line.Trim()) }
        Ppl   $cand[0] $cand[1] @('-rtr')
        Speed $cand[0] $cand[1] @('-rtr') 18
        Speed ($cand[0] + ' + draft') $cand[1] @('-rtr','-md',$DR3,'--spec-type','draft:n_max=3') 19
    } else {
        Note 'ne skvantovalos'
    }
}

# --------------------------------------------------------------- 7. mx9: unlock -mqkv
# A consequence of two separate findings meeting. The flag audit found -mqkv - merging Q, K and V
# into one contiguous matmul - is a no-op on every file we have, because merging requires
# wq, wk and wv to share a type (src/llama-load-tensors.cpp:4555) and Unsloth's recipe leaves
# attn_q at one type while attn_k and attn_v are Q8_0. But that type is OUR choice when we
# requantise. Give all three the same type and the flag becomes available - and attention weights
# are 28% of the bytes read on every single token, so locality there is worth chasing.
#
# Five bits, not four, because the error ladder says five costs 3.73% against four bits' 7.60%,
# and the head stays at six because a four-bit head was measured at about +2% perplexity for
# only 5% of the bytes.
$MX9 = 'D:\Qwen3-Coder-30B-A3B-mx9.gguf'
$P9  = 'ffn_up_exps=iq5_ks,ffn_gate_exps=iq5_ks,ffn_down_exps=iq5_ks,' +
       'attn_q.weight=iq5_ks,attn_k.weight=iq5_ks,attn_v.weight=iq5_ks,attn_output.weight=iq5_ks'
Say 'mx9: experts and ALL of q/k/v at five bits, so -mqkv can actually merge'
if (-not (Test-Path $MX9)) {
    & "$BIN\llama-quantize.exe" --allow-requantize --imatrix $IMAT --custom-q $P9 `
        $Q6 $MX9 q6_k 4 *> 'D:\MemeX\results\quant_mx9.log'
}
if (Test-Path $MX9) {
    Note ("size: {0:N2} GB" -f ((Get-Item $MX9).Length / 1GB))
    # Confirm all three really landed on the same type - the whole point of this candidate.
    foreach ($probe in @('blk\.0\.attn_q\.weight', 'blk\.0\.attn_k\.weight',
                         'blk\.0\.attn_v\.weight', 'output\.weight')) {
        $l = Select-String -Path 'D:\MemeX\results\quant_mx9.log' -Pattern $probe -EA SilentlyContinue |
             Select-Object -First 1
        if ($l) { Note ("  " + $l.Line.Trim()) } else { Note "  $probe - net v loge" }
    }
    Ppl   'mx9' $MX9 @('-rtr')
    Speed 'mx9'                 $MX9 @('-rtr')          18
    Speed 'mx9 + mqkv'          $MX9 @('-rtr','-mqkv')  18
    Speed 'mx9 + mqkv + muge'   $MX9 @('-rtr','-mqkv','-muge') 18
    if (Test-Path $DR3) {
        Speed 'mx9 + mqkv + draft' $MX9 @('-rtr','-mqkv','-md',$DR3,'--spec-type','draft:n_max=3') 19
    }
} else {
    Note 'mx9 ne skvantovalsja:'
    Get-Content 'D:\MemeX\results\quant_mx9.log' -Tail 4 -EA SilentlyContinue | ForEach-Object { Note ("    " + $_) }
}

# --------------------------------------------------------------- prediction, corrected
# The first version of this prediction was wrong and the correction matters more than the guess.
# It used a Q6 byte split of experts 0.93 + attention 0.51 + head 0.26 = 1.70 GB/token. The
# measured budget is 2.794 GB/token for Q6_K_XL - the split was low by 64%, because the expert
# share was underestimated and the router was omitted entirely (ffn_gate_inp is f32 and costs
# 48 MiB/token, more than attn_k and attn_v together).
#
# The same arithmetic error produced a phantom "28% of the time is not memory". It was not: mx1
# reads 1.804 GB/token, and 1.804 / 72.7 ms = 24.8 GB/s, i.e. exactly the machine's bandwidth.
# The 1.29 GB/token figure implied 3.39 bits per weight over 3.042B active parameters - below
# iq4_xs, the coarsest type in the file. Impossible, and it should have been caught by that check.
#
# Corrected expectation, from Q6's real 2.794 GB/token and its measured split:
#   five-bit experts and attention, six-bit head  ->  about 2.3 GB/token  ->  ~10.8 tok/s
# So mx8 and mx9 should be SLOWER than mx1's 13.76, not faster: five bits buys quality back at
# the cost of speed. The frontier on this model is roughly
#   Q6 8.9 tok/s at +0%  |  five bits ~10.8 at +2..4%  |  four bits 13.76 at +7.9%
# and 20 tok/s needs <=1.21-1.25 GB/token, which is below even four-bit experts. On this model it
# is arithmetically out of reach; the only lever that amortises weight reads across tokens is
# speculative decoding, and the only other route is a model with fewer active parameters.
Note 'prognoz: mx8/mx9 okolo 10.5-11 tok/s pri +2..+4% ppl - MEDLENNEE mx1, eto obmen skorosti na kachestvo'

# --------------------------------------------------------------- threads, with replicates
# Two findings force this. First, the thread curve does not saturate: 177.4/99.2/84.4/80.4/74.6 ms
# at t=1/2/3/4/8, so t=8 is 7% faster than t=4 - four cores cannot keep enough loads in flight,
# and the hyperthreads add memory-level parallelism rather than compute. Second, this contradicts
# a long-standing belief in this project that four threads beat eight (12.82 against 12.17), and
# that gap was 5.3% - right at the noise floor, which four replicates of an identical config put
# at CV 4.2% with a 9.9% range. So the old conclusion was probably noise.
#
# Hence replicates, not single runs. Anything under about 5% here is not a result.
Say 'threads: t=4 against t=8, three replicates each'
$best = if (GoodGguf $MX9) { $MX9 } elseif (GoodGguf $MX8) { $MX8 } else { $MX1 }
Note ("na modeli: " + (Split-Path $best -Leaf))
foreach ($t in @('4','8')) {
    for ($r = 1; $r -le 3; $r++) { Speed ("t=$t povtor $r") $best @('-rtr','-t',$t) 18 }
}

# --------------------------------------------------------------- the router in f16
# ffn_gate_inp is stored f32 and costs 2.8% of the bytes read every token - more than attn_k and
# attn_v combined. Halving it is 1.4% for a routing decision that only needs to rank 128 experts,
# where f16 has far more precision than the decision requires. Cheap to try, easy to verify: if
# the quantiser refuses the type it will say so in the log.
Say 'router f32 -> f16'
$MXR = 'D:\Qwen3-Coder-30B-A3B-mx1r.gguf'
if (-not (Test-Path $MXR)) {
    & "$BIN\llama-quantize.exe" --allow-requantize --imatrix $IMAT `
        --custom-q 'ffn_gate_inp.weight=f16,ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq4_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks' `
        $Q6 $MXR q6_k 4 *> 'D:\MemeX\results\quant_mx1r.log'
}
if (Test-Path $MXR) {
    Note ("size: {0:N2} GB" -f ((Get-Item $MXR).Length / 1GB))
    $l = Select-String -Path 'D:\MemeX\results\quant_mx1r.log' -Pattern 'ffn_gate_inp' -EA SilentlyContinue | Select-Object -First 1
    if ($l) { Note ("  " + $l.Line.Trim()) } else { Note '  ffn_gate_inp net v loge - vozmozhno tip otvergnut' }
    Ppl 'mx1r (router f16)' $MXR @('-rtr')
    for ($r = 1; $r -le 3; $r++) { Speed ("mx1r povtor $r") $MXR @('-rtr','-t','8') 18 }
    for ($r = 1; $r -le 3; $r++) { Speed ("mx1 povtor $r (dlja sverki)") $MX1 @('-rtr','-t','8') 18 }
} else {
    Note 'mx1r ne skvantovalsja:'
    Get-Content 'D:\MemeX\results\quant_mx1r.log' -Tail 4 -EA SilentlyContinue | ForEach-Object { Note ("    " + $_) }
}

Say 'done'
