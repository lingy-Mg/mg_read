# Architecture Decision Records

ADR 记录 MgRead 不得被普通实现修改隐式改变的决策。

## 状态规则

- `Proposed`：讨论中，不约束实现。
- `Accepted`：已接受，所有实现和专题文档必须遵守。
- `Superseded`：已被新 ADR 取代，保留历史原因并链接替代项。
- `Deprecated`：不再建议，但尚有兼容义务。

修改已接受决策时：

1. 新建 ADR，说明新证据、替代方案、迁移和回滚。
2. 新 ADR 接受后，把旧 ADR 标记为 `Superseded by ADR-xxxx`。
3. 同步专题文档、协议 Schema、测试和 README。
4. 不允许只改旧 ADR 的结论来抹去历史。

## 已接受决策

| ADR | 决策 | 状态 |
| --- | --- | --- |
| [ADR-0001](0001-single-node-vm.md) | 每个应用进程只运行一个 Node VM | Accepted |
| [ADR-0002](0002-trusted-plugins.md) | 首版插件完全可信，不建立安全沙箱 | Accepted |
| [ADR-0003](0003-node24-javet-platform-hosting.md) | Node 24；Android Javet，桌面捆绑官方 Node | Accepted |
| [ADR-0004](0004-ws-http-transport.md) | WS 控制面、HTTP 数据面，所有二进制经 Node | Accepted |
| [ADR-0005](0005-host-database-authority.md) | Flutter 数据库是业务权威，Node 负责文件传输 | Superseded by ADR-0008 |
| [ADR-0006](0006-cold-plugin-activation.md) | 插件更新使用版本目录并在下次进程冷激活 | Accepted |
| [ADR-0007](0007-direct-distribution.md) | 首版全平台站外分发 | Accepted |
| [ADR-0008](0008-standalone-plugin-runtime-boundary.md) | 独立插件运行时、零主项目注入与 Runtime 自有持久化 | Superseded by ADR-0011 |
| [ADR-0009](0009-scoped-versioned-json-records.md) | 稳定记录骨架与作用域化版本 JSON | Superseded by ADR-0011 |
| [ADR-0011](0011-app-owned-versioned-persistence.md) | 主应用权威持久化与版本化元数据记录 | Accepted |
| [ADR-0013](0013-app-owned-content-library.md) | 应用拥有 Content Library 三层持久化 | Accepted |
| [ADR-0014](0014-tiered-diagnostics-storage.md) | 分域事件索引、span 与独立诊断附件对象 | Superseded by ADR-0016 |
| [ADR-0015](0015-standard-node-plugin-projects.md) | 标准 Node 插件、npm lockfile 恢复与依赖对象仓 | Accepted |
| [ADR-0016](0016-segmented-text-diagnostics.md) | 分段 TXT 日志与显式调试详情捕获 | Accepted |

## 提议中决策

| ADR | 决策 | 状态 |
| --- | --- | --- |
| [ADR-0010](0010-split-sqlite-content-store.md) | SQLite 元数据/正文分库与外部文件对象 | Superseded by ADR-0011 |
