# ADR-0014：分层诊断事件索引与附件对象存储

- 状态：Superseded by [ADR-0016](0016-segmented-text-diagnostics.md)
- 日期：2026-08-14
- 决策者：MgRead 项目
- 依赖：[ADR-0004](0004-ws-http-transport.md)、
  [ADR-0011](0011-app-owned-versioned-persistence.md)

## 背景

MgRead 既需要低成本的普通日志，也需要未来专用调试器能还原插件调用、HTTP 交换和复杂
内部状态。HTTP 页面或 JSON 响应可能达到数百 KiB；若把它们直接放入日志正文、SQLite
event row 或内存 ring buffer，会造成重复编码、大对象分配、WAL 膨胀、查询卡顿和 UI 内存
随 body 大小线性增长。

现有可观测性规范只允许脱敏小事件并全面禁止 request/response body。该默认仍然合理，
但无法满足用户显式开启的本地深度调试会话。与此同时，Runtime 的 HTTP、插件、内部通信
和平台日志必须继续留在 `mg_read_runtime` 边界内，不能让主应用重新实现 Runtime client、
读取 Runtime 文件或共享打开一个诊断数据库。

## 决策

1. 全局日志采用统一语义、trace 和查询契约，但按执行所有者物理分域：`mg_read` 保存
   Flutter/app 诊断，`mg_read_runtime` 保存插件、HTTP、Runtime Store、通信与平台诊断。
   主应用查看器通过版本化强类型 Facade 联合查询，不共享数据库或路径。
2. 数据分为三层：小型 event envelope、可关联的 span/event、独立 attachment object。
   event row 只含可索引投影和受限小属性；HTTP body、大 JSON、HTML、二进制和复杂对象图
   一律作为附件，通过 `attachmentId` 关联。
3. 每个来源使用独立的诊断 index SQLite 和不可变对象目录。主应用诊断库与
   `app_metadata.sqlite` 物理分离，但其 executor、schema、路径和生命周期仍由
   `lib/core/persistence/` 负责；管理/策略/query port 位于 `lib/core/diagnostics/`。
4. Runtime 诊断是可删除的运行证据，不是应用业务数据权威，不改变 ADR-0011。Runtime
   不打开主应用数据库；主应用也不打开 Runtime 诊断库或对象目录。这是对 ADR-0011
   “业务持久化”边界的窄化澄清，不授权 Runtime 保存书架等主应用业务记录。
5. 普通日志默认 `metadataOnly`。HTTP body 与大动态结构只能在显式、有时限、有磁盘配额、
   有 component/origin allowlist 的捕获会话中保存。Authorization、Cookie、token、凭据和
   已知 secret 字段永不自动进入普通事件；敏感 raw payload 需要单独高风险确认、版本化
   流式加密对象和平台保护的会话密钥，默认不导出、不全文索引，且首个实现包不得默认启用。
6. 动态数据不以任意 `Map<String, dynamic>` 穿透管理层或 Runtime Facade。小属性使用受限
   `DiagnosticValue`；大 JSON 保存为附件；非 JSON 对象图使用版本化 tagged tree，显式表示
   64 位整数、特殊值、循环引用、脱敏、截断和不支持节点。
7. 写入采用 caller 快速判定、有界优先级队列、后台编码/脱敏、单写入者批量事务和流式对象
   spool。诊断分支发生背压时截断/丢弃附件并记录聚合状态，业务 HTTP、Node 事件循环和 UI
   isolate 优先，不能因为日志失败而使业务请求失败。
8. 查询、live tail、附件和结构化树全部使用稳定 cursor/range 分页。查看器只在用户选择
   详情后加载附件；列表不解析 body，不执行 HTML、脚本、SQL、URL 或对象 getter。
9. 日志按时间与字节双配额轮转。对象使用 staging、摘要、原子提交、租约和 mark-and-sweep
   恢复；诊断目录不进入普通业务备份。联合导出由用户显式触发，导出前再次脱敏。
10. Runtime 当前 writer 停止后，Runtime 集成包必须能以只读 offline reader 查询已提交的
    旧会话和启动失败；查看诊断不得要求 Node/Javet ready、启动第二个 VM 或让主应用开库。

完整字段、捕获模式、初始预算、故障恢复、性能基线和交付顺序见
[14 全局日志与诊断数据系统](../14-global-diagnostics-logging.md)。

## 后果

正面：

- 高频事件仍可快速查询，而数百 KiB body 不污染 event row、WAL 或 UI 列表内存。
- HTTP 捕获直接发生在 Runtime 统一网络层，不复制网络栈，也不把 raw transport 暴露给主应用。
- 同一套 viewer 可以用 trace 联合展示 app 与 Runtime，同时保留各自的生命周期和故障域。
- JSON、内部对象图和未来专用 renderer 可独立版本演进，未知格式仍可只读保留。
- 队列、磁盘、解析和 UI 都有明确上限，诊断过载会降级而不是拖垮业务。

代价与风险：

- 两个物理 store 不能做跨库事务或严格全序；联合查询和导出必须维护多个 cursor，并允许
  Runtime 暂时不可用。
- event/object 两阶段提交需要孤儿清理、incomplete 状态和租约，复杂于单个文本文件。
- 原始 HTTP body 本质上可能含敏感信息；即使位于 app-private 目录，也必须使用显式捕获、
  短 retention、导出二次确认和 canary 测试，不能宣称绝对安全。
- 后台 isolate/worker 降低 UI 阻塞，但有消息传递和批处理延迟；必须用真实平台基准调参。

## 被拒绝的方案

- **所有日志写一个长文本/NDJSON 文件**：顺序追加简单，但 trace、筛选、附件生命周期、
  分页和引用完整性差，查看器最终需要重新建立索引。
- **所有内容放一个 SQLite JSON/BLOB 列**：大 body 放大 WAL、复制、VACUUM 和查询成本，
  也容易让列表误加载附件。
- **只用内存 ring buffer**：无法在重启/崩溃后查看，容量仍会被复杂对象和 body 快速耗尽。
- **让主应用截获和保存 Runtime HTTP**：破坏 Runtime Facade 与仓库边界，额外跨桥复制大
  字节，并让 UI 工程承担网络和 Runtime 生命周期。
- **Runtime 写主应用 diagnostics SQLite**：形成双开数据库、双 schema/迁移所有者和锁竞争。
- **默认记录全部 request/response body**：磁盘、性能和隐私成本不可预测，且用户无法知道
  捕获范围。
- **把任意 Map 直接交给 UI**：缺少版本、大小、循环、特殊类型和 renderer 边界，容易产生
  大对象驻留与跨版本数据丢失。
- **先绑定某个通用 logging/telemetry 包**：第三方 API 不能替代本决策中的 Runtime 所有权、
  大附件、动态树、配额、脱敏与查看器契约；依赖只能在实现交付中单独评估。

## 迁移与执行规则

1. 先建立 event/attachment/dynamic value 契约、privacy policy、临时数据根 testkit 和基准；
   不先做 UI。
2. 主应用底层 manager 与 store 只处理 app 自身事件。不得在 `mg_read` 实现 HTTP 拦截、
   Runtime Store、WS/HTTP client 或扫描 Runtime 文件。
3. Runtime HTTP capture、诊断 store 和 Facade query 在 `mg_read_runtime` 单独交付并通过其
   平台、网络、背压和 secret-canary 测试。
4. 查看器在两个 query port 稳定后实现分页联合视图；不能用全量复制 Runtime 日志到主应用
   数据库作为过渡方案。
5. `restrictedRaw` 必须最后单独验收；缺少单独安全决策、流式加密格式、平台凭据存储、
   明确确认、保留/导出测试或性能基准时保持 unsupported。

## 变更条件

只有真实 Android、Windows、macOS 基线证明分域 index + attachment object 是主要瓶颈，
或平台安全/存储政策要求改变时，才能提出替代 ADR。新方案必须保留：单一业务数据权威、
Runtime 边界、流式大对象、有界内存/磁盘、动态格式版本、脱敏、分页查看和崩溃恢复。
