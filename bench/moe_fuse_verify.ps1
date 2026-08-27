# Proverka slitogo hvosta MoE: ggml_mul_multi_add vmesto vosmi uzlov.
#
# CHTO IMENNO PROVERJAETSJA I POCHEMU IMENNO ETIM.
#
# Utverzhdenie "bitovo odno i to zhe" opiraetsja na chtenie jadra (iqk_cpu_ops.cpp:430):
# poslotnoe proizvedenie i nakoplenie s nulevogo slota vverh, kak i v cepochke. Ostatochnyj
# risk odin - kontrakcija `y[k] += x0[k]*x1[0]` v FMA ostavljaet proizvedenie neokruglennym.
# Chteniem ishodnika eto ne reshaetsja, reshaetsja progonom.
#
# I zdes vazhno, chto plecho OBJAZANO SOVPAST (pravilo 69): esli ffn_moe_weighted-N vyhodit
# L2 0.0000% protiv etalona, vopros zakryt celikom, bez interpretacii. Maloe rashozhdenie
# prishlos by tolkovat, a tolkovanie - eto to, na chjom proekt uzhe terjal dni.
#
# Zaodno eto PERVOE chislo dlja etogo tenzora voobshche: "ffn_moe_out" bylo nashe imja i na
# storone etalona ne sootvetstvovalo nichemu, tak chto hvost MoE u qwen3moe ni razu ne byl
# sverjon. Ta zhe dyra, chto najdena i zakryta na gemma4.
#
# Zamer NE timingovyj, poetomu zagruzhennaja mashina ego ne portit (pravilo 47) - no zamok
# vsjo ravno berjotsja, potomu chto progon derzhit 16 GB.
param(
    [string] $Model  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf',
    [int]    $Tokens = 12,
    [int]    $Steps  = 6,
    [int]    $Threads = 8,
    [int]    $LimitMin = 12,
    [switch] $External
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$LOG = 'D:\MemeX\results\moe_fuse_verify.log'
# Pravilo 71: Start-Process -ArgumentList ne kavychit elementy s probelami, poetomu prompt
# zhivjot v fajle, a ne v komandnoj stroke. Odnazhdy vsjo posle pervogo slova ushlo v dvizhok
# otdelnymi flagami i progon konchilsja za 16 sekund, nichego ne skazav.
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

# Pravilo 49: zapuskaemost do sbora dannyh, a ne vyvod ejo iz pustogo loga.
$null = & $EXE --version 2>&1
if ($LASTEXITCODE -ne 0) { Say ("exe ne zapuskaetsja, kod " + $LASTEXITCODE); exit 1 }

# $proc, nikogda $p (pravilo 45).
function RunOnce($tag, [string[]]$extra) {
    $so = "D:\MemeX\results\_mfv_$tag.out"
    $a = @('-m', $Model, '-f', $PFILE, '--tokens', "$Tokens", '-t', "$Threads",
           '--no-repack') + $extra
    $proc = $null
    try {
        $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
    } catch { Say ("ne zapustilsja: " + $_.Exception.Message); return $null }
    if ($null -eq $proc) { Say 'Start-Process nichego ne vernul'; return $null }
    # Pravilo 60: bez chtenija .Handle ExitCode prihodit PUSTYM, a pustoe ne est nol.
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) {
        Say "$tag ne uspel za $LimitMin min - ubivaju"
        try { $proc.Kill() } catch {}
        return $null
    }
    Say "$tag zakonchil, kod $($proc.ExitCode)"
    return $so
}

if (-not $External) {
    Say 'berjom mashinu pod proverku'
    if (-not (Take-Machine -Who 'moe-fuse-verify' -TimeoutMin 60)) { Say 'mashinu ne poluchili'; exit 1 }
}
try {
    # DVA PLECHA S RAZNYMI PROVERKAMI, i eto ne nebrezhnost - flagi vzaimno isklyuchajushchie.
    #
    #   --decode-check prodvigaet etalonnyj kontekst s pozicii N, i --gen delaet to zhe samoe,
    #   poetomu dvizhok otkazyvaet, esli dat oba. A --gpu-experts BEZ --gen otkazyvaet tozhe:
    #   rasshcheplenie zhivjot tolko na dekode. Znachit sverit rasshcheplenie s etalonom
    #   poshagovo nelzja voobshche, i u nego drugoj kriterij - sobstvennaja svjorstka slotov
    #   ("slotov svereno, rashozhdenij 0") i --gpu-experts-check, kotoryj zastavljaet CPU
    #   poschitat rezidentnuju polovinu vtoroj raz i sravnit s kartoj.
    #
    # Dva progona ushli na to, chtoby vyjasnit eto otkazami. Zapisano zdes, chtoby tretij ne
    # ponadobilsja.
    foreach ($arm in @(
        @{ t = 'cpu';      e = @('--decode-check', "$Steps", '--probe', 'all') },
        @{ t = 'stat_exp'; e = @('--gpu-static-layers', '--gpu-experts', '--gpu-experts-check',
                                 '--gen', '8', '--probe', 'all') }
    )) {
        $out = RunOnce $arm.t $arm.e
        if (-not $out) { continue }
        Say "--- $($arm.t) ---"
        Get-Content -LiteralPath $out -Encoding UTF8 |
            Select-String -Pattern 'routed_out-|ffn_moe_gate_par-|ffn_moe_down-|graf sloja|slotov sver|poslotno|rashozhdenij|OTKAZ|nelzja|шаг |совпал|РАСХОД|логит' |
            ForEach-Object { Say ("  " + $_.Line.Trim()) }
    }
} finally {
    if (-not $External) { Free-Machine; Say 'mashina osvobozhdena' }
}
