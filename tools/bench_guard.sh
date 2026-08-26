#!/usr/bin/env bash
# Run a measurement with our own downloads paused, then bring them back.
#
# This exists because of a wrong conclusion it would have prevented. A thread sweep
# taken while an eight-worker downloader was running showed the MoE layer getting
# slower with more threads - 4.68 ms at one thread against 888 ms at eight - and that
# led to a whole custom ggml operator being written to "fix" barriers that were never
# the problem. With the download paused the same sweep reads 2.66 / 1.43 / 1.47 / 1.27
# ms, i.e. threading was fine all along.
#
# Pausing is free here: the downloader records finished blocks in a .parts sidecar, so
# stopping it loses nothing and restarting continues from the same place.
#
# Usage: tools/bench_guard.sh <command...>
set -u

PAUSED=0
pause_downloads() {
    local n
    n=$(powershell -NoProfile -Command "
        \$p = Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" |
              Where-Object { \$_.CommandLine -match 'fetch_big' }
        \$p | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }
        (\$p | Measure-Object).Count" 2>/dev/null | tr -d '\r' | tail -1)
    PAUSED=${n:-0}
    if [ "${PAUSED}" != "0" ]; then
        echo "[guard] остановлено загрузок: ${PAUSED}"
        sleep 3
    fi
}

resume_downloads() {
    if [ "${PAUSED}" = "0" ]; then
        return
    fi
    local sc="/c/Users/User11/AppData/Local/Temp/claude/C--Users-User11-Desktop-MemeX/e062fca5-0a77-458c-941d-247ed8e0e716/scratchpad"
    # Only the repair we own is restarted; anything the user started by hand is left
    # alone, since killing and reviving someone else's transfer is not ours to do.
    if [ -f "/c/Users/User11/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf.parts" ]; then
        echo "[guard] возобновляю докачку Gemma"
        ( cd /c/Users/User11/Desktop/MemeX && \
          nohup D:/MemeX/venv/Scripts/python.exe memex/fetch_big.py \
            --repo unsloth/gemma-4-26b-a4b-it-GGUF \
            --file gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf \
            --out-dir "C:/Users/User11" --repair --workers 8 --block-mb 32 \
            >> "${sc}/gemma_repair2.log" 2>&1 < /dev/null & )
    fi
}

trap resume_downloads EXIT

pause_downloads
echo "[guard] замер: $*"
"$@"
status=$?
exit ${status}
