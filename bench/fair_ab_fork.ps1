# Chestnoe sravnenie: nash dvizhok (statika + rezidentnye eksperty na karte) protiv SHTATNOGO
# forka s tem zhe razdelom cherez flagi: -ngl 99 -ot "exps=CPU" (statika i KV na karte, eksperty
# na CPU). Model mx1 (30B-A3B, 4 bita, vlezaet v OZU). Plechi chereduyutsja, tri kruga, razbros
# pechataetsja rjadom so srednim. Pod zamkom, odnim processom.
#   pwsh -File C:\Users\User11\Desktop\MemeX\bench\fair_ab_fork.ps1
param([int]$Rounds = 3, [int]$TimeoutMin = 300, [int]$Threads = 8, [int]$Ngen = 32)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$BIN = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release'
$MODEL = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_micro.txt'
$OUT = 'D:\MemeX\results\fair_ab_fork.txt'
function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) | Tee-Object -FilePath $OUT -Append }

if (-not (Take-Machine -Who 'fair_ab' -TimeoutMin $TimeoutMin)) { "NE POLUCHIL MASHINU" | Out-File $OUT -Append; exit 3 }
try {
    Note "start: model $MODEL, promt $PROMPT, -t $Threads, gen $Ngen, krugov $Rounds"
    $ours = @(); $fork = @()
    for ($r = 1; $r -le $Rounds; $r++) {
        # plecho A: nash dvizhok
        $so = "D:\MemeX\results\_fair_ours_$r.out"
        & "$BIN\llama-memex-fwd.exe" -m $MODEL -f $PROMPT --tokens 32 -t $Threads --gen $Ngen --no-repack --no-ref `
            --gpu-static-layers --gpu-experts --resident 0 --resident-period 3 *> $so
        $line = Select-String -Path $so -Pattern 'tok/s' | Select-Object -Last 1
        $v = $null
        if ($line -and $line.Line -match '([\d]+[.,][\d]+)\s*tok/s') { $v = [double]($Matches[1] -replace ',', '.') }
        Note ("krug $r  NASH  : " + ($(if ($v) { "$v tok/s" } else { "NE RAZOBRANO, sm. $so" })))
        if ($v) { $ours += $v }
        # plecho B: shtatnyj fork
        $sf = "D:\MemeX\results\_fair_fork_$r.out"
        & "$BIN\llama-cli.exe" -m $MODEL -f $PROMPT -n $Ngen -c 2048 -t $Threads -ngl 99 -ot "exps=CPU" -fa off --no-warmup *> $sf
        $l2 = Select-String -Path $sf -Pattern 'eval time.*tokens per second' | Where-Object { $_.Line -notmatch 'prompt eval' } | Select-Object -Last 1
        $w = $null
        if ($l2 -and $l2.Line -match '([\d.]+)\s*tokens per second') { $w = [double]$Matches[1] }
        Note ("krug $r  FORK  : " + ($(if ($w) { "$w tok/s" } else { "NE RAZOBRANO, sm. $sf" })))
        if ($w) { $fork += $w }
    }
    foreach ($pair in @(@('NASH', $ours), @('FORK', $fork))) {
        $name = $pair[0]; $arr = $pair[1]
        if ($arr.Count -ge 2) {
            $m = ($arr | Measure-Object -Average).Average
            $mx = ($arr | Measure-Object -Maximum).Maximum; $mn = ($arr | Measure-Object -Minimum).Minimum
            Note ("{0}: {1}  srednee {2:N2}  razbros {3:N1}%" -f $name, ($arr -join ' / '), $m, (($mx - $mn) / $m * 100))
        } else { Note "$name : nedostatochno tochek ($($arr.Count))" }
    }
    Note "NE IZMERENO: kachestvo/sovpadenie tokenov mezhdu plechami; fork s -rtr (repak) - otdelnoe plecho"
} finally { Free-Machine }
