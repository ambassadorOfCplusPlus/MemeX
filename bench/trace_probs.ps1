# Re-record the router trace WITH the full distributions, not just the selections.
#
# The trace on disk stores only each token's chosen top-8. That was enough to show the selection is
# strongly persistent (47-52% repeat k tokens later against a 6.25% floor) and that a 16-token
# window covers 91% of the next ten tokens' needs. It was not enough to test the idea that matters:
# ranking experts by the router's probability mass instead of by how often they crossed into the
# top-8. An expert sitting consistently ninth by probability never earns a count, and it is exactly
# the one about to enter the top-8.
#
# The gap that idea has to close is measured: at 16 experts per layer, LFU gets 76.2% and an oracle
# that can see the next four tokens gets 91.0%. Fifteen points are on the table and neither policy
# tested so far takes them.
#
# MOE_TRACE_PROBS makes the tool emit the distribution under tag -(layer)-10001. -no-fmoe is not
# optional: the fused MoE path elides the ffn_moe_probs node the callback matches on, which is the
# same reason four layers came out empty in the importance matrix.

$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$BIN = 'D:\MemeX\src\ik_llama.cpp\build\bin\Release'
$LOG = 'D:\MemeX\results\trace_probs.log'
$OUT = 'D:\MemeX\results\moe_trace_probs.bin'

function Say($m) { ("`n[{0}] ===== {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Note($m) { ("  " + $m) | Tee-Object -FilePath $LOG -Append }

("`n`n######## trassa s raspredelenijami " + (Get-Date)) | Add-Content $LOG
if (-not (Take-Machine -Who 'trace_probs' -TimeoutMin 600 -MinFreeGB 16)) { Note 'mashinu ne poluchili'; exit 1 }
Note ('vladeem: ' + (Get-LockHolder))
try {
    # -b/-ub objazatelny: promt na 4000 tokenov ne vlezaet v batch po umolchaniju (2048), i
    # llama.cpp padaet na GGML_ASSERT(n_tokens_all <= cparams.n_batch) do togo, kak chto-libo
    # zapisat. Kontekst zadan, a razmer batcha - net; eto raznye veshchi, i pervyj vtoroj ne zadajot.
    # Promt na 2000 tokenov, ne 4000. Chetvjortoe padenie etoj trassy bylo iz-za togo, chto ja
    # podnjal batch do 4096, a prompt_4000.txt eto 17205 bajt, to est okolo 4300 tokenov - "chetyre
    # simvola na tokjen" ja vzjal kak dannost i ne proverил. Dlja trassy dvuh tysjach s izbytkom:
    # nuzhny raspredelenija marshrutizatora, a ne dlinnyj kontekst.
    Say 'zapis trassy s polnymi raspredelenijami marshrutizatora'
    # Staryj fajl udaljaetsja do progona, inache ego nalichie posle progona nichego ne dokazyvaet.
    if (Test-Path $OUT) { Remove-Item $OUT -Force -EA SilentlyContinue }
    $env:MOE_TRACE_OUT   = $OUT
    $env:MOE_TRACE_PROBS = '1'
    $exe = "$BIN" + [char]92 + "llama-moe-trace.exe"
    if (-not (Test-Path $exe)) { $exe = "$BIN" + [char]92 + "moe-trace.exe" }
    if (-not (Test-Path $exe)) { Note 'net binarnika moe-trace'; exit 1 }
    & $exe -m 'D:\Qwen3-Coder-30B-A3B-mx1.gguf' -f 'D:\MemeX\results\prompt_2000.txt' -c 4096 -b 4096 -ub 4096 -t 8 -ngl 0 -fa off `
        -no-fmoe -no-fug --seed 1 *> 'D:\MemeX\results\trace_run.log'
    Remove-Item Env:MOE_TRACE_PROBS -EA SilentlyContinue
    Remove-Item Env:MOE_TRACE_OUT   -EA SilentlyContinue
    # Nalichie fajla ne est zapis. Nulevoj fajl ot proshlogo raza lezhal na meste, Test-Path ego
    # nashjol, i skript otchitalsja ob uspehe - a analiz potom skazal "trassa pusta". Tot zhe klass
    # oshibki, chto "razmer ne est celostnost" posle otkljuchenija sveta: proverjalos sushchestvovanie
    # tam, gde nuzhna byla prigodnost.
    if (Test-Path $OUT) { Remove-Item $OUT -Force -EA SilentlyContinue }
    # ... zapusk vyshe perepisyvaet fajl; posle nego proverjaem razmer, a ne fakt nalichija
    if ((Test-Path $OUT) -and ((Get-Item $OUT).Length -gt 1MB)) {
        Note ('trassa zapisana: {0:N1} MB' -f ((Get-Item $OUT).Length/1MB))
    } else {
        Note 'trassa ne zapisalas:'
        Get-Content 'D:\MemeX\results\trace_run.log' -Tail 6 -EA SilentlyContinue | ForEach-Object { Note ('    ' + $_) }
        exit 1
    }

    Say 'proverka silnoj formy idei: rang po verojatnostnoj masse'
    $py = & python 'C:/Users/User11/Desktop/MemeX/memex/predict_experts.py' --trace $OUT 2>&1
    $py | ForEach-Object { Note $_ }
} finally {
    Free-Machine
    Note 'mashina osvobozhdena'
}
