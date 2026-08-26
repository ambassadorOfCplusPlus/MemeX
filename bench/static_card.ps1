# The static-weights-on-card plan, tested before any of it is written.
#
# The plan in ARCHITECTURE 8.41 says: put attention, the head, the router and the KV cache on the
# card, keep the experts on the CPU. That is a boundary the fork can already express with -ot, so
# the premise is measurable today rather than after the module exists:
#
#   -ngl 99 -ot "exps=CPU"   ->  every layer on the device, expert tensors overridden back to host
#
# What each arm is for:
#   A  the honest CPU baseline, repacked, as the thing to beat
#   B  the boundary with no repacking - experts lose the +34% repacking is worth
#   C  the boundary with repacking - the target configuration, if -rtr leaves device tensors alone
#   D/E  fused MoE off, because -no-fmoe was worth 5.4x the last time the card was involved
#   F  the same boundary at a filled 16k context, which is where the KV cache is supposed to pay
#
# The risk C is testing: -rtr repacks CPU-resident tensors into _R8 forms, and the Vulkan backend
# supports none of them. If -rtr respects the -ot placement it repacks only the experts, which is
# exactly the split we want. If it repacks everything, the device tensors become unusable and C
# fails loudly rather than silently - which is itself the answer to whether the repack flag needs
# to become a parameter.
#
# VRAM arithmetic: static is 801.8 MB; KV is 96 KB per occupied token, so 192 MB at 2k and 1536 MB
# at 16k. 802 + 1536 = 2338 MB against 3980 MB usable, so even arm F fits with room to spare.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$VK  = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
$LOG = 'D:\MemeX\results\static_card.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

function Arm($label, [string[]]$extra, $prompt, $ctx, $ngen, $limitSec) {
    if (-not (Test-Path $prompt)) { Note ("{0,-38} net promta" -f $label); return }
    $vals = @(); $err = ''
    for ($r = 1; $r -le 3; $r++) {
        # A separate output path per replicate. This was first written believing a shared file was
        # what killed replicates 2 and 3; it was not - the cause was the $P/$p collision noted
        # below, and spec_study.ps1 shares one file across three replicates quite happily. Kept
        # anyway because distinct files make a failed replicate diagnosable after the fact.
        $so = 'D:\MemeX\results\_sc' + "_$r.out"
        $a = @('-m', $M, '-f', $prompt, '-n', "$ngen", '-c', "$ctx", '-t', '8',
               '-fa', 'off', '--seed', '1', '--no-display-prompt') + $extra
        $p = Start-Process -FilePath "$VK\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden -PassThru `
                 -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        if (-not $p.WaitForExit($limitSec * 1000)) {
            Stop-Process -Id $p.Id -Force -EA SilentlyContinue; $err = 'tajm-aut'; continue
        }
        $out = @(); if (Test-Path $so) { $out += Get-Content $so }; if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
        $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
        if ($h -and $h.Line -match '([\d.]+) tokens per second') { $vals += [double]$Matches[1] }
        else {
            # A failure here is information, not noise: it says the boundary is not expressible.
            $bad = $out | Select-String -Pattern 'not supported|failed|error|abort|assert' | Select-Object -First 1
            if ($bad) { $err = $bad.Line.Trim() }
        }
        Start-Sleep -Seconds 15
    }
    if ($vals.Count -eq 0) { Note ("{0,-38} NE POSHLO: {1}" -f $label, $err); return }
    if ($vals.Count -lt 2) {
        Note ("{0,-38} {1,6:N2} tok/s  <<< tolko 1 povtor - ne rezultat" -f $label, $vals[0])
        return
    }
    $mean = ($vals | Measure-Object -Average).Average
    $spread = 100.0*(($vals|Measure-Object -Maximum).Maximum - ($vals|Measure-Object -Minimum).Minimum)/$mean
    $flag = if ($spread -gt 4.2) { '  <<< razbros vyshe shuma' } else { '' }
    Note ("{0,-38} {1,6:N2} tok/s (razbros {2:N1}%, {3}){4}" -f $label, $mean, $spread,
          (($vals | ForEach-Object { $_.ToString('N2') }) -join '/'), $flag)
}

("`n`n######## statika na karte " + (Get-Date)) | Add-Content $LOG
if (-not (Take-Machine -Who 'static_card' -TimeoutMin 600 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    $SHORT = 'D:\MemeX\results\prompt_short.txt'
    $LONG  = 'D:\MemeX\results\prompt_16000.txt'
    $EXPS  = 'exps=CPU'

    Say 'korotkij kontekst, -c 2048'
    Arm 'A. baza: vsjo na CPU, rtr'        @('-ngl','0','-rtr')                      $SHORT 2048 256 600
    Arm 'B. statika na karte, bez rtr'     @('-ngl','99','-ot',$EXPS)                $SHORT 2048 256 600
    Arm 'C. statika na karte + rtr'        @('-ngl','99','-ot',$EXPS,'-rtr')         $SHORT 2048 256 600
    Arm 'D. to zhe + no-fmoe'              @('-ngl','99','-ot',$EXPS,'-rtr','-no-fmoe') $SHORT 2048 256 600
    Arm 'E. bez rtr + no-fmoe'             @('-ngl','99','-ot',$EXPS,'-no-fmoe')     $SHORT 2048 256 600

    Say 'zapolnennyj kontekst 16k - radi etogo kesh i edet na kartu'
    Arm 'F. baza 16k: vsjo na CPU, rtr'    @('-ngl','0','-rtr')                      $LONG 16384 64 1800
    Arm 'G. 16k, statika i kesh na karte'  @('-ngl','99','-ot',$EXPS,'-rtr')         $LONG 16384 64 1800

    Say 'chto eto reshaet'
    Note 'esli C ili D vyshe A - granica verna i modul stoit pisat;'
    Note 'esli G/F bolshe chem C/A - kesh na karte i est glavnyj rychag, kak i schitalos.'
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
