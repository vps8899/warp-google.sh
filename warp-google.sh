#!/bin/bash
# ===================================================
# Project: WARP Google Unlock (System Level)
# Version: 3.0 (Final Stable)
# Description: KVM/LXC/OpenVZ compatible, Duplicate-proof
# ===================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# ===================================================
# 0. 环境预检 (新增)
# ===================================================
check_env() {
    # Root 检查
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 权限运行！${NC}" && exit 1

    # TUN/TAP 检查 (针对 OpenVZ/LXC)
    if [ ! -e /dev/net/tun ]; then
        echo -e "${RED}❌ 致命错误：未检测到 TUN 设备！${NC}"
        echo -e "${YELLOW}请在 VPS 控制面板开启 TUN/TAP 功能，或联系服务商。${NC}"
        exit 1
    fi
}

# ===================================================
# 1. 安装逻辑
# ===================================================
install_warp() {
    check_env
    echo -e "${YELLOW}>>> [1/5] 安装依赖...${NC}"
    
    # 安装工具
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wireguard-tools curl wget git lsb-release ufw >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y wireguard-tools curl wget git >/dev/null 2>&1
    fi

    # 开启转发
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi

    echo -e "${YELLOW}>>> [2/5] 注册 WARP 账号...${NC}"
    mkdir -p /etc/wireguard/warp_tmp
    cd /etc/wireguard/warp_tmp || exit

    # 下载 wgcf
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

    # 注册 (防止重复注册报错)
    if [ ! -f wgcf-account.toml ]; then
        echo | /usr/local/bin/wgcf register >/dev/null 2>&1
    fi
    /usr/local/bin/wgcf generate >/dev/null 2>&1

    # 检查是否成功生成
    if [ ! -f wgcf-profile.conf ]; then
        echo -e "${RED}❌ WARP 配置文件生成失败！可能是接口被限制，请稍后再试。${NC}"
        rm -rf /etc/wireguard/warp_tmp
        exit 1
    fi

    echo -e "${YELLOW}>>> [3/5] 优化配置 (防断连/DNS优化)...${NC}"
    CONF_PATH="/etc/wireguard/warp.conf"
    cp wgcf-profile.conf $CONF_PATH

    # --- 配置修改 (幂等性检查，防止重复添加) ---
    
    # 1. 强制 DNS (避免污染)
    sed -i '/DNS/d' $CONF_PATH
    sed -i '/\[Interface\]/a DNS = 8.8.8.8, 1.1.1.1' $CONF_PATH

    # 2. 禁止接管全流量
    sed -i '/Table/d' $CONF_PATH
    sed -i '/\[Interface\]/a Table = off' $CONF_PATH

    # 3. 永久保活 (25s)
    sed -i '/PersistentKeepalive/d' $CONF_PATH
    sed -i '/\[Peer\]/a PersistentKeepalive = 25' $CONF_PATH

    # 4. 路由脚本钩子 (先删旧的再加新的，防止重复)
    sed -i '/PostUp/d' $CONF_PATH
    sed -i '/PreDown/d' $CONF_PATH
    sed -i '/\[Interface\]/a PostUp = bash /etc/wireguard/add_google_routes.sh' $CONF_PATH
    sed -i '/\[Interface\]/a PreDown = bash /etc/wireguard/del_google_routes.sh' $CONF_PATH

    cd /root || exit
    rm -rf /etc/wireguard/warp_tmp

    echo -e "${YELLOW}>>> [4/5] 生成路由规则脚本...${NC}"
    
    # 写入添加路由脚本 (增加容错)
    cat > /etc/wireguard/add_google_routes.sh << 'EOF'
#!/bin/bash
IP_LIST="/etc/wireguard/google_ips.txt"
# 增加重试机制下载 IP 列表
wget -T 10 -t 3 -qO $IP_LIST https://raw.githubusercontent.com/mayaxcn/china-ip-list/master/google.txt

# 如果下载失败，生成一个最小化的 Gemini IP 列表防止报错
if [ ! -s $IP_LIST ]; then
    echo "142.250.0.0/15" > $IP_LIST
    echo "2001:4860::/32" >> $IP_LIST
fi

while read ip; do
  [[ $ip =~ ^# ]] && continue
  [[ -z $ip ]] && continue
  ip route add $ip dev warp >/dev/null 2>&1
done < $IP_LIST
EOF

    # 写入删除路由脚本
    cat > /etc/wireguard/del_google_routes.sh << 'EOF'
#!/bin/bash
IP_LIST="/etc/wireguard/google_ips.txt"
[ ! -f "$IP_LIST" ] && exit 0
while read ip; do
  [[ $ip =~ ^# ]] && continue
  [[ -z $ip ]] && continue
  ip route del $ip dev warp >/dev/null 2>&1
done < $IP_LIST
EOF

    chmod +x /etc/wireguard/*.sh

    echo -e "${YELLOW}>>> [5/5] 启动服务...${NC}"
    # 放行 UFW 防火墙
    if command -v ufw >/dev/null; then
        ufw allow out 51820/udp >/dev/null 2>&1
    fi

    wg-quick down warp >/dev/null 2>&1
    systemctl enable wg-quick@warp >/dev/null 2>&1
    systemctl restart wg-quick@warp

    echo -e "${GREEN}>>> ✅ 安装完成！${NC}"
    check_status
}

# ===================================================
# 2. 卸载逻辑
# ===================================================
uninstall_warp() {
    echo -e "${YELLOW}>>> 正在卸载...${NC}"
    systemctl stop wg-quick@warp >/dev/null 2>&1
    systemctl disable wg-quick@warp >/dev/null 2>&1
    
    # 执行清理路由
    if [ -f /etc/wireguard/del_google_routes.sh ]; then
        bash /etc/wireguard/del_google_routes.sh >/dev/null 2>&1
    fi

    rm -rf /etc/wireguard/warp.conf
    rm -rf /etc/wireguard/add_google_routes.sh
    rm -rf /etc/wireguard/del_google_routes.sh
    rm -rf /etc/wireguard/google_ips.txt
    
    echo -e "${GREEN}>>> 卸载完成，已恢复直连。${NC}"
}

# ===================================================
# 3. 状态检查 (集成防火墙检测)
# ===================================================
check_status() {
    echo -e "${SKYBLUE}>>> 状态检测...${NC}"
    
    if ! systemctl is-active --quiet wg-quick@warp; then
        echo -e "服务状态: ${RED}未运行${NC}"
        return
    fi

    # 握手检测 (防火墙检测核心)
    LATEST_HANDSHAKE=$(wg show warp latest-handshakes | awk '{print $2}')
    if [ -z "$LATEST_HANDSHAKE" ] || [ "$LATEST_HANDSHAKE" = "0" ]; then
        echo -e "${RED}⚠️  警告：握手失败 (Handshake = 0)${NC}"
        echo -e "${YELLOW}请检查云厂商防火墙(安全组)，确保允许 UDP 出站 (Outbound)。${NC}"
        return
    fi

    # 路由检测
    ROUTE_COUNT=$(ip route | grep warp | wc -l)
    echo -e "Google 路由规则: ${GREEN}${ROUTE_COUNT} 条${NC}"

    # 联网测试 (-4 强制 IPv4, --max-time 避免卡死)
    RESULT=$(curl -sI -4 -o /dev/null -w "%{http_code}" https://gemini.google.com --max-time 5)
    if [ "$RESULT" == "200" ] || [ "$RESULT" == "301" ] || [ "$RESULT" == "302" ]; then
        echo -e "Gemini 访问: ${GREEN}解锁成功 (Code: $RESULT)${NC}"
    else
        echo -e "Gemini 访问: ${RED}失败 (Code: $RESULT)${NC}"
    fi
}

# ===================================================
# 4. 菜单入口
# ===================================================
clear
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}   WARP Google Unlocker (System Routing)     ${NC}"
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
