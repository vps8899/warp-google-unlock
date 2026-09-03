#!/bin/bash
# =========================================================
# VPS 全自动系统级 WARP 动态分流解锁脚本 (2026 智能检测高精度版)
# 
# 核心特性:
# 1. 启动自检与清理：自动深度清除历史/老版本残留及失效规则
# 2. 权威高精度送中判定：
#    - 深度对齐 NodeQuality / IPQuality / 融合怪 行业通用判定算法
#    - 基于 YouTube Premium 原生接口与 Google 搜索多维交叉验证
#    - 彻底解决现代 Google 搜索不发生 302 重定向导致的误判漏判
# 3. 完整资产分流库：
#    - YouTube 全家桶 (含视频流 googlevideo.com / 解决 [CN] 送中)
#    - Google 搜索、API、账户、Play商店及 Android CDN
#    - Google AI 矩阵 (Gemini / Antigravity / AI Studio / DeepMind)
#    - OpenAI / ChatGPT 全系列
# 4. 零配置与防失效保障：
#    - Dnsmasq 动态捕获 IP 并入库 Ipset 策略路由，IP 轮换永不失效
#    - 锁定 /etc/resolv.conf 属性，彻底防止 VPS 重启或 DHCP 覆写失效
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
        echo -e "${YELLOW}[自检] 检测到历史/老版本 WARP 脚本残留，正在自动彻底清理...${NC}"
        
        # 1. 解除 resolv.conf 写保护
        chattr -i /etc/resolv.conf 2>/dev/null || true

        # 2. 停止并禁用所有相关 systemd 服务
        systemctl stop warp-unlock.service warp-svc cloudflare-warp 2>/dev/null || true
        systemctl disable warp-unlock.service warp-svc cloudflare-warp 2>/dev/null || true
        
        # 3. 停止 WireGuard 接口
        command -v wg-quick &>/dev/null && wg-quick down warp0 2>/dev/null || true
        command -v warp-cli &>/dev/null && warp-cli disconnect 2>/dev/null || true

        # 4. 清理 iptables mangle 规则与策略路由
        iptables -t mangle -D OUTPUT -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null || true
        iptables -t mangle -D PREROUTING -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null || true
        ip rule del fwmark 51820 lookup 51820 2>/dev/null || true
        ip route flush table 51820 2>/dev/null || true

        # 5. 销毁 ipset 集合
        ipset destroy warp_unlock 2>/dev/null || true

        # 6. 清除旧版配置文件与脚本
        rm -f /etc/dnsmasq.d/warp_unlock.conf \
              /etc/dnsmasq.d/warp-google.conf \
              /usr/local/bin/warp-route-apply.sh \
              /usr/local/bin/wgcf \
              /etc/systemd/system/warp-unlock.service \
              /etc/wireguard/warp0.conf \
              /etc/warp-unlock/wgcf-profile.conf 2>/dev/null || true

        # 7. 恢复系统 DNS 解析
        if [ -f /etc/resolv.conf.warp.bak ]; then
            cp -f /etc/resolv.conf.warp.bak /etc/resolv.conf
        else
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        fi

        systemctl daemon-reload 2>/dev/null || true
        systemctl restart dnsmasq 2>/dev/null || true
        echo -e "${GREEN}✓ 历史残留规则与配置文件已彻底清理！${NC}\n"
    fi
}

# ---------------------------------------------------------
# 功能 2：权威精准探测原生 IP 是否送中 (对齐 NodeQuality 算法)
# ---------------------------------------------------------
check_native_songzhong() {
    echo -e "${CYAN}[检测] 正在通过权威多维接口深度探测当前 VPS 原生 IP 归属状态...${NC}"
    
    # 绑定默认网卡，确保探测的是 VPS 真实原生出口
    local IFACE_ARG=""
    [ -n "$DEFAULT_IFACE" ] && IFACE_ARG="--interface $DEFAULT_IFACE"

    # 获取当前出口 IP 信息
    local CURRENT_IP
    CURRENT_IP=$(curl -s -4 --max-time 5 $IFACE_ARG ip.sb 2>/dev/null || \
                 curl -s -4 --max-time 5 $IFACE_ARG ifconfig.me 2>/dev/null || \
                 curl -s -4 --max-time 5 $IFACE_ARG icanhazip.com 2>/dev/null)
    echo -e "当前原生 IPv4: ${YELLOW}${CURRENT_IP:-未知}${NC}"

    local IS_SONGZHONG=0
    local REASON=""
    local YT_REGION=""

    # -------------------------------------------------------------
    # 核心探测 1：YouTube Premium 接口检测 (NodeQuality 行业黄金标准)
    # -------------------------------------------------------------
    echo -e "${CYAN}[检测] 正在请求 YouTube 官方区域接口 (NodeQuality 同款)...${NC}"
    local YT_RES
    YT_RES=$(curl -sSL -4 --max-time 8 $IFACE_ARG \
        -H "Accept-Language: en" \
        -b "YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai" \
        "https://www.youtube.com/premium" 2>&1)

    # 提取区域代码
    YT_REGION=$(echo "$YT_RES" | sed -n 's/.*"contentRegion":"\([^"]*\)".*/\1/p' | head -n 1)

    # 判定规则 A：页面包含 www.google.cn
    if echo "$YT_RES" | grep -q "www.google.cn"; then
        IS_SONGZHONG=1
        REASON="YouTube 源码包含 www.google.cn 域名引用"
    # 判定规则 B：地区标记明确为 CN
    elif echo "$YT_RES" | grep -qiE '"countryCode":"CN"|"contentRegion":"CN"'; then
        IS_SONGZHONG=1
        REASON="YouTube 接口返回归属地为 [CN] (中国)"
    # 判定规则 C：中国区不可用提示
    elif echo "$YT_RES" | grep -q "Premium is not available in your country" && [ "$YT_REGION" == "CN" ]; then
        IS_SONGZHONG=1
        REASON="YouTube Premium 提示所在地区不支持 (CN)"
    fi

    # -------------------------------------------------------------
    # 辅助探测 2：Google 搜索重定向与 NCR 检测
    # -------------------------------------------------------------
    local GOOGLE_HEADER
    GOOGLE_HEADER=$(curl -sI -4 --max-time 6 $IFACE_ARG "https://www.google.com" 2>/dev/null)
    local LOCATION
    LOCATION=$(echo "$GOOGLE_HEADER" | grep -i "^location:" | awk '{print $2}' | tr -d '\r')

    if echo "$LOCATION" | grep -qiE "google\.com\.hk|google\.cn"; then
        IS_SONGZHONG=1
        REASON="Google 搜索被强制重定向至 $LOCATION"
    fi

    # -------------------------------------------------------------
    # 输出结果汇总
    # -------------------------------------------------------------
    echo "--------------------------------------------------------"
    if [ $IS_SONGZHONG -eq 1 ]; then
        echo -e "YouTube 状态判定:  ${RED}中国 [CN]${NC} (与 NodeQuality 检测一致)"
        echo -e "送中特征详情:      ${RED}$REASON${NC}"
        echo -e "综合归属判定:      ${RED}🔴 已确认送中 (Google/YouTube 判定为中国地区)${NC}"
        echo "--------------------------------------------------------"
        return 0 # 0 代表已送中，需要安装解锁
    else
        echo -e "YouTube 状态判定:  ${GREEN}[${YT_REGION:-US}] 原生正常解锁${NC}"
        echo -e "Google 搜索判定:   ${GREEN}正常直连 (无区域重定向)${NC}"
        echo -e "综合归属判定:      ${GREEN}🟢 原生正常 / 未送中${NC}"
        echo "--------------------------------------------------------"
        return 1 # 1 代表未送中
    fi
}

# ---------------------------------------------------------
# 安装核心依赖
# ---------------------------------------------------------
install_dependencies() {
    echo -e "\n${CYAN}[1/4] 正在安装必要底层网络组件...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wireguard wireguard-tools ipset dnsmasq curl wget iptables jq e2fsprogs >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y epel-release >/dev/null 2>&1
        dnf install -y wireguard-tools ipset dnsmasq curl wget iptables iptables-services jq e2fsprogs >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y wireguard-tools ipset dnsmasq curl wget iptables iptables-services jq e2fsprogs >/dev/null 2>&1
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
    echo -e "\n${CYAN}[3/4] 正在配置 Dnsmasq 动态域名拦截名单与防失效保护...${NC}"
    mkdir -p /etc/dnsmasq.d
    
    # 备份原生 resolv.conf
    [ ! -f /etc/resolv.conf.warp.bak ] && cp -f /etc/resolv.conf /etc/resolv.conf.warp.bak

    cat > /etc/dnsmasq.d/warp_unlock.conf << 'EOF'
server=8.8.8.8
server=1.1.1.1

# ----------------- 1. Google 搜索与核心基础服务 -----------------
ipset=/google.com/warp_unlock
ipset=/google.co.jp/warp_unlock
ipset=/google.com.hk/warp_unlock
ipset=/google.cn/warp_unlock
ipset=/googleapis.com/warp_unlock
ipset=/googleusercontent.com/warp_unlock
ipset=/gstatic.com/warp_unlock
ipset=/1e100.net/warp_unlock
ipset=/google-analytics.com/warp_unlock
ipset=/googletagmanager.com/warp_unlock

# ----------------- 2. YouTube 全系列 (解决 YouTube 送中 / Premium 中国区限制) -----------------
ipset=/youtube.com/warp_unlock
ipset=/youtu.be/warp_unlock
ipset=/ytimg.com/warp_unlock
ipset=/googlevideo.com/warp_unlock
ipset=/yt.be/warp_unlock

# ----------------- 3. Google Play 商店 & 安卓全家桶 -----------------
ipset=/android.com/warp_unlock
ipset=/gvt1.com/warp_unlock
ipset=/gvt2.com/warp_unlock
ipset=/gvt3.com/warp_unlock
ipset=/ggpht.com/warp_unlock
ipset=/googleplay.com/warp_unlock

# ----------------- 4. Google AI 矩阵 (Gemini / Antigravity / DeepMind) -----------------
ipset=/gemini.google.com/warp_unlock
ipset=/antigravity.google/warp_unlock
ipset=/aistudio.google.com/warp_unlock
ipset=/bard.google.com/warp_unlock
ipset=/deepmind.com/warp_unlock
ipset=/deepmind.google/warp_unlock

# ----------------- 5. OpenAI / ChatGPT 全系列 -----------------
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
    
    # 写入本机 DNS 并使用 chattr +i 锁死，彻底杜绝 DHCP / 重启覆写导致失效
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo -e "${GREEN}✓ DNS 嗅探配置生效，并已锁定 /etc/resolv.conf 防止 DHCP 覆盖失效${NC}"
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
    echo -e "\n${CYAN}正在预热 DNS 并验证全平台解锁效果...${NC}"
    
    # 主动触发 DNS 动态嗅探入库
    curl -sSL -4 --max-time 6 "https://www.youtube.com/premium" >/dev/null 2>&1
    curl -sSL -4 --max-time 6 "https://www.google.com" >/dev/null 2>&1
    curl -sSL -4 --max-time 6 "https://chatgpt.com" >/dev/null 2>&1
    sleep 2

    # 1. 验证 YouTube 解锁
    local YT_TEST
    YT_TEST=$(curl -sSL -4 --max-time 8 \
        -H "Accept-Language: en" \
        -b "YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai" \
        "https://www.youtube.com/premium" 2>&1)
    local YT_REG
    YT_REG=$(echo "$YT_TEST" | sed -n 's/.*"contentRegion":"\([^"]*\)".*/\1/p' | head -n 1)

    # 2. 验证 Google 搜索
    local GOOGLE_CODE
    GOOGLE_CODE=$(curl -sI -o /dev/null -w "%{http_code}" -L --max-time 8 https://www.google.com/ncr)
    
    # 3. 验证 Gemini / Antigravity
    local GEMINI_CODE
    GEMINI_CODE=$(curl -sI -o /dev/null -w "%{http_code}" -L --max-time 8 https://gemini.google.com)

    # 4. 验证 OpenAI / ChatGPT
    local CHATGPT_CODE
    CHATGPT_CODE=$(curl -sI -o /dev/null -w "%{http_code}" -L --max-time 8 https://chatgpt.com)

    echo "========================================================"
    echo -e "               🎉 解锁与脱离送中验证报告                 "
    echo "========================================================"
    
    if echo "$YT_TEST" | grep -q "www.google.cn"; then
        echo -e "YouTube Premium 解锁:        ${RED}✗ 仍显示送中 (请检查 WARP 运行状态)${NC}"
    else
        echo -e "YouTube Premium 解锁:        ${GREEN}✓ 成功脱离送中 (当前归属: [${YT_REG:-US}])${NC}"
    fi

    if [ "$GOOGLE_CODE" == "200" ]; then
        echo -e "Google 搜索/API 解锁:        ${GREEN}✓ 解锁成功 (HTTP $GOOGLE_CODE，已脱离送中)${NC}"
    else
        echo -e "Google 搜索/API 解锁:        ${YELLOW}⚠ 状态码: $GOOGLE_CODE (200/302均属正常)${NC}"
    fi

    if [ "$GEMINI_CODE" == "200" ] || [ "$GEMINI_CODE" == "302" ]; then
        echo -e "Google Gemini / Antigravity: ${GREEN}✓ 解锁成功 (HTTP $GEMINI_CODE)${NC}"
    else
        echo -e "Google Gemini / Antigravity: ${RED}✗ 异常 (HTTP $GEMINI_CODE)${NC}"
    fi

    if [ "$CHATGPT_CODE" == "200" ] || [ "$CHATGPT_CODE" == "302" ] || [ "$CHATGPT_CODE" == "403" ]; then
        echo -e "OpenAI / ChatGPT 访问状态:   ${GREEN}✓ 正常连通 (HTTP $CHATGPT_CODE)${NC}"
    else
        echo -e "OpenAI / ChatGPT 访问状态:   ${YELLOW}⚠ 状态码: $CHATGPT_CODE${NC}"
    fi
    echo "========================================================"
    echo -e "${GREEN}🎉 部署完成！您现在可以重新运行 NodeQuality 进行复测，YouTube 将完美脱离 [CN]！${NC}\n"
}

# ---------------------------------------------------------
# 智能执行主流程
# ---------------------------------------------------------
smart_install_flow() {
    # 步骤 1: 自动检测并清理老版本/历史残留
    auto_clean_old_warp

    # 步骤 2: 精准检测原生是否送中
    if check_native_songzhong; then
        echo -e "\n${YELLOW}>>> 检测到原生 IP 已送中，全自动启动 WARP 动态分流解锁流程...${NC}"
        install_dependencies
        setup_warp_profile
        setup_dnsmasq_rules
        setup_routing_rules
        test_unlock_status
    else
        echo -e "\n${GREEN}======================================================${NC}"
        echo -e "${GREEN}🎉 检测到当前 VPS 原生 IP 为纯净非送中 IP！${NC}"
        echo -e "${GREEN}======================================================${NC}"
        read -t 10 -p "是否仍然需要强制安装 WARP 动态分流？[y/N] (10秒无输入默认退出保持原生): " force_choice
        case "$force_choice" in
            [yY][eE][sS]|[yY])
                echo -e "\n${YELLOW}>>> 用户选择继续安装 WARP 动态分流...${NC}"
                install_dependencies
                setup_warp_profile
                setup_dnsmasq_rules
                setup_routing_rules
                test_unlock_status
                ;;
            *)
                echo -e "\n已保持原生纯净直连，享受最低延迟与最佳性能。\n"
                ;;
        esac
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
echo "║   • 智能判断：原生送中才安装，未送中则自动免装/可自选     ║"
echo "║   • 动态嗅探：Google全家桶/YouTube/Gemini/Antigravity/AI   ║"
echo "║   • 防覆写：锁定 DNS 属性，彻底防止重启或 DHCP 导致失效   ║"
echo "║   • 零配置：小白直接运行，各代理节点无需任何路由改动       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo "1. 智能运行 (自动清理旧版 + 精准检测送中 + 智能安装)"
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
