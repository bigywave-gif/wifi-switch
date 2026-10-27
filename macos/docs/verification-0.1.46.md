# 0.1.46 / build 47 验证

日期：2026-10-22。

## 问题证据与边界

用户报告系统“拷贝密码”可用，WiFi Switch 添加个人热点时没有授权弹窗，直接提示无法读取完整配置。

本机针对用户指定热点的只读探针观察到：

- 默认搜索列表和系统钥匙串中均存在准确 SSID 对应条目，服务为 `AirPort`、类型为 `AirPort network password`，两个查询不能据此当作两个不同条目。
- CoreWLAN `CWKeychainFindWiFiPassword` 用户域查询返回 `4097`；系统域返回 `-25293`。探针禁止用户交互，且密码输出指针为 nil，因此系统域结果不能解释为用户拒绝或密码错误。
- 旧代码先查询用户域，抛错后不会继续读取后续凭据，并在最外层统一映射为 unavailable。这是一条能导致截图错误的明确路径；未取得旧应用那一次的原始返回码，不能宣称排除了所有其他原因。
- 新查询使用生产 `PersonalWiFiKeychainReader.searchQuery` / `passwordQuery`：查找 status=0、一个条目；引用解析 status=0、SSID 与服务均匹配。此探针移除了 ReturnData，只验证引用/元数据，没有读取用户密码、没有弹窗或修改钥匙串。
- 命令行受定位权限限制，不能可靠读取当前 SSID；没有切换用户实际网络来复现完整导入。

诊断程序位于 `.build/hotspot-import/`。所有输出仅含状态码和匹配结果，不含密码或条目引用。

## 实现

普通 Wi-Fi/热点的用户确认导入先精确查找 `class=generic password / service=AirPort / account=SSID`。先读取属性和持久引用，再每次按一个引用读取属性和密码；重新核对服务/SSID，保留密码原值，重复引用只读一次。没有标准条目才进入原 CoreWLAN 路径；授权取消/拒绝、数据损坏不换路径继续查询。多个不同密码仍交给原冲突检查拒绝导入。

这一流程仅用于点击添加后的读取；后台识别不读取密码。企业认证、开放网络及系统凭据同步写入策略不变。操作前后仍核对连接，返回后改用重新获取的接口核对认证方式。

错误区分取消、拒绝、交互不可用、认证方式未知、数据缺失，接口错误保留阶段与状态码。配置及密码只在完成读取和一致性校验后保存。

依据 [Apple SecItemCopyMatching 文档](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))，不能用 MatchLimitAll 同时获取密码数据，因此采用先枚举引用、再逐项读取的方式；CoreWLAN 参数及返回码合同参见 [Apple 文档](https://developer.apple.com/documentation/corewlan/cwkeychainfindwifipassword(_:_:_:)) 和本机 SDK CoreWLANUtil.h。AirPort 条目字段来自本机准确 SSID 的实际元数据观察，不声称涵盖 Apple 所有私有凭据存储方式。

## 验证

- 完整 Swift Testing：185 tests / 15 suites 通过；日志 `.build/hotspot-import/tests.log`。
- 新增 8 个测试函数：标准条目读取且不调用 CoreWLAN；取消/拒绝/禁止交互立即停止；仅不存在时允许后备；企业/开放路径隔离；多条目不同密码冲突及引用去重；错误 SSID/服务不读取密码；条目消失/变化/无效数据失败；原始阶段及 4097 传到弹窗且不保存配置。
- 9 项发布规则测试通过。
- 未改主配置面板布局、Wi-Fi 连接及同步实现、Windows；未安装新包或改动真实用户数据。未重复上版菜单模拟界面点击验证。
- 模拟测试和只读元数据验证不等于真实热点密码导入验收；新包第一次读取系统密码仍可能需要用户在 macOS 窗口授权。

## 制品

- Mac 0.1.46（47），arm64，macOS 13+，本地证书内部签名、未公证。
- `macos/dist/WiFi-Switch-0.1.46-arm64-internal.dmg`
- SHA-256：`6d43cc648a7479e88ec7bcef470ee9fab475f9938e0877bb289970a5d2b1d2ba`
- 发布构建、签名验证、DMG 校验、只读挂载、Applications 入口、包内二进制及 README/CHANGELOG 一致性检查全部通过；日志 `.build/hotspot-import/package.log`。
- 再次核对版本、构建号、架构、最低系统要求及发布类型通过；release.json 由打包成功后自动记录。
- 旧版 DMG 保留，新包未安装到本机。
