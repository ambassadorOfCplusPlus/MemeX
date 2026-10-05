# smartstock local AI stack: run CHAT + EMBEDDINGS servers together.
#
# Uses the ik_llama.cpp fork's llama-server (build-bt2022). Two independent OpenAI-compatible
# servers on separate ports so the app can hit /v1/chat/completions and /v1/embeddings at once.
#
# HARDWARE NOTE (verified 2026-09-12 on this box: RX 6500 XT 4GB / i3-10100F / 32GB):
#   The RX 6500 XT has a tiny host-visible VRAM heap (small-BAR, no ReBAR), so the fork's Vulkan
#   backend falls back to "submit-with-wait" for buffer writes and DECODE COLLAPSES to ~2.7 tok/s
#   even with all layers offloaded. Plain CPU is ~3-4x faster here. Therefore the default is CPU
#   (-Ngl 0). Do not "optimize" by adding GPU layers on this card - it is slower, measured.
#     qwen3-4b   CPU decode 7.7 tok/s   |  Vulkan full-offload 2.7 tok/s
#     llama-3.2-3b CPU decode 10.1 tok/s
#
# Tools/function-calling REQUIRES --jinja (the server rejects a `tools` param without it), and the
# chat model must be a qwen3 (name contains "qwen3") for the fork to parse tool calls into the
# OpenAI tool_calls shape. qwen3-4b covers both plain chat AND tool-calling.
#
# Usage:
#   pwsh -File bench/smartstock_serve.ps1            # start chat(18080) + embeddings(18081)
#   pwsh -File bench/smartstock_serve.ps1 -Stop      # stop both
#   pwsh -File bench/smartstock_serve.ps1 -UseLock   # take the machine lock first (share with agents)

param(
    [string]$ChatModel  = 'D:/smartstock/models/qwen3-4b-q4_k_m.gguf',
    [string]$ChatAlias  = 'qwen3-4b',            # keep "qwen3" in the alias so tool parsing engages
    [string]$EmbedModel = 'D:/smartstock/models/bge-m3-q8.gguf',
    [string]$EmbedAlias = 'bge-m3',
    [int]$ChatPort  = 18080,
    [int]$EmbedPort = 18081,
    [int]$Ngl = 0,               # 0 = CPU (fast here). GPU is slower on the RX 6500 XT - see note.
    [int]$ChatCtx = 4096,
    [int]$EmbedCtx = 512,
    [switch]$Stop,
    [switch]$UseLock             # only when sharing the dev machine with bench agents
)

$ErrorActionPreference = 'Continue'
$bin = 'D:/MemeX/src/ik_llama.cpp/build-bt2022/bin/Release/llama-server.exe'
$run = 'D:/smartstock/run'
New-Item -ItemType Directory -Force -Path $run | Out-Null
$pidFile = Join-Path $run 'servers.pids'
function Say($m){ Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

if ($Stop) {
    if (Test-Path $pidFile) {
        foreach ($line in Get-Content $pidFile) {
            $id = ($line -split '\s+')[0]
            if ($id -match '^\d+$') { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue; Say ("stopped PID " + $id) }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } else { Say "no pid file; nothing to stop" }
    return
}

if ($UseLock) {
    . 'C:/Users/User11/Desktop/MemeX/bench/lock.ps1'
    Say "taking machine lock"
    if (-not (Take-Machine -Who 'smartstock-serve' -TimeoutMin 30)) { Say "no machine"; exit 1 }
}

function Start-One($model,$alias,$port,$ctx,[switch]$embed,[switch]$jinja) {
    $a = @('-m',$model,'-a',$alias,'-ngl',"$Ngl",'-c',"$ctx",'--host','127.0.0.1','--port',"$port")
    if ($embed) { $a += '--embedding' }
    if ($jinja) { $a += '--jinja' }
    $elog = Join-Path $run ("srv_" + $alias + ".log")
    $p = Start-Process -FilePath $bin -ArgumentList $a -RedirectStandardError $elog -RedirectStandardOutput ($elog + '.out') -PassThru -WindowStyle Hidden
    return $p
}

function Wait-Health($port,$name) {
    for ($i=0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2
        try { $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3 -EA Stop
              if ($h.status -eq 'ok') { Say ("$name ready on $port"); return $true } } catch {}
    }
    Say ("$name did NOT become healthy on $port"); return $false
}

Say "starting CHAT (qwen3-4b, --jinja for tools) + EMBEDDINGS (bge-m3)"
$chat  = Start-One $ChatModel  $ChatAlias  $ChatPort  $ChatCtx  -jinja
$embed = Start-One $EmbedModel $EmbedAlias $EmbedPort $EmbedCtx -embed
"$($chat.Id) chat $ChatPort`n$($embed.Id) embed $EmbedPort" | Set-Content -LiteralPath $pidFile -Encoding ASCII

$okc = Wait-Health $ChatPort  'chat'
$oke = Wait-Health $EmbedPort 'embeddings'

Say "----------------------------------------------------------"
Say ("CHAT        : http://127.0.0.1:$ChatPort/v1/chat/completions   (model=$ChatAlias, tools via --jinja)")
Say ("EMBEDDINGS  : http://127.0.0.1:$EmbedPort/v1/embeddings          (model=$EmbedAlias, dim=1024)")
Say ("stop with   : pwsh -File bench/smartstock_serve.ps1 -Stop")
Say "----------------------------------------------------------"
if (-not ($okc -and $oke)) { Say "WARNING: one or both servers unhealthy - check logs in $run" }
Say "servers running detached; this script can exit and they keep serving."
