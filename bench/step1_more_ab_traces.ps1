# SHAG 1, prodolzhenie: chistye krugi A/B + sledy marshrutizacii na DRUGIH tekstah.
#
# POCHEMU DOPOLNITELNYE KRUGI. Koordinator soznalsja, chto s 19:44 do 19:49 vne zamka u nego
# rabotal odnopotochnyj python (~100% odnogo jadra). V eto okno popali krugi 1 i 2 pervogo
# skripta, i oni ZAGRJAZNENY - v srednee ne idut. Zdes snimajutsja tri kruga zavedomo posle
# 19:49, pod zamkom.
#
# POCHEMU SLEDY DRUGIH TEKSTOV. 1,4% obrashchenij - PERVOE pojavlenie eksperta v dokumente;
# chastota po tekushchemu tekstu ih ne predskazyvaet v principe, potomu chto istorii po nim jeshchjo
# net. Chtoby izmerit zatravku s CHUZHOGO teksta, nuzhny sledy drugih tekstov.
#
# --tokens vybiraetsja ADAPTIVNO: snachala prosim 1900 (esli dvizhok obrezaet po dline promta -
# poluchim skolko est), i tolko esli sled ne zapisalsja - povtorjaem s ocenkoj po bajtam.
# Ugadyvat dlinu v tokenah po dline v bajtah zaranee nelzja: u koda i u russkogo teksta
# bajt-na-token raznyj, a promah v storonu bolshego stoit celogo lishnego prohoda.

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

$EXE   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MOD_D = 'D:\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
$MOD_C = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
$PMICR = 'D:\MemeX\results\prompt_micro.txt'
$RES   = 'D:\MemeX\results'
$PROG  = "$RES\step1_more_progress.log"

Remove-Item -LiteralPath $PROG -Force -ErrorAction SilentlyContinue
function Say([string]$s) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $s
    Write-Host $line
    Add-Content -LiteralPath $PROG -Value $line -Encoding utf8
}

function Run-Exe {
    param([string[]]$ExeArgs, [string]$LogFile)
    Add-Content -LiteralPath $PROG -Value ('    komanda: ' + ($ExeArgs -join ' ')) -Encoding utf8
    & $EXE @ExeArgs 2>&1 | ForEach-Object { $_.ToString() } |
        Tee-Object -FilePath $LogFile | Out-Null
    return $LASTEXITCODE
}

# Lovushka 7.7 v chistom vide: binarnik bez argumentov ne otkazyvaetsja, a beriot vshituju model
# po umolchaniju i otschitivaetsja pravdopodobnym logom. Poetomu imja fajla chitaetsja iz loga.
function Assert-Model {
    param([string]$LogFile, [string]$WantPath)
    if (-not (Test-Path -LiteralPath $LogFile)) { return 'loga net vovse' }
    $m = Select-String -LiteralPath $LogFile -Pattern 'loaded meta data .* from (.+\.gguf)' |
         Select-Object -First 1
    if (-not $m) { return 'v logu net stroki zagruzchika s putjom modeli' }
    $got  = $m.Matches[0].Groups[1].Value.Trim().Replace('/', '\')
    if ([IO.Path]::GetFileName($got) -ne [IO.Path]::GetFileName($WantPath)) {
        return ('otkryta CHUZHAJA model ' + $got)
    }
    return ''
}

function Get-TokS([string]$LogFile) {
    $m = Select-String -LiteralPath $LogFile -Pattern 'STATIC_AB our_tok_s ([0-9.]+)' |
         Select-Object -Last 1
    if ($m) { return [double]$m.Matches[0].Groups[1].Value }
    return [double]::NaN
}

. C:\Users\User11\Desktop\MemeX\bench\lock.ps1

Say 'zamok: proshu mashinu'
if (-not (Take-Machine -Who 'step1-more' -TimeoutMin 300)) {
    Say 'MASHINU NE POLUCHIL za 300 min - nichego ne izmereno'
    exit 1
}
Say ('zamok vzjat, PID ' + $PID)

try {
    # ------------------------------------------------ A/B: tri CHISTYH kruga, plechi cheredujutsja
    $rows = @()
    for ($k = 4; $k -le 6; $k++) {
        foreach ($arm in @('C','D')) {
            $mod = if ($arm -eq 'C') { $MOD_C } else { $MOD_D }
            $lf  = "$RES\step1_ab_${arm}_$k.log"
            $t0 = Get-Date
            $null = Run-Exe -ExeArgs @('-m',$mod,'-f',$PMICR,'--tokens','32','--gen','8','-t','8',
                                       '--no-repack','--no-ref') -LogFile $lf
            $sec = [math]::Round(((Get-Date)-$t0).TotalSeconds,1)
            $bad = Assert-Model $lf $mod
            if ($bad) { Say ("AB krug $k plecho $arm - " + $bad + ' - OTBROSHENO'); continue }
            $ts = Get-TokS $lf
            Say ("AB krug $k plecho $arm -> " + $ts + " tok/s (" + $sec + ' s na prohod)')
            $rows += [pscustomobject]@{ krug = $k; plecho = $arm; tok_s = $ts; sec = $sec }
        }
    }
    $rows | Export-Csv -LiteralPath "$RES\step1_ab_more.csv" -NoTypeInformation -Encoding utf8
    foreach ($arm in @('C','D')) {
        $v = @($rows | Where-Object { $_.plecho -eq $arm -and -not [double]::IsNaN($_.tok_s) } |
               ForEach-Object { $_.tok_s })
        if ($v.Count -eq 0) { Say "AB plecho $arm - ni odnogo dejstvitelnogo chisla"; continue }
        $mean = ($v | Measure-Object -Average).Average
        $mx = ($v | Measure-Object -Maximum).Maximum
        $mn = ($v | Measure-Object -Minimum).Minimum
        $spr = if ($mean -ne 0) { 100.0 * ($mx - $mn) / $mean } else { 0 }
        $sv = @($rows | Where-Object { $_.plecho -eq $arm } | ForEach-Object { $_.sec })
        Say ("AB plecho $arm  " + (($v | ForEach-Object { $_.ToString('F4') }) -join ' / ') +
             '  srednee ' + $mean.ToString('F4') + ' tok/s  razbros ' + $spr.ToString('F1') +
             '%  nastennoe ' + ($sv -join ' / ') + ' s')
    }

    # ------------------------------------------------ sledy na DRUGIH tekstah
    $jobs = @(
        @{ p = "$RES\prompt_code.txt"; o = "$RES\route_trace_code.bin"; l = "$RES\route_trace_code.log" },
        @{ p = "$RES\prompt_ru.txt";   o = "$RES\route_trace_ru.bin";   l = "$RES\route_trace_ru.log" },
        @{ p = "$RES\prompt_tech.txt"; o = "$RES\route_trace_tech.bin"; l = "$RES\route_trace_tech.log" }
    )
    foreach ($j in $jobs) {
        if (-not (Test-Path -LiteralPath $j.p)) { Say ('SLED: promta ' + $j.p + ' net - propushchen'); continue }
        $bytes = (Get-Item -LiteralPath $j.p).Length
        Say ('SLED: ' + [IO.Path]::GetFileName($j.p) + ', ' + $bytes + ' bajt')
        $env:MEMEX_EXPERT_COVERAGE = '1'
        $env:MEMEX_MTP_OVERLAP     = '1'
        $env:MEMEX_EXPERT_TRACE    = $j.o
        Remove-Item -LiteralPath $j.o -Force -ErrorAction SilentlyContinue
        # Popytka 1: prosim 1900 i smotrim, obrezhet li dvizhok po dline promta.
        $tk = 1900
        foreach ($attempt in 1,2) {
            $null = Run-Exe -ExeArgs @('-m',$MOD_C,'-f',$j.p,'--tokens',"$tk",'--gen','2','-t','8',
                                       '--no-repack','--no-ref','--prefill-chunk','128') -LogFile $j.l
            $bad = Assert-Model $j.l $MOD_C
            if ($bad) { Say ('SLED: ' + $bad + ' - SLED NEDEJSTVITELEN'); break }
            if (Test-Path -LiteralPath $j.o) { break }
            if ($attempt -eq 1) {
                # Ocenka po bajtam. 4,7 bajta na token izmereno na prompt_2000.txt (8863 bajta,
                # 1900 tokenov). Dlja koda i russkogo eto ocenka SVERHU po tokenam, to est
                # zapros zavedomo ne prevysit dlinu promta.
                $tk = [int][math]::Floor($bytes / 4.7)
                if ($tk -lt 64) { Say 'SLED: promt koroche 64 tokenov po ocenke - propushchen'; break }
                Say ("SLED: s --tokens 1900 sleda net, povtorjaju s --tokens $tk (ocenka po bajtam)")
            }
        }
        Remove-Item Env:MEMEX_EXPERT_COVERAGE, Env:MEMEX_EXPERT_TRACE, Env:MEMEX_MTP_OVERLAP -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $j.o) {
            $hdr = Select-String -LiteralPath $j.l -Pattern 'sled marshrutizacii zapisan: (.+)$' |
                   Select-Object -Last 1
            Say ('SLED: ' + [IO.Path]::GetFileName($j.o) + ' = ' +
                 (Get-Item -LiteralPath $j.o).Length + ' bajt; ' +
                 (if ($hdr) { $hdr.Matches[0].Groups[1].Value } else { 'zagolovok v logu ne najden' }))
        } else {
            Say ('SLED: ' + [IO.Path]::GetFileName($j.o) + ' NE ZAPISAN')
        }
    }
    Say 'GOTOVO'
}
catch { Say ('OSHIBKA: ' + $_.Exception.Message) }
finally { Free-Machine; Say 'zamok otpushchen' }
