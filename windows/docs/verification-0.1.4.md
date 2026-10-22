# Windows 0.1.4 — 完整连接过程诊断

日期：2026-10-20。

## 实现

- Controller 与 NativeWiFi 共用一次连接的诊断会话，在读取凭据前开始，
  最终验证及账号状态保存完成后才记录成功；凭据读取失败和持久化失败也留下记录。
- 记录阶段开始/结束、带时区时间、累计毫秒耗时、独立会话编号、应用版本、
  系统/运行时版本、进程架构以及是否使用管理员令牌，不记录 Windows 用户名。
- 覆盖扫描、配置权限检查、旧会话结束、配置写入、EAP 凭据提交、
  账号标记、关联/认证通知、IP 验证、自动加入和回退恢复。
- 等待结果期间每 5 秒查询并记录系统状态。保存 API 返回码、
  WLAN 原因码、MSM 阶段、ONEX 状态及可读的 EAP 错误类别。
- ONEX 仅解析固定数值字段及经过范围检查的 EAP 错误值。
  不读取身份参数、原始认证载荷、根因描述字符串或凭据数据。
- 扩展通知注册失败，依次回退 ACM + ONEX、ACM 并记录错误。
- 后台每秒将新增记录保存到最近日志和历史日志；最多保留 10 次会话，
  单会话最多保留尾部 1500 行并注明截断数量。日志 I/O 失败不改变连接结果。
- 主窗口底部、异常详情和托盘齿轮菜单提供导出诊断 ZIP。
  可在连接进行中导出，写盘失败时也可导出当前内存记录。
  ZIP 仅包含应用日志和说明，不包含账号 JSON、SSID、用户名、密码、IP/MAC 或完整 XML。
- 既有认证配置、密码提交方式及连接成功判断保持原有逻辑。

## 验证

- 48/48 自动测试通过，包括旧连接/重试/持久化回归。
- 新增验证：凭据读取之前的失败记录、错误码保留、异常消息敏感内容排除、
  未结束会话的后台落盘、日志轮换和 ZIP 内容、日志写入失败下连接结果不变、
  部分写入失败时历史/导出数量上限、ONEX 截断及越界数据处理。
- Windows x64 Release 自包含构建及 NSIS 构建成功。
- 独立 7-Zip 解包验证通过，程序与 README 与发布目录逐字节一致。
- 仅 windows/ 有实现及制品写入，没有操作 Mac 网络、安装应用、密码或配置。
  Mac 基线现存 36 个文件哈希一致；旧基线引用的
  `dist/WiFi-Switch-0.1.29-arm64-internal.dmg.sha256` 仍不存在，未修改该基线。
- 尚无 Windows 实机运行验收，导出入口的真实桌面交互和 Example-Enterprise 认证需要目标机器验证。
  本版本增强诊断，不代表已定位或解决 Example-Enterprise 认证根因。
  系统不返回具体原因时，仍可能需要 Windows 事件或认证服务器日志。

安装包：`../dist/WiFi-Switch-0.1.4-windows-x64-setup.exe`

SHA-256：`a80955815bee1ba5a56d5675c8402cf19a7a5182874a4a7188cfef16e713c588`

## 接口依据

- [ONEX_RESULT_UPDATE_DATA](https://learn.microsoft.com/en-us/windows/win32/api/dot1x/ns-dot1x-onex_result_update_data)
- [ONEX_STATUS](https://learn.microsoft.com/en-us/windows/win32/api/dot1x/ns-dot1x-onex_status)
- [ONEX_EAP_ERROR](https://learn.microsoft.com/en-us/windows/win32/api/dot1x/ns-dot1x-onex_eap_error)
- [ONEX_AUTH_STATUS](https://learn.microsoft.com/en-us/windows/win32/api/dot1x/ne-dot1x-onex_auth_status)
- [ONEX_VARIABLE_BLOB](https://learn.microsoft.com/en-us/windows/win32/api/dot1x/ns-dot1x-onex_variable_blob)
