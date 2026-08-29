# mg_read_audio_player

MgRead 的独立音频播放 package。它提供可嵌入的浅色封面式播放器、不可变公开模型、宿主数据与进度
契约、安全控制器，以及可替换的播放后端。默认后端使用精确固定的 `media_kit 1.2.6`，支持 URL、
HTTP headers、队列、播放/暂停、seek、倍速和音量。

```dart
AudioPlayerView(
  collectionId: 'book-1',
  dataSource: myAudioDataSource,
  stateStore: myPlaybackStateStore,
  observer: myObserver,
)
```

## 宿主责任

- 数据来源、鉴权 headers、下载和持久化。
- Android/Windows 后台音频服务、系统媒体通知、音频焦点与中断策略。
- MediaKit 原生库选择与发布验证。

本 package 刻意不混入原生 libs。仅音频宿主选择 `media_kit_libs_audio`；同时包含任何视频播放能力的
宿主改选 `media_kit_libs_video`。两者不能同时安装，具体版本由宿主基于所固定的 MediaKit 版本和官方
兼容说明精确锁定。

`media_kit 1.2.6` 本身采用 MIT 许可证。本 package 不捆绑 native libs；宿主选择
`media_kit_libs_*` 时仍必须核对其打包的 mpv、FFmpeg 等第三方许可证，并随发布物提供所需 notices。

## 验证

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```
