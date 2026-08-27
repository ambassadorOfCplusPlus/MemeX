# Razvjortka po tochkam otpravki dlja grafa sloja.
#
# Graf sloja - 29 uzlov, iz nih 5 matumnozhenij, i pri lubom delitele on otpravljaetsja
# DVAZHDY. Vopros, kotoryj stoit odnogo pjatiminutnogo zamera: eto horosho ili ploho.
#
# Dva sledstvija tjanut v raznye storony i oba izmerimy tolko vmeste:
#   - kazhdyj submit stoit 24.1 us, i pri odnom peresechenii na sloj eto 48 us x 48 = 2.3 ms
#     na tokjen. Menshe submitov - deshevle.
#   - rannij submit zapuskaet ustrojstvo, poka host eshchjo zapisyvaet ostavshiesja uzly, i
#     dajot ggml_vk_wait_for_fence na chjom SPAT (klauza almost_ready). Ubrat ego - znachit
#     krutit hostom ves graf. Bolshe submitov - ranshe start.
#
# Ostorozhno s delitelem 0: on snimaet ogranichenie min(100 MB, ...) na dlinu odnoj otpravki,
# a Windows ubivaet jadro okolo dvuh sekund. Otkaz togda - device-lost, a ne medlennyj progon.
# Nashi grafy malenkie, no razvjortka vsjo ravno predpochitaet malyj delitel nulju.
param(
    [int] $Ngen   = 64,
    [int] $Tokens = 512,
    [int] $Threads = 8,
    [int] $LimitMin = 15
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\static_submit_sweep.log'

function Say($m) { $l = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

$null = & $EXE --version *> $null
if ($LASTEXITCODE -ne 0) { Say 'exe ne zapuskaetsja'; exit 1 }

function RunOnce($tag, $divisor, $tail) {
    $so = "D:\MemeX\results\_ssw_$tag.out"
    $env:GGML_VK_SUBMIT_DIVISOR = "$divisor"
    $env:GGML_VK_SUBMIT_TAIL    = "$tail"
    $env:GGML_VK_SUBMIT_STATS   = '1'
    $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$Threads",
           '--gen', "$Ngen", '--no-repack', '--gpu-static-layers')
    $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                          -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) { Say "$tag - tajm-aut"; try { $proc.Kill() } catch {}; return }
    $ln = (Get-Content -LiteralPath $so -Encoding UTF8 | Select-String -Pattern 'na odno peresechenie|na tokjen ' | ForEach-Object { $_.Line.Trim() }) -join ' | '
    $ab = (Get-Content -LiteralPath $so -Encoding UTF8 | Select-String -Pattern '^STATIC_AB ' | ForEach-Object { $_.Line.Trim() })
    $sb = (Get-Content -LiteralPath "$so.err" -Encoding UTF8 | Select-String -Pattern 'uzlov v splite   29' | Select-Object -First 1)
    Say ("delitel $divisor, hvost $tail : " + $ab)
    Say ("    " + $ln)
    if ($sb) { Say ("    " + $sb.Line.Trim()) }
}

Say 'berjom mashinu pod razvjortku otpravok'
if (-not (Take-Machine -Who 'static-submit-sweep' -TimeoutMin 60)) { Say 'mashinu ne poluchili'; exit 1 }
try {
    RunOnce 'd1t0'  1  0
    RunOnce 'd1t1'  1  1
    RunOnce 'd4t1'  4  1
    RunOnce 'd40t1' 40 1
} finally {
    Remove-Item Env:GGML_VK_SUBMIT_DIVISOR -ErrorAction SilentlyContinue
    Remove-Item Env:GGML_VK_SUBMIT_TAIL -ErrorAction SilentlyContinue
    Remove-Item Env:GGML_VK_SUBMIT_STATS -ErrorAction SilentlyContinue
    Free-Machine
    Say 'mashina osvobozhdena'
}
