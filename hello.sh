#!/bin/bash
# ======================================================
# 3x-ui + Reality 一键部署（终极兼容版）
# 系统：Ubuntu / Debian / CentOS 7+
# 用法：sudo bash install.sh
# ======================================================

set -e

# ---------- 固定参数（可修改） ----------
PANEL_PORT="49632"
PANEL_USER="admin"
PANEL_PASS="Ej834950@"
SNI_DOMAIN="xiao06.kdns.fr"
REALITY_PORT="443"
# -----------------------------------------

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}>>> 开始一键部署 3x-ui + Reality ...${NC}"

# 检测系统
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}不支持的系统${NC}" && exit 1
fi

# 安装依赖（包含 jq、ss 等）
install_deps() {
    echo -e "${GREEN}>>> 安装依赖...${NC}"
    case $OS in
        ubuntu|debian)
            apt update -y
            apt install -y curl wget ufw nginx qrencode openssl uuid-runtime jq iproute2
            ;;
        centos|rhel|rocky|almalinux)
            yum install -y curl wget epel-release nginx qrencode openssl util-linux jq iproute
            ;;
        *) echo -e "${RED}不支持的系统${NC}" && exit 1 ;;
    esac
    # 依赖安装完成后生成随机根路径
    WEB_BASE_PATH=$(openssl rand -hex 4)
    export WEB_BASE_PATH
}

# 配置防火墙（只添加规则，不启用）
setup_firewall() {
    echo -e "${GREEN}>>> 配置防火墙规则...${NC}"
    if command -v ufw &> /dev/null; then
        ufw allow $REALITY_PORT/tcp
        ufw allow $PANEL_PORT/tcp
        echo -e "${YELLOW}提示：ufw 规则已添加，如需启用请执行 'ufw enable'（注意先放行SSH）${NC}"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=$REALITY_PORT/tcp
        firewall-cmd --permanent --add-port=$PANEL_PORT/tcp
        firewall-cmd --reload
    else
        echo -e "${YELLOW}未检测到防火墙，请手动放行端口 $REALITY_PORT 和 $PANEL_PORT${NC}"
    fi
}

# 配置伪装网站（Nginx 回落）
setup_nginx() {
    echo -e "${GREEN}>>> 配置伪装网站（Nginx）...${NC}"
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>My Tech Blog</title></head>
<body>
    <h1>Welcome to My Server</h1>
    <p>This is a personal blog about cloud computing and DevOps.</p>
</body>
</html>
HTML

    cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    server {
        listen 127.0.0.1:8080 default_server;
        root /var/www/html;
        index index.html;
        server_name _;
    }
}
EOF
    systemctl restart nginx 2>/dev/null || systemctl start nginx
    systemctl enable nginx
}

# 安装 3x-ui（非交互式）
install_3xui() {
    echo -e "${GREEN}>>> 安装 3x-ui 面板...${NC}"
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF


EOF
    sleep 5
    # 设置面板端口、用户名、密码、根路径
    /usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"
    /usr/local/x-ui/x-ui setting -webBasePath "/$WEB_BASE_PATH"
    systemctl restart x-ui
}

# 配置 Reality 入站（使用 jq 安全构造 JSON）
setup_reality() {
    echo -e "${GREEN}>>> 配置 Reality 入站...${NC}"
    sleep 5  # 等待 Xray 核心完全就绪

    # ---------- 端口占用检查（兼容 ss 缺失的情况） ----------
    PORT_CHECK_CMD=""
    if command -v ss &> /dev/null; then
        PORT_CHECK_CMD="ss -tlnp | grep -q \":${REALITY_PORT} \""
    elif command -v netstat &> /dev/null; then
        PORT_CHECK_CMD="netstat -tlnp | grep -q \":${REALITY_PORT} \""
    else
        echo -e "${YELLOW}警告：未找到 ss 或 netstat，跳过端口检查${NC}"
    fi

    if [[ -n "$PORT_CHECK_CMD" ]] && eval "$PORT_CHECK_CMD"; then
        echo -e "${RED}错误：端口 $REALITY_PORT 已被占用，请修改 REALITY_PORT 或停止占用进程${NC}"
        exit 1
    fi

    # 确定 Xray 二进制路径（仅用于生成密钥）
    if [ -f "/usr/local/x-ui/bin/xray" ]; then
        XRAY_BIN="/usr/local/x-ui/bin/xray"
    elif command -v xray &> /dev/null; then
        XRAY_BIN="xray"
    else
        echo -e "${RED}找不到 xray 核心，请检查 3x-ui 是否安装成功${NC}"
        exit 1
    fi

    # 生成 Reality 密钥对
    KEYPAIR=$($XRAY_BIN x25519)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "Private" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "Public" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    # 生成 UUID
    if command -v uuidgen &> /dev/null; then
        UUID=$(uuidgen)
    else
        UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")
    fi

    # 获取本机 IP
    SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 ip.sb)

    # ---- 使用 jq 构造安全的 JSON ----
    INBOUND_JSON=$(jq -n \
        --arg port "$REALITY_PORT" \
        --arg uuid "$UUID" \
        --arg sni "$SNI_DOMAIN" \
        --arg privateKey "$PRIVATE_KEY" \
        --arg shortId "$SHORT_ID" \
    '{
        protocol: "vless",
        port: ($port | tonumber),
        settings: {
            clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
            decryption: "none"
        },
        streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
                dest: "www.microsoft.com:443",
                serverNames: [$sni],
                privateKey: $privateKey,
                shortIds: [$shortId],
                fallback: {dest: "127.0.0.1:8080"}
            }
        },
        sniffing: {
            enabled: true,
            destOverride: ["http", "tls"]
        }
    }')

    # 导入入站
    /usr/local/x-ui/x-ui addInbound --json "$INBOUND_JSON"

    # 重启面板使配置生效
    systemctl restart x-ui

    # 保存信息到文件
    cat > /root/node_info.txt <<EOF
========================================
【节点链接】（复制到 V2RayN 导入）
vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI_DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#Reality_$SNI_DOMAIN

【面板访问】
http://$SERVER_IP:$PANEL_PORT/$WEB_BASE_PATH
用户名: $PANEL_USER
密码: $PANEL_PASS

【关键参数】
UUID: $UUID
公钥: $PUBLIC_KEY
短ID: $SHORT_ID
========================================
EOF
}

# 输出结果
show_result() {
    SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 ip.sb)
    echo ""
    echo "======================================================"
    echo -e "${GREEN}✅ 部署完成！${NC}"
    echo ""
    echo "【面板访问地址】"
    echo -e "${YELLOW}http://${SERVER_IP}:${PANEL_PORT}/${WEB_BASE_PATH}${NC}"
    echo "用户名: $PANEL_USER"
    echo "密码: $PANEL_PASS"
    echo ""
    echo "【节点链接已保存】cat /root/node_info.txt"
    echo -e "${YELLOW}cat /root/node_info.txt | grep vless://${NC}"
    echo ""
    echo "【伪装验证】浏览器访问 http://${SERVER_IP}:8080 看博客页面"
    echo "======================================================"
}

# ========== 主流程 ==========
main() {
    install_deps
    setup_firewall
    setup_nginx
    install_3xui
    setup_reality
    show_result
}

main