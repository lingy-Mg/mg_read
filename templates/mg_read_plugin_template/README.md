# MgRead 标准 Node 插件模板

这是新的官方空白项目。插件开发仍是普通 Node.js 24 项目：npm 负责开发机上的依赖求解，
TypeScript 由 `tsc` 编译为多个 JavaScript 文件；发布默认用精确 `esbuild 0.28.2` 合并为一个
自描述 ESM artifact。项目没有 `manifest.json`、共享依赖声明、自定义 lock、插件 VM 或 Runtime
私有协议。

## 目录

```text
mg_read_plugin_template/
├─ package.json              # Node、依赖和唯一 mgread 元数据
├─ package-lock.json         # npm 开发复现用；只有 archive 发布必需
├─ src/                      # TypeScript 与由代码 import 的 JSON
├─ dist/                     # tsc 多文件开发输出
├─ packages/example-parser/  # 包内 file: Node package 示例
├─ tools/mgread.mjs          # single-file/显式 archive 确定性 pack
└─ test/
```

`dist/index.mjs` 命名导出：

```js
export async function activate(ctx) {}
export async function discover(request) {}
export async function search(request) {}
export async function getDetail(request) {}
export async function getChapters(request) {}
export async function getContent(request) {}
```

`package.json` 是开发项目元数据的唯一入口：`mgread` 对象保存 MgRead 元数据，
`main` 必须指向构建后的 `dist/` 内入口。不要把元数据复制到其他文件，也不要让 `main`
指向源码或 `node_modules`。`mgread.displayName` 是 UI 显示的来源名，npm `name`
不是 UI 文案。Runtime 会先冷激活该不可变版本一次，再按需调用这六个
必需命名导出；能提供热门搜索词的数据源插件可额外导出 `searchSuggestions`。它们不是应用自行发现的
默认导出，也不应改名。

- `activate(ctx)`：生命周期初始化点。只在此保存 Runtime 提供的上下文、读取只读资源和建立
  可复用的轻量状态；不要在模块顶层做依赖 `ctx` 的工作，也不要在这里启动 Worker、子进程或
  长期阻塞任务。
- `discover(request)`：返回递归受控组件 document，或对指定内容集合的 append；支持 tabs、
  section/group、内容/分类集合、文本和分隔线。target、cursor、collectionId 都只回传给当前插件；
  不能下发任意样式、Flutter 组件或脚本。tab、section 和 category 可声明 `mgread-api.ts` 中的可选
  `DiscoveryIcon` 语义名；同一图标系统由宿主统一渲染，不能传字体码点、颜色、尺寸或图片 URL。
- `search({query,cursor,pageSize})`：返回 `items/nextCursor/totalCount`。每个 item 都包含书名、
  内容类型，以及显式 nullable 的作者、URL、封面、简介、字数、章节数、更新时间、最新章节等
  字段；`id` 必须是后续 `getDetail`、`getChapters` 能识别的稳定来源 ID。
- `getDetail({id})`、`getChapters({id})`：接收前一步的稳定 ID，分别返回完整内容元信息与单次
  完整 `{items}` 章节列表。网站自身分页必须由数据源插件内部追完并去重；不得返回目录 cursor，目录
  最多 5000 章且编码结果最多 2 MiB。
  不要把页码、像素位置等 UI 状态当作 ID 或进度语义。
- `getContent({id,chapterId})`：接收内容和章节稳定 ID，返回该章节内容。正文和大对象不要写入日志、
  `package.json` 或静态元数据。

### 空值只有一种表达

- 必填的 `id/title/contentKind` 等字段不得为 null 或空白。
- 可空标量的键也必须存在；未知或不适用时返回 JSON `null`，禁止省略、返回 `undefined`、空字符串、
  `0`、`false` 或“未知”文案。
- `0` 是有效计数；例如 `wordCount: 0` 表示已知为零，未知必须是 `wordCount: null`。
- `categories/tags/attributes/items/pages` 等集合始终返回数组，没有内容时返回 `[]`，不能返回 null。
- `status/access` 使用固定枚举的 `unknown`，不使用 null。
- 来源特有元信息写入有界 `attributes[{key,label,value}]`，不要添加任意 Map 让 Flutter 猜测。

模板的 `src/mgread-api.ts`、`src/source.ts` 与测试完整演示这些字段和 null/零/空数组差异；
Runtime 会拒绝缺少固定 nullable 键的插件响应。

`ctx` 只补充 MgRead 能力：`dataDir`、`cacheDir`、`http`、`log`、`app`、`plugin`。Node 已有的
`fs`、`crypto`、`buffer`、`stream`、`url`、`path` 和 `process` 直接使用，不由 SDK 再包装。
插件安装目录只读，可变内容只能写到 `dataDir`/`cacheDir`。默认 single-file 只支持由 JavaScript
import 并内联的 JSON；不能在运行时读取 sidecar。需要字典、模板、Wasm 或其他相对文件资源的作者
必须显式选择 `mgread.packageMode: "archive"`，工具不会自动回退。`mgread.icon` 是唯一声明式资源，
会被校验并内嵌进信封。

### 缓存

缓存仅用于可重复的无副作用远程 GET 展示投影：发现/分类/搜索列表使用 10 分钟刷新窗，详情和
章节目录使用 1 小时刷新窗。缓存必须在 Runtime 提供的绝对 `ctx.cacheDir` 下建立版本化子目录，
以规范化请求 SHA-256 为键，单条不超过 1 MiB、插件总量不超过 100 MiB 并按 LRU 淘汰；同键并发
请求合并，过期后先刷新，刷新失败才使用旧值。必须原子写入，缓存失败视作未命中。

不得缓存正文、漫画/封面等媒体字节、Cookie/凭据/登录态、写操作响应或主应用拥有的业务数据；
不得从 `cwd` 或其他路径推导缓存位置。跨文件边界见
[核心插件规范](../../docs/core.md#标准插件项目artifact-与安装)，具体行为由本模板测试固定。

## 开发与打包

使用 Node `24.16.0`、npm `11.13.0`：

```powershell
npm ci
npm test
npm run verify
npm run pack:plugin
```

`npm test` 是开发期间的必跑离线回归，不能依赖目标网站；`npm run verify` 是交付前门槛，包含
类型检查、离线测试和标准插件打包。真实数据源插件在来源解析或请求规则变化后还必须执行一次
`npm run test:live`，验证分类、搜索、详情、目录和正文。线上 smoke 不作为常规 CI 的唯一测试，
但失败时不能宣称该来源完成。

在 MgRead monorepo 的 Windows Debug 应用中，模板派生的 `plugins/sources/*` 开发项目直接从
工作区加载；运行数据源插件自己的 `tsc --watch`/build 更新 `dist/` 后，下一次数据源调用会有序重启开发
Runtime 并使用新代码，不需要 pack、复制或安装。下面的 pack 命令只用于 installed 插件和
Android 安装测试。

因此电脑端可以直接测试插件：先运行 `npm test` 验证 Node 代码，再启动/使用 Windows Debug
应用实际调用数据源验证 Runtime Facade 链路。Windows 直测只证明 development 工作区加载；Android
和发布仍必须使用正式插件 artifact 安装路线。

若希望使用讨论中的原样命令，可在这个模板目录执行一次 `npm link`，随后直接运行：

```powershell
mgread pack
```

输出位于 `artifacts/org.example.source-0.1.2.mgplugin.js`。首行是规范化 Base64URL 信封，随后是
Node 24 ESM bundle；不含 lock、源码、`node_modules`、sidecar、时间戳、source map 或 minify。
信封、可选图标、完整 artifact 上限分别为 512 KiB、256 KiB、32 MiB。Runtime 不运行 npm、
pnpm 或 install scripts，也不支持 Git/native addon。

## 开始一个真实插件

1. 修改 npm `name`、`version` 和 `mgread.id`，ID 发布后保持稳定。
2. 保持生产依赖精确版本；执行 `npm install --save-exact <package>` 更新 package-lock。
   需要拆分本地纯 JS/ESM/CommonJS 辅助包时，只能使用 `packages/` 下的相对 `file:` 依赖，
   例如模板的 `file:./packages/example-parser`；默认发布会把其实际引用代码合并进 single-file，
   但不能使用 Git 依赖、native addon 或安装期构建。
3. 替换 `src/source.ts` 的离线占位逻辑；不要把凭据、Cookie 或真实用户数据提交到项目。
4. JSON 用 JavaScript import 进入默认 single-file；其他 sidecar 资源需显式选择 archive。
5. 运行 `npm run verify` 和 `mgread pack`，再交给 Runtime 安装。

首版插件是可信代码，不是沙箱。Worker、子进程、原生 addon 和同步阻塞代码不属于支持契约；
一个插件阻塞事件循环会影响同一 Node VM 中的全部插件。

`tools/mgread.mjs` 是模板自包含的发布工具，不是 Runtime SDK。它导出只返回内存产物的
`buildPluginArtifact({versionOverride})` 供显式 development sync 复用，CLI 才写 `artifacts/`。
single-file 构建只允许 Node builtin external，并对 unresolved/dynamic import、sidecar、
Wasm/native/binary 和超限资源明确失败；显式 archive 保留确定性 ZIP 与 lock 恢复。两种模式都不
打包 `node_modules`，也不执行 install script。
