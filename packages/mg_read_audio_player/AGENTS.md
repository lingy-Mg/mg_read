# mg_read_audio_player 增量规则

根 `AGENTS.md` 始终适用。本 package 独立维护音频播放，不导入小说阅读器或视频播放器。

- 公共入口只从 `lib/mg_read_audio_player.dart` 导出不可变 `Audio*` 模型、宿主契约、控制器和
  `AudioPlayerView`；`lib/src/` 其余实现保持私有。
- 宿主后台播放使用公开 `AudioPlayerEngine` 持有会话，并以 `AudioPlayerView.controlled` 临时连接同一
  Controller；受控 View 只能监听和发指令，销毁时不得关闭 Engine、后端或数据源。
- UI 不访问宿主数据库、Service Locator 或路由；内容、进度、后台音频服务、通知、音频焦点策略及
  下载均由宿主通过公开契约提供。
- UI 动效消费 `MediaQuery.disableAnimations`；弹层关闭动画、装饰控制器停到终态，切换偏好不重建播放会话。
- `AudioPlayerView` 的 `rememberPosition` 与 `onRememberPositionChanged` 只投影宿主续播偏好；
  没有回调时隐藏开关。宿主控制持久进度读写，关闭后保留旧记录和当前会话恢复，不重建 Engine。
- 默认后端固定使用 `media_kit: 1.2.6`，本 package 不依赖任何 `media_kit_libs_*`。原生库由最终宿主
  选择；`media_kit_libs_audio` 与 `media_kit_libs_video` 不得同时安装。
- 异步结果提交前检查会话世代和关闭状态；Stream、Timer、Controller 与后端必须成对释放。高频位置
  变化只节流持久化，暂停、切歌、生命周期、退出和关闭必须刷新。
- 原生 `open()` 返回不代表文件已加载；恢复跳转须等待有效媒体时长，`seek()` 完成前须观察到目标
  位置事件，避免静默从头播放或退出时保存旧时间。等待只使用事件订阅，成功、失败和超时均释放。
- `resourceLoading` 由资源请求边界拥有；普通播放器进度、完成和缓冲事件不得清除它。目标章节就绪后必须按最新
  播放意图显式播放，暂停或更新的选择必须使旧续播失效。播放命令 Future 返回不等于已出声，必须等到后端
  发布 `playing=true` 才结束启动状态；超时或后端错误要形成用户可见的分阶段失败。
- 章末恢复不得用短等待超时取消仍在解析的下一章请求；请求完成或失败仍由原加载链路处理。
  追加队列前后都要检查播放完成状态，覆盖拖到尾部后在 append 期间播完的竞态；前后台共用此规则。
  等待有效请求不消耗失败重试次数；EOF 后以明确的追加索引切章，避免 MediaKit `next()` 从队首重启。
- 每个源码文件保持低于 700 个非空行。修改后在本目录执行格式化、`flutter analyze` 和
  `flutter test`。

- 播放 UI 采用封面主导的极简布局；`audio_player_layout.dart` 拥有竖屏/横屏排布，
  `audio_player_surface.dart` 仅提供不透明面板，不叠加 BackdropFilter。背景随章节静态换色，进度更新不重建封面。
- 倍速和定时快捷入口定位对应设置区域；大字和矮屏允许滚动，主要播放操作保留至少 44px 点击区域。
  不展示宿主未提供能力的假交互或待开发占位区。视觉基线使用仓库内字体，确保中文字和图标可读。
