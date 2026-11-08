#!/usr/bin/env bash
# =============================================================
# frpctl - 服务端 Dashboard 远程销毁/管控插件一键安装脚本
#
# 功能：
#   1. 为原版 frps Dashboard 自动注入「💻 终端」「⏸️ 封禁」「🗑️ 卸载端口」「☢️ 彻底自毁」操作按钮
#   2. 提供右下角「🛡️ 客户端管控与自毁中心」抽屉面板，支持查看已吊销/待自毁节点及送达回执
#   3. 对接 frps 原生 httpPlugins (Login / NewProxy / Ping)：
#      - 在线 WebSSH 节点：通过本地网关秒级主动触发卸载/自毁
#      - 在线 RDP/SSH 节点：在 ≤30 秒心跳 (Ping) 内触发被动自毁
#      - 关机/离线节点：加入持久化吊销队列，客户端下次开机联网即刻自动自毁
#
# 用法（在 frps 服务端 root 下执行）：
#   sudo bash server-panel.sh install
#   sudo bash server-panel.sh status
#   sudo bash server-panel.sh uninstall
# =============================================================
set -euo pipefail

FRP_DIR="${FRP_DIR:-/usr/local/frp}"
PANEL_PORT="${PANEL_PORT:-49500}"
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
    # 尝试从 systemd 服务中查找
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
import socket
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
    '#fc-fab{position:fixed;right:22px;bottom:22px;height:44px;padding:0 16px;border-radius:22px;background:linear-gradient(135deg,#1890ff,#096dd9);color:#fff;box-shadow:0 4px 14px rgba(24,144,255,.4);display:flex;align-items:center;gap:8px;cursor:pointer;z-index:99999;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;font-size:14px;font-weight:600;user-select:none;transition:transform .15s}',
    '#fc-fab:hover{transform:translateY(-2px)}',
    '#fc-drawer{position:fixed;top:0;right:0;width:560px;max-width:95vw;height:100vh;background:#fff;color:#303133;z-index:100000;display:none;flex-direction:column;box-shadow:-4px 0 20px rgba(0,0,0,.18);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;font-size:13px}',
    '#fc-drawer *{box-sizing:border-box}',
    '#fc-head{height:54px;border-bottom:1px solid #ebeef5;display:flex;align-items:center;justify-content:space-between;padding:0 18px;background:#f8fafc}',
    '#fc-title{font-size:15px;font-weight:600;color:#1f2937;display:flex;align-items:center;gap:8px}',
    '#fc-body{flex:1;overflow-y:auto;padding:14px 16px 80px 16px}',
    '.fc-card{border:1px solid #e4e7ed;border-radius:8px;padding:12px 14px;margin-bottom:10px;background:#fff;transition:border-color .15s}',
    '.fc-card:hover{border-color:#c0c4cc}',
    '.fc-row1{display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;gap:8px;flex-wrap:wrap}',
    '.fc-name{font-size:14px;font-weight:600;color:#111827;display:flex;align-items:center;gap:8px}',
    '.fc-tag{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}',
    '.fc-tag-on{background:#e6f4ea;color:#137333}',
    '.fc-tag-off{background:#f1f3f4;color:#5f6368}',
    '.fc-tag-rev{background:#fce8e6;color:#c5221f}',
    '.fc-tag-proto{background:#e8f0fe;color:#1967d2}',
    '.fc-meta{font-size:12px;color:#606266;margin-bottom:10px;display:flex;gap:14px;flex-wrap:wrap}',
    '.fc-actions{display:flex;gap:6px;flex-wrap:wrap}',
    '.fc-btn{border:1px solid #dcdfe6;background:#fff;color:#606266;border-radius:4px;padding:4px 9px;font-size:12px;cursor:pointer;display:inline-flex;align-items:center;gap:4px;transition:all .15s;line-height:1.4}',
    '.fc-btn:hover{border-color:#409eff;color:#409eff;background:#ecf5ff}',
    '.fc-btn-term{border-color:#b3d8ff;background:#ecf5ff;color:#409eff}',
    '.fc-btn-term:hover{background:#409eff;color:#fff}',
    '.fc-btn-warn{border-color:#f5dab1;background:#fdf6ec;color:#e6a23c}',
    '.fc-btn-warn:hover{background:#e6a23c;color:#fff;border-color:#e6a23c}',
    '.fc-btn-danger{border-color:#fbc4c4;background:#fef0f0;color:#f56c6c}',
    '.fc-btn-danger:hover{background:#f56c6c;color:#fff;border-color:#f56c6c}',
    '.fc-btn-nuke{border-color:#f56c6c;background:#f56c6c;color:#fff;font-weight:600}',
    '.fc-btn-nuke:hover{background:#dd6161;border-color:#dd6161}',
    '.fc-inline-box{display:inline-flex;gap:4px;margin-left:8px;vertical-align:middle}',
    '#fc-toast{position:fixed;top:16px;right:20px;background:#1f2937;color:#fff;padding:10px 16px;border-radius:6px;font-size:13px;z-index:100005;display:none;box-shadow:0 4px 12px rgba(0,0,0,.25);max-width:420px}'
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
    '  <div style="display:flex;gap:8px">',
    '    <button class="fc-btn" id="fc-refresh">🔄 刷新</button>',
    '    <button class="fc-btn" id="fc-clean-off" title="清理 frps 面板中的离线残留行">🧹 清离线</button>',
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

  var nodesMap = {};
  var isOpen = false;

  function showToast(msg, ms){
    toast.textContent = msg;
    toast.style.display = 'block';
    clearTimeout(toast._t);
    toast._t = setTimeout(function(){ toast.style.display = 'none'; }, ms || 3500);
  }

  function parsePortFromProxyName(name){
    if (!name) return null;
    var m = name.match(/_(\d{4,5})(?:_udp)?$/);
    return m ? m[1] : null;
  }

  function doNodeAction(port, remark, act){
    var title = '[' + port + '] ' + (remark || '');
    if (act === 'block') {
      if (!confirm('⏸️ 确认暂停/封禁客户端 ' + title + ' 吗？\n\n说明：封禁后服务端将拒绝该端口连接，但【不会卸载】客户端本地服务，后续可随时点「恢复」重新连接。')) return;
    } else if (act === 'unblock') {
      if (!confirm('▶️ 确认解除对 ' + title + ' 的封禁/吊销状态，允许其重新连接吗？')) return;
    } else if (act === 'destroy') {
      if (!confirm('🗑️ 确认远程卸载客户端 ' + title + ' 的当前端口 (' + port + ') 实例吗？\n\n• 若客户端在线(WebSSH)：立即秒级卸载该端口服务\n• 若客户端为RDP/SSH或当前关机：将在下次心跳(≤30s)或下次开机联网时自动卸载该端口（不影响该电脑上的其他端口）。')) return;
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
        showToast(res.message || '✅ 操作已执行', 4500);
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
      box.innerHTML = '<div style="text-align:center;color:#909399;padding:40px 0">暂无客户端记录</div>';
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
        var deliv = it.revoked.delivered ? '（已送达客户端）' : '（等待客户端心跳/开机触发）';
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
        '  <span>代理名: ' + (it.proxy_name || '-') + '</span>',
        '  <span>客户端地址: ' + (it.client_addr || '-') + '</span>',
        '  <span>当前连接: ' + (it.cur_conns || 0) + '</span>',
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
      if (it.status !== 'online') {
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

  function injectTableButtons(){
    var cells = document.querySelectorAll('td div.cell, td');
    cells.forEach(function(cell){
      if (cell.children.length > 1) return;
      var txt = (cell.textContent || '').trim();
      if (!txt || txt.endsWith('_udp')) return;
      var port = parsePortFromProxyName(txt);
      if (!port) return;
      var tr = cell.closest('tr');
      if (!tr || tr.querySelector('.fc-inline-box')) return;

      var info = nodesMap[port] || { port: port, remark: txt.split('_')[0], proto: txt.indexOf('_webssh_') > 0 ? 'webssh' : 'tcp' };
      var box = document.createElement('span');
      box.className = 'fc-inline-box';

      if (info.proto === 'webssh') {
        var bWs = document.createElement('button');
        bWs.className = 'fc-btn fc-btn-term';
        bWs.textContent = '💻终端';
        bWs.onclick = function(e){ e.stopPropagation(); window.open('https://' + window.location.hostname + ':' + port, '_blank'); };
        box.appendChild(bWs);
      }

      var bRm = document.createElement('button');
      bRm.className = 'fc-btn fc-btn-danger';
      bRm.textContent = '🗑️卸载';
      bRm.title = '远程卸载该客户端端口实例';
      bRm.onclick = function(e){ e.stopPropagation(); doNodeAction(port, info.remark, 'destroy'); };
      box.appendChild(bRm);

      var bNuke = document.createElement('button');
      bNuke.className = 'fc-btn fc-btn-nuke';
      bNuke.textContent = '☢️自毁';
      bNuke.title = '彻底卸载该客户端所有穿透服务并删除文件';
      bNuke.onclick = function(e){ e.stopPropagation(); doNodeAction(port, info.remark, 'purge'); };
      box.appendChild(bNuke);

      cell.appendChild(box);
    });
  }

  function fetchNodes(){
    fetch('/__frpctl_api__/nodes', { credentials: 'same-origin' })
      .then(function(r){ return r.json(); })
      .then(function(data){
        var list = data.nodes || [];
        nodesMap = {};
        list.forEach(function(n){ nodesMap[String(n.port)] = n; });
        if (isOpen) renderDrawer(list);
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
    showToast('已刷新节点状态', 1500);
  };

  document.getElementById('fc-clean-off').onclick = function(){
    doNodeAction('0', '所有离线残留代理', 'clean_offline');
  };

  fetchNodes();
  setInterval(injectTableButtons, 1500);
  setInterval(function(){ if (isOpen) fetchNodes(); }, 5000);
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

def extract_client_info(op, content):
    user_str = ''
    proxy_name = ''
    remote_port = 0
    client_addr = ''

    if op == 'Login':
        user_str = content.get('user', '') or ''
        client_addr = content.get('client_address', '') or ''
    else:
        u_obj = content.get('user', {}) or {}
        user_str = u_obj.get('user', '') or ''
        proxy_name = content.get('proxy_name', '') or ''
        remote_port = int(content.get('remote_port', 0) or 0)

    port = None
    remark = ''
    proto = ''

    # 优先从 proxy_name 解析: 备注_协议_端口
    m_proxy = re.match(r'^(.+)_([a-z0-9]+)_(\d{4,5})(?:_udp)?$', proxy_name)
    if m_proxy:
        remark, proto, port = m_proxy.group(1), m_proxy.group(2), m_proxy.group(3)

    # 其次从 user 解析: 备注_端口
    if not port and user_str:
        m_user = re.match(r'^(.+)_(\d{4,5})$', user_str)
        if m_user:
            remark = remark or m_user.group(1)
            port = m_user.group(2)

    # 再次从 remote_port 反推
    if not port and remote_port > 0:
        if 50000 <= remote_port < 60000:
            port = str(remote_port - 10000)
            proto = proto or 'webssh'
        else:
            port = str(remote_port)

    return port, remark, proto, proxy_name, client_addr

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
        # 仅允许本机 frps 调用
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

        port, remark, proto, proxy_name, client_addr = extract_client_info(op, content)
        state_file = self.cfg['state_file']
        state = load_state(state_file)

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
                node['client_addr'] = client_addr
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

    def fetch_frps_proxies(self):
        proxies = []
        hdrs = {}
        if self.cfg.get('dash_auth_b64'):
            hdrs['Authorization'] = 'Basic ' + self.cfg['dash_auth_b64']
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.cfg['internal_port']}/api/proxy/tcp",
                headers=hdrs
            )
            with urllib.request.urlopen(req, timeout=4) as resp:
                data = json.loads(resp.read().decode('utf-8', errors='replace'))
                proxies = data.get('proxies', []) or []
        except Exception:
            pass
        return proxies

    def handle_api_nodes(self):
        state = load_state(self.cfg['state_file'])
        proxies = self.fetch_frps_proxies()
        merged = {}

        for p, n in state.get('nodes', {}).items():
            merged[str(p)] = {
                'port': str(p),
                'remark': n.get('remark', ''),
                'proto': n.get('proto', 'tcp'),
                'proxy_name': n.get('proxy_name', ''),
                'client_addr': n.get('client_addr', ''),
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
            port, remark, proto, _, _ = extract_client_info('NewProxy', {'proxy_name': pname, 'remote_port': rport})
            if not port:
                continue
            item = merged.get(port, {'port': port})
            item['remark'] = remark or item.get('remark') or pname
            item['proto'] = proto or item.get('proto') or 'tcp'
            item['proxy_name'] = pname
            item['status'] = px.get('status', 'offline')
            item['cur_conns'] = px.get('curConns', 0)
            item['revoked'] = state.get('revoked', {}).get(port)
            merged[port] = item

            # 同步回 state
            st_node = state['nodes'].get(port, {'port': port})
            st_node.update({
                'remark': item['remark'],
                'proto': item['proto'],
                'proxy_name': pname
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
            self.send_json(200, {'ok': True, 'message': f'⏸️ 已封禁端口 {port}（将在下次心跳 ≤30s 内断开，不卸载客户端）'})
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
                msg = f'{label}：已加入拦截队列 ({port})，在线节点将在 ≤30秒心跳内自毁，离线节点将在下次开机联网时自动自毁！'
            self.send_json(200, {'ok': True, 'delivered': active_ok, 'message': msg})
            return

        self.send_json(400, {'error': f'未知操作: {action}'})

    def proxy_to_frps(self, method):
        clen = int(self.headers.get('Content-Length', '0'))
        req_body = self.rfile.read(clen) if clen > 0 else None

        conn = http.client.HTTPConnection('127.0.0.1', self.cfg['internal_port'], timeout=15)
        fwd_headers = {}
        for k, v in self.headers.items():
            if k.lower() not in ('host', 'accept-encoding', 'connection'):
                fwd_headers[k] = v
        fwd_headers['Host'] = f"127.0.0.1:{self.cfg['internal_port']}"

        try:
            conn.request(method, self.path, body=req_body, headers=fwd_headers)
            resp = conn.getresponse()
            data = resp.read()
            ctype = resp.getheader('Content-Type', '')

            if method == 'GET' and ('text/html' in ctype.lower() or self.path in ('/', '/index.html')):
                if resp.getheader('Content-Encoding', '').lower() == 'gzip' or data[:2] == b'\x1f\x8b':
                    try:
                        data = gzip.decompress(data)
                    except Exception:
                        pass
                inject = b'<script src="/__frpctl_api__/panel.js"></script>'
                if b'</body>' in data:
                    data = data.replace(b'</body>', inject + b'</body>', 1)
                else:
                    data += inject

            self.send_response(resp.status)
            for hk, hv in resp.getheaders():
                if hk.lower() in ('content-length', 'content-encoding', 'transfer-encoding', 'connection'):
                    continue
                self.send_header(hk, hv)
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
    p.add_argument('--listen-port', type=int, default=49500)
    p.add_argument('--internal-port', type=int, default=49501)
    p.add_argument('--dash-user', type=str, default='admin')
    p.add_argument('--dash-pass', type=str, default='admin')
    p.add_argument('--frp-token', type=str, default='CHANGE_ME_TOKEN')
    p.add_argument('--state-file', type=str, default='/usr/local/frp/frpctl_state.json')
    args = p.parse_args()

    auth_str = f"{args.dash_user}:{args.dash_pass}"
    PanelHandler.cfg = {
        'listen_port': args.listen_port,
        'internal_port': args.internal_port,
        'dash_auth_b64': base64.b64encode(auth_str.encode('utf-8')).decode('ascii') if args.dash_user else '',
        'frp_token': args.frp_token,
        'state_file': args.state_file
    }

    srv = ThreadingHTTPServer(('0.0.0.0', args.listen_port), PanelHandler)
    print(f"[*] frpctl Dashboard 管控网关已启动: 0.0.0.0:{args.listen_port} -> 127.0.0.1:{args.internal_port}")
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

    cp -f "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"

    # 提取 token、webServer 用户名密码
    local token dash_user dash_pass
    token=$(grep -E '^(auth\.token|token)[[:space:]]*=' "$conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)
    dash_user=$(grep -E '^(webServer\.user|dashboard_user)[[:space:]]*=' "$conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)
    dash_pass=$(grep -E '^(webServer\.password|dashboard_pwd)[[:space:]]*=' "$conf" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)

    token="${token:-CHANGE_ME_TOKEN}"
    dash_user="${dash_user:-admin}"
    dash_pass="${dash_pass:-admin}"

    # 修改 frps 内部 Dashboard 端口为 127.0.0.1:49501 并挂载 httpPlugins
    if [[ "$conf" == *.toml ]]; then
        sed -i -E 's/^webServer\.addr[[:space:]]*=.*/webServer.addr = "127.0.0.1"/' "$conf"
        sed -i -E "s/^webServer\.port[[:space:]]*=.*/webServer.port = ${INTERNAL_DASH_PORT}/" "$conf"
        if ! grep -q "frpctl-revoker" "$conf"; then
            cat >> "$conf" <<EOF

[[httpPlugins]]
name = "frpctl-revoker"
addr = "127.0.0.1:${PANEL_PORT}"
path = "/__frpctl_plugin__"
ops = ["Login", "NewProxy", "Ping"]
EOF
        fi
    else
        sed -i -E 's/^dashboard_addr[[:space:]]*=.*/dashboard_addr = 127.0.0.1/' "$conf"
        sed -i -E "s/^dashboard_port[[:space:]]*=.*/dashboard_port = ${INTERNAL_DASH_PORT}/" "$conf"
        if ! grep -q "plugin.frpctl-revoker" "$conf"; then
            cat >> "$conf" <<EOF

[plugin.frpctl-revoker]
addr = 127.0.0.1:${PANEL_PORT}
path = /__frpctl_plugin__
ops = Login,NewProxy,Ping
EOF
        fi
    fi

    write_panel_py
    local py_bin
    py_bin="$(command -v python3 || echo /usr/bin/python3)"

    cat > "$SVC_FILE" <<EOF
[Unit]
Description=frpctl Dashboard Control & Client Revocation Plugin
After=network.target

[Service]
Type=simple
WorkingDirectory=$FRP_DIR
ExecStart=$py_bin $PANEL_PY --listen-port $PANEL_PORT --internal-port $INTERNAL_DASH_PORT --dash-user $dash_user --dash-pass $dash_pass --frp-token $token --state-file $STATE_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frps-panel >/dev/null 2>&1 || true
    systemctl restart frps-panel
    sleep 1
    systemctl restart frps

    echo ""
    echo "================ 部署成功 ================"
    echo "  Dashboard 外部端口 : $PANEL_PORT (保持不变)"
    echo "  frps 内部面板端口  : 127.0.0.1:$INTERNAL_DASH_PORT"
    echo "  状态持久化文件     : $STATE_FILE"
    echo "  打开原 Dashboard 即可在表格行内与右下角看到："
    echo "    [💻终端] [⏸️封禁] [🗑️卸载该端口] [☢️彻底自毁撤离]"
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
