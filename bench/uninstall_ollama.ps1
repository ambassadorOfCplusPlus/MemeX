# Ollama did not come off through winget's silent path. Fall back to its own uninstaller, which is
# what winget would have invoked anyway - the difference is that here we can see it fail.
$before = (Get-PSDrive C).Free
$done = $false
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    foreach ($i in (Get-ItemProperty $k -ErrorAction SilentlyContinue)) {
        if ($i.DisplayName -notmatch 'Ollama') { continue }
        Write-Output ("  najden: " + $i.DisplayName + "  ->  " + $i.UninstallString)
        if (-not $i.UninstallString) { continue }
        $s = $i.UninstallString.Trim('"')
        if (Test-Path -LiteralPath $s) {
            Start-Process -FilePath $s -ArgumentList '/S' -Wait -ErrorAction SilentlyContinue
            $done = $true
        }
    }
}
if (-not $done) { Write-Output "  shtatnyj deinstalljator ne najden ili ne zapustilsja" }
$after = (Get-PSDrive C).Free
Write-Output ("  svobodno na C: {0:N1} GB (izmenenie {1:N1} GB)" -f ($after/1GB), (($after-$before)/1GB))
