# 数据源插件开发规范

## 权威入口

开始实现前核对当前版本：

- 官方模板类型：`templates/mg_read_plugin_template/src/mgread-api.ts`
- 官方模板导出：`templates/mg_read_plugin_template/src/index.mts`
- Runtime 上下文：`packages/mg_read_runtime/src/plugin-manager-contract.ts`
- 内容类型与校验：`packages/mg_read_runtime/src/plugin-content-types.ts`、`plugin-content-validation.ts`
- 项目和 artifact：`packages/mg_read_runtime/src/plugin-package.ts`、`plugin-single-file.ts`、`plugin-archive.ts`
- 真实数据源增量规则：`plugins/sources/AGENTS.md`

技能说明用于决策和复核，不能替代这些当前公开类型。

## 项目与生命周期

- 数据源开发项目是标准 Node.js 24 ESM 项目。`package.json.mgread` 是唯一 MgRead 元数据，`package-lock.json` v3 是开发依赖图。
- Runtime 调用 `activate(ctx)` 一次并提供进程期上下文。不要在模块导入阶段访问尚未提供的上下文，也不要自行建立第二 VM、Worker、插件子进程或 native addon。
- 安装版本不可变并在冷启动激活。Windows Debug 的 `plugins/sources/*` 是开发源，可因指纹变化重启唯一 Runtime；它不是安装包的热覆盖持久化。
- 安装目录只读；可变数据只能写 `ctx.dataDir` 或 `ctx.cacheDir`。不要把书架、进度、书签、目录或正文业务权威存进 Runtime 私有目录。

## 内容 API

必需命名导出为 `activate`、`discover`、`search`、`getDetail`、`getChapters`、`getContent`；`searchSuggestions` 和 `resource` 按能力提供。

| 函数 | 输入与输出 | 关键约束 |
| --- | --- | --- |
| `activate(ctx)` | 接收 `MgReadPluginContext` | 只保存公开上下文；日志不能包含 Cookie、token 或正文 |
| `discover(request)` | 首次文档、target 导航或 collection 续页 | target/cursor/collectionId 是插件作用域不透明值；递归布局按发现契约校验 |
| `search(request)` | `query/cursor/pageSize` 到内容摘要和 nextCursor | 默认进入搜索页不自动搜索；只响应用户提交或建议点击 |
| `searchSuggestions(request)` | 可选的来源热门词 | 只能返回来源真实数据，宿主不伪造补齐 |
| `getDetail({id})` | 完整内容详情 | id 必须来自发现或搜索，且稳定可回传 |
| `getChapters({id})` | 一次返回完整目录 | 稳定章节 ID、顺序唯一；最多 5000 章和编码后 2 MiB |
| `getContent({id,chapterId})` | 小说正文或漫画页 | 小说：`text` 非 null、`pages=[]`；漫画：`text=null`、pages 非空有序 |
| `resource(request)` | 私有资源代理响应 | 大媒体走数据面，不进入控制面 JSON/Base64；公开 URL 只由 `ctx.resource.proxy` 生成 |

内容调用链固定为：

```text
discover/search -> content id -> getDetail/getChapters
                                  -> chapter id -> getContent
```

ID、cursor 和 target 不得用数组位置、页面页码、瞬时对象或易变标题代替。URL 可以作为来源元数据，但不是宿主业务主键。

## 数据形状

- 必填标量必须存在且有效；未知或不适用的可空标量保留键并显式返回 `null`。
- 已知零值返回 `0`，不能与未知的 `null` 混用。集合始终返回数组，空集合为 `[]`。
- Runtime 不自动把缺键、空字符串或未知枚举修补成合法值；无效输出统一为 `plugin_invalid_response`。
- 不记录原始响应、正文、搜索词、Cookie、UA、挑战内容或 token。Fixture 只保留选择器、分页、null/0/空集合和错误分支需要的最小脱敏结构。

## `MgReadPluginContext` 能力选择

- 普通无浏览器会话 HTTP 使用 `ctx.http.fetch`。
- 需要页面 JS、真实浏览器 Cookie、用户验证或原生输入时使用 `ctx.webview`，并读取 `webview-api.md`。
- `ctx.browser.sessionV1` 只用于仍依赖兼容 transport 的来源；不要为新代码引入 `sessionKey`。
- 大型或带来源签名的图片、媒体使用 `ctx.resource.proxy(request)`，由 `resource` 导出处理。
- `ctx.log` 只记录有界事件名和非敏感状态；不能把页面 HTML、正文、请求头或异常原文直接写入日志。

### 受保护来源兼容 transport

仅在维护仍依赖 `ctx.browser.sessionV1` 的来源时使用：

- `transport:'webview'` 在宿主 WebView 中执行固定的同源 fetch，Cookie、UA、重定向和同源规则仍由宿主持有。
- `transport:'html'` 用真实 WebView 导航并返回有界的当前 DOM HTML，适合必须解析渲染后页面的来源。
- `transport:'http'` 先允许用户完成真实浏览器验证，再由宿主使用自己的 Cookie/UA 发出有界请求。

Windows 与 Android 必须保留相同的上限、origin、取消、挑战和人工验证语义。不要把兼容接口的 `sessionKey`、Cookie 或 transport 重新暴露给新 `ctx.webview`。

## 缓存

- 数据源私有缓存只用于可重复 GET 的展示投影：发现/搜索默认 10 分钟，详情/目录默认 1 小时。
- 使用哈希键、原子写、single-flight 和有界 LRU；每项最大 1 MiB、每插件最大 100 MiB。
- 刷新失败可读 stale；不得缓存正文、媒体、登录数据、写请求结果或主应用业务数据。
- 缓存失败按 miss 处理，不能让可恢复缓存故障变成来源永久失败。

## 两种发布模式

两种模式彼此独立，不能自动互相降级或把 archive 当作单文件：

### `single-file`

- 默认模式，产物为 `<id>-<version>.mgplugin.js`。
- 使用仓库固定的 esbuild 生成 Node 24 ESM；不 minify、不带 source map 或时间戳，只 externalize Node builtin。
- 首行包含规范化自描述信封、descriptor、代码长度和 SHA-256，可内嵌有界图标。
- 不携带 `node_modules`、源码、Wasm、native binary 或 sidecar。

### `archive`

- 显式模式，产物为确定性 `.mgplugin` ZIP。
- 保留 package、lock、dist、assets、packages 与 lock/SRI 恢复语义。
- 不携带 `node_modules` 或源码，不运行 install script；Runtime 不重新求解 SemVer。

项目工具应导出 `buildPluginArtifact({versionOverride})` 并返回内存中的 bytes、fileName 和 format；只有 CLI 写入磁盘。

## 解析与线上证据

- 先用脱敏 fixture 覆盖结构和错误分支，再做明确授权的网络 smoke。网络失败不能用新 fixture 覆盖旧证据。
- 选择器、菜单文本或历史规则只是规则证据；只有真实响应和实际页面行为才是线上验证。
- 受保护页面必须让用户在真实 WebView 中完成验证。禁止 token 抽取、回放、绕过脚本、CDP 或 DOM 合成交互。
