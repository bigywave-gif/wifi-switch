# WiFi Switch

**在 macOS 和 Windows 上管理多组 Wi-Fi 账号，快速切换企业网络、家庭 Wi-Fi 与手机热点。**

WiFi Switch 是一款原生桌面工具，按「账号 → Wi-Fi」整理连接配置。同一账号可以关联多个网络，同一网络也可以保存多个账号；从菜单栏或系统托盘选择账号即可发起连接，密码保存在本机系统凭据库中。

[下载安装](#下载安装) · [快速上手](#快速上手) · [功能与平台差异](#功能与平台差异) · [使用文档](#使用文档) · [问题反馈](https://github.com/bigywave-gif/wifi-switch/issues)

## 下载安装

Mac 与 Windows 独立维护版本。以下是当前已打包并上传的安装文件，下载后即可安装，无需自行编译。

| 平台 | 当前版本 | 系统与架构 | 安装包 | 校验文件 |
| --- | --- | --- | --- | --- |
| macOS | **0.1.66** · build 67 | macOS 13+ · Apple Silicon（arm64） | [下载 DMG](https://github.com/bigywave-gif/wifi-switch/releases/download/macos-v0.1.66/WiFi-Switch-0.1.66-arm64-internal.dmg) | [SHA-256](https://github.com/bigywave-gif/wifi-switch/releases/download/macos-v0.1.66/WiFi-Switch-0.1.66-arm64-internal.dmg.sha256) |
| Windows | **0.1.9** | Windows 10/11 · Intel/AMD x64 | [下载 EXE 安装程序](https://github.com/bigywave-gif/wifi-switch/releases/download/windows-v0.1.9/WiFi-Switch-0.1.9-windows-x64-setup.exe) | [SHA-256](https://github.com/bigywave-gif/wifi-switch/releases/download/windows-v0.1.9/WiFi-Switch-0.1.9-windows-x64-setup.exe.sha256) |

[Mac 发布说明](https://github.com/bigywave-gif/wifi-switch/releases/tag/macos-v0.1.66) · [Windows 发布说明](https://github.com/bigywave-gif/wifi-switch/releases/tag/windows-v0.1.9) · [全部发行版本](https://github.com/bigywave-gif/wifi-switch/releases)

> 当前提供内部测试版，供验证与试用。Mac 包使用本地证书签名、未经过 Apple 公证；Windows 包尚未进行 Authenticode 代码签名。Windows 的安装、驱动交互与真实企业认证仍需目标设备验收。当前没有提供 Intel Mac 或 Windows ARM64 专用安装包。

### macOS

1. 下载并打开 DMG，将 **WiFi Switch.app** 拖到 **Applications（应用程序）**。
2. 从“应用程序”启动。升级前先在旧版齿轮菜单中选择 **退出系统**，再替换应用。
3. 首次打开若被 macOS 阻止，确认文件来源后按 [Apple 的说明](https://support.apple.com/zh-cn/102445)，在 **系统设置 → 隐私与安全性** 中允许打开。
4. 按应用提示授予定位权限，以便扫描网络和读取当前 Wi-Fi 名称。

安装用户无需 Xcode 或 Apple 开发者账号。此 DMG 仅适用于 Apple Silicon Mac。

### Windows

1. 下载并运行 EXE 安装程序，使用默认目录或选择当前用户有写入权限的位置。
2. 从开始菜单中的 **WiFi Switch** 启动，使用普通用户会话，无需另外安装 .NET。
3. 升级前先从托盘齿轮菜单中选择 **退出系统**，再运行新安装包。
4. 扫描或读取 Wi-Fi 信息被拒绝时，检查 **设置 → 隐私和安全性 → 位置** 中的桌面应用权限，以及单位的设备管理策略。

安装包未签名，Windows 可能显示未知发布者提示。受管理设备请按单位策略处理，不要关闭系统安全保护，也不要通过“以管理员身份运行”绕过权限问题。

### 校验下载文件

同时下载对应的 `.sha256` 文件，将它与安装包放在同一目录。

macOS / Linux：

```sh
shasum -a 256 -c WiFi-Switch-0.1.66-arm64-internal.dmg.sha256
```

Windows PowerShell：

```powershell
Get-FileHash .\WiFi-Switch-0.1.9-windows-x64-setup.exe -Algorithm SHA256
Get-Content .\WiFi-Switch-0.1.9-windows-x64-setup.exe.sha256
```

核对计算结果与校验文件中的哈希一致。GitHub 自动生成的 **Source code (zip / tar.gz)** 是源码压缩包，安装时请选择上表中的 DMG 或 EXE。

## 快速上手

1. **添加账号**：填写便于辨认的备注，并选择或手动添加一个或多个 Wi-Fi。
2. **填写凭据**：企业网络需要用户名与密码；普通密码网络或手机热点使用密码；开放网络不需要凭据。必填项会随所选网络调整。
3. **保存配置**：保存仅建立账号与网络关联，不立即连接或验证密码。
4. **连接网络**：展开账号，点击目标 Wi-Fi 旁的 **连接**。切换时会短暂断网，请等待应用确认结果。
5. **日常切换**：关闭主窗口后，仍可通过 macOS 菜单栏或 Windows 系统托盘使用；从齿轮菜单进入配置管理或退出应用。

同一账号下的网络共用一份密码，密码不同的网络请分别创建账号。删除账号会移除该账号在应用中的配置与凭据，不会自动让系统忘记已知网络。

## 功能与平台差异

- **多个账号与网络**：集中管理企业 Wi-Fi、普通密码 Wi-Fi、手机热点和开放网络。
- **菜单栏与系统托盘**：查看当前连接、切换保存的账号，并快速进入配置管理。
- **本机密码存储**：macOS 使用钥匙串，Windows 使用凭据管理器；账号配置文件不保存明文密码。
- **明确的连接结果**：展示连接中、成功、失败及恢复状态，避免把保存配置当作认证成功。

| 能力 | macOS | Windows |
| --- | --- | --- |
| 原生界面 | SwiftUI / AppKit | Windows Forms |
| 企业 Wi-Fi | 通过 CoreWLAN 使用用户名与密码认证 | PEAP/MSCHAPv2；保留兼容系统配置的证书与服务器验证设置 |
| 连接与系统配置 | 连接前可选择“同步账号”或“仅本次连接” | 连接时将目标 WLAN 配置设为自动加入并提升优先级，即使连接失败也保留此设置 |
| 系统账号与密码核对 | 支持添加系统配置、核对及确认后更新保存的凭据 | 按 WLAN 配置标记与连接状态识别账号；提供“认领当前连接” |
| 网络信息与诊断 | 查看 IP、网关、DNS 等信息；菜单栏提供互联网状态检测 | 多网卡选择、连接进度与诊断 ZIP 导出 |
| 故障恢复 | 断线后等待系统恢复，再由用户确认是否重连 | 自动恢复及失败停止机制，详见平台说明 |

企业策略、EAP 类型和系统授权会影响可用功能。两端的连接方式、状态判断和恢复规则不同，完整行为见 [产品功能说明](docs/product-functional-spec.md)。

## 数据与权限

| 数据 | macOS | Windows |
| --- | --- | --- |
| 账号与网络配置 | `~/Library/Application Support/WiFiSwitch/accounts.json` | `%LOCALAPPDATA%\WiFiSwitch\accounts.json` |
| 密码 | 当前用户的 macOS 钥匙串 | 当前用户的 Windows 凭据管理器 |

应用不提供账号云同步，不上传 Wi-Fi 账号和密码。Mac 的互联网检测会连接 Apple 与 Microsoft 的 HTTPS 端点，不携带账号凭据；检测成功只说明外部端点可达，不代表所有网站或公司业务都可访问。

macOS 的登录钥匙串密码、系统钥匙串管理员授权与 Wi-Fi 认证密码属于不同授权。不同条目或应用升级后仍可能再次提示，不能保证一次授权后永久免提示。详情见 [签名与钥匙串说明](macos/docs/signing.md)。

正常升级和卸载保留已保存的账号数据。应用自己的凭据与操作系统保存的 Wi-Fi 配置相互独立；卸载程序或删除应用账号不会自动清除系统已知网络。两平台的数据文件不可互相覆盖。

## 使用文档

| 文档 | 内容 |
| --- | --- |
| [Mac 简明指南](macos/Resources/UserGuide.txt) | 添加账号、连接、菜单栏、密码授权和日常管理 |
| [macOS 完整说明](macos/README.md) | 系统配置同步、账号核对、网络状态、构建与验证 |
| [Windows 完整说明](windows/README.md) | 安装、企业认证、多网卡、诊断导出、升级与卸载 |
| [产品功能说明](docs/product-functional-spec.md) | 功能规则、平台差异、数据行为与验收清单 |
| [版本记录](CHANGELOG.md) | 两平台各版本的新增、修复和已知限制 |

## 从源码开发

以下克隆命令使用 SSH，需要先为 GitHub 账号配置本机 SSH 密钥。

```sh
git clone git@github.com:bigywave-gif/wifi-switch.git
cd wifi-switch
```

两平台源码、构建流程与产物相互独立：

```text
wifi-switch/
├── macos/       # Swift 源码、测试、资源和 macOS 打包脚本
├── windows/     # .NET 源码、测试和 Windows 安装器
├── docs/        # 跨平台产品说明
├── CHANGELOG.md # 两平台版本记录入口
└── README.md
```

### macOS 开发

需要 macOS、Apple Command Line Tools 或 Xcode，以及 Python 3。应用声明 Swift 5.9+，测试还依赖工具链自带的 Swift Testing；本次测试使用 Apple Swift 6.3.2 与 Python 3.9.6 通过。

```sh
cd macos
swift build
bash scripts/test.sh
python3 scripts/test-check-release.py
python3 scripts/test-signing.py
```

签名与 DMG 打包步骤见 [macOS 构建说明](macos/README.md#构建)。新打包版本须更新版本号、构建号及变更记录，遵循 [发布规则](macos/docs/release-policy.md)；已发布安装包不覆盖。

### Windows 开发

需要 .NET 10 SDK；生成安装器另需 NSIS 3。以下命令在仓库根目录执行：

```powershell
dotnet run --project windows/tests/WiFiSwitch.Tests -c Release
.\windows\scripts\build.ps1
```

macOS 交叉编译与安装器检查见 [Windows 构建说明](windows/README.md#从源码构建)，独立解包校验还需 7-Zip。自动化测试、交叉编译和安装包校验不替代真实设备上的安装与 Wi-Fi 认证验收。

## 反馈与贡献

欢迎通过 [Issues](https://github.com/bigywave-gif/wifi-switch/issues) 反馈问题或提出功能建议，也可提交 Pull Request。问题报告请包含平台与系统版本、应用版本、复现步骤、预期行为和实际结果；Windows 可附应用导出的诊断 ZIP。

提交前请移除账号、密码及其他私人信息。修改代码时同步补充相应测试与平台版本记录；影响使用方式的变更也应更新文档。

## 许可证

仓库目前尚未添加 `LICENSE` 文件，未声明开源许可证。
