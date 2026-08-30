# mg_read_audio_player

MgRead 独立音频播放器 package。公开入口导出不可变音频契约、Controller 和可嵌入视图。

```dart
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
```

宿主负责数据源、路由、播放队列持久化、授权资源刷新和应用生命周期；播放器只负责当前会话、控制、状态投影
和系统媒体能力。公开 API 以 [`lib/mg_read_audio_player.dart`](lib/mg_read_audio_player.dart) 为准。
