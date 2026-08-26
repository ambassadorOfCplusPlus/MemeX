# Overnight pipeline: one serial stream of heavy work so the machine never idles, and so two
# runs never compute at once - on four cores that puts about 13% of noise into every timing.
#
# Rewritten from sh to PowerShell after the sh version died instantly on a Cygwin fork failure
# ("cygheap read copy failed", "Resource temporarily unavailable"): several agents plus the
# running campaign had already exhausted MSYS's fork emulation. PowerShell does not emulate
# fork, so that whole failure class is gone. ASCII only, for the same class of reason - a
# previous .ps1 in this project failed to parse because of UTF-8 without BOM under PS 5.
#
# Order is by value of the answer, not convenience:
#   1. importance matrix, redone. The first one was void: the fused up-gate op reports stats
#      under src[0]'s name only, so ffn_gate_exps collected nothing, and save_imatrix drops any
#      tensor where some expert was never exercised, which cost 44 of 48 layers.
#   2. mx4 - same byte profile as mx3 but fully calibrated. mx1 (no calibration) / mx3
#      (attention only) / mx4 (everything) isolates calibration as the variable.
#   3. our own engine against the fork - decides how we develop the engine.
#   4. flags never measured.
#   5. mx5 - one more bit on down_exps, now under correct calibration. Last time this bought
#      nothing, which was the clue that the problem was calibration rather than bit allocation.

$ErrorActionPreference = 'Continue'

$BIN   = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG   = 'D:\MemeX\results\night.log'
$Q6    = 'D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf'
$MX1   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$MX3   = 'D:\Qwen3-Coder-30B-A3B-mx3.gguf'
$MX4   = 'D:\Qwen3-Coder-30B-A3B-mx4.gguf'
$MX5   = 'D:\Qwen3-Coder-30B-A3B-mx5.gguf'
$MX6   = 'D:\Qwen3-Coder-30B-A3B-mx6.gguf'
$DRAFT4 = 'D:\smartstock\models\qwen3-0.6b-q4_k_m.gguf'
$DRAFT3 = 'D:\qwen3-0.6b-iq3.gguf'
$IMAT  = 'D:\MemeX\results\imatrix2.dat'
$TEXT  = 'D:\MemeX\data\calibration.txt'
$PROMPT = 'Write a Python function that merges two sorted lists and explain each step.'
$REF_PPL = 2.1236   # Q6_K_XL on these exact settings; the quality budget is +2%

# Byte profile shared by mx3 and mx4, so calibration is the only difference between them.
$PROFILE  = 'ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq4_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks,output.weight=iq4_ks'
$PROFILE5 = 'ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq5_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks,output.weight=iq4_ks'
# mx6: restore the protection the source file had on the first and last block. The specific
# patterns come first, on the assumption that the earliest matching rule wins - verified after
# the run by reading back what the quantiser logged for blocks 0, 5 and 47.
$PROFILE6 = 'blk\.0\.ffn_.*_exps=q6_K,blk\.47\.ffn_.*_exps=q6_K,ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq4_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks,output.weight=iq4_ks'

function Say($m) {
    $line = "`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m
    $line | Tee-Object -FilePath $LOG -Append
}
function Note($m) {
    $line = "  $m"
    $line | Tee-Object -FilePath $LOG -Append
}

function Busy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix','memex-fwd')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# Five consecutive quiet minutes, so a short gap between two arms of the already-running
# campaign is not mistaken for the campaign being finished.
function WaitQuiet {
    $q = 0
    while ($q -lt 10) {
        if (Busy) { $q = 0 } else { $q++ }
        Start-Sleep -Seconds 30
    }
}

function Ppl($label, $model) {
    if (-not (Test-Path $model)) { Note ("{0,-32} net fajla" -f $label); return }
    $out = & "$BIN\llama-perplexity.exe" -m $model -f $TEXT -c 512 --chunks 16 `
              -t 4 -ngl 0 -fa off -rtr 2>&1
    $hit = $out | Select-String -Pattern 'Final estimate' | Select-Object -First 1
    if ($hit -and $hit.Line -match '= ([\d.]+) \+/-') {
        $v = [double]$Matches[1]
        $d = 100.0 * ($v - $REF_PPL) / $REF_PPL
        $verdict = if ($d -le 2.0) { 'v budzhete' } else { 'VNE BUDZHETA' }
        Note ("{0,-32} ppl {1}  ({2:+0.00;-0.00}% k {3}) {4}" -f $label, $v, $d, $REF_PPL, $verdict)
    } else {
        Note ("{0,-32} ne poschitalos" -f $label)
    }
}

function Speed($label, $model, [string[]]$extra) {
    if (-not (Test-Path $model)) { Note ("{0,-32} net fajla" -f $label); return }
    $a = @('-m', $model, '-p', $PROMPT, '-n', '128', '-c', '4096', '-t', '4',
           '-ngl', '0', '-fa', 'off', '-rtr', '--seed', '1', '--no-display-prompt')
    if ($extra) { $a += $extra }
    $out = & "$BIN\llama-cli.exe" @a 2>&1
    # llama-cli is built from examples/main, which prints its own timings with a "main:" prefix
    # (main.cpp:1394); the library's own llama_print_timings uses a different prefix. Accept
    # both, because an arm that silently matches nothing reads as a failed arm.
    $hit = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    if ($hit -and $hit.Line -match '([\d.]+) tokens per second') {
        Note ("{0,-32} {1} tok/s" -f $label, $Matches[1])
    } else {
        Note ("{0,-32} ne zapustilos" -f $label)
        $out | Select-Object -Last 4 | ForEach-Object { Note "      $_" }
    }
}

# A GGUF being written by the quantiser starts with a zero-filled metadata placeholder that is
# only backfilled at the very end, so "the file exists" does not mean "the file is usable".
# Checking the magic is the difference between measuring a model and measuring nothing.
function GoodGguf($path) {
    if (-not (Test-Path $path)) { return $false }
    try {
        $b = [byte[]]::new(4)
        $s = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $n = $s.Read($b, 0, 4); $s.Close()
        return ($n -eq 4 -and [System.Text.Encoding]::ASCII.GetString($b) -eq 'GGUF')
    } catch { return $false }
}

# How many of the 48 layers actually carry expert data. The first matrix looked fine by file
# size and was almost entirely useless; only this check would have caught it.
function Coverage {
    $py = @'
import collections, re, struct, sys
c = collections.Counter()
try:
    with open(r"D:\MemeX\results\imatrix2.dat", "rb") as f:
        n = struct.unpack("<i", f.read(4))[0]
        for _ in range(n):
            ln = struct.unpack("<i", f.read(4))[0]
            name = f.read(ln).decode("utf-8", "replace")
            ncall, nval = struct.unpack("<ii", f.read(8))
            f.read(4 * nval)
            c[re.sub(r"blk\.\d+\.", "blk.N.", name)] += 1
except Exception as e:
    print("unreadable:", e); sys.exit(0)
for k in ("blk.N.ffn_up_exps.weight", "blk.N.ffn_gate_exps.weight",
          "blk.N.ffn_down_exps.weight", "blk.N.attn_q.weight", "output.weight"):
    print("%-32s %d / 48" % (k, c.get(k, 0)))
'@
    $tmp = 'D:\MemeX\results\_cov.py'
    Set-Content -Path $tmp -Value $py -Encoding utf8
    & python $tmp 2>&1
}

New-Item -ItemType Directory -Force -Path 'D:\MemeX\results' | Out-Null
("`n`n######## night run, start " + (Get-Date)) | Add-Content -Path $LOG

Say 'waiting for the CPU to free up'
WaitQuiet
Note 'free'

# ------------------------------------------------------------------ 1. importance matrix
# An earlier queued job was orphaned rather than killed - its shell died, the imatrix process
# kept going, and it is computing exactly what is wanted here (400 chunks, fusion off). So
# check what is already on disk before spending another hour on it. The check is coverage, not
# file size: the first matrix looked healthy at 7.9 MB and was almost entirely useless.
$gate = 0
Say 'checking the matrix already on disk'
$cov = Coverage
$cov | ForEach-Object { Note "  $_" }
$g = $cov | Select-String -Pattern 'ffn_gate_exps'
if ($g -and $g.Line -match '(\d+) / 48') { $gate = [int]$Matches[1] }

if ($gate -ge 24) {
    Note "gate coverage $gate/48 - good enough, not recomputing"
} else {
    Say "gate coverage $gate/48 - computing the matrix: 400 chunks, up-gate fusion off"
    & "$BIN\llama-imatrix.exe" -m $Q6 -f $TEXT -o $IMAT --chunks 400 -c 512 `
        -t 4 -ngl 0 -fa off -rtr -no-fmoe -no-fug *> 'D:\MemeX\results\imatrix2.log'
    Note 'coverage:'
    $cov = Coverage
    $cov | ForEach-Object { Note "  $_" }
}

# -rtr repacks the weights and it is not certain the collection hooks behave identically for
# repacked types. If the expert tensors came out thin, redo it the slow plain way rather than
# quantise against a matrix we do not trust.
$gate = 0
$g = $cov | Select-String -Pattern 'ffn_gate_exps'
if ($g -and $g.Line -match '(\d+) / 48') { $gate = [int]$Matches[1] }
if ($gate -lt 24) {
    Say "gate coverage is poor ($gate/48) - redoing without -rtr"
    & "$BIN\llama-imatrix.exe" -m $Q6 -f $TEXT -o $IMAT --chunks 400 -c 512 `
        -t 4 -ngl 0 -fa off -no-fmoe -no-fug *> 'D:\MemeX\results\imatrix2b.log'
    Note 'coverage:'
    Coverage | ForEach-Object { Note "  $_" }
}

# ------------------------------------------------------------------ 2. mx4
Say 'mx4: profile of mx3 but with a calibrated matrix'
& "$BIN\llama-quantize.exe" --allow-requantize --imatrix $IMAT --custom-q $PROFILE `
    $Q6 $MX4 q6_k 4 *> 'D:\MemeX\results\quant4.log'
if (Test-Path $MX4) {
    Note ("size: {0:N1} GB" -f ((Get-Item $MX4).Length / 1GB))
}
$missing = (Select-String -Path 'D:\MemeX\results\quant4.log' -Pattern 'did not find weights' -AllMatches |
            Measure-Object).Count
Note "tensors with no matrix data: $missing"

Say 'quality and speed: mx1 (none) / mx3 (attention) / mx4 (all)'
Ppl 'mx4' $MX4
Ppl 'mx3' $MX3
Ppl 'mx1' $MX1
Speed 'mx4' $MX4 @()
if (Test-Path $DRAFT3) {
    Speed 'mx4 + draft IQ3 n_max=3' $MX4 @('-md', $DRAFT3, '--spec-type', 'draft:n_max=3')
} elseif (Test-Path $DRAFT4) {
    Speed 'mx4 + draft Q4 n_max=3' $MX4 @('-md', $DRAFT4, '--spec-type', 'draft:n_max=3')
}

# ------------------------------------------------------------------ 3. our engine vs the fork
# Three points, not two: the fork with -rtr, the fork WITHOUT -rtr, and us. The middle one is
# the honest baseline, because our engine does not repack weights yet - comparing against the
# fork's best configuration would repeat exactly the mistake that produced the bogus "cost of
# four bits" number, where the baseline was prepared better than the candidate.
Say 'our loop against the fork'
$model = if (GoodGguf $MX4) { $MX4 } elseif (GoodGguf $MX3) { $MX3 } else { $MX1 }
Note "model: $model"
$short = 'Write a Python function that merges two sorted lists.'
foreach ($arm in @(@('fork, with -rtr', @('-rtr')), @('fork, without -rtr', @()))) {
    $a = @('-m', $model, '-p', $short, '-n', '64', '-c', '2048', '-t', '4', '-ngl', '0',
           '-fa', 'off', '--seed', '1', '--no-display-prompt') + $arm[1]
    $out = & "$BIN\llama-cli.exe" @a 2>&1
    $hit = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    if ($hit -and $hit.Line -match '([\d.]+) tokens per second') {
        Note ("{0,-32} {1} tok/s" -f $arm[0], $Matches[1])
    } else { Note ("{0,-32} ne zapustilos" -f $arm[0]) }
}
# The binaries carry a "llama-" prefix from the example CMake convention - checking the wrong
# name would have silently skipped this whole section, which is the failure mode this project
# keeps hitting: an arm that measures nothing looks the same as an arm that measures zero.
#
# Three arms on our side: the binary as it was before tonight's two fixes (preserved on purpose),
# the fixed one, and the fixed one with load-time repacking. Repacking is behind a flag and off
# by default because the loader forces mmap off with it, turning a file-backed mapping into the
# whole model as resident private memory - about 16 GB here, which only fits on an idle machine.
$engine_arms = @(
    @('our engine, before fixes', 'llama-memex-fwd-BEFORE.exe', @()),
    @('our engine, after fixes',  'llama-memex-fwd.exe',        @()),
    @('our engine, with repack',  'llama-memex-fwd.exe',        @('-rtr'))
)
foreach ($arm in $engine_arms) {
    $exe = Join-Path $BIN $arm[1]
    if (-not (Test-Path $exe)) { Note ("{0,-32} binarnika net" -f $arm[0]); continue }
    $a = @('-m', $model, '-p', $short, '--gen', '64', '-t', '4') + $arm[2]
    $out = & $exe @a 2>&1
    Note ("{0}:" -f $arm[0])
    $out | Select-Object -Last 10 | ForEach-Object { Note "    $_" }
}

# ------------------------------------------------------------------ 4. flags never measured
# One thing changed per arm against the same baseline. Flags established as Linux-only
# (--prefetch-experts, --defer-experts, -thp) are deliberately absent, as are the ones already
# on by default (fused up-gate, graph reuse). An arm that will not start prints so rather than
# printing nothing: a silently empty result has caused a false conclusion here before.
Say 'flags never measured'
Speed 'baseline'           $model @()
Speed 'no mmap'            $model @('--no-mmap')
Speed 'mlock'              $model @('--mlock')
# -muge merges each layer's up and gate expert tensors into ONE contiguous buffer. Fusion of the
# two matmuls already happens by default, so this changes locality, not the op count - which is
# exactly the axis that matters when the limit is RAM bandwidth. It needs up and gate to share
# type and dims; both are IQ4_XS here, so it will actually engage.
Speed 'merge up-gate exps' $model @('-muge')
Speed 'ubatch 128'         $model @('-ub', '128')
Speed 'ubatch 1024'        $model @('-ub', '1024')
Speed 'threads 3'          $model @('-t', '3')
Speed 'threads 8'          $model @('-t', '8')
# Dropped from this sweep after reading the code rather than after wasting a run on each:
#   -mqkv    - needs wq/wk/wv to share a type; attn_q is IQ4_XS while attn_k/attn_v are Q8_0
#   -rcache  - removed from the fork, prints "no longer supported"
#   -sas -smgs - gated on split mode GRAPH; the default is LAYER and we have one device
#   -ger -gap -grt -mtp -mtprot - other architectures only, or throw outright
#   -wb --no-warmup - warmup is one BOS decode and timings are reset after it
#   -amb     - it is a threshold in MiB, and at one token per step the value is 0 MiB, so it
#              cannot fire during generation. Measured in the long-context section instead.

# Quantised KV at long context.
#
# Correcting a wrong belief before it costs a measurement: the fork's -ctk-first/-ctk-last take
# N as a number of LAYERS, not token positions (src/llama.cpp:1487-1502 indexes the layer loop).
# So this is per-layer cache precision, NOT the positional zoning we built by hand - within a
# layer the type stays uniform and there is one ordinary softmax. Positional zones remain ours
# alone, which is an argument for the engine rather than against it.
#
# Also from the code: quantised V throws without flash attention, so every arm here runs -fa on.
# And -amb is measured here rather than in the generation sweep, because it is a threshold in
# MiB that only a multi-token batch can cross.
Say 'quantised KV and per-layer precision at 16k'
$long = 'D:\MemeX\results\prompt_code.txt'
if (Test-Path $long) {
    $arms = @(
        @('f16 baseline',          @('-fa','on')),
        @('q8_0 everywhere',       @('-fa','on','-ctk','q8_0','-ctv','q8_0')),
        @('q8_0 + hadamard K',     @('-fa','on','-ctk','q8_0','-ctv','q8_0','-khad')),
        @('q8_0, f16 first 4 lay', @('-fa','on','-ctk','q8_0','-ctv','q8_0','-ctk-first','f16,4','-ctv-first','f16,4')),
        @('q8_0, f16 last 4 lay',  @('-fa','on','-ctk','q8_0','-ctv','q8_0','-ctk-last','f16,4','-ctv-last','f16,4')),
        @('f16 + amb 1024',        @('-fa','off','-amb','1024')),
        @('f16 + amb 0',           @('-fa','off','-amb','0'))
    )
    foreach ($arm in $arms) {
        $a = @('-m', $model, '-f', $long, '-n', '64', '-c', '16384', '-t', '4', '-ngl', '0',
               '-rtr', '--seed', '1', '--no-display-prompt') + $arm[1]
        $out = & "$BIN\llama-cli.exe" @a 2>&1
        $pp = ($out | Select-String -Pattern '^(main|llama_print_timings): prompt eval time' | Select-Object -First 1)
        $tg = ($out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1)
        $ppv = if ($pp -and $pp.Line -match '([\d.]+) tokens per second') { $Matches[1] } else { '?' }
        $tgv = if ($tg -and $tg.Line -match '([\d.]+) tokens per second') { $Matches[1] } else { '?' }
        Note ("{0,-32} prefill {1} tok/s, gen {2} tok/s" -f $arm[0], $ppv, $tgv)
    }
} else {
    Note "no long prompt file at $long - skipped"
}

# ------------------------------------------------------------------ 4b. speculation with a cheap draft
# Folded in from a separate campaign script that was running concurrently with the importance
# matrix - which made all of its timings worthless, so it was stopped and its unique arms moved
# here where they get the machine to themselves.
#
# Why the draft's price is the whole question: at n_max=3 about 2.4 tokens are accepted per
# round, attention and the head are read once per round, and the experts grow almost linearly
# with the batch (neighbouring tokens overlap only 34%). That should have given about x1.6. It
# gave x1.04, because the draft itself eats roughly 30% of the time: 379 MB read three times a
# round is 21% of the target model's byte budget. For it to pay, the draft has to cost about
# five percent - so roughly four times less.
Say 'cheaper draft and speculation'
if (-not (GoodGguf $DRAFT3)) {
    & "$BIN\llama-quantize.exe" --allow-requantize $DRAFT4 $DRAFT3 iq3_s 4 `
        *> 'D:\MemeX\results\quant_draft.log'
}
if (GoodGguf $DRAFT3) {
    Note ("draft IQ3: {0:N0} MB (bylo 379)" -f ((Get-Item $DRAFT3).Length / 1MB))
} else {
    Note 'draft IQ3 ne poluchilsja:'
    Get-Content 'D:\MemeX\results\quant_draft.log' -Tail 4 -EA SilentlyContinue |
        ForEach-Object { Note "    $_" }
}
Speed 'no speculation'          $model @()
Speed 'draft Q4  n_max=3'       $model @('-md', $DRAFT4, '--spec-type', 'draft:n_max=3')
if (GoodGguf $DRAFT3) {
    Speed 'draft IQ3 n_max=2'   $model @('-md', $DRAFT3, '--spec-type', 'draft:n_max=2')
    Speed 'draft IQ3 n_max=3'   $model @('-md', $DRAFT3, '--spec-type', 'draft:n_max=3')
    Speed 'draft IQ3 n_max=4'   $model @('-md', $DRAFT3, '--spec-type', 'draft:n_max=4')
}

# ------------------------------------------------------------------ 4c. prefill on the card
# Every "the card is useless" measurement in this project was taken on decoding, which is
# matrix-by-vector work bound by bandwidth and kernel-launch count. Prefill is matrix-by-matrix
# and bound by arithmetic, which is the card's own ground - so it is measured separately here,
# and only prompt-eval is reported.
#
# Known hazard: building targets in `build` has been observed to remove ggml.dll from
# build-vk's output directory. If that happened, these arms will fail to start, and the tail is
# printed so the cause is readable instead of guessable.
Say 'prefill on the card (Vulkan build)'
$VK = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
if ((Test-Path "$VK\llama-cli.exe") -and (Test-Path $long)) {
    foreach ($n in @(0, 8, 16)) {
        $a = @('-m', $model, '-f', $long, '-n', '8', '-c', '8192', '-t', '4',
               '-ngl', "$n", '-fa', 'off', '--seed', '1', '--no-display-prompt')
        $out = & "$VK\llama-cli.exe" @a 2>&1
        $pp = $out | Select-String -Pattern '^(main|llama_print_timings): prompt eval time' | Select-Object -First 1
        if ($pp -and $pp.Line -match '([\d.]+) tokens per second') {
            Note ("{0,-32} prefill {1} tok/s" -f "ngl=$n", $Matches[1])
        } else {
            Note ("{0,-32} ne zapustilos" -f "ngl=$n")
            $out | Select-Object -Last 3 | ForEach-Object { Note "      $_" }
        }
    }
} else {
    Note 'net build-vk\llama-cli.exe ili dlinnogo prompta - propusk'
}

# ------------------------------------------------------------------ 5. mx6
# The source file is not uniform: blocks 0 and 47 are stored q8_0 while 1..46 are q6_K. That is
# Unsloth's "UD ... XL" recipe deliberately protecting the first and last layer - and every mx
# profile so far requantised all 48 blocks to iq4_ks, i.e. threw that protection away. Two of
# 48 layers is about 4% of the bytes, so if it buys back a meaningful part of the perplexity
# it is the cheapest quality we can get.
#
# Note on per-expert precision, which this replaces: measured and dead. Requantisation error is
# flat across the 128 experts of a layer (median expert within ~1% of the least damaged one,
# same ~0.0743 floor in every layer and every tensor), so there is no concentration of damage to
# pay bits against. Per-LAYER allocation survives; per-expert does not.
Say 'mx6: layers 0 and 47 kept at q6_K, the rest iq4_ks'
& "$BIN\llama-quantize.exe" --allow-requantize --imatrix $IMAT --custom-q $PROFILE6 `
    $Q6 $MX6 q6_k 4 *> 'D:\MemeX\results\quant6.log'
if (Test-Path $MX6) { Note ("size: {0:N1} GB" -f ((Get-Item $MX6).Length / 1GB)) }
# --custom-q is a list of regex-to-type pairs and the match order decides the winner, which is
# an assumption worth checking rather than trusting: print what the quantiser actually chose.
foreach ($probe in @('blk\.0\.ffn_up_exps', 'blk\.5\.ffn_up_exps', 'blk\.47\.ffn_up_exps')) {
    $l = Select-String -Path 'D:\MemeX\results\quant6.log' -Pattern $probe -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($l) { Note ("  " + $l.Line.Trim()) } else { Note "  $probe - ne najdeno v loge" }
}
Ppl 'mx6' $MX6
Speed 'mx6' $MX6 @()

# ------------------------------------------------------------------ 6. mx5
Say 'mx5: one more bit on down_exps, now with correct calibration'
& "$BIN\llama-quantize.exe" --allow-requantize --imatrix $IMAT --custom-q $PROFILE5 `
    $Q6 $MX5 q6_k 4 *> 'D:\MemeX\results\quant5.log'
if (Test-Path $MX5) { Note ("size: {0:N1} GB" -f ((Get-Item $MX5).Length / 1GB)) }
Ppl 'mx5' $MX5
Speed 'mx5' $MX5 @()

# ------------------------------------------------------------------ 7. engine test harness
# Five levels: per-layer tensor agreement, logits, token agreement that tells a near-tie apart
# from a real error, cache behaviour past the first block, and determinism. It compiles and has
# had a review pass, but it has never been executed against a qwen3moe model - so this run is
# itself the first test of the tester.
#
# Hard timeout on purpose. Unproven code that hangs here would leave the log without its 'done'
# marker, and the watchdog would then relaunch the entire night from the beginning. Split into
# two invocations so a hang in the expensive levels does not cost the cheap ones.
Say 'engine test harness (first run ever on a real model)'
function RunLimited($label, $exe, [string[]]$a, $limitSec) {
    if (-not (Test-Path $exe)) { Note ("{0,-32} binarnika net" -f $label); return }
    $so = "D:\MemeX\results\test_$label.out" -replace '[ ,]', '_'
    $p = Start-Process -FilePath $exe -ArgumentList $a -RedirectStandardOutput $so `
             -RedirectStandardError "$so.err" -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit($limitSec * 1000)) {
        Stop-Process -Id $p.Id -Force -EA SilentlyContinue
        Note ("{0,-32} TAJM-AUT posle {1} s - ubit" -f $label, $limitSec)
    } else {
        Note ("{0,-32} kod vozvrata {1}" -f $label, $p.ExitCode)
    }
    Get-Content $so -Tail 14 -EA SilentlyContinue | ForEach-Object { Note "    $_" }
}
$TEST = Join-Path $BIN 'llama-memex-test.exe'
if (-not (Test-Path $TEST)) { $TEST = Join-Path $BIN 'memex-test.exe' }
RunLimited 'levels 5,2,3' $TEST @('-m', $model, '--levels', '5,2,3', '-t', '4') 1500
RunLimited 'levels 1,4'   $TEST @('-m', $model, '--levels', '1,4',   '-t', '4') 2400

Say 'done'
Note "summary in $LOG"
