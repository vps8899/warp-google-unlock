# 🚀 WARP Google/Gemini 专线解锁脚本 (系统级分流)

**专为 VPS 解锁 Google Gemini、ChatGPT、Netflix 等流媒体设计。**
**特别优化 RackNerd 等纯 IPv4 / 无 TUN 基础环境，一键修复“送中”问题。**

![Bash](https://img.shields.io/badge/Language-Bash-green.svg) ![System](https://img.shields.io/badge/System-Linux-blue.svg) ![Support](https://img.shields.io/badge/Support-RackNerd%2FIPv4-orange.svg)

## 🌟 核心痛点与解决方案

你是否遇到了以下问题：
* VPS IP 被 Google 标记（送中），无法使用 **Gemini**、**Google Search** 需验证码。
* VPS 是 **RackNerd** 或其他廉价商家，**没有 IPv6**，安装普通 WARP 脚本报错 `RTNETLINK answers: Permission denied`。
* 使用 Xray/Sing-box/Hy2，**不想修改复杂的 JSON 配置文件**来做分流。
* 想看 YouTube **没广告**（利用送中 IP 特性），但又想解锁 Gemini。

👉 **这个脚本就是为你准备的。**

## ✨ 功能特点

1.  **系统级路由接管 (Zero Config)**
    * 脚本直接修改 Linux 内核路由表 (`ip route`)。
    * **无论你使用 Xray, Sing-box, Hysteria2, TUIC 还是 SSH**，无需任何配置，流量在系统底层自动分流。
2.  **RackNerd / 纯 IPv4 专用修复**
    * 自动识别并剔除配置文件中的 IPv6 地址，防止启动报错。
    * **强制锁定 IPv4 Endpoint** (162.159.192.1)，解决因 DNS 解析到 IPv6 导致的握手失败 (Handshake=0) 问题。
3.  **精细化分流模式 (独家)**
    * **模式 1 (推荐)：** 仅代理 Google 搜索/Gemini/商店。**保留 YouTube 直连**（享受送中 IP 无广告福利）。
    * **模式 2：** 代理 Google 全家桶（含 YouTube）。适合 IP 彻底被墙无法看视频的情况。
    * **模式 3：** 包含 Netflix、Disney+、OpenAI 等流媒体规则。
4.  **极致稳定**
    * 内置 `PersistentKeepalive` 心跳保活，防止 WARP 隧道空闲断连。
    * 采用 `wgcf` 官方接口注册，纯净 WireGuard 协议。

## 🛠️ 一键安装

支持系统：Ubuntu / Debian / CentOS / AlmaLinux
要求：Root 权限

```bash
bash <(curl -sL https://raw.githubusercontent.com/vps8899/warp-google-unlock/main/warp-google.sh)
