#!/bin/bash
# Zhdjot konca konvejera (stroka PIPELINE DONE posle stroki 64) i zapuskaet obuchenie predskazatelja pod zamkom.
until tail -n +65 D:/MemeX/results/predres/pipeline.log 2>/dev/null | grep -q "PIPELINE DONE"; do sleep 60; done
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/User11/Desktop/MemeX/bench/with_lock.ps1 -Who predres-train -Script C:/Users/User11/Desktop/MemeX/bench/predres_train.sh -TimeoutMin 240 >> D:/MemeX/results/predres/pipeline.log 2>&1
