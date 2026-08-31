# Nabljudatel za bibliotekami v oboih derevjah.
#
# ZACHEM. ggml.dll ischezala ili podmenjalas chetyre raza, i ni odin raz prichinu ne udalos najti
# retrospektivno: kopija sohranjaet otmetku vremeni, tak chto data fajla nichego ne govorit o
# momente podmeny. Posledinj sluchaj - v build-vk okazalas ggml.dll na 67 KB ot 26 ijunja vmesto
# 46 MB, binarnik padal na zagruzchike s -1073741511, i logi prihodili PUSTYMI.
#
# Etot skript pishet razmer i vremja kazhdye 30 sekund. Sledujushchij sluchaj okazhetsja zazhat
# mezhdu dvumja zapisjami, i togda budet vidno, chto rabotalo v etot promezhutok.
$LOG = 'D:/MemeX/results/dll_watch.log'
$paths = @(
    'D:/MemeX/src/ik_llama.cpp/build/bin/Release/ggml.dll',
    'D:/MemeX/src/ik_llama.cpp/build/bin/Release/llama.dll',
    'D:/MemeX/src/ik_llama.cpp/build-vk/bin/Release/ggml.dll',
    'D:/MemeX/src/ik_llama.cpp/build-vk/bin/Release/llama.dll'
)
$last = @{}
while ($true) {
    foreach ($p in $paths) {
        $now = if (Test-Path -LiteralPath $p) {
            $f = Get-Item -LiteralPath $p
            ("{0} {1:yyyy-MM-dd HH:mm:ss}" -f $f.Length, $f.LastWriteTime)
        } else { 'NET' }
        if ($last[$p] -ne $now) {
            # Tolko izmenenija. Rovnaja stroka kazhdye polminuty utopila by fakt v shume.
            $who = (Get-Process | Where-Object { $_.Name -match 'cl|MSBuild|cmake|link|powershell|llama' } |
                    ForEach-Object { $_.Name + '/' + $_.Id }) -join ','
            ("[{0:HH:mm:ss}] {1} : {2} -> {3} | zhivy: {4}" -f (Get-Date), $p, $last[$p], $now, $who) |
                Add-Content -LiteralPath $LOG
            $last[$p] = $now
        }
    }
    Start-Sleep -Seconds 30
}
