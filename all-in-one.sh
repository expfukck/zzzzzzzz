#!/bin/bash
# ============================================================
# 超级一键部署脚本（Ubuntu/Debian）
# 功能：
#   1. Nginx HTTPS 网站（静态 / 反向代理 Docker）
#   2. Apache WebDAV 文件服务器
#   自动换源、修复 DNS，新手友好
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 sudo 或以 root 用户执行此脚本${NC}"
    exit 1
fi

# 获取系统代号
CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")

# -------------------- 通用函数：换源与修复 DNS --------------------
function setup_sources_and_dns() {
    echo -e "${YELLOW}[前置任务] 更换阿里云源并修复 DNS...${NC}"

    # 备份 sources.list
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)
    fi

    # 写入阿里云源（适配版本代号）
    cat > /etc/apt/sources.list <<EOF
# 阿里云镜像源 - ${CODENAME}
deb http://mirrors.aliyun.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ ${CODENAME} main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
EOF

    # 修复 DNS
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver 223.5.5.5
nameserver 223.6.6.6
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
    chattr +i /etc/resolv.conf

    apt update
    echo -e "${GREEN}源与 DNS 配置完成${NC}"
}

# -------------------- 功能1：Nginx HTTPS 部署 --------------------
function install_nginx_https() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${GREEN}   Nginx HTTPS 一键部署${NC}"
    echo -e "${YELLOW}========================================${NC}"

    read -p "请输入你的域名（例如 example.com）: " DOMAIN
    read -p "请输入你的邮箱（用于证书提醒）: " EMAIL

    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
        echo -e "${RED}域名和邮箱不能为空！${NC}"
        return 1
    fi

    echo -e "${BLUE}请选择部署模式：${NC}"
    echo "  1) 静态网站（提供本地 HTML 文件）"
    echo "  2) 反向代理（转发到 Docker 容器或本地服务）"
    read -p "请输入数字 [1 或 2]: " MODE

    if [ "$MODE" == "1" ]; then
        DEPLOY_MODE="static"
        WEB_ROOT="/var/www/$DOMAIN/html"
        echo -e "${GREEN}静态网站模式，根目录：$WEB_ROOT${NC}"
    elif [ "$MODE" == "2" ]; then
        DEPLOY_MODE="proxy"
        read -p "请输入后端服务地址（例如 127.0.0.1:4000，默认 http://127.0.0.1:4000）: " BACKEND
        BACKEND=${BACKEND:-127.0.0.1:4000}
        if [[ ! "$BACKEND" =~ ^https?:// ]]; then
            BACKEND="http://$BACKEND"
        fi
        echo -e "${GREEN}反向代理模式，转发到：$BACKEND${NC}"
    else
        echo -e "${RED}无效选择，退出${NC}"
        return 1
    fi

    # 安装依赖
    apt install -y curl wget nginx certbot python3-certbot-nginx ufw

    # 静态网站准备
    if [ "$DEPLOY_MODE" == "static" ]; then
        mkdir -p "$WEB_ROOT"
        chown -R $SUDO_USER:$SUDO_USER /var/www/$DOMAIN
        chmod -R 755 /var/www/$DOMAIN
        cat > "$WEB_ROOT/index.html" <<EOF
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>$DOMAIN</title></head>
<body><h1>🎉 HTTPS 部署成功！</h1><p>$DOMAIN</p></body></html>
EOF
    fi

    # Nginx HTTP 配置
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    if [ "$DEPLOY_MODE" == "static" ]; then
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80; listen [::]:80;
    server_name $DOMAIN;
    root $WEB_ROOT; index index.html;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    else
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80; listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
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
    nginx -t && systemctl reload nginx
    systemctl enable nginx

    # 防火墙
    ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw --force enable

    # 申请证书
    certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --redirect --non-interactive --keep-until-expiring

    # 自动续期
    systemctl enable --now certbot.timer 2>/dev/null || true

    IP=$(curl -s ifconfig.me)
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} ✅ Nginx HTTPS 部署完成！${NC}"
    echo -e "访问地址：${BLUE}https://$DOMAIN${NC}"
    echo -e "服务器IP：$IP"
    echo -e "${GREEN}========================================${NC}"
}

# -------------------- 功能2：WebDAV 部署 --------------------
function install_webdav() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${GREEN}   Apache WebDAV 一键部署${NC}"
    echo -e "${YELLOW}========================================${NC}"

    # 可自定义参数
    WEBDAV_DOMAIN="www1.movemama.cn"
    WEBDAV_USER="movemama"
    WEBDAV_PASS="qq123456"
    WEBDAV_ROOT="/var/www/webdav"
    MAX_UPLOAD="5368709120"  # 5GB

    read -p "请输入域名 [默认 $WEBDAV_DOMAIN]: " input
    [ -n "$input" ] && WEBDAV_DOMAIN="$input"
    read -p "请输入用户名 [默认 $WEBDAV_USER]: " input
    [ -n "$input" ] && WEBDAV_USER="$input"
    read -p "请输入密码 [默认 $WEBDAV_PASS]: " input
    [ -n "$input" ] && WEBDAV_PASS="$input"
    read -p "存储目录 [默认 $WEBDAV_ROOT]: " input
    [ -n "$input" ] && WEBDAV_ROOT="$input"

    echo -e "${BLUE}配置确认：${NC}"
    echo -e "域名: $WEBDAV_DOMAIN"
    echo -e "用户: $WEBDAV_USER"
    echo -e "密码: $WEBDAV_PASS"
    echo -e "目录: $WEBDAV_ROOT"
    read -p "确认开始安装？(y/n) " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    apt install -y apache2 apache2-utils

    a2enmod dav dav_fs auth_basic

    mkdir -p "$WEBDAV_ROOT"
    chown -R www-data:www-data "$WEBDAV_ROOT"
    chmod -R 755 "$WEBDAV_ROOT"

    htpasswd -cb /etc/apache2/webdav.passwd "$WEBDAV_USER" "$WEBDAV_PASS"
    chmod 640 /etc/apache2/webdav.passwd
    chown root:www-data /etc/apache2/webdav.passwd

    mkdir -p /var/lock/apache2
    chown www-data:www-data /var/lock/apache2

    cat > /etc/apache2/sites-available/webdav.conf <<EOF
<VirtualHost *:80>
    ServerName $WEBDAV_DOMAIN
    DocumentRoot $WEBDAV_ROOT
    LimitRequestBody $MAX_UPLOAD
    DavLockDB /var/lock/apache2/DAVLock

    <Directory $WEBDAV_ROOT>
        Dav On
        AuthType Basic
        AuthName "WebDAV"
        AuthUserFile /etc/apache2/webdav.passwd
        Require valid-user

        <FilesMatch "\.txt$">
            Require all granted
            ForceType 'text/plain; charset=UTF-8'
        </FilesMatch>

        Options Indexes FollowSymLinks MultiViews
        AllowOverride All
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/webdav_error.log
    CustomLog \${APACHE_LOG_DIR}/webdav_access.log combined
</VirtualHost>
EOF

    a2ensite webdav.conf
    a2dissite 000-default.conf 2>/dev/null || true
    apache2ctl configtest
    systemctl restart apache2
    systemctl enable apache2

    IP=$(curl -s ifconfig.me)
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} ✅ WebDAV 部署完成！${NC}"
    echo -e "访问地址：${BLUE}http://$WEBDAV_DOMAIN/${NC}"
    echo -e "用户名：$WEBDAV_USER  密码：$WEBDAV_PASS"
    echo -e "服务器IP：$IP"
    echo -e "${GREEN}========================================${NC}"
}

# -------------------- 主菜单 --------------------
function main_menu() {
    # 先执行通用优化
    setup_sources_and_dns

    while true; do
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${GREEN}       超级一键部署脚本主菜单${NC}"
        echo -e "${YELLOW}========================================${NC}"
        echo "1) 安装 Nginx + HTTPS（静态网站/反向代理）"
        echo "2) 安装 Apache WebDAV 文件服务器"
        echo "3) 退出脚本"
        echo -e "${YELLOW}========================================${NC}"
        read -p "请输入数字选择功能: " choice

        case $choice in
            1) install_nginx_https ;;
            2) install_webdav ;;
            3) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效输入，请重新选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键返回主菜单..."
    done
}

# 启动主菜单
main_menu
