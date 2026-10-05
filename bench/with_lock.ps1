# Vzjat mashinnyj zamok, vypolnit odin bash-skript (tjazhjolyj progon), otpustit zamok.
# Sam progon pishet svoi logi vnutri skripta (bash-redirect, ne PowerShell: pwsh padaet na
# dvoichnom stderr). Latinica namerenno.
param(
    [Parameter(Mandatory=$true)][string] $Who,
    [Parameter(Mandatory=$true)][string] $Script,
    [int] $TimeoutMin = 600,
    [int] $MinFreeGB = 0
)
. 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
function Say($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
if (-not (Take-Machine -Who $Who -TimeoutMin $TimeoutMin -MinFreeGB $MinFreeGB)) { Say "NE POLUCHIL MASHINU ($Who)"; exit 3 }
try {
    Say "zamok vzjat: $Who -> bash $Script"
    & 'C:/Program Files/Git/bin/bash.exe' $Script
    Say ("bash zavershjon kod {0}" -f $LASTEXITCODE)
} finally { Free-Machine; Say 'zamok otpushchen' }
