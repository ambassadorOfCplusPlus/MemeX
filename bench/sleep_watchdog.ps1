# Esli rabota oborvalas - ulozhit PK spat, chtoby on ne zhjog elektrichestvo vsju noch.
#
# CHTO SCHITAETSJA "rabota idjot": libo zhivjot process llama-memex-fwd (dolgij zamer mozhet
# idti 40 minut bez edinogo obnovlenija fajla), libo heartbeat svezhee poroga. Poetomu porog
# shchedryj: 90 minut polnoj tishiny. Zamer, kotoryj idjot, PK ne usypit.
#
# ESCAPE. Fajl D:\MemeX\results\.no-sleep otklyuchaet storozha nasovsem - polzovatel mozhet
# sozdat ego rukoj i nichego ne sluchitsja. Eto vazhnee, chem tochnost: usypit mashinu poseredine
# raboty huzhe, chem ne usypit vovse.
param(
    [int] $IdleMin  = 90,
    [int] $CheckSec = 300
)
$HB   = 'D:\MemeX\results\.heartbeat'
$STOP = 'D:\MemeX\results\.no-sleep'
$LOG  = 'D:\MemeX\results\sleep_watchdog.log'
function Say($m) {
    $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -LiteralPath $LOG -Value $l -Encoding UTF8
}
Say "storozh zapushchen: porog tishiny $IdleMin min, proverka kazhdye $CheckSec s"
while ($true) {
    Start-Sleep -Seconds $CheckSec
    if (Test-Path -LiteralPath $STOP) { Say 'najden .no-sleep - storozh vyhodit'; break }
    $busy = @(Get-Process -Name 'llama-memex-fwd' -ErrorAction SilentlyContinue).Count -gt 0
    if ($busy) { continue }
    $age = 1e9
    if (Test-Path -LiteralPath $HB) {
        $t = [int64](Get-Content -LiteralPath $HB -TotalCount 1)
        $age = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $t) / 60.0
    }
    if ($age -ge $IdleMin) {
        Say ("tishina {0:N0} min i ni odnogo zamera - uklyudyvayu PK spat" -f $age)
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) | Out-Null
        Say 'PK vernulsja iz sna - storozh prodolzhaet'
    }
}
