<#
.SYNOPSIS
    frpctl - 跨平台 FRP 客户端多实例管理与 WebSSH 运维工具（Windows 版）

.DESCRIPTION
    支持多实例端口隔离部署、就地平滑升级（In-Place Upgrade）、Windows SCM 服务死锁（delete-pending）自动修复、
    以及内置 ttyd + 类哪吒探针风格右侧文件管理抽屉的进程级 WebSSH（-t webssh）。
    外部配置文件路径：C:\ProgramData\frpctl\frpctl.conf

.EXAMPLE
    frpctl config -ServerAddr frp.example.com -ServerPort 49000 -AuthToken MySecretToken
    frpctl install   -RemotePort 40005 -Remark 办公室电脑 -Protocol rdp -LocalPort 3389
    frpctl install   -RemotePort 40090 -Remark 远程终端   -Protocol webssh -WebAuth admin:ChangeMe123
    frpctl update    -RemotePort 40005
    frpctl uninstall -RemotePort 40005
    frpctl list
    frpctl status    -RemotePort 40005
    frpctl logs      -RemotePort 40005
    frpctl doctor
    frpctl self-update
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Action,

    # 端口可作为第二个位置参数直接传入：frpctl up 40006
    [Parameter(Position=1)]
    [Alias('p','port')]
    [ValidateRange(1,65535)]
    [int]$RemotePort,

    [Alias('r','name')]
    [string]$Remark,

    [Alias('t','proto')]
    [string]$Protocol,

    [Alias('l','local')]
    [int]$LocalPort = 0,

    # WebSSH 登录凭据（格式 user:pass；若只填密码则默认用户名为 admin）
    [Alias('a','auth')]
    [string]$WebAuth,

    # 服务端连接（命令行参数 > frpctl.conf > 默认值）
    [string]$ServerAddr,
    [int]$ServerPort = 0,
    [string]$AuthToken,

    # 强杀 mmc/Taskmgr 释放服务句柄（默认温和提示）
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 0. 全局常量 + 默认值（可被 frpctl.conf 覆盖）
# ============================================================
$Script:DefaultServerAddr = 'frp.example.com'
$Script:DefaultServerPort = 49000
$Script:DefaultAuthToken  = 'CHANGE_ME_TOKEN'
$Script:DefaultMirrors    = @(
    'https://ghfast.top/https://github.com',
    'https://ghproxy.net/https://github.com',
    'https://github.com'
)
$Script:DefaultFrpVersion = 'latest'   # latest = 自动从 GitHub Release 获取最新稳定版
$Script:SelfUpdateRepo    = if ($env:FRPCTL_REPO) { $env:FRPCTL_REPO } else { 'jfmeng/frp-ctl' }
$Script:SelfUpdateBranch  = if ($env:FRPCTL_BRANCH) { $env:FRPCTL_BRANCH } else { 'main' }
# 可选：若将仓库Fork为私有仓库，可通过环境变量 GH_TOKEN 传入访问令牌；公开仓库留空即可
$Script:SelfUpdateToken   = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { '' }

$InstallDir   = 'C:\Program Files\frp'
$BaseDir      = Join-Path $env:ProgramData 'frpctl'
$ConfFile     = Join-Path $BaseDir 'frpctl.conf'
$GitHubApi    = 'https://api.github.com'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ============================================================
# 1. 读取与保存 frpctl.conf
# ============================================================
function Read-Conf {
    $cfg = @{
        SERVER_ADDR      = $Script:DefaultServerAddr
        SERVER_PORT      = $Script:DefaultServerPort
        AUTH_TOKEN       = $Script:DefaultAuthToken
        FRP_VERSION      = $Script:DefaultFrpVersion
        GH_MIRRORS       = ($Script:DefaultMirrors -join ',')
        DEFAULT_PROTOCOL = 'rdp'
        WEBSSH_AUTH      = ''
    }
    if (Test-Path $ConfFile) {
        Get-Content $ConfFile -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
                $kv = $line -split '=', 2
                $k = $kv[0].Trim()
                $v = $kv[1].Trim()
                if ($v) { $cfg[$k] = $v }
            }
        }
    }
    return $cfg
}

function Save-Conf {
    param(
        [string]$Addr  = $ServerAddr,
        [int]$Port     = $ServerPort,
        [string]$Token = $AuthToken
    )
    if (-not (Test-Path $BaseDir)) {
        New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
    }
    $mirrorsStr = ($Mirrors -join ',')
    $content = @"
# frpctl 客户端全局配置文件
# 路径: $ConfFile

SERVER_ADDR=$Addr
SERVER_PORT=$Port
AUTH_TOKEN=$Token
FRP_VERSION=$($Cfg.FRP_VERSION)
GH_MIRRORS=$mirrorsStr
DEFAULT_PROTOCOL=$($Cfg.DEFAULT_PROTOCOL)
WEBSSH_AUTH=$($Cfg.WEBSSH_AUTH)
"@
    $content | Out-File -FilePath $ConfFile -Encoding utf8
    Write-Host "[√] 全局配置已保存至: $ConfFile" -ForegroundColor Green
}

$Cfg = Read-Conf

# 优先级：命令行 > frpctl.conf > 默认值
if (-not $ServerAddr)  { $ServerAddr = $Cfg.SERVER_ADDR }
if ($ServerPort -le 0) { $ServerPort = [int]$Cfg.SERVER_PORT }
if (-not $AuthToken)   { $AuthToken  = $Cfg.AUTH_TOKEN }
$Mirrors = $Cfg.GH_MIRRORS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# ============================================================
# 2. 通用工具：管理员检查、镜像下载、版本查询
# ============================================================
function Test-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (Test-Admin) { return }
    $self = $PSCommandPath
    if (-not $self) { throw '此操作需要管理员权限，请用管理员 PowerShell 重新运行。' }
    Write-Host '[*] 需要管理员权限，正在请求 UAC 提权...' -ForegroundColor Yellow
    $argLine = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$self`"", $Action)
    if ($RemotePort)      { $argLine += @('-RemotePort', $RemotePort) }
    if ($Remark)          { $argLine += @('-Remark',     "`"$Remark`"") }
    if ($Protocol)        { $argLine += @('-Protocol',   $Protocol) }
    if ($LocalPort -gt 0) { $argLine += @('-LocalPort',  $LocalPort) }
    if ($WebAuth)         { $argLine += @('-WebAuth',    "`"$WebAuth`"") }
    if ($ServerAddr -and $ServerAddr -ne $Cfg.SERVER_ADDR) { $argLine += @('-ServerAddr', "`"$ServerAddr`"") }
    if ($ServerPort -gt 0 -and $ServerPort -ne [int]$Cfg.SERVER_PORT) { $argLine += @('-ServerPort', $ServerPort) }
    if ($AuthToken -and $AuthToken -ne $Cfg.AUTH_TOKEN) { $argLine += @('-AuthToken', "`"$AuthToken`"") }
    if ($Force)           { $argLine += '-Force' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs | Out-Null
        Write-Host '[i] 已在新的管理员窗口中继续执行。' -ForegroundColor Cyan
        exit 0
    } catch {
        throw '提权失败，请手动以管理员身份运行 PowerShell。'
    }
}

function Download-WithMirrors {
    param(
        [Parameter(Mandatory)][string]$RelativeGitHubUrl,
        [Parameter(Mandatory)][string]$OutFile
    )
    foreach ($m in $Mirrors) {
        $base = $m.TrimEnd('/')
        $full = "$base/$RelativeGitHubUrl"
        try {
            Write-Host "  ↓ 尝试 $full" -ForegroundColor DarkGray
            Invoke-WebRequest -Uri $full -OutFile $OutFile -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            return $true
        } catch {
            Write-Host "    失败：$($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
    return $false
}

function Get-LatestRelease {
    param([string]$Repo, [string]$AssetFilter)
    $ver = $null
    $tag = $null

    # 1) 优先通过加速镜像解析 /releases/latest 页面（不依赖 api.github.com，防止 DNS 污染或 API 限流）
    foreach ($m in $Mirrors) {
        $base = $m.TrimEnd('/')
        try {
            $resp = Invoke-WebRequest -Uri "$base/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($resp.Content -match 'releases/tag/(v?([0-9]+\.[0-9]+\.[0-9]+))') {
                $tag = $Matches[1]
                $ver = $Matches[2]
                break
            }
        } catch {}
    }

    # 2) 若镜像未解析出，尝试直连 api.github.com
    if (-not $ver) {
        try {
            $res = Invoke-RestMethod -Uri "$GitHubApi/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $tag = $res.tag_name
            $ver = $tag.TrimStart('v')
        } catch {}
    }

    # 3) 最终兜底稳定版本，避免因查询超时中断安装
    if (-not $ver) {
        switch -Wildcard ($Repo) {
            '*fatedier/frp*' { $ver = '0.68.1'; $tag = 'v0.68.1' }
            '*winsw/winsw*'  { $ver = '2.12.0'; $tag = 'v2.12.0' }
            '*tsl0922/ttyd*' { $ver = '1.7.7';  $tag = '1.7.7' }
            default          { throw "查询 $Repo 最新版本失败" }
        }
        Write-Host "  [i] 在线查询版本超时，使用内置稳定版本: $ver" -ForegroundColor Yellow
    }

    $assetName = switch -Wildcard ($Repo) {
        '*fatedier/frp*' { "frp_${ver}_windows_amd64.zip" }
        '*winsw/winsw*'  { 'WinSW-x64.exe' }
        '*tsl0922/ttyd*' { 'ttyd.win32.exe' }
        default          { $AssetFilter }
    }

    return @{
        Version   = $ver
        Tag       = $tag
        AssetUrl  = "$Repo/releases/download/$tag/$assetName"
        AssetName = $assetName
    }
}

# ============================================================
# 3. 环境准备（执行策略 + Defender 白名单 + 电源防休眠）
# ============================================================
function Prepare-Environment {
    Write-Host "--- [环境准备] ---" -ForegroundColor Cyan

    try {
        $cur = Get-ExecutionPolicy -Scope LocalMachine -ErrorAction Stop
        if ($cur -notin @('RemoteSigned','Unrestricted')) {
            Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
            Write-Host "  [√] 执行策略已设为 RemoteSigned" -ForegroundColor Green
        }
    } catch {}

    try {
        $ex = Get-MpPreference -ErrorAction Stop | Select-Object -ExpandProperty ExclusionPath
        if ($null -eq $ex -or $ex -notcontains $InstallDir) {
            Add-MpPreference -ExclusionPath $InstallDir -ErrorAction Stop
            Write-Host "  [√] 已添加 Defender 排除项: $InstallDir" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [跳过] Defender 不可用，忽略" -ForegroundColor DarkGray
    }

    try {
        powercfg.exe -h off 2>&1 | Out-Null
        powercfg.exe -x -standby-timeout-ac 0 2>&1 | Out-Null
        powercfg.exe -x -standby-timeout-dc 0 2>&1 | Out-Null
        Write-Host "  [√] 已禁用睡眠/休眠（保证 frpc 持续在线）" -ForegroundColor Green
    } catch {}
    Write-Host "------------------"
}

# ============================================================
# 4. 死锁服务清理（解决 Windows SCM delete-pending 1072 错误）
# ============================================================
function Test-ServiceExists {
    param([string]$Name)
    sc.exe query $Name 2>&1 | Out-Null
    return ($LASTEXITCODE -ne 1060)   # 1060 = 服务不存在
}

function Wait-ServiceStopped {
    param([string]$Name, [int]$TimeoutSec = 30)
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        $out = sc.exe query $Name 2>&1 | Out-String
        if ($LASTEXITCODE -eq 1060) { return $true }
        if ($out -match 'STOPPED')  { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Kill-FrpcProcess {
    param([int]$Port)
    $cfg = Join-Path $InstallDir "frpc_${Port}.toml"
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'frpc.exe'" |
            Where-Object { $_.CommandLine -like "*$cfg*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Release-ServiceHandle {
    $mmc = Get-Process -Name mmc     -ErrorAction SilentlyContinue
    $tm  = Get-Process -Name Taskmgr -ErrorAction SilentlyContinue
    if ($mmc -or $tm) {
        if ($Force) {
            $mmc | Stop-Process -Force -ErrorAction SilentlyContinue
            $tm  | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            Write-Host "  [Force] 已强制关闭 services.msc / 任务管理器" -ForegroundColor Yellow
        } else {
            Write-Host "  [提示] 检测到 services.msc / 任务管理器已打开，可能持有服务句柄。" -ForegroundColor Yellow
            Write-Host "         如卸载/更新失败，请手动关闭它们，或在命令后追加 -Force。" -ForegroundColor Yellow
        }
    }
}

function Force-RenameDeadService {
    param([string]$ServiceID)
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceID"
    if (-not (Test-Path $regPath)) { return $true }
    $tomb = "$($ServiceID)_DEAD_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $tombPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$tomb"
    try {
        Copy-Item -Path $regPath -Destination $tombPath -Recurse -Force
        Remove-Item -Path $regPath -Recurse -Force
        Release-ServiceHandle
        sc.exe delete $ServiceID 2>&1 | Out-Null
        for ($i=1; $i -le 15; $i++) {
            if (-not (Test-ServiceExists -Name $ServiceID)) { return $true }
            Start-Sleep -Seconds 1
            sc.exe delete $ServiceID 2>&1 | Out-Null
        }
        return $true
    } catch {
        Write-Host "  [失败] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ============================================================
# 5. config / install / update / uninstall
# ============================================================
function Configure-FRP {
    Require-Admin
    Write-Host "--- [配置 frpctl 全局服务端参数] ---" -ForegroundColor Cyan
    Write-Host "配置文件路径: $ConfFile" -ForegroundColor DarkGray

    $inAddr = if ($PSBoundParameters.ContainsKey('ServerAddr') -and $ServerAddr) { $ServerAddr } else {
        $v = Read-Host "请输入 frps 服务端地址 (当前: $ServerAddr)"
        if ($v) { $v } else { $ServerAddr }
    }
    $inPort = if ($PSBoundParameters.ContainsKey('ServerPort') -and $ServerPort -gt 0) { $ServerPort } else {
        $v = Read-Host "请输入 frps 服务端端口 (当前: $ServerPort)"
        if ($v) { [int]$v } else { $ServerPort }
    }
    $inToken = if ($PSBoundParameters.ContainsKey('AuthToken') -and $AuthToken) { $AuthToken } else {
        $v = Read-Host "请输入 frps 认证 Token (当前: $AuthToken)"
        if ($v) { $v } else { $AuthToken }
    }

    $Script:ServerAddr = $inAddr
    $Script:ServerPort = $inPort
    $Script:AuthToken  = $inToken
    Save-Conf -Addr $inAddr -Port $inPort -Token $inToken
}

function Ensure-ServerConfigured {
    $needSave = $false
    if (-not $ServerAddr -or $ServerAddr -eq 'frp.example.com') {
        Write-Host "[!] 检测到尚未配置 frps 服务端地址（当前为示例值 frp.example.com）" -ForegroundColor Yellow
        do {
            $inAddr = Read-Host "请输入你的 frps 服务端域名或公网 IP"
        } while ([string]::IsNullOrWhiteSpace($inAddr))
        $Script:ServerAddr = $inAddr.Trim()
        $needSave = $true
    }
    if (-not $AuthToken -or $AuthToken -eq 'CHANGE_ME_TOKEN') {
        Write-Host "[!] 检测到尚未配置 frps 认证 Token（当前为示例值 CHANGE_ME_TOKEN）" -ForegroundColor Yellow
        do {
            $inTok = Read-Host "请输入你的 frps 认证 Token (auth.token)"
        } while ([string]::IsNullOrWhiteSpace($inTok))
        $Script:AuthToken = $inTok.Trim()
        $needSave = $true
    }
    if ($needSave) {
        $inPort = Read-Host "请输入 frps 服务端连接端口 (默认 $ServerPort)"
        if ($inPort) { $Script:ServerPort = [int]$inPort }
        Save-Conf -Addr $ServerAddr -Port $ServerPort -Token $AuthToken
    }
}

function Install-FRP {
    Require-Admin
    if (-not $RemotePort) { throw 'install 需要 -RemotePort 参数（例如: frpctl i 40005）' }

    Ensure-ServerConfigured

    # ---- 交互输入 ----
    if ([string]::IsNullOrWhiteSpace($Remark)) {
        $Script:Remark = Read-Host '请输入该节点备注 (例如: 办公室, 家里NAS)'
        if (-not $Remark) { $Script:Remark = '未命名' }
    }
    $SafeRemark = $Remark -replace '[^a-zA-Z0-9\u4e00-\u9fa5_]','_'

    if ([string]::IsNullOrWhiteSpace($Protocol)) {
        Write-Host '请选择协议:' -ForegroundColor Cyan
        Write-Host '  [1] rdp    (远程桌面 3389，自动开启 TCP+UDP)'
        Write-Host '  [2] ssh    (SSH 22)'
        Write-Host '  [3] web    (HTTP 80)'
        Write-Host '  [4] webssh (内置 ttyd 网页终端 + 右侧文件管理器，无视本机 SSH 端口改动)'
        Write-Host '  [5] custom'
        $c = Read-Host "请选择 [1-5] (默认 $($Cfg.DEFAULT_PROTOCOL))"
        $Script:Protocol = switch ($c) {
            '1' { 'rdp' }
            '2' { 'ssh' }
            '3' { 'web' }
            '4' { 'webssh' }
            '5' { Read-Host '请输入自定义协议名 (如 vnc/mysql)' }
            default { $Cfg.DEFAULT_PROTOCOL }
        }
    }
    $SafeProto = ($Protocol -replace '[^a-zA-Z0-9]','').ToLower()
    if (-not $SafeProto) { $SafeProto = 'tcp' }

    if ($SafeProto -eq 'webssh') {
        if ($LocalPort -le 0) {
            $Script:LocalPort = 17681 + ($RemotePort % 1000)
            Write-Host "[*] WebSSH 本地回环端口自动设为: 127.0.0.1:$LocalPort" -ForegroundColor Cyan
        }
        if ([string]::IsNullOrWhiteSpace($WebAuth)) { $Script:WebAuth = $Cfg.WEBSSH_AUTH }
        while ([string]::IsNullOrWhiteSpace($WebAuth)) {
            $Script:WebAuth = Read-Host '请设置 WebSSH 登录账号密码 (格式 用户名:密码，例如 admin:123456)'
        }
        if ($WebAuth -notmatch ':') { $Script:WebAuth = "admin:$WebAuth" }
    } elseif ($LocalPort -le 0) {
        $def = switch ($SafeProto) { 'rdp' {3389} 'ssh' {22} 'web' {80} default {3389} }
        $i = Read-Host "请输入本地端口 (默认 $def)"
        $Script:LocalPort = if ($i) { [int]$i } else { $def }
    }

    Prepare-Environment

    # ---- 取版本 ----
    $tag = if ($Cfg.FRP_VERSION -and $Cfg.FRP_VERSION -ne 'latest') { "v$($Cfg.FRP_VERSION.TrimStart('v'))" } else { $null }
    if (-not $tag) {
        $info = Get-LatestRelease -Repo 'fatedier/frp' -AssetFilter 'windows_amd64.zip'
        $tag = $info.Tag
        $frpVer = $info.Version
        $asset = $info.AssetName
    } else {
        $frpVer = $tag.TrimStart('v')
        $asset = "frp_${frpVer}_windows_amd64.zip"
    }
    $winsw = Get-LatestRelease -Repo 'winsw/winsw' -AssetFilter 'WinSW-x64.exe'

    Write-Host "[*] FRP 版本: $frpVer" -ForegroundColor Cyan
    Write-Host "[*] WinSW 版本: $($winsw.Version)" -ForegroundColor Cyan

    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    $TempDir = New-Item -ItemType Directory -Path "$InstallDir\temp_$(Get-Random)" -Force
    $LogDir = Join-Path $InstallDir 'logs'
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

    try {
        # ---- 下载 frp.zip ----
        $zip = Join-Path $TempDir.FullName 'frp.zip'
        Write-Host "[*] 下载 frp.zip..."
        if (-not (Download-WithMirrors -RelativeGitHubUrl "fatedier/frp/releases/download/$tag/$asset" -OutFile $zip)) {
            throw 'frp.zip 全部镜像下载失败'
        }
        Expand-Archive -Path $zip -DestinationPath $TempDir.FullName -Force
        $src = Resolve-Path "$($TempDir.FullName)\*windows_amd64\frpc.exe" -ErrorAction Stop
        Copy-Item $src.Path $InstallDir -Force

        # ---- 下载 WinSW ----
        $winswExe = "FRPService_${RemotePort}.exe"
        $winswPath = Join-Path $InstallDir $winswExe
        Write-Host "[*] 下载 WinSW..."
        if (-not (Download-WithMirrors -RelativeGitHubUrl $winsw.AssetUrl -OutFile $winswPath)) {
            throw 'WinSW 全部镜像下载失败'
        }

        # ---- 如为 webssh，下载 ttyd 并注册本地守护服务（含哪吒风格右侧文件管理抽屉） ----
        if ($SafeProto -eq 'webssh') {
            $ttydExe = Join-Path $InstallDir 'ttyd.exe'
            if (-not (Test-Path $ttydExe)) {
                $ttydRel = Get-LatestRelease -Repo 'tsl0922/ttyd' -AssetFilter 'ttyd.win32.exe'
                Write-Host "[*] 下载 ttyd ($($ttydRel.Version))..." -ForegroundColor Cyan
                if (-not (Download-WithMirrors -RelativeGitHubUrl $ttydRel.AssetUrl -OutFile $ttydExe)) {
                    throw 'ttyd.exe 全部镜像下载失败'
                }
            }
            Write-WebSSHAssets
            $ttydSvcId   = "frp_ttyd_$RemotePort"
            $ttydWinsw   = Join-Path $InstallDir "TTYDService_${RemotePort}.exe"
            $ttydXml     = Join-Path $InstallDir "TTYDService_${RemotePort}.xml"
            $gwScript    = Join-Path $InstallDir "webssh_gw.ps1"
            Copy-Item $winswPath $ttydWinsw -Force
            @"
<service>
  <id>$ttydSvcId</id>
  <name>$ttydSvcId</name>
  <description>ttyd WebSSH &amp; FileDrawer for FRP (Remark: $Remark, Port: $RemotePort)</description>
  <executable>powershell.exe</executable>
  <arguments>-NoProfile -ExecutionPolicy Bypass -File "$gwScript" -Port $LocalPort -c "$WebAuth" -Ttyd "$ttydExe" -Root "$InstallDir" -RemotePort $RemotePort -Token "$AuthToken"</arguments>
  <log mode="roll-by-size">
    <logpath>$LogDir</logpath>
    <logname>TTYDService_${RemotePort}.log</logname>
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>3</keepFiles>
  </log>
  <workingdirectory>$InstallDir</workingdirectory>
  <startmode>Automatic</startmode>
  <failure action="restart" delay="5 sec"/>
</service>
"@ | Out-File -FilePath $ttydXml -Encoding utf8

            if (Test-ServiceExists -Name $ttydSvcId) {
                sc.exe stop $ttydSvcId 2>&1 | Out-Null
                Wait-ServiceStopped -Name $ttydSvcId -TimeoutSec 10 | Out-Null
                sc.exe delete $ttydSvcId 2>&1 | Out-Null
                Start-Sleep -Seconds 2
            }
            Write-Host "[*] 安装并启动本地 WebSSH 服务 $ttydSvcId..." -ForegroundColor Cyan
            Start-Process -FilePath $ttydWinsw -ArgumentList 'install' -Wait -NoNewWindow | Out-Null
            Start-Process -FilePath $ttydWinsw -ArgumentList 'start'   -Wait -NoNewWindow | Out-Null
        }

        # ---- 写 frpc_xxx.toml（webssh 模式下，若公网端口在 40000..49999，自动将 frpc 隧道端口设为 +10000 供服务端 Nginx HTTPS 反代） ----
        $cfgPath = Join-Path $InstallDir "frpc_${RemotePort}.toml"
        $proxyName = "${SafeRemark}_${SafeProto}_${RemotePort}"
        $clientName = "${SafeRemark}_${RemotePort}"
        $tunnelPort = if ($SafeProto -eq 'webssh' -and $RemotePort -ge 40000 -and $RemotePort -lt 50000) { $RemotePort + 10000 } else { $RemotePort }
        $toml = @"
[common]
server_addr = "$ServerAddr"
server_port = $ServerPort
token = "$AuthToken"
user = "$clientName"
login_fail_exit = false
tcp_mux = true
heartbeat_interval = 30
heartbeat_timeout = 90

[$proxyName]
type = "tcp"
local_ip = "127.0.0.1"
local_port = $LocalPort
remote_port = $tunnelPort
health_check_type = "tcp"
health_check_timeout_s = 3
health_check_max_failed = 3
health_check_interval_s = 10
"@
        $udpEnabled = $false
        if ($SafeProto -eq 'rdp') {
            $toml += @"

[${proxyName}_udp]
type = "udp"
local_ip = "127.0.0.1"
local_port = $LocalPort
remote_port = $RemotePort
"@
            $udpEnabled = $true
        }
        $toml | Out-File -FilePath $cfgPath -Encoding utf8

        # ---- 写被动自毁守护脚本与 WinSW XML ----
        Write-FrpcGuard
        $guardScript = Join-Path $InstallDir "frpc_guard.ps1"
        $xmlPath = Join-Path $InstallDir "FRPService_${RemotePort}.xml"
        @"
<service>
  <id>frp_$RemotePort</id>
  <name>frp_$RemotePort</name>
  <description>FRP Client (Remark: $Remark)</description>
  <executable>powershell.exe</executable>
  <arguments>-NoProfile -ExecutionPolicy Bypass -File "$guardScript" -Port $RemotePort -Config "$cfgPath"</arguments>
  <log mode="roll-by-size">
    <logpath>$LogDir</logpath>
    <logname>FRPService_${RemotePort}.log</logname>
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
  <workingdirectory>$InstallDir</workingdirectory>
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
  <failure action="restart" delay="15 sec"/>
  <resetfailure>1 hour</resetfailure>
</service>
"@ | Out-File -FilePath $xmlPath -Encoding utf8

        # ---- 预清理同名残留 ----
        $svcId = "frp_$RemotePort"
        if (Test-ServiceExists -Name $svcId) {
            Write-Host "[!] SCM 残留同名服务，预清理..." -ForegroundColor Yellow
            Release-ServiceHandle
            sc.exe stop $svcId 2>&1 | Out-Null
            Wait-ServiceStopped -Name $svcId -TimeoutSec 15 | Out-Null
            sc.exe delete $svcId 2>&1 | Out-Null
            $gone = $false
            for ($i=1; $i -le 20; $i++) {
                if (-not (Test-ServiceExists -Name $svcId)) { $gone = $true; break }
                Start-Sleep -Seconds 1
            }
            if (-not $gone) {
                Force-RenameDeadService -ServiceID $svcId | Out-Null
                Start-Sleep -Seconds 2
            }
            if (Test-ServiceExists -Name $svcId) {
                Write-Host "[X] 服务 $svcId 处于「标记为删除」(delete-pending) 状态，SCM 拒绝重建同名服务。" -ForegroundColor Red
                Write-Host "    解决办法（按顺序尝试）：" -ForegroundColor Yellow
                Write-Host "    1. 关闭所有 services.msc、任务管理器、其他 PowerShell/CMD 窗口，重新运行本命令"
                Write-Host "    2. 注销当前用户重新登录（比重启快，通常就能释放句柄）"
                Write-Host "    3. 重启电脑后重新运行 frpctl install -RemotePort $RemotePort"
                throw "服务 $svcId 删除挂起，无法安装。"
            }
        }

        Write-Host "[*] 安装服务 $svcId..."
        $p = Start-Process -FilePath $winswPath -ArgumentList 'install' -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) {
            Write-Host "  [重试] 首次失败，刷新 SCM 后重试..." -ForegroundColor Yellow
            Release-ServiceHandle
            Force-RenameDeadService -ServiceID $svcId | Out-Null
            Start-Sleep -Seconds 3
            $p = Start-Process -FilePath $winswPath -ArgumentList 'install' -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -ne 0) { throw "服务安装失败 (ExitCode=$($p.ExitCode))" }
        }
        $p = Start-Process -FilePath $winswPath -ArgumentList 'start' -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { throw "服务启动失败" }

        Write-Host ""
        Write-Host "=========== 安装成功 ===========" -ForegroundColor Yellow
        Write-Host "  备注           : $Remark"
        Write-Host "  协议/本地端口  : $SafeProto / $LocalPort"
        Write-Host "  远程端口       : $RemotePort"
        Write-Host "  Proxies 名     : $proxyName"
        Write-Host "  Clients 名     : $clientName"
        if ($udpEnabled) { Write-Host "  UDP 加速       : ${proxyName}_udp" -ForegroundColor Cyan }
        if ($SafeProto -eq 'webssh') {
            Write-Host "  WebSSH 地址    : https://${ServerAddr}:${RemotePort}  (内部隧道端口: $tunnelPort)" -ForegroundColor Green
            Write-Host "  WebSSH 账号    : $($WebAuth.Split(':')[0]) (密码已设)" -ForegroundColor Green
        }
        Write-Host "================================" -ForegroundColor Yellow
    } finally {
        if ($TempDir -and (Test-Path $TempDir.FullName)) {
            Remove-Item $TempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Uninstall-FRP {
    Require-Admin
    if (-not $RemotePort) { throw 'uninstall 需要 -RemotePort 参数' }

    $svcId = "frp_$RemotePort"
    $winswExe = "FRPService_${RemotePort}.exe"
    $winswPath = Join-Path $InstallDir $winswExe
    $winswName = [IO.Path]::GetFileNameWithoutExtension($winswExe)

    Release-ServiceHandle
    if (Test-ServiceExists -Name $svcId) {
        Write-Host "[*] 清理服务 $svcId..." -ForegroundColor Cyan

        # 1) 先停服务，并等到真正 STOPPED（删除前没停干净 = delete-pending 的元凶）
        sc.exe stop $svcId 2>&1 | Out-Null
        if (-not (Wait-ServiceStopped -Name $svcId -TimeoutSec 20)) {
            Write-Host "  [!] 服务 20 秒内未停止，强制结束进程..." -ForegroundColor Yellow
        }

        # 2) 杀掉可能残留的 winsw 包装进程和 frpc 进程
        Get-Process -Name $winswName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Kill-FrpcProcess -Port $RemotePort
        Start-Sleep -Milliseconds 500

        # 3) winsw uninstall
        if (Test-Path $winswPath) {
            Start-Process -FilePath $winswPath -ArgumentList 'uninstall' -Wait -NoNewWindow | Out-Null
        }
        sc.exe delete $svcId 2>&1 | Out-Null

        # 4) 用 sc.exe query 轮询（不用 Get-Service —— 它会打开服务句柄，反而拖住 SCM 删除）
        $cleared = $false
        for ($i=1; $i -le 10; $i++) {
            if (-not (Test-ServiceExists -Name $svcId)) { $cleared = $true; break }
            Write-Host "  等待 SCM 清理... ($i/10)" -ForegroundColor DarkCyan
            Start-Sleep -Seconds 1
        }
        if (-not $cleared) {
            Write-Host "  服务标记为删除，启用注册表 tombstone..." -ForegroundColor Yellow
            Force-RenameDeadService -ServiceID $svcId | Out-Null
            if (Test-ServiceExists -Name $svcId) {
                Write-Host "  [!] 服务仍处于 delete-pending 状态。" -ForegroundColor Red
                Write-Host "      这是 Windows SCM 行为：有进程持有服务句柄时删除会挂起。" -ForegroundColor Red
                Write-Host "      请关闭 services.msc / 任务管理器 / 其他 PowerShell 窗口后重试，" -ForegroundColor Red
                Write-Host "      或重启电脑后再执行 frpctl install。" -ForegroundColor Red
                throw "服务 $svcId 处于删除挂起状态，无法继续。"
            }
        }
    } else {
        Write-Host "[i] 服务 $svcId 不存在，仅清理文件"
    }

    # 如存在配套的 frp_ttyd_<Port> 服务，一并卸载
    $ttydSvcId = "frp_ttyd_$RemotePort"
    $ttydWinsw = Join-Path $InstallDir "TTYDService_${RemotePort}.exe"
    if (Test-ServiceExists -Name $ttydSvcId) {
        Write-Host "[*] 清理配套 WebSSH 服务 $ttydSvcId..." -ForegroundColor Cyan
        sc.exe stop $ttydSvcId 2>&1 | Out-Null
        Wait-ServiceStopped -Name $ttydSvcId -TimeoutSec 10 | Out-Null
        if (Test-Path $ttydWinsw) {
            Start-Process -FilePath $ttydWinsw -ArgumentList 'uninstall' -Wait -NoNewWindow | Out-Null
        }
        sc.exe delete $ttydSvcId 2>&1 | Out-Null
    }

    if (Test-Path $InstallDir) {
        @($winswPath, "$InstallDir\FRPService_${RemotePort}.xml", "$InstallDir\frpc_${RemotePort}.toml",
          $ttydWinsw, "$InstallDir\TTYDService_${RemotePort}.xml") |
            ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }
        if ((Get-ChildItem -Path $InstallDir -Filter 'frpc_*.toml' -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "[√] 端口 $RemotePort 实例已卸载" -ForegroundColor Green
}

function Update-FRP {
    Require-Admin
    if (-not $RemotePort) { throw 'update 需要 -RemotePort 参数' }

    # ============================================================
    # 就地升级（in-place）：服务存在时只停服务 → 换 frpc.exe → 启服务。
    # 完全不删除/重建服务，从根源绕开 SCM delete-pending 问题。
    # ============================================================
    $svcId = "frp_$RemotePort"
    $frpcExe = Join-Path $InstallDir 'frpc.exe'

    # 若存在配套的 frp_ttyd_<port> 服务，同步升级 WebSSH 右侧文件管理抽屉组件
    $ttydSvcId = "frp_ttyd_$RemotePort"
    $ttydXml   = Join-Path $InstallDir "TTYDService_${RemotePort}.xml"
    if ((Test-ServiceExists -Name $ttydSvcId) -and (Test-Path $ttydXml)) {
        Write-Host "[*] 同步升级 WebSSH 右侧文件管理器组件 ($ttydSvcId)..." -ForegroundColor Cyan
        Write-WebSSHAssets
        $xmlRaw = Get-Content $ttydXml -Raw -Encoding UTF8
        $lpMatch = [regex]::Match($xmlRaw, '-p(?:ort)?\s+(\d+)', 'IgnoreCase')
        $acMatch = [regex]::Match($xmlRaw, '-c\s+"?([^"\s<]+)"?')
        if ($lpMatch.Success -and $acMatch.Success) {
            $lpVal = $lpMatch.Groups[1].Value
            $acVal = $acMatch.Groups[1].Value
            $gwScript = Join-Path $InstallDir "webssh_gw.ps1"
            $ttydExe  = Join-Path $InstallDir "ttyd.exe"
            $xmlRaw = $xmlRaw -replace '<executable>.*?</executable>', '<executable>powershell.exe</executable>'
            $xmlRaw = $xmlRaw -replace '<arguments>.*?</arguments>', "<arguments>-NoProfile -ExecutionPolicy Bypass -File `"$gwScript`" -Port $lpVal -c `"$acVal`" -Ttyd `"$ttydExe`" -Root `"$InstallDir`" -RemotePort $RemotePort -Token `"$AuthToken`"</arguments>"
            $xmlRaw | Out-File -FilePath $ttydXml -Encoding utf8
            sc.exe stop $ttydSvcId 2>&1 | Out-Null
            Wait-ServiceStopped -Name $ttydSvcId -TimeoutSec 10 | Out-Null
            sc.exe start $ttydSvcId 2>&1 | Out-Null
            Write-Host "[√] WebSSH 文件管理器组件已就绪" -ForegroundColor Green
        }
    }

    if ((Test-ServiceExists -Name $svcId) -and (Test-Path $frpcExe)) {
        Write-FrpcGuard
        $frpXml = Join-Path $InstallDir "FRPService_${RemotePort}.xml"
        $cfgPath = Join-Path $InstallDir "frpc_${RemotePort}.toml"
        $guardScript = Join-Path $InstallDir "frpc_guard.ps1"
        if (Test-Path $frpXml) {
            $fXmlRaw = Get-Content $frpXml -Raw -Encoding UTF8
            if ($fXmlRaw -notmatch 'frpc_guard\.ps1') {
                $fXmlRaw = $fXmlRaw -replace '<executable>.*?</executable>', '<executable>powershell.exe</executable>'
                $fXmlRaw = $fXmlRaw -replace '<arguments>.*?</arguments>', "<arguments>-NoProfile -ExecutionPolicy Bypass -File `"$guardScript`" -Port $RemotePort -Config `"$cfgPath`"</arguments>"
                $fXmlRaw | Out-File -FilePath $frpXml -Encoding utf8
            }
        }
        $tag = if ($Cfg.FRP_VERSION -and $Cfg.FRP_VERSION -ne 'latest') { "v$($Cfg.FRP_VERSION.TrimStart('v'))" } else { $null }
        if (-not $tag) {
            $info   = Get-LatestRelease -Repo 'fatedier/frp' -AssetFilter 'windows_amd64.zip'
            $tag    = $info.Tag
            $frpVer = $info.Version
            $asset  = $info.AssetName
        } else {
            $frpVer = $tag.TrimStart('v')
            $asset  = "frp_${frpVer}_windows_amd64.zip"
        }

        $curVer = ''
        try { $curVer = ((& $frpcExe -v) 2>$null | Out-String).Trim() } catch {}
        Write-Host "[*] 当前版本: $curVer → 目标版本: $frpVer" -ForegroundColor Cyan
        if ($curVer -and ($curVer -match [regex]::Escape($frpVer))) {
            Write-Host "[√] 已是最新版本，无需升级" -ForegroundColor Green
            return
        }

        # 1) 下载新版 zip 到临时目录
        $tmpDir = Join-Path $env:TEMP "frpctl_up_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $zipPath = Join-Path $tmpDir 'frp.zip'
        Write-Host "[*] 下载 $asset..." -ForegroundColor Cyan
        $ok = Download-WithMirrors -RelativeGitHubUrl "fatedier/frp/releases/download/$tag/$asset" -OutFile $zipPath
        if (-not $ok -or -not (Test-Path $zipPath)) {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            throw "下载 $asset 失败：所有镜像不可达。服务未受影响，仍在运行旧版本。"
        }
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
        $newExe = Get-ChildItem -Path $tmpDir -Filter 'frpc.exe' -Recurse | Select-Object -First 1
        if (-not $newExe) { throw '下载包中未找到 frpc.exe' }

        # 2) 停服务（等真正 STOPPED，只停不删）
        Write-Host "[*] 停止服务 $svcId..." -ForegroundColor Cyan
        sc.exe stop $svcId 2>&1 | Out-Null
        if (-not (Wait-ServiceStopped -Name $svcId -TimeoutSec 30)) {
            Kill-FrpcProcess -Port $RemotePort
            Start-Sleep -Seconds 2
        }

        # 3) 原子换文件（旧 exe 先改名保底，失败可回滚）
        $bak = "$frpcExe.old"
        Remove-Item $bak -Force -ErrorAction SilentlyContinue
        Move-Item -Path $frpcExe -Destination $bak -Force
        try {
            Move-Item -Path $newExe.FullName -Destination $frpcExe -Force
        } catch {
            Move-Item -Path $bak -Destination $frpcExe -Force
            throw "替换 frpc.exe 失败，已回滚: $($_.Exception.Message)"
        }

        # 4) 启动服务并验证
        Write-Host "[*] 启动服务 $svcId..." -ForegroundColor Cyan
        sc.exe start $svcId 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $st = (sc.exe query $svcId | Out-String)
        if ($st -match 'RUNNING') {
            Remove-Item $bak -Force -ErrorAction SilentlyContinue
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[√] 升级完成: $frpVer（服务未重建，零风险）" -ForegroundColor Green
        } else {
            Write-Host "[!] 新版启动失败，回滚旧版本..." -ForegroundColor Yellow
            sc.exe stop $svcId 2>&1 | Out-Null
            Wait-ServiceStopped -Name $svcId -TimeoutSec 15 | Out-Null
            Move-Item -Path $bak -Destination $frpcExe -Force
            sc.exe start $svcId 2>&1 | Out-Null
            throw '新版 frpc 启动失败，已回滚到旧版本。请用 frpctl logs 查看原因。'
        }
        return
    }

    # --- 服务不存在（或 frpc.exe 缺失）才走完整卸载+重装 ---
    $oldCfg = Join-Path $InstallDir "frpc_${RemotePort}.toml"
    if ((Test-Path $oldCfg) -and [string]::IsNullOrWhiteSpace($Remark)) {
        $content = Get-Content $oldCfg -Raw
        $oldRemark = $null; $oldProto = $null; $oldLocal = $null
        if ($content -match '(?m)^\[([^\[\]]+)_([a-z0-9]+)_' + [regex]::Escape("$RemotePort") + '\]') {
            $oldRemark = $Matches[1]
            $oldProto  = $Matches[2]
        }
        if ($content -match '(?m)^local_port\s*=\s*(\d+)') { $oldLocal = [int]$Matches[1] }

        if ($oldRemark -and $oldProto -and $oldLocal) {
            Write-Host "检测到原配置: 备注=$oldRemark 协议=$oldProto 本地端口=$oldLocal" -ForegroundColor Cyan
            $keep = Read-Host '是否保留原配置直接升级？[Y/n]'
            if ($keep -eq '' -or $keep -match '^[Yy]') {
                $Script:Remark    = $oldRemark
                $Script:Protocol  = $oldProto
                $Script:LocalPort = $oldLocal
                Write-Host "[√] 将按原配置升级，无需再次输入" -ForegroundColor Green
            }
        }
    }
    if (Test-ServiceExists -Name $svcId) {
        Uninstall-FRP
    }
    Install-FRP
}

# ============================================================
# 6. list / status / logs / self-update / doctor
# ============================================================
function List-FRP {
    Get-Service -Name 'frp_*' -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType, DisplayName |
        Format-Table -AutoSize
    if (Test-Path $InstallDir) {
        Get-ChildItem -Path $InstallDir -Filter 'frpc_*.toml' -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "  └ 配置: $($_.Name)" -ForegroundColor DarkGray
            }
    }
}

function Status-FRP {
    if (-not $RemotePort) { throw 'status 需要 -RemotePort 参数' }
    Get-Service -Name "frp_$RemotePort" -ErrorAction Stop |
        Select-Object Name, Status, StartType, DisplayName | Format-List
    $log = Join-Path $InstallDir "logs\FRPService_${RemotePort}.log"
    if (Test-Path $log) {
        Write-Host "--- 最近 20 行日志 ---" -ForegroundColor Cyan
        Get-Content $log -Tail 20
    }
}

function Logs-FRP {
    if (-not $RemotePort) { throw 'logs 需要 -RemotePort 参数' }
    $log = Join-Path $InstallDir "logs\FRPService_${RemotePort}.log"
    if (-not (Test-Path $log)) { throw "日志不存在: $log" }
    Get-Content $log -Tail 50 -Wait
}

function Self-Update {
    Require-Admin
    $target = $PSCommandPath
    if (-not $target) { $target = Join-Path $BaseDir 'frpctl.ps1' }
    Write-Host "[*] 自我更新到 $target" -ForegroundColor Cyan
    $tmp = "$target.new"
    $headers = @{}
    if ($Script:SelfUpdateToken) {
        $headers['Authorization'] = "token $Script:SelfUpdateToken"
    }
    foreach ($m in $Mirrors) {
        $rawBase = $m -replace 'https://github\.com$','https://raw.githubusercontent.com'
        $url = "$rawBase/$Script:SelfUpdateRepo/$Script:SelfUpdateBranch/frpctl.ps1?_=$(Get-Random)"
        try {
            Write-Host "  ↓ $url" -ForegroundColor DarkGray
            if ($headers.Count -gt 0) {
                Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 30 -Headers $headers
            } else {
                Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 30
            }
            Move-Item -Path $tmp -Destination $target -Force
            Write-Host "[√] frpctl.ps1 已更新" -ForegroundColor Green
            return
        } catch {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    throw 'self-update 失败：所有镜像不可达'
}

function Doctor-FRP {
    Write-Host "--- [frpctl 体检] ---" -ForegroundColor Cyan

    Write-Host "`n[1] 管理员权限"
    if (Test-Admin) { Write-Host "  [OK] 已以管理员运行" -ForegroundColor Green }
    else { Write-Host "  [!!] 非管理员，install/update/uninstall 会自动触发 UAC 提权" -ForegroundColor Yellow }

    Write-Host "`n[2] 全局配置 ($ConfFile)"
    if (Test-Path $ConfFile) {
        Write-Host "  [OK] 已存在配置文件 (Server: $ServerAddr`:$ServerPort)" -ForegroundColor Green
    } else {
        Write-Host "  [i] 尚未创建配置文件，当前使用: $ServerAddr`:$ServerPort（可执行 frpctl config 配置）" -ForegroundColor Yellow
    }

    Write-Host "`n[3] 本机 frp 实例"
    $svcs = @(Get-Service -Name 'frp_*' -ErrorAction SilentlyContinue)
    if ($svcs.Count -eq 0) { Write-Host "  (无)" -ForegroundColor DarkGray }
    foreach ($s in $svcs) {
        $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-16} {1}" -f $s.Name, $s.Status) -ForegroundColor $color
    }

    Write-Host "`n[4] delete-pending 检测"
    $pending = @()
    if (Test-Path $InstallDir) {
        Get-ChildItem -Path $InstallDir -Filter 'frpc_*.toml' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.BaseName -match 'frpc_(\d+)') {
                $id = "frp_$($Matches[1])"
                if ((Test-ServiceExists -Name $id) -and -not (Get-Service -Name $id -ErrorAction SilentlyContinue)) {
                    $pending += $id
                }
            }
        }
    }
    if ($pending.Count -gt 0) {
        Write-Host "  [!!] 以下服务处于「标记为删除」状态：" -ForegroundColor Red
        $pending | ForEach-Object { Write-Host "       $_" -ForegroundColor Red }
        Write-Host "       处理：关闭 services.msc/任务管理器 → 注销重登 → 仍不行则重启" -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] 无删除挂起的服务" -ForegroundColor Green
    }

    Write-Host "`n[5] frps 服务端连通性 ($ServerAddr : $ServerPort)"
    if ($ServerAddr -eq 'frp.example.com') {
        Write-Host "  [i] 服务端仍为示例地址 frp.example.com，请先运行 frpctl config 配置" -ForegroundColor Yellow
    } else {
        try {
            $r = Test-NetConnection -ComputerName $ServerAddr -Port $ServerPort -WarningAction SilentlyContinue
            if ($r.TcpTestSucceeded) { Write-Host "  [OK] TCP 可达" -ForegroundColor Green }
            else { Write-Host "  [!!] TCP 不可达，检查网络或 frps 是否在线" -ForegroundColor Red }
        } catch { Write-Host "  [?] 检测失败: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    Write-Host "`n[6] GitHub 镜像可用性"
    foreach ($m in $Mirrors) {
        $probe = "$($m.TrimEnd('/'))/fatedier/frp/releases"
        try {
            Invoke-WebRequest -Uri $probe -UseBasicParsing -TimeoutSec 8 -Method Head -ErrorAction Stop | Out-Null
            Write-Host "  [OK] $m" -ForegroundColor Green
        } catch {
            Write-Host "  [X]  $m" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n[7] 电源设置（防休眠掉线）"
    $hib = (powercfg /a 2>&1 | Out-String)
    if ($hib -match '休眠|Hibernate') { Write-Host "  [i] 建议执行 powercfg -h off（install 时已自动处理）" -ForegroundColor Yellow }
    else { Write-Host "  [OK] 休眠已关闭" -ForegroundColor Green }

    Write-Host "`n--- 体检完成 ---" -ForegroundColor Cyan
}

function Write-WebSSHAssets {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $drawerPath = Join-Path $InstallDir 'drawer.js'
    $gwPath     = Join-Path $InstallDir 'webssh_gw.ps1'

    @'
(function(){
  if (window.__frpctlDrawerLoaded) return;
  window.__frpctlDrawerLoaded = true;

  var style = document.createElement('style');
  style.textContent = [
    '#fm-fab{position:fixed;right:20px;bottom:20px;width:48px;height:48px;border-radius:50%;background:#1890ff;box-shadow:0 4px 12px rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center;cursor:pointer;z-index:100001;user-select:none;transition:transform .15s,background .15s}',
    '#fm-fab:hover{transform:scale(1.06);background:#40a9ff}',
    '#fm-drawer{position:fixed;top:0;right:0;width:30vw;min-width:320px;max-width:480px;height:100vh;background:#fff;color:#333;z-index:100000;display:none;flex-direction:column;border-left:1px solid #e8e8e8;box-shadow:-2px 0 10px rgba(0,0,0,.15);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;font-size:14px;box-sizing:border-box}',
    '#fm-drawer *{box-sizing:border-box}',
    '#fm-header{height:50px;min-height:50px;border-bottom:1px solid #ececec;display:flex;align-items:center;justify-content:space-between;padding:0 16px;background:#fff;position:relative}',
    '#fm-icon-btn{width:32px;height:32px;border-radius:4px;display:flex;align-items:center;justify-content:center;cursor:pointer;color:#555;border:none;background:transparent;padding:0}',
    '#fm-icon-btn:hover{background:#f5f5f5;color:#1890ff}',
    '#fm-cwd{flex:1;text-align:center;font-size:14px;color:#333;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 10px;cursor:pointer}',
    '#fm-cwd:hover{color:#1890ff;text-decoration:underline}',
    '#fm-progress{height:3px;width:0%;background:#1890ff;transition:width .2s;display:none}',
    '#fm-list{flex:1;overflow-y:auto;padding:12px 14px 76px 14px;background:#fff}',
    '.fm-item{border:1px solid #e4e7ed;border-radius:4px;padding:14px 16px;margin-bottom:8px;display:flex;align-items:center;justify-content:space-between;cursor:pointer;background:#fff;transition:border-color .15s,background .15s}',
    '.fm-item:hover{border-color:#c0c4cc;background:#f9fafc}',
    '.fm-left{display:flex;align-items:center;gap:12px;min-width:0;flex:1}',
    '.fm-name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#303133;font-size:14px}',
    '.fm-meta{font-size:12px;color:#909399;margin-left:10px;white-space:nowrap}',
    '#fm-menu{position:absolute;top:46px;left:12px;background:#fff;border:1px solid #ebeef5;border-radius:4px;box-shadow:0 2px 12px rgba(0,0,0,.12);display:none;flex-direction:column;min-width:150px;z-index:100002;padding:4px 0}',
    '.fm-menu-item{padding:8px 14px;font-size:13px;color:#333;cursor:pointer;white-space:nowrap}',
    '.fm-menu-item:hover{background:#ecf5ff;color:#1890ff}',
    '#fm-toast{position:fixed;top:14px;right:20px;background:#323232;color:#fff;padding:8px 14px;border-radius:4px;font-size:13px;z-index:100005;display:none;box-shadow:0 2px 8px rgba(0,0,0,.25)}'
  ].join('\n');
  document.head.appendChild(style);

  var fab = document.createElement('div');
  fab.id = 'fm-fab';
  fab.title = '打开/关闭文件管理器';
  fab.innerHTML = '<svg viewBox="0 0 24 24" width="24" height="24"><path fill="#ffc53d" d="M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z"/></svg>';

  var drawer = document.createElement('div');
  drawer.id = 'fm-drawer';
  drawer.innerHTML = [
    '<div id="fm-header">',
    '  <button id="fm-icon-btn" data-act="menu" title="菜单">',
    '    <svg viewBox="0 0 24 24" width="18" height="18"><path fill="currentColor" d="M3 6h18v2H3V6zm0 5h18v2H3v-2zm0 5h18v2H3v-2z"/></svg>',
    '  </button>',
    '  <div id="fm-cwd" title="点击可手动输入路径跳转">/</div>',
    '  <button id="fm-icon-btn" data-act="upload" title="上传文件到当前目录">',
    '    <svg viewBox="0 0 24 24" width="18" height="18"><path fill="currentColor" d="M9 16h6v-6h4l-7-7-7 7h4v6zm-4 2h14v2H5v-2z"/></svg>',
    '  </button>',
    '  <input id="fm-file-input" type="file" multiple style="display:none" />',
    '  <div id="fm-menu">',
    '    <div class="fm-menu-item" data-m="refresh">刷新当前目录</div>',
    '    <div class="fm-menu-item" data-m="default">回到默认目录</div>',
    '    <div class="fm-menu-item" data-m="jump">手动输入路径...</div>',
    '    <div class="fm-menu-item" data-m="mkdir">新建文件夹...</div>',
    '    <div style="border-top:1px solid #ebeef5;margin:4px 0"></div>',
    '    <div class="fm-menu-item" data-m="destroy-rm" style="color:#e6a23c">🗑️ 卸载当前端口实例</div>',
    '    <div class="fm-menu-item" data-m="destroy-purge" style="color:#f56c6c;font-weight:600">☢️ 彻底自毁并撤离本机</div>',
    '  </div>',
    '</div>',
    '<div id="fm-progress"></div>',
    '<div id="fm-list"></div>'
  ].join('');

  var toast = document.createElement('div');
  toast.id = 'fm-toast';

  document.body.appendChild(drawer);
  document.body.appendChild(fab);
  document.body.appendChild(toast);

  var currentCwd = '';
  var parentCwd = '';
  var sep = '\\';
  var isOpen = false;

  function showToast(msg, ms){
    toast.textContent = msg;
    toast.style.display = 'block';
    clearTimeout(toast._t);
    toast._t = setTimeout(function(){ toast.style.display = 'none'; }, ms || 2400);
  }

  function fmtSize(n){
    if (n === undefined || n === null) return '';
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
    return (n / 1073741824).toFixed(2) + ' GB';
  }

  function syncTerminalLayout(){
    var term = document.getElementById('terminal-container') || document.querySelector('.terminal') || document.body.firstElementChild;
    if (isOpen) {
      var w = drawer.getBoundingClientRect().width || Math.max(320, window.innerWidth * 0.3);
      if (term && term !== drawer && term !== fab) {
        term.style.width = (window.innerWidth - w) + 'px';
      }
    } else if (term && term !== drawer && term !== fab) {
      term.style.width = '100%';
    }
    setTimeout(function(){ window.dispatchEvent(new Event('resize')); }, 60);
  }

  function joinPath(base, name){
    if (!base) return name;
    if (base.endsWith('/') || base.endsWith('\\')) return base + name;
    return base + sep + name;
  }

  function loadDir(targetPath){
    var q = targetPath ? ('?path=' + encodeURIComponent(targetPath)) : '';
    fetch('/__fm__/list' + q, { credentials: 'same-origin' })
      .then(function(r){ return r.json(); })
      .then(function(data){
        if (data.error) { showToast('错误: ' + data.error, 3000); return; }
        currentCwd = data.cwd || '';
        parentCwd = data.parent !== undefined ? data.parent : '';
        sep = data.sep || '\\';
        var disp = currentCwd;
        if (disp && !disp.endsWith('/') && !disp.endsWith('\\')) disp += sep;
        document.getElementById('fm-cwd').textContent = disp || '/';
        renderList(data.items || []);
      })
      .catch(function(e){ showToast('加载目录失败: ' + e, 3000); });
  }

  function renderList(items){
    var box = document.getElementById('fm-list');
    box.innerHTML = '';

    var upRow = document.createElement('div');
    upRow.className = 'fm-item';
    upRow.innerHTML = '<div class="fm-left"><svg viewBox="0 0 24 24" width="18" height="18"><path fill="#606266" d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg><span class="fm-name">..</span></div>';
    upRow.onclick = function(){
      if (parentCwd !== undefined && parentCwd !== currentCwd) loadDir(parentCwd);
    };
    box.appendChild(upRow);

    items.forEach(function(it){
      var row = document.createElement('div');
      row.className = 'fm-item';
      var icon = it.is_dir
        ? '<svg viewBox="0 0 24 24" width="20" height="20"><path fill="#4e5969" d="M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z"/></svg>'
        : '<svg viewBox="0 0 24 24" width="18" height="18"><path fill="#8c939d" d="M14 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6zm-1 7V3.5L18.5 9H13z"/></svg>';
      var left = document.createElement('div');
      left.className = 'fm-left';
      left.innerHTML = icon;
      var nameSpan = document.createElement('span');
      nameSpan.className = 'fm-name';
      nameSpan.textContent = it.name;
      left.appendChild(nameSpan);
      row.appendChild(left);

      if (!it.is_dir) {
        var meta = document.createElement('span');
        meta.className = 'fm-meta';
        meta.textContent = fmtSize(it.size);
        row.appendChild(meta);
      }

      row.onclick = function(){
        var full = it.full_path || joinPath(currentCwd, it.name);
        if (it.is_dir) {
          loadDir(full);
        } else {
          var a = document.createElement('a');
          a.href = '/__fm__/download?path=' + encodeURIComponent(full);
          a.download = it.name;
          document.body.appendChild(a);
          a.click();
          a.remove();
        }
      };
      box.appendChild(row);
    });
  }

  function uploadFiles(files){
    if (!files || !files.length) return;
    var bar = document.getElementById('fm-progress');
    bar.style.display = 'block';
    bar.style.width = '5%';
    var idx = 0;

    function next(){
      if (idx >= files.length) {
        bar.style.width = '100%';
        setTimeout(function(){ bar.style.display = 'none'; bar.style.width = '0%'; }, 400);
        showToast('已上传 ' + files.length + ' 个文件');
        loadDir(currentCwd);
        return;
      }
      var f = files[idx++];
      showToast('正在上传 (' + idx + '/' + files.length + '): ' + f.name, 10000);
      var url = '/__fm__/upload?dir=' + encodeURIComponent(currentCwd) + '&name=' + encodeURIComponent(f.name);
      fetch(url, { method: 'POST', body: f, credentials: 'same-origin' })
        .then(function(r){ return r.json(); })
        .then(function(res){
          if (res.error) showToast('上传失败: ' + res.error, 4000);
          bar.style.width = Math.round((idx / files.length) * 100) + '%';
          next();
        })
        .catch(function(err){
          showToast('上传出错: ' + err, 4000);
          next();
        });
    }
    next();
  }

  fab.onclick = function(){
    isOpen = !isOpen;
    drawer.style.display = isOpen ? 'flex' : 'none';
    syncTerminalLayout();
    if (isOpen && !currentCwd) loadDir('');
  };

  window.addEventListener('resize', function(){
    if (isOpen) syncTerminalLayout();
  });

  drawer.addEventListener('click', function(e){
    var menu = document.getElementById('fm-menu');
    var btn = e.target.closest('#fm-icon-btn');
    if (btn) {
      var act = btn.getAttribute('data-act');
      if (act === 'menu') {
        menu.style.display = (menu.style.display === 'flex') ? 'none' : 'flex';
        e.stopPropagation();
        return;
      }
      if (act === 'upload') {
        document.getElementById('fm-file-input').click();
        return;
      }
    }
    var mi = e.target.closest('.fm-menu-item');
    if (mi) {
      menu.style.display = 'none';
      var m = mi.getAttribute('data-m');
      if (m === 'refresh') loadDir(currentCwd);
      if (m === 'default') loadDir('');
      if (m === 'jump') {
        var p = prompt('请输入要跳转的目录路径:', currentCwd || 'C:\\');
        if (p !== null && p.trim() !== '') loadDir(p.trim());
      }
      if (m === 'mkdir') {
        var name = prompt('请输入新建文件夹名称:');
        if (name && name.trim()) {
          fetch('/__fm__/mkdir?dir=' + encodeURIComponent(currentCwd) + '&name=' + encodeURIComponent(name.trim()), { method: 'POST', credentials: 'same-origin' })
            .then(function(){ loadDir(currentCwd); });
        }
      }
      if (m === 'destroy-rm') {
        if (confirm('⚠️ 确认要远程卸载当前端口的 FRP 穿透实例吗？\n卸载后当前连接将立即断开（本机其他端口实例保留）。')) {
          fetch('/__frpctl__/destroy?mode=rm', { method: 'POST', credentials: 'same-origin' })
            .then(function(r){ return r.json(); })
            .then(function(){ showToast('已下发单端口卸载指令，连接即将断开...', 5000); })
            .catch(function(){ showToast('卸载指令已发送，连接已断开', 5000); });
        }
      }
      if (m === 'destroy-purge') {
        var c = prompt('☢️ 高危操作：这将彻底卸载本机所有 frpctl 穿透服务并删除全部二进制与配置文件！\n确认无痕自毁请输入 DESTROY :');
        if (c === 'DESTROY') {
          fetch('/__frpctl__/destroy?mode=purge', { method: 'POST', credentials: 'same-origin' })
            .then(function(r){ return r.json(); })
            .then(function(){ showToast('☢️ 已触发客户端全盘无痕自毁，连接即将永久断开...', 6000); })
            .catch(function(){ showToast('☢️ 自毁指令已执行，连接已断开', 6000); });
        }
      }
      return;
    }
    menu.style.display = 'none';
  });

  document.getElementById('fm-cwd').onclick = function(){
    var p = prompt('跳转到目录路径:', currentCwd || 'C:\\');
    if (p !== null && p.trim() !== '') loadDir(p.trim());
  };

  document.getElementById('fm-file-input').onchange = function(e){
    uploadFiles(e.target.files);
    e.target.value = '';
  };

  drawer.addEventListener('dragover', function(e){ e.preventDefault(); });
  drawer.addEventListener('drop', function(e){
    e.preventDefault();
    if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) {
      uploadFiles(e.dataTransfer.files);
    }
  });
})();
'@ | Out-File -FilePath $drawerPath -Encoding utf8

    @'
param(
    [int]$Port,
    [string]$c,
    [string]$Ttyd,
    [string]$Root = 'C:\Program Files\frp',
    [int]$RemotePort = 0,
    [string]$Token = ''
)

$ttydPort = $Port + 10000
$authB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($c))
$drawerJs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'drawer.js'
if ($RemotePort -le 0) { $RemotePort = $Port - 17681 + 40000 }

$proc = Start-Process -FilePath $Ttyd -ArgumentList "-W -i 127.0.0.1 -p $ttydPort -c `"$c`" powershell.exe -NoLogo" -PassThru -WindowStyle Hidden

Add-Type -ReferencedAssemblies System.Web -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
using System.Web;

public class FrpWebSshGw {
    private static string EscJson(string s) {
        if (s == null) return "";
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
    }

    private static void SendBytes(NetworkStream ns, string status, string ctype, byte[] body, string extraHdr = "") {
        string hdr = "HTTP/1.1 " + status + "\r\nContent-Type: " + ctype + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\n" + extraHdr + "Connection: close\r\n\r\n";
        byte[] hb = Encoding.UTF8.GetBytes(hdr);
        ns.Write(hb, 0, hb.Length);
        if (body.Length > 0) ns.Write(body, 0, body.Length);
        ns.Flush();
    }

    private static void HandleClient(TcpClient client, int ttydPort, string authB64, string rootDir, string drawerJsPath, int remotePort, string token) {
        using (client)
        using (NetworkStream ns = client.GetStream()) {
            MemoryStream ms = new MemoryStream();
            byte[] buf = new byte[8192];
            int hdrEnd = -1;
            while (hdrEnd < 0) {
                int r = ns.Read(buf, 0, buf.Length);
                if (r <= 0) return;
                ms.Write(buf, 0, r);
                byte[] cur = ms.ToArray();
                for (int i = 0; i <= cur.Length - 4; i++) {
                    if (cur[i] == 13 && cur[i+1] == 10 && cur[i+2] == 13 && cur[i+3] == 10) {
                        hdrEnd = i + 4;
                        break;
                    }
                }
                if (cur.Length > 65536) return;
            }
            byte[] all = ms.ToArray();
            string hdrStr = Encoding.ASCII.GetString(all, 0, hdrEnd);
            string[] lines = hdrStr.Split(new string[]{"\r\n"}, StringSplitOptions.None);
            string[] reqParts = lines[0].Split(' ');
            if (reqParts.Length < 2) return;
            string method = reqParts[0].ToUpperInvariant();
            string rawTarget = reqParts[1];

            string authHdr = "";
            string upgradeHdr = "";
            string tokenHdr = "";
            long contentLen = 0;
            for (int i = 1; i < lines.Length; i++) {
                int idx = lines[i].IndexOf(':');
                if (idx > 0) {
                    string k = lines[i].Substring(0, idx).Trim().ToLowerInvariant();
                    string v = lines[i].Substring(idx + 1).Trim();
                    if (k == "authorization") authHdr = v;
                    if (k == "upgrade") upgradeHdr = v;
                    if (k == "x-frpctl-token") tokenHdr = v;
                    if (k == "content-length") long.TryParse(v, out contentLen);
                }
            }

            Uri uri = new Uri("http://localhost" + rawTarget);
            string path = uri.AbsolutePath;
            var qs = HttpUtility.ParseQueryString(uri.Query);

            if (path == "/__frpctl__/destroy" && (method == "POST" || method == "GET")) {
                bool authed = (authHdr.StartsWith("Basic ", StringComparison.OrdinalIgnoreCase) && authHdr.Substring(6).Trim() == authB64);
                string qTok = qs["token"] ?? "";
                if (!authed && !string.IsNullOrEmpty(token) && (tokenHdr == token || qTok == token)) {
                    authed = true;
                }
                if (!authed) {
                    SendBytes(ns, "401 Unauthorized", "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"error\":\"Unauthorized\"}"));
                    return;
                }
                string mode = (qs["mode"] ?? "rm").ToLowerInvariant();
                string respJson = "{\"ok\":true,\"mode\":\"" + EscJson(mode) + "\",\"port\":" + remotePort + "}";
                SendBytes(ns, "200 OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(respJson));
                string frpctlPs1 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "frpctl", "frpctl.ps1");
                string psCmd = (mode == "purge")
                    ? "Start-Sleep -Seconds 1; & '" + frpctlPs1 + "' purge -Force"
                    : "Start-Sleep -Seconds 1; & '" + frpctlPs1 + "' rm " + remotePort + " -Force";
                ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" + psCmd + "\"");
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                Process.Start(psi);
                return;
            }

            if ((path.StartsWith("/__fm__/") || path == "/" || path == "/index.html") &&
                (!authHdr.StartsWith("Basic ", StringComparison.OrdinalIgnoreCase) || authHdr.Substring(6).Trim() != authB64)) {
                SendBytes(ns, "401 Unauthorized", "text/plain", new byte[0], "WWW-Authenticate: Basic realm=\"WebSSH\"\r\n");
                return;
            }

            if (path == "/__fm__/drawer.js") {
                byte[] js = File.ReadAllBytes(drawerJsPath);
                SendBytes(ns, "200 OK", "application/javascript; charset=utf-8", js);
                return;
            }

            if (path == "/__fm__/list") {
                string reqPath = qs["path"];
                string target = string.IsNullOrWhiteSpace(reqPath) ? rootDir : reqPath;
                try {
                    if (target == "__drives__") {
                        StringBuilder dsb = new StringBuilder();
                        dsb.Append("{\"cwd\":\"\",\"parent\":\"\",\"sep\":\"\\\\\",\"items\":[");
                        bool df = true;
                        foreach (var drv in DriveInfo.GetDrives()) {
                            if (!df) dsb.Append(","); df = false;
                            dsb.Append("{\"name\":\"").Append(EscJson(drv.Name)).Append("\",\"full_path\":\"").Append(EscJson(drv.Name)).Append("\",\"is_dir\":true,\"size\":0}");
                        }
                        dsb.Append("]}");
                        SendBytes(ns, "200 OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(dsb.ToString()));
                        return;
                    }
                    DirectoryInfo di = new DirectoryInfo(target);
                    string parent = di.Parent != null ? di.Parent.FullName : "__drives__";
                    StringBuilder sb = new StringBuilder();
                    sb.Append("{\"cwd\":\"").Append(EscJson(di.FullName)).Append("\",\"parent\":\"").Append(EscJson(parent)).Append("\",\"sep\":\"\\\\\",\"items\":[");
                    bool first = true;
                    foreach (var d in di.GetDirectories()) {
                        if (!first) sb.Append(","); first = false;
                        sb.Append("{\"name\":\"").Append(EscJson(d.Name)).Append("\",\"is_dir\":true,\"size\":0}");
                    }
                    foreach (var f in di.GetFiles()) {
                        if (!first) sb.Append(","); first = false;
                        sb.Append("{\"name\":\"").Append(EscJson(f.Name)).Append("\",\"is_dir\":false,\"size\":").Append(f.Length).Append("}");
                    }
                    sb.Append("]}");
                    SendBytes(ns, "200 OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(sb.ToString()));
                } catch (Exception ex) {
                    string err = "{\"error\":\"" + EscJson(ex.Message) + "\",\"cwd\":\"" + EscJson(target) + "\",\"parent\":\"\",\"sep\":\"\\\\\",\"items\":[]}";
                    SendBytes(ns, "200 OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(err));
                }
                return;
            }

            if (path == "/__fm__/download") {
                string fpath = qs["path"];
                if (string.IsNullOrEmpty(fpath) || !File.Exists(fpath)) {
                    SendBytes(ns, "404 Not Found", "application/json", Encoding.UTF8.GetBytes("{\"error\":\"Not found\"}"));
                    return;
                }
                FileInfo fi = new FileInfo(fpath);
                string fn = Uri.EscapeDataString(fi.Name);
                string hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: " + fi.Length + "\r\nContent-Disposition: attachment; filename*=UTF-8''" + fn + "\r\nConnection: close\r\n\r\n";
                byte[] hb = Encoding.UTF8.GetBytes(hdr);
                ns.Write(hb, 0, hb.Length);
                using (FileStream fs = File.OpenRead(fpath)) {
                    fs.CopyTo(ns);
                }
                ns.Flush();
                return;
            }

            if (path == "/__fm__/upload" && method == "POST") {
                string dir = qs["dir"];
                if (string.IsNullOrEmpty(dir)) dir = rootDir;
                string name = Path.GetFileName(qs["name"] ?? "upload.bin");
                string dest = Path.Combine(dir, name);
                long rem = contentLen;
                try {
                    using (FileStream fs = File.Create(dest)) {
                        int already = all.Length - hdrEnd;
                        if (already > 0) {
                            int take = (int)Math.Min(already, rem);
                            fs.Write(all, hdrEnd, take);
                            rem -= take;
                        }
                        while (rem > 0) {
                            int r = ns.Read(buf, 0, (int)Math.Min(buf.Length, rem));
                            if (r <= 0) break;
                            fs.Write(buf, 0, r);
                            rem -= r;
                        }
                    }
                    SendBytes(ns, "200 OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":true}"));
                } catch (Exception ex) {
                    SendBytes(ns, "200 OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"error\":\"" + EscJson(ex.Message) + "\"}"));
                }
                return;
            }

            if (path == "/__fm__/mkdir" && method == "POST") {
                string dir = qs["dir"];
                if (string.IsNullOrEmpty(dir)) dir = rootDir;
                string name = Path.GetFileName(qs["name"] ?? "NewFolder");
                Directory.CreateDirectory(Path.Combine(dir, name));
                SendBytes(ns, "200 OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":true}"));
                return;
            }

            if (method == "GET" && (path == "/" || path == "/index.html") && !upgradeHdr.Equals("websocket", StringComparison.OrdinalIgnoreCase)) {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + ttydPort + "/");
                req.Headers["Authorization"] = "Basic " + authB64;
                req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                using (Stream rs = resp.GetResponseStream())
                using (MemoryStream rms = new MemoryStream()) {
                    rs.CopyTo(rms);
                    string html = Encoding.UTF8.GetString(rms.ToArray());
                    string inj = "<script src=\"/__fm__/drawer.js\"></script>";
                    if (html.Contains("</body>")) html = html.Replace("</body>", inj + "</body>");
                    else html += inj;
                    SendBytes(ns, "200 OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(html));
                }
                return;
            }

            using (TcpClient up = new TcpClient("127.0.0.1", ttydPort))
            using (NetworkStream ups = up.GetStream()) {
                ups.Write(all, 0, all.Length);
                ups.Flush();
                Task t1 = ns.CopyToAsync(ups);
                Task t2 = ups.CopyToAsync(ns);
                Task.WaitAny(t1, t2);
            }
        }
    }

    public static void Run(int port, int ttydPort, string authB64, string rootDir, string drawerJsPath, int remotePort, string token) {
        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        while (true) {
            TcpClient client = listener.AcceptTcpClient();
            Task.Run(() => {
                try { HandleClient(client, ttydPort, authB64, rootDir, drawerJsPath, remotePort, token); } catch {}
            });
        }
    }
}
"@

try {
    [FrpWebSshGw]::Run($Port, $ttydPort, $authB64, $Root, $drawerJs, $RemotePort, $Token)
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}
'@ | Out-File -FilePath $gwPath -Encoding utf8
}

function Write-FrpcGuard {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $guardPath = Join-Path $InstallDir 'frpc_guard.ps1'
    @'
param(
    [int]$Port,
    [string]$Config
)

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$frpcExe    = Join-Path $installDir 'frpc.exe'
$frpctlPs1  = Join-Path $env:ProgramData 'frpctl\frpctl.ps1'

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $frpcExe
$psi.Arguments = "-c `"$Config`""
$psi.WorkingDirectory = $installDir
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
[void]$proc.Start()

while (-not $proc.StandardOutput.EndOfStream) {
    $line = $proc.StandardOutput.ReadLine()
    if ($null -eq $line) { break }
    [Console]::WriteLine($line)
    if ($line -match 'FRPCTL_REVOKED_PURGE') {
        [Console]::WriteLine("[!] 收到服务端远程彻底自毁指令 (FRPCTL_REVOKED_PURGE)，正在执行全盘无痕卸载...")
        $cmd = "Start-Sleep -Seconds 1; & '$frpctlPs1' purge -Force"
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd)
        try { $proc.Kill() } catch {}
        exit 0
    } elseif ($line -match 'FRPCTL_REVOKED_DESTROY') {
        [Console]::WriteLine("[!] 收到服务端远程销毁端口指令 (FRPCTL_REVOKED_DESTROY)，正在卸载端口 $Port...")
        $cmd = "Start-Sleep -Seconds 1; & '$frpctlPs1' rm $Port -Force"
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd)
        try { $proc.Kill() } catch {}
        exit 0
    }
}
$proc.WaitForExit()
exit $proc.ExitCode
'@ | Out-File -FilePath $guardPath -Encoding utf8
}

function Purge-FRP {
    Require-Admin
    if (-not $Force) {
        $ans = Read-Host "⚠️ 确认彻底卸载本机所有 frpctl 穿透服务并删除全部二进制与配置文件？[y/N]"
        if ($ans -notmatch '^[Yy]$') {
            Write-Host "[i] 已取消" -ForegroundColor Yellow
            return
        }
    }

    Write-Host "[*] 正在停止并清理本机所有 frpctl 穿透服务与 WebSSH 服务..." -ForegroundColor Cyan
    Release-ServiceHandle

    $ports = New-Object System.Collections.Generic.HashSet[int]
    Get-Service -Name 'frp_*' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^frp_(?:ttyd_)?(\d+)$') { [void]$ports.Add([int]$Matches[1]) }
    }
    if (Test-Path $InstallDir) {
        Get-ChildItem -Path $InstallDir -Filter 'frpc_*.toml' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.BaseName -match '^frpc_(\d+)$') { [void]$ports.Add([int]$Matches[1]) }
        }
    }

    foreach ($p in $ports) {
        foreach ($svcId in @("frp_$p", "frp_ttyd_$p")) {
            if (Test-ServiceExists -Name $svcId) {
                sc.exe stop $svcId 2>&1 | Out-Null
                Wait-ServiceStopped -Name $svcId -TimeoutSec 10 | Out-Null
                sc.exe delete $svcId 2>&1 | Out-Null
                if (Test-ServiceExists -Name $svcId) {
                    Force-RenameDeadService -ServiceID $svcId | Out-Null
                }
                Write-Host "  - 已清理服务: $svcId" -ForegroundColor Green
            }
        }
    }

    Get-Process -Name 'frpc','ttyd','FRPService_*','TTYDService_*' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    try { Remove-MpPreference -ExclusionPath $InstallDir -ErrorAction SilentlyContinue } catch {}

    foreach ($scope in @('Machine','User')) {
        try {
            $curPath = [Environment]::GetEnvironmentVariable('Path', $scope)
            if ($curPath -and $curPath -like "*$BaseDir*") {
                $newPath = (($curPath -split ';') | Where-Object { $_ -and ($_ -ne $BaseDir) }) -join ';'
                [Environment]::SetEnvironmentVariable('Path', $newPath, $scope)
            }
        } catch {}
    }

    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path 'C:\frp') {
        Remove-Item 'C:\frp' -Recurse -Force -ErrorAction SilentlyContinue
    }

    $cleanCmd = "ping 127.0.0.1 -n 3 >nul & rmdir /s /q `"$InstallDir`" 2>nul & rmdir /s /q `"$BaseDir`" 2>nul"
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $cleanCmd" -WindowStyle Hidden
    Write-Host "[√] 已彻底卸载并无痕清理本机所有 frpctl 组件与文件" -ForegroundColor Green
}

function Set-WebSSHPasswd {
    Require-Admin
    if (-not $RemotePort) {
        $RemotePort = [int](Read-Host "请输入要修改 WebSSH 账号密码的远程端口 (如 40090)")
    }
    if ([string]::IsNullOrWhiteSpace($WebAuth) -or ($WebAuth -notmatch '^[^:]+:.+$')) {
        do {
            $WebAuth = Read-Host "请输入新的 WebSSH 登录账号:密码 (格式 用户名:密码，如 admin:123456)"
        } while ($WebAuth -notmatch '^[^:]+:.+$')
    }
    $ttydSvcId = "frp_ttyd_${RemotePort}"
    $ttydXml   = Join-Path $InstallDir "TTYDService_${RemotePort}.xml"
    if (-not (Test-Path $ttydXml)) {
        $ttydXml = Join-Path $InstallDir "${ttydSvcId}.xml"
    }
    if (-not (Test-Path $ttydXml)) {
        throw "未找到 WebSSH 配置文件: $ttydXml"
    }
    $content = Get-Content $ttydXml -Raw -Encoding UTF8
    $content = $content -replace '-c\s+"?[^"\s<]+"?', "-c `"$WebAuth`""
    $content | Out-File -FilePath $ttydXml -Encoding utf8
    sc.exe stop $ttydSvcId 2>&1 | Out-Null
    Wait-ServiceStopped -Name $ttydSvcId -TimeoutSec 10 | Out-Null
    sc.exe start $ttydSvcId 2>&1 | Out-Null
    Write-Host "[+] 已更新 $ttydSvcId 登录凭据并重启服务（新账号: $($WebAuth.Split(':')[0])）" -ForegroundColor Green
}

# ============================================================
# 8. 主入口（支持动作别名）
# ============================================================
$aliasMap = @{
    'cfg'='config';  'conf'='config';  'set'='config'
    'i'='install';   'add'='install';  'new'='install'
    'up'='update';   'u'='update';     'upgrade'='update'
    'rm'='uninstall';'del'='uninstall';'remove'='uninstall'; 'un'='uninstall'
    'purge'='purge'; 'nuke'='purge';   'destroy'='purge';    'clean-all'='purge'
    'ls'='list';     'l'='list'
    'st'='status';   's'='status'
    'log'='logs';    'f'='logs'
    'pw'='passwd';   'auth'='passwd'
    'selfupdate'='self-update'; 'su'='self-update'
    'doc'='doctor';  'check'='doctor'; 'dr'='doctor'
    'h'='help';      '--help'='help';  '-h'='help'
}
$act = $Action.ToLower()
if ($aliasMap.ContainsKey($act)) { $act = $aliasMap[$act] }

$valid = @('config','install','update','uninstall','purge','list','status','logs','passwd','self-update','doctor','help')
if ($valid -notcontains $act) {
    Write-Host "未知命令: $Action" -ForegroundColor Red
    $act = 'help'
}

function Show-Help {
    Write-Host @"
frpctl - 跨平台 FRP 客户端多实例管理与 WebSSH 运维工具

用法: frpctl <命令> [端口] [选项]

命令（含简写别名）:
  config   | cfg| set      设置/更新全局 frps 服务端地址与认证 Token
  install  | i  | add      安装并启动新的端口穿透实例
  update   | up | u        就地平滑升级实例（保留原配置，不删系统服务）
  passwd   | pw | auth     修改已安装 WebSSH 实例的网页登录账号密码
  uninstall| rm | del      卸载指定端口实例
  purge    | nuke | destroy 彻底卸载本机所有实例并无痕自毁清理
  list     | ls | l        列出所有已安装实例与状态
  status   | st | s        查看指定端口状态与最新日志
  logs     | log| f        实时滚动查看日志
  doctor   | dr | check    一键体检诊断（权限/服务/连通性/镜像/休眠）
  self-update | su         从云端升级 frpctl 自身
  help     | h             显示本帮助

选项（均支持短别名）:
  -p  <端口>       远程端口（也可直接作为第二个位置参数）
  -r  <备注>       节点备注名
  -t  <协议>       rdp / ssh / web / webssh / 自定义
  -l  <端口>       本地端口（webssh 模式免填，自动分配本机回环端口）
  -a  <账号:密码>  WebSSH 登录凭据（如 admin:ChangeMe123）
  -ServerAddr      覆盖 frps 服务端地址
  -ServerPort      覆盖 frps 服务端端口（默认 49000）
  -AuthToken       覆盖 frps 认证 Token
  -Force           卸载/重装时强制关闭占用服务句柄的管理器窗口 / 免确认自毁

示例:
  frpctl cfg -ServerAddr frp.example.com -ServerPort 49000 -AuthToken MySecretToken
  frpctl i 40006 -r 办公室电脑 -t rdp -l 3389
  frpctl i 40090 -r 远程终端   -t webssh -a admin:ChangeMe123
  frpctl up 40006
  frpctl rm 40006
  frpctl purge -Force
  frpctl ls
  frpctl dr
"@ -ForegroundColor Cyan
}

if ($act -ne 'help') {
    Write-Host ""
    Write-Host "=== frpctl ($act) ===" -ForegroundColor Magenta
}
try {
    switch ($act) {
        'config'      { Configure-FRP }
        'install'     { Install-FRP }
        'update'      { Update-FRP }
        'uninstall'   { Uninstall-FRP }
        'purge'       { Purge-FRP }
        'list'        { List-FRP }
        'status'      { Status-FRP }
        'logs'        { Logs-FRP }
        'passwd'      { Set-WebSSHPasswd }
        'self-update' { Self-Update }
        'doctor'      { Doctor-FRP }
        'help'        { Show-Help }
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
