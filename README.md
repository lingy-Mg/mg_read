# mg_read_runtime

MgRead 的**完整独立插件运行时**。本仓库最终拥有多平台 Runtime 承载、Node Runtime
Core、Flutter-facing Runtime Facade、内部协议、Runtime Store、插件 SDK、插件生命周期
以及共享 Schema/fixture；`mg_read` 主项目只消费版本化 capability，不注入或实现
Runtime 细节。

正式职责见 [独立插件运行时契约](docs/standalone-runtime-contract.md)。它与主项目的
[ADR-0008](../mg_read/docs/architecture/adr/0008-standalone-plugin-runtime-boundary.md)
共同固定以下边界：

```text
mg_read UI -> PluginRuntime.invoke(PluginInvocation) -> mg_read_runtime
```

主项目不得接触 Javet、Node 子进程、端口、ready、bootId、WS、HTTP、Runtime Store、
Cookie、文件、`host.*` 或任何 HostPort/callback 注入。

## 当前 M1.3 状态

M1.2 已实现并在当前 Windows x64 主机测试一条最小的**桌面 Runtime 通信闭环**；M1.3 在
此基础上增加一个只供本仓库验收的**空白插件模板双向夹具**：

- 随 Runtime 仓库提供的精确 Node 24.16.0 启动单个 desktop Core；Core 只绑定
  `127.0.0.1:0`，经 stdout `ready`、内部 HTTP health 与 WS `runtime.hello` 完成门禁。
  Windows Supervisor 在创建 child 前先持有带 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的
  Runtime-owned Job Object；Flutter 进程退出或受控关闭时，内核会终止已加入 Job 的 Node
  和其后续后代进程。
- Runtime 自有 Flutter 包 `packages/mgread_plugin_runtime` 将内部路径封装为
  `PluginRuntime.invoke(PluginInvocation<T>)`；生产 `PluginRuntime()` 当前只有诊断性
  `RuntimePingInvocation`，不暴露端口、PID、bootId 或 raw wire protocol。缺 Node、缺主脚本、
  拉起失败、无效 ready、HTTP readiness 失败和 Node 结构化 fatal 都投影为稳定错误码与有界脱敏
  诊断。
- Node 单测与真实 Flutter↔Node 集成测试共同读取同一 fixture，并验证生产 Facade 的
  process-wide singleton 与 128 路并发调用只启动一个 Runtime 子进程。控制 WS 使用一条
  多路复用连接、256 个在途请求上限、1 MiB 写侧背压队列和 deadline 后的 best-effort cancel；
  大资源仍只走 loopback HTTP。
- `templates/mgread-plugin-template` 是可整体复制的空白 TypeScript 插件项目。它没有书源、
  网络、文件、Cookie、数据库、Worker、子进程或主项目 callback；唯一代码样例通过
  `context.runtime.request('runtime.template.context')` 证明“Runtime → 插件 → Runtime”
  往返。Flutter 测试以 `desktopForTesting(enableTemplatePluginFixture: true)` 显式启用
  固定的仓库内模板，并检查回包和脱敏日志链。该开关没有插件路径或任意对象参数；生产
  `PluginRuntime()` 不传它，也不加载任何模板。

Windows 发布前由 Runtime 仓库运行 `npm run stage:flutter-windows`，把完整的固定 Node
24.16.0 distribution 与编译后的 `dist/` 复制到 Flutter package 自身的 asset 布局。`mg_read`
不参与该脚本、不会提供 Node 路径或启动代码。该 staging 流程已在源码仓库检查，尚未构成
最终 Windows 应用包内运行验收。

这不表示通用插件系统、ZIP 安装、官方仓库、任意 ESM 加载、业务 RPC、HTTP 资源服务、
Runtime Store、阅读器适配、Android Javet、macOS bundle/signing 或最终应用包集成已经实现。
移动端在本轮不测试。细节和证据边界见[桌面 Runtime 通信闭环](docs/desktop-runtime-bridge.md)
与[空白插件模板](docs/plugin-template.md)。

## 目标 Runtime 责任

- Android Javet Adapter、Windows/macOS bundled Node launcher、Runtime Supervisor、
  生命周期、启动/关闭/恢复和平台打包。
- 单 Node VM Runtime Core、ESM 插件、SDK、`ctx.http`、调度、取消、诊断、冷激活与回滚。
- 内部 WS 控制面、loopback HTTP 数据面、资源句柄、Range、背压、ready/hello 和协议 fixture。
- Runtime Store：插件状态、书架、目录、进度、书签、下载、内容/缓存文件、Cookie、KV、
  设置和脱敏诊断。
- 唯一公开 Flutter-facing 门面：强类型 `PluginRuntime.invoke(PluginInvocation)`；首次调用
  自动完成初始化，资源和错误均以版本化类型返回。

未来文件选择、WebView、通知、媒体或其他平台能力必须在本仓库实现并作为 capability
发布；不得要求主项目提供 callback、数据库路径、Cookie、文件服务或平台通道。

## Fixed baseline

| Component | Exact version |
| --- | --- |
| Javet Android coordinate | com.caoccao.javet:javet-android:5.0.8 |
| Javet-carried Node | 24.16.0 |
| Desktop bundled Node | 24.16.0 |
| npm bundled with that Node release | 11.13.0 |
| TypeScript | 5.9.3 |
| Node type declarations | @types/node 24.13.3 |
| Protocol marker | 1.0 |

Detailed evidence, ABI support, lifecycle API boundary, upgrade rules, risks and
pending probes are in [docs/runtime-version-matrix.md](docs/runtime-version-matrix.md).

## Local verification

Use exactly Node 24.16.0 and npm 11.13.0. The checked-in `.npmrc` enables strict
engine enforcement; every validation script first asserts both active toolchain
versions so a different Node resolved from PATH fails early.

~~~
npm ci
npm run typecheck
npm test
npm run check:no-native-addons
npm run test:flutter-desktop
npm run stage:flutter-windows
~~~

`npm test` 会先对 `templates/mgread-plugin-template` 执行独立类型/单元测试，再执行 Node
Core 合约测试；`npm run check:no-native-addons` 同时审计根项目和模板的 npm 依赖树。Javet 的
Android shared libraries 是平台产物，不是 npm dependencies。`test:flutter-desktop` 从
Runtime-owned Flutter package 实际启动 Node 并完成模板往返；`stage:flutter-windows` 是发布
资产准备步骤，不替代测试。当前 Windows 主机已验证该源码闭环；它仍不建立 Android Javet、
macOS 执行/签名、最终桌面包内路径、Runtime Store 或产品插件能力验收。

## Layout

| Path | Current M1.3 responsibility | Target ownership |
| --- | --- | --- |
| `src/` | Version metadata、desktop Core、HTTP/WS 最小内部协议与 CLI | Runtime Core |
| `test/` | Exact-Node ESM、loopback health 和 WS contract tests | Runtime unit/contract tests |
| `packages/mgread_plugin_runtime/` | Flutter-facing Facade 与 desktop Flutter↔Node integration test | Runtime package; never main-app transport code |
| `protocol/` | M1.3 desktop/template fixture; no business schema yet | Internal wire schema, Facade types and fixtures |
| `templates/mgread-plugin-template/` | 可独立构建、测试和复制的空白插件项目；仅在测试开关下被固定路径加载 | Official template source and Runtime-owned fixture |
| `probes/` | Npm native-addon audit and platform probe plan | Independent Runtime/platform gates |
| `docs/` | Version selection and future probe evidence | Standalone Runtime contract and lifecycle evidence |

Future Flutter integration packages, Android/desktop adapters and Runtime Store
remain in this repository. Do not move them into `mg_read` to simplify an
individual feature.
