# bw_fit.ps1 -- Part 2/3: measure ms per generated token cleanly, for the
# bandwidth-vs-overhead fit. Appends one CSV row per run.
#
# Refuses to measure under contention: a contended number looks real and is not.

$ErrorActionPreference = 'Continue'

$CLI    = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release\llama-cli.exe'
$OUTCSV = 'C:\Users\User11\Desktop\MemeX\bench\bw_fit.csv'
$LOGDIR = 'C:\Users\User11\Desktop\MemeX\bench\bw_fit_logs'
$PROMPT = 'Write a Python function that merges two sorted lists and explain each step.'

New-Item -ItemType Directory -Force -Path $LOGDIR | Out-Null
if (-not (Test-Path $OUTCSV)) {
    'tag,model,threads,rep,extra,file_gb,free_gb_before,eval_ms,eval_tokens,ms_per_tok,tok_per_s,status' |
        Out-File -FilePath $OUTCSV -Encoding utf8
}

function Get-FreeGB {
    # Win32_OperatingSystem.FreePhysicalMemory excludes the standby (file cache)
    # list, so it badly understates what a fresh allocation can claim. Use the
    # Memory\Available MBytes counter = free + standby + zero, which is the real
    # headroom, and fall back to the CIM value if the counter is unavailable.
    # (Verified on this box: Win32_OperatingSystem.FreePhysicalMemory tracks
    #  AvailableMBytes to within 0.15 GB, i.e. it does include the standby list.)
    $m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue
    if ($m) { return [math]::Round($m.AvailableMBytes / 1024, 2) }
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1MB, 2)
}

function Test-MachineIdle {
    $busy = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -like 'llama-*' -or $_.ProcessName -like 'memex-*' }
    if ($busy) {
        return @{ idle = $false; why = ('busy: ' + (($busy | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ' ')) }
    }
    return @{ idle = $true; why = 'idle' }
}

function Wait-ForIdle {
    param([int]$MaxMinutes = 240)
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    while ((Get-Date) -lt $deadline) {
        $s = Test-MachineIdle
        if ($s.idle) { return $true }
        Write-Host ("[{0}] waiting -- {1}" -f (Get-Date -Format 'HH:mm:ss'), $s.why)
        Start-Sleep -Seconds 60
    }
    return $false
}

function Invoke-Run {
    param(
        [string]$Tag,
        [string]$ModelPath,
        [int]$Threads = 4,
        [int]$Rep = 1,
        [string[]]$Extra = @(),
        [string]$ExtraLabel = ''
    )

    $name = Split-Path $ModelPath -Leaf

    # resume: never redo a run that already produced a good number
    $done = Import-Csv $OUTCSV | Where-Object {
        $_.tag -eq $Tag -and $_.model -eq $name -and $_.threads -eq "$Threads" -and
        $_.rep -eq "$Rep" -and $_.extra -eq $ExtraLabel -and $_.status -eq 'OK'
    }
    if ($done) {
        Write-Host "SKIP $name t=$Threads rep=$Rep $ExtraLabel -- already measured ($($done[0].ms_per_tok) ms/tok)"
        return
    }

    if (-not (Test-Path $ModelPath)) {
        Write-Host "SKIP $name -- file missing"
        "$Tag,$name,$Threads,$Rep,$ExtraLabel,,,,,,,MISSING_FILE" | Add-Content $OUTCSV
        return
    }

    $fileGB = [math]::Round((Get-Item $ModelPath).Length / 1GB, 2)

    if (-not (Wait-ForIdle)) {
        Write-Host "SKIP $name -- machine never went idle"
        "$Tag,$name,$Threads,$Rep,$ExtraLabel,$fileGB,,,,,,NOT_IDLE" | Add-Content $OUTCSV
        return
    }

    # -rtr turns mmap off: the whole file must fit in RAM plus repack + KV + OS.
    $freeGB = Get-FreeGB
    $needGB = [math]::Round($fileGB * 1.02 + 1.5, 2)
    if ($freeGB -lt $needGB) {
        Write-Host "REFUSE $name t=$Threads -- need ${needGB}GB free for -rtr, have ${freeGB}GB (would thrash)"
        "$Tag,$name,$Threads,$Rep,$ExtraLabel,$fileGB,$freeGB,,,,,REFUSED_INSUFFICIENT_RAM_need_${needGB}GB" | Add-Content $OUTCSV
        return
    }

    $stamp = "{0}_{1}_t{2}_r{3}{4}" -f $Tag, ($name -replace '\.gguf$',''), $Threads, $Rep, $ExtraLabel
    $log = Join-Path $LOGDIR "$stamp.log"

    $argv = @(
        '-m', $ModelPath,
        '-p', $PROMPT,
        '-n', '256',
        '-c', '2048',
        '-t', "$Threads",
        '-ngl', '0',
        '-fa', 'off',
        '-rtr',
        '--seed', '1',
        '--no-display-prompt'
    ) + $Extra

    Write-Host ("[{0}] RUN {1} t={2} rep={3} {4} (free {5}GB)" -f `
        (Get-Date -Format 'HH:mm:ss'), $name, $Threads, $Rep, $ExtraLabel, $freeGB)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $CLI @argv *>&1 | Out-File -FilePath $log -Encoding utf8
    $ec = $LASTEXITCODE
    $sw.Stop()

    $line = Select-String -Path $log -Pattern '^(main|llama_print_timings):\s+eval time' |
            Select-Object -Last 1 -ExpandProperty Line

    if (-not $line) {
        Write-Host "  FAIL -- no eval time line (exit $ec). see $log"
        "$Tag,$name,$Threads,$Rep,$ExtraLabel,$fileGB,$freeGB,,,,,NO_TIMINGS_exit$ec" | Add-Content $OUTCSV
        return
    }

    # main:        eval time =    5486.55 ms /    64 tokens (   85.73 ms per token,    11.66 tokens per second)
    $rx = 'eval time\s+=\s+([0-9.]+)\s+ms\s+/\s+(\d+)\s+\w+\s+\(\s*([0-9.]+)\s+ms per token,\s+([0-9.]+)\s+tokens per second'
    $m = [regex]::Match($line, $rx)
    if (-not $m.Success) {
        Write-Host "  FAIL -- could not parse: $line"
        "$Tag,$name,$Threads,$Rep,$ExtraLabel,$fileGB,$freeGB,,,,,UNPARSED" | Add-Content $OUTCSV
        return
    }

    $evalMs = [double]$m.Groups[1].Value
    $ntok   = [int]$m.Groups[2].Value
    $mspt   = [double]$m.Groups[3].Value
    $tps    = [double]$m.Groups[4].Value

    Write-Host ("  -> {0:N2} ms/tok  {1:N2} tok/s  ({2} tokens, wall {3:N0}s)" -f $mspt, $tps, $ntok, $sw.Elapsed.TotalSeconds)
    "$Tag,$name,$Threads,$Rep,$ExtraLabel,$fileGB,$freeGB,$evalMs,$ntok,$mspt,$tps,OK" | Add-Content $OUTCSV
}

# --------------------------------------------------------------------- plan

$MODELS = @(
    'D:\Qwen3-Coder-30B-A3B-mx1.gguf',
    'D:\Qwen3-Coder-30B-A3B-mx2.gguf',
    'D:\Qwen3-Coder-30B-A3B-mx3.gguf',
    'D:\Qwen3-Coder-30B-A3B-mx4.gguf',
    'D:\Qwen3-Coder-30B-A3B-mx5.gguf',
    'D:\Qwen3-Coder-30B-A3B-mx6.gguf',
    'D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf'
)

$mode = if ($args.Count -gt 0) { $args[0] } else { 'all' }

if ($mode -eq 'all' -or $mode -eq 'sweep') {
    Write-Host '=== ARM A: bytes/token sweep, 2 repeats each, t=4 ==='
    foreach ($rep in 1, 2) {
        foreach ($m in $MODELS) { Invoke-Run -Tag 'sweep' -ModelPath $m -Threads 4 -Rep $rep }
    }
}

if ($mode -eq 'all' -or $mode -eq 'threads') {
    Write-Host '=== ARM B: thread scaling on mx1 ==='
    foreach ($t in 1, 2, 3, 4, 8) {
        Invoke-Run -Tag 'threads' -ModelPath 'D:\Qwen3-Coder-30B-A3B-mx1.gguf' -Threads $t -Rep 1
    }
}

if ($mode -eq 'all' -or $mode -eq 'experts') {
    # Orthogonal lever: same file, same attention/head bytes, fewer expert bytes.
    # Isolates the expert-read term without changing anything else.
    Write-Host '=== ARM C: active-expert override on mx1 (same file, different bytes/token) ==='
    foreach ($k in 2, 4, 8, 16) {
        Invoke-Run -Tag 'experts' -ModelPath 'D:\Qwen3-Coder-30B-A3B-mx1.gguf' -Threads 4 -Rep 1 `
            -Extra @('-okv', "qwen3moe.expert_used_count=int:$k") -ExtraLabel "_e$k"
    }
}

Write-Host ''
Write-Host "=== done. results in $OUTCSV ==="
Get-Content $OUTCSV
