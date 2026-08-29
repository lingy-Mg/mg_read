# mg_read_audio_player 增量规则

根 `AGENTS.md` 始终适用。本 package 独立维护音频播放，不导入小说阅读器或视频播放器。

- 公共入口只从 `lib/mg_read_audio_player.dart` 导出不可变 `Audio*` 模型、宿主契约、控制器和
  `AudioPlayerView`；`lib/src/` 其余实现保持私有。
- UI 不访问宿主数据库、Service Locator 或路由；内容、进度、后台音频服务、通知、音频焦点策略及
  下载均由宿主通过公开契约提供。
- 默认后端固定使用 `media_kit: 1.2.6`，本 package 不依赖任何 `media_kit_libs_*`。原生库由最终宿主
  选择；`media_kit_libs_audio` 与 `media_kit_libs_video` 不得同时安装。
- 异步结果提交前检查会话世代和关闭状态；Stream、Timer、Controller 与后端必须成对释放。高频位置
  变化只节流持久化，暂停、切歌、生命周期、退出和关闭必须刷新。
- 每个源码文件保持低于 700 个非空行。修改后在本目录执行格式化、`flutter analyze` 和
  `flutter test`。
