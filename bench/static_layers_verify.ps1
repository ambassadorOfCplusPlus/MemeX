# Proverka pravilnosti sloev na karte, do ljubogo zamera.
#
# CHTO IMENNO PROVERJAETSJA, i pochemu ne "sovpadenie tokenov".
#
# Etalon zdes - CPU-put forka, a ego jadra iqk KVANTUJUT vektor aktivacij: na odnom
# mul_mat_id protiv etalona dvojnoj tochnosti CPU dal 5.0e-2, a Vulkan 9.4e-8. Znachit
# raznica v polprocenta govorit "karta schitaet inache", a ne "neverno" - i po edinstvennomu
# izmereniju protiv istiny inache znachit TOCHNEE. Sovpadenie s CPU do 1e-7 bylo by
# podozritelno, a ne uspokoitelno: eto znachilo by, chto my vosproizveli kvantovanie
# aktivacij CPU.
#
# Chto NADO smotret: rastjot li raznica s glubinoj. Eto podpis nakoplenija ot perestanovki
# slozhenij, i proekt na nej uzhe gorel: 2.5e-8 na sloe 1 stalo 1.6% k sloju 47 i 3-6% na
# logitah, PRICHJOM vse porozhdjonnye tokeny sovpadali. Poetomu skript pechataet l_out po
# sloju i osobo - sloj 47.
#
# PROMPT IDJOT FAJLOM, ne cherez -p. Start-Process -ArgumentList ne kavychit elementy s
# probelami, i prosche vsego eto uzhe stoilo proektu vechera: vsjo posle pervogo slova
# prihodit v dvizhok kak otdelnye flagi, kazhdyj otvergaetsja, i edinstvennym plechom po
# Gemma za vecher ostalos to, gde promt byl odnim slovom.
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
$LOG = 'D:\MemeX\results\static_layers_verify.log'
$PFILE = 'D:\MemeX\results\prompt_short.txt'
if (-not (Test-Path -LiteralPath $PFILE)) {
    Set-Content -LiteralPath $PFILE -Encoding UTF8 -NoNewline `
        -Value 'The capital of France is Paris, and the capital of Japan is'
}

function Say($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)
    Write-Host $line
    Add-Content -LiteralPath $LOG -Value $line -Encoding UTF8
}

# Pravilo 49: dokazat, chto binarnik zapuskaetsja, DO sbora dannyh. Pustoj log ot upavshego
# na zagruzchike exe chitaetsja kak otricatelnyj rezultat, a ne kak "my nichego ne uznali".
$null = & $EXE --version 2>&1
if ($LASTEXITCODE -ne 0) { Say ("exe ne zapuskaetsja, kod " + $LASTEXITCODE); exit 1 }

function RunOnce($tag, [string[]]$extra) {
    $so = "D:\MemeX\results\_slv_$tag.out"
    $a = @('-m', $Model, '-f', $PFILE, '--tokens', "$Tokens", '-t', "$Threads",
           '--decode-check', "$Steps", '--probe', 'all', '--no-repack') + $extra
    $proc = $null
    try {
        $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { Say ("ne zapustilsja: " + $_.Exception.Message); return $null }
    if ($null -eq $proc) { Say 'Start-Process nichego ne vernul'; return $null }
    # Pravilo 55: bez chtenija .Handle ExitCode prihodit PUSTYM, a pustoe ne ravno nulju -
    # uspeshnyj shag togda otchityvaetsja kak upavshij.
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) {
        Say "$tag ne uspel za $LimitMin min - ubivaju"
        try { $proc.Kill() } catch {}
        return $null
    }
    # Kod 2 u etogo dvizhka znachit "progon sostojalsja i chisla ne soshlis" - eto rezultat,
    # a ne slomannyj shag. Odin raz eto stoilo lishnego trjohminutnogo progona.
    Say "$tag zakonchil, kod $($proc.ExitCode)"
    return $so
}

Say "berjom mashinu pod proverku"
if (-not (Take-Machine -Who 'static-layers-verify' -TimeoutMin 60)) { Say 'mashinu ne poluchili'; exit 1 }
try {
    $out = RunOnce 'layers' @('--gpu-static-layers')
    if (-not $out) { exit 1 }
    Say '--- chto skazal progon ---'
    Get-Content -LiteralPath $out -Encoding UTF8 |
        Select-String -Pattern 'l_out-|result_norm|USTROJSTVO|peresechenij|na odno peresechenie|na tokjen|kesh prompta|совпал|РАСХОД|шаг |bufer:|vnimanie, marshrutizatory|OTKAZ|ne uehal|nacelit|логит|токен' |
        ForEach-Object { Say ("  " + $_.Line.Trim()) }
} finally {
    Free-Machine
    Say 'mashina osvobozhdena'
}
