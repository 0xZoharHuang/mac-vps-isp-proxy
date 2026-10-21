# 脱敏片段，不是可安装配置

`192.0.2.10` 是文档保留地址；`vpn.example.com` 和 `REPLACE_*` 必须替换。没有真实秘密或证书 pin。

- [Surge](surge.fragment.conf)：仅 Proxy/Rule，没有机器相关 General。
- [mihomo](mihomo.fragment.yaml)：仅代理/DNS/规则思路，不启用 TUN/辅助服务，不承诺宿主 IPv6 防泄漏。

不能直接接管网络。按[指南](../../docs/stable-isp/architecture-and-clients.md)在仓库外生成私有完整配置，再经实际解析与验收。LAN/Tailscale/维护路径根据设备补齐，不能复制别人地址。微信例外默认注释，严格全局模式不执行这些规则。

没有一键安装、提权、自动回滚或后台任务。本次只做静态文档/片段检查，未做官方核心完整配置验证。
