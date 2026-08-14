# 11 Runtime Store 独立验收规范

## 状态

本文定义 Runtime Store 实现阶段必须建设的独立验收套件。当前仍是文档阶段，没有 Store
实现、测试 runner、SQLite 依赖或测试结果；本文通过不等于任何测试已经执行。

验收代码、fixture、故障注入 runner 和报告全部属于 `mg_read_runtime`。`mg_read` 只保留
本规范和最终消费 Runtime Facade 的 UI 测试，不创建数据库、迁移或文件恢复测试替身。

## 验收目标

Store 验收必须单独证明：

- 作用域化 JSON 的校验、未知字段保留、版本升级和未来版本保护正确。
- 事务、revision、幂等、批量写和并发关闭不会丢失已确认数据。
- 元数据、正文库和文件对象在每个崩溃切点都能恢复为可解释状态。
- 正文统一对象表在代表性目录规模下可工作，不依赖按书分表/分库或每章文件。
- 清缓存、清正文、插件卸载、备份和恢复不会误删书架、进度、书签或显式下载。
- 日志、报告和默认导出不泄露正文、远端 ID、Cookie、令牌、绝对路径或数据库行。
- 同一套 fixture 和不变量在 Android、Windows、macOS 上一致。

## 完全独立的硬约束

独立验收进程不得：

- 导入或启动 `mg_read`、任何页面、路由、Widget 或 `novel_reader_ui`。
- 启动 Node/Javet、WS/HTTP、插件、真实书源、本地代理或外部网络。
- 读取用户真实数据根、现有数据库、浏览器 Cookie、凭据或真实小说正文。
- 依赖测试执行顺序、系统当前时间、随机未记录端口或开发机残留状态。
- 通过 UI fake、内存 Repository 或 mock SQLite 宣称持久化已验收。
- 直接改表来完成黑盒用例；只有关闭 Store 后的只读结构/泄漏检查可以使用专用 inspector。

每个用例创建新的临时数据根，使用确定性时钟、记录 seed 的伪随机生成器和合成数据。测试
结束必须关闭 Store、确认锁释放并删除自己的临时根；失败时可按测试配置保留脱敏副本，
绝不复制到用户数据目录。

生产 Facade 仍没有 path/database 注入。独立测试通过 Runtime 仓库内、仅测试可见的
`runtime_store_testkit` 创建 Store，并注入临时根、时钟和故障点；testkit 不得进入发布 API。

## 被测端口

验收以稳定 Store 端口而不是 SQL 为中心。实现语言可在探针后确定，但必须提供等价操作：

```text
open / close / reopen
readRecord / queryRecords
createRecord / compareAndSwap / deleteRecord
runBatch / readOperationReceipt
putContent / openContent / detachContent
putFileObject / openFileObject / detachFileObject
backup / restore / checkIntegrity
runRecovery / runMaintenance
```

所有结果使用稳定错误码和 revision。测试不以表行数或内部异常字符串替代领域结果；结构
检查只验证 envelope、索引、明文泄漏和禁止项，不把私有表名变成 Facade 契约。

## 套件分层

| 套件 | 运行时机 | 环境 | 目的 |
| --- | --- | --- | --- |
| Store codec | 每次变更 | 纯进程、无文件或临时文件 | JSON、validator、升级器、模型属性 |
| Store acceptance | 每次 Store 变更 | 临时真实后端 | CRUD、事务、作用域、重开、备份 |
| Store crash | 每次提交/恢复变更 | 可强杀子进程 | fsync/commit 切点、分裂提交、恢复 |
| Store stress | 合并门禁及定期 | 独立临时卷 | 150,000 目录项、批量、GC、重开基线 |
| Store platform | 对应平台发布前 | Android/Windows/macOS | 相同 fixture、锁、WAL、路径和生命周期 |
| Store security | 每次导出/秘密存储变更 | 临时真实后端 | 明文、日志、诊断、路径与配额 |

任何套件不得调用另一个产品层来“顺便”覆盖 Store。Runtime 完整集成测试可以复用已经通过
的 Store fixture，但不能取代这里的独立结果。

## 固定 fixture 集

Runtime Store 仓库必须版本控制以下合成 fixture：

- 当前版、每个仍支持旧版和一个未来版的 record envelope。
- 每种 scope 的最小文档、完整文档、未知扩展字段和合法最大边界文档。
- Unicode：简繁中文、组合字符、emoji、RTL、换行、NUL 拒绝路径和规范化差异。
- 64 位边界：安全整数内外、最大合法十进制字符串、负数/溢出/前导零非法样本。
- 缺失、显式 `null`、空对象、空数组、重复键、非法 UTF-8、过深/过大/过多键样本。
- 合成正文、图片头、`.part`、摘要错误、长度错误和 generation 不一致样本。
- `CANARY_BODY`、`CANARY_COOKIE`、`CANARY_TOKEN`、`CANARY_PATH` 等泄漏探针值；它们
  只能用于断言不出现在日志、报告和默认导出，不能长得像真实凭据。

fixture 生成器必须给出 seed、生成器版本和预期摘要。升级 fixture 只追加新版本，不覆盖
旧输入，以便持续证明兼容链。

## 验收用例目录

### A. Harness 与生命周期

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-A01` | 空临时根首次打开 | 原子创建、版本/generation 合法、无用户路径访问 |
| `ST-A02` | 正常 close 后 reopen | 所有已确认 revision 可读、锁释放、无重复恢复 |
| `ST-A03` | 同一根并发第二写实例 | 明确拒绝或只读，不出现两个 writer |
| `ST-A04` | close 与在途读写竞争 | 提交点前取消或提交点后返回确认，不悬挂 Future |
| `ST-A05` | 非法/只读/无权限根 | 稳定 `store_unavailable`，不在旁路目录建库 |
| `ST-A06` | testkit 自检 | 能证明网络未启用、时钟确定、seed/临时根隔离 |

### B. 作用域、身份与关系

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-B01` | 相同 key 位于两个 scope | 互不覆盖，查询不越权 |
| `ST-B02` | 相同远端 ID 位于两个插件 | identity 隔离，不自动跨源合并 |
| `ST-B03` | 同 scope 重复 identity | 唯一性错误且原记录不变 |
| `ST-B04` | parent 缺失/删除中创建 child | 事务拒绝，不产生孤儿 |
| `ST-B05` | 目录排序与分页 | stable order、无重复/漏项，标题变化不影响顺序 |
| `ST-B06` | 首版 `local` 与未来资料域 fixture | 查询必须显式 space，不依赖全局当前用户 |
| `ST-B07` | 插件 KV 跨命名空间访问 | 拒绝且不泄露目标是否存在 |

### C. JSON 文档与 codec

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-C01` | 当前版 round-trip | 规范 UTF-8、语义等价、revision 单调增加 |
| `ST-C02` | 未知字段读改写 | 未知对象/数组/标量逐字义保留，已知字段正确更新 |
| `ST-C03` | 缺失与显式 null | 按文档规则区分，不互相归一化 |
| `ST-C04` | 重复键/非法 UTF-8/尾随垃圾 | 写前拒绝，无部分记录 |
| `ST-C05` | 深度、大小、键数、数组上限 | 稳定 `data_invalid` 或配额错误，无内存失控 |
| `ST-C06` | 64 位值跨 codec 往返 | 无舍入、溢出和科学计数法漂移 |
| `ST-C07` | 确定性编码 | 同语义输入产生同一规范摘要 |
| `ST-C08` | 插件 extension 与核心键冲突 | 核心字段不被覆盖，命名空间强制 |
| `ST-C09` | 二进制/Base64/绝对路径禁止项 | validator 拒绝或投影为受控对象引用 |

### D. 文档与容器迁移

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-D01` | 每个支持旧版本逐级升级 | 与黄金 fixture 一致，未知字段保留 |
| `ST-D02` | 升级器重复执行 | 幂等、结果摘要一致、无系统时间/网络依赖 |
| `ST-D03` | read-repair CAS 冲突 | 新写入胜出，旧升级结果不覆盖 |
| `ST-D04` | 中途缺少升级器 | 原始字节保留，返回 `data_version_unsupported` |
| `ST-D05` | 未来版本读取 | 不改写；只读投影或稳定拒绝 |
| `ST-D06` | 后台批量升级被取消/重开 | 从 checkpoint 继续，无重复副作用 |
| `ST-D07` | 容器迁移每个 statement/commit 故障 | 旧版可恢复或新版完整，不存在半迁移可写状态 |
| `ST-D08` | 只新增可选 JSON 字段 | 容器版本不变，旧 fixture 仍可读 |

### E. 事务、revision 与幂等

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-E01` | 多记录 batch 成功/失败 | 全部提交或全部回滚 |
| `ST-E02` | 两 writer 使用同 revision | 只一个成功，另一个 `revision_conflict` |
| `ST-E03` | 同幂等键重复写 | 返回同一确认结果，不重复创建/扣配额 |
| `ST-E04` | 幂等键参数不同 | 明确冲突，不复用旧结果 |
| `ST-E05` | 阅读进度乱序完成 | 新语义位置不被旧请求覆盖 |
| `ST-E06` | 下载 checkpoint 重复/回退 | 单调规则生效，已确认字节不倒退 |
| `ST-E07` | 读事务与写事务并发 | 每个读取看到一致 snapshot，无混合 revision |
| `ST-E08` | commit 前/后取消 | 结果能唯一判断是否已提交，可安全重试 |

### F. 领域不变量

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-F01` | 插件禁用/缺失 | 书架、目录快照、进度、书签和本地内容仍可读 |
| `ST-F02` | 插件卸载 | 不级联删除用户权威/显式离线数据 |
| `ST-F03` | 目录改名/重排/删除 | 稳定 entry ID 与语义锚点按规则保留或显式失效 |
| `ST-F04` | 书签创建/删除/恢复 | revision 与 tombstone/恢复语义一致 |
| `ST-F05` | 清缓存 | 只删可再生对象，不删显式下载和用户状态 |
| `ST-F06` | 删除显式离线内容 | 保留书架/进度/书签，availability 正确更新 |
| `ST-F07` | 插件 KV/Cookie 配额 | 单记录、单插件、全局界限均生效且可诊断 |

### G. 正文与文件对象

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-G01` | put/open 单章 UTF-8 正文 | 主键读取字节、长度、摘要完全一致 |
| `ST-G02` | 相同内容/对象重复提交 | 幂等且不产生重复引用/文件 |
| `ST-G03` | 摘要或长度不符 | 对象不进入可用状态，staging 可恢复/清理 |
| `ST-G04` | 引用已提交、对象缺失 | `content_missing`，用户元数据不被删除 |
| `ST-G05` | 对象存在、引用未提交 | 成为有保留期的 orphan，不立即误删 |
| `ST-G06` | 替换正文 | 新引用先可用，旧对象只在无引用后 GC |
| `ST-G07` | 文件名/path traversal/symlink 输入 | 映射为 Runtime ID 或拒绝，不越出数据根 |
| `ST-G08` | 慢读、取消和 close | 流被释放，文件/数据库句柄无泄漏 |
| `ST-G09` | 不支持 codec | 稳定 `data_version_unsupported`，原字节保留 |
| `ST-G10` | 内容库 generation 重建 | 旧引用统一变 missing，不逐条伪造完成 |

### H. 崩溃与恢复故障矩阵

故障测试必须用独立子进程在真实持久化边界强制终止；仅抛异常不算崩溃验收。每个
fault point 对创建、替换、删除和清理至少运行一次，并在新进程 reopen 后检查。

| ID | 强杀点 | 允许的恢复结果 |
| --- | --- | --- |
| `ST-H01` | staging 创建前/后 | 无记录，或合法 staging 候选 |
| `ST-H02` | 对象写一半 | 不可读为完成；可续传或清理 |
| `ST-H03` | 对象 fsync/rename 前后 | 旧对象可用，或新对象为无引用 orphan |
| `ST-H04` | content DB commit 前后 | 单库事务完整，无半行/坏摘要 |
| `ST-H05` | metadata 引用 commit 前后 | 旧引用或新引用二选一，revision 可判定 |
| `ST-H06` | maintenance receipt 前后 | 重放幂等，不重复删除/计费 |
| `ST-H07` | 解除引用与实际删除之间 | 引用不会指向已删除对象；残留可 GC |
| `ST-H08` | content generation 轮换各阶段 | reopen 能完成或回退，不影响核心元数据 |
| `ST-H09` | WAL/checkpoint/close 期间强杀 | 已确认事务仍在，未确认事务不出现 |
| `ST-H10` | 恢复任务自身再次强杀 | 下次恢复继续，终态不依赖只运行一次 |

### I. 磁盘、损坏与维护

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-I01` | 写入前/中途磁盘满 | `disk_full`，无伪完成和无限重试 |
| `ST-I02` | 数据库页/正文/sidecar 位翻转 | 检出损坏并隔离，未损坏数据仍可诊断/导出 |
| `ST-I03` | 锁长期占用/busy timeout | 有界失败，不阻塞 UI/Runtime 无限等待 |
| `ST-I04` | `.part` 新旧/无记录组合 | 合法恢复；过期孤儿只在安全期限后清理 |
| `ST-I05` | maintenance 并发业务写 | 业务写被有界拒绝/排队，不绕过维护锁 |
| `ST-I06` | 完整性扫描取消/继续 | checkpoint 正确，不把未扫描对象标为健康 |

### J. 备份、恢复与导出

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-J01` | 写入并发时轻量备份 | 得到同一 snapshot，不是漏 WAL 的文件副本 |
| `ST-J02` | 轻量备份恢复 | 用户元数据/进度/书签恢复，正文明确为未包含 |
| `ST-J03` | 完整备份恢复 | 内容引用、对象、generation 和摘要一致 |
| `ST-J04` | 截断/篡改/未来版本备份 | 原数据不被覆盖，给出稳定错误 |
| `ST-J05` | 恢复中强杀 | 原 Store 或新 Store 至少一个完整可恢复 |
| `ST-J06` | 默认诊断/导出 | 不含 secret/body/path canary；包含范围清单准确 |

### K. 隐私与安全边界

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| `ST-K01` | 元数据数据库/日志全文扫描 | 找不到 Cookie/token/path/body canary；正文库只允许正文 canary |
| `ST-K02` | 敏感文档落盘 | payload 非明文，错误/备份策略符合分类 |
| `ST-K03` | 非法 record/scope/文件 ID | 无 SQL/path 注入、目录穿越或跨 scope 读取 |
| `ST-K04` | 超大/高嵌套 JSON | 在分配失控前拒绝，错误不回显 payload |
| `ST-K05` | 损坏密文/密钥不可用 | 不返回空值伪成功，不把密文当普通 JSON |
| `ST-K06` | 只读 inspector | 测试结束后无写能力进入生产包 |

### L. 模型属性与随机序列

使用简单内存参考模型生成至少包含 create/update/CAS/delete/reopen/backup/restore/GC 的随机
操作序列。每一步把 Store 可观察状态与模型比较，并记录 seed。必须覆盖：

- 任意成功写后 reopen 仍可观察。
- 任意失败写不改变前一 revision。
- GC 永不删除仍被引用或 pinned 的对象。
- 同一幂等键只有一个业务效果。
- 未来版/无升级器文档从不被旧 Runtime 改写。
- 清缓存不改变用户权威集合。

发现失败后保留最小化操作序列和 seed 作为固定回归 fixture。

## 规模与性能基线

性能只在正确性套件全部通过后运行。首版先建立可比较基线，不凭文档设拍脑袋的发布毫秒
门槛；但超时、OOM、损坏、无界增长和规模用例未完成都属于失败。

### 代表性规模

- 50 本 × 3,000 目录项 = 150,000 条 `CatalogEntry`。
- 对这些 entry 建立内容引用，并以可配置合成正文 profile 写入统一内容表；每次报告实际
  原始/落盘字节，不用稀疏文件大小伪装真实 I/O。
- 分别测量空库初始化、批量导入、单章主键读取、相邻章有界预取、目录分页、进度更新、
  删除一本书、GC、checkpoint、close/reopen、轻量备份和完整性扫描。
- 比较单条事务与多组有界批次，选择吞吐、取消延迟和内存峰值平衡点；实现不得硬编码
  文档示例中的 100/500 为永远正确的批次大小。

### 报告指标

每次记录平台/ABI、引擎与绑定精确版本、compile options、journal/synchronous 设置、CPU、
内存、存储介质、fixture seed/版本、记录数、正文原始/落盘字节、数据库/WAL 大小、总耗时、
p50/p95/p99、峰值 RSS、事务数、checkpoint/GC 时长和失败码计数。

基线回归必须与同平台同 profile 比较。若环境变化，建立新基线而不是把不同机器数字直接
相除。性能结果不能替代故障、迁移或平台验收。

## 平台矩阵

同一套逻辑 fixture 和断言必须运行：

| 平台 | 必须覆盖 |
| --- | --- |
| Android arm64 真机 | 打开/关闭、前后台、强杀恢复、空间压力、文件锁、完整 Store 套件 |
| Android x86_64 | 模拟器/CI 快速回归；不替代 arm64 真机耐久与强杀 |
| Windows x64 | 本地文件系统、并发锁、异常进程终止、安装升级后的数据根 |
| macOS arm64 | 沙盒外直接分发数据根、签名包环境、异常终止与恢复 |
| macOS x64 | 原生 x64 包同等 Store 冒烟；Rosetta 不能替代 |

纯 codec/model 套件可以在普通 Dart/语言进程运行；涉及 SQLite/文件/锁/掉电边界的用例
必须使用该平台真实后端。Android 测试可以由无 UI 的 instrumentation harness 承载，但
不能通过主应用页面触发。

## 结果与证据

Runtime 仓库最终必须提供一个根级、非交互式 Store 验收入口，并输出机器可读报告。报告
至少包含：

- commit、平台、ABI、引擎/绑定版本、Store/container/document 版本。
- 执行/跳过/失败用例 ID及原因；不允许静默 skip。
- fixture 版本、seed、fault point、规模 profile 和性能环境。
- 临时根是否清理、是否保留脱敏失败工件及其摘要。
- 明确的零网络、零主项目、零 Node/Javet、零真实用户数据证明。

发布声明“Runtime Store 验收完成”必须满足：目标平台所有强制用例通过、没有未解释 skip、
150,000 条规模基线已生成、崩溃矩阵已由真实子进程强杀执行、日志/导出 canary 扫描通过。
只通过 unit test、`flutter analyze`、Node 测试、主应用 UI 或 Windows 单平台均不得这样声明。

## 当前文档阶段的验收

本轮只验证术语、链接、ADR 状态、边界一致性和现有主项目静态检查。以下全部明确未执行：

- Store codec/acceptance/crash/stress/security 测试。
- SQLite 后端和绑定探针。
- Android、Windows、macOS Store 运行。
- 150,000 条目录/正文对象基线。
- 备份、恢复、加密、磁盘满和真实进程强杀。

这些未执行项是后续 Runtime Store 实现里程碑的门禁，不是本轮文档缺陷，也不能被写成
“已有测试覆盖”。
