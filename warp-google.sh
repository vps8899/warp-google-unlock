#!/bin/bash
# ===================================================
# Project: WARP Unlocker (Smart Fallback v8.1)
# Version: 8.1 (Auto-Downgrade if IPv6 Fails)
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
    MODE=$1 

    echo -e "${YELLOW}>>> [1/7] 初始化与环境检测...${NC}"
    check_root
    check_tun
    install_deps
    
    # 1. 初步检测 IPv6 (RackNerd 可能会在这里骗过检测)
    HAS_IPV6=false
    if ping6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; then
        HAS_IPV6=true
        echo -e "环境检测: ${GREEN}双栈网络 (IPv4 + IPv6)${NC}"
    else
        echo -e "环境检测: ${YELLOW}单栈网络 (仅 IPv4)${NC}"
    fi

    # 清理旧环境
    systemctl stop wg-quick@warp >/dev/null 2>&1
    systemctl disable wg-quick@warp >/dev/null 2>&1
    ip link delete dev warp >/dev/null 2>&1
    rm -rf /etc/wireguard/warp.conf
    rm -rf /etc/wireguard/routes.txt
    rm -rf /etc/wireguard/routes6.txt

    echo -e "${YELLOW}>>> [2/7] 获取 WARP 账户与密钥...${NC}"
    get_warp_profile

    echo -e "${YELLOW}>>> [3/7] 生成初始配置...${NC}"
    
    PRIVATE_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d' ' -f3)
    ORIG_ADDR=$(grep 'Address' wgcf-profile.conf | cut -d'=' -f2 | tr -d ' ')
    
    # 根据检测结果决定初始 Address
    if [ "$HAS_IPV6" = true ]; then
        FINAL_ADDR="$ORIG_ADDR"
        DNS_STR="8.8.8.8, 1.1.1.1, 2001:4860:4860::8888"
        ALLOWED_IPS="0.0.0.0/0, ::/0"
    else
        FINAL_ADDR=$(echo "$ORIG_ADDR" | cut -d',' -f1)
        DNS_STR="8.8.8.8, 1.1.1.1"
        ALLOWED_IPS="0.0.0.0/0"
    fi

    write_conf "$PRIVATE_KEY" "$FINAL_ADDR" "$DNS_STR" "$ALLOWED_IPS"

    echo -e "${YELLOW}>>> [4/7] 下载分流规则 (模式: $MODE)...${NC}"
    generate_routes "$MODE" "$HAS_IPV6"

    echo -e "${YELLOW}>>> [5/7] 首次启动服务...${NC}"
    # 开启转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/warp.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/warp.conf
    sysctl -p /etc/sysctl.d/warp.conf >/dev/null 2>&1

    systemctl enable wg-quick@warp >/dev/null 2>&1
    if systemctl start wg-quick@warp; then
        echo -e "${GREEN}>>> 启动成功！${NC}"
        FINAL_IPV6_STATUS=$HAS_IPV6
    else
        # === 核心修复逻辑：自动降级 ===
        echo -e "${RED}>>> 启动失败！检测到可能的 IPv6 兼容性问题 (RackNerd Trap)。${NC}"
        echo -e "${YELLOW}>>> 正在触发自动降级机制：强制切换为纯 IPv4 模式重试...${NC}"
        
        # 1. 强制只取 IPv4 地址
        IPV4_ONLY_ADDR=$(echo "$ORIG_ADDR" | cut -d',' -f1)
        # 2. 重写配置文件
        write_conf "$PRIVATE_KEY" "$IPV4_ONLY_ADDR" "8.8.8.8, 1.1.1.1" "0.0.0.0/0"
        # 3. 重新生成路由 (强制 disable IPv6)
        generate_routes "$MODE" "false"
        
        # 4. 重试启动
        if systemctl restart wg-quick@warp; then
            echo -e "${GREEN}>>> 降级重试成功！已切换为纯 IPv4 模式。${NC}"
            FINAL_IPV6_STATUS="false"
        else
            echo -e "${RED}>>> 严重错误：纯 IPv4 模式也无法启动。请检查系统日志。${NC}"
            exit 1
        fi
    fi

    echo -e "${YELLOW}>>> [6/7] 最终验证...${NC}"
    sleep 3
    check_status "$FINAL_IPV6_STATUS"
}

# ===================================================
# 辅助函数模块
# ===================================================

write_conf() {
    local key=$1
    local addr=$2
    local dns=$3
    local allowed=$4
    
    cat > /etc/wireguard/warp.conf <<WG_CONF
[Interface]
PrivateKey = $key
Address = $addr
DNS = $dns
MTU = 1280
Table = off
PostUp = bash /etc/wireguard/add_routes.sh
PreDown = bash /etc/wireguard/del_routes.sh

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = $allowed
Endpoint = 162.159.192.1:2408
PersistentKeepalive = 25
WG_CONF
}

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
        echo -e "${RED}❌ WARP 配置文件生成失败，请检查网络连接${NC}"
        exit 1
    fi
    cp wgcf-profile.conf profile_backup.conf
}

generate_routes() {
    MODE=$1
    IPV6_ENABLED=$2
    
    cat > /etc/wireguard/add_routes.sh <<EOF
#!/bin/bash
IP_FILE="/etc/wireguard/routes.txt"
IP6_FILE="/etc/wireguard/routes6.txt"
rm -f \$IP_FILE \$IP6_FILE

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

if [ "$IPV6_ENABLED" = true ]; then
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
    HAS_IPV6=$1
    if ! systemctl is-active --quiet wg-quick@warp; then
        echo -e "服务状态: ${RED}未运行${NC}"
        return
    fi
    
    HANDSHAKE=$(wg show warp latest-handshakes | awk '{print $2}')
    if [ -z "$HANDSHAKE" ] || [ "$HANDSHAKE" == "0" ]; then
        echo -e "${RED}⚠️  握手失败 (Handshake=0)${NC}"
        return
    else
        echo -e "WARP 握手: ${GREEN}正常 (Mode: $([ "$HAS_IPV6" = true ] && echo "IPv4+IPv6" || echo "IPv4-Only"))${NC}"
    fi

    echo -e "--- 分流效果测试 ---"
    G4_CODE=$(curl -sI -4 -o /dev/null -w "%{http_code}" https://gemini.google.com --max-time 5)
    if [[ "$G4_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "Gemini (IPv4): ${GREEN}✅ 已解锁${NC}"
    else
        echo -e "Gemini (IPv4): ${RED}❌ 失败 ($G4_CODE)${NC}"
    fi

    if [ "$HAS_IPV6" = true ]; then
        G6_CODE=$(curl -sI -6 -o /dev/null -w "%{http_code}" https://gemini.google.com --max-time 5)
        if [[ "$G6_CODE" =~ ^(200|301|302)$ ]]; then
            echo -e "Gemini (IPv6): ${GREEN}✅ 已解锁${NC}"
        else
            echo -e "Gemini (IPv6): ${RED}❌ 失败 (IPv6不可用)${NC}"
        fi
    fi
}

# ===================================================
# 菜单
# ===================================================
clear
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}   WARP Unlocker (Smart Fallback v8.1)       ${NC}"
echo -e "${GREEN}=============================================${NC}"
echo -e "${YELLOW}自动检测双栈 -> 失败自动降级 IPv4${NC}"
echo -e "---------------------------------------------"
echo -e "1. 解锁 Google基础 (Gemini/搜索) - ${SKYBLUE}YouTube 直连(无广告)${NC}"
echo -e "2. 解锁 Google全家桶 (含 YouTube) - ${SKYBLUE}YouTube 走 WARP${NC}"
echo -e "3. 解锁 媒体全家桶 (含 YouTube/Netflix)"
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
    5) check_status "false" ;; 
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac
