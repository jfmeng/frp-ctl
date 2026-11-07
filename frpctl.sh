#!/usr/bin/env bash
# =============================================================
# frpctl - 跨平台 FRP 客户端多实例管理与 WebSSH 运维工具（Linux / macOS 版）
#
# 子命令：config / install / update / passwd / uninstall / list / status / logs / doctor / self-update
#
# 外部配置文件路径：
#   Linux : /etc/frpctl/frpctl.conf
#   macOS : /usr/local/etc/frpctl/frpctl.conf
#
# 用法示例：
#   sudo frpctl config --server frp.example.com --server-port 49000 --token MySecretToken
#   sudo frpctl install   --port 40005 --remark 服务器 --protocol ssh --local-port 22
#   sudo frpctl install   --port 40090 --remark 网页终端 --protocol webssh --auth admin:ChangeMe123
#   sudo frpctl update    --port 40005
#   sudo frpctl uninstall --port 40005
#   sudo frpctl list
#   sudo frpctl status    --port 40005
#   sudo frpctl logs      --port 40005
#   sudo frpctl doctor
#   sudo frpctl self-update
# =============================================================
set -euo pipefail

# ---------- 默认值（可被 frpctl.conf 覆盖，再被命令行参数覆盖） ----------
DEFAULT_SERVER_ADDR="frp.example.com"
DEFAULT_SERVER_PORT=49000
DEFAULT_AUTH_TOKEN="CHANGE_ME_TOKEN"
DEFAULT_FRP_VERSION="latest"
DEFAULT_PROTOCOL="ssh"
DEFAULT_GH_MIRRORS=(
    "https://ghfast.top/https://github.com"
    "https://ghproxy.net/https://github.com"
    "https://github.com"
)

SELF_UPDATE_REPO="${FRPCTL_REPO:-jfmeng/frp-ctl}"
SELF_UPDATE_BRANCH="${FRPCTL_BRANCH:-main}"
# 可选：若将仓库 Fork 为私有仓库，可通过环境变量 GH_TOKEN 传入访问令牌；公开仓库留空即可
SELF_UPDATE_TOKEN="${GH_TOKEN:-}"

# ---------- 平台检测 ----------
OS=""
ARCH=""
INSTALL_DIR=""
SERVICE_DIR=""
CONF_DIR=""
SERVICE_KIND=""   # systemd / launchd

detect_platform() {
    case "$(uname -s)" in
        Linux)
            OS="linux"
            INSTALL_DIR="/usr/local/frp"
            SERVICE_DIR="/etc/systemd/system"
            CONF_DIR="/etc/frpctl"
            SERVICE_KIND="systemd"
            ;;
        Darwin)
            OS="darwin"
            INSTALL_DIR="/usr/local/frp"
            SERVICE_DIR="/Library/LaunchDaemons"
            CONF_DIR="/usr/local/etc/frpctl"
            SERVICE_KIND="launchd"
            ;;
        *) echo "[X] 不支持的系统: $(uname -s)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7)  ARCH="arm" ;;
        i386|i686)     ARCH="386" ;;
        *) echo "[X] 不支持的架构: $(uname -m)" >&2; exit 1 ;;
    esac
}

# ---------- 读取与保存 conf ----------
SERVER_ADDR="$DEFAULT_SERVER_ADDR"
SERVER_PORT="$DEFAULT_SERVER_PORT"
AUTH_TOKEN="$DEFAULT_AUTH_TOKEN"
FRP_VERSION="$DEFAULT_FRP_VERSION"
DEFAULT_PROTO_FROM_CONF="$DEFAULT_PROTOCOL"
WEBSSH_AUTH=""
GH_MIRRORS=("${DEFAULT_GH_MIRRORS[@]}")

read_conf() {
    local conf="$CONF_DIR/frpctl.conf"
    [[ -f "$conf" ]] || return 0
    while IFS='=' read -r k v; do
        [[ -z "$k" || "$k" =~ ^# ]] && continue
        k=$(echo "$k" | tr -d '[:space:]')
        v=$(echo "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "$v" ]] && continue
        case "$k" in
            SERVER_ADDR)      SERVER_ADDR="$v" ;;
            SERVER_PORT)      SERVER_PORT="$v" ;;
            AUTH_TOKEN)       AUTH_TOKEN="$v" ;;
            FRP_VERSION)      FRP_VERSION="${v:-latest}" ;;
            DEFAULT_PROTOCOL) DEFAULT_PROTO_FROM_CONF="$v" ;;
            WEBSSH_AUTH)      WEBSSH_AUTH="$v" ;;
            GH_MIRRORS)       IFS=',' read -ra GH_MIRRORS <<< "$v" ;;
        esac
    done < "$conf"
}

save_conf() {
    mkdir -p "$CONF_DIR"
    local conf="$CONF_DIR/frpctl.conf"
    local mirrors_str
    mirrors_str=$(IFS=','; echo "${GH_MIRRORS[*]}")
    cat > "$conf" <<EOF
# frpctl 客户端全局配置文件
# 路径: $conf

SERVER_ADDR=$SERVER_ADDR
SERVER_PORT=$SERVER_PORT
AUTH_TOKEN=$AUTH_TOKEN
FRP_VERSION=$FRP_VERSION
GH_MIRRORS=$mirrors_str
DEFAULT_PROTOCOL=$DEFAULT_PROTO_FROM_CONF
WEBSSH_AUTH=$WEBSSH_AUTH
EOF
    chmod 600 "$conf"
    echo "[√] 全局配置已保存至: $conf (权限 600)"
}

# ---------- 通用工具 ----------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[X] 此操作需要 root 权限，请使用 sudo" >&2
        exit 1
    fi
}

ensure_deps() {
    local missing=()
    for c in curl tar python3; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [[ ${#missing[@]} -eq 0 ]] && return
    echo "[*] 安装依赖: ${missing[*]}"
    if   command -v apt-get >/dev/null; then apt-get update && apt-get install -y "${missing[@]}"
    elif command -v yum     >/dev/null; then yum install -y "${missing[@]}"
    elif command -v dnf     >/dev/null; then dnf install -y "${missing[@]}"
    elif command -v apk     >/dev/null; then apk add --no-cache "${missing[@]}"
    elif command -v brew    >/dev/null; then sudo -u "$(stat -f '%Su' /usr/local/Homebrew 2>/dev/null || echo "$SUDO_USER")" brew install "${missing[@]}"
    else echo "[!] 请手动安装: ${missing[*]}"; fi
}

download_with_mirrors() {
    local rel="$1" out="$2"
    for m in "${GH_MIRRORS[@]}"; do
        m="${m%/}"
        local url="${m}/${rel}"
        echo "  ↓ 尝试 $url"
        if curl -fsSL --connect-timeout 10 --retry 1 -o "$out" "$url"; then
            return 0
        fi
        echo "    失败，换下一个镜像"
    done
    return 1
}

get_latest_tag_via_mirrors() {
    local repo="$1" fallback="$2"
    local html tag=""
    for m in "${GH_MIRRORS[@]}"; do
        m="${m%/}"
        html=$(curl -fsSL --connect-timeout 8 --max-time 12 "${m}/${repo}/releases/latest" 2>/dev/null || true)
        if [[ -n "$html" ]]; then
            tag=$(printf '%s' "$html" | grep -oE "releases/tag/v?[0-9]+\.[0-9]+\.[0-9]+" | head -1 | sed -E 's|releases/tag/v?||' || true)
            if [[ -n "$tag" ]]; then
                echo "$tag"
                return 0
            fi
        fi
    done
    echo "$fallback"
}

get_latest_frp_version() {
    get_latest_tag_via_mirrors "fatedier/frp" "0.68.1"
}

get_latest_ttyd_version() {
    get_latest_tag_via_mirrors "tsl0922/ttyd" "1.7.7"
}

# 生成哪吒风格右侧文件管理抽屉前端与本地网关脚本
write_webssh_assets() {
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/drawer.js" <<'EOF_DRAWER_JS'
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
  var sep = '/';
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
        sep = data.sep || '/';
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
        var p = prompt('请输入要跳转的目录路径:', currentCwd || '/');
        if (p !== null && p.trim() !== '') loadDir(p.trim());
      }
      if (m === 'mkdir') {
        var name = prompt('请输入新建文件夹名称:');
        if (name && name.trim()) {
          fetch('/__fm__/mkdir?dir=' + encodeURIComponent(currentCwd) + '&name=' + encodeURIComponent(name.trim()), { method: 'POST', credentials: 'same-origin' })
            .then(function(){ loadDir(currentCwd); });
        }
      }
      return;
    }
    menu.style.display = 'none';
  });

  document.getElementById('fm-cwd').onclick = function(){
    var p = prompt('跳转到目录路径:', currentCwd || '/');
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
EOF_DRAWER_JS

    cat > "$INSTALL_DIR/webssh_gw.py" <<'EOF_WEBSSH_GW_PY'
#!/usr/bin/env python3
import argparse
import asyncio
import base64
import gzip
import json
import os
import signal
import subprocess
import sys
import urllib.parse
import urllib.request

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('-p', '--port', type=int, required=True)
    p.add_argument('-c', '--credential', type=str, required=True)
    p.add_argument('--ttyd', type=str, required=True)
    p.add_argument('--root', type=str, default='/usr/local/frp')
    p.add_argument('shell', nargs=argparse.REMAINDER)
    return p.parse_args()

def check_auth(headers, expected_b64):
    auth = headers.get('authorization', '')
    if not auth.lower().startswith('basic '):
        return False
    return auth[6:].strip() == expected_b64

async def send_json(writer, status, obj):
    body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
    hdr = (
        f"HTTP/1.1 {status}\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n"
    ).encode('utf-8')
    writer.write(hdr + body)
    await writer.drain()

async def pipe_stream(r, w):
    try:
        while True:
            data = await r.read(65536)
            if not data:
                break
            w.write(data)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass

async def handle_client(reader, writer, cfg):
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = await reader.read(8192)
            if not chunk:
                writer.close()
                return
            buf += chunk
            if len(buf) > 65536:
                writer.close()
                return

        hdr_end = buf.index(b"\r\n\r\n") + 4
        hdr_bytes = buf[:hdr_end]
        rest = buf[hdr_end:]

        lines = hdr_bytes.decode('latin-1', errors='replace').split('\r\n')
        req_line = lines[0].split(' ')
        if len(req_line) < 2:
            writer.close()
            return
        method, raw_target = req_line[0], req_line[1]
        headers = {}
        for line in lines[1:]:
            if ':' in line:
                k, v = line.split(':', 1)
                headers[k.strip().lower()] = v.strip()

        parsed = urllib.parse.urlsplit(raw_target)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if (path.startswith('/__fm__/') or path in ('/', '/index.html')) and not check_auth(headers, cfg['auth_b64']):
            resp = (
                "HTTP/1.1 401 Unauthorized\r\n"
                'WWW-Authenticate: Basic realm="WebSSH"\r\n'
                "Content-Length: 0\r\n"
                "Connection: close\r\n\r\n"
            ).encode('utf-8')
            writer.write(resp)
            await writer.drain()
            writer.close()
            return

        if path == '/__fm__/drawer.js':
            js_path = os.path.join(cfg['install_dir'], 'drawer.js')
            with open(js_path, 'rb') as f:
                data = f.read()
            hdr = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/javascript; charset=utf-8\r\n"
                f"Content-Length: {len(data)}\r\n"
                "Cache-Control: no-store\r\n"
                "Connection: close\r\n\r\n"
            ).encode('utf-8')
            writer.write(hdr + data)
            await writer.drain()
            writer.close()
            return

        if path == '/__fm__/list':
            req_path = qs.get('path', [''])[0].strip()
            target = os.path.abspath(req_path if req_path else cfg['root'])
            if not os.path.exists(target):
                target = cfg['root']
            parent = os.path.dirname(target)
            items = []
            try:
                with os.scandir(target) as it:
                    for entry in it:
                        try:
                            is_d = entry.is_dir(follow_symlinks=True)
                            st = entry.stat(follow_symlinks=True)
                            items.append({
                                'name': entry.name,
                                'is_dir': is_d,
                                'size': 0 if is_d else st.st_size
                            })
                        except Exception:
                            items.append({'name': entry.name, 'is_dir': False, 'size': 0})
                items.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
                await send_json(writer, '200 OK', {'cwd': target, 'parent': parent, 'sep': os.sep, 'items': items})
            except Exception as e:
                await send_json(writer, '200 OK', {'error': str(e), 'cwd': target, 'parent': parent, 'sep': os.sep, 'items': []})
            writer.close()
            return

        if path == '/__fm__/download':
            file_path = qs.get('path', [''])[0]
            if not file_path or not os.path.isfile(file_path):
                await send_json(writer, '404 Not Found', {'error': 'File not found'})
                writer.close()
                return
            fsize = os.path.getsize(file_path)
            fname = urllib.parse.quote(os.path.basename(file_path))
            hdr = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/octet-stream\r\n"
                f"Content-Length: {fsize}\r\n"
                f"Content-Disposition: attachment; filename*=UTF-8''{fname}\r\n"
                "Connection: close\r\n\r\n"
            ).encode('utf-8')
            writer.write(hdr)
            await writer.drain()
            with open(file_path, 'rb') as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    writer.write(chunk)
                    await writer.drain()
            writer.close()
            return

        if path == '/__fm__/upload' and method.upper() == 'POST':
            target_dir = qs.get('dir', [cfg['root']])[0] or cfg['root']
            fname = os.path.basename(qs.get('name', ['upload.bin'])[0])
            dest = os.path.join(target_dir, fname)
            clen = int(headers.get('content-length', '0'))
            rem = clen
            try:
                with open(dest, 'wb') as f:
                    if rest:
                        take = rest[:rem]
                        f.write(take)
                        rem -= len(take)
                    while rem > 0:
                        chunk = await reader.read(min(65536, rem))
                        if not chunk:
                            break
                        f.write(chunk)
                        rem -= len(chunk)
                await send_json(writer, '200 OK', {'ok': True, 'path': dest})
            except Exception as e:
                await send_json(writer, '200 OK', {'error': str(e)})
            writer.close()
            return

        if path == '/__fm__/mkdir' and method.upper() == 'POST':
            target_dir = qs.get('dir', [cfg['root']])[0] or cfg['root']
            fname = os.path.basename(qs.get('name', ['NewFolder'])[0])
            os.makedirs(os.path.join(target_dir, fname), exist_ok=True)
            await send_json(writer, '200 OK', {'ok': True})
            writer.close()
            return

        if method.upper() == 'GET' and path in ('/', '/index.html') and headers.get('upgrade', '').lower() != 'websocket':
            raw = b''
            for _ in range(10):
                try:
                    req = urllib.request.Request(
                        f"http://127.0.0.1:{cfg['ttyd_port']}/",
                        headers={'Accept-Encoding': 'gzip', 'Authorization': f"Basic {cfg['auth_b64']}"}
                    )
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        raw = resp.read()
                        if resp.headers.get('Content-Encoding', '').lower() == 'gzip' or raw[:2] == b'\x1f\x8b':
                            raw = gzip.decompress(raw)
                    break
                except Exception:
                    await asyncio.sleep(0.2)
            inject = b'<script src="/__fm__/drawer.js"></script>'
            if b'</body>' in raw:
                raw = raw.replace(b'</body>', inject + b'</body>', 1)
            else:
                raw = raw + inject
            hdr = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/html; charset=utf-8\r\n"
                f"Content-Length: {len(raw)}\r\n"
                "Cache-Control: no-store\r\n"
                "Connection: close\r\n\r\n"
            ).encode('utf-8')
            writer.write(hdr + raw)
            await writer.drain()
            writer.close()
            return

        up_r, up_w = await asyncio.open_connection('127.0.0.1', cfg['ttyd_port'])
        up_w.write(hdr_bytes + rest)
        await up_w.drain()
        await asyncio.gather(pipe_stream(reader, up_w), pipe_stream(up_r, writer))
    except Exception:
        try:
            writer.close()
        except Exception:
            pass

async def main():
    args = parse_args()
    shell_cmd = [s for s in args.shell if s != '--']
    if not shell_cmd:
        shell_cmd = ['/bin/bash', '-l'] if os.path.exists('/bin/bash') else ['/bin/sh']

    ttyd_port = args.port + 10000
    cmd = [args.ttyd, '-W', '-i', '127.0.0.1', '-p', str(ttyd_port), '-c', args.credential] + shell_cmd
    proc = subprocess.Popen(cmd)

    def cleanup(*_):
        try:
            proc.terminate()
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    cfg = {
        'port': args.port,
        'ttyd_port': ttyd_port,
        'auth_b64': base64.b64encode(args.credential.encode('utf-8')).decode('ascii'),
        'root': args.root if os.path.isdir(args.root) else '/',
        'install_dir': os.path.dirname(os.path.abspath(__file__))
    }

    srv = await asyncio.start_server(lambda r, w: handle_client(r, w, cfg), '127.0.0.1', args.port)
    async with srv:
        await srv.serve_forever()

if __name__ == '__main__':
    asyncio.run(main())
EOF_WEBSSH_GW_PY
    chmod 755 "$INSTALL_DIR/webssh_gw.py"
}

# 安装并配置本地 ttyd + 文件管理抽屉守护服务（仅监听 127.0.0.1:$LOCAL_PORT，直接拉起系统 Shell）
setup_ttyd_service() {
    local ttyd_bin="$INSTALL_DIR/ttyd"
    if [[ ! -x "$ttyd_bin" ]]; then
        if [[ "$OS" == "darwin" ]]; then
            echo "[*] macOS 环境通过 brew 安装 ttyd..."
            command -v ttyd >/dev/null 2>&1 || brew install ttyd
            ttyd_bin="$(command -v ttyd)"
        else
            local ttyd_arch
            case "$ARCH" in
                amd64) ttyd_arch="x86_64" ;;
                arm64) ttyd_arch="aarch64" ;;
                arm)   ttyd_arch="armhf" ;;
                386)   ttyd_arch="i686" ;;
                *) echo "[X] ttyd 暂不支持架构: $ARCH" >&2; exit 1 ;;
            esac
            local tver
            tver=$(get_latest_ttyd_version)
            tver="${tver:-1.7.7}"
            echo "[*] 下载 ttyd ($tver, ttyd.${ttyd_arch})..."
            if ! download_with_mirrors "tsl0922/ttyd/releases/download/${tver}/ttyd.${ttyd_arch}" "$ttyd_bin"; then
                echo "[X] ttyd 下载失败：所有镜像不可达" >&2
                exit 1
            fi
            chmod 755 "$ttyd_bin"
        fi
    fi

    write_webssh_assets

    local ttyd_svc="ttyd_${REMOTE_PORT}"
    local shell_cmd="/bin/bash -l"
    [[ -x /bin/bash ]] || shell_cmd="/bin/sh"
    local py_bin
    py_bin="$(command -v python3 || echo /usr/bin/python3)"

    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        cat > "$SERVICE_DIR/${ttyd_svc}.service" <<EOF
[Unit]
Description=ttyd WebSSH & FileDrawer for FRP (Remark: $REMARK, Port: $REMOTE_PORT)
After=network.target

[Service]
Type=simple
WorkingDirectory=/root
ExecStart=$py_bin $INSTALL_DIR/webssh_gw.py -p $LOCAL_PORT -c $WEBSSH_AUTH --ttyd $ttyd_bin --root $INSTALL_DIR -- $shell_cmd
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$ttyd_svc" >/dev/null 2>&1 || true
        systemctl restart "$ttyd_svc"
    else
        local tplist="$SERVICE_DIR/com.frpctl.${ttyd_svc}.plist"
        cat > "$tplist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.frpctl.${ttyd_svc}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$py_bin</string>
        <string>$INSTALL_DIR/webssh_gw.py</string>
        <string>-p</string><string>$LOCAL_PORT</string>
        <string>-c</string><string>$WEBSSH_AUTH</string>
        <string>--ttyd</string><string>$ttyd_bin</string>
        <string>--root</string><string>$INSTALL_DIR</string>
        <string>--</string>
        <string>/bin/bash</string><string>-l</string>
    </array>
    <key>KeepAlive</key><true/>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
        launchctl unload "$tplist" >/dev/null 2>&1 || true
        launchctl load -w "$tplist"
    fi
}

# ---------- 全局配置 ----------
do_config() {
    require_root
    echo "--- [配置 frpctl 全局服务端参数] ---"
    echo "配置文件路径: $CONF_DIR/frpctl.conf"

    if [[ -z "${CLI_SERVER_ADDR:-}" ]]; then
        read -r -p "请输入 frps 服务端地址 (当前: $SERVER_ADDR): " in_addr
        [[ -n "$in_addr" ]] && SERVER_ADDR="$in_addr"
    else
        SERVER_ADDR="$CLI_SERVER_ADDR"
    fi

    if [[ -z "${CLI_SERVER_PORT:-}" ]]; then
        read -r -p "请输入 frps 服务端端口 (当前: $SERVER_PORT): " in_port
        [[ -n "$in_port" ]] && SERVER_PORT="$in_port"
    else
        SERVER_PORT="$CLI_SERVER_PORT"
    fi

    if [[ -z "${CLI_AUTH_TOKEN:-}" ]]; then
        read -r -p "请输入 frps 认证 Token (当前: $AUTH_TOKEN): " in_tok
        [[ -n "$in_tok" ]] && AUTH_TOKEN="$in_tok"
    else
        AUTH_TOKEN="$CLI_AUTH_TOKEN"
    fi

    save_conf
}

ensure_server_configured() {
    local need_save=0
    if [[ -z "$SERVER_ADDR" || "$SERVER_ADDR" == "frp.example.com" ]]; then
        echo "[!] 检测到尚未配置 frps 服务端地址（当前为示例值 frp.example.com）"
        while [[ -z "$SERVER_ADDR" || "$SERVER_ADDR" == "frp.example.com" ]]; do
            read -r -p "请输入你的 frps 服务端域名或公网 IP: " SERVER_ADDR
        done
        need_save=1
    fi
    if [[ -z "$AUTH_TOKEN" || "$AUTH_TOKEN" == "CHANGE_ME_TOKEN" ]]; then
        echo "[!] 检测到尚未配置 frps 认证 Token（当前为示例值 CHANGE_ME_TOKEN）"
        while [[ -z "$AUTH_TOKEN" || "$AUTH_TOKEN" == "CHANGE_ME_TOKEN" ]]; do
            read -r -p "请输入你的 frps 认证 Token (auth.token): " AUTH_TOKEN
        done
        need_save=1
    fi
    if [[ $need_save -eq 1 ]]; then
        read -r -p "请输入 frps 服务端连接端口 (默认 $SERVER_PORT): " in_port
        [[ -n "$in_port" ]] && SERVER_PORT="$in_port"
        save_conf
    fi
}

# ---------- 安装 ----------
do_install() {
    require_root
    [[ -z "${REMOTE_PORT:-}" ]] && { echo "[X] 必须指定远程端口，例如: sudo frpctl i 40005" >&2; exit 1; }

    ensure_server_configured

    # 交互输入
    if [[ -z "${REMARK:-}" ]]; then
        read -r -p "请输入该节点备注 (例如: 服务器, 家里NAS): " REMARK
        REMARK="${REMARK:-未命名}"
    fi
    SAFE_REMARK=$(printf '%s' "$REMARK" | LC_ALL=C sed 's/[[:space:]\/\\:*?"<>|[\]=]/_/g')

    if [[ -z "${PROTOCOL:-}" ]]; then
        echo "请选择协议:"
        echo "  [1] ssh    (默认 22)"
        echo "  [2] rdp    (默认 3389，自动开启 TCP+UDP)"
        echo "  [3] web    (默认 80)"
        echo "  [4] webssh (内置 ttyd 网页终端 + 右侧文件管理器，无视本机 SSH 端口改动)"
        echo "  [5] custom"
        read -r -p "请选择 [1-5] (默认 ${DEFAULT_PROTO_FROM_CONF}): " c
        case "$c" in
            1) PROTOCOL="ssh" ;;
            2) PROTOCOL="rdp" ;;
            3) PROTOCOL="web" ;;
            4) PROTOCOL="webssh" ;;
            5) read -r -p "请输入自定义协议名: " PROTOCOL ;;
            *) PROTOCOL="$DEFAULT_PROTO_FROM_CONF" ;;
        esac
    fi
    SAFE_PROTO=$(echo "$PROTOCOL" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
    [[ -z "$SAFE_PROTO" ]] && SAFE_PROTO="tcp"

    if [[ "$SAFE_PROTO" == "webssh" ]]; then
        if [[ -z "${LOCAL_PORT:-}" || "${LOCAL_PORT:-0}" -le 0 ]]; then
            LOCAL_PORT=$((17681 + (REMOTE_PORT % 1000)))
            echo "[*] WebSSH 本地回环端口自动设为: 127.0.0.1:${LOCAL_PORT}"
        fi
        while [[ -z "${WEBSSH_AUTH:-}" ]]; do
            read -r -p "请设置 WebSSH 登录账号密码 (格式 用户名:密码，例如 admin:123456): " WEBSSH_AUTH
        done
        [[ "$WEBSSH_AUTH" == *:* ]] || WEBSSH_AUTH="admin:${WEBSSH_AUTH}"
    elif [[ -z "${LOCAL_PORT:-}" || "${LOCAL_PORT:-0}" -le 0 ]]; then
        case "$SAFE_PROTO" in
            ssh) DEF_LOCAL=22 ;;
            rdp) DEF_LOCAL=3389 ;;
            web) DEF_LOCAL=80 ;;
            *)   DEF_LOCAL=22 ;;
        esac
        read -r -p "请输入本地端口 (默认 $DEF_LOCAL): " p
        LOCAL_PORT="${p:-$DEF_LOCAL}"
    fi

    ensure_deps

    # 取版本
    local ver tag asset
    if [[ "$FRP_VERSION" == "latest" || -z "$FRP_VERSION" ]]; then
        echo "[*] 查询 frp 最新版本..."
        ver=$(get_latest_frp_version)
        [[ -z "$ver" ]] && { echo "[X] 获取版本失败" >&2; exit 1; }
    else
        ver="${FRP_VERSION#v}"
    fi
    tag="v$ver"
    asset="frp_${ver}_${OS}_${ARCH}.tar.gz"
    echo "[*] FRP 版本: $ver  ($OS/$ARCH)"

    mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/logs"
    local tmp="/tmp/frp_${RANDOM}.tar.gz"
    if ! download_with_mirrors "fatedier/frp/releases/download/$tag/$asset" "$tmp"; then
        echo "[X] frp 下载失败：所有镜像不可达" >&2
        exit 1
    fi
    tar -xzf "$tmp" -C "$INSTALL_DIR" --strip-components=1
    rm -f "$tmp"
    chmod 755 "$INSTALL_DIR/frpc"

    # 如为 webssh 模式，先安装并启动本地 ttyd 守护服务
    if [[ "$SAFE_PROTO" == "webssh" ]]; then
        setup_ttyd_service
    fi

    # 写 toml（webssh 模式下，若公网端口在 40000..49999，自动将 frpc 隧道端口设为 +10000 供服务端 Nginx HTTPS 反代）
    local cfg="$INSTALL_DIR/frpc_${REMOTE_PORT}.toml"
    local proxy_name="${SAFE_REMARK}_${SAFE_PROTO}_${REMOTE_PORT}"
    local client_name="${SAFE_REMARK}_${REMOTE_PORT}"
    local tunnel_port="$REMOTE_PORT"
    if [[ "$SAFE_PROTO" == "webssh" && "$REMOTE_PORT" -ge 40000 && "$REMOTE_PORT" -lt 50000 ]]; then
        tunnel_port=$((REMOTE_PORT + 10000))
    fi
    cat > "$cfg" <<EOF
[common]
server_addr = "$SERVER_ADDR"
server_port = $SERVER_PORT
token = "$AUTH_TOKEN"
user = "$client_name"
login_fail_exit = false
tcp_mux = true
heartbeat_interval = 30
heartbeat_timeout = 90

[$proxy_name]
type = "tcp"
local_ip = "127.0.0.1"
local_port = $LOCAL_PORT
remote_port = $tunnel_port
health_check_type = "tcp"
health_check_timeout_s = 3
health_check_max_failed = 3
health_check_interval_s = 10
EOF
    if [[ "$SAFE_PROTO" == "rdp" ]]; then
        cat >> "$cfg" <<EOF

[${proxy_name}_udp]
type = "udp"
local_ip = "127.0.0.1"
local_port = $LOCAL_PORT
remote_port = $REMOTE_PORT
EOF
    fi

    # 创建服务
    local svc="frpc_${REMOTE_PORT}"
    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        cat > "$SERVICE_DIR/${svc}.service" <<EOF
[Unit]
Description=FRP Client (Remark: $REMARK, Port: $REMOTE_PORT)
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/frpc -c $cfg
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$svc" >/dev/null 2>&1 || true
        systemctl restart "$svc"
    else
        local plist="$SERVICE_DIR/com.frpctl.${svc}.plist"
        cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.frpctl.${svc}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/frpc</string>
        <string>-c</string><string>$cfg</string>
    </array>
    <key>KeepAlive</key><true/>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$INSTALL_DIR/logs/${svc}.log</string>
    <key>StandardErrorPath</key><string>$INSTALL_DIR/logs/${svc}.err</string>
</dict>
</plist>
EOF
        launchctl unload "$plist" >/dev/null 2>&1 || true
        launchctl load -w "$plist"
    fi

    echo ""
    echo "=========== 安装成功 ==========="
    echo "  备注           : $REMARK"
    echo "  协议/本地端口  : $SAFE_PROTO / $LOCAL_PORT"
    echo "  远程端口       : $REMOTE_PORT"
    echo "  Proxies 名     : $proxy_name"
    echo "  Clients 名     : $client_name"
    [[ "$SAFE_PROTO" == "rdp" ]] && echo "  UDP 加速       : ${proxy_name}_udp"
    if [[ "$SAFE_PROTO" == "webssh" ]]; then
        echo "  WebSSH 地址    : https://${SERVER_ADDR}:${REMOTE_PORT}  (内部隧道端口: ${tunnel_port})"
        echo "  WebSSH 账号    : ${WEBSSH_AUTH%%:*} (密码已设)"
    fi
    echo "  配置文件       : $cfg"
    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        echo "  服务管理       : systemctl status $svc"
        echo "  实时日志       : journalctl -u $svc -f"
    else
        echo "  服务管理       : launchctl list | grep $svc"
        echo "  实时日志       : tail -f $INSTALL_DIR/logs/${svc}.log"
    fi
    echo "================================"
}

# ---------- 卸载 ----------
do_uninstall() {
    require_root
    [[ -z "${REMOTE_PORT:-}" ]] && { echo "[X] 必须指定 --port" >&2; exit 1; }
    local svc="frpc_${REMOTE_PORT}"
    local ttyd_svc="ttyd_${REMOTE_PORT}"
    local cfg="$INSTALL_DIR/frpc_${REMOTE_PORT}.toml"

    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        systemctl stop "$svc" "$ttyd_svc" 2>/dev/null || true
        systemctl disable "$svc" "$ttyd_svc" 2>/dev/null || true
        rm -f "$SERVICE_DIR/${svc}.service" "$SERVICE_DIR/${ttyd_svc}.service"
        systemctl daemon-reload
    else
        local plist="$SERVICE_DIR/com.frpctl.${svc}.plist"
        local tplist="$SERVICE_DIR/com.frpctl.${ttyd_svc}.plist"
        launchctl unload "$plist" "$tplist" 2>/dev/null || true
        rm -f "$plist" "$tplist"
    fi
    rm -f "$cfg"

    if ! ls "$INSTALL_DIR"/frpc_*.toml >/dev/null 2>&1; then
        rm -rf "$INSTALL_DIR"
        echo "[√] 已删除最后一个实例，连同安装目录一起清理"
    else
        echo "[√] 端口 $REMOTE_PORT 实例已卸载（其他实例保留）"
    fi
}

# ---------- 就地平滑升级 ----------
do_update() {
    require_root
    [[ -z "${REMOTE_PORT:-}" ]] && { echo "[X] 必须指定端口，如: sudo frpctl up 40005" >&2; exit 1; }

    local svc="frpc_${REMOTE_PORT}"
    local frpc_bin="$INSTALL_DIR/frpc"
    local plist="$SERVICE_DIR/com.frpctl.${svc}.plist"

    # 若存在配套的 ttyd_<port> 服务，同步升级 WebSSH 右侧文件管理抽屉组件
    local ttyd_unit="/etc/systemd/system/ttyd_${REMOTE_PORT}.service"
    if [[ "$SERVICE_KIND" == "systemd" && -f "$ttyd_unit" ]]; then
        ensure_deps
        LOCAL_PORT=$(grep -oE '\-p [0-9]+' "$ttyd_unit" | head -1 | awk '{print $2}')
        WEBSSH_AUTH=$(grep -oE '\-c [^ ]+' "$ttyd_unit" | head -1 | awk '{print $2}' | tr -d '"')
        REMARK=$(grep -oE 'Remark: [^,]+' "$ttyd_unit" | head -1 | sed 's/Remark: //')
        if [[ -n "$LOCAL_PORT" && -n "$WEBSSH_AUTH" ]]; then
            echo "[*] 同步升级 WebSSH 右侧文件管理器组件 (ttyd_${REMOTE_PORT})..."
            setup_ttyd_service
            echo "[√] WebSSH 文件管理器组件已就绪"
        fi
    fi

    # ---- 就地升级：服务存在时只停服务→换二进制→启服务，不删服务 ----
    local svc_exists=0
    if [[ "$SERVICE_KIND" == "systemd" && -f "/etc/systemd/system/${svc}.service" ]]; then svc_exists=1; fi
    if [[ "$SERVICE_KIND" == "launchd" && -f "$plist" ]]; then svc_exists=1; fi

    if [[ $svc_exists -eq 1 && -x "$frpc_bin" ]]; then
        local ver
        if [[ "$FRP_VERSION" == "latest" || -z "$FRP_VERSION" ]]; then
            echo "[*] 查询 frp 最新版本..."
            ver=$(get_latest_frp_version)
            [[ -z "$ver" ]] && { echo "[X] 获取版本失败" >&2; exit 1; }
        else
            ver="${FRP_VERSION#v}"
        fi

        local cur_ver
        cur_ver=$("$frpc_bin" -v 2>/dev/null | head -1 || true)
        echo "[*] 当前版本: ${cur_ver:-未知} → 目标版本: $ver"
        if [[ "$cur_ver" == *"$ver"* ]]; then
            echo "[√] 已是最新版本，无需升级"
            return 0
        fi

        local tmp_dir asset
        tmp_dir=$(mktemp -d)
        asset="frp_${ver}_${OS}_${ARCH}.tar.gz"
        echo "[*] 下载 $asset..."
        if ! download_with_mirrors "fatedier/frp/releases/download/v${ver}/${asset}" "$tmp_dir/frp.tar.gz"; then
            echo "[X] 下载失败：所有镜像不可达" >&2; exit 1
        fi
        tar -xzf "$tmp_dir/frp.tar.gz" -C "$tmp_dir"
        local new_bin
        new_bin=$(find "$tmp_dir" -name frpc -type f | head -1)
        [[ -z "$new_bin" ]] && { echo "[X] 下载包中未找到 frpc" >&2; exit 1; }

        echo "[*] 停止服务 $svc..."
        if [[ "$SERVICE_KIND" == "systemd" ]]; then
            systemctl stop "$svc" || true
        else
            launchctl unload "$plist" 2>/dev/null || true
        fi

        cp -f "$frpc_bin" "${frpc_bin}.old"
        install -m 755 "$new_bin" "$frpc_bin"

        echo "[*] 启动服务 $svc..."
        if [[ "$SERVICE_KIND" == "systemd" ]]; then
            systemctl start "$svc"
            sleep 2
            if systemctl is-active --quiet "$svc"; then
                rm -f "${frpc_bin}.old"
                rm -rf "$tmp_dir"
                echo "[√] 升级完成: $ver（服务未重建）"
            else
                echo "[!] 新版启动失败，回滚旧版本..."
                systemctl stop "$svc" || true
                mv -f "${frpc_bin}.old" "$frpc_bin"
                systemctl start "$svc" || true
                rm -rf "$tmp_dir"
                echo "[X] 已回滚。用 frpctl f $REMOTE_PORT 查看日志" >&2
                exit 1
            fi
        else
            launchctl load "$plist"
            rm -f "${frpc_bin}.old"
            rm -rf "$tmp_dir"
            echo "[√] 升级完成: $ver"
        fi
        return 0
    fi

    # ---- 服务不存在才走完整卸载+重装 ----
    local cfg="$INSTALL_DIR/frpc_${REMOTE_PORT}.toml"
    if [[ -f "$cfg" && -z "${REMARK:-}" ]]; then
        local first_proxy
        first_proxy=$(grep -m1 -E '^\[[^c]' "$cfg" | tr -d '[]')
        if [[ "$first_proxy" =~ ^([^_]+)_([^_]+)_([0-9]+)$ ]]; then
            REMARK="${BASH_REMATCH[1]}"
            PROTOCOL="${BASH_REMATCH[2]}"
            LOCAL_PORT=$(grep -m1 '^local_port' "$cfg" | sed 's/[^0-9]//g')
            echo "[*] 复用旧配置: remark=$REMARK protocol=$PROTOCOL local=$LOCAL_PORT"
        fi
    fi
    do_uninstall
    do_install
}

# ---------- list ----------
do_list() {
    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        systemctl list-units --type=service --all 'frpc_*.service' --no-pager 2>/dev/null \
            | awk '/frpc_/' || true
    else
        launchctl list | awk '/com.frpctl/ {print}'
    fi
    if [[ -d "$INSTALL_DIR" ]]; then
        echo "--- 配置文件 ---"
        ls -1 "$INSTALL_DIR"/frpc_*.toml 2>/dev/null || echo "(无)"
    fi
}

# ---------- status ----------
do_status() {
    [[ -z "${REMOTE_PORT:-}" ]] && { echo "[X] 必须指定 --port" >&2; exit 1; }
    local svc="frpc_${REMOTE_PORT}"
    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        systemctl status "$svc" --no-pager
    else
        launchctl list | grep "com.frpctl.${svc}" || echo "服务未运行"
    fi
}

# ---------- logs ----------
do_logs() {
    [[ -z "${REMOTE_PORT:-}" ]] && { echo "[X] 必须指定 --port" >&2; exit 1; }
    local svc="frpc_${REMOTE_PORT}"
    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        journalctl -u "$svc" -f
    else
        tail -f "$INSTALL_DIR/logs/${svc}.log"
    fi
}

# ---------- self-update ----------
do_self_update() {
    require_root
    local target="/usr/local/sbin/frpctl"
    local tmp="${target}.new"
    local auth_args=()
    if [[ -n "$SELF_UPDATE_TOKEN" ]]; then
        auth_args=(-H "Authorization: token ${SELF_UPDATE_TOKEN}")
    fi
    for m in "${GH_MIRRORS[@]}"; do
        local raw="${m/https:\/\/github.com/https:\/\/raw.githubusercontent.com}"
        local url="${raw%/}/${SELF_UPDATE_REPO}/${SELF_UPDATE_BRANCH}/frpctl.sh?_=$(date +%s)"
        echo "  ↓ $url"
        if curl -fsSL --connect-timeout 15 "${auth_args[@]}" -o "$tmp" "$url"; then
            chmod +x "$tmp"
            mv "$tmp" "$target"
            ln -sf "$target" /usr/local/bin/frpctl 2>/dev/null || true
            echo "[√] frpctl 已更新"
            return
        fi
        rm -f "$tmp"
    done
    echo "[X] self-update 失败：所有镜像不可达" >&2
    exit 1
}

# ---------- 帮助 ----------
show_help() {
    cat <<'HELP'
frpctl - 跨平台 FRP 客户端多实例管理与 WebSSH 运维工具

用法: frpctl <命令> [端口] [选项]

命令（含简写别名）:
  config   | cfg| set      设置/更新全局 frps 服务端地址与认证 Token
  install  | i  | add      安装并启动新的端口穿透实例
  update   | up | u        就地平滑升级实例（保留原配置，不删系统服务）
  passwd   | pw | auth     修改已安装 WebSSH 实例的网页登录账号密码
  uninstall| rm | del      卸载指定端口实例
  list     | ls | l        列出所有已安装实例与状态
  status   | st | s        查看指定端口状态
  logs     | log| f        实时滚动查看日志
  doctor   | dr | check    一键体检诊断（权限/服务/连通性/镜像/版本）
  self-update | su         从云端升级 frpctl 自身
  help     | h             显示本帮助

选项（长短均可）:
  -p, --port <端口>        远程端口（也可直接作为第二个位置参数）
  -r, --remark <备注>      节点备注名
  -t, --protocol <协议>    ssh / rdp / web / webssh / 自定义
  -l, --local-port <端口>  本地端口（webssh 模式免填，自动分配本机回环端口）
  -a, --auth <账号:密码>   WebSSH 登录凭据（如 admin:ChangeMe123）
      --server <地址>      frps 服务端地址
      --server-port <端口> frps 服务端端口（默认 49000）
      --token <令牌>       frps 认证 Token
      --version <版本>     指定 frp 版本（默认 latest）

示例:
  sudo frpctl cfg --server frp.example.com --server-port 49000 --token MySecretToken
  sudo frpctl i 40006 -r 树莓派   -t ssh -l 22
  sudo frpctl i 40090 -r 云服务器 -t webssh -a admin:ChangeMe123
  sudo frpctl up 40006
  sudo frpctl ls
  sudo frpctl dr
HELP
}

# ---------- doctor ----------
do_doctor() {
    echo "--- [frpctl 体检] ---"

    echo ""
    echo "[1] 运行权限"
    if [[ $EUID -eq 0 ]]; then echo "  [OK] root"; else echo "  [!!] 非 root，install/update/uninstall 需要 sudo"; fi

    echo ""
    echo "[2] 平台与全局配置 ($CONF_DIR/frpctl.conf)"
    echo "  OS=$OS ARCH=$ARCH 服务类型=$SERVICE_KIND"
    if [[ -f "$CONF_DIR/frpctl.conf" ]]; then
        echo "  [OK] 已存在配置文件 (Server: $SERVER_ADDR:$SERVER_PORT)"
    else
        echo "  [i] 尚未创建配置文件，当前使用: $SERVER_ADDR:$SERVER_PORT（可执行 sudo frpctl config 配置）"
    fi

    echo ""
    echo "[3] 本机 frp 实例"
    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        local found=0
        for u in /etc/systemd/system/frpc_*.service; do
            [[ -e "$u" ]] || continue
            found=1
            local n; n=$(basename "$u" .service)
            printf "  %-16s %s\n" "$n" "$(systemctl is-active "$n" 2>/dev/null)"
        done
        [[ $found -eq 0 ]] && echo "  (无)"
    else
        launchctl list 2>/dev/null | awk '/com.frpctl/ {print "  "$3"  pid="$1}' || echo "  (无)"
    fi

    echo ""
    echo "[4] frps 服务端连通性 ($SERVER_ADDR:$SERVER_PORT)"
    if [[ "$SERVER_ADDR" == "frp.example.com" ]]; then
        echo "  [i] 服务端仍为示例地址 frp.example.com，请先执行 sudo frpctl config 配置"
    elif command -v nc >/dev/null 2>&1; then
        if nc -z -w5 "$SERVER_ADDR" "$SERVER_PORT" 2>/dev/null; then echo "  [OK] TCP 可达"; else echo "  [!!] TCP 不可达"; fi
    elif command -v timeout >/dev/null 2>&1; then
        if timeout 5 bash -c "echo > /dev/tcp/$SERVER_ADDR/$SERVER_PORT" 2>/dev/null; then echo "  [OK] TCP 可达"; else echo "  [!!] TCP 不可达"; fi
    else
        echo "  [?] 缺少 nc/timeout，跳过"
    fi

    echo ""
    echo "[5] GitHub 镜像可用性"
    for m in "${GH_MIRRORS[@]}"; do
        if curl -fsI --connect-timeout 8 "${m%/}/fatedier/frp/releases" >/dev/null 2>&1; then
            echo "  [OK] $m"
        else
            echo "  [X]  $m"
        fi
    done

    echo ""
    echo "[6] frpc 二进制"
    if [[ -x "$INSTALL_DIR/frpc" ]]; then
        echo "  [OK] $("$INSTALL_DIR/frpc" -v 2>/dev/null || echo '版本未知')"
    else
        echo "  [i] 未安装"
    fi

    echo ""
    echo "--- 体检完成 ---"
}

do_passwd() {
    require_root
    [[ -z "$REMOTE_PORT" ]] && read -rp "请输入要修改 WebSSH 账号密码的远程端口 (如 40090): " REMOTE_PORT
    [[ -z "$WEBSSH_AUTH" ]] && read -rp "请输入新的 WebSSH 登录账号:密码 (格式 用户名:密码，如 admin:123456): " WEBSSH_AUTH
    while [[ ! "$WEBSSH_AUTH" =~ ^[^:]+:.+$ ]]; do
        read -rp "格式不正确，请按 用户名:密码 格式输入: " WEBSSH_AUTH
    done

    local ttyd_svc="ttyd_${REMOTE_PORT}"
    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        local unit_file="$SERVICE_DIR/${ttyd_svc}.service"
        if [[ ! -f "$unit_file" ]]; then
            echo "未找到 WebSSH 服务配置: $unit_file" >&2; exit 1
        fi
        sed -i -E "s|-c [^ ]+ |-c ${WEBSSH_AUTH} |" "$unit_file"
        systemctl daemon-reload
        systemctl restart "$ttyd_svc"
        echo "[+] 已更新 $ttyd_svc 登录凭据并重启服务（新账号: ${WEBSSH_AUTH%%:*}）"
    else
        local plist="$SERVICE_DIR/com.frpctl.${ttyd_svc}.plist"
        if [[ ! -f "$plist" ]]; then
            echo "未找到 WebSSH 服务配置: $plist" >&2; exit 1
        fi
        sed -i.bak -E "/<string>-c<\/string>/{n;s|<string>.*</string>|<string>${WEBSSH_AUTH}</string>|;}" "$plist"
        rm -f "${plist}.bak"
        launchctl unload "$plist" >/dev/null 2>&1 || true
        launchctl load -w "$plist"
        echo "[+] 已更新 $ttyd_svc 登录凭据并重启服务（新账号: ${WEBSSH_AUTH%%:*}）"
    fi
}

# ---------- 参数解析 ----------
detect_platform
read_conf

ACTION="${1:-}"
shift || true
REMOTE_PORT=""
REMARK=""
PROTOCOL=""
LOCAL_PORT=""
CLI_SERVER_ADDR=""
CLI_SERVER_PORT=""
CLI_AUTH_TOKEN=""

if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    REMOTE_PORT="$1"; shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)        REMOTE_PORT="$2"; shift 2 ;;
        -r|--remark)      REMARK="$2"; shift 2 ;;
        -t|--protocol)    PROTOCOL="$2"; shift 2 ;;
        -l|--local-port)  LOCAL_PORT="$2"; shift 2 ;;
        -a|--auth)        WEBSSH_AUTH="$2"; shift 2 ;;
        --server)         SERVER_ADDR="$2"; CLI_SERVER_ADDR="$2"; shift 2 ;;
        --server-port)    SERVER_PORT="$2"; CLI_SERVER_PORT="$2"; shift 2 ;;
        --token)          AUTH_TOKEN="$2";  CLI_AUTH_TOKEN="$2";  shift 2 ;;
        --version)        FRP_VERSION="$2"; shift 2 ;;
        -h|--help)        show_help; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

case "$ACTION" in
    cfg|conf|set)       ACTION="config" ;;
    i|add|new)          ACTION="install" ;;
    up|u|upgrade)       ACTION="update" ;;
    rm|del|remove|un)   ACTION="uninstall" ;;
    ls|l)               ACTION="list" ;;
    st|s)               ACTION="status" ;;
    log|f)              ACTION="logs" ;;
    su|selfupdate)      ACTION="self-update" ;;
    pw|passwd|auth)     ACTION="passwd" ;;
    doc|check|dr)       ACTION="doctor" ;;
    h)                  ACTION="help" ;;
esac

case "$ACTION" in
    config)      do_config ;;
    install)     do_install ;;
    uninstall)   do_uninstall ;;
    update)      do_update ;;
    list)        do_list ;;
    status)      do_status ;;
    logs)        do_logs ;;
    passwd)      do_passwd ;;
    self-update) do_self_update ;;
    doctor)      do_doctor ;;
    ""|help|-h|--help) show_help ;;
    *) echo "未知子命令: $ACTION" >&2; show_help; exit 1 ;;
esac
