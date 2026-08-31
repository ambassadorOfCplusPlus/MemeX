# Edinstvennyj sposob sobirat etot proekt. Cherez nego, a ne golym cmake.
#
# ZACHEM. Trizhdy iz build/bin/Release ischezala ggml.dll, i pervyj raz eto stoilo nochi: CMake
# schitaet celi gotovymi, obychnaja peresborka - pustyshka, a binarniki padajut na zagruzchike
# Windows DO pervoj stroki vyvoda. Logi prihodjat pustymi, i eto chitaetsja kak "progon ne dal
# dannyh", a ne "progon ne sostojalsja".
#
# PRICHINA najdena i ona neprijatnaja: --clean-first SNACHALA UDALJAET vsjo, chto cel proizvodit, i
# tolko potom sobiraet. To est lekarstvo, propisannoe posle pervoj avarii, stalo prichinoj vtoroj i
# tretjej - mezhdu udaleniem i pojavleniem derevo zavedomo slomano, i esli v eto okno sborku
# prervat (dvazhdy konchalas sessija, odin raz otkljuchali svet), ono takim i ostajotsja.
#
# TRI PRAVILA, kotorye etot skript ispolnjaet vmesto cheloveka:
#   1. Sobirat pod mashinnym zamkom. Polnaja sborka zanimaet chetyre jadra na desjat minut, i delat
#      eto pri svobodnom zamke - to zhe samoe, chto portit chuzhoj zamer molcha. Odin raz tak vyshlo.
#   2. Posle sborki proverjat ZAPUSKAEMOST, a ne kod vozvrata cmake. Sborka, zavershivshajasja
#      uspehom i ostavivshaja nezagruzhaemoe derevo, huzhe upavshej: otkaz vsplyvaet cherez tri shaga
#      v chuzhoj rabote.
#   3. --clean-first primenjat tolko k polnoj cepochke ggml -> llama -> binarniki, nikogda k odnoj
#      celi. Chistka odnoj celi garantiruet okno, v kotorom ostalnye ssylajutsja na udaljonnoe.
#
# Napisano latinicej namerenno: PowerShell na etoj mashine chitaet fajly bez metki kak ANSI, i
# kirillica v skripte lomaet razbor. Ostalnye skripty proekta po toj zhe prichine takie zhe.

param(
    [string[]]$Targets = @('llama-cli'),
    [string]  $Dir     = 'D:/MemeX/src/ik_llama.cpp/build',
    [switch]  $Clean,
    [int]     $Jobs    = 4,
    [int]     $LockMin = 120,
    [switch]  $NoLock
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$bin = Join-Path $Dir 'bin/Release'
function Say($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m) }

# Vyzov cherez -File peredajot spisok celej ODNOJ strokoj: "llama-cli,llama-moe-trace" prihodit kak
# odin element i uhodit v cmake kak imja nesushchestvujushchej celi. Cherez -Command tot zhe vyzov
# dajot massiv. Skript ne dolzhen zaviset ot togo, kak ego pozvali, poetomu razbor zdes.
$Targets = @($Targets | ForEach-Object { $_ -split ',' } | Where-Object { $_ -and $_.Trim() } |
             ForEach-Object { $_.Trim() })

# Zapuskaemost - edinstvennaja proverka, kotoroj mozhno verit. Kody, kotorye stoit uznavat v lico:
#   -1073741511  tochka vhoda ne najdena: DLL ne sootvetstvuet exe, to est peresobrali polovinu
#   -1073741515  DLL ne najdena vovse
function Test-Startable([string]$exe) {
    if (-not (Test-Path -LiteralPath $exe)) { return "net fajla" }
    $null = & $exe --version 2>&1
    switch ($LASTEXITCODE) {
        0           { return $null }
        -1073741511 { return "tochka vhoda ne najdena (DLL ne sootvetstvuet exe)" }
        -1073741515 { return "DLL ne najdena" }
        default     { return "kod vyhoda $LASTEXITCODE" }
    }
}

# Kod vozvrata otdajotsja cherez script-scope, a ne cherez return.
#
# V PowerShell funkcija vozvrashchaet VSJO, chto napisala v potok vyvoda, a ne tolko to, chto stoit
# posle return. Pervaja versija pechatala hvost sborki cherez Say vnutri funkcii - i $rc prihodil
# massivom iz etih strok plus chislo, tak chto proverka "$rc -ne 0" byla istinnoj pri uspeshnoj
# sborke. Sborka prohodila, a skript otchityvalsja ob oshibke.
# Proverka DEREVA, a ne celi. Eto to, chego ne hvatalo v pervoj versii.
#
# Skript proverjal zapuskaemost tolko teh celej, kotorye sam sobiral - i eto propuskalo glavnoe:
# derevo obshchee. Sborka odnogo llama-memex-fwd ostavljala llama-cli i llama-moe-trace slomannymi,
# nikto ih ne proverjal, i otkaz vsplyval cherez chas v chuzhom progone, kotoryj otchityvalsja
# nulevym fajlom vmesto oshibki. Tak DLL propadali chetyre raza, i tri iz nih ja diagnostiroval
# zanovo.
#
# DLL zdes vazhnee binarnikov: exe bez svoej DLL ne startuet voobshche, a otsutstvie DLL vidno
# srazu i deshevo, bez zapuska.
$RequiredDlls = @('ggml.dll','llama.dll','ggml-base.dll','mtmd.dll')

function Test-Tree {
    # NALICHIE NEDOSTATOCHNO, i eto stoilo vechera. V build-vk okazalas ggml.dll na 67 KB ot 26
    # ijunja vmesto 46 MB - chuzhaja ili ustarevshaja, no PRISUTSTVUJUSHCHAJA, tak chto proverka na
    # Test-Path ejo propuskala. Binarnik pri etom padal na zagruzchike s -1073741511 "tochka vhoda
    # ne najdena", to est logi prihodili PUSTYMI i chitalis kak "progon ne dal dannyh".
    #
    # Porog v 1 MB uzhe byl - v tree_check.ps1, u sosednego proverjalshchika. Dva proverjalshchika,
    # strogij i dyrjavyj, i polzovalis dyrjavym.
    $miss = @()
    foreach ($d in @('ggml.dll','llama.dll')) {
        $f = Join-Path $bin $d
        if (-not (Test-Path -LiteralPath $f)) { $miss += ($d + " (net)"); continue }
        $len = (Get-Item -LiteralPath $f).Length
        if ($len -lt 1048576) { $miss += ($d + " (" + [math]::Round($len/1KB) + " KB - zaglushka)") }
    }
    if ($miss.Count -gt 0) { return ("biblioteki negodny: " + ($miss -join ', ')) }
    return $null
}

# ------------------------------------------------------------------ hranilishche bibliotek
#
# Vosstanovlenie iz kopii - sekundy protiv desjati minut peresborki, i imenno poetomu ono opasno:
# STARAJA DLL protiv NOVOGO exe dajot -1073741511 "tochka vhoda ne najdena", a eto otkaz huzhe
# otsutstvija. Ne startuet tak zhe, no prichina vygljadit inache i iskat ejo budут v kode.
#
# Poetomu dva pravila, i oba objazatelny:
#   1. Kopija snimaetsja TOLKO posle togo, kak sborka proverena na zapuskaemost. Nikogda "na vsjakij
#      sluchaj" i nikogda do proverki - inache v hranilishche ljazhet to zhe slomannoe derevo.
#   2. Posle vosstanovlenija proverka zapuskaemosti prohoditsja ZANOVO, i esli ne proshla - kopija
#      objavljaetsja negodnoj i idjot polnaja peresborka. Hranilishche - bystryj put, a ne istina.
#
# Rjadom s kopiej lezhit metka: kommit, iz kotorogo sobrano, i vremja. Ona ne uchastvuet v reshenii
# (reshaet zapuskaemost), no bez nejo nevozmozhno ponjat, chto imenno lezhit v hranilishche.
# ODNO HRANILISHCHE NA DVA DEREVA - eto byla oshibka. $bin uvazhaet -Dir, a $vault byl propisan
# zhjostko, tak chto sborka bez Vulkan kladjot tuda 31-megabajtnuju ggml.dll, sborka s Vulkan -
# 46-megabajtnuju, i vosstanovlenie podsovyvaet chuzhuju. Otkaz vygljadit kak -1073741511 "tochka
# vhoda ne najdena" - huzhe otsutstvija, potomu chto prichinu iskat budut v kode.
$vault = 'D:/MemeX/dll_vault/' + (Split-Path -Leaf $Dir)

function Save-Vault {
    New-Item -ItemType Directory -Path $vault -Force -EA SilentlyContinue | Out-Null
    $n = 0
    foreach ($d in $RequiredDlls) {
        $src = Join-Path $bin $d
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $vault -Force -EA SilentlyContinue; $n++ }
    }
    $head = (& git -C 'D:/MemeX/src/ik_llama.cpp' rev-parse --short HEAD 2>$null)
    ("kommit " + $head + ", snjato " + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ", bibliotek " + $n) |
        Set-Content -LiteralPath (Join-Path $vault 'metka.txt') -Encoding UTF8
    Say ("  kopija bibliotek obnovlena: " + $n + " sht")
}

function Restore-Vault {
    if (-not (Test-Path -LiteralPath $vault)) { return $false }
    $n = 0
    foreach ($d in $RequiredDlls) {
        $src = Join-Path $vault $d
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $bin -Force -EA SilentlyContinue; $n++ }
    }
    if ($n -eq 0) { return $false }
    $m = if (Test-Path -LiteralPath (Join-Path $vault 'metka.txt')) { (Get-Content -LiteralPath (Join-Path $vault 'metka.txt') -Raw).Trim() } else { 'bez metki' }
    Say ("  vosstanovleno iz kopii: " + $n + " sht (" + $m + ")")
    return $true
}

# VSEGDA CEPOChKA, nikogda odna cel. Prichina najdena i vosproizvodima v dve komandy:
#
#   cmake --build build-vk --target ggml              -> ggml.dll na meste
#   cmake --build build-vk --target llama-memex-fwd   -> ggml.dll UDALENA, oshibok nol
#
# MSBuild pri sborke zavisimoj celi obhodit proekt ggml, reshaet chto tot ustarel (iz-za shaga
# 'Auto build dll exports', kotoryj peresozdajot fajl eksportov), UDALJAET staryj vyhod i zatem ne
# komponuet zanovo, potomu chto objektnye fajly ne menjalis. Otkaz molchalivyj: kod vozvrata nol,
# oshibok net, binarnik posle etogo padaet na zagruzchike DO pervoj stroki vyvoda, i pustoj log
# chitaetsja kak 'progon ne dal dannyh'.
#
# Eto i est vse chetyre istoricheskih ischeznovenija: kazhdoe shlo posle sborki ODNOJ celi. I eto
# zhe objasnjaet, pochemu --clean-first kazalsja lekarstvom - on zastavljal peresobrat vsjo, to est
# sluchajno zakryval dyru, kotoruju sam zhe rasshirjal.
function Invoke-Build([string[]]$t, [bool]$c) {
    # Cepochka celikom, vsegda. Sm. kommentarij vyshe: sborka odnoj celi udaljaet ggml.dll.
    $chain = @('ggml','llama') + ($t | Where-Object { $_ -ne 'ggml' -and $_ -ne 'llama' })
    $a = @('--build', $Dir, '--config', 'Release', '-j', "$Jobs")
    foreach ($x in $chain) { $a += @('--target', $x) }
    if ($c) { $a += '--clean-first' }
    $out = & cmake @a 2>&1
    $script:BuildRc = $LASTEXITCODE
    $out | Select-Object -Last 2 | ForEach-Object { Say ("  " + $_) }
}

$held = $false
if (-not $NoLock) {
    Say "berjom mashinu pod sborku"
    if (-not (Take-Machine -Who 'build' -TimeoutMin $LockMin)) { Say "mashinu ne poluchili"; exit 1 }
    $held = $true
}

try {
    # Chistaja sborka idjot vsej cepochkoj srazu. Porozn nelzja: mezhdu udaleniem ggml.dll i ejo
    # pojavleniem vsjo, chto na nejo ssylaetsja, nezagruzhaemo.
    $chain = if ($Clean) { @('ggml','llama') + $Targets } else { $Targets }
    Say ("sobiraju: " + ($chain -join ', ') + $(if ($Clean) { " (s chistkoj)" } else { "" }))
    Invoke-Build $chain $Clean.IsPresent
    if ($script:BuildRc -ne 0) { Say ("cmake vernul " + $script:BuildRc); exit $script:BuildRc }

    # Vot radi chego vsjo. cmake skazal "uspeh" - eto eshchjo nichego ne znachit.
    $bad = @()

    # Snachala derevo celikom: esli net ggml.dll ili llama.dll, slomany VSE binarniki, a ne tolko
    # te, chto my sobirali. Proverjaetsja do zapuskov, potomu chto deshevle i tochnee nazyvaet
    # prichinu, chem kod -1073741515 iz kazhdogo exe po ocheredi.
    $treeWhy = Test-Tree
    if ($treeWhy) { $bad += ("derevo : " + $treeWhy) }

    foreach ($t in $Targets) {
        $why = Test-Startable (Join-Path $bin ($t + '.exe'))
        if ($why) { $bad += ($t + " : " + $why) } else { Say ("  " + $t + " zapuskaetsja") }
    }

    if ($bad.Count -gt 0) {
        foreach ($b in $bad) { Say ("  NE ZAPUSKAETSJA: " + $b) }

        # Snachala bystryj put: vosstanovit biblioteki iz kopii i proverit zanovo. Eto sekundy
        # protiv desjati minut, i esli propali imenno DLL - a imenno oni propadali vse chetyre
        # raza - togo dostatochno. Esli posle vosstanovlenija vsjo eshchjo ne startuet, kopija
        # negodna (staraja DLL protiv novogo exe), i idjot polnaja peresborka.
        if (Restore-Vault) {
            $after = @()
            $treeWhy = Test-Tree
            if ($treeWhy) { $after += ("derevo : " + $treeWhy) }
            foreach ($t in $Targets) {
                $why = Test-Startable (Join-Path $bin ($t + '.exe'))
                if ($why) { $after += ($t + " : " + $why) }
            }
            if ($after.Count -eq 0) { Say "kopija podoshla, peresborka ne nuzhna"; Say "sborka godna"; exit 0 }
            foreach ($a in $after) { Say ("  posle vosstanovlenija vsjo eshchjo: " + $a) }
            Say "kopija ne podoshla - sobiraju polnostju"
        }

        # BEZ --clean-first. Shapka etogo fajla objasnjaet, pochemu: on SNACHALA udaljaet vsjo, chto
        # cel proizvodit, i tolko potom sobiraet, tak chto prervannaja pochinka ostavljaet derevo
        # slomannym navsegda - imenno tak biblioteki ischezali tri raza. Ostavit ego v REMONTNOM
        # puti znachilo ostavit tot zhe mehanizm tam, kuda popadajut imenno slomannye derevja.
        # Obychnaja peresborka cepochki perezapisyvaet biblioteki, ne udaljaja ih zaranee.
        Say "chinju peresborkoj cepochki ggml -> llama -> celi (bez ochistki)"
        Invoke-Build (@('ggml','llama') + $Targets) $false
        if ($script:BuildRc -ne 0) { Say ("pochinka ne udalas, cmake vernul " + $script:BuildRc); exit $script:BuildRc }
        $still = @()
        $treeWhy = Test-Tree
        if ($treeWhy) { $still += ("derevo : " + $treeWhy) }
        foreach ($t in $Targets) {
            $why = Test-Startable (Join-Path $bin ($t + '.exe'))
            if ($why) { $still += ($t + " : " + $why) }
        }
        if ($still.Count -gt 0) {
            foreach ($s in $still) { Say ("  VSJO ESHCHJO NE ZAPUSKAETSJA: " + $s) }
            exit 1
        }
        Say "posle pochinki vsjo zapuskaetsja"
    }
    Save-Vault
    Say "sborka godna"
} finally {
    if ($held) { Free-Machine; Say "mashina osvobozhdena" }
}
