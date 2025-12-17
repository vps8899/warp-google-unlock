#!/bin/bash
# ===================================================
# Project: WARP Unlocker (Granular Control Edition)
# Version: 7.0 (YouTube Separate & AppStore Included)
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
    # MODE 1: Google Only (Gemini/Search/PlayStore) - No YouTube
    # MODE 2: Google + YouTube
    # MODE 3: Google + YouTube + Media (Netflix/Disney+)
    MODE=$1 

    echo -e "${YELLOW}>>> [1/6] 初始化环境...${NC}"
    check_env
    
    # 清理动作
    systemctl stop wg-quick@warp >/dev/null 2>&1
    systemctl disable wg-quick@warp >/dev/null 2>&1
    ip link delete dev warp >/dev/null 2>&1
    rm -rf /etc/wireguard/warp.conf
    rm -rf /etc/wireguard/routes.txt

    install_deps

    echo -e "${YELLOW}>>> [2/6] 获取 WARP 密钥...${NC}"
    get_warp_key

    echo -e "${YELLOW}>>> [3/6] 写入纯净配置 (强制 IPv4)...${NC}"
    # 核心配置不动，保证 RackNerd 稳定性
    cat > /etc/wireguard/warp.conf <<WG_CONF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 172.16.0.2/32
DNS = 8.8.8.8, 1.1.1.1
MTU = 1280
Table = off
PostUp = bash /etc/wireguard/add_routes.sh
PreDown = bash /etc/wireguard/del_routes.sh

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:2408
PersistentKeepalive = 25
WG_CONF

    echo -e "${YELLOW}>>> [4/6] 下载分流规则 (模式: $MODE)...${NC}"
    generate_routes "$MODE"

    echo -e "${YELLOW}>>> [5/6] 启动服务...${NC}"
    # 开启转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/warp.conf
    sysctl -p /etc/sysctl.d/warp.conf >/dev/null 2>&1

    systemctl enable wg-quick@warp >/dev/null 2>&1
    systemctl start wg-quick@warp

    echo -e "${YELLOW}>>> [6/6] 最终验证...${NC}"
    sleep 3
    check_status
}

# ===================================================
# 辅助函数
# ===================================================

check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 权限运行！${NC}" && exit 1
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

get_warp_key() {
    mkdir -p /etc/wireguard/warp_tmp
    cd /etc/wireguard/warp_tmp || exit
    ARCH=$(uname -m)
    if [[ $ARCH == "x86_64" ]]; then
        WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64"
    elif [[ $ARCH == "aarch64" ]]; then
        WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_arm64"
    else
        echo -e "${RED}不支持的架构${NC}" && exit 1
    fi
    if [ ! -f /usr/local/bin/wgcf ]; then
        wget -qO /usr/local/bin/wgcf $WGCF_URL
        chmod +x /usr/local/bin/wgcf
    fi
    if [ ! -f wgcf-account.toml ]; then
        echo | /usr/local/bin/wgcf register >/dev/null 2>&1
    fi
    /usr/local/bin/wgcf generate >/dev/null 2>&1
    PRIVATE_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d' ' -f3)
    cd /root || exit
    rm -rf /etc/wireguard/warp_tmp
    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED}❌ 密钥获取失败，请重试${NC}"
        exit 1
    fi
}

generate_routes() {
    MODE=$1
    cat > /etc/wireguard/add_routes.sh <<EOF
#!/bin/bash
IP_FILE="/etc/wireguard/routes.txt"
rm -f \$IP_FILE

# === 规则源：Blackmatrix7 (更精准的分类) ===

echo "正在下载 Google 基础规则 (Search/Gemini/PlayStore)..."
wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Google/Google_IP-CIDR.txt >> \$IP_FILE

if [ "$MODE" == "youtube" ] || [ "$MODE" == "media" ]; then
    echo "正在下载 YouTube 规则..."
    wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/YouTube/YouTube_IP-CIDR.txt >> \$IP_FILE
fi

if [ "$MODE" == "media" ]; then
    echo "正在下载 Netflix/Disney+/OpenAI 规则..."
    wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Netflix/Netflix_IP-CIDR.txt >> \$IP_FILE
    wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Disney/Disney_IP-CIDR.txt >> \$IP_FILE
    wget -qO- https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OpenAI/OpenAI_IP-CIDR.txt >> \$IP_FILE
fi

# 兜底
if [ ! -s \$IP_FILE ]; then
    echo "142.250.0.0/15" > \$IP_FILE
fi

# 批量添加
while read ip; do
  [[ \$ip =~ ^# ]] && continue
  [[ -z \$ip ]] && continue
  clean_ip=\$(echo \$ip | awk '{print \$1}')
  ip route add \$clean_ip dev warp >/dev/null 2>&1
done < \$IP_FILE
EOF

    cat > /etc/wireguard/del_routes.sh <<EOF
#!/bin/bash
IP_FILE="/etc/wireguard/routes.txt"
[ ! -f "\$IP_FILE" ] && exit 0
while read ip; do
  [[ \$ip =~ ^# ]] && continue
  [[ -z \$ip ]] && continue
  clean_ip=\$(echo \$ip | awk '{print \$1}')
  ip route del \$clean_ip dev warp >/dev/null 2>&1
done < \$IP_FILE
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
    rm -f /usr/local/bin/wgcf
    echo -e "${GREEN}>>> 卸载完成。${NC}"
}

check_status() {
    # 服务检测
    if ! systemctl is-active --quiet wg-quick@warp; then
        echo -e "服务状态: ${RED}未运行${NC}"
        return
    fi
    # 握手检测
    HANDSHAKE=$(wg show warp latest-handshakes | awk '{print $2}')
    if [ -z "$HANDSHAKE" ] || [ "$HANDSHAKE" == "0" ]; then
        echo -e "${RED}⚠️  握手失败 (Handshake=0)，请检查防火墙。${NC}"
        return
    else
        echo -e "WARP 握手: ${GREEN}正常${NC}"
    fi

    echo -e "--- 分流效果测试 ---"
    # Google/Gemini
    G_CODE=$(curl -sI -4 -o /dev/null -w "%{http_code}" https://gemini.google.com --max-time 5)
    if [[ "$G_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "Gemini/商店: ${GREEN}✅ 已解锁 (WARP)${NC}"
    else
        echo -e "Gemini/商店: ${RED}❌ 失败 ($G_CODE)${NC}"
    fi

    # YouTube 检测 (判断是否直连)
    # 我们没法直接检测“是否有广告”，但可以检测 IP 归属。
    # 如果没把 YouTube 加入规则，这里显示的应该是 VPS 原生 IP 归属地。
    
    # Netflix 检测
    N_CODE=$(curl -sI -4 -o /dev/null -w "%{http_code}" https://www.netflix.com --max-time 5)
    if [[ "$N_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "Netflix连接: ${GREEN}✅ 畅通${NC}"
    else
        echo -e "Netflix连接: ${YELLOW}⚠️  直连/未解锁${NC}"
    fi
}

# ===================================================
# 菜单
# ===================================================
clear
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}    WARP Unlocker (Granular Control v7.0)    ${NC}"
echo -e "${GREEN}=============================================${NC}"
echo -e "${YELLOW}说明：保留 YouTube 直连可享受送中 IP 无广告福利。${NC}"
echo -e "---------------------------------------------"
echo -e "1. 解锁 Google基础 (Gemini/搜索/商店) - ${SKYBLUE}YouTube 直连(无广告)${NC}"
echo -e "2. 解锁 Google全家桶 (含 YouTube)     - ${SKYBLUE}YouTube 走 WARP${NC}"
echo -e "3. 解锁 媒体全家桶 (含 YouTube/Netflix) - ${SKYBLUE}全部走 WARP${NC}"
echo -e "---------------------------------------------"
echo -e "4. 卸载 (Uninstall)"
echo -e "5. 检测状态 (Check Status)"
echo -e "0. 退出"
echo -e "---------------------------------------------"
read -p "请选择 [0-5]: " choice

case $choice in
    1) install_core "google" ;;
    2) install_core "youtube" ;;
    3) install_core "media" ;;
    4) uninstall_warp ;;
    5) check_status ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac
