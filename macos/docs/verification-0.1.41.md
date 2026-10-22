# 0.1.41 / build 42 验证

2026-10-22。配置管理 AccountCard 的 Wi-Fi 图标颜色绑定原有 accountConnectionStatus(for:on:)：normal 为蓝色，其余为 secondary 灰色。原有连接、账号标记和菜单栏逻辑未修改。

发布编译及独立模拟预览编译通过。尝试原生截图验收时，工具报告 Mac 已锁屏且自动解锁失败，因此本版没有完成视觉或模拟点击切换验收；不将先前版本的截图冒充本版结果。该改动只增加颜色条件，未新增镜像实现的测试，也未重复完整测试套件。

发布脚本完成签名、DMG、只读挂载后的二进制/说明一致性及 Applications 入口验证。实际版本 0.1.41 (42)，arm64，macOS 13+，内部本地签名未公证。未替换已安装应用，未改动 Windows、用户数据或实际网络。

产物：`macos/dist/WiFi-Switch-0.1.41-arm64-internal.dmg`

SHA-256：`a0c34e9de64ebd2849fed20b287f33fe2ed4f6435929e104748fc198a164fd5c`

日志：`macos/.build/connected-icon/package-0.1.41.log`、`preview.log`。
