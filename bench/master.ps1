# One queue, one process, phases strictly in order. Everything else is called from here.
#
# Written this way after the failure mode that cost a night: several scripts were queued
# separately, each waiting for "the machine to be quiet", and they all saw the same quiet gap
# and started together. Two 15 GB models in 32 GB meant almost every arm died on "unable to
# allocate backend buffer". Sequential phases inside a single process cannot do that.
#
# Order is the one asked for:
#   1. the 30B Qwen - all quality-free optimisations, plus the two untested middles (4-bit and
#      5-bit experts with the output head left alone)
#   2. link-time optimisation, the last unlit build switch
#   3. the engine's own five-level test harness, which has never run to completion
#   4. a single cheap probe of Coder-Next as soon as its download finishes - out of order on
#      purpose, and only one arm, because at 80B total with 3B active it is the likeliest thing
#      on this disk to clear 20 tok/s and five minutes now can redirect hours later
#   5. Gemma
#   6. the 35B Qwen, adaptively compressed
#   7. Coder-Next in full
#
# A download is running in parallel. That is deliberate: it uses network and disk, not the
# processor, and with repacking the model sits in private memory rather than the page cache, so
# it cannot evict what we are measuring.

$ErrorActionPreference = 'Continue'
$BENCH = 'C:\Users\User11\Desktop\MemeX\bench'
$BIN   = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG   = 'D:\MemeX\results\master.log'
$NEXT  = 'D:\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
$NEXT_FULL = 28489000000   # content-length from the repository, checked before starting

function Say($m) { ("`n[{0}] ######## {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

# Also waits out the subagents that may be compiling or running the test harness. curl is
# deliberately excluded: the download must not block the queue.
function Busy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'llama-moe-trace','memex-test','llama-memex-test','llama-memex-fwd',
                     'memex-qerr','llama-memex-kv','memex-kv')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    # Compilers are judged by CPU time, not by existence. MSBuild leaves idle node-reuse daemons
    # running after a build finishes, and listing it by name froze this queue for two and a half
    # hours on a completely free machine: a process that exists while burning nothing looked
    # exactly like work in progress. So only a compiler actually spending CPU counts as busy.
    foreach ($n in @('cl', 'link', 'MSBuild')) {
        foreach ($p in (Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try {
                $a = $p.TotalProcessorTime.TotalSeconds
                Start-Sleep -Milliseconds 700
                $p.Refresh()
                if (($p.TotalProcessorTime.TotalSeconds - $a) -gt 0.15) { return $true }
            } catch { continue }   # the process exited while we looked at it: not busy
        }
    }
    return $false
}
# Ten quiet minutes, not three: a subagent between two build steps goes quiet for a while, and
# starting a 15 GB measurement on top of it would spoil both.
function WaitQuiet($why) {
    Note ("zhdu tishiny: " + $why)
    $q = 0
    while ($q -lt 10) { if (Busy) { $q = 0 } else { $q++ }; Start-Sleep -Seconds 30 }
    Note ("svobodno, RAM {0:N1} GB" -f (FreeGB))
}

# Test-Path is not enough. A whole night was lost to ggml.dll vanishing from bin/Release: every
# binary was present, none could start, and each arm reported "did not run" with no reason -
# STATUS_DLL_NOT_FOUND is exit code -1073741515 and produces no message of its own. CMake made it
# worse by considering the target up to date, so a plain rebuild did nothing. So: before any
# phase, confirm the binaries actually start, and repair the libraries if they do not.
function Startable($exe) {
    if (-not (Test-Path $exe)) { return $false }
    $null = & $exe --version 2>&1
    return ($LASTEXITCODE -ne -1073741515)
}
function EnsureBinaries {
    $probe = "$BIN\llama-cli.exe"
    if (Startable $probe) { return $true }
    Note 'binarniki ne startujut (net dll) - vosstanavlivaju'
    # --clean-first because an ordinary rebuild is a no-op when CMake thinks the target is fresh.
    & cmake --build 'D:\MemeX\src\ik_llama.cpp\build' --target ggml --config Release --clean-first -j 4 `
        *> 'D:\MemeX\results\repair_ggml.log'
    & cmake --build 'D:\MemeX\src\ik_llama.cpp\build' --config Release -j 4 `
        *> 'D:\MemeX\results\repair_all.log'
    $ok = Startable $probe
    Note ("posle vosstanovlenija startuet: " + $ok)
    return $ok
}

function RunPhase($name, $script) {
    if (-not (Test-Path $script)) { Note ("net skripta: " + $script); return }
    Say $name
    WaitQuiet $name
    if (-not (EnsureBinaries)) { Note 'binarniki nerabotosposobny - faza propushchena'; return }
    & pwsh -NoProfile -NonInteractive -File $script 2>&1 | Out-Null
    Note ("faza zavershena: " + $name)
}

("`n`n@@@@@@@@ master start " + (Get-Date)) | Add-Content $LOG

# ------------------------------------------------------------------ 1. the 30B
# Phase 1 completed on the previous run and its numbers are recorded (mx9 at +3.25% and 9.47
# tok/s is the quality-band winner; mx1 stays the speed winner at +7.92%). Skipped rather than
# repeated: it costs three hours and would only confirm what is already written down.
Note 'faza 1 uzhe vypolnena ranee - propusk'

# ------------------------------------------------------------------ 1b. speculation
# Promoted to right after the 30B candidates because the roofline settled that generation is
# 100% memory-bound and the byte budget says no model on this disk can reach 20 tok/s on weight
# reduction alone. Speculation is the only lever that amortises a weight read across several
# tokens, and it is free in quality terms - rejection sampling preserves the target distribution.
RunPhase '1b. spekuljacija: eto teper kriticheskij put' "$BENCH\spec_study.ps1"
# ------------------------------------------------------------------ 1c. zoned KV, speed
# The byte saving is measured (1.69x at 2048 up to 1.86x at 16384, token agreement 16 of 16) but
# the speed never was. KV is only 10% of the budget at 2048 and 47% at 16384, so the prediction
# is +4% and +28% respectively - and the short arm is there precisely to show the technique does
# nothing where it is not supposed to.
# Measured and closed: zoning is x0.46 at 2048, x0.51 at 8192, x0.60 at 16384 - the byte saving
# is real but the added compute (Hadamard on the query, the compressed tail, four masked zones)
# costs more than it saves. Superseded by putting the cache in video memory, where reducing reads
# from system RAM stops being the point. Skipped rather than repeated.
Note 'faza 1c (zonnyj KV) izmerena i zakryta - propusk'

# ------------------------------------------------------------------ 2. link-time optimisation
# The only build switch still off. Expectation is low and stated as such: the hot kernels are
# hand-written intrinsics inside one translation unit, which is where LTO has least to give. It
# is measured rather than assumed because it is one rebuild and it is bit-exact.
Say '2. LTO build'
WaitQuiet 'LTO'
$LTODIR = 'D:\MemeX\src\ik_llama.cpp\build-lto'
if (-not (Test-Path "$LTODIR\CMakeCache.txt")) {
    & cmake -S 'D:\MemeX\src\ik_llama.cpp' -B $LTODIR -DCMAKE_BUILD_TYPE=Release `
        -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_NATIVE=ON `
        -DGGML_IQK_MUL_MAT=ON -DGGML_IQK_FLASH_ATTENTION=ON -DGGML_OPENMP=ON `
        -DGGML_LTO=ON -DGGML_VULKAN=OFF *> 'D:\MemeX\results\lto_cmake.log'
}
& cmake --build $LTODIR --target llama-cli --config Release -j 4 *> 'D:\MemeX\results\lto_build.log'
$ltoexe = "$LTODIR\bin\Release\llama-cli.exe"
if (Test-Path $ltoexe) {
    $M = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
    foreach ($arm in @(@('bez LTO', "$BIN\llama-cli.exe"), @('s LTO', $ltoexe))) {
        if ((FreeGB) -lt 18) { Note ("{0}: OTKAZ, svobodno {1:N1} GB" -f $arm[0], (FreeGB)); continue }
        $out = & $arm[1] -m $M -p 'Write a Python function that merges two sorted lists.' `
                  -n 256 -c 2048 -t 4 -ngl 0 -fa off -rtr --seed 1 --no-display-prompt 2>&1
        $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($h -and $h.Line -match '([\d.]+) tokens per second') { Note ("{0,-20} {1} tok/s" -f $arm[0], $Matches[1]) }
        else { Note ("{0,-20} ne zapustilos" -f $arm[0]) }
        Start-Sleep -Seconds 25
    }
} else {
    Note 'LTO-sborka ne poluchilas:'
    Get-Content 'D:\MemeX\results\lto_build.log' -Tail 5 -EA SilentlyContinue | ForEach-Object { Note ("    " + $_) }
}

# ------------------------------------------------------------------ 3. the engine test harness
# Five levels: per-layer tensor agreement, logits with an argmax-margin proof rather than a
# relative-L2 proxy, token agreement that tells a near-tie from a real error, cache behaviour
# past the first block, and determinism. Level 4 has passed; level 1's tolerance was just
# re-derived from measurement, so this is the first run that can be believed end to end.
Say '3. engine test harness, all five levels'
WaitQuiet 'test harness'
$TEST = if (Test-Path "$BIN\llama-memex-test.exe") { "$BIN\llama-memex-test.exe" } else { "$BIN\memex-test.exe" }
if (Test-Path $TEST) {
    foreach ($lv in @('5,2,3', '1,4')) {
        if ((FreeGB) -lt 17) { Note ("urovni {0}: OTKAZ, svobodno {1:N1} GB" -f $lv, (FreeGB)); continue }
        $so = "D:\MemeX\results\test_master_$($lv -replace ',','_').out"
        $p = Start-Process -FilePath $TEST -ArgumentList @('-m','D:\Qwen3-Coder-30B-A3B-mx1.gguf','--levels',$lv,'-t','4') `
                 -RedirectStandardOutput $so -RedirectStandardError "$so.err" -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit(2700 * 1000)) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue; Note ("urovni {0}: TAJM-AUT" -f $lv) }
        else { Note ("urovni {0}: kod {1}" -f $lv, $p.ExitCode) }
        Get-Content $so -Tail 12 -EA SilentlyContinue | ForEach-Object { Note ("    " + $_) }
    }
} else { Note 'net binarnika stenda' }

# ------------------------------------------------------------------ 4. Gemma
# Order set by the user: Gemma and the 35B come before Coder-Next. Both are measured with the
# fork first - our engine does not load either architecture yet - so what these phases produce is
# the baseline the card path will be judged against, not a finished result.
#
# Both turned out to suit this hardware better than the 30B does, for reasons that only show up
# once the KV cache is read per layer instead of per model: gemma4 puts a 1024 sliding window on 25
# of its 30 layers (their cache is 200 MB flat, it does not grow with context), and qwen35moe is a
# hybrid whose 30 SSM layers carry a fixed-size recurrent state and no KV cache at all. At 16k
# occupied that is 520 MB and 320 MB of cache against the 30B's 1536 MB.
RunPhase '4. Gemma 4 26B-A4B: baza i granica' "$BENCH\multimodel.ps1" 18

# ------------------------------------------------------------------ 5. the 35B, adaptive
RunPhase '5. Qwen3.6 35B: baza i granica' "$BENCH\adaptive35.ps1" 18

# ------------------------------------------------------------------ 6 and 7. Coder-Next
# 80B total with 3B active. The files are far too large to repack - 26.5 GB at three bits and
# 35.8 GB at four - but with mmap only the active experts are touched per token, and that shape
# is the likeliest thing on this disk to clear 20 tok/s where the 30B cannot: three bits over
# 3B active parameters is under a gigabyte per token.
#
# Measured with mmap only, deliberately. Repacking would need the whole file resident and cannot
# fit in 32 GB, so it is not attempted; a refusal printed is worth more than an hour of paging.
function CoderNext($label, $path, $expected) {
    Say $label
    $have = if (Test-Path $path) { (Get-Item $path).Length } else { 0 }
    if ($have -lt $expected) {
        Note ("nedokachan: {0:N2} iz {1:N2} GB - zhdu do 4 chasov" -f ($have/1GB), ($expected/1GB))
        $deadline = (Get-Date).AddHours(4)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 180
            if ((Test-Path $path) -and (Get-Item $path).Length -ge $expected) { break }
        }
        $have = if (Test-Path $path) { (Get-Item $path).Length } else { 0 }
    }
    if ($have -lt $expected) { Note ("tak i ne dokachalsja: {0:N2} GB" -f ($have/1GB)); return }
    WaitQuiet $label
    Note ("razmer: {0:N2} GB" -f ($have/1GB))
    foreach ($arm in @(@('mmap', @('-fa','off')),
                       @('mmap + muge', @('-fa','off','-muge')),
                       @('mmap, 8 nitej', @('-fa','off','-t','8')),
                       @('q8_0 KV', @('-fa','on','-ctk','q8_0','-ctv','q8_0')))) {
        $a = @('-m', $path, '-p', 'Write a Python function that merges two sorted lists and explain each step.',
               '-n', '128', '-c', '2048', '-t', '4', '-ngl', '0', '--seed', '1', '--no-display-prompt') + $arm[1]
        $out = & "$BIN\llama-cli.exe" @a 2>&1
        $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($h -and $h.Line -match '([\d.]+) tokens per second') {
            $v = [double]$Matches[1]
            Note ("{0,-22} {1} tok/s{2}" -f $arm[0], $Matches[1],
                  $(if ($v -ge 20) { '  <<< 20+' } elseif ($v -ge 15) { '  <<< 15+' } else { '' }))
        } else {
            Note ("{0,-22} ne zapustilos" -f $arm[0])
            $out | Select-String -Pattern 'error|unsupported|unknown|alloc' | Select-Object -Last 3 |
                ForEach-Object { Note ("      " + $_.Line.Trim()) }
        }
        Start-Sleep -Seconds 25
    }
}

Note 'faza 6 (Coder-Next 3 bita) otlozhena - snachala Gemma i 35B'
Note 'faza 7 (Coder-Next 4 bita) otlozhena - snachala Gemma i 35B'

Say 'master done'






