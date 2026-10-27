# 0.1.43 / build 44 验证

日期：2026-10-22。

## 范围

删除 MenuPanel 中渲染 model.notice.text 的三行代码，移除“其他网络”下方的操作结果文字。没有清空 model.notice，也没有改动配置管理面板中的通知、连接状态、列表、操作或其他内容。菜单栏其他控件、连接进度及认证等待提示保留。

## 核对

- 与本次修改前完整 Views.swift 快照逐字比较，唯一差异为 MenuPanel 的上述三行删除；MenuPanel 之前的管理面板等代码及之后的状态视图完全一致。
- 同步版本、构建号、README、CHANGELOG 和产品功能说明，不修改 Windows 源码、配置或制品。
- 未进行真实网络操作、读取密码、替换本机安装或新包原生截图验收。不为三行视图删除新增镜像业务测试。

打包日志：`.build/menu-notice-package.log`。实际制品结果如下。

## 制品结果

- 发布编译及签名通过；DMG 校验、只读挂载、Applications 入口、应用二进制和 README/CHANGELOG 一致性检查全部通过。
- 实际版本 0.1.43（44），arm64，macOS 13+，本地证书内部签名，未公证。发布记录由脚本在校验成功后更新。
- 安装包：`macos/dist/WiFi-Switch-0.1.43-arm64-internal.dmg`。
- SHA-256：`b7b23ef8a815fbff5a6042ceb79ab306d18bb46f274865ff071df9d6e26b6cdd`。
- 未替换本机已安装应用，旧版 DMG 保留。
