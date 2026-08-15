# 15 插件内容 API v1

本专题落实 [ADR-0017](adr/0017-versioned-plugin-content-contract.md)。规范类型、运行时校验与
跨语言 fixture 由 `mg_read_runtime` 维护；本文件固定产品语义，主项目只消费 Runtime Facade
发布的 Dart 强类型。

## 调用链与稳定引用

```text
discover/search -> ContentSummary.id
                         |-> getDetail({ id })
                         |-> getChapters({ id, cursor, pageSize })
                                      |-> ChapterSummary.id
                                      `-> getContent({ id, chapterId })
```

`id` 是插件作用域的不透明稳定引用。`url`、书名、作者、数组位置、页码和 Dart 对象都不能替代
它。URL 可以改变或不存在；Runtime/应用保存绑定时同时保存 plugin ID 与 opaque content ID。

## 固定空值规则

| 值类别 | JSON 表达 | 规则 |
| --- | --- | --- |
| 必填身份/枚举 | 非 null 值 | 缺键、null、空白或未知枚举均拒绝 |
| 可空标量 | 键存在，值为具体值或 `null` | 缺键/`undefined` 拒绝；空白字符串不等于 null |
| 非负计数 | 安全整数或 `null` | `0` 是真实零值；负数、浮点和字符串拒绝 |
| 状态 | `ongoing/completed/hiatus/unknown` 等枚举 | 不用 null 或本地化文字表达未知 |
| 集合 | 数组 | 没有或不支持时为 `[]`，永不为 null |
| 时间 | RFC 3339 字符串或 `null` | 必须带 `Z` 或明确时区，UI 再本地化 |
| URL | HTTP(S) 字符串或 `null` | 不含凭据；只作元数据，不作业务主键 |

Runtime 不自动把空字符串改成 null，也不把缺键补成 null。错误插件必须在开发期暴露，不能让
不同语言各自生成默认值。未知附加键可以被 Runtime 丢弃，但不会穿透 Facade。

## 富内容摘要

搜索项和发现内容项共用以下固定字段：

```json
{
  "id": "book:123",
  "title": "示例书名",
  "contentKind": "novel",
  "author": null,
  "url": "https://example.invalid/book/123",
  "coverUrl": null,
  "description": null,
  "language": null,
  "status": "unknown",
  "access": "unknown",
  "wordCount": null,
  "chapterCount": 0,
  "publishedAt": null,
  "updatedAt": null,
  "latestChapter": null,
  "categories": [],
  "tags": [],
  "attributes": []
}
```

字段含义：

| 字段 | 类型 | UI/领域用途 |
| --- | --- | --- |
| `id` | string | 后续详情、目录和正文调用的唯一来源引用 |
| `title` | string | 书名/作品名，必填 |
| `contentKind` | `novel` / `manga` | 选择详情、目录与阅读器能力 |
| `author` | string/null | 作者、原作或主要创作者 |
| `url` | string/null | 来源详情地址；不作 ID，不由 Widget 直接请求 |
| `coverUrl` | string/null | 封面来源地址；最终由 Runtime 资源适配获取 |
| `description` | string/null | 搜索/推荐可用的短简介；详情可返回完整版本 |
| `language` | string/null | BCP 47 或来源可稳定提供的语言代码 |
| `status` | enum | `ongoing/completed/hiatus/unknown` |
| `access` | enum | `free/paid/mixed/unknown` |
| `wordCount` | int/null | 当前已知字数，零和未知严格区分 |
| `chapterCount` | int/null | 当前已知章节数 |
| `publishedAt` | timestamp/null | 首次发布时间 |
| `updatedAt` | timestamp/null | 作品或目录最近更新时间 |
| `latestChapter` | object/null | 最新章节标题及可选 ID、URL、更新时间 |
| `categories` | string[] | 题材/分类；空数组表示无可展示值 |
| `tags` | string[] | 来源标签/内容标签；不承载状态 |
| `attributes` | attribute[] | 有界来源扩展信息，键/标签/值均为非空字符串 |

非 null 的 `latestChapter` 固定为：

```json
{
  "id": null,
  "title": "最新章节名称",
  "url": null,
  "updatedAt": null
}
```

## 搜索

```ts
search({ query, cursor, pageSize }) -> {
  items: ContentSummary[],
  nextCursor: string | null,
  totalCount: number | null
}
```

`query` 必须是非空用户输入，cursor 完全不透明。Runtime Facade 结果额外带调用使用的
`pluginId` 和 `sourceName`；插件不重复填写这两个可信投影。

## 发现

```ts
discover({ target, cursor, pageSize }) -> {
  tabs: DiscoveryTab[],
  selectedTabId: string | null,
  sections: DiscoverySection[],
  nextCursor: string | null
}
```

- tab 由 `{id,label,target}` 构成，`target` 只回传给同一插件。
- section layout 限定为 `featured/carousel/ranking/list/categories`。
- 内容分区项包含同一个 `ContentSummary`，以及 nullable `rank/metric/recommendation`。
- 分类分区项包含稳定 `id/title/target`、nullable `count/url`。
- 主项目按插件返回顺序逐个渲染所有 tab、section、内容项和分类项；`layout` 只改变展示方式，
  不得把多个分区压入固定槽位、截断为演示数量、复制首项或丢弃后续分区。只有分类项的结果也
  是有效发现内容，不能误判为空页面。
- 非分类分区的 `categories` 必须是 `[]`；分类分区的 `items` 必须是 `[]`。
- Flutter 只把 layout 当受控展示提示；主题、颜色、间距、可访问性与降级仍由宿主决定。

## 详情、目录和正文

- `getDetail({id})` 返回完整富摘要并增加固定 `aliases` 数组与 nullable `catalogUrl`。
- `getChapters({id,cursor,pageSize})` 返回 `items/nextCursor/totalCount`。每章至少有稳定
  `id/title/order`，并显式返回 nullable `url/volumeTitle/wordCount/updatedAt/isLocked` 与
  非 null `attributes` 数组。
- `getContent({id,chapterId})` 返回固定 `contentKind/chapterId/title/updatedAt/text/pages`。
  小说使用非 null `text` 和空 `pages`；漫画使用 null `text` 和非空有序 `pages`。
- 漫画 `pages` 的 `index` 必须与数组中的零基位置一致；搜索页内内容 ID、目录页内章节 ID、
  同一发现分区内的内容/分类 ID 均不可重复。
- v1 控制面只允许有界内联小说文本；超限正文和图片必须走 Runtime 资源数据面，不能拆成
  Base64 或无界 JSON。

## 校验、错误与日志

Runtime 在插件调用完成、写入 wire 之前校验全部固定键、枚举、URL、时间、计数、唯一性和大小。
缺键、空白必填值、错误 null、超限或条件不一致统一返回 `plugin_invalid_response`；不会把原始
插件对象、标题、URL、正文或异常文本写入日志。

每个 `source.*.v1` 调用复用 `runtime.plugin-invoke` owner span，`operation` 只取
`discover/search/getDetail/getChapters/getContent`，记录 queue wait、duration、结果计数/字节和
稳定终态。搜索词、标题、作者、URL、latestChapter、attributes 和正文一律不进入默认事件。

## 跨仓库验收

- Runtime Node 测试：完整值、全 null、零值、空数组、缺键、空白、非法 URL/时间/枚举、超限。
- Flutter Facade 测试：同一 fixture 解码为强类型，缺少 nullable 键必须失败而不是生成默认值。
- 官方模板：所有固定键均显式填写；离线 fixture 同时覆盖 null、零与空数组。
- 主项目：adapter 只负责显示格式和页面状态，不重新解释 null，不直接请求 `url/coverUrl`。
