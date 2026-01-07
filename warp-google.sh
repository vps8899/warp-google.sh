#!/bin/bash
# ===================================================
# Project: WARP Unlocker (Manual Mode v9.0)
# Version: 9.0 (Menu Selector: Dual Stack vs IPv4 Only)
# ===================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# ===================================================
# 核心安装逻辑
# ===================================================
install_core() {
    # 参数1: 分流模式 (google/youtube/media)
    # 参数2: 网络栈模式 (auto/ipv4)
    ROUTING_MODE=$1 
    NET_STACK=$2

    echo -e "${YELLOW}>>> [1/7] 环境初始化...${NC}"
    check_root
    check_tun
    install_deps
    
    # 强制清理旧环境 (防止残留导致启动失败)
    systemctl stop wg-quick@warp >/dev/null 2>&1
    systemctl disable wg-quick@warp >/dev/null 2>&1
    ip link delete dev warp >/dev/null 2>&1
    rm -rf /etc/wireguard/warp.conf
    rm -rf /etc/wireguard/routes.txt
    rm -rf /etc/wireguard/routes6.txt

    # 决定是否启用 IPv6
    ENABLE_IPV6=false
    if [ "$NET_STACK" == "auto" ]; then
        # 自动检测：尝试 Ping Google IPv6 DNS
        if ping6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; then
            ENABLE_IPV6=true
            echo -e "网络模式: ${GREEN}双栈 (自动检测到 IPv6)${NC}"
        else
            echo -e "网络模式: ${YELLOW}单栈 (仅 IPv4)${NC}"
        fi
    else
        # 强制 IPv4 模式 (RackNerd 救星)
        echo -e "网络模式: ${SKYBLUE}强制 IPv4 (忽略系统 IPv6)${NC}"
    fi

    echo -e "${YELLOW}>>> [2/7] 获取 WARP 密钥...${NC}"
    get_warp_profile

    echo -e "${YELLOW}>>> [3/7] 生成配置文件...${NC}"
    
    PRIVATE_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d' ' -f3)
    ORIG_ADDR=$(grep 'Address' wgcf-profile.conf | cut -d'=' -f2 | tr -d ' ')
    
    # 根据模式生成配置
    if [ "$ENABLE_IPV6" = true ]; then
        # 双栈配置
        FINAL_ADDR="$ORIG_ADDR"
        DNS_STR="8.8.8.8, 1.1.1.1, 2001:4860:4860::8888"
        ALLOWED_IPS="0.0.0.0/0, ::/0"
        ENDPOINT_HOST="engage.cloudflareclient.com:2408" # 双栈可用域名
    else
        # 强制 IPv4 配置
        # 1. 截取 IPv4 地址
        FINAL_ADDR=$(echo "$ORIG_ADDR" | cut -d',' -f1)
        DNS_STR="8.8.8.8, 1.1.1.1"
        ALLOWED_IPS="0.0.0.0/0"
        # 关键修改：RackNerd 必须用纯 IPv4 IP，防止解析到 IPv6
        ENDPOINT_HOST="162.159.192.1:2408" 
    fi

    cat > /etc/wireguard/warp.conf <<WG_CONF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $FINAL_ADDR
DNS = $DNS_STR
MTU = 1280
Table = off
PostUp = bash /etc/wireguard/add_routes.sh
PreDown = bash /etc/wireguard/del_routes.sh

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = $ALLOWED_IPS
Endpoint = $ENDPOINT_HOST
PersistentKeepalive = 25
WG_CONF

    echo -e "${YELLOW}>>> [4/7] 下载分流规则...${NC}"
    generate_routes "$ROUTING_MODE" "$ENABLE_IPV6"

    echo -e "${YELLOW}>>> [5/7] 启动服务...${NC}"
    # 开启转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/warp.conf
    if [ "$ENABLE_IPV6" = true ]; then
        echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/warp.conf
    fi
    sysctl -p /etc/sysctl.d/warp.conf >/dev/null 2>&1

    systemctl enable wg-quick@warp >/dev/null 2>&1
    
    if systemctl start wg-quick@warp; then
        echo -e "${GREEN}>>> 启动成功！${NC}"
    else
        echo -e "${RED}>>> 启动失败！${NC}"
        echo -e "${YELLOW}如果是 RackNerd 机器，请务必选择菜单中的 [强制 IPv4] 选项！${NC}"
        echo -e "查看日志: journalctl -xeu wg-quick@warp"
        exit 1
    fi

    echo -e "${YELLOW}>>> [6/7] 验证连接...${NC}"
    sleep 3
    check_status "$ENABLE_IPV6"
}

# ===================================================
# 辅助函数
# ===================================================

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 权限运行！${NC}" && exit 1
}

check_tun() {
    if [ ! -e /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 >/dev/null 2>&1
        chmod 600 /dev/net/tun >/dev/null 2>&1
    fi
}

install_deps() {
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wireguard-tools curl wget git lsb-release openresolv >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y wireguard-tools curl wget git openresolv >/dev/null 2>&1
    fi
}

get_warp_profile() {
    mkdir -p /etc/wireguard/warp_tmp
    cd /etc/wireguard/warp_tmp || exit
    ARCH=$(uname -m)
    if [[ $ARCH == "x86_64" ]]; then
        WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64"
    elif [[ $ARCH == "aarch64" ]]; then
        WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_arm64"
    fi
    
    if [ ! -f /usr/local/bin/wgcf ]; then
        wget -qO /usr/local/bin/wgcf $WGCF_URL
        chmod +x /usr/local/bin/wgcf
    fi

    if [ ! -f wgcf-account.toml ]; then
        echo | /usr/local/bin/wgcf register >/dev/null 2>&1
    fi
    /usr/local/bin/wgcf generate >/dev/null 2>&1
    
    if [ ! -f wgcf-profile.conf ]; then
        echo -e "${RED}❌ WARP 配置文件生成失败${NC}"
        exit 1
    fi
}

generate_routes() {
    MODE=$1
    IPV6=$2
    
    cat > /etc/wireguard/add_routes.sh <<EOF
#!/bin/bash
IP_FILE="/etc/wireguard/routes.txt"
IP6_FILE="/etc/wireguard/routes6.txt"
rm -f \$IP_FILE \$IP6_FILE

# IPv4 规则
wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Google/Google_IP-CIDR.txt >> \$IP_FILE

if [ "$MODE" == "youtube" ] || [ "$MODE" == "media" ]; then
    wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/YouTube/YouTube_IP-CIDR.txt >> \$IP_FILE
fi

if [ "$MODE" == "media" ]; then
    wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Netflix/Netflix_IP-CIDR.txt >> \$IP_FILE
    wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Disney/Disney_IP-CIDR.txt >> \$IP_FILE
    wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OpenAI/OpenAI_IP-CIDR.txt >> \$IP_FILE
fi

if [ ! -s \$IP_FILE ]; then echo "142.250.0.0/15" > \$IP_FILE; fi

while read ip; do
  [[ \$ip =~ ^# ]] && continue
  [[ -z \$ip ]] && continue
  clean_ip=\$(echo \$ip | awk '{print \$1}')
  ip route add \$clean_ip dev warp >/dev/null 2>&1
done < \$IP_FILE

# IPv6 规则 (仅当启用时)
if [ "$IPV6" = true ]; then
    echo "2001:4860::/32" > \$IP6_FILE
    echo "2404:6800::/32" >> \$IP6_FILE
    while read ip; do
      ip -6 route add \$ip dev warp >/dev/null 2>&1
    done < \$IP6_FILE
fi
EOF

    cat > /etc/wireguard/del_routes.sh <<EOF
#!/bin/bash
IP_FILE="/etc/wireguard/routes.txt"
IP6_FILE="/etc/wireguard/routes6.txt"

if [ -f "\$IP_FILE" ]; then
    while read ip; do
      [[ \$ip =~ ^# ]] && continue
      [[ -z \$ip ]] && continue
      clean_ip=\$(echo \$ip | awk '{print \$1}')
      ip route del \$clean_ip dev warp >/dev/null 2>&1
    done < \$IP_FILE
fi

if [ -f "\$IP6_FILE" ]; then
    while read ip; do
      ip -6 route del \$ip dev warp >/dev/null 2>&1
    done < \$IP6_FILE
fi
EOF
    chmod +x /etc/wireguard/*.sh
}

uninstall_warp() {
    echo -e "${YELLOW}>>> 正在卸载...${NC}"
    systemctl stop wg-quick@warp >/dev/null 2>&1
    systemctl disable wg-quick@warp >/dev/null 2>&1
    if [ -f /etc/wireguard/del_routes.sh ]; then
        bash /etc/wireguard/del_routes.sh >/dev/null 2>&1
    fi
    ip link delete dev warp >/dev/null 2>&1
    rm -rf /etc/wireguard/warp.conf
    rm -rf /etc/wireguard/*.sh
    rm -rf /etc/wireguard/routes.txt
    rm -rf /etc/wireguard/routes6.txt
    rm -rf /etc/wireguard/warp_tmp
    rm -f /usr/local/bin/wgcf
    echo -e "${GREEN}>>> 卸载完成。${NC}"
}

check_status() {
    IPV6=$1
    if ! systemctl is-active --quiet wg-quick@warp; then
        echo -e "服务状态: ${RED}未运行${NC}"
        return
    fi
    
    HANDSHAKE=$(wg show warp latest-handshakes | awk '{print $2}')
    if [ -z "$HANDSHAKE" ] || [ "$HANDSHAKE" == "0" ]; then
        echo -e "${RED}⚠️  握手失败 (Handshake=0)${NC}"
        return
    else
        echo -e "WARP 握手: ${GREEN}正常${NC}"
    fi

    echo -e "--- 分流测试 ---"
    G4_CODE=$(curl -sI -4 -o /dev/null -w "%{http_code}" https://gemini.google.com --max-time 5)
    if [[ "$G4_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "Gemini (IPv4): ${GREEN}✅ 解锁成功${NC}"
    else
        echo -e "Gemini (IPv4): ${RED}❌ 失败 ($G4_CODE)${NC}"
    fi
}

# ===================================================
# 菜单
# ===================================================
clear
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}   WARP Unlocker (Stable v9.0)               ${NC}"
echo -e "${GREEN}=============================================${NC}"
echo -e "---------------------------------------------"
echo -e "  [模式 A]: 自动检测双栈 (普通 VPS 推荐)"
echo -e "  [模式 B]: 强制 IPv4 (RackNerd/Buggy IPv6 推荐)"
echo -e "---------------------------------------------"
echo -e "1. Google基础 (无广告YouTube) - ${YELLOW}自动检测${NC}"
echo -e "2. Google基础 (无广告YouTube) - ${SKYBLUE}强制 IPv4${NC} (RN选这个!)"
echo -e "---------------------------------------------"
echo -e "3. Google全家桶 (全走代理)    - ${YELLOW}自动检测${NC}"
echo -e "4. Google全家桶 (全走代理)    - ${SKYBLUE}强制 IPv4${NC}"
echo -e "---------------------------------------------"
echo -e "5. 卸载 (Uninstall)"
echo -e "6. 检测状态 (Check Status)"
echo -e "0. 退出"
echo -e "---------------------------------------------"
read -p "请选择 [0-6]: " choice

case $choice in
    1) install_core "google" "auto" ;;
    2) install_core "google" "ipv4" ;; # 这里就是你要的“只允许IPv4出站”
    3) install_core "youtube" "auto" ;;
    4) install_core "youtube" "ipv4" ;;
    5) uninstall_warp ;;
    6) check_status "false" ;; 
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac
