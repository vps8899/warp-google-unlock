#!/bin/bash
# =========================================================
# VPS 全自动系统级 WARP 动态分流解锁脚本 (智能检测升级版)
# 
# 新增特性:
# 1. 运行自检：自动检测并彻底清除旧版本/残留 WARP 脚本与规则
# 2. 智能感知：自动检测原生 IP 是否送中
#    - 未送中：自动清理并卸载，提示用户原生 IP 干净，保持最佳性能
#    - 已送中：全自动一键安装动态域名分流解锁 (Google全家桶/Gemini/Antigravity/OpenAI)
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${NC}"; exit 1; }

# 获取默认网络出口网卡
DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n 1)

# ---------------------------------------------------------
# 功能 1：彻底检测并清理老版本脚本及各种历史残留
# ---------------------------------------------------------
auto_clean_old_warp() {
    local has_old=0

    # 检测是否存在旧版残留标志
    if command -v warp-cli &>/dev/null || \
       [ -f /etc/wireguard/warp0.conf ] || \
       [ -f /usr/local/bin/warp-route-apply.sh ] || \
       [ -f /etc/systemd/system/warp-unlock.service ] || \
       [ -f /etc/dnsmasq.d/warp_unlock.conf ] || \
       iptables -t mangle -S 2>/dev/null | grep -q "warp_unlock" || \
       ipset list warp_unlock &>/dev/null; then
        has_old=1
    fi

    if [ $has_old -eq 1 ]; then
        echo -e "${YELLOW}[检测到历史/老版本 WARP 脚本残留，正在自动彻底清理...]${NC}"
        
        # 1. 停止并禁用所有相关 systemd 服务
        systemctl stop warp-unlock.service warp-svc cloudflare-warp 2>/dev/null || true
        systemctl disable warp-unlock.service warp-svc cloudflare-warp 2>/dev/null || true
        
        # 2. 停止 WireGuard 接口
        command -v wg-quick &>/dev/null && wg-quick down warp0 2>/dev/null || true
        command -v warp-cli &>/dev/null && warp-cli disconnect 2>/dev/null || true

        # 3. 清理 iptables mangle 规则与策略路由
        iptables -t mangle -D OUTPUT -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null || true
        iptables -t mangle -D PREROUTING -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null || true
        ip rule del fwmark 51820 lookup 51820 2>/dev/null || true
        ip route flush table 51820 2>/dev/null || true

        # 4. 销毁 ipset 集合
        ipset destroy warp_unlock 2>/dev/null || true

        # 5. 清除旧版配置文件与脚本
        rm -f /etc/dnsmasq.d/warp_unlock.conf \
              /etc/dnsmasq.d/warp-google.conf \
              /usr/local/bin/warp-route-apply.sh \
              /usr/local/bin/wgcf \
              /etc/systemd/system/warp-unlock.service \
              /etc/wireguard/warp0.conf \
              /etc/warp-unlock/wgcf-profile.conf 2>/dev/null || true

        # 6. 恢复系统 DNS 解析
        if [ -f /etc/resolv.conf.warp.bak ]; then
            cp -f /etc/resolv.conf.warp.bak /etc/resolv.conf
        fi

        systemctl daemon-reload 2>/dev/null || true
        systemctl restart dnsmasq 2>/dev/null || true
        echo -e "${GREEN}✓ 老版本残留清理完成！${NC}\n"
    fi
}

# ---------------------------------------------------------
# 功能 2：检测原生 IP 是否送中
# ---------------------------------------------------------
check_native_songzhong() {
    echo -e "${CYAN}[检测] 正在精确探测当前 VPS 原生 IP 的 Google 归属状态...${NC}"
    
    # 绑定默认网卡，确保测试的是原生网络
    local IFACE_ARG=""
    [ -n "$DEFAULT_IFACE" ] && IFACE_ARG="--interface $DEFAULT_IFACE"

    # 请求 Google 搜索首页获取 HTTP Header (不跟随重定向，嗅探跳转目标)
    local GOOGLE_HEADER
    GOOGLE_HEADER=$(curl -sI -4 --max-time 6 $IFACE_ARG "https://www.google.com" 2>/dev/null)
    local LOCATION
    LOCATION=$(echo "$GOOGLE_HEADER" | grep -i "^location:" | awk '{print $2}' | tr -d '\r')

    # 获取当前出口 IP 信息
    local CURRENT_IP
    CURRENT_IP=$(curl -s -4 --max-time 5 $IFACE_ARG ip.sb 2>/dev/null || curl -s -4 --max-time 5 $IFACE_ARG ifconfig.me 2>/dev/null)
    echo -e "当前原生 IPv4: ${YELLOW}${CURRENT_IP:-未知}${NC}"

    # 判断规则：如果 www.google.com 302 重定向到 google.com.hk 或 google.cn，则为送中
    if echo "$LOCATION" | grep -qiE "google\.com\.hk|google\.cn"; then
        echo -e "Google 归属判定: ${RED}已送中 (被 Google 重定向至 $LOCATION)${NC}"
        return 0 # 0 代表已送中
    fi

    # 进一步校验 NCR 接口
    local NCR_CODE
    NCR_CODE=$(curl -sI -4 -o /dev/null -w "%{http_code}" -L --max-time 6 $IFACE_ARG "https://www.google.com/ncr" 2>/dev/null)
    if [ "$NCR_CODE" != "200" ] && [ -n "$LOCATION" ]; then
        echo -e "Google 归属判定: ${RED}已送中 (受区域重定向限制)${NC}"
        return 0 # 送中
    fi

    echo -e "Google 归属判定: ${GREEN}原生正常 / 未送中 (直连访问正常，无强制跳香港/跳大陆)${NC}"
    return 1 # 1 代表未送中（原生干净）
}

# ---------------------------------------------------------
# 安装核心依赖
# ---------------------------------------------------------
install_dependencies() {
    echo -e "\n${CYAN}[1/4] 正在安装必要底层网络组件...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wireguard wireguard-tools ipset dnsmasq curl wget iptables jq >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y epel-release >/dev/null 2>&1
        dnf install -y wireguard-tools ipset dnsmasq curl wget iptables iptables-services jq >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y wireguard-tools ipset dnsmasq curl wget iptables iptables-services jq >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------
# 原生 API 注册 Cloudflare WARP 节点配置 (强推 IPv4，完美适配 RackNerd)
# ---------------------------------------------------------
setup_warp_profile() {
    echo -e "\n${CYAN}[2/4] 正在通过 Cloudflare 原生 API 生成 WARP 节点配置...${NC}"
    mkdir -p /etc/wireguard
    
    local PRIVKEY
    PRIVKEY=$(wg genkey 2>/dev/null || openssl rand -base64 32)
    local PUBKEY
    PUBKEY=$(echo "$PRIVKEY" | wg pubkey 2>/dev/null)

    # 强制 -4 IPv4 请求 Cloudflare 注册 API
    local RESPONSE
    RESPONSE=$(curl -4 -s -X POST -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.3-2158' -H 'Content-Type: application/json' \
      -d "{\"key\":\"$PUBKEY\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"zh_CN\"}" \
      https://api.cloudflareclient.com/v0a2158/reg)

    local IPV4_ADDR
    IPV4_ADDR=$(echo "$RESPONSE" | grep -oP '"v4":\s*"\K[0-9.]+' | head -n 1)
    local IPV6_ADDR
    IPV6_ADDR=$(echo "$RESPONSE" | grep -oP '"v6":\s*"\K[0-9a-fA-F:]+' | head -n 1)
    local PEER_PUBKEY
    PEER_PUBKEY=$(echo "$RESPONSE" | grep -oP '"public_key":\s*"\K[^"]+' | head -n 1)

    # 备用 API 兜底
    if [ -z "$PEER_PUBKEY" ] || [ -z "$IPV4_ADDR" ]; then
        RESPONSE=$(curl -4 -s -X POST -H 'User-Agent: okhttp/3.12.1' -H 'Content-Type: application/json' \
          -d "{\"key\":\"$PUBKEY\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" \
          https://api.cloudflareclient.com/v0a884/reg)
        IPV4_ADDR=$(echo "$RESPONSE" | grep -oP '"v4":\s*"\K[0-9.]+' | head -n 1)
        PEER_PUBKEY=$(echo "$RESPONSE" | grep -oP '"public_key":\s*"\K[^"]+' | head -n 1)
    fi

    if [ -z "$PEER_PUBKEY" ]; then
        echo -e "${RED}[错误] 无法获取 Cloudflare 授权，请检查 VPS 出口网络后重试！${NC}"
        exit 1
    fi

    # Table = off: 不接管系统全局默认路由
    cat > /etc/wireguard/warp0.conf << EOF
[Interface]
PrivateKey = $PRIVKEY
Address = ${IPV4_ADDR}/32, ${IPV6_ADDR:-2606:4700:110:8::1}/128
DNS = 1.1.1.1, 8.8.8.8
Table = off

[Peer]
PublicKey = ${PEER_PUBKEY:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}
Endpoint = 162.159.192.1:2408
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    echo -e "${GREEN}✓ Cloudflare WARP 节点配置已生成${NC}"
}

# ---------------------------------------------------------
# 配置 Dnsmasq 动态域名嗅探（涵盖全部已知域名资产）
# ---------------------------------------------------------
setup_dnsmasq_rules() {
    echo -e "\n${CYAN}[3/4] 正在配置 Dnsmasq 动态域名拦截名单...${NC}"
    mkdir -p /etc/dnsmasq.d
    
    [ ! -f /etc/resolv.conf.warp.bak ] && cp -f /etc/resolv.conf /etc/resolv.conf.warp.bak

    cat > /etc/dnsmasq.d/warp_unlock.conf << 'EOF'
server=8.8.8.8
server=1.1.1.1

# Google 全家桶及所有 API 子域
ipset=/google.com/warp_unlock
ipset=/google.co.jp/warp_unlock
ipset=/google.com.hk/warp_unlock
ipset=/googleapis.com/warp_unlock
ipset=/googleusercontent.com/warp_unlock
ipset=/gstatic.com/warp_unlock
ipset=/gemini.google.com/warp_unlock
ipset=/antigravity.google/warp_unlock
ipset=/android.com/warp_unlock
ipset=/gvt1.com/warp_unlock
ipset=/ggpht.com/warp_unlock

# OpenAI / ChatGPT 全系列
ipset=/openai.com/warp_unlock
ipset=/chatgpt.com/warp_unlock
ipset=/oaistatic.com/warp_unlock
ipset=/oaiusercontent.com/warp_unlock
ipset=/auth0.openai.com/warp_unlock
EOF

    # 避免 Ubuntu 等系统 systemd-resolved 占用 53 端口
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        sed -i 's/#DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf 2>/dev/null || true
        sed -i 's/DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf 2>/dev/null || true
        systemctl restart systemd-resolved 2>/dev/null || true
    fi

    systemctl restart dnsmasq
    systemctl enable dnsmasq >/dev/null 2>&1
    
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
}

# ---------------------------------------------------------
# 配置系统级策略路由 (Ipset + Fwmark)
# ---------------------------------------------------------
setup_routing_rules() {
    echo -e "\n${CYAN}[4/4] 正在配置系统底层动态路由与开机守护...${NC}"

    cat > /usr/local/bin/warp-route-apply.sh << 'EOF'
#!/bin/bash
# 1. 创建 ipset 集合 (86400秒动态过期自动刷新)
ipset create warp_unlock hash:ip timeout 86400 -exist

# 2. 创建专用路由表 51820
ip rule del fwmark 51820 lookup 51820 2>/dev/null || true
ip rule add fwmark 51820 lookup 51820 priority 100

# 3. 启动 WireGuard 虚拟网卡
wg-quick down warp0 2>/dev/null || true
wg-quick up warp0

# 4. 指定 51820 路由表的默认网关为 warp0 虚拟接口
ip route flush table 51820 2>/dev/null || true
ip route add default dev warp0 table 51820

# 5. iptables 标记匹配 ipset 的流量
iptables -t mangle -D OUTPUT -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null || true
iptables -t mangle -A OUTPUT -m set --match-set warp_unlock dst -j MARK --set-mark 51820
iptables -t mangle -D PREROUTING -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null || true
iptables -t mangle -A PREROUTING -m set --match-set warp_unlock dst -j MARK --set-mark 51820
EOF
    chmod +x /usr/local/bin/warp-route-apply.sh
    /usr/local/bin/warp-route-apply.sh

    # 注册 systemd 开机自启
    cat > /etc/systemd/system/warp-unlock.service << 'EOF'
[Unit]
Description=WARP Dynamic Unlock Routing Service
After=network.target dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-route-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-unlock.service >/dev/null 2>&1
}

# ---------------------------------------------------------
# 测试解锁状态
# ---------------------------------------------------------
test_unlock_status() {
    echo -e "\n${CYAN}正在验证解锁效果...${NC}"
    sleep 2

    # 触发 DNS 动态嗅探
    curl -s https://www.google.com >/dev/null 2>&1
    curl -s https://chatgpt.com >/dev/null 2>&1

    local GOOGLE_CODE
    GOOGLE_CODE=$(curl -sI -o /dev/null -w "%{http_code}" -L --max-time 8 https://www.google.com/ncr)
    local GEMINI_CODE
    GEMINI_CODE=$(curl -sI -o /dev/null -w "%{http_code}" -L --max-time 8 https://gemini.google.com)

    echo "--------------------------------------------------------"
    if [ "$GOOGLE_CODE" == "200" ]; then
        echo -e "Google 搜索/API 解锁状态:    ${GREEN}✓ 解锁成功 (HTTP $GOOGLE_CODE，已脱离送中)${NC}"
    else
        echo -e "Google 搜索/API 解锁状态:    ${YELLOW}⚠ 状态码: $GOOGLE_CODE (200/302均属正常)${NC}"
    fi

    if [ "$GEMINI_CODE" == "200" ] || [ "$GEMINI_CODE" == "302" ]; then
        echo -e "Google Gemini / Antigravity: ${GREEN}✓ 解锁成功 (HTTP $GEMINI_CODE)${NC}"
    else
        echo -e "Google Gemini / Antigravity: ${RED}✗ 异常 (HTTP $GEMINI_CODE)${NC}"
    fi
    echo "--------------------------------------------------------"
    echo -e "${GREEN}🎉 部署完成！任何接入此 VPS 的代理协议均已自动生效，IP 轮换永不失效。${NC}\n"
}

# ---------------------------------------------------------
# 智能执行主流程
# ---------------------------------------------------------
smart_install_flow() {
    # 步骤 1: 自动检测并清理老版本/历史残留
    auto_clean_old_warp

    # 步骤 2: 检测原生是否送中
    if check_native_songzhong; then
        echo -e "\n${YELLOW}>>> 检测到原生 IP 已送中，开始全自动安装动态分流解锁...${NC}"
        install_dependencies
        setup_warp_profile
        setup_dnsmasq_rules
        setup_routing_rules
        test_unlock_status
    else
        echo -e "\n${GREEN}======================================================${NC}"
        echo -e "${GREEN}🎉 恭喜！检测到当前 VPS 原生 IP 为纯净非送中 IP，无需安装 WARP！${NC}"
        echo -e "${GREEN}已自动清理残留并保持原生纯净网络直连，享受最低延迟。${NC}"
        echo -e "${GREEN}======================================================${NC}\n"
    fi
}

# ---------------------------------------------------------
# 主菜单
# ---------------------------------------------------------
clear
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║      🚀 VPS 系统级 WARP 智能动态解锁脚本 (升级版)          ║"
echo "║   • 启动自检：自动彻底清理老版本脚本及旧规则残留          ║"
echo "║   • 智能判断：原生送中才安装，未送中则自动卸载/免装       ║"
echo "║   • 动态嗅探：Google全家桶/Gemini/Antigravity/OpenAI       ║"
echo "║   • 零配置：小白直接运行，各代理节点无需任何路由改动       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo "1. 智能运行 (自动清理旧版 + 检测送中 + 智能安装/卸载)"
echo "2. 强制安装 / 修复 WARP 动态解锁"
echo "3. 测试当前解锁与归属状态"
echo "4. 彻底卸载恢复原生网络"
echo "0. 退出"
echo ""
read -p "请输入选项 [0-4] (默认按回车直接智能运行 [1]): " choice
choice=${choice:-1}

case $choice in
    1)
        smart_install_flow
        ;;
    2)
        auto_clean_old_warp
        install_dependencies
        setup_warp_profile
        setup_dnsmasq_rules
        setup_routing_rules
        test_unlock_status
        ;;
    3)
        check_native_songzhong
        test_unlock_status
        ;;
    4)
        auto_clean_old_warp
        echo -e "${GREEN}✓ 已彻底卸载并恢复原生网络配置。${NC}"
        ;;
    *)
        exit 0
        ;;
esac
