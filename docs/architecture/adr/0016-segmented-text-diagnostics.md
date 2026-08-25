# ADR-0016：分段 TXT 日志与显式调试详情捕获

- 状态：Accepted（仅 App；Runtime 部分被 ADR-0024 取代）
- 日期：2026-08-14
- 决策者：MgRead 项目
- 替代：[ADR-0014](0014-tiered-diagnostics-storage.md)
- 依赖：[ADR-0004](0004-ws-http-transport.md)、
  [ADR-0011](0011-app-owned-versioned-persistence.md)

> Runtime 的分段事件、capture、附件和历史查询已被
> [ADR-0024](0024-runtime-transient-simple-logging.md) 删除；下文 Runtime 内容仅保留历史原因。

## 背景

ADR-0014 采用独立 SQLite 事件索引和附件对象目录。进一步确认产品调试方式后，日志的首要
目标调整为：默认只保留人可读、可直接打包检查的关键文本日志；只有用户打开专用调试窗口
或显式开启调试会话时，才允许捕获大型 JSON、HTML 和动态对象详情。未开启调试时，这些详情
不得被复制、序列化、放入内存缓冲区或写盘。

日志不是业务数据权威，也不需要 SQLite 的关系约束和任意查询能力。为日志单独维护数据库、
迁移、WAL、checkpoint 和对象引用回收会增加实现与故障面，也不符合本项目“日志只写 TXT”
的明确产品约束。

## 决策

1. App 与 Runtime 继续使用统一事件/span/capture/query 语义并物理分域；主应用通过版本化
   Runtime Facade 查询 Runtime 日志，不共享路径、文件句柄或数据库。
2. 诊断持久化只使用 UTF-8 `.txt` 文件，不创建日志 SQLite、WAL、二进制索引或数据库。
   小事件使用一行一个稳定 JSON envelope 的 NDJSON 文本分段；扩展名仍为 `.txt`。
3. 默认模式为 `keyOnly`：只启用关键生命周期、用户可见操作、跨边界调用终态、稳定错误、
   性能摘要和日志系统健康事件。默认事件只含低基数元数据、计数、字节和耗时，不含正文、
   HTTP body、大 JSON、HTML、任意对象 dump、凭据、用户输入或绝对路径。
4. 大型 JSON、HTML、小说正文和复杂动态结构的捕获开关与日志级别分离。只有专用调试窗口
   可见或显式、有期限的 capture session 活动，且 component/origin/payload kind 命中
   allowlist 时，调用方才可构造或复制详情。
5. 调试详情先进入按字节计费的有界内存 spool/ring。单条、单会话和全局内存均有硬上限；
   队列满时立即截断或丢弃诊断副本，业务消费者继续运行。不得用无界字符串拼接完整 body。
6. 调试策略可选择 `memoryOnly` 或 `persistToText`。只有 `persistToText` 会把已脱敏详情异步
   写入独立 `.txt` 文件；写完即释放对应内存。详情不内联到事件分段，事件只保存 opaque
   `attachmentId`、类型、大小、摘要和 capture state。
7. `Authorization`、`Cookie`、`Set-Cookie`、token、credential、验证码及已知 secret 字段
   永不自动捕获。`restrictedRaw` 继续保持 unsupported，除非后续安全 ADR 单独接受加密格式、
   密钥生命周期、确认流程、导出与跨平台测试。
8. 每个 TXT 分段有字节上限；达到阈值或跨运行边界即轮转。保留策略同时限制时间、总字节、
   分段数和详情字节，优先删除最旧的已关闭分段及其详情。
9. 查询使用 opaque cursor，内部只包含来源、分段 ID 和字节偏移。读取按行/范围分页，在后台
   isolate 或 Runtime 调度任务中完成；查看器不得整文件读取、整会话解码或常驻全部事件。
10. 每批事件只做一次追加写；只有换段、显式 flush、后台/退出或错误级别门禁才请求 flush。
    日志写入、轮转、恢复或磁盘满失败均不得改变业务结果。
11. 崩溃恢复只接受以换行结束的完整记录；尾部半行在下次打开时截断。详情采用
    `staging/*.partial.txt -> details/*.txt` 同卷原子重命名，残留 staging 在启动时清理。
12. TXT 是存储格式，不是自由文本协议。事件名、schemaVersion、字段预算、trace/span 关系、
    恰好一个终态、脱敏、分页和未来版本只读规则继续由强类型管理层保证。

建议初始预算：常规事件 3 天或 32 MiB；单事件分段 4 MiB；调试详情内存队列 8 MiB；单详情
8 MiB；单会话持久化详情 128 MiB；单页最多 200 条。数值可由平台基准收紧，但不得改为无界。

## 后果

正面：

- 默认路径没有大型内容的复制、JSON 编码、内存驻留或磁盘写入，小说正文不会撑爆日志。
- 文本分段易于人工检查、故障恢复和用户显式导出，不需要日志数据库迁移与 WAL 维护。
- 调试窗口仍可按需查看 HTTP/JSON/HTML，并通过有界 spool 和独立详情文件隔离大负载。
- App 与 Runtime 保持各自所有权；TXT 不成为绕过 Runtime Facade 的共享协议。

代价与风险：

- 复杂筛选需要扫描有限保留分段，查询能力弱于 SQLite；必须依靠严格配额、稀疏内存目录和
  cursor 分页控制成本。
- NDJSON 行仍是机器结构，不承诺用户用普通文本编辑器修改后可继续作为合法日志读取。
- 调试详情可能包含内容数据，即使经过脱敏也只能短期保留、默认不导出。
- 当前进程内的稀疏目录在重启后需要流式重建；打开日志的首个查询可能有一次性后台开销。

## 被拒绝的方案

- **继续使用日志 SQLite**：违背 TXT-only 约束，并引入 migration/WAL/checkpoint 故障面。
- **所有级别写同一个无限 TXT**：无法限制磁盘，崩溃恢复和分页成本随历史无限增长。
- **默认把 body 写 TXT**：扩展名不会降低正文、隐私、I/O 与磁盘膨胀风险。
- **默认把完整 body 放内存 ring**：未调试时仍有复制和峰值内存成本，大页面会挤掉关键事件。
- **打开查看器时再从业务缓存倒推详情**：改变原业务所有权，且无法保证 HTTP 原始时序和内容。
- **为加速查看器建立持久化二进制索引**：形成第二存储协议；首版以有界分段和内存稀疏目录
  满足查询，真实基准证明必要后再提替代 ADR。

## 迁移与验收

1. 停止创建新的 diagnostics SQLite/WAL/object 文件；旧诊断库只作为可删除遗留数据，不自动
   导入 TXT，避免后台迁移读取潜在正文。
2. App 与 Runtime 的现有 manager/query API 保持强类型，store 改为分段 TXT 实现。
3. 测试必须断言默认模式下 secret canary、HTML、JSON 和小说正文未出现在内存 capture、事件
   TXT、详情 TXT、preview 和控制台；同时断言禁用时不调用详情 supplier/getter/serializer。
4. 调试模式测试覆盖 memoryOnly/persistToText、allowlist、超限截断、背压、磁盘满、半行恢复、
   原子提交、轮转、分页和未来 schema 只读。
5. 性能报告分别测 disabled、默认 keyOnly 和显式详情捕获，至少报告 p50/p95/p99、吞吐、分配、
   峰值内存、队列高水位、drop、事件 TXT 与详情 TXT 增长。
