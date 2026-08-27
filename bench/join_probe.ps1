# Odin instrumentirovannyj progon na plecho: kuda uhodjat nedostajushchie 33 ms.
#
# ETO NE A/B. Odin progon na plecho, i sravnivajutsja zdes ne plechi, a SLAGAEMYE vnutri
# odnogo tokjena, kotorye vse snjaty odnim i tem zhe progonom. Porog 4.2% k etomu ne
# otnositsja: on pro raznicu mezhdu progonami, a razlozhenie tokjena na chasti - eto odno
# chislo, razlozhennoe na chasti, gde summa chastej proverjaetsja protiv celogo.
#
# PREDSKAZANIE, zapisannoe DO progona (inache eto poisk, a ne proverka):
#
#   stat_exp, 65.3 ms/tokjen izmerennye ranshe, iz nih 31.7 uchteny (sloi 29.36 + golova 2.36).
#   Rasklad sloja: peresechenie statiki (CPU stoit) -> marshrutizator -> fork -> polovina CPU
#   -> dzhojn. Karta beretsja za ekspertov TOLKO posle togo, kak peresechenie statiki
#   zakoncheno, poetomu perekryvatsja u nejo est tolko s polovinoj CPU.
#     polovina CPU  28.4% promaha * 962.6 MB = 273 MB pri 24.8 GB/s = 11.0 ms/tokjen
#                   = 0.23 ms na sloj
#     polovina karty 5.73 eksperta * 2.51 MB iz VRAM + dva barjera = okolo 0.45 ms na sloj
#                   = 20-25 ms/tokjen
#   Polovina karty DLINNEE poloviny CPU pochti vdvoe, znachit dzhojn dolzhen zhdat.
#
#   ZHDJOM         predskazyvaju 8 - 15 ms/tokjen
#   gotova k prihodu CPU  predskazyvaju menshe 25% dzhojnov
#   polovina CPU   predskazyvaju 10 - 15 ms/tokjen
#   polovina karty predskazyvaju 20 - 29 ms/tokjen
#   peresechenij statiki na sloj  predskazyvaju 1.02 - to est kandidat (2) k statike NE
#                   otnositsja, u nejo odno peresechenie na sloj, a dva barjera na sloj est u
#                   puti ekspertov i oni uzhe socheny (2.20 na sloj)
#
#   Esli ZHDJOM okazhetsja okolo 30 ms - eto kandidat (1) v polnyj rost i predskazanie mimo
#   po velichine, no ne po napravleniju. Esli ZHDJOM okolo nulja - oba kandidata mimo, i
#   iskat nado v tretjem meste.

param(
    [int] $Ngen    = 192,
    [int] $Tokens  = 512,
    [int] $Threads = 8,
    [int] $LimitMin = 20
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$EXE    = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL  = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf'
$PROMPT = 'D:\MemeX\results\prompt_2000.txt'
$LOG    = 'D:\MemeX\results\join_probe.log'

function Say($m)  { $l = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m); Write-Host $l; Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8 }

$null = & $EXE --version *> $null
if ($LASTEXITCODE -ne 0) { Say ("exe ne zapuskaetsja, kod " + $LASTEXITCODE); exit 1 }

$arms = @(
    @{ t = 'stat_exp'; e = @('--gpu-static-layers', '--gpu-experts', '--resident', '0') },
    @{ t = 'exp';      e = @('--gpu-experts', '--resident', '0') }
)

("`n`n######## join probe " + (Get-Date)) | Add-Content -LiteralPath $LOG -Encoding UTF8
Say 'berjom mashinu'
if (-not (Take-Machine -Who 'join-probe' -TimeoutMin 60 -MinFreeGB 16)) { Say 'mashinu ne poluchili'; exit 1 }
try {
    foreach ($arm in $arms) {
        $so = "D:\MemeX\results\_jp_$($arm.t).out"
        $a = @('-m', $MODEL, '-f', $PROMPT, '--tokens', "$Tokens", '-t', "$Threads",
               '--gen', "$Ngen", '--no-repack') + $arm.e
        Say ("plecho $($arm.t): " + ($a -join ' '))
        $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                              -RedirectStandardOutput $so -RedirectStandardError "$so.err"
        $null = $proc.Handle
        if (-not $proc.WaitForExit($LimitMin * 60 * 1000)) {
            Say 'ne uspel - ubivaju'; try { $proc.Kill() } catch {}; continue
        }
        Say "  kod vyhoda $($proc.ExitCode)"
        Get-Content -LiteralPath $so -Encoding UTF8 |
            Select-String -Pattern 'STATIC_AB|peresechenij|na odno peresechenie|na tokjen|джойн|джойнов|барьеры|попаданий \d|экспертов запущено|слоёв на устройстве|подкачек по PCIe|выборок без слота|скорость генерации|USTROJSTVO|поток устройства упал' |
            ForEach-Object { Say ('    ' + $_.Line.Trim()) }
    }
} finally {
    Free-Machine
    Say 'mashina osvobozhdena'
}
