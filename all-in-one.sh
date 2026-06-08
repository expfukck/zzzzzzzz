#!/bin/bash
# ============================================================
# 超级一键部署脚本（Ubuntu/Debian） - 增强版 v3.0
# 功能：
#   1. Nginx HTTPS 网站（自定义静态目录 / 任意反向代理）
#   2. Apache WebDAV 文件服务器
#   DNS 修复（可选），新手友好
# 修复：
#   - Listen 指令位置修正（解决 Cannot define multiple Listeners）
#   - 移除 set -e 与交互冲突
#   - 兼容 Debian/Ubuntu 双系统
#   - 输入校验、端口冲突检测
#   - 配置自动备份
#   - 改进 DNS 修复方式（不再破坏 systemd-resolved）
#   - v3.0：移除镜像源管理功能
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 信号处理（Ctrl+C 优雅退出）
trap 'echo -e "\n${RED}脚本被中断，退出${NC}"; exit 1' INT TERM

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 sudo 或以 root 用户执行此脚本${NC}"
    exit 1
fi

# -------------------- 工具函数 --------------------
# 检查端口是否被占用
function check_port() {
    local port=$1
    if ss -tlnp 2>/dev/null | grep -qE ":${port}(\s|$)"; then
        return 1
    fi
    return 0
}

# 校验端口（1-65535）
function validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 校验域名
function validate_domain() {
    local domain=$1
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-\.]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
        return 1
    fi
    return 0
}

# 校验绝对路径
function validate_path() {
    local path=$1
    if [[ "$path" =~ ^/ ]] && [ ${#path} -gt 1 ]; then
        return 0
    fi
    return 1
}

# 获取公网 IP（带超时和备用方案）
function get_public_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(curl -s --connect-timeout 5 --max-time 10 ip.sb 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -s --connect-timeout 5 --max-time 10 api.ipify.org 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

# -------------------- DNS 修复函数 --------------------
function fix_dns() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${GREEN}       DNS 修复（可选）${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo "当前 DNS 配置："
    cat /etc/resolv.conf 2>/dev/null || echo "无法读取 /etc/resolv.conf"
    echo ""
    read -p "是否修复 DNS（使用阿里云+Google DNS）？(y/n): " dns_fix
    if [[ "$dns_fix" =~ ^[Yy]$ ]]; then
        [ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s)

        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            echo -e "${YELLOW}检测到 systemd-resolved 正在运行，使用 resolvectl 配置${NC}"
            local iface
            iface=$(ip route | awk '/default/ {print $5; exit}')
            if [ -n "$iface" ]; then
                resolvectl dns "$iface" 223.5.5.5 223.6.6.6 8.8.8.8 8.8.4.4 2>/dev/null || true
            fi
        fi

        cat > /etc/resolv.conf <<EOF
# 由部署脚本生成 $(date)
nameserver 223.5.5.5
nameserver 223.6.6.6
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
        echo -e "${GREEN}DNS 已修复${NC}"
        echo -e "${YELLOW}提示：未锁定文件，重启后可能被覆盖。如需永久生效，建议配置 systemd-resolved 或 NetworkManager${NC}"
    else
        echo -e "${YELLOW}跳过 DNS 修复${NC}"
    fi
}

# -------------------- 前置通用优化 --------------------
function setup_environment() {
    echo -e "${YELLOW}[前置任务] 系统环境优化${NC}"
    fix_dns
    echo -e "${GREEN}环境优化完成${NC}"
}

# -------------------- 功能1：Nginx HTTPS 部署 --------------------
function install_nginx_https() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${GREEN}   Nginx HTTPS 一键部署（增强版）${NC}"
    echo -e "${YELLOW}========================================${NC}"

    read -p "请输入你的域名（例如 example.com）: " DOMAIN
    read -p "请输入你的邮箱（用于证书提醒）: " EMAIL

    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
        echo -e "${RED}域名和邮箱不能为空！${NC}"
        return 1
    fi

    if ! validate_domain "$DOMAIN"; then
        echo -e "${RED}域名格式不正确${NC}"
        return 1
    fi

    for port in 80 443; do
        if ! check_port $port; then
            echo -e "${YELLOW}警告：端口 $port 已被占用${NC}"
            ss -tlnp | grep ":${port}\s"
            read -p "是否继续？(y/n): " cont
            [[ ! "$cont" =~ ^[Yy]$ ]] && return 1
        fi
    done

    echo -e "${BLUE}请选择部署模式：${NC}"
    echo "  1) 静态文件托管（自定义本地目录）"
    echo "  2) 反向代理（转发到任意 URL / IP:端口）"
    read -p "请输入数字 [1 或 2]: " MODE

    local DEPLOY_MODE=""
    local STATIC_PATH=""
    local BACKEND=""

    if [ "$MODE" == "1" ]; then
        DEPLOY_MODE="static"
        read -p "请输入静态文件存放的绝对路径（例如 /home/user/www）: " STATIC_PATH
        if ! validate_path "$STATIC_PATH"; then
            echo -e "${RED}路径必须是绝对路径！${NC}"
            return 1
        fi
        if [ ! -d "$STATIC_PATH" ]; then
            mkdir -p "$STATIC_PATH"
            echo -e "${YELLOW}目录 $STATIC_PATH 不存在，已自动创建${NC}"
        fi
        chown -R www-data:www-data "$STATIC_PATH" 2>/dev/null || true
        chmod -R 755 "$STATIC_PATH"
        if [ ! -f "$STATIC_PATH/index.html" ]; then
            cat > "$STATIC_PATH/index.html" <<EOF
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>$DOMAIN</title></head>
<body><h1>🎉 静态网站已就绪！</h1><p>域名: $DOMAIN</p><p>目录: $STATIC_PATH</p></body></html>
EOF
        fi
        echo -e "${GREEN}静态文件模式，根目录：$STATIC_PATH${NC}"

    elif [ "$MODE" == "2" ]; then
        DEPLOY_MODE="proxy"
        read -p "请输入后端目标地址（支持 http://IP:端口、https://域名 等）: " BACKEND
        if [ -z "$BACKEND" ]; then
            echo -e "${RED}目标地址不能为空！${NC}"
            return 1
        fi
        if [[ ! "$BACKEND" =~ ^https?:// ]]; then
            BACKEND="http://$BACKEND"
        fi
        echo -e "${GREEN}反向代理模式，转发到：$BACKEND${NC}"
    else
        echo -e "${RED}无效选择，退出${NC}"
        return 1
    fi

    echo -e "${BLUE}正在安装 Nginx 和 Certbot...${NC}"
    apt install -y curl wget nginx certbot python3-certbot-nginx ufw

    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    if [ -f "$NGINX_CONF" ]; then
        cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"
        echo -e "${YELLOW}已备份原有配置${NC}"
    fi

    if [ "$DEPLOY_MODE" == "static" ]; then
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $STATIC_PATH;
    index index.html index.htm;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    else
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass $BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    fi

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    if ! nginx -t; then
        echo -e "${RED}Nginx 配置测试失败！${NC}"
        return 1
    fi

    systemctl restart nginx
    systemctl enable nginx

    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw --force enable 2>/dev/null || true

    echo -e "${BLUE}正在申请 SSL 证书...${NC}"
    certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --redirect --non-interactive --keep-until-expiring

    systemctl enable --now certbot.timer 2>/dev/null || true

    local IP
    IP=$(get_public_ip)

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} ✅ Nginx HTTPS 部署完成！${NC}"
    echo -e "访问地址：${BLUE}https://$DOMAIN${NC}"
    echo -e "服务器IP：$IP"
    if [ "$DEPLOY_MODE" == "static" ]; then
        echo -e "静态文件目录：$STATIC_PATH"
    else
        echo -e "反向代理目标：$BACKEND"
    fi
    echo -e "${GREEN}========================================${NC}"
}

# -------------------- 功能2：WebDAV 部署 --------------------
function install_webdav() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${GREEN}   Apache WebDAV 一键部署${NC}"
    echo -e "${YELLOW}========================================${NC}"

    WEBDAV_DOMAIN="www1.movemama.cn"
    WEBDAV_USER="movemama"
    WEBDAV_PASS="qq123456"
    WEBDAV_PORT="9520"
    WEBDAV_ROOT="/var/www/webdav"

    read -p "请输入域名 [默认 $WEBDAV_DOMAIN]: " input
    [ -n "$input" ] && WEBDAV_DOMAIN="$input"

    read -p "请输入端口 [默认 $WEBDAV_PORT]: " input
    [ -n "$input" ] && WEBDAV_PORT="$input"

    read -p "请输入用户名 [默认 $WEBDAV_USER]: " input
    [ -n "$input" ] && WEBDAV_USER="$input"

    read -p "请输入密码 [默认 $WEBDAV_PASS]: " input
    [ -n "$input" ] && WEBDAV_PASS="$input"

    read -p "存储目录 [默认 $WEBDAV_ROOT]: " input
    [ -n "$input" ] && WEBDAV_ROOT="$input"

    if ! validate_port "$WEBDAV_PORT"; then
        echo -e "${RED}端口必须是 1-65535 的数字${NC}"
        return 1
    fi

    if ! check_port "$WEBDAV_PORT"; then
        echo -e "${RED}端口 $WEBDAV_PORT 已被占用！${NC}"
        ss -tlnp | grep ":${WEBDAV_PORT}\s"
        return 1
    fi

    if ! validate_path "$WEBDAV_ROOT"; then
        echo -e "${RED}存储目录必须是绝对路径${NC}"
        return 1
    fi

    echo -e "${BLUE}配置确认：${NC}"
    echo -e "域名: $WEBDAV_DOMAIN"
    echo -e "端口: $WEBDAV_PORT"
    echo -e "用户: $WEBDAV_USER"
    echo -e "密码: $WEBDAV_PASS"
    echo -e "目录: $WEBDAV_ROOT"
    read -p "确认开始安装？(y/n) " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    echo -e "${BLUE}正在安装 Apache...${NC}"
    apt install -y apache2 apache2-utils

    a2enmod dav dav_fs auth_basic authn_core authz_core rewrite headers >/dev/null 2>&1 || true

    mkdir -p "$WEBDAV_ROOT"
    chown -R www-data:www-data "$WEBDAV_ROOT"
    chmod -R 755 "$WEBDAV_ROOT"

    htpasswd -cb /etc/apache2/webdav.passwd "$WEBDAV_USER" "$WEBDAV_PASS"
    chmod 640 /etc/apache2/webdav.passwd
    chown root:www-data /etc/apache2/webdav.passwd

    mkdir -p /var/lock/apache2
    chown www-data:www-data /var/lock/apache2

    if ! grep -qE "^Listen\s+$WEBDAV_PORT(\s|$)" /etc/apache2/ports.conf; then
        echo "Listen $WEBDAV_PORT" >> /etc/apache2/ports.conf
        echo -e "${GREEN}已将 Listen $WEBDAV_PORT 添加到 ports.conf${NC}"
    else
        echo -e "${YELLOW}Listen $WEBDAV_PORT 已存在于 ports.conf${NC}"
    fi

    WEBDAV_CONF="/etc/apache2/sites-available/webdav.conf"
    if [ -f "$WEBDAV_CONF" ]; then
        cp "$WEBDAV_CONF" "${WEBDAV_CONF}.bak.$(date +%s)"
        echo -e "${YELLOW}已备份原有 WebDAV 配置${NC}"
    fi

    cat > "$WEBDAV_CONF" <<EOF
<VirtualHost *:$WEBDAV_PORT>
    ServerName $WEBDAV_DOMAIN
    DocumentRoot $WEBDAV_ROOT

    EnableSendfile Off
    EnableMMAP Off

    DavLockDB /var/lock/apache2/DAVLock

    LimitRequestBody 0
    Timeout 600

    <Directory $WEBDAV_ROOT>
        Dav On
        AuthType Basic
        AuthName "WebDAV"
        AuthUserFile /etc/apache2/webdav.passwd
        Require valid-user
        Options Indexes FollowSymLinks MultiViews
        AllowOverride All

        Header always set Accept-Ranges "bytes"
        Header always set Access-Control-Allow-Origin "*"
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/webdav_error.log
    CustomLog \${APACHE_LOG_DIR}/webdav_access.log combined
</VirtualHost>
EOF

    a2ensite webdav.conf
    a2dissite 000-default.conf 2>/dev/null || true

    if ! apache2ctl configtest; then
        echo -e "${RED}Apache 配置测试失败，请检查${NC}"
        return 1
    fi

    systemctl restart apache2
    systemctl enable apache2

    ufw allow "$WEBDAV_PORT/tcp" 2>/dev/null || true

    local IP
    IP=$(get_public_ip)

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} ✅ WebDAV 部署完成！${NC}"
    echo -e "访问地址：${BLUE}http://$WEBDAV_DOMAIN:$WEBDAV_PORT/${NC}"
    echo -e "局域网访问：${BLUE}http://$IP:$WEBDAV_PORT/${NC}"
    echo -e "端口：$WEBDAV_PORT"
    echo -e "用户名：$WEBDAV_USER  密码：$WEBDAV_PASS"
    echo -e "服务器IP：$IP"
    echo -e "${YELLOW}⚠️  请妥善保管密码，密码文件位于：/etc/apache2/webdav.passwd${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# -------------------- 主菜单 --------------------
function main_menu() {
    while true; do
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${GREEN}       超级一键部署脚本主菜单${NC}"
        echo -e "${YELLOW}========================================${NC}"
        echo "1) 安装 Nginx + HTTPS（静态目录 / 反向代理）"
        echo "2) 安装 Apache WebDAV 文件服务器"
        echo "3) 修复 DNS（阿里云 + Google）"
        echo "4) 退出脚本"
        echo -e "${YELLOW}========================================${NC}"
        read -p "请输入数字选择功能: " choice

        case $choice in
            1) install_nginx_https ;;
            2) install_webdav ;;
            3) fix_dns ;;
            4) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效输入，请重新选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键返回主菜单..."
    done
}

# 启动主菜单
main_menu
