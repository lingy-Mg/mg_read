# novel_reader_ui

MgRead 独立维护的小说与漫画阅读器 package。它提供阅读会话、文本/漫画语义位置、工具栏、设置和宿主回调，
内容获取、持久化、路由、下载与账号能力由宿主负责。

## 接入

```dart
import 'package:novel_reader_ui/novel_reader_ui.dart';
```

只使用 [`lib/novel_reader_ui.dart`](lib/novel_reader_ui.dart) 导出的公开类型，不导入 `lib/src/`。完整运行示例见
[`example/`](example/)，版本兼容变化见 [CHANGELOG](CHANGELOG.md)。

## 支持边界

- 文本与漫画阅读相互独立，但共享宿主提供的生命周期与能力注册方式。
- 文本位置使用章节、段落和字符偏移；漫画位置使用章节、图片和图片内比例。
- package 不发业务网络请求，不打开宿主数据库，也不拥有书架、下载、账号、支付或 DRM。
- 当前首要平台是 Android，Windows 为第二平台；其他平台能力以公开类型和实际测试为准。

开发和 AI 规则只在 [AGENTS.md](AGENTS.md) 维护。

## EPUB 文档阅读器

通过 `DocumentReaderView` 接入连续滚动、可重排的 EPUB 文档阅读；宿主实现公开的
`ReaderDocumentDataSource`，并提供 `ReaderDocumentChapter`、`ReaderDocumentBlock` 和资源读取，负责解析、存储与链接解析。
阅读器只接收宿主提供的章节和资源，不自行访问网络、文件系统或数据库。为限制单次布局与图片解码开销，宿主应将章节分段到每段最多 16 Ki UTF-16 字符、128 个块、512 个渲染节点和 4 张图片；资源通过不透明 `resourceId` 按需读取。
