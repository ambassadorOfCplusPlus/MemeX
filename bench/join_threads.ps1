# Proverka ODNOGO mehanizma: iz chego sostoit 11.47 ms ozhidanija na dzhojne.
#
# Zamer razlozhil ego na dve chasti, i lechatsja oni po-raznomu:
#     disbalans   21.08 - 15.77 = 5.31 ms   karta prosto dolshe, chem CPU
#     peredacha   11.47 - 5.31  = 6.16 ms   = 0.128 ms na sloj na notify + probuzhdenie
#
# 0.128 ms na peredachu mezhdu dvumja potokami - ochen mnogo, obychno 5-20 us. Gipoteza uzhe
# zapisana v gpu_experts.cpp:789: op dzhojna idjot s n_tasks = 1, poka potok 0 stoit v wait,
# ostalnye SEM potokov ggml krutjatsja na svojom barjere, jader vosem, i planirovshchiku
# nekuda postavit potok-rabochij. Togda odin potok MENSHE dolzhen ubrat pochti vsju peredachu.
#
# PREDSKAZANIE, zapisano DO progona:
#
#   -t 8 (uzhe izmereno): 15.28 tok/s = 65.4 ms; polovina CPU 15.77, karty 21.08, ZHDJOM 11.47
#
#   -t 7: polovina CPU rastjot na 8/7 = 18.0 ms. Peredacha, esli gipoteza verna, padaet s
#         0.128 do 0.02-0.04 ms na sloj = 1-2 ms. Ozhidanie = (21.08 - 18.0) + 1.5 = 4.6 ms.
#         Ostalnaja rabota CPU (okolo 6 ms) rastjot na 8/7 = +0.9.
#         Itogo 65.4 - 11.47 + 4.6 + 2.2 + 0.9 = 61.6 ms
#         PREDSKAZYVAJU 16.0 - 16.8 tok/s, i ZHDJOM 3 - 6 ms
#
#   -t 6: polovina CPU 21.0, pochti rovno polovina karty; ozhidanie okolo 1.5-3 ms, no vsja
#         ostalnaja rabota CPU rastjot na 8/6.
#         PREDSKAZYVAJU 15.6 - 16.4 tok/s - to est HUZHE semi, i eto to, chto otlichaet
#         gipotezu "planirovshchiku nekuda postavit rabochego" ot prostogo "menshe potokov
#         luchshe": esli by delo bylo v oversubscribe voobshche, shest bylo by ne huzhe semi.
#
#   Esli ZHDJOM pri -t 7 ostanetsja okolo 11 ms - gipoteza o planirovshchike neverna, i
#   6.16 ms peredachi nado iskat v drugom meste (naprimer v samom cv/notify, a ne v jadrah).
#
# Odin progon na plecho: sravnivajutsja SLAGAEMYE odnogo tokjena, snjatye odnim progonom, a
# tok/s mezhdu -t sravnivajutsja v odnoj sessii i podrjad. Dlja tok/s tut po odnomu povtoru,
# poetomu vyvod delaetsja po ZHDJOM, kotoroe menjaetsja v razy, a ne po tok/s, kotorye
# menjajutsja na procenty.

param(
    [int]   $Ngen    = 192,
    [int]   $Tokens  = 512,
    [int[]] $Threads = @(7, 6, 8),
    [int]   $LimitMin = 20
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\join_threads.log'

function Say($m) { $l = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

function Wait-Settled([int]$capSec = 180, [int]$deltaMB = 200) {
    $prev = -1.0
    $deadline = (Get-Date).AddSeconds($capSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB
        if ($prev -ge 0 -and [math]::Abs($free - $prev) -lt $deltaMB) { return $free }
        $prev = $free
    }
    return $prev
}

$null = & $EXE --version *> $null
if ($LASTEXITCODE -ne 0) { Say ("exe ne zapuskaetsja, kod " + $LASTEXITCODE); exit 1 }

("`n`n######## join threads " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8
Say 'berjom mashinu'
if (-not (Take-Machine -Who 'join-threads' -TimeoutMin 60 -MinFreeGB 16)) { Say 'mashinu ne poluchili'; exit 1 }
try {
    foreach ($t in $Threads) {
        $so = "D:\MemeX\results\_jt_t$t.out"
        $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$t",
               '--gen', "$Ngen", '--no-repack', '--gpu-static-layers', '--gpu-experts',
               '--resident', '0')
        Say "-t $t"
        $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        $null = $proc.Handle
        if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) {
            Say '  ne uspel - ubivaju'; try { $proc.Kill() } catch {}; $null = Wait-Settled; continue
        }
        Get-Content -LiteralPath $so -Encoding UTF8 |
            Select-String -Pattern 'STATIC_AB|джойн, на токен|джойнов|na tokjen \d|попаданий \d+\.\d+% \(' |
            ForEach-Object { Say ('    ' + $_.Line.Trim()) }
        $null = Wait-Settled
    }
} finally {
    Free-Machine
    Say 'mashina osvobozhdena'
}
