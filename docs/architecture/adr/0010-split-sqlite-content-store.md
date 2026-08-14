# ADR-0010：SQLite 元数据/正文分库与外部文件对象

- 状态：Superseded by ADR-0011
- 日期：2026-08-14
- 决策者：MgRead 项目
- 依赖：[ADR-0008](0008-standalone-plugin-runtime-boundary.md)、
  [ADR-0009](0009-scoped-versioned-json-records.md)

## 背景

小说目录可达到几十万条，正文可增长到数 GB 或十几 GB；书架、进度、书签和设置则应
保持小而易备份。一本书一张表、一本书一个数据库或一章一个文件会放大迁移、备份、删除、
恢复和跨书查询复杂度。把全部正文和关键元数据放在同一数据库，又会让轻量备份、完整性
检查和清理离线内容承担不必要的大文件成本。

当前 Runtime 契约尚未选择 Store 后端，并明确要求先证明 Android Javet、Windows、macOS、
无 Node 原生 Addon、生命周期、包体和版本固定能力。因此本 ADR 只记录首选物理方案，
在探针和独立验收通过前不进入 Accepted，也不授权增加依赖。

## 提议

在 SQLite 方案通过探针后，Runtime 自有数据根使用：

```text
runtime-data/
  database/
    runtime.sqlite             # 稳定骨架、作用域 JSON、关系、进度、任务和内容引用
    content.sqlite             # 所有小说正文统一的内容对象表
  content/objects/             # 漫画图片、封面及其他大文件对象
  downloads/parts/
  cache/objects/
  staging/
  diagnostics/
```

- 不按小说分表或分库，不创建一章一个 TXT。
- `content.sqlite` 使用统一 `content_objects` 表，以稳定对象 ID 主键读取；正文基线为未压缩
  UTF-8 字节，媒体类型、codec、长度、摘要、generation 和动态 descriptor 分开记录。
- `runtime.sqlite` 不保存正文，只保存内容对象稳定引用、完整性信息和可用性投影。
- 漫画图片、ZIP、插件包、`.part` 与未来媒体继续放文件对象层，不进入 SQLite BLOB。
- FTS、缩略图和其他索引只能是可删除、可重建的派生产物，不能成为用户数据权威。

## 两库一致性

SQLite WAL 模式下，跨多个 attached 数据库的提交不保证掉电原子性。因此实现不得把
`runtime.sqlite + content.sqlite` 当成一个跨文件事务：

1. 新内容先以不可变对象写入并在 `content.sqlite` 独立提交。
2. 校验成功后，以 revision compare-and-swap 在 `runtime.sqlite` 提交引用。
3. 替换时先指向新对象，再把旧对象加入有界垃圾回收候选。
4. 任一步崩溃后，启动恢复通过 maintenance journal、generation 和摘要进行幂等重放；
   无引用内容是可清理孤儿，引用缺失内容则标记 `damaged/missing`，绝不伪造成功。

清除正文必须经 Runtime maintenance capability：取得维护锁、记录意图、关闭内容库、
重建 generation 并恢复引用投影。主项目不得直接删除数据库；轻量元数据、进度、书签和
设置不受正文库重建影响。

## 探针与接受条件

转为 Accepted 前必须在 `mg_read_runtime` 给出：

- 精确 SQLite 引擎与绑定版本、许可证、供应链、安装包体积和升级策略。
- Android arm64/x86_64、Windows x64、macOS arm64/x64 的打开、WAL、锁、关闭、异常退出、
  备份/恢复与损坏检测证据。
- 证明实现不要求 Node native addon，不从主项目注入数据库路径/连接或平台 callback。
- 证明普通 JSON 即使没有数据库 JSON 扩展也可验证和读写；SQLite compile options 被记录。
- 两库每个提交阶段的进程终止故障注入与恢复证据。
- 统一内容表在至少 150,000 个目录项/正文对象索引下的批量写、主键读取、删除和重开基线。
- 完整通过独立 Runtime Store 验收规范，且主应用、Node、网络和真实书源均不是测试前置。

精确 SQLite/Flutter/Dart 库在上述探针完成前保持未定；旧方案中的 Drift 不能被视为已经
批准的依赖。

## 后果

正面：

- 关键元数据保持轻量，正文可独立增长、校验、备份或清理。
- 统一内容表避免动态 SQL、成百上千张表和每章文件风暴。
- codec 字段允许未来在有证据后加入压缩，不需要修改正文表结构。
- 两库不假定跨文件原子提交，故障边界和恢复行为可被明确测试。

代价与风险：

- 两库没有跨文件外键和 WAL 原子提交，必须维护 generation、意图日志和孤儿恢复。
- SQLite 绑定本身可能增加原生包体和平台维护成本；探针失败时需要替代后端。
- 正文库独立不意味着可以任意删除；显式下载与缓存仍需不同删除策略。

## 被拒绝的方案

- **一本书一张表/一个数据库**：迁移、查询、备份和生命周期管理随书籍数量增长。
- **一章一个文件**：小文件数量、目录扫描、原子更新和清理成本过高。
- **漫画图片或插件包进入 SQLite**：不利于 Range、流式传输、原子文件替换和对象级清理。
- **两库 WAL 事务视为原子**：与 SQLite 的跨 attached 数据库约束不符，掉电后可能分裂提交。
- **现在直接引入 Drift/SQLite 依赖**：越过 Runtime 契约要求的平台、包体和生命周期探针。

## 回退方案

若任一首发平台无法满足探针，保留 ADR-0009 的稳定 envelope、作用域 JSON、内容对象和
独立 Store Port，替换物理后端；不得把持久化移回 `mg_read`，也不得让 Node 与 Flutter
同时直接打开同一数据文件。
