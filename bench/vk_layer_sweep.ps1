# Cena ODNOGO peresechenija granicy kak funkcija CHISLA sloev na karte.
#
# VOPROS. Shag 3b dal 0,889 ms na peresechenie pri 48 slojah na karte. Chistoe jadro stolko
# stoit ne mozhet: bajty sloja (13,12 + 6,56 + 6,56 MiB u delta-sloja) pri izmerennyh
# 128,5 GB/s eto 0,20 ms, vychislenija delta-seti okolo 53 mks, dispatchi 29 x ~10 mks.
# Znachit v 0,889 est okolo 0,5 ms, kotorye ne bajty i ne arifmetika. Dva vzaimoiskljuchajushchih
# ob'jasnenija, i oni trebujut RAZNYH pravok:
#
#   A. Postojannaja cena kruga "submit -> planirovshchik -> karta -> zabor" na KAZHDYJ vyzov
#      graph_compute. Togda ona ne zavisit ot chisla sloev na karte, i lekarstvo - odin submit
#      na neskolko sloev.
#   B. Borba za ochered / kesh karty, rastushchaja s chislom sloev. Togda ona rastjot, i
#      ob'edinenie submitov nichego ne dast.
#
# SPOSOB. MEMEX_CARD_LO/HI suzhajut, kakie sloi VYZYVAJUTSJA na karte; vesa i grafy vseh sloev
# pri etom vsjo ravno lezhat v videopamjati, poetomu raskladka pamjati odna i ta zhe vo vseh
# plechah - menjaetsja tolko chislo peresechenij za tokjen. Eto i delaet sravnenie chestnym.
#
# POCHEMU IMENNO 4/12/24/48. Vnimanie u qwen3next na slojah 3,7,11...47, to est kazhdyj chetvjortyj.
# Diapazony 0..3, 0..11, 0..23, 0..47 vse derzhat sootnoshenie delta:vnimanie ravnym 3:1, tak chto
# srednij sloj v plechah odin i tot zhe. Diapazon 0..0 (odin delta-sloj) dobavlen otdelno i
# sravnivat ego so ostalnymi po srednemu NELZJA - u nego drugoj sostav.
#
# CHEGO ETOT ZAMER NE DAJOT. Chem menshe sloev na karte, tem bolshe schitaet processor, tem
# dolshe karta prostaivaet mezhdu peresechenijami - a prostoj, po izmereniju iz STATE.md
# ("static odin 0,277 protiv static + rezidentnye eksperty 0,234"), sam po sebe delaet
# peresechenie dorozhe. Poetomu rost ceny pri MALOM chisle sloev ne otlichim ot varianta B
# naoborot; razlichajutsja imenno tri tochki 12/24/48, gde zanjatost karty rastjot.

param(
    [string] $Model  = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
    [string] $Prompt = 'D:\MemeX\results\prompt_micro.txt',
    [int]    $Tokens = 32,
    [int]    $Gen    = 64,
    [int]    $LockMin = 300,
    [string] $OutDir = 'D:\MemeX\results\vk_layer_sweep'
)

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'

$exe = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Force $OutDir | Out-Null

# Poriadok plech PEREMESHAN namerenno: pervyj progon gruzit model s diska i grejot stranichnyj
# kesh, i esli plechi idut po vozrastaniju, samoe deshjovoe plecho vsegda platit za progrev.
$arms = @(
    @{ hi = 47; n = 48 },
    @{ hi =  3; n =  4 },
    @{ hi = 23; n = 24 },
    @{ hi = 11; n = 12 },
    @{ hi =  0; n =  1 }
)

if (-not (Take-Machine -Who 'vk-layer-sweep' -TimeoutMin $LockMin)) {
    Write-Output 'NE POLUCHIL MASHINU'
    exit 1
}
try {
    foreach ($a in $arms) {
        $log = Join-Path $OutDir ("layers_{0:d2}.log" -f $a.n)
        Write-Output ("[{0}] sloev na karte {1} (LO=0 HI={2})" -f (Get-Date -Format 'HH:mm:ss'), $a.n, $a.hi)
        $env:MEMEX_CARD_LO = '0'
        $env:MEMEX_CARD_HI = [string]$a.hi
        & $exe -m $Model -f $Prompt --tokens $Tokens --gen $Gen -t 8 `
               --no-repack --no-ref --gpu-static --gpu-static-layers *>&1 |
            Tee-Object -FilePath $log | Out-Null
        Get-Content -LiteralPath $log |
            Where-Object { $_ -match 'peresechenij|na odno peresechenie|na tokjen|STATIC_AB|sloi na karte' } |
            ForEach-Object { Write-Output ("    " + $_) }
    }
} finally {
    Remove-Item Env:MEMEX_CARD_LO -ErrorAction SilentlyContinue
    Remove-Item Env:MEMEX_CARD_HI -ErrorAction SilentlyContinue
    Free-Machine
}
