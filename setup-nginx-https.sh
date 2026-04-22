#!/bin/bash
# Nginx HTTPS 一键安装脚本（Ubuntu 24.04.1 x64）
# 支持静态网站 / Docker 反向代理，Let's Encrypt 免费证书，自动续期

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 sudo 或以 root 用户执行此脚本${NC}"
    exit 1
fi

echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN} Nginx HTTPS 一键部署脚本${NC}"
echo -e "${YELLOW}========================================${NC}"

# 获取域名和邮箱
read -p "请输入你的域名（例如 example.com）: " DOMAIN
read -p "请输入你的邮箱（用于证书到期提醒）: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo -e "${RED}域名和邮箱不能为空！${NC}"
    exit 1
fi

# 选择部署模式
echo -e "${BLUE}请选择部署模式：${NC}"
echo "  1) 静态网站（提供本地 HTML 文件）"
echo "  2) 反向代理（转发到 Docker 容器或本地服务）"
read -p "请输入数字 [1 或 2]: " MODE

if [ "$MODE" == "1" ]; then
    DEPLOY_MODE="static"
    WEB_ROOT="/var/www/$DOMAIN/html"
    echo -e "${GREEN}已选择：静态网站模式，文件根目录为 $WEB_ROOT${NC}"
elif [ "$MODE" == "2" ]; then
    DEPLOY_MODE="proxy"
    read -p "请输入后端服务地址（例如 127.0.0.1:4000，默认 http://127.0.0.1:4000）: " BACKEND
    BACKEND=${BACKEND:-127.0.0.1:4000}
    # 智能补全 http:// 前缀
    if [[ ! "$BACKEND" =~ ^https?:// ]]; then
        BACKEND="http://$BACKEND"
    fi
    echo -e "${GREEN}已选择：反向代理模式，转发到 $BACKEND${NC}"
else
    echo -e "${RED}无效选择，退出脚本${NC}"
    exit 1
fi

# 构建 certbot 域名参数（仅主域名）
CERTBOT_DOMAINS="-d $DOMAIN"

# 1. 系统更新与基础依赖
echo -e "${YELLOW}[1/7] 更新系统包并安装依赖...${NC}"
apt update
apt upgrade -y
apt install -y curl wget nginx certbot python3-certbot-nginx ufw

# 2. 准备网站内容（静态模式需要）
if [ "$DEPLOY_MODE" == "static" ]; then
    echo -e "${YELLOW}[2/7] 创建网站目录与测试页面...${NC}"
    mkdir -p "$WEB_ROOT"
    chown -R $SUDO_USER:$SUDO_USER /var/www/$DOMAIN
    chmod -R 755 /var/www/$DOMAIN

    cat > "$WEB_ROOT/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Welcome to $DOMAIN</title>
</head>
<body>
    <h1>🎉 恭喜！你的 HTTPS 网站已成功部署！</h1>
    <p>域名: $DOMAIN</p>
    <p>服务器时间: $(date)</p>
</body>
</html>
EOF
else
    echo -e "${YELLOW}[2/7] 跳过静态页面创建（反向代理模式）${NC}"
fi

# 3. 配置 Nginx HTTP 虚拟主机
echo -e "${YELLOW}[3/7] 配置 Nginx HTTP 站点...${NC}"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

# server_name 仅使用主域名
SERVER_NAMES="$DOMAIN"

# 生成配置文件（HTTP 部分，用于证书验证）
if [ "$DEPLOY_MODE" == "static" ]; then
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $SERVER_NAMES;

    root $WEB_ROOT;
    index index.html index.htm;

    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log /var/log/nginx/$DOMAIN.error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
EOF
else
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $SERVER_NAMES;

    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log /var/log/nginx/$DOMAIN.error.log;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass $BACKEND;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90;
    }
}
EOF
fi

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx
systemctl enable nginx

# 4. 配置防火墙
echo -e "${YELLOW}[4/7] 配置防火墙规则...${NC}"
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# 5. 申请 SSL 证书
echo -e "${YELLOW}[5/7] 申请 SSL 证书...${NC}"
certbot --nginx $CERTBOT_DOMAINS \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --redirect \
    --non-interactive \
    --keep-until-expiring || {
        echo -e "${RED}证书申请失败！请检查：${NC}"
        echo -e "${RED}1. 域名 DNS 是否已解析到本服务器 IP${NC}"
        echo -e "${RED}2. 80/443 端口是否在云安全组中放行${NC}"
        exit 1
    }

# 6. 验证 HTTPS 配置（Certbot 已自动修改配置文件）
echo -e "${YELLOW}[6/7] 验证 HTTPS 配置...${NC}"
systemctl reload nginx

# 7. 证书自动续期
echo -e "${YELLOW}[7/7] 验证证书自动续期定时任务...${NC}"
systemctl is-active certbot.timer >/dev/null 2>&1 || {
    echo -e "${YELLOW}未检测到 certbot.timer，正在手动添加...${NC}"
    systemctl enable --now certbot.timer
}

IP_ADDR=$(curl -s ifconfig.me)
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} ✅ 部署成功！${NC}"
echo -e "${GREEN}========================================${NC}"
if [ "$DEPLOY_MODE" == "static" ]; then
    echo -e "网站目录: ${WEB_ROOT}"
else
    echo -e "代理后端: ${BACKEND}"
fi
echo -e "访问地址: ${GREEN}https://$DOMAIN${NC}"
echo -e "服务器 IP: ${IP_ADDR}"
echo -e ""
echo -e "证书自动续期: ${GREEN}已启用${NC}"
echo -e "测试续期命令: sudo certbot renew --dry-run"
echo -e ""
if [ "$DEPLOY_MODE" == "static" ]; then
    echo -e "如需修改网页，请编辑: ${WEB_ROOT}/index.html"
else
    echo -e "如需修改代理配置，请编辑: ${NGINX_CONF}"
    echo -e "修改后执行: sudo nginx -t && sudo systemctl reload nginx"
fi
echo -e "${GREEN}========================================${NC}"
