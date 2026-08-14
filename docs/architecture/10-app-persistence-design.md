# 10 主应用持久化设计

本专题落实 [ADR-0011](adr/0011-app-owned-versioned-persistence.md)。主应用 metadata record store 是应用权威持久化；它不替代 Runtime 的插件执行职责，也不向 Runtime 暴露数据库路径、连接或 SQL。

`lib/core/persistence/` 对外提供异步 `PersistenceRecordStore`、稳定 `RecordEnvelope`、`ScopeKey` 与按 record/scope 注册的文档 codec。内部容器是 SQLite，所有 SQL 由 Drift 的后台 native executor 执行。当前 schema 只有 `metadata_records`，可查询的 envelope 保持固定，业务文档是受 codec 约束的 JSON object。

## 依赖选择

本交付固定 `drift: 2.34.3`（MIT）。它是维护中的 Flutter/Dart SQLite 映射库，官方发布页列出 Android、Windows 与 macOS；原生平台文档说明 `NativeDatabase.createInBackground` 会用独立 isolate 承载同步 SQLite。本项目只引入 `drift`，不引入 code generator 或额外 Flutter 路径插件；其传递 `sqlite3` 原生库会增加首发平台二进制体积，尚未进行 Android/macOS 实机包体测量，因此该数据只能在后续平台发布验收补齐。

每次写入验证当前格式；读取对旧格式执行纯、确定性的逐版本升级并保留未知字段。未来格式返回只读错误，损坏 JSON 返回稳定损坏错误。CAS 以 revision 为唯一竞争依据；批处理在短 SQLite 事务中提交。正文、文件对象、Cookie、凭据、下载、备份恢复和容器迁移不是本交付包。

后续 feature 只应依赖自己的窄端口，例如 `LibraryStore`，由 data 层映射至本核心端口；不得把 Drift 或 JSON Map 透传到 domain/presentation。
