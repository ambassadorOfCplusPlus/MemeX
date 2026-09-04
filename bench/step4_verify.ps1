# SVERKA SHAGA 4: rezidentnoe hranilishche ekspertov ne menjaet otvet modeli.
#
# Chto imenno proverjaetsja. Hranilishche podstavljaet v tri uzla mul_mat_id DRUGIE tenzory
# (sloty vmesto modelnyh) i DRUGIE identifikatory (slot vmesto id eksperta). Bajty vesov v
# slote - kopija bajtov modeli, tak chto arifmetika ta zhe; no oshibka na odin slot, poterja
# slota pod promah ili perestanovka nabora poserjod tokena dali by pravdopodobnye logity i
# drugoj tekst. Poetomu kriterij - TE ZHE TOKENY i TOT ZHE L2, chto u plecha bez hranilishcha
# na TOM ZHE binarnike.
#
# Plechi zdes NE cheredujutsja i eto naroschno: sverka - ne zamer skorosti, stranichnyj kesh
# na tokeny ne vlijaet.
#
# LLAMA_MMAP_PREFETCH=0 vo vseh progonah: bez nego zagruzchik zovjot PrefetchVirtualMemory na
# ves fajl (26,5 GiB), i eto i dolgo, i nabivaet kesh statikoj, kotoraja posle podjoma na
# kartu v OZU ne nuzhna (kommit dvizhka 7497d394).

param(
    [string] $Model  = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
    [string] $Prompt = 'D:\MemeX\results\prompt_micro.txt',
    [int]    $Tokens = 32,
    [int]    $Steps  = 16,
    # STROKOJ, a ne [int[]]: pri zapuske cherez `pwsh -File` argument "256,410" prihodit
    # odnoj strokoj, i PowerShell privodit ejo k CHISLU 256410 (zapjataja kak razdelitel
    # razryadov). Tak i sluchilos: progon poprosil C = 256410, poluchil C = 512 posle
    # obrezki po n_expert, zanjal 24,6 GiB i uvjol mashinu v podkachku.
    [string] $Caps   = '256,410',
    [switch] $Repack,
    [string] $Prior  = '',
    [string] $OutDir = 'D:\MemeX\results\step4'
)

. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Path $OutDir -Force -EA SilentlyContinue | Out-Null

function Run-Arm([string]$name, [string[]]$extra) {
    $log = Join-Path $OutDir ("verify_{0}.log" -f $name)
    $a = @('-m', $Model, '-f', $Prompt, '--tokens', "$Tokens", '--decode-check', "$Steps",
           '-t', '8', '--no-repack', '--gpu-static', '--gpu-static-layers') + $extra
    $env:LLAMA_MMAP_PREFETCH = '0'
    $t0 = Get-Date
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $wall = ((Get-Date) - $t0).TotalSeconds
    $txt = Get-Content -LiteralPath $log -Raw
    $want = Split-Path -Leaf $Model
    if ($txt -notmatch [regex]::Escape($want)) {
        Write-Host ("  OTKAZ: v loge net imeni " + $want + " - progon otbroshen")
        return $null
    }
    # LATINICEJ, a ne po russkoj stroke itoga: konsol pod Windows otdajot russkie stroki v
    # OEM-kodirovke, Set-Content sohranjaet ih kak est, i regexp po nim ne nahodit nichego -
    # progon chitaetsja kak "sverka ne sostojalas" pri polnom pravilnom loge. Odin raz na
    # etom uzhe poterjali progon.
    $m = [regex]::Match($txt, 'DECODE_CHECK agree (\d+) steps (\d+) worst_l2 ([0-9.]+) worst_step (-?\d+) ids([^

]*)')
    if (-not $m.Success) {
        Write-Host "  OTKAZ: v loge net stroki DECODE_CHECK - progon otbroshen"
        return $null
    }
    $agree = [int]$m.Groups[1].Value
    $steps = [int]$m.Groups[2].Value
    $l2    = [double]$m.Groups[3].Value
    $txtline = $m.Groups[5].Value.Trim()
    $es = [regex]::Match($txt, 'ESTORE_AB\s+(.*)')
    $ev = [regex]::Match($txt, 'ESTORE_VERIFY\s+(.*)')
    Write-Host ("  {0}: {1} iz {2} tokenov etalona, hudshij L2 {3:N4}%, nastennoe {4:N0} s" -f `
        $name, $agree, $steps, $l2, $wall)
    if ($es.Success) { Write-Host ("      " + $es.Groups[1].Value) }
    if ($ev.Success) { Write-Host ("      VERIFY " + $ev.Groups[1].Value) }
    return [pscustomobject]@{ arm = $name; agree = $agree; steps = $steps; l2 = $l2; text = $txtline }
}

if (-not (Take-Machine -Who 'step4-verify' -TimeoutMin 300)) {
    Write-Output 'mashinu ne dali'
    exit 1
}
$res = @()
$res += Run-Arm 'bez_hranilishcha' @()
foreach ($c in ($Caps -split ',' | ForEach-Object { [int]$_.Trim() })) {
    $extra = @('--expert-store', "$c")
    if ($Repack) { $extra += '--expert-store-repack' }
    if ($Prior -ne '') { $extra += @('--expert-prior', $Prior) }
    $nm = "C$c"
    if ($Repack) { $nm += '_repack' }
    $res += Run-Arm $nm $extra
}
Free-Machine

Write-Output ''
$base = $res | Where-Object { $_ -and $_.arm -eq 'bez_hranilishcha' } | Select-Object -First 1
if (-not $base) { Write-Output 'ETALONNOE PLECHO NE POLUCHILOS - sravnivat ne s chem'; exit 1 }
foreach ($r in $res) {
    if (-not $r -or $r.arm -eq 'bez_hranilishcha') { continue }
    $same_tok = ($r.text -eq $base.text)
    $same_l2  = ([math]::Abs($r.l2 - $base.l2) -lt 0.0000005)
    Write-Output ("{0}: tokeny {1}, hudshij L2 {2:N4}% protiv {3:N4}% - {4}" -f `
        $r.arm, ($(if ($same_tok) { 'TOT ZHE' } else { 'DRUGOJ' })), $r.l2, $base.l2,
        ($(if ($same_tok -and $same_l2) { 'SOSHLOS DO ZNAKA' } elseif ($same_tok) { 'tokeny te zhe, L2 otlichaetsja' } else { 'RASHOZHDENIE' })))
}
