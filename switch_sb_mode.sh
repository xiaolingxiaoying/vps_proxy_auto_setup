#!/bin/bash

# 配置文件路径
SB_CONFIG="/etc/s-box/sb.json"
BACKUP_CONFIG="/etc/s-box/sb.json.bak"
SERVICE_NAME="sing-box" # 请确认你的服务名称，有时可能是 'sing-box.service'

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 root 权限运行此脚本"
  exit 1
fi

# 检查并安装 jq
if ! command -v jq &> /dev/null; then
    echo "未检测到 jq，正在安装..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y jq
    elif [ -f /etc/redhat-release ]; then
        if ! rpm -qa | grep -q epel-release; then
            yum install -y epel-release
        fi
        yum install -y jq
    else
        echo "不支持自动安装。请手动安装 'jq' 后重试。"
        exit 1
    fi
fi

echo "==========================================="
echo " Sing-box 出站策略切换脚本"
echo "==========================================="
echo "1. 模式一：原生 IPv4 (使用物理网卡出站)"
echo "   - 移除 IPv6 优先策略"
echo "   - 移除 WARP 强制 IPv6 规则"
echo ""
echo "2. 模式二：IPv6 优先 (WARP IPv6 可用时优先使用)"
echo "   - 增加 IPv6 解析优先策略"
echo "   - 强制所有 IPv6 流量走 WARP"
echo "==========================================="
read -p "请输入你的选择 [1 或 2]: " choice

# 备份配置函数
backup_config() {
    echo "正在备份配置到 $BACKUP_CONFIG..."
    cp "$SB_CONFIG" "$BACKUP_CONFIG"
}

case "$choice" in
    1)
        echo "正在切换至 [模式一：原生 IPv4]..."
        backup_config
        
        # 逻辑：删除特定的 IPv6 规则
        # 1. 删除全局 prefer_ipv6 策略（检查 domain_suffix 为空以避免删除特定域名的规则）
        # 2. 删除特定的 warp-out 规则（检查 ip_cidr 不为空以避免 jq 报错）
        tmp=$(mktemp)
        jq 'del(.route.rules[] | select(.strategy == "prefer_ipv6" and .domain_suffix == null)) | 
            del(.route.rules[] | select(.outbound == "warp-out" and (.ip_cidr != null) and (.ip_cidr | contains(["::/0"]))))' \
            "$SB_CONFIG" > "$tmp" && mv "$tmp" "$SB_CONFIG"
        
        echo "配置修改已应用。"
        ;;
    2)
        echo "正在切换至 [模式二：IPv6 优先]..."
        backup_config
        
        tmp=$(mktemp)
        # 第一步：清理现有规则以避免重复（同模式一）
        # 增加了 ip_cidr != null 检查
        jq 'del(.route.rules[] | select(.strategy == "prefer_ipv6" and .domain_suffix == null)) | 
            del(.route.rules[] | select(.outbound == "warp-out" and (.ip_cidr != null) and (.ip_cidr | contains(["::/0"]))))' \
            "$SB_CONFIG" > "$tmp"
            
        # 第二步：在第一条规则之后插入新规则（假设索引 0 是 sniff 或类似的基础规则）
        # 我们插入：1. 全局 IPv6 优先策略 2. 路由 ::/0 到 warp-out
        jq '.route.rules |= [.[0]] + [
            {
                "action": "resolve",
                "strategy": "prefer_ipv6"
            },
            {
                "ip_cidr": ["::/0"],
                "outbound": "warp-out"
            }
        ] + .[1:]' "$tmp" > "$SB_CONFIG"
        rm -f "$tmp"
        
        echo "配置修改已应用。"
        ;;
    *)
        echo "无效的选择。退出。"
        exit 1
        ;;
esac

# 重启服务
echo "正在重启 $SERVICE_NAME..."
if systemctl restart "$SERVICE_NAME"; then
    echo "成功！服务已重启。"
    systemctl status "$SERVICE_NAME" --no-pager | grep "Active:"
else
    echo "错误：服务重启失败。请检查配置。"
    echo "正在恢复备份..."
    cp "$BACKUP_CONFIG" "$SB_CONFIG"
    systemctl restart "$SERVICE_NAME"
    echo "已恢复到修改前的配置。"
fi
