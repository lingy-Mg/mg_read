# MgRead 架构入口

状态：权威架构路由。复核日期：2026-08-20。

本目录定义产品范围、系统边界、公开协议和已接受决策。普通开发任务不需要顺序阅读全部专题；
先从 [开发文档路由](../development/README.md)选择当前任务所需文件。

## 当前核心结论

1. 每个应用进程只有一个 Node Runtime/VM；插件共享事件循环，不支持 Worker、子进程、第二 VM
   或原生 Addon。
2. `packages/mg_read_runtime` 独立拥有 Node/Javet 平台承载、Supervisor、内部 WS/HTTP、插件
   安装执行和版本化 Flutter Facade；主应用看不到端口、bootId、wire DTO 或 Runtime 路径。
3. `mg_read` 的 `AppPersistence` 是应用业务数据权威。metadata、Content Library 正文对象和
   受控文件对象属于主应用；Runtime 不打开主应用 SQLite，也不获得数据库/文件绝对路径。
4. Runtime 可拥有插件安装树、插件私有 data/cache、Cookie、临时运行状态与诊断，但不得成为
   书架、目录、阅读进度、书签等主应用业务权威。
5. 插件是可信的标准 Node.js 24 项目。installed 使用不可变冷激活版本目录；Windows Debug 的
   development 项目直接读取工作区并在变更后有序重启唯一 Runtime；可信不等于安全沙箱。
6. WS 控制面和 loopback HTTP 数据面是 Runtime 内部实现；大二进制/超限文本不进入
   JSON/Base64，主应用只消费强类型 Facade。
7. 阅读器插件不联网、不内置业务数据库；主应用 adapter 提供内容和状态，进度/书签保留语义
   锚点。
8. App 诊断只持久化为有界 UTF-8 分段 TXT；Runtime 只保留瞬时简单日志，不写事件文件。
9. installed 更新在下次 Runtime 冷激活；仅 Windows Debug development 可在回收旧 VM 后重启
   唯一 Runtime，不在同一 VM 内热换模块。
10. Android、Windows、macOS 分别验收。Windows 源码证据不能证明 Android/Javet、macOS 或最终
    发布包。

## 决策优先级

冲突时采用：用户当前明确要求/Accepted ADR → 根 `AGENTS.md` → 当前专题 → 实现说明/证据。
完整状态和替代关系见 [ADR 索引](adr/README.md)。ADR-0011 与 ADR-0100 已取代旧文档中
“Runtime Store 拥有主应用书架/目录/进度/正文”的结论。

## 专题导航

| 专题 | 状态 | 只在何时读取 |
| --- | --- | --- |
| [01 产品范围与路线图](01-product-roadmap.md) | 规划 | 划分交付包、首版/延期边界 |
| [02 系统分层](02-system-architecture.md) | 权威专题 | 改主应用、Runtime、reader 依赖方向 |
| [03 Runtime 生命周期](03-runtime-lifecycle.md) | 权威专题 | 改 Supervisor、Javet、desktop 启停/ready |
| [04 标准插件与安装](04-plugin-sdk-packaging-registry.md) | 权威专题 | 改 package/lock、安装、冷激活、registry |
| [05 内部 WS/HTTP](05-transport-protocol.md) | 权威协议；数据所有权受 ADR-0011 覆盖 | 改 Runtime 内部 wire、资源、Range、取消 |
| [07 并发与性能](07-concurrency-performance.md) | 开发规范；旧 Store 段落仅供历史 | 改调度、背压、性能关键路径 |
| [08 可靠性、可观测性与测试](08-reliability-observability-testing.md) | 开发规范；旧 Store 段落仅供历史 | 故障、测试矩阵、证据边界 |
| [09 平台发布与未来能力](09-platform-release-future-capabilities.md) | 规划/发布规范 | 平台包、WebView、媒体、商店决策 |
| [10 主应用持久化](10-app-persistence-design.md) | 权威专题 | metadata persistence |
| [11 主应用持久化验收](11-app-persistence-acceptance.md) | 验收规范 | persistence 测试与平台证据 |
| [12 全局设置](12-global-settings.md) | 实现规范 | settings manager/adapter |
| [14 日志与诊断边界](14-global-diagnostics-logging.md) | 权威专题 | App 持久诊断、Runtime 瞬时日志、隐私与查看方式 |
| [15 插件内容 API v1](15-plugin-content-contract.md) | 权威契约 | discover/search/detail/chapters/content |
| [20 Content Library](20-content-library.md) | 权威专题 | 书架、目录、正文、漫画文件对象 |
| [21 前台局域网同步](21-lan-sync.md) | 权威专题 | 前台 Windows/Android 点对点、二维码与开发书源同步边界 |
| [ADR 索引](adr/README.md) | 权威 | 改决策或调查冲突 |

## 历史专题：默认不读

- [06 Runtime 数据、缓存与下载](06-domain-data-cache-downloads.md)
- [10 Runtime Store 设计](10-runtime-store-persistence.md)
- [11 Runtime Store 验收](11-runtime-store-acceptance.md)

它们保存 ADR-0008/0009/0010 时期的设计推理和测试思想，但主应用业务数据所有权已被
ADR-0011/ADR-0100 改写。未新增替代 ADR 前，不得从这些历史文件恢复 Runtime 业务权威。

## 首版与证据边界

首版目标仍包括插件管理、发现/搜索/详情/目录、书架、小说/漫画阅读、语义进度/书签、缓存/
下载和故障恢复；账号、云同步、WebView 登录、音视频、沙箱和商店分发延期。目标不等于当前
实现，当前 tracked evidence 和优先缺口统一见 [规划快照](../planning/README.md)。
