# 0.1.32 验证记录

日期：2026-10-21。Mac arm64 内部包，build 33。

## 本次交付

保留连接验证后的账号密码同步，仅作用于目标 SSID。移除首选网络列表的读取、重排和提交，以及 SFAuthorization 网络配置授权。应用不再额外设置首选顺序或 Auto-Join；macOS 本身仍可根据手动连接历史更新偏好。

## 证据

- Swift Testing：132 个测试、9 个套件通过。包含公司网络与家庭热点分开保存、切换同一公司 SSID 的账号不覆盖热点凭据、写入失败和回滚。
- 源码检查：生产源码没有 commitConfiguration、SFAuthorization、networkProfiles 赋值或 promoting 调用。
- Release 编译、原签名身份兼容校验、严格签名校验、DMG 校验通过。
- 只读挂载后，包内应用可执行文件和 README.md/README.txt 与构建输出一致；Applications 链接正确；已卸载校验卷。
- 产物：`dist/WiFi-Switch-0.1.32-arm64-internal.dmg`。
- SHA-256：`b3239dc12b2bb3c6a4a07811726ee6e74d2d43b6afcb352cd7999a18e3a11b12`。

## 未完成及限制

未安装到本机，未切换真实网络，未改写真实 Wi-Fi 密码。用户报告的系统首次读取 Example-Enterprise 凭据的钥匙串弹窗未修复。0.1.31 改过的网络顺序没有原始备份，不自动猜测恢复。

当前界面已有实际 SSID 的主窗口摘要，但菜单栏、未保存网络和跨 SSID 账号标记仍需进一步完善。此版本没有实现按网络独立恢复账号历史，也不保证能读取系统当次实际认证身份；不得把此包描述为已解决全部系统状态同步场景。
