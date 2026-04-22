#!/bin/bash
# Nginx HTTPS 一键安装脚本（Ubuntu 24.04.1 x64）
# 使用 Let's Encrypt 免费证书，支持自动续期

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 sudo 或以 root 用户执行此脚本${NC}"
    exit 1
fi

# 获取用户输入
echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN} Nginx HTTPS 一键部署脚本${NC}"
echo -e "${YELLOW}========================================${NC}"
read -p "请输入你的域名（例如 example.com）: " DOMAIN
read -p "请输入你的邮箱（用于证书到期提醒）: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo -e "${RED}域名和邮箱不能为空！${NC}"
    exit 1
fi

# 定义变量
WEB_ROOT="/var/www/$DOMAIN/html"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

# 1. 系统更新与基础依赖
echo -e "${YELLOW}[1/7] 更新系统包并安装依赖...${NC}"
apt update
apt upgrade -y
apt install -y curl wget nginx certbot python3-certbot-nginx ufw

# 2. 创建网站目录与测试页面
echo -e "${YELLOW}[2/7] 创建网站目录与测试页面...${NC}"
mkdir -p "$WEB_ROOT"
chown -R $SUDO_USER:$SUDO_USER /var/www/$DOMAIN  # 使用执行脚本的用户
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

# 3. 配置 Nginx HTTP 虚拟主机（用于证书申请前的验证）
echo -e "${YELLOW}[3/7] 配置 Nginx HTTP 站点...${NC}"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN www.$DOMAIN;

    root $WEB_ROOT;
    index index.html index.htm;

    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log /var/log/nginx/$DOMAIN.error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# 启用站点
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

# 测试 Nginx 配置
nginx -t

# 重载 Nginx
systemctl reload nginx
systemctl enable nginx

# 4. 配置防火墙（UFW）
echo -e "${YELLOW}[4/7] 配置防火墙规则...${NC}"
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# 5. 申请 SSL 证书（Let's Encrypt）
echo -e "${YELLOW}[5/7] 申请 SSL 证书（请确保域名已正确解析到本服务器 IP）...${NC}"
certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" \
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

# 6. 验证 HTTPS 并输出信息
echo -e "${YELLOW}[6/7] 验证 HTTPS 配置...${NC}"
systemctl reload nginx

# 7. 设置证书自动续期（Certbot 已自动创建定时任务）
echo -e "${YELLOW}[7/7] 验证证书自动续期定时任务...${NC}"
systemctl is-active certbot.timer >/dev/null 2>&1 || {
    echo -e "${YELLOW}未检测到 certbot.timer，正在手动添加...${NC}"
    systemctl enable --now certbot.timer
}

# 完成提示
IP_ADDR=$(curl -s ifconfig.me)
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} ✅ 部署成功！${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "网站目录: ${WEB_ROOT}"
echo -e "访问地址: ${GREEN}https://$DOMAIN${NC}"
echo -e "服务器 IP: ${IP_ADDR}"
echo -e ""
echo -e "证书自动续期: ${GREEN}已启用${NC} (定时任务: systemctl status certbot.timer)"
echo -e "测试续期命令: sudo certbot renew --dry-run"
echo -e ""
echo -e "如需修改网页，请编辑: ${WEB_ROOT}/index.html"
echo -e "${GREEN}========================================${NC}"
