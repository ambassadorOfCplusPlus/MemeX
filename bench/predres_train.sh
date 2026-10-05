#!/bin/bash
# Obuchenie MLP-predskazatelja (MXPR) na sobrannyh dampah: wp+docs+code obuchenie (hvost - kontrol), gen - tolko kontrol.
OUT=D:/MemeX/results/predres; B=C:/Users/User11/Desktop/MemeX/bench
{
echo "##### TRAIN $(date +%H:%M:%S)"
D:/Python311/python.exe $B/pred_train.py fit --dump $OUT/dump_wp.bin --dump $OUT/dump_docs.bin --dump $OUT/dump_code.bin \
  --eval-dump $OUT/dump_gen.bin --routers $OUT/dump_code.bin.routers --out $OUT/ds4_pred.bin --depth 4 --hidden 256 --steps 400 --budgets 6,8,10,16
echo "##### TRAIN DONE $(date +%H:%M:%S) $?"
} >> $OUT/train.log 2>&1
