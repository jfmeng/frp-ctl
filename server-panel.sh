#!/usr/bin/env bash
# =============================================================
# frpctl - 服务端 Dashboard 远程销毁/管控插件一键安装脚本
#
# 功能：
#   1. 为原版 frps Dashboard (含 v0.7x 新版 Vue 面板 /#/clients 与 /#/proxies/tcp)
#      自动注入「💻终端」「⏸️封禁」「🗑️卸载端口」「☢️彻底自毁」操作按钮
#   2. 提供右下角「🛡️ 客户端管控 / 远程销毁」抽屉面板，支持查看在线/离线/已吊销节点及送达回执
#   3. 自动兼容 frps.toml 中的 INI ([common]) 与 TOML 两种语法格式，支持 HTTPS (443/自定义端口)
#   4. 对接 frps 原生 httpPlugins (Login / NewProxy / Ping)：
#      - 在线 WebSSH 节点：通过本地网关秒级主动触发卸载/自毁
#      - 在线 RDP/SSH 节点：在 ≤30 秒心跳或重连内触发被动自毁
#      - 关机/离线节点：加入持久化吊销队列，客户端下次开机联网即刻自动自毁
#
# 用法（在 frps 服务端 root 下执行）：
#   sudo bash server-panel.sh install
#   sudo bash server-panel.sh status
#   sudo bash server-panel.sh uninstall
# =============================================================
set -euo pipefail

FRP_DIR="${FRP_DIR:-/usr/local/frp}"
PLUGIN_HTTP_PORT="${PLUGIN_HTTP_PORT:-49500}"
INTERNAL_DASH_PORT="${INTERNAL_DASH_PORT:-49501}"
PANEL_PY="$FRP_DIR/frps_panel.py"
STATE_FILE="$FRP_DIR/frpctl_state.json"
SVC_FILE="/etc/systemd/system/frps-panel.service"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "❌ 请使用 root 或 sudo 运行此脚本" >&2
        exit 1
    fi
}

find_frps_conf() {
    for f in "$FRP_DIR/frps.toml" "$FRP_DIR/frps.ini" "/etc/frp/frps.toml" "/etc/frp/frps.ini"; do
        if [[ -f "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    local unit
    unit=$(systemctl cat frps 2>/dev/null | grep -oE '\-c [^ ]+' | head -1 | awk '{print $2}' || true)
    if [[ -n "$unit" && -f "$unit" ]]; then
        echo "$unit"
        return 0
    fi
    return 1
}

write_panel_py() {
    mkdir -p "$FRP_DIR"
    cat > "$PANEL_PY" <<'EOF_PANEL_PY'
#!/usr/bin/env python3
import argparse
import base64
import gzip
import http.client
import json
import os
import re
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_LOCK = threading.Lock()

PANEL_JS = r"""
(function(){
  if (window.__frpctlPanelLoaded) return;
  window.__frpctlPanelLoaded = true;

  var style = document.createElement('style');
  style.textContent = [
    '#fc-fab{position:fixed;right:24px;bottom:24px;height:44px;padding:0 18px;border-radius:22px;background:linear-gradient(135deg,#2563eb,#1d4ed8);color:#fff;box-shadow:0 6px 18px rgba(37,99,235,.45);display:flex;align-items:center;gap:8px;cursor:pointer;z-index:99999;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;font-size:14px;font-weight:600;user-select:none;transition:transform .15s}',
    '#fc-fab:hover{transform:translateY(-2px)}',
    '#fc-drawer{position:fixed;top:0;right:0;width:600px;max-width:96vw;height:100vh;background:#1e293b;color:#f1f5f9;z-index:100000;display:none;flex-direction:column;box-shadow:-6px 0 24px rgba(0,0,0,.45);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;font-size:13px;border-left:1px solid #334155}',
    '#fc-drawer *{box-sizing:border-box}',
    '#fc-head{height:56px;border-bottom:1px solid #334155;display:flex;align-items:center;justify-content:space-between;padding:0 18px;background:#0f172a}',
    '#fc-title{font-size:15px;font-weight:600;color:#f8fafc;display:flex;align-items:center;gap:8px}',
    '#fc-body{flex:1;overflow-y:auto;padding:14px 16px 80px 16px}',
    '.fc-card{border:1px solid #334155;border-radius:8px;padding:12px 14px;margin-bottom:10px;background:#0f172a;transition:border-color .15s}',
    '.fc-card:hover{border-color:#64748b}',
    '.fc-row1{display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;gap:8px;flex-wrap:wrap}',
    '.fc-name{font-size:14px;font-weight:600;color:#f8fafc;display:flex;align-items:center;gap:8px;flex-wrap:wrap}',
    '.fc-tag{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}',
    '.fc-tag-on{background:rgba(34,197,94,.2);color:#4ade80;border:1px solid rgba(34,197,94,.35)}',
    '.fc-tag-off{background:rgba(148,163,184,.15);color:#94a3b8;border:1px solid rgba(148,163,184,.3)}',
    '.fc-tag-rev{background:rgba(239,68,68,.2);color:#f87171;border:1px solid rgba(239,68,68,.4)}',
    '.fc-tag-proto{background:rgba(59,130,246,.2);color:#60a5fa;border:1px solid rgba(59,130,246,.35)}',
    '.fc-meta{font-size:12px;color:#94a3b8;margin-bottom:10px;display:flex;gap:14px;flex-wrap:wrap}',
    '.fc-actions{display:flex;gap:6px;flex-wrap:wrap}',
    '.fc-btn{border:1px solid #475569;background:#1e293b;color:#e2e8f0;border-radius:5px;padding:4px 9px;font-size:12px;cursor:pointer;display:inline-flex;align-items:center;gap:4px;transition:all .15s;line-height:1.4}',
    '.fc-btn:hover{border-color:#60a5fa;color:#fff;background:#2563eb}',
    '.fc-btn-term{border-color:#2563eb;background:rgba(37,99,235,.2);color:#60a5fa}',
    '.fc-btn-term:hover{background:#2563eb;color:#fff}',
    '.fc-btn-warn{border-color:#d97706;background:rgba(217,119,6,.18);color:#fbbf24}',
    '.fc-btn-warn:hover{background:#d97706;color:#fff}',
    '.fc-btn-danger{border-color:#dc2626;background:rgba(220,38,38,.18);color:#f87171}',
    '.fc-btn-danger:hover{background:#dc2626;color:#fff}',
    '.fc-btn-nuke{border-color:#dc2626;background:#dc2626;color:#fff;font-weight:600}',
    '.fc-btn-nuke:hover{background:#b91c1c;border-color:#b91c1c}',
    '.fc-inline-box{display:inline-flex;gap:5px;margin-left:10px;vertical-align:middle}',
    '#fc-toast{position:fixed;top:18px;right:22px;background:#0f172a;color:#f8fafc;border:1px solid #3b82f6;padding:11px 16px;border-radius:8px;font-size:13px;z-index:100005;display:none;box-shadow:0 6px 20px rgba(0,0,0,.45);max-width:460px}'
  ].join('\n');
  document.head.appendChild(style);

  var fab = document.createElement('div');
  fab.id = 'fc-fab';
  fab.innerHTML = '<span>🛡️ 客户端管控 / 远程销毁</span>';

  var drawer = document.createElement('div');
  drawer.id = 'fc-drawer';
  drawer.innerHTML = [
    '<div id="fc-head">',
    '  <div id="fc-title">🛡️ frpctl 客户端远程管控与自毁中心</div>',
    '  <div style="display:flex;gap:6px">',
    '    <button class="fc-btn" id="fc-refresh">🔄 刷新</button>',
    '    <button class="fc-btn" id="fc-clean-off" title="清理 frps 面板中的离线代理残留">🧹 清离线</button>',
    '    <button class="fc-btn" id="fc-close">✕ 关闭</button>',
    '  </div>',
    '</div>',
    '<div id="fc-body">加载中...</div>'
  ].join('');

  var toast = document.createElement('div');
  toast.id = 'fc-toast';

  document.body.appendChild(fab);
  document.body.appendChild(drawer);
  document.body.appendChild(toast);

  var nodesList = [];
  var nodesByPort = {};
  var nodesByKey = {};
  var isOpen = false;

  function showToast(msg, ms){
    toast.textContent = msg;
    toast.style.display = 'block';
    clearTimeout(toast._t);
    toast._t = setTimeout(function(){ toast.style.display = 'none'; }, ms || 4000);
  }

  function doNodeAction(port, remark, act){
    var title = '[' + port + '] ' + (remark || '');
    if (act === 'block') {
      if (!confirm('⏸️ 确认暂停/封禁客户端 ' + title + ' 吗？\n\n说明：封禁后服务端将拒绝该客户端连接，但【不会卸载】客户端本地服务，后续可随时点「恢复」重新连接。')) return;
    } else if (act === 'unblock') {
      if (!confirm('▶️ 确认解除对 ' + title + ' 的封禁/吊销状态，允许其重新连接吗？')) return;
    } else if (act === 'destroy') {
      if (!confirm('🗑️ 确认远程卸载客户端 ' + title + ' 的端口 (' + port + ') 实例吗？\n\n• 在线 WebSSH 节点：立即秒级卸载该端口服务\n• RDP/SSH 或离线节点：在下次心跳/重连或下次开机联网时自动执行 frpctl rm ' + port + '（不影响该电脑上的其他端口）。')) return;
    } else if (act === 'purge') {
      var inp = prompt('☢️【高危·全盘无痕自毁】\n目标客户端：' + title + '\n\n此操作将彻底卸载该客户端电脑上的【所有 frpctl 穿透服务】并自动删除全部二进制、配置文件与命令入口，永不再连！\n\n确认执行请输入 YES ：');
      if (inp !== 'YES') return;
    } else if (act === 'forget') {
      if (!confirm('🧹 确认从管控列表中移除 ' + title + ' 的历史记录吗？')) return;
    }

    fetch('/__frpctl_api__/action', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      credentials: 'same-origin',
      body: JSON.stringify({ port: String(port), action: act })
    })
    .then(function(r){ return r.json(); })
    .then(function(res){
      if (res.error) {
        showToast('❌ 操作失败: ' + res.error, 4500);
      } else {
        showToast(res.message || '✅ 操作已执行', 5000);
      }
      fetchNodes();
    })
    .catch(function(err){
      showToast('请求失败: ' + err, 4000);
    });
  }

  function renderDrawer(list){
    var box = document.getElementById('fc-body');
    if (!list || !list.length) {
      box.innerHTML = '<div style="text-align:center;color:#94a3b8;padding:40px 0">暂无客户端记录</div>';
      return;
    }
    box.innerHTML = '';
    list.forEach(function(it){
      var card = document.createElement('div');
      card.className = 'fc-card';

      var stTag = it.status === 'online'
        ? '<span class="fc-tag fc-tag-on">● 在线</span>'
        : '<span class="fc-tag fc-tag-off">○ 离线</span>';

      var revTag = '';
      if (it.revoked) {
        var rMode = it.revoked.action;
        var deliv = it.revoked.delivered ? '（已送达客户端）' : '（已拦截，等待重连/开机触发）';
        if (rMode === 'block') revTag = '<span class="fc-tag fc-tag-rev">⏸️ 已封禁停用</span>';
        if (rMode === 'destroy') revTag = '<span class="fc-tag fc-tag-rev">🗑️ 单端口销毁' + deliv + '</span>';
        if (rMode === 'purge') revTag = '<span class="fc-tag fc-tag-rev">☢️ 全盘彻底自毁' + deliv + '</span>';
      }

      var protoTag = '<span class="fc-tag fc-tag-proto">' + (it.proto || 'tcp').toUpperCase() + '</span>';
      var websshUrl = 'https://' + window.location.hostname + ':' + it.port;

      var html = [
        '<div class="fc-row1">',
        '  <div class="fc-name"><span>[' + it.port + '] ' + (it.remark || '未命名节点') + '</span>' + protoTag + stTag + revTag + '</div>',
        '</div>',
        '<div class="fc-meta">',
        '  <span>主机名: ' + (it.hostname || '-') + '</span>',
        '  <span>客户端 IP: ' + (it.client_addr || '-') + '</span>',
        '  <span>FRP版本: ' + (it.version || '-') + '</span>',
        '  <span>代理名: ' + (it.proxy_name || '-') + '</span>',
        '</div>',
        '<div class="fc-actions">'
      ];

      if (it.proto === 'webssh' && it.status === 'online') {
        html.push('<button class="fc-btn fc-btn-term" data-act="open-ws" data-url="' + websshUrl + '">💻 打开 WebSSH</button>');
      }
      if (it.revoked) {
        html.push('<button class="fc-btn" data-act="unblock">▶️ 取消吊销/恢复连接</button>');
      } else {
        html.push('<button class="fc-btn fc-btn-warn" data-act="block">⏸️ 封禁停用</button>');
      }
      html.push('<button class="fc-btn fc-btn-danger" data-act="destroy">🗑️ 卸载该端口</button>');
      html.push('<button class="fc-btn fc-btn-nuke" data-act="purge">☢️ 彻底自毁撤离</button>');
      if (it.status !== 'online' || it.revoked) {
        html.push('<button class="fc-btn" data-act="forget">🧹 移除记录</button>');
      }
      html.push('</div>');
      card.innerHTML = html.join('');

      card.addEventListener('click', function(e){
        var b = e.target.closest('button[data-act]');
        if (!b) return;
        var a = b.getAttribute('data-act');
        if (a === 'open-ws') {
          window.open(b.getAttribute('data-url'), '_blank');
          return;
        }
        doNodeAction(it.port, it.remark, a);
      });

      box.appendChild(card);
    });
  }

  function matchNodeFromRowText(txt){
    if (!txt) return null;
    if (nodesByKey[txt]) return nodesByKey[txt];
    var mPort = txt.match(/_(\d{4,5})(?:_udp|\.[0-9a-f]+)?$/);
    if (mPort && nodesByPort[mPort[1]]) return nodesByPort[mPort[1]];
    if (mPort) {
      return { port: mPort[1], remark: txt.split('_')[0], proto: txt.indexOf('_webssh_') > 0 ? 'webssh' : 'tcp' };
    }
    return null;
  }

  function injectTableButtons(){
    var rows = document.querySelectorAll('tr.el-table__row, tbody tr');
    rows.forEach(function(tr){
      if (tr.querySelector('.fc-inline-box')) return;
      var cells = tr.querySelectorAll('td');
      if (!cells || !cells.length) return;

      var matched = null;
      var targetCell = null;
      for (var i = 0; i < Math.min(cells.length, 3); i++) {
        var c = cells[i].querySelector('.cell') || cells[i];
        var t = (c.textContent || '').trim();
        if (!t || t.endsWith('_udp')) continue;
        var m = matchNodeFromRowText(t);
        if (m) {
          matched = m;
          targetCell = c;
          break;
        }
      }
      if (!matched || !targetCell) return;

      var box = document.createElement('span');
      box.className = 'fc-inline-box';

      if (matched.proto === 'webssh') {
        var bWs = document.createElement('button');
        bWs.className = 'fc-btn fc-btn-term';
        bWs.textContent = '💻终端';
        bWs.onclick = function(e){ e.stopPropagation(); window.open('https://' + window.location.hostname + ':' + matched.port, '_blank'); };
        box.appendChild(bWs);
      }

      var bBlock = document.createElement('button');
      bBlock.className = 'fc-btn fc-btn-warn';
      bBlock.textContent = matched.revoked ? '▶️恢复' : '⏸️封禁';
      bBlock.onclick = function(e){
        e.stopPropagation();
        doNodeAction(matched.port, matched.remark, matched.revoked ? 'unblock' : 'block');
      };
      box.appendChild(bBlock);

      var bRm = document.createElement('button');
      bRm.className = 'fc-btn fc-btn-danger';
      bRm.textContent = '🗑️卸载';
      bRm.title = '远程卸载该客户端端口实例';
      bRm.onclick = function(e){ e.stopPropagation(); doNodeAction(matched.port, matched.remark, 'destroy'); };
      box.appendChild(bRm);

      var bNuke = document.createElement('button');
      bNuke.className = 'fc-btn fc-btn-nuke';
      bNuke.textContent = '☢️自毁';
      bNuke.title = '彻底卸载该客户端所有穿透服务并删除文件';
      bNuke.onclick = function(e){ e.stopPropagation(); doNodeAction(matched.port, matched.remark, 'purge'); };
      box.appendChild(bNuke);

      targetCell.appendChild(box);
    });
  }

  function fetchNodes(){
    fetch('/__frpctl_api__/nodes', { credentials: 'same-origin' })
      .then(function(r){ return r.json(); })
      .then(function(data){
        nodesList = data.nodes || [];
        nodesByPort = {};
        nodesByKey = {};
        nodesList.forEach(function(n){
          nodesByPort[String(n.port)] = n;
          if (n.proxy_name) nodesByKey[n.proxy_name] = n;
          if (n.client_key) nodesByKey[n.client_key] = n;
          if (n.client_id) nodesByKey[n.client_id] = n;
          if (n.user) nodesByKey[n.user] = n;
        });
        if (isOpen) renderDrawer(nodesList);
        injectTableButtons();
      })
      .catch(function(){});
  }

  fab.onclick = function(){
    isOpen = !isOpen;
    drawer.style.display = isOpen ? 'flex' : 'none';
    if (isOpen) fetchNodes();
  };

  document.getElementById('fc-close').onclick = function(){
    isOpen = false;
    drawer.style.display = 'none';
  };

  document.getElementById('fc-refresh').onclick = function(){
    fetchNodes();
    showToast('已刷新客户端列表', 1500);
  };

  document.getElementById('fc-clean-off').onclick = function(){
    doNodeAction('0', '所有离线残留代理', 'clean_offline');
  };

  fetchNodes();
  setInterval(injectTableButtons, 1000);
  setInterval(fetchNodes, 5000);
})();
"""

def load_state(path):
    with STATE_LOCK:
        if os.path.exists(path):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    data.setdefault('nodes', {})
                    data.setdefault('revoked', {})
                    return data
            except Exception:
                pass
        return {'nodes': {}, 'revoked': {}}

def save_state(path, data):
    with STATE_LOCK:
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)

def parse_proxy_or_user(proxy_name='', user_str='', remote_port=0):
    port = None
    remark = ''
    proto = ''

    # 兼容 "备注_端口.备注_协议_端口" 或 "备注_协议_端口"
    clean_pname = proxy_name.split('.')[-1] if '.' in proxy_name else proxy_name
    m_proxy = re.match(r'^(.+)_([a-z0-9]+)_(\d{4,5})(?:_udp)?$', clean_pname)
    if m_proxy:
        remark, proto, port = m_proxy.group(1), m_proxy.group(2), m_proxy.group(3)

    if not port and user_str:
        m_user = re.match(r'^(.+)_(\d{4,5})$', user_str)
        if m_user:
            remark = remark or m_user.group(1)
            port = m_user.group(2)

    if not port and remote_port > 0:
        if 50000 <= remote_port < 60000:
            port = str(remote_port - 10000)
            proto = proto or 'webssh'
        else:
            port = str(remote_port)

    return port, remark, proto

def extract_client_info(op, content, state):
    user_str = ''
    proxy_name = ''
    remote_port = 0
    client_addr = ''
    run_id = ''
    hostname = ''
    version = ''

    if op == 'Login':
        user_str = content.get('user', '') or ''
        client_addr = content.get('client_address', '') or ''
        run_id = content.get('run_id', '') or ''
        hostname = content.get('hostname', '') or ''
        version = content.get('version', '') or ''
    else:
        u_obj = content.get('user', {}) or {}
        user_str = u_obj.get('user', '') or ''
        run_id = u_obj.get('run_id', '') or ''
        hostname = u_obj.get('hostname', '') or ''
        version = u_obj.get('version', '') or ''
        proxy_name = content.get('proxy_name', '') or ''
        remote_port = int(content.get('remote_port', 0) or 0)

    port, remark, proto = parse_proxy_or_user(proxy_name, user_str, remote_port)

    # 若 Login/Ping 时未携带 user_str，尝试通过 run_id 从已知节点反查端口
    if not port and run_id:
        for p_k, n_v in state.get('nodes', {}).items():
            if n_v.get('client_id') == run_id:
                port = p_k
                remark = remark or n_v.get('remark', '')
                proto = proto or n_v.get('proto', '')
                break

    return port, remark, proto, proxy_name, client_addr, run_id, hostname, version, user_str

class PanelHandler(BaseHTTPRequestHandler):
    cfg = {}

    def log_message(self, fmt, *args):
        return

    def check_dash_auth(self):
        expected = self.cfg.get('dash_auth_b64', '')
        if not expected:
            return True
        auth = self.headers.get('Authorization', '')
        if not auth.lower().startswith('basic '):
            return False
        return auth[6:].strip() == expected

    def send_json(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(raw)

    def handle_plugin(self, parsed):
        if self.client_address[0] not in ('127.0.0.1', '::1'):
            self.send_json(403, {'error': 'Forbidden'})
            return

        clen = int(self.headers.get('Content-Length', '0'))
        body_raw = self.rfile.read(clen) if clen > 0 else b'{}'
        try:
            payload = json.loads(body_raw.decode('utf-8', errors='replace'))
        except Exception:
            payload = {}

        qs = urllib.parse.parse_qs(parsed.query)
        op = qs.get('op', [payload.get('op', '')])[0]
        content = payload.get('content', {}) or {}

        state_file = self.cfg['state_file']
        state = load_state(state_file)
        port, remark, proto, proxy_name, client_addr, run_id, hostname, version, user_str = extract_client_info(op, content, state)

        if port:
            now_str = time.strftime('%Y-%m-%d %H:%M:%S')
            node = state['nodes'].get(port, {'port': port})
            if remark:
                node['remark'] = remark
            if proto:
                node['proto'] = proto
            if proxy_name and not proxy_name.endswith('_udp'):
                node['proxy_name'] = proxy_name
            if client_addr:
                node['client_addr'] = client_addr.split(':')[0]
            if run_id:
                node['client_id'] = run_id
            if hostname:
                node['hostname'] = hostname
            if version:
                node['version'] = version
            if user_str:
                node['user'] = user_str
            node['last_seen'] = now_str
            state['nodes'][port] = node

            rev = state['revoked'].get(port)
            if rev:
                act = rev.get('action', 'block')
                if act == 'purge':
                    rev['delivered'] = True
                    rev['delivered_at'] = now_str
                    save_state(state_file, state)
                    self.send_json(200, {'reject': True, 'reject_reason': 'FRPCTL_REVOKED_PURGE'})
                    return
                elif act == 'destroy':
                    rev['delivered'] = True
                    rev['delivered_at'] = now_str
                    save_state(state_file, state)
                    self.send_json(200, {'reject': True, 'reject_reason': 'FRPCTL_REVOKED_DESTROY'})
                    return
                else:
                    save_state(state_file, state)
                    self.send_json(200, {'reject': True, 'reject_reason': 'FRPCTL_BLOCKED_BY_ADMIN'})
                    return

            save_state(state_file, state)

        self.send_json(200, {'reject': False, 'unchange': True})

    def fetch_frps_json(self, api_path):
        hdrs = {}
        if self.cfg.get('dash_auth_b64'):
            hdrs['Authorization'] = 'Basic ' + self.cfg['dash_auth_b64']
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.cfg['internal_port']}{api_path}",
                headers=hdrs
            )
            with urllib.request.urlopen(req, timeout=4) as resp:
                return json.loads(resp.read().decode('utf-8', errors='replace'))
        except Exception:
            return {}

    def handle_api_nodes(self):
        state = load_state(self.cfg['state_file'])
        tcp_data = self.fetch_frps_json('/api/proxy/tcp')
        proxies = tcp_data.get('proxies', []) or []
        v2_clients_resp = self.fetch_frps_json('/api/v2/clients')
        v2_items = (v2_clients_resp.get('data') or {}).get('items') or []

        clients_by_id = {}
        for c in v2_items:
            cid = c.get('clientID') or c.get('runID') or ''
            if cid:
                clients_by_id[cid] = c

        merged = {}
        for p, n in state.get('nodes', {}).items():
            merged[str(p)] = {
                'port': str(p),
                'remark': n.get('remark', ''),
                'proto': n.get('proto', 'tcp'),
                'proxy_name': n.get('proxy_name', ''),
                'client_addr': n.get('client_addr', ''),
                'client_id': n.get('client_id', ''),
                'client_key': n.get('client_key', ''),
                'hostname': n.get('hostname', ''),
                'version': n.get('version', ''),
                'user': n.get('user', ''),
                'status': 'offline',
                'cur_conns': 0,
                'last_seen': n.get('last_seen', ''),
                'revoked': state.get('revoked', {}).get(str(p))
            }

        for px in proxies:
            pname = px.get('name', '')
            if pname.endswith('_udp'):
                continue
            conf = px.get('conf', {}) or {}
            rport = int(conf.get('remotePort') or conf.get('remote_port') or 0)
            user_str = px.get('user', '') or ''
            cid = px.get('clientID', '') or ''
            port, remark, proto = parse_proxy_or_user(pname, user_str, rport)
            if not port:
                continue

            c_info = clients_by_id.get(cid, {})
            item = merged.get(port, {'port': port})
            item['remark'] = remark or item.get('remark') or pname
            item['proto'] = proto or item.get('proto') or 'tcp'
            item['proxy_name'] = pname
            item['user'] = user_str or c_info.get('user') or item.get('user', '')
            item['client_id'] = cid or item.get('client_id', '')
            item['client_key'] = c_info.get('key') or item.get('client_key', '')
            item['client_addr'] = c_info.get('clientIP') or item.get('client_addr', '')
            item['hostname'] = c_info.get('hostname') or item.get('hostname', '')
            item['version'] = c_info.get('version') or item.get('version', '')
            item['status'] = px.get('status', 'offline')
            item['cur_conns'] = px.get('curConns', 0)
            item['revoked'] = state.get('revoked', {}).get(port)
            merged[port] = item

            st_node = state['nodes'].get(port, {'port': port})
            st_node.update({
                'remark': item['remark'],
                'proto': item['proto'],
                'proxy_name': pname,
                'user': item['user'],
                'client_id': item['client_id'],
                'client_key': item['client_key'],
                'client_addr': item['client_addr'],
                'hostname': item['hostname'],
                'version': item['version']
            })
            state['nodes'][port] = st_node

        save_state(self.cfg['state_file'], state)
        res_list = sorted(merged.values(), key=lambda x: (x['status'] != 'online', int(x['port']) if x['port'].isdigit() else 99999))
        self.send_json(200, {'nodes': res_list})

    def trigger_active_webssh_destroy(self, port_str, mode):
        try:
            p_num = int(port_str)
        except Exception:
            return False
        candidates = [p_num + 10000, p_num] if 40000 <= p_num < 50000 else [p_num]
        token = self.cfg.get('frp_token', '')
        for tp in candidates:
            try:
                url = f"http://127.0.0.1:{tp}/__frpctl__/destroy?mode={mode}&token={urllib.parse.quote(token)}"
                req = urllib.request.Request(url, method='POST', headers={'X-Frpctl-Token': token})
                with urllib.request.urlopen(req, timeout=2.5) as resp:
                    if resp.status == 200:
                        return True
            except Exception:
                pass
        return False

    def clean_frps_offline(self):
        hdrs = {}
        if self.cfg.get('dash_auth_b64'):
            hdrs['Authorization'] = 'Basic ' + self.cfg['dash_auth_b64']
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.cfg['internal_port']}/api/proxies?status=offline",
                method='DELETE',
                headers=hdrs
            )
            urllib.request.urlopen(req, timeout=4).read()
            return True
        except Exception:
            return False

    def handle_api_action(self):
        clen = int(self.headers.get('Content-Length', '0'))
        raw = self.rfile.read(clen) if clen > 0 else b'{}'
        try:
            body = json.loads(raw.decode('utf-8', errors='replace'))
        except Exception:
            body = {}

        port = str(body.get('port', '')).strip()
        action = str(body.get('action', '')).strip()
        state_file = self.cfg['state_file']
        state = load_state(state_file)
        now_str = time.strftime('%Y-%m-%d %H:%M:%S')

        if action == 'clean_offline':
            self.clean_frps_offline()
            self.send_json(200, {'ok': True, 'message': '🧹 已清理 frps 面板中的离线代理记录'})
            return

        if not port:
            self.send_json(400, {'error': '缺少 port 参数'})
            return

        if action == 'unblock':
            state['revoked'].pop(port, None)
            save_state(state_file, state)
            self.send_json(200, {'ok': True, 'message': f'▶️ 已解除端口 {port} 的封禁/吊销状态'})
            return

        if action == 'forget':
            state['revoked'].pop(port, None)
            state['nodes'].pop(port, None)
            save_state(state_file, state)
            self.clean_frps_offline()
            self.send_json(200, {'ok': True, 'message': f'🧹 已移除端口 {port} 的记录'})
            return

        if action == 'block':
            state['revoked'][port] = {
                'action': 'block',
                'created_at': now_str,
                'delivered': False
            }
            save_state(state_file, state)
            self.send_json(200, {'ok': True, 'message': f'⏸️ 已封禁端口 {port}（将在下次心跳/重连时拦截，不卸载客户端）'})
            return

        if action in ('destroy', 'purge'):
            gw_mode = 'purge' if action == 'purge' else 'rm'
            active_ok = self.trigger_active_webssh_destroy(port, gw_mode)
            state['revoked'][port] = {
                'action': action,
                'created_at': now_str,
                'delivered': active_ok,
                'delivered_at': now_str if active_ok else ''
            }
            save_state(state_file, state)
            label = '☢️ 全盘无痕自毁' if action == 'purge' else '🗑️ 单端口卸载'
            if active_ok:
                msg = f'{label}：已通过隧道主动送达客户端 ({port})，客户端正在立即卸载清理！'
            else:
                msg = f'{label}：已加入拦截队列 ({port})，在线节点将在心跳/重连时自毁，离线节点将在下次开机联网时自动自毁！'
            self.send_json(200, {'ok': True, 'delivered': active_ok, 'message': msg})
            return

        self.send_json(400, {'error': f'未知操作: {action}'})

    def proxy_to_frps(self, method):
        clen = int(self.headers.get('Content-Length', '0'))
        req_body = self.rfile.read(clen) if clen > 0 else None

        parsed = urllib.parse.urlsplit(self.path)
        is_html_entry = parsed.path in ('/', '/index.html', '/static/', '/static/index.html')

        conn = http.client.HTTPConnection('127.0.0.1', self.cfg['internal_port'], timeout=15)
        fwd_headers = {}
        for k, v in self.headers.items():
            kl = k.lower()
            if kl in ('host', 'accept-encoding', 'connection'):
                continue
            # 防止浏览器缓存导致 304 Not Modified 跳过脚本注入
            if is_html_entry and kl in ('if-none-match', 'if-modified-since'):
                continue
            fwd_headers[k] = v
        fwd_headers['Host'] = f"127.0.0.1:{self.cfg['internal_port']}"

        try:
            conn.request(method, self.path, body=req_body, headers=fwd_headers)
            resp = conn.getresponse()
            data = resp.read()
            ctype = resp.getheader('Content-Type', '')

            injected = False
            if method == 'GET' and ('text/html' in ctype.lower() or is_html_entry):
                if resp.getheader('Content-Encoding', '').lower() == 'gzip' or data[:2] == b'\x1f\x8b':
                    try:
                        data = gzip.decompress(data)
                    except Exception:
                        pass
                inject = b'<script src="/__frpctl_api__/panel.js"></script>'
                if b'</body>' in data:
                    data = data.replace(b'</body>', inject + b'</body>', 1)
                    injected = True

            self.send_response(resp.status)
            for hk, hv in resp.getheaders():
                hkl = hk.lower()
                if hkl in ('content-length', 'content-encoding', 'transfer-encoding', 'connection'):
                    continue
                if injected and hkl in ('etag', 'last-modified', 'cache-control'):
                    continue
                self.send_header(hk, hv)
            if injected:
                self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_json(502, {'error': f'frps 内部面板不可达: {e}'})
        finally:
            conn.close()

    def do_request(self, method):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == '/__frpctl_plugin__':
            self.handle_plugin(parsed)
            return

        if parsed.path.startswith('/__frpctl_api__/'):
            if not self.check_dash_auth():
                self.send_response(401)
                self.send_header('WWW-Authenticate', 'Basic realm="frps Dashboard"')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            if parsed.path == '/__frpctl_api__/panel.js':
                js_bytes = PANEL_JS.encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'application/javascript; charset=utf-8')
                self.send_header('Content-Length', str(len(js_bytes)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(js_bytes)
                return
            if parsed.path == '/__frpctl_api__/nodes' and method == 'GET':
                self.handle_api_nodes()
                return
            if parsed.path == '/__frpctl_api__/action' and method == 'POST':
                self.handle_api_action()
                return
            self.send_json(404, {'error': 'Not Found'})
            return

        self.proxy_to_frps(method)

    def do_GET(self):
        self.do_request('GET')

    def do_POST(self):
        self.do_request('POST')

    def do_DELETE(self):
        self.do_request('DELETE')

    def do_PUT(self):
        self.do_request('PUT')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--listen-port', type=int, default=443)
    p.add_argument('--plugin-port', type=int, default=49500)
    p.add_argument('--internal-port', type=int, default=49501)
    p.add_argument('--dash-user', type=str, default='admin')
    p.add_argument('--dash-pass', type=str, default='admin')
    p.add_argument('--frp-token', type=str, default='CHANGE_ME_TOKEN')
    p.add_argument('--tls-cert', type=str, default='')
    p.add_argument('--tls-key', type=str, default='')
    p.add_argument('--state-file', type=str, default='/usr/local/frp/frpctl_state.json')
    args = p.parse_args()

    auth_str = f"{args.dash_user}:{args.dash_pass}"
    PanelHandler.cfg = {
        'listen_port': args.listen_port,
        'plugin_port': args.plugin_port,
        'internal_port': args.internal_port,
        'dash_auth_b64': base64.b64encode(auth_str.encode('utf-8')).decode('ascii') if args.dash_user else '',
        'frp_token': args.frp_token,
        'state_file': args.state_file
    }

    # 若 listen_port != plugin_port，单独在 127.0.0.1:plugin_port 启一个本地 HTTP 监听供 frps httpPlugin 调用
    if args.listen_port != args.plugin_port:
        plugin_srv = ThreadingHTTPServer(('127.0.0.1', args.plugin_port), PanelHandler)
        t = threading.Thread(target=plugin_srv.serve_forever, daemon=True)
        t.start()
        print(f"[*] frps httpPlugin 本地监听已启动: http://127.0.0.1:{args.plugin_port}/__frpctl_plugin__")

    srv = ThreadingHTTPServer(('0.0.0.0', args.listen_port), PanelHandler)
    if args.tls_cert and args.tls_key and os.path.isfile(args.tls_cert) and os.path.isfile(args.tls_key):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=args.tls_cert, keyfile=args.tls_key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        print(f"[*] frpctl Dashboard 管控网关已启动 (HTTPS): 0.0.0.0:{args.listen_port} -> 127.0.0.1:{args.internal_port}")
    else:
        print(f"[*] frpctl Dashboard 管控网关已启动 (HTTP): 0.0.0.0:{args.listen_port} -> 127.0.0.1:{args.internal_port}")

    srv.serve_forever()

if __name__ == '__main__':
    main()
EOF_PANEL_PY
    chmod 755 "$PANEL_PY"
}

install_panel() {
    require_root
    local conf
    if ! conf=$(find_frps_conf); then
        echo "❌ 未找到 frps 配置文件 (frps.toml / frps.ini)" >&2
        exit 1
    fi
    echo "[*] 检测到 frps 配置文件: $conf"

    # 若存在最初的备份，优先从干净原配置读取原始端口与证书，避免重复执行时读到已改写的内部端口
    local first_bak
    first_bak=$(ls -1t "${conf}".bak.* 2>/dev/null | tail -1 || true)
    local src_conf="${first_bak:-$conf}"

    cp -f "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"

    local token dash_user dash_pass orig_port tls_cert tls_key
    token=$(grep -E '^[[:space:]]*(auth\.token|token)[[:space:]]*=' "$src_conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)
    dash_user=$(grep -E '^[[:space:]]*(webServer\.user|dashboard_user)[[:space:]]*=' "$src_conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)
    dash_pass=$(grep -E '^[[:space:]]*(webServer\.password|dashboard_pwd)[[:space:]]*=' "$src_conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)
    orig_port=$(grep -E '^[[:space:]]*(webServer\.port|dashboard_port)[[:space:]]*=' "$src_conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([0-9]+)"?.*/\1/' || true)
    tls_cert=$(grep -E '^[[:space:]]*(webServer\.tls\.certFile|dashboard_tls_cert_file)[[:space:]]*=' "$src_conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)
    tls_key=$(grep -E '^[[:space:]]*(webServer\.tls\.keyFile|dashboard_tls_key_file)[[:space:]]*=' "$src_conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)

    token="${token:-CHANGE_ME_TOKEN}"
    dash_user="${dash_user:-admin}"
    dash_pass="${dash_pass:-admin}"
    orig_port="${orig_port:-49500}"
    if [[ "$orig_port" == "$INTERNAL_DASH_PORT" ]]; then
        orig_port=443
    fi

    # 根据文件内容判断是 INI 语法 (含 [common]) 还是纯 TOML 语法
    if grep -qE '^[[:space:]]*\[common\]' "$conf"; then
        echo "[*] 识别到 INI 格式配置 ([common])，对外 Dashboard 端口: $orig_port"
        # 清理此前误加的 [[httpPlugins]] 块
        sed -i '/^\[\[httpPlugins\]\]/,/^ops =/d' "$conf"

        if grep -qE '^[[:space:]]*dashboard_addr[[:space:]]*=' "$conf"; then
            sed -i -E 's/^[[:space:]]*dashboard_addr[[:space:]]*=.*/dashboard_addr = "127.0.0.1"/' "$conf"
        else
            sed -i -E "/^[[:space:]]*dashboard_port[[:space:]]*=/i dashboard_addr = \"127.0.0.1\"" "$conf"
        fi
        sed -i -E "s/^[[:space:]]*dashboard_port[[:space:]]*=.*/dashboard_port = ${INTERNAL_DASH_PORT}/" "$conf"
        sed -i -E 's/^[[:space:]]*dashboard_tls_mode[[:space:]]*=.*/dashboard_tls_mode = "false"/' "$conf"

        if ! grep -q '^\[plugin\.frpctl-revoker\]' "$conf"; then
            cat >> "$conf" <<EOF

[plugin.frpctl-revoker]
addr = "127.0.0.1:${PLUGIN_HTTP_PORT}"
path = "/__frpctl_plugin__"
ops = "Login,NewProxy,Ping"
EOF
        fi
    else
        echo "[*] 识别到 TOML 格式配置，对外 Dashboard 端口: $orig_port"
        sed -i -E 's/^[[:space:]]*webServer\.addr[[:space:]]*=.*/webServer.addr = "127.0.0.1"/' "$conf"
        sed -i -E "s/^[[:space:]]*webServer\.port[[:space:]]*=.*/webServer.port = ${INTERNAL_DASH_PORT}/" "$conf"
        if ! grep -q "frpctl-revoker" "$conf"; then
            cat >> "$conf" <<EOF

[[httpPlugins]]
name = "frpctl-revoker"
addr = "127.0.0.1:${PLUGIN_HTTP_PORT}"
path = "/__frpctl_plugin__"
ops = ["Login", "NewProxy", "Ping"]
EOF
        fi
    fi

    write_panel_py
    local py_bin
    py_bin="$(command -v python3 || echo /usr/bin/python3)"

    local tls_args=""
    if [[ -n "$tls_cert" && -n "$tls_key" && -f "$tls_cert" && -f "$tls_key" ]]; then
        tls_args="--tls-cert $tls_cert --tls-key $tls_key"
    fi

    cat > "$SVC_FILE" <<EOF
[Unit]
Description=frpctl Dashboard Control & Client Revocation Plugin
After=network.target

[Service]
Type=simple
WorkingDirectory=$FRP_DIR
ExecStart=$py_bin $PANEL_PY --listen-port $orig_port --plugin-port $PLUGIN_HTTP_PORT --internal-port $INTERNAL_DASH_PORT --dash-user $dash_user --dash-pass $dash_pass --frp-token $token --state-file $STATE_FILE $tls_args
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    # 先重启 frps 释放原对外 Dashboard 端口 (如 443)，再启动 frps-panel 接管该端口
    systemctl stop frps-panel 2>/dev/null || true
    systemctl restart frps
    sleep 1
    systemctl enable frps-panel >/dev/null 2>&1 || true
    systemctl restart frps-panel

    echo ""
    echo "================ 部署成功 ================"
    echo "  Dashboard 对外端口 : $orig_port (支持 HTTPS/HTTP 原地址访问)"
    echo "  frps 内部面板端口  : 127.0.0.1:$INTERNAL_DASH_PORT"
    echo "  httpPlugin 端口    : 127.0.0.1:$PLUGIN_HTTP_PORT"
    echo "  状态持久化文件     : $STATE_FILE"
    echo "=========================================="
}

uninstall_panel() {
    require_root
    systemctl stop frps-panel 2>/dev/null || true
    systemctl disable frps-panel 2>/dev/null || true
    rm -f "$SVC_FILE" "$PANEL_PY"
    systemctl daemon-reload
    echo "[√] 已移除 frps-panel 服务（如需恢复原 frps.toml 端口，可还原同目录下的 .bak 备份并重启 frps）"
}

case "${1:-install}" in
    install|i)   install_panel ;;
    uninstall|rm) uninstall_panel ;;
    status|st)   systemctl status frps-panel --no-pager ;;
    *)           echo "用法: $0 {install|status|uninstall}" >&2; exit 1 ;;
esac
