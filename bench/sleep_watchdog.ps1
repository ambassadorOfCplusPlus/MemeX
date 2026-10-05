$log = 'C:\Users\User11\Desktop\MemeX\bench\_sleep_watchdog.log'
"WATCHDOG START $(Get-Date -F 'HH:mm:ss')" | Out-File $log
while ($true) {
  $now = Get-Date
  # deadline 02:55; esli seichas >= 02:55 i < 05:00 (nochnoe okno) - spat
  if ($now.Hour -eq 2 -and $now.Minute -ge 55) { break }
  if ($now.Hour -ge 3 -and $now.Hour -lt 5) { break }
  # stop-fajl otmenjaet son (esli polzovatel vernulsja)
  if (Test-Path 'C:\Users\User11\Desktop\MemeX\bench\_no_sleep') { "otmena: _no_sleep" | Add-Content $log; exit }
  Start-Sleep 60
}
"USYPLJAJU PK $(Get-Date -F 'HH:mm:ss')" | Add-Content $log
# final: ubit tjazhjolye progony chtoby ne meshali
Get-Process llama-memex-fwd -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 3
rundll32.exe powrprof.dll,SetSuspendState 0,1,0
