# 跨层发现契约

只在修改公开组件形状、布局枚举、图标、Runtime 校验、Flutter Facade 或宿主渲染时读取本文件。

## 所有权边界

- 来源拥有真实数据、稳定 `id/target/cursor`、组件树和内容语义。
- `contentKind` 拥有媒介/打开能力语义，`coverOrientation` 拥有横竖封面语义；两者正交，来源必须分别声明。
- Runtime 拒绝未知组件、布局、图标、重复 ID、越界深度/数量和非法 nullable 值，并把兼容输入归一化为稳定 wire 结果。
- Flutter Facade 把 wire 解码成不可变强类型；主应用只消费公开 package 类型。
- Flutter UI 决定 Material 图标、颜色、间距、列数、断点、滚动和交互。插件不能传 UI 代码或样式。

## 当前组件与布局

- 容器：`tabs`、`section`、`group`、`text`、`divider`。
- 内容集合：`featured`、`carousel`、`coverGrid`、`shelf`、`compact`、`ranking`、`list`。`ranking` 是旧
  插件兼容别名，宿主必须与带 rank 的 `compact` 使用同一标准榜单；新来源只输出 `compact`。
- 分类集合：`grid`、`chips`、`list`。
- 组合：`vertical`、`horizontal`、`grid`。group 只负责排列，不为已有 surface 的子组件重复套面板；
  横向组合与轮播、书架共用支持鼠标直接拖动的宿主策略。

语义图标类型为 `PluginDiscoveryIcon`/`DiscoveryIcon`，包含小说/书籍、漫画、音频与视频等媒介语义。tab、section、category 可选声明 `icon`；Runtime 接受缺省或 `null` 并归一化为 `null`，非白名单字符串必须失败。图标的 Material 映射只由 `lib/features/discovery/presentation/discovery_semantic_icons.dart` 持有。

## 跨层修改清单

按实际边界检查，不要盲目全读：

- Runtime 类型：`packages/mg_read_runtime/src/plugin-content-types.ts`
- 递归校验：`packages/mg_read_runtime/src/plugin-content-discovery.ts`
- 通用读取器：`packages/mg_read_runtime/src/plugin-content-validation.ts`
- 公开导出：`packages/mg_read_runtime/src/plugin-content.ts`、`src/index.ts`
- Flutter 摘要类型：`packages/mg_read_runtime/packages/mgread_plugin_runtime/lib/src/plugin_content_summary.dart`
- Flutter 调用类型：`packages/mg_read_runtime/packages/mgread_plugin_runtime/lib/src/plugin_content_invocation.dart`
- Flutter 解码：`packages/mg_read_runtime/packages/mgread_plugin_runtime/lib/src/plugin_content_decoder.dart`
- 主应用路由：`lib/features/discovery/presentation/runtime_discovery_page.dart`
- 竖向集合与列表：`discovery_composite_components.dart`、
  `widgets/discovery_portrait_content_list_item.dart`
- 横向集合与列表：`widgets/discovery_landscape_cover_collection.dart`、
  `widgets/discovery_landscape_content_list_item.dart`
- 横竖详情头：`source_content_detail_sheet.dart`、`source_content_detail_sections.dart`
- 数据源宿主上下文唯一声明：`packages/mg_read_source_api/index.d.ts`
- 来源内容结果类型：各来源自己的内容类型文件；不得复制宿主 Context/WebView 声明
- 稳定规范：`docs/core.md` 的“插件内容 API”章节

`coverOrientation=portrait|landscape` 只选择两套独立的通用封面组件。横向组件不表示视频，不添加播放图标或
“视频”标识；视频也可以声明竖向封面。新增 nullable 字段时优先保持旧插件兼容：允许旧输入缺省，在 Runtime
输出中显式归一化；不要让 Flutter 猜测缺键含义。新增枚举时 Runtime、Facade、宿主映射和受影响参考来源必须同一轮完成。

## 最小验证

- Runtime 类型或校验：固定 Node typecheck 和直接 content-tree/validation 测试。
- Facade/decoder：相邻 Dart 测试；触及 desktop reverse wire 时再增加 desktop fixture。
- 主应用渲染：只格式化拥有文件，运行目标 widget/golden 和任务收尾 analyze。
- 参考来源与其他真实来源：各自运行声明的 verify；只有请求或解析变化才增加 live smoke。
- 根 Flutter 生产 UI 变化按根规则更新一次版本；纯 Runtime、技能或独立来源变化不升级根版本。
