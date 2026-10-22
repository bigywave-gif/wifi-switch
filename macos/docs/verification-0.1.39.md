# 0.1.39 / build 40 验证

2026-10-22，仅 Mac 改动，Windows、用户数据及实际网络连接未修改。未替换已安装应用。

查看 Wi-Fi 信息入口只对当前连接正常的账号与网络组合开放；即使 SSID 相同，其他账号也不展示。点击时再次核对，信息窗口随连接资格失效关闭；异步读取完成后再次核对账号及读取器确认标记，避免迟到结果展示旧信息。

Swift Testing：165 tests / 13 suites 全部通过。新增连接切换、同 SSID 其他账号、其他网络及断开后的访问限制测试，并断言读取器在非当前网络、权限不足、连接变化时不返回确认标记。

原生 UI 使用生产 ContentView 和内存模拟网络：未连接的“测试环境”菜单只有重新连接、移除 Wi-Fi；已连接的“日常办公”菜单保留查看信息，实际打开并关闭信息窗口。未对真实网络执行断开来验收自动关闭；连接失效条件由模拟测试覆盖。

发布脚本完成签名、DMG、挂载内容、README 一致性与 Applications 入口验证。0.1.39 (40)，arm64，macOS 13+，内部签名未公证。

产物：`macos/dist/WiFi-Switch-0.1.39-arm64-internal.dmg`

SHA-256：`0f2b854c35e224487e0f3805ff21ce5755eea5db6e17b791133017b6bbd35d52`

日志：`macos/.build/information-access/tests.log`、`package-0.1.39.log`。
