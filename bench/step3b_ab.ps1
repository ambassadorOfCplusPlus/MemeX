# A/B shaga 3b: vsja statika Coder Next na karte protiv chisto processornogo puti.
#
# Plechi CHEREDUJUTSJA i krug povtorjaetsja: lovushka 7.4 (stranichnyj kesh) delaet odinochnoe
# sravnenie na etoj modeli nedejstvitelnym - ta zhe komanda uzhe davala 2,97 i 6,01 tok/s podrjad.
# Razbros pechataetsja rjadom so srednim, i esli on bolshe effekta - eto i est otvet.
#
# Posle KAZHDOGO progona iz loga chitaetsja imja fajla, kotoryj realno otkryl zagruzchik, i
# sveryaetsja s tem, chto prosili: odin raz uzhe vyshlo, chto binarnik vzjal vshituju model po
# umolchaniju i otchitalsja polnym pravdopodobnym logom o DRUGOJ modeli.

param(
    [string] $Model  = 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf',
    [string] $Prompt = 'D:\MemeX\results\prompt_micro.txt',
    [int]    $Rounds = 3,
    [int]    $Gen    = 8,
    [int]    $Tokens = 32,
    [string] $OutDir = 'D:\MemeX\results\step3b'
)

. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE = 'D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe'
New-Item -ItemType Directory -Path $OutDir -Force -EA SilentlyContinue | Out-Null

# NE $Args: eto AVTOMATICHESKAJA peremennaja PowerShell, i vnutri funkcii ona derzhit
# NESVJAZANNYE argumenty, to est pustotu. Odin raz iz-za etogo binarnik zapustilsja BEZ
# argumentov, vzjal model po umolchaniju i otchitalsja polnym logom o drugoj modeli.
function Run-Arm([string]$name, [string[]]$extra, [int]$round) {
    $log = Join-Path $OutDir ("{0}_r{1}.log" -f $name, $round)
    $a = @('-m', $Model, '-f', $Prompt, '--tokens', "$Tokens", '--gen', "$Gen",
           '-t', '8', '--no-repack', '--no-ref') + $extra
    $t0 = Get-Date
    & $EXE @a *>&1 | Set-Content -LiteralPath $log -Encoding UTF8
    $wall = ((Get-Date) - $t0).TotalSeconds
    $txt = Get-Content -LiteralPath $log -Raw
    # Assert-Model: chto ZAGRUZCHIK realno otkryl.
    $want = Split-Path -Leaf $Model
    if ($txt -notmatch [regex]::Escape($want)) {
        Write-Output ("  OTKAZ: v loge net imeni " + $want + " - progon otbroshen")
        return $null
    }
    $m = [regex]::Match($txt, 'скорость генерации: наш\s+([0-9]+[.,][0-9]+)')
    if (-not $m.Success) {
        Write-Output "  OTKAZ: v loge net stroki skorosti - progon otbroshen"
        return $null
    }
    $v = [double]($m.Groups[1].Value -replace ',', '.')
    Write-Output ("  {0} krug {1}: {2:N4} tok/s, nastennoe {3:N1} s" -f $name, $round, $v, $wall)
    return [pscustomobject]@{ arm = $name; round = $round; toks = $v; wall = $wall }
}

Take-Machine -Who 'step3b-ab' -TimeoutMin 300
$res = @()
for ($r = 1; $r -le $Rounds; $r++) {
    # Poriadok plech MENJAETSJA mezhdu krugami: inache "kto grel kesh dlja kogo" postojanno.
    if ($r % 2 -eq 1) {
        $res += Run-Arm 'karta' @('--gpu-static-layers') $r
        $res += Run-Arm 'cpu'   @()                      $r
    } else {
        $res += Run-Arm 'cpu'   @()                      $r
        $res += Run-Arm 'karta' @('--gpu-static-layers') $r
    }
}
Free-Machine

Write-Output ''
foreach ($arm in @('karta', 'cpu')) {
    $v = @($res | Where-Object { $_ -and $_.arm -eq $arm } | ForEach-Object { $_.toks })
    if ($v.Count -eq 0) { Write-Output ("{0}: ni odnogo godnogo progona" -f $arm); continue }
    $avg = ($v | Measure-Object -Average).Average
    $spread = if ($avg -ne 0) { (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) / $avg * 100 } else { 0 }
    Write-Output ("{0}: {1}  srednee {2:N4} tok/s  razbros {3:N1}%" -f `
        $arm, (($v | ForEach-Object { '{0:N4}' -f $_ }) -join ' / '), $avg, $spread)
}
