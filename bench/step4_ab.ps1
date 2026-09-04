# A/B shaga 4: eksperty cherez strannichnyj kesh mmap protiv rezidentnogo hranilishcha v OZU.
#
# CHTO ZDES MERJAETSJA I POCHEMU IMENNO --gen 64.
#
# --gen 8 posle promta v 32 tokena merjaet holodnyj start: pervaja sotnja tokenov trogaet po
# 80 ranshe ne vstrechavshihsja ekspertov (bench/first_seen.py), i eto ne ustanovivshijsja
# rezhim. No i dlinnaja generacija sama po sebe ne vyhodit v ustanovivshijsja: eksperty
# IQ3_XXS eto 24,6 GiB, svobodnoj pamjati okolo 23,5, i strannichnyj kesh vytesnjaet rovno to,
# chto sledujushchij token snova prochitaet - izmereno koordinatorom, 254 ms/token na --gen 64
# protiv 131 na --gen 8. Imenno etu poterju hranilishche i dolzhno zabrat.
#
# TRI LOVUSHKI, KOTORYE ZDES UCHTENY.
#
# 1. Stranichnyj kesh (lovushka 7.4): odinochnoe sravnenie na etoj modeli nedejstvitelno, ta
#    zhe komanda davala 2,97 i 6,01 tok/s podrjad. Poetomu plechi cheredujutsja i krug
#    povtorjaetsja, a razbros pechataetsja rjadom so srednim.
#
# 2. No cheredovanie zdes SAMO vnositj oshibku, i eto tozhe izmereno: plechi s raznymi
#    rabochimi naborami travjat drug drugu kesh. Plecho s hranilishchem derzhit 20 GiB
#    privatnoj pamjati, plecho bez nego - te zhe bajty v kesha; posle pereklyuchenija
#    pervyj progon platit za vytesnenie chuzhogo nabora. Poetomu krome cheredovanija zdes est
#    KONTROL PODRJAD: dva odinakovyh plecha odno za drugim. Razbros v njom - eto razbros
#    bez vlijanija cheredovanija, i tolko s nim mozhno sravnivat effekt.
#
# 3. Assert-Model posle kazhdogo progona: odin raz binarnik vzjal vshituju model po umolchaniju
#    i otchitalsja polnym pravdopodobnym logom o DRUGOJ modeli.
#
# LLAMA_MMAP_PREFETCH=0 vo vseh progonah (kommit dvizhka 7497d394): bez nego zagruzchik zovjot
# PrefetchVirtualMemory na ves fajl i nabivaet kesh statikoj, kotoraja posle podjoma na kartu
# v OZU ne nuzhna.

param(
    [string] $Model  = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
    [string] $Prompt = 'D:\MemeX\results\prompt_micro.txt',
    [int]    $Rounds = 2,
    [int]    $Gen    = 64,
    [int]    $Tokens = 32,
    [string] $Cap    = 'auto',          # 'auto' ili chislo
    [int]    $Reserve = 2048,           # MiB, ne zanimat pri auto
    [string] $Prior  = '',
    [switch] $Repack,                   # tretje plecho: hranilishche + repak v _R4
    [switch] $NoCard,                   # bez --gpu-static-layers (dlja IQ4_XS, esli statika ne vlezaet)
    [string] $OutDir = 'D:\MemeX\results\step4_ab'
)

. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Path $OutDir -Force -EA SilentlyContinue | Out-Null

function Free-GiB {
    [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2)
}

# NE $Args: eto AVTOMATICHESKAJA peremennaja PowerShell, i vnutri funkcii ona derzhit
# NESVJAZANNYE argumenty, to est pustotu.
function Run-Arm([string]$name, [string[]]$extra, [string]$tag) {
    $log = Join-Path $OutDir ("{0}_{1}.log" -f $name, $tag)
    $a = @('-m', $Model, '-f', $Prompt, '--tokens', "$Tokens", '--gen', "$Gen",
           '-t', '8', '--no-repack', '--no-ref')
    if (-not $NoCard) { $a += @('--gpu-static', '--gpu-static-layers') }
    $a += $extra
    $env:LLAMA_MMAP_PREFETCH = '0'
    $free0 = Free-GiB
    $t0 = Get-Date
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $wall = ((Get-Date) - $t0).TotalSeconds
    $free1 = Free-GiB
    $txt = Get-Content -LiteralPath $log -Raw
    $want = Split-Path -Leaf $Model
    if ($txt -notmatch [regex]::Escape($want)) {
        Write-Host ("  OTKAZ: v loge net imeni " + $want + " - progon otbroshen")
        return $null
    }
    $m = [regex]::Match($txt, 'скорость генерации: наш\s+([0-9]+[.,][0-9]+)')
    if (-not $m.Success) {
        Write-Host "  OTKAZ: v loge net stroki skorosti - progon otbroshen"
        return $null
    }
    $v = [double]($m.Groups[1].Value -replace ',', '.')
    $mspt = if ($v -gt 0) { 1000.0 / $v } else { 0.0 }
    # Sinhronnye promahi i mjagkie/zhjostkie promahi stranic - iz mashinochitaemoj stroki.
    $miss = -1.0; $mssync = -1.0; $hits = -1.0
    $es = [regex]::Match($txt, 'ESTORE_AB .*miss_per_tok\s+([0-9.]+)\s+ms_sync_per_tok\s+([0-9.]+)')
    if ($es.Success) {
        $miss = [double]$es.Groups[1].Value
        $mssync = [double]$es.Groups[2].Value
    }
    $hm = [regex]::Match($txt, 'ESTORE_AB .*hits\s+([0-9.]+)')
    if ($hm.Success) { $hits = 100.0 * [double]$hm.Groups[1].Value }
    $pf = -1
    $pm = [regex]::Match($txt, 'promahov\s+страниц за фазу\s+(\d+)')
    if (-not $pm.Success) { $pm = [regex]::Match($txt, 'promahov[^\d]*(\d+)\s*$') }
    if ($pm.Success) { $pf = [int64]$pm.Groups[1].Value }
    $ids = [regex]::Match($txt, 'наши id:([^\r\n]*)')
    Write-Host ("  {0} [{1}]: {2:N4} tok/s = {3:N1} ms/token, nastennoe {4:N0} s, svobodno {5} -> {6} GiB" -f `
        $name, $tag, $v, $mspt, $wall, $free0, $free1)
    if ($miss -ge 0) {
        Write-Host ("      popadanij {0:N3}%, sinhronnyh promahov {1:N3}/token = {2:N2} ms/token" -f $hits, $miss, $mssync)
    }
    return [pscustomobject]@{
        arm = $name; tag = $tag; toks = $v; mspt = $mspt; wall = $wall
        miss = $miss; mssync = $mssync; hits = $hits
        ids = $(if ($ids.Success) { $ids.Groups[1].Value.Trim() } else { '' })
    }
}

$storeArgs = @()
if ($Cap -eq 'auto') {
    $storeArgs += @('--expert-store-auto', '--expert-store-reserve', "$Reserve")
} else {
    $storeArgs += @('--expert-store', $Cap)
}
if ($Prior -ne '') { $storeArgs += @('--expert-prior', $Prior) }

if (-not (Take-Machine -Who 'step4-ab' -TimeoutMin 300)) {
    Write-Output 'mashinu ne dali'
    exit 1
}
$res = @()
for ($r = 1; $r -le $Rounds; $r++) {
    if ($r % 2 -eq 1) {
        $res += Run-Arm 'mmap'  @()         "r$r"
        $res += Run-Arm 'store' $storeArgs  "r$r"
        if ($Repack) { $res += Run-Arm 'store_repack' ($storeArgs + '--expert-store-repack') "r$r" }
    } else {
        if ($Repack) { $res += Run-Arm 'store_repack' ($storeArgs + '--expert-store-repack') "r$r" }
        $res += Run-Arm 'store' $storeArgs  "r$r"
        $res += Run-Arm 'mmap'  @()         "r$r"
    }
}
# KONTROL PODRJAD: dva odinakovyh plecha odno za drugim, oba plecha. Razbros zdes - eto
# razbros samogo plecha; razbros vyshe vkljuchaet cenu pereklyuchenija rabochego nabora.
$res += Run-Arm 'mmap'  @()        'podryad1'
$res += Run-Arm 'mmap'  @()        'podryad2'
$res += Run-Arm 'store' $storeArgs 'podryad1'
$res += Run-Arm 'store' $storeArgs 'podryad2'
Free-Machine

Write-Output ''
function Summ([string]$arm, [string]$filter) {
    $rows = @($res | Where-Object { $_ -and $_.arm -eq $arm -and $_.tag -like $filter })
    if ($rows.Count -eq 0) { Write-Output ("{0} [{1}]: ni odnogo godnogo progona" -f $arm, $filter); return }
    $v = @($rows | ForEach-Object { $_.toks })
    $avg = ($v | Measure-Object -Average).Average
    $spread = if ($avg -ne 0) { (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $avg * 100 } else { 0 }
    $ms = if ($avg -gt 0) { 1000.0 / $avg } else { 0 }
    $mi = @($rows | Where-Object { $_.miss -ge 0 } | ForEach-Object { $_.miss })
    $mtxt = if ($mi.Count -gt 0) { '  promahov/token ' + ('{0:N3}' -f (($mi | Measure-Object -Average).Average)) } else { '' }
    Write-Output ("{0} [{1}]: {2}  srednee {3:N4} tok/s = {4:N1} ms/token  razbros {5:N1}%{6}" -f `
        $arm, $filter, (($v | ForEach-Object { '{0:N4}' -f $_ }) -join ' / '), $avg, $ms, $spread, $mtxt)
}
foreach ($arm in @('mmap', 'store', 'store_repack')) {
    Summ $arm 'r*'
    Summ $arm 'podryad*'
}
# Tokeny: plechi objazany davat odnu i tu zhe posledovatelnost (krome repaka - on menjaet bajty).
$ids = @{}
foreach ($r in $res) { if ($r) { if (-not $ids.ContainsKey($r.arm)) { $ids[$r.arm] = @() }; $ids[$r.arm] += $r.ids } }
Write-Output ''
foreach ($arm in $ids.Keys) {
    $u = @($ids[$arm] | Where-Object { $_ -ne '' } | Select-Object -Unique)
    Write-Output ("{0}: razlichnyh posledovatelnostej tokenov {1}" -f $arm, $u.Count)
}
$mm = @($ids['mmap'] | Where-Object { $_ -ne '' } | Select-Object -Unique)
$st = @($ids['store'] | Where-Object { $_ -ne '' } | Select-Object -Unique)
if ($mm.Count -eq 1 -and $st.Count -eq 1) {
    Write-Output ("mmap protiv hranilishcha: tokeny {0}" -f ($(if ($mm[0] -eq $st[0]) { 'TE ZHE' } else { 'RAZOSHLIS - eto defekt, a ne uskorenie' })))
}
