# novel_reader_ui

一个可嵌入 Flutter App 的文本与漫画阅读器插件。`0.4.0` 在完整文本阅读能力上新增宿主托管的章节下载状态与外部字体仓库公共契约，并提供独立的 `Comic*` 纵向渐进阅读 API。Android 和 Windows 继续负责阅读期间的系统能力。

> 字体声明：本项目内嵌未经修改的 **MiSans VF** 作为默认阅读字体。MiSans 的字体软件及相关
> 知识产权属于许可方小米科技有限责任公司；嵌入使用须在软件中注明 MiSans，且不得改编字体
> 或单独再分发字体文件。请阅读 [第三方声明](THIRD_PARTY_NOTICES.md) 与
> [MiSans 官方许可协议](https://hyperos.mi.com/font-download/MiSans%E5%AD%97%E4%BD%93%E7%9F%A5%E8%AF%86%E4%BA%A7%E6%9D%83%E8%AE%B8%E5%8F%AF%E5%8D%8F%E8%AE%AE.pdf)。

## 平台

| 平台 | 状态 | 原生能力 |
| --- | --- | --- |
| Android | 优先支持 | 常亮与可选沉浸阅读（默认关闭；系统边缘滑动可临时唤出栏） |
| Windows | 支持 | `SetThreadExecutionState` 常亮；不接管宿主全屏 |

iOS、macOS、Linux 和 Web 暂不属于承诺支持范围。本轮仅额外授权在 macOS 上进行 UI 人工验收；这不代表 macOS 已成为发布平台，也不能替代 Android 真机和 Windows 主机验收。

## 接入

宿主提供异步内容接口和状态存储接口，然后嵌入 `TextReaderView`：

```dart
TextReaderView(
  bookId: book.id,
  dataSource: appReaderDataSource,
  stateStore: appReaderStateStore,
  extensions: ReaderExtensions(
    commentFeed: appReaderCommentFeed,
    chapterStateCapability: appChapterStateCapability,
    fontRepository: appFontRepository,
  ),
  observer: AppReaderObserver(
    onExit: () => Navigator.of(context).pop(),
  ),
)
```

### 内容接口

```dart
class AppReaderDataSource implements TextReaderDataSource {
  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    return api.fetchBook(bookId);
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async {
    return api.fetchCatalog(bookId, cursor: cursor, limit: pageSize);
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(
    String bookId,
    int index,
  ) async {
    return api.fetchChapterInfoAtIndex(bookId, index);
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    return api.fetchChapter(bookId, chapterId);
  }
}
```

每个 `TextParagraph` 必须有稳定且非空的 ID。阅读位置和书签使用 `chapterId + paragraphId + characterOffset` 保存，因此改变字体或窗口尺寸后仍能恢复到相同语义位置。

阅读器默认进入索引 `-1` 的书籍信息预览，不加载任何章节正文。`loadChapterAtIndex` 用于全书进度条随机定位章节，不会为了跳转顺序遍历所有目录页。

如需在阅读顶部展示来源并让用户在外部浏览器查看当前章节，可在
`ReaderBookInfo.sourceName` 和 `TextChapterContent.chapterUrl` 中提供可选值。插件只接受
HTTP/HTTPS 链接，并且仅在用户点击链接时打开外部浏览器。

### 状态接口

宿主实现 `TextReaderStateStore`，负责保存：

- `ReaderProgress`
- `TextReaderPreferences`
- `ReaderBookmark`

插件不依赖数据库、用户系统或网络库。示例使用内存实现，生产 App 可接入 SQLite、Isar、服务端同步或自己的数据层。

`TextReaderPreferences` 由阅读器设置 UI 产生，宿主只需原样持久化。`customFontId` 是可空的稳定字体 ID，缺失、空白或被清除时使用内置字体。旧数值仍会在读取时归一到最近的合法预设。

### 章节状态与下载边界

`ReaderBookInfo.sourceKind` 区分本地、远程和未知来源。`ReaderChapterInfo` 可附带 `availability`、`wordCount` 和 `hasBeenRead`，旧构造调用无需修改。需要刷新动态状态时，宿主可注册 `ReaderChapterStateCapability`，批量返回状态并接收幂等的 `markRead` 通知。

插件不直接联网或管理持久缓存。用户进入未下载章节时仍调用既有 `loadChapterContent`；宿主可以在该 Future 内完成下载、校验和缓存，再返回完整正文。错误由阅读器转换为可恢复状态。

### 外部字体仓库

`ReaderFontRepository` 由宿主实现，负责字体目录、许可与完整性检查、下载、持久缓存、预览字节、安装和删除。`ReaderFontDescriptor` 使用稳定 ID，并可声明显示名、family、URL、版本、许可、文件大小、SHA-256 与字重。URL 只是宿主元数据，插件不会直接请求。

字体安装完成后，仓库通过 `Uint8List` 返回每个声明字重的缓存字节。Flutter engine 已注册字体不能在当前进程卸载；`remove` 仅移除宿主缓存并影响后续加载。

### 漫画公共契约

漫画使用独立的 `ComicBookInfo`、`ComicChapterInfo`、`ComicImageInfo`、`ComicChapterContent`、`ComicReaderProgress`、`ComicReaderBookmark` 和 `ComicReaderPreferences`，不复用文本段落、分页或位置模型。`ComicReaderDataSource` 先返回章节及图片元数据，再通过 `loadImageBytes` 按可见区域和邻近区域渐进加载完整 `Uint8List`；网络、鉴权、文件和缓存仍全部归宿主。

漫画只允许纵向阅读，相邻章节连续衔接；慢图片必须保留稳定占位，失败可以局部重试，过期异步结果不得覆盖新章节。`ComicReaderStateStore` 保存独立语义进度和书签，`ComicReaderController` 只提供章节、chrome 与刷新命令。`ComicReaderView` 可选接收 `commentFeed`，并用 `ReaderCommentTarget.comicImage` 在对应图片上叠放不改变图片占位的只读评论入口；未注入时完全隐藏。

### 可选只读评论

评论使用独立的 `ReaderCommentFeed`，不会向正文数据源或状态存储增加方法：

```dart
class AppReaderCommentFeed implements ReaderCommentFeed {
  @override
  Future<Map<ReaderCommentTarget, ReaderCommentSummary>> loadSummaries(
    List<ReaderCommentTarget> targets, {
    int previewLimit = 3,
  }) {
    return api.fetchCommentSummaries(targets, previewLimit: previewLimit);
  }

  @override
  Future<ReaderCommentPage> loadComments(
    ReaderCommentTarget target, {
    ReaderCommentSort sort = ReaderCommentSort.hot,
    String? cursor,
    int pageSize = 20,
  }) {
    return api.fetchComments(
      target,
      sort: sort,
      cursor: cursor,
      limit: pageSize,
    );
  }
}
```

目标使用 `ReaderCommentTarget.book`、`.chapter`、`.paragraph` 或 `.comicImage` 表示，所有层级 ID 必须为非空字符串。摘要通过一次批量请求加载，列表支持热门/最新排序和游标分页。书籍和章节入口保持评论总数与只读摘要展示；段落入口只展示数量，不展示评论正文摘要。紧凑段评气泡紧随段落最后一个字同行显示，评论数量直接位于气泡内部，零评论也显示 `0`。点击气泡打开该段落的只读评论列表；异步数量到达或变化时只更新气泡内部状态，不改变已预留的行内空间，不触发正文重排、分页边界变化或阅读位置跳动。漫画图片入口叠放在已确定尺寸的图片层上，摘要状态变化不得改变图片占位高度。

分页返回值必须使用非负总数；`hasMore` 为 true 时返回非空且推进的 `nextCursor`，为 false 时游标必须为 null；每条评论的 target 必须与请求一致。插件只展示宿主返回的纯文本、作者、时间、只读点赞数，不提供发布、回复、点赞或举报操作。未注册 `commentFeed` 时不显示评论入口。

旧的 `ReaderExtensions.comments` 和 `ReaderCommentsCapability` 已弃用，但为源代码兼容仍暂时保留；新接入应使用 `commentFeed`。

### 外部控制

需要从宿主主动控制阅读器时传入 `TextReaderController`：

```dart
final controller = TextReaderController();

await controller.openChapter('chapter-120');
await controller.nextPage();
await controller.showControls();
await controller.startAutoReading();
await controller.stopAutoReading();
```

通过 `controller.snapshot` 或监听 Controller 可以读取当前书籍、章节、进度、loading、错误和 `isAutoReading` 状态。自动阅读只属于当前阅读会话，不写入 `TextReaderPreferences`；重新进入阅读器时默认关闭。

## 组件内功能

- 默认左右滑页和左/中/右点击区域。
- 左右翻页同时支持触摸和鼠标按住拖动。
- 可切换上下连续滚动；自动阅读在横向模式定时翻页，在纵向模式持续滚动。
- 目录分页、当前章高亮和进度跳转。
- 语义书签的添加、跳转和删除。
- 七套阅读配色和六套插件内置原创背景，可独立组合。
- 仿真、覆盖、平移和无动画四种横向翻页效果；上下模式继续使用纵向滚动。
- 单页紧凑设置面板：亮度、护眼快捷切换、字号、字体、配色、背景、翻页、间距、评论显示偏好和设备能力。
- 字体、字号、字重、字距、行距、段距、首行缩进、页边距和阅读区域亮度；旧持久化值会归一到最近预设。
- 可选的书籍、章节、段落三级只读评论：书籍和章节保留摘要，段评气泡紧随最后一个字同行且数量内嵌；列表支持热门/最新排序、游标分页、loading、empty、error 和 retry。
- Android 返回键及 Windows 键盘、鼠标交互。
- 前后台生命周期通知、进度 flush 和引用计数常亮。
- 最后一章继续前进时显示“没有下一章了”，不会停在空白边界页。

正文和排版严格按需处理：内存只保留当前章和下一章正文，只有当前章会执行分页；返回上一章时重新加载、临时排版并定位到末页。不支持原生常亮的平台会忽略并隐藏常亮设置。

系统要求减少动态效果时，横向动画统一降级为无动画。用户手动翻页或滚动、进入后台、加载失败、到达全书末尾、退出或销毁阅读器时，自动阅读会停止。

## 运行示例

```bash
cd example
flutter run -d <android-device>
```

Windows 主机：

```powershell
cd example
flutter run -d windows
```

示例小说《山灯未眠》和三级评论均为项目内原创演示内容。漫画示例《云上明信片》轮替使用由 OpenAI ImageGen 为本项目生成的原创竖向漫画页与仓库原创背景素材，用于检查不同纵横比图片的稳定占位和渐进加载。`DemoReaderCommentFeed` 使用稳定内存数据和短暂延迟，覆盖批量摘要、零评论目标、热门/最新排序和游标分页。示例首页还提供默认关闭的一次性评论加载失败和章节正文加载失败开关，用于人工检查错误状态与重试。

## VS Code 任务按钮

安装推荐的 `spencerwmiles.vscode-task-buttons` 扩展后，状态栏会提供：

- `开发运行`：在 `example/` 中启动 Flutter 开发版本，并自动选择设备。
- `发布 APK`：执行 Android Release 构建。
- `发布 Windows EXE`：执行 Windows Release 构建。

也可以直接按 `F5`，在 Flutter/Dart 调试配置中选择 `Example（选择设备）` 或
`Example（Windows）`。发布任务不会使用 debug 构建，Android APK 固定为单一
`arm64-v8a`（ARMv8）架构，Windows 固定为 `x64` 架构：APK 位于
`build/novel_reader_ui_example-release.apk`；Windows 完整应用位于
`build/novel_reader_ui_example-windows-release/`，任务会自动从 Flutter 的深层构建目录复制过去。需要将该目录整体作为 Windows 应用分发，不能只复制 EXE 文件。

## 验证

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
cd example
flutter analyze
```

项目不保留或运行自动化测试与 Golden 截图。重大视觉改造经用户明确授权时，可在 Android 模拟器运行 `example/` 做人工点击、拖动和截图检查，但这不等同于自动化测试，也不能替代 Android 真机的常亮、生命周期和系统返回验收。Windows 运行时和可变窗口交互只能在 Windows 主机或对应 CI 环境人工检查。

建议人工检查：

- 七套配色、六套背景、字体与间距改变后仍保持同一语义阅读位置。
- 仿真、覆盖、平移、无动画和系统减少动态效果均符合预期。
- 横向/纵向自动阅读能够启动，并在手动操作、后台、错误、末章和退出时停止。
- 注册评论 feed 时确认书籍/章节摘要、紧随段落最后一个字同行的气泡内数量（包括 `0`）、只读列表、空状态、重试、排序和继续加载可用；异步数量变化不引起正文跳动。不注册时不显示任何评论占位。

完整工程约定见 [AGENTS.md](AGENTS.md)，接入与异步边界见 [开发规范](docs/DEVELOPMENT.md)，视觉与可访问性标准见 [UI 设计规范](docs/UI_DESIGN.md)。
