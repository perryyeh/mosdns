# mosdns 域名分流配置说明

本仓库提供一套 **基于 mosdns 的域名分流解析配置**，核心目标是：

- 🇨🇳 国内域名就近解析（AliDNS / Tencent DNS）
- 🌍 国外域名使用 FakeIP 配合代理
- 🧠 未明确归类的域名，通过真实 IP 归属自动判定
- ⚠️ 无缓存，建议配合 adguardhome 使用

## ⚙️ 修改注意事项（文件dns.yaml）
- 10.0.0.1 -> 路由器ip，供查询局域网dns（模板值，真实环境按实际 IP 修改）
- 198.18.0.2 / fd00:6152::2 -> fake ip的dns，供查询外部站点dns。surge写198.18.0.2 / fd00:6152::2；mihomo写IP
- Google / Cloudflare 上游：Surge 场景用 socks5 走代理，mihomo 场景用 bootstrap

## 🚀 解析流程说明

整体解析逻辑按以下顺序执行，优先级从高到低：

1. **局域网域名（rule/geosite_local.txt）**
   - 直接交由路由器解析
   - 不参与后续分流逻辑

2. **自定义 hosts（my/hosts.txt）**
   - 直接返回规则文件中定义的 IP
   - 常用于内网服务、固定地址映射等场景

3. **自定义黑名单（my/blacklist.txt）**
   - 最高优先级，压过所有公共规则和自定义白/灰名单
   - 直接返回 NXDOMAIN

4. **自定义灰名单（my/greylist.txt）**
   - 走 FakeIP，压过自定义白名单里的宽泛规则和公共 direct
   - A 记录走 forward_fakeipv4，AAAA 走 forward_fakeipv6

5. **自定义白名单（my/whitelist.txt）**
   - 走 AliDNS / Tencent DNS 直连解析，压过公共 proxy

6. **公共黑名单（rule/geosite_block.txt）**
   - 直接返回 NXDOMAIN

7. **公共代理域名（rule/geosite_proxy.txt）**
   - 走 FakeIP，优先于公共 direct，降低 DNS 污染风险
   - A 记录走 forward_fakeipv4，AAAA 走 forward_fakeipv6

8. **公共直连域名（rule/geosite_direct.txt + geosite_applecn.txt + geosite_googlecn.txt）**
   - 走 AliDNS / Tencent DNS 直连解析

9. **未命中名单域名（兜底逻辑）**
   - 先拦截 SVCB/HTTPS（qtype 64/65），直接返回 NODATA，防止 IPv4Hint/IPv6Hint 泄露真实 IP
   - 带 ECS（上海电信）查询 Cloudflare / Google
   - 非 A/AAAA 记录直接返回 remote 结果
   - 不带 ECS 再查一遍，用于后续 IP 归属判断
   - 根据返回 IP 判断是否属于 geoip:cn：
     - **属于 CN**：再用 AliDNS / Tencent DNS 解析一次，获取国内最优 IP → 记录到 tmp/not-in-list-direct.txt
     - **无 IP（NXDOMAIN/NODATA）**：再用 AliDNS / Tencent DNS 解析一次；仍无结果则返回原始结果
     - **不属于 CN**：走 FakeIP 逻辑 → 记录到 tmp/not-in-list-proxy.txt


## 📖 目录结构

```text
rule/     # 公共规则（geosite、geoip、通用分流规则）
my/       # 自定义规则（hosts、黑名单、白名单、灰名单）
cron/     # 定时任务：00:00 更新 IP 和 site 库，00:15 更新不在名单中的域名分流结果
tmp/      # 运行时输出：未命中名单域名的分流日志（not-in-list-direct.txt / not-in-list-proxy.txt）
```


## 📦 依赖项目

https://github.com/IrineSistiana/mosdns

本配置已在以下 Docker 镜像中测试通过：
https://hub.docker.com/r/irinesistiana/mosdns

## 📊 数据来源

- 域名分类（geosite）：https://github.com/Loyalsoldier/v2ray-rules-dat
- IP 归属（geoip）：https://github.com/gaoyifan/china-operator-ip


## 📚 参考文献

- https://github.com/IrineSistiana/mosdns/discussions/837
- https://github.com/moreoronce/MosDNS-Config

## 📜 License
MIT License © 2026
