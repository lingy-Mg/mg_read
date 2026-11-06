# mg_read_video_player 增量规则

根 `AGENTS.md` 始终适用；本文件只补充独立视频 package 的边界。

- 仅负责视频会话、MediaKit 适配、视频画面与控制层；不得依赖小说阅读器或音频 package。
- 唯一公共入口是 `lib/mg_read_video_player.dart`，宿主不得深层导入 `lib/src/`。
- 网络解析、持久化实现、全屏、方向、PiP 和系统常亮由宿主通过公开契约提供；未传 Observer 时
  仅允许播放器对最近 Navigator 执行保存后的默认返回。
- 原生播放器资源必须成对释放；加载、切集和保存均需防止过期异步结果覆盖当前会话。
- 分组保持业务中立，不引入季/线路枚举；恢复、切集和进度必须同时携带 groupId 与 episodeId。
  上一集、下一集和自动续播只在当前分组内移动；跨分组由用户显式选择。解析或打开失败时不得将旧后端时间写入候选选集。
- 每个源码文件保持少于 700 个非空行。
- `VideoPreparedSession` 是可转移的静音候选后端；宿主必须让 `buildSurface` 实际挂载以取得首帧，
  未 `ready` 前不得替换当前路由。仅由宿主在新播放器可见并确认激活后启用该会话的持久化；
  取消或失败时先卸载候选视图并释放其平台资源，再恢复旧会话。测试后端首帧不能替代 Android 原生画面验收。
  原生后端允许在首次 open 前设置音量，候选静音必须在自动播放前生效。未显式指定代理时，私网 IPv4、
  localhost 与回环媒体绕过继承的系统代理；显式宿主代理保持优先。
- `VideoPlayerView.tvMode` 只切换展示和遥控器映射；焦点在画面时方向键快进退，进入控制栏后恢复按钮遍历。
  宿主 `topRightAction` 使用紧凑图标按钮，位于普通模式顶部操作栏内，随控制栏隐藏和锁定；TV 模式不显示。
  TV 返回先收起控制栏，再走现有保存退出；播放时控制栏在最后一次操作后自动隐藏，
  隐藏时焦点归还画面，暂停与选集/倍速弹层期间保留操作，弹层关闭后重新计时。
  画面上的左右短按跳转 10 秒；按住超过 450 ms 后每 200 ms 连续跳转，按住时长递增步幅，
  不依赖设备重复键频率。松开停止推进并完成最后目标；失焦、切集、后台或退出取消待处理目标。
  慢后端只执行一个 seek 并合并中间目标，不积压整段长按的命令。
- 可选 `VideoGroupDataSource` 按需取得一个 deferred 分组的完整选集；选集弹层浏览不打断当前播放，
  续播必须先解析保存的分组。失败保留重试，下一集不得越过尚未加载的分组跳到另一组。
- Android 原生解码器协商的 `Could not open codec.` 允许 mpv 继续回退，不直接触发暂停；终止错误与
  首帧超时仍必须可见。原生解码和自动播放验收使用根目录的 `integration_test/tv_native_video_playback_test.dart`。
- 宿主可通过后端工厂的 `preferAndroidSurface` 为确认兼容的 Android 硬件选择直连解码 Surface；
  `VideoPlayerView.tvMode` 不推断硬件，也不切换解码策略。
- 后端工厂的 `decoderMode` 与 `androidOutputMode` 只在创建时采样；显式选择覆盖设备自动策略，
  软件解码必须使用 GPU 输出，不能创建仅支持硬解的 Surface 直连组合。界面渲染由宿主独立管理。

验证仅在本 package 内执行：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```
