# Downloads that yield to timing measurements.
#
# The earlier assumption was that a download cannot disturb a benchmark: it uses network and
# disk, and with repacking the model sits in private memory rather than the page cache. That was
# wrong, and measured wrong - three replicates of one configuration taken while a download ran
# spread 17% (11.77/11.66/13.66 tok/s), and the same three taken in silence spread 2.7%
# (13.48/13.15/13.51). Load-time reads of a 15 GB model contend with the transfer for the disk,
# and that is enough.
#
# So this downloader watches for llama-cli - the only binary our scripts use for timing - and
# stops while it runs, resuming afterwards. curl's -C - continues from the current file length,
# so stopping costs nothing but the seconds already in flight. Quantisation and perplexity are
# not timed, so it keeps going through those: the point is to yield to measurements, not to idle.

$ErrorActionPreference = 'Continue'
$LOG  = 'D:\MemeX\results\downloads.log'
$BASE = 'https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF/resolve/main'
$FILE = 'Qwen3-Coder-Next-UD-IQ4_XS.gguf'
$PATH_OUT = "D:\$FILE"
$SIZE = 38430000000        # content-length from the repository tree API
$RESERVE = 25GB            # left free for the quantisation candidates still to be written

function Note($m) { ("[{0}] {1}" -f (Get-Date -Format 'HH:mm'), $m) | Tee-Object -FilePath $LOG -Append }
function Have { if (Test-Path $PATH_OUT) { (Get-Item $PATH_OUT).Length } else { 0 } }
function Timing { [bool](Get-Process -Name 'llama-cli' -ErrorAction SilentlyContinue) }

function StartCurl {
    Start-Process -FilePath 'curl.exe' -WindowStyle Hidden -PassThru `
        -RedirectStandardError 'D:\MemeX\results\dl_polite.err' `
        -ArgumentList @('-L','-C','-','--retry','40','--retry-delay','15','--retry-all-errors',
                        '-s','-S','-o', $PATH_OUT, "$BASE/$FILE")
}

Note ("$FILE : {0:N2} iz {1:N2} GB" -f ((Have)/1GB), ($SIZE/1GB))
if ((Have) -ge $SIZE) { Note 'uzhe polnyj'; exit 0 }

$proc = $null
$last = Have
$stall = 0
$deadline = (Get-Date).AddHours(12)

while ((Get-Date) -lt $deadline) {
    if ((Have) -ge $SIZE) { Note ("GOTOVO: {0:N2} GB" -f ((Have)/1GB)); break }

    # Never fill the disk out from under the measurement queue, which still has quantisation
    # candidates to write. Refusing is a result; a full disk breaks everything at once.
    $free = (Get-PSDrive D).Free
    if ($free -lt (($SIZE - (Have)) + $RESERVE)) {
        Note ("PAUZA: na D: {0:N1} GB, nuzhno {1:N1} plus {2:N0} GB zapasa" -f `
              ($free/1GB), (($SIZE - (Have))/1GB), ($RESERVE/1GB))
        if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; $proc = $null }
        Start-Sleep -Seconds 300
        continue
    }

    if (Timing) {
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
            $proc = $null
            Note ("ustupaju zameru na {0:N2} GB" -f ((Have)/1GB))
        }
        Start-Sleep -Seconds 20
        continue
    }

    if (-not $proc -or $proc.HasExited) {
        $proc = StartCurl
        Note ("kachaju s {0:N2} GB" -f ((Have)/1GB))
        $last = Have
        $stall = 0
    }

    Start-Sleep -Seconds 120
    $now = Have
    if ($now -gt $last) {
        Note ("  {0:N2} GB ({1:N1}%), {2:N1} MB/s" -f ($now/1GB), (100.0*$now/$SIZE), (($now-$last)/1MB/120))
        $last = $now; $stall = 0
    } else {
        $stall++
        # Only give up after an hour of no progress: curl's own retries handle short outages, and
        # a twenty-minute limit killed this transfer once at 86% when the server went quiet.
        if ($stall -ge 30) {
            Note '60 minut bez rosta - ostanavlivaju'
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue }
            break
        }
    }
}

$final = Have
if ($final -ge $SIZE) { Note ("$FILE gotov: {0:N2} GB" -f ($final/1GB)) }
else { Note ("$FILE nepolnyj: {0:N2} iz {1:N2} GB" -f ($final/1GB), ($SIZE/1GB)) }
