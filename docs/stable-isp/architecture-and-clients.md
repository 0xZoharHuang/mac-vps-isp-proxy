# 架构与客户端接入

## 线路与载体解耦

服务端负责接入认证、加密传输终止、转发到 ISP；客户端负责系统捕获、DNS、规则与连接生命周期。固定出口是后端契约，不是 PersonalVPN 品牌特性。

| 场景 | 路径 | 必须单独验证 |
|---|---|---|
| 已有 Surge 的 Mac | 独立 Hysteria2 配置 | 解析、增强模式、最终策略、UDP、IPv6 |
| FlClash macOS/Windows | mihomo AnyTLS | GUI 下发配置、辅助服务、TUN、DNS |
| 其他兼容客户端 | 同一接入契约，独立凭据 | 协议、pin 语义、系统捕获，不只看能否导入 |
| 自研 PersonalVPN | 借鉴模型、凭据引用、状态机 | Apple 签名/entitlement、扩展生命周期，仍是研发候选 |
| VPS 容器 | 受限容器封装中继 | 端口、UDP、源 IP 白名单、只读密钥挂载、资源限制；没有已验收 Docker 发行物 |
| 桌面容器 | 显式代理指定应用 | 不会自动捕获宿主全部 App，不把 privileged/host-network 当跨平台 TUN |

Hysteria2 要求客户端到 VPS 的 UDP 可达；AnyTLS 使用 TCP 接入，其 UDP relay 到 ISP 的能力仍需实测。二者是接入选择，不是自动换出口策略。SSH 管理密钥不进入客户端。

## 单控制器与 DNS 所有权

可以安装多个 VPN，不能让两套全隧道争夺默认路由/DNS。Tailscale 普通 mesh 与 Exit Node 要区别检查；普通 mesh 也可能管理 DNS，不凭进程名宣称兼容。不自动杀其他客户端。

Surge 内部切配置保持同一 Fake-IP 所有者。跨产品切换时，应用可能保留旧代理连接/Fake-IP；新客户端不掌握旧映射，不能将 `198.18.0.0/15` 当公网目的地发送。不要把这段地址当通用远程设备地址。这是历史故障机制之一，不代表所有慢速的唯一原因；VPS/ISP 有流量也不能证明目标正确。

默认公网指向唯一 Stable ISP；VPS 地址、必要 LAN/维护路径绕行避免递归。按目标设备实际地址配置，不复制他人的 LAN IP。无直连兜底不等于核心崩溃或退出后的系统级 kill switch；严格断网保护需另行设计验收。

## Surge/macOS

1. 新建独立配置，原订阅不动。General 从目标设备已验证配置逐项审查，不复制远程模块、MITM、监听 LAN 或脚本。
2. 参考[脱敏片段](../../examples/stable-isp/surge.fragment.conf)：数字 VPS IP、UDP 端口、SNI、独立密码、完整证书 SHA-256 pin，不能关闭验证。
3. Hysteria2 原生支持 UDP relay，不凭猜测增加其他客户端参数。历史 `proxy-test-url` 曾导致配置加载失败，测试参数必须查对应版本文档。
4. 全应用覆盖需验证增强模式，不仅系统 HTTP 代理。
5. 需要微信直连时用**规则模式 + FINAL Stable ISP**。严格全局代理会绕过规则，不能同时声称微信直连。Mac 6 的应用包路径前缀匹配可覆盖 helper，实际请求仍要核验。
6. 用户手动切换与恢复；监控只记录。旧 `personal-vpn/Scripts/validate-surge-stable-profile.sh` 含机器地址、旧哈希、远端查询及过时限制，不是通用/官方解析器。旧 monitor 的宽松 HTTP 通过判定不等于登录业务成功。

## FlClash/mihomo

从[官方发行](https://github.com/chen08209/FlClash)获取对应平台版本、校验摘要/签名；许可由使用者确认。优先 GUI 导入新配置、安装官方辅助服务，不推广旧 macOS 版本的 setuid 手工安装方式。

- AnyTLS 密码与证书 pin 按设备/使用组独立；`fingerprint` 是**完整证书 SHA-256**，不是 SPKI 或 `client-fingerprint`。叶证书 pin 与普通 CA/SNI 校验语义不同，按核心版本核对。
- TUN 与系统代理是两件事。授权后确认路由实际装载，不只看开关。
- 本案例用 redir-host 减少跨产品 Fake-IP 遗留；不能修复所有应用旧缓存。DNS 查询使用受控路径，bootstrap 避免“解析 VPS 必须先连 VPS”的循环。
- 看 GUI **最终下发配置**。历史 0.8.92 在 source 未设 `dns.enable: true` 时出现混入 `system://` 的行为；这是版本经验，不泛化成所有版本缺陷。
- 直连 CDN 的解析也应明确选择直连 DNS；只加路由规则仍可能绕远。
- `ipv6: false`/禁 AAAA 不是防泄漏证明；原始公网 IPv6、路由和退出状态分别测。若捕获后拒绝 IPv6，核心/TUN 可能需要启用 IPv6 地址。
- 不写永久网卡 DNS，不注入 shell 启动脚本。旧代理环境变量需先定位来源，再授权清理。
- 不把 SQLite/shared_preferences/NamedPipe 注入当公共安装步骤；GUI 版本之间内部格式不同，升级后重新验收。

## 微信与维护例外

经授权只对 App 与明确域名例外：`weixin.qq.com`、`mmbiz.qpic.cn`、`wx.qlogo.cn` 是起点，不是永久完整 CDN 列表。不使用整个 `qq.com` 或所有国内流量直连替代。查连接目标与规则，不读聊天内容。根路径 400 可证明传输到达，不能证明图片业务成功。

UU/SSH 维护按设备需要配置进程、域名与 LAN 绕行；Wi-Fi 断开、换网段、睡眠仍可能中断，不能保证独立于所有网络故障。浏览器、终端及其他公网 App 继续 FINAL/MATCH ISP，使用无代理参数的终端请求和连接日志交叉检查。

## 官方依据（2026-10-21 核对）

- [Surge Hysteria2](https://manual.nssurge.com/policies/hysteria2.html)、[进程规则](https://manual.nssurge.com/rules/process.html)
- [mihomo AnyTLS](https://wiki.metacubex.one/config/proxies/anytls/)、[TLS](https://wiki.metacubex.one/config/proxies/tls/)、[DNS](https://wiki.metacubex.one/config/dns/)、[TUN](https://wiki.metacubex.one/config/inbound/tun/)

在线手册可能包含新版本字段，历史版本不是最新版推荐。片段仅供组装，未通过目标机器完整导入与验收前不可上线。
