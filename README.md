# mosdns 域名分流配置说明

本仓库提供一套 **基于 mosdns 的域名分流解析配置**，核心目标是：

- 🇨🇳 国内域名就近解析（AliDNS / DNSPod）
- 🌍 国外域名使用 FakeIP 配合代理
- 🧠 未明确归类的域名，通过真实 IP 归属自动判定
- ⚡ 减少无意义的上游请求，降低解析延迟与抖动

---
## 修改注意事项（文件dns.yaml）
- 10.0.0.1 -> 路由器ip，供查询局域网dns
- 198.18.0.2 -> fake ip的dns，供查询外部站点dns。surge写198.18.0.2；mihomo写IP
- 10.0.1.120:6153 -> 代理ip + socks5端口

---
## 解析流程说明

整体解析逻辑按以下顺序执行：

1. **局域网域名（rule/local）**
   - 直接交由路由器解析
   - 不参与后续分流逻辑

2. **自定义域名（my/hosts）**
   - 直接返回规则文件中定义的 IP
   - 常用于内网服务、固定地址映射等场景

3. **黑名单域名（my/blacklist 和 rule/blocklist）**
   - 直接返回无法解析（NXDOMAIN）
   - 主要用于广告域名、恶意域名等

4. **明确海外站点（my/greylist 和 `geosite:!cn`）**
   - 直接走 FakeIP 逻辑
   - 由代理侧决定最终访问出口

5. **明确国内站点（my/whitelist 和 `geosite:cn`）**
   - 交由 AliDNS / DNSPod 解析
   - 获取就近、低延迟的真实 IP

6. **未命中名单域名**
   - 先使用 Cloudflare / Google 进行解析
   - 根据返回 IP 判断是否属于 `geoip:cn`
     - **属于 CN**：再使用 AliDNS / DNSPod 解析一次，获取国内最优 IP
     - **不属于 CN**：走 FakeIP 逻辑
   - 若返回结果为 NXDOMAIN / NODATA / 上游失败，则直接返回原始结果

---
## 目录结构

```text
rule/     # 公共规则（geosite、geoip、通用分流规则）
my/       # 自定义规则（特殊映射、黑名单、白名单、灰名单）
```

---
## 依赖项目

https://github.com/IrineSistiana/mosdns

本配置已在以下 Docker 镜像中测试通过：
https://hub.docker.com/r/irinesistiana/mosdns

---
## 参考文献

- https://github.com/IrineSistiana/mosdns/discussions/837
- https://github.com/moreoronce/MosDNS-Config
