# mosdns 域名分流配置说明

本仓库提供一套 **基于 mosdns 的域名分流解析配置**，核心目标是：

- 🇨🇳 国内域名就近解析（AliDNS / Tencent DNS）
- 🌍 国外域名使用 FakeIP 配合代理
- 🧠 未明确归类的域名，通过真实 IP 归属自动判定
- ⚠️ 力求解析路径和结果准确，mosdns 层不启用缓存；如需缓存建议放在 AdGuardHome 等上游/前置组件

## ⚙️ 修改注意事项（文件dns.yaml）
- 10.0.0.1 -> 路由器ip，供查询局域网dns（模板值，真实环境按实际 IP 修改）
- 198.18.0.2 / fd00:6152::2 -> fake ip的dns，供查询外部站点dns。surge写198.18.0.2 / fd00:6152::2；mihomo写IP
- Google / Cloudflare 上游：Surge 场景用 socks5 走代理，mihomo 场景用 bootstrap

## 🚀 解析流程说明

整体解析逻辑按以下顺序执行，优先级从高到低：

1. **自定义 hosts（my/hosts.txt）**
   - 直接返回规则文件中定义的 IP
   - 常用于内网服务、固定地址映射等场景
   - 压过局域网域名和所有公共规则

2. **自定义黑名单（my/blacklist.txt）**
   - 最高优先级，压过局域网域名、所有公共规则和自定义白/灰名单
   - 直接返回 NXDOMAIN

3. **自定义灰名单（my/greylist.txt）**
   - 压过局域网域名、自定义白名单里的宽泛规则和公共 direct，命中后不降级到后续规则
   - SVCB/HTTPS（qtype 64/65）直接返回 NODATA
   - A 记录走 forward_fakeipv4，AAAA 走 forward_fakeipv6，其他 qtype 返回 Cloudflare / Google 真实结果

4. **自定义白名单（my/whitelist.txt）**
   - 走 AliDNS / Tencent DNS 直连解析，压过局域网域名和公共 proxy

5. **局域网域名（rule/geosite_local.txt）**
   - 直接交由路由器解析
   - 低于 my/* 自定义规则，高于公共规则

6. **公共黑名单（rule/geosite_block.txt）**
   - 直接返回 NXDOMAIN
   - 默认不同步公共 reject/block 列表，保持空文件；需要阻断的域名优先写入 `my/blacklist.txt`

7. **公共代理域名（rule/geosite_proxy.txt）**
   - 优先于公共 direct，命中后不降级到后续规则
   - SVCB/HTTPS（qtype 64/65）直接返回 NODATA
   - A 记录走 forward_fakeipv4，AAAA 走 forward_fakeipv6，其他 qtype 返回 Cloudflare / Google 真实结果

8. **公共直连域名（rule/geosite_direct.txt + geosite_applecn.txt + geosite_googlecn.txt）**
   - 走 AliDNS / Tencent DNS 直连解析

9. **未命中名单域名（兜底逻辑）**
   - 先拦截 SVCB/HTTPS（qtype 64/65），直接返回 NODATA，防止 IPv4Hint/IPv6Hint 泄露真实 IP
   - 其余请求先带 ECS（上海电信）查询 Cloudflare / Google，用返回结果判定后续路径
   - 非 A/AAAA 记录不参与国内/海外 IP 判定，直接返回 Cloudflare / Google 真实结果
   - A/AAAA 根据 Cloudflare / Google 返回结果判断：
     - **无 IP（NXDOMAIN/NODATA）**：不再补查 AliDNS / Tencent DNS，直接走 FakeIP 兜底，避免空结果探测域名触达国内 DNS
     - **属于 CN**：清 ECS 后用 AliDNS / Tencent DNS 再查一次；若仍是 CN IP，返回真实 IP 并记录到 tmp/not-in-list-direct.txt；若变成海外/非 CN IP，走 FakeIP
     - **不属于 CN**：走 FakeIP 逻辑，并记录到 tmp/not-in-list-proxy.txt


## 📖 目录结构

```text
rule/     # 公共规则（geosite、geoip、通用分流规则）
my/       # 自定义规则（hosts、黑名单、白名单、灰名单）
cron/     # 定时任务：更新规则、汇总候选域名、自动提升高频候选、延迟重载
tmp/      # 运行时输出：未命中名单域名的分流日志（not-in-list-direct.txt / not-in-list-proxy.txt）
```

## ⏱️ 定时任务开关

定时任务的开关和阈值都在 `cron/cron.env`。

公共名单更新来源和每个名单是否同步在 `cron/sync.conf`。要新增/删除公共名单来源，或把某个名单从 `yes` 改成 `no`，直接改这个文件。

需要关闭某项功能时，直接把对应变量改成 `0`：

- `MOSDNS_SYNC_RULES_ENABLED=0`：关闭 rule/ 公共规则同步
- `MOSDNS_SYNC_CANDIDATES_ENABLED=0`：关闭每小时 not-in-list 候选域名汇总
- `MOSDNS_PROMOTE_ENABLED=0`：关闭每天自动加入 my/whitelist.txt 和 my/greylist.txt
- `MOSDNS_RELOAD_ENABLED=0`：关闭规则/名单变化后的自动重启流程

候选记录保留天数、自动提升统计窗口和阈值也在同一个文件里改。

## ✅ 手动验证

以下命令以 `10.0.1.119` 为模板 mosdns 地址；真实环境替换为实际 mosdns 地址。

- 检查 SVCB/HTTPS 是否被拦截，正常应返回 NODATA / 无 answer：
  `dig @10.0.1.119 example.com HTTPS +short`

- 检查灰名单 / 公共代理域名是否返回 FakeIP：
  `dig @10.0.1.119 <grey-or-proxy-domain> A +short`

- 检查白名单 / 公共直连域名是否返回真实 IP：
  `dig @10.0.1.119 <white-or-direct-domain> A +short`

- 查看未命中名单的自动判定候选：
  `tail -n 50 tmp/not-in-list-direct.txt`
  `tail -n 50 tmp/not-in-list-proxy.txt`

- 查看定时任务日志：
  `tail -n 50 tmp/sync-rules-$(date +%F).log`
  `tail -n 50 tmp/sync-candidates-$(date +%F).log`
  `tail -n 50 tmp/promote-candidates-$(date +%F).log`
  `tail -n 50 tmp/reload-$(date +%F).log`


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
