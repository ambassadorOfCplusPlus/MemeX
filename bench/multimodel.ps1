# The other models already on disk: can any of them reach 15-20 tok/s on this machine?
#
# Runs after everything else, one model at a time. Queued rather than run immediately because
# a 27 GB model on a 32 GB machine leaves no room for a second process, and this project has
# already lost a whole night's numbers to two runs overlapping.
#
# A note on what is comparable and what is not. Perplexity across DIFFERENT models is
# meaningless - different tokenisers, different vocabularies, different training. So quality
# here is judged by reading the generated text, and perplexity is reported only to compare
# quantisations OF THE SAME model. Anything else would be a number that looks rigorous and
# means nothing.
#
# Expected from the byte budget, written down before measuring so it can be wrong. Generation
# speed is bytes-read-per-token divided by 24.8 GB/s of RAM bandwidth:
#   Qwen3.6-35B-A3B at Q6, 27.3 GB file, ~3B active -> roughly 2.0 GB/token -> about 12 tok/s
#     ceiling, realistically 8-9. Reaching 15-20 would need four-bit experts.
#   Qwen3-Coder-Next at IQ3_XXS, 13.0 GB -> depends on how much of it is active per token;
#     if it is an A3B-shaped MoE this is the most promising candidate on the disk.
#   Gemma 4 E4B, 3.93 GB dense-ish -> a dense model reads its whole file per token, so 3.93 GB
#     would be about 6 tok/s. If it measures much faster, the model is doing something
#     selective per token and that is worth knowing.

$ErrorActionPreference = 'Continue'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\multimodel.log'
$DR3 = 'D:\qwen3-0.6b-iq3.gguf'
$PROMPT = 'Write a Python function that merges two sorted lists and explain each step.'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

function Busy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix',
                     'llama-moe-trace','memex-test','llama-memex-fwd','llama-memex-test','memex-qerr')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function WaitQuiet { $q = 0; while ($q -lt 6) { if (Busy) { $q = 0 } else { $q++ }; Start-Sleep -Seconds 30 } }

# needGB: expected resident footprint. Refusing is a result; a thrashed number is a lie that
# looks like a measurement.
function Run($label, $model, [string[]]$extra, $needGB, $showText) {
    if (-not (Test-Path $model)) { Note ("{0,-40} net fajla" -f $label); return }
    $free = FreeGB
    if ($free -lt $needGB) {
        Note ("{0,-40} OTKAZ: svobodno {1:N1} GB, nuzhno ~{2}" -f $label, $free, $needGB); return
    }
    $a = @('-m', $model, '-p', $PROMPT, '-n', '128', '-c', '2048', '-t', '4',
           '-ngl', '0', '--seed', '1', '--no-display-prompt') + $extra
    $out = & "$BIN\llama-cli.exe" @a 2>&1
    $tg = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
    $pp = $out | Select-String -Pattern '^(main|llama_print_timings): prompt eval time' | Select-Object -First 1
    $tgv = if ($tg -and $tg.Line -match '([\d.]+) tokens per second') { $Matches[1] } else { '?' }
    $ppv = if ($pp -and $pp.Line -match '([\d.]+) tokens per second') { $Matches[1] } else { '?' }
    if ($tgv -eq '?') {
        Note ("{0,-40} ne zapustilos" -f $label)
        $out | Select-String -Pattern 'error|failed|alloc|unsupported|unknown' | Select-Object -Last 3 |
            ForEach-Object { Note ("      " + $_.Line.Trim()) }
        return
    }
    $verdict = if ([double]$tgv -ge 15) { '  <<< 15+' } else { '' }
    Note ("{0,-40} gen {1} tok/s, prefill {2}{3}" -f $label, $tgv, $ppv, $verdict)
    # Print the text so quality can be judged by reading it - across different models there is
    # no comparable numeric quality measure.
    if ($showText) {
        $body = ($out | Where-Object { $_ -notmatch '^(main|llama_|ggml_|load_|llm_|print_info|init_)' } |
                 Select-Object -First 14) -join ' '
        Note ("    tekst: " + ($body -replace '\s+', ' ').Substring(0, [Math]::Min(400, $body.Length)))
    }
    [System.GC]::Collect(); Start-Sleep -Seconds 25
}

("`n`n######## multimodel " + (Get-Date)) | Add-Content $LOG
Say 'waiting for the machine to be free'
WaitQuiet
Note ("free RAM: {0:N1} GB" -f (FreeGB))

# ---------------------------------------------------------------- Qwen3-Coder-Next, 3 bit
# The most promising file on disk: 13 GB, so -rtr fits comfortably, unlike the 27 GB Qwen.
Say 'Qwen3-Coder-Next: nedokachan, propusk'
$NEXT = 'D:\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
Note 'fajl 13.010 GB ne rastjot i obrezan - iz testov iskljuchjon'

# ---------------------------------------------------------------- Qwen3.6-35B-A3B, Q6
# 27.3 GB. -rtr would need the whole file resident and cannot fit in 32 GB, so it is not even
# attempted - the gate will refuse it and say so, which is the honest outcome rather than an
# hour of paging. Quantised KV is tried instead, which needs flash attention for the V side.
Say 'Qwen3.6-35B-A3B, UD-Q6_K, 27.3 GB'
$Q35 = 'D:\Qwen3.6-35B-A3B-UD-Q6_K.gguf'
Run '35B Q6, mmap'                $Q35 @('-fa','off')                   5 $true
Run '35B Q6, mmap + muge'         $Q35 @('-fa','off','-muge')           5 $false
Run '35B Q6, q8_0 KV'             $Q35 @('-fa','on','-ctk','q8_0','-ctv','q8_0') 5 $false
Run '35B Q6, rtr (ozhidaetsja otkaz)' $Q35 @('-fa','off','-rtr')       29 $false

# ---------------------------------------------------------------- Gemma 4
# Three variants of the same model, so perplexity IS comparable between them - reported at the
# end for the two that differ only by quantisation.
Say 'Gemma 4'
$G4  = 'D:\smartstock\models\gemma-4-e4b-it-qat.gguf'
$G4Q = 'D:\smartstock\models\gemma-4-E4B-it-UD-Q2_K_XL.gguf'
$G2  = 'D:\smartstock\models\gemma-4-e2b-it-qat.gguf'
Run 'Gemma4 E4B QAT, rtr'         $G4  @('-fa','off','-rtr')            6 $true
Run 'Gemma4 E4B QAT, mmap'        $G4  @('-fa','off')                   5 $false
Run 'Gemma4 E4B Q2_K_XL, rtr'     $G4Q @('-fa','off','-rtr')            6 $true
Run 'Gemma4 E2B QAT, rtr'         $G2  @('-fa','off','-rtr')            5 $false

# Within one model family the number means something, so compare the two E4B quantisations.
Say 'Gemma 4 E4B: perplexity of the two quantisations (comparable, same model)'
foreach ($m in @(@('E4B QAT', $G4), @('E4B Q2_K_XL', $G4Q))) {
    if (-not (Test-Path $m[1])) { Note ("{0,-40} net fajla" -f $m[0]); continue }
    $out = & "$BIN\llama-perplexity.exe" -m $m[1] -f 'D:\MemeX\data\calibration.txt' `
             -c 512 --chunks 12 -t 4 -ngl 0 -fa off -rtr 2>&1
    $hit = $out | Select-String -Pattern 'Final estimate' | Select-Object -First 1
    if ($hit) { Note ("{0,-40} {1}" -f $m[0], $hit.Line.Trim()) }
    else { Note ("{0,-40} ne poschitalos" -f $m[0]) }
    Start-Sleep -Seconds 20
}

# ---------------------------------------------------------------- Gemma 4 26B-A4B (the big one)
# 26B total with 4B active: a mixture-of-experts, unlike the dense E2B/E4B variants. At 15.8 GB
# it fits under repacking with room to spare, which makes it the strongest 15-20 tok/s candidate
# on the disk now that Coder-Next turned out to be a partial download.
Say 'Gemma 4 26B-A4B, UD-Q4_K_XL, 15.8 GB'
$G26 = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'
Run 'Gemma4 26B-A4B, mmap'          $G26 @('-fa','off')                  6 $true
Run 'Gemma4 26B-A4B, rtr'           $G26 @('-fa','off','-rtr')          18 $false
Run 'Gemma4 26B-A4B, rtr + muge'    $G26 @('-fa','off','-rtr','-muge')  18 $false
Run 'Gemma4 26B-A4B, rtr, 8 nitej'  $G26 @('-fa','off','-rtr','-t','8') 18 $false

Say 'done'
