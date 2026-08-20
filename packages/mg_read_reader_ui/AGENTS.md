# novel_reader_ui Agent 增量规则

根 [AGENTS.md](../../AGENTS.md) 的 Git、安全、日志、依赖、测试和证据规则始终适用。本文件只
补充阅读器 package 的边界；不要再把旧版 19 节长契约作为常驻上下文。

## 渐进式读取

- 公共 API、会话、缓存、生命周期或原生能力：读
  [项目目标](docs/PROJECT_GOAL.md) + [开发指南](docs/DEVELOPMENT.md)。
- UI、排版、设置、评论、响应式或可访问性：读
  [UI 规范](docs/UI_DESIGN.md)，需要公共语义时再加开发指南。
- 宿主接入或兼容：读 [README](README.md)、公开入口 `lib/novel_reader_ui.dart` 和
  [CHANGELOG](CHANGELOG.md)。
- 字体/素材：额外读 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)。

只读与任务相关的一条，不预加载全部 package 文档或整个 `lib/src/`。

## 产品边界

`novel_reader_ui` 是嵌入宿主的小说/漫画阅读器插件，不是书城或内容平台。它负责阅读会话、
排版/分页/纵向漫画、内部工具栏与设置、语义位置、生命周期和已实现平台能力；不负责网络、
鉴权、Cookie、数据库、下载、账号、支付、DRM、宿主路由或评论写入。

- 包名和唯一公共入口固定为 `novel_reader_ui` / `lib/novel_reader_ui.dart`。
- `example/` 是 package 的演示宿主，不在根 `lib/main.dart` 建第二个 App。
- `lib/src/` 未从公共入口导出的符号均为私有；示例和主应用禁止深层导入。
- Android、Windows 是该 package 当前实现平台。monorepo 的 macOS 首发承诺仍需单独实现和
  验收，不能从 Flutter UI 可运行推断原生支持。

## 公共契约

- 文本入口为 `TextReaderView`，宿主提供 `TextReaderDataSource`、`TextReaderStateStore`，可选
  observer/controller/extensions。组件不自行 `Navigator.pop`，只发
  `ReaderObserver.onExitRequested`。
- 文本进度和书签使用 `chapterId + paragraphId + characterOffset`；漫画使用
  `chapterId + imageId + imageFraction`。页码/像素偏移不得成为持久权威。
- 文本与 `Comic*` 模型、状态、Controller、缓存和语义位置保持独立；共享只能通过组合复用
  生命周期、常亮、错误和竞态模式。
- 公共模型不可变；新增公开类型/成员需要 DartDoc、安全默认、兼容说明与示例。删除、重命名、
  收紧输入或改变默认行为是破坏性变更。
- 宿主返回纯业务类型，不返回 Widget、HTTP response、数据库实体、绝对路径或可变集合。

## 运行时与 UI 规则

- UI、分页和漫画调度不访问网络、数据库、文件系统或宿主 Service Locator，不在 `build()`
  发请求、写状态或调平台通道。
- 每个异步域使用请求世代/取消；过期结果和 dispose 后完成不得覆盖当前会话。
- 文本正文只保留当前章和下一章，分页结果只保留当前章；漫画只挂载/缓存视口附近图片。所有
  目录、评论、字体、图片和解码缓存有明确上限。
- 设置/窗口/字体/方向变化后恢复语义位置。工具栏显隐和异步评论数量不得改变正文可用尺寸或
  已确定的分页边界。
- loading/empty/error/retry 是局部、可恢复状态；宿主 callback 失败不能让阅读页面崩溃。
- 可选 capability 未注册时隐藏 UI，不显示伪造状态。评论只读；段落气泡在注册后使用固定预留
  几何，数量变化不重排。
- Controller、Timer、Ticker、FocusNode、ScrollController、监听器、图片/字体句柄和常亮资源
  必须成对释放。

## 平台增量

- Android 常亮使用当前 Activity 的 `FLAG_KEEP_SCREEN_ON`，窗口操作回到主线程；系统返回与
  顶部返回走同一退出请求。
- Windows 常亮使用 `SetThreadExecutionState`，并维护鼠标拖页、滚轮、键盘和可变窗口语义。
- 平台通道只承载阅读器原生能力，不承载书籍、章节、设置或宿主业务数据。
- Android 真机是常亮、生命周期和系统返回的最终证据；Windows 构建/运行只在 Windows 主机或
  CI 声明完成。macOS UI 观察不等于 package 原生支持。

## 验证

修改代码时按影响执行：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
Push-Location example; flutter analyze; Pop-Location
flutter test
```

若 package 当前没有对应测试资产，新增/修改行为仍应在合适的 package 或 monorepo 测试层补齐，
不得沿用旧文档中的“禁止自动化测试”政策。平台构建、Golden 更新和人工运行只在任务需要且
用户授权时执行，并按根契约分层报告。
