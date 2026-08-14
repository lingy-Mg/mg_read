# Protocol baseline

`protocol/` 将维护 `mg_read_runtime` 的内部 WS/HTTP wire schema、固定 fixture 和
Runtime Facade 的版本化公开类型。主项目不直接连接 wire protocol；它只消费 Runtime
发布的强类型 `PluginRuntime.invoke(PluginInvocation)` 门面。

M1.3 当前固定一个狭窄的桌面 bootstrap + template-fixture contract：
[`fixtures/desktop-runtime-m1.3.json`](fixtures/desktop-runtime-m1.3.json)。默认 Core 只覆盖
`ready` 后的 loopback health、WS `runtime.hello`/`runtime.ping`/内部 shutdown、精确版本和
64 KiB 控制帧限制；fixture 还固定单连接 256 个在途控制请求、1 MiB 写侧队列和
best-effort `cancel` envelope。它额外记录一个仅由固定测试 CLI 旗标启用的模板 method、
plugin ID、唯一 Runtime 内部服务和文本上限。Node 与 Flutter 集成测试共同读取它；当前
cancel 只用于 Facade deadline 后撤销仍在途的内部控制工作，不是已完成的插件业务取消、
事件、重连或资源 HTTP contract，更不是完整跨平台 fixture。

`fixtures/desktop-runtime-m1.2.json` 保留为已验收的历史 bootstrap 基线；当前运行时和测试
使用 M1.3 fixture。模板夹具不是 ZIP/registry/plugin discovery schema，也不能据此让主项目
加载任意 ESM、连接 WS 或实现 `host.*`。

后续业务契约只能在 Runtime Core、Runtime Store、Flutter-facing Facade 和固定跨平台
fixture 准备就绪时一起引入。不得先在 `mg_read` 创建 WebSocket Client、`host.*` handler
或复制 DTO 来“临时接入”。

`compatibility.json` 是版本标记，不是业务协议规范。它捕获独立 Runtime 在内部
`runtime.hello` 协商中报告的兼容单元：

- protocol version 1.0；
- Javet Android 5.0.8；
- Node 24.16.0 on Android and desktop；
- Android minSdk 24 and the selected Node ABIs。

Runtime 集成包自行进行 ready/hello、版本核对和重连；主项目不会接收端口、boot ID 或
envelope。完整边界见 [独立插件运行时契约](../docs/standalone-runtime-contract.md)。
