# 0.1.44 / build 45 验证

日期：2026-10-22。

## 问题与修改

旧信息读取器只取 `State:/Network/Service/<id>/DNS`，没有读取 `Setup:/Network/Service/<id>/DNS`，因此系统手动 DNS 未展示。现在同一次 Dynamic Store 快照读取两种来源，仍以当前接口的运行服务 ID 绑定，不混用其他接口、全局或闲置服务的数据。

另外通过只读 `/usr/sbin/scutil --dns` 读取当前 Wi-Fi 接口的 scoped 默认解析器，单独展示“当前 DNS（Wi-Fi）”；不根据手动配置存在与否猜测生效结果。排除其他接口、全局、mDNS、按域名及服务专属解析器。未知输出/权限失败/超时返回未确认。

命令在后台执行，等待最多 3 秒，超时终止；输出边读边收集，最多保留 256 KiB，超限丢弃结果。返回前继续核对网卡、SSID、安全类型、BSSID，原有账号与连接可见性条件不变。示例模式使用模拟 DNS，不调用系统诊断。

## 验证

- 完整 Swift Testing：173 tests / 14 suites 通过，日志 `.build/dns-tests.log`。
- 新增 8 项测试：手动/自动分离和跨服务隔离；仅手动和删除后刷新；相同地址保留来源及异常接口过滤；真实读取模式包含 Setup DNS；当前地址来自观察而非配置推断；解析器排除全局/VPN/域名/服务专属项；无权限、缺失、损坏、mDNS 不猜测；IPv6 scope 和多个解析器顺序。
- 目标设备的 `scutil` 只读核对确认手动 DNS、按接口查询的当前 DNS 与自动 DNS 为不同来源；原始地址及网卡标识已脱敏。取值时间不同，验证未修改系统设置。
- 使用当前生产 `WiFiInformationReader` 和 `DNSResolverReader` 源码编译只读探针，三行输出与上述系统结果一致。探针使用真实 DNS 数据，但为避免额外定位授权，连接身份门控使用合成接口；不声称完成真实 SSID 门控或 UI 验收。探针位于 `.build/dns-probe/`。
- 主配置列表、菜单栏以及连接/凭据逻辑未修改；Windows 未修改。未安装新包、未修改网络设置或读取密码；未完成新窗口的原生截图验收。

## 数据含义

“当前 DNS”指系统当前为 Wi-Fi 接口配置的解析器集合，不能追踪某次查询实际选中的服务器。多个地址全部显示，不承诺每个地址都收到查询。VPN、加密 DNS、按域名分流或应用自身 DNS 可能使用其他路径。读取失败明确显示“未确认”，不会回退到猜测。

参考：[Apple scutil 手册（--dns 报告当前 DNS 配置）](https://github.com/apple-oss-distributions/configd/blob/main/scutil.tproj/scutil.8)、[SystemConfiguration DNS 地址字段](https://developer.apple.com/documentation/systemconfiguration/kscpropnetdnsserveraddresses-swift.var)。

发布编译、签名、DMG 校验、只读挂载、Applications 入口与二进制/README/CHANGELOG 一致性检查全部通过；日志 `.build/dns-package.log`。

## 制品

- Mac 0.1.44（45），arm64，macOS 13+，本地证书内部签名，未公证。
- `macos/dist/WiFi-Switch-0.1.44-arm64-internal.dmg`
- SHA-256：`e9044801d512ec1a3e2cfec3fd52736df18599c3c6c5afc68388a06873ad7b1e`
- release.json 由打包脚本校验通过后更新，旧 DMG 保留；尚未安装。
