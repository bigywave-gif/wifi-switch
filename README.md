# WiFi Switch

两个平台独立开发、构建与交付：

完整版本记录见 [CHANGELOG.md](CHANGELOG.md)，分别列出每版新增、修复、调整与验证限制。

完整功能、操作规则、Mac/Windows 差异、数据与卸载行为及验收清单见 [产品功能说明](docs/product-functional-spec.md)。功能发生变化时须同步维护该文档。

| 平台 | 项目 | 安装包 |
| --- | --- | --- |
| macOS | [macos/README.md](macos/README.md) | `macos/dist/` |
| Windows | [windows/README.md](windows/README.md) | `windows/dist/` |

macOS 原项目整体移入 `macos/`，源码、测试、资源、脚本与已有安装包内容保持一致。
从源码执行原来的命令时先进入 `macos/`。目录整理不操作 `/Applications`、钥匙串、
系统应用注册信息或 `~/Library/Application Support/WiFiSwitch/`。

Windows 项目不引用、修改或在构建时运行 macOS 项目。不要把两平台的账号文件互相覆盖。
