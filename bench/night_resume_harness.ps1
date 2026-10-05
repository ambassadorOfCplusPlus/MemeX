# HARNESS perezhivajushchij sbros limita ispolzovanija Claude. Zapuskaetsja DETACHED.
# Logika: esli zhivaja sessija rabotaet (svezhij heartbeat) - ne meshaem. Esli sessija umerla
# (heartbeat star ILI net) - zapuskaem `claude -p` chtoby prodolzhit nochnoj plan iz pamjati.
# Pri limite - lovim vremja sbrosa i cherez 60s posle sbrosa - snova. Zhjostkie relsy:
#   - stop-fajl _night_stop otmenjaet vsjo (polzovatel mozhet sozdat kogda prosnjotsja)
#   - potolok ciklov (16) i vremeni (8 chasov)
#   - kazhdyj claude -p delaet ODIN shag i vozvrashchaetsja (ne loop vnutri)
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\User11\Desktop\MemeX'
$hb   = "$root\bench\_night_heartbeat"
$stop = "$root\bench\_night_stop"
$log  = "$root\bench\_night_harness.log"
function L($m){ "$((Get-Date).ToString('HH:mm:ss')) $m" | Out-File -Append -Encoding UTF8 $log }
$prompt = 'Nochnoj avtoprogon MemeX. Prochti MEMORY.md i STATE.md, sverjsja s night-plan-2026-09-07. Vypolni SLEDUJUSHCHIJ odin proverjaemyj shag nochnogo plana (vnedrenie arh llama/Mixtral i deepseek4; optimizacija fit+nonfit, statika na kartu, odna Vulkan-ochered na token; polnyj revju; OBJAZATELNO zapusk+zamer). Kazhdaja pravka - build_safe + regressija 16/16. Sohrani progress v STATE i pamjat. NE usypljaj PK poka plan ne vypolnen. Sdelaj shag i zavershis (bez vnutrennego cikla).'
L "HARNESS START"
$claude = (Get-Command claude -EA SilentlyContinue).Source
if (-not $claude) { L "claude CLI ne najden v PATH - harness ne mozhet zapuskat sessii. Vyhod."; exit }
$startT = Get-Date
for ($i=0; $i -lt 16; $i++) {
  if (Test-Path $stop) { L "stop-fajl najden - ostanovka"; break }
  if (((Get-Date) - $startT).TotalHours -ge 8) { L "8 chasov proshlo - ostanovka"; break }
  # zhivaja sessija? svezhij heartbeat (<65 min) = ne meshaem
  $fresh = (Test-Path $hb) -and ((Get-Date) - (Get-Item $hb).LastWriteTime).TotalMinutes -lt 90
  if ($fresh) { L "zhivaja sessija aktivna (heartbeat svezh) - propuskaju cikl, splju 20 min"; Start-Sleep 1200; continue }
  L "sessija ne aktivna - zapuskaju claude -p (cikl $i)"
  $out = & $claude -p $prompt 2>&1 | Out-String
  ($out.Substring(0,[Math]::Min(2000,$out.Length))) | Out-File -Append -Encoding UTF8 $log
  # detekt limita
  if ($out -match '(?i)usage limit|rate limit|limit reached|resets? at|try again|too many requests') {
    $sleepS = 3600
    if ($out -match '(?i)reset[s]?\s+at\s+(\d{1,2}):(\d{2})') {
      $now=Get-Date; $rt=Get-Date -Hour ([int]$Matches[1]) -Minute ([int]$Matches[2]) -Second 0
      if ($rt -le $now) { $rt=$rt.AddDays(1) }
      $sleepS = [int]([Math]::Max(60, ($rt - $now).TotalSeconds)) + 60  # +1 min posle sbrosa
      L "LIMIT: sbros v $($rt.ToString('HH:mm')), splju do sbrosa+60s ($sleepS s)"
    } else { L "LIMIT bez vremeni - splju 60 min"; }
    Start-Sleep $sleepS
  } else {
    L "cikl $i ok - splju 55 min do sledujushchego budilnika"; Start-Sleep 3300
  }
}
L "HARNESS END"
