# Core 基础设施边界

`core/` 不承载书架、插件、阅读或下载的业务规则。它只提供跨 feature 可复用的基础能力：

- `diagnostics/`：脱敏的只读状态、指标和诊断投影。
- `errors/`：稳定错误码及安全错误归一化。
- `files/`：受控应用文件布局、原子提交和恢复策略。
- `persistence/`：唯一 Drift/SQLite 执行器、Schema、迁移和通用持久化基础能力。
- `runtime/`：Host 侧 Runtime Supervisor、WS/HTTP Client 和严格协议适配；这里不保存业务权威数据。
- `scheduling/`：有界后台 Isolate 计算、队列、取消和 deadline 基础能力。

`runtime/` 只调用公开协议，不能打开 SQLite；`persistence/` 不发起 Node/网络业务调用；`files/` 不存放 Widget 或 feature 状态。
