# AGENTS.md

本文件是 `mg_read` 主应用的长期开发契约。修改本仓库前必须完整阅读本文件；需求与本文件冲突时，先更新本文件并说明原因，再修改实现。

## 项目定位

`mg_read` 是 `novel_reader_ui` 的主 Flutter 应用，不是阅读器插件本体，也不是插件运行时。它拥有应用导航、主题、UI、用户交互、阅读器视图宿主、UI-facing 用例和应用权威持久化；Runtime 继续独立提供插件执行与平台运行时。阅读器体验由同级 `../mg_read_reader_ui` 插件提供。

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
- Android 的一个专用线程 Javet `NodeRuntime`、Windows/macOS 的固定 Node 24 子进程及其打包/生命周期全部由 `mg_read_runtime` 实现；本仓库不得创建任何 Javet/Node bridge、Supervisor 或平台 Runtime 适配。
- WS 控制面和 loopback HTTP 数据面是 Runtime 内部实现；本仓库不得创建 Runtime Client、WebSocket/HTTP handler、端口/ready/bootId 管理或 raw protocol DTO，只能调用版本化 Runtime Facade。
- 同级 Runtime 当前的 M1.2 desktop `RuntimePingInvocation` 仅是其仓库内的 Windows 通信
  证据（包括 Runtime-own Job Object、启动诊断和有界 WS 多路复用），不是本项目接入 Runtime
  或复制 transport 的许可；在完整 capability 发布前继续用 Facade 替身进行 UI 测试，绝不把
  其 test helper、Node 路径或 wire fixture 带入本仓库。
- 主应用 SQLite 是应用权威元数据来源，通用执行器、schema、容器迁移、备份恢复和生命周期只位于 `lib/core/persistence/`；feature 只能定义/消费窄端口并在 data 层映射。Runtime 不得打开主应用 SQLite 或获得路径/连接；未来需要持久化时只能经版本化强类型宿主能力提交，当前不实现 transport。
- Runtime Store 的可变业务字段使用按 `recordKind + scopeKind + formatVersion` 约束的版本化
  JSON；稳定 ID、关系、排序、主要状态、revision、大小/摘要等一致性字段保留为稳定骨架。
  动态 JSON 不得作为任意 Map 暴露给主项目，也不得承载正文、二进制、明文凭据或绝对路径。
- 主应用持久化使用稳定 envelope 与按 recordKind/scopeKind/formatVersion 注册的 JSON 文档；未知字段保留、null 与缺失不同、未来版本只读。正文、二进制/Base64、明文凭据和绝对路径禁止进入文档。独立 Store testkit 必须使用临时数据根，且不依赖 Widget、Node/Javet、网络或真实用户数据。
- 插件更新使用不可变版本目录并在下次应用进程启动时冷激活；不得在当前进程热替换插件或以重启 Runtime 绕过该限制。
- 插件格式由 ADR-0015 固定为标准 Node.js 24 项目：`package.json.mgread` 是唯一 MgRead
  元数据，`package-lock.json` v3 是唯一精确依赖图；禁止恢复 `manifest.json`、bundle、
  `sharedDependencies`、`bundledDependencies` 或自定义 dependency lock。
- Runtime 使用标准 Node 模块解析和普通 `node_modules`。共享依赖只能是 Runtime 内容仓的
  hardlink/copy 存储优化，不能成为插件可见协议；插件不运行 install script，不支持 Git/native
  addon，并且 `file:` 依赖只能指向 `.mgplugin` 内部。
- 首版不创建插件 VM/Context、自定义 ESM Loader 或模块隔离。插件是可信代码，可直接使用
  Node 的 `fs`、`process` 等标准能力；Worker/子进程仍不属于支持契约，可信模型也不构成沙箱。
- Runtime 在自身数据根内持久化的有界分段事件 TXT 与调试详情 TXT 只是可删除运行证据，
  不是主应用业务数据权威；日志不得使用 SQLite/WAL。这是日志架构的窄例外，不授权 Runtime
  获得主应用数据库/路径、保存书架等业务记录或把诊断文件路径暴露给主项目。

## 目录与依赖方向

新增代码按以下职责放置：

```text
lib/
  app/                        # 应用根、主题和路由
  core/persistence/           # 应用权威存储端口、容器与生命周期
  features/
    library/                  # 书架和书籍入口
    reader/
      application/            # 阅读器视图请求与用例编排
      data/                   # 消费 Runtime 发布的 DataSource / StateStore 公开适配器
      presentation/           # ReaderHostPage 等主应用页面
  shared/                     # 跨 feature 的组件和工具
```

依赖方向为 `app -> features -> core/shared`，feature 通过版本化 Runtime Facade 消费插件能力，并通过窄端口消费主应用持久化。阅读器 feature 可以依赖阅读器和 Runtime 的公开 API；Runtime/插件不得反向依赖主应用。Widget 不直接访问网络、SQLite、文件系统、Runtime 内部协议或 Service Locator，也不能在 `build()` 发起请求或写持久化状态。

## 阅读器集成规则

- Runtime 发布公开的小说/漫画数据源、状态存储和已实现 capability；主应用只把它们接入阅读器视图。阅读器插件不直接联网或内置数据库。
- 数据来源插件的入口是 `package.json.main` 指向的普通 ESM/CommonJS 文件，并通过命名导出
  `activate/search/getDetail/getChapters/getContent` 接入；TypeScript 只编译、不 bundle。
- 进度和书签必须保留插件定义的语义锚点，不用页码或像素偏移替代。
- 退出阅读器由 `ReaderObserver.onExitRequested` 通知主应用；由主应用决定 `Navigator`、确认弹窗或其他路由行为。
- 真实书源、插件数据、进度、缓存与下载必须在 `mg_read_runtime` 中实现，不能塞入 `ReaderHostPage`、feature/data 或 core。
- 新增 UI 依赖前先查阅当时的官方文档，并说明必要性、精确版本、维护状态、Android/Windows/macOS 支持和体积影响；不得借 UI 依赖引入 Runtime、Javet、Node、SQLite、文件传输或网络实现。
- 依赖必须固定精确版本。禁止加入未经审查的原生 Addon；如确有必要，先完成兼容性、安全和包体审查，并取得明确授权。

## UI、状态与安全

- 复用 `app/app_theme.dart` 的语义主题和集中尺寸；不要在页面散落独立视觉系统或魔法颜色。
- 可见中文文案直接定义在使用它的页面或局部组件内；当前不建立集中字符串层，也不考虑多语言资源。
- 不用全局单例保存当前用户、书籍、阅读进度或主题。状态边界要显式并可释放。
- 异步完成后更新页面前检查挂载状态；请求竞态使用请求世代或等价取消机制。
- 常规日志不记录正文、HTTP body、用户标识、鉴权信息、Cookie、令牌或数据库内容。默认未开启
  调试时，大型 JSON/HTML/小说正文和复杂对象不得被构造、复制、放入内存或写盘。只有用户从
  专用调试器显式开启、受时限/内存/磁盘配额和来源 allowlist 约束的本地捕获会话，详情才可
  先进入有界内存；只有会话选择保存详情时才异步写入独立 TXT。详情不得内联进事件或业务
  JSON，不得暴露绝对路径，Authorization/Cookie/token/credential 永不自动捕获，敏感详情
  默认不导出。错误应归一化为可行动的 UI 状态。
- Controller、监听器、FocusNode、ScrollController、Timer 和平台资源必须成对释放。

## 日志、Trace 与性能埋点硬约束

全局日志必须遵守 [14 全局日志与诊断数据系统](docs/architecture/14-global-diagnostics-logging.md)
和 [ADR-0016](docs/architecture/adr/0016-segmented-text-diagnostics.md)。日志统一持久化只允许
UTF-8 分段 `.txt`；不得创建日志 SQLite、WAL 或二进制索引。日志系统仍处于设计阶段时，
后续功能必须同时定义事件/schema/埋点位置；统一 API 落地后，新增或修改关键链路必须在同一
交付包补齐实现和测试。缺少所需日志能力时不得以 `print` 临时代替，也不得把功能声明为完整
可诊断；交付报告必须明确标为待日志门禁。

### “关键点”的判定

代码路径满足以下任一项就是关键点，不依赖开发者主观判断：

- 用户正在等待其结果，或失败会改变可见页面、可用数据、导航、阅读或恢复动作。
- 发生初始化、ready、状态迁移、提交、回滚、激活、关闭、取消、重试、超时或故障恢复。
- 跨越 Widget/application、Runtime Facade、Node/Javet、插件、HTTP、SQLite 或文件对象边界。
- 进入有界队列、竞争并发槽、等待锁/事务、触发背压、采样、丢弃、限流或断路。
- 执行网络、数据库、文件、解析、序列化、校验、摘要、解压、分页、渲染或其他可能成为
  性能瓶颈的工作。
- 分配/释放长生命周期资源，或出现内存、磁盘、WAL、队列、句柄、缓存和 worker 压力。
- 结果会被缓存、持久化、导出或在应用重启后恢复。

### 最低强制覆盖矩阵

- **应用与页面**：bootstrap 每阶段、前后台/退出、稳定 route 名切换、关键用户意图、首次
  可用内容、异步状态的 loading/success/empty/error/cancelled/stale-discarded；不记录路由
  原始参数、搜索词或用户输入。
- **Runtime Facade**：每次 capability 调用的排队、开始、完成、稳定错误、取消、deadline、
  重试和结果规模投影；主项目只记录门面层 span，不复制 wire/bootId/端口细节。
- **Runtime 与插件**：Node/Javet start/ready/failed/shutdown、插件加载/校验/调用/解析、调度器
  queue wait、并发槽、overload、watchdog 和恢复必须在 `mg_read_runtime` 记录；不得为打日志把
  Runtime 内部实现搬入本仓库。
- **HTTP**：request start、response headers、complete/error/cancel、queue/DNS/connect/TLS/
  TTFB/body/parse 可取得的阶段耗时、method、脱敏 origin/route、status、重定向、重试、缓存、
  Range、上传/下载字节和稳定错误码。body 仍只按显式捕获策略进入附件。
- **主应用持久化与内容对象**：open/close、schema/migration、query/write/batch/transaction、
  revision conflict、WAL checkpoint、备份/恢复、staging/摘要/原子提交、孤儿清理、损坏、
  磁盘满；只记录操作、数量、字节、耗时和结果，绝不记录 SQL 参数、行内容或路径。
- **书架、目录与阅读器**：书架/目录分页和刷新、来源切换、章节/图片获取、缓存命中、解析、
  reader launch、首屏、翻章、分页/布局、进度/书签提交和退出；只记录稳定技术 ID 的受控投影，
  不记录书名、作者、正文、语义锚点原值或图片内容。
- **下载、缓存与文件**：排队、开始/暂停/恢复/取消、Range 续传、进度时间窗、吞吐摘要、
  checkpoint、校验、原子完成、清理、配额和失败恢复；禁止每个网络 chunk 写事件。
- **未捕获错误与崩溃边界**：Flutter error、PlatformDispatcher/isolate error、Node fatal、
  Javet fatal、桌面 child 非预期退出和平台能力失败，至少记录脱敏 stack fingerprint、当前阶段、
  最近 trace、稳定错误码和恢复结果；原始堆栈、参数、路径和正文不得直接持久化。
- **日志系统自身**：writer 启停、队列高水位、批量大小/追加耗时、TXT 轮转/尾部恢复、丢弃/
  采样聚合、详情截断、retention、导出和故障必须可观测，但不得因记录自身故障形成递归日志风暴。

### Event/span 规则

- 每个用户操作、跨边界调用和长任务只有一个 owner span；必须写 start，并在 success/error/
  cancelled/timeout/overloaded 中恰好写一个终态。分阶段耗时使用 child span，不用多层重复记录
  同一条自由文本错误。
- event 名称使用稳定命名空间和独立版本；必须带 component、severity、trace/span 关系、
  outcome、duration，适用时带 queue wait、attempt、count/bytes、cache/retry 投影和稳定错误码。
- 错误由能够决定恢复语义的所有者记录一次；上层只在增加新语义时补充事件。取消、stale
  result 和预期 not-found 不冒充 internal error。
- 性能日志必须区分排队、实际执行、首结果/首字节和端到端耗时。超过可配置阈值时写
  `*.slow` 聚合事件，并在事件中记录阈值与平台/构建模式；阈值必须来自基线，不能散落魔法数。
- build/layout/frame、滚动、下载进度、网络 chunk、目录项和循环体等高频路径只做计数器、
  histogram 或时间窗摘要；禁止每帧、每像素、每条目或每 chunk 持久化一条日志。
- 指标标签必须低基数。traceId、URL、remote ID、书籍 ID、自由文本和异常文本不能成为指标
  label；需要关联时留在受控 event 字段中。

### 开发期默认与性能保护

- Debug/Profile 默认启用 `keyOnly/metadataOnly`：关键 `info`、所有稳定终态和性能摘要写入
  有界分段事件 TXT；`debug/trace` 按 component/显式调试会话临时开启。Release 保留 warn/
  error/fatal 和有界生命周期/健康摘要。任何默认模式都不得读取、缓存或保存 body。
- 日志调用先做 `isEnabled`，禁用时不得插值长字符串、抓堆栈、遍历对象或编码 JSON。caller
  只构造小 draft；详情必须以惰性 supplier/流提供，`shouldCapture` 为 false 时 supplier 不得
  执行。TXT 文件、递归脱敏和大 JSON 处理进入有界后台 worker。
- 日志队列满、磁盘满、writer 故障或附件截断时，业务请求、UI isolate 和 Node 事件循环优先；
  日志降级为合并 drop/pressure 事件，绝不能让业务失败或把队列改成无界。
- 新增生产代码不得直接使用 `print`、`debugPrint`、`developer.log`、`console.*` 或自行写日志
  文件。只有统一日志实现内部和统一 manager 建立前的最早 bootstrap fallback 可以使用受控
  stderr/console，并必须在 manager ready 后接管、归一化和停止 fallback。

### 测试与交付门禁

- 新功能设计/实现必须列出关键操作、event 名、schema 版本、owner、级别、字段、附件策略、
  采样/聚合方式和预期终态；新增事件进入 registry，不能临时拼自由文本名称。
- 受影响测试至少验证 success、error 和适用的 cancel/timeout/overload 事件，验证 trace/span
  关联、恰好一个终态、未来 schema 只读、日志失败不改变业务结果。
- HTTP、持久化、导出和动态详情测试必须放置 secret canary，并断言默认内存、事件 TXT、
  详情 TXT、preview、console 和默认导出均无 Authorization/Cookie/token/凭据/正文等禁止内容；
  还必须断言默认模式不会执行详情 supplier/getter/serializer。
- 性能关键改动同时报告日志关闭、默认 keyOnly 和显式详情捕获三组基线，至少包含 p50/p95/
  p99、吞吐、分配/峰值内存、队列高水位、drop 数、事件 TXT 与详情 TXT 增长；不能只证明
  “有日志”，还要证明日志
  开启后没有改变业务正确性或造成无界资源增长。
- 交付报告必须单列：新增/变更事件、实际覆盖的关键路径、执行过的日志断言/secret canary/
  性能基线、尚未覆盖的路径及原因。静态分析或普通业务测试通过不能替代日志验收。

## 平台与原生代码

- Android 常亮、生命周期和系统返回等阅读器原生能力由插件实现；主应用不复制其平台通道。
- 改动 Android、Windows、macOS、CMake、Gradle、Xcode 或原生配置时，需要同步静态审阅三个首发目标的影响；不要因为尚未支持的平台引入复杂分支。
- Android 真机是 Android 原生行为的最终人工验收入口；Windows 和 macOS 的运行、打包与原生行为只在对应主机或对应 CI 上声明完成。

## 工作流与验证

- 修改前检查 `git status --short`、相关实现和本文件；保留不属于当前任务的脏改动，绝不 reset、restore 或覆盖它们。
- 修改前同时确认当前分支、未提交修改和任务相关文件；并发任务产生的文件或 hunks 不属于当前任务，必须保留原状。
- 创建 Codex 新任务时一律在本仓库当前原工作区直接修改，不得创建 Git worktree、隔离分支工作区或第二份检出；如需改变此约束，必须先由用户明确要求更新本文件。新任务仍须先核对并保护原工作区已有的并发改动。
- 大型 UI 改动按“Runtime Facade 公开契约 → 纯 UI 逻辑与适配器 → UI → 静态检查”推进；平台 Runtime 改动必须转到 `mg_read_runtime`。
- 自动化测试按风险分层建设：Dart UI 纯逻辑、错误投影和 Facade 替身使用单元测试；关键状态与交互使用 Widget 测试；Runtime Facade 契约由 `mg_read_runtime` 维护；通信、资源流、恢复、存储和平台运行时只在 Runtime 仓库做集成或冒烟测试。Golden 仅在视觉规范稳定后按需启用。
- 新增或修改实现时必须同步补充并运行受影响层级的测试。Node Runtime、插件 API 与协议仓库执行各自的类型检查与自动化测试；不得以“当前没有测试目录”为理由长期跳过测试建设。
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
