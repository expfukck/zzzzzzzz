#!/bin/bash
# ============================================================
# 超级一键部署脚本 v4.0（Ubuntu/Debian）
#   1. Nginx HTTPS：静态 / 普通反代 / AI 反代（SSE+WS+长超时）
#   2. Apache WebDAV
#   3. DNS 修复
# 变更摘要：
#   - 新增 AI 反向代理模板（对齐生产 AI 站点配置）
#   - 修复 Connection 头在 SSE/WS 场景互覆盖问题（map 动态判定）
#   - 证书申请改 webroot 模式，不再让 certbot 改写 nginx 配置
#   - 续期 deploy-hook 自动 reload nginx
#   - 通配符证书提示使用 DNS API hook 实现真正自动续期
#   - set -euo pipefail + 幂等性 + 端口释放安全化
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
trap 'echo -e "\n${RED}脚本被中断，退出${NC}"; exit 1' INT TERM

[ "$EUID" -ne 0 ] && { echo -e "${RED}请使用 sudo 或以 root 执行${NC}"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# -------------------- 工具函数 --------------------
check_port() {
    ss -tlnp 2>/dev/null | grep -qE ":${1}(\s|$)"
}

# 仅释放指定端口，跳过 sshd / nginx 自身，避免误杀
free_port() {
    local port=$1
    local pids
    pids=$(ss -tlnp 2>/dev/null | grep -E ":${port}\s" \
           | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u \
           | while read -r pid; do
               [ -z "$pid" ] && continue
               local cmd
               cmd=$(ps -p "$pid" -o comm= 2>/dev/null || true)
               case "$cmd" in
                   sshd|nginx|apache2) echo "$pid:skip($cmd)" >&2; continue ;;
                   *) echo "$pid" ;;
               esac
             done)
    [ -z "$pids" ] && return 0
    echo -e "${YELLOW}⚠️  端口 $port 被占用 (PID: $(echo $pids | tr '\n' ' '))，尝试释放...${NC}"
    kill $pids 2>/dev/null || true
    sleep 1
    local remaining
    remaining=$(ss -tlnp 2>/dev/null | grep -E ":${port}\s" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
    [ -n "$remaining" ] && kill -9 $remaining 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}✅ 端口 $port 已处理${NC}"
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_domain() {
    local bare
    bare=$(echo "$1" | sed -E 's/^(\*\.|www\.)//')
    [[ "$bare" =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]]
}

validate_path() {
    [[ "$1" =~ ^/ ]] && [ ${#1} -gt 1 ]
}

get_public_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -s --connect-timeout 5 --max-time 10 ip.sb 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -s --connect-timeout 5 --max-time 10 api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-unknown}"
}

# apt 幂等安装
apt_ensure() {
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            apt-get install -y "$pkg"
        fi
    done
}

# -------------------- DNS 修复 --------------------
fix_dns() {
    echo -e "${YELLOW}=========== DNS 修复（可选）===========${NC}"
    cat /etc/resolv.conf 2>/dev/null || echo "无法读取 resolv.conf"
    read -rp "是否修复 DNS（阿里云+Google）？(y/n): " dns_fix
    if [[ "$dns_fix" =~ ^[Yy]$ ]]; then
        cp -f /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)" 2>/dev/null || true
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            local iface; iface=$(ip route | awk '/default/ {print $5; exit}')
            [ -n "$iface" ] && resolvectl dns "$iface" 223.5.5.5 8.8.8.8 2>/dev/null || true
        fi
        cat > /etc/resolv.conf <<EOF
# 由部署脚本生成 $(date)
nameserver 223.5.5.5
nameserver 223.6.6.6
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
        echo -e "${GREEN}DNS 已修复${NC}"
    else
        echo -e "${YELLOW}跳过${NC}"
    fi
}

# -------------------- Nginx HTTPS 部署 --------------------
install_nginx_https() {
    echo -e "${GREEN}=========== Nginx HTTPS 部署 v4.0 ===========${NC}"

    read -rp "主域名（如 ai.movemama.cn 或 example.com）: " DOMAIN
    read -rp "邮箱（用于证书提醒）: " EMAIL
    [ -z "$DOMAIN" ] || [ -z "$EMAIL" ] && { echo -e "${RED}域名/邮箱不能为空${NC}"; return 1; }
    validate_domain "$DOMAIN" || { echo -e "${RED}域名格式不正确${NC}"; return 1; }

    local BARE_DOMAIN
    BARE_DOMAIN=$(echo "$DOMAIN" | sed -E 's/^(www\.|\*\.)//')

    local CERT_DOMAINS=() NGINX_SERVER_NAMES=()

    echo -e "${YELLOW}━━━ 泛域名通配符证书 ━━━${NC}"
    echo -e "泛域名证书覆盖 *.${BARE_DOMAIN}，${RED}必须 DNS 验证${NC}。"
    echo -e "如需自动续期，须配置 DNS API hook（阿里云/Cloudflare），否则每次续期都要手动加 TXT。"
    read -rp "是否申请泛域名 *.${BARE_DOMAIN}？(y/n 默认 n): " USE_WILDCARD

    if [[ "$USE_WILDCARD" =~ ^[Yy]$ ]]; then
        CERT_DOMAINS+=("*.${BARE_DOMAIN}" "${BARE_DOMAIN}")
        NGINX_SERVER_NAMES+=("*.${BARE_DOMAIN}" "${BARE_DOMAIN}")
    else
        CERT_DOMAINS+=("$DOMAIN"); NGINX_SERVER_NAMES+=("$DOMAIN")
        if [[ ! "$DOMAIN" =~ ^www\. ]]; then
            read -rp "同时添加 www.${BARE_DOMAIN}？(y/n 默认 y): " ADD_WWW
            [[ ! "$ADD_WWW" =~ ^[Nn]$ ]] && { CERT_DOMAINS+=("www.${BARE_DOMAIN}"); NGINX_SERVER_NAMES+=("www.${BARE_DOMAIN}"); }
        else
            read -rp "同时添加裸域名 ${BARE_DOMAIN}？(y/n 默认 y): " ADD_BARE
            [[ ! "$ADD_BARE" =~ ^[Nn]$ ]] && { CERT_DOMAINS+=("${BARE_DOMAIN}"); NGINX_SERVER_NAMES+=("${BARE_DOMAIN}"); }
        fi
    fi

    echo -e "${YELLOW}━━━ 额外子域名（回车跳过）━━━${NC}"
    while true; do
        read -rp "添加子域名: " EXTRA_SUB
        [ -z "$EXTRA_SUB" ] && break
        [[ ! "$EXTRA_SUB" =~ \. ]] && EXTRA_SUB="${EXTRA_SUB}.${BARE_DOMAIN}"
        local dup=n
        for d in "${CERT_DOMAINS[@]}"; do [ "$d" == "$EXTRA_SUB" ] && dup=y && break; done
        if [ "$dup" == n ]; then
            CERT_DOMAINS+=("$EXTRA_SUB"); NGINX_SERVER_NAMES+=("$EXTRA_SUB")
            echo -e "${GREEN}✅ 已加 $EXTRA_SUB${NC}"
        else
            echo -e "${YELLOW}⚠  已存在，跳过${NC}"
        fi
    done

    echo -e "${YELLOW}━━━ 证书域名汇总 ━━━${NC}"
    local CERT_LIST=""
    for d in "${CERT_DOMAINS[@]}"; do echo -e "  🔒 $d"; CERT_LIST="$CERT_LIST -d $d"; done
    read -rp "确认？(y/n 默认 y): " CONFIRM_DOMAINS
    [[ "$CONFIRM_DOMAINS" =~ ^[Nn]$ ]] && { echo -e "${YELLOW}已取消${NC}"; return 0; }

    free_port 80; free_port 443

    echo -e "${BLUE}部署模式：${NC}"
    echo "  1) 静态文件托管"
    echo "  2) 普通反向代理"
    echo "  3) AI 反向代理（SSE 流式 + WebSocket + 长超时，推荐 LLM 场景）"
    read -rp "请输入 [1/2/3 默认 3]: " MODE
    MODE="${MODE:-3}"

    local DEPLOY_MODE STATIC_PATH BACKEND
    case "$MODE" in
        1)
            DEPLOY_MODE="static"
            read -rp "静态文件绝对路径（如 /var/www/html）: " STATIC_PATH
            validate_path "$STATIC_PATH" || { echo -e "${RED}需绝对路径${NC}"; return 1; }
            mkdir -p "$STATIC_PATH"
            chown -R www-data:www-data "$STATIC_PATH" 2>/dev/null || true
            chmod -R 755 "$STATIC_PATH"
            [ ! -f "$STATIC_PATH/index.html" ] && cat > "$STATIC_PATH/index.html" <<EOF
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>$BARE_DOMAIN</title></head>
<body><h1>🎉 就绪</h1><p>$BARE_DOMAIN</p></body></html>
EOF
            ;;
        2|3)
            DEPLOY_MODE=$([ "$MODE" == 3 ] && echo "ai_proxy" || echo "proxy")
            [ "$MODE" == 3 ] && echo -e "${YELLOW}AI 反代：后端建议为 http://127.0.0.1:PORT${NC}"
            read -rp "后端目标地址（如 http://127.0.0.1:3000）: " BACKEND
            [ -z "$BACKEND" ] && { echo -e "${RED}不能为空${NC}"; return 1; }
            [[ ! "$BACKEND" =~ ^https?:// ]] && BACKEND="http://$BACKEND"
            ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac

    echo -e "${BLUE}安装依赖...${NC}"
    apt-get update -qq
    apt_ensure curl wget nginx certbot python3-certbot-nginx ufw
    mkdir -p /var/www/html

    local SERVER_NAME_STR
    SERVER_NAME_STR=$(IFS=' '; echo "${NGINX_SERVER_NAMES[*]}")
    local NGINX_CONF="/etc/nginx/sites-available/$BARE_DOMAIN"

    [ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)" && echo -e "${YELLOW}已备份旧配置${NC}"

    # —— 生成 HTTP 配置（含 ACME 验证路径，用 ^~ 保证优先级）——
    generate_http_conf() {
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME_STR;
    server_tokens off;

    # ACME HTTP-01 验证：^~ 前缀优先级最高，不被 location / 抢
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
        allow all;
    }
EOF
        if [ "$DEPLOY_MODE" == "static" ]; then
            cat >> "$NGINX_CONF" <<EOF
    root $STATIC_PATH;
    index index.html index.htm;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
        else
            cat >> "$NGINX_CONF" <<EOF
    location / { return 301 https://\$host\$request_uri; }
}
EOF
        fi
    }
    generate_http_conf

    # 清理默认站点，避免 80 端口 default_server 冲突
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    nginx -t
    systemctl restart nginx
    systemctl enable nginx

    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw --force enable 2>/dev/null || true

    echo -e "${BLUE}申请 SSL 证书...${NC}"
    local CERT_OK=0
    if [[ "$USE_WILDCARD" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}泛域名证书需 DNS 验证${NC}"
        echo -e "请到 DNS 后台为 ${GREEN}_acme-challenge.${BARE_DOMAIN}${NC} 添加 TXT 记录"
        echo -e "${RED}注意：手动模式续期时仍需人工干预，建议改用 --manual-auth-hook 接 DNS API${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -rp "准备好按回车开始: "
        if certbot certonly --manual --preferred-challenges dns \
            --agree-tos --no-eff-email --email "$EMAIL" \
            --keep-until-expiring $CERT_LIST; then
            CERT_OK=1
        fi
    else
        # webroot 模式：不动 nginx 配置，仅取证书
        if certbot certonly --webroot -w /var/www/html \
            --agree-tos --no-eff-email --email "$EMAIL" \
            --non-interactive --keep-until-expiring $CERT_LIST; then
            CERT_OK=1
        fi
    fi

    [ "$CERT_OK" -ne 1 ] && { echo -e "${RED}证书申请失败${NC}"; return 1; }

    # —— 生成 HTTPS 配置 ——
    generate_https_conf() {
        local SSL_CONF="/etc/nginx/sites-available/${BARE_DOMAIN}-ssl"
        local MAP_SNIPPET="/etc/nginx/conf.d/connection_upgrade.map.conf"
        # 全局 map：SSE/WS 共存的关键
        if [ ! -f "$MAP_SNIPPET" ]; then
            cat > "$MAP_SNIPPET" <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      keep-alive;
}
EOF
        fi

        cat > "$SSL_CONF" <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $SERVER_NAME_STR;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/${BARE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${BARE_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # 安全响应头
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Strict-Transport-Security "max-age=31536000" always;

    client_max_body_size 0;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
        allow all;
    }
EOF
        if [ "$DEPLOY_MODE" == "static" ]; then
            cat >> "$SSL_CONF" <<EOF
    root $STATIC_PATH;
    index index.html index.htm;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
        elif [ "$DEPLOY_MODE" == "proxy" ]; then
            cat >> "$SSL_CONF" <<EOF
    location / {
        proxy_pass $BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
        else
            # —— AI 反向代理模板（对齐生产配置）——
            cat >> "$SSL_CONF" <<EOF
    location / {
        proxy_pass $BACKEND;

        # 透传客户端信息
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 超时：AI 推理/流式输出必须拉长
        proxy_connect_timeout 60s;
        proxy_send_timeout    600s;
        proxy_read_timeout    600s;

        # SSE 流式输出：关闭缓冲，否则打字机效果变一次性吐出
        proxy_buffering         off;
        proxy_cache             off;
        proxy_http_version      1.1;
        proxy_set_header        Connection \$connection_upgrade;
        proxy_set_header        X-Accel-Buffering no;

        # WebSocket 支持（实时语音/双向通道）
        proxy_set_header        Upgrade \$http_upgrade;

        # 关闭请求体缓冲，大 JSON/多模态请求体直接流式转发
        proxy_request_buffering off;

        # gzip 会强制缓冲，流式场景必须关
        gzip off;
    }
}
EOF
        fi

        # HTTP -> HTTPS 301（保留 ACME 验证路径）
        cat >> "$SSL_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME_STR;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
        allow all;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
        ln -sf "$SSL_CONF" /etc/nginx/sites-enabled/
        # 移除纯 HTTP 配置，避免重复 server_name
        rm -f "/etc/nginx/sites-enabled/$(basename "$NGINX_CONF")"
    }
    generate_https_conf

    nginx -t
    systemctl reload nginx

    # —— 续期后自动 reload nginx 的 deploy hook ——
    local HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$HOOK_DIR"
    cat > "$HOOK_DIR/nginx-reload.sh" <<'EOF'
#!/bin/bash
# 证书续期成功后自动 reload nginx
if systemctl reload nginx 2>/dev/null; then
    echo "[certbot-hook] nginx reloaded" >&2
else
    systemctl restart nginx 2>/dev/null || true
fi
EOF
    chmod +x "$HOOK_DIR/nginx-reload.sh"

    systemctl enable --now certbot.timer 2>/dev/null || true

    local IP; IP=$(get_public_ip)
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} ✅ 部署完成${NC}"
    for d in "${CERT_DOMAINS[@]}"; do echo -e "  🌐 https://$d"; done
    echo -e "服务器IP：$IP"
    case "$DEPLOY_MODE" in
        static)    echo -e "静态目录：$STATIC_PATH" ;;
        proxy)     echo -e "反代目标：$BACKEND" ;;
        ai_proxy)  echo -e "AI 反代目标：$BACKEND（SSE+WS+600s 超时）" ;;
    esac
    echo -e "${GREEN}========================================${NC}"
}

# -------------------- WebDAV --------------------
install_webdav() {
    echo -e "${GREEN}=========== Apache WebDAV ===========${NC}"
    local WEBDAV_DOMAIN="www1.movemama.cn" WEBDAV_USER="movemama"
    local WEBDAV_PASS="qq123456" WEBDAV_PORT="9520" WEBDAV_ROOT="/var/www/webdav"

    read -rp "域名 [$WEBDAV_DOMAIN]: " i; [ -n "$i" ] && WEBDAV_DOMAIN="$i"
    read -rp "端口 [$WEBDAV_PORT]: " i; [ -n "$i" ] && WEBDAV_PORT="$i"
    read -rp "用户名 [$WEBDAV_USER]: " i; [ -n "$i" ] && WEBDAV_USER="$i"
    read -rp "密码 [$WEBDAV_PASS]（回车则随机生成）: " i
    if [ -z "$i" ]; then
        WEBDAV_PASS=$(openssl rand -base64 18 2>/dev/null || head -c 18 /dev/urandom | base64)
        echo -e "${GREEN}已生成随机密码：$WEBDAV_PASS${NC}"
    else
        WEBDAV_PASS="$i"
    fi
    read -rp "存储目录 [$WEBDAV_ROOT]: " i; [ -n "$i" ] && WEBDAV_ROOT="$i"

    validate_port "$WEBDAV_PORT" || { echo -e "${RED}端口非法${NC}"; return 1; }
    validate_path "$WEBDAV_ROOT" || { echo -e "${RED}需绝对路径${NC}"; return 1; }

    echo -e "域名:$WEBDAV_DOMAIN 端口:$WEBDAV_PORT 用户:$WEBDAV_USER 目录:$WEBDAV_ROOT"
    read -rp "确认安装？: " c; [[ ! "$c" =~ ^[Yy]$ ]] && return

    free_port "$WEBDAV_PORT"

    apt-get update -qq
    apt_ensure apache2 apache2-utils
    a2enmod dav dav_fs auth_basic authn_core authz_core rewrite headers >/dev/null 2>&1 || true

    mkdir -p "$WEBDAV_ROOT" /var/lock/apache2
    chown -R www-data:www-data "$WEBDAV_ROOT" /var/lock/apache2
    chmod -R 755 "$WEBDAV_ROOT"

    htpasswd -cb /etc/apache2/webdav.passwd "$WEBDAV_USER" "$WEBDAV_PASS"
    chmod 640 /etc/apache2/webdav.passwd
    chown root:www-data /etc/apache2/webdav.passwd

    # 幂等：避免重复 append Listen
    if ! grep -qE "^\s*Listen\s+${WEBDAV_PORT}(\s|$)" /etc/apache2/ports.conf; then
        echo "Listen $WEBDAV_PORT" >> /etc/apache2/ports.conf
        echo -e "${GREEN}已添加 Listen $WEBDAV_PORT${NC}"
    fi

    local WEBDAV_CONF="/etc/apache2/sites-available/webdav.conf"
    [ -f "$WEBDAV_CONF" ] && cp "$WEBDAV_CONF" "${WEBDAV_CONF}.bak.$(date +%s)"
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
    apache2ctl configtest
    systemctl restart apache2
    systemctl enable apache2
    ufw allow "$WEBDAV_PORT/tcp" 2>/dev/null || true

    local IP; IP=$(get_public_ip)
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} ✅ WebDAV 完成${NC}"
    echo -e "访问：http://$WEBDAV_DOMAIN:$WEBDAV_PORT/"
    echo -e "局域网：http://$IP:$WEBDAV_PORT/"
    echo -e "用户：$WEBDAV_USER  密码：$WEBDAV_PASS"
    echo -e "${YELLOW}密码文件：/etc/apache2/webdav.passwd${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# -------------------- 主菜单 --------------------
main_menu() {
    while true; do
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${GREEN}       超级一键部署脚本 v4.0${NC}"
        echo -e "${YELLOW}========================================${NC}"
        echo "1) Nginx + HTTPS（静态 / 普通反代 / AI 反代）"
        echo "2) Apache WebDAV"
        echo "3) 修复 DNS"
        echo "4) 退出"
        read -rp "选择: " choice
        case "$choice" in
            1) install_nginx_https || true ;;
            2) install_webdav || true ;;
            3) fix_dns ;;
            4) echo -e "${GREEN}再见${NC}"; exit 0 ;;
            *) echo -e "${RED}无效${NC}" ;;
        esac
        echo ""
        read -rp "回车返回菜单..."
    done
}

main_menu
