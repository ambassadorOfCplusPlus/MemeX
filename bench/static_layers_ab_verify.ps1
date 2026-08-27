# Dva plecha proverki, karta i processor, v odnom zapuske i s odinakovym --probe all.
#
# ZACHEM IMENNO TAK, i eto glavnoe v etom fajle.
#
# Rjad l_out-0..46 v pervom progone rastjol monotonno: 0.0489% -> 0.9954%. Eto v tochnosti
# podpis nakoplenija ot perestanovki slozhenij, na kotoroj proekt uzhe gorel. No prezhde chem
# iskat prichinu, nado otvetit na vopros deshevle: A NASHA LI ETO OSHIBKA VOOBSHCHE.
#
# Put sloev na karte - TOLKO dekod (n_tokens == 1). Prefill mnogotokennyj, u nego drugaja
# forma grafa, i build_step ostavljaet ego celikom na hoste. A l_out-N pechataet imenno
# sravnenie PREFILLA. Znachit rjad l_out ne dolzhen zavisit ot flaga vovse - i eto proverjaemo
# pobitovo: dva plecha, odna komanda, otlichie v odnom flage. Esli rjady sovpadut do poslednej
# cifry, rost s glubinoj prinadlezhit CPU-putju dvizhka i suschestvoval do karty; togda
# kontrolem dlja karty sluzhat stroki "shag N: L2" iz --decode-check, a ne l_out.
#
# Esli zhe rjady razojdutsja - flag vlijaet na to, na chto vlijat ne mozhet, i eto nahodka
# sama po sebe, kotoruju nado iskat do ljubogo zamera skorosti.
param(
    [string]$Model  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf',
    [int]   $Tokens = 12,
    [int]   $Steps  = 6,
    [int]   $Threads = 8,
    [int]   $LimitMin = 18
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$LOG = 'D:\MemeX\results\static_layers_ab_verify.log'
$PFILE = 'D:\MemeX\results\prompt_short.txt'

function Say($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)
    Write-Host $line
    Add-Content -LiteralPath $LOG -Value $line -Encoding UTF8
}

$null = & $EXE --version 2>&1
if ($LASTEXITCODE -ne 0) { Say ("exe ne zapuskaetsja, kod " + $LASTEXITCODE); exit 1 }

function RunOnce($tag, [string[]]$extra) {
    $so = "D:\MemeX\results\_slab_$tag.out"
    $a = @('-m', $Model, '-f', $PFILE, '--tokens', "$Tokens", '-t', "$Threads",
           '--decode-check', "$Steps", '--probe', 'all', '--no-repack') + $extra
    $proc = $null
    try {
        $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { Say ("ne zapustilsja: " + $_.Exception.Message); return $null }
    if ($null -eq $proc) { Say 'Start-Process nichego ne vernul'; return $null }
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) {
        Say "$tag ne uspel za $LimitMin min - ubivaju"
        try { $proc.Kill() } catch {}
        return $null
    }
    Say "$tag zakonchil, kod $($proc.ExitCode)"
    return $so
}

Say 'berjom mashinu pod dvuhplechevuju proverku'
if (-not (Take-Machine -Who 'static-layers-ab-verify' -TimeoutMin 60)) { Say 'mashinu ne poluchili'; exit 1 }
try {
    foreach ($arm in @(@{t='cpu'; e=@()}, @{t='card'; e=@('--gpu-static-layers')})) {
        $out = RunOnce $arm.t $arm.e
        if (-not $out) { continue }
        Say ("--- plecho " + $arm.t + " ---")
        Get-Content -LiteralPath $out -Encoding UTF8 |
            Select-String -Pattern 'шаг +\d+ \(позиция|итог:|лучший токен|na odno peresechenie|peresechenij|na tokjen|kesh prompta|USTROJSTVO|vsego .* MiB v videopamjati' |
            ForEach-Object { Say ("  " + $_.Line.Trim()) }
    }
    # Pobitovoe sravnenie rjada l_out mezhdu plechami. Imenno eto otvechaet na vopros, chja
    # oshibka rastjot s glubinoj, i otvechaet odnoznachno: stroki libo sovpadajut, libo net.
    $cl = @(Get-Content -LiteralPath 'D:\MemeX\results\_slab_cpu.out'  -Encoding UTF8 |
            Select-String -Pattern '^\s+l_out-' | ForEach-Object { $_.Line.Trim() })
    $kl = @(Get-Content -LiteralPath 'D:\MemeX\results\_slab_card.out' -Encoding UTF8 |
            Select-String -Pattern '^\s+l_out-' | ForEach-Object { $_.Line.Trim() })
    Say ("--- rjad l_out: strok u cpu " + $cl.Count + ", u karty " + $kl.Count + " ---")
    $diff = 0
    for ($i = 0; $i -lt [math]::Min($cl.Count, $kl.Count); $i++) {
        if ($cl[$i] -ne $kl[$i]) { $diff++; Say ("  RAZNICA: cpu  " + $cl[$i]); Say ("           karta " + $kl[$i]) }
    }
    if ($diff -eq 0 -and $cl.Count -gt 0) {
        Say '  rjad l_out SOVPAL POSTROCHNO: prefill idjot na hoste v oboih plechah, i rost s'
        Say '  glubinoj prinadlezhit CPU-putju dvizhka, a ne karte. Kontrol dlja karty - stroki'
        Say '  "shag N: L2" vyshe, i ih nado sravnivat mezhdu plechami.'
    } else {
        Say ('  STROK S RAZNICEJ: ' + $diff + ' - flag vlijaet na prefill, chego on delat ne dolzhen')
    }
} finally {
    Free-Machine
    Say 'mashina osvobozhdena'
}
