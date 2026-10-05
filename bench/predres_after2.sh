#!/bin/bash
until tail -n +116 D:/MemeX/results/predres/pipeline.log 2>/dev/null | grep -q "FOLLOWUP DONE"; do sleep 60; done
echo "--- ab_pred $(date +%H:%M:%S)" >> D:/MemeX/results/predres/pipeline.log
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/User11/Desktop/MemeX/bench/with_lock.ps1 -Who predres-ab-pred -Script C:/Users/User11/Desktop/MemeX/bench/predres_ab_pred.sh -TimeoutMin 480 >> D:/MemeX/results/predres/pipeline.log 2>&1
echo "##### AB_PRED DONE $(date +%H:%M:%S)" >> D:/MemeX/results/predres/pipeline.log
