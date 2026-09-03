# SHAG 1 plana "Coder Next na slabom zheleze": nol koda.
#
# Odin skript, potomu chto zamok mashiny derzhitsja PROCESSOM (PID v .machine.lock). Vzjat ego v
# odnom pwsh i merit v drugom nelzja: pervyj process zavershaetsja, zamok schitaetsja mjortvym,
# i sosed spokojno startuet poverh zamera. Poetomu kopija, sled i A/B - vnutri odnogo procesa.
#
# Chto delaet po porjadku:
#   B) kopiruet IQ3_XXS s mehanicheskogo D: na SSD C:, robocopy /J - BEZ bufferizacii, chtoby
#      kopija ne nabila stranichnyj kesh i ne otravila A/B nizhe;
#   S) korotkij dymovoj prohod - proverka, chto argumenty doshli i model TA;
#   C) snimaet sled marshrutizacii na 1900 tokenov s kopii na C:;
#   D) A/B skorosti C: protiv D:, plechi CHEREDUJUTSJA po tri kruga - odinochnyj A/B na etoj
#      modeli nedejstvitelen, ona ne vlezaet v OZU i vtoroj prohod chitaet kesh pervogo.
#
# POCHEMU EST Assert-Model. Pervaja versija etogo skripta nazvala parametr funkcii $Args - a eto
# AVTOMATICHESKAJA peremennaja PowerShell, i vnutri funkcii ona derzhit NESVJAZANNYE argumenty,
# to est pustotu. `& $EXE @Args` zapustil binarnik BEZ argumentov, a tot molcha vzjal vshituju
# model po umolchaniju (Qwen3-Coder-30B-A3B, arhitektura qwen3moe, 128 ekspertov) i otschitalsja
# pravdopodobnym logom. Eto ta zhe lovushka 7.7: opcija, kotoruju nelzja ispolnit, byla
# proignorirovana vmesto otkaza vsluh. Poetomu posle KAZHDOGO prohoda skript chitaet iz loga imja
# fajla, kotoryj realno otkryl zagruzchik, i sveriaet ego s tem, chto prosili.
#
# Chego skript NE delaet i govorit ob etom vsluh:
#   - ne sbrasyvaet stranichnyj kesh mezhdu prohodami (RAMMap na mashine net);
#   - ne sveriaet hesh kopii, tolko dlinu v bajtah - celostnost proveriaet sam zagruzchik.

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

$EXE   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MOD_D = 'D:\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
$MOD_C = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
$P2000 = 'D:\MemeX\results\prompt_2000.txt'
$PMICR = 'D:\MemeX\results\prompt_micro.txt'
$RES   = 'D:\MemeX\results'
$PROG  = "$RES\step1_progress.log"

Remove-Item -LiteralPath $PROG -Force -ErrorAction SilentlyContinue
function Say([string]$s) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $s
    Write-Host $line
    Add-Content -LiteralPath $PROG -Value $line -Encoding utf8
}

# Zapusk binarnika s progressivnym logom. stderr slivaetsja v stdout: chast otchjota dvizhka
# idjot imenno tuda, i teriat ejo znachit teriat stroku "USTROJSTVO OTKAZALO".
# Out-Null v konce - chtoby vyvod exe NE stal vozvrashchaemym znacheniem funkcii.
function Run-Exe {
    param([string[]]$ExeArgs, [string]$LogFile)
    Add-Content -LiteralPath $PROG -Value ('    komanda: ' + ($ExeArgs -join ' ')) -Encoding utf8
    & $EXE @ExeArgs 2>&1 | ForEach-Object { $_.ToString() } |
        Tee-Object -FilePath $LogFile | Out-Null
    return $LASTEXITCODE
}

# Kakoj fajl realno otkryl zagruzchik. Pustaja strka = sovpalo.
function Assert-Model {
    param([string]$LogFile, [string]$WantPath)
    if (-not (Test-Path -LiteralPath $LogFile)) { return 'loga net vovse' }
    $m = Select-String -LiteralPath $LogFile -Pattern 'loaded meta data .* from (.+\.gguf)' |
         Select-Object -First 1
    if (-not $m) { return 'v logu net stroki zagruzchika s putjom modeli' }
    $got  = $m.Matches[0].Groups[1].Value.Trim().Replace('/', '\')
    $want = [IO.Path]::GetFileName($WantPath)
    if ([IO.Path]::GetFileName($got) -ne $want) { return ("otkryta CHUZHAJA model " + $got + " vmesto " + $want) }
    return ''
}

# Odna cifra iz mashinochitaemoj stroki. Imenno iz nejo, a ne iz cirillicheskoj vyshe: cirillica
# zavisit ot kodovoj stranicy peredirekta, i na etom proekte uzhe dvazhdy terjalis replikacii.
function Get-TokS([string]$LogFile) {
    $m = Select-String -LiteralPath $LogFile -Pattern 'STATIC_AB our_tok_s ([0-9.]+)' |
         Select-Object -Last 1
    if ($m) { return [double]$m.Matches[0].Groups[1].Value }
    return [double]::NaN
}

. C:\Users\User11\Desktop\MemeX\bench\lock.ps1

Say 'zamok: proshu mashinu'
if (-not (Take-Machine -Who 'step1' -TimeoutMin 300)) {
    Say 'MASHINU NE POLUCHIL za 300 min - nichego ne izmereno'
    exit 1
}
Say ('zamok vzjat, PID ' + $PID)

try {
    # ---------------------------------------------------------------- B: kopija na SSD
    $srcLen = (Get-Item -LiteralPath $MOD_D).Length
    Say ("B: istochnik $MOD_D, $srcLen bajt (" + [math]::Round($srcLen/1GB,3) + ' GiB)')
    $needCopy = $true
    if (Test-Path -LiteralPath $MOD_C) {
        $dl = (Get-Item -LiteralPath $MOD_C).Length
        if ($dl -eq $srcLen) { Say "B: kopija uzhe est, dlina $dl = $srcLen - kopirovanie propushcheno"; $needCopy = $false }
        else { Say "B: kopija est, no dlina $dl != $srcLen - perekopiruju" }
    }
    if ($needCopy) {
        Say ('B: na C: svobodno ' + [math]::Round((Get-PSDrive C).Free/1GB,2) + ' GiB do kopii')
        $t0 = Get-Date
        # /J - nebufferizovannyj vvod-vyvod. Ne skorost radi: bufferizovannaja kopija 26,5 GiB
        # ostavljaet v stranichnom keshe imenno tot fajl, kotoryj potom uchastvuet v A/B.
        robocopy 'D:\' 'C:\models' 'Qwen3-Coder-Next-UD-IQ3_XXS.gguf' /J /NFL /NDL /NP /NJH /NJS /R:1 /W:5 |
            Out-File -FilePath "$RES\step1_copy.log" -Encoding utf8
        $rc = $LASTEXITCODE
        $dt = ((Get-Date) - $t0).TotalSeconds
        Say ("B: robocopy kod $rc, " + [math]::Round($dt,1) + ' s, ' + [math]::Round($srcLen/1MB/$dt,1) + ' MB/s')
        if ($rc -ge 8) { Say 'B: KOPIJA NE UDALAS'; throw 'copy failed' }
        $dstLen = (Get-Item -LiteralPath $MOD_C).Length
        Say "B: kopija $dstLen bajt, istochnik $srcLen bajt"
        if ($dstLen -ne $srcLen) { Say 'B: DLINA NE SOSHLAS'; throw 'size mismatch' }
        Say ('B: na C: ostalos ' + [math]::Round((Get-PSDrive C).Free/1GB,2) + ' GiB')
    }

    # ------------------------------------------------- S: dymovoj prohod, proverka argumentov
    Say 'S: dymovoj prohod - doshli li argumenty i ta li model'
    $null = Run-Exe -ExeArgs @('-m',$MOD_C,'-f',$PMICR,'--tokens','16','--gen','1','-t','8',
                               '--no-repack','--no-ref') -LogFile "$RES\step1_smoke.log"
    $bad = Assert-Model "$RES\step1_smoke.log" $MOD_C
    if ($bad) { Say ('S: ' + $bad + ' - DALSHE NE IDU'); throw 'wrong model' }
    Say ('S: model ta, ' + (Get-TokS "$RES\step1_smoke.log") + ' tok/s na dymovom (v A/B ne idjot)')

    # ---------------------------------------------------------------- C: sled marshrutizacii
    if (-not (Test-Path -LiteralPath $P2000)) { Say "C: promta $P2000 net"; throw 'no prompt' }
    Say ('C: sled, promt ' + $P2000 + ', ' + (Get-Item -LiteralPath $P2000).Length + ' bajt')
    $env:MEMEX_EXPERT_COVERAGE = '1'
    $env:MEMEX_EXPERT_TRACE    = "$RES\route_trace.bin"
    # MEMEX_MTP_OVERLAP - ne po zhelaniju, a po neobhodimosti: v binarnike ot 3 sentiabria blok
    # zapisi sleda vlozhen vnutr imenno etoj proverki, i bez nejo sled ne pishetsja vovse.
    $env:MEMEX_MTP_OVERLAP     = '1'
    Remove-Item -LiteralPath "$RES\route_trace.bin" -Force -ErrorAction SilentlyContinue
    $t0 = Get-Date
    $rc = Run-Exe -ExeArgs @('-m',$MOD_C,'-f',$P2000,'--tokens','1900','--gen','2','-t','8',
                             '--no-repack','--no-ref','--prefill-chunk','128') -LogFile "$RES\route_trace_run.log"
    Say ('C: kod vozvrata ' + $rc + ', ' + [math]::Round(((Get-Date)-$t0).TotalMinutes,2) + ' min')
    Remove-Item Env:MEMEX_EXPERT_COVERAGE, Env:MEMEX_EXPERT_TRACE, Env:MEMEX_MTP_OVERLAP -ErrorAction SilentlyContinue
    $bad = Assert-Model "$RES\route_trace_run.log" $MOD_C
    if ($bad) { Say ('C: ' + $bad + ' - SLED NEDEJSTVITELEN') }
    elseif (Test-Path -LiteralPath "$RES\route_trace.bin") {
        Say ('C: sled ' + (Get-Item -LiteralPath "$RES\route_trace.bin").Length + ' bajt')
        python C:\Users\User11\Desktop\MemeX\bench\route_predict.py "$RES\route_trace.bin" 2>&1 |
            ForEach-Object { $_.ToString() } | Tee-Object -FilePath "$RES\route_predict_base.txt" | Out-Null
        Say 'C: route_predict.py otschitalsja v route_predict_base.txt'
    } else {
        Say 'C: SLEDA NET - fajl ne sozdan'
    }

    # ---------------------------------------------------------------- D: A/B skorosti C: vs D:
    # Plechi cheredujutsja, tri kruga. Pervyj prohod kazhdogo plecha - "holodnyj": kesh nabit
    # predydushchim plechom, a ne svoim.
    $rows = @()
    for ($k = 1; $k -le 3; $k++) {
        foreach ($arm in @('C','D')) {
            $mod = if ($arm -eq 'C') { $MOD_C } else { $MOD_D }
            $lf  = "$RES\step1_ab_${arm}_$k.log"
            Say "D: krug $k, plecho $arm"
            $t0 = Get-Date
            $null = Run-Exe -ExeArgs @('-m',$mod,'-f',$PMICR,'--tokens','32','--gen','8','-t','8',
                                       '--no-repack','--no-ref') -LogFile $lf
            $sec = [math]::Round(((Get-Date)-$t0).TotalSeconds,1)
            $bad = Assert-Model $lf $mod
            if ($bad) { Say ("D: krug $k plecho $arm - " + $bad + ' - ZNACHENIE OTBROSHENO'); continue }
            $ts = Get-TokS $lf
            Say ("D: krug $k plecho $arm -> " + $ts + " tok/s (" + $sec + ' s na prohod)')
            $rows += [pscustomobject]@{ krug = $k; plecho = $arm; tok_s = $ts; sec = $sec }
        }
    }
    $rows | Export-Csv -LiteralPath "$RES\step1_ab.csv" -NoTypeInformation -Encoding utf8
    Say 'D: svodka'
    foreach ($arm in @('C','D')) {
        $v = @($rows | Where-Object { $_.plecho -eq $arm -and -not [double]::IsNaN($_.tok_s) } |
               ForEach-Object { $_.tok_s })
        if ($v.Count -eq 0) { Say "D: plecho $arm - ni odnogo dejstvitelnogo chisla"; continue }
        $mean = ($v | Measure-Object -Average).Average
        $mx = ($v | Measure-Object -Maximum).Maximum
        $mn = ($v | Measure-Object -Minimum).Minimum
        $spr = if ($mean -ne 0) { 100.0 * ($mx - $mn) / $mean } else { 0 }
        Say ("D: plecho $arm  " + (($v | ForEach-Object { $_.ToString('F4') }) -join ' / ') +
             '  srednee ' + $mean.ToString('F4') + ' tok/s  razbros ' + $spr.ToString('F1') + '%')
    }
    Say 'GOTOVO'
}
catch { Say ('OSHIBKA: ' + $_.Exception.Message) }
finally { Free-Machine; Say 'zamok otpushchen' }
