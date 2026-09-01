# One unattended pass: rebuild both trees, then re-run the two checks that the day's fixes
# invalidated. Sequential, one lock acquisition per step, so nothing here fights the machine
# with anything else.
#
# Why both trees. memex-fwd.cpp changed (the gemma4 card probes are ggml_cont now, not views),
# and the gemma check compares a `build` arm against a `build-vk` arm. Two arms from two
# different builds is the trap this project has already paid for twice - a green verdict from
# a run that did not happen.
#
# What each step re-establishes:
#   1. gemma_card_probe - the 369%/4394% norm divergences were the probe reading a reused
#      buffer, all thirty layers reporting the last layer's bytes. With storage of their own the
#      probes should now differ BETWEEN LAYERS. That, not the L2 value, is the pass condition.
#   2. promo_async_ab - the first measurement read "submit/zabor 0.000, reap 0.015", i.e. the
#      wait vanished. It had not: OSTATOK went 0.005 -> 0.545 because batch_begin reaped past
#      the counter. The behaviour is unchanged and the arithmetic already says ~0.33 ms of 0.878
#      genuinely went; this run is to make the columns say it too.
$ErrorActionPreference = 'Continue'
$LOG = 'D:\MemeX\results\night_verify.log'
function Say($m) { $l = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

Say '===== sborka: build-vk'
& pwsh -NoProfile -File 'C:\Users\User11\Desktop\MemeX\bench\build_safe.ps1' `
       -Targets llama-memex-fwd -Dir D:/MemeX/src/ik_llama.cpp/build-vk -Jobs 4 2>&1 |
    ForEach-Object { Say ('  ' + $_) }
if ($LASTEXITCODE -ne 0) { Say "build-vk upala (kod $LASTEXITCODE) - dalshe idti nelzja"; exit 1 }

Say '===== sborka: build'
& pwsh -NoProfile -File 'C:\Users\User11\Desktop\MemeX\bench\build_safe.ps1' `
       -Targets llama-memex-fwd -Dir D:/MemeX/src/ik_llama.cpp/build -Jobs 4 2>&1 |
    ForEach-Object { Say ('  ' + $_) }
if ($LASTEXITCODE -ne 0) { Say "build upala (kod $LASTEXITCODE) - gemma-shag propuskaem"; $skipGemma = $true }

if (-not $skipGemma) {
    Say '===== Gemma: zondy na karte protiv processornyh'
    & pwsh -NoProfile -File 'C:\Users\User11\Desktop\MemeX\bench\gemma_card_probe.ps1' -Threads 8 2>&1 |
        ForEach-Object { Say ('  ' + $_) }
}

Say '===== Asinhronnaja podkachka: povtor s chestnym uchjotom'
& pwsh -NoProfile -File 'C:\Users\User11\Desktop\MemeX\bench\promo_async_ab.ps1' -Reps 2 -RestMin 2 2>&1 |
    ForEach-Object { Say ('  ' + $_) }

Say '===== gotovo'
