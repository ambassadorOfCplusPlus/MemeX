# Speculation with a real draft model on the card.
#
# Why this and not the fine-grained expert split. Crossing the device boundary costs
# 0.16-0.25 ms and a layer's expert work is about 1.0 ms, so forty-eight crossings per token
# eat more than a 1.54x faster card can return - measured, not argued. Speculation crosses
# once per round instead, and it is the only technique here that is free in quality terms:
# it preserves the target model's distribution exactly.
#
# The draft is Qwen3-0.6B at four bits, 0.4 GB, which fits the card with room to spare along
# with its own tiny cache. The processor verifies the batch, and a batch amortises the weight
# read over several tokens - the union of experts over neighbouring tokens grows sublinearly
# (34% overlap measured), so verifying five tokens costs far less than five single tokens.
#
# The model-free variants were already measured and are dead here: ngram-simple, suffix and
# ngram-map-k produced zero drafts, ngram-cache accepted 3 tokens out of 84 and cost 47 ms a
# call. A real draft is the remaining option.

$ErrorActionPreference = "Continue"
$BIN = "D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-cli.exe"
$MODEL = "D:\Qwen3-Coder-30B-A3B-mx1.gguf"
$DRAFT = "D:\smartstock\models\qwen3-0.6b-q4_k_m.gguf"
$PROMPT = "Write a Python function that merges two sorted lists and explain each step."

# Two prompts' worth of behaviour matter: ordinary prose-like generation, where a draft has to
# guess real content, and code, where it guesses structure and does much better.
$CODE = Get-Content "D:\MemeX\results\prompt_code.txt" -Raw

function Run-One($label, $extra, $useFile) {
    $a = @("-m", $MODEL, "-n", "128", "-c", "8192", "-t", "4", "-ngl", "0",
           "-fa", "off", "-rtr", "--seed", "1", "--no-display-prompt")
    if ($useFile) { $a += @("-f", "D:\MemeX\results\prompt_code.txt") }
    else { $a += @("-p", $PROMPT) }
    $a += $extra
    $out = & $BIN @a 2>&1
    $tps = ($out | Select-String -Pattern "^main:\s+eval time" | Select-Object -First 1).Line
    $st = ($out | Select-String -Pattern "^statistics" | Select-Object -First 1).Line
    Write-Output "--- $label"
    if ($tps) { Write-Output "    $tps" } else { Write-Output "    не запустилось: $($out | Select-Object -Last 1)" }
    if ($st) { Write-Output "    $st" }
}

Write-Output "=== короткий промпт ==="
Run-One "без спекуляции" @() $false
Run-One "черновик на карте, n_max=3" @("-md", $DRAFT, "-ngld", "99", "--spec-type", "draft:n_max=3") $false
Run-One "черновик на карте, n_max=5" @("-md", $DRAFT, "-ngld", "99", "--spec-type", "draft:n_max=5") $false
Run-One "черновик на процессоре, n_max=5" @("-md", $DRAFT, "-ngld", "0", "--spec-type", "draft:n_max=5") $false

Write-Output ""
Write-Output "=== промпт с кодом ==="
Run-One "без спекуляции" @() $true
Run-One "черновик на карте, n_max=5" @("-md", $DRAFT, "-ngld", "99", "--spec-type", "draft:n_max=5") $true
