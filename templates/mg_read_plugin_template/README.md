# MgRead 标准 Node 插件模板

这是新的官方空白项目。插件就是普通 Node.js 24 项目：npm 负责开发机上的依赖求解，
TypeScript 只由 `tsc` 编译为多个 JavaScript 文件，Runtime 根据 lockfile 恢复普通
`node_modules`。项目没有 `manifest.json`、bundle、共享依赖声明、自定义 lock、插件 VM 或
Runtime 私有协议。

## 目录

```text
mg_read_plugin_template/
├─ package.json              # Node、依赖和唯一 mgread 元数据
├─ package-lock.json         # npm lockfile v3，发布必需
├─ src/                      # TypeScript，多文件源码
├─ dist/                     # tsc 输出，不 bundle
├─ assets/rules.json         # 插件自己的只读资源
├─ packages/example-parser/  # 包内 file: Node package 示例
├─ tools/mgread.mjs          # 自包含的 mgread pack
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

`package.json` 是 Runtime 识别插件的唯一入口：`mgread` 对象保存 MgRead 元数据，
`main` 必须指向构建后的 `dist/` 内入口。不要把元数据复制到其他文件，也不要让 `main`
指向源码、bundle 或 `node_modules`。`mgread.displayName` 是 UI 显示的来源名，npm `name`
不是 UI 文案。Runtime 会先冷激活该不可变版本一次，再按需调用这六个
命名导出；它们不是应用自行发现的默认导出，也不应改名。

- `activate(ctx)`：生命周期初始化点。只在此保存 Runtime 提供的上下文、读取只读资源和建立
  可复用的轻量状态；不要在模块顶层做依赖 `ctx` 的工作，也不要在这里启动 Worker、子进程或
  长期阻塞任务。
- `discover(request)`：返回递归受控组件 document，或对指定内容集合的 append；支持 tabs、
  section/group、内容/分类集合、文本和分隔线。target、cursor、collectionId 都只回传给当前插件；
  不能下发任意样式、Flutter 组件或脚本。
- `search({query,cursor,pageSize})`：返回 `items/nextCursor/totalCount`。每个 item 都包含书名、
  内容类型，以及显式 nullable 的作者、URL、封面、简介、字数、章节数、更新时间、最新章节等
  字段；`id` 必须是后续 `getDetail`、`getChapters` 能识别的稳定来源 ID。
- `getDetail({id})`、`getChapters({id,cursor,pageSize})`：接收前一步的稳定 ID，分别返回完整
  内容元信息与分页章节列表。
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
插件安装目录只读，可变内容只能写到 `dataDir`/`cacheDir`。资源文件可随插件置于 `assets/` 或
包内目录，并用 `new URL(..., import.meta.url)` 读取，不能假定 `process.cwd()` 是插件根目录。

### 缓存

缓存仅用于可重复的无副作用远程 GET 展示投影：发现/分类/搜索列表使用 10 分钟刷新窗，详情和
章节目录使用 1 小时刷新窗。缓存必须在 Runtime 提供的绝对 `ctx.cacheDir` 下建立版本化子目录，
以规范化请求 SHA-256 为键，单条不超过 1 MiB、插件总量不超过 100 MiB 并按 LRU 淘汰；同键并发
请求合并，过期后先刷新，刷新失败才使用旧值。必须原子写入，缓存失败视作未命中。

不得缓存正文、漫画/封面等媒体字节、Cookie/凭据/登录态、写操作响应或主应用拥有的业务数据；
不得从 `cwd` 或其他路径推导缓存位置。完整规则和测试矩阵见
[标准插件规范](../../docs/architecture/04-plugin-sdk-packaging-registry.md#插件私有缓存规则)。

## 开发与打包

使用 Node `24.16.0`、npm `11.13.0`：

```powershell
npm ci
npm run verify
npm run pack:plugin
```

在 MgRead monorepo 的 Windows Debug 应用中，模板派生的 `plugins/sources/*` 开发项目直接从
工作区加载；运行来源自己的 `tsc --watch`/build 更新 `dist/` 后，下一次来源调用会有序重启开发
Runtime 并使用新代码，不需要 pack、复制或安装。下面的 pack 命令只用于 installed 插件和
Android 安装测试。

若希望使用讨论中的原样命令，可在这个模板目录执行一次 `npm link`，随后直接运行：

```powershell
mgread pack
```

输出位于 `artifacts/org.example.source-0.1.0.mgplugin`。容器只含 `package.json`、
`package-lock.json`、`dist/`、`assets/`、包内 `packages/`、`tools/`、README/LICENSE，不含
`node_modules`。Runtime 不运行 npm、pnpm 或 install scripts，也不支持 Git/native addon。

## 开始一个真实插件

1. 修改 npm `name`、`version` 和 `mgread.id`，ID 发布后保持稳定。
2. 保持生产依赖精确版本；执行 `npm install --save-exact <package>` 更新 package-lock。
   需要拆分本地纯 JS/ESM/CommonJS 辅助包时，只能使用 `packages/` 下的相对 `file:` 依赖，
   例如模板的 `file:./packages/example-parser`；它会随源码进入 `.mgplugin`，但不能使用
   Git 依赖、native addon 或安装期构建。
3. 替换 `src/source.ts` 的离线占位逻辑；不要把凭据、Cookie 或真实用户数据提交到项目。
4. JSON、Wasm、字典和模板直接保留在 package/asset 中并用标准 Node 相对 URL 读取。
5. 运行 `npm run verify` 和 `mgread pack`，再交给 Runtime 安装。

首版插件是可信代码，不是沙箱。Worker、子进程、原生 addon 和同步阻塞代码不属于支持契约；
一个插件阻塞事件循环会影响同一 Node VM 中的全部插件。

`tools/mgread.mjs` 是模板自包含的校验与 ZIP 打包工具，不是 Runtime SDK：不要为了“方便”放宽
它对 `mgread` 元数据、`main` 位置、普通文件、项目内路径或 `node_modules` 的检查。`.mgplugin`
只是传输容器，Runtime 将依据随包的 `package-lock.json` 恢复依赖；因此工具刻意不打包
`node_modules`，也不执行任何 install script。
