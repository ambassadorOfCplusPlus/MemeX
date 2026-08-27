# Единственный способ собирать этот проект. Через него, а не голым cmake.
#
# Почему он существует. Трижды за проект из `build\bin\Release` исчезала `ggml.dll`, и первый раз
# это стоило ночи: CMake считает цели готовыми, обычная пересборка — пустышка, а бинарники падают
# на загрузчике Windows ДО первой строки вывода. Логи приходят пустыми, и это читается как «прогон
# не дал данных», а не «прогон не состоялся».
#
# Причина найдена и она неприятная: **`--clean-first` сначала удаляет всё, что цель производит**, и
# только потом собирает. То есть лекарство, прописанное после первой аварии, стало причиной второй
# и третьей — между удалением и концом сборки дерево заведомо сломано, и если в это окно сборку
# прервать (кончилась сессия, убили процесс, отключили свет — у нас было всё три), оно таким и
# остаётся.
#
# Отсюда три правила, которые этот скрипт исполняет вместо человека:
#   1. Собирать под машинным замком. Полная сборка занимает четыре ядра на десять минут, и делать
#      это при свободном замке — то же самое, что портить чужой замер молча. Один раз уже так вышло.
#   2. После сборки проверять ЗАПУСКАЕМОСТЬ, а не код возврата cmake. Сборка, завершившаяся успехом
#      и оставившая незагружаемое дерево, хуже упавшей: отказ всплывает через три шага в чужой
#      работе.
#   3. `--clean-first` применять только к полной цепочке ggml → llama → бинарники, никогда к одной
#      цели. Чистка одной цели гарантирует окно, в котором остальные ссылаются на удалённое.

param(
    [string[]]$Targets = @('llama-cli'),
    [string]  $Dir     = 'D:\MemeX\src\ik_llama.cpp\build',
    [switch]  $Clean,
    [int]     $Jobs    = 4,
    [int]     $LockMin = 120,
    [switch]  $NoLock          # только если замок уже держит вызывающий
)

$ErrorActionPreference = 'Continue'
. 'C:\Users\User11\Desktop\MemeX\bench\lock.ps1'

$bin = Join-Path $Dir 'bin\Release'

function Say($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m) }

# Запускаемость — единственная проверка, которой можно верить. Коды, которые стоит узнавать в лицо:
#   -1073741511  точка входа не найдена: DLL не соответствует exe, то есть пересобрали половину
#   -1073741515  DLL не найдена вовсе
function Test-Startable([string]$exe) {
    if (-not (Test-Path -LiteralPath $exe)) { return "нет файла" }
    $null = & $exe --version 2>&1
    switch ($LASTEXITCODE) {
        0           { return $null }
        -1073741511 { return "точка входа не найдена (DLL не соответствует exe)" }
        -1073741515 { return "DLL не найдена" }
        default     { return "код выхода $LASTEXITCODE" }
    }
}

function Invoke-Build([string[]]$t, [switch]$c) {
    $a = @('--build', $Dir, '--config', 'Release', '-j', "$Jobs")
    foreach ($x in $t) { $a += @('--target', $x) }
    if ($c) { $a += '--clean-first' }
    & cmake @a 2>&1 | Select-Object -Last 2 | ForEach-Object { Say ("  " + $_) }
    return $LASTEXITCODE
}

$held = $false
if (-not $NoLock) {
    Say "беру машину под сборку"
    if (-not (Take-Machine -Who 'build' -TimeoutMin $LockMin)) { Say "машину не получили"; exit 1 }
    $held = $true
}

try {
    # Чистая сборка идёт всей цепочкой сразу. Порознь нельзя: между удалением ggml.dll и её
    # появлением всё, что на неё ссылается, незагружаемо.
    $chain = if ($Clean) { @('ggml','llama') + $Targets } else { $Targets }
    Say ("собираю: " + ($chain -join ', ') + $(if ($Clean) { " (с чисткой)" } else { "" }))
    $rc = Invoke-Build $chain -c:$Clean

    if ($rc -ne 0) { Say "cmake вернул $rc"; exit $rc }

    # Вот ради чего всё. cmake сказал «успех» — это ещё ничего не значит.
    $bad = @()
    foreach ($t in $Targets) {
        $exe = Join-Path $bin ($t + '.exe')
        $why = Test-Startable $exe
        if ($why) { $bad += "$t : $why" } else { Say "  $t запускается" }
    }

    if ($bad.Count -gt 0) {
        foreach ($b in $bad) { Say "  НЕ ЗАПУСКАЕТСЯ: $b" }
        Say "чиню полной пересборкой цепочки — это ровно тот случай, ради которого скрипт написан"
        $rc = Invoke-Build (@('ggml','llama') + $Targets) -c
        if ($rc -ne 0) { Say "починка не удалась, cmake вернул $rc"; exit $rc }
        $still = @()
        foreach ($t in $Targets) {
            $why = Test-Startable (Join-Path $bin ($t + '.exe'))
            if ($why) { $still += "$t : $why" }
        }
        if ($still.Count -gt 0) {
            foreach ($s in $still) { Say "  ВСЁ ЕЩЁ НЕ ЗАПУСКАЕТСЯ: $s" }
            exit 1
        }
        Say "после починки всё запускается"
    }
    Say "сборка годна"
} finally {
    if ($held) { Free-Machine; Say "машина освобождена" }
}
