# Is the 310 us round-trip floor a property of the hardware, or of how busy the queue is?
#
# WHY THIS IS THE BIGGEST REMAINING ITEM. 49 crossings a token at ~310 us is 15.2 ms - 28% of the
# token, the largest single term in the budget and the one nothing has moved. Everything tried
# against it failed for a reason that is now understood: pre-recorded command buffers (host
# recording is 0.06-0.93 us a node, there is nothing to save), narrowed barriers (-0.1%), node
# cutting (<=0.5%), the keep-warm poke (-0.7%). All of those attacked the HOST side, and the
# floor is not on the host side: ggml_vk_wait_for_fence already spins in user space with
# _mm_pause, and GGML_VK_SUBMIT_TAIL=0 is the default, so there is no kernel transition and no
# scheduler wake-up left to remove. The 310 us is submit-to-completion-visible on the device.
#
# THE HYPOTHESIS, which is not a guess - it falls out of two numbers this project already has:
#   - a crossing costs 0.277 ms with the static path alone and 0.234 ms with the expert path
#     ALSO live, and both contexts share one VkQueue (vk_instance.devices[idx] is a singleton);
#   - a batched eight-matmul graph submitted back to back totals 185.4 us - BELOW the floor the
#     real workload shows.
# Both point the same way: the floor falls when the queue already has work in it. If that holds
# it is not a constant, and 310 -> 185 us would be 6.1 ms a token, about +13%.
#
# THE PREDICTION, WRITTEN BEFORE THE RUN, because this arm has an obvious confound and naming
# the direction in advance is what separates the two readings:
#
#   If occupancy is the mechanism, the STATIC context's own wait per crossing goes DOWN in the
#   arm that adds the expert path - even though that arm does strictly more total work on the
#   same queue. That is the counter-intuitive direction and it is the whole test.
#
#   If the static wait goes UP instead, that is ordinary contention for one queue, the floor is
#   not occupancy-dependent, and the line dies here. A wash means the confound swallowed it and
#   the arm was built badly - which is NOT MEASURED, not "no effect".
#
# --resident-freeze in BOTH arms: without it the expert arm also runs promotions, which occupy
# the worker thread and the transfer queue, and the difference stops being about queue occupancy.
#
# FENCE_SPLIT prints per CONTEXT id, and that matters more here than anywhere else: two contexts
# live on one device (static and experts), and these counters used to be file statics that
# blended a 29-node attention crossing with a 3-node expert dispatch into one average. Every
# number below compares ctx 0 against ctx 0.
param(
    [int]    $Reps    = 3,
    [int]    $Tokens  = 512,
    [int]    $Ngen    = 192,
    [int]    $Threads = 8,
    [string] $Prompt  = 'D:\MemeX\results\prompt_2000.txt'
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$LOG   = 'D:\MemeX\results\queue_floor_ab.log'
$OUT   = 'D:\MemeX\results'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

foreach ($f in @($EXE, $MODEL, $Prompt)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "NET FAJLA: $f"; exit 4 }
}

# One run. Returns the per-crossing submit and wait for each context id it saw.
function RunOnce {
    param([string]$Tag, [string[]]$Extra, [int]$LimitSec)
    $log = Join-Path $OUT "_qf_$Tag.out"
    $err = "$log.err"
    $a = @('-m', $MODEL, '-f', $Prompt, '--tokens', "$Tokens", '--gen', "$Ngen",
           '-t', "$Threads", '--no-repack', '--resident-freeze') + $Extra
    $cmdline = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" } }) -join ' '
    $env:GGML_VK_FENCE_SPLIT = '1'
    $proc = Start-Process -FilePath $EXE -ArgumentList $cmdline -NoNewWindow -PassThru `
                          -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $proc.Handle          # without this .ExitCode comes back EMPTY, not zero
    if (-not $proc.WaitForExit($LimitSec * 1000)) {
        try { $proc.Kill($true) } catch { }
        Remove-Item Env:GGML_VK_FENCE_SPLIT -EA SilentlyContinue
        return @{ err = 'tajm-aut' }
    }
    Remove-Item Env:GGML_VK_FENCE_SPLIT -EA SilentlyContinue
    $res = @{ err = ''; ctx = @{} }
    $code = $proc.ExitCode
    if ($null -eq $code) { $code = -2 }
    if ($code -ne 0 -and $code -ne 2) { $res.err = "kod vyhoda $code"; return $res }
    # Last FENCE_SPLIT line per context: the counters are cumulative, so the last one is the run.
    $lines = Get-Content -LiteralPath $err -EA SilentlyContinue |
             Select-String -Pattern '^FENCE_SPLIT ctx (\d+) n (\d+) submit ([\d.]+) zhdjom ([\d.]+)'
    foreach ($ln in $lines) {
        $id = [int]$ln.Matches[0].Groups[1].Value
        $res.ctx[$id] = @{ n      = [int]   $ln.Matches[0].Groups[2].Value
                           submit = [double]$ln.Matches[0].Groups[3].Value
                           wait   = [double]$ln.Matches[0].Groups[4].Value }
    }
    # Rule 68: the arm must say which arm it is, and the script checks it rather than trusting
    # the flags. Two live contexts means the expert path really ran; one means it did not.
    $res.nctx = $res.ctx.Keys.Count
    $g = Get-Content -LiteralPath $log -EA SilentlyContinue |
         Select-String -Pattern 'our_tok_s ([\d.]+)' | Select-Object -First 1
    if ($g -and $g.Line -match 'our_tok_s ([\d.]+)') { $res.gen = [double]$Matches[1] }
    return $res
}

# --gpu-static-LAYERS in both arms, and the first attempt got this wrong.
#
# It used plain --gpu-static, which puts only the HEAD on the card: one crossing per token, and
# a big matmul at that. The measured wait then came back at 1.88 ms in BOTH arms to within 0.1%,
# which is not a refutation of anything - the head's own wait has no reason to move when an
# expert context appears beside it. The floor being tested lives on the LAYER path, where there
# are 49 crossings a token of 27 nodes each. The script said "NE IZMERENO, plecho nichego ne
# razdelilo" rather than "no effect", which is the only reason this was caught rather than
# recorded as a closed line.
$arms = @(
    @{ t = 'sloi';     x = @('--gpu-static-layers')                },
    @{ t = 'sloi+exp'; x = @('--gpu-static-layers','--gpu-experts') }
)
$acc = @{}
foreach ($arm in $arms) { $acc[$arm.t] = @{ wait = @(); submit = @(); gen = @(); nctx = @() } }

("`n`n######## porog ocheredi " + (Get-Date)) | Add-Content $LOG
Say 'PREDSKAZANIE (zapisano do progona): esli delo v zanjatosti ocheredi, u KONTEKSTA 0 ozhidanie na peresechenie UPADET v pleche st+exp, hotja raboty tam bolshe. Rost = obychnaja konkurencija za ochered, i linija umiraet.'

for ($r = 1; $r -le $Reps; $r++) {
    Say "berjom mashinu pod raund $r"
    if (-not (Take-Machine -Who 'queue_floor' -TimeoutMin 180)) { Note 'mashinu ne poluchili'; exit 3 }
    try {
        foreach ($arm in $arms) {
            $res = RunOnce "$($arm.t)_$r" $arm.x 1800
            if ($res.err -ne '') { Note ("raund ${r} $($arm.t): " + $res.err); continue }
            # Identify the LAYER context by its crossing count, not by its index or by how
            # many contexts exist. Both of those were wrong: the head now lives on the card too
            # and opens its own context, so the arms came back with 2 and 3 rather than the 1
            # and 2 this script first demanded, and every arm was thrown away. The layer path
            # crosses ~48 times a token and the head once, so the busiest context IS the layer
            # context - a property of the thing being measured rather than of the wiring.
            if ($res.ctx.Count -lt 1) { Note ("raund ${r} $($arm.t): FENCE_SPLIT ne napechatan - vybrosheno"); continue }
            $c0 = $null; $best = -1
            foreach ($k in $res.ctx.Keys) { if ($res.ctx[$k].n -gt $best) { $best = $res.ctx[$k].n; $c0 = $res.ctx[$k] } }
            # And the arm still has to say which arm it is: the expert arm must have MORE live
            # contexts than the plain one. Recorded per round and checked at the end, because
            # neither count is knowable in advance once the head moved.
            $acc[$arm.t].nctx += $res.ctx.Count
            $acc[$arm.t].wait   += $c0.wait
            $acc[$arm.t].submit += $c0.submit
            if ($res.ContainsKey('gen')) { $acc[$arm.t].gen += $res.gen }
            Note ("raund {0} {1,-8} ctx0: peresechenij {2,6}  submit {3:N4} ms  zhdjom {4:N4} ms  tok/s {5:N2}" -f
                  $r, $arm.t, $c0.n, $c0.submit, $c0.wait, $(if ($res.ContainsKey('gen')) { $res.gen } else { 0 }))
        }
    } finally { Free-Machine; Say "mashina osvobozhdena posle raunda $r" }
}

Say 'ITOG'
function Summ($name, $v) {
    $a = @($v | Where-Object { $null -ne $_ })
    if ($a.Count -eq 0) { return ("{0,-22} NE IZMERENO" -f $name) }
    $m = ($a | Measure-Object -Average).Average
    if ($a.Count -lt 2) { return ("{0,-22} {1,9:N4} (odin progon - NE REZULTAT)" -f $name, $m) }
    $sp = (($a | Measure-Object -Maximum).Maximum - ($a | Measure-Object -Minimum).Minimum) / [Math]::Max($m, 1e-9)
    return ("{0,-22} {1,9:N4} (razbros {2,5:P1}, n={3})" -f $name, $m, $sp, $a.Count)
}
foreach ($arm in $arms) {
    Note (Summ "$($arm.t) kontekstov" $acc[$arm.t].nctx)
    Note (Summ "$($arm.t) zhdjom ms"  $acc[$arm.t].wait)
    Note (Summ "$($arm.t) submit ms"  $acc[$arm.t].submit)
    Note (Summ "$($arm.t) tok/s"      $acc[$arm.t].gen)
}
$ws = @($acc['sloi'].wait); $we = @($acc['sloi+exp'].wait)
$ns = @($acc['sloi'].nctx); $ne = @($acc['sloi+exp'].nctx)
if ($ns.Count -ge 1 -and $ne.Count -ge 1) {
    $mns = ($ns | Measure-Object -Average).Average
    $mne = ($ne | Measure-Object -Average).Average
    if ($mne -le $mns) {
        Note ("kontekstov v pleche s ekspertami $mne, bez nih $mns - ekspertnyj put ne zapustilsja, VSJO VYBROSHENO")
        exit 5
    }
}
if ($ws.Count -ge 2 -and $we.Count -ge 2) {
    $ms = ($ws | Measure-Object -Average).Average
    $me = ($we | Measure-Object -Average).Average
    $d  = 100.0 * ($me - $ms) / $ms
    Note ("ctx0 zhdjom: sloi {0:N4} -> sloi+exp {1:N4} ms, {2:N1}%" -f $ms, $me, $d)
    if ($d -lt -5)    { Note 'UPALO: porog zavisit ot zanjatosti ocheredi - gipoteza podtverzhdena, ocenka 6,1 ms/token' }
    elseif ($d -gt 5) { Note 'VYROSLO: eto konkurencija za ochered, a ne porog. Linija zakryta.' }
    else              { Note 'VNUTRI SHUMA: arm nichego ne razdelil. NE IZMERENO, a ne "net effekta".' }
} else { Note 'menshe dvuh povtorov hotja by v odnom pleche - NE REZULTAT' }
