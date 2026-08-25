# ADR-0021：Windows/Android 前台局域网同步

状态：Accepted（2026-08-25）。本 ADR 只定义前台、点对点局域网同步；实现与验证证据见
[局域网同步专题](../21-lan-sync.md)。

二维码连接和 Windows Debug development 书源的显式同步由后续
[ADR-0022](0022-lan-sync-qr-development-source-transfer.md) 细化。

## 决策

- Windows 与 Android 任一端都可以发起发送；两端都必须处于前台。无云端、无后台同步、无
  账号或服务器中转。
- 发现使用 UDP 广播/发现报文；发现失败时允许用户手动输入 IPv4。配对使用前台 TCP，且
  双方都显示并比较同一个六位数字码；码不一致即中止。它是可信私有局域网明文传输，不声称
  加密或跨不可信网络安全。
- 协议使用版本化、强类型、有限长度的握手、控制帧、manifest 与数据帧。单次会话最长 10 分钟，
  握手超时 30 秒；控制帧 64 KiB、manifest 1 MiB、普通 chunk 256 KiB、插件归档 32 MiB，
  单批最多 32 项或 512 MiB（先达到者为准）。
- Runtime 拥有的插件归档只能由 Runtime 通过 path-free、有界流发送；主应用不得接收 Runtime
  路径或扫描 Runtime 数据根。主应用发送/接收的是由 AppPersistence/Content Library 产生的
  书架与阅读进度快照。
- 同步范围仅包括书架与进度快照，以及缺失插件的安装或插件版本升级提示/传输。不得同步离线
  正文、设置、书签或删除操作；插件依赖可按标准 npm 规则正常下载，不要求随同步离线携带。
- 每本书冲突由用户逐本选择智能合并、采用发送端或保留本机；智能合并采用发送端展示信息并
  保留更新时间较新的阅读进度，不得静默覆盖。快照提交仍遵守
  [ADR-0011](0011-app-owned-versioned-persistence.md) 与 [ADR-0100](0100-app-owned-content-library.md)。

## 边界与平台注记

同步入口属于主应用前台能力，Runtime 只提供其拥有的插件归档流能力与稳定错误结果，不获得
主应用数据库、文件路径、Cookie 或平台通道。Android 当前 targetSdk 36 使用 `INTERNET`；
targetSdk 37 的本地网络权限要求属于未来兼容事项，不在本 ADR 预先宣称已处理。

## 诊断与隐私

同步必须接入 [ADR-0016](0016-segmented-text-diagnostics.md) 的 owner span。诊断只保留阶段、
计数、大小、耗时、稳定结果/错误码和脱敏版本信息；不得记录 IP、六位码、token、书名、作者、
remote ID、归档字节、路径或原始错误。诊断失败不得改变同步结果。

## 不在本决策中的事项

本 ADR 不定义加密、云同步、后台调度、删除传播、离线内容迁移、设置/书签迁移、通用冲突合并、
远程发现协议的公共服务器或 npm 离线依赖包。
