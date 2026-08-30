# mg_read_video_player

MgRead 独立视频播放器 package。公开入口导出视频数据源契约、播放后端、Controller、状态模型和嵌入视图。

```dart
import 'package:mg_read_video_player/mg_read_video_player.dart';
```

宿主负责数据、路由、授权资源刷新和进度持久化；播放器不拥有来源解析、书架或账号业务。公开 API 以
[`lib/mg_read_video_player.dart`](lib/mg_read_video_player.dart) 为准。
