# frp-ctl (frpctl) — 跨平台 FRP 客户端多实例管理与 WebSSH 远程运维工具

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-success.svg)](#)
[![Arch](https://img.shields.io/badge/Arch-amd64%20%7C%20arm64%20%7C%20armv7-orange.svg)](#)

`frp-ctl`（命令行入口 `frpctl`）是一套面向 **Windows（PowerShell 5.1+）**、**Linux（systemd）** 与 **macOS（launchd）** 的跨平台 FRP 客户端多实例管理与远程运维工具链。它支持按端口隔离的多隧道实例管理、零停机风险的就地平滑升级（In-Place Upgrade），并内置基于 `ttyd` 的**进程级 WebSSH 终端 + 类哪吒探针风格的右侧抽屉式文件管理器**。

---

## 核心特性

1. **全平台统一命令与短别名**：
   Windows 与 Linux / macOS 共享完全一致的子命令（`cfg`、`i`、`up`、`pw`、`rm`、`ls`、`st`、`f`、`dr`、`su`）和参数选项（`-p`、`-r`、`-t`、`-l`、`-a`）。
2. **就地平滑升级（In-Place Upgrade）**：
   升级 `frpc` 时采用“停止服务 → 原子备份并替换二进制 → 启动服务（失败自动回滚）”机制，**不删除系统服务**，从根源解决 Windows 服务控制管理器（SCM）因句柄占用导致的 `delete-pending`（错误码 1072 / 1073）死锁问题。
3. **进程级 WebSSH 与右侧文件管理抽屉（`-t webssh`）**：
   - **免依赖 `sshd`**：基于 `ttyd` 在客户端本机回环地址 `127.0.0.1` 直接拉起系统 Shell（Linux 为 `/bin/bash -l`，Windows 为 `powershell.exe`）。即使客户端修改了 SSH 端口或未开启 SSH 服务，WebSSH 依然可用，可作为可靠的“救砖终端”。
   - **内置右侧抽屉文件管理器**：网页右下角常驻悬浮文件夹按钮，点击即可滑出文件管理面板（终端宽度自动自适应重排），支持全盘目录浏览（Windows 支持跨盘符切换）、点击文件直接下载、多文件按钮上传/拖拽上传（带实时进度条）、新建文件夹与路径跳转。
4. **服务端 Nginx SSL 统一反代与端口隔离规划**：
   - 当 `-t webssh` 使用 `40000 ~ 49999` 范围内的公网端口（如 `40090`）时，客户端会自动将底层 `frpc` 隧道远程端口映射为 `+10000`（如 `50090`），由服务端 Nginx 监听公网 `40090`（HTTPS + WebSocket）并反向代理至 `127.0.0.1:50090`，客户端无需分发任何证书即可直接通过 `https://frp.example.com:40090` 安全访问。
5. **Windows 无人值守深度优化**：
   - 自动配置 Windows Defender 目录排除项、关闭系统休眠与睡眠，并提供独立的 `power-tweak.ps1` 工具一键固化电源策略（关闭快速启动、禁用网卡节能、锁屏不断网）。
6. **多镜像加速与离线版本兜底**：
   - 内置 GitHub 镜像列表顺序回退，直接解析 Release 页面获取最新稳定版本号，不强依赖 `api.github.com`，避免因 API 限流或 DNS 污染导致安装中断。

---

## 架构与端口分段规划

为了彻底避免 `frps` 直连端口（如 RDP 远程桌面、传统 SSH）与 `Nginx` HTTPS 反代端口（WebSSH）发生冲突，推荐采用以下端口分段规划：

```text
[浏览器 HTTPS] ──► 服务端 Nginx (0.0.0.0:40090~40099 SSL)
                        │
                        ▼ 反代 HTTP + WebSocket
                 服务端 frps (127.0.0.1:50090~50099)
                        ▲
                        │ FRP 隧道 (控制端口 49000)
                        ▼
                 客户端本地网关 webssh_gw (127.0.0.1:17681+尾号)
                   ├── /__fm__/*  ──► 右侧抽屉文件管理 API (浏览/上传/下载/新建目录)
                   └── /*         ──► 客户端 ttyd (127.0.0.1:27681+尾号) ──► bash / PowerShell
```

| 端口段 | 协议类型 | 用途规划 | 监听进程 | 云服务器防火墙/安全组是否放行 |
|---|---|---|---|---|
| **`49000`** | **TCP** | **`frps` 控制通信总端口**（所有客户端连接服务端必用） | `frps` (`0.0.0.0`) | **必须放行 (TCP)** |
| **`40001 ~ 40089`** | **TCP + UDP** | **远程桌面 (RDP) / 传统 SSH / TCP 专属号段** | `frps` (`0.0.0.0`) | **必须放行 (TCP + UDP)** |
| **`40090 ~ 40099`** | **TCP** | **WebSSH 网页终端专属号段**（HTTPS + 右侧文件管理） | `Nginx` (`0.0.0.0 ssl`) | **必须放行 (仅 TCP)** |
| **`50090 ~ 50099`** | **TCP** | **WebSSH 内部隧道端口**（`frpctl` 自动将 `4009x` 映射为 `5009x`） | `frps` (`127.0.0.1`) | **无需放行**（仅服务端本机回环） |
| **`17681 + 端口尾号`** | **TCP** | **客户端本机 WebSSH 网关与文件管理接口** | 客户端 `127.0.0.1` | 无需放行 |
| **`27681 + 端口尾号`** | **TCP** | **客户端本机 `ttyd` 终端进程端口** | 客户端 `127.0.0.1` | 无需放行 |

---

## 第一部分：服务端部署（一次性配置）

服务端只需部署一次 `frps` 与（可选的）`Nginx` HTTPS 反向代理，后续新增客户端节点时服务端无需任何改动。仓库 `examples/` 目录下提供了完整的配置模板：

- [`examples/frps.toml.example`](examples/frps.toml.example)：服务端 `frps` 配置模板
- [`examples/nginx-webssh.conf.example`](examples/nginx-webssh.conf.example)：服务端 WebSSH HTTPS 反向代理配置模板

### 1.1 配置 `frps.toml`

```toml
bindAddr = "0.0.0.0"
bindPort = 49000

auth.method = "token"
auth.token = "CHANGE_ME_TO_STRONG_TOKEN"

# 可选：服务端 Dashboard 监控面板（建议仅绑定 127.0.0.1 或限制内网访问）
webServer.addr = "127.0.0.1"
webServer.port = 49500
webServer.user = "admin"
webServer.password = "CHANGE_ME_DASHBOARD_PASS"

allowPorts = [
  { start = 40001, end = 40089 },
  { start = 50090, end = 50099 }
]
```

### 1.2 配置 Nginx WebSSH HTTPS 反向代理（可选，推荐）

如果你希望通过 HTTPS 安全访问 WebSSH（`40090 ~ 40099`），请将 [`examples/nginx-webssh.conf.example`](examples/nginx-webssh.conf.example) 复制到 `/etc/nginx/conf.d/frp-webssh.conf`，并替换为你自己的域名与 SSL 证书路径（例如使用 Certbot / Let's Encrypt 签发的证书）：

```bash
sudo cp examples/nginx-webssh.conf.example /etc/nginx/conf.d/frp-webssh.conf
# 编辑域名与 ssl_certificate 路径后重载 Nginx
sudo nginx -t && sudo systemctl reload nginx
```

---

## 第二部分：客户端快速开始

### 1. Linux / macOS 客户端部署

适用系统：Debian / Ubuntu / CentOS / Rocky / Alpine / Armbian（树莓派、ARM 盒子）及 macOS。

#### 第一步：一键安装 `frpctl`

```bash
curl -fsSL "https://raw.githubusercontent.com/jfmeng/frp-ctl/main/install.sh" | sudo bash
```

> **提示**：你也可以在安装时通过环境变量直接写入你的 `frps` 服务端配置：
> ```bash
> curl -fsSL "https://raw.githubusercontent.com/jfmeng/frp-ctl/main/install.sh" | \
>   sudo FRP_SERVER_ADDR="frp.example.com" FRP_SERVER_PORT="49000" FRP_AUTH_TOKEN="你的Token" bash
> ```

#### 第二步：配置服务端地址（若第一步未通过环境变量指定）

```bash
sudo frpctl cfg --server frp.example.com --server-port 49000 --token 你的Token
```

> 如果未提前执行 `frpctl cfg`，首次运行 `frpctl i` 安装实例时脚本也会自动交互引导你输入并保存到 `/etc/frpctl/frpctl.conf`。

#### 第三步：添加穿透实例

- **方式 A：安装 WebSSH 网页终端 + 右侧文件管理器（推荐）**
  假设分配公网端口 **`40090`**（脚本会自动将底层 `frpc` 隧道端口设为 `50090` 对接服务端 Nginx）：
  ```bash
  sudo frpctl i 40090 -r 生产服务器 -t webssh -a admin:YourStrongPassword
  ```
  安装完成后，浏览器打开：`https://frp.example.com:40090`

- **方式 B：安装传统 SSH 端口映射**
  ```bash
  sudo frpctl i 40005 -r 生产服务器SSH -t ssh -l 22
  ```

---

### 2. Windows 客户端部署

适用系统：Windows 10 / Windows 11 / Windows Server 2016+（自动关闭休眠防断连、自动配置 Windows Defender 白名单）。

#### 第一步：在管理员 PowerShell 中一键安装 `frpctl`

```powershell
$t = "$env:TEMP\install-frpctl.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/jfmeng/frp-ctl/main/install.ps1" -UseBasicParsing -OutFile $t
& $t
```

#### 第二步：配置服务端地址

```powershell
frpctl cfg -ServerAddr frp.example.com -ServerPort 49000 -AuthToken 你的Token
```

#### 第三步：添加穿透实例（单机可同时运行多个端口）

- **方式 A：安装 WebSSH 网页终端 + 右侧文件管理器**
  ```powershell
  frpctl i 40091 -r 办公室工作站 -t webssh -a admin:YourStrongPassword
  ```
  安装完成后，浏览器打开 `https://frp.example.com:40091` 即可直接进入管理员 PowerShell 终端并管理全盘文件。

- **方式 B：安装 RDP 远程桌面穿透（自动开启 TCP + UDP 双通道加速）**
  ```powershell
  frpctl i 40012 -r 办公室工作站桌面 -t rdp -l 3389
  ```
  安装完成后，使用 Windows 远程桌面（`mstsc`）连接 `frp.example.com:40012`。

- **可选：运行 Windows 无人值守电源固化脚本**
  针对笔记本合盖睡眠、快速启动（Fast Startup）或网卡节能导致的断连，可在管理员 PowerShell 中执行仓库附带的 [`power-tweak.ps1`](power-tweak.ps1)：
  ```powershell
  .\power-tweak.ps1
  ```

---

## 第三部分：命令与参数速查表（全平台通用）

### 1. 子命令速查

| 完整命令 | 简写别名（推荐） | 功能说明 | 示例 |
|---|---|---|---|
| `config` | **`cfg`** / `set` | 设置或修改本机全局 `frps` 服务端地址、端口与 Token | `frpctl cfg` |
| `install` | **`i`** / `add` | 安装并启动一个新的端口穿透实例 | `frpctl i 40090 -r 节点名 -t webssh -a admin:123456` |
| `update` | **`up`** / `u` | 就地平滑升级指定端口的 `frpc` 及 WebSSH 组件（不删系统服务） | `frpctl up 40090` |
| `passwd` | **`pw`** / `auth` | 修改已安装 WebSSH 实例的网页登录账号与密码 | `frpctl pw 40090 -a admin:NewPass123` |
| `list` | **`ls`** / `l` | 列出本机所有已安装的穿透端口、状态与配置文件 | `frpctl ls` |
| `status` | **`st`** / `s` | 查看指定端口的服务状态及最近日志 | `frpctl st 40090` |
| `logs` | **`f`** / `log` | 实时滚动查看指定端口的运行日志（按 `Ctrl+C` 退出） | `frpctl f 40090` |
| `doctor` | **`dr`** / `check` | 一键体检：检查权限、配置文件、服务状态、`frps` 连通性、镜像可用性 | `frpctl dr` |
| `self-update` | **`su`** | 从 GitHub 拉取最新版本的 `frpctl` 脚本自身 | `frpctl su` |
| `uninstall` | **`rm`** / `del` | 卸载指定端口实例（若是 WebSSH 会一并清理本地 `ttyd` 服务） | `frpctl rm 40090` |
| `help` | **`h`** | 查看命令帮助说明 | `frpctl h` |

### 2. 参数选项速查

| 短参数 | 长参数（Linux / Windows） | 说明 |
|---|---|---|
| **`-p`** | `--port` / `-RemotePort` | 远程端口号（也可省略 `-p`，直接作为子命令后的第二个参数，如 `frpctl i 40090`） |
| **`-r`** | `--remark` / `-Remark` | 节点备注名称（支持中文，会显示在 `frps` Dashboard 中） |
| **`-t`** | `--protocol` / `-Protocol` | 穿透类型：`webssh`（网页终端+文件管理）/ `rdp`（远程桌面）/ `ssh` / `web` |
| **`-l`** | `--local-port` / `-LocalPort` | 本地端口（`-t webssh` 时无需填写，自动计算分配本机回环端口） |
| **`-a`** | `--auth` / `-WebAuth` | WebSSH 网页登录凭据，格式为 `用户名:密码`（如 `-a admin:ChangeMe123`） |
| — | `--server` / `-ServerAddr` | 临时覆盖或设置 `frps` 服务端地址 |
| — | `--server-port` / `-ServerPort` | 临时覆盖或设置 `frps` 服务端端口（默认 `49000`） |
| — | `--token` / `-AuthToken` | 临时覆盖或设置 `frps` 认证 Token |

---

## 第四部分：WebSSH 网页终端与右侧文件管理器使用指南

在浏览器访问 `https://<你的服务端域名>:<端口号>`（或直连 `http://<服务端IP>:<端口号>`），输入设置的账号密码即可进入终端。

### 1. 打开与收起右侧文件管理器
- 页面**右下角常驻蓝底黄色文件夹圆形按钮**。
- **点击按钮展开**：左侧终端区域会自动缩窄为 70% 宽度并重新计算终端列数（文字不会遮挡），右侧滑出 30% 宽度的文件管理面板。
- **再次点击按钮收起**：右侧面板隐藏，左侧终端恢复 100% 全屏宽度。

### 2. 目录浏览与快速跳转
1. **默认起始目录**：
   - Linux / macOS 客户端默认打开 `/usr/local/frp/`
   - Windows 客户端默认打开 `C:\Program Files\frp\`
2. **返回上级与切换磁盘**：
   - 点击列表第一行的 **`..`** 即可返回上一级目录。
   - 在 Windows 客户端下，退到盘符根目录（如 `C:\`）后再次点击 **`..`**，会列出本机所有磁盘驱动器（`C:\`、`D:\` 等），点击即可跨盘浏览。
3. **任意路径跳转与新建文件夹**：
   - 点击顶部中间显示的**当前路径文字**，可输入任意绝对路径直接跳转。
   - 点击顶部左上角的 **菜单图标**，可执行：**刷新当前目录**、**回到默认目录**、**手动输入路径...**、**新建文件夹...**。

### 3. 文件上传与下载
1. **下载文件到本地**：在右侧文件列表中，**直接点击任意文件行**，浏览器即刻开始下载该文件。
2. **上传文件到远程机器**：
   - **按钮上传**：点击右侧面板右上角的 **上传图标**，选择一个或多个本地文件上传至当前目录。
   - **拖拽上传**：直接从本地桌面或资源管理器把文件（支持多选）**拖进右侧文件面板**松开鼠标即可上传。

---

## 第五部分：关键文件路径清单

| 平台 | 文件/目录路径 | 用途说明 |
|---|---|---|
| **Linux / macOS** | `/usr/local/sbin/frpctl`、`/usr/local/bin/frpctl` | `frpctl` 主脚本命令入口 |
| **Linux / macOS** | `/etc/frpctl/frpctl.conf`（macOS 为 `/usr/local/etc/frpctl/frpctl.conf`） | 客户端全局配置文件（保存 `SERVER_ADDR` 与 `AUTH_TOKEN`） |
| **Linux / macOS** | `/usr/local/frp/frpc`、`/usr/local/frp/ttyd` | `frpc` 与 `ttyd` 二进制程序 |
| **Linux / macOS** | `/usr/local/frp/webssh_gw.py`、`drawer.js` | WebSSH 本地网关与右侧文件抽屉前端 |
| **Linux / macOS** | `/usr/local/frp/frpc_<端口>.toml` | 各端口实例的 FRP 配置文件 |
| **Linux** | `/etc/systemd/system/frpc_<端口>.service`、`ttyd_<端口>.service` | systemd 守护服务单元文件 |
| **Windows** | `C:\ProgramData\frpctl\frpctl.ps1`、`frpctl.cmd` | Windows 主脚本与全局命令入口（已加入系统 PATH） |
| **Windows** | `C:\ProgramData\frpctl\frpctl.conf` | Windows 客户端全局配置文件 |
| **Windows** | `C:\Program Files\frp\frpc.exe`、`ttyd.exe` | Windows 端 `frpc` 与 `ttyd` 可执行文件 |
| **Windows** | `C:\Program Files\frp\webssh_gw.ps1`、`drawer.js` | Windows 端 WebSSH 网关与右侧文件抽屉前端 |
| **Windows** | `C:\Program Files\frp\frpc_<端口>.toml` | 各端口实例的 FRP 配置文件 |
| **Windows** | `C:\Program Files\frp\FRPService_<端口>.xml`、`TTYDService_<端口>.xml` | WinSW Windows 系统服务配置文件 |

---

## 开源许可 (License)

本项目基于 [MIT License](LICENSE) 开源。
