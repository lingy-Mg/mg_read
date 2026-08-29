# mg_read_runtime

状态：package 入口与实现快照。复核基线：`59a279b`（2026-08-26）；之后提交和未提交工作区必须
从代码、测试和平台证据重新确认。

MgRead 的独立插件运行时。它拥有平台 Runtime、单 Node.js 24 VM、标准 Node 插件安装与执行、
内部 HTTP/WS、Runtime 数据根和唯一 Flutter-facing Facade；`mg_read` 主项目只调用版本化
`PluginInvocation`，不接触 Node/Javet、路径、端口或 wire DTO。

```text
mg_read UI
  -> PluginRuntime.invoke(...)
  -> Runtime-owned Supervisor
  -> one Node.js 24 Runtime
  -> standard Node plugin projects
```

正式边界见[独立插件运行时契约](docs/standalone-runtime-contract.md)，插件格式由主项目
[核心插件规范](../../docs/core.md#标准插件项目artifact-与安装)固定。

## 当前实现

- Windows x64 desktop Supervisor 使用固定 Node 24.16.0、loopback ready/HTTP/WS、单进程
  多路复用和 Runtime-owned Job Object；关闭 owner 时由内核清理 Node 进程树。
- `packages/mgread_plugin_runtime` 公开 `RuntimePingInvocation`、`RuntimeStatusInvocation`、
  `InstalledPluginsInvocation`、`SetPluginEnabledInvocation` 与
  `SourceDiscover/Search/Detail/Chapters/ContentInvocation`；生产
  构造器不接受 Runtime 路径。
- 插件是 `package.json.mgread` + `package-lock.json` v3 的标准 Node 项目，入口为普通多文件
  ESM/CommonJS；Runtime 不创建插件 VM 或自定义 Loader。
- `.mgplugin` 是确定性 ZIP。安装器验证路径和大小、恢复 lock 已确定的 `node_modules`、验证
  registry SHA-512 SRI、保留 package 内 JSON/Wasm/字典，并支持包内 `file:./packages/...`。
- 相同 registry 对象进入 `dependencies/objects`；插件目录优先 hardlink，失败逐文件 copy。
- 版本不可变；安装写 `pending`，下次 Runtime 冷启动切换。失败更新保留旧 `current`；卸载和
  dependency mark-sweep 也只由 Runtime 执行。
- Runtime Core 在 ready 前扫描插件，并公开内部 `plugins.list.v1`、`plugins.setEnabled.v1`、
  `plugins.cache.usage/clear/clearAll.v1` 与五个 `source.*.v1`
  内容能力；Flutter Facade 对书名、作者、字数、更新时间、最新章节、URL、递归发现组件、目录和正文
  等字段做强类型投影与显式 null 校验。
- Runtime 关键事件使用 4 MiB 分段 UTF-8 TXT；HTTP/JSON/HTML 详情默认完全不读取，仅在
  显式调试会话中经过有界内存 spool，并按 `memoryOnly/persistToText` 策略保留。
- Windows Debug 直接加载工作区中的爱丽丝书屋与纯离线“发现组件演示数据源”；后者覆盖全部受控
  节点、嵌套分类、返回栈与集合定向分页。开发项目不进入 Flutter assets 或安装树。

旧 manifest、单文件 bundle、`sharedDependencies`、自定义 dependency lock、旧模板夹具和
测试专用模板 RPC 已删除且不提供兼容读取。

当前不应扩张为已完成的范围：Android Javet、macOS 包内 Node、官方 registry 下载/导入
capability、大资源 HTTP、下载跨边界契约和最终应用包验收仍待后续交付。主应用业务
Persistence/Content Library 不属于 Runtime 待办。

## 固定工具链

| Component | Exact version |
| --- | --- |
| Javet Android coordinate | `com.caoccao.javet:javet-android:5.0.8` |
| Javet/desktop Node | `24.16.0` |
| npm | `11.13.0` |
| TypeScript | `5.9.3` |
| `@types/node` | `24.13.3` |
| Internal protocol marker | `1.0` |

本仓库命令必须使用 `tools/node-v24.16.0-win-x64` 中的 Node/npm；`.npmrc` 会拒绝漂移的
engine。版本与平台证据见[版本矩阵](docs/runtime-version-matrix.md)。

## 验证

```powershell
$env:PATH = "$PWD\tools\node-v24.16.0-win-x64;$env:PATH"
npm.cmd ci
npm.cmd run typecheck
npm.cmd test
npm.cmd run check:no-native-addons
npm.cmd run test:flutter-desktop
npm.cmd run stage:flutter-windows
```

- `npm test` 覆盖 standard package/lock、archive traversal、SRI、完整依赖资源、`file:`、
  optional、hardlink/copy、冷激活/失败回退、取消/超时、卸载和 mark-sweep，以及 desktop
  HTTP/WS Core。
- `test:flutter-desktop` 从 Runtime-owned Flutter package 启动真实 Node，验证 singleton、
  Job Object、list/discover/search/detail/chapters/content、错误投影与并发复用。
- Debug 日志测试覆盖原值保留、有界内存、分页、清空和不创建 `runtime/diagnostics`；Runtime 不再
  维护结构化事件 writer 或对应性能基准。
- `stage:flutter-windows` 只准备 Node、LICENSE 与编译 Core，不打包/复制开发数据源插件，也不替代最终
  应用包运行验收。

## 目录

| Path | Responsibility |
| --- | --- |
| `src/plugin-package.ts` | 标准 package/lock 校验与精确依赖投影 |
| `src/plugin-archive.ts` | 确定性 `.mgplugin` 创建与安全解压 |
| `src/dependency-store.ts` | SRI 内容仓、tar 恢复、hardlink/copy |
| `src/plugin-installer.ts` | 不可变安装、pending、启停/卸载、mark-sweep |
| `src/plugin-manager.ts` | 冷启动加载、标准 Node 模块、调用与 MgRead context |
| `src/desktop-runtime.ts` | Runtime-owned HTTP/WS Core 与 capability dispatch |
| `packages/mgread_plugin_runtime/` | 唯一公开 Flutter Facade 和真实 desktop 集成测试 |
| `protocol/fixtures/standard-node-plugin-v1.json` | Node/Flutter 共享的当前标准插件 fixture |
| `test/fixtures/standard-plugin/` | Runtime 自有无网络标准项目测试件 |
| `probes/` | 工具链、原生依赖和性能探针 |

官方模板位于 monorepo 的 `../../templates/mg_read_plugin_template`，不嵌入 Runtime 包。模板只依赖公开
Node/MgRead 契约，Runtime 测试不通过任意模板路径注入生产启动流程。
