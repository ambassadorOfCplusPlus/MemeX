# Gibridnyj zagruzchik: VPN(huggingface.co) + prjamoj(hf-mirror.com) parallelno = ~13,6 MB/s.
# Kanaly fizicheski nezavisimy (VPN-tunnel vs syroj Ethernet), skladyvajutsja. NE nuzhen admin.
# Prichina: HF-naprjamuju dushit DPI (3 KB/s); zerkalo ~3,6 MB/s; VPN 10 MB/s odnim potokom.
param(
  [Parameter(Mandatory)][string]$RepoPath,   # naprimer: unsloth/DeepSeek-.../resolve/main/.../file.gguf
  [Parameter(Mandatory)][string]$OutFile,     # kuda sohranit (D:\...)
  [double]$VpnFrac = 0.73                      # dolja cherez VPN (10/13.6); ostatok - prjamo s zerkala
)
$ErrorActionPreference = 'Stop'
$ethIp = '192.168.50.222'                       # Ethernet IP dlja obhoda VPN
$hfUrl  = "https://huggingface.co/$RepoPath"
$mirUrl = "https://hf-mirror.com/$RepoPath"     # transparentnyj proksi HF = BAJT-IDENTICHEN
# 1) uznat polnyj razmer (cherez VPN - nadjozhno)
$len = [int64]((curl.exe -sIL $hfUrl | Select-String -Pattern 'content-length:\s*(\d+)' | Select-Object -Last 1).Matches.Groups[1].Value)
if ($len -le 0) { throw "ne uznal razmer" }
$split = [int64]([math]::Floor($len * $VpnFrac))
Write-Host "razmer $([math]::Round($len/1GB,2)) GB; VPN [0..$split), prjamo [$split..$len)"
$pA = "$OutFile.vpnpart"; $pB = "$OutFile.dirpart"
# 2) dva potoka parallelno, kazhdyj svoj range v svoj fajl (bez peresechenij, bez porchi)
$jA = Start-Job { param($u,$o,$s) curl.exe -sL -C - -r "0-$($s-1)" -o $o $u } -ArgumentList $hfUrl,$pA,$split
$jB = Start-Job { param($u,$o,$s,$e,$ip) curl.exe -sL -C - --interface $ip -r "$s-$($e-1)" -o $o $u } -ArgumentList $mirUrl,$pB,$split,$len,$ethIp
# progress
while (($jA.State -eq 'Running') -or ($jB.State -eq 'Running')) {
  Start-Sleep 15
  $a = if (Test-Path $pA) { (Get-Item $pA).Length } else { 0 }
  $b = if (Test-Path $pB) { (Get-Item $pB).Length } else { 0 }
  Write-Host ("  VPN {0:N0}/{1:N0} MB | prjamo {2:N0}/{3:N0} MB" -f ($a/1MB),($split/1MB),($b/1MB),(($len-$split)/1MB))
}
Receive-Job $jA; Receive-Job $jB; Remove-Job $jA,$jB
# 3) proverka razmerov chastej + sklejka
$szA = (Get-Item $pA).Length; $szB = (Get-Item $pB).Length
if ($szA -ne $split -or $szB -ne ($len-$split)) { throw "chasti nepolnye: A=$szA/$split B=$szB/$($len-$split)" }
cmd /c copy /b "`"$pA`"+`"$pB`"" "`"$OutFile`"" | Out-Null
if ((Get-Item $OutFile).Length -ne $len) { throw "sklejka nepolnaja" }
Remove-Item $pA,$pB
Write-Host "GOTOVO: $OutFile ($([math]::Round($len/1GB,2)) GB). Proverit sha256 otdelno (certutil)."
