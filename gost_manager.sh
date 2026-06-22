# 1. 清空旧配置
> /etc/gost/socks5_list.conf
systemctl restart gost-socks5

# 2. 写入修正版脚本并运行
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

get_public_ip() {
    IP=$(curl -s -4 --max-time 5 ifconfig.me)
    if [ -z "$IP" ]; then
        IP=$(curl -s --max-time 5 ifconfig.me)
    fi
    [ -z "$IP" ] && IP="你的VPS公网IP"
    echo "$IP"
}

add_proxy() {
    install_gost
    mkdir -p $CONF_DIR
    touch $CONF_FILE

    echo ""
    read -p "请输入新代理的端口 (直接回车默认 2889): " PORT
    PORT=${PORT:-2889}

    read -p "请输入新代理的账号 (直接回车默认 mosdadce): " USERNAME
    USERNAME=${USERNAME:-mosdadce}

    read -p "请输入新代理的密码 (直接回车默认 qq147258..): " PASSWORD
    PASSWORD=${PASSWORD:-qq147258..}

    # 修正：匹配格式是 @:端口
    if grep -q "@:${PORT}" $CONF_FILE; then
        echo "❌ 端口 $PORT 已经被占用，请换一个端口！"
        return
    fi

    echo "-L socks5://${USERNAME}:${PASSWORD}@:${PORT}" >> $CONF_FILE
    setup_service

    if command -v ufw &> /dev/null; then
        ufw allow ${PORT}/tcp > /dev/null 2>&1
        ufw allow ${PORT}/udp > /dev/null 2>&1
    fi

    IP=$(get_public_ip)
    echo ""
    echo "✅ 新增代理成功！"
    echo "=============================================="
    echo " 代理 IP:   $IP"
    echo " 代理端口:  $PORT"
    echo " 账号:      $USERNAME"
    echo " 密码:      $PASSWORD"
    echo "----------------------------------------------"
    echo " 软件可直接使用的代理链接："
    echo " socks5://${USERNAME}:${PASSWORD}@${IP}:${PORT}"
    echo "=============================================="
    echo "⚠️ 云服务器请去网页控制台【安全组】放行 TCP $PORT 端口！"
}

show_proxies() {
    echo ""
    echo "当前已配置的所有 SOCKS5 代理："
    echo "=============================================="
    if [ -s "$CONF_FILE" ]; then
        IP=$(get_public_ip)
        while IFS= read -r line; do
            INFO=$(echo "$line" | grep -oP 'socks5://\K.*')
            USERPASS=$(echo "$INFO" | awk -F'@:' '{print $1}')
            PORT=$(echo "$INFO" | awk -F'@:' '{print $2}')
            USERNAME=$(echo "$USERPASS" | awk -F':' '{print $1}')
            PASSWORD=$(echo "$USERPASS" | awk -F':' '{print $2}')
            echo " 端口:     $PORT"
            echo " 账号:     $USERNAME"
            echo " 密码:     $PASSWORD"
            echo " 代理链接: socks5://${USERNAME}:${PASSWORD}@${IP}:${PORT}"
            echo "----------------------------------------------"
        done < $CONF_FILE
    else
        echo "暂无配置，请先选择 [1] 增加代理"
    fi
    echo "=============================================="
}

delete_proxy() {
    echo ""
    if [ ! -s "$CONF_FILE" ]; then
        echo "当前没有任何代理可删除"
        return
    fi
    echo "当前代理端口列表："
    grep -oP '@:\K[0-9]+' $CONF_FILE | nl -w2 -s'. '
    echo ""
    read -p "请输入要删除的端口号 (例如 2889): " DELPORT
    # 修正：匹配格式是 @:端口，不是 :端口@
    if ! grep -q "@:${DELPORT}" $CONF_FILE; then
        echo "❌ 没有找到端口 $DELPORT 的代理"
        return
    fi
    sed -i "/@:${DELPORT}/d" $CONF_FILE
    setup_service
    echo "✅ 已删除端口 $DELPORT 的代理"
}

while true; do
    echo ""
    echo "===== gost SOCKS5 管理菜单 ====="
    echo "1. 增加新代理"
    echo "2. 查看所有代理 (含代理链接)"
    echo "3. 删除代理"
    echo "4. 重启代理服务"
    echo "5. 退出"
    read -p "请输入选项 [1-5]: " choice

    case $choice in
        1) add_proxy ;;
        2) show_proxies ;;
        3) delete_proxy ;;
        4) systemctl restart gost-socks5; echo "✅ 代理服务已重启" ;;
        5) exit 0 ;;
        *) echo "❌ 无效选项，请重新输入" ;;
    esac
done
OUTER_EOF

chmod +x gost_manager.sh && ./gost_manager.sh
