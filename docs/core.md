# MgRead 核心规范

状态：唯一跨模块开发规范。复核日期：2026-08-26。

本文件只保存跨多个文件或 package 的稳定边界。AI 不得默认全文读取：先查看目标文件头、最近的
`AGENTS.md` 和相关测试，再由[最小路由](development/README.md)打开本文件的一个目标章节。
单文件职责、协作者、IO、状态所有权、生命周期和局部 TODO 必须写在对应源码文件头，不复制到文档。

## 决策与范围

- 指令优先级：用户当前要求 → 本核心规范 → 最近的 `AGENTS.md` 增量 → 代码公开契约与测试。
- 架构变化直接修改本文件的最小章节，并同步公开类型、测试和调用方。历史原因由 Git 保存，不再
  新建成组 ADR、实现快照或阶段规划文档。
- `mg_read` 是唯一 Flutter 主应用；首发 Android、Windows、macOS，Android 优先。iOS、Linux、Web、
  账号、云同步、WebView 登录、DRM 和商店分发不在当前范围。
- 每个任务只完成用户指定切片，不顺手进入其他里程碑或未来能力。

## 仓库与所有权

```text
lib/                               Flutter 主应用
packages/mg_read_reader_ui/        novel_reader_ui 阅读器 package
packages/mg_read_audio_player/     独立音频播放器 package
packages/mg_read_video_player/     独立视频播放器 package
packages/mg_read_runtime/          Runtime Core、平台宿主和 Flutter Facade
templates/mg_read_plugin_template/ 官方空白 Node 插件模板
plugins/sources/                    真实数据源插件
```

- 依赖方向为 `app -> features -> core/shared`。feature 只消费窄端口；Widget 不直接访问网络、
  SQLite、文件、Runtime transport 或 Service Locator，也不在 `build()` 中发请求或写状态。
- 主应用只调用 Runtime package 的版本化强类型 Facade；不得创建 raw Client/DTO/WS/HTTP handler，
  也不得向 Runtime 注入主应用数据库、路径、Cookie、文件服务、callback、端口或平台通道。
- package 的公开入口是唯一跨边界入口；主应用不得深层导入 reader 或 Runtime 的 `src/`。

## 主应用持久化与 Content Library

- `AppPersistence` 为权威；metadata 版本、schema、JSON 和容器生命周期仅留在 core persistence。
- `ContentLibrary` 拥有书架、目录、正文、漫画文件、进度和书签；Runtime 不打开 SQLite 或获取内容路径。
- 书架唯一上限为 `bookshelfMaxItemCount`（100）；新增须在 metadata 事务内校验，超限抛
  `BookshelfCapacityExceededException`，更新不占名额。
- metadata、不可变正文对象和受控文件之间没有跨库原子事务：先写入并校验对象，再以 metadata
  revision CAS 切换引用；已提交 metadata 是故障恢复权威，无引用对象由有界 maintenance/GC 清理。
- metadata JSON 规范化、限制、版本和不可变语义由 core persistence 统一执行；仅有界小写入可 inline，
  超界与目录批次使用 worker。
- 目录刷新写 pending snapshot 后一次切换 active；使用稳定 ID 和 keyset cursor，不用 offset、页码、
  数组位置或全量内存载入作为持久权威。
- Runtime 结果经公开 Facade 和强类型 adapter 校验后才能入库；无公开协议时保持 `unsupported`，
  不得用 raw transport 或 `host.*` 回调补齐。
- 漫画正文图片缓存返回总量与按 `LibraryItemId` 的用量；无归属旧缓存只计总量。
- 发现页临时阅读会话退出即丢弃，不替代正式入库、目录、正文、进度和书签流程。
- 本地 `.mgread` v1 仅含所选 artifact、书架和进度；导入先预览选择，再复用 Runtime 校验与 Content Library 事务。

## Runtime 与平台宿主

- 每个应用进程只有一个 Node Runtime 和一个 V8 VM。禁止 Worker、插件子进程、第二 VM、Engine
  Pool、native addon 或自定义 VM/loader。
- Runtime package 独立拥有 Node Core、Android Javet、Windows/macOS 固定 Node 24 launcher、
  Supervisor、内部 WS 控制面/HTTP 数据面、Plugin API、安装执行、私有数据根、瞬时诊断和 Facade。
- Android 由一个专用线程持有一个 Javet `NodeRuntime`；desktop 只从 package 固定路径启动精确
  Node。Windows Job Object、macOS 签名/公证和 Android ABI 分平台验收，不能相互替代。
- Runtime 数据根只保存插件不可变安装版本、插件私有 data/cache、Cookie、临时资源和运行状态；
  不保存书架、目录、正文、进度或书签业务权威。
- installed 插件版本不可变且仅冷启动激活。Windows Debug 可直读工作区；指纹变化先回收旧 VM，
  再启动唯一新 Runtime，不热替换模块。
- 内部 WS/HTTP、ready、bootId、端口、PID、URL 和 envelope 不暴露给主应用。控制帧有界；大资源走
  Runtime HTTP 数据面，不进入无界 JSON/Base64。
- `browser.session.v1` 保留同源 HTTPS 与 64 KiB/2 MiB/1--120 秒边界；Cookie/UA 留在宿主，交互不用
  DOM 合成事件、value setter 或 CDP。
- `ctx.webview` 每源一页且 `open` 复用，无 `sessionKey`/`onUrlChanged`/Cookie API；支持导航、异步 JS/JSON、
  HTML、CORS `fetch`、原生输入、等待、URL 与显隐关闭。普通调用 FIFO、控制旁路；超时不毁页并撤销结果
  token。不用 CDP；Windows 允许 F12。
- Android/Windows 每插件一个 WebView（最多 8/16）；Android multi-profile 不可用时记录 `single_fallback`。
  `visible` 全局唯一；Windows 窗口标题显示来源/行为，页面内只显示 URL，用户关闭窗口只隐藏且仅脚本
  `close` 销毁。宿主阻止越界能力；Windows 静音，Android 暂仅禁止自动播放。
- Debug 检查页优先监听 `0.0.0.0:52173`，不可用时临时绑定系统端口；只持久化开关，返回实际地址和临时状态；Release 禁用。

## 标准插件项目、artifact 与安装

- 插件是可信 Node.js 24 项目；`package.json.mgread` 是唯一元数据，lockfile v3 是依赖图。开发使用普通
  `node_modules`/多文件 ESM；禁止 Git dependency、install script、native addon、第二 VM 或自定义协议。
- `mgread.packageMode` 为 `single-file|archive`，默认 `single-file`。single-file 使用精确
  `esbuild 0.28.2` 生成 Node 24 ESM，不 minify、不带 source map/时间戳，只 externalize Node builtin；
  unresolved/dynamic import、非 builtin external、Wasm/native/binary/sidecar 必须构建失败。
- single-file 名为 `<id>-<version>.mgplugin.js`，首行是版本化自描述信封，包含规范 descriptor、
  code 字节数/SHA-256 和可选内嵌图标；信封 512 KiB、图标 256 KiB、artifact 32 MiB 上限。
- 显式 archive 为确定性 `.mgplugin` ZIP，保留 package/lock/dist/assets/packages 和 lock 恢复语义。
  两种模式都不携带 `node_modules` 或源码，不运行 install script，不自动互相回退。
- `buildPluginArtifact({versionOverride})` 只返回内存 bytes/fileName/format，CLI 才写盘。Windows
  development 同步或本地导出先调用它；发送端校验形状/格式/大小并计算 SHA-256，接收端校验字节与摘要。
- 安装写入不可变版本目录并原子切换 pending；失败不破坏当前版本。archive 依赖按 lock/SRI 精确
  恢复，Runtime 不求解 SemVer、不运行 npm 生命周期脚本。
- 插件私有缓存只保存可重复 GET 展示投影：发现/搜索 10 分钟，详情/目录 1 小时；使用哈希键、原子
  写、single-flight、每项 1 MiB/每插件 100 MiB LRU。刷新失败可读 stale；不得缓存正文/媒体、登录
  数据、写响应或主应用业务数据，缓存失败视为 miss。

## 插件内容 API

- 中文统一称“数据源”；仅在 Node 项目、artifact、安装、启停、打包和 Runtime 生命周期中称“数据源插件”。
  英文 `source/plugin` 与普通“来源”字段保持既有契约。
- 调用链固定为 `discover/search -> contentId -> getDetail/getChapters -> chapterId -> getContent`；ID、cursor、
  target 是插件内稳定不透明值，URL、标题、数组位置和页码不得作主键。
- 必填身份/枚举缺失、null、空白或未知时拒绝；可空标量显式保留值或 `null`；`0` 不等于未知，集合始终
  为数组，Runtime 不修补缺键或空字符串。
- `discover` 仅返回 `tabs/section/group/contentCollection/categoryCollection/text/divider`。
  内容布局为 `featured/carousel/coverGrid/shelf/compact/ranking/list`，分类布局为 `grid/chips/list`；它们只
  表达内容语义，UI、主题、断点、尺寸和交互归宿主。`ranking` 仅兼容旧插件；新插件用 `compact` 和真实
  `rank/metric`。tab、section、category 的 `icon` 来自同一白名单；Runtime 校验、Flutter 映射，插件不得
  下发 UI 代码、码点或图标资源。续页只追加指定 collection，target/cursor 原样回传。
- 首页按真实来源区块组合，不建数据源 Flutter 专页。榜单、题材整行 `vertical`；`group.grid` 只排列真正
  并列的小面板，不给已有 surface 再套面板；`coverGrid` 列数和横向触摸/鼠标拖动策略归宿主。
- `searchSuggestions` 热门词必须来自来源；宿主不伪造，只有用户点击建议或提交才搜索。
- `getChapters` 返回完整有序且 ID 唯一的目录，最多 5000 章、2 MiB；站点分页由插件追完并去重。
- 小说为非 null `text` 和空 `pages`，漫画相反且 pages 有序非空；超限内容走资源数据面，不进控制面。
- `ctx.resource.proxy` 私有 request 最大 16 KiB；URL 仅 Runtime 内有效且最多 1024 个。resource 只接受
  GET、安全响应头和 8 MiB body；Flutter 不解析代理 URL，也不复刻来源请求、Cookie 或签名。
- Runtime 写 wire 前校验固定键、枚举、URL、时间、计数、唯一性和大小；无效结果统一为
  `plugin_invalid_response`，不记录原始对象或内容。
- 真实数据源插件按目标文件头 -> 最近 `AGENTS.md` -> 公开类型/fixture/contract -> 本节读取；仅新增 Runtime
  capability 再读宿主章节。固定 Node 下运行 `npm.cmd ci/test/run verify`；选择器变化加 `test:live`，Runtime
  变化加 `typecheck/test/check:no-native-addons`，并冷安装实际 `.mgplugin.js`/`.mgplugin` 验证激活。
- fixture 只保留触发选择器、分页、null/0/空集合和错误分支所需的最小脱敏 HTML；禁止保存线上正文、
  图片、Cookie、UA、token、完整录制或用户搜索词。更新 fixture 时记录来源 UUID/版本/散列和采集日期，
  先以网络 smoke 确认结构，再人工裁剪；网络失败不能用新 fixture 覆盖旧证据。
- CF 测试注入 `browser.session.v1` provider，覆盖 verified、`interaction_required`、`unsupported`、timeout、
  cancelled、超限和跨源拒绝，并断言插件请求不含 Cookie/UA。桌面浏览器通过仅是桌面证据；Android
  只有 packaged artifact 在授权设备上的 integration test 才算 Android 通过，两个平台不得互相替代。
- 失败诊断顺序为仓库映射/源版本 -> fixture 解析 -> capability mock -> artifact 信封与冷安装 -> 目标平台
  provider -> 真实网络。禁止写死临时 Cookie/UA、执行站点下发的非受控绕过脚本、记录挑战页内容、
  用桌面成功代替 Android，或把 `unsupported`/人工验证未完成写成来源通过。
- 2026-08-28 首批转换证据：已验证 repository 100 条中精确映射两条“第一版主”与 `写真集`、`写真集2`，
  四源离线 fixture/contract、single-file artifact 和 Runtime 冷激活通过；规则脚本中的选择器、分类及
  `diyibanzhu-me` 分页 ID 属规则证据/待线上复核；桌面 CF 人工完成、生产 host provider、Android 与
  真机均未验证。后续只在新证据上更新本段状态，不把推断提升为事实。

## 阅读器

- `novel_reader_ui` 只负责小说/漫画；音频与视频分别由 `mg_read_audio_player`、
  `mg_read_video_player` 独立维护。三个 package 不互相深导入，也不建立统一媒体模型、Controller 或 UI。
- 各 package 只拥有会话、交互、语义位置、生命周期和已实现平台能力；宿主提供纯业务数据、状态存储、
  路由及授权资源，不把网络鉴权、Cookie、数据库、下载、账号、支付或 DRM 下沉到 Widget。
- 主应用 adapter 提供纯业务数据和状态。文本锚点使用 `chapterId + paragraphId + characterOffset`；
  漫画使用 `chapterId + imageId + imageFraction`。页码/像素偏移不能成为持久权威。
- `ReaderObserver.onExitRequested` 只通知宿主，由主应用决定路由/确认。可选 capability 未注册时隐藏
  UI，不显示伪造状态。
- UI/分页不访问网络、数据库、文件或宿主 Service Locator；异步域使用请求世代/取消并有界缓存。
  设置、窗口、字体和方向变化后恢复语义位置，所有 Controller/Timer/句柄/常亮资源成对释放。

## UI、状态与组件

- 当前只开发和验收浅色模式；保留既有深色实现，不新增深色截图或 Golden。
- 页面只组合布局、状态和 feature 私有语义。复用顺序为同 feature 组件 → `shared/`；只有跨两个
  以上 feature 的无业务视觉/交互模式进入 shared。
- 全局视觉只通过 `AppTheme`、`AppThemeTokens`、`TextTheme`、`AppSpacing`、`AppRadii` 和既有
  Material/共享组件扩展；页面不建立平行颜色、字号、间距、圆角、阴影、按钮或图标规范。
- 组件接收不可变数据和显式回调，不用大量可选参数构造万能组件。加载、空、错、重试保持局部且
  可恢复；异步刷新保留稳定可见数据，过期结果或 dispose 后结果不得覆盖当前状态。
- 可见中文文案留在页面/局部组件，不新建集中多语言层。真实字段缺失时显示 `--` 或隐藏，不伪造
  API 数据或能力。

## 诊断

- App 诊断默认关闭；总开关由普通设置存储持有。显式启用才创建 writer；关闭从下次启动生效，
  使当前日志安全收尾。Runtime 只保留 Debug 启用窗口内的有界瞬时日志。
- 每个已启用的 App 启动只写一个 UTF-8 TXT，内存只持有当前启动目录。历史文件完全冷存储：
  启动不读取、修复、反序列化或重建历史；查看器只用文件名、mtime、length 列表，用户选择单个
  文件后才读取。损坏只隔离所选文件；删除和保留按文件元数据执行，当前文件只能在安全关闭时结束。
- 诊断字段和显式捕获字节原样保存，不识别、脱敏、投影或清洗。容量、时限和保留上限只是资源边界。
- App 用户操作/长任务只有一个 owner span 和一个终态：`success/error/cancelled/timeout/overloaded`；
  高频 frame、滚动、chunk 和条目只做有界聚合。Runtime/插件只写阶段、稳定分支、计数、字节、
  耗时和稳定错误码。
- 日志、viewer、observer、磁盘或缓冲失败不得改变业务结果。生产代码不得直接使用 `print`、
  `debugPrint`、`developer.log`、`console.*` 或自建日志文件；测试覆盖原样往返和失败隔离。

## 前台局域网同步

- 只支持 Windows/Android 前台、点对点、可信私有局域网会话；不提供后台、云端或加密承诺。UDP
  发现可回退手工 IPv4；二维码只携带版本化候选地址，不携带六位确认码。
- 发送方建立会话后显示六位码；接收方核对并确认连接，然后读取 manifest 并选择内容。书架项目和
  缺失/升级插件默认选中；相同或更高版本插件不可选。未选内容不得传输或写入。
- 同步只包含书架身份/展示信息/进度和缺失或升级插件；不包含离线正文、设置、书签、删除操作或
  Runtime/主应用路径。接收方逐本选择智能合并、采用发送端或保留本机。
- 会话 10 分钟、握手 30 秒、控制帧 64 KiB、manifest 1 MiB、chunk 256 KiB、插件 artifact
  32 MiB、单批最多 32 项或 512 MiB。帧强类型、版本化、有界；超限/截断/未知版本/顺序错误稳定失败。
- Windows Debug development 只在用户显式发送时由唯一 Runtime 调用可信构建工具生成内存临时
  artifact；手机按 installed 生命周期安装，不获得工作区路径或 development 加载模式。

## 验证与平台证据

- 根 Flutter 生产代码运行 `dart format --output=none --set-exit-if-changed .`、`flutter analyze` 和
  受影响测试；子项目只运行最近 `AGENTS.md`/README 的对应命令。每次代码修改还运行源码规模检查。
- 页面、路由和跨层真实流程只用 Android `integration_test`，交互经 Finder、语义和稳定 `Key`；
  禁止坐标、鼠标/键盘注入、`adb input`、系统截图、Computer Use 或人工点击取证。
- 只有用户对当前任务明确授权视觉/运行验收时才运行。获得任务授权后，connected/ready 的
  `emulator-5556` 是默认设备，仅可回退 `127.0.0.1:7555`；Agent 不得启动、创建、唤醒、关闭或重置。
- Android 截图只由 Integration Test 的 `takeScreenshot` 请求。Golden 只用于很小、隔离、确定性的
  浅色组件，不能证明页面、路由、Runtime、设备或发布包。
- 交付分开报告：格式/静态、自动化、真实运行、平台/真机、发布、日志/性能断言和未执行项。任何
  层级不能替代另一层；源码/Windows 证据不能扩张为 Android、macOS 或最终包证据。

## 文件、文档与版本治理

- 新建人工维护源码、脚本或可注释配置在文件头说明用途、职责和真实边界；只在存在真实待办时写
  TODO。首次修改缺摘要的旧文件时补齐；职责、IO/状态所有权、生命周期或 TODO 改变时同步更新,无待办的时候移除TODO。
- 只适用于一个文件的约束写入该文件注释；只适用于一个 package 的规则写最近 `AGENTS.md`；只有
  跨多个文件/package 的稳定规则才进入本核心规范。禁止为单页面、阶段交付或测试快照新增文档。
- 手写源码达到 700 非空行且本次修改时按职责开始拆分，1000 行为硬上限；遗留基线只能下降。
  禁止用 `part1`、`utils`、`helpers` 或按行移动规避。
- 根应用版本只在根 Flutter 生产代码、用户可见资源或 Android/Windows/macOS 发布配置变化后，
  于任务末执行一次版本脚本。纯文档、测试、工具、Runtime/reader package、模板和独立数据源插件不升级根版本。
- 文档任务运行 `tools/check_documentation.ps1`。`docs/` 只允许本核心规范、最小路由和入口；历史、
  实现快照、规划、重复 README 或单文件说明不再保留。
