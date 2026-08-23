# ADR-0015：标准 Node.js 插件项目与 lockfile 恢复安装

- 状态：Accepted
- 日期：2026-08-14
- 决策者：MgRead 项目
- 细化：[ADR-0002](0002-trusted-plugins.md)、[ADR-0019](0019-development-plugin-live-loading.md)

## 背景

早期方案把插件描述为自定义 `manifest.json` 加单文件 bundle，并规划
`sharedDependencies`、`bundledDependencies` 和 Runtime 自定义 dependency lock。该模型会
重复 npm 已经解决的模块、依赖和本地资源语义；bundle 还会破坏 npm package 内 JSON、Wasm、
字典、模板和相对文件访问。

插件已经被 ADR-0002 定义为可信代码，所有插件又按 ADR-0001 共享一个 Node VM，因此没有
必要为每个插件建立 VM、Context、自定义 ESM Loader 或自定义模块实例隔离。

## 决策

1. MgRead 插件就是标准 Node.js 24 项目。唯一插件元数据位于 `package.json` 的 `mgread`
   对象；不再存在 `manifest.json`。
2. TypeScript 只通过 `tsc` 编译为普通多文件 JavaScript，不 bundle、不 tree-shaking，入口由
   `package.json.main` 指定。
3. 依赖只声明在 `package.json`，精确依赖布局只来自 npm 生成的 `package-lock.json`
   lockfile v3。Runtime 不实现 SemVer 求解，也不运行 npm/pnpm。
4. `sharedDependencies`、`bundledDependencies`、自定义 `dependency-lock.json` 和所有相应
   兼容层全部删除。共享只是 Runtime 的物理存储优化，不是插件协议。
5. Registry package 按 lock 中的 `resolved` 与 `integrity` 下载、校验并完整解压到 Runtime
   内容寻址对象仓。每个插件仍得到普通 `node_modules` 布局；同一对象优先 hardlink 文件，
   hardlink 不可用时逐文件 copy。
6. 首版支持纯 JS、ESM、CommonJS、JSON/字典/模板、Wasm、lock 已确定的 peer layout、简单
   optional dependency，以及只指向包内目录的 `file:./...`。拒绝 Git dependency、包外
   `file:`、安装脚本执行、node-gyp、原生 `.node`/`.so`/`.dll`。
7. Runtime 使用 Node 标准模块解析和模块缓存，不创建插件 VM、第二 Context 或自定义 Loader。
   插件可以直接使用 Node 自带的 `fs`、`crypto`、`buffer`、`stream`、`url`、`path` 和
   `process`。这不是沙箱；Worker/子进程仍不属于受支持插件契约，且单 VM 风险必须明确展示。
8. Runtime 只额外提供 MgRead 能力上下文：`dataDir`、`cacheDir`、`http`、`log`、`app` 和
   `plugin`。安装目录与依赖对象默认只读；插件可变数据只能写入自己的 data/cache 目录。
9. `.mgplugin` 保留，但只是标准 Node 项目的 ZIP 运输容器。默认包含 `package.json`、
   `package-lock.json`、`dist/`、可选 `assets/`、包内 `packages/`、README/LICENSE；默认不含
   `node_modules`。
10. installed 插件版本仍安装到不可变版本目录，更新完整安装后写 `pending`，只在下次 Runtime
    冷启动激活。Windows Debug 的 development 项目例外由 ADR-0019 定义，不进入安装树。依赖 GC
    扫描保留版本的 lockfile 收集 integrity，不维护易漂移的引用计数。

## `package.json` v1 投影

```json
{
  "name": "@mgread-plugin/example",
  "version": "1.2.3",
  "type": "module",
  "main": "dist/index.mjs",
  "engines": { "node": ">=24 <25" },
  "dependencies": {
    "cheerio": "1.1.0",
    "iconv-lite": "0.6.3"
  },
  "mgread": {
    "schemaVersion": 1,
    "id": "org.example.source",
    "pluginApi": 1,
    "contentKinds": ["novel"]
  }
}
```

Runtime 校验 npm name/version、入口相对路径、Node 24 兼容声明、MgRead schema、稳定插件 ID、
API 主版本和内容类型。未知 `mgread.schemaVersion` 或未来 `pluginApi` 必须稳定拒绝，不能把任意
附加字段透传给主项目。

## 后果

正面：

- 插件作者使用 npm/Node 原生心智模型，本地资源和多文件模块自然工作。
- Runtime 不再维护版本求解器、自定义 Resolver 或两套依赖声明。
- 内容仓去重不影响插件可见布局，也不受 symlink realpath 语义影响。
- ESM/CommonJS 和 npm package 的实际行为更接近开发机。

代价与风险：

- 可信插件可读取 Runtime 进程可访问的文件、环境和其他同 VM 状态；这不是安全隔离。
- hardlink 使插件目录与对象仓共享文件实体，因此两者必须由 Runtime 管理为只读；不能允许
  插件修改安装文件。
- Runtime 仍需安全实现 ZIP/tar 路径校验、SRI 校验、原子安装、失败恢复和依赖 GC。
- 不执行 install script 会使依赖 postinstall 才能工作的 package 自然不兼容。

## 迁移

- 旧 `manifest.json` 包、旧模板默认导出、模板专用 Runtime method 和自定义依赖字段不提供
  兼容读取；开发期旧包直接判为 `plugin_package_legacy_unsupported`。
- 官方模板改为标准 `package.json` + `package-lock.json` + 命名导出，旧模板源码与 fixture
  删除。
- Registry 与本地包在公开发布前必须重新打包为新 `.mgplugin`。尚无公开用户数据，因此不做
  双格式迁移器。

## 被拒绝的方案

- 保留 manifest 与 package.json 双写：会持续产生版本、入口和依赖漂移。
- Runtime 自己求解 SemVer：重复 npm 的复杂工作，且难以与开发机布局一致。
- symlink/junction 共享整个 package：Node realpath 与平台权限差异会改变模块解析。
- 每插件 VM/自定义 Loader：与单 VM 和可信插件决策冲突，并增加缓存与 Android 复杂度。
- bundle 作为默认发布格式：破坏 package 内资源语义并隐藏真实依赖图。

## 变更条件

若未来需要不联网安装、第三方不可信插件或原生依赖，必须分别新增 Portable deps、签名/沙箱、
原生 ABI 的替代 ADR；不得在本协议中静默执行安装脚本或放宽原生文件。
