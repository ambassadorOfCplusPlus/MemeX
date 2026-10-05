# Zamer skorosti dekoda odnoj modeli v ZADANNOM (pik) konfige protiv build-bt2022.
# Start-Process s REDIREKTOM v fajly (ne pajp) - poetomu stderr binarnika NE roняet PS-obertku
# (pravilo: PS-obertki padajut na stderr binarja tolko pri zahvate v pajplajn).
# Progrev odin na vybros (model s HDD v page-cache), potom Reps povtorov, mediana + razbros.
# Latinica namerenno (PS chitaet ANSI).
param(
    [Parameter(Mandatory=$true)][string]   $Model,
    [string[]] $Flags   = @(),
    [string]   $Label   = 'run',
    [int]      $Gen     = 48,
    [int]      $Tokens  = 64,
    [int]      $Threads = 8,
    [int]      $Ctx     = 512,
    [int]      $Reps    = 3,
    [int]      $LimitSec = 1200,
    [string]   $Log     = 'C:\Users\User11\Desktop\MemeX\bench\PEAK_2026-09-08.log',
    [switch]   $External          # zamok u vyzyvajushchego
)
$ErrorActionPreference = 'Continue'
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
$EXE  = 'D:\MemeX\src\ik_llama.cpp\build-bt2022\bin\Release\llama-memex-fwd.exe'
$PROM = 'D:\MemeX\results\prompt_2000.txt'
if (-not (Test-Path $PROM)) { $PROM = 'D:\MemeX\results\prompt_micro.txt' }
function Say($m){ $l=("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'),$m); Write-Host $l; Add-Content -LiteralPath $Log -Value $l -Encoding UTF8 }

if (-not (Test-Path $EXE))   { Say "NET EXE: $EXE"; exit 1 }
if (-not (Test-Path $Model)) { Say "NET MODELI: $Model"; exit 1 }

function RunOnce([int]$gen){
    $so = "D:\MemeX\results\_peak_$Label.out"
    $a = @('-m',$Model,'-f',$PROM,'--tokens',"$Tokens",'-t',"$Threads",'--gen',"$gen",'-c',"$Ctx") + $Flags
    $proc = $null
    try { $proc = Start-Process -FilePath $EXE -ArgumentList $a -WindowStyle Hidden -PassThru `
                  -RedirectStandardOutput $so -RedirectStandardError "$so.err" } catch { return @{err=$_.Exception.Message} }
    if ($null -eq $proc) { return @{err='Start-Process vernul null'} }
    $null = $proc.Handle
    if (-not $proc.WaitForExit($LimitSec*1000)) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; return @{err='tajm-aut'} }
    $out = @()
    if (Test-Path $so)       { $out += Get-Content -LiteralPath $so -Encoding UTF8 }
    if (Test-Path "$so.err") { $out += Get-Content -LiteralPath "$so.err" -Encoding UTF8 }
    $h = $out | Select-String -Pattern '^STATIC_AB ' | Select-Object -First 1
    if ($h -and $h.Line -match 'our_tok_s ([\d.]+)') { return @{tok=[double]$Matches[1]; err=''} }
    $bad = $out | Select-String -Pattern 'not supported|failed|abort|assert|OTKAZ|ne vlez|OOM|bad_alloc' | Select-Object -First 1
    return @{err=$(if($bad){$bad.Line.Trim()}else{"net STATIC_AB (exit $($proc.ExitCode))"})}
}

$owns = -not $External
try {
    if ($owns) { if (-not (Take-Machine -Who "peak-$Label" -TimeoutMin 60 -MinFreeGB 12)) { Say 'mashinu ne poluchili'; exit 1 } }
    Say ("===== $Label :: $([System.IO.Path]::GetFileName($Model)) :: flags=[$($Flags -join ' ')] gen=$Gen tokens=$Tokens ctx=$Ctx")
    Say 'progrev (vybros)...'
    $w = RunOnce ([math]::Min($Gen,16))
    if ($w.err) { Say ("progrev NE POSHJOL: " + $w.err) } else { Say ("progrev {0:N2} tok/s - vybrosheno" -f $w.tok) }
    $vals = @()
    for ($i=1; $i -le $Reps; $i++){
        $r = RunOnce $Gen
        if ($r.err) { Say ("rep $i NE POSHLO: " + $r.err) } else { Say ("rep $i : {0:N2} tok/s" -f $r.tok); $vals += $r.tok }
    }
    if ($vals.Count -ge 1) {
        $sorted = $vals | Sort-Object
        $med = $sorted[[int]([math]::Floor($sorted.Count/2))]
        $mean=($vals|Measure-Object -Average).Average
        $sp = if($vals.Count -ge 2){100.0*(($vals|Measure-Object -Max).Maximum-($vals|Measure-Object -Min).Minimum)/$mean}else{0}
        Say ("ITOG $Label : mediana {0:N2} tok/s  (srednee {1:N2}, razbros {2:N1}%, n={3}){4}" -f $med,$mean,$sp,$vals.Count,$(if($sp -gt 4.2){' RAZBROS'}else{''}))
    } else { Say "ITOG $Label : NET DANNYH" }
} finally { if ($owns) { Free-Machine } }
