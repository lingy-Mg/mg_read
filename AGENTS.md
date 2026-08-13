# AGENTS.md

本文件是 `mg_read` 主应用的长期开发契约。修改本仓库前必须完整阅读本文件；需求与本文件冲突时，先更新本文件并说明原因，再修改实现。

## 项目定位

`mg_read` 是 `novel_reader_ui` 的主 Flutter 应用，不是阅读器插件本体。它拥有应用导航、书架、插件系统、书源适配、持久化和未来业务能力；阅读器体验由同级 `../mg_read_reader_ui` 插件提供。

- 首版承诺平台为 Android、Windows 和 macOS，优先级为 Android 第一、Windows/macOS 第二。
- iOS、Linux 和 Web 不属于当前承诺支持范围；不得为它们破坏 Android、Windows 或 macOS 的实现边界。
- 本仓库根目录是唯一主应用，不再创建嵌套 `example/` 或第二个 Flutter App。
- 插件通过 `pubspec.yaml` 的本地 path 依赖接入。主应用只能导入 `package:novel_reader_ui/novel_reader_ui.dart`，严禁深层导入插件的 `lib/src/`。
- 系统架构、公开协议和已接受决策以 `docs/architecture/` 为唯一入口；改变已接受 ADR 必须新增替代 ADR，不能只改实现。

## 开工门禁与交付边界

- 修改代码、配置、架构文档或依赖声明前，必须完整阅读本文件、`docs/architecture/README.md`、任务相关架构专题及 `docs/architecture/adr/` 下相关 ADR。
- 每个任务只完成用户指定的一个交付包；不得提前进入后续交付包。除非任务明确授权，不得顺手实现真实书源、音视频、WebView 或账号系统。
- 实现若与已接受 ADR 冲突，立即停止并说明冲突与可选方案；不得静默更换引擎、增加 VM、改变数据库所有权或修改通信协议。需要改变决策时，先新增替代 ADR，并同步相关专题、协议、测试和 README。

## Runtime、通信与数据硬约束

- 每个应用进程只能有一个 Node Runtime 和一个 V8 VM；插件不得创建 Worker、子进程、第二个 VM 或原生 Addon。
- Android 使用一个位于专用后台线程的 Javet `NodeRuntime`；Windows/macOS 使用应用捆绑、固定精确版本的 Node 24 子进程。
- Flutter 与 Node 的业务通信只能使用 WS 控制面和 loopback HTTP 数据面；stdio/管道只可承担启动生命周期、结构化日志和 `ready`，不能承载业务数据。
- Flutter 数据库是业务权威；Node 不得取得数据库路径、打开或直接修改数据库，只能通过强类型反向宿主调用提交必要状态。
- 插件更新使用不可变版本目录并在下次应用进程启动时冷激活；不得在当前进程热替换插件或以重启 Runtime 绕过该限制。

## 目录与依赖方向

新增代码按以下职责放置：

```text
lib/
  app/                        # 应用根、主题、路由和集中可见文案
  core/                       # 与业务 UI 无关的基础能力
  features/
    library/                  # 书架和书籍入口
    reader/
      application/            # 插件接入请求与用例编排
      data/                   # TextReaderDataSource / StateStore 宿主适配
      presentation/           # ReaderHostPage 等主应用页面
  shared/                     # 跨 feature 的组件和工具
```

依赖方向为 `app -> features -> core/shared`。阅读器 feature 可以依赖插件的公开 API；插件不得反向依赖主应用。Widget 不直接访问网络、数据库、文件系统、Runtime 或 Service Locator，也不能在 `build()` 发起请求或写持久化状态。

## 阅读器集成规则

- 主应用实现公开的小说/漫画数据源、状态存储和可选 capability；阅读器插件不直接联网或内置数据库。
- 进度和书签必须保留插件定义的语义锚点，不用页码或像素偏移替代。
- 退出阅读器由 `ReaderObserver.onExitRequested` 通知主应用；由主应用决定 `Navigator`、确认弹窗或其他路由行为。
- 真实书源、用户状态和缓存必须在 feature/data 或 core 中实现，不能塞入 `ReaderHostPage`。
- 新增依赖前先查阅当时的官方文档，并说明必要性、精确版本、维护状态、Android/Windows/macOS 支持和体积影响；优先使用 Flutter/Dart 标准能力。
- 依赖必须固定精确版本。禁止加入未经审查的原生 Addon；如确有必要，先完成兼容性、安全和包体审查，并取得明确授权。

## UI、状态与安全

- 复用 `app/app_theme.dart` 的语义主题和集中尺寸；不要在页面散落独立视觉系统或魔法颜色。
- 可见中文文案集中在 `app/app_strings.dart` 或未来本地化资源中。
- 不用全局单例保存当前用户、书籍、阅读进度或主题。状态边界要显式并可释放。
- 异步完成后更新页面前检查挂载状态；请求竞态使用请求世代或等价取消机制。
- 不记录正文、用户标识、鉴权信息、Cookie、令牌或数据库内容。错误应归一化为可行动的 UI 状态。
- Controller、监听器、FocusNode、ScrollController、Timer 和平台资源必须成对释放。

## 平台与原生代码

- Android 常亮、生命周期和系统返回等阅读器原生能力由插件实现；主应用不复制其平台通道。
- 改动 Android、Windows、macOS、CMake、Gradle、Xcode 或原生配置时，需要同步静态审阅三个首发目标的影响；不要因为尚未支持的平台引入复杂分支。
- Android 真机是 Android 原生行为的最终人工验收入口；Windows 和 macOS 的运行、打包与原生行为只在对应主机或对应 CI 上声明完成。

## 工作流与验证

- 修改前检查 `git status --short`、相关实现和本文件；保留不属于当前任务的脏改动，绝不 reset、restore 或覆盖它们。
- 修改前同时确认当前分支、未提交修改和任务相关文件；并发任务产生的文件或 hunks 不属于当前任务，必须保留原状。
- 大型改动按“领域/公开契约 → 纯逻辑与适配器 → UI → 原生 → 静态检查”推进。
- 自动化测试按风险分层建设：Dart 纯逻辑、领域规则、数据库迁移和 Repository 使用单元测试；关键状态与交互使用 Widget 测试；跨 Dart/TypeScript 协议使用共享 Schema 与固定 fixture 的契约测试；通信、资源流、恢复与平台运行时使用集成或冒烟测试。Golden 仅在视觉规范稳定后按需启用。
- 新增或修改实现时必须同步补充并运行受影响层级的测试。Node Runtime、插件 SDK 和协议仓库执行各自的类型检查与自动化测试；不得以“当前没有测试目录”为理由长期跳过测试建设。
- 每次修改至少执行以下静态检查：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
```

- 存在 Dart/Flutter 测试资产时还要执行 `flutter test`；只运行与任务相关的 Node、契约、集成、平台冒烟或构建命令，不用构建替代测试，也不用自动化测试替代人工运行验收。
- 用户明确授权视觉验收时，才可运行 Android 模拟器、Windows 或 macOS 应用进行人工交互检查；准确区分静态检查、自动化测试、桌面运行验收和 Android 真机原生验收。

## 交付要求

- 每次完成一个任务后，重新检查工作区和 diff，只暂存并提交当前任务拥有的文件或 hunk；不得使用 `git add -A`、`git commit -a` 或任何会吸收并发改动的提交方式。
- 若同一文件含有其他任务的并发 hunk，使用精确路径或 hunk 暂存仅提交本次修改；无法可靠拆分时忽略该文件的非本次修改并报告，不覆盖、不回退也不代为整理。
- README 与目录/接入方式保持同步；不要求后续开发者阅读插件私有源码才能接入。
- 交付时明确已完成项、已执行验证、未执行验证及其原因。
