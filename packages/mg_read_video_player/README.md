# mg_read_video_player

独立维护的 MgRead 视频播放器 package。宿主通过 `VideoDataSource` 提供标题、选集、URL 和请求头，
通过 `VideoPlaybackStateStore` 持久化选集与播放位置，并通过 `VideoPlayerObserver` 接收退出和全屏意图。
测试可注入 `VideoPlaybackBackend`，无需启动原生解码器。

## 依赖与原生库

- Dart `^3.12.2`，Flutter `>=3.44.0`。
- 精确固定 `media_kit 1.2.6` 与 `media_kit_video 2.0.1`。
- 本 package 不捆绑 native libs。最终宿主按目标平台选择一个与上述版本兼容的
  `media_kit_libs_video`，不要同时混入 `media_kit_libs_audio`；视频库已覆盖视频播放所需的音频解码。
- `media_kit 1.2.6` 与 `media_kit_video 2.0.1` 使用 MIT 许可证。宿主加入
  `media_kit_libs_video` 前仍需核对其中 mpv、FFmpeg 等第三方组件的许可证、分发条件和发布 notices。

## 宿主边界

播放器只发送全屏请求，不直接修改系统 UI。全屏窗口、方向锁定、PiP、系统常亮、路由退出和平台
验收均由宿主实现。系统返回与 Escape 会先请求退出全屏；非全屏时播放器暂停并刷新进度后才允许
宿主退出路由。

```dart
VideoPlayerView(
  contentId: contentId,
  dataSource: dataSource,
  stateStore: stateStore,
  observer: observer,
)
```
