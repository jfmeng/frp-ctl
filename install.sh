#!/usr/bin/env bash
# frpctl - Linux/macOS 引导安装脚本
# -----------------------------------------------------------
# 用法（root 或 sudo）：
#   curl -fsSL https://raw.githubusercontent.com/jfmeng/frp-ctl/main/install.sh | sudo bash
#   # 国内加速镜像：
#   curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/jfmeng/frp-ctl/main/install.sh | sudo bash
#
#   # 安装同时直接初始化服务端配置或添加实例：
#   curl -fsSL .../install.sh | sudo bash -s -- config --server frp.example.com --server-port 49000 --token your_token
# -----------------------------------------------------------
set -euo pipefail

# ----- 配置区 -----
REPO="${FRPCTL_REPO:-jfmeng/frp-ctl}"
BRANCH="${FRPCTL_BRANCH:-main}"
MIRRORS=(
    "https://ghfast.top/https://raw.githubusercontent.com"
    "https://ghproxy.net/https://raw.githubusercontent.com"
    "https://raw.githubusercontent.com"
)
MAIN_SCRIPT="frpctl.sh"
# 可选：若从私有 Fork 仓库拉取，可通过环境变量传入 GH_TOKEN
GH_TOKEN="${GH_TOKEN:-}"
# ------------------

if [[ $EUID -ne 0 ]]; then
    echo "❌ 请使用 root 用户或 sudo 运行此安装命令" >&2
    exit 1
fi

INSTALL_DIR="/usr/local/sbin"
TARGET="${INSTALL_DIR}/frpctl"
mkdir -p "${INSTALL_DIR}"

echo "[*] 准备下载 frpctl 主脚本到 ${TARGET}"
ok=0
curl_auth_args=()
if [[ -n "${GH_TOKEN}" ]]; then
    curl_auth_args=(-H "Authorization: token ${GH_TOKEN}")
fi

for m in "${MIRRORS[@]}"; do
    url="${m}/${REPO}/${BRANCH}/${MAIN_SCRIPT}?_=$(date +%s)"
    echo "    尝试: ${url}"
    if curl -fsSL --connect-timeout 10 "${curl_auth_args[@]}" -o "${TARGET}" "${url}"; then
        ok=1; break
    else
        echo "    失败，尝试下一个镜像..."
    fi
done

if [[ $ok -ne 1 ]]; then
    echo "❌ 所有镜像均下载失败，请检查网络连接" >&2
    exit 1
fi

chmod +x "${TARGET}"
echo "[√] frpctl 已安装到 ${TARGET}"

# 若通过环境变量传入了 FRP_SERVER_ADDR / FRP_AUTH_TOKEN，自动初始化配置文件
CONF_DIR="/etc/frpctl"
[[ "$(uname -s)" == "Darwin" ]] && CONF_DIR="/usr/local/etc/frpctl"
CONF_FILE="${CONF_DIR}/frpctl.conf"
if [[ -n "${FRP_SERVER_ADDR:-}" || -n "${FRP_AUTH_TOKEN:-}" ]]; then
    mkdir -p "${CONF_DIR}"
    cat > "${CONF_FILE}" <<EOF
SERVER_ADDR=${FRP_SERVER_ADDR:-frp.example.com}
SERVER_PORT=${FRP_SERVER_PORT:-49000}
AUTH_TOKEN=${FRP_AUTH_TOKEN:-CHANGE_ME_TOKEN}
FRP_VERSION=${FRP_VERSION:-latest}
DEFAULT_PROTOCOL=${DEFAULT_PROTOCOL:-ssh}
EOF
    chmod 600 "${CONF_FILE}"
    echo "[√] 已根据环境变量生成配置文件: ${CONF_FILE}"
fi

echo ""
echo "=== 常用命令 ==="
echo "  frpctl config --server frp.example.com --server-port 49000 --token <TOKEN>  # 配置服务端信息"
echo "  frpctl i 40090 -r 节点备注 -t webssh -a admin:StrongPass123                 # 安装 WebSSH + 文件管理器"
echo "  frpctl i 40005 -r 节点备注 -t ssh -l 22                                     # 安装 SSH 隧道"
echo "  frpctl up 40005                                                             # 就地平滑升级实例"
echo "  frpctl rm 40005                                                             # 卸载指定端口实例"
echo "  frpctl ls                                                                   # 查看所有已安装实例"
echo "  frpctl dr                                                                   # 一键环境与连通性体检"
echo ""

# 如果通过 `bash -s -- xxx` 透传了参数，立即执行
if [[ $# -gt 0 ]]; then
    echo "[*] 立即执行：frpctl $*"
    exec "${TARGET}" "$@"
fi
