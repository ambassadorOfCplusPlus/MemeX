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
$RequiredDlls = @('ggml.dll','llama.dll')

function Test-Tree {
    $miss = @()
    foreach ($d in $RequiredDlls) {
        if (-not (Test-Path -LiteralPath (Join-Path $bin $d))) { $miss += $d }
    }
    if ($miss.Count -gt 0) { return ("net bibliotek: " + ($miss -join ', ')) }
    return $null
}

function Invoke-Build([string[]]$t, [bool]$c) {
    $a = @('--build', $Dir, '--config', 'Release', '-j', "$Jobs")
    foreach ($x in $t) { $a += @('--target', $x) }
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
        Say "chinju polnoj peresborkoj cepochki - eto rovno tot sluchaj, radi kotorogo skript napisan"
        Invoke-Build (@('ggml','llama') + $Targets) $true
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
    Say "sborka godna"
} finally {
    if ($held) { Free-Machine; Say "mashina osvobozhdena" }
}
