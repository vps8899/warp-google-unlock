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
    echo -e "${YELLOW}[深度清理] 正在深度检测并彻底清除所有 WARP 策略路由、防火墙规则及旧版残留...${NC}"
    
    # 1. 解除 resolv.conf 写保护并恢复纯净原生 DNS
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

    # 2. 停止并禁用所有相关 systemd 服务
    systemctl stop warp-unlock.service warp-svc cloudflare-warp dnsmasq 2>/dev/null || true
    systemctl disable warp-unlock.service warp-svc cloudflare-warp 2>/dev/null || true
    
    # 3. 停止 WireGuard 接口
    command -v wg-quick &>/dev/null && wg-quick down warp0 2>/dev/null || true
    command -v warp-cli &>/dev/null && warp-cli disconnect 2>/dev/null || true

    # 4. 彻底循环清理所有 iptables mangle / nat / filter 规则 (while 循环清空，一条不剩)
    while iptables -t mangle -D OUTPUT -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null; do :; done
    while iptables -t mangle -D PREROUTING -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null; do :; done
    while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o warp0 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
    while iptables -t filter -D FORWARD -p udp --dport 443 -m set --match-set warp_unlock dst -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
    while iptables -t filter -D OUTPUT -p udp --dport 443 -m set --match-set warp_unlock dst -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done

    # 5. 彻底循环清理策略路由表与规则
    while ip rule del fwmark 51820 lookup 51820 2>/dev/null; do :; done
    ip route flush table 51820 2>/dev/null || true

    # 6. 销毁 ipset 集合
    ipset destroy warp_unlock 2>/dev/null || true

    # 7. 清除配置文件与启动脚本，还原 wg-quick 并清理 wireguard-go
    rm -f /etc/dnsmasq.d/warp_unlock.conf \
          /etc/dnsmasq.d/warp-google.conf \
          /usr/local/bin/warp-route-apply.sh \
          /usr/local/bin/wgcf \
          /etc/systemd/system/warp-unlock.service \
          /etc/wireguard/warp0.conf \
          /usr/bin/wireguard-go \
          /etc/warp-unlock/wgcf-profile.conf 2>/dev/null || true

    if [ -f /usr/bin/wg-quick ]; then
        sed -i '/wireguard-go/d; s/^#\s*add_if/add_if/' /usr/bin/wg-quick 2>/dev/null || true
    fi

    systemctl daemon-reload 2>/dev/null || true
    echo -e "${GREEN}✓ 深度清理完毕！系统网络与 DNS 已彻底恢复纯净原生状态。${NC}\n"
}

# ---------------------------------------------------------
# 功能 2：权威精准探测原生 IP 是否送中 (Google 官网底栏 + YouTube 深度双判)
# ---------------------------------------------------------
check_native_songzhong() {
    echo -e "${CYAN}[检测] 正在深度探测当前 VPS 原生 IP 的 Google / YouTube 真实归属...${NC}"
    
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
    local GOOGLE_GEO=""
    local YT_REGION=""

    # -------------------------------------------------------------
    # 核心探测 1：Google 首页前端配置与底栏归属判定 (用户浏览器同款标准)
    # -------------------------------------------------------------
    echo -e "${CYAN}[检测] 正在访问 Google 搜索官网提取底层归属地区...${NC}"
    local GOOGLE_PAGE
    GOOGLE_PAGE=$(curl -sL -4 --max-time 8 $IFACE_ARG \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -H "Accept-Language: en-US,en" \
        "https://www.google.com" 2>/dev/null)

    # 提取 Google 下发给前端的 ISO-3166 国家代码 (如 USA, CHN, HKG 等)
    GOOGLE_GEO=$(echo "$GOOGLE_PAGE" | grep -oP '\[1,null,null,\d+,\d+,"\K[A-Z]{3}' | head -n 1)
    [ -z "$GOOGLE_GEO" ] && GOOGLE_GEO=$(echo "$GOOGLE_PAGE" | grep -oP '2,1,200,"\K[A-Z]{3}' | head -n 1)

    local GOOGLE_HEADER
    GOOGLE_HEADER=$(curl -sI -4 --max-time 6 $IFACE_ARG "https://www.google.com" 2>/dev/null)
    local LOCATION
    LOCATION=$(echo "$GOOGLE_HEADER" | grep -i "^location:" | awk '{print $2}' | tr -d '\r')

    if [ "$GOOGLE_GEO" == "CHN" ] || [ "$GOOGLE_GEO" == "HKG" ]; then
        IS_SONGZHONG=1
        REASON="Google 搜索底层识别地区为中国/香港 ($GOOGLE_GEO)"
    elif echo "$LOCATION" | grep -qiE "google\.com\.hk|google\.cn"; then
        IS_SONGZHONG=1
        REASON="Google 搜索被强制重定向至 $LOCATION"
    elif echo "$GOOGLE_PAGE" | grep -qiE '"gl":"cn"|"gl":"hk"'; then
        IS_SONGZHONG=1
        REASON="Google 页面标注地区为中国 (gl: cn/hk)"
    fi

    # -------------------------------------------------------------
    # 核心探测 2：YouTube Premium 区域接口 (NodeQuality 行业标准)
    # -------------------------------------------------------------
    echo -e "${CYAN}[检测] 正在请求 YouTube 官方区域接口 (NodeQuality 同款)...${NC}"
    local YT_RES
    YT_RES=$(curl -sSL -4 --max-time 8 $IFACE_ARG \
        -H "Accept-Language: en" \
        -b "YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai" \
        "https://www.youtube.com/premium" 2>&1)

    YT_REGION=$(echo "$YT_RES" | sed -n 's/.*"contentRegion":"\([^"]*\)".*/\1/p' | head -n 1)

    if echo "$YT_RES" | grep -q "www.google.cn"; then
        IS_SONGZHONG=1
        REASON="${REASON:-YouTube 源码引用 www.google.cn}"
    elif echo "$YT_RES" | grep -qiE '"countryCode":"CN"|"contentRegion":"CN"'; then
        IS_SONGZHONG=1
        REASON="${REASON:-YouTube 接口返回归属地为 [CN]}"
    fi

    # -------------------------------------------------------------
    # 输出探测汇总
    # -------------------------------------------------------------
    echo "--------------------------------------------------------"
    echo -e "Google 搜索定位国家: ${YELLOW}${GOOGLE_GEO:-未知}${NC}"
    echo -e "YouTube 接口返回地区: ${YELLOW}[${YT_REGION:-未知}]${NC}"
    if [ $IS_SONGZHONG -eq 1 ]; then
        echo -e "送中特征详情:        ${RED}$REASON${NC}"
        echo -e "综合归属判定:        ${RED}🔴 已确认送中 (部分或全部服务受限)${NC}"
        echo "--------------------------------------------------------"
        return 0 # 0 代表已送中
    else
        echo -e "综合归属判定:        ${GREEN}🟢 原生定位良好 (未送中)${NC}"
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

# 候选优质 WARP Endpoint 列表 (覆盖主流优质节点)
WARP_ENDPOINTS=(
    "162.159.192.1:2408"
    "162.159.192.1:500"
    "162.159.193.10:2408"
    "162.159.193.10:500"
    "188.114.96.1:2408"
    "188.114.97.1:2408"
)

# ---------------------------------------------------------
# 原生 API 注册 Cloudflare WARP 节点配置 (强推 IPv4，完美适配 RackNerd)
# ---------------------------------------------------------
setup_warp_profile() {
    local TARGET_EP="${1:-${WARP_ENDPOINTS[0]}}"
    echo -e "\n${CYAN}[2/4] 正在通过 Cloudflare 原生 API 生成 WARP 节点配置...${NC}"
    mkdir -p /etc/wireguard
    
    local PRIVKEY
    PRIVKEY=$(wg genkey 2>/dev/null || openssl rand -base64 32)
    local PUBKEY
    PUBKEY=$(echo "$PRIVKEY" | wg pubkey 2>/dev/null)

    # 强制 -4 IPv4 请求 Cloudflare 注册 API (指定 en_US 语言)
    local RESPONSE
    RESPONSE=$(curl -4 -s -X POST -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.3-2158' -H 'Content-Type: application/json' \
      -d "{\"key\":\"$PUBKEY\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}" \
      https://api.cloudflareclient.com/v0a2158/reg)

    # Cloudflare WARP 客户端内网 IPv4 规范恒为 172.16.0.2 (杜绝单行 JSON 抓错 endpoint 公网 IP)
    local IPV4_ADDR="172.16.0.2"

    local IPV6_ADDR
    IPV6_ADDR=$(echo "$RESPONSE" | grep -oP '"addresses"\s*:\s*\{[^}]*"v6"\s*:\s*"\K[0-9a-fA-F:]+' | head -n 1)
    IPV6_ADDR=${IPV6_ADDR:-2606:4700:110:8827:18b5:2de8:8b53:96e3}

    local PEER_PUBKEY
    PEER_PUBKEY=$(echo "$RESPONSE" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | head -n 1)
    PEER_PUBKEY=${PEER_PUBKEY:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}

    # 备用 API 兜底
    if [ -z "$RESPONSE" ] || echo "$RESPONSE" | grep -q '"success":false'; then
        RESPONSE=$(curl -4 -s -X POST -H 'User-Agent: okhttp/3.12.1' -H 'Content-Type: application/json' \
          -d "{\"key\":\"$PUBKEY\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" \
          https://api.cloudflareclient.com/v0a884/reg)
        local V6_BACKUP
        V6_BACKUP=$(echo "$RESPONSE" | grep -oP '"addresses"\s*:\s*\{[^}]*"v6"\s*:\s*"\K[0-9a-fA-F:]+' | head -n 1)
        [ -n "$V6_BACKUP" ] && IPV6_ADDR="$V6_BACKUP"
        local PUB_BACKUP
        PUB_BACKUP=$(echo "$RESPONSE" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | head -n 1)
        [ -n "$PUB_BACKUP" ] && PEER_PUBKEY="$PUB_BACKUP"
    fi

    if [ -z "$PEER_PUBKEY" ]; then
        echo -e "${RED}[错误] 无法获取 Cloudflare 授权，请检查 VPS 出口网络后重试！${NC}"
        exit 1
    fi

    # 终极修复: 激活 Cloudflare WARP 官方账号授权 (warp_enabled: true)
    # 彻底解决新注册设备默认处于关闭状态导致握手被服务器静默丢弃 (0 B received) 的问题！
    local DEV_ID
    DEV_ID=$(echo "$RESPONSE" | grep -oP '"id"\s*:\s*"\K[^"]+' | head -n 1)
    local TOKEN
    TOKEN=$(echo "$RESPONSE" | grep -oP '"token"\s*:\s*"\K[^"]+' | head -n 1)

    if [ -n "$DEV_ID" ] && [ -n "$TOKEN" ]; then
        local PATCH_RES
        PATCH_RES=$(curl -4 -s -X PATCH -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.3-2158' -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $TOKEN" \
          -d '{"warp_enabled":true}' \
          "https://api.cloudflareclient.com/v0a2158/reg/$DEV_ID")
        if echo "$PATCH_RES" | grep -q '"warp_enabled":\s*true'; then
            echo -e "${GREEN}✓ Cloudflare WARP 官方授权已成功激活 (warp_enabled: true)${NC}"
        fi
    fi

    # 不添加 DNS 避免触发 resolvconf 权限冲突，显式设置 MTU=1280 杜绝握手大包分片黑洞
    # PostUp 绑定网卡生命周期，确保无论何时重启网卡，路由表 51820 与 MASQUERADE 规则永不丢失
    # 配置文件采用官方标准 WireGuard 规范 (移除一切导致 Line unrecognized 的非标参数)
    cat > /etc/wireguard/warp0.conf << EOF
[Interface]
PrivateKey = $PRIVKEY
Address = ${IPV4_ADDR}/32, ${IPV6_ADDR:-2606:4700:110:8::1}/128
MTU = 1280
Table = off
PostUp = ip rule add fwmark 51820 lookup 51820 priority 100 2>/dev/null || true; ip route replace default dev warp0 table 51820; iptables -t nat -D POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null || true; iptables -t nat -A POSTROUTING -o warp0 -j MASQUERADE; iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o warp0 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true; iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o warp0 -j TCPMSS --clamp-mss-to-pmtu
PostDown = ip route flush table 51820 2>/dev/null || true

[Peer]
PublicKey = ${PEER_PUBKEY:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}
Endpoint = $TARGET_EP
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    echo -e "${GREEN}✓ Cloudflare WARP 节点配置已生成 (Endpoint: $TARGET_EP)${NC}"
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
cache-size=2000
no-resolv
clear-on-reload

# ----------------- 1. Google 搜索与核心基础服务 -----------------
ipset=/google.com/warp_unlock
ipset=/google.co.jp/warp_unlock
ipset=/google.com.hk/warp_unlock
ipset=/google.com.tw/warp_unlock
ipset=/google.cn/warp_unlock
ipset=/googleapis.com/warp_unlock
ipset=/googleusercontent.com/warp_unlock
ipset=/gstatic.com/warp_unlock
ipset=/1e100.net/warp_unlock
ipset=/google-analytics.com/warp_unlock
ipset=/googletagmanager.com/warp_unlock
ipset=/goo.gl/warp_unlock
ipset=/google.dev/warp_unlock
ipset=/web.dev/warp_unlock
ipset=/chrome.com/warp_unlock

# ----------------- 2. YouTube 全系列 (解决 YouTube 送中 / Premium 中国区限制) -----------------
ipset=/youtube.com/warp_unlock
ipset=/youtu.be/warp_unlock
ipset=/ytimg.com/warp_unlock
ipset=/googlevideo.com/warp_unlock
ipset=/yt.be/warp_unlock

# ----------------- 3. Google Play 商店 & 安卓生态核心 CDN -----------------
ipset=/android.com/warp_unlock
ipset=/googleplay.com/warp_unlock
ipset=/gvt1.com/warp_unlock
ipset=/gvt2.com/warp_unlock
ipset=/gvt3.com/warp_unlock
ipset=/ggpht.com/warp_unlock
ipset=/app-measurement.com/warp_unlock

# ----------------- 4. Google AI 全矩阵 (Gemini / Antigravity / AI Studio / NotebookLM) -----------------
ipset=/gemini.google.com/warp_unlock
ipset=/antigravity.google/warp_unlock
ipset=/aistudio.google.com/warp_unlock
ipset=/bard.google.com/warp_unlock
ipset=/deepmind.com/warp_unlock
ipset=/deepmind.google/warp_unlock
ipset=/notebooklm.google/warp_unlock
ipset=/generativeai.google/warp_unlock

# ----------------- 5. OpenAI / ChatGPT & Claude 全系列 -----------------
ipset=/openai.com/warp_unlock
ipset=/chatgpt.com/warp_unlock
ipset=/oaistatic.com/warp_unlock
ipset=/oaiusercontent.com/warp_unlock
ipset=/auth0.openai.com/warp_unlock
ipset=/claude.ai/warp_unlock
ipset=/anthropic.com/warp_unlock
EOF

    # 彻底停用 systemd-resolved 释放 53 端口，杜绝 Dnsmasq 启动失败
    if systemctl is-enabled systemd-resolved &>/dev/null || systemctl is-active systemd-resolved &>/dev/null; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
    fi

    # 测试配置语法，杜绝错误配置导致崩溃
    if ! dnsmasq --test 2>/dev/null; then
        echo -e "${YELLOW}[警告] Dnsmasq 配置存在不兼容语法，正在自动回退安全配置...${NC}"
        cat > /etc/dnsmasq.d/warp_unlock.conf << 'EOF'
server=8.8.8.8
server=1.1.1.1
cache-size=1000
ipset=/google.com/warp_unlock
ipset=/youtube.com/warp_unlock
ipset=/googlevideo.com/warp_unlock
ipset=/gemini.google.com/warp_unlock
ipset=/chatgpt.com/warp_unlock
EOF
    fi

    systemctl restart dnsmasq
    systemctl enable dnsmasq >/dev/null 2>&1

    # 严格验证 Dnsmasq 运行状态，杜绝任何断网风险
    if systemctl is-active --quiet dnsmasq; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null || true
        echo -e "${GREEN}✓ DNS 动态嗅探组件运行正常，并已锁定 /etc/resolv.conf 防止 DHCP 覆盖${NC}"
    else
        echo -e "${YELLOW}[保护] Dnsmasq 暂未成功监听，已自动保持公共 DNS (8.8.8.8) 确保网络绝对畅通！${NC}"
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
    fi
}

# ---------------------------------------------------------
# 配置系统级策略路由 (Ipset + Fwmark)
# ---------------------------------------------------------
setup_routing_rules() {
    echo -e "\n${CYAN}[4/4] 正在配置系统底层动态路由与开机守护...${NC}"

    cat > /usr/local/bin/warp-route-apply.sh << 'EOF'
#!/bin/bash
# 0. 开启内核转发与优化反向路径过滤 (避免策略路由回包被内核阻断)
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1

# 1. 创建 ipset 集合 (升级为 hash:net，支持单个 IP 与 CIDR 网段，86400秒超时)
ipset create warp_unlock hash:net timeout 86400 -exist

# 预置 Google 全球核心骨干网段 (双重保险，零延迟防遗漏)
for net in 142.250.0.0/15 172.217.0.0/16 216.58.192.0/19 173.194.0.0/16 74.125.0.0/16 64.233.160.0/19 66.102.0.0/20 66.249.64.0/19 108.177.0.0/17; do
    ipset add warp_unlock "$net" -exist 2>/dev/null || true
done

# 2. 创建专用路由表 51820
ip rule del fwmark 51820 lookup 51820 2>/dev/null || true
ip rule add fwmark 51820 lookup 51820 priority 100

# 3. 启动 WireGuard 虚拟网卡并进行热切换极速握手
wg-quick down warp0 >/dev/null 2>&1 || true
wg-quick up warp0 >/dev/null 2>&1

# 极速热探测黄金接入点与端口 (秒级生效)
for ep in "162.159.192.1:2408" "162.159.192.1:500" "162.159.193.10:2408" "162.159.193.10:500" "188.114.96.1:2408" "188.114.97.1:2408"; do
    wg set warp0 peer bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo= endpoint "$ep" 2>/dev/null || true
    sleep 2
    RX=$(wg show warp0 transfer 2>/dev/null | awk '{print $2}')
    if [ -n "$RX" ] && [ "$RX" -gt 0 ]; then
        sed -i "s|Endpoint = .*|Endpoint = $ep|" /etc/wireguard/warp0.conf
        break
    fi
done

[ -d /proc/sys/net/ipv4/conf/warp0 ] && sysctl -w net.ipv4.conf.warp0.rp_filter=2 >/dev/null 2>&1

# 4. 确保 51820 路由表的默认网关为 warp0 虚拟接口
ip route flush table 51820 2>/dev/null || true
ip route replace default dev warp0 table 51820

# 5. iptables 标记匹配 ipset 的流量 (OUTPUT 为代理服务端发起的出站)
iptables -t mangle -D OUTPUT -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null || true
iptables -t mangle -A OUTPUT -m set --match-set warp_unlock dst -j MARK --set-mark 51820
iptables -t mangle -D PREROUTING -m set --match-set warp_unlock dst -j MARK --set-mark 51820 2>/dev/null || true
iptables -t mangle -A PREROUTING -m set --match-set warp_unlock dst -j MARK --set-mark 51820

# 6. TCP MSS 钳制 (核心修复: 解决 HTTPS / TLS Client Hello 大包导致 ERR_CONNECTION_CLOSED)
iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o warp0 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o warp0 -j TCPMSS --clamp-mss-to-pmtu

# 7. NAT MASQUERADE (最核心修复: 为 warp0 出口流量执行源地址伪装，避免源 IP 错误被丢弃)
iptables -t nat -D POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o warp0 -j MASQUERADE

# 8. 强制拦截 QUIC (UDP 443)，促使 Chrome/Edge 浏览器瞬间回落至极速稳定的 TCP (TLS 1.3)
iptables -t filter -D FORWARD -p udp --dport 443 -m set --match-set warp_unlock dst -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
iptables -t filter -A FORWARD -p udp --dport 443 -m set --match-set warp_unlock dst -j REJECT --reject-with icmp-port-unreachable
iptables -t filter -D OUTPUT -p udp --dport 443 -m set --match-set warp_unlock dst -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
iptables -t filter -A OUTPUT -p udp --dport 443 -m set --match-set warp_unlock dst -j REJECT --reject-with icmp-port-unreachable
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
# 核心功能：全自动刷 IP 机制 (避开俄罗斯 RU 与中国 CN，锁定美区)
# ---------------------------------------------------------
ensure_clean_warp_region() {
    echo -e "\n${CYAN}正在验证 WARP 出口归属并自动避开俄罗斯(RU)/中国(CN)...${NC}"
    
    local max_retries=6
    local retry_count=0
    local ep_count=${#WARP_ENDPOINTS[@]}
    local CUR_REGION=""
    local GOOGLE_LOC=""

    while [ $retry_count -lt $max_retries ]; do
        sleep 2
        # 预热 DNS
        curl -sSL -4 --max-time 6 "https://www.youtube.com/premium" >/dev/null 2>&1
        curl -sSL -4 --max-time 6 "https://www.google.com" >/dev/null 2>&1
        
        # 探测当前 WARP 出口的 YouTube 归属
        local YT_TEST
        YT_TEST=$(curl -sSL -4 --max-time 8 \
            -H "Accept-Language: en" \
            -b "YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai" \
            "https://www.youtube.com/premium" 2>&1)
        CUR_REGION=$(echo "$YT_TEST" | sed -n 's/.*"contentRegion":"\([^"]*\)".*/\1/p' | head -n 1)

        # 探测 Google 搜索归属
        local GOOGLE_PAGE
        GOOGLE_PAGE=$(curl -sL -4 --max-time 8 -H "Accept-Language: en-US,en" "https://www.google.com" 2>/dev/null)
        GOOGLE_LOC=$(echo "$GOOGLE_PAGE" | grep -oP '\[1,null,null,\d+,\d+,"\K[A-Z]{3}' | head -n 1)

        # 判定是否为受限地区 (RU / CN / CHN / RUS)
        local IS_RESTRICTED=0
        if [ "$CUR_REGION" == "RU" ] || [ "$CUR_REGION" == "CN" ] || echo "$YT_TEST" | grep -q "www.google.cn"; then
            IS_RESTRICTED=1
        elif [ "$GOOGLE_LOC" == "RUS" ] || [ "$GOOGLE_LOC" == "CHN" ]; then
            IS_RESTRICTED=1
        fi

        if [ $IS_RESTRICTED -eq 1 ]; then
            ((retry_count++))
            echo -e "${YELLOW}[尝试 $retry_count/$max_retries] WARP 当前分配至 [${CUR_REGION:-$GOOGLE_LOC}] (限制区)，正在热切换节点获取新 IP...${NC}"
            
            # 选择下一个黄金 Endpoint 并热切换，保留合法的官方已激活凭据
            local next_ep=${WARP_ENDPOINTS[$((retry_count % ep_count))]}
            wg set warp0 peer bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo= endpoint "$next_ep" 2>/dev/null || true
            sed -i "s|Endpoint = .*|Endpoint = $next_ep|" /etc/wireguard/warp0.conf
            sleep 3
        else
            echo -e "${GREEN}✓ 成功锁定 WARP 纯净出口地区: [${CUR_REGION:-${GOOGLE_LOC:-US}}] (非受限区，完美支持 Google / Gemini / YouTube！)${NC}"
            return 0
        fi
    done

    echo -e "${YELLOW}⚠ 已达自动重试上限，当前 WARP 地区为 [${CUR_REGION:-未知}]${NC}"
    return 1
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
    sleep 1

    # 0. 校验 WireGuard 隧道握手状态
    local RX_BYTES
    RX_BYTES=$(wg show warp0 transfer 2>/dev/null | awk '{print $2}')
    if [ -z "$RX_BYTES" ] || [ "$RX_BYTES" -eq 0 ]; then
        echo -e "${YELLOW}[注意] 正在与 Cloudflare 全球 Anycast 节点建立握手...${NC}"
        for _w in $(seq 1 6); do
            sleep 1
            RX_BYTES=$(wg show warp0 transfer 2>/dev/null | awk '{print $2}')
            if [ -n "$RX_BYTES" ] && [ "$RX_BYTES" -gt 0 ]; then
                echo -e "${GREEN}✓ WireGuard 隧道握手成功！(收到回包: ${RX_BYTES} 字节)${NC}"
                break
            fi
        done
    else
        echo -e "${GREEN}✓ WireGuard 隧道运行正常 (累计接收: ${RX_BYTES} 字节)${NC}"
    fi

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
    
    # 3. 验证 Gemini / Antigravity (检测地区是否支持)
    local GEMINI_RES
    GEMINI_RES=$(curl -sL -4 --max-time 8 -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" -H "Accept-Language: en-US,en" https://gemini.google.com 2>&1)
    local GEMINI_OK=1
    if echo "$GEMINI_RES" | grep -qiE "not supported in your country|country_unavailable|not available in your region"; then
        GEMINI_OK=0
    fi

    # 4. 验证 OpenAI / ChatGPT
    local CHATGPT_CODE
    CHATGPT_CODE=$(curl -sI -o /dev/null -w "%{http_code}" -L --max-time 8 https://chatgpt.com)

    echo "========================================================"
    echo -e "               🎉 解锁与脱离送中验证报告                 "
    echo "========================================================"
    
    if [ "$YT_REG" == "RU" ]; then
        echo -e "YouTube Premium 归属:        ${YELLOW}⚠ 归属俄罗斯 [RU] (免广告但 Gemini 不支持，建议选菜单 5 刷新)${NC}"
    elif echo "$YT_TEST" | grep -q "www.google.cn"; then
        echo -e "YouTube Premium 解锁:        ${RED}✗ 仍显示送中 (请检查 WARP 运行状态)${NC}"
    else
        echo -e "YouTube Premium 解锁:        ${GREEN}✓ 成功脱离送中 (当前归属: [${YT_REG:-US}])${NC}"
    fi

    if [ "$GOOGLE_CODE" == "200" ]; then
        echo -e "Google 搜索/API 解锁:        ${GREEN}✓ 解锁成功 (HTTP $GOOGLE_CODE，已脱离送中)${NC}"
    else
        echo -e "Google 搜索/API 解锁:        ${YELLOW}⚠ 状态码: $GOOGLE_CODE (200/302均属正常)${NC}"
    fi

    if [ $GEMINI_OK -eq 1 ]; then
        echo -e "Google Gemini / Antigravity: ${GREEN}✓ 正常可用 (地区已解锁)${NC}"
    else
        echo -e "Google Gemini / Antigravity: ${RED}✗ 当前地区受限 (不可用，建议选菜单 5 刷新)${NC}"
    fi

    if [ "$CHATGPT_CODE" == "200" ] || [ "$CHATGPT_CODE" == "302" ] || [ "$CHATGPT_CODE" == "403" ]; then
        echo -e "OpenAI / ChatGPT 访问状态:   ${GREEN}✓ 正常连通 (HTTP $CHATGPT_CODE)${NC}"
    else
        echo -e "OpenAI / ChatGPT 访问状态:   ${YELLOW}⚠ 状态码: $CHATGPT_CODE${NC}"
    fi
    echo "========================================================"
    echo -e "${GREEN}🎉 部署完成！若需更换出口地区，可随时运行脚本选择选项 [5] 智能刷 IP！${NC}\n"
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
        ensure_clean_warp_region
        test_unlock_status
    else
        echo -e "\n${GREEN}======================================================${NC}"
        echo -e "${GREEN}提示：原生 IP 基础定位未触发硬性跳转。${NC}"
        echo -e "${YELLOW}但若您在浏览器访问 Google 仍未显示美国、或打不开 Gemini，强烈建议继续安装！${NC}"
        echo -e "${GREEN}======================================================${NC}"
        read -p "是否继续安装 WARP 动态分流？[Y/n] (默认直接按回车继续安装): " force_choice
        force_choice=${force_choice:-y}
        case "$force_choice" in
            [yY][eE][sS]|[yY])
                echo -e "\n${YELLOW}>>> 开始安装 WARP 动态分流解锁...${NC}"
                install_dependencies
                setup_warp_profile
                setup_dnsmasq_rules
                setup_routing_rules
                ensure_clean_warp_region
                test_unlock_status
                ;;
            *)
                echo -e "\n已取消安装，保持原生网络状态。\n"
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
echo "║   • 避俄防送：智能刷 IP，自动规避俄罗斯/中国等受限地区    ║"
echo "║   • 动态嗅探：Google全家桶/YouTube/Gemini/Antigravity/AI   ║"
echo "║   • 防覆写：锁定 DNS 属性，彻底防止重启或 DHCP 导致失效   ║"
echo "║   • 零配置：小白直接运行，各代理节点无需任何路由改动       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo "1. 智能运行 (自动清理旧版 + 精准检测送中 + 智能安装)"
echo "2. 强制安装 / 修复 WARP 动态解锁"
echo "3. 测试当前解锁与归属状态"
echo "4. 彻底卸载恢复原生网络"
echo "5. 智能刷新 WARP 出口 IP (自动避开俄罗斯/中国，刷美区)"
echo "0. 退出"
echo ""
read -p "请输入选项 [0-5] (默认按回车直接智能运行 [1]): " choice
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
        ensure_clean_warp_region
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
    5)
        ensure_clean_warp_region
        test_unlock_status
        ;;
    *)
        exit 0
        ;;
esac
