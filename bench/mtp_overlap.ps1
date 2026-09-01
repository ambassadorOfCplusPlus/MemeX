# Skolko ekspertov chitaet prohod na K tokenov - potolok vygody ot MTP/spekuljativki.
#
# POCHEMU ETO PERVOE, CHTO NADO IZMERIT. Dlja plotnoj modeli spekuljativnoe dekodirovanie
# dajot mnozhitel K: vesa chitajutsja odin raz na prohod. Dlja razrezhennoj MoE - net: kazhdyj
# iz K tokenov marshrutiziruetsja v svoi eksperty, i prohod chitaet OBEDINENIE. Esli
# obedinenie rastjot linejno po K, processornaja polovina (49% tokena u Gemmy) ne vyigryvaet
# nichego, i stroit chernovuju golovu radi odnoj kartochnoj poloviny - drugaja arifmetika.
#
# Zond schitaet po `rsel` - top-k marshrutizatora, kotoryj dvizhok i tak chitaet dlja progreva
# rezidentnogo nabora. Nichego ne stroitsja, nichego ne meritsja po vremeni: eto podschjot
# mnozhestv, i on ne zavisit ot sostojanija mashiny.
param(
    [int]    $Tokens  = 512,
    [int]    $Ngen    = 2,
    [int]    $Threads = 8,
    [string] $Prompt  = 'D:\MemeX\results\prompt_2000.txt'
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$OUT = 'D:\MemeX\results'
$LOG = 'D:\MemeX\results\mtp_overlap.log'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'

$models = @(
  @{ t = 'gemma'; m = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf'; x = @('--gpu-static-dense') },
  @{ t = 'qwen';  m = 'D:\Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf'; x = @('--gpu-static-layers') }
)
function Note($m) { Write-Host "  $m"; Add-Content -LiteralPath $LOG -Value "  $m" -Encoding UTF8 }
("`n`n######## perekrytie ekspertov " + (Get-Date)) | Add-Content $LOG

if (-not (Take-Machine -Who 'mtp_overlap' -TimeoutMin 120)) { Note 'mashinu ne poluchili'; exit 3 }
try {
  foreach ($md in $models) {
    if (-not (Test-Path -LiteralPath $md.m)) { Note "$($md.t): net fajla modeli - propushcheno"; continue }
    $log = Join-Path $OUT "_mtp_$($md.t).out"
    $env:MEMEX_MTP_OVERLAP = '1'
    $a = @('-m', $md.m, '-f', $Prompt, '--tokens', "$Tokens", '--gen', "$Ngen",
           '-t', "$Threads", '--no-repack', '--no-ref', '--resident', '8') + $md.x
    $cmdline = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" } }) -join ' '
    $proc = Start-Process -FilePath $EXE -ArgumentList $cmdline -NoNewWindow -PassThru `
                          -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $null = $proc.Handle
    if (-not $proc.WaitForExit(1800 * 1000)) { try { $proc.Kill($true) } catch { }; Note "$($md.t): tajm-aut"; continue }
    $code = $proc.ExitCode; if ($null -eq $code) { $code = -2 }
    Remove-Item Env:MEMEX_MTP_OVERLAP -EA SilentlyContinue
    $txt = Get-Content -LiteralPath $log -EA SilentlyContinue
    $lines = @($txt | Select-String -Pattern 'MTP:|^\s+K=\d|obedinenie|VNIMANIE: eto marshrut|I eto POTOLOK')
    # Rule 83: a channel that was not measured must say so, not print a blank.
    if ($lines.Count -eq 0) {
      Note "$($md.t): zond NICHEGO NE NAPECHATAL (kod vyhoda $code) - NE IZMERENO"
      continue
    }
    Note "===== $($md.t) (kod vyhoda $code)"
    foreach ($l in $lines) { Note $l.Line }
  }
} finally { Free-Machine; Note 'mashina osvobozhdena' }
