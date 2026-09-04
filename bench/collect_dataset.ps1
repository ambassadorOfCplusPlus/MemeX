# Lokalnyj sbor datasetta dlja predskazatelja R1: snjatie dampov (skrytoe sostojanie + sled
# ekspertov) na RAZNYH tekstah. Zamenjaet Kaggle-put (tam nuzhna verifikacija po telefonu, v RF
# nedostupna). Predskazatelju vazhno RAZNOOBRAZIE tekstov, a ne sobstvennaja generacija modeli:
# svjaz skrytoe->eksperty zadajot marshrutizator, on odin i tot zhe na prefille i na generacii.
#
# Idempotentno: dlja teksta, ch'i damp+sled uzhe est, progon propuskaetsja. Pod zamkom, odnim
# processom. Latinica namerenno (PowerShell chitaet fajl bez metki kak ANSI).
#   pwsh -File C:\Users\User11\Desktop\MemeX\bench\collect_dataset.ps1
param([int]$TimeoutMin = 300, [int]$Cap = 1500)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$MODEL = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
$R = 'D:\MemeX\results\dataset'
New-Item -ItemType Directory -Path $R -Force -EA SilentlyContinue | Out-Null

# Raznye teksty: kod, russkij, tehnicheskij, smena temy, tri prozy, KV. Kazhdyj - svoja tema.
$TEXTS = @('prompt_code','prompt_ru','prompt_tech','prompt_switch','prompt_third','prompt_2000','prompt_kv')

if (-not (Take-Machine -Who 'collect' -TimeoutMin $TimeoutMin)) { Write-Output 'NE POLUCHIL MASHINU'; exit 3 }
try {
    $env:LLAMA_MMAP_PREFETCH = '0'
    foreach ($t in $TEXTS) {
        $prompt = "D:\MemeX\results\$t.txt"
        if (-not (Test-Path $prompt)) { Write-Output "PROPUSK $t : net fajla"; continue }
        $hid = "$R\$t.hidden.bin"; $tr = "$R\$t.trace.bin"
        if ((Test-Path $hid) -and (Test-Path $tr)) { Write-Output "propusk $t : uzhe snjato"; continue }
        # tokeny = min(dlina, Cap); dvizhok sam obrezhet po dline promta
        $env:MEMEX_EXPERT_COVERAGE = '1'
        $env:MEMEX_HIDDEN_TRACE = $hid
        $env:MEMEX_EXPERT_TRACE = $tr
        $env:MEMEX_MTP_OVERLAP = '1'   # obhod: pisatel sleda byl vlozhen v etu vetku (sm. STATE)
        $log = "$R\$t.log"
        $t0 = Get-Date
        & $EXE -m $MODEL -f $prompt --tokens $Cap --gen 2 -t 8 --no-repack --no-ref --prefill-chunk 128 *> $log
        $sec = ((Get-Date) - $t0).TotalSeconds
        Remove-Item Env:\MEMEX_HIDDEN_TRACE, Env:\MEMEX_EXPERT_TRACE, Env:\MEMEX_MTP_OVERLAP -EA SilentlyContinue
        if ((Test-Path $hid) -and (Test-Path $tr)) {
            $hb = (Get-Item $hid).Length; $tb = (Get-Item $tr).Length
            Write-Output ("snjato {0}: hidden {1:N0} B, trace {2:N0} B, za {3:N0} s" -f $t, $hb, $tb, $sec)
        } else {
            Write-Output ("OSHIBKA {0}: damp ne zapisan, sm. {1}" -f $t, $log)
        }
    }
    Write-Output 'gotovo; dalshe: python bench/r1_transfer.py'
} finally { Free-Machine }
