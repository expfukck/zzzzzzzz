#!/bin/bash
# ============================================================
# 超级一键部署脚本（Ubuntu/Debian） - 增强版
# 功能：
#   1. Nginx HTTPS 网站（自定义静态目录 / 任意反向代理）
#   2. Apache WebDAV 文件服务器
#   自动换源、修复 DNS（可选，支持恢复官方源），新手友好
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

# 官方源备份文件路径
BACKUP_SOURCES="/etc/apt/sources.list.bak.original"

# -------------------- 镜像源管理函数 --------------------
function manage_sources() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${GREEN}       镜像源管理${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo "1) 更换为阿里云镜像源（推荐国内服务器）"
    echo "2) 恢复官方 Ubuntu 源"
    echo "3) 保持当前源不变，继续"
    read -p "请选择操作 [1-3]: " src_choice

    case $src_choice in
        1)
            # 备份当前源（如果尚未备份过官方源）
            if [ ! -f "$BACKUP_SOURCES" ] && [ -f /etc/apt/sources.list ]; then
                cp /etc/apt/sources.list "$BACKUP_SOURCES"
                echo -e "${GREEN}已备份官方源至 $BACKUP_SOURCES${NC}"
            fi
            # 写入阿里云源
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
            echo -e "${GREEN}已更换为阿里云镜像源${NC}"
            apt update
            ;;
        2)
            if [ -f "$BACKUP_SOURCES" ]; then
                cp "$BACKUP_SOURCES" /etc/apt/sources.list
                echo -e "${GREEN}已恢复官方源${NC}"
                apt update
            else
                echo -e "${RED}未找到官方源备份文件，无法恢复${NC}"
                echo -e "您可手动编辑 /etc/apt/sources.list"
            fi
            ;;
        3)
            echo -e "${YELLOW}保持当前源不变${NC}"
            ;;
        *)
            echo -e "${RED}无效选择，保持当前源${NC}"
            ;;
    esac
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
        echo -e "${GREEN}DNS 已修复并锁定${NC}"
    else
        echo -e "${YELLOW}跳过 DNS 修复${NC}"
    fi
}

# -------------------- 前置通用优化 --------------------
function setup_environment() {
    echo -e "${YELLOW}[前置任务] 系统环境优化${NC}"
    manage_sources
    fix_dns
    echo -e "${GREEN}环境优化完成${NC}"
}

# -------------------- 功能1：Nginx HTTPS 部署（增强版） --------------------
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

    echo -e "${BLUE}请选择部署模式：${NC}"
    echo "  1) 静态文件托管（自定义本地目录）"
    echo "  2) 反向代理（转发到任意 URL / IP:端口）"
    read -p "请输入数字 [1 或 2]: " MODE

    if [ "$MODE" == "1" ]; then
        DEPLOY_MODE="static"
        read -p "请输入静态文件存放的绝对路径（例如 /home/user/www）: " STATIC_PATH
        if [ -z "$STATIC_PATH" ]; then
            echo -e "${RED}路径不能为空！${NC}"
            return 1
        fi
        # 如果目录不存在则创建
        if [ ! -d "$STATIC_PATH" ]; then
            mkdir -p "$STATIC_PATH"
            echo -e "${YELLOW}目录 $STATIC_PATH 不存在，已自动创建${NC}"
        fi
        # 确保 nginx 有权限读取
        chown -R www-data:www-data "$STATIC_PATH" 2>/dev/null || chown -R $SUDO_USER:$SUDO_USER "$STATIC_PATH"
        chmod -R 755 "$STATIC_PATH"
        # 可选：生成一个默认首页
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
        # 如果用户未写协议，默认加 http://
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

    # 生成 Nginx HTTP 配置（用于证书申请）
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
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
    else  # proxy 模式
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

    # 启用站点
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
    systemctl enable nginx

    # 防火墙放行
    ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw --force enable

    # 申请 SSL 证书（使用 certbot 自动配置并重定向到 HTTPS）
    certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --redirect --non-interactive --keep-until-expiring

    # 自动续期定时器
    systemctl enable --now certbot.timer 2>/dev/null || true

    IP=$(curl -s ifconfig.me)
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

# -------------------- 功能2：WebDAV 部署（支持多线程下载） --------------------
function install_webdav() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${GREEN}   Apache WebDAV 一键部署${NC}"
    echo -e "${YELLOW}========================================${NC}"

    # 可自定义参数
    WEBDAV_DOMAIN="www1.movemama.cn"
    WEBDAV_USER="movemama"
    WEBDAV_PASS="qq123456"
    WEBDAV_ROOT="/var/www/webdav"
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

    a2enmod dav dav_fs auth_basic rewrite headers

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

    EnableSendfile Off
    EnableMMAP Off

    DavLockDB /var/lock/apache2/DAVLock

    <Directory $WEBDAV_ROOT>
        Dav On
        AuthType Basic
        AuthName "WebDAV"
        AuthUserFile /etc/apache2/webdav.passwd
        Require valid-user
        Options Indexes FollowSymLinks MultiViews
        AllowOverride All

        RewriteEngine On
        RewriteCond %{REQUEST_METHOD} ^(GET|HEAD)$
        RewriteCond %{REQUEST_FILENAME} -f [OR]
        RewriteCond %{REQUEST_FILENAME} -d
        RewriteRule .* - [H=default-handler]

        Header always set Accept-Ranges "bytes"

        <FilesMatch "\.txt$">
            Require all granted
            ForceType 'text/plain; charset=UTF-8'
        </FilesMatch>
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
    # 先执行环境优化（可交互选择源和DNS）
    setup_environment

    while true; do
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${GREEN}       超级一键部署脚本主菜单${NC}"
        echo -e "${YELLOW}========================================${NC}"
        echo "1) 安装 Nginx + HTTPS（静态目录 / 反向代理）"
        echo "2) 安装 Apache WebDAV 文件服务器"
        echo "3) 重新配置镜像源 / DNS"
        echo "4) 退出脚本"
        echo -e "${YELLOW}========================================${NC}"
        read -p "请输入数字选择功能: " choice

        case $choice in
            1) install_nginx_https ;;
            2) install_webdav ;;
            3) setup_environment ;;
            4) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效输入，请重新选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键返回主菜单..."
    done
}

# 启动主菜单
main_menu
