# Downloads, strictly one at a time.
#
# Two transfers in parallel would split the same 2.3 MB/s rather than add to it, and the 3-bit
# file is half done - finishing it first turns a partial file into a usable model hours sooner.
# Resumes with curl's -C - rather than starting over, which saves 13 GB on the first one.
#
# Runs alongside the measurement queue on purpose: this is network and disk work, and with
# repacking the models under test sit in private memory rather than the page cache, so a
# download cannot evict what is being measured.

$ErrorActionPreference = 'Continue'
$LOG = 'D:\MemeX\results\downloads.log'
$BASE = 'https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF/resolve/main'

function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }

# name, target path, expected bytes (content-length read from the repository tree API)
$jobs = @(
    @{ file = 'Qwen3-Coder-Next-UD-IQ3_XXS.gguf'; path = 'D:\Qwen3-Coder-Next-UD-IQ3_XXS.gguf'; size = 28489000000 },
    @{ file = 'Qwen3-Coder-Next-UD-IQ4_XS.gguf';  path = 'D:\Qwen3-Coder-Next-UD-IQ4_XS.gguf';  size = 38430000000 }
)

foreach ($j in $jobs) {
    $have = if (Test-Path $j.path) { (Get-Item $j.path).Length } else { 0 }
    if ($have -ge $j.size) { Note ("{0}: uzhe polnyj ({1:N2} GB)" -f $j.file, ($have/1GB)); continue }

    # Refuse rather than fill the disk: leave room for the quantisation candidates the
    # measurement queue is going to write.
    $free = (Get-PSDrive D).Free
    $need = $j.size - $have
    if ($free -lt ($need + 30GB)) {
        Note ("{0}: OTKAZ, na D: {1:N1} GB, nuzhno {2:N1} GB plus 30 GB zapasa pod kvantovanija" -f `
              $j.file, ($free/1GB), ($need/1GB))
        continue
    }

    Note ("{0}: kachaju s {1:N2} GB do {2:N2} GB" -f $j.file, ($have/1GB), ($j.size/1GB))
    $p = Start-Process -FilePath 'curl.exe' -WindowStyle Hidden -PassThru `
             -RedirectStandardError ('D:\MemeX\results\dl_' + $j.file + '.err') `
             -ArgumentList @('-L','-C','-','--retry','40','--retry-delay','15','--retry-all-errors',
                             '-s','-S','-o', $j.path, ($BASE + '/' + $j.file))
    # Watch progress and give up only if the file genuinely stops growing for 20 minutes -
    # curl's own retries handle short interruptions, and this machine has already had one.
    $last = $have; $stall = 0
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 120
        $now = if (Test-Path $j.path) { (Get-Item $j.path).Length } else { 0 }
        if ($now -gt $last) {
            Note ("  {0:N2} GB ({1:N1}%), {2:N1} MB/s" -f ($now/1GB), (100.0*$now/$j.size), (($now-$last)/1MB/120))
            $last = $now; $stall = 0
        } else {
            $stall++
            if ($stall -ge 10) { Note '  20 minut bez rosta - ostanavlivaju'; Stop-Process -Id $p.Id -Force -EA SilentlyContinue; break }
        }
    }
    $final = if (Test-Path $j.path) { (Get-Item $j.path).Length } else { 0 }
    if ($final -ge $j.size) { Note ("{0}: GOTOVO, {1:N2} GB" -f $j.file, ($final/1GB)) }
    else { Note ("{0}: nepolnyj, {1:N2} iz {2:N2} GB" -f $j.file, ($final/1GB), ($j.size/1GB)) }
}
Note 'ochered zagruzok zavershena'
