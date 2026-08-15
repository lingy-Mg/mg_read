# ADR-0017：版本化插件内容契约与显式空值语义

- 状态：Accepted
- 日期：2026-08-15
- 决策者：MgRead 项目
- 依赖：[ADR-0008](0008-standalone-plugin-runtime-boundary.md)、[ADR-0015](0015-standard-node-plugin-projects.md)

## 背景

早期 desktop 证据只把插件 `search(keyword)` 投影为 `id/title/author`。这个临时切片无法承载
发现页的 tab、推荐、排行和分类，也不能为搜索、详情和书架 UI 提供封面、简介、字数、章节数、
更新时间、最新章节、来源 URL、连载状态等必要信息。更严重的是，旧投影允许可选键直接缺失，
Node、JSON 和 Dart 会分别猜测“缺失、未知、空字符串和零”的含义，无法形成稳定契约。

当前尚未公开发布 Plugin API，因此应在首个公开版本前直接修正 v1，而不是永久保留一个无法
驱动产品 UI 的兼容层。

## 决策

1. Plugin API v1 使用完整请求/结果对象，不再使用 `search(keyword)` 及极简数组返回。标准入口
   命名导出为 `activate(ctx)`、`discover(request)`、`search(request)`、
   `getDetail(request)`、`getChapters(request)`、`getContent(request)`。
2. Runtime 内部 capability 固定为 `source.discover.v1`、`source.search.v1`、
   `source.getDetail.v1`、`source.getChapters.v1`、`source.getContent.v1`。旧的
   `plugin.search.v1` 仅是未发布的开发证据，直接删除，不提供双协议或签名探测。
3. 搜索与发现共同使用同一个富内容摘要。`id`、`title`、`contentKind`、`status`、`access`、
   `categories`、`tags`、`attributes` 是必需键；`id/title/contentKind` 永不为 null。URL 只是
   元数据，不能替代插件作用域稳定 `id`。
4. 可空标量也必须保留键并显式使用 JSON `null`。禁止用缺键、`undefined`、空白字符串、`0`、
   `false` 或“未知”文本代替 null。Runtime 在插件边界拒绝缺少固定键或类型不符的结果；
   Flutter Facade 只返回强类型 nullable 字段。
5. 集合键永不为 null：已知没有值或来源不提供时返回空数组 `[]`。状态字段不使用 null，使用
   有限枚举中的 `unknown`；这样 UI 可以区分“未知状态”和空集合，而不解析自由文本。
6. `latestChapter` 作为整体可为 null；非 null 时其 `id/url/updatedAt` 仍是显式 nullable 键，
   `title` 必填。`wordCount/chapterCount/totalCount` 为非负安全整数或 null；零是有效已知值，
   null 才表示未知/不适用。时间为带时区的 RFC 3339 字符串或 null。
7. 稳定核心字段之外只允许有界强类型 `attributes[{key,label,value}]`，不把任意 Map/JSON
   穿透到 Flutter。Runtime 限制字符串、列表、分区、条目和响应大小，忽略未识别扩展字段，
   但不会把它们暴露给主项目。
8. 发现结果必须包含 `tabs`、`selectedTabId`、`sections` 和 `nextCursor`。分区使用固定 layout
   枚举并分别承载内容项或分类入口；排行名次、指标和推荐语属于发现项包装，不污染内容身份。
9. 搜索、发现和目录都使用不透明 cursor 与有界 `pageSize`；返回结果显式包含
   `nextCursor` 和 nullable `totalCount`。插件不得把 UI 页码或整个对象当作后续调用引用。
10. `package.json.mgread.displayName` 成为必填的用户可见来源名，`contentKinds` 只使用
    `novel` / `manga`。npm `name` 仍是包身份，不直接充当 UI 来源名称。

## 后果

正面：

- 搜索、发现、详情、目录和正文共享一条可验证的身份链，UI 不再靠猜字段或拼 URL。
- Node 到 JSON 到 Dart 对每个空值只有一种编码，fixture 可以逐字段验证缺键、null、零和空数组。
- 发现页可以表达 hero、横向推荐、排行、分类和列表，同时 UI 仍决定具体颜色、尺寸和交互。
- `attributes` 为来源特有信息提供受控扩展点，不需要恢复动态 Map。

代价：

- 插件作者必须完整构造固定对象，即使多个字段为 null；官方模板需提供构造示例和类型。
- 旧开发 fixture、Runtime handler、Flutter Facade 类型和模板必须同步替换。
- 图片和超限正文仍需 Runtime 资源数据面；元数据中的远端 URL 不授权 Widget 直接联网。

## 迁移

当前没有公开插件或需要保留的用户包。Runtime、fixture、Flutter Facade、主项目适配器和官方
模板一次性切换到新 v1；旧字符串签名或缺少固定 nullable 键的响应返回
`plugin_invalid_response`。不增加旧 API 探测、默认值填充或双格式转换器。

## 被拒绝的方案

- 继续在 UI adapter 中猜缺失字段：不同页面会产生互不一致的默认值，无法契约测试。
- 所有字段都变成可选 Map：会把插件动态结构直接泄漏到主项目并丢失版本边界。
- 强制每个内容都有 URL：API、本地或非网页来源无法满足；稳定 `id` 才是调用身份。
- 用空字符串或零表示未知：会混淆真实空内容、真实零值与尚未获取。
- 让插件完全控制 Flutter Widget 布局：会破坏宿主主题、可访问性和响应式规则。

## 变更条件

新增核心字段、枚举值或发现布局时必须发布新的 capability/Plugin API 版本并同步 Runtime Schema、
跨语言 fixture、模板与 UI adapter。不得在 v1 中把固定 nullable 字段重新改成缺键语义。
