# MgRead Agent 开发契约

本文件只保留所有任务都必须知道的硬约束。不要在开工时预加载全部架构、ADR、协议和子项目
文档；按下面的渐进式读取流程选择当前任务真正需要的材料。

## 指令优先级

发生冲突时依次采用：

1. 用户当前明确要求与已接受 ADR；
2. 本文件的跨仓库硬约束；
3. 当前目录最近的 `AGENTS.md` 增量规则；
4. [开发文档路由](docs/development/README.md)选出的专题规范；
5. README、实现说明、历史设计与测试证据。

已接受 ADR 不能由普通文档或实现静默推翻。需要改变决策时，新增替代 ADR，再同步专题、
公开契约、测试和索引。

## 渐进式读取流程

每个任务依次执行：

1. 检查当前分支、`git status --short` 和任务相关 diff，保护已有并发改动。
2. 打开 [docs/development/README.md](docs/development/README.md)，只选择与任务匹配的行。
3. 完整阅读该行的“必读”文件；只有跨越第二个边界时才增加另一行。
4. 需要改变架构决策时再读相关 ADR 全文；需要核对旧原因时才读标为“历史”的文件。
5. 修改后运行受影响层级的验证，并分别报告静态、自动化、运行、平台和发布证据。

禁止为了“了解项目”一次性读取整个 `docs/`、全部 ADR、全部 package README 或工具链自带
文档。文档总入口、状态和历史边界见 [docs/README.md](docs/README.md)，当前规划与证据快照见
[docs/planning/README.md](docs/planning/README.md)。

## 项目与平台边界

`mg_read` 是单一 monorepo，也是唯一 Flutter 主应用。固定布局：

```text
lib/                              Flutter 主应用
packages/mg_read_reader_ui/       novel_reader_ui 阅读器插件
packages/mg_read_runtime/         独立插件 Runtime 与 Flutter Facade
templates/mg_read_plugin_template/ 官方空白 Node 插件模板
plugins/sources/<source-id>/      实际标准 Node 书源
```

- 首版承诺 Android、Windows、macOS；Android 第一，Windows/macOS 第二。
- iOS、Linux、Web 不在当前承诺范围，不得为它们破坏首发平台。
- 新 Codex 任务在当前工作区直接修改，不建 worktree、第二份检出或嵌套 Flutter App。
- 子项目共享 Git 历史，但产品边界、公开 API、验证命令和发布证据独立。

## 不可违反的架构约束

- 每个应用进程只能有一个 Node Runtime 和一个 V8 VM。插件不得创建 Worker、子进程、第二个
  VM、Engine Pool 或原生 Addon。
- Android 的 Javet `NodeRuntime`、Windows/macOS 的固定 Node 24 子进程、Supervisor、内部
  WS/HTTP、ready/bootId/端口和平台打包全部属于 `packages/mg_read_runtime`。
- 主应用只调用版本化、强类型 Runtime Facade；不得创建 Runtime Client、raw protocol DTO、
  WebSocket/HTTP handler，或向 Runtime 注入数据库路径/连接、Cookie、文件服务、平台通道、
  callback、`HostPort` 或 `host.*`。
- 主应用 `AppPersistence` 是应用业务数据权威：metadata、Content Library 正文对象和受控
  文件对象均由主应用拥有。Runtime 不得打开主应用 SQLite 或获得绝对路径。
- Runtime 可在自己的数据根保存插件安装版本、插件私有 data/cache、Cookie、临时运行状态和
  Runtime 诊断；这些不能成为书架、目录、阅读进度、书签等主应用业务权威。
- Runtime 返回的插件结果只有经过公开 Facade 和主应用强类型 adapter 才能写入
  `ContentLibrary`。当前未发布的宿主提交/下载协议不得用 raw transport 或临时回调补齐。
- 插件使用标准 Node.js 24 项目：`package.json.mgread` 是唯一元数据，`package-lock.json` v3
  是唯一精确依赖图；不恢复 manifest、bundle、自定义 lock 或共享依赖协议。
- 插件使用 Node 标准模块解析和普通 `node_modules`；不运行 install script，不支持 Git/native
  addon，`file:` 依赖只能指向 `.mgplugin` 内部。插件更新只在下次应用进程冷激活。

## 主应用与阅读器边界

- 依赖方向为 `app -> features -> core/shared`。Widget 不直接访问网络、SQLite、文件、Runtime
  内部协议或 Service Locator，也不在 `build()` 发请求或写状态。
- feature 只消费自己的窄端口；Drift、schema、动态 JSON、容器生命周期只在 core persistence/
  content library 内部出现。
- 主应用只能导入 `package:novel_reader_ui/novel_reader_ui.dart`，严禁深层导入
  `packages/mg_read_reader_ui/lib/src/`。
- 阅读器插件只负责阅读体验，不联网、不内置业务数据库。主应用 adapter 向它提供数据和状态；
  进度与书签保存语义锚点，不用页码或像素偏移替代。
- `ReaderObserver.onExitRequested` 只通知主应用，由主应用决定路由或确认。
- 可见中文文案就地放在页面/局部组件；不建立集中多语言层。复用 `app/app_theme.dart` 的语义
  token，不在页面散落魔法颜色和尺寸。
- 异步提交前检查 mounted/请求世代或取消状态；Controller、监听器、FocusNode、
  ScrollController、Timer 和平台资源必须成对释放。

## 日志、隐私与可诊断性

- 全局诊断遵守 [ADR-0016](docs/architecture/adr/0016-segmented-text-diagnostics.md) 和
  [日志专题](docs/architecture/14-global-diagnostics-logging.md)：只持久化有界 UTF-8 分段 TXT，
  不创建日志 SQLite/WAL/二进制索引。
- 默认日志不得读取、构造、复制或保存 HTTP body、HTML、大 JSON、小说正文、图片内容、用户
  输入、书名/作者、Authorization、Cookie、token、credential、原始异常或绝对路径。
- 详情仅在显式、有时限/字节/来源 allowlist 的调试会话中惰性捕获；禁用时 supplier/getter/
  serializer 不得执行。日志失败或压力不得改变业务结果。
- 每个用户操作、跨边界调用和长任务只有一个 owner span：一个 start，恰好一个 success/error/
  cancelled/timeout/overloaded 终态。高频帧、滚动、chunk、条目只做有界聚合。
- 修改插件 capability 时，Flutter Facade、Runtime control、插件 invocation、插件 `ctx.log` 和
  `ctx.http` 必须保持同 trace 的可诊断链，并有 success 与适用的 timeout/cancel/error、secret/
  content canary 测试。插件禁止 `console.*` 或自行写日志文件。
- 新生产代码不得直接使用 `print`、`debugPrint`、`developer.log`、`console.*` 或自建日志文件。

详细事件矩阵、字段预算、性能基线和查看器规则不常驻本文件；只有诊断或关键链路任务才按开发
路由读取日志专题。

## 依赖、Git 与交付

- 新增依赖前查当时官方文档，说明必要性、精确版本、维护状态、Android/Windows/macOS 支持、
  许可证和包体影响。版本必须精确固定。
- 保留所有无关脏改动。禁止 `reset --hard`、restore/checkout 覆盖、`git add -A`、
  `git commit -a`；只处理和暂存任务拥有的文件或 hunk。
- 每次任务只完成用户指定交付包，不顺手进入后续里程碑或实现 WebView、账号、音视频等延期能力。
- 代码改动必须补充受影响层级测试。根项目至少执行：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

- 只改文档时不需要运行 Flutter/Node 业务测试，但必须执行链接、格式、引用和 diff 检查。
- 子项目命令按开发路由和其最近 `AGENTS.md` 执行；Runtime 的 Windows Node 命令必须使用项目内
  `tools/node-v24.16.0-win-x64`，不得回退到全局 Node。
- 只有用户明确授权视觉/运行验收时才启动应用或模拟器。Android 原生行为以真机为最终证据；
  Windows/macOS 只能在对应主机或 CI 声明完成。
- 交付报告分开列出：完成内容、静态检查、自动化测试、真实运行、平台/真机、发布证据、日志
  断言与未执行项。任何一层都不能替代另一层。
