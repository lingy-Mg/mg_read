# Core UI 基础设施边界

`core/` 只承载跨 feature 的 UI 基础能力，不承载插件、书架、阅读、下载或 Runtime 的
业务规则。完整插件运行时属于 `mg_read_runtime`，本仓库只能消费其版本化 Facade。

- `diagnostics/`：Runtime 脱敏状态、指标和诊断投影的 UI 模型。
- `errors/`：Runtime 稳定错误码及安全 UI 归一化。

不得在 `core/` 新增或恢复以下职责：Runtime Supervisor、Javet/Node 启动、WS/HTTP Client、
raw protocol、Runtime Store/SQLite、文件布局/恢复、缓存/下载、Cookie、`host.*` handler
或平台 Runtime 通道。若这些能力需要变更，应修改 `mg_read_runtime` 及其公开门面。
