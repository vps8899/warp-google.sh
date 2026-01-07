#!/bin/bash

# WARP 一键脚本 - 让 Google 流量自动走 WARP
# 运行后无需任何配置，Google 相关服务直接可用

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Google IP 段 (包含主要服务)
GOOGLE_IPS=(
    "8.8.4.0/24"
    "8.8.8.0/24"
    "8.34.208.0/20"
    "8.35.192.0/20"
    "23.236.48.0/20"
    "23.251.128.0/19"
    "34.0.0.0/15"
    "34.2.0.0/16"
    "34.3.0.0/23"
    "34.4.0.0/14"
    "34.8.0.0/13"
    "34.16.0.0/12"
    "34.32.0.0/11"
    "34.64.0.0/10"
    "34.128.0.0/10"
    "35.184.0.0/13"
    "35.192.0.0/14"
    "35.196.0.0/15"
    "35.198.0.0/16"
    "35.199.0.0/17"
    "35.199.128.0/18"
    "35.200.0.0/13"
    "35.208.0.0/12"
    "35.224.0.0/12"
    "35.240.0.0/13"
    "64.233.160.0/19"
    "66.102.0.0/20"
    "66.249.64.0/19"
    "70.32.128.0/19"
    "72.14.192.0/18"
    "74.125.0.0/16"
    "104.132.0.0/14"
    "104.154.0.0/15"
    "104.196.0.0/14"
    "104.237.160.0/19"
    "107.167.160.0/19"
    "107.178.192.0/18"
    "108.59.80.0/20"
    "108.170.192.0/18"
    "108.177.0.0/17"
    "130.211.0.0/16"
    "136.112.0.0/12"
    "142.250.0.0/15"
    "146.148.0.0/17"
    "162.216.148.0/22"
    "162.222.176.0/21"
    "172.110.32.0/21"
    "172.217.0.0/16"
    "172.253.0.0/16"
    "173.194.0.0/16"
    "173.255.112.0/20"
    "192.158.28.0/22"
    "192.178.0.0/15"
    "193.186.4.0/24"
    "199.36.154.0/23"
    "199.36.156.0/24"
    "199.192.112.0/22"
    "199.223.232.0/21"
    "207.223.160.0/20"
    "208.65.152.0/22"
    "208.68.108.0/22"
    "208.81.188.0/22"
    "208.117.224.0/19"
    "209.85.128.0/17"
    "216.58.192.0/19"
    "216.73.80.0/20"
    "216.239.32.0/19"
)

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════╗"
echo "║     🌐 WARP 一键脚本 - Google 自动解锁 🌐           ║"
echo "╚════════════════════════════════════════════════════╝"
echo -e "${NC}"

# 检查 root
[[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }

# 检测系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}无法检测系统${NC}"; exit 1
fi

echo -e "${GREEN}系统: $OS $(uname -m)${NC}"

# 显示当前 IP
echo -e "\n${YELLOW}当前 IP 信息:${NC}"
CURRENT_IP=$(curl -4 -s --max-time 5 ip.sb)
IP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$CURRENT_IP?lang=zh-CN" 2>/dev/null)
echo -e "IP: ${GREEN}$CURRENT_IP${NC}"
echo -e "位置: ${GREEN}$(echo $IP_INFO | grep -oP '"country":"\K[^"]+') - $(echo $IP_INFO | grep -oP '"city":"\K[^"]+')${NC}"

# 安装 WireGuard
echo -e "\n${CYAN}[1/4] 安装 WireGuard...${NC}"
case $OS in
    ubuntu|debian)
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wireguard-tools curl wget >/dev/null 2>&1
        ;;
    centos|rhel|rocky|almalinux|fedora)
        if command -v dnf &>/dev/null; then
            dnf install -y epel-release >/dev/null 2>&1
            dnf install -y wireguard-tools curl wget >/dev/null 2>&1
        else
            yum install -y epel-release >/dev/null 2>&1
            yum install -y wireguard-tools curl wget >/dev/null 2>&1
        fi
        ;;
    alpine)
        apk add wireguard-tools curl wget >/dev/null 2>&1
        ;;
    *)
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wireguard-tools curl wget >/dev/null 2>&1
        ;;
esac
echo -e "${GREEN}✓ WireGuard 已安装${NC}"

# 下载 wgcf
echo -e "\n${CYAN}[2/4] 下载 wgcf...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armhf" ;;
esac

mkdir -p /etc/wireguard
cd /etc/wireguard

# 尝试多个下载源
wget -q -O /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_$ARCH" 2>/dev/null || \
wget -q -O /usr/local/bin/wgcf "https://mirror.ghproxy.com/https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_$ARCH" 2>/dev/null || \
wget -q -O /usr/local/bin/wgcf "https://gh-proxy.com/https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_$ARCH" 2>/dev/null

chmod +x /usr/local/bin/wgcf
echo -e "${GREEN}✓ wgcf 已下载${NC}"

# 注册 WARP 并生成配置
echo -e "\n${CYAN}[3/4] 注册 WARP 账户...${NC}"
cd /etc/wireguard

# 清理旧配置
rm -f wgcf-account.toml wgcf-profile.conf warp.conf 2>/dev/null

# 注册
wgcf register --accept-tos >/dev/null 2>&1
wgcf generate >/dev/null 2>&1

if [ ! -f wgcf-profile.conf ]; then
    echo -e "${RED}WARP 注册失败${NC}"
    exit 1
fi

# 提取密钥
PRIVATE_KEY=$(grep PrivateKey wgcf-profile.conf | cut -d= -f2 | tr -d ' ')
ADDRESS4=$(grep -oP 'Address = \K[0-9./]+' wgcf-profile.conf | head -1)

echo -e "${GREEN}✓ WARP 账户已注册${NC}"

# 生成配置文件 - 只让 Google IP 走 WARP
echo -e "\n${CYAN}[4/4] 配置路由规则...${NC}"

# 构建 AllowedIPs (只包含 Google IP)
ALLOWED_IPS=""
for ip in "${GOOGLE_IPS[@]}"; do
    ALLOWED_IPS="${ALLOWED_IPS}${ip}, "
done
# 移除最后的逗号和空格
ALLOWED_IPS="${ALLOWED_IPS%, }"

cat > /etc/wireguard/warp.conf << EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $ADDRESS4
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = $ALLOWED_IPS
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
EOF

echo -e "${GREEN}✓ 路由规则已配置 (${#GOOGLE_IPS[@]} 个 Google IP 段)${NC}"

# 停止可能存在的旧连接
wg-quick down warp 2>/dev/null

# 启动 WARP
echo -e "\n${CYAN}启动 WARP...${NC}"
wg-quick up warp

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ WARP 已启动${NC}"
else
    echo -e "${RED}WARP 启动失败${NC}"
    exit 1
fi

# 设置开机自启
systemctl enable wg-quick@warp 2>/dev/null

# 等待连接稳定
sleep 3

# 测试
echo -e "\n${CYAN}测试连接...${NC}"

# 测试 Google
GOOGLE_TEST=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
if [ "$GOOGLE_TEST" = "200" ]; then
    echo -e "${GREEN}✓ Google 连接成功！${NC}"
else
    echo -e "${YELLOW}Google 测试返回: $GOOGLE_TEST (可能需要等待几秒)${NC}"
fi

# 显示 WARP IP (访问 Google 时使用的 IP)
WARP_IP=$(curl -s --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K[^"]+' 2>/dev/null)
if [ -n "$WARP_IP" ]; then
    WARP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$WARP_IP?lang=zh-CN" 2>/dev/null)
    echo -e "WARP IP: ${GREEN}$WARP_IP${NC}"
    echo -e "WARP 位置: ${GREEN}$(echo $WARP_INFO | grep -oP '"country":"\K[^"]+') - $(echo $WARP_INFO | grep -oP '"city":"\K[^"]+')${NC}"
fi

# 创建管理脚本
cat > /usr/local/bin/warp << 'WARPSCRIPT'
#!/bin/bash
case "$1" in
    status) wg show warp ;;
    start) wg-quick up warp && echo "WARP 已启动" ;;
    stop) wg-quick down warp && echo "WARP 已停止" ;;
    restart) wg-quick down warp 2>/dev/null; wg-quick up warp && echo "WARP 已重启" ;;
    test) 
        echo "测试 Google..."
        curl -s --max-time 10 -o /dev/null -w "状态: %{http_code}\n" https://www.google.com
        ;;
    uninstall)
        wg-quick down warp 2>/dev/null
        systemctl disable wg-quick@warp 2>/dev/null
        rm -f /etc/wireguard/warp.conf /etc/wireguard/wgcf* /usr/local/bin/wgcf /usr/local/bin/warp
        echo "WARP 已卸载"
        ;;
    *)
        echo "用法: warp {status|start|stop|restart|test|uninstall}"
        ;;
esac
WARPSCRIPT
chmod +x /usr/local/bin/warp

# 完成
echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            🎉 安装完成！Google 已解锁 🎉            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo -e "\n${YELLOW}所有 Google 流量现已自动通过 WARP！${NC}"
echo -e "${YELLOW}无需任何额外配置，直接访问即可。${NC}"
echo -e "\n管理命令: ${CYAN}warp {status|start|stop|restart|test|uninstall}${NC}\n"
