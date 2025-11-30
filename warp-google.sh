#!/usr/bin/env bash
set -e

echo "=== Google / YouTube / Gemini 全域名 WARP 分流一键脚本（Debian 优化） ==="

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash warp-google.sh"
  exit 1
fi

# ---- 1. 检测包管理器并安装依赖 ----
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

# ---- 2. 安装 wgcf，生成 WARP WireGuard 配置 ----
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

if [[ ! -f wgcf-account.toml ]]; then
  echo "[*] 注册 WARP 账户（wgcf）..."
  export WGCF_ACCEPT_TOS=1
  wgcf register --accept-tos || true
fi

echo "[*] 生成 WARP 配置 wgcf-profile.conf ..."
wgcf generate -f wgcf-profile.conf

if [[ ! -f wgcf-profile.conf ]]; then
  echo "生成 wgcf-profile.conf 失败，请检查 wgcf 输出。"
  exit 1
fi

# ---- 3. 从 wgcf-profile.conf 中提取 WireGuard 参数 ----
PROFILE="/etc/wireguard/wgcf-profile.conf"

WG_PRIVATE_KEY=$(grep -m1 '^PrivateKey' "$PROFILE" | awk '{print $3}')
WG_PEER_PUBLIC_KEY=$(grep -m1 '^PublicKey' "$PROFILE" | awk '{print $3}')
WG_ENDPOINT=$(grep -m1 '^Endpoint' "$PROFILE" | awk '{print $3}')
ADDR_LINE=$(grep -m1 '^Address' "$PROFILE" | sed 's/Address *= *//')

WG_ADDR_V4=$(echo "$ADDR_LINE" | grep -oE '([0-9]+\.){3}[0-9]+/[0-9]+' || true)
WG_ADDR_V6=$(echo "$ADDR_LINE" | grep -oE '([0-9a-fA-F:]+)/[0-9]+' || true)

if [[ -z "$WG_PRIVATE_KEY" || -z "$WG_PEER_PUBLIC_KEY" || -z "$WG_ENDPOINT" ]]; then
  echo "从 wgcf-profile.conf 中提取 WARP 参数失败。"
  exit 1
fi

echo "[*] WARP Endpoint: $WG_ENDPOINT"
echo "[*] WARP IPv4: ${WG_ADDR_V4:-无}"
echo "[*] WARP IPv6: ${WG_ADDR_V6:-无}"

# ---- 4. 安装 sing-box ----
if ! command -v sing-box >/dev/null 2>&1; then
  echo "[*] 安装 sing-box ..."
  curl -fsSL https://sing-box.app/install.sh | bash
fi

mkdir -p /usr/local/etc/sing-box

# ---- 5. 写入 sing-box 配置（TProxy + WARP + Google 全家桶分流） ----
CONFIG_PATH="/usr/local/etc/sing-box/config.json"

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
        "$WG_ADDR_V4",
        "$WG_ADDR_V6"
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

# ---- 6. 配置 TProxy 防火墙规则脚本 ----
TPROXY_SCRIPT="/usr/local/bin/singbox-tproxy.sh"

cat > "$TPROXY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -e

# 清空旧规则
iptables -t mangle -F
iptables -t mangle -X SINGBOX 2>/dev/null || true

ip6tables -t mangle -F
ip6tables -t mangle -X SINGBOX 2>/dev/null || true

# 新建链
iptables -t mangle -N SINGBOX
ip6tables -t mangle -N SINGBOX

# 不处理本地回环
iptables -t mangle -A SINGBOX -d 127.0.0.1/32 -j RETURN
ip6tables -t mangle -A SINGBOX -d ::1/128 -j RETURN

# 可选：不处理局域网，如果是纯 VPS 通常没有
# iptables -t mangle -A SINGBOX -d 10.0.0.0/8 -j RETURN
# iptables -t mangle -A SINGBOX -d 192.168.0.0/16 -j RETURN
# iptables -t mangle -A SINGBOX -d 172.16.0.0/12 -j RETURN

# 将 TCP/UDP 导入 TProxy
iptables -t mangle -A SINGBOX -p tcp -j TPROXY --on-port 60080 --tproxy-mark 1
iptables -t mangle -A SINGBOX -p udp -j TPROXY --on-port 60080 --tproxy-mark 1

ip6tables -t mangle -A SINGBOX -p tcp -j TPROXY --on-port 60080 --tproxy-mark 1
ip6tables -t mangle -A SINGBOX -p udp -j TPROXY --on-port 60080 --tproxy-mark 1

# PREROUTING 引流
iptables -t mangle -A PREROUTING -p tcp -j SINGBOX
iptables -t mangle -A PREROUTING -p udp -j SINGBOX

ip6tables -t mangle -A PREROUTING -p tcp -j SINGBOX
ip6tables -t mangle -A PREROUTING -p udp -j SINGBOX

# ip rule + route，确保 1 mark 流量回到本机
ip rule del fwmark 1 lookup 100 2>/dev/null || true
ip -6 rule del fwmark 1 lookup 100 2>/dev/null || true
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true

ip rule add fwmark 1 lookup 100
ip -6 rule add fwmark 1 lookup 100

ip route add local 0.0.0.0/0 dev lo table 100
ip -6 route add local ::/0 dev lo table 100

echo "TProxy 防火墙规则已应用。"
EOF

chmod +x "$TPROXY_SCRIPT"

# ---- 7. systemd 服务：firewall + sing-box ----
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

# 某些安装脚本创建的服务名是 sing-box.service
if systemctl list-unit-files | grep -q '^sing-box.service'; then
  systemctl enable --now sing-box.service
else
  # 兜底：创建一个简单的 sing-box systemd 服务
  cat > /etc/systemd/system/sing-box.service <<EOT
[Unit]
Description=sing-box proxy service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
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
