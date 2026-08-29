# 跨层发现契约

只在修改公开组件形状、布局枚举、图标、Runtime 校验、Flutter Facade 或宿主渲染时读取本文件。

## 所有权边界

- 来源拥有真实数据、稳定 `id/target/cursor`、组件树和内容语义。
- Runtime 拒绝未知组件、布局、图标、重复 ID、越界深度/数量和非法 nullable 值，并把兼容输入归一化为稳定 wire 结果。
- Flutter Facade 把 wire 解码成不可变强类型；主应用只消费公开 package 类型。
- Flutter UI 决定 Material 图标、颜色、间距、列数、断点、滚动和交互。插件不能传 UI 代码或样式。

## 当前组件与布局

- 容器：`tabs`、`section`、`group`、`text`、`divider`。
- 内容集合：`featured`、`carousel`、`coverGrid`、`shelf`、`compact`、`ranking`、`list`。
- 分类集合：`grid`、`chips`、`list`。
- 组合：`vertical`、`horizontal`、`grid`。

语义图标类型为 `PluginDiscoveryIcon`/`DiscoveryIcon`。tab、section、category 可选声明 `icon`；Runtime 接受缺省或 `null` 并归一化为 `null`，非白名单字符串必须失败。图标的 Material 映射只由 `lib/features/discovery/presentation/discovery_semantic_icons.dart` 持有。

## 跨层修改清单

按实际边界检查，不要盲目全读：

- Runtime 类型：`packages/mg_read_runtime/src/plugin-content-types.ts`
- 递归校验：`packages/mg_read_runtime/src/plugin-content-discovery.ts`
- 通用读取器：`packages/mg_read_runtime/src/plugin-content-validation.ts`
- 公开导出：`packages/mg_read_runtime/src/plugin-content.ts`、`src/index.ts`
- Flutter 类型：`packages/mg_read_runtime/packages/mgread_plugin_runtime/lib/src/plugin_content_invocation.dart`
- Flutter 解码：`packages/mg_read_runtime/packages/mgread_plugin_runtime/lib/src/plugin_content_decoder.dart`
- 主应用渲染：`lib/features/discovery/presentation/runtime_discovery_page.dart`、`discovery_composite_components.dart`
- 插件公开模板：`templates/mg_read_plugin_template/src/mgread-api.ts`
- 真实来源编译期类型：各来源 `src/mgread-api.ts`
- 稳定规范：`docs/core.md` 的“插件内容 API”章节

新增 nullable 字段时优先保持旧插件兼容：允许旧输入缺省，在 Runtime 输出中显式归一化；不要让 Flutter 猜测缺键含义。新增枚举时 Runtime、Facade、宿主映射和模板必须同一轮完成。
