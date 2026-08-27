# ADAPTACIJA NABORA PRI RAZNOM PERIODE OBNOVLENIJA. Ne skorost - POVEDENIE.
#
# ZACHEM ETO OTDELNYJ SKRIPT. Zamorozhennyj nabor izmerilsja samym bystrym plechom (+10,5% k
# tokjenu pri poterie 2,25 punkta popadanij), i ottuda ochevidnyj shag - ne morozit naveki, a
# udlinit period obnovlenija s 3 do 32-64. No u etogo shaga est lovushka, kotoruju svip skorosti
# NE lovit: period, kotoryj pokupaet skorost tem, chto nabor perestajot adaptirovatsja, - eto
# zamorozka s lishnimi shagami. Srednaja dolja popadanij za progon ejo ne razlichaet vovse:
# na odnorodnom promptе nabor, kotoryj adaptiruetsja mgnovenno, i nabor, kotoryj ne
# adaptiruetsja nikogda, dajut odnu i tu zhe srednjuju.
#
# CHTO RAZLICHAET: prompt, kotoryj MENJAET DOMEN posredine, i dolja popadanij, razreshjonnaja po
# vremeni. Sdvig raspredelenija u nas izmeren ranee - nabor, sobrannyj na kode, berjot 24,1%
# na russkom tekste protiv 25,0% u SLUCHAJNOGO nabora, to est na chuzhom domene on ne luchshe
# sluchajnogo. Znachit provalu est gde byt, i on dolzhen byt krupnym.
#
# GDE ZHIVJOT PEREKLJUCHENIE. Ne na generacii: ona zhadnaja i samokormjashchaja, ejo domen - tot,
# v kotorom ejo ostavil prompt. A prompt my pishem sami. Progrev nabora na promptе obhodit
# nastojashchie vybory marshrutizatora prefilla token za tokenom cherez te zhe observe/end_token,
# chto i generacija (memex-fwd.cpp), tak chto eto ne model povedenija, a to zhe povedenie.
#
# ETO NE ZAMER VREMENI, poetomu po pravilu 47 zagruzhennaja mashina ego isportit ne mozhet:
# rezultat - kakie eksperty vybrany, a ne kogda. Zamok vsjo ravno berjotsja - model est 15 GB.
#
# PREDSKAZANIE, ZAPISANNOE DO PROGONA.
#
# Mehanizm, iz kotorogo ono sdelano: okno LFU - 64 tokena. Cherez 64 tokena posle perekljuchenija
# v kolce ne ostajotsja ni odnoj vyborki starogo domena, znachit rekomendacija LFU k etomu momentu
# celikom prinadlezhit novomu domenu. Period tolko zaderzhivaet primenenie rekomendacii, i ne
# bolshe chem na odin svoj period. Otsjuda vremja vosstanovlenija = OKNO + do odnogo perioda:
#
#     period  3   vosstanovlenie za ~64-70 tokenov posle perekljuchenija (~22 perioda)
#     period 16   ~80  (5 periodov)
#     period 32   ~96  (3 perioda)
#     period 64   ~128 (2 perioda)
#     never       NE vosstanavlivaetsja vovse - eto kontrol
#
# SILNOE UTVERZHDENIE, kotoroe iz etogo sleduet i kotoroe i proverjaetsja: pri P <= 64 uzkoe
# mesto adaptacii - OKNO, a ne period. Znachit P=64 dolzhen adaptirovatsja ne bolshe chem vdvoe
# medlennee P=3. Esli P=64 trebuet 256+ tokenov, to est chetyre-pjat periodov, - predskazanie
# oprovergnuto, uzkoe mesto v periode, i 64 slishkom mnogo pri ljubom vyigryshe v tok/s.
#
# GLUBINA PROVALA. Emkost 12 iz 128 = 9,4%, to est sluchajnyj pol popadanij 9,4%; ustojchivyj
# uroven na odnorodnom tekste ~70%. Nabor s koda na russkom - ne luchshe sluchajnogo, znachit
# zhdu proval do 10-20% i vozvrat k 60-70%.
#
# KONTROL 'never' (period 100000) objazatelen i vot pochemu: esli on POKAZHET vosstanovlenie,
# to to, chto ja chitaju kak adaptaciju, - artefakt (naprimer prosto shodstvo domenov ili
# progrev okna), i vsja tablica nichego ne znachit. Plecho, kotoroe objazano NE dvinutsja
# (pravilo 69), stoit odnogo progona.
#
# Napisano latinicej: PowerShell zdes chitaet fajl bez metki kak ANSI.
param(
    [int]    $Tokens  = 1600,
    [int]    $Threads = 8,
    [int]    $Seg     = 16,
    [int]    $Cap     = 12,
    [switch] $External
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$SNAP   = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-adapt-snap.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PCODE  = 'D:\MemeX\results\prompt_code.txt'
$PSW    = 'D:\MemeX\results\prompt_switch.txt'
$LOG    = 'D:\MemeX\results\period_adapt.log'

function Say($m)  { $l = ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }
function Note($m) { $l = ("  " + $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

# $proc, nikogda $p (pravilo 45).
function RunOnce($tag, [string]$prompt, [int]$period, [int]$limitSec) {
    $so = "D:\MemeX\results\_adapt_$tag.out"
    $a = @('-m', $MODEL, '-f', $prompt, '--tokens', "$Tokens", '-t', "$Threads",
           '--gen', '2', '--no-repack',
           '--resident', "$Cap", '--resident-window', '64', '--resident-budget', '8',
           '--resident-period', "$period", '--resident-trace', "$Seg")
    $proc = $null
    try {
        $proc = Start-Process -FilePath $SNAP -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { return @{ err = ('ne zapustilsja: ' + $_.Exception.Message) } }
    if ($null -eq $proc) { return @{ err = 'Start-Process nichego ne vernul' } }
    $null = $proc.Handle
    if (-not $proc.WaitForExit($limitSec * 1000)) {
        Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
        return @{ err = 'tajm-aut' }
    }
    $out = @()
    if (Test-Path $so) { $out += Get-Content -LiteralPath $so -Encoding UTF8 }
    if (Test-Path "$so.err") { $out += Get-Content -LiteralPath "$so.err" -Encoding UTF8 }
    $res = @{ err = ''; seg = @() }
    # Pravilo 68: bez podtverzhdenija nastrojki plecho ne plecho. Period pechataetsja v
    # zagolovke rezidentnogo nabora, i on chitaetsja obratno, a ne predpolagaetsja.
    $hdr = $out | Select-String -Pattern 'RSET_CFG ' | Select-Object -First 1
    if ($hdr -and $hdr.Line -match 'period (\d+) capacity (\d+) window (\d+)') {
        $res.period = [int]$Matches[1]; $res.cap = [int]$Matches[2]; $res.win = [int]$Matches[3]
    }
    $tk = $out | Select-String -Pattern 'RSET_WARM tokens (\d+)' | Select-Object -First 1
    if ($tk -and $tk.Line -match 'RSET_WARM tokens (\d+) hits ([\d.]+)') {
        $res.ntok = [int]$Matches[1]; $res.warm_hits = [double]$Matches[2]
    }
    foreach ($m in ($out | Select-String -Pattern '^RSET_SEG phase warm ')) {
        if ($m.Line -match 'tok (\d+) hits ([\d.]+) promo (\d+)') {
            $res.seg += @{ tok = [int]$Matches[1]; hits = [double]$Matches[2]; promo = [int]$Matches[3] }
        }
    }
    if ($res.seg.Count -eq 0) {
        $bad = $out | Select-String -Pattern 'not supported|failed|abort|assert|OTKAZALO|бессмысленно' |
               Select-Object -First 1
        $res.err = if ($bad) { $bad.Line.Trim() } else { "net strok RSET_SEG (exit $($proc.ExitCode))" }
    }
    return $res
}

("`n`n######## period adapt " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8
if (-not (Test-Path -LiteralPath $EXE)) { Note "net binarnika: $EXE"; exit 1 }
Copy-Item -LiteralPath $EXE -Destination $SNAP -Force
$null = & $SNAP --version *> $null
if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) { Note "snimok ne zapuskaetsja"; exit 1 }

if (-not $External) {
    Say 'berjom mashinu pod proverku adaptacii'
    if (-not (Take-Machine -Who 'period-adapt' -TimeoutMin 90)) { Note 'mashinu ne poluchili'; exit 1 }
}
try {
    # SNACHALA - gde stoit perekljuchenie. Odin progon na odnoj kodovoj polovine dajot chislo
    # tokenov v nej, i eto NEZAVISIMOE znanie o tochke pereloma: bez nego proval v serii
    # prishlos by tolkovat, a tolkovanie - to, na chjom etot proekt teriaet dni.
    Say 'gde perekljuchenie: tokeny odnoj kodovoj poloviny'
    $c = RunOnce 'codeonly' $PCODE 3 1200
    if ($c.err -ne '') { Note ('kodovaja polovina NE POSHLA: ' + $c.err); }
    $switch_at = if ($c.ContainsKey('ntok')) { $c.ntok } else { -1 }
    Note ("kodovaja polovina: $switch_at tokenov - PEREKLJUCHENIE ZDES")

    $arms = @(
        @{ t = 'p3';    p = 3 },
        @{ t = 'p16';   p = 16 },
        @{ t = 'p32';   p = 32 },
        @{ t = 'p64';   p = 64 },
        @{ t = 'never'; p = 100000 }
    )
    $store = @{}
    foreach ($arm in $arms) {
        Say ("period $($arm.p)")
        $r = RunOnce $arm.t $PSW $arm.p 1800
        if ($r.err -ne '') { Note ('NE POSHLO: ' + $r.err); continue }
        if (-not $r.ContainsKey('period') -or $r.period -ne $arm.p) {
            Note ("v otchjote period $($r.period), prosili $($arm.p) - VYBROSHENO (pravilo 68)")
            continue
        }
        $store[$arm.t] = $r
        Note ("tokenov v promptе $($r.ntok), emkost $($r.cap), okno $($r.win), srednee $('{0:N1}' -f $r.warm_hits)%")
        $line = ($r.seg | ForEach-Object { '{0:N0}' -f $_.hits }) -join ' '
        Note ("popadanija po otrezkam po $Seg tokenov: $line")
    }

    Say 'PROVAL I VOSSTANOVLENIE'
    Note ("perekljuchenie na tokene $switch_at; otrezki po $Seg tokenov")
    foreach ($arm in $arms) {
        if (-not $store.ContainsKey($arm.t)) { Note ("{0,-6} net dannyh" -f $arm.t); continue }
        $r = $store[$arm.t]
        $pre  = @($r.seg | Where-Object { $_.tok -le $switch_at -and $_.tok -gt [int]($switch_at/2) })
        $post = @($r.seg | Where-Object { $_.tok -gt $switch_at })
        if ($pre.Count -lt 2 -or $post.Count -lt 3) { Note ("{0,-6} otrezkov malo" -f $arm.t); continue }
        $plateau = ($pre | ForEach-Object { $_.hits } | Measure-Object -Average).Average
        $trough  = ($post | ForEach-Object { $_.hits } | Measure-Object -Minimum).Minimum
        # Vosstanovlenie: pervyj otrezok POSLE provala, dostigshij 90% ot doperekljuchennogo
        # urovnja i uderzhavshij ego na sledujushchem otrezke tozhe (odin otrezok mozhet
        # popast v urovent sluchajno).
        $need = 0.90 * $plateau
        $rec = -1
        for ($k = 0; $k -lt $post.Count - 1; ++$k) {
            if ($post[$k].hits -ge $need -and $post[$k+1].hits -ge $need) { $rec = $post[$k].tok; break }
        }
        $recTok = if ($rec -ge 0) { $rec - $switch_at } else { -1 }
        Note ("{0,-6} plato do {1,5:N1}%  proval {2,5:N1}%  vosstanovlenie za {3} tokenov {4}" -f
              $arm.t, $plateau, $trough, $recTok,
              $(if ($rec -lt 0) { '- NE VOSSTANOVILOS do konca prompta' } else { '' }))
    }
} finally {
    if (-not $External) { Free-Machine; Say 'mashina osvobozhdena' }
}
