# MgRead 文档中心

这里是项目文档的总入口，服务于“先定位、再按需读取”。开发任务不要从本页继续打开全部链接；
先进入 [开发文档路由](development/README.md)，选择当前任务的一行。

## 文档层级

| 层级 | 作用 | 何时读取 |
| --- | --- | --- |
| L0 | 根 `AGENTS.md` 的全局硬约束 | 每个任务 |
| L1 | `development/README.md` 任务路由、`planning/README.md` 当前状态 | 开工定位 |
| L2 | 架构专题、实现说明、package `AGENTS.md` | 当前任务直接相关时 |
| L3 | ADR、内部协议、平台矩阵、性能/验收证据 | 改决策、改协议或核验证据时 |
| 历史 | 已被替代但保留原因的设计 | 只做考古、迁移或冲突调查时 |

## 状态定义

- **权威**：当前必须遵守的已接受 ADR 或由其直接落实的专题。
- **开发规范**：约束实现方式，但不能推翻权威架构。
- **实现说明**：描述某个已交付切片及已知限制，可能随代码更新。
- **证据快照**：只证明记录日期、平台和命令下实际执行的范围。
- **规划**：目标和顺序，不表示已完成。
- **历史**：结论已被后续 ADR 取代；默认不得作为实现依据。

若文档未显式写状态，以本页分类为准；冲突仍按根 `AGENTS.md` 的优先级处理。

## 当前权威架构

- [架构入口](architecture/README.md)：产品边界、核心不变量和专题路由。
- [ADR 索引](architecture/adr/README.md)：Accepted、Superseded 与历史关系。
- [产品范围与路线图](architecture/01-product-roadmap.md)：目标闭环和里程碑定义。
- [系统分层](architecture/02-system-architecture.md)：主应用、Runtime、阅读器和插件边界。
- [Runtime 生命周期](architecture/03-runtime-lifecycle.md)、[标准插件](architecture/04-plugin-sdk-packaging-registry.md)、
  [内部传输](architecture/05-transport-protocol.md)。
- [并发性能](architecture/07-concurrency-performance.md)、[可靠性与测试](architecture/08-reliability-observability-testing.md)、
  [平台发布](architecture/09-platform-release-future-capabilities.md)。
- [主应用持久化](architecture/10-app-persistence-design.md)、[持久化验收](architecture/11-app-persistence-acceptance.md)、
  [全局设置](architecture/12-global-settings.md)、[日志诊断](architecture/14-global-diagnostics-logging.md)、
  [插件内容契约](architecture/15-plugin-content-contract.md)、[Content Library](architecture/20-content-library.md)。

## 实现说明

- [主应用结构](implementation/main-app-structure.md)
- [Content Library 接入](implementation/content-library-integration.md)
- [首页 UI 系统](implementation/ui-design-system.md)
- [M2 UI 基础设施历史交付说明](implementation/m2-app-infrastructure.md)
- 源码局部地图：[`lib/`](../lib/README.md)、[`lib/core/`](../lib/core/README.md)、
  [`lib/features/`](../lib/features/README.md)、[`lib/shared/`](../lib/shared/README.md)、
  [`test/`](../test/README.md)

## 子项目文档

### 阅读器插件

从 [`packages/mg_read_reader_ui/AGENTS.md`](../packages/mg_read_reader_ui/AGENTS.md) 开始；再按任务选择
[项目目标](../packages/mg_read_reader_ui/docs/PROJECT_GOAL.md)、
[开发指南](../packages/mg_read_reader_ui/docs/DEVELOPMENT.md) 或
[UI 规范](../packages/mg_read_reader_ui/docs/UI_DESIGN.md)。接入示例、变更记录和第三方声明分别见
其 [README](../packages/mg_read_reader_ui/README.md)、
[CHANGELOG](../packages/mg_read_reader_ui/CHANGELOG.md) 与
[THIRD_PARTY_NOTICES](../packages/mg_read_reader_ui/THIRD_PARTY_NOTICES.md)。

### Plugin Runtime

从 [`packages/mg_read_runtime/AGENTS.md`](../packages/mg_read_runtime/AGENTS.md) 开始；按任务读取
[Runtime 契约](../packages/mg_read_runtime/docs/standalone-runtime-contract.md)、
[桌面闭环证据](../packages/mg_read_runtime/docs/desktop-runtime-bridge.md)、
[版本矩阵](../packages/mg_read_runtime/docs/runtime-version-matrix.md)、
[性能快照](../packages/mg_read_runtime/docs/standard-plugin-performance-baseline.md)、
[Flutter Facade](../packages/mg_read_runtime/packages/mgread_plugin_runtime/README.md)、
[协议 fixture 说明](../packages/mg_read_runtime/protocol/README.md) 或
[探针计划](../packages/mg_read_runtime/probes/README.md)。

### Node 插件

- 官方模板：[`templates/mg_read_plugin_template/AGENTS.md`](../templates/mg_read_plugin_template/AGENTS.md)
  和 [README](../templates/mg_read_plugin_template/README.md)。
- 真实书源：各自目录最近的 `AGENTS.md` 与 README，例如
  [`plugins/sources/aisishuwu/`](../plugins/sources/aisishuwu/README.md)。

## 历史设计：默认不读

下列文件保留旧方案的原因和验收思想，但其中“Runtime Store 拥有书架/目录/进度/正文”的
结论已被 ADR-0011 与 ADR-0100 取代：

- `architecture/06-domain-data-cache-downloads.md`
- `architecture/10-runtime-store-persistence.md`
- `architecture/11-runtime-store-acceptance.md`
- ADR-0008、ADR-0009、ADR-0010 中对应的数据所有权部分

若要恢复其中任何结论，必须先新增替代 ADR；不能从历史文件直接实现。

## 维护入口

文档编辑规则见 [documentation.md](development/documentation.md)。新增或移动文档时必须更新
本页或相应任务路由，但不要同时在多个入口复制同一段规范。
