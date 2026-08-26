# Speculative decoding, studied properly, because it is now the only route left to 20 tok/s.
#
# Why it is the only one. The roofline measurement settled that generation is 100% memory-bound:
# mx1 reads 1.804 GB/token and 1.804/72.7ms = 24.8 GB/s, exactly the machine's bandwidth. There
# is no overhead to remove. And the byte budget, computed from the GGUF headers for every model
# on this disk, says none of them can reach 20 tok/s:
#
#   mx1 (30B, 8/128 experts)        1.80 GB/token  ->  14.8
#   Coder-Next IQ3 (10/512)         2.20 GB/token  ->  11.3   (965 MiB of attention per token)
#   Qwen3.6-35B Q6 (8/256)          2.77 GB/token  ->   9.0
#   Gemma 4 26B-A4B (8/128)         3.24 GB/token  ->   7.7   (head tied to a 748 MiB embedding)
#
# 20 tok/s needs <= 1.24 GB/token. Quantisation cannot get there without going below four bits,
# which the error ladder prices at 2.09x the four-bit error. Activation sparsity is closed twice
# over. So the only lever that remains is the one that amortises a weight read across several
# tokens - and speculation is exactly that, and it is free in quality terms because rejection
# sampling preserves the target distribution exactly.
#
# The arithmetic to test. Per round with n_max=3 and ~2.4 tokens accepted, the target reads its
# attention, router and head ONCE for the whole batch, but its experts grow with the union of
# the batch's choices - measured overlap between neighbouring tokens is 34%, so about 2.2x rather
# than 3x. That gives roughly 1.49 GB/token, i.e. 16.6 tok/s, a 21% win. Measured previously: +4%.
# The gap has to be either the draft costing more than three reads of its own weights, or a lower
# acceptance rate than assumed. This script separates those two.

$ErrorActionPreference = 'Continue'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\spec_study.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$DR4 = 'D:\smartstock\models\qwen3-0.6b-q4_k_m.gguf'   # 379 MB
$DR3 = 'D:\qwen3-0.6b-iq3.gguf'                        # 297 MB
$DR2 = 'D:\qwen3-0.6b-iq2.gguf'                        # built below if missing
$SMALL = 'D:\smartstock\models\qwen3-1.7b-q4_k_m.gguf' # a stronger, costlier draft
$PROMPT = 'Write a Python function that merges two sorted lists and explain each step.'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }
function Busy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'llama-moe-trace','memex-test','llama-memex-test','llama-memex-fwd','memex-qerr')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function WaitQuiet { $q = 0; while ($q -lt 8) { if (Busy) { $q = 0 } else { $q++ }; Start-Sleep -Seconds 30 } }

# Three replicates, because four runs of an identical config measured CV 4.2% and a 9.9% range:
# a single run cannot tell a 5% win from nothing, and several past conclusions in this project
# were probably that mistake.
# The fork already prints exactly the diagnostic this study needs, at speculative.cpp:2675:
#
#   statistics <type>: #calls(b,g,a) = .., #gen drafts = .., #acc drafts = .., #gen tokens = N,
#                      #acc tokens = N, dur(b,g,a) = begin, draft, accept ms
#
# So the two competing explanations for "theory says +20%, measurement says +1%" are separable
# from one line: #acc/#gen tokens is the accepted fraction, and dur's middle term is the time
# spent inside the draft. Low acceptance and an expensive draft look identical in a tokens/sec
# number and completely different here. Parsing it is the whole point of this rewrite.
function Arm($label, [string[]]$extra) {
    if ((FreeGB) -lt 18) { Note ("{0,-40} OTKAZ: svobodno {1:N1} GB" -f $label, (FreeGB)); return }
    $vals = @(); $stat = ''
    for ($r = 1; $r -le 3; $r++) {
        $a = @('-m', $M, '-f','D:\MemeX\results\prompt_short.txt', '-n', '256', '-c', '2048', '-t', '8', '-ngl', '0',
               '-fa', 'off', '-rtr', '--seed', '1', '--no-display-prompt') + $extra
        # Every arm gets a hard timeout. The first version of this script called llama-cli
        # directly and one arm hung on its first draft configuration, taking thirteen hours of
        # machine time with it and producing not a single line of log. A run that hangs has to
        # cost one arm, not a night.
        $so = 'D:\MemeX\results\_spec_arm.out'
        $p = Start-Process -FilePath "$BIN\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden `
                 -RedirectStandardOutput $so -RedirectStandardError "$so.err" -PassThru
        if (-not $p.WaitForExit(420 * 1000)) {
            Stop-Process -Id $p.Id -Force -EA SilentlyContinue
            Note ("      povtor {0}: TAJM-AUT posle 7 minut" -f $r)
            Start-Sleep -Seconds 10
            continue
        }
        $out = @()
        if (Test-Path $so)        { $out += Get-Content $so -EA SilentlyContinue }
        if (Test-Path "$so.err")  { $out += Get-Content "$so.err" -EA SilentlyContinue }
        $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($h -and $h.Line -match '([\d.]+) tokens per second') { $vals += [double]$Matches[1] }
        if (-not $stat) {
            $s = $out | Select-String -Pattern 'statistics .*#acc tokens' | Select-Object -First 1
            if ($s) { $stat = $s.Line }
        }
        # A vocabulary mismatch makes the fork refuse speculation silently as far as tokens/sec
        # is concerned, so surface the warning rather than reporting a baseline as a result.
        $w = $out | Select-String -Pattern 'draft model .*(vocab|special tokens)' | Select-Object -First 1
        if ($w) { Note ("      VNIMANIE: " + $w.Line.Trim()) }
        Start-Sleep -Seconds 20
    }
    if ($vals.Count -eq 0) { Note ("{0,-40} ne zapustilos" -f $label); return }
    $mean = ($vals | Measure-Object -Average).Average
    $spread = 100.0 * (($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum) / $mean
    Note ("{0,-40} {1:N2} tok/s  (razbros {2:N1}%, {3})" -f $label, $mean, $spread,
          (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'))
    if ($stat) {
        $gen = if ($stat -match '#gen tokens = (\d+)') { [double]$Matches[1] } else { 0 }
        $acc = if ($stat -match '#acc tokens = (\d+)') { [double]$Matches[1] } else { 0 }
        $gd  = if ($stat -match '#gen drafts = (\d+)') { [double]$Matches[1] } else { 0 }
        if ($gen -gt 0) {
            $perRound = if ($gd -gt 0) { $acc / $gd } else { 0 }
            Note ("      prijomka {0:P1} ({1:N0} iz {2:N0}), prinjato za raund {3:N2}" -f `
                  ($acc / $gen), $acc, $gen, $perRound)
        }
        if ($stat -match 'dur\(b,g,a\) = ([\d.]+), ([\d.]+), ([\d.]+) ms') {
            $tb = [double]$Matches[1]; $tg = [double]$Matches[2]; $ta = [double]$Matches[3]
            $tot = $tb + $tg + $ta
            if ($tot -gt 0) {
                Note ("      vremja: nachalo {0:N0} ms, chernovik {1:N0} ms ({2:P0} ot spekuljacii), prijomka {3:N0} ms" -f `
                      $tb, $tg, ($tg / $tot), $ta)
            }
        }
    }
}

("`n`n######## speculation study " + (Get-Date)) | Add-Content $LOG
Say 'waiting for the machine'
WaitQuiet

# CORRECTION, measured before this script ran: making the draft cheaper is the wrong direction.
# On the Q6 base, no speculation gave 7.26 tok/s, the 379 MB Q4 draft gave 7.33, and the 297 MB
# IQ3 draft gave 5.69 - a 22% LOSS for a 22% byte saving. At depth 4 it fell to 4.90.
#
# The reason is acceptance, not bytes. Three-bit quantisation damaged the little model's
# predictions, its accepted fraction collapsed, and the target spent its reads verifying tokens
# it then threw away. A rejected draft token costs a full target verification and buys nothing.
#
# So the lever is the opposite of what this script was built around: raise acceptance, and only
# then worry about what the draft costs. The IQ2 draft is still built and measured, but now as a
# confirmation of the trend rather than a hope - if the trend holds it should be worse again,
# and a measurement that confirms a mechanism is worth its five minutes.
Say 'IQ2 draft: built to confirm the trend, not to win'
if (-not (Test-Path $DR2)) {
    & "$BIN\llama-quantize.exe" --allow-requantize --leave-output-tensor `
        --custom-q 'attn_.*=iq2_ks,ffn_.*=iq2_ks' $DR4 $DR2 iq2_ks 4 `
        *> 'D:\MemeX\results\quant_draft2.log'
}
foreach ($d in @(@('Q4', $DR4), @('IQ3', $DR3), @('IQ2', $DR2), @('1.7B Q4', $SMALL))) {
    if (Test-Path $d[1]) { Note ("{0,-10} {1,7:N0} MB" -f $d[0], ((Get-Item $d[1]).Length/1MB)) }
    else { Note ("{0,-10} net" -f $d[0]) }
}

Say 'baseline without speculation'
Arm 'bez spekuljacii' @()

# n_max sweeps the trade directly: more drafted tokens amortise the target's attention and head
# over more accepted tokens, but the expert union grows and the draft is read more often. There
# has to be an optimum and nobody has looked for it.
Say 'n_max sweep, per draft'
foreach ($d in @(@('Q4', $DR4), @('IQ3', $DR3), @('IQ2', $DR2), @('1.7B', $SMALL))) {
    if (-not (Test-Path $d[1])) { continue }
    foreach ($n in @(2, 3, 4, 6, 8)) {
        Arm ("chernovik {0}, n_max={1}" -f $d[0], $n) @('-md', $d[1], '--spec-type', "draft:n_max=$n")
    }
}

# The lever that actually matters, now that acceptance is known to dominate: stop drafting early
# when the draft is not confident. p_min makes the draft abandon a round rather than emit tokens
# the target will reject, which trades a shorter round for a higher accepted fraction - exactly
# the direction the measurements point in. Swept on the BEST draft, not the cheapest.
Say 'p_min: stop drafting when the draft is unsure'
$bestDraft = if (Test-Path $SMALL) { $SMALL } elseif (Test-Path $DR4) { $DR4 } else { $DR3 }
Note ("luchshij chernovik: " + (Split-Path $bestDraft -Leaf))
foreach ($pm in @('0.0', '0.3', '0.5', '0.7', '0.9')) {
    Arm ("p_min=$pm, n_max=4") @('-md', $bestDraft, '--spec-type', "draft:n_max=4,p_min=$pm")
}
foreach ($pm in @('0.5', '0.8')) {
    Arm ("p_min=$pm, n_max=8") @('-md', $bestDraft, '--spec-type', "draft:n_max=8,p_min=$pm")
}

# Two mechanisms that change the economics rather than the parameters. The draft's own KV can be
# quantised for free in quality terms: a draft token that is rejected costs nothing, and one that
# is accepted was verified by the target anyway, so the draft's cache precision cannot affect the
# output distribution at all - only the acceptance rate.
Say 'other levers on the same round'
if (Test-Path $bestDraft) {
    Arm 'luchshij chernovik, ctk q8_0'   @('-md', $bestDraft, '--spec-type', 'draft:n_max=4',
                                           '-ctkd', 'q8_0', '-fa', 'on')
    Arm 'luchshij chernovik, 2 niti'     @('-md', $bestDraft, '--spec-type', 'draft:n_max=4', '-td', '2')
    Arm 'luchshij chernovik, 8 nitej'    @('-md', $bestDraft, '--spec-type', 'draft:n_max=4', '-td', '8')
}

# Let the fork tune itself. It carries a feedback tuner (speculative.cpp:1630, accept_feedback)
# that adjusts the speculative parameters to maximise tokens per second from observed acceptance.
# A grid search by hand is a worse instrument than a controller that sees every round, so this
# arm is the honest comparison against my own sweep: if autotune beats the best hand-picked
# point, the sweep was wasted effort and that is worth knowing.
Say 'autotune against the best hand-picked point'
foreach ($d in @(@('0.6B Q4', $DR4), @('0.6B IQ3', $DR3))) {
    if (Test-Path $d[1]) {
        Arm ("avtotjun, chernovik " + $d[0]) @('-md', $d[1], '--spec-autotune')
    }
}

# The 1.7B and 4B drafts are deliberately NOT swept, and the reason is arithmetic rather than
# taste. A draft reads its own weights once per token it predicts, so at depth 4 the 1.7B Q4
# draft reads 4 x 1030 MB = 4.1 GB per round - more than the 30B target reads for the whole
# batch (about 2.8 GB). No acceptance rate can repay that. Measured once each to confirm the
# arithmetic rather than sweeping five depths on a foregone conclusion.
Say 'bigger drafts: one arm each, to confirm they cannot pay'
foreach ($d in @(@('1.7B Q4', $SMALL), @('4B Q4', 'D:\smartstock\models\qwen3-4b-q4_k_m.gguf'))) {
    if (Test-Path $d[1]) {
        Note ("{0}: {1:N0} MB, na glubine 3 eto {2:N1} GB za raund protiv ~2.8 GB u celi" -f `
              $d[0], ((Get-Item $d[1]).Length/1MB), (3 * (Get-Item $d[1]).Length/1GB))
        Arm ("chernovik " + $d[0] + ", n_max=3") @('-md', $d[1], '--spec-type', 'draft:n_max=3')
    }
}

Say 'done'

