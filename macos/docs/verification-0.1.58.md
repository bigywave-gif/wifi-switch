# macOS 0.1.58 验证记录

日期：2026-10-26（Asia/Shanghai），构建 59。

## 自动化验证

255 项 Swift 测试／20 个 suite 通过，覆盖：系统默认用户名与请求用户名相同／不同均不能证明当前企业会话身份；无法读取系统属性时不申请密码读取；断线后丢弃未返回的属性查询；应用恢复保留请求目标，系统恢复清除旧提示并重新识别。网络异常优先于灰色身份提示。原有热点密码核对、稳定差异二次读取、系统首选保留和失败回滚测试继续通过。

测试采用内存凭据和模拟驱动，不读取真实密码。日志：`.build/manual-verify/58-tests.log`。

## 原生界面验证

独立 Menu Import Preview 使用生产 AppModel、ContentView、MenuPanel 与模拟服务：点击 App recovery 后，主面板和菜单显示 Studio · 未核验，操作提示仅说明自动重连流程完成，标记为灰色信息按钮。点击后原生窗口列出请求 Studio（studio-user）、系统保存示例公司账号（demo-user）及来源；内容与关闭按钮完整可见。

点击 System power cycle 后，系统模拟恢复到示例公司账号，两处标记同步恢复，旧 Studio 请求提示清除。未更改真实 Wi-Fi、系统首选或真实钥匙串。最后补充无障碍标签“本次请求账号，未核验”，避免读屏继续称其为已确认当前账号。

## 现场诊断与限制

只读系统日志表明 该次关联请求由 WiFiSwitch 发起，随后 eapolclient 认证成功，join 为 auto=no；不是仅凭截图推断系统自动加入。但日志没有可确认的本次认证用户名。系统复制出的用户名是保存凭据，不足以确认实际会话属于办公或项目。

本版修复未核验身份却绿色成功的错误声明，未实现服务器认证用户名查询。真实 Example-Enterprise 双账号仍需服务器记录或业务权限验收。系统控制中心主动断开但保持 Wi-Fi 开启，现有应用恢复可能触发；这项来源识别限制没有在本版修复。

无需数据迁移，不改变系统自动加入、首选账号或钥匙串授权范围，不修改 Windows，不自动安装。

## 制品

发布规则测试 9 项、签名规则测试 15 项通过。package-internal.sh 已完成签名、DMG 校验、只读挂载及包内二进制／说明／版本记录一致性检查，release.json 更新为 0.1.58／59。独立读取成品 Info.plist 与 lipo 确认版本 0.1.58、构建 59、arm64；沿用本地签名，未 Apple 公证，未安装到 Applications。

安装包：`macos/dist/WiFi-Switch-0.1.58-arm64-internal.dmg`

SHA-256：`997b70854a9e15a36c752bdfa8fc553209ffeaa702f6f21be19991fde8b0bb03`

发布日志：`.build/manual-verify/58-package.log`。`git diff --check` 通过，Windows 无工作区变更。
