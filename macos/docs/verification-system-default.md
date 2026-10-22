# 系统默认 Wi-Fi 与账号同步验证

日期：2026-10-21。状态：源码实现与隔离回归完成，0.1.31（build 32）Apple 芯片内部安装包已生成并校验；未安装、未进行真实网络切换验收。

## 改动

- 主动连接完成 CoreWLAN 调用与连续三次 SSID/IP 验证后，进入保存系统默认设置阶段。
- 企业网络写入系统 Wi-Fi 用户名和密码，普通网络写密码，开放网络不访问凭据。
- 更新用户域及已存在的系统域凭据；不新增系统域条目。将目标网络置于首选列表前面，保留其完整网络配置及其他网络顺序。
- 用 SFAuthorization 请求网络设置权限，不使用 sudo、明文密码命令或常驻特权进程。
- 读回核对、网络变化和并发配置变化检查、失败回滚；回滚失败明确提示。保存失败不归类为密码错误，不触发自动重试。
- 自动恢复连接不会改写默认设置。

## 已验证

使用 /tmp 独立 SwiftPM 构建目录，编译完整 Mac 可执行目标和测试目标；Swift Testing 共 **131 个测试、9 个测试套件通过**。

工具链的 Testing.framework 最低目标为 macOS 14，测试链接存在与项目 macOS 13 目标的版本警告；本次通过不代表已在 macOS 13 实机验收。

新增覆盖：验证前不保存、认证失败不保存、后台恢复不保存、用户域与已有系统域同步、无系统条目时不新建、权限拒绝、读回不一致、部分写入回滚、新建条目撤销、连接中途变化、外部配置变化、回滚失败和错误脱敏、普通/开放网络分支、无变化不请求配置写入、失败不误导修改账号。

测试使用 FakeDefaultStore、FakeDriver 和 MockWiFiService，不读取真实密码、不写真实钥匙串、不改变当前连接或系统首选网络。

## 尚未验证的边界

- 真实网络上 Keychain/SFAuthorization 弹窗及系统域写入权限。
- 同一 SSID 切换账号后，系统断线重连、睡眠唤醒、重启后实际使用的新账号，以及相应业务网段。不能仅凭保存值或 SSID/IP 推断实时认证身份。
- CoreWLAN 没有公开的单网络 Auto-Join 开关写接口；保留原设置，不保证覆盖关闭自动加入或公司管理策略。
- 系统 Wi-Fi 用户域凭据可能随系统 iCloud 钥匙串设置同步；应用自己的独立密码条目仍不启用同步。

## 范围

本次写入仅在 macos 源码、测试、文档和构建制品。Windows 快照核对发现独立的 0.1.8 工作及构建变化，未覆盖或回滚它们，因此不宣称整个共享工作区 Windows 目录在本次期间完全未变化。

## 安装包校验

- `dist/WiFi-Switch-0.1.31-arm64-internal.dmg`，保留原签名身份，15 项签名保护测试通过。
- Release 使用独立构建缓存，避免迁移目录遗留缓存。
- DMG 校验和通过；只读挂载后，应用深度严格签名校验、包内可执行文件与 Release 应用比对、README.md/README.txt/签名说明比对通过；Applications 链接指向 `/Applications`。
- 包已更新，运行中的已安装应用未替换。系统默认连接的真实网络验收边界仍如上所述。

接口依据：[CoreWLAN 保存企业凭据](https://developer.apple.com/documentation/corewlan/cwkeychainsetwifieapusernameandpassword(_:_:_:_:))、[配置提交与授权](https://developer.apple.com/documentation/corewlan/cwinterface/commitconfiguration(_:authorization:))。
