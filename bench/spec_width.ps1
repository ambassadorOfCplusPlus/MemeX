# Cena prohoda na K tokenov - vremenem, a ne modelju.
#
# Zond MEMEX_MTP_OVERLAP poschital po marshrutizatoru, chto pri K=4 Gemma chitaet 0,618 ot
# linejnogo chisla ekspertov. Eto PREDSKAZANIE. Zdes ono proverjaetsja chasami: esli otnoshenie
# prohoda k K odinochnym shagam ljazhet okolo 0,618 - model verna i ejo mozhno prodolzhat. Esli
# ljazhet u 1,00 - ekonomii net, i chernovuju golovu pisat ne stoit.
param(
    [int]    $Kmax    = 6,
    [int]    $Tokens  = 512,
    [int]    $Threads = 8,
    [string] $Prompt  = 'D:\MemeX\results\prompt_2000.txt',
    # KONTROL. Bez etogo kljucha shirina 1 idjot S KARTOJ, a shiriny >1 - bez nejo (dvizhok
    # otklyuchaet kartochnyj put sam pri n_tokens > 1), i otnoshenie meshaet DVA effekta:
    # ekonomiju ot perekrytija ekspertov i poterju karty. S -NoCard karta ne sozdajotsja
    # voobshche, vse shiriny odinakovo processornye, i otnoshenie merit tolko perekrytie.
    [switch] $NoCard
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$LOG = 'D:\MemeX\results\spec_width.log'
$OUT = 'D:\MemeX\results'
$models = @(
  @{ t = 'gemma'; m = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'; x = $(if ($NoCard) { @() } else { @('--gpu-static-dense') }) },
  @{ t = 'qwen';  m = 'D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf'; x = $(if ($NoCard) { @() } else { @('--gpu-static-layers') }) }
)
function Note($m) { Write-Host "  $m"; Add-Content -LiteralPath $LOG -Value "  $m" -Encoding UTF8 }
("`n`n######## cena prohoda na K tokenov " + (Get-Date)) | Add-Content $LOG
if (-not (Take-Machine -Who 'spec_width' -TimeoutMin 180)) { Note 'mashinu ne poluchili'; exit 3 }
try {
  foreach ($md in $models) {
    if (-not (Test-Path -LiteralPath $md.m)) { Note "$($md.t): net fajla - propushcheno"; continue }
    $log = Join-Path $OUT "_sw_$($md.t)$(if ($NoCard) {'_nocard'}).out"
    $env:MEMEX_SPEC_WIDTH = "$Kmax"
    $a = @('-m', $md.m, '-f', $Prompt, '--tokens', "$Tokens", '--gen', '2',
           '-t', "$Threads", '--no-repack', '--no-ref', '--resident', '8') + $md.x
    $cmdline = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" } }) -join ' '
    $proc = Start-Process -FilePath $EXE -ArgumentList $cmdline -NoNewWindow -PassThru `
                          -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $null = $proc.Handle
    if (-not $proc.WaitForExit(2400 * 1000)) { try { $proc.Kill($true) } catch { }; Note "$($md.t): tajm-aut"; continue }
    $code = $proc.ExitCode; if ($null -eq $code) { $code = -2 }
    Remove-Item Env:MEMEX_SPEC_WIDTH -EA SilentlyContinue
    $txt = Get-Content -LiteralPath $log -EA SilentlyContinue
    $lines = @($txt | Select-String -Pattern 'CENA PROHODA|^\s+K=\d|OTNOSHENIE - eto|NE IZMERENO|vse shiriny|karta \(sloi\)')
    if ($lines.Count -eq 0) { Note "$($md.t): razvjortka NICHEGO ne napechatala (kod $code) - NE IZMERENO"; continue }
    Note "===== $($md.t) (kod vyhoda $code)"
    foreach ($l in $lines) { Note $l.Line }
  }
} finally { Free-Machine; Note 'mashina osvobozhdena' }
