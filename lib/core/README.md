# Core UI 基础设施边界

`core/` 承载跨 feature 的基础能力及主应用权威持久化；完整插件运行时仍属于 `mg_read_runtime`。

- `diagnostics/`：Runtime 脱敏状态、指标和诊断投影的 UI 模型。
- `errors/`：Runtime 稳定错误码及安全 UI 归一化。
- `persistence/`：版本化 metadata record port、SQLite 容器和生命周期。feature 只能经窄端口使用它，不能持有 Drift 或 schema。
- `settings/`：全局设置的强类型内存快照、分组异步提交、CAS 合并与 Riverpod 注入端口。它只
  通过 `SettingsStore` 消费 persistence；业务/UI 不接触 JSON、revision 或数据库。

不得在 `core/` 新增或恢复以下职责：Runtime Supervisor、Javet/Node 启动、WS/HTTP Client、
raw protocol、Runtime Store、文件布局/恢复、缓存/下载、Cookie、`host.*` handler
或平台 Runtime 通道。若这些能力需要变更，应修改 `mg_read_runtime` 及其公开门面。
