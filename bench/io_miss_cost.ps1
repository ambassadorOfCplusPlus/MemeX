# Cena promaha eksperta po kanalam, pod mashinnym zamkom. Zapusk odnim processom:
#   pwsh -File C:\Users\User11\Desktop\MemeX\bench\io_miss_cost.ps1
# Rezultat: D:\MemeX\results\io_miss_cost.txt
param([int]$TimeoutMin = 300)
. C:\Users\User11\Desktop\MemeX\bench\lock.ps1
$out = 'D:\MemeX\results\io_miss_cost.txt'
if (-not (Take-Machine -Who 'io_miss_cost' -TimeoutMin $TimeoutMin)) {
    "NE POLUCHIL MASHINU za $TimeoutMin min" | Tee-Object -FilePath $out
    exit 3
}
try {
    $py = 'C:\Users\User11\Desktop\MemeX\bench\io_miss_cost.py'
    "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm') SSD C: (fajl menshe OZU: kanal mmap nedejstvitelen, ne zaproshen)" | Out-File $out -Encoding utf8
    python $py 'C:\models\Qwen3-Coder-Next-UD-IQ3_XXS.gguf' --sizes 0.32,0.38,1.03 --qd 1,2,4,8,16 --n 64 2>&1 | Out-File $out -Append -Encoding utf8
    "" | Out-File $out -Append -Encoding utf8
    "=== $(Get-Date -Format 'HH:mm') HDD D: IQ4_XS (fajl bolshe OZU: kanal mmap dejstvitelen)" | Out-File $out -Append -Encoding utf8
    python $py 'D:\Qwen3-Coder-Next-UD-IQ4_XS.gguf' --sizes 0.43,0.53,1.39 --qd 1,2,4,8 --n 24 --mmap 2>&1 | Out-File $out -Append -Encoding utf8
    "=== $(Get-Date -Format 'HH:mm') gotovo" | Out-File $out -Append -Encoding utf8
} finally {
    Free-Machine
}
