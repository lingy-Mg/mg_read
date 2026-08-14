# 12 全局设置内存门面与异步持久化

全局设置位于 `lib/core/settings/`。它是主应用权威 persistence 之上的强类型门面，不是
`features/settings` 页面实现，也不是 Runtime Store。页面和 feature 只持有注册过的
`SettingKey<T>` 与 `AppSettingsManager`，看不到 SQLite、JSON envelope、revision、数据库路径
或 Drift。

## 快照与写入语义

- `get<T>()` 只查不可变的分组内存快照；初始化后不触发 SQL、JSON、文件或跨 isolate 调用。
- `set/reset/resetGroup/transaction` 在 owner isolate 内同步校验并立即替换受影响 document group；
  方法返回前，新值与同步 broadcast 变更通知已经可见。返回的 `Future` 只表示内存事务已接受，
  持久性由 `flush()`/状态投影明确表达。
- 显式 `null` 通过 `containsKey` 与字段缺失区分。缺失读取默认值；存在且为 null 的 nullable key
  返回 null。
- transaction 只复制、编码和发布被修改的 document group；未知字段保留，默认值只在内存合并，
  首次启动不会主动写库。
- 非标量 `SettingKey<T>` 必须在 `SettingCodec<T>` 注册保持 `T` 运行时类型的冻结器。默认值在
  registry 构建时只规范化一次，Map/List 设置值在进入快照前防御复制并变为不可修改，调用方不能
  通过保留集合引用绕过 generation、配额或变更通知。

每个已注册 document group 使用独立、可配置的 trailing debounce，生产默认 300ms。同一组在
窗口内的高频变化只提交最终文档；不同组不会互相延长窗口。`flush()`、应用进入 inactive/
paused/hidden/detached、`close()` 都取消等待并强制提交。关闭使用有界 deadline，不能因坏磁盘
或卡住的 Store 无限阻塞。

## 单一并发入口与 CAS

`AppSettingsManager` 所在 isolate 是唯一状态所有者。UI/application 直接调用同一个同步内存入口；
后台 isolate 只能获得可传递的 `SendPort`，通过 `BackgroundSettingsClient` 发送稳定 key ID 与
JSON 值。owner port 按到达顺序验证并应用完整命令事务，不允许后台 isolate 创建第二个 manager
或共享可变快照。

落盘使用加载时的 revision 做 CAS。若数据库已被其他受控 writer 更新，manager 单次批量重载
冲突组，以最新文档为 base，只重放仍待提交的已注册 key patch：本地待提交 key 胜出，未修改的
已知字段和未知字段采用数据库新值。冲突重试有界；普通写失败不回滚会话内存，而是保留 dirty、
进入 degraded、按有界退避自动重试。成功后清除 transient degraded。
若冲突重载发现 future-version、损坏或已知 key 无法解码，该组立即切换安全默认值、清除无法安全
合并的本地 patch 并变为 read-only，不会永久保持 dirty 或用旧进程覆盖受损/未来格式。

## 状态与故障边界

生命周期状态固定为 `loading → ready|degraded|failed → closing → closed`。`SettingsStatus` 同时投影
每组的 `dirty/persisted/degraded/readOnly/inFlight`、revision、内存 generation、已持久化
generation、重试次数和稳定错误码，不保留原始异常、SQL、路径或文档值。

启动按注册的 document IDs 发出一条 `IN (...)` SQLite 查询，不扫描整库。future-version、损坏
JSON 或已注册 key 解码失败只让对应组使用安全默认值并变为 degraded/read-only，旧程序不会自动
覆盖原数据。其他组仍可 ready 和写入。

设置 JSON 的硬上限为 64 KiB UTF-8、8 层、256 keys、1024 nodes、单数组 256 项和单字符串
8192 字符；凭据、Cookie、Authorization、token/password/secret 类 key 被拒绝。该配额本身也
阻止正文、HTTP body、二进制/Base64 或大型动态对象进入设置。通用 persistence 另有更高但仍
有界的元数据配额。JSON decode/normalize/encode 在受控 worker isolate 执行，SQL 继续由 Drift
后台 native executor 执行；批量写最多 128 个文档且逐项调度 codec worker，避免一次请求无界
扩散 isolate。

## 启动组合与平台边界

`bootstrapMgReadApp()` 先 await manager `initialize()`，再以 Riverpod override 显式注入并挂载
应用；初始化失败仍注入 `failed` manager，让状态可观察，而不是创建静态 singleton。生产数据根
由 Flutter 官方 `path_provider 2.1.6`（BSD-3-Clause）提供 Application Support 目录。官方包
声明 Android、Windows、macOS 均支持该目录；它会引入相应平台插件注册与少量原生包体，实际
Android/macOS 包体和运行仍需各平台验收。

本设置核心交付不修改现有深色模式 UI 或其测试；`AppSettingKeys.themeMode` 的消费由独立 UI
交付维护。本交付不实现 reader/download 设置、Runtime、Cookie/Secret Store 或正文。未来
`features/settings` 只负责 UI/application 意图，必须调用本门面。统一诊断日志 manager 尚未
落地，因此当前只提供安全状态流，不使用 `print`/`debugPrint` 代替；结构化 settings
event/span 仍受全局日志门禁约束。

## 验收入口

- Fake Store：`test/core/settings/app_settings_manager_test.dart`
- 后台 isolate：`test/core/settings/background_settings_isolate_test.dart`
- 真实 SQLite：`test/core/settings/persistent_settings_store_test.dart`
- 组合根与生命周期：`test/app/app_settings_bootstrap_test.dart`

这些测试只使用临时数据根和合成小 JSON，不依赖 Widget 页面、Node/Javet、网络、真实正文、
凭据或用户目录。Windows 主机自动化不能替代 Android 真机或 macOS 实际运行验收。
