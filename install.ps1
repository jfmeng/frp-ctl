<#
  frpctl - Windows 引导安装脚本
  -----------------------------------------------------------
  用法（PowerShell 管理员，下载到临时文件再执行）：
    $t="$env:TEMP\install-frpctl.ps1"
    iwr -UseBasicParsing -Uri 'https://ghfast.top/https://raw.githubusercontent.com/jfmeng/frp-ctl/main/install.ps1' -OutFile $t
    & $t

  本脚本负责：
    1) 拉取最新的 frpctl.ps1 主脚本到 %ProgramData%\frpctl\
    2) 将 %ProgramData%\frpctl 加入系统/用户 PATH
    3) 生成 frpctl.cmd 包装器（支持在 CMD 与 PowerShell 中直接调用 frpctl）
    4) 如设置了 $env:FRPCTL_ARGS，安装后立即执行一次

  注意：本脚本不使用 param() 块（避免 iex 内存执行时与自动变量冲突）。
#>

# ----- 配置区 -----
$Repo       = if ($env:FRPCTL_REPO)   { $env:FRPCTL_REPO }   else { 'jfmeng/frp-ctl' }
$Branch     = if ($env:FRPCTL_BRANCH) { $env:FRPCTL_BRANCH } else { 'main' }
$Mirrors    = @(
    'https://ghfast.top/https://raw.githubusercontent.com',
    'https://ghproxy.net/https://raw.githubusercontent.com',
    'https://raw.githubusercontent.com'
)
$MainScript = 'frpctl.ps1'
# 可选：若从私有 Fork 仓库下载，可通过 $env:GH_TOKEN 传入访问令牌
$GHToken    = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { '' }
# ------------------

$ErrorActionPreference = 'Stop'

# 管理员权限检查
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error '请以管理员身份运行 PowerShell 后再执行此安装命令。'
    exit 1
}

# 目标目录
$BaseDir = Join-Path $env:ProgramData 'frpctl'
if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
$Target = Join-Path $BaseDir $MainScript

# 镜像 fallback 下载
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ok = $false
$headers = @{}
if ($GHToken) { $headers['Authorization'] = "token $GHToken" }

foreach ($m in $Mirrors) {
    $url = "$m/$Repo/$Branch/${MainScript}?_=$(Get-Random)"
    try {
        Write-Host "[*] 正在尝试: $url" -ForegroundColor Cyan
        if ($headers.Count -gt 0) {
            Invoke-WebRequest -Uri $url -OutFile $Target -UseBasicParsing -TimeoutSec 30 -Headers $headers
        } else {
            Invoke-WebRequest -Uri $url -OutFile $Target -UseBasicParsing -TimeoutSec 30
        }
        $ok = $true; break
    } catch {
        Write-Warning ("  失败：" + $_.Exception.Message)
    }
}
if (-not $ok) { Write-Error '所有镜像均下载失败，请检查网络连接。'; exit 1 }
Write-Host "[√] frpctl.ps1 已下载到 $Target" -ForegroundColor Green

# 若设置了环境变量 FRP_SERVER_ADDR / FRP_AUTH_TOKEN，自动生成 frpctl.conf
$ConfFile = Join-Path $BaseDir 'frpctl.conf'
if ($env:FRP_SERVER_ADDR -or $env:FRP_AUTH_TOKEN) {
    $srvAddr = if ($env:FRP_SERVER_ADDR) { $env:FRP_SERVER_ADDR } else { 'frp.example.com' }
    $srvPort = if ($env:FRP_SERVER_PORT) { $env:FRP_SERVER_PORT } else { '49000' }
    $token   = if ($env:FRP_AUTH_TOKEN)  { $env:FRP_AUTH_TOKEN }  else { 'CHANGE_ME_TOKEN' }
    @"
SERVER_ADDR=$srvAddr
SERVER_PORT=$srvPort
AUTH_TOKEN=$token
FRP_VERSION=latest
DEFAULT_PROTOCOL=rdp
"@ | Out-File -FilePath $ConfFile -Encoding utf8 -Force
    Write-Host "[√] 已根据环境变量生成配置文件: $ConfFile" -ForegroundColor Green
}

# 加入 PATH：优先系统级（所有账号/管理员窗口都能用），无权限时退回用户级
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$scope = if ($isAdmin) { 'Machine' } else { 'User' }
$curPath = [Environment]::GetEnvironmentVariable('Path', $scope)
if ($curPath -notlike "*$BaseDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$curPath;$BaseDir", $scope)
    Write-Host "[√] 已将 $BaseDir 加入 $(if($scope -eq 'Machine'){'系统'}else{'用户'}) PATH" -ForegroundColor Green
}
# 当前会话立即生效
if ($env:Path -notlike "*$BaseDir*") { $env:Path = "$env:Path;$BaseDir" }

# 写 frpctl.cmd 包装器（cmd / PowerShell 都能直接敲 frpctl）
$wrapper = Join-Path $BaseDir 'frpctl.cmd'
@"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0frpctl.ps1" %*
"@ | Out-File -FilePath $wrapper -Encoding ascii -Force

Write-Host ''
Write-Host '=== frpctl 已就绪 ===' -ForegroundColor Magenta
Write-Host '常用命令：' -ForegroundColor Magenta
Write-Host '  frpctl config -ServerAddr frp.example.com -ServerPort 49000 -AuthToken <TOKEN> # 初始化服务端配置'
Write-Host '  frpctl i  40005 -r 办公室电脑 -t rdp -l 3389                                    # 安装 RDP 穿透'
Write-Host '  frpctl i  40090 -r 办公室终端 -t webssh -a admin:StrongPass123                  # 安装 WebSSH + 文件管理'
Write-Host '  frpctl up 40005                                                                 # 就地平滑升级'
Write-Host '  frpctl rm 40005                                                                 # 卸载实例'
Write-Host '  frpctl ls                                                                       # 实例列表'
Write-Host '  frpctl dr                                                                       # 一键体检'
Write-Host '  frpctl h                                                                        # 查看帮助'
Write-Host ''
Write-Host '提示：如当前窗口输入 frpctl 提示找不到命令，请重新打开一个 PowerShell 窗口。' -ForegroundColor DarkGray
Write-Host ''

# 如设置了 FRPCTL_ARGS，安装后立即执行一次
if ($env:FRPCTL_ARGS) {
    Write-Host "[*] 检测到 FRPCTL_ARGS，立即执行：frpctl $env:FRPCTL_ARGS" -ForegroundColor Cyan
    $argList = $env:FRPCTL_ARGS -split '\s+'
    & $Target @argList
}
