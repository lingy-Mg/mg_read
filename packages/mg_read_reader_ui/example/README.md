# novel_reader_ui example

Android/Windows 示例宿主，演示如何向阅读器注入异步书籍数据、进度、偏好设置、书签存储、退出事件和可选的三级只读评论 feed。

```bash
flutter run -d <android-device>
```

在 Windows 主机上：

```powershell
flutter run -d windows
```

示例正文《山灯未眠》和全部评论均为项目原创演示内容。

`DemoReaderCommentFeed` 通过
`ReaderExtensions(commentFeed: DemoReaderCommentFeed())` 注册，使用稳定的纯内存数据和短暂异步延迟，演示：

- 书籍、章节和段落三级 `ReaderCommentTarget`。
- 一次请求多个目标的 `loadSummaries`，包括总数为零的段落目标。
- `ReaderCommentSort.hot` 与 `ReaderCommentSort.newest`。
- 使用不透明字符串游标的 `loadComments` 分页。
- 只读评论的作者、正文、创建时间和点赞数展示。
- 书籍和章节入口的评论摘要，以及每个段落末尾固定高度的紧凑评论气泡；数量显示在气泡内部，零评论显示 `0`，点击后打开只读评论列表。段落入口只展示数量，不展示评论正文摘要，异步数量变化不会改变正文布局。

首页的两个失败开关默认关闭：开启“下一次评论列表加载失败”后，首次打开评论列表会失败一次，点击重试即可恢复；“下一次章节正文加载失败”以同样方式提供章节错误人工检查入口。失败只触发一次，不改变稳定评论或章节数据。

阅读设置还可人工检查七套配色、六套原创背景、字体与间距、仿真/覆盖/平移/无动画，以及横向和纵向自动阅读。自动阅读是会话级状态，不会写入内存状态存储。

建议重点人工验收：

- 改变配色、背景、字体、字号、间距或窗口大小后仍停留在相同语义位置。
- 启停自动阅读，并确认手动操作、进入后台、加载错误、末章和退出会停止它。
- 书籍/章节评论摘要和段落末尾评论气泡；确认气泡内数量（包括 `0`）、点击进入只读列表，以及 loading、empty、热门/最新切换和继续加载。使用首页开关检查 error/retry，并确认异步状态变化不会造成正文跳动。
- 移除 `ReaderExtensions.commentFeed` 后，阅读器不显示评论入口或占位。

旧的 `ReaderExtensions.comments` / `ReaderCommentsCapability` 已弃用，示例不再使用它们。

本仓库不提供自动化测试或 Golden。Android 模拟器运行只能作为当次人工交互检查；常亮、生命周期和系统返回仍需 Android 真机验收，Windows 可变窗口与输入行为需在 Windows 主机验收。
