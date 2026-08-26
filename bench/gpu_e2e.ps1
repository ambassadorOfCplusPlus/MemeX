# First end-to-end run of the concurrent CPU+GPU expert path on the real model.
#
# Everything below it is verified; this is the one step that never got a chance. The self-test
# proved the pieces in a real ggml graph without a model - 48/48 bit-exact CPU split, 384/384
# slots where the device half is exactly zero in what it does not own, 384/384 per-slot sums
# bit-identical, 576/576 VRAM slots byte-identical to their source tensors - but the 48-layer
# integration was never executed because the measurement queue held 15-22 GB for an entire
# session and free memory never sustained 20 GB.
#
# Two things about how this must be judged, both discovered the hard way:
#
# 1. Token agreement can no longer be the gate. Against a double-precision reference on identical
#    bytes, one mul_mat_id gives CPU 5.0e-2 versus Vulkan 9.4e-8 for IQ4_XS - the CPU kernels
#    quantise the activation vector to compute in integers, and carry a systematic scale bias of
#    0.9953. A whole layer is 1.11e-1 unsplit on the CPU against 5.87e-2 split with the device.
#    The device half is MORE accurate, so it will legitimately disagree with the CPU-only path.
#    Divergence here is not evidence of a bug.
# 2. The join blocks ggml's thread 0 while the others spin, so the CPU half should run with one
#    thread fewer than usual.
#
# Requires 20 GB free: mx10 is 15.37 GB and the resident set adds about 2.7 GB of VRAM staging
# plus the usual cache. Refusing is a result; thrashing produces a number that looks real.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$VK  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
$E   = "$VK\llama-memex-fwd.exe"
$LOG = 'D:\MemeX\results\gpu_e2e.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx10-xs.gguf'    # experts IQ4_XS - the only type Vulkan implements
$P   = 'D:\MemeX\results\prompt_short.txt'

function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }
function ModelBusy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix','llama-moe-trace',
                     'memex-test','llama-memex-test','llama-memex-fwd','memex-qerr','llama-memex-kv')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function SiblingBusy {
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.ProcessId -eq $PID) { continue }
        $c = $p.CommandLine
        if (-not $c) { continue }
        if ($c -notmatch '-File\s+\S*bench') { continue }
        # Orchestrators never load a model themselves; they only wait for the child they started.
        # Treating one as a competitor deadlocks the child against its own parent.
        if ($c -match 'resume_all\.ps1|master\.ps1|chain\.ps1|rerun_spec\.ps1') { continue }
        return $true
    }
    return $false
}

("`n`n######## gpu end-to-end " + (Get-Date)) | Add-Content $LOG

# A binary that cannot start looks exactly like a failed measurement. Both ggml.dll and
# vulkan-1.dll vanished from this output directory once already today.
if (-not (Test-Path $E)) { Note "net binarnika: $E"; exit 1 }
$null = & $E --version 2>&1
if ($LASTEXITCODE -eq -1073741515) {
    Note 'binarnik ne startuet (net dll) - peresobiraju v build-vk'
    & cmake --build 'D:\MemeX\src\ik_llama.cpp\build-vk' --target ggml llama llama-memex-fwd `
        --config Release -j 4 *> 'D:\MemeX\results\vk_repair.log'
    $null = & $E --version 2>&1
    if ($LASTEXITCODE -eq -1073741515) { Note 'ne pomoglo, vyhozhu'; exit 1 }
}
Note 'binarnik startuet'

# Ownership, not a resource test. This script previously waited on three conditions - no model,
# no sibling script, 20 GB free - and each failed in its own way: the sibling check deadlocked
# against this script's own parent orchestrator, and the eight-consecutive-quiet-readings rule
# never converged because Windows' reported free memory dithers. The lock replaces all of it, and
# it also waits out the scripts that do not take the lock (see Test-ForeignModel).
if (-not (Take-Machine -Who 'gpu_e2e' -TimeoutMin 600 -MinFreeGB 20)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {

function Run($label, [string[]]$extra, $limitSec) {
    $so = 'D:\MemeX\results\_e2e.out'
    $a = @('-m', $M, '-f', $P, '--gen', '8', '-t', '7') + $extra
    $p = Start-Process -FilePath $E -ArgumentList $a -WindowStyle Hidden -PassThru `
             -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    if (-not $p.WaitForExit($limitSec * 1000)) {
        Stop-Process -Id $p.Id -Force -EA SilentlyContinue
        Note ("{0}: TAJM-AUT posle {1} s" -f $label, $limitSec); return
    }
    Note ("{0}: kod {1}" -f $label, $p.ExitCode)
    $out = @()
    if (Test-Path $so)       { $out += Get-Content $so -EA SilentlyContinue }
    if (Test-Path "$so.err") { $out += Get-Content "$so.err" -EA SilentlyContinue }
    $out | Select-String -Pattern 'ток/с|скорость|попадан|резидент|слот|устройств|VRAM|байт|ошибк|расхожд|refus|отказ|assert|error|GGML' |
        Select-Object -Last 16 | ForEach-Object { Note ("    " + $_.Line.Trim()) }
    Start-Sleep -Seconds 20
}

# Order matters: prove it runs at all, then prove the halves agree, then let it stand alone.
Note '--- 1. bez karty, opornaja tochka'
Run 'CPU only' @('--no-ref') 900
Note '--- 2. s kartoj i sverkoj polovin (obe schitajutsja, sravnivajutsja)'
Run 'gpu-experts-check' @('--gpu-experts','--gpu-experts-check','--no-ref') 1200
Note '--- 3. s kartoj, rabochij rezhim'
Run 'gpu-experts' @('--gpu-experts','--no-ref') 900

} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
