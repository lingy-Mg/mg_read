# 数据源两阶段测试流程

## 目标与边界

数据源验证分为两层，结论必须分别记录：

1. 开发阶段使用 `mg_read_source_testkit` 的纯 Node.js CLI，快速检查插件构建、公开导出、临时宿主和 live
   阅读链路。
2. 开发完成后启动 Windows Release App 的正式 CLI，经生产 `SourceContentGateway -> Runtime Facade ->
   Runtime -> 已启用插件` 检查实际宿主行为。

Node 层不依赖 Flutter、PowerShell 脚本或 Runtime 私有实现；App 层不是 `flutter test` 或
`integration_test`。

## 阶段一：纯 Node.js 轻量测试

从仓库根目录直接使用固定 Node，不创建 `.ps1`/`pwsh` 包装：

```text
packages\mg_read_runtime\tools\node-v24.16.0-win-x64\node.exe --use-env-proxy packages\mg_read_source_testkit\bin\mgread-source-test.mjs --source aisishuwu --report artifacts\source-tests\node-aisishuwu.json
```

`--source` 接受来源目录名、`package.json` 名称或插件 ID。开发循环默认跑目标单源；测试库、公共 Source
契约或跨来源共用代码变化时追加全源：

```text
packages\mg_read_runtime\tools\node-v24.16.0-win-x64\node.exe --use-env-proxy packages\mg_read_source_testkit\bin\mgread-source-test.mjs --all --report artifacts\source-tests\node-all.json
```

CLI 默认执行每个来源声明的 `build`，再从 `dist` 检查：

- `package.json.mgread`、标准导出和可选 capability；
- 隔离的 `activate(ctx)`、缓存根、日志与资源代理登记，并模拟 `ctx.http.fetch` 的 Runtime 默认桌面 UA；
- 发现结果和最多六个发现 target；
- 从发现标题自动派生搜索词，再使用搜索首项完成详情和完整目录；
- 未锁定章节的首、中、末内容；
- 最多八个已登记封面、漫画或媒体资源的有界探测。

`test/acceptance.json` 的 `searchQuery` 只作无法从发现/建议派生查询时的后备，不得用固定 `contentId` 绕过
自动发现和搜索。`--skip-build` 只用于确认 `dist` 与源码一致时的重复诊断。测试库自身变化还要运行：

```text
packages\mg_read_runtime\tools\node-v24.16.0-win-x64\node.exe --test packages\mg_read_source_testkit\test\*.test.mjs
```

Node CLI 退出码：`0` 全部通过、`1` 已完成且存在来源失败、`2` 参数或启动失败。全源模式必须继续到最后一个
来源，不得在首错后停止。

## 阶段二：Windows 正式 App CLI

使用与交付版本一致的 Release 可执行文件。App、Runtime 或 Facade 变化后先重新构建：

```text
flutter build windows --release
```

插件开发完成后至少跑目标单源：

```text
build\windows\x64\runner\Release\mg_read.exe --source-check=org.mgread.aisishuwu --source-check-report=artifacts\source-tests\app-aisishuwu.json
```

测试库、Runtime 公共边界、宿主或跨来源逻辑变化时追加全部已启用来源：

```text
build\windows\x64\runner\Release\mg_read.exe --source-check-all --source-check-report=artifacts\source-tests\app-all.json
```

Windows Release 是 GUI 子系统进程，自动化调用不能依赖普通 shell 调用自然阻塞；使用
`Start-Process -WindowStyle Hidden -Wait -PassThru` 等待真实进程退出，再读取报告和 `ExitCode`。这只是调用
正式 CLI 的进程控制，不得替换成 Flutter 测试入口。

App 引擎顺序验证 Runtime 状态、发现、搜索、详情、完整且唯一有序的目录、首/中/末未锁定内容，以及 Runtime
代理后的封面/漫画/媒体资源。单源与全源页面复用同一生产引擎。退出码：`0` 全部通过、`1` 完成但包含失败
或取消、`2` 内部错误或报告写入失败、`3` 需要人工交互、`4` 参数错误或平台不支持。

## 判读与交叉验证

先看报告 `status/totals`，再按 `pluginId -> stages` 定位首个失败阶段。线上内容会变化，Node 与 App 的条目数、
目录数和耗时无需相等；插件 ID、阶段语义、稳定错误码和能否完成同一公开链路才是可比较证据。

- Node 和 App 同阶段失败：优先检查来源解析、网络状态或该阶段的公共返回值；用单源模式复现一次。
- Node 通过而 App 为 `invalid_format`：直接检查 Runtime 的公开校验限制，不能把 Node 通过当作宿主通过。
- Node 通过而 App 在 `resource.*` 失败：检查 `ctx.resource.proxy` 描述和 Runtime 数据面。
- Node 因 WebView/人工交互能力受限：记录 Node 能力边界，必须以 App CLI 的 `interactionRequired` 或实际结果
  完成验收，禁止绕过登录或挑战。
- 仅一次 live 失败而随后自动选择了不同内容：保留第一次报告，单源复跑一次确认波动；不得无限重试到通过。

验证测试框架本身时，应同时满足：测试库离线测试通过；一个已知健康来源在 Node/App 两层通过；全源模式在
存在失败时仍完成所有来源、总数正确并返回非零；两层对同一真实缺陷给出可解释的阶段差异。最终报告分别列出
Node、App CLI、Windows Release、未执行平台和所有仍失败来源，不把全源失败隐藏为“框架已通过”。
