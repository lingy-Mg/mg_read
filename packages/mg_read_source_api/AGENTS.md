# MgRead source API

本 package 只保存数据源编译期可见的公开声明，不实现 Runtime、校验或宿主行为。`MgReadPluginContext`、
`PluginWebViewApi` 和 `PluginWebViewPage` 是所有数据源的唯一类型来源；公共字段变化必须同步
`packages/mg_read_node_runtime`、数据源 typecheck、直接测试和 `mgread-source-development` 技能文档。
数据源通过 `@mgread/source-api` 的 `import type` 引用，禁止在来源目录复制 Context 或 WebView 子集。
