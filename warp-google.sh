#!/usr/bin/env bash
set -e

echo "=== Google / YouTube / Gemini 全域名 WARP 分流一键脚本（Debian 优化·最终版） ==="

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash warp-google.sh"
  exit 1
fi

########################################
# 1. 检测包管理器并安装依赖
########################################

detect_pkg() {
  if command -v apt >/dev/null 2>&1; then
    echo apt
  elif command -v apt-get >/dev/null 2>&1; then
    echo apt-get
  elif command -v yum >/dev/null 2>&1; then
    echo yum
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v pacman >/dev/null 2>&1; then
    echo pacman
  else
    echo ""
  fi
}

PKG_MANAGER=$(detect_pkg)

if [[ -z "$PKG_MANAGER" ]]; then
  echo "无法识别包管理器，请手动安装：curl wget iptables iproute2 jq"
  exit 1
fi

echo "[*] 使用包管理器：$PKG_MANAGER 安装依赖..."

case "$PKG_MANAGER" in
  apt|apt-get)
    $PKG_MANAGER update -y
    $PKG_MANAGER install -y curl wget iptables iproute2 jq
    ;;
  yum|dnf)
    $PKG_MANAGER install -y curl wget iptables iproute jq
    ;;
  pacman)
    pacman -Sy --noconfirm curl wget iptables iproute2 jq
    ;;
esac

########################################
# 2. 安装 wgcf，生成 / 复用 WARP WireGuard 配置
########################################

if ! command -v wgcf >/dev/null 2>&1; then
  echo "[*] 安装 wgcf..."
  WGCF_VER="2.2.18"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) WG_ARCH=amd64 ;;
    aarch64|arm64) WG_ARCH=arm64 ;;
    *)
      echo "暂不支持当前架构：$ARCH，需要手动安装 wgcf。"
      exit 1
      ;;
  esac

  wget -O /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WG_ARCH}"
  chmod +x /usr/local/bin/wgcf
fi

mkdir -p /etc/wireguard
cd /etc/wireguard

# 2.1 注册 WARP 账户（带重试），如已有有效账号则跳过
if [[ -f wgcf-account.toml && -s wgcf-account.toml ]]; then
  echo "[*] 检测到已有 wgcf-account.toml，跳过 register。"
else
  echo "[*] 未检测到 wgcf-account.toml，开始注册 WARP 账户..."
  export WGCF_ACCEPT_TOS=1

  RETRY=0
  MAX_RETRY=5
  while (( RETRY < MAX_RETRY )); do
    if wgcf register --accept-tos; then
      echo "[*] WARP 账户注册成功。"
      break
    else
      RETRY=$((RETRY+1))
      echo "[!] wgcf register 失败（第 ${RETRY} 次），稍后重试..."
      sleep 5
    fi
  done

  if (( RETRY >= MAX_RETRY )); then
    echo "[x] 多次尝试 wgcf register 仍失败，请稍后再试或检查网络。"
    exit 1
  fi
fi

# 2.2 生成 / 复用 wgcf-profile.conf
if [[ -f wgcf-profile.conf && -s wgcf-profile.conf ]]; then
  echo "[*] 检测到已有 wgcf-profile.conf，复用该配置。"
else
  echo "[*] 生成 WARP WireGuard 配置 wgcf-profile.conf ..."
  if ! wgcf generate -p wgcf-profile.conf; then
    echo "[x] wgcf generate 失败，请检查 wgcf 或网络。"
    exit 1
  fi
fi

PROFILE="/etc/wireguard/wgcf-profile.conf"

if [[ ! -f "$PROFILE" ]]; then
  echo "[x] 未找到 wgcf-profile.conf，无法继续。"
  exit 1
fi

########################################
# 3. 从 wgcf-profile.conf 中提取 WireGuard 参数
########################################

WG_PRIVATE_KEY=$(grep -m1 '^PrivateKey' "$PROFILE" | awk '{print $3}')
WG_PEER_PUBLIC_KEY=$(grep -m1 '^PublicKey' "$PROFILE" | awk '{print $3}')
WG_ENDPOINT=$(grep -m1 '^Endpoint' "$PROFILE" | awk '{print $3}')
ADDR_LINE=$(grep -m1 '^Address' "$PROFILE" | sed 's/Address *= *//')

WG_ADDR_V4=""
WG_ADDR_V6=""

# Address 一般类似：Address = 172.16.0.2/32, 2606:4700:xxxx::xxxx/128
# 我们按逗号拆分，分别判断是 v4 还是 v6，避免之前正则错误匹配出 "2/32"
IFS=',' read -ra ADDR_ARR <<< "$ADDR_LINE"
for token in "${ADDR_ARR[@]}"; do
  # 去掉前后空格和引号
  token=$(echo "$token" | sed 's/^[ "]*//;s/[ "]*$//')
  if [[ "$token" == *:* ]]; then
    WG_ADDR_V6="$token"
  elif [[ "$token" == *.* ]]; then
    WG_ADDR_V4="$token"
  fi
done

if [[ -z "$WG_PRIVATE_KEY" || -z "$WG_PEER_PUBLIC_KEY" || -z "$WG_ENDPOINT" ]]; then
  echo "[x] 从 wgcf-profile.conf 中提取 WARP 参数失败。"
  exit 1
fi

# 组装 local_address 数组（可能只有 v4 或只有 v6）
if [[ -n "$WG_ADDR_V4" && -n "$WG_ADDR_V6" ]]; then
  LOCAL_ADDRS="\"$WG_ADDR_V4\", \"$WG_ADDR_V6\""
elif [[ -n "$WG_ADDR_V4" ]]; then
  LOCAL_ADDRS="\"$WG_ADDR_V4\""
elif [[ -n "$WG_ADDR_V6" ]]; then
  LOCAL_ADDRS="\"$WG_ADDR_V6\""
else
  echo "[x] 未在 wgcf-profile.conf 中找到任何 Address（v4/v6），无法继续。"
  exit 1
fi

echo "[*] WARP Endpoint: $WG_ENDPOINT"
echo "[*] WARP IPv4: ${WG_ADDR_V4:-无}"
echo "[*] WARP IPv6: ${WG_ADDR_V6:-无}"

########################################
# 4. 安装 sing-box
########################################

if ! command -v sing-box >/dev/null 2>&1; then
  echo "[*] 安装 sing-box ..."
  curl -fsSL https://sing-box.app/install.sh | bash
fi

CONFIG_DIR="/etc/sing-box"
mkdir -p "$CONFIG_DIR"

########################################
# 5. 写入 sing-box 配置（TProxy + WARP + Google 全家桶分流）
########################################

CONFIG_PATH="$CONFIG_DIR/config.json"

cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "level": "info",
    "output": "stderr"
  },
  "dns": {
    "servers": [
      {
        "tag": "google-dns",
        "address": "8.8.8.8",
        "address_resolver": "local"
      },
      {
        "tag": "local",
        "address": "system"
      }
    ],
    "rules": [
      {
        "domain_suffix": [
          "google.com",
          "google.cn",
          "gstatic.com",
          "ggpht.com",
          "googleapis.com",
          "googleusercontent.com",
          "googlevideo.com",
          "gvt1.com",
          "gvt2.com",
          "withgoogle.com",
          "android.com",
          "youtube.com",
          "ytimg.com",
          "youtu.be",
          "youtube-nocookie.com",
          "yt.be",
          "gemini.google.com",
          "deepmind.com",
          "chrome.com",
          "chromium.org",
          "g.co",
          "goo.gl",
          "gmail.com",
          "drive.google.com",
          "docs.google.com",
          "meet.google.com",
          "hangouts.google.com",
          "play.google.com",
          "firebaseio.com",
          "snap.googleapis.com"
        ],
        "server": "google-dns"
      }
    ],
    "final": "local"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": 60080,
      "network": "tcp,udp",
      "sniff": true,
      "sniff_override_destination": true
    }
  ],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "warp",
      "server": "$(echo "$WG_ENDPOINT" | cut -d: -f1)",
      "server_port": $(echo "$WG_ENDPOINT" | cut -d: -f2),
      "local_address": [
        $LOCAL_ADDRS
      ],
      "private_key": "$WG_PRIVATE_KEY",
      "peer_public_key": "$WG_PEER_PUBLIC_KEY",
      "reserved": [1, 2, 3],
      "mtu": 1280
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": [
          "google.com",
          "google.cn",
          "gstatic.com",
          "ggpht.com",
          "googleapis.com",
          "googleusercontent.com",
          "googlevideo.com",
          "gvt1.com",
          "gvt2.com",
          "withgoogle.com",
          "android.com",
          "youtube.com",
          "ytimg.com",
          "youtu.be",
          "youtube-nocookie.com",
          "yt.be",
          "gemini.google.com",
          "deepmind.com",
          "chrome.com",
          "chromium.org",
          "g.co",
          "goo.gl",
          "gmail.com",
          "drive.google.com",
          "docs.google.com",
          "meet.google.com",
          "hangouts.google.com",
          "play.google.com",
          "firebaseio.com",
          "snap.googleapis.com"
        ],
        "outbound": "warp"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

echo "[*] sing-box 配置已写入：$CONFIG_PATH"

########################################
# 6. 配置 TProxy 防火墙规则脚本（稳健版）
########################################

TPROXY_SCRIPT="/usr/local/bin/singbox-tproxy.sh"

cat > "$TPROXY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -e

# 只清理我们自己的链，避免影响其他 mangle 规则
iptables -t mangle -F SINGBOX 2>/dev/null || true
iptables -t mangle -D PREROUTING -p tcp -j SINGBOX 2>/dev/null || true
iptables -t mangle -D PREROUTING -p udp -j SINGBOX 2>/dev/null || true
iptables -t mangle -X SINGBOX 2>/dev/null || true

if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t mangle -F SINGBOX 2>/dev/null || true
  ip6tables -t mangle -D PREROUTING -p tcp -j SINGBOX 2>/dev/null || true
  ip6tables -t mangle -D PREROUTING -p udp -j SINGBOX 2>/dev/null || true
  ip6tables -t mangle -X SINGBOX 2>/dev/null || true
fi

# 新建链并接管 TCP/UDP 流量（IPv4）
iptables -t mangle -N SINGBOX
# 不处理本地回环
iptables -t mangle -A SINGBOX -d 127.0.0.1/32 -j RETURN
# 将 TCP/UDP 导入 TProxy
iptables -t mangle -A SINGBOX -p tcp -j TPROXY --on-port 60080 --tproxy-mark 1
iptables -t mangle -A SINGBOX -p udp -j TPROXY --on-port 60080 --tproxy-mark 1
# PREROUTING 引流
iptables -t mangle -A PREROUTING -p tcp -j SINGBOX
iptables -t mangle -A PREROUTING -p udp -j SINGBOX

# IPv6 部分是可选的，如果系统不支持 IPv6 或没开启，相关错误会被忽略
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t mangle -N SINGBOX
  ip6tables -t mangle -A SINGBOX -d ::1/128 -j RETURN
  ip6tables -t mangle -A SINGBOX -p tcp -j TPROXY --on-port 60080 --tproxy-mark 1
  ip6tables -t mangle -A SINGBOX -p udp -j TPROXY --on-port 60080 --tproxy-mark 1
  ip6tables -t mangle -A PREROUTING -p tcp -j SINGBOX
  ip6tables -t mangle -A PREROUTING -p udp -j SINGBOX
fi

# ip rule + route，确保 mark=1 的流量回到本机（透明代理）

# 先删旧的，忽略错误
ip rule del fwmark 1 lookup 100 2>/dev/null || true
ip -6 rule del fwmark 1 lookup 100 2>/dev/null || true
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true

# 再加新的，忽略 "File exists" 等错误
ip rule add fwmark 1 lookup 100 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

# IPv6 路由是可选的，系统没开 IPv6 也无所谓
ip -6 rule add fwmark 1 lookup 100 2>/dev/null || true
ip -6 route add local ::/0 dev lo table 100 2>/dev/null || true

echo "TProxy 防火墙规则已应用。"
EOF

chmod +x "$TPROXY_SCRIPT"

########################################
# 7. systemd 服务：TProxy + sing-box
########################################

TPROXY_SERVICE="/etc/systemd/system/singbox-tproxy.service"

cat > "$TPROXY_SERVICE" <<EOF
[Unit]
Description=sing-box TProxy 防火墙规则
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$TPROXY_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo "[*] 启用并启动 sing-box 与 TProxy 服务..."

# 使用安装包自带的 sing-box.service（Debian .deb 安装会提供）
if systemctl list-unit-files | grep -q '^sing-box.service'; then
  systemctl enable --now sing-box.service
else
  # 兜底：如果没有自带 service，则创建一个简单的
  cat > /etc/systemd/system/sing-box.service <<EOT
[Unit]
Description=sing-box proxy service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$(command -v sing-box) run -c $CONFIG_PATH
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT
  systemctl daemon-reload
  systemctl enable --now sing-box.service
fi

systemctl enable --now singbox-tproxy.service

echo "=== 完成！==="
echo "现在系统默认走 VPS 原始出口，所有 Google / YouTube / Gemini 等域名走 WARP。"
echo "测试示例："
echo "  curl https://www.google.com  # IP 应该是 Cloudflare / WARP 段"
echo "  curl https://ifconfig.me     # IP 应该还是你的 VPS 原 IP"
