# Rust / WebAssembly 数据源模式

`@mgread/source-wasm` 将一个 ABI v1 Wasm 模块映射为现有数据源能力。Windows 的 Node/V8 和 Android 的
Javet/V8 使用同一份 Wasm。安装产物继续采用 `.mgplugin.js`，里面内嵌编译后的二进制与宿主适配代码。
用户设备不需要 Rust、Cargo、JDK、JVM 或 npm 安装。

参考实现与实测：[爱丽丝 Rust/Wasm](../../plugins/sources/aisishuwu-wasm/EFFECT_REPORT.md)。现有 JS 数据源继续工作。

## ABI v1

模块不允许 imports，必须导出：

| 导出 | 签名 / 约定 |
| --- | --- |
| `memory` | wasm32 线性内存；参考链接参数限制为 64 MiB |
| `abi_version` | `() -> i32`，必须返回 1 |
| `alloc` | `(length: i32) -> pointer: i32` |
| `release` | `(pointer: i32, length: i32) -> void`；每块内存释放一次 |
| `invoke` | `(inputPointer: i32, inputLength: i32) -> outputPointer: i32` |
| `result_len` | `() -> i32`，读取刚刚返回的输出长度 |

消息使用 UTF-8 JSON。初始输入为 `{method, request}`；每次 HTTP 后续输入为
`{method, request, state, responses}`。模块必须不保留输入指针，HTTP 等待期间也不依赖共享可变业务状态。
适配器在下一次 guest 调用前复制并解析输出，然后释放输入和输出。各个异步调用持有自己的 continuation。

输出有三种形式：

```json
{"kind":"result","value":{"items":[],"nextCursor":null}}
{"kind":"http","requests":[{"url":"https://example.org/","headers":{},"optional":false}],"state":{"stage":"parse"}}
{"kind":"error","code":"source_access_blocked"}
```

HTTP 成功响应为 `{body}`；可选请求失败为 `{error:"http_failed"}`。响应文本有界读取，超量立即取消。
每轮最多 4 个请求，每次能力调用最多 128 个请求 / 128 轮。每个 HTTP 请求 20 秒超时，轮次之间检查
90 秒总期限。最终结果里的单字段对象 `{"$resource": descriptor}` 被替换为 `ctx.resource.proxy(descriptor)`
的返回值；描述校验、站点 allowlist 和请求策略由来源负责，宿主仍执行原有资源校验。

只有 `source_access_blocked` 映射为稳定公开错误，其余来源错误统一失败。适配器不记录 HTML、正文或凭据。
JSON 消息上限各 8 MiB，单个 HTTP 文本 4 MiB；最终公开结果还要通过 Runtime 更严格的字段及 inline 限额。

## 使用和生命周期

```js
import { Buffer } from 'node:buffer';
import { createWasmSource } from '@mgread/source-wasm';
const source = createWasmSource(Buffer.from(embeddedBinaryBase64, 'base64'));
export const { activate, discover, search, searchSuggestions,
  getDetail, getChapters, getContent } = source;
```

`activate` 只保存 Context，首次能力调用才单飞编译和实例化。独立调用方可使用 `deactivate` 取消适配器拥有的
HTTP 请求并丢弃实例；标准插件的公开导出保持现有约定，Runtime generation 生命周期继续由宿主管理。

这是一种可信插件执行模式。Wasm 没有原生文件系统、Socket 或线程入口，但外层 JS 与现有插件享有同样的
Node 权限。同步 Wasm 代码不能在同一 V8 调用栈中被超时抢占，64 MiB 也仅是参考二进制的线性内存限制，
不等于整个 Runtime 内存预算。Wasm 是可反编译的二进制，不提供代码保密或签名认证。

## 验证

固定 Node 在此目录执行 `npm.cmd run typecheck` 与 `npm.cmd test`。参考来源的 `npm.cmd verify` 额外运行真实 Rust 二进制、内容契约、
包确定性与冷安装测试。平台验收分别运行参考来源的 Windows Facade 测试与根 Android Integration Test。
