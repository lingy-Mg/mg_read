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
