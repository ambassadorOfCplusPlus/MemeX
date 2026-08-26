# Move folders off the SSD to D:, leaving a junction where an application needs
# the original path. A folder is deleted from the source only after robocopy
# reports zero files left behind, so an interrupted copy never loses data.
param(
    [switch]$WhatIf
)

$plan = @(
    @{ Src = "$env:USERPROFILE\Desktop\llama.cpp";  Dst = 'D:\from-desktop\llama.cpp';  Junction = $false }
    @{ Src = "$env:USERPROFILE\Desktop\w64devkit";  Dst = 'D:\from-desktop\w64devkit';  Junction = $false }
    @{ Src = "$env:USERPROFILE\Desktop\скан";        Dst = 'D:\from-desktop\скан';        Junction = $false }
    @{ Src = "$env:USERPROFILE\Desktop\сканирование"; Dst = 'D:\from-desktop\сканирование'; Junction = $false }
    @{ Src = "$env:APPDATA\SmartStock";              Dst = 'D:\SmartStock-appdata';        Junction = $true }
)

foreach ($item in $plan) {
    $src = $item.Src
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "нет: $src"; continue }
    # Never touch a path that is already a link
    $info = Get-Item -LiteralPath $src -Force
    if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Host "уже ссылка, пропуск: $src"; continue
    }
    $sizeGb = [math]::Round(((Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Sum Length).Sum) / 1GB, 2)
    Write-Host "перенос $src -> $($item.Dst)  ($sizeGb GB)"
    if ($WhatIf) { continue }

    & robocopy $src $item.Dst /MOVE /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null

    $left = (Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object).Count
    if ($left -ne 0) {
        Write-Host "  ОСТАВЛЕНО: в источнике ещё $left файлов, ничего не удаляю"
        continue
    }
    Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $src) {
        Write-Host "  файлы перенесены, но пустые папки источника остались"
        continue
    }
    if ($item.Junction) {
        & cmd /c mklink /J "$src" "$($item.Dst)" | Out-Null
        Write-Host "  готово + junction на прежнем пути"
    } else {
        Write-Host "  готово"
    }
}

$free = (Get-PSDrive C).Free / 1GB
Write-Host ("C: свободно {0:N1} GB" -f $free)
