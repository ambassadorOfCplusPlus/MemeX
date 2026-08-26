# Both numbers for one model file, measured the same way every time.
#
# The point is a quality budget rather than a speed race. Requantising the experts to IQ4_XS
# bought x1.42 and cost 7.9% perplexity (2.1236 -> 2.2918), which is a bad trade and was only
# discovered because the question was asked. So from here every candidate reports perplexity
# and tokens per second together, against the same reference, and anything over the budget is
# rejected regardless of how fast it is.
#
# Conditions are fixed deliberately: the plain build (the Vulkan one costs 23% on the CPU path
# because the model lands in host-visible device memory), four threads (eight is slower - the
# hyperthreads contend), and -rtr (weight repacking, +17% for nothing).

param(
    [Parameter(Mandatory=$true)][string]$Model,
    [int]$Chunks = 16,
    [int]$Tokens = 128,
    [int]$Threads = 4,
    [string]$Draft = ""
)

$BIN = "D:\MemeX\src\ik_llama.cpp\build\bin\Release"
$TEXT = "D:\MemeX\data\calibration.txt"
$PROMPT = "Write a Python function that merges two sorted lists and explain each step."

if (-not (Test-Path $Model)) {
    Write-Output "нет файла: $Model"
    exit 1
}
$sizeGb = [math]::Round((Get-Item $Model).Length / 1GB, 2)
Write-Output ("модель: " + (Split-Path $Model -Leaf) + ", $sizeGb ГБ")

# Perplexity first: it is the number that decides whether the candidate is admissible at all.
$ppl = & "$BIN\llama-perplexity.exe" -m $Model -f $TEXT -c 512 --chunks $Chunks `
        -t $Threads -ngl 0 -fa off -rtr 2>&1 |
       Select-String -Pattern "Final estimate"
Write-Output ("  " + ($ppl -replace "^\s+", ""))

# Reference from the unquantised-experts file, so the percentage is always against the same
# thing rather than against whatever was measured last.
$REF = 2.1236
if ($ppl -match "= ([\d.]+) \+/-") {
    $v = [double]$Matches[1]
    $delta = 100.0 * ($v - $REF) / $REF
    $verdict = if ($delta -le 2.0) { "в бюджете" } else { "ВНЕ БЮДЖЕТА" }
    Write-Output ("  против Q6_K_XL ($REF): {0:+0.00;-0.00}% — $verdict" -f $delta)
}

# Speed, with and without a draft. Speculation is free in quality terms - it preserves the
# target distribution exactly - so it is always worth reporting alongside.
function Speed($label, $extra) {
    $a = @("-m", $Model, "-p", $PROMPT, "-n", "$Tokens", "-c", "4096", "-t", "$Threads",
           "-ngl", "0", "-fa", "off", "-rtr", "--seed", "1", "--no-display-prompt") + $extra
    $out = & "$BIN\llama-cli.exe" @a 2>&1
    $line = ($out | Select-String -Pattern "^main:\s+eval time" | Select-Object -First 1).Line
    if ($line -match "([\d.]+) tokens per second") {
        Write-Output ("  $label" + ": " + $Matches[1] + " ток/с")
    } else {
        Write-Output ("  $label" + ": не запустилось")
    }
}
Speed "скорость" @()
if ($Draft -ne "") {
    Speed "с черновиком n_max=3" @("-md", $Draft, "--spec-type", "draft:n_max=3")
}
