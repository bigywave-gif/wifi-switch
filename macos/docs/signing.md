# 打包身份与钥匙串授权

## 内部交付流程

默认按内部使用打包，无需加入 Apple Developer Program。开发者使用固定本地证书签名；用户将应用复制到“应用程序”，按 macOS 提示允许首次打开。安装用户无需创建证书，也不接收签名私钥。此包未经过 Apple 公证。

Wi-Fi 密码及访问授权分别保存在每位使用者自己的 Mac 登录钥匙串中。“始终允许”与首次打开应用是两项独立授权。本地自签名不能保证更新后沿用已有授权，以下是实际验证边界。

## 2026-10-19 的真实验证结果

之前的临时签名随构建改变 cdhash。本轮进一步生成了固定本地证书，使用生产 KeychainVault.swift 编译两个不同版本的独立测试应用，得到：

- 两版 designated requirement 相同，代码哈希不同，真实 codesign 校验通过。
- 新建两个临时密码、同版本重复读取、进程退出后重开读取成功。
- **改用第二个版本读取失败，返回 -25293；在同一安装路径替换更新也失败。** 因此固定本地自签名没有满足跨版本免授权要求。
- 测试关闭了其进程内的钥匙串交互，授权缺失直接失败，不会靠用户点击窗口掩盖失败。临时密码条目已清理，没有查询真实 Wi-Fi 密码。

原因不仅是 designated requirement。Apple Security 开源实现还按 partition 区分调用者：符合 Apple 开发者签名要求的程序使用团队身份，其他已签名程序回退为该版本的代码哈希。本地自签名缺少 Apple 验证的团队身份，因此仅固定证书不能保证更新后继续无提示读取。

参考：[Apple Security 的 partitionIdForProcess](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)、[Developer ID 分发](https://developer.apple.com/developer-id/)、[钥匙串“始终允许”](https://support.apple.com/guide/keychain-access/if-youre-asked-for-access-to-your-keychain-kyca1243/mac)。

这些结果修正了此前“换成固定自签名即可完成修复”的假设。现阶段不能宣称跨版本问题已修复，也未验证旧真实密码条目重新授权后的完整流程。

## 内部构建：由打包端配置

本机已有 WiFi Switch Local Signing，指纹 BD803007399E55FEBF79714C88F03955B4A8CA92。其私钥访问限定到 codesign，未调整系统证书信任。临时加密密钥文件在导入后已删除。配置脚本会复用现有身份，重复证书或私钥丢失时停止，不自动换新身份。

```sh
# 仅打包电脑首次需要；已存在时复用
python3 scripts/setup-local-signing.py
bash scripts/package-internal.sh
```

默认签名模式为 internal，默认身份为 WiFi Switch Local Signing。可用 WIFI_SWITCH_SIGNING_IDENTITY 指定证书，独立钥匙串可通过 WIFI_SWITCH_SIGNING_KEYCHAIN 指定。构建校验签名及旧版 designated requirement，不符合时保留旧产物；这些检查不代表跨版本钥匙串免授权已经通过。

应用输出到 dist/WiFi Switch.app。安装包另含 README.md、可直接用文本编辑器阅读的 README.txt、相关文档及 Applications 快捷入口。没有签名私钥、构建电脑的账号配置或真实密码。WIFI_SWITCH_LOCAL_BUILD=1 可将开发测试应用输出到 dist/local。

## 可选的 Developer ID 构建

这不是内部使用的前置条件。如日后采用 Apple 签发的 Developer ID Application 证书，可显式运行：

```sh
WIFI_SWITCH_SIGNING_MODE=developer-id WIFI_SWITCH_SIGNING_IDENTITY='Developer ID Application 证书名称或指纹' bash scripts/build-app.sh
```

此模式使用 Hardened Runtime、签名时间戳并验证 Apple 证书链与 Developer ID 扩展。仍需另行完成公证；当前没有公证凭据，不能称为已公证。若从本地签名换用新身份，旧版身份保护检查会阻止直接覆盖，需单独规划身份迁移和用户重新授权。

## 可复现检查

```sh
# 模拟构建保护检查，不访问钥匙串
python3 scripts/test-signing.py

# 使用真实签名及钥匙串，限定临时条目，结束清理
# 默认本地证书用于复现跨版本失败；配置 Developer ID 后可用同一测试重新验收
WIFI_SWITCH_SIGNING_IDENTITY='用于验证的证书名称或指纹' python3 scripts/verify-keychain-continuity.py
```

真实检查报告写入 .build/keychain-continuity-report.json，明确记录通过与失败，失败返回非零状态。它不验证旧账号迁移、用户选择“始终允许”或另一台 Mac 的安装体验。这些仍需在实际安装环境由用户完成。

截图中的授权密码是登录钥匙串密码，通常与 Mac 登录密码相同。两个 Wi-Fi 账号是独立密码条目，可能分别要求授权。不要将密码发到聊天中，也不要将条目开放给所有应用。钥匙串被锁定、权限重置或发行身份改变时仍可能需要用户处理。
