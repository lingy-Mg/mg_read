# 0.4.0 开发指南

本文说明 `novel_reader_ui` 0.4.0 的开发流程、公共契约与宿主集成边界。根目录
`AGENTS.md` 是长期最高优先级契约；本文用于把 0.4.0 的实现约束整理为可执行的开发清单，
不得据此扩大插件的产品职责。

## 1. 产品边界

`novel_reader_ui` 是嵌入宿主应用的 Flutter 阅读器插件，不是内容平台。插件负责阅读会话、
正文或漫画画面的呈现、阅读位置、内部工具栏、设置、生命周期和受支持平台的常亮协调；
宿主负责内容来源与用户业务。

插件不得直接承担以下职责：

- 网络协议、请求签名、鉴权、Cookie、重试策略和代理配置。
- 书城、搜索、推荐、账号、会员、广告、支付、DRM 和内容审核。
- 文件下载、磁盘数据库、离线包、清理策略、云同步和用户身份映射。
- 评论发布、回复、点赞、举报或其他写操作。
- 未经许可的字体、插画、漫画或小说内容分发。

宿主失败应被转换为可恢复的 `ReaderFailure` 并通知观察器。正文、漫画或字体的局部失败不能
导致整个 Flutter 页面崩溃，也不能在日志中泄露正文、图片字节、用户标识或鉴权信息。

## 2. 目录与依赖方向

公共入口始终是 `lib/novel_reader_ui.dart`。仅被该文件导出的类型属于公共 API，`lib/src/`
中的其他符号均为私有实现；`example/` 只能从包入口导入。

```text
lib/
  novel_reader_ui.dart           公共导出入口
  src/
    api/                         不可变模型、数据源、状态仓库和控制器契约
    core/                        会话、异步世代、缓存、生命周期和错误归一化
    pagination/                  文本测量、分页边界和语义位置映射
    platform/                    Dart 平台抽象和常亮协调
    ui/                          阅读页、设置、评论、视觉 token 和效果
    comic/                       Comic* 独立运行时与 UI；不得继承文本模型
android/                         Kotlin 平台实现
windows/                         C++ 平台实现
example/                         唯一演示宿主
docs/                            开发与视觉契约
```

依赖只能沿以下方向流动：

```text
宿主数据源/仓库/状态实现
          ↓
      公共不可变 API
          ↓
  Reader 会话与纯逻辑内核
       ↙          ↘
分页或媒体调度      Flutter UI
          ↓
平台能力抽象 → Android / Windows
```

UI 不访问网络、文件系统、数据库或宿主 Service Locator；分页和媒体调度不依赖
`BuildContext`、宿主路由或具体平台通道；Widget 不直接调用 `MethodChannel`。

## 3. 标准开发流程

每次修改按以下顺序进行：

1. 完整阅读 `AGENTS.md`，检查 `git status`，识别并保留用户已有改动。
2. 明确范围、支持平台、兼容性和失败路径；高影响契约先更新设计文档。
3. 先修改公共契约和不可变模型，再实现 core、分页或媒体调度。
4. 接入 UI，最后处理 Android/Windows 平台层和 `example/`。
5. 为新增公共类型和成员补充 DartDoc，并同步 README、示例和版本记录。
6. 复核 loading、empty、error、retry、后台、退出和 dispose 路径。
7. 检查请求过期屏蔽、资源释放、缓存上限和语义位置恢复。
8. 只执行仓库允许的格式与静态分析；不新增或运行自动化测试、Golden 或平台构建。

仓库规定的最终检查为：

```bash
git diff --check
dart format --output=none --set-exit-if-changed .
flutter analyze
cd example && flutter analyze
```

不得通过降低 lint、排除源码或吞掉异常制造通过结果。静态分析通过不等于功能测试通过。

## 4. 公共 API 与版本兼容

### 4.1 主组件与命令入口

`TextReaderView` 的构造参数只包含业务接入项：`bookId`、`TextReaderDataSource`、
`TextReaderStateStore`，以及可选观察器、控制器和扩展能力。宿主不得通过任意 builder 或视觉
参数改写阅读器内部设计。

`TextReaderController` 是安全失败的命令入口：未绑定、已销毁或当前不可执行时不访问陈旧
State。`TextReaderSnapshot` 是只读快照。退出按钮、系统返回键和 Escape 只触发
`ReaderObserver.onExitRequested`，由宿主决定路由行为。

### 4.2 文本数据与状态

文本数据源异步提供轻量书籍信息、游标目录、按全书索引定位的章节元数据和结构化纯文本正文。
每个章节、段落必须有稳定且非空的 ID。文本进度与书签使用：

```text
chapterId + paragraphId + characterOffset
```

页码和像素偏移只允许作为瞬时 UI 状态。字体、字号、窗口和横竖模式变化后必须通过上述语义
锚点恢复。`chapterIndex = -1` 专门表示书籍信息预览。

`ReaderBookInfo.sourceKind` 使用 `ReaderBookSourceKind.local`、`remote` 或 `unknown` 描述宿主
来源。它只用于呈现和能力判断，插件不能据此直接访问文件或网络。目录初始状态可由
`ReaderChapterInfo.availability`、`wordCount` 与 `hasBeenRead` 携带。

### 4.3 文本章节状态 capability

0.4.0 通过 `ReaderExtensions.chapterStateCapability` 注册可选
`ReaderChapterStateCapability`。`loadChapterStates(bookId, chapterIds)` 批量返回
`Map<String, ReaderChapterState>`；`ReaderChapterAvailability` 明确区分 `downloaded`、
`notDownloaded`、`downloading`、`failed` 与 `unknown`。该能力遵循以下约束：

- 状态以稳定 `bookId + chapterId` 为键，是 `loadChapterStates` 当次返回的宿主事实快照。
- 未注册能力时，文本阅读和目录必须完整可用，且不显示伪造状态。
- 状态只影响目录或提示的呈现，不改变章节顺序、正文段落身份、分页键或语义进度。
- 点击章节仍通过标准文本数据源加载；插件不得因状态值自行发起下载、删除缓存或重试网络。
- 插件仅在章节真正进入已读语义后调用幂等 `markRead(bookId, chapterId)`；该通知不能触发插件
  自己下载正文，也不能因宿主持久化失败回退当前阅读位置。
- 状态刷新必须带请求世代；旧书、旧章节或 dispose 后的结果必须丢弃。
- capability 抛出的异常归一化为局部可恢复失败，不阻塞当前已加载正文。

### 4.4 只读评论

评论通过可选 `ReaderCommentFeed` 注入，与核心内容数据源分离。插件批量加载摘要，并按目标、
排序和游标分页加载列表；不得提供写操作。未注册 feed 时隐藏所有评论 UI。评论错误只影响局部
入口或列表，不阻塞正文。

漫画单图评论使用
`ReaderCommentTarget.comicImage(bookId, chapterId, imageId)`，且目标 ID 必须与
`ComicImageInfo` 的稳定图片 ID 一致。`ComicReaderView.commentFeed` 未提供时不显示任何入口；
提供时入口叠放在图片层上，不改变图片占位高度。它复用只读 feed、局部错误和分页列表规则，
不得产生点赞或回复写入接口。

段落气泡只展示数量，零条也显示 `0`。其 loading、成功、零条和错误状态使用相同预留几何，
不得让异步返回改变分页边界或阅读位置。

## 5. 宿主网络、下载与缓存总边界

所有外部 I/O 都属于宿主。无论内容是文本、评论、字体还是漫画，插件只调用异步 capability，
不持有以下策略：

- URL 解析、DNS、HTTP、Header、鉴权、Cookie、证书固定和代理。
- 断点续传、Range 请求、并发下载、退避重试、流量策略和后台任务。
- 临时文件、磁盘命名、数据库索引、加密、配额、LRU、过期和清理。
- CDN 切换、内容版本协商、增量更新和离线包修复。

宿主返回给插件的 ID、版本、游标和状态必须稳定。插件只维护有明确上限的会话级内存缓存：

- 文本正文仅当前章与下一章；分页结果仅当前章。
- 目录按需分页并去重，不能通过顺序扫描代替按索引定位。
- 评论摘要和页列表按目标、排序、游标与请求世代隔离。
- 字体句柄和漫画字节遵守各自的内存预算与淘汰规则。

宿主持久缓存命中或未命中不应改变公共数据语义。插件不能通过路径、HTTP 响应对象、数据库
实体或可变集合反向依赖宿主实现。

## 6. 外部字体仓库

内置字体与跨平台回退链仍是默认且必须离线可用。0.4.0 通过
`ReaderExtensions.fontRepository` 注册宿主的 `ReaderFontRepository`；插件本身不联网、不搜索
字体站点，也不持久化下载文件。`ReaderFontDescriptor` 提供稳定 ID、显示名、family 元数据、
版本、许可、文件大小、SHA-256、字重及宿主解释的字体/预览 URL。

宿主字体仓库负责：

- 展示名、稳定字体 ID、版本、字重范围、来源和许可元数据。
- 下载、断点续传、磁盘缓存、更新与删除。
- 在交付插件前校验声明的字节长度和 SHA-256 等强完整性摘要。
- 只接受明确允许应用内嵌入和显示的许可，并保留归属、许可文本和来源记录。
- 拒绝未知格式、超大文件、摘要不符、许可缺失、路径逃逸和符号链接越界。

仓库方法的职责固定如下：

- `loadCatalog()` 返回当前用户与会话可见的不可变 `ReaderFontDescriptor` 列表。
- `loadCachedFontBytes(fontId, version:, weight:)` 只返回已验证缓存字节，未安装时返回 null。
- `loadCachedPreviewBytes(fontId, version:)` 只返回缓存的预览图字节，缺失时返回 null。
- `install(descriptor)` 由宿主完成下载、校验和持久安装；插件只呈现局部进度与结果。
- `remove(fontId)` 删除宿主持久文件，但已注册进 Flutter Engine 的字体在本进程内不能卸载。

插件只消费仓库交付的已验证本地字体结果，并仍需：

- 限制可接受格式、单文件大小、字体数量和内存占用。
- 在独立字体身份下注册，避免覆盖系统字体或其他宿主字体。
- 解析或注册失败时回退到内置字体，不破坏当前语义位置。
- 字体切换触发当前章重排，但不得清空正文或目录缓存。
- 不把本地绝对路径、字体字节、来源 Token 或用户目录写入日志。

已选字体的稳定 ID 保存到 `TextReaderPreferences.customFontId`。null 表示使用内置 `font`；清除
外部选择必须调用 `copyWith(clearCustomFontId: true)`，不能用 `copyWith(customFontId: null)`
误以为会覆盖已有值。旧版本偏好没有该字段时安全回退为 null。

字体文件是非可信二进制输入。宿主和插件都应使用平台/Flutter 支持的解析路径，禁止执行字体
携带的脚本或外部辅助程序。更新字体时使用新版本身份，待旧布局释放后再回收旧句柄，避免正在
绘制的页面引用失效。

## 7. Comic 阅读能力设计

Comic 能力与文本阅读器并列，使用 `Comic*` 前缀和独立组合，不继承 `TextParagraph`、
`TextPainter` 分页、文本字号或文本进度。公共数据模型为 `ComicBookInfo`、
`ComicChapterInfo`、`ComicImageInfo` 与 `ComicChapterContent`；接入边界为
`ComicReaderDataSource`、`ComicReaderStateStore`、`ComicReaderObserver`、
`ComicReaderController` 和只读 `ComicReaderSnapshot`。`ComicReaderPreferences` 只承载漫画
展示偏好。共享范围仅限生命周期、常亮协调、错误类型、观察器语义和异步竞态模式。

### 7.1 纵向逐图渐进调度

漫画目录与 `ComicChapterContent`/`ComicImageInfo` 元数据由 `ComicReaderDataSource` 异步提供，
每张图片通过 `Future<Uint8List>` 交付完整字节。这里的“渐进”指阅读器按视口逐图请求、解码和
展示，不指 partial bytes、流式事件或增量解码。插件不得直接根据 URL 下载。纵向阅读器按视口
调度：

1. 优先请求可见页，随后请求滚动方向上的小范围页。
2. 每个 Future 结果按稳定书籍、章节、图片 ID、内容版本和请求世代核验后才能提交。
3. 只有完整 `Uint8List` 可以进入解码；单图请求或解码失败不能移除其他已成功画面。
4. 每页保持已知纵横比占位，loading、重试和图片到达不得导致列表跳动。
5. 离开预算窗口的解码图和字节按有界 LRU 回收；宿主磁盘缓存不受插件管理。
6. 快速反向滚动时提升当前可见页优先级，取消或忽略不再需要的低优先级结果。

### 7.2 相邻章节无缝衔接

接近章节尾部时可预取下一章元数据和首批页；接近顶部时按需请求上一章末尾。章节内容以边界
标记连续挂接，不能把全书所有页面一次性挂载。新章失败时保留当前章末页和局部重试入口，
不得停留在空白边界。

跨章后只在位置稳定时提交新章节进度。预取完成不等于用户已进入下一章，也不得触发章节变化
观察事件。目录顺序、章节 ID 或内容版本变化时，旧预取结果必须按世代丢弃。

### 7.3 独立进度与书签

漫画使用独立的 `ComicReaderProgress`、`ComicReaderBookmark` 和
`ComicReaderStateStore` 语义。锚点为：

```text
chapterId + imageId + imageFraction
```

`imageFraction` 表示图片内部从 0 到 1 的归一化纵向位置，而不是列表像素偏移；
`chapterIndex`、`chapterFraction` 与 `bookFraction` 只提供稳定导航和展示进度。文本进度与漫画
进度不得互相序列化、转换或共用书签类型。窗口尺寸、缩放和图片重新解码后，漫画按图片 ID 与
归一化位置恢复。

## 8. 异步竞态、缓存与性能

每个会改变用户意图的加载域都维护独立递增世代：书籍会话、章节、目录、评论目标、外部字体、
漫画章节与漫画页。异步结果提交前至少验证：组件未销毁、会话 ID 相同、请求世代相同、目标 ID
和内容版本相同。

通用规则：

- 同一目标的并发请求去重；不同目标不能共享“最后完成者获胜”的隐式状态。
- dispose 后所有 Future、Stream、Timer、Ticker 和解码回调变为无操作并成对释放。
- 手动导航、设置变更、后台、错误和末尾状态立即停止自动阅读。
- 缓存键包含所有影响结果的身份；失效只清理相关层，不级联清空无关数据。
- 所有 Map、目录页、评论页、字体句柄、图片字节和解码图都有集中定义的数量或字节上限。
- 大文本分页、图片解码和批量摘要避免阻塞 UI 帧；高频滚动更新节流，持久化约 800ms 防抖。
- 调试日志只记录类别、目标摘要和耗时，不记录正文、评论全文、字体或漫画原始字节。

性能验收关注首个可读内容时间、翻页/滚动帧稳定性、重排耗时、峰值内存、跨章停顿和反向滚动
恢复。不得以无限预取、无限缓存或降低清晰度来掩盖指标问题。

## 9. 平台职责与本轮验证限制

### Android

Android 是第一优先平台。常亮使用当前 Activity 的 `FLAG_KEEP_SCREEN_ON`，窗口操作在主线程
执行；获取、释放、配置切换、后台和 Engine detach 必须幂等并保留宿主原有标志。系统返回与
顶部返回走同一退出请求路径。模拟器人工检查不能替代真机的常亮、生命周期和系统返回验证。

### Windows

Windows 使用 `SetThreadExecutionState` 管理常亮，并支持鼠标拖页、滚轮、方向键、
PageUp/PageDown、空格、Shift+空格、Escape 和可变窗口。Windows 构建与运行只能在 Windows
主机或相应 CI 完成；macOS 上的静态阅读不能声明 Windows 已验证。

### macOS 本轮限制

macOS 不属于承诺支持平台。本轮在 macOS 上最多进行 Flutter UI 人工验收、截图复核、Dart
格式化/静态分析和原生源码静态审阅；这不证明 macOS 平台能力可用，也不替代 Android 真机或
Windows 真机/CI 验证。交付报告必须逐项列出未执行的平台构建、运行和原生行为检查及原因。

## 10. 0.4.0 完成清单

- 公共 API 只有从包入口导出的稳定类型，新增成员有 DartDoc 和安全默认值。
- 宿主网络、下载、字体许可、完整性和持久缓存职责没有渗入插件。
- 文本章节状态缺失或失败时不影响正文；外部字体失败可回退。
- Comic 逐图渐进调度有稳定占位、有界缓存、世代屏蔽和独立进度/书签。
- loading、empty、error、retry、后台、退出和 dispose 均有明确路径。
- Android 与 Windows 平台语义实现一致，环境未覆盖项被准确披露。
- README、示例、版本记录与实际导出的 0.4.0 契约一致。
- 格式、根包与示例静态分析通过；没有新增测试目录、测试依赖或无关改动。
