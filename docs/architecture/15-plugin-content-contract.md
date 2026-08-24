# 15 插件内容 API v1

本专题落实 [ADR-0018](adr/0018-recursive-discovery-document.md) 与
[ADR-0020](adr/0020-complete-source-catalog.md)。规范类型、运行时校验与
跨语言 fixture 由 `mg_read_runtime` 维护；本文件固定产品语义，主项目只消费 Runtime Facade
发布的 Dart 强类型。

## 调用链与稳定引用

```text
discover/search -> ContentSummary.id
                         |-> getDetail({ id })
                         |-> getChapters({ id })
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
不同语言各自生成默认值。一般未知附加键可以被 Runtime 丢弃且不会穿透 Facade；完整目录为避免
把旧分页首段误认成全量，结果只允许 `items`。

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

### 热门搜索建议

```ts
searchSuggestions({ cursor, pageSize }) -> {
  items: Array<{ query: string, metric: string | null }>,
  nextCursor: string | null
}
```

这是可选的 `source.searchSuggestions.v1` 能力：书源决定热门词及可展示的短热度文字，宿主不再
内置或混入本地热门词。`query` 是非空、去重的可直接提交搜索词；`metric` 必须显式为字符串或
`null`，不能携带 URL、作者、正文或未脱敏用户数据。尚未实现该扩展的旧 v1 书源返回空列表，
不影响普通搜索；点击任一建议才会发起 `search`。

## 发现

```ts
discover({ target, cursor, collectionId, pageSize }) -> DiscoveryDocumentResult | DiscoveryAppendResult
```

- document 返回 `{kind:'document', document:{components}}`；component 是唯一 ID 的递归联合：
  `tabs/section/group/contentCollection/categoryCollection/text/divider`。tabs 至多一个且只能置于根首。
- `section/group` 的 children 可递归；group 为 vertical/horizontal/grid，内容集合为
  featured/carousel/ranking/list，分类集合为 grid/list。插件不能控制主题、样式或执行代码。
- content collection 承载内容项和 nullable continuation `{target,cursor}`；分类集合承载
  `id/title/target/count/url`。所有 target/cursor 均不透明且只回传同一插件。
- 续页请求同时提供 cursor 与 collectionId，返回 `{kind:'append',collectionId,items,continuation}`；
  collectionId 必须命中当前树的内容集合，宿主仅追加该集合。聚合页没有 continuation 时不展示加载更多。
- 主项目按节点与数组顺序无损渲染；分类集合本身也是有效发现内容。Flutter 只把枚举视作受控展示
  提示，主题、间距、无障碍与降级仍由宿主决定。

## 详情、目录和正文

- `getDetail({id})` 返回完整富摘要并增加固定 `aliases` 数组与 nullable `catalogUrl`。
- `getChapters({id})` 一次返回完整的 `{items}`，`items.length` 就是本次完整章节数；目录不向
  宿主暴露分页字段。目标网站自身有分页时，书源必须在内部追完并按稳定 ID 去重。每章至少有稳定
  `id/title/order`，并显式返回 nullable `url/volumeTitle/wordCount/updatedAt/isLocked` 与
  非 null `attributes` 数组。
- `getContent({id,chapterId})` 返回固定 `contentKind/chapterId/title/updatedAt/text/pages`。
  小说使用非 null `text` 和空 `pages`；漫画使用 null `text` 和非空有序 `pages`。
- 漫画 `pages` 的 `index` 必须与数组中的零基位置一致；搜索页内内容 ID、目录页内章节 ID、
  同一发现分区内的内容/分类 ID 均不可重复。
- v1 控制面只允许有界内联小说文本；超限正文和图片必须走 Runtime 资源数据面，不能拆成
  Base64 或无界 JSON。
- 完整目录最多 5000 章，编码后的目录结果最多 2 MiB；5001 章、重复章节 ID、超限结果或旧
  `cursor/pageSize/nextCursor/totalCount` 形状统一拒绝为 `plugin_invalid_response`。

## Runtime 资源代理数据面

封面、漫画页和其他不适合放入控制面 JSON 的来源资源，通过书源发起、Runtime 托管的本地代理
传递。它的目标是让复杂请求头、Cookie、签名算法和二进制响应始终留在 Node 书源侧；Widget
不得直接请求来源 URL，也不得自行复刻书源 HTTP 逻辑。

### 书源 API

激活上下文提供：

```ts
ctx.resource.proxy(request) -> string
```

`request` 是书源私有的 JSON 对象（最多 16 KiB），Runtime 返回不透明的本地资源 URL。书源将
该 URL 放入 `coverUrl` 或漫画页 URL；App 按普通图片 URL 加载它。URL 不含原始来源地址、Cookie、
token 或用户输入，App 不得解析、拼接、替换或把它当作业务主键。

书源可选导出对应的处理器：

```ts
resource(request) -> {
  status?: number,
  headers?: Record<string, string>,
  body: string | Uint8Array
}
```

当 App 对该 URL 发起 `GET` 时，Runtime 只把保存的私有 `request` 交给同一插件的 `resource()`。
旧插件未导出该函数时稳定返回 `404`，不影响既有内容能力。处理器必须再次校验请求中的来源引用，
并且所有远程访问只能使用 `ctx.http.fetch`；不能信任 URL 已因来自代理令牌而安全，也不能把请求
转交给 Flutter、主应用或第三方子进程。

### 生命周期、响应与安全

- 资源 URL 仅在生成它的 Runtime 进程存活期间有效。Runtime 的 loopback 端口和不透明映射会在
  冷启动时重建，不能把该 URL 当作可跨启动使用的远程地址；需要重新展示时由书源链路重新生成。
- Runtime 只接受 `GET`，代理令牌最多保留 1024 个；达到上限时淘汰最早的条目。调用方必须能将
  代理失败降级为封面/页面加载失败，不能把令牌当成持久文件标识。
- `body` 可为 UTF-8 文本或任意二进制，最大 8 MiB。Runtime 只透传
  `content-type`、`cache-control`、`content-disposition`、`etag`、`expires`、`last-modified`；
  它自行设置长度和默认 `no-store`，拒绝 Cookie、认证、跳转/连接等头。
- 默认诊断不得记录代理 URL、令牌、私有 request、来源 URL、响应头、正文或二进制内容。书源仍须
  用 `ctx.log` 写入有界阶段事件，并让 Runtime 的 HTTP/调用诊断保留唯一终态。

### 开发与验收

新增或修改资源代理时，Runtime 必须覆盖生成 URL、重复 `GET`、二进制 body、状态码、安全响应头
和未知/失效令牌；书源离线测试必须覆盖代理 URL 的生成、请求校验及“拒绝时不发起 HTTP”。来源
请求逻辑变化后，仍按书源规范运行不保存 HTML/正文的 `npm run test:live`。Android 的实际图片加载
属于 Integration Test 验收，不能由 Node 或桌面 Runtime 测试替代。

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
