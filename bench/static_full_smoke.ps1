# Odin korotkij progon vsej shemy srazu: statika na karte, rezidentnye eksperty rjadom,
# obnovlenie nabora vtorym potokom - i proverki vkljucheny vse, kakie est.
#
# ETO NE ZAMER. Ceny zdes nedejstvitelny po postrojeniju: --gpu-experts-check schitaet
# rezidentnuju polovinu DVAZHDY, a --resident sam po sebe zastavljaet garness gonjat
# nerasshcheplennyj graf na pervyh chetyrjoh shagah. Nuzhno drugoe - chtoby dva konteksta
# Vulkan na odnom ustrojstve ne upali i chtoby rasshcheplenie soshlos posloten.
#
# Chto imenno smotrim v vyvode:
#   "видеопамять против модели: сверено слотов N, расхождений 0"  - slot-karta i ukladka
#   "расщеплённый против нерасщеплённого"                          - summa dvuh polovin
#   "поток устройства упал"                                        - dolzhno otsutstvovat
#   "USTROJSTVO OTKAZALO"                                          - to zhe
param(
    [int]    $Ngen   = 24,
    [int]    $Tokens = 128,
    [int]    $Threads = 8,
    [int]    $Resident = 0,
    [int]    $LimitMin = 20,
    [switch] $NoCheck
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\static_full_smoke.log'

function Say($m) { $l = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

$null = & $EXE --version *> $null
if ($LASTEXITCODE -ne 0) { Say ("exe ne zapuskaetsja, kod " + $LASTEXITCODE); exit 1 }

$extra = @('--gpu-static-layers', '--gpu-experts', '--resident', "$Resident")
if (-not $NoCheck) { $extra += '--gpu-experts-check' }

Say 'berjom mashinu pod smoke'
if (-not (Take-Machine -Who 'static-full-smoke' -TimeoutMin 60)) { Say 'mashinu ne poluchili'; exit 1 }
try {
    $so = 'D:\MemeX\results\_sfs.out'
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$Threads",
           '--gen', "$Ngen", '--no-repack') + $extra
    Say ('argumenty: ' + ($a -join ' '))
    $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                          -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) {
        Say 'ne uspel - ubivaju'; try { $proc.Kill() } catch {}; exit 1
    }
    Say "kod vyhoda $($proc.ExitCode)"
    Get-Content -LiteralPath $so -Encoding UTF8 |
        Select-String -Pattern 'видеопамять против модели|расщеплённый против|поток устройства упал|USTROJSTVO|OTKAZ|попаданий|экспертов на слой|буфер: слои|bufer:|vsego .* MiB v videopamjati|na odno peresechenie|na tokjen|peresechenij|kesh prompta|STATIC_AB|тип в видеопамяти|источник промоушенов|расхожден|подкачк|скорость генерации|итог' |
        ForEach-Object { Say ('  ' + $_.Line.Trim()) }
    Say '--- stderr, esli est ---'
    if (Test-Path "$so.err") { Get-Content -LiteralPath "$so.err" -Encoding UTF8 | Select-Object -First 20 | ForEach-Object { Say ('  ' + $_) } }
} finally {
    Free-Machine
    Say 'mashina osvobozhdena'
}
