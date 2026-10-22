# Windows 0.1.3 — 连接超时清理及认证诊断

日期：2026-10-20。

## 实机日志结论与边界

用户提供的日志显示连接接口返回 0，随后收到目标配置的 ACM connection_start。
45 秒内未记录 connection_complete 或 connection_attempt_fail，最终由应用等待超时。
日志没有权限拒绝或明确的凭据拒绝，不能据此认定需要管理员权限、密码错误或服务器故障。
旧日志只订阅 ACM，不足以确定停在接入点关联还是安全认证阶段。

## 变更

- 等待超时后查询 Windows 当前连接状态。仅本次已开始、未被其他配置请求替代、
  且当前配置一致并仍处于关联/发现/认证状态时请求断开，等待断开完成后返回。
- 已连接、其他配置或不可读状态不强制断开；消息明确区分停止成功与无法确认。
- 记录 WLAN 配置保存和 EAP 凭据提交的返回码。
- 增加 MSM 阶段/原因码及 ONEX 通知类型；不记录 MAC 地址、SSID、账号、密码或原始认证载荷。
  扩展通知注册失败时回退 ACM，避免额外诊断权限阻止应用启动。
- 对明确凭据拒绝立即停止等待并尝试结束仍在执行的同一请求；不将其他 MSM 阶段视为认证成功。
- 超时提示保留最近阶段、错误码及诊断日志路径。

## 验证

- 42/42 自动测试通过，包括账号状态、持久化、重试、通知隔离、
  超时取消边界、认证拒绝和 MSM 原生结构布局。
- Windows x64 自包含构建、NSIS 打包及独立 7-Zip 解包验证通过。
- 安装包内程序与发布目录一致，README 与源码目录一致。
- 本次写入范围仅 windows/，没有操作 Mac 网络、密码或安装应用。
- Mac 旧基线中现存的 36 个文件哈希一致。基线引用的
  `dist/WiFi-Switch-0.1.29-arm64-internal.dmg.sha256` 当前不存在，因此原 37 文件检查无法完整通过；
  本轮未删除该文件，也未调整基线。
- 无可执行真实 WLAN 验收的 Windows 环境。尚未证明 Example-Enterprise 认证根因已解决；
  仍需目标电脑对照系统原生连接及新版连接日志。

安装包：`../dist/WiFi-Switch-0.1.3-windows-x64-setup.exe`

SHA-256：`780bb726876fd0f79d5c546ff1939fe35c8265ce0b1f17f015f59bf7ee10acd5`

参考：
- [Windows 连接通知及超时查询](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlanregisternotification)
- [MSM 连接阶段数据](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/ns-wlanapi-wlan_msm_notification_data)
- [EAP 用户凭据接口](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlansetprofileeapxmluserdata)
