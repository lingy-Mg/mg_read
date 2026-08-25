# MgRead Agent 开发契约

本文件只保留所有任务都必须知道的硬约束。不要在开工时预加载全部架构、ADR、协议和子项目
文档；按下面的渐进式读取流程选择当前任务真正需要的材料。

## Flutter 应用版本

- 版本维护在 `pubspec.yaml` 的 `version` 字段，不写入 `AGENTS.md`。
- 每次修改后执行一次 `pwsh -File tools/update_flutter_version.ps1 -ChangeType small`；大修改使用
  `large`。小修改递增 patch，大修改递增 minor 并将 patch 归零，build number 自动递增。
- 只读检查不升级版本，禁止手工改版本号。

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

## 文件头维护摘要

- 新建的人工维护源码、脚本或支持注释的配置文件，必须在文件开头使用该语言的文档注释写明：
  一句话用途、主要职责、关键边界/注意事项；存在真实待办时再写 `TODO`。Dart 库文件采用下面
  的形式，其他语言使用等价注释语法：

```dart
/// 书籍详情页面。
///
/// 职责：
/// - 展示书籍基本信息。
/// - 处理阅读、收藏、目录等操作。
///
/// 注意：
/// - 不要在 build() 中执行网络或磁盘 IO。
/// - 数据加载统一交给 BookDetailController。
///
/// TODO:
/// - 增加详情缓存。
library;
```

- 文件头是“当前事实摘要”，不是按日期追加的变更流水。后续修改文件职责、边界、关键协作者、
  IO/状态所有权或待办状态时，必须在同一任务中同步更新文件头；首次修改缺少摘要的旧文件时补齐。
- `TODO` 没有真实待办时写 `- 无。`；Dart 的 `library;` 只用于适用的库文件，
  `part of`、生成文件、vendored 文件、锁文件、二进制资源和 Golden 不强加文件头。
- Markdown 文档只维护稳定的核心框架、跨文件契约、决策、流程和证据，不复制单个文件已经说明的
  职责与实现细节。跨文件框架发生变化时同时更新文档与相关文件头；文件头不得推翻已接受 ADR。
  详细维护边界见 [文档维护规则](docs/development/documentation.md)。

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
  addon，`file:` 依赖只能指向 `.mgplugin` 内部。installed 更新只在下次 Runtime 冷激活；Windows
  Debug development 项目按 ADR-0019 直读工作区并在变更后有序重启唯一 Runtime。

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
- UI 开发先检索同 feature 的现有组件，再检索 `shared/`；页面只负责布局组合、状态接线与 feature
  私有语义，不复制已有卡片、列表项、筛选栏、操作、空/错/加载态或交互模式。相同的视觉和交互
  模式一旦会在两个以上 feature 使用，就抽为无业务依赖的 `shared/` 组件；只在单一 feature 内复用
  的组件留在该 feature。组件接收不可变数据与显式回调，禁止用一堆可选参数造“万能组件”。
- 全局风格只能由 `AppTheme`、`AppThemeTokens`、`TextTheme`、`AppSpacing`、`AppRadii` 和既有
  Material/共享组件表达；新增页面不得自行定义平行的颜色、字号、间距、圆角、阴影、按钮或图标
  规格。需要新视觉规则时先扩展全局语义 token/共享组件，并同步受影响页面保持一致。
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
- 新增或修改用户操作、异步加载、缓存、持久化、Runtime Facade 或后台任务时，必须同步接入或更新
  全局诊断：先复用/注册版本化 schema，再仅通过注入的窄 `DiagnosticsManager` 记录。非 Release 的
  VS Code Debug Console 只能由中心镜像自动输出人可读摘要，完整 envelope 仅在 TXT/查看器中保留，
  feature/Widget 不得自行写控制台。
  交付前必须有受影响链路的 span/终态、隐私 canary 和失败不影响业务的测试证据；完整步骤见
  [诊断接入规范](docs/development/diagnostics-instrumentation.md)。
- 修改插件 capability 时，Flutter Facade、Runtime control、插件 invocation、插件 `ctx.log` 和
  `ctx.http` 必须保持同 trace 的可诊断链，并有 success 与适用的 timeout/cancel/error、secret/
  content canary 测试。插件禁止 `console.*` 或自行写日志文件。
- 新生产代码不得直接使用 `print`、`debugPrint`、`developer.log`、`console.*` 或自建日志文件。

详细事件矩阵、字段预算、性能基线和查看器规则不常驻本文件；只有诊断或关键链路任务才按开发
路由读取日志专题。

## 依赖、Git 与交付

## 源码文件规模

- 手写源码按非空物理行统计：文件达到或超过 700 行后，只要本次任务修改该文件，实施者必须在同一任务中主动
  设计并开始按职责拆分；可安全完成的拆分必须完成，不能只记录“后续处理”。1000 行是硬上限。除非有可复核的
  性能、生命周期或语言可见性约束，否则不得继续增长；例外必须说明原因、保留边界和下一步拆分入口。
- 每次代码修改执行 `pwsh -File tools/check_source_file_sizes.ps1`。`tools/source_file_size_policy.json` 的
  遗留基线只能下降；新文件或已脱离基线的文件不得达到 1000 行。不得用无语义的 `part`、`utils`、`helpers`
  或按行分片规避规则；完整拆分原则见 `docs/development/source-file-governance.md`。
- 遗留基线只用于已存在且存在可验证 Runtime/性能/语言私有状态边界的协调器；必须配对
  `legacyRationale`，写明为什么当前不能安全拆开及下一次真实拆分入口。它不是永久白名单、不能增长、
  不能用于新文件，也不能替代职责拆分。
- 新建或按职责重构的 Dart library 文件，首段必须使用中文 `///` 模块说明，依次表达名称、职责、注意和
  TODO；说明后紧跟 `library;`，再写 import。职责说明必须可验证，注意项必须包含该模块实际的边界或异步/
  生命周期约束；没有已知待办时写 `TODO: - 无。`。`part` 与生成文件不新增此声明。TS/JS 等没有 `library;`
  语法的模块使用同等 JSDoc，不伪造 Dart 指令。

- 新增依赖前查当时官方文档，说明必要性、精确版本、维护状态、Android/Windows/macOS 支持、
  许可证和包体影响。版本必须精确固定。
- 保留所有无关脏改动。禁止 `reset --hard`、restore/checkout 覆盖、`git add -A`、
  `git commit -a`；只处理和暂存任务拥有的文件或 hunk。
- 每次任务只完成用户指定交付包，不顺手进入后续里程碑或实现 WebView、账号、音视频等延期能力。
- 真实应用/页面/跨层流程的自动化验收一律使用 Android `integration_test`；测试交互只能通过
  `WidgetTester` 的 Finder、语义和稳定 `Key` 驱动。禁止用鼠标坐标、键盘注入、`adb input`、
  `adb screencap`、Computer Use、桌面自动化或人工点击来操作或取证。ADR-0019 允许测试脚本仅用
  ADB 传输已验证的 `.mgplugin` 到 Debug 应用私有 inbox；这不是 UI 操作或截图通道。
- Android 测试目标必须由用户事先自行启动。`emulator-5556` 是后续 Android
  Integration Test 的默认已授权目标；只要它已连接且 ready，Agent 可直接使用它运行项目脚本，
  无需再次请求选择或授权。`127.0.0.1:7555` 与 `emulator-5556` 仍是仅有的允许目标；Agent 不得
  启动、创建、选择、唤醒、关闭或重置设备，也不得改用其他设备。未连接或未 ready 时停止 Android
  真实验收并如实报告。真实验收不得使用 Windows
  版本、`flutter run`、Windows 设备或桌面截图替代。
- 从 `tools/run_android_integration_tests.ps1` 启动真实验收。它只接受上述已连接且 ready 的目标，
  通过 `flutter drive` 运行 Integration Test，并在忽略的
  `artifacts/integration-tests/` 保存机器可读结果和由 `IntegrationTestWidgetsFlutterBinding`
  请求的截图。截图必须由测试中的 `takeScreenshot` 触发，禁止从操作系统截屏。
- `test/` 中的 Golden 仅可用于非常小、隔离、确定性的展示组件；它不是页面、路由、完整交互或
  Android 实际行为的验收，也不能代替 Integration Test。
- 当前 UI 阶段只开发、修复和验收浅色模式。深色/系统深色模式暂不完善、暂不验收，也不新增
  深色截图或 Golden；保留已有深色实现，不因浅色任务顺手修改它。所有当前 UI 的 Android
  Integration Test、截图和 Golden 基线均显式使用浅色主题。
- 代码改动至少执行下列静态检查；真实应用改动还必须在用户提供 Android 模拟器后执行对应的
  Integration Test：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
```

- 只改文档时不需要运行 Flutter/Node 业务测试，但必须执行链接、格式、引用和 diff 检查。
- 子项目命令按开发路由和其最近 `AGENTS.md` 执行；Runtime 的 Windows Node 命令必须使用项目内
  `tools/node-v24.16.0-win-x64`，不得回退到全局 Node。
- 只有用户明确授权视觉/运行验收时才运行 Integration Test；Android 实际测试默认使用已连接且
  ready 的 `emulator-5556`，并仅允许回退到同样已连接且 ready 的 `127.0.0.1:7555`。Windows/macOS 的运行验收只能在用户另行授权时由对应主机或 CI
  声明完成，绝不作为 Android 实际测试的替代。
- 交付报告分开列出：完成内容、静态检查、自动化测试、真实运行、平台/真机、发布证据、日志
  断言与未执行项。任何一层都不能替代另一层。
