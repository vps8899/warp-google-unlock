# 🚀 VPS 系统级 WARP 智能动态解锁与防送中脚本

[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20CentOS-orange.svg)]()
[![Cloudflare WARP](https://img.shields.io/badge/Cloudflare-WARP-f38020.svg)]()

专为 Linux VPS 打造的**系统底层智能动态分流解锁方案**。针对 Google 全家桶、Google Play 商店、谷歌学术、YouTube Premium 以及主流 AI 服务（Gemini / ChatGPT / Claude）实现**精准定向分流**。

非目标流量（如 x.com、GitHub、普通外网访问等）**100% 走 VPS 原生网络**，既完美解除限制，又保持原生速度与低延迟！

---

## 🌟 核心特色与技术优势

- 🧠 **智能送中检测**：运行即自动调用 Google 搜索底层与 YouTube 官方区域接口探测，未送中自动提示免装，拒绝盲目折腾。
- 🎯 **全自动动态嗅探**：采用 Dnsmasq + Ipset + Fwmark 策略路由，只要访问指定域名或其任意子域名，自动实时入库并走 WARP 出口。
- 🛡️ **全球骨干网段兜底**：预置 Google 全球核心 CIDR 骨干网段，即使 DNS 解析发生波动，也能实现零延迟防遗漏。
- 🌍 **智能避俄防送**：内置智能区域嗅探，自动检测并规避分配到俄罗斯 (RU) 或中国 (CN) 的受限出口，确保分配纯净可用节点。
- 🔒 **防覆写 DNS 保护**：自动清理并接管 DNS，锁定属性防止系统重启或机房 DHCP 强行覆盖导致失联或断网。
- ⚡ **零配置小白体验**：系统全局生效，不论您使用 Xray、Sing-box、V2Ray 还是自建协议，各节点**无需修改任何路由规则**，即装即用。
- 🧹 **一键彻底清零卸载**：提供无残留卸载功能，循环清理所有策略路由、网卡、防火墙表及守护服务，秒级恢复纯净原生系统。

---

## 📥 一键安装与管理命令

在您的 Linux VPS（Debian / Ubuntu / CentOS / AlmaLinux / Rocky）终端中以 `root` 用户运行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/vps8899/warp-google-unlock/main/warp-google.sh)
```

> **提示**：脚本自带交互式控制台，支持：
> 1. `智能运行`（自动清理旧版 + 精准检测送中 + 智能安装）
> 2. `强制安装 / 修复`
> 3. `测试当前解锁与归属状态`
> 4. `彻底卸载恢复原生网络`
> 5. `智能刷新 WARP 出口 IP`（自动避开受限地区，刷美区）

---

## 📋 完整解锁域名与服务矩阵

系统支持**根域名全自动泛解析**，凡是以对应根域名结尾的**所有前缀子域名自动全部覆盖**：

| 业务矩阵 | 覆盖范围与关键说明 | 包含的根域名（所有二级/多级子域名全自动生效） |
| :--- | :--- | :--- |
| **Google 搜索与核心基础** | 搜索主站、亚太防跳转域名、API 总线、CDN 资源库、骨干节点 | `google.com`<br>`googleapis.com`<br>`googleusercontent.com`<br>`gstatic.com`<br>`1e100.net`<br>`google.co.jp`<br>`google.com.hk`<br>`google.com.tw`<br>`google.cn`<br>`goo.gl`<br>`google.dev`<br>`web.dev`<br>`chrome.com`<br>`google-analytics.com`<br>`googletagmanager.com` |
| **Google 学术** | 谷歌文献检索、引用文献库 | 由 `google.com` / `google.com.hk` 全自动泛解析完美覆盖 |
| **Google Play 商店生态** | 商店主页、应用与游戏安装包下载 CDN、图标图片资源、Android 底层组件 | `android.com`<br>`googleplay.com`<br>`gvt1.com` *(核心APK下载CDN)*<br>`gvt2.com`<br>`gvt3.com`<br>`ggpht.com` *(高清图标截图)*<br>`app-measurement.com` |
| **YouTube 影音全系列** | 官网主页、短链接、视频与音频流切片 CDN、缩略图服务器（解决送中与后台播放限制） | `youtube.com`<br>`youtu.be`<br>`yt.be`<br>`googlevideo.com` *(核心视频流服务器)*<br>`ytimg.com` |
| **Google AI 矩阵** | Gemini AI 对话、开发者模型平台、DeepMind、笔记本等全新 AI 工具 | `gemini.google.com`<br>`antigravity.google`<br>`aistudio.google.com`<br>`bard.google.com`<br>`notebooklm.google`<br>`generativeai.google`<br>`deepmind.com`<br>`deepmind.google` |
| **AI 对话全家桶** | ChatGPT、Claude 官网与登录认证、API 数据传输、图片文件交互 | `chatgpt.com`<br>`openai.com`<br>`oaistatic.com`<br>`oaiusercontent.com`<br>`auth0.openai.com`<br>`claude.ai`<br>`anthropic.com` |

---

## 🔍 日常状态与流量检测方法

如需验证分流是否真正生效、流量是否确实走 WARP，可使用以下检测命令：

### 1. 验证防火墙分流命中（实时计数）
```bash
iptables -t mangle -L OUTPUT -v -n | grep warp_unlock
```
- **解读**：输出前两列为 `pkts`（命中包数）和 `bytes`（流量大小）。当您访问 Google 或 AI 时，该数字持续递增，证明流量被精准捕获并引流。

### 2. 检查 WireGuard 隧道回包状态
```bash
wg show warp0
```
- **解读**：重点观察 `transfer: xx KiB received, xx KiB sent`。只要 `received` 大于 0 且有持续增长，证明隧道双向互通、回包完全正常。

### 3. 查看原生公网出口 IP（验证未分流网站走直连）
```bash
curl -4 -s ip.sb
```
- **解读**：返回 VPS 本机原生公网 IP，证明普通外网流量依然保持原生极速直连。

---

## 🛠️ 常见问题解答 (FAQ)

### Q: 为什么某些网站打开提示验证码或显示受限？
- 部分机房 IP 若曾被分配到俄罗斯或受限节点可能触发验证。直接在脚本菜单中选择选项 **`[5] 智能刷新 WARP 出口 IP`**，脚本将自动轮换直至锁定干净可用的非受限出口。

### Q: 卸载后系统是否会残留垃圾规则？
- 不会。在脚本菜单中选择选项 **`[4] 彻底卸载恢复原生网络`**，脚本将循环清理所有 mangle / nat / filter 表规则、注销路由表 51820、销毁 ipset 集合并恢复官方标准 DNS。
