# SHAG 5: PREDZAGRUZKA EKSPERTOV PO R1 poverh rezidentnogo hranilishcha (shag 4).
#
# CHAST A - SVERKA: predzagruzka NE menjaet otvet. Ona lish zaranee kladjot v zapasnye sloty
# to, chto inache prochitalos by sinhronno; rezidentnost i vybor ekspertov ne trogajutsja.
# Kriterij - TE ZHE TOKENY i TOT ZHE L2, chto u plecha "hranilishche bez predzagruzki" na tom
# zhe binarnike. Plechi NE cheredujutsja - sverka ne o skorosti.
#
# CHAST B - HOLODNYJ START: malyj C (promahov mnogo, nabor ne progret), --gen podrjad. Meraem
# sinhronnyh promahov/token i ms/token: hranilishche bez predzagruzki protiv s predzagruzkoj
# (async), i - dlja chestnosti - sinhronnyj rezhim predzagruzki, kotoryj chtenie NE prjachet.
#
# LLAMA_MMAP_PREFETCH=0 vezde (kommit 7497d394).

param(
    [string] $Model   = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
    [string] $Prompt  = 'D:\MemeX\results\prompt_micro.txt',
    [string] $Corr    = 'D:\MemeX\results\r1_corr_k4.bin',
    [int]    $Cap     = 128,
    [int]    $Budget  = 16,
    [int]    $Steps   = 16,     # decode-check
    [int]    $Tokens  = 32,
    [int]    $Gen     = 48,     # holodnyj start
    [int]    $Rounds  = 2,
    [string] $Prior   = '',    # --expert-prior: zatravka rezidentnogo nabora (uslovie sim)
    [string] $OutDir  = 'D:\MemeX\results\step5'
)
$PriorArg = @(); if ($Prior -ne '') { $PriorArg = @('--expert-prior', $Prior) }

. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Path $OutDir -Force -EA SilentlyContinue | Out-Null

function Run-DC([string]$name, [string[]]$extra) {
    $log = Join-Path $OutDir ("dc_{0}.log" -f $name)
    $a = @('-m', $Model, '-f', $Prompt, '--tokens', "$Tokens", '--decode-check', "$Steps",
           '-t', '8', '--no-repack', '--gpu-static', '--gpu-static-layers',
           '--expert-store', "$Cap") + $PriorArg + $extra
    $env:LLAMA_MMAP_PREFETCH = '0'
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $txt = Get-Content -LiteralPath $log -Raw
    $want = Split-Path -Leaf $Model
    if ($txt -notmatch [regex]::Escape($want)) { Write-Host "  OTKAZ ($name): net imeni modeli"; return $null }
    $m = [regex]::Match($txt, 'DECODE_CHECK agree (\d+) steps (\d+) worst_l2 ([0-9.]+) worst_step (-?\d+) ids([^\r\n]*)')
    if (-not $m.Success) { Write-Host "  OTKAZ ($name): net stroki DECODE_CHECK"; return $null }
    $vr = [regex]::Match($txt, 'ESTORE_VERIFY slots (\d+) bad (\d+)')
    $pf = [regex]::Match($txt, 'PREFETCH_AB (.*)')
    Write-Host ("  {0}: {1}/{2} tokenov, hudshij L2 {3:N4}%{4}" -f `
        $name, $m.Groups[1].Value, $m.Groups[2].Value, [double]$m.Groups[3].Value,
        $(if ($vr.Success) { "  VERIFY slots $($vr.Groups[1].Value) bad $($vr.Groups[2].Value)" } else { '' }))
    if ($pf.Success) { Write-Host ("      " + $pf.Groups[1].Value) }
    return [pscustomobject]@{ arm=$name; agree=[int]$m.Groups[1].Value; steps=[int]$m.Groups[2].Value;
        l2=[double]$m.Groups[3].Value; ids=$m.Groups[5].Value.Trim() }
}

function Run-Gen([string]$name, [string[]]$extra, [string]$tag) {
    $log = Join-Path $OutDir ("gen_{0}_{1}.log" -f $name, $tag)
    $a = @('-m', $Model, '-f', $Prompt, '--tokens', "$Tokens", '--gen', "$Gen",
           '-t', '8', '--no-repack', '--no-ref', '--gpu-static', '--gpu-static-layers',
           '--expert-store', "$Cap") + $PriorArg + $extra
    $env:LLAMA_MMAP_PREFETCH = '0'
    $t0 = Get-Date
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $wall = ((Get-Date) - $t0).TotalSeconds
    $txt = Get-Content -LiteralPath $log -Raw
    if ($txt -notmatch [regex]::Escape((Split-Path -Leaf $Model))) { Write-Host "  OTKAZ ($name/$tag): net imeni modeli"; return $null }
    $m = [regex]::Match($txt, 'скорость генерации: наш\s+([0-9]+[.,][0-9]+)')
    if (-not $m.Success) { Write-Host "  OTKAZ ($name/$tag): net stroki skorosti"; return $null }
    $v = [double]($m.Groups[1].Value -replace ',', '.')
    $mspt = if ($v -gt 0) { 1000.0 / $v } else { 0.0 }
    $miss = -1.0; $mssync = -1.0; $hits = -1.0
    $es = [regex]::Match($txt, 'ESTORE_AB .*hits\s+([0-9.]+)\s+miss_per_tok\s+([0-9.]+)\s+ms_sync_per_tok\s+([0-9.]+)')
    if ($es.Success) { $hits=100.0*[double]$es.Groups[1].Value; $miss=[double]$es.Groups[2].Value; $mssync=[double]$es.Groups[3].Value }
    $pf = [regex]::Match($txt, 'PREFETCH_AB (.*)')
    $ids = [regex]::Match($txt, 'наши id:([^\r\n]*)')
    Write-Host ("  {0} [{1}]: {2:N4} tok/s = {3:N1} ms/token, nastennoe {4:N0} s; popadanij {5:N3}%, sinhr.promahov {6:N3}/token ({7:N2} ms)" -f `
        $name, $tag, $v, $mspt, $wall, $hits, $miss, $mssync)
    if ($pf.Success) { Write-Host ("      " + $pf.Groups[1].Value) }
    return [pscustomobject]@{ arm=$name; tag=$tag; toks=$v; mspt=$mspt; miss=$miss; mssync=$mssync; hits=$hits;
        ids=$(if ($ids.Success) { $ids.Groups[1].Value.Trim() } else { '' }) }
}

if (-not (Take-Machine -Who 'step5-prefetch' -TimeoutMin 300)) { Write-Output 'mashinu ne dali'; exit 1 }

Write-Host "== CHAST A: SVERKA (decode-check, C=$Cap) =="
$dc = @()
$dc += Run-DC 'store'          @()
$dc += Run-DC 'prefetch_async' @('--expert-prefetch', $Corr, '--prefetch-budget', "$Budget")
$dc += Run-DC 'prefetch_sync'  @('--expert-prefetch', $Corr, '--prefetch-budget', "$Budget", '--prefetch-sync')

Write-Host ""
Write-Host "== CHAST B: HOLODNYJ START (--gen $Gen podrjad, C=$Cap) =="
$gn = @()
for ($r = 1; $r -le $Rounds; $r++) {
    $gn += Run-Gen 'store'          @()                                                              "r$r"
    $gn += Run-Gen 'prefetch_async' @('--expert-prefetch', $Corr, '--prefetch-budget', "$Budget")   "r$r"
}
$gn += Run-Gen 'prefetch_sync' @('--expert-prefetch', $Corr, '--prefetch-budget', "$Budget", '--prefetch-sync') 'r1'

Free-Machine

Write-Output ''
Write-Output '=== SVERKA TOKENOV ==='
$base = $dc | Where-Object { $_ -and $_.arm -eq 'store' } | Select-Object -First 1
if ($base) {
    foreach ($r in $dc) {
        if (-not $r -or $r.arm -eq 'store') { continue }
        $same_tok = ($r.ids -eq $base.ids)
        $same_l2  = ([math]::Abs($r.l2 - $base.l2) -lt 0.0000005)
        Write-Output ("{0}: tokeny {1}, L2 {2:N4}% protiv {3:N4}% - {4}" -f `
            $r.arm, ($(if ($same_tok) { 'TE ZHE' } else { 'DRUGIE' })), $r.l2, $base.l2,
            ($(if ($same_tok -and $same_l2) { 'SOSHLOS DO ZNAKA' } elseif ($same_tok) { 'tokeny te zhe, L2 otlichaetsja' } else { 'RASHOZHDENIE - DEFEKT' })))
    }
}
Write-Output ''
Write-Output '=== HOLODNYJ START: srednee po podrjad-progonam ==='
function Summ([string]$arm) {
    $rows = @($gn | Where-Object { $_ -and $_.arm -eq $arm })
    if ($rows.Count -eq 0) { Write-Output ("{0}: net progonov" -f $arm); return }
    $v = @($rows | ForEach-Object { $_.toks })
    $avg = ($v | Measure-Object -Average).Average
    $ms = if ($avg -gt 0) { 1000.0 / $avg } else { 0 }
    $miss = ($rows | ForEach-Object { $_.miss } | Measure-Object -Average).Average
    $mssync = ($rows | ForEach-Object { $_.mssync } | Measure-Object -Average).Average
    Write-Output ("{0}: {1} tok/s  srednee {2:N3} = {3:N1} ms/token; sinhr.promahov {4:N3}/token, {5:N2} ms/token" -f `
        $arm, (($v | ForEach-Object { '{0:N3}' -f $_ }) -join ' / '), $avg, $ms, $miss, $mssync)
}
Summ 'store'; Summ 'prefetch_async'; Summ 'prefetch_sync'
