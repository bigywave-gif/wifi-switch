# Windows 0.1.1 连接取消问题修订

日期：2026-10-20。

用户在 Example-Enterprise 上点击连接后收到 `0x38001`，原网络断开；用户确认没有出现系统认证窗口。
此错误表示 Windows 取消操作，不能据此认定密码错误。没有目标 Windows 的通知记录，
尚未确认这一次取消的唯一根因。

## 修改

- 不同配置之间切换由 WlanConnect 处理，不再先调用 WlanDisconnect。
- 重新认证同一活动配置时，在改写凭据前等待 ACM disconnected 通知。
- 新连接在匹配网卡与配置的 connection_start 之后才接受完成通知，忽略更早的结果。
- 手动切换失败且原网络可用、原配置不同、网卡仍断开时，尝试一次恢复原配置；不重试失败目标的凭据。
- 失败后刷新实际网络状态，恢复原网络不标记目标账号成功。
- 最近连接诊断只保存阶段和代码，便于继续定位，排除用户名、密码、SSID 和完整配置。
- 安装器版本提升到 0.1.1，继续提供默认及自定义安装目录。

## 验证

- 33/33 测试通过，包括过期取消通知隔离、网卡/配置隔离、认证拒绝立即停止、
  以及恢复条件中的手动/自动连接、原配置、外部切换、网卡关闭和权限状态。
- Windows x64 Release 编译及自包含发布成功，NSIS 构建成功。
- 独立 7-Zip 解包验证：程序和 README 与发布目录一致，安装器与卸载程序具有有效 PE 格式。
- macOS 原有 37 个文件校验一致，没有执行 Mac Wi-Fi 连接操作。
- 尚未在目标 Windows 电脑上复现及验证本次修复；不将逻辑回归测试视为真实认证通过。

安装包：`../dist/WiFi-Switch-0.1.1-windows-x64-setup.exe`

SHA-256：`3494d04953b425b152ea5478d68e93ba2fdf8343c9bc026b638182a7190f8dac`

官方接口参考：

- https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlandisconnect
- https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/ns-wlanapi-wlan_connection_notification_data
