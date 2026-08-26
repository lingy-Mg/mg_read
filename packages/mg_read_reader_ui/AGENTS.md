# novel_reader_ui 增量规则

状态：开发规范。根 `AGENTS.md` 始终适用；本文件只补充阅读器 package 的产品/API/平台边界和验证
入口，不重复根级 Git、诊断和 Android 验收规则。

## 按任务读取

- 公共 API、会话、缓存或生命周期：只读 `docs/DEVELOPMENT.md` 的对应标题。
- UI、排版、设置、评论、响应式或可访问性：只读 `docs/UI_DESIGN.md` 的对应组件标题。
- 宿主接入或兼容：读 README、公开入口 `lib/novel_reader_ui.dart` 和相关 CHANGELOG 条目。
- 字体/素材：额外读 `THIRD_PARTY_NOTICES.md`。不要预加载全部 package 文档或整个 `lib/src/`。

## 产品与公共 API

- `novel_reader_ui` 只负责小说/漫画阅读会话、排版、工具栏、语义位置、生命周期和已实现原生能力；
  不负责网络、鉴权、Cookie、数据库、下载、账号、支付、DRM、宿主路由或评论写入。
- 唯一公共入口是 `package:novel_reader_ui/novel_reader_ui.dart`；`lib/src/` 未导出符号均为私有。
- 文本进度/书签使用 `chapterId + paragraphId + characterOffset`；漫画使用
  `chapterId + imageId + imageFraction`。页码或像素偏移不能成为持久权威。
- 公共模型不可变。新增公开成员需要 DartDoc、安全默认和兼容说明；宿主返回纯业务类型，不返回
  Widget、HTTP response、数据库实体、绝对路径或可变集合。
- `ReaderObserver.onExitRequested` 只发退出请求，不自行 `Navigator.pop`。

## 运行与平台增量

- UI、分页和漫画调度不访问网络、数据库、文件系统或宿主 Service Locator，也不在 `build()` 中
  发请求、写状态或调平台通道。每个异步域使用请求世代/取消并有界缓存；所有控制器和平台资源
  成对释放。
- 设置、窗口、字体或方向变化后恢复语义位置；loading/empty/error/retry 保持局部可恢复。可选
  capability 未注册时隐藏 UI，不伪造状态。
- Android 常亮使用当前 Activity 的 `FLAG_KEEP_SCREEN_ON`；Windows 使用
  `SetThreadExecutionState`。平台通道只承载阅读器原生能力。macOS 首发承诺需要独立实现和验收，
  不能从 Flutter UI 可运行推断。

## 验证

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
Push-Location example; flutter analyze; Pop-Location
flutter test
```

新增或修改行为必须在 package 或 monorepo 合适层补测试。平台构建、Golden 和真实运行只在任务
需要且用户授权时执行，并按根契约分层报告。
