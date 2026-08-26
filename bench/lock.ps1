# One owner of the machine at a time. Dot-source this and call Take-Machine / Free-Machine.
#
# Why a lock and not another resource check. Over one day this project lost roughly five hours to
# four different collisions, and each fix caught the previous case and missed the next:
#
#   * "no model process running"      -> two waiting scripts saw the same silence and started together
#   * "no compiler running"           -> idle MSBuild node-reuse daemons froze the queue for 2.5 hours
#   * "no sibling bench script"       -> a child deadlocked against its own parent orchestrator
#   * "at least 18 GB free"           -> a 7 GB and a 15 GB process each passed the gate alone
#
# The last one is the giveaway: every resource test asks "is there room for me", and two honest
# answers can both be yes. Ownership is not a resource question. A lock asks "does anyone else
# hold the right", which has exactly one answer.
#
# The file holds the PID, so a holder that died - a crash, a kill, a power cut, all of which
# happened today - is detected and its lock broken rather than blocking everything forever.

$script:MEMEX_LOCK = 'D:\MemeX\results\.machine.lock'
$script:MEMEX_HELD  = $false

function Test-LockAlive {
    if (-not (Test-Path -LiteralPath $script:MEMEX_LOCK)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $script:MEMEX_LOCK -Raw -ErrorAction Stop
        $pidText = ($raw -split '\|')[0]
        $holder = 0
        if (-not [int]::TryParse($pidText.Trim(), [ref]$holder)) { return $false }
        if ($holder -eq $PID) { return $false }          # our own lock is not a competitor
        return [bool](Get-Process -Id $holder -ErrorAction SilentlyContinue)
    } catch { return $false }                            # unreadable or half-written: treat as stale
}

# Returns $true once the machine is ours. $TimeoutMin bounds the wait so a caller can report
# "did not get the machine" rather than hanging - a hang cost thirteen hours here once.
function Take-Machine {
    param([string]$Who = 'unknown', [int]$TimeoutMin = 480, [int]$MinFreeGB = 0)
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        if (Test-LockAlive) { Start-Sleep -Seconds 30; continue }
        # Stale or absent: claim it. CreateNew makes the claim atomic between two racers.
        try {
            $fs = [IO.File]::Open($script:MEMEX_LOCK, 'Create', 'Write', 'None')
            $bytes = [Text.Encoding]::UTF8.GetBytes("$PID|$Who|" + (Get-Date -Format 'HH:mm:ss'))
            $fs.Write($bytes, 0, $bytes.Length); $fs.Close()
        } catch { Start-Sleep -Seconds 15; continue }     # someone else won the race
        # Memory is still worth checking, but now as a precondition rather than as the gate: the
        # lock decides who runs, this decides whether running is worth anything.
        if ($MinFreeGB -gt 0) {
            $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
            if ($free -lt $MinFreeGB) {
                Remove-Item -LiteralPath $script:MEMEX_LOCK -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 60
                continue
            }
        }
        if ((Test-ForeignModel) -or (Test-ForeignBuild) -or (Test-ForeignLoad)) {
            Remove-Item -LiteralPath $script:MEMEX_LOCK -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 45
            continue
        }
        $script:MEMEX_HELD = $true
        return $true
    }
    return $false
}

function Free-Machine {
    if (-not $script:MEMEX_HELD) { return }
    try {
        $raw = Get-Content -LiteralPath $script:MEMEX_LOCK -Raw -ErrorAction Stop
        if (($raw -split '\|')[0].Trim() -eq "$PID") {
            Remove-Item -LiteralPath $script:MEMEX_LOCK -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    $script:MEMEX_HELD = $false
}

function Get-LockHolder {
    if (-not (Test-Path -LiteralPath $script:MEMEX_LOCK)) { return 'svoboden' }
    try { return (Get-Content -LiteralPath $script:MEMEX_LOCK -Raw).Trim() } catch { return 'nechitaem' }
}

# The lock is necessary and not sufficient, because it only binds the scripts that call it.
# Three scripts in this queue predate it - spec_study, resume_all, master - and one of them was
# midway through a measurement, holding 12.6 GB, when a lock-aware script claimed the machine and
# was about to start a run on top of it. Ownership answers "does anyone else hold the right"; it
# cannot answer "is anyone else already working without asking". Until every script takes the lock,
# both questions have to be asked, so a claim also requires that no model process is running.
#
# This is deliberately blunt: at claim time we have not started anything ourselves, so any model
# process at all is someone else's.
# A compile is foreign work too, and it is the participant nobody enrolled. A reference arm was
# measured at 9.95 tok/s with a 34% spread while cl.exe burned cores for a subagent's build - the
# lock was held correctly and the machine was still not quiet.
#
# Judged by CPU-time delta rather than by existence, because judging compilers by existence is the
# mistake that froze this queue for 2.5 hours: MSBuild keeps node-reuse daemons alive between
# builds, and they sit there consuming nothing. A process that has not accumulated CPU over a
# sampling interval is not compiling, whatever its name is.
function Test-ForeignBuild {
    param([int]$SampleMs = 1500, [double]$MinCpuSec = 0.4)
    # Imena nazvany sosedom po mashine, i eto ne dogadka: `dotnet build` NE sozdajot processa
    # MSBuild.exe. Sborka .NET SDK idjot vnutri dotnet.exe (MSBuild tam bibliotekoj), a C#
    # kompiliruet otdelnyj rezidentnyj server VBCSCompiler.exe. Ni togo, ni drugogo v spiske ne
    # bylo - poetomu proverka chestno otvechala "chisto", poka sosed zhjog vosem potokov i portil
    # chetyre tablicy zamerov podrjad.
    #
    # VBCSCompiler - tot zhe sluchaj, chto node-reuse demony MSBuild: on zhivjot mezhdu sborkami i
    # prostaivaet. Sud po prirostu processornogo vremeni s nim spravljaetsja verno, a sud po
    # nalichiju zamorozil by ochered tak zhe, kak odnazhdy na 2.5 chasa.
    #
    # java - na budushchee: sborka Android cherez gradlew pojdjot pod nim i opjat mimo spiska.
    $names = 'cl','MSBuild','msbuild','dotnet','VBCSCompiler','java','cmake','ninja','link','lib','rc','cl_arm64'
    $before = @{}
    foreach ($pr in Get-Process -Name $names -ErrorAction SilentlyContinue) {
        try { $before[$pr.Id] = $pr.CPU } catch { }
    }
    if ($before.Count -eq 0) { return $false }
    Start-Sleep -Milliseconds $SampleMs
    foreach ($pr in Get-Process -Name $names -ErrorAction SilentlyContinue) {
        try {
            if ($before.ContainsKey($pr.Id) -and ($pr.CPU - $before[$pr.Id]) -ge $MinCpuSec) { return $true }
        } catch { }
    }
    return $false
}

function Test-ForeignModel {
    foreach ($n in @('llama-cli','llama-perplexity','llama-quantize','llama-imatrix','llama-moe-trace',
                     'llama-bench','llama-memex-fwd','llama-memex-test','llama-memex-kv',
                     'memex-test','memex-qerr')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# Kto zabiraet jadra PRJAMO SEJCHAS - po prirostu processornogo vremeni, i bez spiska imjon.
#
# Zachem eto ponadobilos. Ves vecher zamery guljali na 8-35% pri poroge shuma 4.2, i ja trizhdy
# proverjal "tihaja li mashina" spiskom processov po imenam: cl, MSBuild, link, cmake, ninja.
# Sborka drugogo proekta drugim instrumentom v takoj filtr ne popadaet vovse. Ja iskal tu pomehu,
# kotoruju ozhidal, a ne pomehu voobshche.
#
# Prirost, a ne nalichie - potomu chto MSBuild derzhit prostaivajushchih demonov, kotorye odnazhdy
# zamorozili etu ochered na 2.5 chasa. I bez spiska imjon - potomu chto imja govorit o tom, chto
# process soboj predstavljaet, a ne o tom, skolko on jest.
function Get-CpuHogs {
    param([int]$SampleMs = 2000, [double]$MinPct = 8.0, [int]$Top = 6)
    $ncpu = [Environment]::ProcessorCount
    $before = @{}
    foreach ($p in Get-Process -EA SilentlyContinue) { try { $before[$p.Id] = @($p.ProcessName, $p.CPU) } catch {} }
    Start-Sleep -Milliseconds $SampleMs
    $out = @()
    foreach ($p in Get-Process -EA SilentlyContinue) {
        try {
            if (-not $before.ContainsKey($p.Id)) { continue }
            $d = $p.CPU - $before[$p.Id][1]
            if ($d -le 0) { continue }
            $pct = 100.0 * $d / ($SampleMs / 1000.0) / $ncpu
            if ($pct -ge $MinPct) { $out += [pscustomobject]@{ Name = $p.ProcessName; Id = $p.Id; Pct = $pct } }
        } catch {}
    }
    return $out | Sort-Object Pct -Descending | Select-Object -First $Top
}

# Tot zhe vopros, no odnim otvetom: est li chuzhaja nagruzka krome nashej sobstvennoj.
function Test-ForeignLoad {
    # Sobstvennaja infrastruktura v spisok vhodit objazatelno, i eto ne udobstvo, a uslovie
    # korrektnosti. Odin odnopotochnyj claude - eto 12.5% ot vosmi jader, to est vyshe poroga.
    # Bez etoj stroki Take-Machine zajavljaet zamok, vidit agenta, kotoryj vypolnjaet zaprosivshij
    # skript, udaljaet svoj zhe zamok i uhodit na povtor - i tak do konca tajm-auta. Prosjashchij
    # process po postroeniju zanjat imenno v etot moment, potomu chto on i est tot, kto prosit.
    #
    # Imenno ot etogo imennoj variant proverki byl sluchajno zashchishchjon: 'claude' nikogda ne
    # popadal v spisok, po kotoromu on iskal. Sud po nagruzke etu sluchajnost ubiraet, i zashchitu
    # prihoditsja pisat javno.
    param([string[]]$Ours = @('claude','pwsh','powershell','node','conhost','WindowsTerminal','git',
                              'llama-cli','llama-perplexity','llama-quantize','llama-imatrix',
                              'llama-moe-trace','llama-bench','llama-memex-fwd','llama-memex-test',
                              'llama-memex-kv','llama-memex-vkdisp','llama-memex-vksplit',
                              'memex-test','memex-qerr'),
          [double]$MinPct = 12.0)
    foreach ($h in (Get-CpuHogs)) {
        if ($Ours -notcontains $h.Name -and $h.Pct -ge $MinPct) { return $true }
    }
    return $false
}
