cat << 'OUTER_EOF' > gost_manager.sh
#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 用户运行此脚本" 
   exit 1
fi

GOST_BIN="/usr/bin/gost"
CONF_DIR="/etc/gost"
CONF_FILE="${CONF_DIR}/socks5_list.conf"
SERVICE_FILE="/etc/systemd/system/gost-socks5.service"

# 安装基础环境和 gost 程序
install_gost() {
    if [ -f "$GOST_BIN" ]; then return; fi
    echo "首次运行，正在安装依赖和 gost..."
    apt update -y && apt install -y wget curl gzip
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        GOST_ARCH="amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        GOST_ARCH="armv8"
    else
        echo "不支持的系统架构: $ARCH"; exit 1
    fi
    wget -q --no-check-certificate -O gost.gz "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${GOST_ARCH}-2.11.5.gz"
    gzip -d gost.gz
    mv gost $GOST_BIN
    chmod +x $GOST_BIN
    mkdir -p $CONF_DIR
}

# 生成并重启 systemd 服务
setup_service() {
    cat > $SERVICE_FILE <<INNER_EOF
[Unit]
Description=gost SOCKS5 Multi-Server
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '${GOST_BIN} $(cat ${CONF_FILE} | tr "\n" " ")'
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
INNER_EOF

    systemctl daemon-reload
    systemctl enable gost-socks5
    systemctl restart gost-socks5
}

# 增加新代理
add_proxy() {
    install_gost
    touch $CONF_FILE
    
    echo ""
    read -p "请输入新代理的端口 (例如 1081): " PORT
    read -p "请输入新代理的账号 (例如 user2): " USERNAME
    read -p "请输入新代理的密码 (例如 Pass456): " PASSWORD

    # 检查端口是否已存在
    if grep -q ":${PORT}@" $CONF_FILE; then
        echo "❌ 端口 $PORT 已经被占用，请换一个端口！"
        return
    fi

    # 写入配置文件
    echo "-L socks5://${USERNAME}:${PASSWORD}@:${PORT}" >> $CONF_FILE
    
    # 更新服务并重启
    setup_service

    # 放行 UFW 防火墙
    if command -v ufw &> /dev/null; then
        ufw allow ${PORT}/tcp > /dev/null 2>&1
        ufw allow ${PORT}/udp > /dev/null 2>&1
    fi

    IP=$(curl -s --max-time 5 ifconfig.me)
    echo ""
    echo "✅ 新增代理成功！"
    echo "=============================================="
    echo " 代理 IP:   $IP"
    echo " 代理端口:  $PORT"
    echo " 账号:      $USERNAME"
    echo " 密码:      $PASSWORD"
    echo "=============================================="
    echo "⚠️ 注意：如果是云服务器，请务必去网页控制台【安全组】放行 $PORT 端口！"
}

# 查看所有代理
show_proxies() {
    echo ""
    echo "当前已配置的所有 SOCKS5 代理："
    echo "-----------------------------------"
    if [ -s "$CONF_FILE" ]; then
        grep -oP 'socks5://\K.*' $CONF_FILE | awk -F'@:' '{printf "账号密码: %-20s 端口: %s\n", $1, $2}'
    else
        echo "暂无配置，请先选择 [1] 增加代理"
    fi
    echo "-----------------------------------"
}

# 主菜单
while true; do
    echo ""
    echo "===== gost SOCKS5 管理菜单 ====="
    echo "1. 增加新代理 (首次安装也选此)"
    echo "2. 查看所有代理"
    echo "3. 重启代理服务"
    echo "4. 退出"
    read -p "请输入选项 [1-4]: " choice

    case $choice in
        1) add_proxy ;;
        2) show_proxies ;;
        3) systemctl restart gost-socks5; echo "✅ 代理服务已重启" ;;
        4) exit 0 ;;
        *) echo "❌ 无效选项，请重新输入" ;;
    esac
done
OUTER_EOF

chmod +x gost_manager.sh && ./gost_manager.sh
