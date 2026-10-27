# macOS 0.1.59 验证记录

日期：2026-10-27（Asia/Shanghai）；构建：60。

## 自动化测试

257 项 Swift 测试、20 个 suite 通过；9 项发布规则测试、15 项签名规则测试通过。测试覆盖企业 Wi-Fi 手动切换和应用自动重连，系统默认账号相同、不同、无法读取，认证调用失败，最终 IP 不可用，互联网检测可达及不可达，以及系统抢先恢复后重新识别账号。断线时丢弃过期读取结果，不将系统默认账号与本次请求不同误判为密码变化。

连接驱动已有测试验证断开旧连接、提交所选凭据和连续三次目标 SSID／可用 IP。测试使用模拟网络和内存凭据，不读取真实密码。日志：`.build/manual-verify/59-tests.log`。

## 原生隔离界面

使用生产 AppModel、ContentView、MenuPanel 的 Menu Import Preview 和模拟服务。点击 App recovery 后，顶部、账号、网络行及菜单均显示 Studio，菜单与账号为绿色对钩，网络行为绿色状态点，提示“自动重连成功，当前账号：Studio”。点击 System power cycle，主面板与菜单切换为示例公司账号，清除旧 Studio 提示。模拟界面不连接实际 Wi-Fi、不读写真实钥匙串。

## 限制与升级

绿色表示应用使用所选凭据的关联调用和 SSID/IP 检查成功，且互联网探测通过；不代表直接获取认证服务器的本次会话用户名。真实 Example-Enterprise 的项目／办公账号切换、服务器身份、权限及系统自动恢复仍需目标设备验收。系统控制中心主动断开但不关闭 Wi-Fi 时，应用仍可能自动恢复，来源识别不是本次改动范围。

无需数据迁移，不改变系统 Wi-Fi 首选或自动加入；Windows 无改动。未自动安装。

## 制品

发布脚本已完成签名、DMG 校验、只读挂载、包内应用与说明一致性检查；release.json 为 0.1.59／60。独立检查 Info.plist 与二进制确认版本 0.1.59、构建 60、Apple Silicon arm64、最低 macOS 13、内部使用版，图标 AppIcon。采用既有本地签名，未 Apple 公证，未安装。

安装包：`macos/dist/WiFi-Switch-0.1.59-arm64-internal.dmg`

SHA-256：`14583aa2564f22a559a32de131a023065d4997fe91eef636f62bdf015597c513`

发布日志：`.build/manual-verify/59-package.log`。`git diff --check` 通过；Windows 无工作区变更。
