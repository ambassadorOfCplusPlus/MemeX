#  ---- SVERKA DO/POSLE REESTRA ARHITEKTUR (shag 2) ----------------------------------------
#
#  Odin process pwsh: zamok privjazan k PID, poetomu vzjatie i osvobozhdenie objazany zhit
#  v tom zhe processe, chto i progony.
#
#  -Bin        put k binarniku (snimok starogo libo svezhesobrannyj)
#  -Tag        suffiks imeni loga: step2_<tag>_<model>[_gen].log
#  -Only       progon tolko po odnoj modeli (mx1 | gemma4 | next)
#  -Skip       propustit fazu: 'check' libo 'gen'
#
#  DVA progona na model, i eto ne izbytochnost. --decode-check idjot cherez Generator, to
#  est cherez ODIN dispetcher build_one; devjat tochek harnessa on ne trogaet vovse. Devjat
#  tochek gonjaet --gen. Poetomu reestr arhitektur proverjaetsja tolko oboimi vmeste:
#  --decode-check dajot L2 protiv llama_decode (chislo, a ne vid vyhoda), --gen dajot tot
#  zhe tekst iz tochek prefill / prefill_tail / decode.
param(
    [string]$Bin = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe',
    [string]$Tag = 'before',
    [string]$Only = '',
    [string]$Skip = '',
    [int]$LockMin = 300
)

$ErrorActionPreference = 'Continue'
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1

$models = @(
    @{ key = 'mx1';    path = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf' },
    @{ key = 'gemma4'; path = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf' },
    @{ key = 'next';   path = 'D:\Qwen3-Coder-Next-UD-IQ3_XXS.gguf' }
)
# Kopija na SSD, esli ona pojavilas: to zhe chtenie s C: v shest raz bystree, chem s
# mehanicheskogo D:. Podmena nazyvaetsja vsluh v logfajle, chtoby "do" i "posle" ne okazalis
# snjatymi s raznyh nositelej nezametno.
$nextC = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'
if (Test-Path -LiteralPath $nextC) { $models[2].path = $nextC }

if (-not (Test-Path -LiteralPath $Bin)) {
    Write-Host "NET BINARNIKA: $Bin"
    exit 2
}

function Run-One {
    param([string]$Log, [string]$ModelPath, [string[]]$Extra)
    Write-Host ("=== " + $Log + " (" + (Get-Date -Format 'HH:mm:ss') + ")")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $cliArgs = @('-m', $ModelPath, '-f', 'D:\MemeX\results\prompt_micro.txt',
              '--tokens', '32', '-t', '8', '--no-repack') + $Extra
    & $Bin @cliArgs *>&1 | Tee-Object -FilePath $Log | Out-Null
    $sw.Stop()
    Add-Content -LiteralPath $Log -Value ("# binarnik: " + $Bin)
    Add-Content -LiteralPath $Log -Value ("# model: " + $ModelPath)
    Add-Content -LiteralPath $Log -Value ("# argumenty: " + ($cliArgs -join ' '))
    Add-Content -LiteralPath $Log -Value ("# vremja progona, sek: " + [int]$sw.Elapsed.TotalSeconds)
    Write-Host ("=== gotovo za " + [int]$sw.Elapsed.TotalSeconds + " sek")
}

if (-not (Take-Machine -Who "step2-$Tag" -TimeoutMin $LockMin)) {
    Write-Host 'MASHINU NE POLUCHIL - NE IZMERENO'
    exit 3
}
try {
    foreach ($m in $models) {
        if ($Only -ne '' -and $Only -ne $m.key) { continue }
        if (-not (Test-Path -LiteralPath $m.path)) {
            Write-Host ("NET MODELI: " + $m.path)
            continue
        }
        if ($Skip -ne 'check') {
            Run-One -Log "D:\MemeX\results\step2_${Tag}_$($m.key).log" `
                    -ModelPath $m.path -Extra @('--decode-check', '16')
        }
        if ($Skip -ne 'gen') {
            Run-One -Log "D:\MemeX\results\step2_${Tag}_$($m.key)_gen.log" `
                    -ModelPath $m.path -Extra @('--gen', '8', '--no-ref')
        }
    }
} finally {
    Free-Machine
}
Write-Host 'GOTOVO'
