# Regressionnyj nabor: pod zamkom gonjaet --decode-check na trjoh arhitekturah i sravnivaet
# vydannye tokeny s etalonnym snimkom (bench/golden_decode.json). Padaet vsluh pri drejfe.
# Eto zapolnjaet probel "net testov kotorye gonjajutsja pri kazhdoj sborke": vyzyvat posle
# build_safe.ps1, ili vruchnuju. Pervyj zapusk s -Record zapisyvaet etalon.
#
# Pochemu tokeny, a ne L2: L2 protiv etalona - eto rashozhdenie s llama_decode, ono plavaet ot
# f16-vygruzki i ne dvoichnoe. Tokeny zhe - eto to, chto model realno vydajot; ih sovpadenie s
# proshloj sborkoj lovit REGRESSIJU PORTA (chuzhoj postroitel, sbityj porjadok uzlov) tochno.
#
# Latinica namerenno: PowerShell na etoj mashine chitaet fajl bez metki kak ANSI.
param(
    [switch] $Record,                 # zapisat tekushchie tokeny kak etalon vmesto sverki
    [int]    $Tokens = 32,
    [int]    $Check  = 16,
    [int]    $TimeoutMin = 240,
    [string] $Golden = 'C:\Users\User11\Desktop\MemeX\bench\golden_decode.json'
)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
$PROMPT = 'D:\MemeX\results\prompt_micro.txt'
$OUT = 'D:\MemeX\results\regress'
New-Item -ItemType Directory -Path $OUT -Force -EA SilentlyContinue | Out-Null

# Modeli: po odnoj na kazhdyj postroitel. Coder Next - s kopii na SSD.
$MODELS = @(
    @{ name = 'qwen3moe_mx1'; path = 'D:\Qwen3-Coder-30B-A3B-mx1.gguf';                   extra = @() },
    @{ name = 'gemma4';       path = 'D:\gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf';             extra = @() },
    @{ name = 'qwen3next';    path = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf';        extra = @() }
)

function Get-Tokens([hashtable]$m) {
    $log = Join-Path $OUT ("{0}.log" -f $m.name)
    $env:LLAMA_MMAP_PREFETCH = '0'
    $a = @('-m', $m.path, '-f', $PROMPT, '--tokens', "$Tokens", '--decode-check', "$Check",
           '-t', '8', '--no-repack') + $m.extra
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $txt = Get-Content -LiteralPath $log -Raw
    # Assert-Model: zagruzchik realno otkryl to, chto prosili.
    $want = Split-Path -Leaf $m.path
    if ($txt -notmatch [regex]::Escape($want)) { return @{ err = "v loge net imeni $want" } }
    # Stroka "nashi id: 1817 3950 ..." - eto vydannye tokeny.
    $line = Select-String -Path $log -Pattern 'nashi id:\s*([\d ]+)' | Select-Object -Last 1
    if (-not $line) { $line = Select-String -Path $log -Pattern 'наши id:\s*([\d ]+)' | Select-Object -Last 1 }
    if (-not $line) { return @{ err = 'ne nashjol stroku "nashi id:" v loge' } }
    $ids = ($line.Matches[0].Groups[1].Value.Trim() -split '\s+') | ForEach-Object { [int]$_ }
    # Skolko iz Check shagov soshlis s etalonom - dlja spravki.
    $agree = Select-String -Path $log -Pattern 'iz (\d+) shagov dali tot zhe token|(\d+) iz \d+ shagov' | Select-Object -Last 1
    return @{ ids = $ids; agree = ($agree ? $agree.Line.Trim() : '') }
}

if (-not (Take-Machine -Who 'regress' -TimeoutMin $TimeoutMin)) { Write-Output 'NE POLUCHIL MASHINU'; exit 3 }
$fail = 0
try {
    $golden = @{}
    if ((Test-Path $Golden) -and -not $Record) { $golden = Get-Content -LiteralPath $Golden -Raw | ConvertFrom-Json }
    $result = @{}
    foreach ($m in $MODELS) {
        if (-not (Test-Path $m.path)) { Write-Output ("PROPUSK {0}: net fajla {1}" -f $m.name, $m.path); continue }
        Write-Output ("progon {0} ..." -f $m.name)
        $r = Get-Tokens $m
        if ($r.err) { Write-Output ("  OSHIBKA {0}: {1}" -f $m.name, $r.err); $fail++; continue }
        $result[$m.name] = $r.ids
        if ($Record) {
            Write-Output ("  zapisano {0}: {1} tokenov" -f $m.name, $r.ids.Count)
        } else {
            $exp = $golden.($m.name)
            if (-not $exp) { Write-Output ("  NET ETALONA dlja {0} - zapusti s -Record" -f $m.name); $fail++; continue }
            $diff = @(); for ($i = 0; $i -lt [Math]::Min($exp.Count, $r.ids.Count); $i++) { if ($exp[$i] -ne $r.ids[$i]) { $diff += $i } }
            if ($diff.Count -eq 0 -and $exp.Count -eq $r.ids.Count) {
                Write-Output ("  OK {0}: {1} tokenov sovpali s etalonom" -f $m.name, $r.ids.Count)
            } else {
                Write-Output ("  REGRESSIJA {0}: rashozhdenie na pozicijah {1}; etalon {2}; sejchas {3}" -f `
                    $m.name, ($diff -join ','), ($exp -join ' '), ($r.ids -join ' '))
                $fail++
            }
        }
    }
    if ($Record) {
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Golden -Encoding UTF8
        Write-Output ("etalon zapisan: {0}" -f $Golden)
    }
} finally { Free-Machine }
if ($fail -gt 0) { Write-Output ("REGRESS: {0} otkazov" -f $fail); exit 1 } else { Write-Output 'REGRESS: vsjo OK'; exit 0 }
