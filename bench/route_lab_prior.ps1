# Zatravka holodnogo starta: osnovnoj sled s zatravkoj iz trjoh chuzhih tekstov, i naoborot
# (sled koda s zatravkoj iz ostalnyh). Pod zamkom, odnim processom.
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$R = 'D:\MemeX\results'
if (-not (Take-Machine -Who 'route_lab_prior' -TimeoutMin 240)) { 'NE POLUCHIL' > "$R\route_lab_prior.txt"; exit 3 }
try {
  $py = 'C:\Users\User11\Desktop\MemeX\bench\route_lab.py'
  python $py "$R\route_trace.bin" --prior "$R\route_trace_code.bin" --prior "$R\route_trace_ru.bin" --prior "$R\route_trace_tech.bin" --resident 128,192,256,320,410 --prefetch 10,16,32 --ks 1 > "$R\route_lab_prior.txt" 2>&1
  python $py "$R\route_trace_code.bin" --prior "$R\route_trace.bin" --prior "$R\route_trace_ru.bin" --prior "$R\route_trace_tech.bin" --resident 128,192,256,320,410 --prefetch 10,16,32 --ks 1 > "$R\route_lab_prior_code.txt" 2>&1
} finally { Free-Machine }
