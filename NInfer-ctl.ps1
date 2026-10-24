# NInfer Control - persistent live dashboard
# The window IS the dashboard: menu + status stay on top, and a real-time token panel
# (throughput, session totals, KV capacity, live log) refreshes underneath it.
# Redraw is in-place (SetCursorPosition) and diff-checked => no flicker when idle.
# Keys: [S] start  [P] stop  [L] refresh  [Q]/Esc quit. There is no separate full-screen view.
$ErrorActionPreference = 'SilentlyContinue'

# ---- run a WSL command WITHOUT giving it the console keyboard (wsl.exe otherwise eats keypresses) ----
function Invoke-Wsl {
    param([string]$cmd)
    $i = New-Object System.Diagnostics.ProcessStartInfo
    $i.FileName = 'wsl.exe'
    $i.Arguments = '-d Ubuntu -- bash -lc "' + $cmd + '"'
    $i.RedirectStandardInput = $true; $i.RedirectStandardOutput = $true; $i.RedirectStandardError = $true
    $i.UseShellExecute = $false; $i.CreateNoWindow = $true
    try {
        $x = [System.Diagnostics.Process]::Start($i)
        $x.StandardInput.Close()
        $null = $x.StandardError.ReadToEndAsync()
        $o = $x.StandardOutput.ReadToEnd()
        $x.WaitForExit(); $x.Dispose()
        return @($o -split "`r?`n" | Where-Object { $_ -ne '' })
    } catch { return @() }
}

# ---- data: one WSL call returns state + gpu + comfyui + opencode ----
function Get-Live {
    $out = Invoke-Wsl '~/ninfer-live.sh'
    $r = [ordered]@{
        State='stopped'; Pid='none'; Up='-'; RssGb='0'; Cpu='0'
        GpuName='unknown'; Util='0'; MemGb='0'; MemTotalGb='0'; Temp='0'; Power='0'
        Cui='stopped'; Live='off'; Ago=0; Running=0
        TDecode='0'; TRunning=0; TPrefillTok='0'; TKV='0'; TKVType=''; TSesHp='0'; TSesOut='0'
        LastId=''; LastPrompt='0'; LastOutput='0'; LastCache='0'
        Log=@()
    }
    foreach ($line in $out) {
        if ($line -like 'STATE=*') {
            $body = $line.Substring(6)
            $r.State = ($body -split '\|')[0]
            foreach ($kv in ($body -split '\|')) { $p = $kv -split '=',2; switch ($p[0]) {
                'pid' {$r.Pid=$p[1]} 'up' {$r.Up=$p[1]} 'rss_gb' {$r.RssGb=$p[1]} 'cpu' {$r.Cpu=$p[1]} } }
        }
        elseif ($line -like 'GPU=*') {
            foreach ($kv in ($line.Substring(4) -split '\|')) { $p = $kv -split '=',2; switch ($p[0]) {
                'name'{$r.GpuName=$p[1]} 'util'{$r.Util=$p[1]} 'mem_gb'{$r.MemGb=$p[1]}
                'mem_total_gb'{$r.MemTotalGb=$p[1]} 'temp'{$r.Temp=$p[1]} 'power'{$r.Power=$p[1]} } }
        }
        elseif ($line -match '^CUI=(\w+)') { $r.Cui = $matches[1] }
        elseif ($line -like 'LIVE=*') {
            $body = $line.Substring(5)
            $r.Live = ($body -split '\|')[0]
            foreach ($kv in ($body -split '\|')) { $p = $kv -split '=',2; switch ($p[0]) {
                'ago'{$r.Ago=$p[1]} 'running'{$r.Running=$p[1]} } }
        }
        elseif ($line -like 'TOK=*') {
            foreach ($kv in ($line.Substring(4) -split '\|')) { $p = $kv -split '=',2; switch ($p[0]) {
                'decode'{$r.TDecode=$p[1]} 'running'{$r.TRunning=$p[1]} 'prefill_tok'{$r.TPrefillTok=$p[1]}
                'kv'{$r.TKV=$p[1]} 'kvtype'{$r.TKVType=$p[1]} 'seshp'{$r.TSesHp=$p[1]} 'sesout'{$r.TSesOut=$p[1]} } }
        }
        elseif ($line -like 'LAST=*') {
            foreach ($kv in ($line.Substring(5) -split '\|')) { $p = $kv -split '=',2; switch ($p[0]) {
                'id'{$r.LastId=$p[1]} 'prompt'{$r.LastPrompt=$p[1]} 'output'{$r.LastOutput=$p[1]} 'cache'{$r.LastCache=$p[1]} } }
        }
        elseif ($line -like 'LOG=*') { $r.Log += $line.Substring(4) }
    }
    $r.Opencode = @(Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" |
                    Where-Object { $_.CommandLine -and ($_.CommandLine -notmatch 'serve --service') }).Count
    return $r
}

function Start-NInfer { $null = Invoke-Wsl '~/ensure-ninfer.sh' }
function Stop-NInfer  { $null = Invoke-Wsl '~/stop-ninfer.sh' }

function Vram-Bar {
    param([double]$used, [double]$total)
    if ($total -le 0) { return '                    0.0/0.0' }
    $pct = [math]::Min(1.0, $used / $total)
    $fill = [int]([math]::Round(20 * $pct))
    $bar = ('#' * $fill) + ('-' * (20 - $fill))
    return ("[{0}] {1:N1}/{2:N1}" -f $bar, $used, $total)
}

# ---- live token panel (sourced from the stream, updated in place) ----
$panel = [ordered]@{
    DecodeTokS=0; DecodeTok=0; PrefillTok=0
    Running=0; KVcap=0; KVType=''
    SesPrompt=0; SesOutput=0
    LastId=''; LastPrompt=0; LastOutput=0; LastCache='0'
    LogTail=[System.Collections.Generic.Queue[string]]::new()
}

# update the token panel from one raw log line (throughput / req# done / capacity)
function Update-Panel {
    param([string]$body)
    while ($panel.LogTail.Count -ge 8) { $panel.LogTail.Dequeue() }
    $panel.LogTail.Enqueue($body)
    if ($body -match 'throughput') {
        if ($body -match 'decode ([\d.]+) tok/s \(([\d,]+) tok\)') {
            $panel.DecodeTokS=[double]$matches[1]; $panel.DecodeTok=[int]($matches[2] -replace ',','') }
        if ($body -match 'prefill [\d.]+[km]? tok/s \(([\d,]+) tok\)') {
            $panel.PrefillTok=[int]($matches[1] -replace ',','') }
        if ($body -match 'running (\d+)') { $panel.Running=[int]$matches[1] }
    }
    elseif ($body -match 'req#\d+ done') {
        if ($body -match 'req#(\d+)')           { $panel.LastId=$matches[1] }
        if ($body -match 'prompt ([\d,]+)')     { $p=[int]($matches[1] -replace ',',''); $panel.LastPrompt=$p; $panel.SesPrompt+=$p }
        if ($body -match 'output ([\d,]+)')     { $o=[int]($matches[1] -replace ',',''); $panel.LastOutput=$o; $panel.SesOutput+=$o }
        if ($body -match 'cache [\d,]+ \(([\d.]+)%') { $panel.LastCache=$matches[1] }
    }
    elseif ($body -match 'capacity') {
        if ($body -match '(?:KV )?([\d,]+) tokens')  { $panel.KVcap=[int]($matches[1] -replace ',','') }
        if ($body -match 'int8')                { $panel.KVType='int8' }
    }
}

function Color-For-Log {
    param([string]$body)
    if ($body -match 'ERROR|FATAL|SEVERE|panic|segfault|CUDA error|out of memory|OOM|Aborted|Traceback|killed|SIGKILL|EADDR|bind') { return 'Red' }
    if ($body -match 'WARN|WARNING') { return 'Yellow' }
    if ($body -match 'throughput')  { return 'Yellow' }
    if ($body -match 'req#')        { return 'Green' }
    if ($body -match 'INFO')        { return 'White' }
    return 'DarkGray'
}

# ---- render the whole dashboard as fixed-layout, width-padded colored rows ----
function Render-Dashboard {
    param($s, $g, [int]$W)
    function Pad { param([string]$t,[int]$w) if ($t.Length -ge $w) { $t.Substring(0,$w) } else { $t.PadRight($w) } }
    $nColor = if ($s.State -eq 'running') { 'Green' } else { 'DarkRed' }
    $cColor = if ($s.Cui  -eq 'running') { 'Green' } else { 'DarkGray' }
    $pf = if ($panel.PrefillTok -gt 0) { "   {0:N0} tok prefill" -f $panel.PrefillTok } else { '' }
    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add([pscustomobject]@{ T=(Pad '============================================================' $W); C='Cyan' })
    $rows.Add([pscustomobject]@{ T=(Pad '                     N I N F E R   C O N T R O L' $W); C='Cyan' })
    $rows.Add([pscustomobject]@{ T=(Pad '============================================================' $W); C='Cyan' })
    $rows.Add([pscustomobject]@{ T=(Pad ("  NInfer      : {0,-8} pid {1}  up {2}  rss {3} GB" -f $s.State,$s.Pid,$s.Up,$s.RssGb) $W); C=$nColor })
    $rows.Add([pscustomobject]@{ T=(Pad ("  ComfyUI     : {0}" -f $s.Cui) $W); C=$cColor })
    $rows.Add([pscustomobject]@{ T=(Pad ("  Opencode    : {0} window(s) open" -f $s.Opencode) $W); C='White' })
    $rows.Add([pscustomobject]@{ T=(Pad ("  VRAM        : {0}  {1}%  {2}C" -f (Vram-Bar ([double]$g.Mem) ([double]$g.MemTotal)), $g.Util, $g.Temp) $W); C='Cyan' })
    $rows.Add([pscustomobject]@{ T=(Pad '' $W); C='White' })
    $rows.Add([pscustomobject]@{ T=(Pad '   [S] Start      [P] Stop      [L] Refresh      [Q] Quit' $W); C='White' })
    $rows.Add([pscustomobject]@{ T=(Pad '' $W); C='White' })
    $rows.Add([pscustomobject]@{ T=(Pad '  -- LIVE TOKENS --  (session totals, live)' $W); C='Cyan' })
    $rows.Add([pscustomobject]@{ T=(Pad ("  speed      : {0:N1} tok/s decode{1}" -f $panel.DecodeTokS, $pf) $W); C='Yellow' })
    $rows.Add([pscustomobject]@{ T=(Pad ("  in-flight  : {0} request(s) running" -f $panel.Running) $W); C='Yellow' })
    $rows.Add([pscustomobject]@{ T=(Pad ("  session    : prompt {0:N0}  +  output {1:N0}  =  {2:N0} tokens" -f $panel.SesPrompt, $panel.SesOutput, ($panel.SesPrompt+$panel.SesOutput)) $W); C='Green' })
    # the capacity line is logged once at server start; fall back to the full-log scan from ninfer-live.sh
    $kvc = if ($panel.KVcap -gt 0) { $panel.KVcap } else { [int]("0" + ($s.TKV -replace ',','')) }
    $kvt = if ($panel.KVType) { $panel.KVType } else { $s.TKVType }
    $rows.Add([pscustomobject]@{ T=(Pad ("  KV cache   : {0:N0} tokens  {1}" -f $kvc, $kvt) $W); C='White' })
    $rows.Add([pscustomobject]@{ T=(Pad ("  last req   : req#{0}  prompt {1:N0}  output {2:N0}  cache {3}%" -f $panel.LastId, $panel.LastPrompt, $panel.LastOutput, $panel.LastCache) $W); C='Green' })
    $rows.Add([pscustomobject]@{ T=(Pad '' $W); C='White' })
    $rows.Add([pscustomobject]@{ T=(Pad '  latest log:' $W); C='DarkGray' })
    $tail = @($panel.LogTail)
    for ($i=0; $i -lt 8; $i++) {
        $ln = if ($i -lt $tail.Count) { $tail[$i] } else { '' }
        $c  = if ($ln) { Color-For-Log $ln } else { 'DarkGray' }
        $rows.Add([pscustomobject]@{ T=(Pad ("  " + $ln) $W); C=$c })
    }
    return $rows.ToArray()
}

# ---- live stream: wsl process with its own stdin; lines read with async .NET reads polled from the main loop ----
$lineQ   = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$proc    = $null; $outTask = $null; $errTask = $null
$nextStreamTry = [DateTime]::MinValue

function Stop-Stream {
    try { if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill(); $script:proc.WaitForExit(2000) | Out-Null } } catch { }
    try { if ($script:proc) { $script:proc.Dispose() } } catch { }
    $script:proc = $null; $script:outTask = $null; $script:errTask = $null
}

function Start-Stream {
    Stop-Stream
    $i = New-Object System.Diagnostics.ProcessStartInfo
    $i.FileName  = 'wsl.exe'
    $i.Arguments = '-d Ubuntu -- bash -lc "~/ninfer-stream.sh"'
    $i.RedirectStandardInput = $true; $i.RedirectStandardOutput = $true; $i.RedirectStandardError = $true
    $i.UseShellExecute = $false; $i.CreateNoWindow = $true
    try {
        $script:proc = [System.Diagnostics.Process]::Start($i)
        $script:proc.StandardInput.Close()
        $script:outTask = $script:proc.StandardOutput.ReadLineAsync()
        $script:errTask = $script:proc.StandardError.ReadLineAsync()
    } catch { $lineQ.Enqueue("L|ERROR could not start ninfer-stream.sh: $($_.Exception.Message)") }
}

# move every finished read into the queue; restart the stream (every 5 s) if it died
function Pump-Stream {
    while ($script:outTask -and $script:outTask.IsCompleted) {
        $l = $null; try { $l = $script:outTask.Result } catch { }
        if ($null -eq $l) { $script:outTask = $null; $lineQ.Enqueue('L|WARN live stream ended - reconnecting'); break }
        $lineQ.Enqueue($l)
        $script:outTask = $script:proc.StandardOutput.ReadLineAsync()
    }
    while ($script:errTask -and $script:errTask.IsCompleted) {
        $e = $null; try { $e = $script:errTask.Result } catch { }
        if ($null -eq $e) { $script:errTask = $null; break }
        if ($e.Trim()) { $lineQ.Enqueue("L|ERROR (stream) $e") }
        $script:errTask = $script:proc.StandardError.ReadLineAsync()
    }
    if (-not $script:outTask -and [DateTime]::Now -ge $script:nextStreamTry) {
        $script:nextStreamTry = [DateTime]::Now.AddSeconds(5)
        Start-Stream
    }
}

Start-Stream

# ---- state ----
$g          = [ordered]@{ State='stopped'; Mem=0; MemTotal=0; Util=0; Temp=0 }
$quit       = $false
$first      = $true
$lastScreen = ''
$lastSize   = ''
$lastTs     = ''
$nextRepaint = [DateTime]::MinValue
try { [Console]::CursorVisible = $false } catch { }
$s          = Get-Live
$nextStatus = [DateTime]::Now.AddSeconds(3)

# draw a frame in place (Clear-Host only on first frame / window too short / resize)
function Draw-Frame {
    param([object[]]$rows, [ref]$first, [int]$W)
    $ww = [Console]::WindowWidth; $wh = [Console]::WindowHeight
    $size = "${ww}x${wh}"
    if ($first.Value -or $size -ne $script:lastSize -or [Console]::WindowTop -ne 0) {
        Clear-Host
        $first.Value = $false
        $script:lastSize = $size
    }
    # repaint every cell of every row (except the last) so nothing stray can survive
    for ($i = 0; $i -lt $wh - 1; $i++) {
        if ($i -lt $rows.Count) { $t = $rows[$i].T; $c = $rows[$i].C } else { $t = ''; $c = 'White' }
        if ($t.Length -gt $ww) { $t = $t.Substring(0, $ww) }
        [Console]::SetCursorPosition(0, $i)
        Write-Host $t.PadRight($ww) -ForegroundColor $c -NoNewline
    }
    [Console]::SetCursorPosition(0, $wh - 1)
}

# ---- main loop: menu + status on top, live token panel underneath ----
while (-not $quit) {
    # 1) drain the stream -> update the token panel + gpu snapshot
    Pump-Stream
    $l = $null; $got = $false
    while ($lineQ.TryDequeue([ref]$l)) {
        if ($l -match '^STATUS\|(.*)$') {
            $b = $matches[1]
            if ($b -match 'state=(\w+)')            { $g.State=$matches[1] }
            if ($b -match 'vram=([\d.]+)/([\d.]+)')  { $g.Mem=$matches[1]; $g.MemTotal=$matches[2] }
            if ($b -match 'util=(\d+)')              { $g.Util=$matches[1] }
            if ($b -match 'temp=(\d+)')              { $g.Temp=$matches[1] }
            $got = $true
        }
        elseif ($l -match '^L\|(.*)$') {
            $body = $matches[1]
            # the stream replays the last log lines on (re)connect: skip anything already counted
            if ($body -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)') {
                if ($matches[1] -le $script:lastTs) { continue }
                $script:lastTs = $matches[1]
            }
            Update-Panel $body; $got = $true
        }
        # H| header lines are ignored
    }
    if ($got) { $nextStatus = [DateTime]::Now.AddSeconds(3) }   # fresh data: push out the next poll

    # 2) non-blocking keys
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true); $ch = ([string]$k.KeyChar).ToLower()
        switch ($ch) {
            's' { Start-NInfer }
            'p' { Stop-NInfer }
            'l' { }
            'q' { $quit = $true }
            default { }
        }
        if ($k.Key -eq 'Escape') { $quit = $true }
        $s = Get-Live
        $nextStatus = [DateTime]::MinValue
    }

    # 3) periodic header refresh (NInfer pid/up/rss, ComfyUI, Opencode)
    if ([DateTime]::Now -ge $nextStatus) { $s = Get-Live; $nextStatus = [DateTime]::Now.AddSeconds(3) }

    # 4) render (diff-checked => redraw only when the picture actually changed)
    $W = [Console]::WindowWidth - 1; if ($W -lt 40) { $W = 40 }
    $rows = Render-Dashboard $s $g $W
    $plain = ($rows | ForEach-Object { $_.T }) -join "`n"
    $plain += "`n" + [Console]::WindowWidth + 'x' + [Console]::WindowHeight
    if ($plain -ne $lastScreen -or [DateTime]::Now -ge $nextRepaint) {
        Draw-Frame $rows ([ref]$first) $W; $lastScreen = $plain
        $nextRepaint = [DateTime]::Now.AddSeconds(2)
    }

    Start-Sleep -Milliseconds 120
}

# ---- cleanup ----
Stop-Stream
try { [Console]::CursorVisible = $true } catch { }
Clear-Host
Write-Host "NInfer Control closed." -ForegroundColor DarkGray
exit
