# VPS → 固定 ISP 出口：跨客户端接入参考

本仓库保留 PersonalVPN 的研发历史，并整理后来采用的 **VPS 中继 + 固定 ISP 出口 + 成熟客户端** 方案。线路不绑定某个菜单 App，也不要求使用 PersonalVPN。Surge、FlClash 与自建 PersonalVPN 可以作为可选方案共存；同一设备同一时刻只选择一个接管默认流量和 DNS。

```text
Surge / FlClash(mihomo) / 其他兼容客户端
       │ Hysteria2 或 AnyTLS（独立凭据、TLS）
       ▼
VPS 中继（本案例使用 DMIT）
       │ SOCKS5，供应商允许的认证方式
       ▼
固定 ISP 出口（本案例使用 IPRoyal） → 互联网
```

**文档更新：2026-10-21。不是一键安装包，也不是生产 SLA。** 本次整理不部署、不安装、不切换网络；历史现场验证和当前可重复验收分开说明。

## 阅读顺序

1. [架构与客户端接入](docs/stable-isp/architecture-and-clients.md)：选型、单控制器、Surge/FlClash、DNS、微信例外、容器边界。
2. [服务端与运维](docs/stable-isp/operations.md)：凭据、TLS、部署、容量和故障定位。
3. [迁移与验收](docs/stable-isp/acceptance.md)：测试方法、历史证据与未验证项。
4. [脱敏配置片段](examples/stable-isp/README.md)：保留地址和占位符，不能直接上线。

## 当前与历史代码

此轮发布只同步文档和脱敏片段。下表包含本地研发目录的定位，部分候选目录尚未发布到 Git；不存在的目录不是安装前置条件，也不表示此版本已经交付其实现。

| 路径 | 定位 |
|---|---|
| `docs/stable-isp/`、`examples/stable-isp/` | 当前跨客户端参考，新采用者先读这里 |
| `personal-vpn/Application/`、`TunnelExtension/` | 原生 Network Extension 研发候选，非已完成签名发布/生产验收的产品 |
| `personal-vpn/ServerDeployment/` | 早期 Hysteria2 离线候选，不覆盖后来全部 AnyTLS 部署 |
| `personal-vpn/LocalRuntime/`、`Packaging/` | 旧 root daemon / 独立 TUN 路径，不推荐新装 |
| `scripts/`、`swiftbar/` | 旧 SSH relay 栈，见[历史说明](docs/legacy-ssh-stack.md) |

## 不变的原则

- 一个明确选定的客户端拥有默认流量与 DNS；不堆叠第二套 TUN 修补第一套。
- SSH 仅管理；公网默认最终指向固定 ISP，无静默 DIRECT、订阅节点或其他出口回退。
- 用户手动切换，监控只记录，不擅自切换配置、重启其他 VPN 或恢复旧 PersonalVPN。
- 系统代理不等于终端/原生 App 全覆盖，Enhanced Mode/TUN 必须独立验收。
- 局域网、维护通道及获准微信直连是明确例外，不声称这些流量也走 ISP。
- 不写永久 DNS；停止后按基线验收。无策略回退不等于系统级 kill switch。
- 生产配置、密码、订阅 URL、私钥和完整日志留在仓库外。历史工作区未经全面秘密审计，不可 `git add .` 后直接发布。

旧文档冲突时，以此入口及 `docs/stable-isp/` 为当前采用说明；旧代码不会因文档更新而改变行为。
