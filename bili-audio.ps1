<#
.SYNOPSIS
    B 站直播「纯音频」播放器：命令行、无窗口、低开销。

.DESCRIPTION
    取流链路（本机已实测跑通）：streamlink 取 HLS -> 本机内存管道 -> ffplay -nodisp -vn（只解 AAC）。

    设计理由（都是本机实测结论，改动前先看 README）：
      1) 本机 ffmpeg 是 schannel 构建（--enable-schannel），直连任何 HTTPS 都会报
         [tls] Unable to acquire security credentials (0x8009030e) = SEC_E_NO_CREDENTIALS。
         所以 ffmpeg/ffplay 绝不允许自己去联网；必须由 streamlink（Python/OpenSSL，正常）
         取流后喂给本地管道。
      2) ffplay 加 -vn -nodisp：视频轨完全不解码、不建窗口。实测约 24MB 内存、CPU≈0%。
      3) streamlink 用 -O 把流写到 stdout，本脚本用 .NET 管道直接接到 ffplay 的 stdin，
         不经 cmd.exe ——既避免 URL 里 & 等字符的转义坑，又让两个进程 PID 都由本脚本掌控，
         Ctrl+C 时能干净收尾，不留孤儿进程。
      4) HLS token 约 1 小时过期，且会断流/下播：脚本每次重连都重新解析 URL，
         下播时按固定间隔探测，开播自动续听。

.PARAMETER Room
    直播间地址（https://live.bilibili.com/xxx）、纯房间号（如 6），或 config.json 里的别名。

.PARAMETER Volume
    启动音量 0-100。缺省取 config.json 中该房间的 volume，再缺省取 defaults.volume（50）。
    运行中要改音量：右键任务栏音量图标 -> 音量合成器 -> 单独调 ffplay.exe（无断音）。

.PARAMETER Stream
    auto（默认）| flv | hls | 具体流名。auto = 先探测该直播间有哪些推流方式，
    有 FLV 走 FLV 低码档（实测约 771kbps），没有 FLV 才走 HLS（实测约 2896kbps）。

.PARAMETER LowLatency
    追直播边缘（--hls-live-edge 1）。延迟更低但易缓冲，默认关闭。

.PARAMETER RunForSeconds
    只运行指定秒数后自动退出（0 = 一直听）。用于定时收听或自测。

.PARAMETER OfflineProbeSeconds
    未开播时的探测间隔，默认 60 秒。

.PARAMETER List
    列出 config.json 里的别名后退出。

.EXAMPLE
    .\bili-audio.ps1 6
    .\bili-audio.ps1 lpl -Volume 30
    .\bili-audio.ps1 https://live.bilibili.com/6 -LowLatency
    .\bili-audio.ps1 lpl -RunForSeconds 3600
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Room,
    [int]$Volume = -1,
    [string]$Stream = 'auto',
    [switch]$LowLatency,
    [int]$RunForSeconds = 0,
    [int]$OfflineProbeSeconds = 60,
    [string]$LogDir,
    [string]$RoomsFile,
    [string]$FfplayLogLevel = 'warning',
    [string]$StreamlinkPath,
    [string]$FfplayPath,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
# 防止原生程序写到 stderr 的内容被当成 PowerShell 异常抛出（PS 7.3+）
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $LogDir) { $LogDir = Join-Path $ScriptDir 'logs' }
if (-not $RoomsFile) {
    # 发布版以 config.json 为唯一配置源；为兼容旧版本仍支持 rooms.json
    $candidate = Join-Path $ScriptDir 'config.json'
    if (-not (Test-Path -LiteralPath $candidate)) { $candidate = Join-Path $ScriptDir 'rooms.json' }
    $RoomsFile = $candidate
}
if (-not (Test-Path -LiteralPath $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir -Force }
$script:LogFile = Join-Path $LogDir ("bili-audio-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$script:StartedAt = Get-Date
$script:LowLatency = [bool]$LowLatency
$script:StreamPref = $Stream      # auto | flv | hls | 具体流名
$script:StreamChoice = $null      # 探测后实际选定的流名（懒探测 + 轮内缓存）
$script:PreferHls = $false        # FLV 会话秒退后的临时降级开关
$script:FfplayLogLevel = $FfplayLogLevel

function Get-ShortUrl {
    param([string]$Url)
    if (-not $Url) { return '' }
    $i = $Url.IndexOf('?')
    if ($i -lt 0) { return $Url }
    return $Url.Substring(0, $i) + '?...(token 已省略)'
}

function Format-LogLine {
    <# 日志里出现的长 URL（HLS 地址带 token）一律截断，避免刷屏与泄露签名 #>
    param([string]$Line)
    $out = $Line
    foreach ($m in [Regex]::Matches($out, 'https?://\S+')) {
        if ($m.Value.Length -gt 60) { $out = $out.Replace($m.Value, (Get-ShortUrl $m.Value)) }
    }
    return $out
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('OK', 'INFO', 'DEBUG', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = "[{0}][{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    try {
        [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    } catch {
        Write-Host "[WARN] 写日志失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Resolve-ToolPath {
    param([string]$Explicit, [string[]]$Names, [string[]]$Fallbacks)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "指定的程序路径不存在: $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    foreach ($n in $Names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    foreach ($f in $Fallbacks) {
        if (Test-Path -LiteralPath $f) { return $f }
    }
    return $null
}

function Get-RoomsConfig {
    if (-not (Test-Path -LiteralPath $RoomsFile)) { return $null }
    try {
        return (Get-Content -LiteralPath $RoomsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Log "配置文件解析失败（将忽略别名配置）: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Find-ToolInWinget {
    <# winget 装的包在 %LOCALAPPDATA%\Microsoft\WinGet\Packages\<包名>\… 下，目录名带版本号，
       所以用通配搜索而不是写死某个版本的绝对路径（发布版不能带开发者本机路径）。 #>
    param([string]$Exe, [int]$Depth = 5)
    $root = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    try {
        $hit = Get-ChildItem -LiteralPath $root -Filter $Exe -Recurse -Depth $Depth -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    } catch { }
    return $null
}

function Get-CookieArgs {
    <# 取 cookie 并转成 streamlink 的 --http-cookie 参数数组。
       来源优先级：config.json(bilibili) > 旧版 cookies.txt > 环境变量；
       都没有就返回空数组，让 streamlink 用它自己的配置（已登录 streamlink 的用户照样能用）。 #>
    param($Config)
    $jar = @{}
    if ($Config -and $Config.bilibili) {
        if ($Config.bilibili.sessdata) { $jar['SESSDATA'] = [string]$Config.bilibili.sessdata }
        if ($Config.bilibili.buvid3) { $jar['buvid3'] = [string]$Config.bilibili.buvid3 }
    }
    $legacy = Join-Path $ScriptDir 'cookies.txt'
    if (Test-Path -LiteralPath $legacy) {
        foreach ($line in (Get-Content -LiteralPath $legacy -Encoding UTF8)) {
            $s = $line.Trim()
            if (-not $s -or $s.StartsWith('#')) { continue }
            foreach ($part in ($s -split ';')) {
                $i = $part.IndexOf('=')
                if ($i -gt 0) { $jar[$part.Substring(0, $i).Trim()] = $part.Substring($i + 1).Trim() }
            }
        }
    }
    if ($env:SESSDATA) { $jar['SESSDATA'] = $env:SESSDATA }
    if ($env:BILI_JCT) { $jar['bili_jct'] = $env:BILI_JCT }
    $out = @()
    foreach ($k in @($jar.Keys)) {
        if ($jar[$k]) { $out += '--http-cookie'; $out += ('{0}={1}' -f $k, $jar[$k]) }
    }
    return , $out
}

function Get-StderrPump {
    param([Diagnostics.Process]$Proc, [string]$Tag)
    $buf = New-Object byte[] 8192
    $pump = @{
        Proc = $Proc
        Tag  = $Tag
        Buf  = $buf
        Acc  = New-Object System.Text.StringBuilder
        Lines = New-Object System.Collections.Generic.List[string]
        Task = $null
    }
    try { $pump.Task = $Proc.StandardError.BaseStream.ReadAsync($buf, 0, $buf.Length) } catch { $pump.Task = $null }
    return $pump
}

function Write-StderrLines {
    <# 把捕获到的 stderr 文本按行写日志。
       - \r 也当作行分隔：ffplay 的统计行用 \r 原地刷新，只认 \n 会攒成一条超长行刷屏。
       - ffplay 的实时统计行（"... fd=   0 aq=    0KB vq= ..."）对本工具排查无用，直接丢弃。 #>
    param($Pump, [string]$Text)
    foreach ($ln in [Regex]::Split($Text, "`r`n|`r|`n")) {
        # 剥掉 ffplay 状态行带的 ANSI 控制序列（如 \x1b[2K），否则日志里会留下 "[2K" 这种碎行
        $ln = [Regex]::Replace($ln, '\x1b\[[0-9;]*[A-Za-z]', '').Trim()
        if (-not $ln) { continue }
        if ($ln -match 'fd=\s*\d+ aq=') { continue }
        [void]$Pump.Lines.Add($ln)
        Write-Log ("[{0}] {1}" -f $Pump.Tag, (Format-LogLine $ln)) 'DEBUG'
    }
}

function Read-StderrPump {
    param($Pump)
    if ($null -ne $Pump.Task) {
        # 上限保护（重要）：生产者持续有数据时（例如 ffplay 的统计行），IsCompleted 永远为真，
        # 无界循环会把控制权永远留在函数内，主循环的「到时/停止」检查再也执行不到（实测挂死）。
        $guard = 0
        while ($Pump.Task.IsCompleted -and $guard -lt 64) {
            $guard++
            $n = 0
            try { $n = $Pump.Task.Result } catch { $n = 0 }
            if ($n -le 0) { $Pump.Task = $null; break }
            [void]$Pump.Acc.Append([Text.Encoding]::UTF8.GetString($Pump.Buf, 0, $n))
            try { $Pump.Task = $Pump.Proc.StandardError.BaseStream.ReadAsync($Pump.Buf, 0, $Pump.Buf.Length) }
            catch { $Pump.Task = $null; break }
        }
    }

    # 快路径：ffplay 的统计块（无换行且含 fd=/aq=）整块丢弃，避免逐行正则带来的开销
    $raw = $Pump.Acc.ToString()
    if ($Pump.Tag -eq 'ffplay' -and $raw.IndexOf("`n") -lt 0 -and $raw -match 'fd=\s*\d+ aq=') {
        [void]$Pump.Acc.Clear()
        return
    }

    $text = $raw
    if ($Pump.Task -eq $null) {
        # 流已结束：把残留内容也当整行输出
        [void]$Pump.Acc.Clear()
        Write-StderrLines -Pump $Pump -Text $text
        return
    }
    $idx = [Math]::Max($text.LastIndexOf("`n"), $text.LastIndexOf("`r"))
    if ($idx -lt 0) { return }
    [void]$Pump.Acc.Clear()
    [void]$Pump.Acc.Append($text.Substring($idx + 1))
    Write-StderrLines -Pump $Pump -Text $text.Substring(0, $idx)
}

function Get-AvailableStreams {
    <# 用 streamlink --json 探测该直播间有哪些推流方式（只列流、不播放）。
       返回 @{ Ok; Offline; Error; Streams }；Offline=$true 表示未开播/无可用流。 #>
    param([string]$Url)
    $out = & $script:StreamlinkExe @script:CookieArgs --json $Url 2>&1
    $text = ($out | Out-String)
    $i = $text.IndexOf('{')
    $j = $text.LastIndexOf('}')
    if ($i -ge 0 -and $j -gt $i) {
        try {
            $obj = $text.Substring($i, $j - $i + 1) | ConvertFrom-Json
            if ($obj.streams -and @($obj.streams.PSObject.Properties).Count -gt 0) {
                return [pscustomobject]@{ Ok = $true; Offline = $false; Error = $null; Streams = $obj.streams }
            }
            return [pscustomobject]@{ Ok = $false; Offline = $true; Error = '探测结果里没有可用流'; Streams = $null }
        } catch {
            return [pscustomobject]@{ Ok = $false; Offline = $false; Error = "JSON 解析失败: $($_.Exception.Message)"; Streams = $null }
        }
    }
    $flat = ($text -replace '\s+', ' ').Trim()
    $offline = $flat -match 'No playable streams found|is offline|Channel is offline'
    return [pscustomobject]@{ Ok = $false; Offline = $offline; Error = $flat; Streams = $null }
}

function Get-StreamBitrate {
    param($Info)
    if ($Info -and $Info.url -and ($Info.url -match 'origin_bitrate=(\d+)')) { return [int]$Matches[1] }
    return 0
}

function Select-StreamName {
    <# 选流规则（用户要求）：有 FLV 推流就走 FLV 低码档，没有 FLV 才走 HLS。
       $Pref: auto（默认）| flv | hls | 其它（当作具体流名） #>
    param($Streams, [string]$Pref)
    $names = @($Streams.PSObject.Properties | ForEach-Object { $_.Name })
    $flvHit = @($names | Where-Object { $_ -like 'httpstream*' } | Select-Object -First 1)
    $hlsHit = @($names | Where-Object { $_ -like 'hls*' } | Select-Object -First 1)
    $flvName = if ($flvHit.Count) { $flvHit[0] } else { $null }
    $hlsName = if ($hlsHit.Count) { $hlsHit[0] } else { $null }
    $pick = $null
    $why = ''

    switch ($Pref) {
        'auto' {
            if ($script:PreferHls -and $hlsName) { $pick = $hlsName; $why = 'FLV 上一轮秒退，暂时降级到 HLS' }
            elseif ($flvName) { $pick = $flvName; $why = '该房间有 FLV 推流，按规则走 FLV 低码档' }
            elseif ($hlsName) { $pick = $hlsName; $why = '该房间没有 FLV 推流，回退 HLS' }
        }
        'flv' {
            if ($flvName) { $pick = $flvName; $why = '手动指定 FLV' }
            elseif ($hlsName) { $pick = $hlsName; $why = '手动指定了 FLV，但该房间没有 FLV，回退 HLS' }
        }
        'hls' {
            if ($hlsName) { $pick = $hlsName; $why = '手动指定 HLS' }
            elseif ($flvName) { $pick = $flvName; $why = '手动指定了 HLS，但该房间没有 HLS，回退 FLV' }
        }
        default {
            if ($names -contains $Pref) { $pick = $Pref; $why = '手动指定的流名' }
            elseif ($flvName) { $pick = $flvName; $why = "指定流名 '$Pref' 不存在，改用 FLV" }
            elseif ($hlsName) { $pick = $hlsName; $why = "指定流名 '$Pref' 不存在，改用 HLS" }
        }
    }
    if (-not $pick) { return $null }
    return [pscustomobject]@{
        Name    = $pick
        Why     = $why
        Bitrate = Get-StreamBitrate $Streams.$pick
        HlsRate = if ($hlsName) { Get-StreamBitrate $Streams.$hlsName } else { 0 }
    }
}

function Start-PlaybackSession {
    <# 启动 streamlink -> ffplay 管道，跑到结束/超时后收尾。
       $Url 必须是「直播间地址」，绝不能传预解析出来的 .m3u8 地址：
       传 .m3u8 会命中 streamlink 的通用 hls 插件（而不是 bilibili 插件），
       它会去找名字叫 hls 的流并报错（实测: The specified stream(s) 'hls' could not be found /
       Available streams: live (worst, best)），结果是根本播不出声音。 #>
    param([string]$Url, [int]$Vol, [int]$MaxSeconds, [string]$StreamName)
    if (-not $StreamName) { throw 'StreamName 不能为空（应由 Select-StreamName 探测后给出）' }

    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.FileName = $script:StreamlinkExe
    # --retry-* / --stream-segment-attempts：让 streamlink 自己扛住 CDN 分片 404 与读超时，
    # 比我们整段重连便宜得多（重连要重新攒 ~9 秒 HLS 缓冲，等于断音一次）。
    $sArgs = @(
        '--stdout', '--loglevel', 'info', '--stream-timeout', '20',
        '--retry-streams', '3', '--retry-max', '3', '--retry-open', '3',
        '--stream-segment-attempts', '3'
    )
    $sArgs += $script:CookieArgs
    if ($script:LowLatency) { $sArgs += @('--hls-live-edge', '1') }
    $si.Arguments = (($sArgs -join ' ') + ' "' + $Url + '" ' + $StreamName)
    $si.UseShellExecute = $false
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $si.CreateNoWindow = $true

    $sj = [Diagnostics.ProcessStartInfo]::new()
    $sj.FileName = $script:FfplayExe
    # 注意：ffplay 的 -stats 是纯布尔开关，不能写成 "-stats 0"——那样会把 0 当成输入文件名，
    # 与 -i pipe:0 冲突并导致 ffplay 秒退（实测踩过）。统计噪声改由 Write-StderrLines 过滤。
    $sj.Arguments = "-hide_banner -nodisp -vn -autoexit -volume $Vol -loglevel $script:FfplayLogLevel -i pipe:0"
    $sj.UseShellExecute = $false
    $sj.RedirectStandardInput = $true
    $sj.RedirectStandardError = $true
    $sj.CreateNoWindow = $true

    $p1 = $null; $p2 = $null; $pump = $null; $e1 = $null; $e2 = $null
    try {
        $p1 = [Diagnostics.Process]::Start($si)
        $p2 = [Diagnostics.Process]::Start($sj)
        $pump = $p1.StandardOutput.BaseStream.CopyToAsync($p2.StandardInput.BaseStream)
        $e1 = Get-StderrPump -Proc $p1 -Tag 'streamlink'
        $e2 = Get-StderrPump -Proc $p2 -Tag 'ffplay'
        Write-Log "已启动: streamlink pid=$($p1.Id)  ->  ffplay pid=$($p2.Id)（音量 $Vol，本次最长 ${MaxSeconds}s，0=不限）" 'INFO'

        $start = Get-Date
        while ($true) {
            Read-StderrPump $e1
            Read-StderrPump $e2
            if ($pump.IsCompleted) { Write-Log '分片流已结束（断流或主播下播）' 'WARN'; break }
            if ($p2.HasExited) { Write-Log "ffplay 已退出（exit=$($p2.ExitCode)）" 'WARN'; break }
            if ($p1.HasExited) { Write-Log "streamlink 已退出（exit=$($p1.ExitCode)）" 'WARN'; break }
            if ($MaxSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $MaxSeconds) {
                Write-Log '到达指定运行时长，正常停止本次播放' 'OK'; break
            }
            Start-Sleep -Milliseconds 200
        }
    }
    finally {
        # 先断数据源，再关 ffplay 的 stdin（它收到 EOF 会自行收尾），最后才强杀。
        # 注意：残留检查必须在 Dispose 之前做——Dispose 之后读 .HasExited/.Id 已不可靠
        # （之前就踩过：日志打印出 "pid= 未退出" 的假告警，其实没有残留）。
        if ($p1 -and -not $p1.HasExited) {
            try { $p1.Kill() } catch { }
            $null = $p1.WaitForExit(2000)
        }
        if ($p2) {
            try { $p2.StandardInput.BaseStream.Close() } catch { }
            if (-not $p2.HasExited) { $null = $p2.WaitForExit(1500) }
            if (-not $p2.HasExited) { try { $p2.Kill() } catch { }; $null = $p2.WaitForExit(2000) }
        }
        if ($e1) { Read-StderrPump $e1 }
        if ($e2) { Read-StderrPump $e2 }
        if ($p1 -and -not $p1.HasExited) { Write-Log "警告: streamlink pid=$($p1.Id) 未能在 2 秒内退出" 'ERROR' }
        if ($p2 -and -not $p2.HasExited) { Write-Log "警告: ffplay pid=$($p2.Id) 未能在 2 秒内退出" 'ERROR' }
        foreach ($p in @($p1, $p2)) { if ($p) { try { $p.Dispose() } catch { } } }
    }

    return [pscustomobject]@{
        StreamlinkLines = if ($e1) { @($e1.Lines) } else { @() }
        FfplayLines     = if ($e2) { @($e2.Lines) } else { @() }
    }
}

# ---------------------------------------------------------------- 主流程

Write-Log "===== bili-audio 启动 =====" 'INFO'
Write-Log "日志文件: $($script:LogFile)" 'DEBUG'

$config = Get-RoomsConfig
$script:CookieArgs = Get-CookieArgs -Config $config
if ($script:CookieArgs.Count -gt 0) {
    $names = @($script:CookieArgs | Where-Object { $_ -like '*=*' } | ForEach-Object { ($_ -split '=')[0] })
    Write-Log ("已从配置读取 cookie: {0}（作为 --http-cookie 传给 streamlink；只记录名字，不记录值）" -f ($names -join ', ')) 'DEBUG'
} else {
    Write-Log 'config.json 里没有 cookie，将使用 streamlink 自己的配置' 'DEBUG'
}

if ($List) {
    if (-not $config -or -not $config.rooms) {
        Write-Host "配置文件里还没有任何别名（文件: $RoomsFile）" -ForegroundColor Yellow
    } else {
        Write-Host "`n可用别名（来自 $RoomsFile）：" -ForegroundColor Cyan
        foreach ($prop in $config.rooms.PSObject.Properties) {
            $v = $prop.Value
            $u = if ($v -is [string]) { $v } else { $v.url }
            $n = if ($v -is [string]) { '' } else { $v.note }
            $vol = if ($v -is [string]) { '' } else { $v.volume }
            $extra = @()
            if ($vol) { $extra += "音量=$vol" }
            if ($n) { $extra += $n }
            "  {0,-12} {1,-42} {2}" -f $prop.Name, $u, ($extra -join '  ')
        }
        Write-Host ""
    }
    exit 0
}

if (-not $Room -and $config -and $config.defaults -and $config.defaults.room) {
    $Room = [string]$config.defaults.room
    Write-Log "未指定直播间，使用 config.json 的 defaults.room=$Room" 'INFO'
}

if (-not $Room) {
    Write-Host @"

bili-audio —— B 站直播纯音频播放（命令行 / 无窗口 / 低开销）

用法:
  .\bili-audio.ps1 <直播间地址|房间号|别名> [选项]

示例:
  .\bili-audio.ps1 6                                   # 房间号
  .\bili-audio.ps1 https://live.bilibili.com/6         # 完整地址
  .\bili-audio.ps1 lpl -Volume 30                      # 用 config.json 里的别名
  .\bili-audio.ps1 6 -LowLatency                       # 追直播边缘，延迟更低
  .\bili-audio.ps1 6 -RunForSeconds 3600               # 只听 1 小时后自动退出
  .\bili-audio.ps1 -List                               # 列出别名

停止: Ctrl+C         运行中调音量: 任务栏音量 -> 音量合成器 -> ffplay.exe
"@ -ForegroundColor Gray
    exit 2
}

# --- 解析房间 ---
$roomUrl = $null
$roomNote = ''
$roomVolume = $null
$roomStream = $null
if ($Room -match '^\s*https?://') {
    $roomUrl = $Room.Trim()
} elseif ($Room -match '^\s*\d+\s*$') {
    $roomUrl = "https://live.bilibili.com/$($Room.Trim())"
} elseif ($config -and $config.rooms) {
    $entry = $config.rooms.PSObject.Properties | Where-Object { $_.Name -eq $Room } | Select-Object -First 1
    if ($entry) {
        $v = $entry.Value
        if ($v -is [string]) { $roomUrl = $v } else { $roomUrl = $v.url; $roomNote = [string]$v.note; $roomVolume = $v.volume; $roomStream = [string]$v.stream }
    }
}
if (-not $roomUrl) {
    Write-Log "无法识别的直播间: '$Room'（既不是地址/房间号，也不是 config.json 里的别名，可用 -List 查看）" 'ERROR'
    exit 2
}

if ($Volume -ge 0) { $vol = $Volume }
elseif ($roomVolume) { $vol = [int]$roomVolume }
elseif ($config -and $config.defaults -and $config.defaults.volume) { $vol = [int]$config.defaults.volume }
else { $vol = 50 }
if ($vol -lt 0 -or $vol -gt 100) { Write-Log "音量必须 0-100，当前: $vol" 'ERROR'; exit 2 }

# config.json 里该房间可指定 stream（auto/flv/hls）；命令行显式传了 -Stream 时以命令行为准
if (-not $PSBoundParameters.ContainsKey('Stream')) {
    if ($roomStream) {
        $script:StreamPref = $roomStream
        Write-Log "该房间在 config.json 里指定了 stream=$roomStream，以它为准" 'DEBUG'
    } elseif ($config -and $config.defaults -and $config.defaults.stream) {
        $script:StreamPref = [string]$config.defaults.stream
    }
}

# --- 解析依赖程序 ---
$script:StreamlinkExe = Resolve-ToolPath -Explicit $StreamlinkPath -Names @('streamlink') -Fallbacks @(
    (Join-Path $env:ProgramFiles 'Streamlink\bin\streamlink.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Streamlink\bin\streamlink.exe'),
    (Join-Path $env:LOCALAPPDATA 'Streamlink\bin\streamlink.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Streamlink\bin\streamlink.exe')
)
if (-not $script:StreamlinkExe) { $script:StreamlinkExe = Find-ToolInWinget 'streamlink.exe' }
$script:FfplayExe = Resolve-ToolPath -Explicit $FfplayPath -Names @('ffplay') -Fallbacks @(
    'C:\ffmpeg\bin\ffplay.exe',
    (Join-Path $env:ProgramFiles 'ffmpeg\bin\ffplay.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\ffmpeg\bin\ffplay.exe')
)
if (-not $script:FfplayExe) { $script:FfplayExe = Find-ToolInWinget 'ffplay.exe' }
if (-not $script:StreamlinkExe) { Write-Log '找不到 streamlink.exe（可用 -StreamlinkPath 指定）' 'ERROR'; exit 3 }
if (-not $script:FfplayExe) { Write-Log '找不到 ffplay.exe（可用 -FfplayPath 指定）' 'ERROR'; exit 3 }

if ($script:StreamPref -match '^(best|worst)$') {
    Write-Log "流名 '$($script:StreamPref)' 由 streamlink 按权重自己挑；推荐用 -Stream auto 让工具按带宽选" 'WARN'
}

Write-Log "直播间: $roomUrl $roomNote" 'INFO'
Write-Log "依赖: streamlink=$($script:StreamlinkExe)" 'DEBUG'
Write-Log "依赖: ffplay=$($script:FfplayExe)" 'DEBUG'
Write-Log "推流偏好: $($script:StreamPref)（auto = 有 FLV 走 FLV 低码档，无 FLV 才走 HLS）  音量: $vol  未开播探测: ${OfflineProbeSeconds}s$(if ($script:LowLatency) { '  低延迟 live-edge=1' })" 'INFO'

$deadline = if ($RunForSeconds -gt 0) { (Get-Date).AddSeconds($RunForSeconds) } else { $null }
$sessions = 0
$failDelay = 5

try {
    while ($true) {
        if ($deadline -and (Get-Date) -ge $deadline) { Write-Log '到达指定总运行时长，退出' 'OK'; break }

        # 先探测推流方式并选定流名（同一轮内只探测一次；失败/重新开播时才重新探测）
        if (-not $script:StreamChoice) {
            $probe = Get-AvailableStreams -Url $roomUrl
            if (-not $probe.Ok) {
                if ($probe.Offline) {
                    Write-Log "未开播 / 该房间当前无可用流；${OfflineProbeSeconds} 秒后再探测（开播会自动接上）" 'WARN'
                    Start-Sleep -Seconds $OfflineProbeSeconds
                } else {
                    Write-Log "推流方式探测失败：$($probe.Error)；${failDelay} 秒后重试" 'ERROR'
                    Start-Sleep -Seconds $failDelay
                    $failDelay = [Math]::Min($failDelay * 2, 60)
                }
                continue
            }
            $rateList = @($probe.Streams.PSObject.Properties | ForEach-Object {
                $rate = Get-StreamBitrate $_.Value
                if ($rate -gt 0) { "$($_.Name)=${rate}kbps" } else { $_.Name }
            })
            Write-Log ("可用推流方式: {0}" -f ($rateList -join ', ')) 'INFO'
            $sel = Select-StreamName -Streams $probe.Streams -Pref $script:StreamPref
            if (-not $sel) {
                Write-Log '探测结果里没有可用的流名，10 秒后重试' 'ERROR'
                Start-Sleep -Seconds 10
                continue
            }
            $script:StreamChoice = $sel.Name
            $compare = ''
            if ($sel.Bitrate -gt 0 -and $sel.HlsRate -gt 0 -and $sel.Name -like 'httpstream*') {
                $saving = [int](100 - ($sel.Bitrate * 100 / $sel.HlsRate))
                $compare = "；带宽约 $($sel.Bitrate)kbps，比 HLS 的 $($sel.HlsRate)kbps 省约 ${saving}%"
            } elseif ($sel.Bitrate -gt 0) {
                $compare = "；带宽约 $($sel.Bitrate)kbps"
            }
            Write-Log "选定推流: $($sel.Name)（$($sel.Why)$compare）" 'OK'
        }

        $sessions++
        Write-Log "第 $sessions 次会话开始播放（流=$($script:StreamChoice)）" 'OK'
        # 本次会话允许的最长秒数（0 = 不限）。这行曾被补丁误删，导致 -RunForSeconds 静默失效、永不退出。
        $remain = if ($deadline) { [int][Math]::Max(1, ($deadline - (Get-Date)).TotalSeconds) } else { 0 }
        $sessStart = Get-Date
        $sess = Start-PlaybackSession -Url $roomUrl -Vol $vol -MaxSeconds $remain -StreamName $script:StreamChoice
        $sessSecs = ((Get-Date) - $sessStart).TotalSeconds
        $slText = ($sess.StreamlinkLines -join ' ')

        if ($deadline -and (Get-Date) -ge $deadline) { Write-Log '到达指定总运行时长，退出' 'OK'; break }

        if ($sessSecs -lt 5) {
            # 会话秒退：区分「未开播」与「其他错误」，前者等待开播、后者退避重试。
            # 判定依据是 streamlink 自己的 stderr（离线时它会说 No playable streams found / is offline）。
            if ($slText -match 'No playable streams found|is offline|Channel is offline') {
                # 清掉缓存：重新开播后推流方式可能变了，需要重新探测
                $script:StreamChoice = $null
                Write-Log "未开播 / 该房间当前无可用流；${OfflineProbeSeconds} 秒后再探测（开播会自动接上）" 'WARN'
                Start-Sleep -Seconds $OfflineProbeSeconds
            } else {
                $msg = "取流/播放失败（会话仅 {0:N0} 秒，流={1}）；{2} 秒后重试" -f $sessSecs, $script:StreamChoice, $failDelay
                Write-Log $msg 'ERROR'
                # 协议回退：FLV 走不通就换 HLS 试（反之亦然）；被 -Stream 强制指定时不动
                if ($script:StreamPref -eq 'auto') {
                    if ($script:StreamChoice -like 'httpstream*') {
                        $script:PreferHls = $true
                        $script:StreamChoice = $null
                        Write-Log 'FLV 会话秒退，下一轮改试 HLS' 'WARN'
                    } elseif ($script:StreamChoice -like 'hls*' -and $script:PreferHls) {
                        $script:PreferHls = $false
                        $script:StreamChoice = $null
                        Write-Log 'HLS 也秒退，下一轮恢复按规则重新探测' 'WARN'
                    }
                }
                Start-Sleep -Seconds $failDelay
                $failDelay = [Math]::Min($failDelay * 2, 60)
            }
            continue
        }

        $failDelay = 5
        if ($script:StreamChoice -like 'httpstream*') { $script:PreferHls = $false }
        Write-Log ("本次会话持续 {0:N0} 秒，2 秒后重新解析地址续听（token 过期/断流/下播都会自动接上）" -f $sessSecs) 'INFO'
        Start-Sleep -Seconds 2    }
} finally {
    $secs = [int]((Get-Date) - $script:StartedAt).TotalSeconds
    # 自报内存：外部按进程名归属有歧义（本机 Get-CimInstance 被沙箱拒，拿不到父子关系）
    $rss = [math]::Round((Get-Process -Id $PID -ErrorAction SilentlyContinue).WorkingSet64 / 1MB, 1)
    Write-Log "===== 退出：总运行 ${secs} 秒，共 $sessions 次播放会话；本进程内存 ${rss}MB（ffplay/streamlink 子进程另计）=====" 'OK'
}
