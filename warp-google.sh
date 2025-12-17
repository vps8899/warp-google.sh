#!/bin/bash
# ===================================================
# Project: WARP Google Unlock (RackNerd/IPv4 Fix)
# Version: 4.3 (Force IPv4 Endpoint)
# ===================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 权限运行！${NC}" && exit 1
    if [ ! -e /dev/net/tun ]; then
        echo -e "${YELLOW}正在尝试开启 TUN 设备...${NC}"
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 >/dev/null 2>&1
        chmod 600 /dev/net/tun >/dev/null 2>&1
    fi
}

install_warp() {
    check_env
    echo -e "${YELLOW}>>> [1/5] 安装依赖...${NC}"
    
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wireguard-tools curl wget git lsb-release ufw openresolv >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y wireguard-tools curl wget git openresolv >/dev/null 2>&1
    fi

    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi

    echo -e "${YELLOW}>>> [2/5] 注册 WARP 账号...${NC}"
    systemctl stop wg-quick@warp >/dev/null 2>&1
    rm -rf /etc/wireguard/warp_tmp
    
    mkdir -p /etc/wireguard/warp_tmp
    cd /etc/wireguard/warp_tmp || exit

    ARCH=$(uname -m)
    if [[ $ARCH == "x86_64" ]]; then
        WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64"
    elif [[ $ARCH == "aarch64" ]]; then
        WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_arm64"
    else
        echo -e "${RED}不支持的架构: $ARCH${NC}" && exit 1
    fi

    wget -qO /usr/local/bin/wgcf $WGCF_URL
    chmod +x /usr/local/bin/wgcf

    if [ ! -f wgcf-account.toml ]; then
        echo | /usr/local/bin/wgcf register >/dev/null 2>&1
    fi
    /usr/local/bin/wgcf generate >/dev/null 2>&1

    echo -e "${YELLOW}>>> [3/5] 优化配置 (强制 IPv4)...${NC}"
    CONF_PATH="/etc/wireguard/warp.conf"
    cp wgcf-profile.conf $CONF_PATH

    # --- 核心修复 v4.2: 防止重复 Address ---
    sed -i '/^Address/d' $CONF_PATH
    sed -i '/^PrivateKey/a Address = 172.16.0.2/32' $CONF_PATH

    # --- 核心修复 v4.3: 强制 IPv4 Endpoint ---
    # 解决 DNS 解析到 IPv6 导致握手失败的问题
    sed -i 's/Endpoint.*/Endpoint = 162.159.192.1:2408/' $CONF_PATH

    # --- 基础配置修改 ---
    sed -i '/DNS/d' $CONF_PATH
    sed -i '/\[Interface\]/a DNS = 8.8.8.8, 1.1.1.1' $CONF_PATH

    sed -i '/Table/d' $CONF_PATH
    sed -i '/\[Interface\]/a Table = off' $CONF_PATH

    sed -i '/PersistentKeepalive/d' $CONF_PATH
    sed -i '/\[Peer\]/a PersistentKeepalive = 25' $CONF_PATH

    sed -i '/PostUp/d' $CONF_PATH
    sed -i '/PreDown/d' $CONF_PATH
    sed -i '/\[Interface\]/a PostUp = bash /etc/wireguard/add_google_routes.sh' $CONF_PATH
    sed -i '/\[Interface\]/a PreDown = bash /etc/wireguard/del_google_routes.sh' $CONF_PATH

    cd /root || exit
    rm -rf /etc/wireguard/warp_tmp

    echo -e "${YELLOW}>>> [4/5] 生成路由规则脚本...${NC}"
    cat > /etc/wireguard/add_google_routes.sh << 'SCRIPT_EOF'
#!/bin/bash
IP_LIST="/etc/wireguard/google_ips.txt"
wget -T 10 -t 3 -qO $IP_LIST https://raw.githubusercontent.com/mayaxcn/china-ip-list/master/google.txt
if [ ! -s $IP_LIST ]; then
    echo "142.250.0.0/15" > $IP_LIST
fi
while read ip; do
  [[ $ip =~ ^# ]] && continue
  [[ -z $ip ]] && continue
  ip route add $ip dev warp >/dev/null 2>&1
done < $IP_LIST
SCRIPT_EOF

    cat > /etc/wireguard/del_google_routes.sh << 'SCRIPT_EOF'
#!/bin/bash
IP_LIST="/etc/wireguard/google_ips.txt"
[ ! -f "$IP_LIST" ] && exit 0
while read ip; do
  [[ $ip =~ ^# ]] && continue
  [[ -z $ip ]] && continue
  ip route del $ip dev warp >/dev/null 2>&1
done < $IP_LIST
SCRIPT_EOF

    chmod +x /etc/wireguard/*.sh

    echo -e "${YELLOW}>>> [5/5] 启动服务...${NC}"
    if command -v ufw >/dev/null; then
        ufw allow out 51820/udp >/dev/null 2>&1
    fi

    wg-quick down warp >/dev/null 2>&1
    systemctl enable wg-quick@warp >/dev/null 2>&1
    systemctl restart wg-quick@warp

    echo -e "${GREEN}>>> ✅ 安装完成！正在检测...${NC}"
    sleep 3
    check_status
}

uninstall_warp() {
    echo -e "${YELLOW}>>> 正在卸载...${NC}"
    systemctl stop wg-quick@warp >/dev/null 2>&1
    systemctl disable wg-quick@warp >/dev/null 2>&1
    if [ -f /etc/wireguard/del_google_routes.sh ]; then
        bash /etc/wireguard/del_google_routes.sh >/dev/null 2>&1
    fi
    rm -rf /etc/wireguard/warp.conf
    rm -rf /etc/wireguard/*.sh
    rm -rf /etc/wireguard/google_ips.txt
    echo -e "${GREEN}>>> 卸载完成。${NC}"
}

check_status() {
    if ! systemctl is-active --quiet wg-quick@warp; then
        echo -e "服务状态: ${RED}未运行 (Failed)${NC}"
        echo -e "请运行: journalctl -xeu wg-quick@warp 查看错误日志"
        return
    fi

    LATEST_HANDSHAKE=$(wg show warp latest-handshakes | awk '{print $2}')
    if [ -z "$LATEST_HANDSHAKE" ] || [ "$LATEST_HANDSHAKE" = "0" ]; then
        echo -e "${RED}⚠️  警告：握手失败 (Handshake = 0)${NC}"
        echo -e "${YELLOW}可能原因：Endpoint 解析到了 IPv6 (RackNerd不支持)。${NC}"
        echo -e "${YELLOW}尝试修复：请更新脚本到 v4.3 版本强制使用 IPv4 Endpoint。${NC}"
        return
    fi

    echo -e "WARP 状态: ${GREEN}运行正常 (握手成功)${NC}"
    
    RESULT=$(curl -sI -4 -o /dev/null -w "%{http_code}" https://gemini.google.com --max-time 5)
    if [ "$RESULT" == "200" ] || [ "$RESULT" == "301" ] || [ "$RESULT" == "302" ]; then
        echo -e "Gemini 解锁: ${GREEN}成功 (Code: $RESULT)${NC}"
    else
        echo -e "Gemini 解锁: ${RED}失败 (Code: $RESULT)${NC}"
    fi
}

clear
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}   WARP Google Unlocker (Auto Fix IPv6)      ${NC}"
echo -e "${GREEN}=============================================${NC}"
echo -e "1. 安装 / 修复 (Install/Repair)"
echo -e "2. 卸载 (Uninstall)"
echo -e "3. 检测状态 (Check Status)"
echo -e "0. 退出 (Exit)"
echo -e "---------------------------------------------"
read -p "选择: " choice

case $choice in
    1) install_warp ;;
    2) uninstall_warp ;;
    3) check_status ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
esac
