# ADR-0011：主应用权威持久化与版本化元数据记录

- 状态：Accepted
- 日期：2026-08-14
- 决策者：MgRead 项目
- 取代：ADR-0008、ADR-0009、ADR-0010 中关于 Runtime Store 拥有主应用业务持久化的结论

## 决策

`mg_read` 拥有应用权威持久化。通用存储实现只位于 `lib/core/persistence/`，feature 仅定义和消费窄业务端口，并在自己的 data 层映射领域类型；feature 不拥有 SQLite、Drift、schema、容器迁移、备份恢复或生命周期。

持久化记录使用稳定 envelope：ID、`recordKind`、`scopeKind/scopeId`、可查询状态/排序/摘要投影、`formatVersion`、revision 与 UTC 时间。其余会演进的业务字段是由 `recordKind + scopeKind + formatVersion` 注册的 JSON object。codec 必须验证、升级并保留未知字段；缺失与显式 null 不相同。未来版本只能只读，损坏文档必须投影为稳定错误。正文、二进制/Base64、明文凭据与绝对路径禁止进入该 JSON。

公开 API 全异步。SQLite 使用 Drift 的后台 native executor，UI isolate 不执行同步 SQL、迁移或大 JSON 处理。首个交付只提供元数据 record store，不提供正文库、外部对象、Cookie、下载、业务 feature 或 Runtime transport。

`mg_read_runtime` 继续拥有插件执行和平台 Runtime，但不得打开主应用 SQLite，也不得获得数据库路径或连接。未来 Runtime 持久化需求只能经版本化、强类型的宿主能力提交；本 ADR 不实现该 transport。

## 后果

- 主应用可用独立临时数据根和 testkit 验收 CRUD、CAS、隔离、版本升级、事务与关闭边界，不依赖 Widget、Node、网络或真实目录。
- Runtime 不再是书架、进度或其他主应用数据的持久化权威；后续 feature 接入必须先定义窄端口。
- 容器迁移、备份/恢复以及正文/外部对象仍是后续单独交付，不能从本 ADR 推导为已实现。
