# Restores everything after the power cut, strictly one thing at a time.
#
# Sequential on purpose. Today's collision was mine: the speculation study had just acquired the
# machine when a second measurement was launched outside the queue, and every one of its arms was
# refused for memory. So this owns the whole machine and hands it over in order, and nothing else
# should be started while it runs.
#
# Order is by what is unknown and cheap to learn, not by what is interesting:
#   1. the end-to-end GPU expert path - never once executed on the real model, and every piece
#      below it is verified, so this is the single largest open unknown
#   2. speculation - the previous attempt measured literally nothing
#   3. the router in f16 - the file was reported at 12.97 GB and turned out to have no GGUF magic
#      at all, so that experiment never happened either
#   4. the rest of the queue: LTO, the test harness, Gemma, the 35B, Coder-Next
#
# What the power cut destroyed, for the record: build-vk had no binaries at all, and two
# quantisation outputs were left without GGUF magic - the IQ2 draft and mx1r. mx1r had been
# logged as "size: 12.97 GB" and looked finished. Size is not integrity.

$ErrorActionPreference = 'Continue'
$BENCH = 'C:\Users\User11\Desktop\MemeX\bench'
$BIN   = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG   = 'D:\MemeX\results\resume.log'

function Say($m) { ("`n[{0}] ######## {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }
function FreeGB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

function ModelBusy {
    foreach ($n in @('llama-quantize','llama-cli','llama-perplexity','llama-imatrix','llama-moe-trace',
                     'memex-test','llama-memex-test','llama-memex-fwd','memex-qerr','llama-memex-kv')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function Quiet($minFreeGB) {
    $q = 0
    while ($q -lt 2) {
        if ((ModelBusy) -or ((FreeGB) -lt $minFreeGB)) { $q = 0 } else { $q++ }
        Start-Sleep -Seconds 60
    }
}

# A file with the right size and no GGUF magic is what the power cut left behind, so integrity is
# checked by the magic and never by the size.
function GoodGguf($p) {
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    try {
        $b = [byte[]]::new(4)
        $s = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
        $n = $s.Read($b, 0, 4); $s.Close()
        return ($n -eq 4 -and [System.Text.Encoding]::ASCII.GetString($b) -eq 'GGUF')
    } catch { return $false }
}

function Phase($name, $script, $minFreeGB) {
    if (-not (Test-Path $script)) { Note ("net skripta: " + $script); return }
    Say $name
    Note ("zhdu tishiny i {0} GB" -f $minFreeGB)
    Quiet $minFreeGB
    Note ("start, svobodno {0:N1} GB" -f (FreeGB))
    & pwsh -NoProfile -NonInteractive -File $script 2>&1 | Out-Null
    Note ('zavershena: ' + $name)
}

("`n`n@@@@@@@@ resume after power cut " + (Get-Date)) | Add-Content $LOG
Note ("D: {0:N1} GB, RAM {1:N1} GB" -f ((Get-PSDrive D).Free/1GB), (FreeGB))

# Ran manually and produced its numbers: the mechanism is correct (3072 slots, 0 discrepancies)
# but the card path is 3.89 tok/s against 9.98 without it, because repacked weights are not
# supported on Vulkan so --no-repack is forced, costing the +34% repacking is worth. Repeating it
# would tell us nothing new; the fix is in the code, not in another measurement.
Note 'faza 1 vypolnena vruchnuju - propusk'
Phase '2. spekuljacija'                      "$BENCH\spec_study.ps1" 18

# --------------------------------------------------------------- 3. the router in f16, redone
# ffn_gate_inp is stored f32 and costs 48 MiB per token - 2.8% of the budget, more than attn_k
# and attn_v together. Halving it is 1.4% for a decision that only ranks 128 experts, where f16
# has far more precision than the ranking needs. The first attempt produced a file with no GGUF
# magic, so this is the first real measurement of it.
Say '3. router f32 -> f16, zanovo'
Note 'zhdu tishiny'
Quiet 18
$MXR = 'D:\Qwen3-Coder-30B-A3B-mx1r.gguf'
if (-not (GoodGguf $MXR)) {
    if (Test-Path -LiteralPath $MXR) { Remove-Item -LiteralPath $MXR -Force -EA SilentlyContinue }
    & "$BIN\llama-quantize.exe" --allow-requantize --imatrix 'D:\MemeX\results\imatrix2.dat' `
        --custom-q 'ffn_gate_inp.weight=f16,ffn_up_exps=iq4_ks,ffn_gate_exps=iq4_ks,ffn_down_exps=iq4_ks,attn_q.weight=iq4_ks,attn_output.weight=iq4_ks' `
        'D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf' $MXR q6_k 4 *> 'D:\MemeX\results\quant_mx1r.log'
}
if (GoodGguf $MXR) {
    Note ("razmer: {0:N2} GB, magija na meste" -f ((Get-Item -LiteralPath $MXR).Length/1GB))
    $l = Select-String -Path 'D:\MemeX\results\quant_mx1r.log' -Pattern 'ffn_gate_inp' -EA SilentlyContinue | Select-Object -First 1
    if ($l) { Note ('  ' + $l.Line.Trim()) } else { Note '  ffn_gate_inp net v loge - tip mog byt otvergnut' }
    foreach ($m in @(@('mx1r (router f16)', $MXR), @('mx1 (dlja sverki)', 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'))) {
        for ($r = 1; $r -le 3; $r++) {
            if ((FreeGB) -lt 18) { Note ("{0} povtor {1}: OTKAZ po pamjati" -f $m[0], $r); continue }
            $so = 'D:\MemeX\results\_mxr.out'
            $p = Start-Process -FilePath "$BIN\llama-cli.exe" -WindowStyle Hidden -PassThru `
                     -RedirectStandardOutput $so -RedirectStandardError "$so.err" `
                     -ArgumentList @('-m',$m[1],'-f','D:\MemeX\results\prompt_short.txt','-n','256',
                                     '-c','2048','-t','8','-ngl','0','-fa','off','-rtr',
                                     '--seed','1','--no-display-prompt')
            if (-not $p.WaitForExit(420*1000)) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue; Note ("{0} povtor {1}: TAJM-AUT" -f $m[0], $r); continue }
            $out = @(); if (Test-Path $so) { $out += Get-Content $so }; if (Test-Path "$so.err") { $out += Get-Content "$so.err" }
            $h = $out | Select-String -Pattern '^(main|llama_print_timings):\s+eval time' | Select-Object -First 1
            if ($h -and $h.Line -match '([\d.]+) tokens per second') { Note ("{0,-22} povtor {1}: {2} tok/s" -f $m[0], $r, $Matches[1]) }
            else { Note ("{0,-22} povtor {1}: ne izmerilos" -f $m[0], $r) }
            Start-Sleep -Seconds 20
        }
    }
} else {
    Note 'mx1r opjat bez magii GGUF:'
    Get-Content 'D:\MemeX\results\quant_mx1r.log' -Tail 5 -EA SilentlyContinue | ForEach-Object { Note ('    ' + $_) }
}

Phase '4. ostalnaja ochered' "$BENCH\master.ps1" 18

Say 'vsjo'

