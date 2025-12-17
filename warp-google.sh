cat > force_fix_warp.sh << 'EOF'
#!/bin/bash
# ===================================================
# Project: WARP Google Unlock (Reconstruct Strategy)
# Version: 5.0 (Final Robust - RackNerd/IPv4 Only)
# ===================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${YELLOW}>>> [1/6] 初始化环境与依赖...${NC}"

# 1. 停止并清理旧服务 (防止占用)
systemctl stop wg-quick@warp >/dev/null 2>&1
systemctl disable wg-quick@warp >/dev/null 2>&1
ip link delete dev warp >/dev/null 2>&1
rm -rf /etc/wireguard/warp.conf

# 2. 安装必要工具
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y wireguard-tools curl wget git lsb-release openresolv >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y wireguard-tools curl wget git openresolv >/dev/null 2>&1
fi

# 3. 检查 TUN
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 >/dev/null 2>&1
    chmod 600 /dev/net/tun >/dev/null 2>&1
fi

echo -e "${YELLOW}>>> [2/6] 获取 WARP 密钥...${NC}"
mkdir -p /etc/wireguard/warp_tmp
cd /etc/wireguard/warp_tmp || exit

# 下载 wgcf
ARCH=$(uname -m)
if [[ $ARCH == "x86_64" ]]; then
    WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64"
elif [[ $ARCH == "aarch64" ]]; then
    WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_arm64"
else
    echo -e "${RED}不支持的架构${NC}" && exit 1
fi

wget -qO /usr/local/bin/wgcf $WGCF_URL
chmod +x /usr/local/bin/wgcf

# 注册账号
if [ ! -f wgcf-account.toml ]; then
    echo | /usr/local/bin/wgcf register >/dev/null 2>&1
fi
/usr/local/bin/wgcf generate >/dev/null 2>&1

# === 关键步骤：提取私钥 ===
# 我们不再复制整个文件，只提取 PrivateKey，避免任何格式污染
PRIVATE_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d' ' -f3)

if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}❌ 获取 WARP 密钥失败，请检查网络或重试。${NC}"
    exit 1
fi

cd /root || exit
rm -rf /etc/wireguard/warp_tmp

echo -e "${YELLOW}>>> [3/6] 写入纯净配置文件 (强制 IPv4)...${NC}"

# === 核心：从零写入配置文件 ===
# 直接硬编码 Endpoint IP (162.159.192.1)，避开 DNS 解析
# 直接硬编码 Address (172.16.0.2)，避开 IPv6
cat > /etc/wireguard/warp.conf <<WG_CONF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 172.16.0.2/32
DNS = 8.8.8.8, 1.1.1.1
MTU = 1280
Table = off
PostUp = bash /etc/wireguard/add_google_routes.sh
PreDown = bash /etc/wireguard/del_google_routes.sh

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:2408
PersistentKeepalive = 25
WG_CONF

echo -e "${YELLOW}>>> [4/6] 生成路由脚本...${NC}"
# 生成添加路由脚本
cat > /etc/wireguard/add_google_routes.sh << 'SCRIPT_EOF'
#!/bin/bash
IP_LIST="/etc/wireguard/google_ips.txt"
# 尝试下载 IP 列表，如果失败则使用保底列表
wget -T 10 -t 3 -qO $IP_LIST https://raw.githubusercontent.com/mayaxcn/china-ip-list/master/google.txt
if [ ! -s $IP_LIST ]; then
    # 保底 IP 段 (Gemini/Google API 常用段)
    echo "142.250.0.0/15" > $IP_LIST
    echo "172.217.0.0/16" >> $IP_LIST
fi

while read ip; do
  [[ $ip =~ ^# ]] && continue
  [[ -z $ip ]] && continue
  ip route add $ip dev warp >/dev/null 2>&1
done < $IP_LIST
SCRIPT_EOF

# 生成删除路由脚本
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

echo -e "${YELLOW}>>> [5/6] 启动服务...${NC}"
# 开启转发
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/warp.conf
sysctl -p /etc/sysctl.d/warp.conf >/dev/null 2>&1

systemctl enable wg-quick@warp >/dev/null 2>&1
systemctl start wg-quick@warp

echo -e "${YELLOW}>>> [6/6] 最终检测...${NC}"
sleep 2

# 1. 检查握手
HANDSHAKE=$(wg show warp latest-handshakes | awk '{print $2}')
if [ -z "$HANDSHAKE" ] || [ "$HANDSHAKE" == "0" ]; then
    echo -e "${RED}❌ 严重错误：握手失败 (Handshake=0)${NC}"
    echo -e "这通常意味着 RackNerd 的网络环境极其特殊，或者端口被封。"
    echo -e "当前尝试连接 Endpoint: 162.159.192.1:2408 (Cloudflare IP)"
else
    # 计算握手时间
    NOW=$(date +%s)
    DIFF=$((NOW - HANDSHAKE))
    echo -e "${GREEN}✅ 握手成功！(上一次握手在 $DIFF 秒前)${NC}"
    
    # 2. 检查 Gemini
    HTTP_CODE=$(curl -sI -4 -o /dev/null -w "%{http_code}" https://gemini.google.com --max-time 10)
    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}🎉 恭喜！Gemini 解锁成功 (HTTP $HTTP_CODE)${NC}"
        echo -e "你的脚本逻辑已通过验证，可以上传到 GitHub 了。"
    else
        echo -e "${RED}⚠️  握手虽然成功，但 Gemini 访问返回: $HTTP_CODE${NC}"
    fi
fi
EOF

# 运行脚本
bash force_fix_warp.sh
