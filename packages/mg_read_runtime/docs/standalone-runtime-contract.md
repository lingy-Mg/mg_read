# 独立插件运行时契约

## 状态与优先级

本文固定 `mg_read_runtime` 的目标职责。当前仓库已实现 **Windows desktop communication +
standard Node plugin slice**：固定 Node 24 child、stdout ready、loopback HTTP/WS、
Runtime-owned Flutter Facade、标准 package/lock 安装、依赖对象仓、冷加载以及插件列表、
发现、搜索、详情、目录和有界正文均已在当前 Windows x64 主机自动化测试。它不表示完整
Runtime Store、Android Javet、macOS
包集成或最终 Flutter 产品包已经验收，也不授权把 Runtime 代码放进主项目。

Runtime 平台/transport 边界由根 AGENTS、ADR-0001/0003/0004 与本文维护；业务数据所有权以
[ADR-0011](../../../docs/architecture/adr/0011-app-owned-versioned-persistence.md) 和
[ADR-0100](../../../docs/architecture/adr/0100-app-owned-content-library.md) 为准。ADR-0008 的
Runtime 业务 Store 结论已被取代；变更当前边界必须先新增替代 ADR。

## 产品定位

`mg_read_runtime` 是一个可独立运行的、完整的多平台插件运行时产品，不是要求
`mg_read` 主项目拼装的 Node Core。它必须能够在没有主项目数据库、路径、Cookie、文件
服务、平台通道、callback 或 `host.*` handler 注入的情况下，启动、恢复、加载并执行
插件执行和 Runtime 管理能力。

主项目只负责 UI、路由、主题、用户交互和阅读器视图宿主。它不应知道 Node/Javet、
子进程、端口、ready、bootId、WebSocket、HTTP、Runtime Store 或插件内部协议。

## 主项目唯一公开面

Runtime 发布版本化 Flutter-facing 集成包。其唯一高层模式是调用 capability：

```text
PluginRuntime.invoke<T>(PluginInvocation<T>) -> Future<T>
```

`PluginInvocation` 包含稳定的插件 ID、版本化 capability、强类型参数、取消语义和结果
类型。它可以表达插件管理、发现、搜索、详情、目录、诊断和资源访问；主应用书架、阅读状态
和 Content Library 经自身强类型端口持久化。下载跨边界能力需等待新 Accepted ADR。主项目
不得拼接 raw method 字符串或直接使用 wire envelope。

- 第一次 `invoke()` 自动完成启动、兼容检查、Runtime 自有操作数据恢复、内部 HTTP readiness
  和 WS hello。
- 资源结果以 Runtime 管理的强类型资源对象返回；主项目不构造/猜测 loopback URL、请求
  头、`bootId`、handle TTL 或 Range。
- Runtime 将稳定错误、进度和脱敏诊断投影为 Facade 类型；主项目不处理内部连接重试、
  端口、事件序号或进程状态机。
- 小说/漫画 `DataSource`、`StateStore` 和资源适配由 Runtime 的 Flutter 集成包发布，
  主项目只交给 `novel_reader_ui` 的公开 API。

这不是“把 `RuntimeClient` 换个名字”。公开 Facade 必须屏蔽所有平台和传输细节，不允许
以可选 `HostPort`、service locator、database/path 参数、callback 或 `host.*` 的形式
绕过边界。

## Runtime 必须完整拥有的组件

```mermaid
flowchart TB
    FACADE["Flutter-facing Runtime Facade"] --> SUP["Runtime Supervisor"]
    SUP --> DESKTOP["Windows/macOS bundled Node launcher"]
    SUP --> ANDROID["Android Javet Adapter"]
    DESKTOP --> CORE["Single Node VM Runtime Core"]
    ANDROID --> CORE
    CORE --> WIRE["Internal WS control + loopback HTTP data plane"]
    CORE --> STORE["Runtime operational data + resources"]
    CORE --> SDK["Plugin API / scheduler / ctx.http"]
    SDK --> PLUGIN["Trusted standard Node plugins"]
```

Runtime 仓库必须拥有并测试：

- Android Javet Adapter、专用线程、事件循环泵送、异常/关闭 watchdog；Windows/macOS
  固定 Node 子进程、允许列表环境、包内路径、签名/公证集成和启动/终止。
- 单 Node VM、标准 ESM/CommonJS 加载、Plugin API、`ctx.http`、有界调度、限流、取消、deadline、
  冷激活、更新、回滚和诊断。
- 内部 WS 控制面、loopback HTTP 数据面、ready/hello、资源句柄、Range、背压、重连
  和协议 fixture。它们是实现，不是主项目 API。
- `.mgplugin` 本地导入/官方仓库、package/lock/依赖校验、不可变版本目录和插件启停。需要用户交互的文件选择
  必须由 Runtime 的集成包实现，不由主项目提供服务。
- Runtime 自有受控数据根：插件安装版本、插件私有 data/cache、Cookie、临时资源、运行状态和
  诊断。主应用业务数据与 Content Library 不在此数据根。
- 下载 checkpoint、内容缓存和跨边界原子提交在新 Accepted ADR/Facade 契约完成前保持未实现
  或 `unsupported`，不能从旧 Runtime Store 规划直接恢复。
- 未来 WebView、通知、媒体和其他平台能力的 Runtime 自有实现，或明确、稳定的
  `unsupported`。未实现能力绝不反向要求主项目实现 callback。

## Runtime 自有数据与主应用业务数据

Runtime 是以下操作数据的唯一权威：

- 插件安装、版本、启用、待激活、回滚和诊断；
- 插件作用域 data/cache/KV、Cookie、临时资源和脱敏运行诊断；
- Node/Javet/desktop 生命周期、内部连接和当前启动周期状态。

主应用是书架、来源绑定、目录快照、正文/漫画对象、阅读进度和书签的唯一业务权威。Runtime
通过 Facade 返回强类型在线结果，主应用 adapter 决定提交；Runtime 不打开主应用数据库或
文件对象，主应用也不扫描 Runtime 数据根。Runtime/插件缺失时，主应用从自己的 Content
Library 提供已提交离线数据。

Runtime 操作数据后端不得使用 Node native addon，也不得复用主应用 Drift/SQLite。若未来
需要新的持久 Runtime capability，先记录数据所有权、跨平台、迁移、包体和恢复决策。

桌面 Node 通过 `--use-env-proxy` 采用 Runtime 显式允许的 `HTTP_PROXY`、`HTTPS_PROXY` 和
`NO_PROXY`；Windows 还读取用户 Internet Settings 的手工代理，不启动额外 helper 进程。PAC/
WPAD 必须按每个目标 URL 解析，尚未实现该 resolver 前不得将其错误降级成固定全局代理。

Runtime 诊断是上述业务 Store 选型之外的有界运行证据，并固定遵守主项目 ADR-0016：关键
事件只批量追加到 UTF-8 分段 `.txt`；不创建日志 SQLite/WAL/二进制索引。默认路径只记录
脱敏元数据，绝不读取或复制 HTTP body。只有显式调试会话命中 component/origin allowlist
时，JSON/HTML/文本详情才进入有界内存 spool；`memoryOnly` 在会话结束时清空，只有
`persistToText` 写入短期详情 TXT。查询只经版本化 Facade 返回 opaque ID/cursor/range。

## 不变量

- 每个应用进程只有一个 Node Runtime、一个 V8 Isolate/Context。插件不得创建 Worker、
  子进程、第二个 VM 或原生 Addon。
- Android 使用一个 Javet `NodeRuntime` 并由 Runtime 自有专用线程持有；Windows/macOS
  只启动 Runtime 包内、版本矩阵记录的精确 Node，不依赖用户 PATH 或全局 Node。
- Node/Javet/桌面 Node/协议/Facade 兼容矩阵整体升级；所有版本精确固定。
- 业务大资源只经过 Runtime HTTP 数据面，JSON/WS 不承载二进制或超限文本。
- 已加载插件仅在下次应用进程启动时冷激活；不得用 Runtime 热重启绕过该规则。
- 首版插件完全可信，但信任模型不允许放宽 archive/lock/SRI 校验、日志脱敏、输入上限、Plugin API 网络入口
  或有界并发。

## 未来能力扩展规则

新增能力必须遵循：

1. 在本仓库为 capability、参数、结果、错误和资源语义定义版本化公开类型。
2. 将所需平台实现、存储、隐私、生命周期和失败恢复放入 Runtime 内部设计与测试。
3. 用 Runtime Facade 发布该 capability 和脱敏投影；主项目只增加 UI 消费。
4. 若改变单 VM、平台承载、数据所有权、冷激活或传输边界，先在根架构集新增
   替代 ADR，并同步本文件、Schema、fixture 和两个 README。

禁止以“主项目已有 Flutter/原生能力”为由添加 callback、`HostPort`、`host.*`、数据库
路径或直接 platform-channel 注入。Runtime 无法独立实现的能力必须返回 `unsupported`，
直到 Runtime 仓库完成相应设计和平台实现。

## 当前 desktop/standard-plugin 验证边界

当前验证精确 Node/npm、TypeScript Core、npm 无原生 Addon 依赖，以及 Windows x64 上的
Flutter↔Node desktop bootstrap：Runtime-owned Facade 在 child 创建前持有 Windows
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` Job Object，启动固定 Node、解析 ready、通过内部 HTTP
readiness 与 WS hello，并在同一 WS 上调用 ping/list 和五个 `source.*.v1` 内容能力。控制面固定 64 KiB frame、256
在途请求、1 MiB 写侧队列、deadline best-effort cancel；超限大内容仍属于未来 HTTP 数据面。

Runtime 还验证标准 `package.json.mgread`、lockfile v3、确定性 `.mgplugin`、安全解压、registry
SRI、完整 package 资源、包内 `file:`、optional、dependency object store、hardlink/copy、
不可变版本、pending 冷激活、失败更新回退、卸载和 mark-sweep。Core 只从 Runtime-owned data
root 扫描插件；生产 Facade 不接受插件路径、package bytes、callback、host.*、主项目数据库/
路径/Cookie/文件/平台通道。Node 与 Flutter 测试共用
`protocol/fixtures/standard-node-plugin-v1.json`；公开 Flutter 面提供
`RuntimePingInvocation`、`InstalledPluginsInvocation` 与
`SourceDiscover/Search/Detail/Chapters/ContentInvocation`，不泄露
wire metadata。详见[桌面 Runtime 与标准插件闭环](desktop-runtime-bridge.md)。

它仍未证明：

- Android Javet 或任意移动端路径；本轮明确不测试移动端。
- macOS 执行、签名/公证，或最终 Windows/macOS 应用包内的 bundle locator/隐藏窗口；Windows
  asset staging 已实现，但最终应用包内启动尚未作为验收运行。
- 官方仓库下载/本地选择 invocation、大资源流、下载跨边界契约和正式阅读器入库适配。
- Android ABI 打包、macOS 签名/公证、最终应用集成或主项目 UI 行为。

后续实现每次都必须先运行固定 Node/npm 的 `npm ci`、`npm run typecheck`、`npm test` 与
`npm run check:no-native-addons`；触及 desktop Facade/transport 时还必须运行
`npm run test:flutter-desktop`。单独报告未运行的 Android/Javet、macOS 与最终发布包探针；
静态检查或 Windows 通信测试都不是完整独立 Runtime 验收。
