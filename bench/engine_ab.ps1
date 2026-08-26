# Our engine against the fork, one arm at a time, nothing else on the machine.
#
# This is the measurement the night was supposed to produce and did not: two pipelines ran
# concurrently (an sh script that was believed dead - MSYS prints "fork: retry" and retries),
# two 15 GB models did not fit in 32 GB, and almost every arm died on "unable to allocate
# backend buffer". Quality numbers survived that, because perplexity is deterministic
# arithmetic; every speed number from the night is worthless.
#
# Five arms, and the middle two are the honest pair: our engine does not repack weights by
# default, so comparing it against the fork WITH -rtr would repeat the exact mistake that once
# produced a bogus "cost of four bits" - a baseline prepared better than the candidate.

$ErrorActionPreference = 'Continue'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\engine_ab.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'   # the best-quality candidate we have (+7.9%)
$P   = 'Write a Python function that merges two sorted lists.'

function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

("`n######## engine A/B " + (Get-Date -Format 'HH:mm')) | Add-Content $LOG
Note ("model: " + (Split-Path $M -Leaf))
Note ("free RAM before start: {0:N1} GB" -f ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB))

function Arm($label, $exe, [string[]]$extra) {
    $path = Join-Path $BIN $exe
    if (-not (Test-Path $path)) { Note ("{0,-30} net binarnika" -f $label); return }
    # Refuse to measure under contention rather than recording a number that looks real.
    $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    if ($free -lt 14) {
        Note ("{0,-30} PROPUSK: svobodno {1:N1} GB, malo" -f $label, $free); return
    }
    $out = & $path @extra 2>&1
    $hit = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    if ($hit -and $hit.Line -match '([\d.]+) tokens per second') {
        Note ("{0,-30} {1} tok/s" -f $label, $Matches[1])
    } else {
        # Our engine prints its own timing format; look for anything token-rate shaped.
        $any = $out | Select-String -Pattern 'tok/s|tokens per second|мс/ток|ms per tok' | Select-Object -Last 3
        if ($any) { Note ("{0}:" -f $label); $any | ForEach-Object { Note ("    " + $_.Line.Trim()) } }
        else { Note ("{0,-30} ne izvlekli" -f $label); $out | Select-Object -Last 5 | ForEach-Object { Note ("    " + $_) } }
    }
    [System.GC]::Collect()
    Start-Sleep -Seconds 20   # let the page cache settle before the next arm
}

$forkArgs = @('-m', $M, '-p', $P, '-n', '64', '-c', '2048', '-t', '4', '-ngl', '0',
              '-fa', 'off', '--seed', '1', '--no-display-prompt')
Arm 'fork, with -rtr'    'llama-cli.exe' ($forkArgs + @('-rtr'))
Arm 'fork, without -rtr' 'llama-cli.exe' $forkArgs

$ourArgs = @('-m', $M, '-p', $P, '--gen', '64', '-t', '4')
Arm 'ours, before fixes' 'llama-memex-fwd-BEFORE.exe' $ourArgs
Arm 'ours, after fixes'  'llama-memex-fwd.exe'        $ourArgs
Arm 'ours, with repack'  'llama-memex-fwd.exe'        ($ourArgs + @('-rtr'))

Note 'gotovo'
