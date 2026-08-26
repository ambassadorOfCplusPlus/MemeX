# Speed against occupied context - the measurement this project has never made.
#
# Every number here is a short-context number and nobody noticed. Generating 256 tokens from a
# short prompt fills about 300 cache slots regardless of what -c is set to, so -c 16384 measured a
# cache that was 2% full. The KV geometry says that hides the dominant cost: 96.0 KB of cache per
# occupied token across 48 layers, read in full on every generated token, is 7.6 ms at 2k occupied
# and 60.5 ms at 16k. The second number is larger than the entire token is today.
#
# This matters because the model is a coding model. The realistic use is a long file in context,
# which is exactly the regime never measured - and it decides what to optimise next: the expert
# split is worth about 6 tok/s, moving a filled 16k cache to the card is worth about 49 ms.
#
# The prompt is fed but not regenerated (-n 64 keeps generation short) so what is being timed is
# generation against a cache that is already full, not prefill.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\longctx.log'
$M   = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

("`n`n######## dlinnyj kontekst " + (Get-Date)) | Add-Content $LOG
if (-not (Take-Machine -Who 'longctx' -TimeoutMin 600 -MinFreeGB 18)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    Say 'skorost generacii protiv zanjatogo konteksta, mx1 + rtr'
    Note ('{0,-10} {1,-12} {2,-10} {3}' -f 'promt', 'tokenov', 'tok/s', 'kesh')
    foreach ($t in 2000, 4000, 8000, 16000) {
        $P = "D:\MemeX\results\prompt_$t.txt"
        if (-not (Test-Path $P)) { Note ("net {0}" -f $P); continue }
        $vals = @(); $ntok = 0
        for ($r = 1; $r -le 2; $r++) {
        # A separate output path per replicate. This was first written believing a shared file was
        # what killed replicates 2 and 3; it was not - the cause was the $P/$p collision noted
        # below, and spec_study.ps1 shares one file across three replicates quite happily. Kept
        # anyway because distinct files make a failed replicate diagnosable after the fact.
            $so = 'D:\MemeX\results\_lc' + "_$r.out"
            $c = [int][math]::Ceiling(($t + 512) / 1024.0) * 1024
            $a = @('-m', $M, '-f', $P, '-n', '64', '-c', "$c", '-t', '8', '-ngl', '0',
                   '-fa', 'off', '-rtr', '--seed', '1', '--no-display-prompt')
                # The process handle is NOT called $p here, and that is not a style choice. PowerShell
    # variable names are case-insensitive, the prompt path lives in $P, and `$p = Start-Process`
    # inside this function makes every later read of $P return a Process object. Replicate 1
    # succeeds, replicates 2 and 3 are handed a Process where a filename belongs and die before
    # they start - which is why every arm this evening reported one surviving run as a flawless
    # 0.0% spread. This exact collision has already cost this project one sweep once.
        $proc = Start-Process -FilePath "$BIN\llama-cli.exe" -ArgumentList $a -WindowStyle Hidden -PassThru `
                     -RedirectStandardOutput $so -RedirectStandardError "$so.err"
            if (-not $proc.WaitForExit(900 * 1000)) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; continue }
            $out = @(); if (Test-Path $so) { $out += Get-Content $so }; if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
            $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
            if ($h -and $h.Line -match '([\d.]+) tokens per second') { $vals += [double]$Matches[1] }
            # The real occupied count, not the 4-chars-per-token guess the prompt was built on.
            $pe = $out | Select-String -Pattern 'prompt eval time.*?/\s*(\d+) tokens' | Select-Object -First 1
            if ($pe -and $pe.Line -match '/\s*(\d+) tokens') { $ntok = [int]$Matches[1] }
            Start-Sleep -Seconds 15
        }
        if ($vals.Count -eq 0) { Note ("{0,-10} ne izmerilos" -f $t); continue }
        $mean = ($vals | Measure-Object -Average).Average
        $kv = $ntok * 96.0 / 1024.0
        Note ('{0,-10} {1,-12} {2,-10:N2} {3:N0} MB, chtenie {4:N1} ms/tok' -f `
              $t, $ntok, $mean, $kv, ($kv/1024.0/24.8*1000))
    }
    Say 'chto eto znachit'
    Note 'esli padenie sovpadaet s 96 KB na zanjatyj token - kesh i est glavnaja cena,'
    Note 'i togda perenos ego na kartu stoit bolshe, chem razdelenie ekspertov.'
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
