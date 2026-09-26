# MgRead source API

本 package 只保存数据源编译期可见的公开声明，不实现 Runtime、校验或宿主行为。`MgReadPluginContext`、
`PluginWebViewApi` 和 `PluginWebViewPage` 是所有数据源的唯一类型来源；公共字段变化必须同步
`packages/mg_read_node_runtime`、数据源 typecheck、直接测试和 `mgread-source-development` 技能文档。
数据源通过 `@mgread/source-api` 的 `import type` 引用，禁止在来源目录复制 Context 或 WebView 子集。

`PluginChaptersRequest` 定义可选视频整组加载；源导出 `deferredGroups = true` 后由 Node Runtime 协商
`supportsDeferredGroups`。未协商时保持完整目录；缺省 deferred 等同 false，禁止把普通空组当作待加载。

独立原生模式的公开边界见 `native-source-contract.md`；C ABI 唯一定义属于同级
`mg_read_native_runtime/abi`。上述 TypeScript Context 规则适用于 JS 来源，原生来源直接消费 ABI crate，
不复制 Node Context，也不通过 JS 适配器执行。公开内容语义仍与 Flutter `PluginRuntime` 保持一致。
