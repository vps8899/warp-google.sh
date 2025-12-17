cat > warp_google.sh << 'EOF'
#!/bin/bash
# ===================================================
# Project: WARP Google Unlock (RackNerd/IPv4 Fix)
# Version: 4.0 (Auto-Fix IPv6 Permission Denied)
# ===================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# ===================================================
# 0. 环境预检
# ===================================================
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 权限运行！${NC}" && exit 1
    
    # 检测 TUN 设备
    if [ ! -e /dev/net/tun ]; then
        echo -e "${YELLOW}正在尝试开启 TUN 设备...${NC}"
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 >/dev/null 2>&1
        chmod 600 /dev/net/tun >/dev/null 2>&1
    fi
}

# ===================================================
# 1. 安装逻辑
# ===================================================
install_warp() {
    check_env
    echo -e "${YELLOW}>>> [1/5] 安装依赖 (修复 RackNerd 缺失组件)...${NC}"
    
    # 针对 RackNerd/Debian 系统增加 openresolv 支持
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wireguard-tools curl wget git lsb-release ufw openresolv >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y wireguard-tools curl wget git openresolv >/dev/null 2>&1
    fi

    # 开启转发
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi

    echo -e "${YELLOW}>>> [2/5] 注册 WARP 账号...${NC}"
    # 先清理旧配置防止冲突
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

    echo -e "${YELLOW}>>> [3/5] 优化配置 (修复 IPv6 报错)...${NC}"
    CONF_PATH="/etc/wireguard/warp.conf"
    cp wgcf-profile.conf $CONF_PATH

    # --- 核心修复：剔除 IPv6 地址 ---
    # RackNerd 等不支持 IPv6 的机器会导致 Permission denied
    # 这行命令会删除 Address 行中逗号后面的部分(即 IPv6 地址)
    sed -i '/^Address/s/,.*//' $CONF_PATH

    # --- 基础配置修改 ---
    # 1. 强制 DNS (避免污染)
    sed -i '/DNS/d' $CONF_PATH
    sed -i '/\[Interface\]/a DNS = 8.8.8.8, 1.1.1.1' $CONF_PATH

    # 2. 禁止接管全流量
    sed -i '/Table/d' $CONF_PATH
    sed -i '/\[Interface\]/a Table = off' $CONF_PATH

    # 3. 永久保活
    sed -i '/PersistentKeepalive/d' $CONF_PATH
    sed -i '/\[Peer\]/a PersistentKeepalive = 25' $CONF_PATH

    # 4. 路由脚本钩子
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

    # 重启接口
    wg-quick down warp >/dev/null 2>&1
    systemctl enable wg-quick@warp >/dev/null 2>&1
    systemctl restart wg-quick@warp

    echo -e "${GREEN}>>> ✅ 安装完成！正在检测...${NC}"
    sleep 3
    check_status
}

# ===================================================
# 2. 卸载逻辑
# ===================================================
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

# ===================================================
# 3. 状态检查
# ===================================================
check_status() {
    if ! systemctl is-active --quiet wg-quick@warp; then
        echo -e "服务状态: ${RED}未运行 (Failed)${NC}"
        echo -e "尝试查看日志: systemctl status wg-quick@warp"
        return
    fi

    LATEST_HANDSHAKE=$(wg show warp latest-handshakes | awk '{print $2}')
    if [ -z "$LATEST_HANDSHAKE" ] || [ "$LATEST_HANDSHAKE" = "0" ]; then
        echo -e "${RED}⚠️  警告：握手失败 (Handshake = 0)${NC}"
        return
    fi

    echo -e "WARP 状态: ${GREEN}运行正常 (握手成功)${NC}"
    
    # 强制使用 IPv4 测试 Gemini
    RESULT=$(curl -sI -4 -o /dev/null -w "%{http_code}" https://gemini.google.com --max-time 5)
    if [ "$RESULT" == "200" ] || [ "$RESULT" == "301" ] || [ "$RESULT" == "302" ]; then
        echo -e "Gemini 解锁: ${GREEN}成功 (Code: $RESULT)${NC}"
    else
        echo -e "Gemini 解锁: ${RED}失败 (Code: $RESULT)${NC}"
    fi
}

# ===================================================
# 菜单入口
# ===================================================
install_warp
EOF

# 运行生成的脚本
bash warp_google.sh
