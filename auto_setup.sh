#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# VPS 流量统计与订阅管理 自动配置脚本
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xiaolingxiaoying/vps-sub-meter/main/auto_setup.sh)
#
# 功能:
#   - 通过 vnstat + sysfs 实时监控 VPS 出口流量
#   - Python HTTP 服务下发带 subscription-userinfo 的订阅 (YAML + JSON)
#   - 同时支持 Clash Meta (YAML) 和 sing-box (JSON) 订阅格式
#   - Caddy 反向代理提供 HTTPS + Basic Auth 鉴权
#   - 支持 ?token= 参数免密访问 (给 CMFA 等不支持 BasicAuth 的客户端)
#   - 每月自动重置流量基线
#   - 每 5 分钟同步上游订阅配置
# ==============================================================================

# 配置文件路径
CONFIG_FILE="/etc/sub-srv/config.conf"

# 0. 确保交互式输入可用 (兼容 bash <(curl ...) 方式)
if [ ! -t 0 ]; then
    exec < /dev/tty
fi

# 1. 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo "错误: 请使用 root 权限运行此脚本 (例如: sudo bash <(curl -fsSL URL))"
    exit 1
fi

# 2. 检查系统兼容性
if ! command -v apt &>/dev/null; then
    echo "错误: 此脚本仅支持 Debian/Ubuntu 系统 (需要 apt 包管理器)"
    exit 1
fi

# ===================== 输入验证函数 =====================

# 验证域名格式 (支持 IDN 和常见域名)
validate_domain() {
    local domain="$1"
    # 基本格式检查：至少有一个点，不包含非法字符
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    # 长度检查
    if [ ${#domain} -gt 253 ]; then
        return 1
    fi
    return 0
}

# 验证用户名 (BasicAuth 用户名限制)
validate_username() {
    local username="$1"
    # BasicAuth 用户名不能包含冒号，且不应包含空格和特殊字符
    if [[ "$username" =~ [:[:space:]] ]]; then
        return 1
    fi
    if [ ${#username} -gt 64 ]; then
        return 1
    fi
    return 0
}

# 验证流量上限 (必须是有效数字)
validate_traffic_limit() {
    local limit="$1"
    if [ -z "$limit" ]; then
        return 0  # 空值表示无限，允许
    fi
    # 必须是非负整数或浮点数
    if [[ ! "$limit" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return 1
    fi
    return 0
}

# 检查端口是否被占用
check_port_available() {
    local port="$1"
    # 使用更精确的正则表达式避免误匹配 (例如 2080 匹配到 12080)
    if ss -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" || \
       netstat -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
        return 1
    fi
    return 0
}

# 保存配置到文件
save_config() {
    local config_dir
    config_dir=$(dirname "$CONFIG_FILE")
    mkdir -p "$config_dir"
    chmod 700 "$config_dir"

    cat > "$CONFIG_FILE" <<EOF
# VPS 订阅服务配置文件
# 生成时间: $(date -Iseconds)

DOMAIN="${DOMAIN}"
CADDY_USER="${CADDY_USER}"
CADDY_PASS_HASH="${PASSWORD_HASH:-}"
TRAFFIC_LIMIT_GIB="${TRAFFIC_LIMIT_GIB}"
TZ_NAME="${TZ_NAME}"
IFACE="${IFACE}"
TOKEN="${TOKEN}"
BACKEND_PORT="${BACKEND_PORT:-2080}"
EOF
    chmod 600 "$CONFIG_FILE"
    echo "=> 配置已保存到 $CONFIG_FILE"
}

# 加载已有配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "检测到已有配置文件: $CONFIG_FILE"
        read -rp "是否加载已有配置? [Y/n]: " load_choice
        load_choice=${load_choice:-Y}
        if [[ "$load_choice" =~ ^[Yy] ]]; then
            # 临时禁用 unset 变量检查以加载配置文件
            set +u
            # shellcheck source=/dev/null
            if ! source "$CONFIG_FILE" 2>/dev/null; then
                echo "警告: 配置文件损坏，将使用默认配置"
                set -u
                return 1
            fi
            set -u
            echo "=> 已加载配置: 域名=${DOMAIN:-未设置}, 用户=${CADDY_USER:-未设置}, 网卡=${IFACE:-未设置}"
            return 0
        fi
    fi
    return 1
}

echo "=================================================="
echo "      VPS 流量统计与订阅管理 - 自动配置向导       "
echo "=================================================="

# 尝试加载已有配置
if load_config; then
    echo "(已加载配置，如需修改请直接输入新值，留空保持原值)"
else
    echo "(如果已运行过此脚本，再次运行将覆盖旧配置)"
fi
echo ""

# 3. 交互式收集配置信息
# 域名输入与验证
while true; do
    if [ -n "${DOMAIN:-}" ]; then
        read -rp "请输入绑定的域名 [当前: $DOMAIN]: " input_domain
        if [ -z "$input_domain" ]; then
            break  # 保持原值
        fi
        DOMAIN="$input_domain"
    else
        read -rp "请输入绑定的域名 (例如: sub.example.com): " DOMAIN
    fi

    if [ -z "$DOMAIN" ]; then
        echo "错误: 域名不能为空"
        continue
    fi

    if ! validate_domain "$DOMAIN"; then
        echo "错误: 域名格式无效 '$DOMAIN'"
        echo "       请使用类似 sub.example.com 的格式"
        DOMAIN=""
        continue
    fi
    break
done

# 用户名输入与验证
while true; do
    if [ -n "${CADDY_USER:-}" ]; then
        read -rp "请输入访问用户名 (用于 BasicAuth) [当前: $CADDY_USER]: " input_user
        if [ -z "$input_user" ]; then
            break  # 保持原值
        fi
        CADDY_USER="$input_user"
    else
        read -rp "请输入访问用户名 (用于 BasicAuth): " CADDY_USER
    fi

    if [ -z "$CADDY_USER" ]; then
        echo "错误: 用户名不能为空"
        continue
    fi

    if ! validate_username "$CADDY_USER"; then
        echo "错误: 用户名包含非法字符 (不能包含冒号或空格)"
        echo "       请使用字母、数字、下划线或短横线"
        CADDY_USER=""
        continue
    fi
    break
done

# URL 编码函数 (安全传递任意字符到 python3，使用 stdin 避免引号/特殊字符问题)
urlencode() {
    printf '%s' "$1" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.buffer.read().decode(), safe=''), end='')"
}

# 密码输入与验证
NEED_NEW_PASSWORD=true
SAVED_PASSWORD_MODE=false
if [ -n "${CADDY_PASS_HASH:-}" ]; then
    echo "检测到已保存的密码 (哈希值: ${CADDY_PASS_HASH:0:20}...)"
    read -rp "是否使用已保存的密码? [Y/n]: " use_saved
    use_saved=${use_saved:-Y}
    if [[ "$use_saved" =~ ^[Yy] ]]; then
        NEED_NEW_PASSWORD=false
        PASSWORD_HASH="$CADDY_PASS_HASH"
        CADDY_PASS="<已保存的密码>"
        SAVED_PASSWORD_MODE=true
        echo "=> 将使用已保存的密码"
    fi
fi

if [ "$NEED_NEW_PASSWORD" = true ]; then
    while true; do
        read -rs -p "请输入访问密码 (用于 BasicAuth，支持特殊字符): " CADDY_PASS
        echo
        if [ -z "$CADDY_PASS" ]; then
            echo "错误: 密码不能为空，请重新输入"
            continue
        fi
        # 检查密码中是否含 URL 不安全字符，提示但不阻止
        if [[ "$CADDY_PASS" =~ [@:/] ]]; then
            echo "提示: 密码中包含特殊字符，一键导入链接将自动进行 URL 编码处理。"
        fi
        break
    done
fi

# 流量上限输入与验证
while true; do
    if [ -n "${TRAFFIC_LIMIT_GIB:-}" ]; then
        read -rp "请输入每月流量上限 (GiB，0 或留空表示无限) [当前: $TRAFFIC_LIMIT_GIB]: " input_limit
        if [ -z "$input_limit" ]; then
            break  # 保持原值
        fi
        TRAFFIC_LIMIT_GIB="$input_limit"
    else
        read -rp "请输入每月流量上限 (GiB，0 或留空表示无限，默认 0): " TRAFFIC_LIMIT_GIB
    fi

    TRAFFIC_LIMIT_GIB=${TRAFFIC_LIMIT_GIB:-0}

    if ! validate_traffic_limit "$TRAFFIC_LIMIT_GIB"; then
        echo "错误: 流量上限必须是有效的数字"
        TRAFFIC_LIMIT_GIB=""
        continue
    fi
    break
done

# 时区输入与验证
while true; do
    if [ -n "${TZ_NAME:-}" ]; then
        read -rp "请输入计费时区 [当前: $TZ_NAME]: " input_tz
        if [ -z "$input_tz" ]; then
            break  # 保持原值
        fi
        TZ_NAME="$input_tz"
    else
        read -rp "请输入计费时区 (默认 America/Los_Angeles): " TZ_NAME
    fi

    TZ_NAME=${TZ_NAME:-America/Los_Angeles}

    # 验证时区合法性
    if [ ! -f "/usr/share/zoneinfo/$TZ_NAME" ]; then
        echo "错误: 无效的时区 '$TZ_NAME'，请使用类似 America/Los_Angeles 的格式"
        echo "       可用时区列表: ls /usr/share/zoneinfo/"
        TZ_NAME=""
        continue
    fi
    break
done

# 自动获取默认网卡
DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -z "$DEFAULT_IFACE" ]; then
    # 备选方案：获取第一个非 lo 网卡
    DEFAULT_IFACE=$(ip link show | grep -v "lo:" | awk -F: '/^[0-9]+:/{gsub(/ /, "", $2); print $2; exit}')
fi

# 网卡输入与验证
while true; do
    if [ -n "${IFACE:-}" ]; then
        read -rp "请确认出口网卡名称 [当前: $IFACE]: " input_iface
        if [ -z "$input_iface" ]; then
            break  # 保持原值
        fi
        IFACE="$input_iface"
    else
        if [ -n "$DEFAULT_IFACE" ]; then
            read -rp "请确认出口网卡名称 [默认: $DEFAULT_IFACE]: " IFACE
            IFACE=${IFACE:-$DEFAULT_IFACE}
        else
            read -rp "请输入出口网卡名称 (例如: eth0, ens4): " IFACE
        fi
    fi

    if [ -z "$IFACE" ]; then
        echo "错误: 网卡名称不能为空"
        IFACE=""
        continue
    fi

    # 验证网卡存在
    if [ ! -d "/sys/class/net/$IFACE" ]; then
        echo "错误: 网卡 $IFACE 不存在"
        echo "       可用网卡列表: $(ls /sys/class/net/ | tr '\n' ' ')"
        IFACE=""
        continue
    fi
    break
done

# 后端端口输入与验证 (默认 2080)
BACKEND_PORT="${BACKEND_PORT:-2080}"
while true; do
    read -rp "请输入后端服务端口 [默认: $BACKEND_PORT]: " input_port
    if [ -z "$input_port" ]; then
        break
    fi

    # 验证端口号
    if [[ ! "$input_port" =~ ^[0-9]+$ ]] || [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
        echo "错误: 端口号必须是 1-65535 之间的整数"
        continue
    fi

    BACKEND_PORT="$input_port"
    break
done

# 检查端口是否被占用 (排除自身 sub-server 服务)
if ! check_port_available "$BACKEND_PORT"; then
    # 检查是否是 sub-server 自身在占用
    PORT_OWNER=$(ss -tlnp 2>/dev/null | grep -E "[:.]${BACKEND_PORT}[[:space:]]" | grep -oP 'users:\(\("\K[^"]+' || true)
    if [ "$PORT_OWNER" = "sub_server.py" ] || [ "$PORT_OWNER" = "python3" ]; then
        echo "=> 端口 $BACKEND_PORT 被 sub-server 服务占用 (重新部署将自动重启)"
    else
        echo "警告: 端口 $BACKEND_PORT 已被其他进程占用 (${PORT_OWNER:-未知})"
        read -rp "是否继续使用此端口? [y/N]: " continue_port
        if [[ ! "$continue_port" =~ ^[Yy] ]]; then
            echo "已取消安装"
            exit 1
        fi
    fi
fi

# 生成随机 Token (如果未从配置文件加载)
if [ -z "${TOKEN:-}" ]; then
    TOKEN="$(openssl rand -hex 24 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 48)"
fi
echo
echo "=> 安全访问 Token: $TOKEN"
echo "=================================================="

# ===================== 配置摘要与确认 =====================
echo ""
echo "========== 配置摘要 =========="
echo "域名:       $DOMAIN"
echo "用户名:     $CADDY_USER"
echo "密码:       $([ "$CADDY_PASS" = "<已保存的密码>" ] && echo "<已保存>" || echo "${CADDY_PASS:0:3}***")"
echo "流量上限:   $TRAFFIC_LIMIT_GIB GiB"
echo "时区:       $TZ_NAME"
echo "网卡:       $IFACE"
echo "后端端口:   $BACKEND_PORT"
echo "Token:      ${TOKEN:0:12}...${TOKEN: -12}"
echo "=============================="
echo ""
read -rp "确认开始安装? [Y/n]: " confirm
confirm=${confirm:-Y}
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "已取消安装"
    exit 0
fi
echo ""

# ===================== 开始安装 =====================

echo "[1/8] 安装基础依赖 (vnstat, python3, curl, openssl)..."
apt-get update -qq
apt-get install -y -qq vnstat python3 curl jq openssl debian-keyring debian-archive-keyring apt-transport-https gpg

echo "[2/8] 安装 Caddy (通过官方 APT 仓库)..."
# 使用 Caddy 官方 APT 仓库，确保稳定可靠
if ! command -v caddy &>/dev/null; then
    # 幂等处理：先删除旧 key 再导入，避免重复运行报错
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq caddy
else
    echo "=> Caddy 已安装，跳过 (当前版本: $(caddy version))"
fi

# 启动基础服务
echo "=> 启动 vnstat 和 Caddy 服务..."
systemctl enable --now vnstat
systemctl enable --now caddy

# 保存配置到文件
echo "=> 保存配置到 $CONFIG_FILE ..."
save_config

echo "[3/8] 配置 vnStat 监控网卡与时区..."
# 只在 Interface 行存在时替换，否则追加
if grep -q '^Interface ' /etc/vnstat.conf 2>/dev/null; then
    sed -i "s/^Interface .*/Interface \"$IFACE\"/" /etc/vnstat.conf
else
    echo "Interface \"$IFACE\"" >> /etc/vnstat.conf
fi
mkdir -p /etc/systemd/system/vnstat.service.d
cat > /etc/systemd/system/vnstat.service.d/override.conf <<EOF
[Service]
Environment=TZ=$TZ_NAME
EOF
systemctl daemon-reload
systemctl restart vnstat

echo "[4/8] 创建隔离的服务用户和目录..."
id subsrv &>/dev/null || useradd -r -s /usr/sbin/nologin subsrv
mkdir -p /var/lib/subsrv
chown subsrv:subsrv /var/lib/subsrv
chmod 750 /var/lib/subsrv

# 初始化订阅配置副本 — Clash Meta (YAML)
if [ -f /etc/s-box/clash_meta_client.yaml ]; then
    cp -f /etc/s-box/clash_meta_client.yaml /var/lib/subsrv/client.yaml
else
    echo "# 暂无订阅内容，等待 yonggekkk 脚本生成" > /var/lib/subsrv/client.yaml
    echo "=> 警告: /etc/s-box/clash_meta_client.yaml 不存在，已创建默认空配置"
fi
chown subsrv:subsrv /var/lib/subsrv/client.yaml
chmod 640 /var/lib/subsrv/client.yaml

# 初始化订阅配置副本 — sing-box (JSON)
if [ -f /etc/s-box/sing_box_client.json ]; then
    cp -f /etc/s-box/sing_box_client.json /var/lib/subsrv/client.json
else
    echo '{"log":{"level":"warn"},"dns":{},"inbounds":[],"outbounds":[]}' > /var/lib/subsrv/client.json
    echo "=> 警告: /etc/s-box/sing_box_client.json 不存在，已创建默认空配置"
fi
chown subsrv:subsrv /var/lib/subsrv/client.json
chmod 640 /var/lib/subsrv/client.json

# 初始化流量状态文件
touch /var/lib/subsrv/tx_state.json
chown subsrv:subsrv /var/lib/subsrv/tx_state.json
chmod 640 /var/lib/subsrv/tx_state.json

echo "[5/8] 配置配置文件定时同步 (每 5 分钟)..."
cat > /usr/local/bin/refresh_sub_copy.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# 同步 Clash Meta 配置 (YAML)
SRC_YAML="/etc/s-box/clash_meta_client.yaml"
DST_YAML="/var/lib/subsrv/client.yaml"
if [ -f "$SRC_YAML" ]; then
    TMP_YAML="/var/lib/subsrv/client.yaml.tmp"
    cp -f "$SRC_YAML" "$TMP_YAML"
    chown subsrv:subsrv "$TMP_YAML"
    chmod 640 "$TMP_YAML"
    mv -f "$TMP_YAML" "$DST_YAML"
fi

# 同步 sing-box 配置 (JSON)
SRC_JSON="/etc/s-box/sing_box_client.json"
DST_JSON="/var/lib/subsrv/client.json"
if [ -f "$SRC_JSON" ]; then
    TMP_JSON="/var/lib/subsrv/client.json.tmp"
    cp -f "$SRC_JSON" "$TMP_JSON"
    chown subsrv:subsrv "$TMP_JSON"
    chmod 640 "$TMP_JSON"
    mv -f "$TMP_JSON" "$DST_JSON"
fi
SH
chmod +x /usr/local/bin/refresh_sub_copy.sh

cat > /etc/systemd/system/refresh-sub-copy.service <<'UNIT'
[Unit]
Description=Refresh served subscription copy
[Service]
Type=oneshot
ExecStart=/usr/local/bin/refresh_sub_copy.sh
UNIT

cat > /etc/systemd/system/refresh-sub-copy.timer <<'UNIT'
[Unit]
Description=Run refresh-sub-copy every 5 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UNIT

echo "[6/8] 配置流量基线重置机制..."
# 使用 printf 代替嵌套 heredoc，避免 heredoc 标记冲突
cat > /usr/local/bin/reset_tx_baseline.sh <<SH
#!/usr/bin/env bash
set -euo pipefail
IFACE="\${1:-$IFACE}"
STATE="/var/lib/subsrv/tx_state.json"
TZNAME="$TZ_NAME"

now_ym="\$(TZ=\$TZNAME date +%Y-%m)"
tx="\$(cat /sys/class/net/"\$IFACE"/statistics/tx_bytes 2>/dev/null || echo 0)"

tmp="\$(mktemp)"
printf '{"ym":"%s","base_tx":%s}\n' "\$now_ym" "\$tx" > "\$tmp"
install -o subsrv -g subsrv -m 640 "\$tmp" "\$STATE"
rm -f "\$tmp"
echo "[reset_tx_baseline] \$(date -Is) IFACE=\$IFACE ym=\$now_ym base_tx=\$tx wrote=\$STATE"
SH
chmod +x /usr/local/bin/reset_tx_baseline.sh
/usr/local/bin/reset_tx_baseline.sh "$IFACE"

# 设置系统时区以确保 systemd timer 在正确时间触发
echo "=> 设置系统时区为 $TZ_NAME (确保 Timer 在正确时间触发)..."
timedatectl set-timezone "$TZ_NAME" 2>/dev/null || {
    ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
    echo "$TZ_NAME" > /etc/timezone
}

cat > /etc/systemd/system/reset-tx-baseline.service <<UNIT
[Unit]
Description=Reset monthly tx baseline
[Service]
Type=oneshot
Environment=TZ=$TZ_NAME
ExecStart=/usr/local/bin/reset_tx_baseline.sh $IFACE
UNIT

cat > /etc/systemd/system/reset-tx-baseline.timer <<'UNIT'
[Unit]
Description=Run reset-tx-baseline at 00:00 on day 1 each month
[Timer]
OnCalendar=*-*-01 00:00:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT

echo "[7/8] 编写并启动动态订阅服务端 (Python)..."
cat > /usr/local/bin/sub_server.py <<'PY'
#!/usr/bin/env python3
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
from datetime import datetime, timezone

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

def log(msg):
    ts = datetime.now(timezone.utc).isoformat()
    print(f"[sub_server] {ts} {msg}", flush=True)

IFACE      = os.environ.get("SUB_IFACE",      "ens4")
YAML_TOKEN_PATH = os.environ.get("SUB_TOKEN_PATH",  "/sub/token.yaml")
JSON_TOKEN_PATH = os.environ.get("SUB_JSON_TOKEN_PATH", "/sub/token.json")
YAML_PATH  = os.environ.get("SUB_YAML_PATH",   "/var/lib/subsrv/client.yaml")
JSON_PATH  = os.environ.get("SUB_JSON_PATH",   "/var/lib/subsrv/client.json")
LIMIT_GIB  = float(os.environ.get("SUB_LIMIT_GIB", "0"))
TZ_NAME    = os.environ.get("SUB_TZ",          "America/Los_Angeles")
STATE_PATH = os.environ.get("SUB_STATE_PATH",  "/var/lib/subsrv/tx_state.json")

# 0 表示无限流量，用 1 TiB 作为显示值 (客户端会显示几乎用不完的额度)
if LIMIT_GIB <= 0:
    TOTAL_BYTES = int(1024 * 1024 * 1024 * 1024)  # 1 TiB
else:
    TOTAL_BYTES = int(LIMIT_GIB * 1024 * 1024 * 1024)

# 路径 -> (文件路径, Content-Type) 的映射表
ROUTE_MAP = {
    YAML_TOKEN_PATH: (YAML_PATH, "text/yaml; charset=utf-8"),
    JSON_TOKEN_PATH: (JSON_PATH, "application/json; charset=utf-8"),
}

def pt_now():
    if ZoneInfo:
        return datetime.now(ZoneInfo(TZ_NAME))
    return datetime.now(timezone.utc)

def current_ym_pt():
    now = pt_now()
    return f"{now.year:04d}-{now.month:02d}"

def next_reset_epoch_pt():
    now = pt_now()
    y, m = now.year, now.month
    if m == 12:
        y2, m2 = y + 1, 1
    else:
        y2, m2 = y, m + 1
    if ZoneInfo:
        dt = datetime(y2, m2, 1, 0, 0, 0, tzinfo=ZoneInfo(TZ_NAME))
    else:
        dt = datetime(y2, m2, 1, 0, 0, 0, tzinfo=timezone.utc)
    return int(dt.timestamp())

def read_tx_bytes_sysfs():
    p = f"/sys/class/net/{IFACE}/statistics/tx_bytes"
    try:
        with open(p, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        log(f"WARN: cannot read {p}: {e}")
        return 0

def load_state():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def save_state(ym, base_tx):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"ym": ym, "base_tx": int(base_tx)}, f, separators=(",", ":"))
    os.replace(tmp, STATE_PATH)

def month_used_tx_bytes_realtime():
    ym = current_ym_pt()
    cur = read_tx_bytes_sysfs()
    st = load_state()
    st_ym = st.get("ym")
    base = st.get("base_tx")

    if st_ym != ym or base is None:
        save_state(ym, cur)
        log(f"state reset: ym={ym} base_tx={cur} (reason: missing or month changed)")
        return 0, cur, cur

    used = cur - int(base)
    if used < 0:
        save_state(ym, cur)
        log(f"state reset: ym={ym} base_tx={cur} (reason: counter wrapped)")
        return 0, cur, cur

    return int(used), int(base), int(cur)

class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self._head_only = True
        return self.do_GET()

    def do_GET(self):
        self._head_only = getattr(self, "_head_only", False)
        path = urlparse(self.path).path
        log(f"{'HEAD' if self._head_only else 'GET'} {path} from {self.client_address[0]}")

        # 查找路由
        route = ROUTE_MAP.get(path)
        if route is None:
            self.send_response(404)
            self.end_headers()
            return

        file_path, content_type = route

        try:
            used_tx, base_tx, cur_tx = month_used_tx_bytes_realtime()
        except Exception as e:
            log(f"ERROR reading tx_bytes: {e}")
            used_tx, base_tx, cur_tx = 0, 0, 0

        expire = next_reset_epoch_pt()
        remain = max(TOTAL_BYTES - used_tx, 0)

        try:
            with open(file_path, "rb") as f:
                body = f.read()
            log(f"read ok: {file_path} bytes={len(body)}")
        except Exception as e:
            log(f"ERROR read file: {e}")
            if content_type.startswith("application/json"):
                body = b'{"error":"subscription source missing"}\n'
            else:
                body = b"# subscription source missing\n"

        header_val = f"upload=0; download={used_tx}; total={TOTAL_BYTES}; expire={expire}"
        log(f"userinfo: used_tx={used_tx} remain={remain} ym={current_ym_pt()} base_tx={base_tx} cur_tx={cur_tx}")

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.send_header("subscription-userinfo", header_val)
        self.end_headers()

        if not self._head_only:
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

def main():
    host = os.environ.get("SUB_LISTEN", "127.0.0.1")
    port = int(os.environ.get("SUB_PORT", "2080"))
    log(f"start listen={host}:{port} iface={IFACE} tz={TZ_NAME}")
    log(f"  yaml: {YAML_TOKEN_PATH} -> {YAML_PATH}")
    log(f"  json: {JSON_TOKEN_PATH} -> {JSON_PATH}")
    log(f"  state={STATE_PATH}")
    HTTPServer((host, port), Handler).serve_forever()

if __name__ == "__main__":
    main()
PY
chmod +x /usr/local/bin/sub_server.py

cat > /etc/systemd/system/sub-server.service <<UNIT
[Unit]
Description=Dynamic subscription server with subscription-userinfo
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
User=subsrv
Group=subsrv
Environment=SUB_IFACE=$IFACE
Environment=SUB_TOKEN_PATH=/sub/$TOKEN.yaml
Environment=SUB_JSON_TOKEN_PATH=/sub/$TOKEN.json
Environment=SUB_YAML_PATH=/var/lib/subsrv/client.yaml
Environment=SUB_JSON_PATH=/var/lib/subsrv/client.json
Environment=SUB_LIMIT_GIB=$TRAFFIC_LIMIT_GIB
Environment=SUB_TZ=$TZ_NAME
Environment=SUB_STATE_PATH=/var/lib/subsrv/tx_state.json
Environment=SUB_LISTEN=127.0.0.1
Environment=SUB_PORT=$BACKEND_PORT
ExecStart=/usr/local/bin/sub_server.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now refresh-sub-copy.timer
systemctl enable --now reset-tx-baseline.timer
# 使用 restart 而非 start，确保覆盖部署时环境变量生效
systemctl enable sub-server
systemctl restart sub-server

echo "[8/8] 配置 Caddy (反向代理与鉴权)..."
# 生成密码哈希 (如果是新密码)
if [ "$NEED_NEW_PASSWORD" = true ]; then
    PASSWORD_HASH=$(caddy hash-password --plaintext "$CADDY_PASS" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$PASSWORD_HASH" ]; then
        echo "错误: caddy hash-password 生成失败，请检查 Caddy 是否正确安装"
        exit 1
    fi
    # 更新配置文件中的密码哈希
    echo "=> 更新配置文件中的密码哈希..."
    save_config
else
    echo "=> 使用已保存的密码哈希: ${PASSWORD_HASH:0:20}..."
fi

# 备份旧配置
cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%F_%H%M%S)" 2>/dev/null || true

# ==========================================
# Caddyfile 使用 handle 块实现互斥路由
# ==========================================
# Caddy 的指令优先级规则: 同级别的 respond / reverse_proxy / basic_auth
# 不保证按书写顺序执行。使用 handle 块可以创建互斥的路由分组:
#   - handle @matcher1 { ... }  优先匹配
#   - handle @matcher2 { ... }  次优先
#   - handle { ... }            兜底 (其他所有请求)
#
# 路由策略:
#   1. ?token=TOKEN 参数访问 -> 免 BasicAuth (给 CMFA 等客户端)
#   2. 精确路径访问 -> 需要 BasicAuth (给 Clash Party / 浏览器)
#   3. 其他所有请求 -> 404
# ==========================================
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
	# 订阅文件的精确路径 (Clash Meta YAML + sing-box JSON)
	@sub_path {
		path /sub/$TOKEN.yaml /sub/$TOKEN.json
	}

	# token 参数免密访问 (给 CMFA / SFA 等不支持 BasicAuth 的客户端)
	@sub_with_token {
		path /sub/$TOKEN.yaml /sub/$TOKEN.json
		query token=$TOKEN
	}

	# 1) token 参数优先：不需要 BasicAuth
	handle @sub_with_token {
		reverse_proxy 127.0.0.1:$BACKEND_PORT
	}

	# 2) 精确路径匹配：需要 BasicAuth
	handle @sub_path {
		basic_auth {
			$CADDY_USER $PASSWORD_HASH
		}
		reverse_proxy 127.0.0.1:$BACKEND_PORT
	}

	# 3) 其他路径全部 404
	handle {
		respond "not found" 404
	}
}
EOF

caddy fmt --overwrite /etc/caddy/Caddyfile

# 先验证配置是否合法，再应用
if caddy validate --config /etc/caddy/Caddyfile; then
    # 使用 restart 而非 reload：首次部署时 Caddy 可能还在用默认配置，
    # reload 有时不能正确切换到新域名的 TLS 证书申请
    systemctl restart caddy
    echo "=> Caddy 配置验证通过并已重启"
else
    echo "错误: Caddyfile 验证失败，请手动检查 /etc/caddy/Caddyfile"
    echo "Caddy 仍在使用旧配置运行"
    exit 1
fi

# 等待 Caddy 启动就绪
sleep 2

# ===================== 部署验证 =====================
echo ""
echo "=> 正在验证本地服务..."

# 验证 Python 后端是否响应
if curl -sf -o /dev/null "http://127.0.0.1:$BACKEND_PORT/sub/$TOKEN.yaml"; then
    echo "   [OK] Python 订阅服务正常响应 (Clash Meta YAML)"
else
    echo "   [WARN] Python 订阅服务未响应 (YAML)，请检查: journalctl -u sub-server -n 40"
fi

if curl -sf -o /dev/null "http://127.0.0.1:$BACKEND_PORT/sub/$TOKEN.json"; then
    echo "   [OK] Python 订阅服务正常响应 (sing-box JSON)"
else
    echo "   [WARN] Python 订阅服务未响应 (JSON)，请检查: journalctl -u sub-server -n 40"
fi

# 验证 Caddy 是否正常转发 (通过 token 参数)
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "https://$DOMAIN/sub/$TOKEN.yaml?token=$TOKEN" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "   [OK] Caddy HTTPS 转发正常 (token 免密访问)"
elif [ "$HTTP_CODE" = "000" ]; then
    echo "   [INFO] HTTPS 验证跳过 (证书可能还在申请中，稍后自动生效)"
else
    echo "   [WARN] Caddy 返回 HTTP $HTTP_CODE，请检查: journalctl -u caddy -n 40"
fi

# ===================== 输出部署信息 =====================
# 只有新密码才编码显示，已保存的密码不显示明文
if [ "$NEED_NEW_PASSWORD" = true ]; then
    ENCODED_USER=$(urlencode "$CADDY_USER")
    ENCODED_PASS=$(urlencode "$CADDY_PASS")
    SHOW_PASSWORD="$CADDY_PASS"
    SHOW_ONE_CLICK=true
else
    ENCODED_USER=""
    ENCODED_PASS=""
    SHOW_PASSWORD="<已保存的密码，如需查看请重新配置>"
    SHOW_ONE_CLICK=false
fi

echo ""
echo "=================================================="
echo "                   部署完成!                      "
echo "=================================================="
echo ""
echo "============= Clash Meta (YAML) 订阅 ============="
echo ""
echo "--- 方式一: BasicAuth 认证访问 (Clash Party / Stash) ---"
echo ""
echo "  订阅地址: https://$DOMAIN/sub/$TOKEN.yaml"
echo "  认证方式: Basic Auth"
echo "  用户名:   $CADDY_USER"
echo "  密码:     $SHOW_PASSWORD"
echo ""
if [ "$SHOW_ONE_CLICK" = true ]; then
    echo "  一键导入链接 (已自动 URL 编码):"
    echo "  https://${ENCODED_USER}:${ENCODED_PASS}@${DOMAIN}/sub/${TOKEN}.yaml"
else
    echo "  一键导入链接:"
    echo "  https://<用户名>:<密码>@${DOMAIN}/sub/${TOKEN}.yaml"
    echo "  (请手动替换 <用户名> 和 <密码>)"
fi
echo ""
echo "--- 方式二: Token 免密访问 (CMFA / 不支持 BasicAuth 的客户端) ---"
echo ""
echo "  https://${DOMAIN}/sub/${TOKEN}.yaml?token=${TOKEN}"
echo ""
echo "============= sing-box (JSON) 订阅 ============="
echo ""
echo "--- 方式一: BasicAuth 认证访问 ---"
echo ""
echo "  订阅地址: https://$DOMAIN/sub/$TOKEN.json"
echo "  认证方式: Basic Auth"
echo "  用户名:   $CADDY_USER"
echo "  密码:     $SHOW_PASSWORD"
echo ""
if [ "$SHOW_ONE_CLICK" = true ]; then
    echo "  一键导入链接 (已自动 URL 编码):"
    echo "  https://${ENCODED_USER}:${ENCODED_PASS}@${DOMAIN}/sub/${TOKEN}.json"
else
    echo "  一键导入链接:"
    echo "  https://<用户名>:<密码>@${DOMAIN}/sub/${TOKEN}.json"
    echo "  (请手动替换 <用户名> 和 <密码>)"
fi
echo ""
echo "--- 方式二: Token 免密访问 (SFA / SFI / SFM 等 sing-box 客户端) ---"
echo ""
echo "  https://${DOMAIN}/sub/${TOKEN}.json?token=${TOKEN}"
echo ""
echo "=================================================="
echo ""
echo "服务状态:"
echo "  systemctl status sub-server caddy"
echo "  systemctl list-timers --all | grep -E 'refresh|reset'"
echo ""
echo "常用排查命令:"
echo "  journalctl -u sub-server -n 80 --no-pager"
echo "  journalctl -u caddy -n 80 --no-pager"
echo ""
echo "测试命令 (Clash Meta YAML - BasicAuth):"
if [ "$SHOW_ONE_CLICK" = true ]; then
    echo "  curl -sD - -u '${CADDY_USER}:${CADDY_PASS}' 'https://${DOMAIN}/sub/${TOKEN}.yaml' -o /dev/null | head -20"
else
    echo "  curl -sD - -u '<用户名>:<密码>' 'https://${DOMAIN}/sub/${TOKEN}.yaml' -o /dev/null | head -20"
fi
echo ""
echo "测试命令 (Clash Meta YAML - Token 免密):"
echo "  curl -sD - 'https://${DOMAIN}/sub/${TOKEN}.yaml?token=${TOKEN}' -o /dev/null | head -20"
echo ""
echo "测试命令 (sing-box JSON - BasicAuth):"
if [ "$SHOW_ONE_CLICK" = true ]; then
    echo "  curl -sD - -u '${CADDY_USER}:${CADDY_PASS}' 'https://${DOMAIN}/sub/${TOKEN}.json' -o /dev/null | head -20"
else
    echo "  curl -sD - -u '<用户名>:<密码>' 'https://${DOMAIN}/sub/${TOKEN}.json' -o /dev/null | head -20"
fi
echo ""
echo "测试命令 (sing-box JSON - Token 免密):"
echo "  curl -sD - 'https://${DOMAIN}/sub/${TOKEN}.json?token=${TOKEN}' -o /dev/null | head -20"
echo ""
