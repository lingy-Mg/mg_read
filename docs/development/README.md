# 渐进式开发文档路由

读完根 `AGENTS.md` 后，在下表选择当前任务最窄的一行。完整阅读“必读”；“按需”只在任务
实际触及对应边界时打开。不要因为一个 Flutter 页面调用了 Facade，就顺便读取 Runtime 内部
协议全文。

| 任务类型 | 必读 | 按需 |
| --- | --- | --- |
| 主应用页面、路由、状态 | [workflow](workflow.md)、[主应用结构](../implementation/main-app-structure.md) | [UI 系统](../implementation/ui-design-system.md)、[二级页面规范](../implementation/secondary-page-design-system.md)、[发现页开发规范](../implementation/discovery-development.md)、最近的 `lib/features/*` 实现与测试 |
| persistence / settings | [ADR-0011](../architecture/adr/0011-app-owned-versioned-persistence.md)、[主应用持久化](../architecture/10-app-persistence-design.md) | [验收](../architecture/11-app-persistence-acceptance.md)、[设置](../architecture/12-global-settings.md) |
| Content Library、目录、正文、漫画文件 | [ADR-0100](../architecture/adr/0100-app-owned-content-library.md)、[Content Library](../architecture/20-content-library.md) | [接入说明](../implementation/content-library-integration.md)、ADR-0011 |
| Runtime Facade 消费 | [系统分层](../architecture/02-system-architecture.md)、Runtime package 的 [AGENTS](../../packages/mg_read_runtime/AGENTS.md) | Facade [README](../../packages/mg_read_runtime/packages/mgread_plugin_runtime/README.md)、插件内容契约 |
| Runtime Core / desktop / Android / macOS | Runtime package 的 [AGENTS](../../packages/mg_read_runtime/AGENTS.md)、[Runtime 契约](../../packages/mg_read_runtime/docs/standalone-runtime-contract.md) | [生命周期](../architecture/03-runtime-lifecycle.md)、[传输](../architecture/05-transport-protocol.md)、[版本矩阵](../../packages/mg_read_runtime/docs/runtime-version-matrix.md)、平台证据 |
| 插件安装、package/lock、冷激活 | Runtime package 的 [AGENTS](../../packages/mg_read_runtime/AGENTS.md)、[标准插件专题](../architecture/04-plugin-sdk-packaging-registry.md) | ADR-0015、ADR-0006、Runtime installer 测试 |
| 真实书源插件 | 该来源最近的 `AGENTS.md`、[插件内容契约](../architecture/15-plugin-content-contract.md) | 官方模板、Runtime fixture、线上 smoke 规则 |
| 官方空白插件模板 | 模板 [AGENTS](../../templates/mg_read_plugin_template/AGENTS.md)、模板 [README](../../templates/mg_read_plugin_template/README.md) | ADR-0015、插件内容契约 |
| 阅读器公共 API / 会话 / 原生能力 | 阅读器 [AGENTS](../../packages/mg_read_reader_ui/AGENTS.md)、[项目目标](../../packages/mg_read_reader_ui/docs/PROJECT_GOAL.md)、[开发指南](../../packages/mg_read_reader_ui/docs/DEVELOPMENT.md) | API 源码、示例、平台实现 |
| 阅读器 UI / 排版 / 交互 | 阅读器 [AGENTS](../../packages/mg_read_reader_ui/AGENTS.md)、[UI 规范](../../packages/mg_read_reader_ui/docs/UI_DESIGN.md) | 开发指南、相关 Widget/分页实现 |
| 日志、trace、关键链路、性能埋点 | [诊断接入规范](diagnostics-instrumentation.md)、[日志专题](../architecture/14-global-diagnostics-logging.md)、[ADR-0016](../architecture/adr/0016-segmented-text-diagnostics.md) | `lib/core/diagnostics/README.md`、Runtime 性能快照、受影响 registry/tests |
| 测试、CI、发布、平台验收 | [workflow](workflow.md) | [可靠性与测试](../architecture/08-reliability-observability-testing.md)、[平台发布](../architecture/09-platform-release-future-capabilities.md)、子项目命令 |
| 架构/ADR 变更 | [架构入口](../architecture/README.md)、[ADR 索引](../architecture/adr/README.md)、相关 Accepted ADR 全文 | 被取代 ADR 和历史专题仅用于理解迁移原因 |
| 文档、规划、AI 指令 | [文档维护](documentation.md)、[文档中心](../README.md)、[当前规划](../planning/README.md) | 只读受影响专题和引用它的入口 |

## 读取停止条件

满足以下条件就停止继续加载：

- 已找到当前代码所有者、公开边界、相关 Accepted ADR 和验证入口；
- 下一份文档只是在重复已知规则；
- 下一份文档属于未触及的平台、未来能力或历史方案；
- 任务可以通过搜索具体标题/符号定位，无需整篇读取另一个大专题。

跨模块任务可以选择多行，但要先列出每行对应的改动和验收边界。若发现路由缺失或文档冲突，
先按 [文档维护规则](documentation.md) 标记权威性，不要同时按两套方案实现。
