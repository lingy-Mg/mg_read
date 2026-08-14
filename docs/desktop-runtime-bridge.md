# M1.2 桌面通信骨架与 M1.3 空白插件模板夹具

## 状态与范围

这是 `mg_read_runtime` 已实现并在当前 Windows 主机自动化验证的窄桌面闭环。M1.2 证明
Runtime 可以在**不由 `mg_read` 注入任何服务**的情况下，自行启动固定 Node、完成内部
ready/HTTP/WS 门禁，并把一个强类型 capability 投影给 Flutter。M1.3 在该骨架上再验证一个
仓库内固定空白模板的 Runtime -> plugin -> Runtime 往返；它不是 Node 回调 Flutter 或主项目。

它不是完整首版 Runtime，也不表示 Android、macOS、通用插件装载、Runtime Store、资源流、
ZIP、下载、Cookie、阅读器适配或主项目 UI 已完成。移动端/Javet 在本轮明确不测试；macOS
打包和执行也尚未在当前 Windows 主机验证。

## 已实现的 Runtime 内部路径

```text
PluginRuntime.invoke(RuntimePingInvocation)
  -> Runtime-owned Desktop Supervisor
  -> Windows Job Object (KILL_ON_JOB_CLOSE)
  -> exact bundled Node 24.16.0 child
  -> stdout ready JSON
  -> GET 127.0.0.1:{ephemeral}/health/ready
  -> ws://127.0.0.1:{ephemeral}/v1/rpc runtime.hello
  -> runtime.ping response mapped to RuntimePingResult
```

M1.3 的第二条路径只在本仓库测试中显式启用：

```text
PluginRuntime.desktopForTesting(enableTemplatePluginFixture: true)
  -> fixed Node CLI argument
  -> checked-in template ESM default export
  -> template context.runtime.request('runtime.template.context')
  -> Runtime-owned internal service result
  -> TemplatePluginRoundTripResult
```

- Core 只绑定 `127.0.0.1:0`；不监听局域网或任意地址。
- Windows Supervisor 在启动 child 前创建一个 Runtime-owned Job Object，并设置
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`。child 在 Core 读取启动输出前被加入 Job；因此 Flutter
  owner 正常关闭或进程退出时，Windows 内核会清理 Node 与它在加入后创建的进程后代。生产
  Core 禁止 `child_process`；桌面测试夹具仍专门创建一个后代以验证内核清理语义。
- `src/cli.ts` 只通过 stdout 发一条生命周期 `ready` JSON；stderr 只输出固定、结构化的
  `diagnostic`/`fatal` 记录。Facade 不转发 raw stderr、路径、堆栈、端口或环境变量，而是提供
  稳定错误码、异常内 diagnostics 与 `PluginRuntime.diagnostics` 的有界脱敏投影。
- 缺 Node executable、缺已编译主脚本、进程拉起失败、无效 ready、提前退出、HTTP readiness
  失败和 Node 启动 fatal 都有独立稳定原因；启动失败不留孤儿进程。
- `src/desktop-runtime.ts` 提供仅供 Runtime 使用的 `/health/live`、`/health/ready` 和
  `/v1/rpc`。它们不是主项目 API。
- 默认 WS 只实现 `runtime.hello`、`runtime.ping` 和有幂等键的内部
  `runtime.shutdown`。当且仅当 CLI 的固定测试旗标已启用，Core 额外暴露
  `plugin.template.roundTrip`；该方法只能加载仓库内固定模板、只接受固定 plugin ID/有界文本，
  并且模板反向服务仅有 `runtime.template.context`。它不接受任意插件路径、package bytes、
  callback 或 `host.*`。所有控制调用验证版本、`bootId`、`c:` 请求 ID、trace、deadline、对象参数和
  64 KiB 控制帧上限；一条连接可并行处理至多 256 个在途控制请求，写侧队列上限为 1 MiB，
  慢消费者超过上限会被关闭而非无限占用 Runtime 内存。Facade 使用请求 ID 多路复用、对超时
  发 best-effort `cancel`，迟到响应不会误伤其他调用。大内容仍只允许走未来 loopback HTTP
  数据面；它不等同于完整业务协议。
- `packages/mgread_plugin_runtime` 是 Runtime 自有的 Flutter 包。生产 `PluginRuntime()` 是
  process-wide singleton，公开调用面为 `PluginRuntime.invoke(PluginInvocation<T>)`；当前生产
  invocation 仍只有无传输细节的 `RuntimePingInvocation`。M1.3 的
  `TemplatePluginRoundTripInvocation`、result 和 fixture 开关均标记为 test-only，不能作为
  主项目的通用插件入口。

`PluginRuntime.desktopForTesting()` 只带有 `@visibleForTesting`，用于让本仓库测试找到自身
的 Node bundle 与已编译 entrypoint，并覆盖缺 executable、缺主脚本、启动 fatal 和固定模板
往返。模板选项仅是布尔值，Node 自行派生已检查入的路径；它不是主项目注入点，不接受端口、
PID、Database、Cookie、文件、callback、platform channel、`host.*` 或任意插件位置。
生产 `PluginRuntime()` 只解析 Runtime package 自身最终 Flutter asset 布局；发布前由
`npm run stage:flutter-windows` 复制完整精确 Node distribution 和 `dist/`。该真实最终 Windows
包启动与 macOS 签名实现仍未在当前主机验收。

## 共享 fixture 与测试

[`protocol/fixtures/desktop-runtime-m1.3.json`](../protocol/fixtures/desktop-runtime-m1.3.json)
固定本闭环的 Node、Runtime、协议版本、loopback 路径、默认方法、帧限制和模板夹具的唯一
method/plugin ID/反向服务/文本上限。Node 单测和 Flutter 集成测试共同读取它，避免两端各自
猜测版本或端点。

| 层级 | 命令/位置 | 已验证内容 |
| --- | --- | --- |
| 空白模板 | `npm test` / `templates/mgread-plugin-template/test/` | TypeScript 类型、实际 ESM 默认导出、清单同步、一次 Runtime 反向服务调用、固定日志顺序和取消处理 |
| Node Core | `npm test` / `test/*.test.mjs` | 单例启动、loopback health、WS hello/ping、稳定错误、cancel parser、256 路同连接多路复用、默认 Core 拒绝模板方法、启用夹具时的模板完整往返、ESM 版本和 fixture 一致性 |
| Flutter ↔ Node | `npm run test:flutter-desktop` / `packages/mgread_plugin_runtime/test/` | process-wide Facade singleton、Flutter `Process.start` 精确 Node、Job Object 进程树关闭、ready、HTTP readiness、WS hello、128 个并发 ping 共享一个子进程、固定模板往返和安全日志链、缺 Node/缺主脚本/结构化启动 fatal 的错误投影 |
| npm 依赖 | `npm run check:no-native-addons` | 根项目和模板的 npm 依赖树没有原生 Addon 指示物 |

当前已经运行的是 Windows x64 主机上的上述 Node 与 Flutter 测试。它不是 Android/Javet
验收、macOS 验收、隐藏窗口发布验收或最终应用包内运行证据；移动端测试在本里程碑明确
不执行。

## 后续实现门槛

后续 capability 必须先在 Runtime 内增加强类型 invocation/结果、schema/fixture、Node
handler、Facade 映射与对应测试；不能让 `mg_read` 拼装 WS、启动 Node 或补 `host.*`。当
Runtime Store 与插件恢复实现时，产品级 `ready` 才能要求 Store、插件目录和恢复扫描完成；
当前 M1.2/M1.3 的 `ready` 只表示最小 desktop Core/HTTP/WS 测试路径已经绑定；即使显式
启用了模板夹具，也不表示 Runtime Store、插件目录扫描、安装恢复或生产插件生命周期完成。
