# Adaptive compression of Qwen3.6-35B-A3B, built from measurements rather than taste.
#
# Why adaptive and not just "four bits everywhere": we have the error ladder now, measured on
# layers whose source is nearly lossless (q8_0), with the pipeline pinned bit-exact by a
# q8_0 -> q8_0 round trip that returned exactly zero:
#
#   bits  type      real bpw   error    vs 4 bit
#   2     iq2_ks    2.195      34.62%   4.55x
#   3     iq3_ks    3.195      15.86%   2.09x
#   4     iq4_ks    4.266       7.60%   1.00
#   5     iq5_ks    5.266       3.73%   0.49x
#   6     q6_K      6.563       1.81%   0.24x
#
# Error halves per added bit. Three consequences drive the profiles below.
#
# 1. The output head stays at six bits. Every earlier candidate put it in four, and the
#    importance matrix has zero coverage for output.weight, so it was quantised blind. mx1 kept
#    the head at Q6 and scored +7.9%; the four candidates that cut it landed at +9.6 to +10.7%.
#    The head is 14% of the byte budget - a bad place to spend damage.
# 2. Attention goes to five bits, not four. Attention weights are 28% of the bytes; five bits
#    halves their error for 23% more attention bytes, about +6% overall.
# 3. Blocks 0 and 47 of the 30B source are stored q8_0 while 1-46 are q6_K - Unsloth protecting
#    the first and last layer. Every profile we wrote before flattened all 48 and threw that
#    away without noticing. Here they are protected explicitly, and the script first reports
#    what THIS file actually stores rather than assuming it matches.
#
# The size arithmetic that makes this worth doing at all: at four-bit experts the 27.3 GB file
# should land near 19.7 GB - which fits under repacking on a 32 GB machine, where 27.3 GB
# cannot. Repacking is bit-exact and worth +17% on the fork and +38% on our engine, so the
# compression buys a second, larger win beyond its own byte reduction. That is the real reason
# to do this.

$ErrorActionPreference = 'Continue'
$BIN  = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG  = 'D:\MemeX\results\adaptive35.log'
$SRC  = 'D:\Qwen3.6-35B-A3B-UD-Q6_K.gguf'
$IMAT = 'D:\MemeX\results\imatrix-35b.dat'
$TEXT = 'D:\MemeX\data\calibration.txt'
$A1   = 'D:\Qwen3.6-35B-a35-1.gguf'
$A2   = 'D:\Qwen3.6-35B-a35-2.gguf'
$DR3  = 'D:\qwen3-0.6b-iq3.gguf'
$PROMPT = 'Write a Python function that merges two sorted lists and explain each step.'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

# Serialise against the two runs already queued. Waiting on "no model process" alone is not
# enough: all three scripts would see the same quiet gap and start together, which is exactly
# how a previous night's measurements were destroyed.
function OthersRunning {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $PID) { continue }
        if ($p.CommandLine -and ($p.CommandLine -like '*quality_first.ps1*' -or
                                 $p.CommandLine -like '*multimodel.ps1*')) { return $true }
    }
    return $false
}
function Busy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'llama-moe-trace','memex-test','llama-memex-fwd','memex-qerr')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function WaitTurn {
    $q = 0
    while ($true) {
        if ((OthersRunning) -or (Busy)) { $q = 0 } else { $q++ }
        if ($q -ge 6) { break }
        Start-Sleep -Seconds 30
    }
}

function Ppl($label, $model, [string[]]$extra) {
    if (-not (Test-Path $model)) { Note ("{0,-34} net fajla" -f $label); return }
    $out = & "$BIN\llama-perplexity.exe" -m $model -f $TEXT -c 512 --chunks 16 -t 4 `
              -ngl 0 -fa off @extra 2>&1
    $hit = $out | Select-String -Pattern 'Final estimate' | Select-Object -First 1
    if ($hit) { Note ("{0,-34} {1}" -f $label, $hit.Line.Trim()) }
    else { Note ("{0,-34} ne poschitalos" -f $label) }
    Start-Sleep -Seconds 20
}

function Speed($label, $model, [string[]]$extra, $needGB) {
    if (-not (Test-Path $model)) { Note ("{0,-34} net fajla" -f $label); return }
    $free = FreeGB
    if ($free -lt $needGB) { Note ("{0,-34} OTKAZ: svobodno {1:N1} GB, nuzhno ~{2}" -f $label, $free, $needGB); return }
    $a = @('-m', $model, '-p', $PROMPT, '-n', '128', '-c', '2048', '-t', '4', '-ngl', '0',
           '-fa', 'off', '--seed', '1', '--no-display-prompt') + $extra
    $out = & "$BIN\llama-cli.exe" @a 2>&1
    $hit = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    if ($hit -and $hit.Line -match '([\d.]+) tokens per second') {
        $v = [double]$Matches[1]
        $mark = if ($v -ge 15) { '  <<< 15+' } else { '' }
        Note ("{0,-34} {1} tok/s{2}" -f $label, $Matches[1], $mark)
    } else {
        Note ("{0,-34} ne zapustilos" -f $label)
        $out | Select-String -Pattern 'error|alloc|failed' | Select-Object -Last 2 |
            ForEach-Object { Note ("      " + $_.Line.Trim()) }
    }
    [System.GC]::Collect(); Start-Sleep -Seconds 25
}

("`n`n######## adaptive 35B " + (Get-Date)) | Add-Content $LOG
Say 'waiting for my turn in the queue'
WaitTurn
Note ("free RAM {0:N1} GB, D: free {1:N1} GB" -f (FreeGB), ((Get-PSDrive D).Free/1GB))

if (-not (Test-Path $SRC)) { Note "net ishodnika $SRC"; exit 1 }
Note ("source: {0:N2} GB" -f ((Get-Item $SRC).Length/1GB))

# --------------------------------------------------------------- what does this file store?
# Assuming it matches the 30B's layout would be exactly the mistake made before. Ask the file.
Say 'stored types per layer, as reported by the quantiser dry run'
& "$BIN\llama-quantize.exe" --dry-run $SRC 'D:\MemeX\results\_dryrun35.gguf' q6_k 1 `
    *> 'D:\MemeX\results\dryrun35.log'
$types = Select-String -Path 'D:\MemeX\results\dryrun35.log' -Pattern 'blk\.(0|1|17|46|47)\.ffn_up_exps' -EA SilentlyContinue
if ($types) { $types | Select-Object -First 6 | ForEach-Object { Note ("  " + $_.Line.Trim()) } }
else { Note '  dry-run nichego ne dal - profili nizhe ne zavisjat ot etogo, no proverit stoit vruchnuju' }
$n_layer = (Select-String -Path 'D:\MemeX\results\dryrun35.log' -Pattern 'block_count' -EA SilentlyContinue |
            Select-Object -First 1)
if ($n_layer) { Note ("  " + $n_layer.Line.Trim()) }

# --------------------------------------------------------------- importance matrix for THIS model
# The 30B's matrix is useless here - different weights. Fusion off, because the fused up-gate op
# reports statistics under src[0]'s name only and ffn_gate_exps would collect nothing at all.
# 400 chunks because at 32 chunks save_imatrix dropped 44 of 48 layers: it discards any tensor
# where even one of the experts was never exercised.
Say 'importance matrix for the 35B'
if (-not (Test-Path $IMAT)) {
    & "$BIN\llama-imatrix.exe" -m $SRC -f $TEXT -o $IMAT --chunks 400 -c 512 `
        -t 4 -ngl 0 -fa off -no-fmoe -no-fug *> 'D:\MemeX\results\imatrix35.log'
}
if (Test-Path $IMAT) { Note ("matrica: {0:N0} KB" -f ((Get-Item $IMAT).Length/1KB)) }
else { Note 'matrica ne poluchilas - kvantuju bez nejo, i eto nado uchest pri chtenii chisel' }

# --------------------------------------------------------------- two candidates
# a35-1 leans on speed: four-bit experts, but head at six, attention at five, and the first and
#       last two layers' experts kept at six.
# a35-2 leans on quality: five-bit experts throughout, same protections.
$P1 = 'blk\.0\.ffn_.*_exps=q6_K,blk\.1\.ffn_.*_exps=q6_K,blk\.4[0-9]\.ffn_.*_exps=q6_K,' +
      'ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq4_ks,' +
      'attn_q.weight=iq5_ks,attn_output.weight=iq5_ks'
$P2 = 'ffn_up_exps=iq5_ks,ffn_gate_exps=iq5_ks,ffn_down_exps=iq5_ks,' +
      'attn_q.weight=iq5_ks,attn_output.weight=iq5_ks'

foreach ($c in @(@('a35-1 (4 bit experts, head 6, attn 5)', $A1, $P1),
                 @('a35-2 (5 bit experts, head 6, attn 5)', $A2, $P2))) {
    Say ('building ' + $c[0])
    $qlog = 'D:\MemeX\results\quant_' + (Split-Path $c[1] -Leaf) + '.log'
    if (-not (Test-Path $c[1])) {
        $im = if (Test-Path $IMAT) { @('--imatrix', $IMAT) } else { @() }
        & "$BIN\llama-quantize.exe" --allow-requantize @im --custom-q $c[2] $SRC $c[1] q6_k 4 *> $qlog
    }
    if (-not (Test-Path $c[1])) { Note 'ne skvantovalos'; Get-Content $qlog -Tail 4 -EA SilentlyContinue | ForEach-Object { Note ("    " + $_) }; continue }
    $gb = (Get-Item $c[1]).Length/1GB
    Note ("size: {0:N2} GB (bylo 27.30, ozhidalos ~19.7 dlja 4 bit)" -f $gb)
    # Verify the profile actually took effect instead of trusting the regex order.
    foreach ($probe in @('blk\.0\.ffn_up_exps', 'blk\.20\.ffn_up_exps', 'output\.weight', 'attn_q\.weight')) {
        $l = Select-String -Path $qlog -Pattern $probe -EA SilentlyContinue | Select-Object -First 1
        if ($l) { Note ("  " + $l.Line.Trim()) }
    }
    Ppl   $c[0] $c[1] @()
    # Repacking needs the whole file resident; the gate decides, and a refusal is a result.
    $need = [int]($gb + 3)
    Speed ($c[0] + ', mmap')       $c[1] @()        6
    Speed ($c[0] + ', rtr')        $c[1] @('-rtr') $need
    Speed ($c[0] + ', rtr + muge') $c[1] @('-rtr','-muge') $need
}

# The source, for the quality reference. Comparable because it is the same model.
Say 'source Q6_K for reference'
Ppl   'Q6_K source' $SRC @()
Speed 'Q6_K source, mmap' $SRC @() 6

Say 'done'
