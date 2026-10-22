# 0.1.37 / build 38 验证

日期：2026-10-22。范围仅 macOS；本次未修改 Windows 源码、配置或制品，未替换本机 Applications 中的应用。

## 功能

配置管理中 Wi-Fi 行的更多菜单新增“查看 Wi-Fi 信息”。只读窗口显示 IPv4、子网掩码、网关、IPv6/前缀、Wi-Fi 服务 DNS、当前接口 MAC、BSSID、信道、RSSI/噪声、协商速率及系统安全类型。每 5 秒刷新，可手动刷新、选择文字复制、关闭。

数据来自 CoreWLAN、SystemConfiguration 及 getifaddrs。读取前后核对网卡、SSID、安全类型及 BSSID。所选网络未连接、名称不可读、关机或读取失败时，不展示其他网络的实时地址。DNS 根据运行时 InterfaceName 绑定服务，不使用全局/VPN DNS。802.1X 的具体 EAP 类型与本次认证身份不由这些接口推断，不访问钥匙串或密码。

## 验证结果

- Swift Testing：160 tests / 12 suites 全部通过。新增 6 项覆盖地址与掩码对应、IPv6/网关、DNS 隔离及去重、非当前网络、权限/关机/读取失败、连接变化、缺失字段、安全类型。
- 本机只读生产读取器探针：en0、Wi-Fi 开启；获取到 IPv4 1 条、IPv6 1 条、当前 MAC、网关及 Wi-Fi 服务 DNS 2 条。终端进程 SSID 不可读，未声称完整 SSID 匹配路径已完成实机验收。探针仅输出是否可用及数量，没有记录实际地址或凭据。
- 独立 bundle ID 的 --demo 副本：通过原生 UI 操作验证新增菜单；打开表单并查看截图，字段按分区对齐，滚动到底能完整查看认证信息；手动刷新时间更新，自动刷新仍保持窗口，Escape 正常关闭。演示数据明确标记，不读取或修改真实网络。
- 发布脚本完成签名校验、DMG 校验、只读挂载后的二进制/使用说明一致性与 Applications 入口检查。About 继续从 Bundle 读取版本信息。
- 实际包信息：0.1.37 (38)，arm64，最低 macOS 13；内部本地证书签名，未 Apple 公证。

## 产物

`macos/dist/WiFi-Switch-0.1.37-arm64-internal.dmg`

SHA-256：`47bbe4b67391cc973a2670f42963275ecb4a693445cdf871e82d43a9af4983bf`

日志：`macos/.build/network-information/tests.log`、`live-reader.log`、`package-0.1.37.log`。
