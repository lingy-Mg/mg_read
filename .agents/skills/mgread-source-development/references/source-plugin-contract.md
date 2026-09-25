# 单来源开发与项目契约

## 适用范围

用于新建来源、修改单个来源能力，或处理项目结构、缓存、资源代理、artifact、安装和开发加载。先读取
`plugins/sources/AGENTS.md`、目标来源的 `package.json`、入口、直接测试和一个最接近的真实来源；仓库不维护
空白官方模板。

事实入口：

- 唯一宿主 Context 声明：`packages/mg_read_source_api/index.d.ts`
- Runtime Context 与内容校验：`packages/mg_read_node_runtime/src/plugin-manager-contract.ts`、
  `plugin-content-types.ts`、`plugin-content-validation.ts`
- 项目与 artifact：`plugin-package.ts`、`plugin-single-file.ts`、`plugin-archive.ts`

不要从本参考推断当前字段或版本；共享类型、Runtime 校验和测试是事实来源。

## 实现边界

- 来源是 Node.js 24 ESM 项目，`package.json.mgread` 是唯一 MgRead 元数据。
- 在 `.ts`/`.mts` 中从 `@mgread/source-api` 使用 `import type`；来源可以声明自己的内容结果类型，但不能复制
  `MgReadPluginContext`、`PluginWebViewPage`、`PluginWebViewApi` 或其字段子集。
- 模块导入不得访问未注入 Context；`activate(ctx)` 只保存公开上下文，不创建 Worker、子进程、native addon、
  第二 VM 或自定义 loader。
- 标准链路是 `discover/search/getDetail/getChapters/getContent`。必填值存在，未知值显式 `null`，零值不是未知，
  集合始终为数组；稳定 ID 不能用标题、索引或页码代替。
- 私有缓存按项目声明区分发现/搜索与详情/目录；stale 可读、刷新单飞、失败按 miss。日志记录能力阶段和结果。

## 内容与资源

小说返回 `text`，漫画返回有序 `pages`，音频/视频返回资源描述。封面和内容资源先校验协议、origin、路径和
必要 headers，再交给 `ctx.resource.proxy`；loopback URL 中的描述是可逆编码，不提供加密或认证。

若当前来源涉及发现组合、媒体或 WebView，只增加入口中对应的一个条件参考。实现后按
[content-validation-matrix.md](content-validation-matrix.md)选择该 `contentKind` 的验证，不把“返回非空对象”
当成内容可用。

## Artifact 与开发生命周期

- 数据源代码强制构建为单个 Node 24 ESM JS。`single-file` 发布 `.mgplugin.js`；`archive` 发布 `.mgplugin`
  压缩包，内部同样是单个 JS 入口及元数据、图标。压缩包没有 npm 依赖恢复语义。
- Rust/Wasm 二进制内核模式使用 `@mgread/source-wasm` ABI v1，并把 `.wasm` 字节与适配器内嵌到同一 JS。
  来源路由、解析与公开结果在 Rust 内实现，IO 通过公开 Context 继续执行；参考 `aisishuwu-wasm`，验证时必须
  分列 Rust/ABI 测试、冷安装、Windows Facade/EXE 与 Android 真正执行结果，不能以编译成功替代平台验收。
- 开发项目可用 npm 管理构建工具和源码依赖，但构建必须启用 bundle、禁用 splitting，并内联所有使用的
  第三方包；仅 Node.js 内置模块可外置。不得用 external 或 packages: external 绕过打包。
- 产物不得包含源码、lock、本地依赖目录或 `node_modules`；descriptor、图标、大小、SHA-256 和包内容必须可复核。
- 不新增引用扫描、动态 import 检查、依赖白名单扫描或自定义 loader。打包要求由构建配置落实，
  导入、安装、导出、同步、删除不下载、恢复、管理或统计 npm 依赖。
- Windows 开发根只在静默窗口后执行来源声明的 `npm run build`，不加载 TypeScript、不启动 watch、也不自动
  安装依赖。generation 只加载打包后的单个 JS，不复制或链接项目依赖目录。候选 build 与 activate
  都成功后才替换 generation；失败保留旧版本。
- Runtime 启动优先建立已校验元数据快照，来源代码在首次能力调用或传输时单飞加载。诊断来源数量与启动性能时
  测量实际扫描、快照、加载事件和首次调用，不根据目录数猜测。

通用 Source API 或生命周期变化先修改 `packages/mg_read_source_api` 的公开声明，再同步 Runtime 实现与校验、
wire/Facade/Flutter 宿主中真实受影响的边界、直接测试和一个参考来源。不要为单一站点把来源专用字段扩展成
公共协议；稳定的跨模块约束才更新对应核心章节。

## 完成条件

使用固定 Node/npm 运行来源声明的 typecheck、fixture/离线测试和 `verify`；请求、选择器、分页或解析变化才加
`test:live`。构建声明的 artifact 并验证确定性和包内容；安装语义变化时使用临时 Runtime 数据根做冷安装与
激活。最后按 [source-testing-workflow.md](source-testing-workflow.md)执行适用的 Node/App CLI 验收。
