# novel_reader_ui 增量规则

根 `AGENTS.md` 始终适用。本文件只补充 Reader package 的公开边界和验证入口，不复制根级 Git、文档或
Android 验收规则。

## 按任务读取

- 公共 API、会话、缓存或生命周期：读 `lib/novel_reader_ui.dart`、相关公开类型和直接测试。
- UI、排版、设置、评论、响应式或可访问性：读目标组件文件头、相邻 token 和对应 widget/golden 测试。
- 宿主接入或兼容：读消费者 [README](README.md)、公开入口和相关 CHANGELOG 条目。
- 字体或素材：额外读 `THIRD_PARTY_NOTICES.md`。不得为背景扫描整个 `lib/src/` 或全部测试。

## 产品与公共 API

- package 只负责小说/漫画阅读会话、排版、工具栏、语义位置、生命周期和已实现原生能力；不负责网络、
  鉴权、Cookie、数据库、下载、账号、支付、DRM、宿主路由或评论写入。
- 唯一公共入口是 `package:novel_reader_ui/novel_reader_ui.dart`；未导出的 `lib/src/` 符号均为私有。
- 宿主临时亮屏通过公共 `ScreenAwakeCoordinator` 使用独立 holder 并成对释放；不修改阅读偏好，
  同步等宿主业务生命周期仍由主应用持有。
- 文本位置使用 `chapterId + paragraphId + characterOffset`，漫画位置使用
  `chapterId + imageId + imageFraction`。页码和像素偏移不得持久化。
- capability 未提供时隐藏对应 UI；Observer 只请求宿主动作。所有异步资源必须支持取消并成对释放。

## 验证

- 漫画预加载由会话按当前章、下一章顺序推进，共享最多 4 路图片请求；前后台切换、导航和销毁须停止旧任务补充。
- 图片尺寸独立于字节缓存保留在章节窗口内，列表布局和图片单元复用同一尺寸；禁止单元重建后回退估算高度。
- 网络瞬时失败重试及响应体取消属于宿主；单图最终失败保留原始原因和单图重试，不阻塞后续图片。

- 只格式化和分析本次拥有的 Dart 文件，运行直接受影响的 package 测试。
- package 公共边界变化时再运行 package `flutter analyze`；example 变化时单独检查 example。
- UI 变化运行最近的 widget/golden 测试并查看渲染结果；Golden 不替代用户授权的 Android 真实验收。
