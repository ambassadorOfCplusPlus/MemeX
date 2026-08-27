# Removes three programs the owner authorised: OpenCode by name, Docker and Ollama as unused.
#
# Verified unused rather than assumed: Docker Desktop installed 2026-05-30 with an empty image
# store (0.14 GB of service files, no containers), Ollama with no models pulled at all, and neither
# process running. OpenCode was named directly by the owner.
#
# NOT removed, and this matters: the .NET SDK. A second agent shares this machine and builds with
# dotnet; removing it would break their whole night. The Windows SDKs stay too - our own C++ engine
# builds against them.
$before = (Get-PSDrive C).Free
foreach ($id in @('SST.OpenCodeDesktop','Ollama.Ollama','Docker.DockerDesktop')) {
    Write-Output ("  --- udaljaju " + $id)
    $out = winget uninstall --id $id --exact --silent --disable-interactivity --accept-source-agreements 2>&1 | Out-String
    $lines = $out -split "`r?`n" | Where-Object { $_.Trim() }
    Write-Output ("      " + (($lines | Select-Object -Last 2) -join ' | ').Trim())
}
$after = (Get-PSDrive C).Free
Write-Output "  ================================"
Write-Output ("  osvobozhdeno {0:N1} GB, svobodno na C: {1:N1} GB" -f (($after-$before)/1GB), ($after/1GB))
$need = 38.7 * 1GB
if ($after -gt $need) {
    Write-Output ("  4-bitnaja model vlezaet, zapas {0:N1} GB" -f (($after-$need)/1GB))
} else {
    Write-Output ("  4-bitnoj modeli ne hvataet {0:N1} GB" -f (($need-$after)/1GB))
}
