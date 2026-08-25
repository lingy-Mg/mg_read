# Protocol baseline

`protocol/` 保存 Runtime 内部 WS/HTTP fixture 和兼容标记。它不是主项目 API；`mg_read` 只
消费 Runtime package 公开的强类型 `PluginRuntime.invoke(PluginInvocation<T>)`。

当前 fixture 是
[`fixtures/standard-node-plugin-v1.json`](fixtures/standard-node-plugin-v1.json)，固定：

- Node `24.16.0`、Runtime `0.3.0-standard.2`、protocol `1.0`；
- loopback live/ready 与 `/v1/rpc`；
- 4 MiB 控制帧、256 个在途请求、8 MiB 写队列和 best-effort cancel；
- `getChapters({id}) -> {items}` 的单次完整目录，以及 5000 条/2 MiB 专用边界；
- `runtime.hello`、`runtime.ping`、`runtime.status.v1`、`plugins.list.v1`、
  `plugins.openCodeDirectory.v1`、`plugins.setEnabled.v1`、`plugins.cache.usage.v1`、`plugins.cache.clear.v1`、
  `plugins.cache.clearAll.v1`、`plugins.installation.usage.v1`、
  `source.discover/search/getDetail/getChapters/getContent.v1`、`runtime.shutdown`；
- 一个按标准 package/lock 安装、冷激活并执行完整内容链路的无网络插件投影。

`plugins.installation.usage.v1` 的 `archive` 范围统计 Runtime 保留的原始 `.mgplugin`，
`data` 范围排除 `node_modules`，`npm` 范围统计物化后的依赖树；三者只返回字节数和文件数。

Node Core 测试和 Flutter↔Node 集成测试共同读取该 fixture，避免两端分别猜测版本、方法或
上限。历史 `desktop-runtime-m1.2.json` 只保留为 bootstrap 证据，不是当前业务 fixture；旧
M1.3 模板 fixture、模板 RPC 和 CLI 开关已经删除。

安装器的 package/lock/archive 规则由源码类型、Runtime 测试和主项目 ADR-0015 共同约束，
不会复制成主项目 raw DTO。后续大资源 HTTP、Store 或安装 UI capability 必须同步增加 Runtime
handler、公开 Facade 类型、固定 fixture 和测试。

`compatibility.json` 继续记录 Node/Javet/ABI 兼容单元。Facade 自行完成 ready/hello 和版本
核对；主项目不会接收端口、boot ID 或 envelope。
