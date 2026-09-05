# SVODNAJA TABLICA SKOROSTEJ DVIZHKA MemeX (--gen 32 podrjad, 3 kruga na konfig).
# Odinakovye plechi merjatsja PODRJAD i sgruppirovany po modeli (odin rabochij nabor za raz),
# chtoby ne travit fajl-kesh OS (urok STATE). Vse progony: LLAMA_MMAP_PREFETCH=0, --no-repack,
# --no-ref, -t 8. ms/token beriotsja iz stroki "izmereno X mс/токен" (gen_ms/n_gen), tok/s=1000/ms.
param(
    [string] $Mx1    = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf',
    [string] $Gemma  = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf',
    [string] $Iq3    = 'D:\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
    [string] $Prompt = 'D:\MemeX\results\prompt_micro.txt',
    [string] $Prior  = 'D:\MemeX\results\expert_prior_coder_next.bin',
    [int]    $Gen    = 32,
    [int]    $Tokens = 32,
    [int]    $Rounds = 3,
    [string] $OutDir = 'D:\MemeX\results\speed_table'
)
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Path $OutDir -Force -EA SilentlyContinue | Out-Null
$env:LLAMA_MMAP_PREFETCH = '0'
$results = @()

function Run([string]$name, [string]$model, [string[]]$extra) {
    $mspts = @()
    for ($r = 1; $r -le $Rounds; $r++) {
        $log = Join-Path $OutDir ("{0}_r{1}.log" -f $name, $r)
        $a = @('-m',$model,'-f',$Prompt,'--tokens',"$Tokens",'--gen',"$Gen",
               '-t','8','--no-repack','--no-ref') + $extra
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
        $sw.Stop()
        $txt = Get-Content -LiteralPath $log -Raw
        # Cyrillic gets mojibaked by console capture; parse the measured print_budget line by
        # its ASCII skeleton: "<izmereno> <NUM> <mс/токен> -> ...". The unit token contains a
        # '/', which the earlier "NNN МиБ -> kucha" memory lines do NOT - anchor on that '/'.
        $m = [regex]::Match($txt, '([0-9.]+) [^ ]*/[^ ]* -> ')
        if (-not $m.Success) { $m = [regex]::Match($txt, 'dolja fazy: ([0-9.]+) ms/token') }
        $ms = if ($m.Success) { [double]$m.Groups[1].Value } else { [double]::NaN }
        $cap = [regex]::Match($txt, 'C = (\d+) iz (\d+)')
        $hit = [regex]::Match($txt, 'popadanij ([0-9.]+)%')
        $otk = [regex]::Match($txt, 'OTKAZ|OTKAZAN|ne podderzh|nedostupen')
        $mspts += $ms
        $extraNote = ''
        if ($cap.Success) { $extraNote += " C=$($cap.Groups[1].Value)/$($cap.Groups[2].Value)" }
        if ($hit.Success) { $extraNote += " hit=$($hit.Groups[1].Value)%" }
        if ($otk.Success) { $extraNote += " [OTKAZ/fallback: $($otk.Value)]" }
        Write-Host ("  {0} r{1}: {2:N1} ms/token  ({3:N2} tok/s)  wall {4:N0}s{5}" -f `
            $name, $r, $ms, (1000.0/$ms), $sw.Elapsed.TotalSeconds, $extraNote)
    }
    $valid = $mspts | Where-Object { -not [double]::IsNaN($_) }
    if ($valid.Count -gt 0) {
        $mean = ($valid | Measure-Object -Average).Average
        $mn = ($valid | Measure-Object -Minimum).Minimum
        $mx = ($valid | Measure-Object -Maximum).Maximum
        $spread = if ($mean -gt 0) { 100.0*($mx-$mn)/$mean } else { 0 }
        $line = "{0,-16} {1,8:N1} {2,8:N2} {3,7:N1}%" -f $name, $mean, (1000.0/$mean), $spread
        Write-Host ("  => AVG {0}: {1:N1} ms/token, {2:N2} tok/s, razbros {3:N1}%" -f $name,$mean,(1000.0/$mean),$spread)
        $script:results += $line
    } else {
        Write-Host ("  => AVG {0}: NET IZMERENIJA (sm. log)" -f $name)
        $script:results += ("{0,-16} {1,8} {2,8} {3,8}" -f $name,'n/a','n/a','n/a')
    }
}

if (-not (Take-Machine -Who 'speed-table' -TimeoutMin 300)) { Write-Host 'ne vzjal mashinu'; exit 1 }
try {
    Write-Host "=== mx1 (qwen3moe) ==="
    Run 'mx1_cpu' $Mx1 @()
    Run 'mx1_gpu' $Mx1 @('--gpu-static','--gpu-static-layers')

    Write-Host "=== gemma4 ==="
    Run 'g4_cpu' $Gemma @()
    Run 'g4_gpu' $Gemma @('--gpu-static','--gpu-static-layers','--gpu-static-dense')

    Write-Host "=== Coder Next IQ3_XXS (qwen3next) ==="
    Run 'iq3_cpu'      $Iq3 @()
    Run 'iq3_gpu'      $Iq3 @('--gpu-static','--gpu-static-layers')
    Run 'iq3_store'    $Iq3 @('--gpu-static','--gpu-static-layers','--expert-store-auto','--expert-prior',$Prior)
    Run 'iq3_store_r4' $Iq3 @('--gpu-static','--gpu-static-layers','--expert-store-auto','--expert-prior',$Prior,'--expert-store-repack')

    Write-Host ""
    Write-Host "===== SVODNAJA TABLICA (konfig -> ms/token, tok/s, razbros) ====="
    Write-Host ("{0,-16} {1,8} {2,8} {3,8}" -f 'config','ms/tok','tok/s','razbros')
    $results | ForEach-Object { Write-Host $_ }
} finally { Free-Machine }
