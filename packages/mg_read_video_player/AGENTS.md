# mg_read_video_player 增量规则

根 `AGENTS.md` 始终适用；本文件只补充独立视频 package 的边界。

- 仅负责视频会话、MediaKit 适配、视频画面与控制层；不得依赖小说阅读器或音频 package。
- 唯一公共入口是 `lib/mg_read_video_player.dart`，宿主不得深层导入 `lib/src/`。
- 网络解析、持久化实现、全屏、方向、PiP 和系统常亮由宿主通过公开契约提供；未传 Observer 时
  仅允许播放器对最近 Navigator 执行保存后的默认返回。
- 原生播放器资源必须成对释放；加载、切集和保存均需防止过期异步结果覆盖当前会话。
- 分组保持业务中立，不引入季/线路枚举；恢复、切集和进度必须同时携带 groupId 与 episodeId。
- 每个源码文件保持少于 700 个非空行。

验证仅在本 package 内执行：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```
