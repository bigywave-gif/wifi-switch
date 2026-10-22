# Windows 0.1.0 内部验收构建

构建日期：2026-10-20。目标：Windows 10/11，Intel/AMD x64。

## 已验证

- 最终 Release 构建成功，Windows x64 自包含程序发布成功。
- 29/29 自动测试通过，覆盖账号持久化、凭据与元数据回滚、认证失败立即停止、网络错误三次限制、重启及休眠状态保留、当前账号凭据更新重连、WLAN XML 和 x64 原生结构布局。
- NSIS EXE 安装包生成成功。独立 7-Zip 解包后，应用程序及 README 与发布目录逐字节一致，卸载程序具有有效 PE 头。
- 应用程序 PE 架构为 AMD64；安装器使用标准 NSIS x86 引导程序，并限制在 x64 Windows 上安装。
- 安装负载仅包含程序和使用说明，不包含任何用户账号数据、密码或 Mac 配置。
- macOS 迁移基线校验通过：37 个原有源码、脚本、文档及安装包文件内容保持一致。迁移仅整理项目目录。

安装包：`../dist/WiFi-Switch-0.1.0-windows-x64-setup.exe`

SHA-256：
`d76002ff67ddc5392dbdc587f06698d82ca454ecb7d94cb0400cc18fb91123e0`

可复核的机器输出：

- `../artifacts/core-tests.log`
- `../artifacts/package-verification.json`
- `macos-preservation.json`

## 尚未实机验证

当前没有可用 Windows 测试环境。上述结果不代表以下项目已通过：

- Windows 安装、开始菜单、升级、卸载及真实界面显示。
- Windows 凭据管理器读写；可在 Windows 上运行 `scripts/smoke-test.ps1` 进行隔离自检。
- 企业 Wi-Fi、普通 Wi-Fi、热点的真实认证及服务器证书交互。
- 断网、认证拒绝、休眠、唤醒、重启、多网卡与企业策略下的实际行为。

安装包未进行 Authenticode 签名。本版本应作为内部待验收版本使用。

## 同日修订

恢复主窗口账号总数，多网卡选择改为独立区域，仅多网卡时展示。按 WLAN 操作区分权限错误提示，避免统一归因于位置权限。未增加跨账号用户名限制。最终重新构建，29/29 测试及独立解包检查通过。

安装目录修订：新增目录选择页，首次默认使用当前用户应用目录，升级默认读取原 InstallLocation。只重建安装包及 README，应用二进制未改动；NSIS 构建确认 4 个安装页面，独立解包与 Mac 37 文件校验通过。目录选择的 Windows 实机操作仍待验证。
