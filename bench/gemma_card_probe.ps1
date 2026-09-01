# Gemma 4 on the card: the same probe list that comes out 0.0000% on the CPU path, run with
# --gpu-static-layers. The CPU arm is already byte-exact (results/gc9.txt, layers 0 and 1 all
# 0.0000%), so any non-zero probe here is the card and nothing else. The first non-zero name
# localises the fault; that is the whole purpose of the run.
#
# Two arms, one acquisition, one model load each. The CPU arm is re-run rather than trusted
# from yesterday's log because the binary was relinked at 14:07 today and a stale baseline is
# how a regression hides.
param(
    [int]$Threads    = 8,
    [int]$TimeoutMin = 120,
    [int]$StepMin    = 45
)

. C:/Users/User11/Desktop/MemeX/bench/lock.ps1

$exeVk  = 'D:/MemeX/src/ik_llama.cpp/build-vk/bin/Release/llama-memex-fwd.exe'
$exeCpu = 'D:/MemeX/src/ik_llama.cpp/build/bin/Release/llama-memex-fwd.exe'
$gemma  = 'D:/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'
$outdir = 'D:/MemeX/results/gemma_card'
$prompt = 'The capital of France is Paris. The capital of Japan is'

New-Item -ItemType Directory -Force -Path $outdir | Out-Null
foreach ($f in @($exeVk, $exeCpu, $gemma)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "NET FAJLA: $f"; exit 4 }
}

$script:child = $null

function Invoke-Step {
    param([string]$Name, [string]$Exe, [string[]]$StepArgs, [int]$LimitMin)
    $log = Join-Path $outdir "$Name.log"
    $err = "$log.err"
    Write-Host ""
    Write-Host "=== $Name -> $log ==="
    $t0 = Get-Date
    # Hand-quoting: -ArgumentList joins with spaces and quotes nothing, so a prompt with
    # spaces arrives as one word per space (arch_verify_run.ps1 carries the same note).
    $cmdline = ($StepArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { "$_" }
    }) -join ' '
    $proc = Start-Process -FilePath $Exe -ArgumentList $cmdline -NoNewWindow -PassThru `
                          -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $proc.Handle          # without this .ExitCode comes back EMPTY, not zero
    $script:child = $proc
    if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) {
        Write-Host "TAJM-AUT $LimitMin min: ubivaju"
        try { $proc.Kill($true) } catch { }
        try { $proc.WaitForExit(30000) | Out-Null } catch { }
        $script:child = $null
        return -1
    }
    $script:child = $null
    $code = $proc.ExitCode
    if ($null -eq $code) { $code = -2 }
    Write-Host ("    exit {0} za {1:N1} min" -f $code, ((Get-Date) - $t0).TotalMinutes)
    return $code
}

# Script-side verdict, not the engine's: read the probe table back and name the FIRST probe
# whose L2 is not zero. METHODS 68 - the script checks what the arm claims.
function Show-FirstBad {
    param([string]$Name)
    $log = Join-Path $outdir "$Name.log"
    if (-not (Test-Path -LiteralPath $log)) { Write-Host "  $Name : NET LOGA"; return }
    $rows = Select-String -LiteralPath $log -Pattern '^\s+(\S+)\s+\d+,\s+L2\s+([\d.,]+)%' -AllMatches
    if (-not $rows) { Write-Host "  $Name : ZONDOV NET V LOGE - probe ne otrabotal"; return }
    Write-Host ("  $Name : zondov {0}" -f $rows.Count)
    $bad = $null
    foreach ($r in $rows) {
        $l2 = [double](($r.Matches[0].Groups[2].Value) -replace ',', '.')
        if ($l2 -gt 0.0) { $bad = $r; break }
    }
    if ($null -eq $bad) {
        Write-Host "  $Name : VSE ZONDY 0.0000% - rashozhdenija v probah net"
    } else {
        Write-Host ("  $Name : PERVYJ NENULEVOJ -> " + $bad.Line.Trim())
        # Three lines of context on either side: the fault is between the last clean probe
        # and this one, and the name of the last clean one is half the answer.
        $i = [Array]::IndexOf($rows, $bad)
        for ($k = [Math]::Max(0, $i - 3); $k -le [Math]::Min($rows.Count - 1, $i + 3); $k++) {
            Write-Host ("      " + $rows[$k].Line.Trim())
        }
    }
}

# THE PASS CONDITION, and it is not the L2 value.
#
# The fault this run exists to re-check was a probe reading a buffer the allocator had reused:
# every one of the thirty layers reported the LAST layer's bytes. The L2 numbers that produced
# (369%, 4394%) looked like a computation fault and sent the project after a norm kernel.
#
# The tell was there the whole time: the same value on two different layers. A quantity that
# depends on its input MUST differ between layers. So the check is distinctness, per probe
# family, across layers - within one decode step. If a family collapses to one value, the probe
# is broken whatever its L2 says; if it is distinct, an L2 of 300% would be a real finding.
function Show-LayerSpread {
    param([string]$Name)
    $log = Join-Path $outdir "$Name.log"
    if (-not (Test-Path -LiteralPath $log)) { Write-Host "  $Name : NET LOGA"; return }
    foreach ($fam in @('attn_out', 'ffn_norm_1', 'ffn_norm_2', 'l_out')) {
        $rows = Select-String -LiteralPath $log -Pattern ("^\s+" + $fam + "-(\d+)\s.*rms ([\d.,]+) / ([\d.,]+)") -AllMatches
        if (-not $rows) { Write-Host ("  {0,-12} : v loge net" -f $fam); continue }
        $ours = @{}
        foreach ($r in $rows) {
            $v = ($r.Matches[0].Groups[2].Value) -replace ',', '.'
            if (-not $ours.ContainsKey($v)) { $ours[$v] = 0 }
            $ours[$v] += 1
        }
        $distinct = $ours.Keys.Count
        $total    = $rows.Count
        # One value per decode step, shared by every layer, is the signature. With six steps and
        # thirty layers a healthy family has far more distinct values than steps.
        $verdict = if ($distinct -le 8) { "PODOZRITELNO - zond mozhet chitat chuzhoj bufer" } else { "raznye po slojam - horosho" }
        Write-Host ("  {0,-12} : strok {1,4}, razlichnyh znachenij {2,4}  {3}" -f $fam, $total, $distinct, $verdict)
    }
}

Write-Host ("lock holder before: " + (Get-LockHolder))
Write-Host "zhdjom mashinu..."
if (-not (Take-Machine -Who 'gemma_card' -TimeoutMin $TimeoutMin)) {
    Write-Host "NE POLUCHIL MASHINU za $TimeoutMin min"; exit 3
}
Write-Host "vzjali mashinu"

try {
    $common = @('-m', $gemma, '-p', $prompt, '--tokens', '24', '-t', "$Threads",
                '--no-repack', '--ref-fa', '--probe', 'all', '--decode-check', '6')

    # CPU arm first: it is the control. If it is not clean, the card arm says nothing.
    $c = Invoke-Step -Name 'cpu' -Exe $exeCpu -StepArgs $common -LimitMin $StepMin
    Write-Host ""
    Write-Host "===== PROCESSORNOE PLECHO (kontrol) ====="
    Show-FirstBad -Name 'cpu'
    Show-LayerSpread -Name 'cpu'

    $v = Invoke-Step -Name 'card' -Exe $exeVk -StepArgs ($common + @('--gpu-static-layers')) -LimitMin $StepMin
    Write-Host ""
    Write-Host "===== PLECHO NA KARTE ====="
    Show-FirstBad -Name 'card'
    Show-LayerSpread -Name 'card'
    Write-Host ""
    Write-Host ("exit: cpu $c, karta $v   (2 = dvizhok sam soobshchil rashozhdenie)")
}
finally {
    if ($script:child) { try { $script:child.Kill($true) } catch { } }
    Free-Machine
    Write-Host "mashina osvobozhdena"
}
