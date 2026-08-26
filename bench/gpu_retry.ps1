# Does the GPU work when the quantisation type is one the Vulkan backend actually implements?
#
# This exists because a direction was closed on a misdiagnosis. Whole-layer offload measured
# x0.15 and I attributed it to mul_mat_id being unavailable on this card. That was wrong twice
# over: mul_mat_id IS available for Q6_K and IQ4_XS (row_ids needs 16,388 B of shared memory
# against a 32,768 B device limit; only the large tile is disabled), and at one token it routes
# to mul_mat_vec_id_q_f16, which issues exactly one dispatch. The real cause is elsewhere:
#
#   IQ4_KS, IQ4_K and every _R4 type appear ZERO times in ggml-vulkan.cpp - not for any op.
#
# mx1's experts are IQ4_KS. So the card was not slow; it was falling back to the CPU and
# dragging weights across PCIe because it had never heard of the type. Two other numbers I had
# wrong and used to close the direction: VRAM bandwidth is 131 GB/s measured, not 37.1 - that is
# 5.3x the CPU's 24.8, not 1.5x - and a kernel launch costs 31 us, not 160-250.
#
# So: requantise the experts to IQ4_XS, which the backend does implement, is the same width
# (4.25 vs 4.27 bpw) and nearly the same error (7.91% vs 7.64%), and re-run the offload sweep.
# One requantisation and one sweep against weeks of custom Vulkan work.
#
# A hazard to respect while reading the numbers: any ggml Vulkan buffer <= 256 MiB lands in the
# 256 MiB BAR heap, and once that is committed the driver silently backs it with system memory -
# shader reads then run at 3.1 GB/s, a 40x penalty that heapUsage still reports as device-local.
# So a bad result here can mean "the type works but the buffer landed in BAR" rather than "the
# GPU is useless", and the arms below vary ngl precisely so that a monotonic curve can be told
# apart from a cliff.

$ErrorActionPreference = 'Continue'
$BIN  = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$VK   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
$LOG  = 'D:\MemeX\results\gpu_retry.log'
$Q6   = 'D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf'
$MX10 = 'D:\Qwen3-Coder-30B-A3B-mx10-xs.gguf'
$IMAT = 'D:\MemeX\results\imatrix2.dat'
$PROMPT = 'Write a Python function that merges two sorted lists and explain each step.'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

# A binary that cannot start looks exactly like a benchmark that measured nothing. This project
# just lost a night to a vanished ggml.dll: every arm reported "did not run" with no reason.
function Startable($exe) {
    if (-not (Test-Path $exe)) { return $false }
    $null = & $exe --version 2>&1
    return ($LASTEXITCODE -ne -1073741515)   # STATUS_DLL_NOT_FOUND
}

function Busy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'llama-moe-trace','memex-test','llama-memex-fwd','memex-qerr')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function WaitQuiet { $q = 0; while ($q -lt 6) { if (Busy) { $q = 0 } else { $q++ }; Start-Sleep -Seconds 30 } }

# Timeout per arm, because one hang cost thirteen hours here.
function Arm($label, $exe, [string[]]$a, $limitSec) {
    $so = 'D:\MemeX\results\_gpu_arm.out'
    $p = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru `
             -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    if (-not $p.WaitForExit($limitSec * 1000)) {
        Stop-Process -Id $p.Id -Force -EA SilentlyContinue
        Note ("{0,-30} TAJM-AUT" -f $label); return
    }
    $out = @()
    if (Test-Path $so)       { $out += Get-Content $so -EA SilentlyContinue }
    if (Test-Path "$so.err") { $out += Get-Content "$so.err" -EA SilentlyContinue }
    $tg = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    $pp = $out | Select-String -Pattern '^(main|llama_print_timings): prompt eval time' | Select-Object -First 1
    $t = if ($tg -and $tg.Line -match '([\d.]+) tokens per second') { $Matches[1] } else { '?' }
    $q = if ($pp -and $pp.Line -match '([\d.]+) tokens per second') { $Matches[1] } else { '?' }
    if ($t -eq '?') {
        Note ("{0,-30} ne zapustilos" -f $label)
        $out | Select-String -Pattern 'error|unsupported|not supported|alloc|fallback|CPU' |
            Select-Object -Last 4 | ForEach-Object { Note ("      " + $_.Line.Trim()) }
        return
    }
    Note ("{0,-30} gen {1} tok/s, prefill {2}" -f $label, $t, $q)
    # Which backend actually took the tensors is the whole question, so surface it.
    $out | Select-String -Pattern 'offloaded|buffer size|Vulkan|assigned' | Select-Object -First 3 |
        ForEach-Object { Note ("      " + $_.Line.Trim()) }
    Start-Sleep -Seconds 25
}

("`n`n######## gpu retry " + (Get-Date)) | Add-Content $LOG
Say 'proverka binarnikov pered zamerom'
Note ("build/llama-cli startuet:    " + (Startable "$BIN\llama-cli.exe"))
Note ("build-vk/llama-cli startuet: " + (Startable "$VK\llama-cli.exe"))
if (-not (Startable "$VK\llama-cli.exe")) {
    Note 'vulkan-sborka ne startuet - peresobiraju ggml v build-vk'
    & cmake --build 'D:\MemeX\src\ik_llama.cpp\build-vk' --target ggml llama llama-cli --config Release -j 4 `
        *> 'D:\MemeX\results\vk_rebuild.log'
    Note ("posle peresborki: " + (Startable "$VK\llama-cli.exe"))
}

Say 'stroju mx10: eksperty v IQ4_XS - tip, kotoryj Vulkan realizuet'
WaitQuiet
if (-not (Test-Path $MX10)) {
    # Experts and attention in IQ4_XS; the output head stays at six bits because a four-bit head
    # measured about +2% perplexity for 5% of the bytes. Everything here must be a type the
    # Vulkan backend knows, or the tensor silently returns to the CPU.
    & "$BIN\llama-quantize.exe" --allow-requantize --imatrix $IMAT `
        --custom-q 'ffn_up_exps=iq4_xs,ffn_gate_exps=iq4_xs,ffn_down_exps=iq4_xs,attn_q.weight=iq4_xs,attn_output.weight=iq4_xs' `
        $Q6 $MX10 q6_k 4 *> 'D:\MemeX\results\quant_mx10.log'
}
if (Test-Path $MX10) { Note ("razmer: {0:N2} GB" -f ((Get-Item $MX10).Length/1GB)) }
else { Note 'ne skvantovalos'; Get-Content 'D:\MemeX\results\quant_mx10.log' -Tail 4 -EA SilentlyContinue | ForEach-Object { Note ("    " + $_) }; exit 1 }

Say 'kachestvo mx10 protiv mx1 - IQ4_XS proigryvaet IQ4_KS 7.91% na 7.64%, poetom proverjaem'
$out = & "$BIN\llama-perplexity.exe" -m $MX10 -f 'D:\MemeX\data\calibration.txt' -c 512 --chunks 16 `
          -t 8 -ngl 0 -fa off -rtr 2>&1
$h = $out | Select-String -Pattern 'Final estimate' | Select-Object -First 1
if ($h) { Note ("mx10: " + $h.Line.Trim() + "   (Q6 baza 2.1121, mx1 2.2918)") } else { Note 'ppl ne poschitalas' }

Say 'CPU baza dlja sravnenija'
Arm 'CPU, ngl=0' "$BIN\llama-cli.exe" @('-m',$MX10,'-f','D:\MemeX\results\prompt_short.txt','-n','128','-c','2048','-t','8',
    '-ngl','0','-fa','off','-rtr','--seed','1','--no-display-prompt') 420

Say 'vygruzka slojov na kartu - to, chto ranshe davalo x0.15'
# ngl varied finely: a monotonic decline means the card is genuinely slower, a cliff between two
# adjacent values means a buffer crossed into BAR memory and is being read over PCIe at 3.1 GB/s.
# No -rtr here: repacked _R4 types do not exist in the Vulkan backend either, so repacking would
# push every tensor straight back to the CPU and measure nothing.
foreach ($n in @(2, 4, 8, 12, 16, 24, 48)) {
    Arm ("Vulkan, ngl=$n") "$VK\llama-cli.exe" @('-m',$MX10,'-f','D:\MemeX\results\prompt_short.txt','-n','128','-c','2048',
        '-t','8','-ngl',"$n",'-fa','off','--seed','1','--no-display-prompt') 420
}

Say 'tolko eksperty na kartu, vnimanie na CPU'
# -ncmoe keeps N layers' experts on the CPU and the rest on the card; the mirror of the above.
foreach ($n in @(0, 24, 40)) {
    Arm ("ncmoe=$n, ngl=48") "$VK\llama-cli.exe" @('-m',$MX10,'-f','D:\MemeX\results\prompt_short.txt','-n','128','-c','2048',
        '-t','8','-ngl','48','-ncmoe',"$n",'-fa','off','--seed','1','--no-display-prompt') 420
}

Say 'done'

